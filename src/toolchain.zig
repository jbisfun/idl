//! Linux -> iOS toolchain discovery (xtool Darwin SDK bundle + a modern
//! Swift-toolchain clang/swiftc) and the compiler/linker flag sets.
const std = @import("std");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub const Toolchain = struct {
    a: Allocator,
    cfg: config.ToolchainConfig,
    root: []const u8,
    env: std.process.EnvMap,
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

    pub fn init(a: Allocator, cfg: config.ToolchainConfig, root: []const u8) !Toolchain {
        var env = try std.process.getEnvMap(a);
        const swiftly_bin = try fsutil.expandHome(a, cfg.swiftly_bin, &env);
        // Append (never prepend) so host tools keep priority, like the old Makefiles.
        const old_path = env.get("PATH") orelse "/usr/bin:/bin";
        try env.put("PATH", try std.fmt.allocPrint(a, "{s}:{s}", .{ old_path, swiftly_bin }));
        const path_env = env.get("PATH").?;

        const bundle = try fsutil.expandHome(a, cfg.sdk_bundle, &env);
        const sdks_dir = try std.fs.path.join(a, &.{ bundle, "Developer/Platforms/iPhoneOS.platform/Developer/SDKs" });
        const sdk = if (cfg.sdk) |s| try fsutil.expandHome(a, s, &env) else try newestEntry(a, sdks_dir, "iPhoneOS", ".sdk");
        const toolchain_lib = try std.fs.path.join(a, &.{ bundle, "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib" });
        const clang_rt = blk: {
            const clang_dir = try std.fs.path.join(a, &.{ toolchain_lib, "clang" });
            const version = try newestEntry(a, clang_dir, "", "") orelse break :blk null;
            const p = try std.fs.path.join(a, &.{ version, "lib/darwin/libclang_rt.ios.a" });
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
            .swift_resource_dir = try std.fs.path.join(a, &.{ toolchain_lib, "swift" }),
            .platform_lib_dir = try std.fs.path.join(a, &.{ bundle, "Developer/Platforms/iPhoneOS.platform/Developer/usr/lib" }),
            .ld64 = try std.fs.path.join(a, &.{ bundle, "toolset/bin/orig/ld64.lld" }),
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
            .{ ".c", .c },     .{ ".m", .objc },   .{ ".mm", .objcxx }, .{ ".cc", .cxx },
            .{ ".cpp", .cxx }, .{ ".cxx", .cxx },  .{ ".s", .asm_ },    .{ ".S", .asm_ },
            .{ ".swift", .swift },
        };
        for (table) |e| if (std.mem.eql(u8, e[0], sfx)) return e[1];
        return null;
    }

    /// clang flags for one C-family source (without -c/-o).
    pub fn cflags(t: *const Toolchain, target: config.Target, lang: Lang, module_cache: []const u8) ![]const []const u8 {
        var f = std.ArrayList([]const u8).init(t.a);
        try f.appendSlice(&.{ "-target", try t.triple(target), "-isysroot", t.sdk.?, target.opt, "-g0", "-fmodules", try std.fmt.allocPrint(t.a, "-fmodules-cache-path={s}", .{module_cache}), "-fno-common", "-MMD", "-MP" });
        switch (lang) {
            .objc => try f.appendSlice(&.{ "-fobjc-arc", "-fobjc-weak", "-std=gnu17" }),
            .cxx => try f.appendSlice(&.{ "-std=gnu++20", "-stdlib=libc++" }),
            .objcxx => try f.appendSlice(&.{ "-fobjc-arc", "-fobjc-weak", "-std=gnu++20", "-stdlib=libc++" }),
            .c, .asm_, .swift => {},
        }
        for (target.include_dirs) |inc| try f.appendSlice(&.{ "-I", try target.path(t.a, inc) });
        for (target.defines) |d| try f.append(try std.fmt.allocPrint(t.a, "-D{s}", .{d}));
        try f.appendSlice(target.cflags);
        return f.items;
    }

    pub fn swiftflags(t: *const Toolchain, target: config.Target, module_cache: []const u8) ![]const []const u8 {
        var f = std.ArrayList([]const u8).init(t.a);
        try f.appendSlice(&.{
            "-target",            try t.triple(target), "-sdk",          t.sdk.?,
            "-resource-dir",      t.swift_resource_dir, "-I",            t.platform_lib_dir,
            "-L",                 t.platform_lib_dir,   "-module-cache-path", module_cache,
            target.swift_opt,     "-wmo",               "-suppress-warnings", "-module-name",
            target.name,
        });
        if (target.bridging_header) |h| try f.appendSlice(&.{ "-import-objc-header", try target.path(t.a, h) });
        for (target.include_dirs) |inc| try f.appendSlice(&.{ "-I", try target.path(t.a, inc) });
        // Swift conditions are flags only; NAME=VALUE defines apply to C-family code.
        for (target.defines) |d| if (std.mem.indexOfScalar(u8, d, '=') == null) try f.append(try std.fmt.allocPrint(t.a, "-D{s}", .{d}));
        try f.appendSlice(target.swiftflags);
        return f.items;
    }

    /// Linker inputs shared by clang and swiftc drivers: frameworks, libraries, extra flags.
    fn linkInputs(t: *const Toolchain, f: *std.ArrayList([]const u8), target: config.Target, need_cxx: bool) !void {
        for (target.frameworks) |fw| try f.appendSlice(&.{ "-framework", stripFramework(fw) });
        for (target.weak_frameworks) |fw| try f.appendSlice(&.{ "-weak_framework", stripFramework(fw) });
        for (target.libraries) |l| try f.append(try std.fmt.allocPrint(t.a, "-l{s}", .{l}));
        if (need_cxx) try f.append("-lc++");
        // Xcode's default LD_RUNPATH_SEARCH_PATHS, so embedded frameworks resolve.
        try f.appendSlice(&.{ "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks" });
        for (target.ldflags) |l| try f.appendSlice(&.{ "-Xlinker", l });
    }

    pub fn clangLink(t: *const Toolchain, target: config.Target, objects: []const []const u8, out: []const u8, need_cxx: bool) ![]const []const u8 {
        var f = std.ArrayList([]const u8).init(t.a);
        try f.appendSlice(&.{
            t.cc.?,                                 "-target",                        try t.triple(target), "-isysroot", t.sdk.?,
            "-fuse-ld=lld",                         try std.fmt.allocPrint(t.a, "--ld-path={s}", .{t.ld64}),
            "-Wl,-dead_strip",                      "-Wl,-headerpad_max_install_names", t.clang_rt.?,
        });
        try f.appendSlice(objects);
        try f.appendSlice(&.{ "-o", out });
        try t.linkInputs(&f, target, need_cxx);
        return f.items;
    }

    pub fn swiftLink(t: *const Toolchain, target: config.Target, module_cache: []const u8, swift_sources: []const []const u8, objects: []const []const u8, out: []const u8, need_cxx: bool) ![]const []const u8 {
        var f = std.ArrayList([]const u8).init(t.a);
        try f.append(t.swiftc.?);
        try f.appendSlice(try t.swiftflags(target, module_cache));
        try f.appendSlice(&.{
            "-use-ld=lld",   try std.fmt.allocPrint(t.a, "-ld-path={s}", .{t.ld64}),
            "-Xlinker",      "-dead_strip",
            "-Xlinker",      "-headerpad_max_install_names",
            "-Xlinker",      t.clang_rt.?,
        });
        try f.appendSlice(swift_sources);
        try f.appendSlice(objects);
        try f.appendSlice(&.{ "-o", out });
        try t.linkInputs(&f, target, need_cxx);
        return f.items;
    }

    // ------------------------------------------------------------- ldid

    /// Resolve ldid (a path, or a name looked up on PATH). idl never installs tools.
    pub fn ldid(t: *const Toolchain) ![]const u8 {
        const p = try fsutil.expandHome(t.a, t.cfg.ldid, &t.env);
        return (try fsutil.which(t.a, p, t.pathEnv())) orelse
            diag.fail("missing tool: ldid ({s} not found on PATH). Install ldid (https://github.com/ProcursusTeam/ldid) or set toolchain.ldid; set `sign: false` to skip signing", .{p});
    }

    // ------------------------------------------------------------ check

    pub fn check(t: *const Toolchain) !bool {
        const out = std.io.getStdOut().writer();
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
        };
        for (rows) |r| {
            const optional = std.mem.eql(u8, r[0], "xtool");
            const found = r[2] and r[1] != null;
            const note = if (found) "" else if (optional) "  (only needed for `builder: xtool`)" else "  <-- missing";
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
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (!std.mem.startsWith(u8, e.name, prefix) or !std.mem.endsWith(u8, e.name, suffix)) continue;
        if (e.name.len < prefix.len + suffix.len) continue;
        const ver = e.name[prefix.len .. e.name.len - suffix.len];
        if (best == null or versionLess(best.?[prefix.len .. best.?.len - suffix.len], ver)) best = try a.dupe(u8, e.name);
    }
    return if (best) |b| try std.fs.path.join(a, &.{ dir_path, b }) else null;
}

fn sdkVersion(a: Allocator, sdk: []const u8) ?[]const u8 {
    const path = std.fs.path.join(a, &.{ sdk, "SDKSettings.json" }) catch return null;
    const bytes = std.fs.cwd().readFileAlloc(a, path, 16 << 20) catch return null;
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
