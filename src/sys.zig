//! Process-wide `std.Io` instance and environment. `main` sets both once from
//! `std.process.Init`; unit tests use `std.testing`'s. idl is a short-lived CLI,
//! so threading `io` through every helper would only add noise.
const std = @import("std");
const builtin = @import("builtin");

pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;
var environ_map: ?*const std.process.Environ.Map = null;

pub fn init(i: std.Io, env: *const std.process.Environ.Map) void {
    io = i;
    environ_map = env;
}

/// A private, mutable copy of the process environment (old `getEnvMap`).
pub fn envMap(a: std.mem.Allocator) !std.process.Environ.Map {
    if (environ_map) |m| return m.clone(a);
    if (builtin.is_test) return std.testing.environ.createMap(a);
    unreachable;
}

pub fn getenv(name: []const u8) ?[]const u8 {
    if (environ_map) |m| return m.get(name);
    if (builtin.is_test) return std.testing.environ.getPosix(name);
    return null;
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// Absolute, symlink-resolved path (old `Dir.realpathAlloc`).
pub fn realpath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return cwd().realPathFileAlloc(io, path, a);
}

pub fn readFile(a: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return cwd().readFileAlloc(io, path, a, .limited(max));
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    return cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn makePath(path: []const u8) !void {
    return cwd().createDirPath(io, path);
}

pub fn deleteTree(path: []const u8) !void {
    return cwd().deleteTree(io, path);
}

pub fn deleteFile(path: []const u8) !void {
    return cwd().deleteFile(io, path);
}

/// Unbuffered stdout/stderr writes (diagnostics are line-sized; children
/// write to the same descriptors, so nothing may sit in a buffer).
pub fn out(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn err(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

pub fn print(file: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

pub fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    print(std.Io.File.stdout(), fmt, args);
}

pub fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    print(std.Io.File.stderr(), fmt, args);
}

/// Unbuffered stdout writer (output interleaves with `diag.info` and children).
pub fn stdoutWriter() std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(io, &.{});
}

// ------------------------------------------------------------- processes

pub const Child = std.process.Child;
pub const Term = std.process.Child.Term;

pub const SpawnOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    stdin: std.process.SpawnOptions.StdIo = .inherit,
    stdout: std.process.SpawnOptions.StdIo = .inherit,
    stderr: std.process.SpawnOptions.StdIo = .inherit,
};

/// `argv[0]` without a '/' is looked up on the PATH of `env` (the child's
/// environment), like Zig 0.14's `Child.spawn` with `env_map` did; std now
/// always searches the parent's PATH.
fn exeFor(argv0: []const u8, env: ?*const std.process.Environ.Map, buf: []u8) std.process.ReplaceOptions.Exe {
    const e = env orelse return .detect;
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) return .detect;
    var it = std.mem.tokenizeScalar(u8, e.get("PATH") orelse return .detect, ':');
    while (it.next()) |dir| {
        const candidate = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, argv0 }) catch continue;
        cwd().access(io, candidate, .{ .execute = true }) catch continue;
        const st = cwd().statFile(io, candidate, .{}) catch continue;
        if (st.kind == .directory) continue;
        return .{ .explicit = .{ .dir = cwd(), .path = candidate } };
    }
    return .detect;
}

pub fn spawn(argv: []const []const u8, opts: SpawnOptions) std.process.SpawnError!Child {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.process.spawn(io, .{
        .exe = exeFor(argv[0], opts.env, &buf),
        .argv = argv,
        .cwd = if (opts.cwd) |d| .{ .path = d } else .inherit,
        .environ_map = opts.env,
        .stdin = opts.stdin,
        .stdout = opts.stdout,
        .stderr = opts.stderr,
    });
}

pub fn wait(child: *Child) !Term {
    return child.wait(io);
}

pub fn succeeded(term: Term) bool {
    return term == .exited and term.exited == 0;
}

pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    /// Per-stream output limit (Zig 0.14's `Child.run` default was 50 KiB).
    max_output_bytes: usize = 50 * 1024,
};

/// Run to completion, collecting stdout and stderr (old `Child.run`).
pub fn run(a: std.mem.Allocator, argv: []const []const u8, opts: RunOptions) std.process.RunError!std.process.RunResult {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.process.run(a, io, .{
        .exe = exeFor(argv[0], opts.env, &buf),
        .argv = argv,
        .cwd = if (opts.cwd) |d| .{ .path = d } else .inherit,
        .environ_map = opts.env,
        .stdout_limit = .limited(opts.max_output_bytes),
        .stderr_limit = .limited(opts.max_output_bytes),
    });
}

pub fn selfExePath(a: std.mem.Allocator) ![]u8 {
    return std.process.executablePathAlloc(io, a);
}

pub fn selfExeDirPath(a: std.mem.Allocator) ![]u8 {
    return std.process.executableDirPathAlloc(io, a);
}

pub fn cpuCount() usize {
    return std.Thread.getCpuCount() catch 4;
}

/// Modification time in nanoseconds, or null if `path` cannot be stat'ed.
pub fn mtime(path: []const u8) ?i96 {
    const st = cwd().statFile(io, path, .{}) catch return null;
    return st.mtime.nanoseconds;
}

/// Lexical absolute path (old `std.fs.path.resolve`, which joined relative
/// paths onto the current directory; `resolveAlloc` no longer does).
pub fn resolve(a: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    const here = try std.process.currentPathAlloc(io, a);
    const all = try a.alloc([]const u8, paths.len + 1);
    all[0] = here;
    @memcpy(all[1..], paths);
    return std.Io.Dir.path.resolveAlloc(a, all);
}

/// Relative path from `from` to `to` (old `std.fs.path.relative`).
pub fn relative(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    const here = try std.process.currentPathAlloc(io, a);
    return std.Io.Dir.path.relativeAlloc(a, here, null, from, to);
}
