//! `idlproj.yml` loader. One file configures the toolchain and every target;
//! keys under `defaults:` apply to all targets unless a target overrides them.
const std = @import("std");
const ynode = @import("ynode.zig");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const pbxproj = @import("pbxproj.zig");

const Allocator = std.mem.Allocator;
const Node = ynode.Node;

pub const file_name = "idlproj.yml";

pub const Builder = enum { direct, xtool };

pub const ToolchainConfig = struct {
    sdk_bundle: []const u8 = "~/.swiftpm/swift-sdks/darwin.artifactbundle",
    /// Optional explicit iPhoneOS.sdk; otherwise the newest one in the bundle.
    sdk: ?[]const u8 = null,
    swiftly_bin: []const u8 = "~/.local/share/swiftly/bin",
    cc: []const u8 = "clang",
    cxx: []const u8 = "clang++",
    swiftc: []const u8 = "swiftc",
    xtool: []const u8 = "xtool",
    /// ldid path or command name on PATH.
    ldid: []const u8 = "ldid",
    /// Asset catalog compiler (tools/idl-actool, AssetKit). Path or command name;
    /// also looked up next to the idl executable.
    actool: []const u8 = "idl-actool",
    /// 0 = number of CPUs.
    jobs: usize = 0,
    /// Jimpactor data dir (relaunch.port, ipc.token). Default: $XDG_CONFIG_HOME/Jimpactor or ~/.config/Jimpactor.
    jimpactor_dir: ?[]const u8 = null,
};

pub const Target = struct {
    name: []const u8,
    /// Absolute target directory; all target paths are relative to it.
    dir: []const u8,
    builder: Builder = .direct,
    bundle_id: []const u8,
    min_ios: []const u8 = "16.0",
    arch: []const u8 = "arm64",
    opt: []const u8 = "-Os",
    debug_symbols: bool = false,
    strict: bool = false,
    /// Selected profile; null preserves the unprofiled legacy output paths.
    profile: ?[]const u8 = null,
    variants: ?*const [2]Target = null,
    configurations: ?ynode.Map = null,
    swift_opt: []const u8 = "-O",
    build_dir: []const u8 = "build",
    version: []const u8 = "1.0",
    build_number: []const u8 = "1",
    swift_version: []const u8 = "5.0",
    device_family: []const u8 = "1,2",
    app_icon: []const u8 = "AppIcon",
    sources: []const []const u8 = &.{"Sources"},
    resources: []const []const u8 = &.{},
    info_plist: ?[]const u8 = null,
    /// Keys merged into the processed Info.plist (`$(VAR)` expanded).
    info: ?ynode.Map = null,
    /// Extra `$(VAR)` values for Info.plist expansion.
    plist_vars: ?ynode.Map = null,
    entitlements: ?[]const u8 = null,
    entitlement_values: ?ynode.Map = null,
    frameworks: []const []const u8 = &.{ "UIKit", "Foundation" },
    weak_frameworks: []const []const u8 = &.{},
    libraries: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
    include_dirs: []const []const u8 = &.{},
    cflags: []const []const u8 = &.{},
    swiftflags: []const []const u8 = &.{},
    ldflags: []const []const u8 = &.{},
    bridging_header: ?[]const u8 = null,
    /// Ad-hoc sign with ldid (direct) / `xtool --sign` (xtool). Default: direct only.
    sign: ?bool = null,
    xcodeproj: bool = false,
    compile_commands: bool = false,
    /// xtool builder only.
    configuration: []const u8 = "release",
    package_swift: bool = true,

    pub fn infoPath(t: Target) []const u8 {
        if (t.profile) |p| return if (std.mem.eql(u8, p, "debug")) ".idl/debug/Info.plist" else ".idl/release/Info.plist";
        return ".idl/Info.plist";
    }

    pub fn entitlementsPath(t: Target) ?[]const u8 {
        if (t.entitlements == null and t.entitlement_values == null) return null;
        if (t.profile) |p| return if (std.mem.eql(u8, p, "debug")) ".idl/debug/Entitlements.plist" else ".idl/release/Entitlements.plist";
        return ".idl/Entitlements.plist";
    }

    fn pbxProfile(t: Target) pbxproj.Profile {
        return .{ .bundle_id = t.bundle_id, .info_plist = t.infoPath(), .entitlements = t.entitlementsPath(), .opt = t.opt, .swift_opt = t.swift_opt, .debug_symbols = t.debug_symbols, .defines = t.defines, .cflags = t.cflags, .swiftflags = t.swiftflags, .ldflags = t.ldflags, .output_dir = t.build_dir, .sign = t.signs() };
    }

    pub fn manifest(t: Target) pbxproj.Manifest {
        return .{
            .name = t.name,
            .bundle_id = t.bundle_id,
            .deployment_target = t.min_ios,
            .marketing_version = t.version,
            .build_number = t.build_number,
            .swift_version = t.swift_version,
            .device_family = t.device_family,
            .app_icon = t.app_icon,
            .info_plist = t.infoPath(),
            .entitlements = t.entitlementsPath(),
            .profiles = if (t.variants) |v| .{ v[0].pbxProfile(), v[1].pbxProfile() } else null,
            .frameworks = t.frameworks,
            .sources = t.sources,
            .resources = t.resources,
        };
    }

    pub fn signs(t: Target) bool {
        return t.sign orelse (t.builder == .direct);
    }

    pub fn path(t: Target, a: Allocator, rel: []const u8) ![]const u8 {
        return fsutil.join(a, t.dir, rel);
    }

    pub fn buildPath(t: Target, a: Allocator) ![]const u8 {
        return t.path(a, t.build_dir);
    }

    pub fn ipaPath(t: Target, a: Allocator) ![]const u8 {
        return switch (t.builder) {
            .direct => std.fmt.allocPrint(a, "{s}/{s}.ipa", .{ try t.buildPath(a), t.name }),
            .xtool => if (t.profile != null) std.fmt.allocPrint(a, "{s}/{s}.ipa", .{ try t.buildPath(a), t.name }) else std.fmt.allocPrint(a, "{s}/xtool/{s}.ipa", .{ t.dir, t.name }),
        };
    }
};

pub const Config = struct {
    /// Absolute path of idlproj.yml and its directory.
    path: []const u8,
    root: []const u8,
    toolchain: ToolchainConfig,
    targets: []Target,

    pub fn select(c: Config, a: Allocator, names: []const []const u8) ![]const Target {
        if (names.len == 0) return c.targets;
        var out = std.ArrayList(Target).init(a);
        outer: for (names) |n| {
            for (c.targets) |t| if (std.mem.eql(u8, t.name, n)) {
                try out.append(t);
                continue :outer;
            };
            var known = std.ArrayList([]const u8).init(a);
            for (c.targets) |t| try known.append(t.name);
            return diag.fail("unknown target '{s}' (known: {s})", .{ n, try std.mem.join(a, ", ", known.items) });
        }
        return out.items;
    }
};

// ------------------------------------------------------------- discovery

/// Walk up from `start` looking for idlproj.yml.
pub fn find(a: Allocator, start: []const u8) ![]const u8 {
    var dir: []const u8 = try std.fs.cwd().realpathAlloc(a, start);
    while (true) {
        const candidate = try std.fs.path.join(a, &.{ dir, file_name });
        if (fsutil.kind(candidate) == .file) return candidate;
        dir = std.fs.path.dirname(dir) orelse return diag.fail("no {s} found in {s} or any parent directory (run `idl init`)", .{ file_name, start });
    }
}

// ---------------------------------------------------------------- loading

const target_keys = [_][]const u8{
    "debug_symbols",   "strict",           "configurations",
    "name",            "dir",              "builder",
    "bundle_id",       "min_ios",          "arch",
    "opt",             "swift_opt",        "build_dir",
    "version",         "build_number",     "swift_version",
    "device_family",   "app_icon",         "sources",
    "resources",       "info_plist",       "info",
    "plist_vars",      "entitlements",     "frameworks",
    "weak_frameworks", "libraries",        "defines",
    "include_dirs",    "cflags",           "swiftflags",
    "ldflags",         "bridging_header",  "sign",
    "xcodeproj",       "compile_commands", "configuration",
    "package_swift",
};
const default_forbidden = [_][]const u8{ "name", "dir", "bundle_id" };
const toolchain_keys = [_][]const u8{ "sdk_bundle", "sdk", "swiftly_bin", "cc", "cxx", "swiftc", "xtool", "ldid", "actool", "jobs", "jimpactor_dir" };
const top_keys = [_][]const u8{ "toolchain", "defaults", "targets", "configurations" };

fn checkKeys(m: ynode.Map, allowed: []const []const u8, where: []const u8) !void {
    outer: for (m.keys) |k| {
        for (allowed) |ok| if (std.mem.eql(u8, k, ok)) continue :outer;
        return diag.fail("{s}: unknown key '{s}'", .{ where, k });
    }
}

const Ctx = struct {
    a: Allocator,
    where: []const u8,

    fn str(c: Ctx, n: Node, key: []const u8) ![]const u8 {
        return switch (n) {
            .scalar => |s| s.text,
            else => diag.fail("{s}: '{s}' must be a string", .{ c.where, key }),
        };
    }

    fn strList(c: Ctx, n: Node, key: []const u8) ![]const []const u8 {
        switch (n) {
            .null => return &.{},
            .list => |items| {
                const out = try c.a.alloc([]const u8, items.len);
                for (items, out) |item, *o| {
                    o.* = try c.str(item, key);
                    if (o.len == 0) return diag.fail("{s}: '{s}' entries must be non-empty strings", .{ c.where, key });
                }
                return out;
            },
            else => return diag.fail("{s}: '{s}' must be a list of strings", .{ c.where, key }),
        }
    }

    fn boolean(c: Ctx, n: Node, key: []const u8) !bool {
        const s = try c.str(n, key);
        for ([_][]const u8{ "true", "yes", "on" }) |t| if (std.ascii.eqlIgnoreCase(s, t)) return true;
        for ([_][]const u8{ "false", "no", "off" }) |f| if (std.ascii.eqlIgnoreCase(s, f)) return false;
        return diag.fail("{s}: '{s}' must be true or false", .{ c.where, key });
    }

    fn map(c: Ctx, n: Node, key: []const u8) !?ynode.Map {
        return switch (n) {
            .null => null,
            .map => |m| m,
            else => diag.fail("{s}: '{s}' must be a mapping", .{ c.where, key }),
        };
    }
};

fn isVersion(s: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        parts += 1;
        if (p.len == 0 or parts > 3) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return parts >= 1;
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-')) return false;
    return true;
}

fn isBundleId(s: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        parts += 1;
        if (p.len == 0 or !std.ascii.isAlphanumeric(p[0])) return false;
        for (p) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return parts >= 2;
}

fn isFramework(s: []const u8) bool {
    const base = if (std.mem.endsWith(u8, s, ".framework")) s[0 .. s.len - ".framework".len] else s;
    if (base.len == 0 or !std.ascii.isAlphabetic(base[0])) return false;
    for (base) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn isDeviceFamily(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |p| {
        if (p.len == 0) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn loadTarget(a: Allocator, root: []const u8, index: usize, node: Node, defaults: ?ynode.Map) !Target {
    const m = switch (node) {
        .map => |m| m,
        else => return diag.fail("targets[{d}] must be a mapping", .{index}),
    };
    var c: Ctx = .{ .a = a, .where = try std.fmt.allocPrint(a, "targets[{d}]", .{index}) };
    try checkKeys(m, &target_keys, c.where);
    const name_node = m.get("name") orelse return diag.fail("{s}: 'name' is required", .{c.where});
    const name = try c.str(name_node, "name");
    if (!isName(name)) return diag.fail("{s}: invalid target name '{s}'; use letters, numbers, dot, underscore, or hyphen", .{ c.where, name });
    c.where = try std.fmt.allocPrint(a, "target '{s}'", .{name});

    const dir_rel = if (m.get("dir")) |d| try c.str(d, "dir") else ".";
    var t: Target = .{
        .name = name,
        .dir = try std.fs.path.resolve(a, &.{ root, dir_rel }),
        .bundle_id = try c.str(m.get("bundle_id") orelse return diag.fail("{s}: 'bundle_id' is required", .{c.where}), "bundle_id"),
    };

    inline for (std.meta.fields(Target)) |field| {
        if (comptime (std.mem.eql(u8, field.name, "name") or std.mem.eql(u8, field.name, "dir") or std.mem.eql(u8, field.name, "bundle_id") or std.mem.eql(u8, field.name, "profile") or std.mem.eql(u8, field.name, "variants"))) continue;
        const value = m.get(field.name) orelse if (defaults) |d| d.get(field.name) else null;
        if (value) |v| {
            if (comptime std.mem.eql(u8, field.name, "entitlements")) {
                if (v == .map) t.entitlement_values = v.map else t.entitlements = if (v == .null) null else try c.str(v, field.name);
            } else @field(t, field.name) = switch (field.type) {
                []const u8 => try c.str(v, field.name),
                ?[]const u8 => if (v == .null) null else try c.str(v, field.name),
                []const []const u8 => try c.strList(v, field.name),
                bool => try c.boolean(v, field.name),
                ?bool => if (v == .null) null else try c.boolean(v, field.name),
                ?ynode.Map => try c.map(v, field.name),
                Builder => std.meta.stringToEnum(Builder, try c.str(v, field.name)) orelse
                    return diag.fail("{s}: builder must be 'direct' or 'xtool'", .{c.where}),
                else => @compileError("unhandled target field type: " ++ @typeName(field.type)),
            };
        }
    }

    if (!isBundleId(t.bundle_id)) return diag.fail("{s}: invalid bundle_id '{s}'", .{ c.where, t.bundle_id });
    for ([_]struct { []const u8, []const u8 }{
        .{ "min_ios", t.min_ios },           .{ "version", t.version },
        .{ "build_number", t.build_number }, .{ "swift_version", t.swift_version },
    }) |kv| if (!isVersion(kv[1])) return diag.fail("{s}: '{s}' must be a numeric version string (got '{s}')", .{ c.where, kv[0], kv[1] });
    if (!isDeviceFamily(t.device_family)) return diag.fail("{s}: device_family must be a comma-separated list of integers", .{c.where});
    if (!isName(t.app_icon)) return diag.fail("{s}: app_icon must be a simple asset name", .{c.where});
    for (t.frameworks) |f| if (!isFramework(f)) return diag.fail("{s}: invalid framework name '{s}'", .{ c.where, f });
    for (t.weak_frameworks) |f| if (!isFramework(f)) return diag.fail("{s}: invalid framework name '{s}'", .{ c.where, f });
    if (t.sources.len == 0) return diag.fail("{s}: 'sources' must not be empty", .{c.where});
    for (t.sources) |s| try fsutil.validateRelativePath(s, "source path");
    for (t.resources) |r| try fsutil.validateRelativePath(r, "resource path");
    if (t.info_plist) |f| try fsutil.validateRelativePath(f, "info_plist");
    if (t.entitlements) |e| try fsutil.validateRelativePath(e, "entitlements");
    if (t.bridging_header) |h| try fsutil.validateRelativePath(h, "bridging_header");
    try fsutil.validateRelativePath(t.build_dir, "build_dir");
    if (!std.mem.eql(u8, t.configuration, "debug") and !std.mem.eql(u8, t.configuration, "release"))
        return diag.fail("{s}: configuration must be 'debug' or 'release'", .{c.where});
    return t;
}

pub fn parse(a: Allocator, source: []const u8, path: []const u8) !Config {
    return parseConfiguration(a, source, path, null);
}

/// Maps merge recursively, sequences replace, null explicitly clears a value.
fn merge(a: Allocator, base: ynode.Map, overlay: ynode.Map) anyerror!ynode.Map {
    var result = std.StringArrayHashMap(Node).init(a);
    for (base.keys, base.values) |k, v| try result.put(k, v);
    for (overlay.keys, overlay.values) |k, v| {
        var value = v;
        if (result.get(k)) |old| if (old == .map and v == .map) {
            value = .{ .map = try merge(a, old.map, v.map) };
        };
        try result.put(k, value);
    }
    return .{ .keys = result.keys(), .values = result.values() };
}

const empty_map: ynode.Map = .{ .keys = &.{}, .values = &.{} };

fn configurationMap(a: Allocator, node: ?Node, where: []const u8) !ynode.Map {
    const c: Ctx = .{ .a = a, .where = where };
    const m = (try c.map(node orelse .null, "configurations")) orelse return empty_map;
    try checkKeys(m, &.{ "debug", "release" }, where);
    for (m.keys, m.values) |k, v| {
        const settings = (try c.map(v, k)) orelse return diag.fail("{s}.{s} must be a mapping", .{ where, k });
        try checkKeys(settings, &.{ "bundle_id", "opt", "swift_opt", "debug_symbols", "defines", "info", "entitlements", "plist_vars", "build_dir", "cflags", "swiftflags", "ldflags", "strict", "sign" }, where);
        for ([_][]const u8{ "name", "dir", "builder", "configurations", "configuration" }) |reserved|
            if (settings.get(reserved) != null) return diag.fail("{s}: '{s}' is not a profile override", .{ where, reserved });
    }
    return m;
}

fn profileTarget(a: Allocator, root: []const u8, index: usize, base: ynode.Map, global: ynode.Map, name: []const u8) !Target {
    const builtin_source = if (std.mem.eql(u8, name, "debug"))
        "opt: -O0\nswift_opt: -Onone\ndebug_symbols: true\n"
    else
        "opt: -Os\nswift_opt: -O\ndebug_symbols: false\n";
    var settings = try merge(a, base, (try ynode.parse(a, builtin_source, "builtin profile")).map);
    // Disable a YAML debug entitlement in release without manufacturing an
    // entitlement file for applications that requested no capabilities.
    if (std.mem.eql(u8, name, "release")) {
        if (base.get("entitlements")) |v| if (v == .map and v.map.get("get-task-allow") != null) {
            const overrides = (try ynode.parse(a, "entitlements:\n  get-task-allow: false\n", "release entitlements")).map;
            settings = try merge(a, settings, overrides);
        };
    }
    if (global.get(name)) |v| settings = try merge(a, settings, v.map);
    const local = try configurationMap(a, base.get("configurations"), "target configurations");
    if (local.get(name)) |v| settings = try merge(a, settings, v.map);
    var t = try loadTarget(a, root, index, .{ .map = settings }, null);
    t.profile = name;
    t.configuration = name;
    t.build_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ t.build_dir, name });
    if (std.mem.eql(u8, name, "debug")) {
        var flags = std.ArrayList([]const u8).init(a);
        try flags.appendSlice(t.defines);
        var has_debug = false;
        for (t.defines) |d| if (std.mem.eql(u8, d, "DEBUG")) {
            has_debug = true;
        };
        if (!has_debug) try flags.append("DEBUG");
        t.defines = flags.items;
    }
    return t;
}

pub fn parseConfiguration(a: Allocator, source: []const u8, path: []const u8, profile: ?[]const u8) !Config {
    if (profile) |name| if (!fsutil.oneOf(name, &.{ "debug", "release" }))
        return diag.fail("unknown configuration '{s}'; expected debug or release", .{name});
    const root_node = try ynode.parse(a, source, path);
    const top = switch (root_node) {
        .map => |m| m,
        .null => return diag.fail("{s} is empty", .{path}),
        else => return diag.fail("{s}: top level must be a mapping", .{path}),
    };
    try checkKeys(top, &top_keys, path);
    const root = std.fs.path.dirname(path) orelse ".";
    var cfg: Config = .{ .path = path, .root = root, .toolchain = .{}, .targets = &.{} };

    const c: Ctx = .{ .a = a, .where = "toolchain" };
    if (try c.map(top.get("toolchain") orelse .null, "toolchain")) |tc| {
        try checkKeys(tc, &toolchain_keys, "toolchain");
        inline for (std.meta.fields(ToolchainConfig)) |field| if (tc.get(field.name)) |v| {
            @field(cfg.toolchain, field.name) = switch (field.type) {
                []const u8 => try c.str(v, field.name),
                ?[]const u8 => if (v == .null) null else try c.str(v, field.name),
                usize => std.fmt.parseInt(usize, try c.str(v, field.name), 10) catch
                    return diag.fail("toolchain: '{s}' must be a non-negative integer", .{field.name}),
                else => @compileError("unhandled toolchain field type"),
            };
        };
    }

    const defaults = try (Ctx{ .a = a, .where = "defaults" }).map(top.get("defaults") orelse .null, "defaults");
    if (defaults) |d| {
        try checkKeys(d, &target_keys, "defaults");
        for (default_forbidden) |k| if (d.get(k) != null) return diag.fail("defaults: '{s}' must be set per target", .{k});
    }

    const global_profiles = try configurationMap(a, top.get("configurations"), "configurations");
    const targets_node = top.get("targets") orelse return diag.fail("{s}: 'targets' is required", .{path});
    const items = switch (targets_node) {
        .list => |l| l,
        else => return diag.fail("{s}: 'targets' must be a list", .{path}),
    };
    if (items.len == 0) return diag.fail("{s}: 'targets' must not be empty", .{path});
    const targets = try a.alloc(Target, items.len);
    for (items, targets, 0..) |item, *t, i| {
        if (item != .map) return diag.fail("targets[{d}] must be a mapping", .{i});
        const base = try merge(a, defaults orelse empty_map, item.map);
        const variants = try a.create([2]Target);
        variants[0] = try profileTarget(a, root, i, base, global_profiles, "debug");
        variants[1] = try profileTarget(a, root, i, base, global_profiles, "release");
        t.* = if (profile) |name| variants[if (std.mem.eql(u8, name, "debug")) @as(usize, 0) else 1] else try loadTarget(a, root, i, .{ .map = base }, null);
        t.variants = variants;
        for (targets[0..i]) |prev| if (std.mem.eql(u8, prev.name, t.name)) return diag.fail("duplicate target name '{s}'", .{t.name});
    }
    cfg.targets = targets;
    return cfg;
}

pub fn load(a: Allocator, path: []const u8) !Config {
    return loadConfiguration(a, path, null);
}

pub fn loadConfiguration(a: Allocator, path: []const u8, profile: ?[]const u8) !Config {
    const abs = try std.fs.cwd().realpathAlloc(a, path);
    const source = std.fs.cwd().readFileAlloc(a, abs, 4 << 20) catch |err|
        return diag.fail("cannot read {s}: {s}", .{ path, @errorName(err) });
    return parseConfiguration(a, source, abs, profile);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "defaults merge and validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parse(a,
        \\toolchain:
        \\  jobs: 4
        \\defaults:
        \\  min_ios: 15.4
        \\  compile_commands: true
        \\targets:
        \\  - name: One
        \\    dir: apps/one
        \\    bundle_id: com.example.one
        \\    frameworks: [UIKit, Foundation, AVFoundation]
        \\  - name: Two
        \\    builder: xtool
        \\    bundle_id: com.example.two
        \\    min_ios: "17.0"
        \\    info:
        \\      CFBundleDisplayName: Two
        \\
    , "/proj/idlproj.yml");
    try testing.expectEqual(@as(usize, 4), cfg.toolchain.jobs);
    try testing.expectEqualStrings("/proj/apps/one", cfg.targets[0].dir);
    try testing.expectEqualStrings("15.4", cfg.targets[0].min_ios);
    try testing.expect(cfg.targets[0].compile_commands);
    try testing.expectEqual(@as(usize, 3), cfg.targets[0].frameworks.len);
    try testing.expectEqual(Builder.xtool, cfg.targets[1].builder);
    try testing.expectEqualStrings("17.0", cfg.targets[1].min_ios);
    try testing.expectEqualStrings("Two", cfg.targets[1].info.?.get("CFBundleDisplayName").?.scalar.text);
}

test "rejects bad configs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "targets:\n  - name: ../Escape\n    bundle_id: com.example.a\n", "invalid target name" },
        .{ "targets:\n  - name: Bad\n    bundle_id: not a bundle id!\n", "invalid bundle_id" },
        .{ "targets:\n  - name: Bad\n    bundle_id: com.example.bad\n    sources: Sources\n", "must be a list of strings" },
        .{ "targets:\n  - name: Bad\n    bundle_id: com.example.bad\n    frameworks: UIKit\n", "must be a list of strings" },
        .{ "targets:\n  - name: Bad\n    bundle_id: com.example.bad\n    min_ios: sixteen\n", "numeric version" },
        .{ "targets:\n  - name: Bad\n    bundle_id: com.example.bad\n    sorces: [x]\n", "unknown key 'sorces'" },
        .{ "targets:\n  - name: Bad\n    bundle_id: com.example.bad\n    sources: [../x]\n", "must stay within" },
        .{ "defaults:\n  bundle_id: com.example.x\ntargets:\n  - name: A\n    bundle_id: com.example.a\n", "must be set per target" },
        .{ "targets:\n  - name: A\n    bundle_id: com.example.a\n  - name: A\n    bundle_id: com.example.b\n", "duplicate target" },
    };
    for (cases) |case| {
        try testing.expectError(error.Invalid, parse(a, case[0], "/p/idlproj.yml"));
        testing.expect(std.mem.indexOf(u8, diag.msg, case[1]) != null) catch |err| {
            std.debug.print("expected '{s}' in '{s}'\n", .{ case[1], diag.msg });
            return err;
        };
    }
}

test "debug and release profiles isolate outputs and deep merge metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\defaults:
        \\  defines: [BASE]
        \\  info:
        \\    NSCameraUsageDescription: Camera
        \\configurations:
        \\  debug:
        \\    bundle_id: com.example.debug
        \\    entitlements:
        \\      get-task-allow: true
        \\  release:
        \\    entitlements:
        \\      get-task-allow: false
        \\targets:
        \\  - name: App
        \\    bundle_id: com.example.app
        \\    info:
        \\      CFBundleDisplayName: App
        \\    configurations:
        \\      debug:
        \\        info:
        \\          CFBundleDisplayName: App Debug
    ;
    const d = (try parseConfiguration(a, source, "/project/idlproj.yml", "debug")).targets[0];
    const rel = (try parseConfiguration(a, source, "/project/idlproj.yml", "release")).targets[0];
    try testing.expectEqualStrings("-O0", d.opt);
    try testing.expect(d.debug_symbols);
    try testing.expectEqualStrings("com.example.debug", d.bundle_id);
    try testing.expectEqualStrings("App Debug", d.info.?.get("CFBundleDisplayName").?.scalar.text);
    try testing.expect(d.info.?.get("NSCameraUsageDescription") != null);
    try testing.expectEqualStrings("build/debug", d.build_dir);
    try testing.expectEqualStrings("build/release", rel.build_dir);
    try testing.expectEqualStrings("false", rel.entitlement_values.?.get("get-task-allow").?.scalar.text);
    try testing.expectError(error.Invalid, parseConfiguration(a, source, "/project/idlproj.yml", "typo"));
}
