//! `idl init`: scaffold a new app with an idlproj.yml.
const std = @import("std");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub const Lang = enum { objc, swift };

const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict>
    \\<key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>
    \\<key>CFBundleDisplayName</key><string>$(PRODUCT_NAME)</string>
    \\<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    \\<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    \\<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    \\<key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
    \\<key>CFBundlePackageType</key><string>APPL</string>
    \\<key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
    \\<key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
    \\<key>LSRequiresIPhoneOS</key><true/>
    \\<key>UILaunchScreen</key><dict/>
    \\<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
    \\</dict></plist>
    \\
;

const project_yml =
    \\# idl project configuration. Reference: docs/configuration.md
    \\toolchain:
    \\  sdk_bundle: ~/.swiftpm/swift-sdks/darwin.artifactbundle
    \\
    \\targets:
    \\  - name: {[name]s}
    \\    bundle_id: {[bundle_id]s}
    \\    min_ios: "16.0"
    \\    version: "1.0"
    \\    build_number: "1"
    \\    sources: [Sources]
    \\    info_plist: Info.plist
    \\    entitlements: Entitlements.plist
    \\    frameworks: [UIKit, Foundation]
    \\    xcodeproj: true
    \\    compile_commands: true
    \\
;

const gitignore =
    \\build/
    \\.idl/
    \\*.ipa
    \\*.xcodeproj/
    \\compile_commands.json
    \\
;

pub fn init(a: Allocator, name: []const u8, lang: Lang, bundle_id_opt: ?[]const u8, dir_opt: ?[]const u8) ![]const u8 {
    const dir = dir_opt orelse name;
    const bundle_id = bundle_id_opt orelse blk: {
        const lower = try std.ascii.allocLowerString(a, name);
        for (lower) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
            c.* = '-';
        };
        break :blk try std.fmt.allocPrint(a, "com.example.{s}", .{lower});
    };
    const yml = try std.fmt.allocPrint(a, project_yml, .{ .name = name, .bundle_id = bundle_id });
    // Validate through the real loader before touching the filesystem.
    _ = try config.parse(a, yml, try std.fs.path.join(a, &.{ "/", config.file_name }));

    const cfg_path = try std.fs.path.join(a, &.{ dir, config.file_name });
    if (fsutil.kind(cfg_path) != .missing) return diag.fail("{s} already exists", .{cfg_path});
    const files = [_]struct { []const u8, []const u8 }{
        .{ config.file_name, yml },
        .{ "Info.plist", info_plist },
        .{ "Entitlements.plist", @embedFile("scaffold_entitlements") },
        .{ ".gitignore", gitignore },
        switch (lang) {
            .objc => .{ "Sources/main.m", @embedFile("scaffold_main_m") },
            .swift => .{ "Sources/main.swift", @embedFile("scaffold_main_swift") },
        },
    };
    for (files) |f| {
        const path = try std.fs.path.join(a, &.{ dir, f[0] });
        if (fsutil.kind(path) != .missing) {
            diag.warn("keeping existing {s}", .{path});
            continue;
        }
        if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = f[1] });
        diag.info("  NEW  {s}", .{path});
    }
    return dir;
}
