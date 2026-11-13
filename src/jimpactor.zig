//! Client for Jimpactor's local IPC protocol (version 1), used by `idl devices`
//! and `idl install`. The running Jimpactor (tray) app signs IPAs with the
//! user's account and installs them on a device.
//!
//! Protocol (see jimpactor crates/utils/ipc.schema.json): connect to 127.0.0.1
//! on the port in <data>/relaunch.port, write one JSON request carrying the
//! token from <data>/ipc.token, shut down the write half, then read one JSON
//! event per line until a terminal event (anything but `progress`).
const std = @import("std");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;

pub const protocol_version = 1;
pub const port_file = "relaunch.port";
pub const token_file = "ipc.token";

/// Jimpactor's data dir: $XDG_CONFIG_HOME/Jimpactor, else ~/.config/Jimpactor.
pub fn defaultDataDir(a: Allocator, env: *const std.process.EnvMap) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fs.path.join(a, &.{ x, "Jimpactor" });
    const home = env.get("HOME") orelse return diag.fail("HOME is not set; set toolchain.jimpactor_dir", .{});
    return std.fs.path.join(a, &.{ home, ".config", "Jimpactor" });
}

pub const Endpoint = struct { port: u16, token: []const u8 };

pub fn endpoint(a: Allocator, data_dir: []const u8) !Endpoint {
    const port_text = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ data_dir, port_file }), 64) catch
        return diag.fail("Jimpactor is not running (no {s} in {s})", .{ port_file, data_dir });
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, port_text, " \t\r\n"), 10) catch
        return diag.fail("invalid {s} in {s}", .{ port_file, data_dir });
    const token = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ data_dir, token_file }), 4096) catch
        return diag.fail("the running Jimpactor is too old to accept IPC requests (no {s})", .{token_file});
    return .{ .port = port, .token = std.mem.trim(u8, token, " \t\r\n") };
}

pub const Device = struct {
    udid: []const u8,
    name: []const u8,
    connection: []const u8,
    available: bool,
};

/// Union of every event's fields; `event` says which ones are set.
pub const Event = struct {
    event: []const u8,
    message: ?[]const u8 = null,
    percent: ?i64 = null,
    devices: ?[]const Device = null,
    app_version: ?[]const u8 = null,
    protocol_version: ?i64 = null,
};

pub const Request = union(enum) {
    info,
    list_devices,
    install: struct { path: []const u8, udid: ?[]const u8 = null },
};

fn encode(a: Allocator, token: []const u8, request: Request) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var w = std.json.writeStream(out.writer(), .{});
    try w.beginObject();
    try w.objectField("version");
    try w.write(protocol_version);
    try w.objectField("token");
    try w.write(token);
    try w.objectField("command");
    try w.write(@tagName(request));
    switch (request) {
        .install => |i| {
            try w.objectField("path");
            try w.write(i.path);
            if (i.udid) |u| {
                try w.objectField("udid");
                try w.write(u);
            }
        },
        else => {},
    }
    try w.endObject();
    return out.items;
}

pub const ProgressFn = *const fn (message: []const u8, percent: i64) void;

/// Send one request and return the terminal event. `error` events become `error.Invalid`.
pub fn send(a: Allocator, data_dir: []const u8, request: Request, on_progress: ?ProgressFn) !Event {
    const ep = try endpoint(a, data_dir);
    const stream = std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, ep.port)) catch |err|
        return diag.fail("could not reach Jimpactor on 127.0.0.1:{d} (is it running?): {s}", .{ ep.port, @errorName(err) });
    defer stream.close();
    stream.writeAll(try encode(a, ep.token, request)) catch |err|
        return diag.fail("could not send the request to Jimpactor: {s}", .{@errorName(err)});
    std.posix.shutdown(stream.handle, .send) catch |err|
        return diag.fail("could not send the request to Jimpactor: {s}", .{@errorName(err)});

    var reader = std.io.bufferedReader(stream.reader());
    while (true) {
        const line = reader.reader().readUntilDelimiterOrEofAlloc(a, '\n', 16 << 20) catch |err|
            return diag.fail("lost the connection to Jimpactor: {s}", .{@errorName(err)});
        const text = std.mem.trim(u8, line orelse break, " \t\r");
        if (text.len == 0) continue;
        const event = std.json.parseFromSliceLeaky(Event, a, text, .{ .ignore_unknown_fields = true }) catch
            return diag.fail("unexpected reply from Jimpactor: {s}", .{text});
        if (std.mem.eql(u8, event.event, "progress")) {
            if (on_progress) |f| f(event.message orelse "", event.percent orelse 0);
            continue;
        }
        if (std.mem.eql(u8, event.event, "error")) return diag.fail("Jimpactor: {s}", .{event.message orelse "unknown error"});
        return event;
    }
    return diag.fail("Jimpactor closed the connection before finishing", .{});
}

pub fn listDevices(a: Allocator, data_dir: []const u8) ![]const Device {
    const event = try send(a, data_dir, .list_devices, null);
    if (!std.mem.eql(u8, event.event, "devices")) return diag.fail("unexpected '{s}' reply to list_devices", .{event.event});
    return event.devices orelse &.{};
}

/// Resolve a device argument (UDID, unique UDID prefix, or name) against Jimpactor's list.
pub fn resolveDevice(devices: []const Device, query: []const u8) !Device {
    for (devices) |d| if (std.mem.eql(u8, d.udid, query)) return d;
    var match: ?Device = null;
    var count: usize = 0;
    for (devices) |d| {
        const hit = std.ascii.eqlIgnoreCase(d.name, query) or
            (query.len >= 4 and std.ascii.startsWithIgnoreCase(d.udid, query));
        if (hit) {
            match = d;
            count += 1;
        }
    }
    if (count == 1) return match.?;
    if (count > 1) return diag.fail("'{s}' matches {d} devices; use the UDID (see `idl devices list`)", .{ query, count });
    if (devices.len == 0) return diag.fail("Jimpactor sees no devices", .{});
    return diag.fail("no device named or with UDID '{s}' (see `idl devices list`)", .{query});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const FakeServer = struct {
    server: std.net.Server,
    replies: []const []const u8,
    request: [4096]u8 = undefined,
    request_len: usize = 0,

    fn run(s: *FakeServer) void {
        const conn = s.server.accept() catch return;
        defer conn.stream.close();
        // Read until the client shuts down its write half.
        while (true) {
            const n = conn.stream.read(s.request[s.request_len..]) catch return;
            if (n == 0) break;
            s.request_len += n;
        }
        for (s.replies) |r| conn.stream.writeAll(r) catch return;
    }
};

fn withServer(replies: []const []const u8, body: *const fn (Allocator, []const u8, *FakeServer) anyerror!void) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake: FakeServer = .{
        .server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{}),
        .replies = replies,
    };
    defer fake.server.deinit();
    try tmp.dir.writeFile(.{ .sub_path = port_file, .data = try std.fmt.allocPrint(a, "{d}\n", .{fake.server.listen_address.getPort()}) });
    try tmp.dir.writeFile(.{ .sub_path = token_file, .data = "secret\n" });
    const thread = try std.Thread.spawn(.{}, FakeServer.run, .{&fake});
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const result = body(a, dir, &fake);
    thread.join();
    return result;
}

var progress_seen: usize = 0;
fn countProgress(_: []const u8, _: i64) void {
    progress_seen += 1;
}

test "install streams progress, sends token/path/udid, returns done" {
    progress_seen = 0;
    try withServer(&.{
        "{\"event\":\"progress\",\"message\":\"Signing\",\"percent\":40}\n",
        "{\"event\":\"progress\",\"message\":\"Installing\",\"percent\":80}\n",
        "{\"event\":\"done\",\"message\":\"Installed App on Phone\"}\n",
    }, struct {
        fn f(a: Allocator, dir: []const u8, fake: *FakeServer) !void {
            const event = try send(a, dir, .{ .install = .{ .path = "/abs/App.ipa", .udid = "U1" } }, countProgress);
            try testing.expectEqualStrings("done", event.event);
            try testing.expectEqualStrings("Installed App on Phone", event.message.?);
            try testing.expectEqual(@as(usize, 2), progress_seen);
            _ = fake;
        }
    }.f);
}

test "request encoding matches the schema" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "{\"version\":1,\"token\":\"t\",\"command\":\"install\",\"path\":\"/a b/App.ipa\",\"udid\":\"X\"}",
        try encode(arena.allocator(), "t", .{ .install = .{ .path = "/a b/App.ipa", .udid = "X" } }),
    );
    try testing.expectEqualStrings(
        "{\"version\":1,\"token\":\"t\",\"command\":\"list_devices\"}",
        try encode(arena.allocator(), "t", .list_devices),
    );
}

test "list devices and resolve by name, UDID and prefix" {
    try withServer(&.{
        "{\"event\":\"devices\",\"devices\":[{\"udid\":\"00008130-000A7D6901E0001C\",\"name\":\"JP's iPhone\",\"connection\":\"wifi\",\"available\":true},{\"udid\":\"00008030-AAAA\",\"name\":\"iPad\",\"connection\":\"usb\",\"available\":false}]}\n",
    }, struct {
        fn f(a: Allocator, dir: []const u8, fake: *FakeServer) !void {
            const devices = try listDevices(a, dir);
            try testing.expectEqual(@as(usize, 2), devices.len);
            try testing.expect(std.mem.indexOf(u8, fake.request[0..fake.request_len], "\"token\":\"secret\"") != null);
            try testing.expectEqualStrings("00008030-AAAA", (try resolveDevice(devices, "ipad")).udid);
            try testing.expectEqualStrings("JP's iPhone", (try resolveDevice(devices, "00008130")).name);
            try testing.expectError(error.Invalid, resolveDevice(devices, "0000"));
            try testing.expectError(error.Invalid, resolveDevice(devices, "Watch"));
        }
    }.f);
}

test "error events become failures" {
    try withServer(&.{"{\"event\":\"error\",\"message\":\"Invalid token\"}\n"}, struct {
        fn f(a: Allocator, dir: []const u8, _: *FakeServer) !void {
            try testing.expectError(error.Invalid, send(a, dir, .info, null));
            try testing.expect(std.mem.indexOf(u8, diag.msg, "Invalid token") != null);
        }
    }.f);
}

test "missing port file means not running" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const dir = try tmp.dir.realpathAlloc(arena.allocator(), ".");
    try testing.expectError(error.Invalid, send(arena.allocator(), dir, .info, null));
    try testing.expect(std.mem.indexOf(u8, diag.msg, "not running") != null);
}
