//! Filesystem helpers shared by codegen and builds: source discovery with the
//! same rules Xcode uses, symlink rejection, and lexical path utilities.
const std = @import("std");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const source_extensions = [_][]const u8{ ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".swift", ".s", ".S", ".metal" };
/// Directories that Xcode treats as a single opaque file.
pub const package_extensions = [_][]const u8{ ".xcassets", ".bundle", ".framework", ".xcdatamodeld", ".mlmodelc" };

pub fn oneOf(value: []const u8, comptime set: []const []const u8) bool {
    inline for (set) |s| if (std.mem.eql(u8, value, s)) return true;
    return false;
}

/// Python-`pathlib`-compatible suffix: "" for ".hidden" or "name.".
pub fn suffix(path: []const u8) []const u8 {
    const name = std.fs.path.basenamePosix(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot == name.len - 1) return "";
    return name[dot..];
}

/// Collapse "", "." segments; leave ".." to validation. Returns "" for the root.
pub fn normalizeRelative(a: Allocator, path: []const u8) ![]const u8 {
    var parts = std.ArrayList([]const u8).init(a);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        try parts.append(part);
    }
    return std.mem.join(a, "/", parts.items);
}

pub fn join(a: Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return base;
    return std.fs.path.join(a, &.{ base, rel });
}

pub fn hasControlCharacters(s: []const u8) bool {
    for (s) |c| if (c < 32) return true;
    return false;
}

pub fn validateRelativePath(value: []const u8, label: []const u8) !void {
    if (value.len == 0) return diag.fail("{s} must be a non-empty relative path", .{label});
    if (hasControlCharacters(value)) return diag.fail("{s} contains control characters", .{label});
    if (std.fs.path.isAbsolute(value)) return diag.fail("{s} must stay within the target directory: {s}", .{ label, value });
    var it = std.mem.tokenizeScalar(u8, value, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, ".."))
        return diag.fail("{s} must stay within the target directory: {s}", .{ label, value });
}

pub const Kind = enum { missing, file, dir, symlink, other };

/// lstat-style classification (never follows the final symlink).
pub fn kindAt(dir: std.fs.Dir, path: []const u8) Kind {
    const st = posix.fstatat(dir.fd, path, posix.AT.SYMLINK_NOFOLLOW) catch return .missing;
    const fmt = st.mode & posix.S.IFMT;
    return switch (fmt) {
        posix.S.IFREG => .file,
        posix.S.IFDIR => .dir,
        posix.S.IFLNK => .symlink,
        else => .other,
    };
}

pub fn kind(path: []const u8) Kind {
    return kindAt(std.fs.cwd(), path);
}

/// Like `kind`, but follows symlinks (for toolchain paths, which may be links).
pub fn kindFollow(path: []const u8) Kind {
    const st = posix.fstatat(std.fs.cwd().fd, path, 0) catch return .missing;
    return switch (st.mode & posix.S.IFMT) {
        posix.S.IFREG => .file,
        posix.S.IFDIR => .dir,
        else => .other,
    };
}

/// Fail if any component of `rel` below `root` is a symlink.
pub fn rejectSymlinkComponents(a: Allocator, root: []const u8, rel: []const u8) !void {
    var prefix = std.ArrayList(u8).init(a);
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (prefix.items.len > 0) try prefix.append('/');
        try prefix.appendSlice(part);
        if (kind(try join(a, root, prefix.items)) == .symlink)
            return diag.fail("symlinks are not allowed: {s}", .{prefix.items});
    }
}

/// Fail if `rel` (relative to `root`) is, or contains, a symlink.
pub fn rejectSymlinksBelow(a: Allocator, root: []const u8, rel: []const u8, comptime label: []const u8) !void {
    const path = try join(a, root, rel);
    switch (kind(path)) {
        .symlink => return diag.fail(label ++ ": {s}", .{rel}),
        .dir => {},
        else => return,
    }
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const child = if (rel.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, entry.name });
        if (entry.kind == .sym_link) return diag.fail(label ++ ": {s}", .{child});
        if (entry.kind == .directory) try rejectSymlinksBelow(a, root, child, label);
    }
}

fn lessThan(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn walk(a: Allocator, root: []const u8, rel: []const u8, out: *std.ArrayList([]const u8)) !void {
    const path = try join(a, root, rel);
    const k = kind(path);
    if (k == .symlink) return diag.fail("symlinks are not allowed: {s}", .{rel});
    const sfx = suffix(rel);
    if (std.mem.eql(u8, sfx, ".xcodeproj")) return;
    if (oneOf(sfx, &package_extensions)) {
        try rejectSymlinksBelow(a, root, rel, "symlinks are not allowed");
        return out.append(rel);
    }
    if (k == .file) return out.append(rel);
    if (k != .dir) return;
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = true });
    defer dir.close();
    var names = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.name[0] == '.') continue;
        try names.append(try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        try walk(a, root, if (rel.len == 0) name else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name }), out);
    }
}

/// Recursively expand `entries` (relative to `root`) into a sorted, de-duplicated
/// list of relative file paths. Package directories are returned whole.
pub fn discover(a: Allocator, root: []const u8, entries: []const []const u8, comptime label: []const u8) ![]const []const u8 {
    var found = std.ArrayList([]const u8).init(a);
    for (entries) |entry| {
        try validateRelativePath(entry, label ++ " path");
        try rejectSymlinkComponents(a, root, entry);
        const rel = try normalizeRelative(a, entry);
        if (kind(try join(a, root, rel)) == .missing)
            return diag.fail(label ++ " path does not exist: {s}", .{entry});
        try walk(a, root, rel, &found);
    }
    std.mem.sort([]const u8, found.items, {}, lessThan);
    var unique = std.ArrayList([]const u8).init(a);
    for (found.items) |item| {
        if (unique.items.len > 0 and std.mem.eql(u8, unique.items[unique.items.len - 1], item)) continue;
        try unique.append(item);
    }
    return unique.items;
}

/// Like Python's `Path.resolve(strict=False)`: realpath the longest existing
/// prefix, then append the remaining components lexically.
pub fn resolveLenient(a: Allocator, path: []const u8) ![]const u8 {
    const abs = try std.fs.path.resolve(a, &.{path});
    var existing: []const u8 = abs;
    var rest: []const u8 = "";
    while (true) {
        if (std.fs.cwd().realpathAlloc(a, existing)) |real| {
            return if (rest.len == 0) real else std.fs.path.join(a, &.{ real, rest });
        } else |_| {}
        const parent = std.fs.path.dirname(existing) orelse return abs;
        const base = std.fs.path.basename(existing);
        rest = if (rest.len == 0) base else try std.fs.path.join(a, &.{ base, rest });
        existing = parent;
    }
}

pub fn expandHome(a: Allocator, path: []const u8, env: *const std.process.EnvMap) ![]const u8 {
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = env.get("HOME") orelse return diag.fail("HOME is not set; cannot expand {s}", .{path});
        return std.fmt.allocPrint(a, "{s}{s}", .{ home, path[1..] });
    }
    return path;
}

/// Look up an executable by name on `path_env` (names containing '/' are checked directly).
pub fn which(a: Allocator, name: []const u8, path_env: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        posix.access(name, posix.X_OK) catch return null;
        return name;
    }
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(a, &.{ dir, name });
        posix.access(candidate, posix.X_OK) catch continue;
        if (kind(candidate) == .dir) continue;
        return candidate;
    }
    return null;
}

/// Write `data` to `path` only when it differs; returns true if written.
pub fn writeIfChanged(a: Allocator, path: []const u8, data: []const u8) !bool {
    if (std.fs.cwd().readFileAlloc(a, path, 64 << 20)) |old| {
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
    return true;
}

test "suffix and normalization" {
    try std.testing.expectEqualStrings(".m", suffix("a/b/main.m"));
    try std.testing.expectEqualStrings("", suffix(".hidden"));
    try std.testing.expectEqualStrings("", suffix("name."));
    try std.testing.expectEqualStrings(".xcassets", suffix("R/Assets.xcassets"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a/b", try normalizeRelative(arena.allocator(), "./a//b/."));
    try std.testing.expectEqualStrings("", try normalizeRelative(arena.allocator(), "."));
    try std.testing.expectError(error.Invalid, validateRelativePath("../x", "p"));
    try std.testing.expectError(error.Invalid, validateRelativePath("/x", "p"));
}
