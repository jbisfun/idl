//! Filesystem helpers shared by codegen and builds: source discovery with the
//! same rules Xcode uses, symlink rejection, and lexical path utilities.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;

pub const source_extensions = [_][]const u8{ ".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".swift", ".s", ".S", ".metal" };
/// Directories that Xcode treats as a single opaque file.
pub const package_extensions = [_][]const u8{ ".xcassets", ".bundle", ".framework", ".storyboardc", ".nib", ".xcdatamodeld", ".xcdatamodel", ".xcmappingmodel", ".mlmodelc", ".mlpackage" };

pub fn oneOf(value: []const u8, comptime set: []const []const u8) bool {
    inline for (set) |s| if (std.mem.eql(u8, value, s)) return true;
    return false;
}

/// Python-`pathlib`-compatible suffix: "" for ".hidden" or "name.".
pub fn suffix(path: []const u8) []const u8 {
    const name = std.Io.Dir.path.basenamePosix(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot == name.len - 1) return "";
    return name[dot..];
}

/// Collapse "", "." segments; leave ".." to validation. Returns "" for the root.
pub fn normalizeRelative(a: Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        try parts.append(a, part);
    }
    return std.mem.join(a, "/", parts.items);
}

pub fn join(a: Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return base;
    return std.Io.Dir.path.join(a, &.{ base, rel });
}

pub fn hasControlCharacters(s: []const u8) bool {
    for (s) |c| if (c < 32) return true;
    return false;
}

pub fn validateRelativePath(value: []const u8, label: []const u8) !void {
    if (value.len == 0) return diag.fail("{s} must be a non-empty relative path", .{label});
    if (hasControlCharacters(value)) return diag.fail("{s} contains control characters", .{label});
    if (std.Io.Dir.path.isAbsolute(value)) return diag.fail("{s} must stay within the target directory: {s}", .{ label, value });
    var it = std.mem.tokenizeScalar(u8, value, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, ".."))
        return diag.fail("{s} must stay within the target directory: {s}", .{ label, value });
}

pub const Kind = enum { missing, file, dir, symlink, other };

/// lstat-style classification (never follows the final symlink).
pub fn kindAt(dir: std.Io.Dir, path: []const u8) Kind {
    const st = dir.statFile(sys.io, path, .{ .follow_symlinks = false }) catch return .missing;
    return switch (st.kind) {
        .file => .file,
        .directory => .dir,
        .sym_link => .symlink,
        else => .other,
    };
}

pub fn kind(path: []const u8) Kind {
    return kindAt(sys.cwd(), path);
}

/// Like `kind`, but follows symlinks (for toolchain paths, which may be links).
pub fn kindFollow(path: []const u8) Kind {
    const st = sys.cwd().statFile(sys.io, path, .{}) catch return .missing;
    return switch (st.kind) {
        .file => .file,
        .directory => .dir,
        else => .other,
    };
}

/// Fail if any component of `rel` below `root` is a symlink.
pub fn rejectSymlinkComponents(a: Allocator, root: []const u8, rel: []const u8) !void {
    var prefix: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (prefix.items.len > 0) try prefix.append(a, '/');
        try prefix.appendSlice(a, part);
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
    var dir = try sys.cwd().openDir(sys.io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(sys.io);
    var it = dir.iterate();
    while (try it.next(sys.io)) |entry| {
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
        return out.append(a, rel);
    }
    if (k == .file) return out.append(a, rel);
    if (k != .dir) return;
    var dir = try sys.cwd().openDir(sys.io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(sys.io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(sys.io)) |entry| {
        if (entry.name[0] == '.') continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |name| {
        try walk(a, root, if (rel.len == 0) name else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name }), out);
    }
}

/// Recursively expand `entries` (relative to `root`) into a sorted, de-duplicated
/// list of relative file paths. Package directories are returned whole.
/// `*` matches any run of characters within one path component.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
    const head = pattern[0..star];
    if (!std.mem.startsWith(u8, name, head)) return false;
    const rest = pattern[star + 1 ..];
    var i: usize = head.len;
    while (i <= name.len) : (i += 1) if (globMatch(rest, name[i..])) return true;
    return false;
}

/// Expand a pattern whose last component contains `*` (e.g. `Resources/*.lproj`).
fn expandGlob(a: Allocator, root: []const u8, entry: []const u8, comptime label: []const u8) ![]const []const u8 {
    const parent = std.Io.Dir.path.dirnamePosix(entry) orelse "";
    const pattern = std.Io.Dir.path.basenamePosix(entry);
    if (std.mem.indexOfScalar(u8, parent, '*') != null) return diag.fail(label ++ " pattern {s}: only the last path component may contain '*'", .{entry});
    if (parent.len > 0) try rejectSymlinkComponents(a, root, parent);
    var dir = sys.cwd().openDir(sys.io, try join(a, root, parent), .{ .iterate = true, .follow_symlinks = false }) catch
        return diag.fail(label ++ " path does not exist: {s}", .{parent});
    defer dir.close(sys.io);
    var out: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(sys.io)) |e| {
        if (e.name[0] == '.' or !globMatch(pattern, e.name)) continue;
        try out.append(a, if (parent.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, e.name }));
    }
    if (out.items.len == 0) return diag.fail(label ++ " pattern matched nothing: {s}", .{entry});
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

/// True if `rel` is `pattern` or lies below it, matching `*` per path component.
pub fn pathMatches(pattern: []const u8, rel: []const u8) bool {
    var pi = std.mem.tokenizeScalar(u8, pattern, '/');
    var ri = std.mem.tokenizeScalar(u8, rel, '/');
    while (pi.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        const r = ri.next() orelse return false;
        if (!globMatch(p, r)) return false;
    }
    return true;
}

test "path pattern matching" {
    try std.testing.expect(pathMatches("ZSign", "ZSign/common/util.h"));
    try std.testing.expect(pathMatches("Vendor/*/src", "Vendor/a/src/x.c"));
    try std.testing.expect(!pathMatches("ZSign", "ZSignX/a.c"));
    try std.testing.expect(!pathMatches("a/b", "a"));
}

test "glob matching" {
    try std.testing.expect(globMatch("*.lproj", "en.lproj"));
    try std.testing.expect(globMatch("a*b*c", "aXbYc"));
    try std.testing.expect(!globMatch("*.lproj", "en.lprojx"));
}

pub fn discover(a: Allocator, root: []const u8, entries: []const []const u8, comptime label: []const u8) ![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        try validateRelativePath(entry, label ++ " path");
        if (std.mem.indexOfScalar(u8, entry, '*') != null) {
            for (try expandGlob(a, root, entry, label)) |rel| try walk(a, root, rel, &found);
            continue;
        }
        try rejectSymlinkComponents(a, root, entry);
        const rel = try normalizeRelative(a, entry);
        if (kind(try join(a, root, rel)) == .missing)
            return diag.fail(label ++ " path does not exist: {s}", .{entry});
        try walk(a, root, rel, &found);
    }
    std.mem.sort([]const u8, found.items, {}, lessThan);
    var unique: std.ArrayList([]const u8) = .empty;
    for (found.items) |item| {
        if (unique.items.len > 0 and std.mem.eql(u8, unique.items[unique.items.len - 1], item)) continue;
        try unique.append(a, item);
    }
    return unique.items;
}

/// Like Python's `Path.resolve(strict=False)`: realpath the longest existing
/// prefix, then append the remaining components lexically.
pub fn resolveLenient(a: Allocator, path: []const u8) ![]const u8 {
    const abs = try sys.resolve(a, &.{path});
    var existing: []const u8 = abs;
    var rest: []const u8 = "";
    while (true) {
        if (sys.realpath(a, existing)) |real| {
            return if (rest.len == 0) real else std.Io.Dir.path.join(a, &.{ real, rest });
        } else |_| {}
        const parent = std.Io.Dir.path.dirname(existing) orelse return abs;
        const base = std.Io.Dir.path.basename(existing);
        rest = if (rest.len == 0) base else try std.Io.Dir.path.join(a, &.{ base, rest });
        existing = parent;
    }
}

pub fn expandHome(a: Allocator, path: []const u8, env: *const std.process.Environ.Map) ![]const u8 {
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home = env.get("HOME") orelse return diag.fail("HOME is not set; cannot expand {s}", .{path});
        return std.fmt.allocPrint(a, "{s}{s}", .{ home, path[1..] });
    }
    return path;
}

/// Look up an executable by name on `path_env` (names containing '/' are checked directly).
pub fn which(a: Allocator, name: []const u8, path_env: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        sys.cwd().access(sys.io, name, .{ .execute = true }) catch return null;
        return name;
    }
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try std.Io.Dir.path.join(a, &.{ dir, name });
        sys.cwd().access(sys.io, candidate, .{ .execute = true }) catch continue;
        if (kind(candidate) == .dir) continue;
        return candidate;
    }
    return null;
}

/// Write `data` to `path` only when it differs; returns true if written.
pub fn writeIfChanged(a: Allocator, path: []const u8, data: []const u8) !bool {
    if (sys.readFile(a, path, 64 << 20)) |old| {
        if (std.mem.eql(u8, old, data)) return false;
    } else |_| {}
    if (std.Io.Dir.path.dirname(path)) |parent| try sys.makePath(parent);
    try sys.cwd().writeFile(sys.io, .{ .sub_path = path, .data = data });
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
