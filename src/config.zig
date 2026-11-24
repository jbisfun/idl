//! `idlproj.yml` loader. One file configures the toolchain and every target;
//! keys under `defaults:` apply to all targets unless a target overrides them.
const std = @import("std");
const sys = @import("sys.zig");
const ynode = @import("ynode.zig");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const pbxproj = @import("pbxproj.zig");

const Allocator = std.mem.Allocator;
const Node = ynode.Node;

pub const file_name = "idlproj.yml";

pub const Builder = enum { direct, xtool };

/// What a target produces. Only `app` targets are packaged as IPAs; the other
/// kinds are built for, linked into and/or embedded in an app via `link` and
/// `embed`. `test` targets are built and run on the Linux host by `idl test`.
pub const Kind = enum {
    app,
    /// Dynamic framework: `<name>.framework` (install name `@rpath/<name>.framework/<name>`).
    framework,
    /// Loose dynamic library: `<name>.dylib` (install name `@rpath/<name>.dylib`).
    dylib,
    /// App extension: `<name>.appex`, embedded under `PlugIns/`.
    appex,
    /// Objects + Swift module only; linked directly into dependents.
    static,
    /// Unit tests compiled for and run on the Linux host (`idl test`), together
    /// with the sources of the static targets it `link`s. Swift: XCTest /
    /// swift-testing through a generated SwiftPM package; C/C++: an executable
    /// whose exit status is the result.
    @"test",

    pub fn bundled(k: Kind) bool {
        return k == .app or k == .framework or k == .appex;
    }

    pub fn packageType(k: Kind) []const u8 {
        return switch (k) {
            .framework => "FMWK",
            .appex => "XPC!",
            else => "APPL",
        };
    }
};

/// `idl lint` settings (per target; `defaults:` maps merge).
pub const LintConfig = struct {
    /// Extra clang warning flags for the compiler pass (the target's own `-w`,
    /// `-Werror` and depfile flags are dropped).
    warnings: []const []const u8 = &.{"-Wall"},
    /// Extra swiftc flags for the Swift type-check pass (warnings are not suppressed).
    swift_flags: []const []const u8 = &.{},
    /// Source paths (relative to the target dir; `*` globs per component) whose
    /// diagnostics are dropped, e.g. vendored code.
    exclude: []const []const u8 = &.{},
    /// clang-tidy pass. null = run when clang-tidy is installed.
    clang_tidy: ?bool = null,
    /// clang static analyzer pass (`clang --analyze`).
    analyze: bool = false,
    /// `swift-format lint` (style rules from the generated config). Off by default.
    swift_format: bool = false,
    /// clang-tidy `Checks` (joined with commas). Empty = idl's default set.
    clang_tidy_checks: []const []const u8 = &.{},
};

/// `idl fmt` settings. idl generates the clang-format / swift-format
/// configurations from these; there are no hand-written style files.
pub const FormatConfig = struct {
    /// Paths (relative to the target dir; `*` globs per component) never formatted.
    exclude: []const []const u8 = &.{},
    /// Indent width for every language.
    indent: []const u8 = "4",
    /// Maximum line length; 0 = never re-wrap lines.
    line_length: []const u8 = "0",
    /// Extra clang-format options (clang-format YAML keys), override the above.
    clang_format: ?ynode.Map = null,
    /// Extra swift-format options (its JSON keys), deep-merged over the above.
    swift_format: ?ynode.Map = null,
    /// `idl gen` also writes .clang-format, .clang-tidy and .swift-format into
    /// the target directory for editors (clangd, sourcekit-lsp).
    editor_configs: bool = false,
};

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
    /// App Intents metadata processor (Apple's, or the open re-appintentsmetadataprocessor).
    /// Path or command name; needed by targets with `app_intents`.
    appintents: []const u8 = "appintentsmetadataprocessor",
    /// 0 = number of CPUs.
    jobs: usize = 0,
    /// Jimpactor data dir (relaunch.port, ipc.token). Default: $XDG_CONFIG_HOME/Jimpactor or ~/.config/Jimpactor.
    jimpactor_dir: ?[]const u8 = null,
    /// Optional quality tools (`idl fmt` / `idl lint`), path or command name.
    clang_format: []const u8 = "clang-format",
    clang_tidy: []const u8 = "clang-tidy",
    swift_format: []const u8 = "swift-format",
};

/// Frameworks a host (Linux) test target or the code it tests may use: the
/// Swift toolchain's corelibs. Everything else is iOS-only.
pub const host_frameworks = [_][]const u8{ "Foundation", "FoundationEssentials", "FoundationNetworking", "FoundationXML", "Dispatch", "XCTest", "Testing" };

pub const Target = struct {
    name: []const u8,
    /// Absolute target directory; all target paths are relative to it.
    dir: []const u8,
    builder: Builder = .direct,
    type: Kind = .app,
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
    /// xtool builder only: PNG copied to the app root as CFBundleIconFile.
    icon: ?[]const u8 = null,
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
    /// `-iquote` directories: only `#include "..."` searches them (Xcode header-map style).
    quote_include_dirs: []const []const u8 = &.{},
    cflags: []const []const u8 = &.{},
    swiftflags: []const []const u8 = &.{},
    ldflags: []const []const u8 = &.{},
    bridging_header: ?[]const u8 = null,
    /// `-F` directories for clang, swiftc and the linker.
    framework_dirs: []const []const u8 = &.{},
    /// Project targets (framework/dylib/static) this target links against.
    link: []const []const u8 = &.{},
    /// Project targets (framework/dylib/appex) copied into this app bundle.
    embed: []const []const u8 = &.{},
    /// Pass `-dead_strip` to the linker.
    dead_strip: bool = true,
    /// Extract App Intents metadata (Swift const values + appintentsmetadataprocessor)
    /// into `Metadata.appintents`; static targets hand their const values to the
    /// bundles linking them. null = when the target links AppIntents or WidgetKit.
    app_intents: ?bool = null,
    /// Commands (argv lists) run in order after an app's IPA is written. They
    /// run in the target directory with IDL_IPA, IDL_APP, IDL_BUILD_DIR and
    /// IDL_TARGET set. YAML: one argv list, or a list of argv lists.
    post_build: []const []const []const u8 = &.{},
    /// Commands (argv lists) `idl test` runs after the bundle checks.
    tests: []const []const []const u8 = &.{},
    lint: LintConfig = .{},
    format: FormatConfig = .{},
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

    /// Whether builds extract App Intents metadata; `explicit` tells a request
    /// (missing tool = error) from the WidgetKit/AppIntents default (warning).
    /// Static targets only emit const values; the bundles linking them extract.
    pub fn appIntents(t: Target) struct { enabled: bool, explicit: bool } {
        if (t.builder != .direct or t.type == .dylib or t.type == .@"test") return .{ .enabled = false, .explicit = false };
        if (t.app_intents) |v| return .{ .enabled = v, .explicit = v };
        for (t.frameworks) |f| if (fsutil.oneOf(f, &.{ "AppIntents", "AppIntents.framework", "WidgetKit", "WidgetKit.framework" }))
            return .{ .enabled = true, .explicit = false };
        return .{ .enabled = false, .explicit = false };
    }

    pub fn signs(t: Target) bool {
        if (t.type == .static or t.type == .@"test") return false;
        return t.sign orelse (t.builder == .direct);
    }

    /// File name of the product inside its container (bundle dir or dylib).
    pub fn productName(t: Target, a: Allocator) ![]const u8 {
        return switch (t.type) {
            .app => std.fmt.allocPrint(a, "{s}.app", .{t.name}),
            .framework => std.fmt.allocPrint(a, "{s}.framework", .{t.name}),
            .appex => std.fmt.allocPrint(a, "{s}.appex", .{t.name}),
            .dylib => std.fmt.allocPrint(a, "{s}.dylib", .{t.name}),
            .static, .@"test" => t.name,
        };
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
        var out: std.ArrayList(Target) = .empty;
        outer: for (names) |n| {
            for (c.targets) |t| if (std.mem.eql(u8, t.name, n)) {
                try out.append(a, t);
                continue :outer;
            };
            var known: std.ArrayList([]const u8) = .empty;
            for (c.targets) |t| try known.append(a, t.name);
            return diag.fail("unknown target '{s}' (known: {s})", .{ n, try std.mem.join(a, ", ", known.items) });
        }
        return out.items;
    }
};

// ------------------------------------------------------------- discovery

/// Walk up from `start` looking for idlproj.yml.
pub fn find(a: Allocator, start: []const u8) ![]const u8 {
    var dir: []const u8 = try sys.realpath(a, start);
    while (true) {
        const candidate = try std.Io.Dir.path.join(a, &.{ dir, file_name });
        if (fsutil.kind(candidate) == .file) return candidate;
        dir = std.Io.Dir.path.dirname(dir) orelse return diag.fail("no {s} found in {s} or any parent directory (run `idl init`)", .{ file_name, start });
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
    "package_swift",   "icon",             "type",
    "framework_dirs",  "link",             "embed",
    "dead_strip",      "post_build",       "quote_include_dirs",
    "tests",           "lint",             "format",
    "app_intents",
};
const default_forbidden = [_][]const u8{ "name", "dir", "bundle_id" };
const toolchain_keys = [_][]const u8{ "sdk_bundle", "sdk", "swiftly_bin", "cc", "cxx", "swiftc", "xtool", "ldid", "actool", "appintents", "jobs", "jimpactor_dir", "clang_format", "clang_tidy", "swift_format" };
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

    /// A settings mapping onto a struct of strings, string lists and (optional) bools.
    fn section(c: Ctx, comptime T: type, n: Node, key: []const u8) !T {
        var out: T = .{};
        const m = (try c.map(n, key)) orelse return out;
        const names = std.meta.fieldNames(T);
        try checkKeys(m, names, try std.fmt.allocPrint(c.a, "{s}.{s}", .{ c.where, key }));
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, FT| if (m.get(name)) |v| {
            @field(out, name) = switch (FT) {
                []const u8 => try c.str(v, name),
                ?ynode.Map => try c.map(v, name),
                []const []const u8 => try c.strList(v, name),
                bool => try c.boolean(v, name),
                ?bool => if (v == .null) null else try c.boolean(v, name),
                else => @compileError("unhandled section field type"),
            };
        };
        return out;
    }

    /// One argv list (`[cmd, arg]`) or a list of them (`[[cmd, arg], [cmd2]]`).
    fn commands(c: Ctx, n: Node, key: []const u8) ![]const []const []const u8 {
        switch (n) {
            .null => return &.{},
            .list => |items| {
                if (items.len == 0) return &.{};
                if (items[0] != .list) {
                    const one = try c.a.alloc([]const []const u8, 1);
                    one[0] = try c.strList(n, key);
                    return one;
                }
                const out = try c.a.alloc([]const []const u8, items.len);
                for (items, out) |item, *o| {
                    o.* = try c.strList(item, key);
                    if (o.len == 0) return diag.fail("{s}: '{s}' commands must not be empty", .{ c.where, key });
                }
                return out;
            },
            else => return diag.fail("{s}: '{s}' must be a command list ([cmd, args...]) or a list of them", .{ c.where, key }),
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
        .dir = try sys.resolve(a, &.{ root, dir_rel }),
        .bundle_id = "",
    };
    const kind_node = m.get("type") orelse if (defaults) |d| d.get("type") else null;
    if (kind_node) |k| t.type = std.meta.stringToEnum(Kind, try c.str(k, "type")) orelse
        return diag.fail("{s}: type must be app, framework, dylib, appex, static or test", .{c.where});
    if (m.get("post_build") orelse if (defaults) |d| d.get("post_build") else null) |pb| t.post_build = try c.commands(pb, "post_build");
    if (m.get("tests") orelse if (defaults) |d| d.get("tests") else null) |v| t.tests = try c.commands(v, "tests");
    if (m.get("lint") orelse if (defaults) |d| d.get("lint") else null) |v| t.lint = try c.section(LintConfig, v, "lint");
    if (m.get("format") orelse if (defaults) |d| d.get("format") else null) |v| t.format = try c.section(FormatConfig, v, "format");
    for ([_][]const u8{ t.format.indent, t.format.line_length }) |n| _ = std.fmt.parseInt(u16, n, 10) catch
        return diag.fail("{s}: format.indent and format.line_length must be non-negative integers", .{c.where});
    if (m.get("bundle_id")) |b| {
        t.bundle_id = try c.str(b, "bundle_id");
    } else if (t.type.bundled()) return diag.fail("{s}: 'bundle_id' is required", .{c.where});

    const target_info = @typeInfo(Target).@"struct";
    inline for (target_info.field_names, target_info.field_types) |field_name, field_type| {
        if (comptime (std.mem.eql(u8, field_name, "name") or std.mem.eql(u8, field_name, "dir") or std.mem.eql(u8, field_name, "bundle_id") or std.mem.eql(u8, field_name, "profile") or std.mem.eql(u8, field_name, "variants") or std.mem.eql(u8, field_name, "type") or std.mem.eql(u8, field_name, "post_build") or std.mem.eql(u8, field_name, "tests") or std.mem.eql(u8, field_name, "lint") or std.mem.eql(u8, field_name, "format"))) continue;
        const value = m.get(field_name) orelse if (defaults) |d| d.get(field_name) else null;
        if (value) |v| {
            if (comptime std.mem.eql(u8, field_name, "entitlements")) {
                if (v == .map) t.entitlement_values = v.map else t.entitlements = if (v == .null) null else try c.str(v, field_name);
            } else @field(t, field_name) = switch (field_type) {
                []const u8 => try c.str(v, field_name),
                ?[]const u8 => if (v == .null) null else try c.str(v, field_name),
                []const []const u8 => try c.strList(v, field_name),
                bool => try c.boolean(v, field_name),
                ?bool => if (v == .null) null else try c.boolean(v, field_name),
                ?ynode.Map => try c.map(v, field_name),
                Builder => std.meta.stringToEnum(Builder, try c.str(v, field_name)) orelse
                    return diag.fail("{s}: builder must be 'direct' or 'xtool'", .{c.where}),
                else => @compileError("unhandled target field type: " ++ @typeName(field_type)),
            };
        }
    }

    if ((t.bundle_id.len > 0 or t.type.bundled()) and !isBundleId(t.bundle_id)) return diag.fail("{s}: invalid bundle_id '{s}'", .{ c.where, t.bundle_id });
    if (t.type != .app) {
        if (t.builder != .direct) return diag.fail("{s}: only app targets can use builder: xtool", .{c.where});
        if (t.xcodeproj) return diag.fail("{s}: xcodeproj generation is only supported for app targets", .{c.where});
        if (t.embed.len > 0) return diag.fail("{s}: only app targets can embed other targets", .{c.where});
        if (t.post_build.len > 0) return diag.fail("{s}: post_build is only supported for app targets", .{c.where});
        if (t.tests.len > 0) return diag.fail("{s}: `tests:` commands are only supported for app targets{s}", .{ c.where, if (t.type == .@"test") "; a test target's own sources are its tests" else "" });
        if (!t.type.bundled() and (t.resources.len > 0 or t.info_plist != null or t.info != null or t.entitlements != null or t.entitlement_values != null))
            return diag.fail("{s}: {s} targets have no bundle (resources, info and entitlements are not allowed)", .{ c.where, @tagName(t.type) });
    }
    if (t.type == .@"test") {
        // The struct default (UIKit, Foundation) describes iOS targets.
        if (m.get("frameworks") == null) t.frameworks = &.{};
        try requireHostFrameworks(c.where, t, null);
        if (t.weak_frameworks.len > 0 or t.framework_dirs.len > 0) return diag.fail("{s}: test targets run on the Linux host; weak_frameworks and framework_dirs are iOS-only", .{c.where});
        if (t.bridging_header != null) return diag.fail("{s}: bridging_header is not supported for test targets (SwiftPM modules)", .{c.where});
        if (t.app_intents == true) return diag.fail("{s}: app_intents is not supported for test targets", .{c.where});
    }
    for (t.framework_dirs) |d| try fsutil.validateRelativePath(d, "framework_dirs");
    for (t.include_dirs) |d| try fsutil.validateRelativePath(d, "include_dirs");
    for (t.quote_include_dirs) |d| try fsutil.validateRelativePath(d, "quote_include_dirs");
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
    if (t.icon) |i| {
        try fsutil.validateRelativePath(i, "icon");
        if (t.builder != .xtool) return diag.fail("{s}: 'icon' is for xtool targets; direct targets take the app icon from an asset catalog", .{c.where});
        if (!std.ascii.endsWithIgnoreCase(i, ".png")) return diag.fail("{s}: icon must be a .png file", .{c.where});
    }
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
    var result: std.array_hash_map.String(Node) = .empty;
    for (base.keys, base.values) |k, v| try result.put(a, k, v);
    for (overlay.keys, overlay.values) |k, v| {
        var value = v;
        if (result.get(k)) |old| if (old == .map and v == .map) {
            value = .{ .map = try merge(a, old.map, v.map) };
        };
        try result.put(a, k, value);
    }
    return .{ .keys = result.keys(), .values = result.values() };
}

const empty_map: ynode.Map = .{ .keys = &.{}, .values = &.{} };

fn without(a: Allocator, m: ynode.Map, key: []const u8) !ynode.Map {
    var keys: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(Node) = .empty;
    for (m.keys, m.values) |k, v| if (!std.mem.eql(u8, k, key)) {
        try keys.append(a, k);
        try values.append(a, v);
    };
    return .{ .keys = keys.items, .values = values.items };
}

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
        var flags: std.ArrayList([]const u8) = .empty;
        try flags.appendSlice(a, t.defines);
        var has_debug = false;
        for (t.defines) |d| if (std.mem.eql(u8, d, "DEBUG")) {
            has_debug = true;
        };
        if (!has_debug) try flags.append(a, "DEBUG");
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
    const root = std.Io.Dir.path.dirname(path) orelse ".";
    var cfg: Config = .{ .path = path, .root = root, .toolchain = .{}, .targets = &.{} };

    const c: Ctx = .{ .a = a, .where = "toolchain" };
    if (try c.map(top.get("toolchain") orelse .null, "toolchain")) |tc| {
        try checkKeys(tc, &toolchain_keys, "toolchain");
        const tc_info = @typeInfo(ToolchainConfig).@"struct";
        inline for (tc_info.field_names, tc_info.field_types) |name, FT| if (tc.get(name)) |v| {
            @field(cfg.toolchain, name) = switch (FT) {
                []const u8 => try c.str(v, name),
                ?[]const u8 => if (v == .null) null else try c.str(v, name),
                usize => std.fmt.parseInt(usize, try c.str(v, name), 10) catch
                    return diag.fail("toolchain: '{s}' must be a non-negative integer", .{name}),
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
        var base = try merge(a, defaults orelse empty_map, item.map);
        // iOS frameworks from `defaults:` do not apply to host test targets.
        if (base.get("type")) |k| if (k == .scalar and std.mem.eql(u8, k.scalar.text, "test") and item.map.get("frameworks") == null) {
            base = try without(a, base, "frameworks");
        };
        const variants = try a.create([2]Target);
        variants[0] = try profileTarget(a, root, i, base, global_profiles, "debug");
        variants[1] = try profileTarget(a, root, i, base, global_profiles, "release");
        t.* = if (profile) |name| variants[if (std.mem.eql(u8, name, "debug")) @as(usize, 0) else 1] else try loadTarget(a, root, i, .{ .map = base }, null);
        t.variants = variants;
        for (targets[0..i]) |prev| if (std.mem.eql(u8, prev.name, t.name)) return diag.fail("duplicate target name '{s}'", .{t.name});
    }
    cfg.targets = targets;
    try validateGraph(a, cfg.targets);
    return cfg;
}

/// Test targets and the static targets they test are compiled for the host,
/// where only the Swift corelibs exist.
fn requireHostFrameworks(where: []const u8, t: Target, tested_by: ?[]const u8) !void {
    for (t.frameworks) |f| {
        const base = if (std.mem.endsWith(u8, f, ".framework")) f[0 .. f.len - ".framework".len] else f;
        if (fsutil.oneOf(base, &host_frameworks)) continue;
        if (tested_by) |tt| return diag.fail("{s}: framework '{s}' is iOS-only, but test target '{s}' compiles this target for the Linux host; tested code must be host-portable (Foundation, XCTest, Testing)", .{ where, f, tt });
        return diag.fail("{s}: framework '{s}' is iOS-only; test targets run on the Linux host and may only use Foundation, XCTest or Testing (set `frameworks: [Foundation]`)", .{ where, f });
    }
}

fn findTarget(targets: []const Target, name: []const u8) ?Target {
    for (targets) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// `link`/`embed` reference existing targets of a compatible kind, and the
/// graph has no cycles.
fn validateGraph(a: Allocator, targets: []const Target) !void {
    for (targets) |t| {
        for (t.link) |n| {
            const dep = findTarget(targets, n) orelse return diag.fail("target '{s}': link: unknown target '{s}'", .{ t.name, n });
            if (!fsutil.oneOf(@tagName(dep.type), &.{ "framework", "dylib", "static" }))
                return diag.fail("target '{s}': cannot link {s} target '{s}'", .{ t.name, @tagName(dep.type), n });
            if (t.type == .@"test" and dep.type != .static)
                return diag.fail("test target '{s}': can only link static targets ('{s}' is a {s}; it would not run on the Linux host)", .{ t.name, n, @tagName(dep.type) });
        }
        for (t.embed) |n| {
            const dep = findTarget(targets, n) orelse return diag.fail("target '{s}': embed: unknown target '{s}'", .{ t.name, n });
            if (!fsutil.oneOf(@tagName(dep.type), &.{ "framework", "dylib", "appex" }))
                return diag.fail("target '{s}': cannot embed {s} target '{s}'", .{ t.name, @tagName(dep.type), n });
        }
    }
    // Ordering doubles as cycle detection.
    _ = try buildOrder(a, targets, targets);
    for (targets) |t| if (t.type == .@"test") for (try buildOrder(a, targets, &.{t})) |dep| {
        if (dep.type == .static) try requireHostFrameworks(try std.fmt.allocPrint(a, "target '{s}'", .{dep.name}), dep, t.name);
    };
}

/// `selected` plus everything it links or embeds (transitively), ordered so
/// every target comes after its dependencies.
pub fn buildOrder(a: Allocator, all: []const Target, selected: []const Target) ![]const Target {
    var out: std.ArrayList(Target) = .empty;
    var state = std.StringHashMap(u8).init(a); // 1 = visiting, 2 = done
    const Visit = struct {
        fn visit(ga: Allocator, al: []const Target, o: *std.ArrayList(Target), st: *std.StringHashMap(u8), t: Target) !void {
            if (st.get(t.name)) |s| {
                if (s == 1) return diag.fail("dependency cycle through target '{s}'", .{t.name});
                return;
            }
            try st.put(t.name, 1);
            for ([_][]const []const u8{ t.link, t.embed }) |names| for (names) |n|
                try visit(ga, al, o, st, findTarget(al, n) orelse return diag.fail("unknown target '{s}'", .{n}));
            try st.put(t.name, 2);
            try o.append(ga, t);
        }
    };
    for (selected) |t| try Visit.visit(a, all, &out, &state, t);
    return out.items;
}

pub fn load(a: Allocator, path: []const u8) !Config {
    return loadConfiguration(a, path, null);
}

pub fn loadConfiguration(a: Allocator, path: []const u8, profile: ?[]const u8) !Config {
    const abs = try sys.realpath(a, path);
    const source = sys.readFile(a, abs, 4 << 20) catch |err|
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

test "product kinds, link/embed validation and dependency order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parse(a,
        \\targets:
        \\  - name: App
        \\    bundle_id: com.example.app
        \\    embed: [Kit, Ext]
        \\  - name: Ext
        \\    type: appex
        \\    bundle_id: com.example.app.ext
        \\    link: [Kit]
        \\  - name: Kit
        \\    type: framework
        \\    bundle_id: com.example.kit
        \\    link: [Core]
        \\  - name: Core
        \\    type: static
        \\
    , "/proj/idlproj.yml");
    try testing.expectEqual(Kind.static, cfg.targets[3].type);
    const one = try parse(a, "targets:\n  - name: A\n    bundle_id: com.example.a\n    post_build: [sh, x.sh]\n", "/p/idlproj.yml");
    try testing.expectEqual(@as(usize, 1), one.targets[0].post_build.len);
    try testing.expectEqualStrings("x.sh", one.targets[0].post_build[0][1]);
    const two = try parse(a, "targets:\n  - name: A\n    bundle_id: com.example.a\n    post_build:\n      - [sh, x.sh]\n      - [sh, y.sh, --flag]\n", "/p/idlproj.yml");
    try testing.expectEqual(@as(usize, 2), two.targets[0].post_build.len);
    try testing.expectEqualStrings("--flag", two.targets[0].post_build[1][2]);
    try testing.expectEqualStrings("", cfg.targets[3].bundle_id);
    try testing.expect(!cfg.targets[3].signs());
    const order = try buildOrder(a, cfg.targets, cfg.targets[0..1]);
    try testing.expectEqual(@as(usize, 4), order.len);
    try testing.expectEqualStrings("Core", order[0].name);
    try testing.expectEqualStrings("Kit", order[1].name);
    try testing.expectEqualStrings("Ext", order[2].name);
    try testing.expectEqualStrings("App", order[3].name);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "targets:\n  - name: A\n    bundle_id: com.example.a\n    link: [Missing]\n", "unknown target 'Missing'" },
        .{ "targets:\n  - name: A\n    bundle_id: com.example.a\n  - name: B\n    bundle_id: com.example.b\n    embed: [A]\n", "cannot embed app" },
        .{ "targets:\n  - name: A\n    type: static\n    link: [B]\n  - name: B\n    type: static\n    link: [A]\n", "dependency cycle" },
        .{ "targets:\n  - name: S\n    type: static\n    resources: [R]\n", "have no bundle" },
        .{ "targets:\n  - name: F\n    type: framework\n", "'bundle_id' is required" },
    };
    for (cases) |case| {
        try testing.expectError(error.Invalid, parse(a, case[0], "/p/idlproj.yml"));
        testing.expect(std.mem.indexOf(u8, diag.msg, case[1]) != null) catch |err| {
            std.debug.print("expected '{s}' in '{s}'\n", .{ case[1], diag.msg });
            return err;
        };
    }
}

test "app_intents follows WidgetKit/AppIntents unless set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try parse(a,
        \\targets:
        \\  - name: App
        \\    bundle_id: com.example.app
        \\    embed: [Widgets]
        \\  - name: Widgets
        \\    type: appex
        \\    bundle_id: com.example.app.widgets
        \\    frameworks: [SwiftUI, WidgetKit]
        \\  - name: Off
        \\    type: appex
        \\    bundle_id: com.example.app.off
        \\    frameworks: [AppIntents]
        \\    app_intents: false
        \\  - name: On
        \\    type: framework
        \\    bundle_id: com.example.on
        \\    app_intents: true
        \\  - name: Shared
        \\    type: static
        \\    frameworks: [AppIntents]
        \\
    , "/proj/idlproj.yml");
    try testing.expect(cfg.targets[4].appIntents().enabled);
    try testing.expect(!cfg.targets[0].appIntents().enabled);
    try testing.expect(cfg.targets[1].appIntents().enabled);
    try testing.expect(!cfg.targets[1].appIntents().explicit);
    try testing.expect(!cfg.targets[2].appIntents().enabled);
    try testing.expect(cfg.targets[3].appIntents().enabled and cfg.targets[3].appIntents().explicit);
}

test "test targets: host frameworks, static links and profiles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\defaults:
        \\  frameworks: [UIKit, Foundation]
        \\targets:
        \\  - name: App
        \\    bundle_id: com.example.app
        \\    link: [Core]
        \\  - name: Core
        \\    type: static
        \\    frameworks: [Foundation]
        \\  - name: CoreTests
        \\    type: test
        \\    sources: [Tests]
        \\    link: [Core]
        \\
    ;
    const cfg = try parse(a, source, "/proj/idlproj.yml");
    const t = cfg.targets[2];
    try testing.expectEqual(Kind.@"test", t.type);
    try testing.expectEqual(@as(usize, 0), t.frameworks.len); // `defaults:` iOS frameworks are not inherited
    try testing.expectEqualStrings("", t.bundle_id);
    try testing.expect(!t.signs());
    try testing.expect(!t.appIntents().enabled);
    const order = try buildOrder(a, cfg.targets, &.{t});
    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expectEqualStrings("Core", order[0].name);
    const d = (try parseConfiguration(a, source, "/proj/idlproj.yml", "debug")).targets[2];
    try testing.expectEqualStrings("build/debug", d.build_dir);
    try testing.expectEqualStrings("DEBUG", d.defines[d.defines.len - 1]);
    const explicit = try parse(a, "targets:\n  - name: T\n    type: test\n    frameworks: [Foundation, XCTest]\n", "/p/idlproj.yml");
    try testing.expectEqual(@as(usize, 2), explicit.targets[0].frameworks.len);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "targets:\n  - name: T\n    type: test\n    frameworks: [UIKit]\n", "framework 'UIKit' is iOS-only" },
        .{ "targets:\n  - name: S\n    type: static\n  - name: T\n    type: test\n    link: [S]\n", "tested code must be host-portable" },
        .{ "targets:\n  - name: F\n    type: framework\n    bundle_id: com.example.f\n  - name: T\n    type: test\n    link: [F]\n", "can only link static targets" },
        .{ "targets:\n  - name: T\n    type: test\n  - name: A\n    bundle_id: com.example.a\n    link: [T]\n", "cannot link test target" },
        .{ "targets:\n  - name: T\n    type: test\n  - name: A\n    bundle_id: com.example.a\n    embed: [T]\n", "cannot embed test target" },
        .{ "targets:\n  - name: T\n    type: test\n    tests: [sh, run.sh]\n", "a test target's own sources are its tests" },
        .{ "targets:\n  - name: T\n    type: test\n    post_build: [sh, x.sh]\n", "post_build is only supported for app targets" },
        .{ "targets:\n  - name: T\n    type: test\n    xcodeproj: true\n", "xcodeproj generation is only supported for app targets" },
        .{ "targets:\n  - name: T\n    type: test\n    resources: [R]\n", "have no bundle" },
        .{ "targets:\n  - name: T\n    type: test\n    builder: xtool\n", "only app targets can use builder: xtool" },
        .{ "targets:\n  - name: T\n    type: test\n    bridging_header: B.h\n", "bridging_header is not supported" },
        .{ "targets:\n  - name: T\n    type: unit\n", "static or test" },
    };
    for (cases) |case| {
        try testing.expectError(error.Invalid, parse(a, case[0], "/p/idlproj.yml"));
        testing.expect(std.mem.indexOf(u8, diag.msg, case[1]) != null) catch |err| {
            std.debug.print("expected '{s}' in '{s}'\n", .{ case[1], diag.msg });
            return err;
        };
    }
}
