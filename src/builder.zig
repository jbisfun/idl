//! Build orchestration. `direct` targets are compiled with clang/swiftc,
//! bundled, ad-hoc signed and zipped here; `xtool` targets delegate to xtool.
const std = @import("std");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const config = @import("config.zig");
const plist = @import("plist.zig");
const resources = @import("resources.zig");
const state = @import("buildstate.zig");
const zip = @import("zip.zig");
const verify = @import("verify.zig");
const codegen = @import("codegen.zig");
const metadata = @import("metadata.zig");
const Toolchain = @import("toolchain.zig").Toolchain;

const Allocator = std.mem.Allocator;
const Target = config.Target;

pub const Options = struct {
    jobs: usize = 0,
    verbose: bool = false,
    strict: bool = false,
    /// The CLI holds all selected targets' locks for the whole operation.
    locked: bool = false,
    prepared: ?resources.Prepared = null,
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

fn commandKey(c: Ctx, argv: []const []const u8) ![]const u8 {
    var f: state.Fingerprint = .{};
    for (argv) |arg| f.add(arg);
    f.add(try c.tc.identity(argv[0], true));
    f.add(c.tc.sdk orelse "");
    f.add(c.tc.sdk_version orelse "");
    f.add(try c.tc.identity(c.tc.ld64, true));
    return f.finish(c.a);
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
        const cmd = try commandKey(c, argv.items);
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
    // Keep locks until any children started before an error have stopped.
    defer for (running.items) |*r| {
        _ = r.child.kill() catch {};
    };
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
    var link_objects = std.ArrayList([]const u8).init(a);
    try link_objects.appendSlice(objects);
    var swift_for_link = swift.items;
    var link_target = c.t;
    // Darwin swiftc -g performs a dsymutil pass when sources and link share
    // an invocation. Keep DWARF in a persistent object and link separately;
    // this preserves debug data without requiring macOS tools on Linux.
    if (swift.items.len > 0 and c.t.debug_symbols) {
        const swift_obj = try std.fmt.allocPrint(a, "{s}/{s}.swift.o", .{ build_dir, c.t.name });
        var compile = std.ArrayList([]const u8).init(a);
        try compile.append(c.tc.swiftc.?);
        try compile.appendSlice(try c.tc.swiftflags(c.t, module_cache));
        try compile.appendSlice(swift.items);
        try compile.appendSlice(&.{ "-c", "-o", swift_obj });
        var deps = std.ArrayList([]const u8).init(a);
        try deps.appendSlice(swift.items);
        if (c.t.bridging_header) |h| try deps.append(try c.t.path(a, h));
        const compile_key = try commandKey(c, compile.items);
        if (!try upToDate(a, swift_obj, compile_key, deps.items, c.t.dir)) {
            if (!c.opts.verbose) diag.info("  SWIFT {s}", .{c.t.name});
            try run(c, compile.items, c.t.dir);
            try writeStamp(a, swift_obj, compile_key);
        }
        try link_objects.append(swift_obj);
        swift_for_link = &.{};
        link_target.debug_symbols = false;
    }
    const argv = if (swift.items.len > 0)
        try c.tc.swiftLink(link_target, module_cache, swift_for_link, link_objects.items, exe, need_cxx)
    else
        try c.tc.clangLink(c.t, link_objects.items, exe, need_cxx);
    const cmd = try commandKey(c, argv);
    var inputs = std.ArrayList([]const u8).init(a);
    try inputs.appendSlice(swift.items);
    try inputs.appendSlice(link_objects.items);
    if (c.t.bridging_header) |h| try inputs.append(try c.t.path(a, h));
    if (!objects_changed and try upToDate(a, exe, cmd, inputs.items, c.t.dir)) return exe;
    if (!c.opts.verbose) diag.info("  {s} {s}", .{ if (swift.items.len > 0) "SWIFT" else "LD  ", c.t.name });
    try run(c, argv, c.t.dir);
    try writeStamp(a, exe, cmd);
    return exe;
}

// ---------------------------------------------------------------- bundling

pub const buildVars = metadata.buildVars;
pub const processInfoPlist = metadata.processInfoPlist;

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

/// Copy only the collision-checked plan. Resource compiler cache directories
/// never enter the app, and framework discovery is based on planned outputs.
fn copyResources(c: Ctx, app: []const u8, prepared: resources.Prepared) ![]const []const u8 {
    var frameworks = std.StringHashMap(void).init(c.a);
    for (prepared.outputs) |o| {
        const dest = try std.fs.path.join(c.a, &.{ app, o.dest });
        try copyTree(c.a, o.source, dest);
        if (std.mem.startsWith(u8, o.dest, "Frameworks/")) {
            const rest = o.dest["Frameworks/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            if (std.mem.endsWith(u8, rest[0..slash], ".framework"))
                try frameworks.put(try std.fs.path.join(c.a, &.{ app, "Frameworks", rest[0..slash] }), {});
        }
    }
    var paths = std.ArrayList([]const u8).init(c.a);
    var it = frameworks.keyIterator();
    while (it.next()) |path| try paths.append(path.*);
    return paths.items;
}

fn entitlementsFile(c: Ctx, build_dir: []const u8) !?[]const u8 {
    const xml = (try metadata.entitlements(c.a, c.t, &c.tc.env)) orelse return null;
    const out = try std.fmt.allocPrint(c.a, "{s}/{s}.xcent", .{ build_dir, c.t.name });
    try std.fs.cwd().writeFile(.{ .sub_path = out, .data = xml });
    return out;
}

pub const Session = struct {
    locks: []state.Lock,
    prepared: []resources.Prepared,

    pub fn release(s: *Session) void {
        for (s.prepared) |p| if (p.info) |info| info.deinit();
        for (s.locks) |*lock| lock.release();
    }
};

pub fn lockTargets(a: Allocator, targets: []const Target) ![]state.Lock {
    var locks = std.ArrayList(state.Lock).init(a);
    errdefer for (locks.items) |*lock| lock.release();
    var roots = std.StringHashMap(void).init(a);
    for (targets) |t| {
        const root = try std.fs.cwd().realpathAlloc(a, t.dir);
        if (roots.contains(root)) continue;
        try locks.append(try state.Lock.acquire(a, root));
        try roots.put(root, {});
    }
    return locks.items;
}

fn hasSvg(a: Allocator, path: []const u8) !bool {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |e| if (std.ascii.endsWithIgnoreCase(e.path, ".svg")) return true;
    return false;
}

/// No app or resource compiler starts until every target passes its tool and
/// input checks. Checks run again inside build() for non-CLI callers.
pub fn checkTarget(a: Allocator, tc: *Toolchain, t: Target, strict: bool) !void {
    try fsutil.rejectSymlinkComponents(a, t.dir, t.build_dir);
    const sources = try fsutil.discover(a, t.dir, t.sources, "source");
    var swift = false;
    var cxx = false;
    var found = false;
    for (sources) |src| {
        if (Toolchain.langOf(src)) |lang| {
            found = true;
            swift = swift or lang == .swift;
            cxx = cxx or lang == .cxx or lang == .objcxx;
        } else if (std.mem.eql(u8, fsutil.suffix(src), ".metal")) {
            if (strict or t.strict) return diag.fail("{s}: unsupported Metal source {s}", .{ t.name, src });
            diag.warn("{s}: Metal source {s} is not compiled", .{ t.name, src });
        }
    }
    if (!found) return diag.fail("{s}: no compilable sources", .{t.name});
    if (t.bridging_header) |h| {
        try fsutil.rejectSymlinkComponents(a, t.dir, h);
        if (fsutil.kind(try t.path(a, h)) != .file) return diag.fail("missing bridging header: {s}", .{h});
    }
    if (t.builder == .direct) {
        try tc.require(swift);
        _ = try tc.identity(tc.cc.?, true);
        if (swift) _ = try tc.identity(tc.swiftc.?, true);
        if (cxx) _ = try tc.identity(tc.cxx orelse return diag.fail("missing C++ compiler: {s}", .{tc.cfg.cxx}), true);
        _ = try tc.identity(tc.ld64, true);
        if (t.signs()) _ = try tc.signerIdentity();
    } else {
        const xtool = (try fsutil.which(a, tc.cfg.xtool, tc.pathEnv())) orelse return diag.fail("missing tool: {s}", .{tc.cfg.xtool});
        _ = try tc.identity(xtool, true);
        if (t.resources.len > 0) return diag.fail("{s}: resource orchestration requires builder: direct; xtool's generated package does not declare these resources", .{t.name});
        _ = try codegen.packageSwift(a, t);
    }
    _ = try metadata.processInfoPlist(a, t, &tc.env, null);
    _ = try metadata.entitlements(a, t, &tc.env);
    for (try fsutil.discover(a, t.dir, t.resources, "resource")) |rel| {
        const suffix = fsutil.suffix(rel);
        if (fsutil.oneOf(suffix, &.{ ".xcdatamodeld", ".xcdatamodel", ".xcmappingmodel", ".metal", ".mlmodel", ".mlpackage" }) and (strict or t.strict))
            return diag.fail("{s}: unsupported resource {s}", .{ t.name, rel });
        if (std.mem.eql(u8, suffix, ".xcassets")) {
            _ = try tc.identity(try tc.actool(), true);
            if (try hasSvg(a, try t.path(a, rel))) {
                const svg_tool = (try fsutil.which(a, "rsvg-convert", tc.pathEnv())) orelse return diag.fail("{s}: SVG assets need rsvg-convert (librsvg) on PATH", .{t.name});
                _ = try tc.identity(svg_tool, true);
            }
        }
    }
}

pub fn prepareAll(a: Allocator, tc: *Toolchain, targets: []const Target, strict: bool, verbose: bool) !Session {
    const locks = try lockTargets(a, targets);
    errdefer for (locks) |*lock| lock.release();
    for (targets) |t| try checkTarget(a, tc, t, strict);
    var prepared = std.ArrayList(resources.Prepared).init(a);
    errdefer for (prepared.items) |p| if (p.info) |info| info.deinit();
    for (targets) |t| try prepared.append(try resources.prepare(a, tc, t, strict or t.strict, verbose));
    return .{ .locks = locks, .prepared = prepared.items };
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

    const prepared = c.opts.prepared.?;
    const info_xml = try processInfoPlist(a, t, &c.tc.env, prepared.info);
    const ent_xml = (try metadata.entitlements(a, t, &c.tc.env)) orelse "";
    var fingerprint: state.Fingerprint = .{};
    fingerprint.add("bundle-v1");
    fingerprint.add(try c.tc.selfIdentity());
    fingerprint.add(try state.treeDigest(a, exe));
    fingerprint.add(prepared.digest);
    fingerprint.add(info_xml);
    fingerprint.add(ent_xml);
    fingerprint.add(if (ldid_opt != null) "signed" else "unsigned");
    if (ldid_opt) |ldid| fingerprint.add(try c.tc.identity(ldid, false));
    const key = try fingerprint.finish(a);
    const ipa = try t.ipaPath(a);
    const stamp = try std.fs.path.join(a, &.{ build_dir, "bundle.state" });
    const payload = try std.fs.path.join(a, &.{ build_dir, "Payload" });
    const payload_stamp = try std.fs.path.join(a, &.{ build_dir, "payload.state" });
    if (try state.hit(a, stamp, key, ipa) and try state.hit(a, payload_stamp, key, payload)) {
        if (c.opts.verbose) diag.info("  CACHED bundle + signature + IPA", .{});
        return ipa;
    }
    // Staging prevents failures from destroying the previous successful app.
    const pending_payload = try std.fs.path.join(a, &.{ build_dir, "Payload.partial" });
    try std.fs.cwd().deleteTree(pending_payload);
    const app = try std.fmt.allocPrint(a, "{s}/{s}.app", .{ pending_payload, t.name });
    try std.fs.cwd().makePath(app);
    const app_exe = try std.fs.path.join(a, &.{ app, t.name });
    try std.fs.cwd().copyFile(exe, std.fs.cwd(), app_exe, .{ .override_mode = 0o755 });
    const frameworks = try copyResources(c, app, prepared);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ app, "Info.plist" }), .data = info_xml });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ app, "PkgInfo" }), .data = "APPL????" });

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
    var payload_dir = try std.fs.cwd().openDir(pending_payload, .{ .iterate = true });
    defer payload_dir.close();
    try w.addTree(payload_dir, "Payload");
    const tmp = try std.fmt.allocPrint(a, "{s}.partial", .{ipa});
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = try w.finish() });
    try std.fs.cwd().rename(tmp, ipa);
    try std.fs.cwd().deleteTree(payload);
    try std.fs.cwd().rename(pending_payload, payload);
    try state.record(a, payload_stamp, key, payload);
    try state.record(a, stamp, key, ipa);
    return ipa;
}

/// xtool 1.24's entitlement-rewrite path can drop executable ZIP mode bits.
/// Repair ZIP metadata only; executable bytes (and signatures) stay identical.
fn normalizeXtoolPermissions(a: Allocator, path: []const u8, name: []const u8) !void {
    const ar = try zip.open(a, try std.fs.cwd().readFileAlloc(a, path, 2 << 30));
    const exe_path = try std.fmt.allocPrint(a, "Payload/{s}.app/{s}", .{ name, name });
    const exe = ar.find(exe_path) orelse return diag.fail("xtool IPA is missing {s}", .{exe_path});
    if (exe.mode & 0o111 != 0) return;
    var out = zip.Writer.init(a);
    for (ar.entries) |entry| {
        if (std.mem.endsWith(u8, entry.name, "/")) {
            try out.addDir(entry.name);
        } else {
            const mode = if (std.mem.eql(u8, entry.name, exe_path)) entry.mode | 0o755 else entry.mode;
            try out.addFile(entry.name, try ar.read(a, entry), mode);
        }
    }
    const tmp = try std.fmt.allocPrint(a, "{s}.partial", .{path});
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = try out.finish() });
    try std.fs.cwd().rename(tmp, path);
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
    const ipa = try c.t.ipaPath(a);
    const original = try std.fmt.allocPrint(a, "{s}/xtool/{s}.ipa", .{ c.t.dir, c.t.name });
    try normalizeXtoolPermissions(a, original, c.t.name);
    if (c.t.profile != null) {
        try std.fs.cwd().makePath(try c.t.buildPath(a));
        try std.fs.cwd().copyFile(original, std.fs.cwd(), ipa, .{});
    }
    return ipa;
}

pub fn build(a: Allocator, tc: *Toolchain, t: Target, opts: Options) ![]const u8 {
    var session: ?Session = if (!opts.locked) try prepareAll(a, tc, &.{t}, opts.strict, opts.verbose) else null;
    defer if (session) |*s| s.release();
    var options = opts;
    if (session) |s| options.prepared = s.prepared[0];
    const c: Ctx = .{ .a = a, .tc = tc, .t = t, .opts = options };
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
        .xtool => {
            try doomed.append(try t.buildPath(a));
            for ([_][]const u8{ ".build", ".bsp", "xtool" }) |d| try doomed.append(try t.path(a, d));
        },
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

test "generate Info.plist without a template" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try config.parse(a, "targets:\n  - name: Bare\n    bundle_id: com.example.bare\n    info:\n      CFBundleDisplayName: My App\n      NSCameraUsageDescription: Take photos\n", "/project/idlproj.yml");
    const bytes = try processInfoPlist(a, cfg.targets[0], null, null);
    const value = try plist.parse(bytes);
    defer value.deinit();
    try std.testing.expectEqualStrings("My App", (try value.getString(a, "CFBundleDisplayName")).?);
    try std.testing.expectEqualStrings("Bare", (try value.getString(a, "CFBundleExecutable")).?);
    try std.testing.expect(try value.get(a, "UIDeviceFamily") != null);
}

test "xtool entitlement rewrite missing ZIP exec bits is normalized without changing code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), "App.ipa" });
    var w = zip.Writer.init(a);
    try w.addFile("Payload/App.app/App", "unchanged executable bytes", 0o644);
    try w.addFile("Payload/App.app/data", "resource", 0o644);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = try w.finish() });
    try normalizeXtoolPermissions(a, path, "App");
    const ar = try zip.open(a, try std.fs.cwd().readFileAlloc(a, path, 1 << 20));
    const exe = ar.find("Payload/App.app/App").?;
    try std.testing.expect(exe.mode & 0o111 != 0);
    try std.testing.expectEqualStrings("unchanged executable bytes", try ar.read(a, exe));
    try std.testing.expectEqual(@as(u32, 0), ar.find("Payload/App.app/data").?.mode & 0o111);
}
