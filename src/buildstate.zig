//! Content-addressed build state and process-scoped advisory locks.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const Allocator = std.mem.Allocator;

// Tests describe the contracts before their implementation.
test "content fingerprint catches edits, additions, deletions and empty directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", a);
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "a", .data = "one" });
    const first = try treeDigest(a, root);
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "a", .data = "two" });
    const second = try treeDigest(a, root);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try tmp.dir.createDirPath(sys.io, "empty");
    try std.testing.expect(!std.mem.eql(u8, second, try treeDigest(a, root)));
    try tmp.dir.deleteTree(sys.io, "empty");
    try std.testing.expectEqualStrings(second, try treeDigest(a, root));
    try tmp.dir.deleteFile(sys.io, "a");
    try std.testing.expect(!std.mem.eql(u8, second, try treeDigest(a, root)));
}

test "cache only hits with matching key and intact outputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", a);
    const out = try std.Io.Dir.path.join(a, &.{ root, "out" });
    const stamp = try std.Io.Dir.path.join(a, &.{ root, "stamp" });
    try tmp.dir.createDirPath(sys.io, "out");
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "out/a", .data = "result" });
    try std.testing.expect(!try hit(a, stamp, "k", out));
    try record(a, stamp, "k", out);
    try std.testing.expect(try hit(a, stamp, "k", out));
    try std.testing.expect(!try hit(a, stamp, "changed tool", out));
    try tmp.dir.deleteFile(sys.io, "out/a");
    try std.testing.expect(!try hit(a, stamp, "k", out));
}

test "build lock is nonblocking and released on close" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", a);
    var first = try Lock.acquire(a, root);
    try std.testing.expectError(error.Invalid, Lock.acquire(a, root));
    first.release();
    var second = try Lock.acquire(a, root);
    second.release();
}

pub const Fingerprint = struct {
    hash: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),

    /// Length framing avoids ambiguity between path/value pairs.
    pub fn add(f: *Fingerprint, data: []const u8) void {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, data.len, .little);
        f.hash.update(&len);
        f.hash.update(data);
    }

    pub fn finish(f: *Fingerprint, a: Allocator) ![]const u8 {
        var digest: [32]u8 = undefined;
        f.hash.final(&digest);
        return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
    }
};

fn less(_: void, l: []const u8, rr: []const u8) bool {
    return std.mem.lessThan(u8, l, rr);
}

fn walk(a: Allocator, f: *Fingerprint, path: []const u8) anyerror!void {
    switch (fsutil.kind(path)) {
        .file => {
            f.add("file");
            var file = try sys.cwd().openFile(sys.io, path, .{ .mode = .read_only });
            defer file.close(sys.io);
            const st = try file.stat(sys.io);
            var meta: [12]u8 = undefined;
            std.mem.writeInt(u64, meta[0..8], st.size, .little);
            std.mem.writeInt(u32, meta[8..12], @intCast(st.permissions.toMode() & 0o777), .little);
            f.add(&meta);
            var buf: [65536]u8 = undefined;
            // Frame the size above; feed bytes without chunk-dependent framing.
            while (true) {
                const n = file.readStreaming(sys.io, &.{&buf}) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                f.hash.update(buf[0..n]);
            }
        },
        .dir => {
            f.add("dir");
            var dir = try sys.cwd().openDir(sys.io, path, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(sys.io);
            var names: std.ArrayList([]const u8) = .empty;
            var it = dir.iterate();
            while (try it.next(sys.io)) |e| try names.append(a, try a.dupe(u8, e.name));
            std.mem.sort([]const u8, names.items, {}, less);
            for (names.items) |name| {
                f.add(name);
                try walk(a, f, try std.Io.Dir.path.join(a, &.{ path, name }));
            }
            f.add("end dir");
        },
        else => return diag.fail("cannot fingerprint missing, symlink or special file: {s}", .{path}),
    }
}

pub fn treeDigest(a: Allocator, path: []const u8) ![]const u8 {
    var f: Fingerprint = .{};
    try walk(a, &f, path);
    return f.finish(a);
}

pub fn hit(a: Allocator, stamp: []const u8, key: []const u8, output: []const u8) !bool {
    const text = sys.readFile(a, stamp, 4096) catch return false;
    const expected = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ key, treeDigest(a, output) catch return false });
    return std.mem.eql(u8, text, expected);
}

pub fn record(a: Allocator, stamp: []const u8, key: []const u8, output: []const u8) !void {
    const text = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ key, try treeDigest(a, output) });
    const tmp = try std.fmt.allocPrint(a, "{s}.partial", .{stamp});
    if (std.Io.Dir.path.dirname(stamp)) |d| try sys.makePath(d);
    try sys.cwd().writeFile(sys.io, .{ .sub_path = tmp, .data = text });
    try sys.cwd().rename(tmp, sys.cwd(), stamp, sys.io);
}

pub const Lock = struct {
    file: std.Io.File,

    /// Lock the target directory, not a deletable build subdirectory. This
    /// also serializes xtool's shared .build/xtool outputs across profiles.
    pub fn acquire(a: Allocator, root: []const u8) !Lock {
        try fsutil.rejectSymlinkComponents(a, root, ".idl/build.lock");
        const dir = try std.Io.Dir.path.join(a, &.{ root, ".idl" });
        try sys.makePath(dir);
        const path = try std.Io.Dir.path.join(a, &.{ dir, "build.lock" });
        const file = try sys.cwd().createFile(sys.io, path, .{ .truncate = false, .read = true });
        errdefer file.close(sys.io);
        if (!try file.tryLock(sys.io, .exclusive)) return diag.fail("build directory busy: {s}; another build, generation or clean is running", .{root});
        return .{ .file = file };
    }

    pub fn release(l: *Lock) void {
        l.file.close(sys.io); // OS releases the lock on normal exit or process death.
    }
};
