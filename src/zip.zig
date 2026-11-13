//! Minimal ZIP support for IPAs: a deterministic writer (deflate via
//! std.compress.flate, Unix modes preserved) and a reader that validates CRCs.
//! ZIP64 is not supported (archives and entries must stay below 4 GiB).
const std = @import("std");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const local_sig = 0x04034b50;
const central_sig = 0x02014b50;
const eocd_sig = 0x06054b50;

/// 1980-01-01 00:00 in MS-DOS format; fixed so builds are reproducible.
const dos_time: u16 = 0;
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;

pub const Writer = struct {
    a: Allocator,
    out: std.ArrayList(u8),
    central: std.ArrayList(u8),
    count: u16 = 0,

    pub fn init(a: Allocator) Writer {
        return .{ .a = a, .out = std.ArrayList(u8).init(a), .central = std.ArrayList(u8).init(a) };
    }

    fn header(w: *Writer, list: *std.ArrayList(u8), central: bool, name: []const u8, method: u16, crc: u32, csize: u32, usize_: u32, mode: u32, offset: u32) !void {
        const x = list.writer();
        try x.writeInt(u32, if (central) central_sig else local_sig, .little);
        if (central) try x.writeInt(u16, (3 << 8) | 30, .little); // made by: Unix, spec 3.0
        try x.writeInt(u16, 20, .little); // version needed
        try x.writeInt(u16, 0x0800, .little); // UTF-8 names
        try x.writeInt(u16, method, .little);
        try x.writeInt(u16, dos_time, .little);
        try x.writeInt(u16, dos_date, .little);
        try x.writeInt(u32, crc, .little);
        try x.writeInt(u32, csize, .little);
        try x.writeInt(u32, usize_, .little);
        try x.writeInt(u16, @intCast(name.len), .little);
        try x.writeInt(u16, 0, .little); // extra
        if (central) {
            try x.writeInt(u16, 0, .little); // comment
            try x.writeInt(u16, 0, .little); // disk
            try x.writeInt(u16, 0, .little); // internal attrs
            const dos_dir: u32 = if (mode & 0o170000 == 0o040000) 0x10 else 0;
            try x.writeInt(u32, (mode << 16) | dos_dir, .little);
            try x.writeInt(u32, offset, .little);
        }
        try x.writeAll(name);
        _ = w;
    }

    fn add(w: *Writer, name: []const u8, data: []const u8, mode: u32) !void {
        if (w.count == std.math.maxInt(u16) or data.len > std.math.maxInt(u32) or w.out.items.len > std.math.maxInt(u32))
            return diag.fail("archive too large (ZIP64 is not supported)", .{});
        const crc = std.hash.Crc32.hash(data);
        var compressed = std.ArrayList(u8).init(w.a);
        var method: u16 = 0;
        var payload = data;
        if (data.len > 0) {
            var in = std.io.fixedBufferStream(data);
            try flate.compress(in.reader(), compressed.writer(), .{});
            if (compressed.items.len < data.len) {
                method = 8;
                payload = compressed.items;
            }
        }
        const offset: u32 = @intCast(w.out.items.len);
        try w.header(&w.out, false, name, method, crc, @intCast(payload.len), @intCast(data.len), mode, 0);
        try w.out.appendSlice(payload);
        try w.header(&w.central, true, name, method, crc, @intCast(payload.len), @intCast(data.len), mode, offset);
        w.count += 1;
    }

    pub fn addFile(w: *Writer, name: []const u8, data: []const u8, mode: u32) !void {
        return w.add(name, data, 0o100000 | (mode & 0o7777));
    }

    pub fn addDir(w: *Writer, name: []const u8) !void {
        const n = if (std.mem.endsWith(u8, name, "/")) name else try std.fmt.allocPrint(w.a, "{s}/", .{name});
        return w.add(n, "", 0o040755);
    }

    /// Recursively add `fs_dir` under archive prefix `prefix` in sorted order.
    pub fn addTree(w: *Writer, fs_dir: std.fs.Dir, prefix: []const u8) !void {
        try w.addDir(prefix);
        var names = std.ArrayList([]const u8).init(w.a);
        var it = fs_dir.iterate();
        while (try it.next()) |e| try names.append(try w.a.dupe(u8, e.name));
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.lessThan(u8, l, r);
            }
        }.lt);
        for (names.items) |name| {
            const path = try std.fmt.allocPrint(w.a, "{s}/{s}", .{ prefix, name });
            const st = try std.posix.fstatat(fs_dir.fd, name, std.posix.AT.SYMLINK_NOFOLLOW);
            switch (st.mode & std.posix.S.IFMT) {
                std.posix.S.IFDIR => {
                    var sub = try fs_dir.openDir(name, .{ .iterate = true, .no_follow = true });
                    defer sub.close();
                    try w.addTree(sub, path);
                },
                std.posix.S.IFREG => try w.addFile(path, try fs_dir.readFileAlloc(w.a, name, std.math.maxInt(u32)), st.mode),
                else => return diag.fail("cannot archive non-regular file (symlink?): {s}", .{path}),
            }
        }
    }

    pub fn finish(w: *Writer) ![]const u8 {
        const cd_offset: u32 = @intCast(w.out.items.len);
        try w.out.appendSlice(w.central.items);
        const x = w.out.writer();
        try x.writeInt(u32, eocd_sig, .little);
        try x.writeInt(u16, 0, .little);
        try x.writeInt(u16, 0, .little);
        try x.writeInt(u16, w.count, .little);
        try x.writeInt(u16, w.count, .little);
        try x.writeInt(u32, @intCast(w.central.items.len), .little);
        try x.writeInt(u32, cd_offset, .little);
        try x.writeInt(u16, 0, .little);
        return w.out.items;
    }
};

pub const Entry = struct {
    name: []const u8,
    method: u16,
    crc: u32,
    compressed_size: u32,
    size: u32,
    /// Unix st_mode from the upper 16 bits of the external attributes (0 if absent).
    mode: u32,
    local_offset: u32,
};

pub const Archive = struct {
    bytes: []const u8,
    entries: []Entry,

    pub fn find(ar: Archive, name: []const u8) ?Entry {
        for (ar.entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    /// Decompress an entry and verify its size and CRC-32.
    pub fn read(ar: Archive, a: Allocator, e: Entry) ![]u8 {
        const b = ar.bytes;
        if (@as(usize, e.local_offset) + 30 > b.len or std.mem.readInt(u32, b[e.local_offset..][0..4], .little) != local_sig)
            return diag.fail("ZIP: bad local header for {s}", .{e.name});
        const name_len = std.mem.readInt(u16, b[e.local_offset + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, b[e.local_offset + 28 ..][0..2], .little);
        const start = @as(usize, e.local_offset) + 30 + name_len + extra_len;
        if (start + e.compressed_size > b.len) return diag.fail("ZIP: truncated data for {s}", .{e.name});
        const raw = b[start..][0..e.compressed_size];
        const data = switch (e.method) {
            0 => try a.dupe(u8, raw),
            8 => blk: {
                var out = std.ArrayList(u8).init(a);
                var in = std.io.fixedBufferStream(raw);
                flate.decompress(in.reader(), out.writer()) catch return diag.fail("ZIP: corrupt deflate stream in {s}", .{e.name});
                break :blk out.items;
            },
            else => return diag.fail("ZIP: unsupported compression method {d} for {s}", .{ e.method, e.name }),
        };
        if (data.len != e.size) return diag.fail("ZIP: size mismatch for {s}", .{e.name});
        if (std.hash.Crc32.hash(data) != e.crc) return diag.fail("ZIP CRC failure: {s}", .{e.name});
        return data;
    }
};

pub fn open(a: Allocator, bytes: []const u8) !Archive {
    if (bytes.len < 22) return diag.fail("not a ZIP archive (too short)", .{});
    var i: usize = bytes.len - 22;
    const floor = if (bytes.len > 22 + 0xffff) bytes.len - 22 - 0xffff else 0;
    const eocd = while (true) : (i -= 1) {
        if (std.mem.readInt(u32, bytes[i..][0..4], .little) == eocd_sig) break i;
        if (i == floor) return diag.fail("not a ZIP archive (no end of central directory)", .{});
    };
    const count = std.mem.readInt(u16, bytes[eocd + 10 ..][0..2], .little);
    const cd_size = std.mem.readInt(u32, bytes[eocd + 12 ..][0..4], .little);
    const cd_offset = std.mem.readInt(u32, bytes[eocd + 16 ..][0..4], .little);
    if (count == 0xffff or cd_offset == 0xffffffff) return diag.fail("ZIP64 archives are not supported", .{});
    if (@as(usize, cd_offset) + cd_size > eocd) return diag.fail("ZIP: central directory out of range", .{});
    const entries = try a.alloc(Entry, count);
    var p: usize = cd_offset;
    for (entries) |*e| {
        if (p + 46 > eocd or std.mem.readInt(u32, bytes[p..][0..4], .little) != central_sig) return diag.fail("ZIP: bad central directory", .{});
        const made_by = std.mem.readInt(u16, bytes[p + 4 ..][0..2], .little);
        const name_len = std.mem.readInt(u16, bytes[p + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, bytes[p + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, bytes[p + 32 ..][0..2], .little);
        const external = std.mem.readInt(u32, bytes[p + 38 ..][0..4], .little);
        if (p + 46 + name_len > eocd) return diag.fail("ZIP: bad central directory", .{});
        e.* = .{
            .name = bytes[p + 46 ..][0..name_len],
            .method = std.mem.readInt(u16, bytes[p + 10 ..][0..2], .little),
            .crc = std.mem.readInt(u32, bytes[p + 16 ..][0..4], .little),
            .compressed_size = std.mem.readInt(u32, bytes[p + 20 ..][0..4], .little),
            .size = std.mem.readInt(u32, bytes[p + 24 ..][0..4], .little),
            .mode = if (made_by >> 8 == 3) external >> 16 else 0,
            .local_offset = std.mem.readInt(u32, bytes[p + 42 ..][0..4], .little),
        };
        p += 46 + name_len + extra_len + comment_len;
    }
    return .{ .bytes = bytes, .entries = entries };
}

test "write and read back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var w = Writer.init(a);
    try w.addDir("Payload");
    const big = "hello " ** 200;
    try w.addFile("Payload/a.txt", big, 0o644);
    try w.addFile("Payload/exe", "\xcf\xfa\xed\xfe", 0o755);
    const bytes = try w.finish();
    const ar = try open(a, bytes);
    try std.testing.expectEqual(@as(usize, 3), ar.entries.len);
    try std.testing.expectEqualStrings(big, try ar.read(a, ar.find("Payload/a.txt").?));
    try std.testing.expectEqual(@as(u16, 8), ar.find("Payload/a.txt").?.method);
    try std.testing.expectEqual(@as(u32, 0o100755), ar.find("Payload/exe").?.mode);
    // Corrupt one byte of the stored executable and expect a CRC failure.
    const copy = try a.dupe(u8, bytes);
    const e = ar.find("Payload/exe").?;
    copy[e.local_offset + 30 + e.name.len] ^= 0xff;
    const bad = try open(a, copy);
    try std.testing.expectError(error.Invalid, bad.read(a, bad.find("Payload/exe").?));
}
