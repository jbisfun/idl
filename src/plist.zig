//! Property lists via libimobiledevice's libplist (built from source in
//! build.zig). This module adds only what libplist lacks: Xcode-style
//! `$(VAR)` expansion and the CLI's `KEY=VALUE` value parsing.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");

pub const c = @import("plist_c");
const Allocator = std.mem.Allocator;

/// An owned libplist node. Child nodes handed to `set` become owned by the parent.
pub const Plist = struct {
    node: c.plist_t,

    pub fn deinit(p: Plist) void {
        c.plist_free(p.node);
    }

    pub fn newDict() Plist {
        return .{ .node = c.plist_new_dict() };
    }

    pub fn isDict(p: Plist) bool {
        return c.plist_get_node_type(p.node) == c.PLIST_DICT;
    }

    pub fn get(p: Plist, a: Allocator, key: []const u8) !c.plist_t {
        return c.plist_dict_get_item(p.node, try a.dupeSentinel(u8, key, 0));
    }

    /// String value of `key`, or null if absent / not a string.
    pub fn getString(p: Plist, a: Allocator, key: []const u8) !?[]const u8 {
        return stringOf(try p.get(a, key));
    }

    /// Insert or replace `key`; takes ownership of `value`.
    pub fn set(p: Plist, a: Allocator, key: []const u8, value: c.plist_t) !void {
        if (c.plist_dict_set_item(p.node, try a.dupeSentinel(u8, key, 0), value) != c.PLIST_ERR_SUCCESS)
            return diag.fail("cannot set plist key {s}", .{key});
    }

    pub fn setDefault(p: Plist, a: Allocator, key: []const u8, value: c.plist_t) !void {
        if (try p.get(a, key) == null) try p.set(a, key, value) else c.plist_free(value);
    }

    pub fn remove(p: Plist, a: Allocator, key: []const u8) !void {
        _ = c.plist_dict_remove_item(p.node, try a.dupeSentinel(u8, key, 0));
    }

    pub fn toBinary(p: Plist, a: Allocator) ![]u8 {
        var buf: [*c]u8 = null;
        var len: u32 = 0;
        if (c.plist_to_bin(p.node, &buf, &len) != c.PLIST_ERR_SUCCESS or buf == null)
            return diag.fail("cannot serialize plist", .{});
        defer c.plist_mem_free(buf);
        return a.dupe(u8, buf[0..len]);
    }

    pub fn toXml(p: Plist, a: Allocator) ![]u8 {
        var buf: [*c]u8 = null;
        var len: u32 = 0;
        if (c.plist_to_xml(p.node, &buf, &len) != c.PLIST_ERR_SUCCESS or buf == null)
            return diag.fail("cannot serialize plist", .{});
        defer c.plist_mem_free(buf);
        return a.dupe(u8, buf[0..len]);
    }
};

pub fn stringOf(node: c.plist_t) ?[]const u8 {
    if (node == null or c.plist_get_node_type(node) != c.PLIST_STRING) return null;
    var len: u64 = 0;
    const ptr = c.plist_get_string_ptr(node, &len) orelse return null;
    return ptr[0..@intCast(len)];
}

pub fn newString(a: Allocator, s: []const u8) !c.plist_t {
    return c.plist_new_string(try a.dupeSentinel(u8, s, 0));
}

/// Parse XML, binary, JSON or OpenStep plist data.
pub fn parse(bytes: []const u8) !Plist {
    if (bytes.len > std.math.maxInt(u32)) return diag.fail("plist too large", .{});
    var out: c.plist_t = null;
    var format: c.plist_format_t = undefined;
    const err = c.plist_from_memory(bytes.ptr, @intCast(bytes.len), &out, &format);
    if (err != c.PLIST_ERR_SUCCESS or out == null) return diag.fail("invalid property list (libplist error {d})", .{err});
    return .{ .node = out };
}

pub fn readFile(a: Allocator, path: []const u8) !Plist {
    const bytes = sys.readFile(a, path, 64 << 20) catch |err|
        return diag.fail("cannot read plist {s}: {s}", .{ path, @errorName(err) });
    return parse(bytes) catch diag.fail("{s}: {s}", .{ path, diag.msg });
}

// ------------------------------------------------------ Xcode variables

pub const Vars = std.StringHashMap([]const u8);

/// Replace `$(NAME)`, `${NAME}` and `$(NAME:modifier)` with values from
/// `vars`, falling back to the process environment, else "".
pub fn expandString(a: Allocator, s: []const u8, vars: *const Vars, env: ?*const std.process.Environ.Map) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '$') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '$' and i + 2 < s.len and (s[i + 1] == '(' or s[i + 1] == '{')) {
            var j = i + 2;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) j += 1;
            const name = s[i + 2 .. j];
            var k = j;
            if (k < s.len and s[k] == ':') {
                k += 1;
                const mod_start = k;
                while (k < s.len and (std.ascii.isLower(s[k]) or std.ascii.isDigit(s[k]))) k += 1;
                if (k == mod_start) k = 0; // `:` must be followed by a modifier
            }
            if (name.len > 0 and k != 0 and k < s.len and (s[k] == ')' or s[k] == '}')) {
                const replacement = vars.get(name) orelse (if (env) |e| e.get(name) else null) orelse "";
                try out.appendSlice(a, replacement);
                i = k + 1;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

/// Expand variables in every string value (not keys), in place.
pub fn expand(a: Allocator, node: c.plist_t, vars: *const Vars, env: ?*const std.process.Environ.Map) !void {
    switch (c.plist_get_node_type(node)) {
        c.PLIST_STRING => {
            const s = stringOf(node).?;
            const expanded = try expandString(a, s, vars, env);
            if (expanded.ptr != s.ptr) c.plist_set_string_val(node, try a.dupeSentinel(u8, expanded, 0));
        },
        c.PLIST_ARRAY => {
            const n = c.plist_array_get_size(node);
            for (0..n) |i| try expand(a, c.plist_array_get_item(node, @intCast(i)), vars, env);
        },
        c.PLIST_DICT => {
            var it: c.plist_dict_iter = null;
            c.plist_dict_new_iter(node, &it);
            defer c.plist_dict_free_iter(it);
            while (true) {
                var key: [*c]u8 = null;
                var val: c.plist_t = null;
                c.plist_dict_next_item(node, it, &key, &val);
                if (val == null) break;
                c.plist_mem_free(key);
                try expand(a, val, vars, env);
            }
        },
        else => {},
    }
}

const string_keys = [_][]const u8{ "CFBundleVersion", "CFBundleShortVersionString", "CFBundleInfoDictionaryVersion", "MinimumOSVersion" };

/// Interpret a command-line/config value: JSON (via libplist) for `[..]`,
/// `{..}`, true/false and integers, otherwise a string. Version keys stay strings.
pub fn parseCliValue(a: Allocator, key: []const u8, raw: []const u8) !c.plist_t {
    for (string_keys) |k| if (std.mem.eql(u8, k, key)) return newString(a, raw);
    if (std.mem.eql(u8, raw, "true")) return c.plist_new_bool(1);
    if (std.mem.eql(u8, raw, "false")) return c.plist_new_bool(0);
    if (std.fmt.parseInt(i64, raw, 10)) |n| {
        if (raw[0] != '+') return c.plist_new_int(n);
    } else |_| {}
    if (raw.len > 0 and (raw[0] == '[' or raw[0] == '{')) {
        var out: c.plist_t = null;
        if (c.plist_from_json(raw.ptr, @intCast(raw.len), &out) != c.PLIST_ERR_SUCCESS or out == null)
            return diag.fail("invalid JSON value for {s}: {s}", .{ key, raw });
        return out;
    }
    return newString(a, raw);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "read, edit, expand and write with libplist" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try parse(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0"><dict>
        \\<key>B</key><string>x &amp; $(EXECUTABLE_NAME)</string>
        \\<key>A</key><array><string>${EXECUTABLE_NAME}</string><integer>2</integer></array>
        \\</dict></plist>
    );
    defer root.deinit();
    try testing.expect(root.isDict());
    try root.set(a, "CFBundleVersion", try parseCliValue(a, "CFBundleVersion", "123"));
    try root.set(a, "Enabled", try parseCliValue(a, "Enabled", "true"));
    try root.set(a, "Arr", try parseCliValue(a, "Arr", "[\"a\",1]"));
    try root.setDefault(a, "B", try newString(a, "ignored"));
    var vars = Vars.init(a);
    try vars.put("EXECUTABLE_NAME", "App");
    try expand(a, root.node, &vars, null);
    try testing.expectEqualStrings("x & App", (try root.getString(a, "B")).?);
    try testing.expectEqualStrings("123", (try root.getString(a, "CFBundleVersion")).?);
    const xml = try root.toXml(a);
    for ([_][]const u8{ "<string>x &amp; App</string>", "<string>App</string>", "<key>Enabled</key>", "<true/>", "<string>123</string>", "<integer>1</integer>" }) |needle|
        try testing.expect(std.mem.indexOf(u8, xml, needle) != null);
    // Round-trips through binary detection too.
    const again = try parse(xml);
    defer again.deinit();
    try testing.expectEqualStrings("App", stringOf(c.plist_array_get_item(try again.get(a, "A"), 0)).?);
}

test "variable expansion forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vars = Vars.init(a);
    try vars.put("N", "v");
    try testing.expectEqualStrings("v-v-v-", try expandString(a, "$(N)-${N}-$(N:rfc1034identifier)-$(MISSING)", &vars, null));
    try testing.expectEqualStrings("$(", try expandString(a, "$(", &vars, null));
    try testing.expectEqualStrings("$5", try expandString(a, "$5", &vars, null));
}

test "invalid data is rejected" {
    try testing.expectError(error.Invalid, parse("<?xml version=\"1.0\"?><plist><dict><key>x</key></plist>"));
    try testing.expectError(error.Invalid, parse("bplist00garbage"));
}
