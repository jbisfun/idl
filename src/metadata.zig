//! Generated application metadata shared by direct builds, Xcode and xtool.
const std = @import("std");
const diag = @import("diag.zig");
const plist = @import("plist.zig");
const ynode = @import("ynode.zig");
const Target = @import("config.zig").Target;
const Allocator = std.mem.Allocator;
pub fn ynodeToPlist(a: Allocator, key: []const u8, n: ynode.Node) !plist.c.plist_t {
    return switch (n) {
        .null => diag.fail("info.{s}: null is not a plist value", .{key}),
        .scalar => |s| if (s.quoted) try plist.newString(a, s.text) else try plist.parseCliValue(a, key, s.text),
        .list => |items| blk: {
            const arr = plist.c.plist_new_array();
            for (items) |item| _ = plist.c.plist_array_append_item(arr, try ynodeToPlist(a, key, item));
            break :blk arr;
        },
        .map => |m| blk: {
            const d = plist.Plist.newDict();
            for (m.keys, m.values) |k, v| try d.set(a, k, try ynodeToPlist(a, k, v));
            break :blk d.node;
        },
    };
}

pub fn buildVars(a: Allocator, t: Target) !plist.Vars {
    var vars = plist.Vars.init(a);
    const module = try a.dupe(u8, t.name);
    for (module) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
        ch.* = '_';
    };
    try vars.put("EXECUTABLE_NAME", t.name);
    try vars.put("PRODUCT_NAME", t.name);
    try vars.put("TARGET_NAME", t.name);
    try vars.put("PRODUCT_MODULE_NAME", module);
    try vars.put("PRODUCT_BUNDLE_IDENTIFIER", t.bundle_id);
    try vars.put("PRODUCT_BUNDLE_PACKAGE_TYPE", t.type.packageType());
    try vars.put("MARKETING_VERSION", t.version);
    try vars.put("CURRENT_PROJECT_VERSION", t.build_number);
    try vars.put("IPHONEOS_DEPLOYMENT_TARGET", t.min_ios);
    try vars.put("DEVELOPMENT_LANGUAGE", "en");
    if (t.plist_vars) |m| for (m.keys, m.values) |k, v| switch (v) {
        .scalar => |s| try vars.put(k, s.text),
        else => return diag.fail("plist_vars.{s} must be a string", .{k}),
    };
    return vars;
}

/// Info.plist with `info:` overrides applied, variables expanded and
/// MinimumOSVersion forced to the target's deployment version. `generated`
/// (keys produced by resource compilers, e.g. app icons) is merged last.
pub fn processInfoPlist(a: Allocator, t: Target, env: ?*const std.process.EnvMap, generated: ?plist.Plist) ![]const u8 {
    const root = if (t.info_plist) |f| try plist.readFile(a, try t.path(a, f)) else plist.Plist.newDict();
    defer root.deinit();
    if (!root.isDict()) return diag.fail("{s}: root must be a dictionary", .{t.info_plist orelse "info"});
    const defaults = [_][2][]const u8{
        .{ "CFBundleExecutable", "$(EXECUTABLE_NAME)" },
        .{ "CFBundleIdentifier", "$(PRODUCT_BUNDLE_IDENTIFIER)" },
        .{ "CFBundleName", "$(PRODUCT_NAME)" },
        .{ "CFBundleInfoDictionaryVersion", "6.0" },
        .{ "CFBundleShortVersionString", "$(MARKETING_VERSION)" },
        .{ "CFBundleVersion", "$(CURRENT_PROJECT_VERSION)" },
    };
    for (defaults) |kv| try root.setDefault(a, kv[0], try plist.newString(a, kv[1]));
    try root.setDefault(a, "CFBundlePackageType", try plist.newString(a, t.type.packageType()));
    if (t.type != .framework) try root.setDefault(a, "CFBundleDisplayName", try plist.newString(a, t.name));
    try root.setDefault(a, "CFBundleDevelopmentRegion", try plist.newString(a, "en"));
    try root.setDefault(a, "CFBundleSupportedPlatforms", try plist.parseCliValue(a, "platforms", "[\"iPhoneOS\"]"));
    try root.setDefault(a, "DTPlatformName", try plist.newString(a, "iphoneos"));
    const family = plist.c.plist_new_array();
    var families = std.mem.splitScalar(u8, t.device_family, ',');
    while (families.next()) |f| _ = plist.c.plist_array_append_item(family, plist.c.plist_new_int(try std.fmt.parseInt(i64, f, 10)));
    try root.setDefault(a, "UIDeviceFamily", family);
    // `info:` keys win; a null value (`Key: ~`) removes the key.
    if (t.info) |m| for (m.keys, m.values) |k, v| {
        if (v == .null) try root.remove(a, k) else try root.set(a, k, try ynodeToPlist(a, k, v));
    };
    if (t.type == .app) {
        try root.setDefault(a, "LSRequiresIPhoneOS", plist.c.plist_new_bool(1));
        try root.setDefault(a, "UISupportedInterfaceOrientations", try plist.parseCliValue(a, "orientations", "[\"UIInterfaceOrientationPortrait\"]"));
        // Without a launch storyboard, iOS needs a launch-screen dictionary.
        if (try root.get(a, "UILaunchStoryboardName") == null)
            try root.setDefault(a, "UILaunchScreen", plist.c.plist_new_dict());
    }
    try root.set(a, "MinimumOSVersion", try plist.newString(a, t.min_ios));
    if (generated) |g| {
        var it: plist.c.plist_dict_iter = null;
        plist.c.plist_dict_new_iter(g.node, &it);
        defer plist.c.plist_dict_free_iter(it);
        while (true) {
            var key: [*c]u8 = null;
            var val: plist.c.plist_t = null;
            plist.c.plist_dict_next_item(g.node, it, &key, &val);
            if (val == null) break;
            defer plist.c.plist_mem_free(key);
            try root.set(a, std.mem.span(key), plist.c.plist_copy(val));
        }
    }
    var vars = try buildVars(a, t);
    try plist.expand(a, root.node, &vars, env);
    for ([_][2][]const u8{ .{ "CFBundleExecutable", t.name }, .{ "CFBundleIdentifier", t.bundle_id }, .{ "CFBundlePackageType", t.type.packageType() } }) |expected| {
        const value = (try root.getString(a, expected[0])) orelse return diag.fail("{s}: {s} must be a string", .{ t.name, expected[0] });
        if (!std.mem.eql(u8, value, expected[1])) return diag.fail("{s}: {s} is '{s}', expected '{s}'; configure identity on the target, not in info", .{ t.name, expected[0], value, expected[1] });
    }
    return root.toXml(a);
}

test "YAML entitlement map is expanded and preserves bool and array types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try @import("config.zig").parse(a, "targets:\n  - name: Bare\n    bundle_id: com.example.bare\n    entitlements:\n      get-task-allow: true\n      keychain-access-groups: [\"$(PRODUCT_BUNDLE_IDENTIFIER)\"]\n", "/project/idlproj.yml");
    const xml = (try entitlements(a, cfg.targets[0], null)).?;
    const value = try plist.parse(xml);
    defer value.deinit();
    try std.testing.expectEqual(plist.c.PLIST_BOOLEAN, plist.c.plist_get_node_type(try value.get(a, "get-task-allow")));
    try std.testing.expectEqualStrings("com.example.bare", plist.stringOf(plist.c.plist_array_get_item(try value.get(a, "keychain-access-groups"), 0)).?);
}

/// No implicit capabilities: absent entitlements means no entitlement file.
pub fn entitlements(a: Allocator, t: Target, env: ?*const std.process.EnvMap) !?[]const u8 {
    if (t.entitlements == null and t.entitlement_values == null) return null;
    const root = if (t.entitlements) |f| try plist.readFile(a, try t.path(a, f)) else plist.Plist.newDict();
    defer root.deinit();
    if (!root.isDict()) return diag.fail("entitlements must be a dictionary", .{});
    if (t.entitlement_values) |m| for (m.keys, m.values) |k, v| try root.set(a, k, try ynodeToPlist(a, k, v));
    var vars = try buildVars(a, t);
    try plist.expand(a, root.node, &vars, env);
    return try root.toXml(a);
}

test "metadata identity overrides must agree with the target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try @import("config.zig").parse(a, "targets:\n  - name: App\n    bundle_id: com.example.app\n    info:\n      CFBundleExecutable: Missing\n", "/project/idlproj.yml");
    try std.testing.expectError(error.Invalid, processInfoPlist(a, cfg.targets[0], null, null));
}
