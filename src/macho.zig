//! Just enough Mach-O parsing to validate an iOS app executable without
//! macOS tools (otool/vtool are Mach-O binaries and do not run on Linux).
const std = @import("std");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;

pub const cpu_arm64: u32 = 0x0100000c;
pub const mh_execute: u32 = 2;
pub const platform_ios: u32 = 2;

const lc_req_dyld: u32 = 0x80000000;
const lc_load_dylib: u32 = 0x0c;
const lc_load_weak_dylib: u32 = 0x18 | lc_req_dyld;
const lc_reexport_dylib: u32 = 0x1f | lc_req_dyld;
const lc_code_signature: u32 = 0x1d;
const lc_version_min_iphoneos: u32 = 0x25;
const lc_main: u32 = 0x28 | lc_req_dyld;
const lc_build_version: u32 = 0x32;

pub const Info = struct {
    cputype: u32,
    filetype: u32,
    has_main: bool = false,
    has_code_signature: bool = false,
    platform: ?u32 = null,
    /// Encoded X.Y.Z as xxxx.yy.zz nibbles (Mach-O convention).
    min_os: ?u32 = null,
    sdk: ?u32 = null,
    dylibs: []const []const u8 = &.{},
};

pub fn formatVersion(buf: []u8, v: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ v >> 16, (v >> 8) & 0xff, v & 0xff }) catch "?";
}

pub fn platformName(p: u32) []const u8 {
    return switch (p) {
        1 => "macOS",
        2 => "iOS",
        3 => "tvOS",
        4 => "watchOS",
        6 => "Mac Catalyst",
        7 => "iOS Simulator",
        else => "unknown",
    };
}

pub fn parse(a: Allocator, b: []const u8) !Info {
    if (b.len < 4) return diag.fail("executable is empty or truncated", .{});
    const magic = std.mem.readInt(u32, b[0..4], .little);
    switch (magic) {
        0xfeedfacf => {},
        0xfeedface => return diag.fail("executable is 32-bit Mach-O; iOS 11+ requires arm64", .{}),
        0xbebafeca, 0xbfbafeca => return diag.fail("executable is a fat/universal Mach-O; expected thin arm64", .{}),
        0xcffaedfe, 0xcefaedfe => return diag.fail("big-endian Mach-O is not an iOS executable", .{}),
        else => return diag.fail("executable is not a Mach-O file", .{}),
    }
    if (b.len < 32) return diag.fail("Mach-O header truncated", .{});
    var info: Info = .{
        .cputype = std.mem.readInt(u32, b[4..8], .little),
        .filetype = std.mem.readInt(u32, b[12..16], .little),
    };
    const ncmds = std.mem.readInt(u32, b[16..20], .little);
    var dylibs = std.ArrayList([]const u8).init(a);
    var off: usize = 32;
    for (0..ncmds) |_| {
        if (off + 8 > b.len) return diag.fail("Mach-O load commands truncated", .{});
        const cmd = std.mem.readInt(u32, b[off..][0..4], .little);
        const size = std.mem.readInt(u32, b[off + 4 ..][0..4], .little);
        if (size < 8 or off + size > b.len) return diag.fail("Mach-O load command out of range", .{});
        const lc = b[off .. off + size];
        switch (cmd) {
            lc_main => info.has_main = true,
            lc_code_signature => info.has_code_signature = true,
            lc_build_version => if (size >= 24) {
                info.platform = std.mem.readInt(u32, lc[8..12], .little);
                info.min_os = std.mem.readInt(u32, lc[12..16], .little);
                info.sdk = std.mem.readInt(u32, lc[16..20], .little);
            },
            lc_version_min_iphoneos => if (size >= 16) {
                info.platform = platform_ios;
                info.min_os = std.mem.readInt(u32, lc[8..12], .little);
                info.sdk = std.mem.readInt(u32, lc[12..16], .little);
            },
            lc_load_dylib, lc_load_weak_dylib, lc_reexport_dylib => if (size >= 24) {
                const name_off = std.mem.readInt(u32, lc[8..12], .little);
                if (name_off < size) {
                    const raw = lc[name_off..];
                    try dylibs.append(raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len]);
                }
            },
            else => {},
        }
        off += size;
    }
    info.dylibs = dylibs.items;
    return info;
}

/// True for libraries every iOS device provides, or ones resolved inside the bundle.
pub fn isSystemOrBundled(path: []const u8) bool {
    for ([_][]const u8{ "/usr/lib/", "/System/Library/", "@rpath/", "@executable_path/", "@loader_path/" }) |p|
        if (std.mem.startsWith(u8, path, p)) return true;
    return false;
}

test "parse a synthetic arm64 executable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf = std.ArrayList(u8).init(arena.allocator());
    const w = buf.writer();
    const dylib_name = "/usr/lib/libobjc.A.dylib\x00\x00\x00\x00\x00\x00\x00\x00";
    const cmds = [_]u32{ 24, 24 + @as(u32, dylib_name.len), 24, 16 };
    try w.writeInt(u32, 0xfeedfacf, .little);
    try w.writeInt(u32, cpu_arm64, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, mh_execute, .little);
    try w.writeInt(u32, cmds.len, .little);
    var total: u32 = 0;
    for (cmds) |c| total += c;
    try w.writeInt(u32, total, .little);
    try w.writeInt(u64, 0, .little);
    // LC_MAIN
    try w.writeInt(u32, lc_main, .little);
    try w.writeInt(u32, 24, .little);
    try w.writeInt(u64, 0, .little);
    try w.writeInt(u64, 0, .little);
    // LC_LOAD_DYLIB
    try w.writeInt(u32, lc_load_dylib, .little);
    try w.writeInt(u32, cmds[1], .little);
    try w.writeInt(u32, 24, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u64, 0, .little);
    try w.writeAll(dylib_name);
    // LC_BUILD_VERSION iOS 16.0, SDK 27.2
    try w.writeInt(u32, lc_build_version, .little);
    try w.writeInt(u32, 24, .little);
    try w.writeInt(u32, platform_ios, .little);
    try w.writeInt(u32, 16 << 16, .little);
    try w.writeInt(u32, (27 << 16) | (2 << 8), .little);
    try w.writeInt(u32, 0, .little);
    // LC_CODE_SIGNATURE
    try w.writeInt(u32, lc_code_signature, .little);
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u64, 0, .little);
    const info = try parse(arena.allocator(), buf.items);
    try std.testing.expect(info.has_main and info.has_code_signature);
    try std.testing.expectEqual(platform_ios, info.platform.?);
    var vb: [32]u8 = undefined;
    try std.testing.expectEqualStrings("16.0.0", formatVersion(&vb, info.min_os.?));
    try std.testing.expectEqualStrings("/usr/lib/libobjc.A.dylib", info.dylibs[0]);
}
