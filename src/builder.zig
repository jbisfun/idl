//! Build orchestration. `direct` targets are compiled with clang/swiftc,
//! bundled, ad-hoc signed and zipped here; `xtool` targets delegate to xtool.
const std = @import("std");
const sys = @import("sys.zig");
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
    /// Products of already-built targets, for `link`/`embed`.
    products: ?*Products = null,
    /// Run app targets' post_build commands.
    post_build: bool = true,
};

const Ctx = struct {
    a: Allocator,
    tc: *Toolchain,
    t: Target,
    opts: Options,
};

// ---------------------------------------------------------------- process

fn printCommand(argv: []const []const u8) void {
    var stdout_w = sys.stdoutWriter();
    const w = &stdout_w.interface;
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch {};
        const plain = arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\"'$\\") == null;
        if (plain) w.writeAll(arg) catch {} else w.print("'{s}'", .{arg}) catch {};
    }
    w.writeByte('\n') catch {};
}

fn spawn(c: Ctx, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    if (c.opts.verbose) printCommand(argv);
    return sys.spawn(argv, .{ .cwd = cwd, .env = &c.tc.env }) catch |err| diag.fail("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
}

const succeeded = sys.succeeded;

pub fn run(c: Ctx, argv: []const []const u8, cwd: []const u8) !void {
    var child = try spawn(c, argv, cwd);
    const term = try sys.wait(&child);
    if (!succeeded(term)) return diag.fail("command failed: {s}", .{std.Io.Dir.path.basename(argv[0])});
}

// ------------------------------------------------------- incremental state

const mtime = sys.mtime;

fn commandKey(c: Ctx, argv: []const []const u8) ![]const u8 {
    return commandKeyProbe(c, argv, true);
}

/// `probe`: fingerprint `argv[0] --version` output too (tools without it use contents only).
fn commandKeyProbe(c: Ctx, argv: []const []const u8, probe: bool) ![]const u8 {
    var f: state.Fingerprint = .{};
    for (argv) |arg| f.add(arg);
    f.add(try c.tc.identity(argv[0], probe));
    f.add(c.tc.sdk orelse "");
    f.add(c.tc.sdk_version orelse "");
    f.add(try c.tc.identity(c.tc.ld64, true));
    return f.finish(c.a);
}

/// Dependencies listed in a Makefile-style depfile written by `clang -MMD`.
pub fn depfileInputs(a: Allocator, text: []const u8) ![]const []const u8 {
    var deps: std.ArrayList([]const u8) = .empty;
    // First rule only: join backslash-continued lines.
    var rule: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.endsWith(u8, l, "\\") and !std.mem.endsWith(u8, l, "\\\\")) {
            try rule.appendSlice(a, l[0 .. l.len - 1]);
            try rule.append(a, ' ');
        } else {
            try rule.appendSlice(a, l);
            break;
        }
    }
    const colon = std.mem.indexOf(u8, rule.items, ": ") orelse return deps.items;
    const body = rule.items[colon + 2 ..];
    var cur: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (ch == '\\' and i + 1 < body.len and body[i + 1] == ' ') {
            try cur.append(a, ' ');
            i += 1;
        } else if (ch == ' ' or ch == '\t') {
            if (cur.items.len > 0) try deps.append(a, try cur.toOwnedSlice(a));
        } else try cur.append(a, ch);
    }
    if (cur.items.len > 0) try deps.append(a, try cur.toOwnedSlice(a));
    return deps.items;
}

/// True if `output` exists, was produced by exactly `cmd`, and is newer than every input.
pub fn upToDate(a: Allocator, output: []const u8, cmd: []const u8, inputs: []const []const u8, cwd: []const u8) !bool {
    const out_time = mtime(output) orelse return false;
    const stamp = try std.fmt.allocPrint(a, "{s}.cmd", .{output});
    const old = sys.readFile(a, stamp, 1 << 20) catch return false;
    if (!std.mem.eql(u8, old, cmd)) return false;
    for (inputs) |in| {
        const p = if (std.Io.Dir.path.isAbsolute(in)) in else try std.Io.Dir.path.join(a, &.{ cwd, in });
        const t = mtime(p) orelse return false;
        if (t > out_time) return false;
    }
    return true;
}

pub fn writeStamp(a: Allocator, output: []const u8, cmd: []const u8) !void {
    try sys.cwd().writeFile(sys.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.cmd", .{output}), .data = cmd });
}

// -------------------------------------------------------------- compiling

const Job = struct { argv: []const []const u8, obj: []const u8, label: []const u8, cmd: []const u8 };

/// Compile C-family sources in parallel; returns object paths and whether any were rebuilt.
fn compileObjects(c: Ctx, sources: []const []const u8, obj_dir: []const u8, module_cache: []const u8, extra: []const []const u8) !struct { []const []const u8, bool } {
    const a = c.a;
    var objects: std.ArrayList([]const u8) = .empty;
    var jobs: std.ArrayList(Job) = .empty;
    for (sources) |rel| {
        const lang = Toolchain.langOf(rel) orelse continue;
        if (lang == .swift) continue;
        const obj = try std.fmt.allocPrint(a, "{s}/{s}.o", .{ obj_dir, rel });
        try objects.append(a, obj);
        const compiler = if (lang == .cxx or lang == .objcxx) c.tc.cxx orelse return diag.fail("missing tool: {s}", .{c.tc.cfg.cxx}) else c.tc.cc.?;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, compiler);
        try argv.appendSlice(a, try c.tc.cflags(c.t, lang, module_cache));
        try argv.appendSlice(a, extra);
        try argv.appendSlice(a, &.{ "-c", try c.t.path(a, rel), "-o", obj });
        const cmd = try commandKey(c, argv.items);
        const depfile = try std.fmt.allocPrint(a, "{s}.d", .{obj[0 .. obj.len - 2]});
        const deps = if (sys.readFile(a, depfile, 16 << 20)) |text| try depfileInputs(a, text) else |_| &[_][]const u8{};
        var inputs: std.ArrayList([]const u8) = .empty;
        try inputs.append(a, try c.t.path(a, rel));
        try inputs.appendSlice(a, deps);
        if (try upToDate(a, obj, cmd, inputs.items, c.t.dir)) continue;
        try sys.makePath(std.Io.Dir.path.dirname(obj).?);
        try jobs.append(a, .{ .argv = argv.items, .obj = obj, .label = rel, .cmd = cmd });
    }
    if (jobs.items.len == 0) return .{ objects.items, false };

    const max = if (c.opts.jobs > 0) c.opts.jobs else sys.cpuCount();
    const Running = struct { child: std.process.Child, job: Job };
    var running: std.ArrayList(Running) = .empty;
    // Keep locks until any children started before an error have stopped.
    defer for (running.items) |*r| {
        r.child.kill(sys.io);
    };
    var failed: ?[]const u8 = null;
    var next: usize = 0;
    while (next < jobs.items.len or running.items.len > 0) {
        if (failed == null and next < jobs.items.len and running.items.len < max) {
            const job = jobs.items[next];
            next += 1;
            if (!c.opts.verbose) diag.info("  CC   [{s}] {s}", .{ c.t.name, job.label });
            try running.append(a, .{ .child = try spawn(c, job.argv, c.t.dir), .job = job });
            continue;
        }
        if (running.items.len == 0) break;
        var r = running.orderedRemove(0);
        const term = try sys.wait(&r.child);
        if (succeeded(term)) {
            try writeStamp(a, r.job.obj, r.job.cmd);
        } else if (failed == null) failed = r.job.label;
    }
    if (failed) |label| return diag.fail("compilation failed: {s}", .{label});
    return .{ objects.items, true };
}

/// What a built target hands to the targets that link or embed it.
pub const Product = struct {
    name: []const u8,
    kind: config.Kind,
    /// Unsigned link-time binary (`<build>/link/...`); dependents link against it.
    link_binary: ?[]const u8 = null,
    /// Signed bundle dir / dylib that embedding apps copy.
    bundle: ?[]const u8 = null,
    /// Objects a `static` target contributes to its dependents' link.
    objects: []const []const u8 = &.{},
    /// Directory holding `<Module>.swiftmodule` (static/framework targets with Swift).
    module_dir: ?[]const u8 = null,
    /// Directory holding the generated `<Module>-Swift.h`.
    header_dir: ?[]const u8 = null,
    /// App IPA.
    ipa: ?[]const u8 = null,
    /// Static targets with App Intents: their const values and Swift sources,
    /// extracted together with the module of the bundle that links them.
    const_values: ?[]const u8 = null,
    swift_sources: []const []const u8 = &.{},
};
pub const Products = std.StringHashMap(Product);

const Deps = struct {
    swift_flags: []const []const u8,
    c_flags: []const []const u8,
    link_args: []const []const u8,
    objects: []const []const u8,
    inputs: []const []const u8,
    /// Linked static targets' App Intents const values and sources.
    intent_consts: []const []const u8 = &.{},
    intent_sources: []const []const u8 = &.{},
};

fn product(c: Ctx, name: []const u8) !Product {
    const products = c.opts.products orelse return diag.fail("target '{s}' depends on '{s}'; build it through `idl build`", .{ c.t.name, name });
    return products.get(name) orelse diag.fail("target '{s}' depends on '{s}', which has not been built", .{ c.t.name, name });
}

fn resolveDeps(c: Ctx) !Deps {
    const a = c.a;
    var swift_flags: std.ArrayList([]const u8) = .empty;
    var c_flags: std.ArrayList([]const u8) = .empty;
    var link_args: std.ArrayList([]const u8) = .empty;
    var objects: std.ArrayList([]const u8) = .empty;
    var inputs: std.ArrayList([]const u8) = .empty;
    var intent_consts: std.ArrayList([]const u8) = .empty;
    var intent_sources: std.ArrayList([]const u8) = .empty;
    for (c.t.link) |name| {
        const p = try product(c, name);
        if (p.const_values) |cv| {
            try intent_consts.append(a, cv);
            try intent_sources.appendSlice(a, p.swift_sources);
        }
        switch (p.kind) {
            .framework => {
                const bin = p.link_binary.?;
                try link_args.appendSlice(a, &.{ "-F", std.Io.Dir.path.dirname(std.Io.Dir.path.dirname(bin).?).?, "-framework", p.name });
                try swift_flags.appendSlice(a, &.{ "-F", std.Io.Dir.path.dirname(std.Io.Dir.path.dirname(bin).?).? });
                try inputs.append(a, bin);
            },
            .dylib => {
                try objects.append(a, p.link_binary.?);
                try inputs.append(a, p.link_binary.?);
            },
            .static => {
                try objects.appendSlice(a, p.objects);
                try inputs.appendSlice(a, p.objects);
            },
            .app, .appex, .@"test" => unreachable, // rejected by config validation
        }
        if (p.module_dir) |d| {
            try swift_flags.appendSlice(a, &.{ "-I", d });
            try inputs.append(a, try std.fmt.allocPrint(a, "{s}/{s}.swiftmodule", .{ d, p.name }));
        }
        if (p.header_dir) |d| try c_flags.appendSlice(a, &.{ "-I", d });
    }
    return .{ .swift_flags = swift_flags.items, .c_flags = c_flags.items, .link_args = link_args.items, .objects = objects.items, .inputs = inputs.items, .intent_consts = intent_consts.items, .intent_sources = intent_sources.items };
}

/// Like Xcode: only a file named main.swift may hold top-level code; every
/// other module (libraries, @main apps, ObjC-main apps) parses as a library.
fn parseAsLibrary(t: Target, swift: []const []const u8) bool {
    if (t.type != .app) return true;
    for (swift) |f| if (std.mem.eql(u8, std.Io.Dir.path.basename(f), "main.swift")) return false;
    return true;
}

const SwiftOut = struct { obj: []const u8, module_dir: ?[]const u8, header_dir: ?[]const u8, changed: bool };

// ------------------------------------------------------------ app intents

/// Protocols whose conformances swiftc records as const values for the App
/// Intents metadata processor (Xcode's SWIFT_EMIT_CONST_VALUE_PROTOCOLS).
/// Refinements such as WidgetConfigurationIntent are found through AppIntent.
const app_intents_protocols = [_][]const u8{
    "AppIntent",                      "EntityQuery",               "AppEntity",
    "TransientEntity",                "AppEnum",                   "AppShortcutProviding",
    "AppShortcutsProvider",           "AnyResolverProviding",      "AppIntentsPackage",
    "DynamicOptionsProvider",         "_IntentValueRepresentable", "_AssistantIntentsProvider",
    "_GenerativeFunctionExtractable", "IntentValueQuery",
};

/// The metadata processor for a target that extracts App Intents metadata, or
/// null. Without the tool, an explicit `app_intents: true` (or `--strict`) fails;
/// the WidgetKit/AppIntents default only warns (`warn`), since the app still
/// builds but its intents and widget configuration won't work on a device.
/// `linked_intents`: a linked static target carries App Intents, which turns
/// extraction on for this bundle too.
fn appIntentsTool(tc: *Toolchain, t: Target, strict: bool, warn: bool, linked_intents: bool) !?[]const u8 {
    const mode = t.appIntents();
    if (t.type == .static or t.app_intents == false or !(mode.enabled or linked_intents)) return null;
    if (try tc.appIntentsProcessor()) |tool| return tool;
    if (mode.explicit or strict or t.strict)
        return diag.fail("{s}: app_intents needs {s} (re-appintentsmetadataprocessor, e.g. `nix profile install nixpkgs#re-appintentsmetadataprocessor`), or set toolchain.appintents", .{ t.name, tc.cfg.appintents });
    if (warn) diag.warn("{s}: {s} not found; skipping App Intents metadata (intents and widget configuration won't work on a device). Set `app_intents: false` to silence", .{ t.name, tc.cfg.appintents });
    return null;
}

fn constValuesPath(a: Allocator, obj_dir: []const u8, t: Target) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.swiftconstvalues", .{ obj_dir, t.name });
}

/// swiftc flags that write the module's const values for the metadata processor.
fn constValueFlags(a: Allocator, obj_dir: []const u8, t: Target) ![]const []const u8 {
    try sys.makePath(obj_dir);
    const protocols = try std.fmt.allocPrint(a, "{s}/{s}.const_extract_protocols.json", .{ obj_dir, t.name });
    const json = try std.json.Stringify.valueAlloc(a, app_intents_protocols, .{});
    _ = try fsutil.writeIfChanged(a, protocols, json);
    return a.dupe([]const u8, &.{ "-emit-const-values-path", try constValuesPath(a, obj_dir, t), "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", protocols });
}

/// Run the metadata processor over the linked binary and the module's const
/// values. Returns `<obj>/appintents/Metadata.appintents`, or null when the
/// module declares no intents (the processor writes nothing).
fn extractAppIntents(c: Ctx, tool: []const u8, linked: []const u8, swift: []const []const u8, obj_dir: []const u8, deps: Deps, changed: bool) !?[]const u8 {
    const a = c.a;
    const t = c.t;
    const out_dir = try std.Io.Dir.path.join(a, &.{ obj_dir, "appintents" });
    const result = try std.Io.Dir.path.join(a, &.{ out_dir, "Metadata.appintents" });
    const consts = try constValuesPath(a, obj_dir, t);
    const source_list = try std.fmt.allocPrint(a, "{s}/{s}.SwiftFileList", .{ obj_dir, t.name });
    const const_list = try std.fmt.allocPrint(a, "{s}/{s}.SwiftConstValuesFileList", .{ obj_dir, t.name });
    // Linked static modules are extracted with this one, under their own module names.
    const sources = try std.mem.concat(a, []const u8, &.{ swift, deps.intent_sources });
    const const_files = try std.mem.concat(a, []const u8, &.{ &.{consts}, deps.intent_consts });
    _ = try fsutil.writeIfChanged(a, source_list, try std.mem.concat(a, u8, &.{ try std.mem.join(a, "\n", sources), "\n" }));
    _ = try fsutil.writeIfChanged(a, const_list, try std.mem.concat(a, u8, &.{ try std.mem.join(a, "\n", const_files), "\n" }));
    const argv = [_][]const u8{
        tool,                 "--output",                   out_dir,
        "--toolchain-dir",    try c.tc.xcodeToolchainDir(), "--module-name",
        t.name,               "--sdk-root",                 c.tc.sdk.?,
        "--xcode-version",    c.tc.xcodeBuildVersion(),     "--platform-family",
        "iOS",                "--deployment-target",        t.min_ios,
        "--target-triple",    try c.tc.triple(t),           "--binary-file",
        linked,               "--bundle-identifier",        t.bundle_id,
        "--source-file-list", source_list,                  "--swift-const-vals-list",
        const_list,           "--compile-time-extraction",  "--force",
    };
    const key = try commandKeyProbe(c, &argv, false);
    const stamp = try std.Io.Dir.path.join(a, &.{ obj_dir, "appintents.extract" });
    if (!changed and try upToDate(a, stamp, key, try std.mem.concat(a, []const u8, &.{ &.{ linked, source_list, const_list }, const_files }), t.dir))
        return if (fsutil.kind(result) == .dir) result else null;
    try sys.deleteTree(out_dir);
    try sys.makePath(out_dir);
    if (!c.opts.verbose) diag.info("  INTENTS [{s}]", .{t.name});
    try run(c, &argv, t.dir);
    try sys.cwd().writeFile(sys.io, .{ .sub_path = stamp, .data = "" });
    try writeStamp(a, stamp, key);
    return if (fsutil.kind(result) == .dir) result else null;
}

/// Whole-module Swift compile to one object. Runs before the C-family compile
/// so Objective-C in the same target can import the generated `<Module>-Swift.h`.
fn compileSwift(c: Ctx, swift: []const []const u8, obj_dir: []const u8, module_cache: []const u8, deps: Deps, has_c: bool, const_values: bool) !SwiftOut {
    const a = c.a;
    const t = c.t;
    const obj = try std.fmt.allocPrint(a, "{s}/{s}.swift.o", .{ obj_dir, t.name });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, c.tc.swiftc.?);
    try argv.appendSlice(a, try c.tc.swiftflags(t, module_cache));
    if (parseAsLibrary(t, swift)) try argv.append(a, "-parse-as-library");
    try argv.appendSlice(a, deps.swift_flags);
    try argv.appendSlice(a, swift);
    try argv.appendSlice(a, &.{ "-c", "-o", obj });
    if (const_values) try argv.appendSlice(a, try constValueFlags(a, obj_dir, t));
    var module_dir: ?[]const u8 = null;
    var header_dir: ?[]const u8 = null;
    // Emitting the ObjC header implies emitting a module; without an explicit
    // path swiftc drops `<Name>-1.swiftmodule` etc. into the working directory.
    if (has_c or t.type == .static or t.type == .framework) {
        module_dir = try std.Io.Dir.path.join(a, &.{ obj_dir, "modules" });
        try sys.makePath(module_dir.?);
        try argv.appendSlice(a, &.{ "-emit-module-path", try std.fmt.allocPrint(a, "{s}/{s}.swiftmodule", .{ module_dir.?, t.name }) });
    }
    if (has_c or t.type == .static or t.type == .framework) {
        header_dir = try std.Io.Dir.path.join(a, &.{ obj_dir, "include" });
        try sys.makePath(header_dir.?);
        try argv.appendSlice(a, &.{ "-emit-objc-header-path", try std.fmt.allocPrint(a, "{s}/{s}-Swift.h", .{ header_dir.?, t.name }) });
    }
    var inputs: std.ArrayList([]const u8) = .empty;
    try inputs.appendSlice(a, swift);
    if (t.bridging_header) |h| try inputs.append(a, try t.path(a, h));
    try inputs.appendSlice(a, deps.inputs);
    const key = try commandKey(c, argv.items);
    if (try upToDate(a, obj, key, inputs.items, t.dir)) return .{ .obj = obj, .module_dir = module_dir, .header_dir = header_dir, .changed = false };
    try sys.makePath(obj_dir);
    if (!c.opts.verbose) diag.info("  SWIFT [{s}] {d} file(s)", .{ t.name, swift.len });
    try run(c, argv.items, t.dir);
    try writeStamp(a, obj, key);
    return .{ .obj = obj, .module_dir = module_dir, .header_dir = header_dir, .changed = true };
}

/// Link-time output path: frameworks get a real `<name>.framework/<name>`
/// layout so dependents can use `-F <build>/link -framework <name>`.
fn linkOutput(a: Allocator, t: Target, build_dir: []const u8) ![]const u8 {
    return switch (t.type) {
        .framework => std.fmt.allocPrint(a, "{s}/link/{s}.framework/{s}", .{ build_dir, t.name, t.name }),
        .dylib => std.fmt.allocPrint(a, "{s}/link/{s}.dylib", .{ build_dir, t.name }),
        else => std.fmt.allocPrint(a, "{s}/link/{s}", .{ build_dir, t.name }),
    };
}

fn link(c: Ctx, objects: []const []const u8, changed: bool, has_swift: bool, need_cxx: bool, out: []const u8, module_cache: []const u8, deps: Deps) !void {
    const a = c.a;
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(a, objects);
    try all.appendSlice(a, deps.objects);
    if (all.items.len == 0) return diag.fail("target '{s}': no compilable sources found", .{c.t.name});
    // Swift was compiled separately: never let the driver run dsymutil.
    var link_target = c.t;
    link_target.debug_symbols = false;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, if (has_swift)
        try c.tc.swiftLink(link_target, module_cache, &.{}, all.items, out, need_cxx)
    else
        try c.tc.clangLink(c.t, all.items, out, need_cxx));
    try argv.appendSlice(a, deps.link_args);
    const cmd = try commandKey(c, argv.items);
    var inputs: std.ArrayList([]const u8) = .empty;
    try inputs.appendSlice(a, all.items);
    try inputs.appendSlice(a, deps.inputs);
    if (!changed and try upToDate(a, out, cmd, inputs.items, c.t.dir)) return;
    if (!c.opts.verbose) diag.info("  LD   [{s}] {s}", .{ c.t.name, std.Io.Dir.path.basename(out) });
    try sys.makePath(std.Io.Dir.path.dirname(out).?);
    try run(c, argv.items, c.t.dir);
    try writeStamp(a, out, cmd);
}

// ---------------------------------------------------------------- bundling

pub const buildVars = metadata.buildVars;
pub const processInfoPlist = metadata.processInfoPlist;

fn copyTree(a: Allocator, src: []const u8, dst: []const u8) !void {
    switch (fsutil.kind(src)) {
        .file => {
            if (std.Io.Dir.path.dirname(dst)) |d| try sys.makePath(d);
            try sys.cwd().copyFile(src, sys.cwd(), dst, sys.io, .{});
        },
        .dir => {
            try sys.makePath(dst);
            var dir = try sys.cwd().openDir(sys.io, src, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(sys.io);
            var it = dir.iterate();
            while (try it.next(sys.io)) |e| try copyTree(a, try std.Io.Dir.path.join(a, &.{ src, e.name }), try std.Io.Dir.path.join(a, &.{ dst, e.name }));
        },
        else => return diag.fail("cannot copy {s} (symlink or special file)", .{src}),
    }
}

/// Embedded framework content Xcode removes on copy (RemoveHeadersOnCopy) or
/// that a re-sign invalidates.
fn strippedFrameworkPart(dest: []const u8) bool {
    if (!std.mem.startsWith(u8, dest, "Frameworks/")) return false;
    var parts = std.mem.splitScalar(u8, dest["Frameworks/".len..], '/');
    const fw = parts.next() orelse return false;
    if (!std.mem.endsWith(u8, fw, ".framework")) return false;
    const sub = parts.next() orelse return false;
    return fsutil.oneOf(sub, &.{ "Headers", "PrivateHeaders", "Modules", "_CodeSignature" });
}

/// Copy only the collision-checked plan. Resource compiler cache directories
/// never enter the app, and framework discovery is based on planned outputs.
fn copyResources(c: Ctx, app: []const u8, prepared: resources.Prepared) ![]const []const u8 {
    var frameworks = std.StringHashMap(void).init(c.a);
    for (prepared.outputs) |o| {
        if (strippedFrameworkPart(o.dest)) continue;
        const dest = try std.Io.Dir.path.join(c.a, &.{ app, o.dest });
        try copyTree(c.a, o.source, dest);
        if (std.mem.startsWith(u8, o.dest, "Frameworks/")) {
            const rest = o.dest["Frameworks/".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            if (std.mem.endsWith(u8, rest[0..slash], ".framework"))
                try frameworks.put(try std.Io.Dir.path.join(c.a, &.{ app, "Frameworks", rest[0..slash] }), {});
        }
    }
    var paths: std.ArrayList([]const u8) = .empty;
    var it = frameworks.keyIterator();
    while (it.next()) |path| try paths.append(c.a, path.*);
    return paths.items;
}

fn entitlementsFile(c: Ctx, build_dir: []const u8) !?[]const u8 {
    const xml = (try metadata.entitlements(c.a, c.t, &c.tc.env)) orelse return null;
    const out = try std.fmt.allocPrint(c.a, "{s}/{s}.xcent", .{ build_dir, c.t.name });
    try sys.cwd().writeFile(sys.io, .{ .sub_path = out, .data = xml });
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
    var locks: std.ArrayList(state.Lock) = .empty;
    errdefer for (locks.items) |*lock| lock.release();
    var roots = std.StringHashMap(void).init(a);
    for (targets) |t| {
        const root = try sys.realpath(a, t.dir);
        if (roots.contains(root)) continue;
        try locks.append(a, try state.Lock.acquire(a, root));
        try roots.put(root, {});
    }
    return locks.items;
}

fn hasSvg(a: Allocator, path: []const u8) !bool {
    var dir = try sys.cwd().openDir(sys.io, path, .{ .iterate = true });
    defer dir.close(sys.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(sys.io)) |e| if (std.ascii.endsWithIgnoreCase(e.path, ".svg")) return true;
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
        // xtool copies `resources:` verbatim into the app root; anything that
        // needs an idl resource compiler still requires builder: direct.
        for (try fsutil.discover(a, t.dir, t.resources, "resource")) |rel| {
            if (codegen.xtoolCompiledResource(rel))
                return diag.fail("{s}: {s} needs a resource compiler; xtool targets only copy resources verbatim (use builder: direct)", .{ t.name, rel });
        }
        if (t.icon) |i| {
            try fsutil.rejectSymlinkComponents(a, t.dir, i);
            if (fsutil.kind(try t.path(a, i)) != .file) return diag.fail("{s}: icon not found: {s}", .{ t.name, i });
        }
        if (t.package_swift) _ = try codegen.packageSwift(a, t);
    }
    if (t.type.bundled()) {
        _ = try metadata.processInfoPlist(a, t, &tc.env, null);
        _ = try metadata.entitlements(a, t, &tc.env);
    }
    if (swift) {
        // No --version: the processor only takes a full extraction command line.
        if (try appIntentsTool(tc, t, strict, true, false)) |tool| _ = try tc.identity(tool, false);
    }
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
    var prepared: std.ArrayList(resources.Prepared) = .empty;
    errdefer for (prepared.items) |p| if (p.info) |info| info.deinit();
    for (targets) |t| try prepared.append(a, try resources.prepare(a, tc, t, strict or t.strict, verbose));
    return .{ .locks = locks, .prepared = prepared.items };
}

fn buildDirect(c: Ctx) !Product {
    const a = c.a;
    const t = c.t;
    const sources = try fsutil.discover(a, t.dir, t.sources, "source");
    var swift: std.ArrayList([]const u8) = .empty;
    var has_c = false;
    var need_cxx = false;
    for (sources) |s| switch (Toolchain.langOf(s) orelse continue) {
        .swift => try swift.append(a, try t.path(a, s)),
        .cxx, .objcxx => {
            has_c = true;
            need_cxx = true;
        },
        else => has_c = true,
    };
    try c.tc.require(swift.items.len > 0);

    const build_dir = try t.buildPath(a);
    const obj_dir = try std.Io.Dir.path.join(a, &.{ build_dir, "obj", t.name });
    const module_cache = try std.Io.Dir.path.join(a, &.{ build_dir, "ModuleCache" });
    try sys.makePath(module_cache);
    const deps = try resolveDeps(c);

    var objects: std.ArrayList([]const u8) = .empty;
    var changed = false;
    var swift_out: ?SwiftOut = null;
    const intents_tool = if (swift.items.len > 0) try appIntentsTool(c.tc, t, c.opts.strict, deps.intent_consts.len > 0, deps.intent_consts.len > 0) else null;
    const const_values = swift.items.len > 0 and (intents_tool != null or (t.type == .static and t.appIntents().enabled));
    if (swift.items.len > 0) {
        swift_out = try compileSwift(c, swift.items, obj_dir, module_cache, deps, has_c, const_values);
        changed = swift_out.?.changed;
    }
    var extra: std.ArrayList([]const u8) = .empty;
    try extra.appendSlice(a, deps.c_flags);
    if (swift_out) |so| if (so.header_dir) |h| try extra.appendSlice(a, &.{ "-I", h });
    const c_objects, const c_changed = try compileObjects(c, sources, obj_dir, module_cache, extra.items);
    try objects.appendSlice(a, c_objects);
    if (swift_out) |so| try objects.append(a, so.obj);
    changed = changed or c_changed;

    if (t.type == .static) {
        if (objects.items.len == 0) return diag.fail("target '{s}': no compilable sources found", .{t.name});
        return .{
            .name = t.name,
            .kind = t.type,
            .objects = objects.items,
            .module_dir = if (swift_out) |so| so.module_dir else null,
            .header_dir = if (swift_out) |so| so.header_dir else null,
            .const_values = if (const_values) try constValuesPath(a, obj_dir, t) else null,
            .swift_sources = if (const_values) swift.items else &.{},
        };
    }
    const linked = try linkOutput(a, t, build_dir);
    try link(c, objects.items, changed, swift.items.len > 0, need_cxx, linked, module_cache, deps);
    const intents = if (intents_tool) |tool| try extractAppIntents(c, tool, linked, swift.items, obj_dir, deps, changed) else null;
    var p: Product = .{ .name = t.name, .kind = t.type, .link_binary = linked, .module_dir = if (swift_out) |so| so.module_dir else null, .header_dir = if (swift_out) |so| so.header_dir else null };
    switch (t.type) {
        .dylib => p.bundle = try assembleDylib(c, linked, build_dir),
        .framework, .appex => p.bundle = try assembleBundle(c, linked, build_dir, intents),
        .app => p.ipa = try assembleBundle(c, linked, build_dir, intents),
        .static, .@"test" => unreachable,
    }
    return p;
}

/// The exact compiler invocations `buildDirect` uses for a target, without
/// outputs (`-c`/`-o`/emit flags), for tools that re-run the compilers (lint).
/// Dependencies must already be in `products`.
pub const Invocations = struct {
    pub const Source = struct { rel: []const u8, path: []const u8, lang: Toolchain.Lang, argv: []const []const u8 };
    c_family: []const Source,
    /// swiftc + flags + all Swift sources of the module, or null.
    swift: ?[]const []const u8,
    swift_files: []const []const u8,
};

pub fn invocations(a: Allocator, tc: *Toolchain, t: Target, products: *Products) !Invocations {
    const c: Ctx = .{ .a = a, .tc = tc, .t = t, .opts = .{ .products = products } };
    const sources = try fsutil.discover(a, t.dir, t.sources, "source");
    var swift: std.ArrayList([]const u8) = .empty;
    var has_c = false;
    for (sources) |s| switch (Toolchain.langOf(s) orelse continue) {
        .swift => try swift.append(a, try t.path(a, s)),
        else => has_c = true,
    };
    try tc.require(swift.items.len > 0);
    const build_dir = try t.buildPath(a);
    const module_cache = try std.Io.Dir.path.join(a, &.{ build_dir, "ModuleCache" });
    try sys.makePath(module_cache);
    const deps = try resolveDeps(c);
    var extra: std.ArrayList([]const u8) = .empty;
    try extra.appendSlice(a, deps.c_flags);
    if (swift.items.len > 0 and has_c) try extra.appendSlice(a, &.{ "-I", try std.Io.Dir.path.join(a, &.{ build_dir, "obj", t.name, "include" }) });
    var out: std.ArrayList(Invocations.Source) = .empty;
    for (sources) |rel| {
        const lang = Toolchain.langOf(rel) orelse continue;
        if (lang == .swift) continue;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, if (lang == .cxx or lang == .objcxx) tc.cxx orelse return diag.fail("missing tool: {s}", .{tc.cfg.cxx}) else tc.cc.?);
        try argv.appendSlice(a, try tc.cflags(t, lang, module_cache));
        try argv.appendSlice(a, extra.items);
        try out.append(a, .{ .rel = rel, .path = try t.path(a, rel), .lang = lang, .argv = argv.items });
    }
    var swift_argv: ?[]const []const u8 = null;
    if (swift.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, tc.swiftc.?);
        try argv.appendSlice(a, try tc.swiftflags(t, module_cache));
        if (parseAsLibrary(t, swift.items)) try argv.append(a, "-parse-as-library");
        try argv.appendSlice(a, deps.swift_flags);
        try argv.appendSlice(a, swift.items);
        swift_argv = argv.items;
    }
    return .{ .c_family = out.items, .swift = swift_argv, .swift_files = swift.items };
}

fn signerKey(c: Ctx, f: *state.Fingerprint, ldid: ?[]const u8) !void {
    f.add(if (ldid != null) "signed" else "unsigned");
    if (ldid) |l| f.add(try c.tc.identity(l, false));
}

fn assembleDylib(c: Ctx, linked: []const u8, build_dir: []const u8) ![]const u8 {
    const a = c.a;
    const ldid_opt: ?[]const u8 = if (c.t.signs()) try c.tc.ldid() else null;
    const out = try std.Io.Dir.path.join(a, &.{ build_dir, "products", try c.t.productName(a) });
    var f: state.Fingerprint = .{};
    f.add("dylib-v1");
    f.add(try c.tc.selfIdentity());
    f.add(try state.treeDigest(a, linked));
    try signerKey(c, &f, ldid_opt);
    const key = try f.finish(a);
    const stamp = try std.fmt.allocPrint(a, "{s}.state", .{out});
    if (try state.hit(a, stamp, key, out)) return out;
    try sys.makePath(std.Io.Dir.path.dirname(out).?);
    const tmp = try std.fmt.allocPrint(a, "{s}.partial", .{out});
    try sys.cwd().copyFile(linked, sys.cwd(), tmp, sys.io, .{ .permissions = .fromMode(0o755) });
    if (ldid_opt) |ldid| {
        if (!c.opts.verbose) diag.info("  SIGN [{s}]", .{c.t.name});
        try run(c, &.{ ldid, "-S", tmp }, c.t.dir);
    }
    try sys.cwd().rename(tmp, sys.cwd(), out, sys.io);
    try state.record(a, stamp, key, out);
    return out;
}

/// Bundle, sign and (for apps) package an app, framework or extension.
/// Returns the IPA for apps, otherwise the signed bundle directory.
fn assembleBundle(c: Ctx, linked: []const u8, build_dir: []const u8, intents: ?[]const u8) ![]const u8 {
    const a = c.a;
    const t = c.t;
    const is_app = t.type == .app;
    const ldid_opt: ?[]const u8 = if (t.signs()) try c.tc.ldid() else null;
    const prepared = c.opts.prepared.?;
    const info_xml = try processInfoPlist(a, t, &c.tc.env, prepared.info);
    const ent_xml = (try metadata.entitlements(a, t, &c.tc.env)) orelse "";

    // Embedded products, checked against resource outputs.
    const Embed = struct { src: []const u8, dest: []const u8 };
    var embeds: std.ArrayList(Embed) = .empty;
    for (t.embed) |name| {
        const p = try product(c, name);
        const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ if (p.kind == .appex) "PlugIns" else "Frameworks", std.Io.Dir.path.basename(p.bundle.?) });
        for (prepared.outputs) |o| if (std.mem.eql(u8, o.dest, dest) or std.mem.startsWith(u8, o.dest, try std.fmt.allocPrint(a, "{s}/", .{dest})))
            return diag.fail("{s}: resource {s} collides with embedded target {s}", .{ t.name, o.owner, name });
        try embeds.append(a, .{ .src = p.bundle.?, .dest = dest });
    }
    // App Intents metadata goes to the bundle root, like Xcode's ExtractAppIntentsMetadata.
    if (intents) |dir| {
        for (prepared.outputs) |o| if (std.mem.eql(u8, o.dest, "Metadata.appintents") or std.mem.startsWith(u8, o.dest, "Metadata.appintents/"))
            return diag.fail("{s}: resource {s} collides with the generated Metadata.appintents", .{ t.name, o.owner });
        try embeds.append(a, .{ .src = dir, .dest = "Metadata.appintents" });
    }

    var fingerprint: state.Fingerprint = .{};
    fingerprint.add("bundle-v2");
    fingerprint.add(try c.tc.selfIdentity());
    fingerprint.add(try state.treeDigest(a, linked));
    fingerprint.add(prepared.digest);
    fingerprint.add(info_xml);
    fingerprint.add(ent_xml);
    for (embeds.items) |e| {
        fingerprint.add(e.dest);
        fingerprint.add(try state.treeDigest(a, e.src));
    }
    try signerKey(c, &fingerprint, ldid_opt);
    const key = try fingerprint.finish(a);

    // Apps: <build>/Payload/<name>.app + <build>/<name>.ipa.
    // Frameworks/extensions: <build>/products/<name>.{framework,appex}.
    const out = if (is_app) try std.Io.Dir.path.join(a, &.{ build_dir, "Payload" }) else try std.Io.Dir.path.join(a, &.{ build_dir, "products", try t.productName(a) });
    const result = if (is_app) try t.ipaPath(a) else out;
    const stamp = if (is_app) try std.Io.Dir.path.join(a, &.{ build_dir, "bundle.state" }) else try std.fmt.allocPrint(a, "{s}.state", .{out});
    const out_stamp = if (is_app) try std.Io.Dir.path.join(a, &.{ build_dir, "payload.state" }) else stamp;
    if (try state.hit(a, stamp, key, result) and try state.hit(a, out_stamp, key, out)) {
        if (c.opts.verbose) diag.info("  CACHED {s}", .{try t.productName(a)});
        return result;
    }
    // Staging prevents failures from destroying the previous successful output.
    const pending = try std.fmt.allocPrint(a, "{s}.partial", .{out});
    try sys.deleteTree(pending);
    const bundle = if (is_app) try std.fmt.allocPrint(a, "{s}/{s}.app", .{ pending, t.name }) else pending;
    try sys.makePath(bundle);
    const bundle_exe = try std.Io.Dir.path.join(a, &.{ bundle, t.name });
    try sys.cwd().copyFile(linked, sys.cwd(), bundle_exe, sys.io, .{ .permissions = .fromMode(0o755) });
    const frameworks = try copyResources(c, bundle, prepared);
    try sys.cwd().writeFile(sys.io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ bundle, "Info.plist" }), .data = info_xml });
    if (is_app) try sys.cwd().writeFile(sys.io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ bundle, "PkgInfo" }), .data = "APPL????" });
    // Embedded products were signed when they were built.
    for (embeds.items) |e| try copyTree(a, e.src, try std.Io.Dir.path.join(a, &.{ bundle, e.dest }));

    if (ldid_opt) |ldid| {
        // Nested code first, then the containing executable.
        for (frameworks) |fw| {
            const bin = try std.Io.Dir.path.join(a, &.{ fw, std.Io.Dir.path.stem(fw) });
            if (fsutil.kind(bin) == .file) try run(c, &.{ ldid, "-S", fw }, t.dir);
        }
        if (!c.opts.verbose) diag.info("  SIGN [{s}]", .{t.name});
        if (t.type == .framework) {
            try run(c, &.{ ldid, "-S", bundle }, t.dir);
        } else {
            const ent = try entitlementsFile(c, build_dir);
            const s_flag = if (ent) |e| try std.fmt.allocPrint(a, "-S{s}", .{e}) else "-S";
            try run(c, &.{ ldid, s_flag, try std.fmt.allocPrint(a, "-I{s}", .{t.bundle_id}), bundle_exe }, t.dir);
        }
    }

    if (is_app) {
        var w = zip.Writer.init(a);
        var payload_dir = try sys.cwd().openDir(sys.io, pending, .{ .iterate = true });
        defer payload_dir.close(sys.io);
        try w.addTree(payload_dir, "Payload");
        const tmp = try std.fmt.allocPrint(a, "{s}.partial", .{result});
        try sys.cwd().writeFile(sys.io, .{ .sub_path = tmp, .data = try w.finish() });
        try sys.cwd().rename(tmp, sys.cwd(), result, sys.io);
    }
    try sys.deleteTree(out);
    try sys.cwd().rename(pending, sys.cwd(), out, sys.io);
    try state.record(a, out_stamp, key, out);
    if (is_app) try state.record(a, stamp, key, result);
    return result;
}

/// xtool 1.24's entitlement-rewrite path can drop executable ZIP mode bits.
/// Repair ZIP metadata only; executable bytes (and signatures) stay identical.
fn normalizeXtoolPermissions(a: Allocator, path: []const u8, name: []const u8) !void {
    const ar = try zip.open(a, try sys.readFile(a, path, 2 << 30));
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
    try sys.cwd().writeFile(sys.io, .{ .sub_path = tmp, .data = try out.finish() });
    try sys.cwd().rename(tmp, sys.cwd(), path, sys.io);
}

fn buildXtool(c: Ctx) ![]const u8 {
    const a = c.a;
    try codegen.genXtool(a, c.t);
    const xtool = (try fsutil.which(a, c.tc.cfg.xtool, c.tc.pathEnv())) orelse return diag.fail("missing tool: {s} (https://github.com/xtool-org/xtool)", .{c.tc.cfg.xtool});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ xtool, "dev", "build", "-c", c.t.configuration });
    if (c.t.signs()) try argv.append(a, "--sign");
    try argv.append(a, "--ipa");
    if (!c.opts.verbose) diag.info("  XTOOL {s}", .{c.t.name});
    try run(c, argv.items, c.t.dir);
    const ipa = try c.t.ipaPath(a);
    const original = try std.fmt.allocPrint(a, "{s}/xtool/{s}.ipa", .{ c.t.dir, c.t.name });
    try normalizeXtoolPermissions(a, original, c.t.name);
    if (c.t.profile != null) {
        try sys.makePath(try c.t.buildPath(a));
        try sys.cwd().copyFile(original, sys.cwd(), ipa, sys.io, .{});
    }
    return ipa;
}

pub fn build(a: Allocator, tc: *Toolchain, t: Target, opts: Options) !Product {
    if (t.type == .@"test") return diag.fail("'{s}' is a test target; `idl test` builds it for the host", .{t.name});
    var session: ?Session = if (!opts.locked) try prepareAll(a, tc, &.{t}, opts.strict, opts.verbose) else null;
    defer if (session) |*s| s.release();
    var options = opts;
    if (session) |s| options.prepared = s.prepared[0];
    const c: Ctx = .{ .a = a, .tc = tc, .t = t, .opts = options };
    diag.info("==> {s} ({s}{s})", .{ t.name, @tagName(t.builder), if (t.type == .app) "" else try std.fmt.allocPrint(a, ", {s}", .{@tagName(t.type)}) });
    const p: Product = switch (t.builder) {
        .direct => try buildDirect(c),
        .xtool => .{ .name = t.name, .kind = .app, .ipa = try buildXtool(c) },
    };
    if (opts.products) |products| try products.put(t.name, p);
    if (p.ipa) |ipa| {
        _ = try verify.verifyFile(a, ipa, .{ .bundle_id = t.bundle_id, .allow_unsigned = !t.signs() });
        if (t.post_build.len > 0 and opts.post_build) try postBuild(c, ipa);
    }
    return p;
}

/// Run the target's post_build commands, in order, after its IPA is verified.
fn postBuild(c: Ctx, ipa: []const u8) !void {
    const a = c.a;
    var env = std.process.Environ.Map.init(a);
    var it = c.tc.env.iterator();
    while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
    const build_dir = try c.t.buildPath(a);
    try env.put("IDL_IPA", ipa);
    try env.put("IDL_APP", try std.fmt.allocPrint(a, "{s}/Payload/{s}.app", .{ build_dir, c.t.name }));
    try env.put("IDL_BUILD_DIR", build_dir);
    try env.put("IDL_TARGET", c.t.name);
    try env.put("IDL", try sys.selfExePath(a));
    if (c.t.profile) |prof| try env.put("IDL_CONFIGURATION", prof);
    for (c.t.post_build) |argv| {
        if (!c.opts.verbose) diag.info("  POST [{s}] {s}", .{ c.t.name, try std.mem.join(a, " ", argv) }) else printCommand(argv);
        var child = sys.spawn(argv, .{ .cwd = c.t.dir, .env = &env }) catch |err| return diag.fail("cannot run post_build {s}: {s}", .{ argv[0], @errorName(err) });
        if (!succeeded(try sys.wait(&child))) return diag.fail("{s}: post_build command failed: {s}", .{ c.t.name, try std.mem.join(a, " ", argv) });
    }
}

pub fn clean(a: Allocator, t: Target) !void {
    var doomed: std.ArrayList([]const u8) = .empty;
    switch (t.builder) {
        .direct => try doomed.append(a, try t.buildPath(a)),
        .xtool => {
            try doomed.append(a, try t.buildPath(a));
            for ([_][]const u8{ ".build", ".bsp", "xtool" }) |d| try doomed.append(a, try t.path(a, d));
        },
    }
    if (t.xcodeproj) try doomed.append(a, try std.fmt.allocPrint(a, "{s}/{s}.xcodeproj", .{ t.dir, t.name }));
    for (doomed.items) |p| if (fsutil.kind(p) != .missing) {
        diag.info("  RM   {s}", .{p});
        try sys.deleteTree(p);
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
    const path = try std.Io.Dir.path.join(a, &.{ try tmp.dir.realPathFileAlloc(sys.io, ".", a), "App.ipa" });
    var w = zip.Writer.init(a);
    try w.addFile("Payload/App.app/App", "unchanged executable bytes", 0o644);
    try w.addFile("Payload/App.app/data", "resource", 0o644);
    try sys.cwd().writeFile(sys.io, .{ .sub_path = path, .data = try w.finish() });
    try normalizeXtoolPermissions(a, path, "App");
    const ar = try zip.open(a, try sys.readFile(a, path, 1 << 20));
    const exe = ar.find("Payload/App.app/App").?;
    try std.testing.expect(exe.mode & 0o111 != 0);
    try std.testing.expectEqualStrings("unchanged executable bytes", try ar.read(a, exe));
    try std.testing.expectEqual(@as(u32, 0), ar.find("Payload/App.app/data").?.mode & 0o111);
}
