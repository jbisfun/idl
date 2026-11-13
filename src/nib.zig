//! NIBArchive object graphs: building, encoding and dumping.
//!
//! Ported from davidquesada/ibtool (genlib.py, nibencoding.py, ibdump.py).
//! An archive is four tables (objects, keys, values, classes) behind a
//! 50-byte header; integers in the tables are "flex" varints whose final
//! byte has the high bit set.
const std = @import("std");
const diag = @import("diag.zig");
const xmldom = @import("xmldom.zig");

const Allocator = std.mem.Allocator;

pub const List = struct { items: std.ArrayListUnmanaged(Value) = .empty };
pub const Dict = struct { keys: std.ArrayListUnmanaged(Value) = .empty, values: std.ArrayListUnmanaged(Value) = .empty };

pub const Value = union(enum) {
    obj: *Obj,
    /// Encoded as an NSString object.
    str: []const u8,
    /// Raw bytes stored inline in the value table (NSString/NSData payloads, NSRGB).
    bytes: []const u8,
    int: i64,
    boolean: bool,
    double: f64,
    /// CGPoint/CGSize/CGRect-style tuple, stored inline as 0x07 + little-endian doubles.
    doubles: []const f64,
    list: *List,
    dict: *Dict,
    /// An IB object id that must be resolved to an object before encoding.
    ref: []const u8,
    nil,
};

pub const Prop = struct { key: []const u8, value: Value };

/// Interface Builder bookkeeping carried by parsed objects; never encoded.
pub const IbInfo = struct {
    id: ?[]const u8 = null,
    /// UIKit class before a customClass swap to UIClassSwapper.
    original_class: ?[]const u8 = null,
    elem: ?*const xmldom.Element = null,
    /// View controllers: `relationship` segue (e.g. a navigation controller's root).
    relationship_segue: ?*const xmldom.Element = null,
    /// View controllers: connections to encode in the scene nib.
    scene_connections: []const *Obj = &.{},
    /// Segue templates: destination view controller id.
    segue_destination: ?[]const u8 = null,
    /// Constraints with an unresolved item; dropped from the view.
    dropped: bool = false,
};

pub const Obj = struct {
    class: []const u8,
    props: std.ArrayListUnmanaged(Prop) = .empty,
    ib: IbInfo = .{},

    pub fn originalClass(o: *const Obj) []const u8 {
        return o.ib.original_class orelse o.class;
    }

    pub fn get(o: *const Obj, key: []const u8) ?Value {
        for (o.props.items) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
        return null;
    }

    pub fn has(o: *const Obj, key: []const u8) bool {
        return o.get(key) != null;
    }

    /// Insert or replace `key` (keeps the original position on replace).
    pub fn set(o: *Obj, a: Allocator, key: []const u8, value: Value) !void {
        for (o.props.items) |*p| if (std.mem.eql(u8, p.key, key)) {
            p.value = value;
            return;
        };
        try o.props.append(a, .{ .key = key, .value = value });
    }

    pub fn setIfEmpty(o: *Obj, a: Allocator, key: []const u8, value: Value) !void {
        if (!o.has(key)) try o.set(a, key, value);
    }

    pub fn setStr(o: *Obj, a: Allocator, key: []const u8, value: ?[]const u8) !void {
        if (value) |v| try o.set(a, key, .{ .str = v });
    }

    pub fn setInt(o: *Obj, a: Allocator, key: []const u8, value: ?i64) !void {
        if (value) |v| try o.set(a, key, .{ .int = v });
    }

    pub fn setObj(o: *Obj, a: Allocator, key: []const u8, value: ?*Obj) !void {
        if (value) |v| try o.set(a, key, .{ .obj = v });
    }

    pub fn remove(o: *Obj, key: []const u8) void {
        for (o.props.items, 0..) |p, i| if (std.mem.eql(u8, p.key, key)) {
            _ = o.props.orderedRemove(i);
            return;
        };
    }

    /// The list stored at `key`, created if missing.
    pub fn list(o: *Obj, a: Allocator, key: []const u8) !*List {
        if (o.get(key)) |v| switch (v) {
            .list => |l| return l,
            else => return diag.fail("nib: property {s} of {s} is not a list", .{ key, o.class }),
        };
        const l = try a.create(List);
        l.* = .{};
        try o.set(a, key, .{ .list = l });
        return l;
    }

    pub fn append(o: *Obj, a: Allocator, key: []const u8, item: *Obj) !void {
        try (try o.list(a, key)).items.append(a, .{ .obj = item });
    }

    pub fn extend(o: *Obj, a: Allocator, key: []const u8, items: []const *Obj) !void {
        const l = try o.list(a, key);
        for (items) |item| try l.items.append(a, .{ .obj = item });
    }

    pub fn dict(o: *Obj, a: Allocator, key: []const u8) !*Dict {
        if (o.get(key)) |v| switch (v) {
            .dict => |d| return d,
            else => return diag.fail("nib: property {s} of {s} is not a dictionary", .{ key, o.class }),
        };
        const d = try a.create(Dict);
        d.* = .{};
        try o.set(a, key, .{ .dict = d });
        return d;
    }
};

pub fn new(a: Allocator, class: []const u8) !*Obj {
    const o = try a.create(Obj);
    o.* = .{ .class = class };
    return o;
}

pub fn proxy(a: Allocator, identifier: []const u8) !*Obj {
    const o = try new(a, "UIProxyObject");
    try o.setStr(a, "UIProxiedObjectIdentifier", identifier);
    return o;
}

pub fn listOf(a: Allocator, items: []const *Obj) !*List {
    const l = try a.create(List);
    l.* = .{};
    for (items) |item| try l.items.append(a, .{ .obj = item });
    return l;
}

pub fn dictPut(a: Allocator, d: *Dict, key: Value, value: Value) !void {
    try d.keys.append(a, key);
    try d.values.append(a, value);
}

// ---------------------------------------------------------------- encoding

pub const Type = enum(u8) {
    int8 = 0x00,
    int16 = 0x01,
    int32 = 0x02,
    int64 = 0x03,
    false = 0x04,
    true = 0x05,
    float = 0x06,
    double = 0x07,
    data = 0x08,
    nil = 0x09,
    object = 0x0A,
};

const EncValue = struct {
    key: u32,
    type: Type,
    int: i64 = 0,
    double: f64 = 0,
    data: []const u8 = "",
};

const EncObject = struct { class: u32, values: std.ArrayListUnmanaged(EncValue) = .empty };

const Encoder = struct {
    a: Allocator,
    objects: std.ArrayListUnmanaged(EncObject) = .empty,
    keys: std.StringArrayHashMapUnmanaged(void) = .empty,
    classes: std.StringArrayHashMapUnmanaged(void) = .empty,
    index: std.AutoHashMapUnmanaged(*const Obj, u32) = .empty,

    fn keyIndex(e: *Encoder, key: []const u8) !u32 {
        const r = try e.keys.getOrPut(e.a, key);
        return @intCast(r.index);
    }

    fn newObject(e: *Encoder, class: []const u8) !u32 {
        const r = try e.classes.getOrPut(e.a, class);
        try e.objects.append(e.a, .{ .class = @intCast(r.index) });
        return @intCast(e.objects.items.len - 1);
    }

    fn put(e: *Encoder, obj: u32, v: EncValue) !void {
        try e.objects.items[obj].values.append(e.a, v);
    }

    fn addObj(e: *Encoder, o: *const Obj) anyerror!u32 {
        if (e.index.get(o)) |i| return i;
        const idx = try e.newObject(o.class);
        try e.index.put(e.a, o, idx);
        for (o.props.items) |p| try e.putValue(idx, p.key, p.value);
        return idx;
    }

    /// Wrapper object holding inline bytes under NS.bytes (NSString / NSData).
    fn bytesObject(e: *Encoder, class: []const u8, bytes: []const u8) !u32 {
        const idx = try e.newObject(class);
        try e.put(idx, .{ .key = try e.keyIndex("NS.bytes"), .type = .data, .data = bytes });
        return idx;
    }

    /// A value that must be an object reference (array items, dictionary entries).
    fn objectFor(e: *Encoder, v: Value) anyerror!u32 {
        return switch (v) {
            .obj => |o| e.addObj(o),
            .str => |s| e.bytesObject("NSString", s),
            .bytes => |b| e.bytesObject("NSData", b),
            .int, .double, .boolean => blk: {
                const idx = try e.newObject("NSNumber");
                switch (v) {
                    .double => |d| try e.put(idx, .{ .key = try e.keyIndex("NS.dblval"), .type = .double, .double = d }),
                    .boolean => |b| try e.putValue(idx, "NS.intval", .{ .int = @intFromBool(b) }),
                    else => try e.putValue(idx, "NS.intval", v),
                }
                break :blk idx;
            },
            .list => |l| blk: {
                const idx = try e.newObject("NSArray");
                try e.put(idx, .{ .key = try e.keyIndex("NSInlinedValue"), .type = .true });
                for (l.items.items) |item| try e.put(idx, .{ .key = try e.keyIndex("UINibEncoderEmptyKey"), .type = .object, .int = try e.objectFor(item) });
                break :blk idx;
            },
            .dict => |d| blk: {
                const idx = try e.newObject("NSDictionary");
                try e.put(idx, .{ .key = try e.keyIndex("NSInlinedValue"), .type = .true });
                for (d.keys.items, d.values.items) |k, val| {
                    try e.put(idx, .{ .key = try e.keyIndex("UINibEncoderEmptyKey"), .type = .object, .int = try e.objectFor(k) });
                    try e.put(idx, .{ .key = try e.keyIndex("UINibEncoderEmptyKey"), .type = .object, .int = try e.objectFor(val) });
                }
                break :blk idx;
            },
            .ref => |id| diag.fail("nib: unresolved object reference '{s}'", .{id}),
            .doubles, .nil => diag.fail("nib: {s} cannot be stored in a collection", .{@tagName(v)}),
        };
    }

    fn putValue(e: *Encoder, obj: u32, key: []const u8, v: Value) anyerror!void {
        const k = try e.keyIndex(key);
        switch (v) {
            .int => |n| {
                const t: Type = if (n >= std.math.minInt(i8) and n <= std.math.maxInt(i8))
                    .int8
                else if (n >= std.math.minInt(i16) and n <= std.math.maxInt(i16))
                    .int16
                else if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32))
                    .int32
                else
                    .int64;
                try e.put(obj, .{ .key = k, .type = t, .int = n });
            },
            .boolean => |b| try e.put(obj, .{ .key = k, .type = if (b) .true else .false }),
            .double => |d| try e.put(obj, .{ .key = k, .type = .double, .double = d }),
            .bytes => |b| try e.put(obj, .{ .key = k, .type = .data, .data = b }),
            .doubles => |ds| {
                var data = try e.a.alloc(u8, 1 + 8 * ds.len);
                data[0] = 0x07;
                for (ds, 0..) |d, i| std.mem.writeInt(u64, data[1 + 8 * i ..][0..8], @bitCast(d), .little);
                try e.put(obj, .{ .key = k, .type = .data, .data = data });
            },
            .nil => try e.put(obj, .{ .key = k, .type = .nil }),
            else => {
                // Reserve the slot first so the value order matches property order.
                try e.put(obj, .{ .key = k, .type = .object });
                const slot = e.objects.items[obj].values.items.len - 1;
                const target = try e.objectFor(v);
                e.objects.items[obj].values.items[slot].int = target;
            },
        }
    }
};

fn writeFlex(out: *std.ArrayList(u8), number: usize) !void {
    var n = number;
    while (true) {
        const byte: u8 = @intCast(n & 0x7f);
        n >>= 7;
        if (n == 0) return out.append(byte | 0x80);
        try out.append(byte);
    }
}

/// Encode the object graph rooted at `root` as a NIBArchive.
pub fn encode(a: Allocator, root: *const Obj) ![]u8 {
    var e: Encoder = .{ .a = a };
    _ = try e.addObj(root);

    var objs = std.ArrayList(u8).init(a);
    var vals = std.ArrayList(u8).init(a);
    var value_count: usize = 0;
    for (e.objects.items) |o| {
        try writeFlex(&objs, o.class);
        try writeFlex(&objs, value_count);
        try writeFlex(&objs, o.values.items.len);
        value_count += o.values.items.len;
        for (o.values.items) |v| {
            try writeFlex(&vals, v.key);
            try vals.append(@intFromEnum(v.type));
            switch (v.type) {
                .int8 => try vals.append(@bitCast(@as(i8, @intCast(v.int)))),
                .int16 => try vals.writer().writeInt(i16, @intCast(v.int), .little),
                .int32 => try vals.writer().writeInt(i32, @intCast(v.int), .little),
                .int64 => try vals.writer().writeInt(i64, v.int, .little),
                .object => try vals.writer().writeInt(u32, @intCast(v.int), .little),
                .double => try vals.writer().writeInt(u64, @bitCast(v.double), .little),
                .float => try vals.writer().writeInt(u32, @bitCast(@as(f32, @floatCast(v.double))), .little),
                .data => {
                    try writeFlex(&vals, v.data.len);
                    try vals.appendSlice(v.data);
                },
                .true, .false, .nil => {},
            }
        }
    }
    var keys = std.ArrayList(u8).init(a);
    for (e.keys.keys()) |k| {
        try writeFlex(&keys, k.len);
        try keys.appendSlice(k);
    }
    var classes = std.ArrayList(u8).init(a);
    for (e.classes.keys()) |c| {
        try writeFlex(&classes, c.len + 1);
        try classes.append(0x80);
        try classes.appendSlice(c);
        try classes.append(0);
    }

    var out = std.ArrayList(u8).init(a);
    try out.appendSlice("NIBArchive");
    const w = out.writer();
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u32, 10, .little); // coder version written by current Xcode
    const header = 50;
    const sections = [_]struct { usize, usize }{
        .{ e.objects.items.len, header },
        .{ e.keys.count(), header + objs.items.len },
        .{ value_count, header + objs.items.len + keys.items.len },
        .{ e.classes.count(), header + objs.items.len + keys.items.len + vals.items.len },
    };
    for (sections) |s| {
        try w.writeInt(u32, @intCast(s[0]), .little);
        try w.writeInt(u32, @intCast(s[1]), .little);
    }
    try out.appendSlice(objs.items);
    try out.appendSlice(keys.items);
    try out.appendSlice(vals.items);
    try out.appendSlice(classes.items);
    return out.items;
}

// ---------------------------------------------------------------- decoding

pub const Archive = struct {
    objects: []const struct { class: usize, start: usize, count: usize },
    keys: []const []const u8,
    values: []const Decoded,
    classes: []const []const u8,
};

pub const Decoded = struct {
    key: usize,
    type: Type,
    int: i64 = 0,
    double: f64 = 0,
    data: []const u8 = "",
};

const Cursor = struct {
    buf: []const u8,
    pos: usize,

    fn byte(c: *Cursor) !u8 {
        if (c.pos >= c.buf.len) return diag.fail("nib: truncated archive", .{});
        c.pos += 1;
        return c.buf[c.pos - 1];
    }

    fn take(c: *Cursor, n: usize) ![]const u8 {
        if (n > c.buf.len - @min(c.pos, c.buf.len)) return diag.fail("nib: truncated archive", .{});
        c.pos += n;
        return c.buf[c.pos - n .. c.pos];
    }

    fn int(c: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try c.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn flex(c: *Cursor) !usize {
        var n: usize = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try c.byte();
            n |= @as(usize, b & 0x7f) << shift;
            if (b & 0x80 != 0) return n;
            shift += 7;
            if (shift > 35) return diag.fail("nib: invalid varint", .{});
        }
    }
};

pub fn isArchive(bytes: []const u8) bool {
    return bytes.len >= 50 and std.mem.startsWith(u8, bytes, "NIBArchive");
}

pub fn decode(a: Allocator, bytes: []const u8) !Archive {
    if (!isArchive(bytes)) return diag.fail("not a NIBArchive", .{});
    var hdr: Cursor = .{ .buf = bytes, .pos = 18 };
    var counts: [4]usize = undefined;
    var offsets: [4]usize = undefined;
    for (0..4) |i| {
        counts[i] = try hdr.int(u32);
        offsets[i] = try hdr.int(u32);
    }
    const Obj_ = @typeInfo(@TypeOf(@as(Archive, undefined).objects)).pointer.child;
    const objects = try a.alloc(Obj_, counts[0]);
    var c: Cursor = .{ .buf = bytes, .pos = offsets[0] };
    for (objects) |*o| o.* = .{ .class = try c.flex(), .start = try c.flex(), .count = try c.flex() };

    const keys = try a.alloc([]const u8, counts[1]);
    c.pos = offsets[1];
    for (keys) |*k| k.* = try c.take(try c.flex());

    const values = try a.alloc(Decoded, counts[2]);
    c.pos = offsets[2];
    for (values) |*v| {
        v.* = .{ .key = try c.flex(), .type = std.meta.intToEnum(Type, try c.byte()) catch return diag.fail("nib: unknown value type at offset {d}", .{c.pos - 1}) };
        switch (v.type) {
            .int8 => v.int = @as(i8, @bitCast(try c.byte())),
            .int16 => v.int = try c.int(i16),
            .int32 => v.int = try c.int(i32),
            .int64 => v.int = try c.int(i64),
            .object => v.int = try c.int(u32),
            .float => v.double = @as(f32, @bitCast(try c.int(u32))),
            .double => v.double = @bitCast(try c.int(u64)),
            .data => v.data = try c.take(try c.flex()),
            .true, .false, .nil => {},
        }
    }

    const classes = try a.alloc([]const u8, counts[3]);
    c.pos = offsets[3];
    for (classes) |*cls| {
        const len = try c.flex();
        const kind = try c.byte();
        if (kind == 0x81) _ = try c.take(4) else if (kind != 0x80) return diag.fail("nib: unknown class entry type 0x{x}", .{kind});
        const name = try c.take(len);
        cls.* = std.mem.trimRight(u8, name, "\x00");
    }
    for (objects) |o| if (o.class >= classes.len or o.start + o.count > values.len)
        return diag.fail("nib: object table out of range", .{});
    for (values) |v| if (v.key >= keys.len) return diag.fail("nib: key index out of range", .{});
    return .{ .objects = objects, .keys = keys, .values = values, .classes = classes };
}

/// Human-readable dump in the style of ibtool's ibdump.py; nested archives are expanded.
pub fn dump(a: Allocator, bytes: []const u8, w: anytype, show_types: bool, prefix: []const u8) !void {
    const nib = try decode(a, bytes);
    for (nib.objects, 0..) |o, i| {
        try w.print("{s}{d:>3}: {s}\n", .{ prefix, i, nib.classes[o.class] });
        for (nib.values[o.start .. o.start + o.count]) |v| {
            const key = nib.keys[v.key];
            if (v.type == .data and std.mem.eql(u8, key, "NS.bytes") and isArchive(v.data)) {
                try w.print("{s}\t{s} = Encoded NIB Archive\n", .{ prefix, key });
                try dump(a, v.data, w, show_types, try std.fmt.allocPrint(a, "{s}\t", .{prefix}));
                continue;
            }
            try w.print("{s}\t{s} = ", .{ prefix, key });
            if (show_types) try w.print("({s}) ", .{@tagName(v.type)});
            switch (v.type) {
                .int8, .int16, .int32, .int64 => try w.print("{d}", .{v.int}),
                .object => try w.print("@{d}", .{v.int}),
                .float, .double => try w.print("{d}", .{v.double}),
                .true => try w.writeAll("true"),
                .false => try w.writeAll("false"),
                .nil => try w.writeAll("nil"),
                .data => if (v.data.len > 0 and v.data[0] == 0x07 and (v.data.len - 1) % 8 == 0) {
                    try w.writeAll("(");
                    var i_: usize = 1;
                    while (i_ < v.data.len) : (i_ += 8) {
                        if (i_ > 1) try w.writeAll(", ");
                        try w.print("{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, v.data[i_..][0..8], .little)))});
                    }
                    try w.writeAll(")");
                } else if (std.unicode.utf8ValidateSlice(v.data)) {
                    try w.print("\"{s}\"", .{v.data});
                } else {
                    try w.print("<{d} bytes>", .{v.data.len});
                },
            }
            try w.writeByte('\n');
        }
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "encode and decode round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try new(a, "NSObject");
    const view = try new(a, "UIView");
    try view.set(a, "UICenter", .{ .doubles = &.{ 160, 240 } });
    try view.set(a, "UIAutoresizingMask", .{ .int = 36 });
    try view.set(a, "UIEventMask", .{ .int = 1 << 19 });
    try view.set(a, "UIAlpha", .{ .double = 0.5 });
    try view.set(a, "UIOpaque", .{ .boolean = true });
    try view.setStr(a, "UIText", "héllo");
    try root.set(a, "UINibTopLevelObjectsKey", .{ .list = try listOf(a, &.{view}) });
    try root.set(a, "UINibObjectsKey", .{ .list = try listOf(a, &.{view}) });
    const d = try root.dict(a, "Table");
    try dictPut(a, d, .{ .str = "k" }, .{ .int = 300 });

    const bytes = try encode(a, root);
    const nib = try decode(a, bytes);
    try testing.expectEqualStrings("NSObject", nib.classes[nib.objects[0].class]);
    // root, NSArray, view, NSString, NSArray, NSDictionary, NSString, NSNumber
    try testing.expectEqual(@as(usize, 8), nib.objects.len);
    var found_mask = false;
    for (nib.values) |v| if (std.mem.eql(u8, nib.keys[v.key], "UIEventMask")) {
        try testing.expectEqual(Type.int32, v.type);
        try testing.expectEqual(@as(i64, 1 << 19), v.int);
        found_mask = true;
    };
    try testing.expect(found_mask);

    var out = std.ArrayList(u8).init(a);
    try dump(a, bytes, out.writer(), false, "");
    for ([_][]const u8{ "UICenter = (160, 240)", "NS.bytes = \"héllo\"", "UIOpaque = true", "UINibEncoderEmptyKey = @" }) |needle|
        try testing.expect(std.mem.indexOf(u8, out.items, needle) != null);
}

test "flex numbers" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try writeFlex(&buf, 0);
    try writeFlex(&buf, 127);
    try writeFlex(&buf, 128);
    try writeFlex(&buf, 300);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0xff, 0x00, 0x81, 0x2c, 0x82 }, buf.items);
    var c: Cursor = .{ .buf = buf.items, .pos = 0 };
    for ([_]usize{ 0, 127, 128, 300 }) |n| try testing.expectEqual(n, try c.flex());
}

test "unresolved references are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try new(arena.allocator(), "NSObject");
    try root.set(arena.allocator(), "X", .{ .ref = "abc-12-xyz" });
    try testing.expectError(error.Invalid, encode(arena.allocator(), root));
}
