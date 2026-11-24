//! A tiny read-only XML DOM on top of zig-xml's streaming reader, enough
//! for Interface Builder documents (.xib / .storyboard).
const std = @import("std");
const xml = @import("xml");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;

pub const Attr = struct { name: []const u8, value: []const u8 };

pub const Element = struct {
    tag: []const u8,
    attrs: []const Attr,
    children: []const *Element,
    line: usize = 0,

    pub fn get(e: *const Element, name: []const u8) ?[]const u8 {
        for (e.attrs) |at| if (std.mem.eql(u8, at.name, name)) return at.value;
        return null;
    }

    /// Attribute value, or null when absent or empty.
    pub fn nonEmpty(e: *const Element, name: []const u8) ?[]const u8 {
        const v = e.get(name) orelse return null;
        return if (v.len == 0) null else v;
    }

    pub fn is(e: *const Element, name: []const u8, value: []const u8) bool {
        return std.mem.eql(u8, e.get(name) orelse return false, value);
    }

    /// First descendant (depth-first, document order) with `tag`, including `e` itself.
    pub fn find(e: *const Element, tag: []const u8) ?*const Element {
        if (std.mem.eql(u8, e.tag, tag)) return e;
        for (e.children) |c| if (c.find(tag)) |hit| return hit;
        return null;
    }

    /// First direct child with `tag`.
    pub fn child(e: *const Element, tag: []const u8) ?*const Element {
        for (e.children) |c| if (std.mem.eql(u8, c.tag, tag)) return c;
        return null;
    }
};

/// Parse a whole document; everything is allocated in `a` (use an arena).
/// Text content is ignored: IB documents keep everything in attributes.
pub fn parse(a: Allocator, data: []const u8, name: []const u8) !*Element {
    var static_reader: xml.Reader.Static = .init(a, data, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    const Frame = struct { el: *Element, kids: std.ArrayList(*Element) };
    var stack: std.ArrayList(Frame) = .empty;
    var root: ?*Element = null;
    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => {
                const loc = reader.errorLocation();
                return diag.fail("{s}:{d}:{d}: malformed XML ({s})", .{ name, loc.line, loc.column, @tagName(reader.errorCode()) });
            },
            else => |e| return e,
        };
        switch (node) {
            .eof => break,
            .element_start => {
                const attrs = try a.alloc(Attr, reader.attributeCount());
                for (attrs, 0..) |*at, i| at.* = .{
                    .name = try a.dupe(u8, reader.attributeName(i)),
                    .value = try a.dupe(u8, try reader.attributeValue(i)),
                };
                const el = try a.create(Element);
                el.* = .{ .tag = try a.dupe(u8, reader.elementName()), .attrs = attrs, .children = &.{}, .line = reader.location().line };
                if (stack.items.len > 0) try stack.items[stack.items.len - 1].kids.append(a, el) else root = el;
                try stack.append(a, .{ .el = el, .kids = .empty });
            },
            .element_end => {
                var f = stack.pop().?;
                f.el.children = try f.kids.toOwnedSlice(a);
            },
            else => {},
        }
    }
    return root orelse diag.fail("{s}: empty XML document", .{name});
}

test "parse a small document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<document type="x"><objects><view id="a&amp;b"><subviews/></view></objects><!-- c --></document>
    , "t.xib");
    try std.testing.expectEqualStrings("document", root.tag);
    const view = root.find("view").?;
    try std.testing.expectEqualStrings("a&b", view.get("id").?);
    try std.testing.expect(view.child("subviews") != null);
    try std.testing.expect(root.find("missing") == null);
    try std.testing.expectError(error.Invalid, parse(arena.allocator(), "<a><b></a>", "bad.xib"));
}
