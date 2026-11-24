//! Deterministic single-target iOS `.xcodeproj` generator.
//!
//! Object IDs are derived from stable content keys (SHA-1 of
//! "pbxprojgen:<section>:<key>"), so regenerating yields byte-identical output
//! and the IDs match projects produced by the previous Python generator.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const Profile = struct {
    output_dir: []const u8,
    sign: bool,
    bundle_id: []const u8,
    info_plist: []const u8,
    entitlements: ?[]const u8,
    opt: []const u8,
    swift_opt: []const u8,
    debug_symbols: bool,
    defines: []const []const u8,
    cflags: []const []const u8,
    swiftflags: []const []const u8,
    ldflags: []const []const u8,
};

pub const Manifest = struct {
    profiles: ?[2]Profile = null,
    name: []const u8,
    bundle_id: []const u8,
    deployment_target: []const u8 = "16.0",
    marketing_version: []const u8 = "1.0",
    build_number: []const u8 = "1",
    swift_version: []const u8 = "5.0",
    device_family: []const u8 = "1,2",
    app_icon: []const u8 = "AppIcon",
    info_plist: []const u8 = "Info.plist",
    entitlements: ?[]const u8 = null,
    frameworks: []const []const u8 = &.{ "UIKit", "Foundation" },
    sources: []const []const u8 = &.{"Sources"},
    resources: []const []const u8 = &.{},
};

const file_types = [_]struct { []const u8, []const u8 }{
    .{ ".c", "sourcecode.c.c" },                   .{ ".cc", "sourcecode.cpp.cpp" },
    .{ ".cpp", "sourcecode.cpp.cpp" },             .{ ".cxx", "sourcecode.cpp.cpp" },
    .{ ".h", "sourcecode.c.h" },                   .{ ".hpp", "sourcecode.cpp.h" },
    .{ ".m", "sourcecode.c.objc" },                .{ ".mm", "sourcecode.cpp.objcpp" },
    .{ ".swift", "sourcecode.swift" },             .{ ".s", "sourcecode.asm" },
    .{ ".S", "sourcecode.asm" },                   .{ ".plist", "text.plist.xml" },
    .{ ".json", "text.json" },                     .{ ".xcassets", "folder.assetcatalog" },
    .{ ".xcstrings", "text.json.xcstrings" },      .{ ".storyboard", "file.storyboard" },
    .{ ".xib", "file.xib" },                       .{ ".strings", "text.plist.strings" },
    .{ ".stringsdict", "text.plist.stringsdict" }, .{ ".metal", "sourcecode.metal" },
    .{ ".bundle", "wrapper.plug-in" },             .{ ".framework", "wrapper.framework" },
    .{ ".xcdatamodeld", "wrapper.xcdatamodel" },   .{ ".mlmodelc", "folder.mlmodelc" },
};

pub fn fileType(path: []const u8) []const u8 {
    const sfx = fsutil.suffix(path);
    for (file_types) |ft| if (std.mem.eql(u8, ft[0], sfx)) return ft[1];
    return "file";
}

pub fn objectId(buf: *[24]u8, kind: []const u8, key: []const u8) []const u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update("pbxprojgen:");
    h.update(kind);
    h.update(":");
    h.update(key);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..12].*, .upper);
    buf.* = hex;
    return buf;
}

fn isBare(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_./+-", c) != null)) return false;
    return true;
}

/// OpenStep plist scalar: bare when safe, else double-quoted.
pub fn quote(a: Allocator, value: []const u8) ![]const u8 {
    if (fsutil.hasControlCharacters(value)) return diag.fail("OpenStep value contains control characters", .{});
    if (isBare(value) and !std.mem.eql(u8, value, "YES") and !std.mem.eql(u8, value, "NO")) return value;
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (value) |c| {
        if (c == '\\' or c == '"') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
    return out.items;
}

fn safeComment(a: Allocator, value: []const u8) ![]const u8 {
    const step = try std.mem.replaceOwned(u8, a, value, "*/", "* /");
    for (step) |*c| if (c.* == '\r' or c.* == '\n') {
        c.* = ' ';
    };
    return step;
}

fn xmlAttribute(a: Allocator, value: []const u8) ![]const u8 {
    if (fsutil.hasControlCharacters(value)) return diag.fail("XML attribute contains control characters", .{});
    var out: std.ArrayList(u8) = .empty;
    for (value) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
    return out.items;
}

const Section = enum {
    PBXBuildFile,
    PBXFileReference,
    PBXFrameworksBuildPhase,
    PBXGroup,
    PBXNativeTarget,
    PBXProject,
    PBXResourcesBuildPhase,
    PBXSourcesBuildPhase,
    XCBuildConfiguration,
    XCConfigurationList,
};

const Object = struct { id: []const u8, comment: []const u8, body: []const u8 };

const Setting = struct {
    key: []const u8,
    value: union(enum) { str: []const u8, list: []const []const u8 },
};

pub const Generator = struct {
    a: Allocator,
    m: Manifest,
    /// Absolute, symlink-resolved directory the manifest paths are relative to.
    root: []const u8,
    /// Absolute output `.xcodeproj` path (parent resolved).
    output: []const u8,
    project_base: []const u8,
    sources: []const []const u8,
    resources: []const []const u8,
    objects: [std.meta.fieldNames(Section).len]std.ArrayList(Object) = @splat(.empty),
    comments: std.StringHashMapUnmanaged([]const u8) = .empty,
    target_id: []const u8 = "",
    project_id: []const u8 = "",

    pub fn init(a: Allocator, m: Manifest, root_dir: []const u8, output: []const u8) !Generator {
        const root = try fsutil.resolveLenient(a, root_dir);
        const out = try fsutil.join(a, try fsutil.resolveLenient(a, std.Io.Dir.path.dirname(output) orelse "."), std.Io.Dir.path.basename(output));
        if (!std.mem.eql(u8, fsutil.suffix(out), ".xcodeproj")) return diag.fail("output must end in .xcodeproj", .{});
        var g: Generator = .{
            .a = a,
            .m = m,
            .root = root,
            .output = out,
            .project_base = std.Io.Dir.path.dirname(out).?,
            .sources = try fsutil.discover(a, root, m.sources, "source"),
            .resources = try fsutil.discover(a, root, m.resources, "resource"),
        };
        try checkFile(a, root, m.info_plist, "Info.plist does not exist");
        if (m.entitlements) |e| try checkFile(a, root, e, "entitlements file does not exist");
        var buf: [24]u8 = undefined;
        g.target_id = try a.dupe(u8, objectId(&buf, "target", m.name));
        g.project_id = try a.dupe(u8, objectId(&buf, "project", m.name));
        return g;
    }

    fn checkFile(a: Allocator, root: []const u8, rel: []const u8, comptime missing: []const u8) !void {
        try fsutil.validateRelativePath(rel, "path");
        try fsutil.rejectSymlinkComponents(a, root, rel);
        switch (fsutil.kind(try fsutil.join(a, root, rel))) {
            .file => {},
            .symlink => return diag.fail("symlinks are not allowed: {s}", .{rel}),
            else => return diag.fail(missing ++ ": {s}", .{rel}),
        }
    }

    fn add(g: *Generator, section: Section, key: []const u8, comment: []const u8, body: []const u8) ![]const u8 {
        var buf: [24]u8 = undefined;
        const id = try g.a.dupe(u8, objectId(&buf, @tagName(section), key));
        const c = try safeComment(g.a, comment);
        try g.objects[@backingInt(section)].append(g.a, .{ .id = id, .comment = c, .body = body });
        try g.comments.put(g.a, id, c);
        return id;
    }

    fn ref(g: *Generator, id: []const u8) ![]const u8 {
        const c = g.comments.get(id) orelse "";
        if (c.len == 0) return id;
        return std.fmt.allocPrint(g.a, "{s} /* {s} */", .{ id, c });
    }

    fn projectRelative(g: *Generator, rel_to_root: []const u8) ![]const u8 {
        const abs = try fsutil.join(g.a, g.root, rel_to_root);
        return sys.relative(g.a, g.project_base, abs);
    }

    fn fileReference(g: *Generator, rel_to_root: []const u8, group_name: []const u8) ![]const u8 {
        const relative = try g.projectRelative(rel_to_root);
        const body = try std.fmt.allocPrint(g.a, "{{isa = PBXFileReference; lastKnownFileType = {s}; path = {s}; sourceTree = \"<group>\"; }}", .{ fileType(rel_to_root), try quote(g.a, relative) });
        return g.add(.PBXFileReference, try std.fmt.allocPrint(g.a, "{s}:{s}", .{ group_name, relative }), std.Io.Dir.path.basename(rel_to_root), body);
    }

    fn buildFile(g: *Generator, file_id: []const u8, phase_name: []const u8) ![]const u8 {
        const filename = g.comments.get(file_id).?;
        const body = try std.fmt.allocPrint(g.a, "{{isa = PBXBuildFile; fileRef = {s}; }}", .{try g.ref(file_id)});
        return g.add(.PBXBuildFile, try std.fmt.allocPrint(g.a, "{s}:{s}", .{ phase_name, file_id }), try std.fmt.allocPrint(g.a, "{s} in {s}", .{ filename, phase_name }), body);
    }

    fn group(g: *Generator, name: []const u8, children: []const []const u8, key: ?[]const u8) ![]const u8 {
        var b: std.Io.Writer.Allocating = .init(g.a);
        const w = &b.writer;
        try w.writeAll("{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n");
        for (children) |child| try w.print("\t\t\t\t{s},\n", .{try g.ref(child)});
        try w.print("\t\t\t);\n\t\t\tname = {s};\n\t\t\tsourceTree = \"<group>\";\n\t\t}}", .{try quote(g.a, name)});
        return g.add(.PBXGroup, key orelse name, name, b.written());
    }

    fn phase(g: *Generator, section: Section, name: []const u8, files: []const []const u8) ![]const u8 {
        var b: std.Io.Writer.Allocating = .init(g.a);
        const w = &b.writer;
        try w.print("{{\n\t\t\tisa = {s};\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n", .{@tagName(section)});
        for (files) |f| try w.print("\t\t\t\t{s},\n", .{try g.ref(f)});
        try w.writeAll("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}");
        return g.add(section, name, name, b.written());
    }

    fn settingLines(g: *Generator, settings: []Setting) ![]const u8 {
        std.mem.sort(Setting, settings, {}, struct {
            fn lt(_: void, l: Setting, r: Setting) bool {
                return std.mem.lessThan(u8, l.key, r.key);
            }
        }.lt);
        const indent = "\t\t\t\t";
        var b: std.Io.Writer.Allocating = .init(g.a);
        const w = &b.writer;
        try w.writeAll("{\n");
        for (settings) |s| switch (s.value) {
            .str => |v| try w.print(indent ++ "{s} = {s};\n", .{ s.key, try quote(g.a, v) }),
            .list => |items| {
                try w.print(indent ++ "{s} = (\n", .{s.key});
                for (items) |item| try w.print(indent ++ "\t{s},\n", .{try quote(g.a, item)});
                try w.writeAll(indent ++ ");\n");
            },
        };
        try w.writeAll("\t\t\t}");
        return b.written();
    }

    fn configurationList(g: *Generator, owner: []const u8, debug: []Setting, release: []Setting) ![]const u8 {
        var ids: [2][]const u8 = undefined;
        for ([_][]const u8{ "Debug", "Release" }, [_][]Setting{ debug, release }, 0..) |name, settings, i| {
            const body = try std.fmt.allocPrint(g.a, "{{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {s};\n\t\t\tname = {s};\n\t\t}}", .{ try g.settingLines(settings), name });
            ids[i] = try g.add(.XCBuildConfiguration, try std.fmt.allocPrint(g.a, "{s}:{s}", .{ owner, name }), name, body);
        }
        const body = try std.fmt.allocPrint(g.a, "{{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{s},\n\t\t\t\t{s},\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}}", .{ try g.ref(ids[0]), try g.ref(ids[1]) });
        return g.add(.XCConfigurationList, owner, try std.fmt.allocPrint(g.a, "Build configuration list for {s} \"{s}\"", .{ owner, g.m.name }), body);
    }

    fn concat(g: *Generator, base: []const Setting, extra: []const Setting) ![]Setting {
        return std.mem.concat(g.a, Setting, &.{ base, extra });
    }

    pub fn generate(g: *Generator) ![]const u8 {
        const a = g.a;
        var source_refs: std.ArrayList([]const u8) = .empty;
        var source_builds: std.ArrayList([]const u8) = .empty;
        for (g.sources) |path| {
            const r = try g.fileReference(path, "Sources");
            try source_refs.append(a, r);
            if (fsutil.oneOf(fsutil.suffix(path), &fsutil.source_extensions)) try source_builds.append(a, try g.buildFile(r, "Sources"));
        }
        var resource_refs: std.ArrayList([]const u8) = .empty;
        var resource_builds: std.ArrayList([]const u8) = .empty;
        for (g.resources) |path| {
            const r = try g.fileReference(path, "Resources");
            try resource_refs.append(a, r);
            try resource_builds.append(a, try g.buildFile(r, "Resources"));
        }
        var extra_refs: std.ArrayList([]const u8) = .empty;
        try extra_refs.append(a, try g.fileReference(g.m.info_plist, "Project"));
        if (g.m.entitlements) |e| try extra_refs.append(a, try g.fileReference(e, "Project"));

        var names: std.ArrayList([]const u8) = .empty;
        for (g.m.frameworks) |f| {
            const n = if (std.mem.endsWith(u8, f, ".framework")) f else try std.fmt.allocPrint(a, "{s}.framework", .{f});
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, n)) break;
            } else try names.append(a, n);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.lessThan(u8, l, r);
            }
        }.lt);
        var framework_refs: std.ArrayList([]const u8) = .empty;
        var framework_builds: std.ArrayList([]const u8) = .empty;
        for (names.items) |n| {
            const body = try std.fmt.allocPrint(a, "{{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {s}; path = {s}; sourceTree = SDKROOT; }}", .{ try quote(a, n), try quote(a, try std.fmt.allocPrint(a, "System/Library/Frameworks/{s}", .{n})) });
            const r = try g.add(.PBXFileReference, try std.fmt.allocPrint(a, "framework:{s}", .{n}), n, body);
            try framework_refs.append(a, r);
            try framework_builds.append(a, try g.buildFile(r, "Frameworks"));
        }

        const app_name = try std.fmt.allocPrint(a, "{s}.app", .{g.m.name});
        const product_ref = try g.add(.PBXFileReference, try std.fmt.allocPrint(a, "product:{s}", .{g.m.name}), app_name, try std.fmt.allocPrint(a, "{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {s}; sourceTree = BUILT_PRODUCTS_DIR; }}", .{try quote(a, app_name)}));

        const source_group = try g.group("Sources", source_refs.items, null);
        const resource_group: ?[]const u8 = if (resource_refs.items.len > 0) try g.group("Resources", resource_refs.items, null) else null;
        const framework_group = try g.group("Frameworks", framework_refs.items, null);
        const products_group = try g.group("Products", &.{product_ref}, null);
        var main_children: std.ArrayList([]const u8) = .empty;
        try main_children.append(a, source_group);
        if (resource_group) |rg| try main_children.append(a, rg);
        try main_children.appendSlice(a, extra_refs.items);
        try main_children.appendSlice(a, &.{ framework_group, products_group });
        const main_group = try g.group(g.m.name, main_children.items, "main");

        const sources_phase = try g.phase(.PBXSourcesBuildPhase, "Sources", source_builds.items);
        const resources_phase = try g.phase(.PBXResourcesBuildPhase, "Resources", resource_builds.items);
        const frameworks_phase = try g.phase(.PBXFrameworksBuildPhase, "Frameworks", framework_builds.items);

        const dt = g.m.deployment_target;
        const project_common = [_]Setting{
            .{ .key = "ALWAYS_SEARCH_USER_PATHS", .value = .{ .str = "NO" } },
            .{ .key = "CLANG_ENABLE_MODULES", .value = .{ .str = "YES" } },
            .{ .key = "CLANG_ENABLE_OBJC_ARC", .value = .{ .str = "YES" } },
            .{ .key = "IPHONEOS_DEPLOYMENT_TARGET", .value = .{ .str = dt } },
            .{ .key = "SDKROOT", .value = .{ .str = "iphoneos" } },
        };
        const project_configs = try g.configurationList("project", try g.concat(&project_common, &.{
            .{ .key = "DEBUG_INFORMATION_FORMAT", .value = .{ .str = "dwarf" } },
            .{ .key = "ENABLE_TESTABILITY", .value = .{ .str = "YES" } },
            .{ .key = "ONLY_ACTIVE_ARCH", .value = .{ .str = "YES" } },
        }), try g.concat(&project_common, &.{
            .{ .key = "DEBUG_INFORMATION_FORMAT", .value = .{ .str = "dwarf-with-dsym" } },
            .{ .key = "SWIFT_COMPILATION_MODE", .value = .{ .str = "wholemodule" } },
            .{ .key = "VALIDATE_PRODUCT", .value = .{ .str = "YES" } },
        }));

        var target_common: std.ArrayList(Setting) = .empty;
        try target_common.appendSlice(a, &.{
            .{ .key = "CODE_SIGN_STYLE", .value = .{ .str = "Automatic" } },
            .{ .key = "CURRENT_PROJECT_VERSION", .value = .{ .str = g.m.build_number } },
            .{ .key = "GENERATE_INFOPLIST_FILE", .value = .{ .str = "NO" } },
            .{ .key = "INFOPLIST_FILE", .value = .{ .str = try g.projectRelative(g.m.info_plist) } },
            .{ .key = "IPHONEOS_DEPLOYMENT_TARGET", .value = .{ .str = dt } },
            .{ .key = "LD_RUNPATH_SEARCH_PATHS", .value = .{ .list = &.{ "$(inherited)", "@executable_path/Frameworks" } } },
            .{ .key = "MARKETING_VERSION", .value = .{ .str = g.m.marketing_version } },
            .{ .key = "PRODUCT_BUNDLE_IDENTIFIER", .value = .{ .str = g.m.bundle_id } },
            .{ .key = "PRODUCT_NAME", .value = .{ .str = "$(TARGET_NAME)" } },
            .{ .key = "SUPPORTED_PLATFORMS", .value = .{ .str = "iphoneos iphonesimulator" } },
            .{ .key = "SUPPORTS_MACCATALYST", .value = .{ .str = "NO" } },
            .{ .key = "SWIFT_VERSION", .value = .{ .str = g.m.swift_version } },
            .{ .key = "TARGETED_DEVICE_FAMILY", .value = .{ .str = g.m.device_family } },
        });
        for (g.resources) |r| if (std.mem.eql(u8, fsutil.suffix(r), ".xcassets")) {
            try target_common.append(a, .{ .key = "ASSETCATALOG_COMPILER_APPICON_NAME", .value = .{ .str = g.m.app_icon } });
            break;
        };
        if (g.m.entitlements) |e| try target_common.append(a, .{ .key = "CODE_SIGN_ENTITLEMENTS", .value = .{ .str = try g.projectRelative(e) } });
        const target_configs = if (g.m.profiles) |profiles|
            try g.configurationList("target", try g.profileSettings(target_common.items, profiles[0]), try g.profileSettings(target_common.items, profiles[1]))
        else
            try g.configurationList("target", try g.concat(target_common.items, &.{
                .{ .key = "SWIFT_ACTIVE_COMPILATION_CONDITIONS", .value = .{ .str = "DEBUG $(inherited)" } },
                .{ .key = "SWIFT_OPTIMIZATION_LEVEL", .value = .{ .str = "-Onone" } },
            }), try g.concat(target_common.items, &.{
                .{ .key = "SWIFT_OPTIMIZATION_LEVEL", .value = .{ .str = "-O" } },
            }));

        const target_body = try std.fmt.allocPrint(
            a,
            "{{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {s};\n\t\t\tbuildPhases = (\n\t\t\t\t{s},\n\t\t\t\t{s},\n\t\t\t\t{s},\n\t\t\t);\n\t\t\tbuildRules = ();\n\t\t\tdependencies = ();\n\t\t\tname = {s};\n\t\t\tproductName = {s};\n\t\t\tproductReference = {s};\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}}",
            .{ try g.ref(target_configs), try g.ref(sources_phase), try g.ref(frameworks_phase), try g.ref(resources_phase), try quote(a, g.m.name), try quote(a, g.m.name), try g.ref(product_ref) },
        );
        try g.objects[@backingInt(Section.PBXNativeTarget)].append(a, .{ .id = g.target_id, .comment = g.m.name, .body = target_body });
        try g.comments.put(a, g.target_id, g.m.name);

        const project_body = try std.fmt.allocPrint(
            a,
            "{{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t}};\n\t\t\tbuildConfigurationList = {s};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (en, Base);\n\t\t\tmainGroup = {s};\n\t\t\tproductRefGroup = {s};\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{s} /* {s} */ ,\n\t\t\t);\n\t\t}}",
            .{ try g.ref(project_configs), try g.ref(main_group), try g.ref(products_group), g.target_id, g.m.name },
        );
        try g.objects[@backingInt(Section.PBXProject)].append(a, .{ .id = g.project_id, .comment = "Project object", .body = project_body });
        try g.comments.put(a, g.project_id, "Project object");
        return g.render();
    }

    fn profileSettings(g: *Generator, common: []const Setting, p: Profile) ![]Setting {
        var out: std.array_hash_map.String(@TypeOf(@as(Setting, undefined).value)) = .empty;
        for (common) |v| try out.put(g.a, v.key, v.value);
        try out.put(g.a, "PRODUCT_BUNDLE_IDENTIFIER", .{ .str = p.bundle_id });
        try out.put(g.a, "CONFIGURATION_BUILD_DIR", .{ .str = try std.fmt.allocPrint(g.a, "$(SRCROOT)/{s}", .{p.output_dir}) });
        try out.put(g.a, "CODE_SIGNING_ALLOWED", .{ .str = if (p.sign) "YES" else "NO" });
        try out.put(g.a, "INFOPLIST_FILE", .{ .str = try g.projectRelative(p.info_plist) });
        _ = out.swapRemove("CODE_SIGN_ENTITLEMENTS");
        if (p.entitlements) |e| try out.put(g.a, "CODE_SIGN_ENTITLEMENTS", .{ .str = try g.projectRelative(e) });
        try out.put(g.a, "GCC_OPTIMIZATION_LEVEL", .{ .str = if (std.mem.startsWith(u8, p.opt, "-O")) p.opt[2..] else "s" });
        try out.put(g.a, "SWIFT_OPTIMIZATION_LEVEL", .{ .str = p.swift_opt });
        try out.put(g.a, "DEBUG_INFORMATION_FORMAT", .{ .str = "dwarf" });
        try out.put(g.a, "GCC_GENERATE_DEBUGGING_SYMBOLS", .{ .str = if (p.debug_symbols) "YES" else "NO" });
        try out.put(g.a, "GCC_PREPROCESSOR_DEFINITIONS", .{ .list = p.defines });
        var conditions: std.ArrayList([]const u8) = .empty;
        for (p.defines) |d| if (std.mem.indexOfScalar(u8, d, '=') == null) try conditions.append(g.a, d);
        try out.put(g.a, "SWIFT_ACTIVE_COMPILATION_CONDITIONS", .{ .list = conditions.items });
        try out.put(g.a, "OTHER_CFLAGS", .{ .list = p.cflags });
        try out.put(g.a, "OTHER_SWIFT_FLAGS", .{ .list = p.swiftflags });
        var link_flags: std.ArrayList([]const u8) = .empty;
        for (p.ldflags) |f| try link_flags.appendSlice(g.a, &.{ "-Xlinker", f });
        try out.put(g.a, "OTHER_LDFLAGS", .{ .list = link_flags.items });
        const result = try g.a.alloc(Setting, out.count());
        for (out.keys(), out.values(), result) |k, v, *item| item.* = .{ .key = k, .value = v };
        return result;
    }

    fn render(g: *Generator) ![]const u8 {
        var b: std.Io.Writer.Allocating = .init(g.a);
        const w = &b.writer;
        try w.writeAll("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n\n");
        for (&g.objects, 0..) |*list, i| {
            if (list.items.len == 0) continue;
            const name = @tagName(@as(Section, @fromBackingInt(@intCast(i))));
            std.mem.sort(Object, list.items, {}, struct {
                fn lt(_: void, l: Object, r: Object) bool {
                    return switch (std.mem.order(u8, l.comment, r.comment)) {
                        .lt => true,
                        .gt => false,
                        .eq => std.mem.lessThan(u8, l.id, r.id),
                    };
                }
            }.lt);
            try w.print("/* Begin {s} section */\n", .{name});
            for (list.items) |o| try w.print("\t\t{s} /* {s} */ = {s};\n", .{ o.id, o.comment, o.body });
            try w.print("/* End {s} section */\n\n", .{name});
        }
        try w.print("\t}};\n\trootObject = {s} /* Project object */;\n}}\n", .{g.project_id});
        return b.written();
    }

    pub fn scheme(g: *Generator) ![]const u8 {
        const name = try xmlAttribute(g.a, g.m.name);
        const app = try xmlAttribute(g.a, try std.fmt.allocPrint(g.a, "{s}.app", .{g.m.name}));
        const container = try xmlAttribute(g.a, std.Io.Dir.path.basename(g.output));
        const buildable = try std.fmt.allocPrint(g.a, "<BuildableReference BuildableIdentifier=\"primary\" BlueprintIdentifier=\"{s}\" BuildableName=\"{s}\" BlueprintName=\"{s}\" ReferencedContainer=\"container:{s}\"/>", .{ g.target_id, app, name, container });
        return std.fmt.allocPrint(g.a,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<Scheme LastUpgradeVersion="1600" version="1.7">
            \\  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            \\    <BuildActionEntries>
            \\      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            \\        {0s}
            \\      </BuildActionEntry>
            \\    </BuildActionEntries>
            \\  </BuildAction>
            \\  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
            \\    <BuildableProductRunnable runnableDebuggingMode="0">
            \\      {0s}
            \\    </BuildableProductRunnable>
            \\  </LaunchAction>
            \\  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
            \\    <BuildableProductRunnable runnableDebuggingMode="0">
            \\      {0s}
            \\    </BuildableProductRunnable>
            \\  </ProfileAction>
            \\  <AnalyzeAction buildConfiguration="Debug"/>
            \\  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
            \\</Scheme>
            \\
        , .{buildable});
    }
};

// ------------------------------------------------- safe atomic publishing

fn openOrCreateDirNoFollow(path: []const u8) !std.Io.Dir {
    if (!std.Io.Dir.path.isAbsolute(path)) return diag.fail("output parent must be absolute", .{});
    var dir = try std.Io.Dir.openDirAbsolute(sys.io, "/", .{});
    errdefer dir.close(sys.io);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        dir.createDir(sys.io, part, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const next = try dir.openDir(sys.io, part, .{ .follow_symlinks = false });
        dir.close(sys.io);
        dir = next;
    }
    return dir;
}

/// Remove `name` inside `parent` without ever following symlinks.
fn removeEntryAt(parent: std.Io.Dir, name: []const u8) !void {
    const st = parent.statFile(sys.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (st.kind != .directory) return parent.deleteFile(sys.io, name);
    var child = try parent.openDir(sys.io, name, .{ .iterate = true, .follow_symlinks = false });
    {
        defer child.close(sys.io);
        var it = child.iterate();
        while (try it.next(sys.io)) |entry| try removeEntryAt(child, entry.name);
    }
    try parent.deleteDir(sys.io, name);
}

fn writeNew(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    var f = try dir.createFile(sys.io, name, .{ .exclusive = true, .permissions = .fromMode(0o644) });
    defer f.close(sys.io);
    try f.writeStreamingAll(sys.io, data);
}

/// Build the project in a private sibling directory, then swap it into place
/// using directory-FD-relative operations that never follow symlinks.
pub fn publish(g: *Generator, before_publish: ?*const fn () anyerror!void) !void {
    var parent = try openOrCreateDirNoFollow(std.Io.Dir.path.dirname(g.output).?);
    defer parent.close(sys.io);
    const out_name = std.Io.Dir.path.basename(g.output);
    var rnd: [12]u8 = undefined;
    sys.io.random(&rnd);
    const tmp_name = try std.fmt.allocPrint(g.a, ".{s}.tmp-{s}", .{ out_name, std.fmt.bytesToHex(rnd, .lower) });
    var published = false;
    defer if (!published) removeEntryAt(parent, tmp_name) catch {};

    try parent.createDir(sys.io, tmp_name, .default_dir);
    {
        var tmp = try parent.openDir(sys.io, tmp_name, .{ .follow_symlinks = false });
        defer tmp.close(sys.io);
        try writeNew(tmp, "project.pbxproj", try g.generate());
        try tmp.createDir(sys.io, "xcshareddata", .default_dir);
        var shared = try tmp.openDir(sys.io, "xcshareddata", .{ .follow_symlinks = false });
        defer shared.close(sys.io);
        try shared.createDir(sys.io, "xcschemes", .default_dir);
        var schemes = try shared.openDir(sys.io, "xcschemes", .{ .follow_symlinks = false });
        defer schemes.close(sys.io);
        try writeNew(schemes, try std.fmt.allocPrint(g.a, "{s}.xcscheme", .{g.m.name}), try g.scheme());
    }
    if (before_publish) |hook| try hook();
    try removeEntryAt(parent, out_name);
    try parent.rename(tmp_name, parent, out_name, sys.io);
    published = true;
}

/// Validate the requested output path and generate the project.
pub fn generateProject(a: Allocator, m: Manifest, root_dir: []const u8, output: []const u8) ![]const u8 {
    if (fsutil.hasControlCharacters(std.Io.Dir.path.basename(output))) return diag.fail("output filename contains control characters", .{});
    switch (fsutil.kind(output)) {
        .symlink => return diag.fail("output may not be a symlink: {s}", .{output}),
        .missing => {},
        .dir => try fsutil.rejectSymlinksBelow(a, output, "", "output contains a symlink"),
        else => return diag.fail("output exists and is not a directory: {s}", .{output}),
    }
    var g = try Generator.init(a, m, root_dir, output);
    try publish(&g, null);
    return g.output;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init() !Fixture {
        var f: Fixture = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = "" };
        f.root = try f.tmp.dir.realPathFileAlloc(sys.io, ".", f.arena.allocator());
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn write(f: *Fixture, rel: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(sys.io, d);
        try f.tmp.dir.writeFile(sys.io, .{ .sub_path = rel, .data = data });
    }

    fn path(f: *Fixture, rel: []const u8) ![]const u8 {
        return std.Io.Dir.path.join(f.arena.allocator(), &.{ f.root, rel });
    }

    fn read(f: *Fixture, rel: []const u8) ![]const u8 {
        return f.tmp.dir.readFileAlloc(sys.io, rel, f.arena.allocator(), .limited(1 << 20));
    }

    fn standard(f: *Fixture) !Manifest {
        try f.write("Sources/main.swift", "import UIKit\n");
        try f.write("Sources/Support/Helper.m", "#import <Foundation/Foundation.h>\n");
        try f.write("Sources/Support/Helper.h", "void helper(void);\n");
        try f.write("Resources/data.json", "{}\n");
        try f.write("Info.plist", "<plist version=\"1.0\"><dict/></plist>\n");
        return .{ .name = "GeneratedApp", .bundle_id = "com.example.generated", .resources = &.{"Resources"} };
    }

    fn gen(f: *Fixture, m: Manifest, out: []const u8) ![]const u8 {
        return generateProject(f.arena.allocator(), m, f.root, try f.path(out));
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "deterministic project with sources, resources and frameworks" {
    var f = try Fixture.init();
    defer f.deinit();
    const m = try f.standard();
    _ = try f.gen(m, "GeneratedApp.xcodeproj");
    const first = try f.read("GeneratedApp.xcodeproj/project.pbxproj");
    _ = try f.gen(m, "GeneratedApp.xcodeproj");
    const second = try f.read("GeneratedApp.xcodeproj/project.pbxproj");
    try testing.expectEqualStrings(first, second);
    for ([_][]const u8{
        "isa = PBXProject;",                                  "productType = \"com.apple.product-type.application\";",
        "PRODUCT_BUNDLE_IDENTIFIER = com.example.generated;", "IPHONEOS_DEPLOYMENT_TARGET = 16.0;",
        "main.swift in Sources",                              "Helper.m in Sources",
        "data.json in Resources",                             "UIKit.framework in Frameworks",
        "Foundation.framework in Frameworks",                 "\"$(inherited)\",",
        "PRODUCT_NAME = \"$(TARGET_NAME)\";",
    }) |needle| try testing.expect(contains(first, needle));
    try testing.expect(!contains(first, "Helper.h in Sources"));
    try testing.expect(!contains(first, "ASSETCATALOG_COMPILER_APPICON_NAME"));
}

test "custom output uses relative paths and matching scheme container" {
    var f = try Fixture.init();
    defer f.deinit();
    var m = try f.standard();
    m.resources = &.{};
    // Generate from a subdirectory root to a sibling output directory.
    try f.write("app/Sources/main.swift", "import UIKit\n");
    try f.write("app/Info.plist", "<plist/>\n");
    _ = try generateProject(f.arena.allocator(), m, try f.path("app"), try f.path("generated/DifferentName.xcodeproj"));
    const project = try f.read("generated/DifferentName.xcodeproj/project.pbxproj");
    const scheme = try f.read("generated/DifferentName.xcodeproj/xcshareddata/xcschemes/GeneratedApp.xcscheme");
    try testing.expect(contains(project, "../app/Sources/main.swift"));
    try testing.expect(contains(project, "INFOPLIST_FILE = ../app/Info.plist;"));
    try testing.expect(contains(scheme, "ReferencedContainer=\"container:DifferentName.xcodeproj\""));
    try testing.expect(contains(scheme, "BlueprintName=\"GeneratedApp\""));
    try testing.expect(contains(scheme, "BuildableName=\"GeneratedApp.app\""));
}

test "framework names are normalized before de-duplication" {
    var f = try Fixture.init();
    defer f.deinit();
    var m = try f.standard();
    m.frameworks = &.{ "UIKit", "UIKit.framework" };
    _ = try f.gen(m, "GeneratedApp.xcodeproj");
    const text = try f.read("GeneratedApp.xcodeproj/project.pbxproj");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "UIKit.framework in Frameworks */ ="));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "/* UIKit.framework */ = {isa = PBXFileReference"));
}

test "asset catalog is one resource" {
    var f = try Fixture.init();
    defer f.deinit();
    const m = try f.standard();
    try f.write("Resources/Assets.xcassets/AppIcon.appiconset/Contents.json", "{}\n");
    _ = try f.gen(m, "GeneratedApp.xcodeproj");
    const text = try f.read("GeneratedApp.xcodeproj/project.pbxproj");
    try testing.expect(contains(text, "Assets.xcassets in Resources"));
    try testing.expect(!contains(text, "Contents.json in Resources"));
    try testing.expect(contains(text, "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"));
}

test "rejects symlinks in inputs, ancestors and packages" {
    {
        var f = try Fixture.init();
        defer f.deinit();
        const m = try f.standard();
        try f.tmp.dir.symLink(sys.io, "main.swift", "Sources/linked.swift", .{});
        try testing.expectError(error.Invalid, f.gen(m, "GeneratedApp.xcodeproj"));
        try testing.expect(contains(diag.msg, "symlinks are not allowed"));
    }
    {
        var f = try Fixture.init();
        defer f.deinit();
        var m = try f.standard();
        try f.write("outside/main.swift", "import UIKit\n");
        try f.tmp.dir.symLink(sys.io, "outside", "Alias", .{ .is_directory = true });
        m.sources = &.{"Alias"};
        try testing.expectError(error.Invalid, f.gen(m, "GeneratedApp.xcodeproj"));
        try testing.expect(contains(diag.msg, "symlinks are not allowed"));
    }
    {
        var f = try Fixture.init();
        defer f.deinit();
        const m = try f.standard();
        try f.tmp.dir.createDirPath(sys.io, "Resources/Assets.xcassets");
        try f.tmp.dir.symLink(sys.io, "../data.json", "Resources/Assets.xcassets/linked.json", .{});
        try testing.expectError(error.Invalid, f.gen(m, "GeneratedApp.xcodeproj"));
        try testing.expect(contains(diag.msg, "symlinks are not allowed"));
    }
}

test "rejects symlinked output files and directories" {
    {
        var f = try Fixture.init();
        defer f.deinit();
        const m = try f.standard();
        try f.write("external.pbxproj", "unchanged");
        try f.tmp.dir.createDirPath(sys.io, "GeneratedApp.xcodeproj");
        try f.tmp.dir.symLink(sys.io, "../external.pbxproj", "GeneratedApp.xcodeproj/project.pbxproj", .{});
        try testing.expectError(error.Invalid, f.gen(m, "GeneratedApp.xcodeproj"));
        try testing.expect(contains(diag.msg, "output contains a symlink"));
        try testing.expectEqualStrings("unchanged", try f.read("external.pbxproj"));
    }
    {
        var f = try Fixture.init();
        defer f.deinit();
        const m = try f.standard();
        try f.write("external-schemes/Keep.xcscheme", "unchanged");
        try f.tmp.dir.createDirPath(sys.io, "GeneratedApp.xcodeproj/xcshareddata");
        try f.tmp.dir.symLink(sys.io, try f.path("external-schemes"), "GeneratedApp.xcodeproj/xcshareddata/xcschemes", .{ .is_directory = true });
        try testing.expectError(error.Invalid, f.gen(m, "GeneratedApp.xcodeproj"));
        try testing.expect(contains(diag.msg, "output contains a symlink"));
        try testing.expectEqualStrings("unchanged", try f.read("external-schemes/Keep.xcscheme"));
    }
}

var swap_fixture: ?*Fixture = null;

fn swapOutput() anyerror!void {
    const f = swap_fixture.?;
    try f.tmp.dir.symLink(sys.io, try f.path("external"), "GeneratedApp.xcodeproj", .{ .is_directory = true });
}

test "atomic publisher does not follow a symlink swapped in before publish" {
    var f = try Fixture.init();
    defer f.deinit();
    const m = try f.standard();
    try f.write("external/marker", "unchanged");
    var g = try Generator.init(f.arena.allocator(), m, f.root, try f.path("GeneratedApp.xcodeproj"));
    swap_fixture = &f;
    defer swap_fixture = null;
    try publish(&g, swapOutput);
    try testing.expectEqualStrings("unchanged", try f.read("external/marker"));
    try testing.expectEqual(fsutil.Kind.dir, fsutil.kind(try f.path("GeneratedApp.xcodeproj")));
    try testing.expectEqual(fsutil.Kind.file, fsutil.kind(try f.path("GeneratedApp.xcodeproj/project.pbxproj")));
}

test "assembly and metal are compiled; generated xcodeproj skipped on rescan" {
    var f = try Fixture.init();
    defer f.deinit();
    var m = try f.standard();
    try f.write("Sources/lower.s", "// asm\n");
    try f.write("Sources/upper.S", "// asm\n");
    try f.write("main.metal", "kernel void k() {}\n");
    m.sources = &.{"."};
    m.resources = &.{};
    _ = try f.gen(m, "GeneratedApp.xcodeproj");
    const first = try f.read("GeneratedApp.xcodeproj/project.pbxproj");
    _ = try f.gen(m, "GeneratedApp.xcodeproj");
    try testing.expectEqualStrings(first, try f.read("GeneratedApp.xcodeproj/project.pbxproj"));
    try testing.expect(contains(first, "lastKnownFileType = sourcecode.asm; path = Sources/lower.s"));
    try testing.expect(contains(first, "lastKnownFileType = sourcecode.asm; path = Sources/upper.S"));
    try testing.expect(contains(first, "upper.S in Sources"));
    try testing.expect(contains(first, "main.metal in Sources"));
    try testing.expect(!contains(first, "project.pbxproj in Sources"));
}

test "escapes special output names and removes stale schemes" {
    var f = try Fixture.init();
    defer f.deinit();
    const m = try f.standard();
    try f.write("Generated&Debug.xcodeproj/xcshareddata/xcschemes/Old.xcscheme", "stale");
    _ = try f.gen(m, "Generated&Debug.xcodeproj");
    try testing.expectEqual(fsutil.Kind.missing, fsutil.kind(try f.path("Generated&Debug.xcodeproj/xcshareddata/xcschemes/Old.xcscheme")));
    const scheme = try f.read("Generated&Debug.xcodeproj/xcshareddata/xcschemes/GeneratedApp.xcscheme");
    try testing.expect(contains(scheme, "container:Generated&amp;Debug.xcodeproj"));
}

test "missing source path" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write("Info.plist", "<plist/>\n");
    try testing.expectError(error.Invalid, f.gen(.{ .name = "Broken", .bundle_id = "com.example.broken", .sources = &.{"Missing"} }, "Broken.xcodeproj"));
    try testing.expect(contains(diag.msg, "source path does not exist"));
}
