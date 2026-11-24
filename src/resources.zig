//! Resource planning, collision detection and content-addressed compiler cache.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const state = @import("buildstate.zig");
const plist = @import("plist.zig");
const metadata = @import("metadata.zig");
const ibtool = @import("ibtool.zig");
const xcstrings = @import("xcstrings.zig");
const Target = @import("config.zig").Target;
const Toolchain = @import("toolchain.zig").Toolchain;
const Allocator = std.mem.Allocator;

pub const Output = struct { source: []const u8, dest: []const u8, owner: []const u8 };
pub const Prepared = struct {
    outputs: []const Output,
    info: ?plist.Plist,
    digest: []const u8,
};

test "generated string output cannot overwrite a raw localized resource" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", a);
    try tmp.dir.createDirPath(sys.io, "R/en.lproj");
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "R/en.lproj/Localizable.strings", .data = "raw" });
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "R/Localizable.xcstrings", .data = "{\"strings\":{\"Hello\":{}}}" });
    var tc = try Toolchain.init(a, .{}, root);
    const t: Target = .{ .name = "App", .bundle_id = "com.example.app", .dir = root, .resources = &.{"R"} };
    try std.testing.expectError(error.Invalid, prepare(a, &tc, t, true, false));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "Localizable.strings") != null);
}

test "missing configured storyboard is rejected before compilation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", a);
    const cfg = try @import("config.zig").parse(a, "targets:\n  - name: App\n    bundle_id: com.example.app\n    info:\n      UIMainStoryboardFile: Missing\n", try std.Io.Dir.path.join(a, &.{ root, "idlproj.yml" }));
    var tc = try Toolchain.init(a, .{}, root);
    try std.testing.expectError(error.Invalid, prepare(a, &tc, cfg.targets[0], true, false));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "Missing") != null);
}

test "resource cache survives unchanged build and invalidates same-length edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(sys.io, ".", a);
    try tmp.dir.createDirPath(sys.io, "R");
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "R/Text.xcstrings", .data = "{\"strings\":{\"Hello\":{}}}" });
    var tc = try Toolchain.init(a, .{}, root);
    const t: Target = .{ .name = "App", .bundle_id = "com.example.app", .dir = root, .resources = &.{"R"} };
    const first = try prepare(a, &tc, t, true, false);
    const file = first.outputs[0].source;
    const before = (try sys.cwd().statFile(sys.io, file, .{})).mtime;
    const second = try prepare(a, &tc, t, true, false);
    try std.testing.expectEqualStrings(first.digest, second.digest);
    try std.testing.expectEqual(before, (try sys.cwd().statFile(sys.io, file, .{})).mtime);
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "R/Text.xcstrings", .data = "{\"strings\":{\"World\":{}}}" });
    const third = try prepare(a, &tc, t, true, false);
    try std.testing.expect(!std.mem.eql(u8, second.digest, third.digest));
}

fn log(comptime fmt: []const u8, args: anytype) void {
    if (!@import("builtin").is_test) diag.info(fmt, args);
}

fn run(a: Allocator, tc: *Toolchain, argv: []const []const u8, cwd: []const u8, verbose: bool) !void {
    if (verbose) log("  {s}", .{try std.mem.join(a, " ", argv)});
    var child = sys.spawn(argv, .{ .cwd = cwd, .env = &tc.env }) catch |err| return diag.fail("cannot execute {s}: {s}", .{ argv[0], @errorName(err) });
    const term = try sys.wait(&child);
    if (!sys.succeeded(term)) return diag.fail("resource compiler failed: {s}", .{argv[0]});
}

fn destName(a: Allocator, rel: []const u8) ![]const u8 {
    const name = std.Io.Dir.path.basename(rel);
    if (std.mem.eql(u8, fsutil.suffix(rel), ".framework")) return std.fmt.allocPrint(a, "Frameworks/{s}", .{name});
    if (std.Io.Dir.path.dirname(rel)) |parent| if (std.mem.eql(u8, fsutil.suffix(parent), ".lproj"))
        return std.fmt.allocPrint(a, "{s}/{s}", .{ std.Io.Dir.path.basename(parent), name });
    return name;
}

fn appendTree(a: Allocator, outputs: *std.ArrayList(Output), source: []const u8, dest: []const u8, owner: []const u8) anyerror!void {
    switch (fsutil.kind(source)) {
        .file => try outputs.append(a, .{ .source = source, .dest = dest, .owner = owner }),
        .dir => {
            var dir = try sys.cwd().openDir(sys.io, source, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(sys.io);
            var it = dir.iterate();
            var empty = true;
            while (try it.next(sys.io)) |entry| {
                empty = false;
                try appendTree(a, outputs, try std.Io.Dir.path.join(a, &.{ source, entry.name }), if (dest.len == 0) try a.dupe(u8, entry.name) else try std.Io.Dir.path.join(a, &.{ dest, entry.name }), owner);
            }
            if (empty and dest.len > 0) try outputs.append(a, .{ .source = source, .dest = dest, .owner = owner });
        },
        else => return diag.fail("unsupported resource file: {s}", .{source}),
    }
}

fn collision(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or (std.mem.startsWith(u8, b, a) and b.len > a.len and b[a.len] == '/') or
        (std.mem.startsWith(u8, a, b) and a.len > b.len and a[b.len] == '/');
}

fn validateOutputs(t: Target, outputs: []Output, info: plist.Plist, a: Allocator) !void {
    std.mem.sort(Output, outputs, {}, struct {
        fn less(_: void, l: Output, rr: Output) bool {
            return std.mem.lessThan(u8, l.dest, rr.dest);
        }
    }.less);
    var seen = std.StringHashMap([]const u8).init(a);
    for (outputs) |o| {
        try fsutil.validateRelativePath(o.dest, "resource output");
        for ([_][]const u8{ "Info.plist", "PkgInfo", t.name }) |reserved| if (collision(o.dest, reserved))
            return diag.fail("resource {s} would overwrite reserved bundle output {s}", .{ o.owner, reserved });
        if (seen.get(o.dest)) |owner| return diag.fail("resources {s} and {s} both produce {s}", .{ owner, o.owner, o.dest });
        var parent = std.Io.Dir.path.dirnamePosix(o.dest);
        while (parent) |p| {
            if (seen.get(p)) |owner| return diag.fail("resource output {s} from {s} conflicts with {s}", .{ o.dest, o.owner, owner });
            parent = std.Io.Dir.path.dirnamePosix(p);
        }
        try seen.put(o.dest, o.owner);
    }
    try validateReferences(a, info.node, outputs);
}

fn validateReferences(a: Allocator, node: plist.c.plist_t, outputs: []const Output) anyerror!void {
    switch (plist.c.plist_get_node_type(node)) {
        plist.c.PLIST_ARRAY => {
            for (0..plist.c.plist_array_get_size(node)) |i| try validateReferences(a, plist.c.plist_array_get_item(node, @intCast(i)), outputs);
        },
        plist.c.PLIST_DICT => {
            var it: plist.c.plist_dict_iter = null;
            plist.c.plist_dict_new_iter(node, &it);
            defer plist.c.plist_dict_free_iter(it);
            while (true) {
                var raw_key: [*c]u8 = null;
                var value: plist.c.plist_t = null;
                plist.c.plist_dict_next_item(node, it, &raw_key, &value);
                if (value == null) break;
                defer plist.c.plist_mem_free(raw_key);
                const key = std.mem.span(raw_key);
                const is_storyboard = fsutil.oneOf(key, &.{ "UIMainStoryboardFile", "UIMainStoryboardFile~ipad", "UILaunchStoryboardName", "UILaunchStoryboardName~ipad", "UISceneStoryboardFile" });
                const is_nib = std.mem.eql(u8, key, "NSMainNibFile");
                if (is_storyboard or is_nib) {
                    const name = plist.stringOf(value) orelse return diag.fail("{s} must be a storyboard/nib name string", .{key});
                    if (name.len == 0) continue;
                    const expected = try std.fmt.allocPrint(a, "{s}{s}", .{ name, if (is_nib) ".nib" else ".storyboardc/Info.plist" });
                    const localized = try std.fmt.allocPrint(a, ".lproj/{s}", .{expected});
                    var found = false;
                    for (outputs) |o| if (std.mem.eql(u8, o.dest, expected) or std.mem.endsWith(u8, o.dest, localized)) {
                        found = true;
                        break;
                    };
                    if (!found) return diag.fail("{s} specifies '{s}', but no resource produces {s}", .{ key, name, expected });
                } else try validateReferences(a, value, outputs);
            }
        },
        else => {},
    }
}

/// Tool checks for every selected target run before this function. Compiled
/// resources are prepared/validated before any application object compilation.
pub fn prepare(a: Allocator, tc: *Toolchain, t: Target, strict: bool, verbose: bool) !Prepared {
    if (!t.type.bundled()) return .{ .outputs = &.{}, .info = null, .digest = "" };
    const xml = try metadata.processInfoPlist(a, t, &tc.env, null);
    const info = try plist.parse(xml);
    defer info.deinit();
    if (try metadata.entitlements(a, t, &tc.env)) |_| {}
    var outputs: std.ArrayList(Output) = .empty;
    var additions: ?plist.Plist = null;
    errdefer if (additions) |p| p.deinit();
    var catalog: ?[]const u8 = null;
    const resources = try fsutil.discover(a, t.dir, t.resources, "resource");
    for (resources) |rel| {
        const src = try t.path(a, rel);
        const sfx = fsutil.suffix(rel);
        if (fsutil.oneOf(sfx, &.{ ".xcdatamodeld", ".xcdatamodel", ".xcmappingmodel", ".metal", ".mlmodel", ".mlpackage" })) {
            if (strict) return diag.fail("{s}: unsupported resource compiler for {s}", .{ t.name, rel });
            diag.warn("{s}: skipped unsupported resource {s}", .{ t.name, rel });
            continue;
        }
        const compiled = fsutil.oneOf(sfx, &.{ ".xcassets", ".storyboard", ".xib", ".xcstrings" });
        if (!compiled) {
            try appendTree(a, &outputs, src, try destName(a, rel), rel);
            continue;
        }
        if (std.mem.eql(u8, sfx, ".xcassets")) {
            if (catalog) |other| return diag.fail("only one asset catalog per target is supported: {s}, {s}", .{ other, rel });
            catalog = rel;
            try validateCatalog(a, src, t.app_icon, strict);
        }
        if (fsutil.oneOf(sfx, &.{ ".xib", ".storyboard" })) try ibtool.validate(a, src, strict);
        var f: state.Fingerprint = .{};
        f.add("resource-cache-v1");
        f.add(try tc.selfIdentity());
        f.add(rel);
        f.add(t.min_ios);
        f.add(if (strict) "strict" else "permissive");
        const input_digest = try state.treeDigest(a, src);
        f.add(input_digest);
        if (std.mem.eql(u8, sfx, ".xcassets")) {
            f.add(try tc.identity(try tc.actool(), true));
            // A different SVG rasterizer must invalidate the catalog too.
            if (try fsutil.which(a, "rsvg-convert", tc.pathEnv())) |tool| f.add(try tc.identity(tool, true));
        }
        const key = try f.finish(a);
        var slot_hash: state.Fingerprint = .{};
        slot_hash.add(rel);
        const slot = try std.Io.Dir.path.join(a, &.{ try t.buildPath(a), "resources", try slot_hash.finish(a), key });
        const out = try std.Io.Dir.path.join(a, &.{ slot, "output" });
        const stamp = try std.Io.Dir.path.join(a, &.{ slot, "state" });
        const dest = try destName(a, rel);
        const produced = if (std.mem.eql(u8, sfx, ".storyboard")) try std.fmt.allocPrint(a, "{s}c", .{dest}) else if (std.mem.eql(u8, sfx, ".xib")) try std.fmt.allocPrint(a, "{s}.nib", .{dest[0 .. dest.len - 4]}) else "";
        if (!try state.hit(a, stamp, key, out)) {
            const pending = try std.Io.Dir.path.join(a, &.{ slot, "partial" });
            try sys.deleteTree(pending);
            try sys.makePath(pending);
            if (std.mem.eql(u8, sfx, ".xcassets")) {
                log("  ACTOOL {s}", .{rel});
                try run(a, tc, &.{ try tc.actool(), src, pending, t.min_ios }, t.dir, verbose);
            } else if (std.mem.eql(u8, sfx, ".storyboard")) {
                log("  IBTOOL {s}", .{rel});
                const result = try ibtool.compileStoryboard(a, src, try std.Io.Dir.path.join(a, &.{ pending, produced }));
                if (strict and result.warnings > 0) return diag.fail("{s}: storyboard compiler reported {d} warning(s) in strict mode", .{ rel, result.warnings });
            } else if (std.mem.eql(u8, sfx, ".xib")) {
                log("  IBTOOL {s}", .{rel});
                const bytes, const result = try ibtool.compileXib(a, src);
                if (strict and result.warnings > 0) return diag.fail("{s}: XIB compiler reported {d} warning(s) in strict mode", .{ rel, result.warnings });
                const path = try std.Io.Dir.path.join(a, &.{ pending, produced });
                try sys.makePath(std.Io.Dir.path.dirname(path).?);
                try sys.cwd().writeFile(sys.io, .{ .sub_path = path, .data = bytes });
            } else {
                log("  STRINGS {s}", .{rel});
                var dir = try sys.cwd().openDir(sys.io, pending, .{});
                defer dir.close(sys.io);
                try xcstrings.convert(a, try sys.readFile(a, src, 64 << 20), dir);
            }
            if (!std.mem.eql(u8, input_digest, try state.treeDigest(a, src)))
                return diag.fail("resource changed while compiling: {s}; retry the build", .{rel});
            try sys.deleteTree(out);
            try sys.cwd().rename(pending, sys.cwd(), out, sys.io);
            try state.record(a, stamp, key, out);
        } else if (verbose) log("  CACHED {s}", .{rel});
        const start = outputs.items.len;
        try appendTree(a, &outputs, out, "", rel);
        if (std.mem.eql(u8, sfx, ".xcassets")) {
            const json_path = try std.Io.Dir.path.join(a, &.{ out, "assetcatalog_generated_info.json" });
            const json = try sys.readFile(a, json_path, 1 << 20);
            var node: plist.c.plist_t = null;
            if (plist.c.plist_from_json(json.ptr, @intCast(json.len), &node) != plist.c.PLIST_ERR_SUCCESS or node == null)
                return diag.fail("invalid asset compiler metadata: {s}", .{rel});
            additions = .{ .node = node };
            if (!additions.?.isDict()) return diag.fail("asset compiler metadata must be a dictionary", .{});
            var i = start;
            while (i < outputs.items.len) {
                if (std.mem.eql(u8, outputs.items[i].dest, "assetcatalog_generated_info.json")) _ = outputs.orderedRemove(i) else i += 1;
            }
        }
    }
    try validateOutputs(t, outputs.items, info, a);
    var digest: state.Fingerprint = .{};
    for (outputs.items) |o| {
        digest.add(o.dest);
        digest.add(try state.treeDigest(a, o.source));
    }
    if (additions) |p| digest.add(try p.toXml(a));
    return .{ .outputs = outputs.items, .info = additions, .digest = try digest.finish(a) };
}

test "ancestor collisions are detected even with intervening sorted names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .name = "App", .bundle_id = "com.example.app", .dir = "/" };
    const info = plist.Plist.newDict();
    defer info.deinit();
    var outputs = [_]Output{
        .{ .source = "unused", .dest = "a", .owner = "one" },
        .{ .source = "unused", .dest = "a-", .owner = "two" },
        .{ .source = "unused", .dest = "a/b", .owner = "three" },
    };
    try std.testing.expectError(error.Invalid, validateOutputs(t, &outputs, info, a));
}

test "strict asset validation rejects unsupported dataset packages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(sys.io, "Assets.xcassets/Data.dataset");
    const path = try tmp.dir.realPathFileAlloc(sys.io, "Assets.xcassets", a);
    try std.testing.expectError(error.Invalid, validateCatalog(a, path, "AppIcon", true));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "dataset") != null);
}

pub fn validateCatalog(a: Allocator, path: []const u8, app_icon: []const u8, strict: bool) !void {
    var dir = try sys.cwd().openDir(sys.io, path, .{ .iterate = true });
    defer dir.close(sys.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var icons: usize = 0;
    while (try walker.next(sys.io)) |entry| {
        if (entry.kind != .directory) continue;
        const suffix = fsutil.suffix(entry.basename);
        if (std.mem.eql(u8, suffix, ".appiconset")) {
            icons += 1;
            const icon_name = entry.basename[0 .. entry.basename.len - suffix.len];
            if (strict and !std.mem.eql(u8, icon_name, app_icon))
                return diag.fail("{s}: app_icon is '{s}' but catalog icon is '{s}'; AssetKit cannot select alternate icons", .{ path, app_icon, icon_name });
        } else if (suffix.len > 0 and !fsutil.oneOf(suffix, &.{ ".imageset", ".colorset" })) {
            if (strict) return diag.fail("{s}: unsupported asset package {s}", .{ path, entry.path });
            diag.warn("{s}: unsupported asset package {s} may be omitted by AssetKit", .{ path, entry.path });
        }
    }
    if (icons > 1) return diag.fail("{s}: AssetKit supports only one appiconset, found {d}", .{ path, icons });
}

test "scene manifest storyboard references are validated recursively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: Target = .{ .name = "App", .bundle_id = "com.example.app", .dir = "/" };
    const info = try plist.parse("{\"UIApplicationSceneManifest\":{\"UISceneConfigurations\":{\"UIWindowSceneSessionRoleApplication\":[{\"UISceneStoryboardFile\":\"MissingScene\"}]}}}");
    defer info.deinit();
    var outputs: [0]Output = .{};
    try std.testing.expectError(error.Invalid, validateOutputs(t, &outputs, info, a));
}
