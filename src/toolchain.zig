//! Linux -> iOS toolchain discovery (xtool Darwin SDK bundle + a modern
//! Swift-toolchain clang/swiftc) and the compiler/linker flag sets.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const config = @import("config.zig");
const plist = @import("plist.zig");

const Allocator = std.mem.Allocator;

pub const Toolchain = struct {
    a: Allocator,
    cfg: config.ToolchainConfig,
    root: []const u8,
    env: std.process.Environ.Map,
    sdk_bundle: []const u8,
    sdk: ?[]const u8,
    sdk_version: ?[]const u8,
    swift_resource_dir: []const u8,
    platform_lib_dir: []const u8,
    ld64: []const u8,
    clang_rt: ?[]const u8,
    cc: ?[]const u8,
    cxx: ?[]const u8,
    swiftc: ?[]const u8,
    identities: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(a: Allocator, cfg: config.ToolchainConfig, root: []const u8) !Toolchain {
        var env = try sys.envMap(a);
        const swiftly_bin = try fsutil.expandHome(a, cfg.swiftly_bin, &env);
        // Append (never prepend) so host tools keep priority, like the old Makefiles.
        const old_path = env.get("PATH") orelse "/usr/bin:/bin";
        try env.put("PATH", try std.fmt.allocPrint(a, "{s}:{s}", .{ old_path, swiftly_bin }));
        const path_env = env.get("PATH").?;
        // $(GIT_BRANCH) / $(GIT_COMMIT) for Info.plist and entitlements (environment wins).
        for ([_]struct { []const u8, []const []const u8 }{
            .{ "GIT_BRANCH", &.{ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" } },
            .{ "GIT_COMMIT", &.{ "git", "-C", root, "log", "-1", "--format=%h" } },
        }) |entry| if (env.get(entry[0]) == null) {
            const value = if (sys.run(a, entry[1], .{})) |r|
                (if (sys.succeeded(r.term)) std.mem.trim(u8, r.stdout, " \n\r") else "unknown")
            else |_| "unknown";
            try env.put(entry[0], value);
        };

        const bundle = try fsutil.expandHome(a, cfg.sdk_bundle, &env);
        const sdks_dir = try std.Io.Dir.path.join(a, &.{ bundle, "Developer/Platforms/iPhoneOS.platform/Developer/SDKs" });
        const sdk = if (cfg.sdk) |s| try fsutil.expandHome(a, s, &env) else try newestEntry(a, sdks_dir, "iPhoneOS", ".sdk");
        const toolchain_lib = try std.Io.Dir.path.join(a, &.{ bundle, "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib" });
        const clang_rt = blk: {
            const clang_dir = try std.Io.Dir.path.join(a, &.{ toolchain_lib, "clang" });
            const version = try newestEntry(a, clang_dir, "", "") orelse break :blk null;
            const p = try std.Io.Dir.path.join(a, &.{ version, "lib/darwin/libclang_rt.ios.a" });
            break :blk if (fsutil.kindFollow(p) == .file) p else null;
        };
        return .{
            .a = a,
            .cfg = cfg,
            .root = root,
            .env = env,
            .sdk_bundle = bundle,
            .sdk = sdk,
            .sdk_version = if (sdk) |s| sdkVersion(a, s) else null,
            .swift_resource_dir = try std.Io.Dir.path.join(a, &.{ toolchain_lib, "swift" }),
            .platform_lib_dir = try std.Io.Dir.path.join(a, &.{ bundle, "Developer/Platforms/iPhoneOS.platform/Developer/usr/lib" }),
            .ld64 = try std.Io.Dir.path.join(a, &.{ bundle, "toolset/bin/orig/ld64.lld" }),
            .clang_rt = clang_rt,
            .cc = try fsutil.which(a, cfg.cc, path_env),
            .cxx = try fsutil.which(a, cfg.cxx, path_env),
            .swiftc = try fsutil.which(a, cfg.swiftc, path_env),
        };
    }

    pub fn pathEnv(t: *const Toolchain) []const u8 {
        return t.env.get("PATH").?;
    }

    /// Fail with a precise message if anything a direct build needs is missing.
    pub fn require(t: *const Toolchain, need_swift: bool) !void {
        if (t.sdk == null) return diag.fail("no iPhoneOS*.sdk under {s} (run: xtool setup)", .{t.sdk_bundle});
        if (fsutil.kindFollow(t.sdk.?) != .dir) return diag.fail("SDK not found: {s}", .{t.sdk.?});
        if (fsutil.kindFollow(t.ld64) == .missing) return diag.fail("missing toolchain path: {s} (run: xtool setup)", .{t.ld64});
        if (t.clang_rt == null) return diag.fail("libclang_rt.ios.a not found in {s} (run: xtool setup)", .{t.sdk_bundle});
        if (t.cc == null) return diag.fail("missing tool: {s} (install a Swift toolchain with swiftly)", .{t.cfg.cc});
        if (need_swift) {
            if (t.swiftc == null) return diag.fail("missing tool: {s}", .{t.cfg.swiftc});
            if (fsutil.kindFollow(t.swift_resource_dir) != .dir) return diag.fail("missing toolchain path: {s}", .{t.swift_resource_dir});
        }
    }

    pub fn triple(t: *const Toolchain, target: config.Target) ![]const u8 {
        return std.fmt.allocPrint(t.a, "{s}-apple-ios{s}", .{ target.arch, target.min_ios });
    }

    pub const Lang = enum { c, objc, cxx, objcxx, asm_, swift };

    pub fn langOf(path: []const u8) ?Lang {
        const sfx = fsutil.suffix(path);
        const table = [_]struct { []const u8, Lang }{
            .{ ".c", .c },         .{ ".m", .objc },  .{ ".mm", .objcxx }, .{ ".cc", .cxx },
            .{ ".cpp", .cxx },     .{ ".cxx", .cxx }, .{ ".s", .asm_ },    .{ ".S", .asm_ },
            .{ ".swift", .swift },
        };
        for (table) |e| if (std.mem.eql(u8, e[0], sfx)) return e[1];
        return null;
    }

    /// clang flags for one C-family source (without -c/-o).
    pub fn cflags(t: *const Toolchain, target: config.Target, lang: Lang, module_cache: []const u8) ![]const []const u8 {
        var f: std.ArrayList([]const u8) = .empty;
        try f.appendSlice(t.a, &.{ "-target", try t.triple(target), "-isysroot", t.sdk.?, target.opt, if (target.debug_symbols) "-g" else "-g0", "-fmodules", try std.fmt.allocPrint(t.a, "-fmodules-cache-path={s}", .{module_cache}), "-fno-common", "-MMD", "-MP" });
        switch (lang) {
            .objc => try f.appendSlice(t.a, &.{ "-fobjc-arc", "-fobjc-weak", "-std=gnu17" }),
            .cxx => try f.appendSlice(t.a, &.{ "-std=gnu++20", "-stdlib=libc++" }),
            .objcxx => try f.appendSlice(t.a, &.{ "-fobjc-arc", "-fobjc-weak", "-std=gnu++20", "-stdlib=libc++" }),
            .c, .asm_, .swift => {},
        }
        for (target.include_dirs) |inc| try f.appendSlice(t.a, &.{ "-I", try target.path(t.a, inc) });
        for (target.quote_include_dirs) |d| try f.appendSlice(t.a, &.{ "-iquote", try target.path(t.a, d) });
        for (target.framework_dirs) |d| try f.appendSlice(t.a, &.{ "-F", try target.path(t.a, d) });
        if (target.type == .appex) try f.append(t.a, "-fapplication-extension");
        for (target.defines) |d| try f.append(t.a, try std.fmt.allocPrint(t.a, "-D{s}", .{d}));
        try f.appendSlice(t.a, target.cflags);
        return f.items;
    }

    pub fn swiftflags(t: *const Toolchain, target: config.Target, module_cache: []const u8) ![]const []const u8 {
        var f: std.ArrayList([]const u8) = .empty;
        try f.appendSlice(t.a, &.{
            "-target",        try t.triple(target), "-sdk",               t.sdk.?,
            "-resource-dir",  t.swift_resource_dir, "-I",                 t.platform_lib_dir,
            "-L",             t.platform_lib_dir,   "-module-cache-path", module_cache,
            target.swift_opt, "-wmo",               "-suppress-warnings", "-module-name",
            target.name,
        });
        if (target.debug_symbols) try f.append(t.a, "-g");
        if (target.bridging_header) |h| try f.appendSlice(t.a, &.{ "-import-objc-header", try target.path(t.a, h) });
        for (target.include_dirs) |inc| try f.appendSlice(t.a, &.{ "-I", try target.path(t.a, inc) });
        for (target.quote_include_dirs) |d| try f.appendSlice(t.a, &.{ "-Xcc", "-iquote", "-Xcc", try target.path(t.a, d) });
        for (target.framework_dirs) |d| try f.appendSlice(t.a, &.{ "-F", try target.path(t.a, d) });
        if (target.type == .appex) try f.append(t.a, "-application-extension");
        // Swift conditions are flags only; NAME=VALUE defines apply to C-family code.
        for (target.defines) |d| if (std.mem.indexOfScalar(u8, d, '=') == null) try f.append(t.a, try std.fmt.allocPrint(t.a, "-D{s}", .{d}));
        try f.appendSlice(t.a, target.swiftflags);
        return f.items;
    }

    /// Linker inputs shared by clang and swiftc drivers: frameworks, libraries, extra flags.
    fn linkInputs(t: *const Toolchain, f: *std.ArrayList([]const u8), target: config.Target, need_cxx: bool) !void {
        for (target.framework_dirs) |d| try f.appendSlice(t.a, &.{ "-F", try target.path(t.a, d) });
        for (target.frameworks) |fw| try f.appendSlice(t.a, &.{ "-framework", stripFramework(fw) });
        for (target.weak_frameworks) |fw| try f.appendSlice(t.a, &.{ "-weak_framework", stripFramework(fw) });
        for (target.libraries) |l| try f.append(t.a, try std.fmt.allocPrint(t.a, "-l{s}", .{l}));
        if (need_cxx) try f.append(t.a, "-lc++");
        // Xcode's default LD_RUNPATH_SEARCH_PATHS, so embedded frameworks resolve.
        try f.appendSlice(t.a, &.{ "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks" });
        switch (target.type) {
            .framework, .dylib => {
                if (target.type == .framework) try f.appendSlice(t.a, &.{ "-Xlinker", "-rpath", "-Xlinker", "@loader_path/Frameworks" });
                const install = if (target.type == .framework)
                    try std.fmt.allocPrint(t.a, "@rpath/{s}.framework/{s}", .{ target.name, target.name })
                else
                    try std.fmt.allocPrint(t.a, "@rpath/{s}.dylib", .{target.name});
                try f.appendSlice(t.a, &.{ "-Xlinker", "-install_name", "-Xlinker", install });
            },
            // Extensions live in <app>/PlugIns/<name>.appex and load the app's frameworks.
            .appex => try f.appendSlice(t.a, &.{ "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks", "-Xlinker", "-application_extension" }),
            .app, .static => {},
        }
        if (target.dead_strip) try f.appendSlice(t.a, &.{ "-Xlinker", "-dead_strip" });
        for (target.ldflags) |l| try f.appendSlice(t.a, &.{ "-Xlinker", l });
    }

    pub fn clangLink(t: *const Toolchain, target: config.Target, objects: []const []const u8, out: []const u8, need_cxx: bool) ![]const []const u8 {
        var f: std.ArrayList([]const u8) = .empty;
        try f.appendSlice(t.a, &.{
            if (need_cxx) t.cxx orelse t.cc.? else t.cc.?, "-target",                                               try t.triple(target), "-isysroot", t.sdk.?,
            "-fuse-ld=lld",                                try std.fmt.allocPrint(t.a, "--ld-path={s}", .{t.ld64}), "-Wl,-headerpad_max_install_names", t.clang_rt.?,
        });
        if (target.type == .framework or target.type == .dylib) try f.append(t.a, "-dynamiclib");
        try f.appendSlice(t.a, objects);
        try f.appendSlice(t.a, &.{ "-o", out });
        try t.linkInputs(&f, target, need_cxx);
        return f.items;
    }

    pub fn swiftLink(t: *const Toolchain, target: config.Target, module_cache: []const u8, swift_sources: []const []const u8, objects: []const []const u8, out: []const u8, need_cxx: bool) ![]const []const u8 {
        var f: std.ArrayList([]const u8) = .empty;
        try f.append(t.a, t.swiftc.?);
        try f.appendSlice(t.a, try t.swiftflags(target, module_cache));
        try f.appendSlice(t.a, &.{
            "-use-ld=lld", try std.fmt.allocPrint(t.a, "-ld-path={s}", .{t.ld64}),
            "-Xlinker",    "-headerpad_max_install_names",
            "-Xlinker",    t.clang_rt.?,
        });
        if (target.type == .framework or target.type == .dylib) try f.append(t.a, "-emit-library");
        try f.appendSlice(t.a, swift_sources);
        try f.appendSlice(t.a, objects);
        try f.appendSlice(t.a, &.{ "-o", out });
        try t.linkInputs(&f, target, need_cxx);
        return f.items;
    }

    /// Probe once per invocation. The identity includes version output and
    /// executable bytes, not just the configured path (swiftly uses proxies).
    pub fn identity(t: *Toolchain, path: []const u8, probe: bool) ![]const u8 {
        return t.identityWithArg(path, if (probe) "--version" else null);
    }

    pub fn signerIdentity(t: *Toolchain) ![]const u8 {
        return t.identityWithArg(try t.ldid(), "-h");
    }

    fn identityWithArg(t: *Toolchain, path: []const u8, probe_arg: ?[]const u8) ![]const u8 {
        if (t.identities.get(path)) |id| return id;
        const resolved = sys.realpath(t.a, path) catch return diag.fail("missing tool: {s}", .{path});
        var f: @import("buildstate.zig").Fingerprint = .{};
        f.add(path);
        f.add(try @import("buildstate.zig").treeDigest(t.a, resolved));
        if (probe_arg) |arg| {
            const result = sys.run(t.a, &.{ path, arg }, .{ .env = &t.env, .max_output_bytes = 1 << 20 }) catch |err|
                return diag.fail("cannot execute {s}: {s}", .{ path, @errorName(err) });
            if (!sys.succeeded(result.term))
                return diag.fail("{s} {s} failed; check the executable and shared runtime: {s}", .{ path, arg, result.stderr });
            f.add(result.stdout);
            f.add(result.stderr);
        }
        const id = try f.finish(t.a);
        try t.identities.put(t.a, path, id);
        return id;
    }

    pub fn selfIdentity(t: *Toolchain) ![]const u8 {
        return t.identity(try sys.selfExePath(t.a), false);
    }

    // ------------------------------------------------------------- ldid

    /// Resolve ldid (a path, or a name looked up on PATH). idl never installs tools.
    pub fn ldid(t: *const Toolchain) ![]const u8 {
        const p = try fsutil.expandHome(t.a, t.cfg.ldid, &t.env);
        return (try fsutil.which(t.a, p, t.pathEnv())) orelse
            diag.fail("missing tool: ldid ({s} not found on PATH). Install ldid (https://github.com/ProcursusTeam/ldid) or set toolchain.ldid; set `sign: false` to skip signing", .{p});
    }

    // ---------------------------------------------------------- actool

    fn findActool(t: *const Toolchain) !?[]const u8 {
        const p = try fsutil.expandHome(t.a, t.cfg.actool, &t.env);
        if (try fsutil.which(t.a, p, t.pathEnv())) |found| return found;
        if (std.mem.indexOfScalar(u8, p, '/') != null) return null;
        // `zig build actool` installs it next to idl.
        const self_dir = sys.selfExeDirPath(t.a) catch return null;
        const sibling = try std.Io.Dir.path.join(t.a, &.{ self_dir, p });
        return if (fsutil.kindFollow(sibling) == .file) sibling else null;
    }

    /// Resolve the asset catalog compiler (needed only for .xcassets resources).
    pub fn actool(t: *const Toolchain) ![]const u8 {
        return (try t.findActool()) orelse
            diag.fail("missing tool: {s} (needed for .xcassets). Build it with `zig build actool` in the idl repo (needs swift), or set toolchain.actool", .{t.cfg.actool});
    }

    // ------------------------------------------------------- app intents

    /// The App Intents metadata processor, or null. Apple's ships with Xcode as a
    /// macOS binary; on Linux use re-appintentsmetadataprocessor (same CLI).
    pub fn appIntentsProcessor(t: *const Toolchain) !?[]const u8 {
        return fsutil.which(t.a, try fsutil.expandHome(t.a, t.cfg.appintents, &t.env), t.pathEnv());
    }

    /// The SDK bundle's XcodeDefault.xctoolchain (`--toolchain-dir`).
    pub fn xcodeToolchainDir(t: *const Toolchain) ![]const u8 {
        return std.Io.Dir.path.join(t.a, &.{ t.sdk_bundle, "Developer/Toolchains/XcodeDefault.xctoolchain" });
    }

    /// ProductBuildVersion of the Xcode the SDK bundle was made from (`--xcode-version`),
    /// recorded as the metadata's toolsVersion.
    pub fn xcodeBuildVersion(t: *const Toolchain) []const u8 {
        const fallback = "16A242d";
        const path = std.Io.Dir.path.join(t.a, &.{ t.sdk_bundle, "Xcode.app/Contents/version.plist" }) catch return fallback;
        const p = plist.readFile(t.a, path) catch return fallback;
        defer p.deinit();
        const v = (p.getString(t.a, "ProductBuildVersion") catch null) orelse return fallback;
        return t.a.dupe(u8, v) catch fallback;
    }

    // ------------------------------------------------------------ check

    pub fn check(t: *const Toolchain) !bool {
        var stdout_w = sys.stdoutWriter();
        const out = &stdout_w.interface;
        var ok = true;
        const Row = struct { []const u8, ?[]const u8, bool };
        const rows = [_]Row{
            .{ "sdk", t.sdk, t.sdk != null and fsutil.kindFollow(t.sdk.?) == .dir },
            .{ "sdk version", t.sdk_version, t.sdk_version != null },
            .{ "swift resources", t.swift_resource_dir, fsutil.kindFollow(t.swift_resource_dir) == .dir },
            .{ "ld64.lld", t.ld64, fsutil.kindFollow(t.ld64) != .missing },
            .{ "compiler-rt", t.clang_rt, t.clang_rt != null },
            .{ "clang", t.cc, t.cc != null },
            .{ "clang++", t.cxx, t.cxx != null },
            .{ "swiftc", t.swiftc, t.swiftc != null },
            .{ "ldid", try fsutil.which(t.a, try fsutil.expandHome(t.a, t.cfg.ldid, &t.env), t.pathEnv()), true },
            .{ "xtool", try fsutil.which(t.a, t.cfg.xtool, t.pathEnv()), true },
            .{ "actool", try t.findActool(), true },
            .{ "rsvg-convert", try fsutil.which(t.a, "rsvg-convert", t.pathEnv()), true },
            .{ "appintents", try t.appIntentsProcessor(), true },
        };
        for (rows) |r| {
            const why: ?[]const u8 = if (std.mem.eql(u8, r[0], "xtool"))
                "  (only needed for `builder: xtool`)"
            else if (std.mem.eql(u8, r[0], "actool"))
                "  (only needed for .xcassets; build with `zig build actool`)"
            else if (std.mem.eql(u8, r[0], "rsvg-convert"))
                "  (only needed for SVG images in .xcassets; librsvg)"
            else if (std.mem.eql(u8, r[0], "appintents"))
                "  (only needed for App Intents / WidgetKit targets; re-appintentsmetadataprocessor)"
            else
                null;
            const optional = why != null;
            const found = r[2] and r[1] != null;
            const note = if (found) "" else why orelse "  <-- missing";
            try out.print("{s:<16} {s}{s}\n", .{ r[0], r[1] orelse "(not found)", note });
            if (!found and !optional) ok = false;
        }
        if (!ok) try out.writeAll(
            \\
            \\Install the missing tools, or point idlproj.yml `toolchain:` at them:
            \\  Darwin SDK:            xtool setup  (https://github.com/xtool-org/xtool)
            \\  clang, clang++, swiftc: a Swift toolchain, e.g. via swiftly
            \\  ldid:                  https://github.com/ProcursusTeam/ldid
            \\
        );
        return ok;
    }
};

fn stripFramework(name: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, name, ".framework")) name[0 .. name.len - ".framework".len] else name;
}

/// Compare dotted numeric version strings ("16.10" > "16.9").
fn versionLess(l: []const u8, r: []const u8) bool {
    var li = std.mem.tokenizeAny(u8, l, ".-");
    var ri = std.mem.tokenizeAny(u8, r, ".-");
    while (true) {
        const lp = li.next();
        const rp = ri.next();
        if (lp == null or rp == null) return lp == null and rp != null;
        const ln = std.fmt.parseInt(u64, lp.?, 10) catch 0;
        const rn = std.fmt.parseInt(u64, rp.?, 10) catch 0;
        if (ln != rn) return ln < rn;
        if (!std.mem.eql(u8, lp.?, rp.?)) return std.mem.lessThan(u8, lp.?, rp.?);
    }
}

/// Entry in `dir` named `<prefix>*<suffix>` with the highest version; absolute path.
fn newestEntry(a: Allocator, dir_path: []const u8, prefix: []const u8, suffix: []const u8) !?[]const u8 {
    var dir = sys.cwd().openDir(sys.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(sys.io);
    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next(sys.io)) |e| {
        if (!std.mem.startsWith(u8, e.name, prefix) or !std.mem.endsWith(u8, e.name, suffix)) continue;
        if (e.name.len < prefix.len + suffix.len) continue;
        const ver = e.name[prefix.len .. e.name.len - suffix.len];
        if (best == null or versionLess(best.?[prefix.len .. best.?.len - suffix.len], ver)) best = try a.dupe(u8, e.name);
    }
    return if (best) |b| try std.Io.Dir.path.join(a, &.{ dir_path, b }) else null;
}

fn sdkVersion(a: Allocator, sdk: []const u8) ?[]const u8 {
    const path = std.Io.Dir.path.join(a, &.{ sdk, "SDKSettings.json" }) catch return null;
    const bytes = sys.readFile(a, path, 16 << 20) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return null;
    if (v != .object) return null;
    const ver = v.object.get("Version") orelse return null;
    return if (ver == .string) ver.string else null;
}

test "version ordering" {
    try std.testing.expect(versionLess("16.9", "16.10"));
    try std.testing.expect(!versionLess("27.2", "27.0"));
    try std.testing.expect(versionLess("21", "21.0.1"));
}
