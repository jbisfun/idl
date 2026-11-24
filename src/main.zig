//! idl — iOS development on Linux. Reads idlproj.yml, generates project files
//! and orchestrates clang/swiftc/ldid/xtool to produce IPAs.
const std = @import("std");
const sys = @import("sys.zig");
const clap = @import("clap");
const diag = @import("diag.zig");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const builder = @import("builder.zig");
const codegen = @import("codegen.zig");
const pbxproj = @import("pbxproj.zig");
const plist = @import("plist.zig");
const xcstrings = @import("xcstrings.zig");
const verify = @import("verify.zig");
const scaffold = @import("scaffold.zig");
const jimpactor = @import("jimpactor.zig");
const quality = @import("quality.zig");
const ibtool = @import("ibtool.zig");
const nib = @import("nib.zig");
const Toolchain = @import("toolchain.zig").Toolchain;

const Allocator = std.mem.Allocator;

// zig-yaml logs every token at debug level; keep output clean in Debug builds.
pub const std_options: std.Options = .{ .log_level = .warn };

const Command = enum { build, gen, check, list, clean, install, devices, verify, init, xcodeproj, plist, xcstrings, ibtool, fmt, lint, @"test", help };

const main_params = clap.parseParamsComptime(
    \\-h, --help           Show help (also: idl <command> --help).
    \\-f, --file <path>    idlproj.yml to use (default: search upward from the current directory).
    \\-v, --verbose        Print every command that is run.
    \\<command>
    \\
);

const main_parsers = .{
    .path = clap.parsers.string,
    .command = clap.parsers.enumeration(Command),
};

const usage_text =
    \\usage: idl [-f idlproj.yml] [-v] <command> [args]
    \\
    \\Project commands (read idlproj.yml):
    \\  build [target...]      build, sign, package and verify IPAs (default: all targets)
    \\  gen [target...]        generate .xcodeproj, xtool.yml/Package.swift, compile_commands.json
    \\  check [target...]      preflight tools and resources (no app compilation)
    \\  list                   list configured targets
    \\  clean [target...]      remove build outputs
    \\  xcodeproj <target>     generate one Xcode project (optionally to --output)
    \\  install <device> [target...]
    \\                         build, then sign + install through the running Jimpactor
    \\  fmt [target...]        format sources (clang-format, swift-format; --check to verify)
    \\  lint [target...]       compiler warnings, clang-tidy, analyzer, swift-format lint
    \\  test [target...]       build, check app bundles, then run each app's `tests:`
    \\
    \\Build/check/install: --strict rejects unsupported inputs.
    \\Project commands: -c debug|release selects isolated profile outputs.
    \\
    \\Jimpactor commands (need the Jimpactor tray app running):
    \\  devices list           list devices Jimpactor can install to
    \\
    \\Standalone commands:
    \\  init <Name>            scaffold a new app with an idlproj.yml
    \\  verify <ipa>           structural IPA validation (ZIP CRCs, plist, Mach-O)
    \\  plist                  expand $(VARS) and edit a plist (Xcode Info.plist processing)
    \\  xcstrings <in> <dir>   convert a String Catalog to .strings/.stringsdict
    \\  ibtool <file>          compile a .xib/.storyboard (-o OUT), or dump a .nib
    \\
    \\Global options:
    \\
;

const Global = struct {
    file: ?[]const u8,
    verbose: bool,
};

pub fn main(init: std.process.Init) !u8 {
    sys.init(init.io, init.environ_map);
    const a = init.arena.allocator();

    var iter = try init.minimal.args.iterateAllocator(a);
    _ = iter.next();
    var parse_diag: clap.Diagnostic = .{};
    const res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &parse_diag,
        .allocator = a,
        .terminating_positional = 0,
    }) catch |err| {
        parse_diag.reportToFile(sys.io, .stderr(), err) catch {};
        return 2;
    };
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(sys.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    const command = res.positionals[0] orelse {
        try stdout.writeAll(usage_text);
        try clap.help(stdout, clap.Help, &main_params, .{});
        try stdout.flush();
        return if (res.args.help != 0) 0 else 2;
    };
    if (res.args.help != 0 or command == .help) {
        try stdout.writeAll(usage_text);
        try clap.help(stdout, clap.Help, &main_params, .{});
        try stdout.flush();
        return 0;
    }
    const global: Global = .{ .file = res.args.file, .verbose = res.args.verbose != 0 };

    dispatch(a, command, &iter, global) catch |err| switch (err) {
        error.Invalid => {
            sys.stderrPrint("error: {s}\n", .{diag.msg});
            return 1;
        },
        error.Usage => return 2,
        error.HelpShown => return 0,
        else => return err,
    };
    return 0;
}

fn dispatch(a: Allocator, command: Command, iter: *std.process.Args.Iterator, g: Global) !void {
    switch (command) {
        .build => try cmdBuild(a, iter, g),
        .gen => try cmdGen(a, iter, g),
        .check => try cmdCheck(a, iter, g),
        .list => try cmdList(a, iter, g),
        .clean => try cmdClean(a, iter, g),
        .install => try cmdInstall(a, iter, g),
        .devices => try cmdDevices(a, iter, g),
        .verify => try cmdVerify(a, iter),
        .init => try cmdInit(a, iter),
        .xcodeproj => try cmdXcodeproj(a, iter, g),
        .plist => try cmdPlist(a, iter),
        .xcstrings => try cmdXcstrings(a, iter),
        .ibtool => try cmdIbtool(a, iter),
        .fmt => try cmdFmt(a, iter, g),
        .lint => try cmdLint(a, iter, g),
        .@"test" => try cmdTest(a, iter, g),
        .help => unreachable,
    }
}

/// Parse a subcommand's arguments; prints help/diagnostics itself.
fn parseSub(a: Allocator, comptime name: []const u8, comptime params: anytype, comptime value_parsers: anytype, iter: *std.process.Args.Iterator) !clap.ResultEx(clap.Help, params, value_parsers) {
    var d: clap.Diagnostic = .{};
    const res = clap.parseEx(clap.Help, params, value_parsers, iter, .{ .diagnostic = &d, .allocator = a }) catch |err| {
        d.reportToFile(sys.io, .stderr(), err) catch {};
        sys.stderrPrint("see: idl {s} --help\n", .{name});
        return error.Usage;
    };
    if (res.args.help != 0) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(sys.io, &buf);
        const out = &w.interface;
        try out.print("usage: idl {s} ", .{name});
        try clap.usage(out, clap.Help, params);
        try out.writeAll("\n\n");
        try clap.help(out, clap.Help, params, .{});
        try out.flush();
        return error.HelpShown;
    }
    return res;
}

const Project = struct { cfg: config.Config, tc: Toolchain };

fn loadProject(a: Allocator, g: Global) !Project {
    return loadProjectConfiguration(a, g, null);
}

fn loadProjectConfiguration(a: Allocator, g: Global, profile: ?[]const u8) !Project {
    const path = g.file orelse try config.find(a, ".");
    const cfg = try config.loadConfiguration(a, path, profile);
    return .{ .cfg = cfg, .tc = try Toolchain.init(a, cfg.toolchain, cfg.root) };
}

const parsers = .{
    .path = clap.parsers.string,
    .str = clap.parsers.string,
    .target = clap.parsers.string,
    .usize = clap.parsers.int(usize, 10),
    .lang = clap.parsers.enumeration(scaffold.Lang),
    .action = clap.parsers.enumeration(DevicesAction),
    .device = clap.parsers.string,
};

const DevicesAction = enum { list };

/// Jimpactor's data dir: toolchain.jimpactor_dir from idlproj.yml if there is one, else the default.
fn jimpactorDir(a: Allocator, g: Global) ![]const u8 {
    var env = try sys.envMap(a);
    const path: ?[]const u8 = g.file orelse (config.find(a, ".") catch null);
    if (path) |p| {
        const cfg = try config.load(a, p);
        if (cfg.toolchain.jimpactor_dir) |d| return fsutil.expandHome(a, d, &env);
    }
    return jimpactor.defaultDataDir(a, &env);
}

fn printDevices(devices: []const jimpactor.Device) void {
    if (devices.len == 0) {
        diag.info("no devices", .{});
        return;
    }
    diag.info("{s:<28} {s:<10} {s:<9} {s}", .{ "UDID", "CONNECTION", "AVAILABLE", "NAME" });
    for (devices) |d| diag.info("{s:<28} {s:<10} {s:<9} {s}", .{ d.udid, d.connection, if (d.available) "yes" else "no", d.name });
}

fn printProgress(message: []const u8, percent: i64) void {
    diag.info("  [{d:>3}%] {s}", .{ percent, message });
}

fn cmdDevices(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<action>
        \\
    );
    const res = try parseSub(a, "devices", &params, parsers, iter);
    switch (res.positionals[0] orelse .list) {
        .list => printDevices(try jimpactor.listDevices(a, try jimpactorDir(a, g))),
    }
}

fn cmdInstall(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-c, --configuration <str>  Build profile: debug or release.
        \\    --strict         Reject unsupported inputs instead of warnings.
        \\-h, --help          Show this help.
        \\    --ipa <path>    Install this IPA instead of building targets.
        \\    --no-build      Install the targets' existing IPAs without rebuilding.
        \\-j, --jobs <usize>  Parallel compile jobs.
        \\-v, --verbose       Print every command that is run.
        \\<device>
        \\<target>...
        \\
    );
    const res = try parseSub(a, "install", &params, parsers, iter);
    const query = res.positionals[0] orelse return diag.fail("install: expected a device (UDID, UDID prefix or name; see `idl devices list`)", .{});
    const data_dir = try jimpactorDir(a, g);
    // Resolve the device first so a missing app or device fails before a build.
    const device = try jimpactor.resolveDevice(try jimpactor.listDevices(a, data_dir), query);
    if (!device.available) diag.warn("{s} is not reachable right now; Jimpactor will try anyway", .{device.name});

    var ipas: std.ArrayList([]const u8) = .empty;
    if (res.args.ipa) |ipa| {
        if (res.positionals[1].len > 0) return diag.fail("install: give either --ipa or targets, not both", .{});
        try ipas.append(a, try sys.realpath(a, ipa));
    } else {
        var p = try loadProjectConfiguration(a, g, res.args.configuration);
        const selected = try p.cfg.select(a, res.positionals[1]);
        const targets = if (res.args.@"no-build" == 0) try config.buildOrder(a, p.cfg.targets, selected) else selected;
        var session: ?builder.Session = if (res.args.@"no-build" == 0) try builder.prepareAll(a, &p.tc, targets, res.args.strict != 0, g.verbose or res.args.verbose != 0) else null;
        defer if (session) |*s| s.release();
        var products = builder.Products.init(a);
        for (targets, 0..) |t, i| {
            const ipa = if (res.args.@"no-build" != 0) try t.ipaPath(a) else (try builder.build(a, &p.tc, t, .{ .jobs = res.args.jobs orelse p.cfg.toolchain.jobs, .verbose = g.verbose or res.args.verbose != 0, .locked = true, .prepared = session.?.prepared[i], .strict = res.args.strict != 0, .products = &products })).ipa orelse continue;
            if (t.type != .app) continue;
            if (fsutil.kind(ipa) != .file) return diag.fail("{s} does not exist; run `idl build {s}` first", .{ ipa, t.name });
            try ipas.append(a, ipa);
        }
    }
    for (ipas.items) |ipa| {
        diag.info("==> installing {s} on {s} ({s})", .{ std.Io.Dir.path.basename(ipa), device.name, device.udid });
        const event = try jimpactor.send(a, data_dir, .{ .install = .{ .path = ipa, .udid = device.udid } }, printProgress);
        diag.info("{s}", .{event.message orelse event.event});
    }
}

fn cmdBuild(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-c, --configuration <str>  Build profile: debug or release.
        \\    --strict         Reject unsupported inputs instead of warnings.
        \\-h, --help          Show this help.
        \\-j, --jobs <usize>  Parallel compile jobs (default: toolchain.jobs or CPU count).
        \\-v, --verbose       Print every command that is run.
        \\    --gen           Also regenerate .xcodeproj / compile_commands.json.
        \\    --no-post-build Skip app targets' post_build commands.
        \\<target>...
        \\
    );
    const res = try parseSub(a, "build", &params, parsers, iter);
    var p = try loadProjectConfiguration(a, g, res.args.configuration);
    // Selected targets plus everything they link or embed, dependencies first.
    const targets = try config.buildOrder(a, p.cfg.targets, try p.cfg.select(a, res.positionals[0]));
    var session = try builder.prepareAll(a, &p.tc, targets, res.args.strict != 0, g.verbose or res.args.verbose != 0);
    defer session.release();
    var ipas: std.ArrayList([]const u8) = .empty;
    var products = builder.Products.init(a);
    for (targets, 0..) |t, i| {
        if (res.args.gen != 0) try codegen.generate(a, &p.tc, t, .{});
        const built = try builder.build(a, &p.tc, t, .{ .jobs = res.args.jobs orelse p.cfg.toolchain.jobs, .verbose = g.verbose or res.args.verbose != 0, .locked = true, .prepared = session.prepared[i], .strict = res.args.strict != 0, .products = &products, .post_build = res.args.@"no-post-build" == 0 });
        if (built.ipa) |ipa| try ipas.append(a, ipa);
    }
    diag.info("\nbuilt {d} IPA(s):", .{ipas.items.len});
    for (ipas.items) |ipa| diag.info("  {s}", .{ipa});
    if (targets.len > 0) diag.info("ad-hoc signatures are not provisioning; re-sign before installing.", .{});
}

fn cmdGen(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-c, --configuration <str>  Build profile: debug or release.
        \\-h, --help  Show this help.
        \\<target>...
        \\
    );
    const res = try parseSub(a, "gen", &params, parsers, iter);
    var p = try loadProjectConfiguration(a, g, res.args.configuration);
    const targets = try p.cfg.select(a, res.positionals[0]);
    const locks = try builder.lockTargets(a, targets);
    defer for (locks) |*lock| lock.release();
    for (targets) |t| {
        diag.info("==> {s}", .{t.name});
        try codegen.generate(a, &p.tc, t, .{});
        try quality.genEditorConfigs(a, t);
    }
}

/// Build `selected` plus dependencies (no post_build) and return the products.
fn buildForQuality(a: Allocator, p: *Project, selected: []const config.Target, jobs: ?usize, verbose: bool, strict: bool) !builder.Products {
    const targets = try config.buildOrder(a, p.cfg.targets, selected);
    var session = try builder.prepareAll(a, &p.tc, targets, strict, verbose);
    defer session.release();
    var products = builder.Products.init(a);
    for (targets, 0..) |t, i| _ = try builder.build(a, &p.tc, t, .{ .jobs = jobs orelse p.cfg.toolchain.jobs, .verbose = verbose, .locked = true, .prepared = session.prepared[i], .strict = strict, .products = &products, .post_build = false });
    return products;
}

fn cmdFmt(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Show this help.
        \\    --check         Report files that need formatting; change nothing (exit 1 if any).
        \\-j, --jobs <usize>  Parallel tool runs.
        \\-v, --verbose       Print every command that is run.
        \\<target>...
        \\
    );
    const res = try parseSub(a, "fmt", &params, parsers, iter);
    var p = try loadProject(a, g);
    const targets = try p.cfg.select(a, res.positionals[0]);
    const locks = try builder.lockTargets(a, targets);
    defer for (locks) |*lock| lock.release();
    const ok = try quality.fmt(a, &p.tc, p.cfg.root, targets, .{ .check = res.args.check != 0, .jobs = res.args.jobs orelse p.cfg.toolchain.jobs, .verbose = g.verbose or res.args.verbose != 0 });
    if (!ok) return diag.fail("{s}", .{if (res.args.check != 0) "some files need formatting (run `idl fmt`)" else "formatting failed"});
}

fn cmdLint(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Show this help.
        \\-c, --configuration <str>  Build profile: debug or release.
        \\    --werror        Fail on warnings too.
        \\    --analyze       Also run the clang static analyzer.
        \\    --no-tidy       Skip clang-tidy.
        \\    --tidy          Require clang-tidy.
        \\-q, --quiet         Print only the summary.
        \\    --max <usize>   Print at most this many diagnostics.
        \\-j, --jobs <usize>  Parallel tool runs.
        \\-v, --verbose       Print every command that is run.
        \\<target>...
        \\
    );
    const res = try parseSub(a, "lint", &params, parsers, iter);
    var p = try loadProjectConfiguration(a, g, res.args.configuration);
    const targets = try p.cfg.select(a, res.positionals[0]);
    const verbose = g.verbose or res.args.verbose != 0;
    // Dependencies' modules and generated Swift headers come from a build.
    var products = try buildForQuality(a, &p, targets, res.args.jobs, verbose, false);
    const locks = try builder.lockTargets(a, targets);
    defer for (locks) |*lock| lock.release();
    const ok = try quality.lint(a, &p.tc, p.cfg.root, targets, &products, .{
        .jobs = res.args.jobs orelse p.cfg.toolchain.jobs,
        .verbose = verbose,
        .werror = res.args.werror != 0,
        .analyze = res.args.analyze != 0,
        .tidy = if (res.args.@"no-tidy" != 0) false else if (res.args.tidy != 0) true else null,
        .quiet = res.args.quiet != 0,
        .max = res.args.max,
    });
    if (!ok) return diag.fail("lint failed", .{});
}

fn cmdTest(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Show this help.
        \\-c, --configuration <str>  Build profile: debug or release.
        \\    --no-build      Test the existing build outputs.
        \\    --strict        Reject unsupported inputs while building.
        \\-j, --jobs <usize>  Parallel compile jobs.
        \\-v, --verbose       Print every command that is run.
        \\<target>...
        \\
    );
    const res = try parseSub(a, "test", &params, parsers, iter);
    var p = try loadProjectConfiguration(a, g, res.args.configuration);
    const selected = try p.cfg.select(a, res.positionals[0]);
    const verbose = g.verbose or res.args.verbose != 0;
    if (res.args.@"no-build" == 0) _ = try buildForQuality(a, &p, selected, res.args.jobs, verbose, res.args.strict != 0);
    var apps: std.ArrayList(config.Target) = .empty;
    for (selected) |t| if (t.type == .app) try apps.append(a, t);
    if (apps.items.len == 0) return diag.fail("test: no app targets selected", .{});
    const locks = try builder.lockTargets(a, apps.items);
    defer for (locks) |*lock| lock.release();
    if (!try quality.runTests(a, &p.tc, apps.items, .{ .verbose = verbose })) return diag.fail("tests failed", .{});
}

fn cmdCheck(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Show this help.
        \\-c, --configuration <str>   Build profile: debug or release.
        \\    --strict                Reject unsupported inputs.
        \\<target>...
        \\
    );
    const res = try parseSub(a, "check", &params, parsers, iter);
    const path: ?[]const u8 = g.file orelse (config.find(a, ".") catch null);
    if (path) |file| {
        const cfg = try config.loadConfiguration(a, file, res.args.configuration);
        var tc = try Toolchain.init(a, cfg.toolchain, cfg.root);
        _ = try tc.check(); // informational inventory; requirements are target-specific
        var session = try builder.prepareAll(a, &tc, try config.buildOrder(a, cfg.targets, try cfg.select(a, res.positionals[0])), res.args.strict != 0, g.verbose);
        defer session.release();
        diag.info("preflight passed (no application sources compiled)", .{});
    } else {
        if (res.positionals[0].len > 0 or res.args.configuration != null) return diag.fail("check: target/profile selection requires idlproj.yml", .{});
        const tc = try Toolchain.init(a, .{}, try sys.realpath(a, "."));
        if (!try tc.check()) return diag.fail("toolchain incomplete", .{});
    }
}

fn cmdList(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-c, --configuration <str>  Build profile: debug or release.
        \\-h, --help  Show this help.
        \\
    );
    const res = try parseSub(a, "list", &params, parsers, iter);
    const p = try loadProjectConfiguration(a, g, res.args.configuration);
    for (p.cfg.targets) |t| {
        const rel = try sys.relative(a, p.cfg.root, t.dir);
        diag.info("{s:<24} {s:<9} {s:<7} {s:<36} iOS {s:<6} {s}", .{ t.name, @tagName(t.type), @tagName(t.builder), t.bundle_id, t.min_ios, if (rel.len == 0) "." else rel });
    }
}

fn cmdClean(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-c, --configuration <str>  Build profile: debug or release.
        \\-h, --help  Show this help.
        \\<target>...
        \\
    );
    const res = try parseSub(a, "clean", &params, parsers, iter);
    const p = try loadProjectConfiguration(a, g, res.args.configuration);
    const targets = try p.cfg.select(a, res.positionals[0]);
    const locks = try builder.lockTargets(a, targets);
    defer for (locks) |*lock| lock.release();
    for (targets) |t| try builder.clean(a, t);
}

fn cmdVerify(a: Allocator, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Show this help.
        \\    --bundle-id <str>   Require this CFBundleIdentifier.
        \\    --allow-unsigned    Accept executables without LC_CODE_SIGNATURE.
        \\<path>...
        \\
    );
    const res = try parseSub(a, "verify", &params, parsers, iter);
    if (res.positionals[0].len == 0) return diag.fail("verify: expected at least one .ipa path", .{});
    for (res.positionals[0]) |ipa| _ = try verify.verifyFile(a, ipa, .{ .bundle_id = res.args.@"bundle-id", .allow_unsigned = res.args.@"allow-unsigned" != 0 });
}

fn cmdInit(a: Allocator, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Show this help.
        \\    --lang <lang>      objc or swift (default: swift).
        \\    --bundle-id <str>  Bundle identifier (default: com.example.<name>).
        \\    --dir <path>       Directory to create (default: <Name>).
        \\<str>
        \\
    );
    const res = try parseSub(a, "init", &params, parsers, iter);
    const name = res.positionals[0] orelse return diag.fail("init: expected an app name", .{});
    const dir = try scaffold.init(a, name, res.args.lang orelse .swift, res.args.@"bundle-id", res.args.dir);
    diag.info("\nnext:\n  cd {s}\n  idl check\n  idl build", .{dir});
}

fn cmdXcodeproj(a: Allocator, iter: *std.process.Args.Iterator, g: Global) !void {
    const params = comptime clap.parseParamsComptime(
        \\-c, --configuration <str>  Build profile: debug or release.
        \\-h, --help           Show this help.
        \\-o, --output <path>  Output .xcodeproj (default: <target dir>/<Name>.xcodeproj).
        \\<target>
        \\
    );
    const res = try parseSub(a, "xcodeproj", &params, parsers, iter);
    const p = try loadProjectConfiguration(a, g, res.args.configuration);
    const name = res.positionals[0] orelse return diag.fail("xcodeproj: expected a target name", .{});
    const t = (try p.cfg.select(a, &.{name}))[0];
    const out = res.args.output orelse try std.fmt.allocPrint(a, "{s}/{s}.xcodeproj", .{ t.dir, t.name });
    var lock = try @import("buildstate.zig").Lock.acquire(a, t.dir);
    defer lock.release();
    try codegen.genXcodeMetadata(a, t);
    diag.info("{s}", .{try pbxproj.generateProject(a, t.manifest(), t.dir, out)});
}

fn splitAssignment(s: []const u8) struct { []const u8, []const u8 } {
    const eq = std.mem.indexOfScalar(u8, s, '=') orelse return .{ s, "" };
    return .{ s[0..eq], s[eq + 1 ..] };
}

fn cmdPlist(a: Allocator, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Show this help.
        \\-i, --input <path>      Input plist (XML, binary, JSON or OpenStep); omit to start empty.
        \\-o, --output <path>     Output XML plist (required).
        \\    --var <str>...      KEY=VALUE for $(KEY) expansion (falls back to the environment).
        \\    --default <str>...  KEY=VALUE set only when the key is absent.
        \\    --set <str>...      KEY=VALUE (JSON for arrays/dicts/bools/ints).
        \\    --delete <str>...   Remove KEY.
        \\
    );
    const res = try parseSub(a, "plist", &params, parsers, iter);
    const output = res.args.output orelse return diag.fail("plist: --output is required", .{});
    const root = if (res.args.input) |in| try plist.readFile(a, in) else plist.Plist.newDict();
    defer root.deinit();
    if (!root.isDict()) return diag.fail("plist root must be a dictionary", .{});
    var vars = plist.Vars.init(a);
    for (res.args.@"var") |s| {
        const k, const v = splitAssignment(s);
        try vars.put(k, v);
    }
    for (res.args.default) |s| {
        const k, const v = splitAssignment(s);
        try root.setDefault(a, k, try plist.parseCliValue(a, k, v));
    }
    for (res.args.set) |s| {
        const k, const v = splitAssignment(s);
        try root.set(a, k, try plist.parseCliValue(a, k, v));
    }
    for (res.args.delete) |k| try root.remove(a, k);
    var env = try sys.envMap(a);
    try plist.expand(a, root.node, &vars, &env);
    const xml = try root.toXml(a);
    if (std.Io.Dir.path.dirname(output)) |d| try sys.makePath(d);
    try sys.cwd().writeFile(sys.io, .{ .sub_path = output, .data = xml });
}

fn cmdXcstrings(a: Allocator, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Show this help.
        \\<path>
        \\<path>
        \\
    );
    const res = try parseSub(a, "xcstrings", &params, parsers, iter);
    const input = res.positionals[0] orelse return diag.fail("xcstrings: expected <input.xcstrings> <outdir>", .{});
    const outdir = res.positionals[1] orelse return diag.fail("xcstrings: expected <input.xcstrings> <outdir>", .{});
    const source = sys.readFile(a, input, 64 << 20) catch |err| return diag.fail("cannot read {s}: {s}", .{ input, @errorName(err) });
    var dir = try sys.cwd().createDirPathOpen(sys.io, outdir, .{});
    defer dir.close(sys.io);
    try xcstrings.convert(a, source, dir);
}

fn cmdIbtool(a: Allocator, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\    --strict         Reject unsupported IB features.
        \\-h, --help           Show this help.
        \\-o, --output <path>  Output .nib / .storyboardc (default: next to the input).
        \\-d, --dump           Print the objects of a compiled .nib (or of the compiled input).
        \\-t, --types          With --dump, show value encodings.
        \\<path>
        \\
    );
    const res = try parseSub(a, "ibtool", &params, parsers, iter);
    const input = res.positionals[0] orelse return diag.fail("ibtool: expected a .xib, .storyboard or .nib file", .{});
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(sys.io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};
    const show_types = res.args.types != 0;
    const sfx = fsutil.suffix(input);
    if (res.args.strict != 0 and fsutil.oneOf(sfx, &.{ ".xib", ".storyboard" })) try ibtool.validate(a, input, true);
    if (std.mem.eql(u8, sfx, ".xib")) {
        const bytes, const result = try ibtool.compileXib(a, input);
        if (res.args.strict != 0 and result.warnings > 0) return diag.fail("ibtool: {d} compiler warning(s) in strict mode", .{result.warnings});
        if (res.args.dump != 0 and res.args.output == null) return nib.dump(a, bytes, out, show_types, "");
        const dest = res.args.output orelse try std.fmt.allocPrint(a, "{s}.nib", .{input[0 .. input.len - sfx.len]});
        try sys.cwd().writeFile(sys.io, .{ .sub_path = dest, .data = bytes });
        diag.info("wrote {s}", .{dest});
    } else if (std.mem.eql(u8, sfx, ".storyboard")) {
        const dest = res.args.output orelse try std.fmt.allocPrint(a, "{s}.storyboardc", .{input[0 .. input.len - sfx.len]});
        const result = try ibtool.compileStoryboard(a, input, dest);
        if (res.args.strict != 0 and result.warnings > 0) return diag.fail("ibtool: {d} compiler warning(s) in strict mode", .{result.warnings});
        diag.info("wrote {s}", .{dest});
    } else {
        const bytes = sys.readFile(a, input, 64 << 20) catch |err| return diag.fail("cannot read {s}: {s}", .{ input, @errorName(err) });
        if (!nib.isArchive(bytes)) return diag.fail("{s}: not a .xib, .storyboard or NIBArchive .nib", .{input});
        try nib.dump(a, bytes, out, show_types, "");
    }
}

test {
    _ = @import("buildstate.zig");
    _ = @import("resources.zig");
    _ = @import("ynode.zig");
    _ = @import("plist.zig");
    _ = @import("xcstrings.zig");
    _ = @import("fsutil.zig");
    _ = @import("pbxproj.zig");
    _ = @import("zip.zig");
    _ = @import("macho.zig");
    _ = @import("verify.zig");
    _ = @import("config.zig");
    _ = @import("toolchain.zig");
    _ = @import("codegen.zig");
    _ = @import("builder.zig");
    _ = @import("scaffold.zig");
    _ = @import("jimpactor.zig");
    _ = @import("xmldom.zig");
    _ = @import("nib.zig");
    _ = @import("ibtool.zig");
    _ = @import("quality.zig");
}
