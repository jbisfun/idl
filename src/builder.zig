//! Build orchestration. `direct` targets are compiled with clang/swiftc,
//! bundled, ad-hoc signed and zipped here; `xtool` targets delegate to xtool.
const std = @import("std");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const config = @import("config.zig");
const plist = @import("plist.zig");
const xcstrings = @import("xcstrings.zig");
const zip = @import("zip.zig");
const verify = @import("verify.zig");
const codegen = @import("codegen.zig");
const ynode = @import("ynode.zig");
const Toolchain = @import("toolchain.zig").Toolchain;

const Allocator = std.mem.Allocator;
const Target = config.Target;

pub const Options = struct {
    jobs: usize = 0,
    verbose: bool = false,
};

const Ctx = struct {
    a: Allocator,
    tc: *Toolchain,
    t: Target,
    opts: Options,
};

// ---------------------------------------------------------------- process

fn printCommand(argv: []const []const u8) void {
    const w = std.io.getStdOut().writer();
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch {};
        const plain = arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"'$\\") == null;
        if (plain) w.writeAll(arg) catch {} else w.print("'{s}'", .{arg}) catch {};
    }
    w.writeByte('\n') catch {};
}

fn spawn(c: Ctx, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    if (c.opts.verbose) printCommand(argv);
    var child = std.process.Child.init(argv, c.a);
    child.cwd = cwd;
    child.env_map = &c.tc.env;
    child.spawn() catch |err| return diag.fail("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
    return child;
}

fn succeeded(term: std.process.Child.Term) bool {
    return term == .Exited and term.Exited == 0;
}

pub fn run(c: Ctx, argv: []const []const u8, cwd: []const u8) !void {
    var child = try spawn(c, argv, cwd);
    const term = try child.wait();
    if (!succeeded(term)) return diag.fail("command failed: {s}", .{std.fs.path.basename(argv[0])});
}

// ------------------------------------------------------- incremental state

fn mtime(path: []const u8) ?i128 {
    const st = std.fs.cwd().statFile(path) catch return null;
    return st.mtime;
}

fn joinArgs(a: Allocator, argv: []const []const u8) ![]const u8 {
    return std.mem.join(a, "\n", argv);
}

/// Dependencies listed in a Makefile-style depfile written by `clang -MMD`.
fn depfileInputs(a: Allocator, text: []const u8) ![]const []const u8 {
    var deps = std.ArrayList([]const u8).init(a);
    // First rule only: join backslash-continued lines.
    var rule = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimRight(u8, line, "\r");
        if (std.mem.endsWith(u8, l, "\\") and !std.mem.endsWith(u8, l, "\\\\")) {
            try rule.appendSlice(l[0 .. l.len - 1]);
            try rule.append(' ');
        } else {
            try rule.appendSlice(l);
            break;
        }
    }
    const colon = std.mem.indexOf(u8, rule.items, ": ") orelse return deps.items;
    const body = rule.items[colon + 2 ..];
    var cur = std.ArrayList(u8).init(a);
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (ch == '\\' and i + 1 < body.len and body[i + 1] == ' ') {
            try cur.append(' ');
            i += 1;
        } else if (ch == ' ' or ch == '\t') {
            if (cur.items.len > 0) try deps.append(try cur.toOwnedSlice());
        } else try cur.append(ch);
    }
    if (cur.items.len > 0) try deps.append(try cur.toOwnedSlice());
    return deps.items;
}

/// True if `output` exists, was produced by exactly `cmd`, and is newer than every input.
fn upToDate(a: Allocator, output: []const u8, cmd: []const u8, inputs: []const []const u8, cwd: []const u8) !bool {
    const out_time = mtime(output) orelse return false;
    const stamp = try std.fmt.allocPrint(a, "{s}.cmd", .{output});
    const old = std.fs.cwd().readFileAlloc(a, stamp, 1 << 20) catch return false;
    if (!std.mem.eql(u8, old, cmd)) return false;
    for (inputs) |in| {
        const p = if (std.fs.path.isAbsolute(in)) in else try std.fs.path.join(a, &.{ cwd, in });
        const t = mtime(p) orelse return false;
        if (t > out_time) return false;
    }
    return true;
}

fn writeStamp(a: Allocator, output: []const u8, cmd: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "{s}.cmd", .{output}), .data = cmd });
}

// -------------------------------------------------------------- compiling

const Job = struct { argv: []const []const u8, obj: []const u8, label: []const u8, cmd: []const u8 };

/// Compile C-family sources in parallel; returns object paths and whether any were rebuilt.
fn compileObjects(c: Ctx, sources: []const []const u8, build_dir: []const u8, module_cache: []const u8) !struct { []const []const u8, bool } {
    const a = c.a;
    var objects = std.ArrayList([]const u8).init(a);
    var jobs = std.ArrayList(Job).init(a);
    for (sources) |rel| {
        const lang = Toolchain.langOf(rel) orelse continue;
        if (lang == .swift) continue;
        const obj = try std.fmt.allocPrint(a, "{s}/obj/{s}.o", .{ build_dir, rel });
        try objects.append(obj);
        const compiler = if (lang == .cxx or lang == .objcxx) c.tc.cxx orelse return diag.fail("missing tool: {s}", .{c.tc.cfg.cxx}) else c.tc.cc.?;
        var argv = std.ArrayList([]const u8).init(a);
        try argv.append(compiler);
        try argv.appendSlice(try c.tc.cflags(c.t, lang, module_cache));
        try argv.appendSlice(&.{ "-c", try c.t.path(a, rel), "-o", obj });
        const cmd = try joinArgs(a, argv.items);
        const depfile = try std.fmt.allocPrint(a, "{s}.d", .{obj[0 .. obj.len - 2]});
        const deps = if (std.fs.cwd().readFileAlloc(a, depfile, 16 << 20)) |text| try depfileInputs(a, text) else |_| &[_][]const u8{};
        var inputs = std.ArrayList([]const u8).init(a);
        try inputs.append(try c.t.path(a, rel));
        try inputs.appendSlice(deps);
        if (try upToDate(a, obj, cmd, inputs.items, c.t.dir)) continue;
        try std.fs.cwd().makePath(std.fs.path.dirname(obj).?);
        try jobs.append(.{ .argv = argv.items, .obj = obj, .label = rel, .cmd = cmd });
    }
    if (jobs.items.len == 0) return .{ objects.items, false };

    const max = if (c.opts.jobs > 0) c.opts.jobs else (std.Thread.getCpuCount() catch 4);
    const Running = struct { child: std.process.Child, job: Job };
    var running = std.ArrayList(Running).init(a);
    var failed: ?[]const u8 = null;
    var next: usize = 0;
    while (next < jobs.items.len or running.items.len > 0) {
        if (failed == null and next < jobs.items.len and running.items.len < max) {
            const job = jobs.items[next];
            next += 1;
            if (!c.opts.verbose) diag.info("  CC   {s}", .{job.label});
            try running.append(.{ .child = try spawn(c, job.argv, c.t.dir), .job = job });
            continue;
        }
        if (running.items.len == 0) break;
        var r = running.orderedRemove(0);
        const term = try r.child.wait();
        if (succeeded(term)) {
            try writeStamp(a, r.job.obj, r.job.cmd);
        } else if (failed == null) failed = r.job.label;
    }
    if (failed) |label| return diag.fail("compilation failed: {s}", .{label});
    return .{ objects.items, true };
}

fn link(c: Ctx, sources: []const []const u8, objects: []const []const u8, objects_changed: bool, build_dir: []const u8, module_cache: []const u8) ![]const u8 {
    const a = c.a;
    var swift = std.ArrayList([]const u8).init(a);
    var need_cxx = false;
    for (sources) |rel| switch (Toolchain.langOf(rel) orelse continue) {
        .swift => try swift.append(try c.t.path(a, rel)),
        .cxx, .objcxx => need_cxx = true,
        else => {},
    };
    if (swift.items.len == 0 and objects.len == 0) return diag.fail("target '{s}': no compilable sources found", .{c.t.name});
    const exe = try std.fmt.allocPrint(a, "{s}/{s}", .{ build_dir, c.t.name });
    const argv = if (swift.items.len > 0)
        try c.tc.swiftLink(c.t, module_cache, swift.items, objects, exe, need_cxx)
    else
        try c.tc.clangLink(c.t, objects, exe, need_cxx);
    const cmd = try joinArgs(a, argv);
    var inputs = std.ArrayList([]const u8).init(a);
    try inputs.appendSlice(swift.items);
    try inputs.appendSlice(objects);
    if (c.t.bridging_header) |h| try inputs.append(try c.t.path(a, h));
    if (!objects_changed and try upToDate(a, exe, cmd, inputs.items, c.t.dir)) return exe;
    if (!c.opts.verbose) diag.info("  {s} {s}", .{ if (swift.items.len > 0) "SWIFT" else "LD  ", c.t.name });
    try run(c, argv, c.t.dir);
    try writeStamp(a, exe, cmd);
    return exe;
}

// ---------------------------------------------------------------- bundling

fn ynodeToPlist(a: Allocator, key: []const u8, n: ynode.Node) !plist.c.plist_t {
    return switch (n) {
        .null => diag.fail("info.{s}: null is not a plist value", .{key}),
        .scalar => |s| if (s.quoted) try plist.newString(a, s.text) else try plist.parseCliValue(a, key, s.text),
        .list => |items| blk: {
            const arr = plist.c.plist_new_array();
            for (items) |item| _ = plist.c.plist_array_append_item(arr, try ynodeToPlist(a, key, item));
            break :blk arr;
        },
        .map => |m| blk: {
            const d = plist.Plist.newDict();
            for (m.keys, m.values) |k, v| try d.set(a, k, try ynodeToPlist(a, k, v));
            break :blk d.node;
        },
    };
}

pub fn buildVars(a: Allocator, t: Target) !plist.Vars {
    var vars = plist.Vars.init(a);
    const module = try a.dupe(u8, t.name);
    for (module) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
        ch.* = '_';
    };
    try vars.put("EXECUTABLE_NAME", t.name);
    try vars.put("PRODUCT_NAME", t.name);
    try vars.put("TARGET_NAME", t.name);
    try vars.put("PRODUCT_MODULE_NAME", module);
    try vars.put("PRODUCT_BUNDLE_IDENTIFIER", t.bundle_id);
    try vars.put("PRODUCT_BUNDLE_PACKAGE_TYPE", "APPL");
    try vars.put("MARKETING_VERSION", t.version);
    try vars.put("CURRENT_PROJECT_VERSION", t.build_number);
    try vars.put("IPHONEOS_DEPLOYMENT_TARGET", t.min_ios);
    try vars.put("DEVELOPMENT_LANGUAGE", "en");
    if (t.plist_vars) |m| for (m.keys, m.values) |k, v| switch (v) {
        .scalar => |s| try vars.put(k, s.text),
        else => return diag.fail("plist_vars.{s} must be a string", .{k}),
    };
    return vars;
}

/// Info.plist with `info:` overrides applied, variables expanded and
/// MinimumOSVersion forced to the target's deployment version.
pub fn processInfoPlist(a: Allocator, t: Target, env: ?*const std.process.EnvMap) ![]const u8 {
    const root = try plist.readFile(a, try t.path(a, t.info_plist));
    defer root.deinit();
    if (!root.isDict()) return diag.fail("{s}: root must be a dictionary", .{t.info_plist});
    const defaults = [_][2][]const u8{
        .{ "CFBundleExecutable", "$(EXECUTABLE_NAME)" },
        .{ "CFBundleIdentifier", "$(PRODUCT_BUNDLE_IDENTIFIER)" },
        .{ "CFBundleName", "$(PRODUCT_NAME)" },
        .{ "CFBundlePackageType", "APPL" },
        .{ "CFBundleInfoDictionaryVersion", "6.0" },
        .{ "CFBundleShortVersionString", "$(MARKETING_VERSION)" },
        .{ "CFBundleVersion", "$(CURRENT_PROJECT_VERSION)" },
    };
    for (defaults) |kv| try root.setDefault(a, kv[0], try plist.newString(a, kv[1]));
    if (t.info) |m| for (m.keys, m.values) |k, v| try root.set(a, k, try ynodeToPlist(a, k, v));
    try root.set(a, "MinimumOSVersion", try plist.newString(a, t.min_ios));
    var vars = try buildVars(a, t);
    try plist.expand(a, root.node, &vars, env);
    return root.toXml(a);
}

fn copyTree(a: Allocator, src: []const u8, dst: []const u8) !void {
    switch (fsutil.kind(src)) {
        .file => {
            if (std.fs.path.dirname(dst)) |d| try std.fs.cwd().makePath(d);
            try std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{});
        },
        .dir => {
            try std.fs.cwd().makePath(dst);
            var dir = try std.fs.cwd().openDir(src, .{ .iterate = true, .no_follow = true });
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |e| try copyTree(a, try std.fs.path.join(a, &.{ src, e.name }), try std.fs.path.join(a, &.{ dst, e.name }));
        },
        else => return diag.fail("cannot copy {s} (symlink or special file)", .{src}),
    }
}

/// Copy resources into the bundle (flattened like Xcode; `*.lproj/` kept).
/// Returns embedded frameworks that need signing.
fn copyResources(c: Ctx, app: []const u8) ![]const []const u8 {
    const a = c.a;
    var frameworks = std.ArrayList([]const u8).init(a);
    var seen = std.StringHashMap([]const u8).init(a);
    const resources = try fsutil.discover(a, c.t.dir, c.t.resources, "resource");
    for (resources) |rel| {
        const sfx = fsutil.suffix(rel);
        const src = try c.t.path(a, rel);
        if (fsutil.oneOf(sfx, &.{ ".xcassets", ".storyboard", ".xib", ".xcdatamodeld" })) {
            diag.warn("{s}: skipped; compiling {s} needs Xcode tools (actool/ibtool/momc) that only run on macOS", .{ rel, sfx });
            continue;
        }
        if (std.mem.eql(u8, sfx, ".xcstrings")) {
            var app_dir = try std.fs.cwd().openDir(app, .{});
            defer app_dir.close();
            try xcstrings.convert(a, try std.fs.cwd().readFileAlloc(a, src, 64 << 20), app_dir);
            continue;
        }
        var dest_rel: []const u8 = std.fs.path.basename(rel);
        if (std.mem.eql(u8, sfx, ".framework")) {
            dest_rel = try std.fmt.allocPrint(a, "Frameworks/{s}", .{dest_rel});
            try frameworks.append(try std.fs.path.join(a, &.{ app, dest_rel }));
        } else if (std.fs.path.dirname(rel)) |parent| {
            if (std.mem.eql(u8, fsutil.suffix(parent), ".lproj"))
                dest_rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.fs.path.basename(parent), dest_rel });
        }
        if (seen.get(dest_rel)) |other| return diag.fail("resources {s} and {s} both map to {s} in the bundle", .{ other, rel, dest_rel });
        for ([_][]const u8{ "Info.plist", "PkgInfo", c.t.name }) |reserved| if (std.mem.eql(u8, dest_rel, reserved))
            return diag.fail("resource {s} would overwrite the bundle's {s}", .{ rel, reserved });
        try seen.put(dest_rel, rel);
        try copyTree(a, src, try std.fs.path.join(a, &.{ app, dest_rel }));
    }
    return frameworks.items;
}

fn entitlementsFile(c: Ctx, build_dir: []const u8) !?[]const u8 {
    const rel = c.t.entitlements orelse return null;
    const value = try plist.readFile(c.a, try c.t.path(c.a, rel));
    defer value.deinit();
    var vars = try buildVars(c.a, c.t);
    try plist.expand(c.a, value.node, &vars, &c.tc.env);
    const out = try std.fmt.allocPrint(c.a, "{s}/{s}.xcent", .{ build_dir, c.t.name });
    try std.fs.cwd().writeFile(.{ .sub_path = out, .data = try value.toXml(c.a) });
    return out;
}

fn buildDirect(c: Ctx) ![]const u8 {
    const a = c.a;
    const t = c.t;
    const sources = try fsutil.discover(a, t.dir, t.sources, "source");
    var has_swift = false;
    for (sources) |s| if (Toolchain.langOf(s) == .swift) {
        has_swift = true;
    };
    try c.tc.require(has_swift);
    const ldid_opt: ?[]const u8 = if (t.signs()) try c.tc.ldid() else null;

    const build_dir = try t.buildPath(a);
    const module_cache = try std.fs.path.join(a, &.{ build_dir, "ModuleCache" });
    try std.fs.cwd().makePath(module_cache);

    const objects, const changed = try compileObjects(c, sources, build_dir, module_cache);
    const exe = try link(c, sources, objects, changed, build_dir, module_cache);

    // Re-assemble the bundle from scratch so deleted resources never linger.
    const payload = try std.fs.path.join(a, &.{ build_dir, "Payload" });
    try std.fs.cwd().deleteTree(payload);
    const app = try std.fmt.allocPrint(a, "{s}/{s}.app", .{ payload, t.name });
    try std.fs.cwd().makePath(app);
    const app_exe = try std.fs.path.join(a, &.{ app, t.name });
    try std.fs.cwd().copyFile(exe, std.fs.cwd(), app_exe, .{ .override_mode = 0o755 });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ app, "Info.plist" }), .data = try processInfoPlist(a, t, &c.tc.env) });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ app, "PkgInfo" }), .data = "APPL????" });
    const frameworks = try copyResources(c, app);

    if (ldid_opt) |ldid| {
        // Nested code first, then the containing executable.
        for (frameworks) |fw| {
            const bin = try std.fs.path.join(a, &.{ fw, std.fs.path.stem(fw) });
            if (fsutil.kind(bin) == .file) try run(c, &.{ ldid, "-S", bin }, t.dir);
        }
        const ent = try entitlementsFile(c, build_dir);
        const s_flag = if (ent) |e| try std.fmt.allocPrint(a, "-S{s}", .{e}) else "-S";
        if (!c.opts.verbose) diag.info("  SIGN {s}", .{t.name});
        try run(c, &.{ ldid, s_flag, try std.fmt.allocPrint(a, "-I{s}", .{t.bundle_id}), app_exe }, t.dir);
    }

    var w = zip.Writer.init(a);
    var payload_dir = try std.fs.cwd().openDir(payload, .{ .iterate = true });
    defer payload_dir.close();
    try w.addTree(payload_dir, "Payload");
    const ipa = try t.ipaPath(a);
    const tmp = try std.fmt.allocPrint(a, "{s}.partial", .{ipa});
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = try w.finish() });
    try std.fs.cwd().rename(tmp, ipa);
    return ipa;
}

fn buildXtool(c: Ctx) ![]const u8 {
    const a = c.a;
    try codegen.genXtool(a, c.t);
    const xtool = (try fsutil.which(a, c.tc.cfg.xtool, c.tc.pathEnv())) orelse return diag.fail("missing tool: {s} (https://github.com/xtool-org/xtool)", .{c.tc.cfg.xtool});
    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ xtool, "dev", "build", "-c", c.t.configuration });
    if (c.t.signs()) try argv.append("--sign");
    try argv.append("--ipa");
    if (!c.opts.verbose) diag.info("  XTOOL {s}", .{c.t.name});
    try run(c, argv.items, c.t.dir);
    return c.t.ipaPath(a);
}

pub fn build(a: Allocator, tc: *Toolchain, t: Target, opts: Options) ![]const u8 {
    const c: Ctx = .{ .a = a, .tc = tc, .t = t, .opts = opts };
    diag.info("==> {s} ({s})", .{ t.name, @tagName(t.builder) });
    const ipa = switch (t.builder) {
        .direct => try buildDirect(c),
        .xtool => try buildXtool(c),
    };
    _ = try verify.verifyFile(a, ipa, .{ .bundle_id = t.bundle_id, .allow_unsigned = !t.signs() });
    return ipa;
}

pub fn clean(a: Allocator, t: Target) !void {
    var doomed = std.ArrayList([]const u8).init(a);
    switch (t.builder) {
        .direct => try doomed.append(try t.buildPath(a)),
        .xtool => for ([_][]const u8{ ".build", ".bsp", "xtool" }) |d| try doomed.append(try t.path(a, d)),
    }
    if (t.xcodeproj) try doomed.append(try std.fmt.allocPrint(a, "{s}/{s}.xcodeproj", .{ t.dir, t.name }));
    for (doomed.items) |p| if (fsutil.kind(p) != .missing) {
        diag.info("  RM   {s}", .{p});
        try std.fs.cwd().deleteTree(p);
    };
}

test "depfile parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deps = try depfileInputs(arena.allocator(), "build/obj/main.m.o: Sources/main.m \\\n  /sdk/UIKit.h My\\ Header.h\n\nSources/main.m:\n");
    try std.testing.expectEqual(@as(usize, 3), deps.len);
    try std.testing.expectEqualStrings("My Header.h", deps[2]);
}
