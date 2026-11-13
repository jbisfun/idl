//! Structural IPA validation: ZIP CRCs, bundle metadata, executable mode and
//! Mach-O load commands. Native replacement for `unzip -t` + verify_ipa.py.
const std = @import("std");
const diag = @import("diag.zig");
const zip = @import("zip.zig");
const plist = @import("plist.zig");
const macho = @import("macho.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    bundle_id: ?[]const u8 = null,
    allow_unsigned: bool = false,
    quiet: bool = false,
};

pub const Report = struct {
    bundle_id: []const u8,
    executable: []const u8,
    executable_size: usize,
    minimum_os: []const u8,
    signed: bool,
    platform: []const u8,
    warnings: []const []const u8,
};

pub fn verifyBytes(a: Allocator, bytes: []const u8, opts: Options) !Report {
    const ar = try zip.open(a, bytes);
    for (ar.entries) |e| _ = try ar.read(a, e); // full CRC pass, like `unzip -t`

    var plist_entry: ?zip.Entry = null;
    var found: usize = 0;
    for (ar.entries) |e| {
        if (std.mem.startsWith(u8, e.name, "Payload/") and std.mem.endsWith(u8, e.name, ".app/Info.plist") and std.mem.count(u8, e.name, "/") == 2) {
            found += 1;
            plist_entry = e;
        }
    }
    if (found != 1) return diag.fail("expected one top-level app Info.plist, found {d}", .{found});
    const info = try plist.parse(try ar.read(a, plist_entry.?));
    defer info.deinit();
    if (!info.isDict()) return diag.fail("Info.plist root is not a dictionary", .{});

    var missing = std.ArrayList([]const u8).init(a);
    for ([_][]const u8{ "CFBundleExecutable", "CFBundleIdentifier", "CFBundlePackageType", "MinimumOSVersion" }) |k| {
        const node = try info.get(a, k);
        if (node == null) {
            try missing.append(k);
        } else if (plist.stringOf(node)) |v| if (v.len == 0) try missing.append(k);
    }
    if (missing.items.len > 0) return diag.fail("missing plist keys: {s}", .{try std.mem.join(a, ", ", missing.items)});
    const bundle_id = try a.dupe(u8, try info.getString(a, "CFBundleIdentifier") orelse return diag.fail("CFBundleIdentifier is not a string", .{}));
    const exe_name = try a.dupe(u8, try info.getString(a, "CFBundleExecutable") orelse return diag.fail("CFBundleExecutable is not a string", .{}));
    const min_os = try a.dupe(u8, try info.getString(a, "MinimumOSVersion") orelse return diag.fail("MinimumOSVersion is not a string", .{}));
    if (opts.bundle_id) |expected| if (!std.mem.eql(u8, bundle_id, expected))
        return diag.fail("bundle ID is {s}, expected {s}", .{ bundle_id, expected });

    const app_dir = std.fs.path.dirnamePosix(plist_entry.?.name).?;
    const exe_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ app_dir, exe_name });
    const exe_entry = ar.find(exe_path) orelse return diag.fail("missing executable: {s}", .{exe_path});
    const exe = try ar.read(a, exe_entry);
    const mh = try macho.parse(a, exe);
    if (exe_entry.mode & 0o111 == 0) return diag.fail("executable is not marked executable in ZIP", .{});
    if (mh.cputype != macho.cpu_arm64) return diag.fail("executable CPU type 0x{x} is not arm64", .{mh.cputype});
    if (mh.filetype != macho.mh_execute) return diag.fail("Mach-O file type {d} is not MH_EXECUTE", .{mh.filetype});
    if (!mh.has_main) return diag.fail("Mach-O has no LC_MAIN", .{});
    if (!mh.has_code_signature and !opts.allow_unsigned) return diag.fail("Mach-O has no LC_CODE_SIGNATURE", .{});
    const platform = mh.platform orelse return diag.fail("Mach-O has no LC_BUILD_VERSION platform", .{});
    if (platform != macho.platform_ios) return diag.fail("Mach-O platform is {s}, expected iOS", .{macho.platformName(platform)});

    var warnings = std.ArrayList([]const u8).init(a);
    for (mh.dylibs) |d| if (!macho.isSystemOrBundled(d))
        try warnings.append(try std.fmt.allocPrint(a, "non-system dylib dependency: {s}", .{d}));
    return .{
        .bundle_id = bundle_id,
        .executable = exe_name,
        .executable_size = exe.len,
        .minimum_os = min_os,
        .signed = mh.has_code_signature,
        .platform = macho.platformName(platform),
        .warnings = warnings.items,
    };
}

pub fn verifyFile(a: Allocator, path: []const u8, opts: Options) !Report {
    const bytes = std.fs.cwd().readFileAlloc(a, path, 2 << 30) catch |err|
        return diag.fail("cannot read {s}: {s}", .{ path, @errorName(err) });
    const report = verifyBytes(a, bytes, opts) catch |err| switch (err) {
        error.Invalid => return diag.fail("{s}: {s}", .{ path, diag.msg }),
        else => return err,
    };
    for (report.warnings) |w| diag.warn("{s}", .{w});
    if (!opts.quiet) {
        diag.info("OK: {s}", .{path});
        diag.info("  bundle: {s}", .{report.bundle_id});
        diag.info("  executable: {s} ({d} bytes, {s} arm64)", .{ report.executable, report.executable_size, report.platform });
        diag.info("  minimum iOS: {s}", .{report.minimum_os});
        diag.info("  load commands: LC_MAIN{s}", .{if (report.signed) ", LC_CODE_SIGNATURE" else " (unsigned)"});
    }
    return report;
}
