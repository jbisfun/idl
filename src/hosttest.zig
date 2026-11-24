//! `type: test` targets: unit tests built and run on the Linux host.
//!
//! iOS binaries cannot run on Linux and the iPhoneOS SDK has no XCTest, so a
//! test target and the static targets it `link`s are compiled for the host:
//!
//! - Swift: idl writes a SwiftPM package to `<build_dir>/test/<Name>/`
//!   (one library target per tested static target, one test target) and runs
//!   `swift build --build-tests` + `swift test`, so SwiftPM does XCTest and
//!   swift-testing discovery. SwiftPM refuses target paths outside the package
//!   root and idl refuses symlinks, so the sources are copied into the package
//!   (only changed files are rewritten, keeping SwiftPM incremental); paths in
//!   the tool output are mapped back to the original files.
//! - C/C++ (and Objective-C, given a host runtime): host clang compiles the
//!   test and tested sources into `<build_dir>/test/<Name>/<Name>`, which is
//!   run; exit status 0 is a pass.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const config = @import("config.zig");
const builder = @import("builder.zig");
const codegen = @import("codegen.zig");
const Toolchain = @import("toolchain.zig").Toolchain;

const Allocator = std.mem.Allocator;
const Target = config.Target;

pub const Options = struct {
    verbose: bool = false,
    /// Run the existing build outputs (`swift test --skip-build`, the existing executable).
    no_build: bool = false,
};

pub const Outcome = union(enum) {
    passed,
    /// Compilation or linking failed (tool output was printed).
    build_failed,
    /// The tests ran and failed; exit status of the runner.
    failed: u8,
};

/// Output directory of a test target: `<build_dir>/test/<name>`.
pub fn outDir(a: Allocator, t: Target) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/test/{s}", .{ try t.buildPath(a), t.name });
}

const Module = struct {
    target: Target,
    /// Source paths relative to `target.dir`.
    files: []const []const u8,
    swift: bool,
};

/// Discovered sources of `t`; mixing Swift with C-family code is rejected.
fn module(a: Allocator, t: Target) !Module {
    var files: std.ArrayList([]const u8) = .empty;
    var swift: usize = 0;
    for (try fsutil.discover(a, t.dir, t.sources, "source")) |rel| {
        const lang = Toolchain.langOf(rel) orelse continue;
        if (lang == .swift) swift += 1;
        try files.append(a, rel);
    }
    if (swift > 0 and swift != files.items.len)
        return diag.fail("target '{s}': mixes Swift and C-family sources; host tests need one language per target (SwiftPM modules)", .{t.name});
    return .{ .target = t, .files = files.items, .swift = swift > 0 };
}

/// The test target's modules: tested static targets first (dependency
/// order), the test target last.
fn modules(a: Allocator, all: []const Target, t: Target) ![]const Module {
    const order = try config.buildOrder(a, all, &.{t});
    const out = try a.alloc(Module, order.len);
    for (order, out) |dep, *m| m.* = try module(a, dep);
    const tests = out[out.len - 1];
    if (tests.files.len == 0) return diag.fail("test target '{s}': no test sources found in {s}", .{ t.name, try std.mem.join(a, ", ", t.sources) });
    for (out[0 .. out.len - 1]) |m| if (m.files.len > 0 and m.swift != tests.swift)
        return diag.fail("test target '{s}': {s} tests cannot link {s} static target '{s}'", .{ t.name, if (tests.swift) "Swift" else "C-family", if (m.swift) "Swift" else "C-family", m.target.name });
    return out;
}

/// Build and run one test target. Prints tool output; the caller reports the outcome.
pub fn run(a: Allocator, tc: *Toolchain, all: []const Target, t: Target, opts: Options) !Outcome {
    const mods = try modules(a, all, t);
    return if (mods[mods.len - 1].swift) runSwift(a, tc, t, mods, opts) else runC(a, tc, t, mods, opts);
}

// ------------------------------------------------------------------- Swift

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// Mirror `files` (relative to `src_root`) into `dest_root`, rewriting only
/// changed files and deleting files that are no longer listed.
fn syncTree(a: Allocator, src_root: []const u8, dest_root: []const u8, files: []const []const u8) !void {
    var keep = std.StringHashMap(void).init(a);
    for (files) |rel| {
        try keep.put(rel, {});
        const data = sys.readFile(a, try fsutil.join(a, src_root, rel), 64 << 20) catch |err|
            return diag.fail("cannot read {s}/{s}: {s}", .{ src_root, rel, @errorName(err) });
        _ = try fsutil.writeIfChanged(a, try fsutil.join(a, dest_root, rel), data);
    }
    if (fsutil.kind(dest_root) != .dir) return;
    for (try fsutil.discover(a, dest_root, &.{"."}, "copied source")) |rel| if (!keep.contains(rel)) {
        try sys.deleteFile(try fsutil.join(a, dest_root, rel));
    };
}

/// `swift` next to the configured `swiftc` (same toolchain), else from PATH.
fn swiftDriver(a: Allocator, tc: *const Toolchain) ![]const u8 {
    const swiftc = tc.swiftc orelse return diag.fail("missing tool: {s} (Swift tests need a host Swift toolchain)", .{tc.cfg.swiftc});
    if (std.Io.Dir.path.dirname(swiftc)) |dir| {
        const sibling = try std.Io.Dir.path.join(a, &.{ dir, "swift" });
        if (fsutil.kindFollow(sibling) == .file) return sibling;
    }
    return (try fsutil.which(a, "swift", tc.pathEnv())) orelse diag.fail("missing tool: swift (needed for Swift test targets)", .{});
}

fn runSwift(a: Allocator, tc: *Toolchain, t: Target, mods: []const Module, opts: Options) !Outcome {
    const pkg = try outDir(a, t);
    var sw_mods: std.ArrayList(codegen.SwiftModule) = .empty;
    var maps: std.ArrayList(PathMap) = .empty;
    for (mods, 0..) |m, i| {
        if (m.files.len == 0) continue;
        if (!isIdentifier(m.target.name)) return diag.fail("target '{s}': Swift module names must be identifiers (letters, digits, underscore)", .{m.target.name});
        const is_tests = i == mods.len - 1;
        const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ if (is_tests) "Tests" else "Sources", m.target.name });
        const copy_root = try std.Io.Dir.path.join(a, &.{ pkg, rel });
        if (!opts.no_build) try syncTree(a, m.target.dir, copy_root, m.files);
        try maps.append(a, .{ .from = try std.fmt.allocPrint(a, "{s}/", .{copy_root}), .to = try std.fmt.allocPrint(a, "{s}/", .{m.target.dir}) });
        var deps: std.ArrayList([]const u8) = .empty;
        for (m.target.link) |d| for (mods) |o| if (std.mem.eql(u8, o.target.name, d) and o.files.len > 0) try deps.append(a, d);
        try sw_mods.append(a, .{ .target = m.target, .path = rel, .deps = deps.items, .tests = is_tests });
    }
    const manifest = try std.Io.Dir.path.join(a, &.{ pkg, "Package.swift" });
    if (opts.no_build) {
        if (fsutil.kind(manifest) != .file) return diag.fail("{s} does not exist; run `idl test {s}` without --no-build first", .{ manifest, t.name });
    } else _ = try fsutil.writeIfChanged(a, manifest, try codegen.testPackageSwift(a, t.name, sw_mods.items));

    const swift = try swiftDriver(a, tc);
    // @testable import needs -enable-testing, which SwiftPM adds in debug only.
    const release = if (t.profile) |p| std.mem.eql(u8, p, "release") else false;
    const cfg_args: []const []const u8 = if (release) &.{ "-c", "release", "-Xswiftc", "-enable-testing" } else &.{ "-c", "debug" };
    const build_argv = try std.mem.concat(a, []const u8, &.{ &.{ swift, "build", "--build-tests", "--package-path", pkg }, cfg_args });
    if (!opts.no_build) {
        diag.info("==> {s}: swift build --build-tests", .{t.name});
        if (!sys.succeeded(try runMapped(a, tc, build_argv, pkg, maps.items, opts))) return .build_failed;
    }
    const test_argv = try std.mem.concat(a, []const u8, &.{ &.{ swift, "test", "--skip-build", "--package-path", pkg }, cfg_args });
    diag.info("==> {s}: swift test", .{t.name});
    return outcome(try runMapped(a, tc, test_argv, pkg, maps.items, opts));
}

fn outcome(term: sys.Term) Outcome {
    return switch (term) {
        .exited => |code| if (code == 0) .passed else .{ .failed = code },
        else => .{ .failed = 128 },
    };
}

const PathMap = struct { from: []const u8, to: []const u8 };

fn mapLine(a: Allocator, line: []const u8, maps: []const PathMap) ![]const u8 {
    var out = line;
    for (maps) |m| if (std.mem.indexOf(u8, out, m.from) != null) {
        out = try std.mem.replaceOwned(u8, a, out, m.from, m.to);
    };
    return out;
}

fn emitLines(a: Allocator, r: *std.Io.Reader, file: std.Io.File, maps: []const PathMap, final: bool) !void {
    while (true) {
        const buffered = r.buffered();
        const nl = std.mem.indexOfScalar(u8, buffered, '\n') orelse {
            if (final and buffered.len > 0) {
                file.writeStreamingAll(sys.io, try mapLine(a, buffered, maps)) catch {};
                r.toss(buffered.len);
            }
            return;
        };
        const line = try mapLine(a, buffered[0 .. nl + 1], maps);
        file.writeStreamingAll(sys.io, line) catch {};
        r.toss(nl + 1);
    }
}

/// Run a tool, streaming its stdout/stderr line by line with copied-source
/// paths mapped back to the originals.
fn runMapped(a: Allocator, tc: *Toolchain, argv: []const []const u8, cwd: []const u8, maps: []const PathMap, opts: Options) !sys.Term {
    if (opts.verbose) diag.info("  {s}", .{try std.mem.join(a, " ", argv)});
    var child = sys.spawn(argv, .{ .cwd = cwd, .env = &tc.env, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe }) catch |err|
        return diag.fail("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
    defer child.kill(sys.io);
    var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, sys.io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const outs = [_]std.Io.File{ .stdout(), .stderr() };
    while (true) {
        const more = if (mr.fill(4096, .none)) |_| true else |err| switch (err) {
            error.EndOfStream => false,
            else => |e| return e,
        };
        for (outs, 0..) |file, i| try emitLines(a, mr.reader(i), file, maps, !more);
        if (!more) break;
    }
    return sys.wait(&child);
}

// ---------------------------------------------------------------------- C

/// Host clang flags for one C-family source of `t` (no -target/-isysroot).
fn hostCflags(a: Allocator, t: Target, lang: Toolchain.Lang) ![]const []const u8 {
    var f: std.ArrayList([]const u8) = .empty;
    try f.appendSlice(a, &.{ t.opt, if (t.debug_symbols) "-g" else "-g0", "-MMD", "-MP" });
    switch (lang) {
        .cxx, .objcxx => try f.append(a, "-std=gnu++20"),
        .c, .objc => try f.append(a, "-std=gnu17"),
        .asm_, .swift => {},
    }
    for (t.include_dirs) |inc| try f.appendSlice(a, &.{ "-I", try t.path(a, inc) });
    for (t.quote_include_dirs) |d| try f.appendSlice(a, &.{ "-iquote", try t.path(a, d) });
    for (t.defines) |d| try f.append(a, try std.fmt.allocPrint(a, "-D{s}", .{d}));
    try f.appendSlice(a, t.cflags);
    return f.items;
}

/// Host compiler for `lang` (the configured cc/cxx, from PATH).
fn hostCompiler(tc: *const Toolchain, lang: Toolchain.Lang) ![]const u8 {
    const cxx = lang == .cxx or lang == .objcxx;
    return (if (cxx) tc.cxx else tc.cc) orelse diag.fail("missing tool: {s} (host compiler for C-family test targets)", .{if (cxx) tc.cfg.cxx else tc.cfg.cc});
}

pub const HostCommand = struct { file: []const u8, argv: []const []const u8, output: []const u8, owner: Target };

/// Compile commands (host flags) for every C-family source of a test target
/// and the static targets it tests; also used for compile_commands.json.
pub fn hostCompileCommands(a: Allocator, tc: *const Toolchain, t: Target, mods: []const Module) ![]const HostCommand {
    const obj_root = try std.fmt.allocPrint(a, "{s}/obj", .{try outDir(a, t)});
    var out: std.ArrayList(HostCommand) = .empty;
    // The tests see the tested targets' include_dirs (their public headers).
    var dep_includes: std.ArrayList([]const u8) = .empty;
    for (mods[0 .. mods.len - 1]) |m| for (m.target.include_dirs) |inc| try dep_includes.appendSlice(a, &.{ "-I", try m.target.path(a, inc) });
    for (mods, 0..) |m, i| for (m.files) |rel| {
        const lang = Toolchain.langOf(rel).?;
        const file = try m.target.path(a, rel);
        const obj = try std.fmt.allocPrint(a, "{s}/{s}/{s}.o", .{ obj_root, m.target.name, rel });
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, try hostCompiler(tc, lang));
        try argv.appendSlice(a, try hostCflags(a, m.target, lang));
        if (i == mods.len - 1) try argv.appendSlice(a, dep_includes.items);
        try argv.appendSlice(a, &.{ "-c", file, "-o", obj });
        try out.append(a, .{ .file = file, .argv = argv.items, .output = obj, .owner = m.target });
    };
    return out.items;
}

fn runC(a: Allocator, tc: *Toolchain, t: Target, mods: []const Module, opts: Options) !Outcome {
    const exe = try std.fmt.allocPrint(a, "{s}/{s}", .{ try outDir(a, t), t.name });
    if (!opts.no_build) {
        if (try buildC(a, tc, t, mods, exe, opts) == .build_failed) return .build_failed;
    } else if (fsutil.kind(exe) != .file) return diag.fail("{s} does not exist; run `idl test {s}` without --no-build first", .{ exe, t.name });
    diag.info("==> {s}: {s}", .{ t.name, exe });
    var env = try tc.env.clone(a);
    try env.put("IDL_TARGET", t.name);
    var child = sys.spawn(&.{exe}, .{ .cwd = t.dir, .env = &env }) catch |err|
        return diag.fail("cannot run {s}: {s}", .{ exe, @errorName(err) });
    return outcome(try sys.wait(&child));
}

fn buildC(a: Allocator, tc: *Toolchain, t: Target, mods: []const Module, exe: []const u8, opts: Options) !Outcome {
    const cmds = try hostCompileCommands(a, tc, t, mods);
    var objects: std.ArrayList([]const u8) = .empty;
    var need_cxx = false;
    var relinked = false;
    for (cmds) |cmd| {
        try objects.append(a, cmd.output);
        const lang = Toolchain.langOf(cmd.file).?;
        if (lang == .cxx or lang == .objcxx) need_cxx = true;
        const key = try std.mem.join(a, "\x00", cmd.argv);
        const depfile = try std.fmt.allocPrint(a, "{s}.d", .{cmd.output[0 .. cmd.output.len - 2]});
        var inputs: std.ArrayList([]const u8) = .empty;
        try inputs.append(a, cmd.file);
        if (sys.readFile(a, depfile, 16 << 20)) |text| try inputs.appendSlice(a, try builder.depfileInputs(a, text)) else |_| {}
        if (try builder.upToDate(a, cmd.output, key, inputs.items, cmd.owner.dir)) continue;
        try sys.makePath(std.Io.Dir.path.dirname(cmd.output).?);
        if (opts.verbose) diag.info("  {s}", .{try std.mem.join(a, " ", cmd.argv)}) else diag.info("  CC   [{s}] {s}", .{ t.name, cmd.file });
        if (!sys.succeeded(try runPlain(cmd.argv, cmd.owner.dir, tc))) return .build_failed;
        try builder.writeStamp(a, cmd.output, key);
        relinked = true;
    }
    var link: std.ArrayList([]const u8) = .empty;
    try link.append(a, try hostCompiler(tc, if (need_cxx) .cxx else .c));
    try link.appendSlice(a, objects.items);
    try link.appendSlice(a, &.{ "-o", exe });
    for (mods) |m| {
        for (m.target.libraries) |l| try link.append(a, try std.fmt.allocPrint(a, "-l{s}", .{l}));
        for (m.target.ldflags) |l| try link.appendSlice(a, &.{ "-Xlinker", l });
    }
    const link_key = try std.mem.join(a, "\x00", link.items);
    if (relinked or !try builder.upToDate(a, exe, link_key, objects.items, t.dir)) {
        if (opts.verbose) diag.info("  {s}", .{try std.mem.join(a, " ", link.items)}) else diag.info("  LD   [{s}] {s}", .{ t.name, exe });
        if (!sys.succeeded(try runPlain(link.items, t.dir, tc))) return .build_failed;
        try builder.writeStamp(a, exe, link_key);
    }
    return .passed;
}

fn runPlain(argv: []const []const u8, cwd: []const u8, tc: *Toolchain) !sys.Term {
    var child = sys.spawn(argv, .{ .cwd = cwd, .env = &tc.env }) catch |err|
        return diag.fail("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
    return sys.wait(&child);
}

/// compile_commands.json entries for a test target (host flags).
pub fn compileCommandsJson(a: Allocator, tc: *const Toolchain, all: []const Target, t: Target) ![]const u8 {
    const mods = try modules(a, all, t);
    const Entry = struct { directory: []const u8, file: []const u8, arguments: []const []const u8, output: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    if (mods[mods.len - 1].swift) {
        // sourcekit-lsp: one entry per file with the module's files; tested
        // modules come from the SwiftPM build of `idl test`.
        const pkg = try outDir(a, t);
        for (mods) |m| {
            if (m.files.len == 0) continue;
            var files: std.ArrayList([]const u8) = .empty;
            for (m.files) |rel| try files.append(a, try m.target.path(a, rel));
            for (files.items) |file| {
                var argv: std.ArrayList([]const u8) = .empty;
                // Module output of SwiftPM's swift-build backend and of its native one.
                try argv.appendSlice(a, &.{ tc.swiftc orelse tc.cfg.swiftc, "-module-name", m.target.name, "-I", try std.fmt.allocPrint(a, "{s}/.build/debug", .{pkg}), "-I", try std.fmt.allocPrint(a, "{s}/.build/debug/Modules", .{pkg}) });
                for (m.target.defines) |d| if (std.mem.indexOfScalar(u8, d, '=') == null) try argv.append(a, try std.fmt.allocPrint(a, "-D{s}", .{d}));
                try argv.appendSlice(a, m.target.swiftflags);
                try argv.appendSlice(a, files.items);
                try entries.append(a, .{ .directory = m.target.dir, .file = file, .arguments = argv.items, .output = pkg });
            }
        }
    } else for (try hostCompileCommands(a, tc, t, mods)) |c|
        try entries.append(a, .{ .directory = c.owner.dir, .file = c.file, .arguments = c.argv, .output = c.output });
    var out: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(entries.items, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

// ------------------------------------------------------------------ tests

test "path mapping and identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const maps = [_]PathMap{.{ .from = "/p/build/test/T/Sources/Core/", .to = "/p/core/" }};
    try std.testing.expectEqualStrings("/p/core/Sources/x.swift:3:1: error: boom", try mapLine(a, "/p/build/test/T/Sources/Core/Sources/x.swift:3:1: error: boom", &maps));
    try std.testing.expectEqualStrings("unrelated", try mapLine(a, "unrelated", &maps));
    try std.testing.expect(isIdentifier("CoreTests"));
    try std.testing.expect(!isIdentifier("Core-Tests"));
}
