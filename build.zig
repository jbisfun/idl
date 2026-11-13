const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });

    const libplist = buildLibplist(b, target, optimize);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("clap", clap.module("clap"));
    mod.addImport("yaml", yaml.module("yaml"));
    mod.linkLibrary(libplist);
    // `idl init` scaffolds from the real examples so templates never drift.
    mod.addAnonymousImport("scaffold_main_m", .{ .root_source_file = b.path("examples/objc-app/Sources/main.m") });
    mod.addAnonymousImport("scaffold_main_swift", .{ .root_source_file = b.path("examples/swift-app/Sources/main.swift") });
    mod.addAnonymousImport("scaffold_entitlements", .{ .root_source_file = b.path("examples/objc-app/Entitlements.plist") });

    const exe = b.addExecutable(.{ .name = "idl", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run idl (pass arguments after --)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Convenience wrappers around the CLI for this repository's idlproj.yml.
    inline for (.{
        .{ "check", "Verify the Linux iOS toolchain", &[_][]const u8{"check"} },
        .{ "examples", "Generate projects and build every example IPA", &[_][]const u8{ "build", "--gen" } },
    }) |spec| {
        const cmd = b.addRunArtifact(exe);
        cmd.setCwd(b.path("."));
        cmd.addArgs(spec[2]);
        cmd.has_side_effects = true;
        b.step(spec[0], spec[1]).dependOn(&cmd.step);
    }
}

/// libplist (libimobiledevice) compiled from source as a static C library,
/// replacing its autotools build. Only the C core is built (no libplist++).
fn buildLibplist(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const dep = b.dependency("libplist", .{});
    const lib = b.addLibrary(.{
        .name = "plist-2.0",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    lib.addIncludePath(dep.path("include"));
    lib.addIncludePath(dep.path("src"));
    lib.addIncludePath(dep.path("libcnary/include"));
    lib.root_module.addCMacro("PACKAGE_VERSION", "\"2.8.1\"");
    for ([_][]const u8{ "HAVE_STRNDUP", "HAVE_STRPTIME", "HAVE_GMTIME_R", "HAVE_LOCALTIME_R", "HAVE_MEMMEM", "HAVE_TM_TM_GMTOFF", "HAVE_TM_TM_ZONE" }) |m|
        lib.root_module.addCMacro(m, "1");
    lib.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &.{
            "src/base64.c",       "src/bytearray.c",    "src/hashtable.c",  "src/ptrarray.c",
            "src/time64.c",       "src/common.c",       "src/xplist.c",     "src/bplist.c",
            "src/jsmn.c",         "src/jplist.c",       "src/oplist.c",     "src/out-default.c",
            "src/out-plutil.c",   "src/out-limd.c",     "src/plist.c",      "libcnary/node.c",
            "libcnary/node_list.c",
        },
        .flags = &.{ "-std=gnu11", "-fno-sanitize=undefined" },
    });
    lib.installHeadersDirectory(dep.path("include"), "", .{});
    return lib;
}
