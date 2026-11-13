//! Single human-readable error message shared by every module.
//! Functions return `error.Invalid` after calling `fail`; main prints `msg`.
//! `fail` may safely be called with the previous `msg` as an argument (to add context).
const std = @import("std");

var buf: [2048]u8 = undefined;
var scratch: [2048]u8 = undefined;
pub var msg: []const u8 = "";

pub fn fail(comptime fmt: []const u8, args: anytype) error{Invalid} {
    const text = std.fmt.bufPrint(&scratch, fmt, args) catch blk: {
        const marker = "...";
        @memcpy(scratch[scratch.len - marker.len ..], marker);
        break :blk scratch[0..];
    };
    @memcpy(buf[0..text.len], text);
    msg = buf[0..text.len];
    return error.Invalid;
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("warning: " ++ fmt ++ "\n", args) catch {};
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt ++ "\n", args) catch {};
}
