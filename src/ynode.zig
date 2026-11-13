//! Loss-free view of a YAML document built on zig-yaml's parse tree.
//!
//! zig-yaml's `Value` eagerly coerces scalars (so `16.10` would become the
//! float 16.1 and quoted strings lose their quoting). Configuration values such
//! as versions must be preserved verbatim, so this walks `yaml.Tree` directly
//! and keeps every scalar as text plus a flag saying whether it was quoted.
const std = @import("std");
const yaml = @import("yaml");
const diag = @import("diag.zig");

const Tree = yaml.Tree;
const Allocator = std.mem.Allocator;

pub const Scalar = struct {
    text: []const u8,
    quoted: bool,
};

pub const Map = struct {
    keys: []const []const u8,
    values: []const Node,

    pub fn get(m: Map, key: []const u8) ?Node {
        for (m.keys, m.values) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }
};

pub const Node = union(enum) {
    null,
    scalar: Scalar,
    list: []const Node,
    map: Map,
};

/// Remove `# comments` (outside quotes, preceded by whitespace or at line
/// start) and trailing whitespace. zig-yaml 0.1.x mis-parses a plain scalar
/// followed by spaces/comments, so this runs first; line numbers are preserved.
pub fn stripComments(arena: Allocator, source: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(arena, source.len);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        var quote: u8 = 0;
        var end: usize = line.len;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (quote != 0) {
                if (c == '\\' and quote == '"') {
                    i += 1;
                } else if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                // Quotes only open a quoted scalar at the start of a value/item.
                const prev = if (i == 0) ' ' else line[i - 1];
                if (std.mem.indexOfScalar(u8, " \t[{,:-", prev) != null) quote = c;
                continue;
            }
            if (c == '#' and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
                end = i;
                break;
            }
        }
        try out.appendSlice(std.mem.trimRight(u8, line[0..end], " \t\r"));
    }
    return out.items;
}

pub fn parse(arena: Allocator, raw_source: []const u8, file_name: []const u8) !Node {
    const source = try stripComments(arena, raw_source);
    var doc: yaml.Yaml = .{ .source = source };
    doc.load(arena) catch |err| switch (err) {
        error.ParseFailure => {
            const stderr = std.io.getStdErr();
            stderr.writer().print("{s}: YAML parse error\n", .{file_name}) catch {};
            doc.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(stderr) });
            return diag.fail("could not parse {s}", .{file_name});
        },
        error.DuplicateMapKey => return diag.fail("{s}: duplicate mapping key", .{file_name}),
        else => return err,
    };
    const tree = doc.tree orelse return .null;
    return switch (tree.docs.len) {
        0 => .null,
        1 => convert(arena, tree, tree.docs[0]),
        else => diag.fail("{s}: expected a single YAML document", .{file_name}),
    };
}

fn unquoteKey(raw: []const u8) []const u8 {
    if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\'') and raw[raw.len - 1] == raw[0]) return raw[1 .. raw.len - 1];
    return raw;
}

fn isNull(raw: []const u8) bool {
    for ([_][]const u8{ "~", "null", "Null", "NULL" }) |n| if (std.mem.eql(u8, raw, n)) return true;
    return false;
}

fn convert(arena: Allocator, tree: Tree, index: Tree.Node.Index) !Node {
    switch (tree.nodeTag(index)) {
        .doc => {
            const inner = tree.nodeData(index).maybe_node.unwrap() orelse return .null;
            return convert(arena, tree, inner);
        },
        .doc_with_directive => {
            const inner = tree.nodeData(index).doc_with_directive.maybe_node.unwrap() orelse return .null;
            return convert(arena, tree, inner);
        },
        .map_single => {
            const entry = tree.nodeData(index).map;
            const keys = try arena.alloc([]const u8, 1);
            const values = try arena.alloc(Node, 1);
            keys[0] = try arena.dupe(u8, unquoteKey(tree.rawString(entry.key, entry.key)));
            values[0] = if (entry.maybe_node.unwrap()) |v| try convert(arena, tree, v) else .null;
            return .{ .map = .{ .keys = keys, .values = values } };
        },
        .map_many => {
            const map = tree.extraData(Tree.Map, tree.nodeData(index).extra);
            const keys = try arena.alloc([]const u8, map.data.map_len);
            const values = try arena.alloc(Node, map.data.map_len);
            var end = map.end;
            for (keys, values, 0..) |*k, *v, i| {
                const entry = tree.extraData(Tree.Map.Entry, end);
                end = entry.end;
                k.* = try arena.dupe(u8, unquoteKey(tree.rawString(entry.data.key, entry.data.key)));
                for (keys[0..i]) |prev| if (std.mem.eql(u8, prev, k.*)) return diag.fail("duplicate mapping key: {s}", .{k.*});
                v.* = if (entry.data.maybe_node.unwrap()) |n| try convert(arena, tree, n) else .null;
            }
            return .{ .map = .{ .keys = keys, .values = values } };
        },
        .list_empty => return .{ .list = &.{} },
        .list_one => {
            const items = try arena.alloc(Node, 1);
            items[0] = try convert(arena, tree, tree.nodeData(index).node);
            return .{ .list = items };
        },
        .list_two => {
            const pair = tree.nodeData(index).list;
            const items = try arena.alloc(Node, 2);
            items[0] = try convert(arena, tree, pair.el1);
            items[1] = try convert(arena, tree, pair.el2);
            return .{ .list = items };
        },
        .list_many => {
            const list = tree.extraData(Tree.List, tree.nodeData(index).extra);
            const items = try arena.alloc(Node, list.data.list_len);
            var end = list.end;
            for (items) |*item| {
                const entry = tree.extraData(Tree.List.Entry, end);
                end = entry.end;
                item.* = try convert(arena, tree, entry.data.node);
            }
            return .{ .list = items };
        },
        .value => {
            const raw = tree.nodeScope(index).rawString(tree);
            if (isNull(raw)) return .null;
            return .{ .scalar = .{ .text = try arena.dupe(u8, raw), .quoted = false } };
        },
        .string_value => {
            const raw = tree.nodeData(index).string.slice(tree);
            return .{ .scalar = .{ .text = try arena.dupe(u8, raw), .quoted = true } };
        },
    }
}

test "scalars keep their source text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const node = try parse(arena,
        \\# leading comment
        \\min_ios: 16.10   # trailing comment
        \\quoted: "1.0 # not a comment"  # comment
        \\url: http://x/#frag
        \\flags: [-Os, -g0]
        \\empty: ~
        \\nested:
        \\  key: value
        \\
    , "test.yml");
    const map = node.map;
    try std.testing.expectEqualStrings("16.10", map.get("min_ios").?.scalar.text);
    try std.testing.expect(map.get("quoted").?.scalar.quoted);
    try std.testing.expectEqualStrings("1.0 # not a comment", map.get("quoted").?.scalar.text);
    try std.testing.expectEqualStrings("http://x/#frag", map.get("url").?.scalar.text);
    try std.testing.expectEqualStrings("-g0", map.get("flags").?.list[1].scalar.text);
    try std.testing.expect(map.get("empty").? == .null);
    try std.testing.expectEqualStrings("value", map.get("nested").?.map.get("key").?.scalar.text);
}
