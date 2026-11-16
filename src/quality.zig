//! Code-quality commands: `idl fmt`, `idl lint` and `idl test`.
//!
//! idl only orchestrates existing tools (clang, swiftc, clang-format,
//! clang-tidy, swift-format). It feeds them the exact per-target compiler
//! invocations a build uses, generates their configurations from idlproj.yml,
//! runs them in parallel and merges their diagnostics into one report.
const std = @import("std");
const diag = @import("diag.zig");
const fsutil = @import("fsutil.zig");
const config = @import("config.zig");
const ynode = @import("ynode.zig");
const plist = @import("plist.zig");
const macho = @import("macho.zig");
const builder = @import("builder.zig");
const codegen = @import("codegen.zig");
const Toolchain = @import("toolchain.zig").Toolchain;

const Allocator = std.mem.Allocator;
const Target = config.Target;

// ------------------------------------------------------------ processes

pub const Task = struct {
    tool: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    label: []const u8 = "",
    // results
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    ok: bool = false,
    spawn_error: ?[]const u8 = null,
};

fn runOne(task: *Task, env: *const std.process.EnvMap) void {
    // The arena is not thread-safe; children use the page allocator and their
    // output simply lives until exit.
    const r = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = task.argv,
        .cwd = task.cwd,
        .env_map = env,
        .max_output_bytes = 256 << 20,
    }) catch |err| {
        task.spawn_error = @errorName(err);
        return;
    };
    task.stdout = r.stdout;
    task.stderr = r.stderr;
    task.ok = r.term == .Exited and r.term.Exited == 0;
}

fn runAll(a: Allocator, tc: *Toolchain, tasks: []Task, jobs: usize, verbose: bool) !void {
    if (tasks.len == 0) return;
    if (verbose) for (tasks) |t| diag.info("  {s}", .{try std.mem.join(a, " ", t.argv)});
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = std.heap.page_allocator, .n_jobs = if (jobs > 0) jobs else @max(1, std.Thread.getCpuCount() catch 4) });
    defer pool.deinit();
    var wg: std.Thread.WaitGroup = .{};
    for (tasks) |*t| pool.spawnWg(&wg, runOne, .{ t, &tc.env });
    pool.waitAndWork(&wg);
}

// ---------------------------------------------------------- diagnostics

pub const Severity = enum { @"error", warning };

pub const Diagnostic = struct {
    tool: []const u8,
    file: []const u8, // absolute
    line: u32,
    col: u32,
    severity: Severity,
    message: []const u8,
    /// `-Wfoo`, clang-tidy check name or swift-format rule; "" if none.
    flag: []const u8,
    /// Source snippet, caret and note lines that followed the diagnostic.
    detail: []const u8,
};

const Header = struct { file: []const u8, line: u32, col: u32, kind: []const u8, message: []const u8 };

/// `path:line[:col]: kind: message` with kind error/fatal error/warning/note/remark.
fn parseHeader(line: []const u8) ?Header {
    const kinds = [_][]const u8{ ": fatal error: ", ": error: ", ": warning: ", ": note: ", ": remark: " };
    for (kinds) |k| {
        const at = std.mem.indexOf(u8, line, k) orelse continue;
        const loc = line[0..at];
        // loc = path:line[:col]
        const last = std.mem.lastIndexOfScalar(u8, loc, ':') orelse return null;
        const n1 = std.fmt.parseInt(u32, loc[last + 1 ..], 10) catch return null;
        const before = loc[0..last];
        var file = before;
        var ln = n1;
        var col: u32 = 0;
        if (std.mem.lastIndexOfScalar(u8, before, ':')) |prev| {
            if (std.fmt.parseInt(u32, before[prev + 1 ..], 10)) |n0| {
                file = before[0..prev];
                ln = n0;
                col = n1;
            } else |_| {}
        }
        if (file.len == 0) return null;
        return .{ .file = file, .line = ln, .col = col, .kind = k[2 .. k.len - 2], .message = line[at + k.len ..] };
    }
    return null;
}

/// Trailing `[...]` (clang flag / tidy check) or leading `[Rule]` (swift-format).
fn splitFlag(message: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.endsWith(u8, message, "]")) if (std.mem.lastIndexOf(u8, message, " [")) |i|
        return .{ message[0..i], message[i + 2 .. message.len - 1] };
    if (std.mem.startsWith(u8, message, "[")) if (std.mem.indexOfScalar(u8, message, ']')) |i|
        return .{ std.mem.trimLeft(u8, message[i + 1 ..], " "), message[1..i] };
    return .{ message, "" };
}

fn isNoise(line: []const u8) bool {
    return line.len == 0 or std.mem.endsWith(u8, line, " generated.") or
        std.mem.startsWith(u8, line, "Suppressed ") or std.mem.startsWith(u8, line, "Use -header-filter") or
        std.mem.startsWith(u8, line, "Error while processing ");
}

fn parseOutput(a: Allocator, tool: []const u8, text: []const u8, cwd: []const u8, out: *std.ArrayList(Diagnostic)) !usize {
    var count: usize = 0;
    var current: ?usize = null;
    var detail = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (parseHeader(line)) |h| {
            if (current) |i| out.items[i].detail = try detail.toOwnedSlice();
            if (std.mem.eql(u8, h.kind, "note") or std.mem.eql(u8, h.kind, "remark")) {
                if (current != null) {
                    try detail.appendSlice(line);
                    try detail.append('\n');
                }
                continue;
            }
            const msg, const flag = splitFlag(h.message);
            try out.append(.{
                .tool = tool,
                .file = try std.fs.path.resolve(a, &.{ cwd, h.file }),
                .line = h.line,
                .col = h.col,
                .severity = if (std.mem.eql(u8, h.kind, "warning")) .warning else .@"error",
                .message = msg,
                .flag = flag,
                .detail = "",
            });
            current = out.items.len - 1;
            count += 1;
        } else if (current != null and !isNoise(line)) {
            try detail.appendSlice(line);
            try detail.append('\n');
        }
    }
    if (current) |i| out.items[i].detail = try detail.toOwnedSlice();
    return count;
}

/// Collect a finished task's diagnostics. A failed tool run that produced no
/// diagnostics is reported as an error of its own.
fn collect(a: Allocator, task: Task, out: *std.ArrayList(Diagnostic)) !void {
    if (task.spawn_error) |e| {
        try out.append(.{ .tool = task.tool, .file = task.label, .line = 0, .col = 0, .severity = .@"error", .message = try std.fmt.allocPrint(a, "cannot run {s}: {s}", .{ task.argv[0], e }), .flag = "", .detail = "" });
        return;
    }
    var n = try parseOutput(a, task.tool, task.stderr, task.cwd, out);
    n += try parseOutput(a, task.tool, task.stdout, task.cwd, out);
    if (!task.ok and n == 0) {
        const tail = std.mem.trim(u8, if (task.stderr.len > 0) task.stderr else task.stdout, " \n");
        try out.append(.{ .tool = task.tool, .file = task.label, .line = 0, .col = 0, .severity = .@"error", .message = "tool failed without diagnostics", .flag = "", .detail = if (tail.len > 2000) tail[tail.len - 2000 ..] else tail });
    }
}

fn diagLess(_: void, l: Diagnostic, r: Diagnostic) bool {
    const fo = std.mem.order(u8, l.file, r.file);
    if (fo != .eq) return fo == .lt;
    if (l.line != r.line) return l.line < r.line;
    if (l.col != r.col) return l.col < r.col;
    return std.mem.lessThan(u8, l.tool, r.tool);
}

/// Sort, drop duplicates (the same header diagnostic from many translation
/// units) and drop diagnostics outside the project or in excluded paths.
fn finalize(a: Allocator, items: []Diagnostic, root: []const u8, excluded: *const fn (ctx: *const anyopaque, abs: []const u8) bool, ctx: *const anyopaque) ![]Diagnostic {
    std.mem.sort(Diagnostic, items, {}, diagLess);
    var out = std.ArrayList(Diagnostic).init(a);
    var seen = std.StringHashMap(void).init(a);
    for (items) |d| {
        if (d.line > 0) {
            if (!std.mem.startsWith(u8, d.file, root)) continue; // SDK / toolchain headers
            if (excluded(ctx, d.file)) continue;
        }
        const key = try std.fmt.allocPrint(a, "{s}|{s}|{d}|{d}|{s}", .{ d.tool, d.file, d.line, d.col, d.message });
        if (seen.contains(key)) continue;
        try seen.put(key, {});
        try out.append(d);
    }
    return out.items;
}

const Totals = struct { errors: usize = 0, warnings: usize = 0 };

fn report(a: Allocator, diags: []const Diagnostic, root: []const u8, quiet: bool, max: ?usize) !Totals {
    const w = std.io.getStdOut().writer();
    var totals: Totals = .{};
    var per_tool = std.StringArrayHashMap(Totals).init(a);
    var per_flag = std.StringArrayHashMap(usize).init(a);
    for (diags, 0..) |d, i| {
        const t = try per_tool.getOrPutValue(d.tool, .{});
        switch (d.severity) {
            .@"error" => {
                totals.errors += 1;
                t.value_ptr.errors += 1;
            },
            .warning => {
                totals.warnings += 1;
                t.value_ptr.warnings += 1;
            },
        }
        if (d.flag.len > 0) (try per_flag.getOrPutValue(d.flag, 0)).value_ptr.* += 1;
        if (quiet or (max != null and i >= max.?)) continue;
        const rel = if (std.mem.startsWith(u8, d.file, root) and d.file.len > root.len) d.file[root.len + 1 ..] else d.file;
        if (d.line > 0) {
            try w.print("{s}:{d}:{d}: {s}: {s}", .{ rel, d.line, d.col, @tagName(d.severity), d.message });
        } else try w.print("{s}: {s}: {s}", .{ rel, @tagName(d.severity), d.message });
        if (d.flag.len > 0) try w.print(" [{s}]", .{d.flag});
        try w.print("  ({s})\n", .{d.tool});
        if (d.detail.len > 0) try w.writeAll(d.detail);
    }
    if (max) |m| if (!quiet and diags.len > m) try w.print("... {d} more (raise --max or use --quiet)\n", .{diags.len - m});
    try w.writeAll("\nsummary:\n");
    for (per_tool.keys(), per_tool.values()) |tool, t| try w.print("  {s:<14} {d} error(s), {d} warning(s)\n", .{ tool, t.errors, t.warnings });
    if (per_tool.count() == 0) try w.writeAll("  no diagnostics\n");
    if (per_flag.count() > 0) {
        const Entry = struct { []const u8, usize };
        var flags = std.ArrayList(Entry).init(a);
        for (per_flag.keys(), per_flag.values()) |k, v| try flags.append(.{ k, v });
        std.mem.sort(Entry, flags.items, {}, struct {
            fn less(_: void, l: Entry, r: Entry) bool {
                return l[1] > r[1] or (l[1] == r[1] and std.mem.lessThan(u8, l[0], r[0]));
            }
        }.less);
        try w.writeAll("  most frequent:");
        for (flags.items[0..@min(8, flags.items.len)]) |e| try w.print(" {s}={d}", .{ e[0], e[1] });
        try w.writeAll("\n");
    }
    return totals;
}

// ------------------------------------------------------- generated configs

fn yamlScalar(w: anytype, s: ynode.Scalar) !void {
    if (!s.quoted) return w.writeAll(s.text);
    try w.writeByte('\'');
    for (s.text) |ch| if (ch == '\'') try w.writeAll("''") else try w.writeByte(ch);
    try w.writeByte('\'');
}

fn emitYaml(w: anytype, n: ynode.Node, indent: usize) anyerror!void {
    switch (n) {
        .null => try w.writeAll("~\n"),
        .scalar => |s| {
            try yamlScalar(w, s);
            try w.writeByte('\n');
        },
        .list => |items| {
            try w.writeByte('\n');
            for (items) |item| {
                try w.writeByteNTimes(' ', indent);
                try w.writeAll("- ");
                if (item == .map) {
                    // first key inline after "- "
                    for (item.map.keys, item.map.values, 0..) |k, v, i| {
                        if (i > 0) try w.writeByteNTimes(' ', indent + 2);
                        try w.print("{s}: ", .{k});
                        try emitYaml(w, v, indent + 4);
                    }
                } else try emitYaml(w, item, indent + 2);
            }
        },
        .map => |m| {
            try w.writeByte('\n');
            for (m.keys, m.values) |k, v| {
                try w.writeByteNTimes(' ', indent);
                try w.print("{s}: ", .{k});
                try emitYaml(w, v, indent + 2);
            }
        },
    }
}

fn jsonValue(a: Allocator, n: ynode.Node) !std.json.Value {
    return switch (n) {
        .null => .null,
        .scalar => |s| blk: {
            if (!s.quoted) {
                if (std.mem.eql(u8, s.text, "true")) break :blk .{ .bool = true };
                if (std.mem.eql(u8, s.text, "false")) break :blk .{ .bool = false };
                if (std.fmt.parseInt(i64, s.text, 10)) |i| break :blk .{ .integer = i } else |_| {}
            }
            break :blk .{ .string = s.text };
        },
        .list => |items| blk: {
            var arr = std.json.Array.init(a);
            for (items) |item| try arr.append(try jsonValue(a, item));
            break :blk .{ .array = arr };
        },
        .map => |m| blk: {
            var obj = std.json.ObjectMap.init(a);
            for (m.keys, m.values) |k, v| try obj.put(k, try jsonValue(a, v));
            break :blk .{ .object = obj };
        },
    };
}

fn deepMerge(a: Allocator, base: *std.json.ObjectMap, over: std.json.ObjectMap) !void {
    var it = over.iterator();
    while (it.next()) |e| {
        if (base.getPtr(e.key_ptr.*)) |old| if (old.* == .object and e.value_ptr.* == .object) {
            try deepMerge(a, &old.object, e.value_ptr.object);
            continue;
        };
        try base.put(e.key_ptr.*, e.value_ptr.*);
    }
}

pub fn clangFormatConfig(a: Allocator, t: Target) ![]const u8 {
    var b = std.ArrayList(u8).init(a);
    const w = b.writer();
    try w.print("# {s}; edit `format:` there instead.\n", .{codegen.marker});
    const overrides = t.format.clang_format;
    const defaults = [_][2][]const u8{
        .{ "BasedOnStyle", "LLVM" },
        .{ "IndentWidth", t.format.indent },
        .{ "ObjCBlockIndentWidth", t.format.indent },
        .{ "ColumnLimit", t.format.line_length },
        .{ "ObjCSpaceAfterProperty", "true" },
        .{ "ObjCSpaceBeforeProtocolList", "true" },
        .{ "SortIncludes", "Never" },
        .{ "AllowShortFunctionsOnASingleLine", "Empty" },
    };
    for (defaults) |kv| {
        if (overrides) |o| if (o.get(kv[0]) != null) continue;
        try w.print("{s}: {s}\n", .{ kv[0], kv[1] });
    }
    if (overrides) |o| for (o.keys, o.values) |k, v| {
        try w.print("{s}: ", .{k});
        try emitYaml(w, v, 2);
    };
    return b.items;
}

/// Bug-finding checks with a low false-positive rate on Objective-C / C++ code.
const default_tidy_checks = "clang-diagnostic-*,clang-analyzer-*,bugprone-*," ++
    "-bugprone-easily-swappable-parameters,-bugprone-reserved-identifier,-bugprone-narrowing-conversions," ++
    "-bugprone-implicit-widening-of-multiplication-result,-bugprone-signed-bitwise,-bugprone-assignment-in-if-condition," ++
    "-bugprone-multi-level-implicit-pointer-conversion,-bugprone-switch-missing-default-case," ++
    "performance-*,-performance-no-int-to-ptr";

pub fn clangTidyConfig(a: Allocator, t: Target) ![]const u8 {
    const checks = if (t.lint.clang_tidy_checks.len > 0) try std.mem.join(a, ",", t.lint.clang_tidy_checks) else default_tidy_checks;
    return std.fmt.allocPrint(a, "# {s}; edit `lint:` there instead.\nChecks: '{s}'\nWarningsAsErrors: ''\nHeaderFilterRegex: ''\n", .{ codegen.marker, checks });
}

pub fn swiftFormatConfig(a: Allocator, t: Target) ![]const u8 {
    var root = std.json.ObjectMap.init(a);
    try root.put("_generated", .{ .string = codegen.marker ++ "; edit `format:` there instead." });
    try root.put("version", .{ .integer = 1 });
    var indentation = std.json.ObjectMap.init(a);
    try indentation.put("spaces", .{ .integer = try std.fmt.parseInt(i64, t.format.indent, 10) });
    try root.put("indentation", .{ .object = indentation });
    const len = try std.fmt.parseInt(i64, t.format.line_length, 10);
    try root.put("lineLength", .{ .integer = if (len == 0) 10000 else len });
    try root.put("respectsExistingLineBreaks", .{ .bool = true });
    try root.put("lineBreakBeforeEachArgument", .{ .bool = false });
    try root.put("maximumBlankLines", .{ .integer = 2 });
    if (t.format.swift_format) |o| {
        const over = try jsonValue(a, .{ .map = o });
        try deepMerge(a, &root, over.object);
    }
    var out = std.ArrayList(u8).init(a);
    try std.json.stringify(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }, out.writer());
    try out.append('\n');
    return out.items;
}

/// Tool configs in `<target dir>/.idl/quality/<target>/`, passed explicitly.
const Configs = struct { clang_format: []const u8, clang_tidy: []const u8, swift_format: []const u8 };

fn writeConfigs(a: Allocator, t: Target) !Configs {
    const dir = try std.fs.path.join(a, &.{ t.dir, ".idl", "quality", t.name });
    try std.fs.cwd().makePath(dir);
    const c: Configs = .{
        .clang_format = try std.fs.path.join(a, &.{ dir, "clang-format.yml" }),
        .clang_tidy = try std.fs.path.join(a, &.{ dir, "clang-tidy.yml" }),
        .swift_format = try std.fs.path.join(a, &.{ dir, "swift-format.json" }),
    };
    _ = try fsutil.writeIfChanged(a, c.clang_format, try clangFormatConfig(a, t));
    _ = try fsutil.writeIfChanged(a, c.clang_tidy, try clangTidyConfig(a, t));
    _ = try fsutil.writeIfChanged(a, c.swift_format, try swiftFormatConfig(a, t));
    return c;
}

/// `idl gen` with `format.editor_configs: true`: dotfiles for clangd / sourcekit-lsp.
pub fn genEditorConfigs(a: Allocator, t: Target) !void {
    if (!t.format.editor_configs) return;
    for ([_]struct { []const u8, []const u8 }{
        .{ ".clang-format", try clangFormatConfig(a, t) },
        .{ ".clang-tidy", try clangTidyConfig(a, t) },
        .{ ".swift-format", try swiftFormatConfig(a, t) },
    }) |f| {
        const path = try t.path(a, f[0]);
        const changed = try codegen.writeGenerated(a, path, f[1]);
        if (!@import("builtin").is_test) diag.info("  GEN  {s}{s}", .{ path, if (changed) "" else " (unchanged)" });
    }
}

// ----------------------------------------------------------- tool lookup

fn findTool(a: Allocator, tc: *Toolchain, name: []const u8) !?[]const u8 {
    return fsutil.which(a, try fsutil.expandHome(a, name, &tc.env), tc.pathEnv());
}

fn excludedBy(a: Allocator, t: Target, patterns: []const []const u8, abs: []const u8) bool {
    _ = a;
    if (!std.mem.startsWith(u8, abs, t.dir) or abs.len <= t.dir.len) return false;
    const rel = abs[t.dir.len + 1 ..];
    for (patterns) |p| if (fsutil.pathMatches(p, rel)) return true;
    return false;
}

const ExcludeCtx = struct { a: Allocator, targets: []const Target, which: enum { lint, format } };

fn excludedAny(ctx_ptr: *const anyopaque, abs: []const u8) bool {
    const ctx: *const ExcludeCtx = @ptrCast(@alignCast(ctx_ptr));
    for (ctx.targets) |t| {
        const pats = if (ctx.which == .lint) t.lint.exclude else t.format.exclude;
        if (excludedBy(ctx.a, t, pats, abs)) return true;
    }
    return false;
}

fn chunks(a: Allocator, items: []const []const u8, n: usize) ![]const []const []const u8 {
    var out = std.ArrayList([]const []const u8).init(a);
    var i: usize = 0;
    while (i < items.len) : (i += n) try out.append(items[i..@min(items.len, i + n)]);
    return out.items;
}

// ------------------------------------------------------------------- fmt

pub const FmtOptions = struct { check: bool = false, jobs: usize = 0, verbose: bool = false };

const c_like = [_][]const u8{ ".c", ".m", ".mm", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx" };

pub fn fmt(a: Allocator, tc: *Toolchain, root: []const u8, targets: []const Target, opts: FmtOptions) !bool {
    const clang_format = try findTool(a, tc, tc.cfg.clang_format);
    const swift_format = try findTool(a, tc, tc.cfg.swift_format);
    var seen = std.StringHashMap(void).init(a);
    var tasks = std.ArrayList(Task).init(a);
    var originals = std.StringArrayHashMap([]const u8).init(a);
    var skipped_c: usize = 0;
    var skipped_swift: usize = 0;
    for (targets) |t| {
        const cfgs = try writeConfigs(a, t);
        var c_files = std.ArrayList([]const u8).init(a);
        var swift_files = std.ArrayList([]const u8).init(a);
        for (try fsutil.discover(a, t.dir, t.sources, "source")) |rel| {
            const abs = try t.path(a, rel);
            if (excludedBy(a, t, t.format.exclude, abs) or seen.contains(abs)) continue;
            try seen.put(abs, {});
            const sfx = fsutil.suffix(rel);
            if (std.mem.eql(u8, sfx, ".swift")) try swift_files.append(abs) else if (fsutil.oneOf(sfx, &c_like)) try c_files.append(abs) else continue;
            if (!opts.check) try originals.put(abs, try std.fs.cwd().readFileAlloc(a, abs, 64 << 20));
        }
        if (c_files.items.len > 0) if (clang_format) |cf| {
            const style = try std.fmt.allocPrint(a, "--style=file:{s}", .{cfgs.clang_format});
            for (try chunks(a, c_files.items, 40)) |chunk| {
                var argv = std.ArrayList([]const u8).init(a);
                try argv.appendSlice(if (opts.check) &.{ cf, "--dry-run", "-Werror", style } else &.{ cf, "-i", style });
                try argv.appendSlice(chunk);
                try tasks.append(.{ .tool = "clang-format", .argv = argv.items, .cwd = root, .label = t.name });
            }
        } else {
            skipped_c += c_files.items.len;
        };
        if (swift_files.items.len > 0) if (swift_format) |sf| {
            if (opts.check) {
                // Formatted output vs. the file; reported as one diagnostic per file.
                for (swift_files.items) |f| try tasks.append(.{ .tool = "swift-format", .argv = try a.dupe([]const u8, &.{ sf, "format", "--configuration", cfgs.swift_format, f }), .cwd = root, .label = f });
            } else for (try chunks(a, swift_files.items, 40)) |chunk| {
                var argv = std.ArrayList([]const u8).init(a);
                try argv.appendSlice(&.{ sf, "format", "--in-place", "--configuration", cfgs.swift_format });
                try argv.appendSlice(chunk);
                try tasks.append(.{ .tool = "swift-format", .argv = argv.items, .cwd = root, .label = t.name });
            }
        } else {
            skipped_swift += swift_files.items.len;
        };
    }
    if (skipped_c > 0) diag.warn("clang-format not found ({s}); {d} C/Objective-C/C++ file(s) not checked", .{ tc.cfg.clang_format, skipped_c });
    if (skipped_swift > 0) diag.warn("swift-format not found ({s}); {d} Swift file(s) not checked", .{ tc.cfg.swift_format, skipped_swift });
    diag.info("==> {s} {d} file(s) with {d} tool run(s)", .{ if (opts.check) "checking" else "formatting", seen.count(), tasks.items.len });
    try runAll(a, tc, tasks.items, opts.jobs, opts.verbose);
    // clang-format is not always idempotent in one pass (alignment that depends
    // on its own earlier changes); repeat until the files stop changing.
    if (!opts.check) {
        var previous = std.StringArrayHashMap([]const u8).init(a);
        for (originals.keys()) |path| try previous.put(path, std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch "");
        var pass: usize = 1;
        while (pass < 4) : (pass += 1) {
            for (tasks.items) |*t| {
                t.stdout = "";
                t.stderr = "";
                t.ok = false;
                t.spawn_error = null;
            }
            try runAll(a, tc, tasks.items, opts.jobs, false);
            var moved = false;
            for (previous.keys(), previous.values()) |path, *content| {
                const now = std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch continue;
                if (!std.mem.eql(u8, now, content.*)) {
                    moved = true;
                    content.* = now;
                }
            }
            if (!moved) break;
        }
    }

    var diags = std.ArrayList(Diagnostic).init(a);
    for (tasks.items) |task| {
        if (opts.check and std.mem.eql(u8, task.tool, "swift-format")) {
            if (task.ok) {
                const current = try std.fs.cwd().readFileAlloc(a, task.label, 64 << 20);
                if (!std.mem.eql(u8, current, task.stdout))
                    try diags.append(.{ .tool = "swift-format", .file = task.label, .line = 1, .col = 1, .severity = .@"error", .message = "code should be swift-formatted", .flag = "", .detail = "" });
                continue;
            }
        }
        try collect(a, task, &diags);
    }
    if (opts.check) {
        // One line per file is enough for a format check.
        var per_file = std.ArrayList(Diagnostic).init(a);
        var files = std.StringHashMap(void).init(a);
        for (diags.items) |d| {
            if (d.line > 0 and files.contains(d.file)) continue;
            try files.put(d.file, {});
            var one = d;
            one.detail = "";
            try per_file.append(one);
        }
        const ctx: ExcludeCtx = .{ .a = a, .targets = targets, .which = .format };
        const final = try finalize(a, per_file.items, root, excludedAny, &ctx);
        const totals = try report(a, final, root, false, null);
        return totals.errors == 0;
    }
    var changed: usize = 0;
    for (originals.keys(), originals.values()) |path, before| {
        const after = std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch continue;
        if (!std.mem.eql(u8, before, after)) {
            changed += 1;
            if (opts.verbose) diag.info("  formatted {s}", .{path});
        }
    }
    const ctx: ExcludeCtx = .{ .a = a, .targets = targets, .which = .format };
    const final = try finalize(a, diags.items, root, excludedAny, &ctx);
    if (final.len > 0) _ = try report(a, final, root, false, null);
    diag.info("{d} of {d} file(s) changed", .{ changed, originals.count() });
    for (final) |d| if (d.severity == .@"error") return false;
    return true;
}

// ------------------------------------------------------------------ lint

pub const LintOptions = struct {
    jobs: usize = 0,
    verbose: bool = false,
    werror: bool = false,
    analyze: bool = false,
    tidy: ?bool = null,
    quiet: bool = false,
    max: ?usize = null,
};

const dropped_c = [_][]const u8{ "-w", "-MMD", "-MP", "-Werror" };

fn lintArgv(a: Allocator, argv: []const []const u8, skip_first: bool) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).init(a);
    for (argv[if (skip_first) 1 else 0..]) |arg| {
        if (fsutil.oneOf(arg, &dropped_c) or std.mem.startsWith(u8, arg, "-Werror=")) continue;
        try out.append(arg);
    }
    return out;
}

/// `targets` must already be built (their products are in `products`).
pub fn lint(a: Allocator, tc: *Toolchain, root: []const u8, targets: []const Target, products: *builder.Products, opts: LintOptions) !bool {
    const clang_tidy = try findTool(a, tc, tc.cfg.clang_tidy);
    const swift_format = try findTool(a, tc, tc.cfg.swift_format);
    var tasks = std.ArrayList(Task).init(a);
    var tools_used = std.StringArrayHashMap(void).init(a);
    for (targets) |t| {
        if (t.builder != .direct) {
            diag.warn("{s}: xtool targets are not linted", .{t.name});
            continue;
        }
        const inv = try builder.invocations(a, tc, t, products);
        const cfgs = try writeConfigs(a, t);
        const want_tidy = opts.tidy orelse (t.lint.clang_tidy orelse true);
        if (want_tidy and clang_tidy == null and (opts.tidy orelse t.lint.clang_tidy orelse false))
            return diag.fail("clang-tidy requested but not found ({s})", .{tc.cfg.clang_tidy});
        for (inv.c_family) |src| {
            if (excludedBy(a, t, t.lint.exclude, src.path)) continue;
            // 1. compiler warnings with the target's real flags
            var argv = try lintArgv(a, src.argv, false);
            try argv.appendSlice(t.lint.warnings);
            try argv.appendSlice(&.{ "-fsyntax-only", src.path });
            try tasks.append(.{ .tool = "clang", .argv = argv.items, .cwd = t.dir, .label = src.path });
            try tools_used.put("clang", {});
            // 2. static analyzer
            if (opts.analyze or t.lint.analyze) {
                var an = try lintArgv(a, src.argv, false);
                try an.appendSlice(&.{ "--analyze", "-Xanalyzer", "-analyzer-output=text", "-o", "/dev/null", src.path });
                try tasks.append(.{ .tool = "analyzer", .argv = an.items, .cwd = t.dir, .label = src.path });
                try tools_used.put("analyzer", {});
            }
            // 3. clang-tidy, with the same flags after `--`
            if (want_tidy) if (clang_tidy) |tidy| {
                var ti = std.ArrayList([]const u8).init(a);
                try ti.appendSlice(&.{ tidy, "--quiet", try std.fmt.allocPrint(a, "--config-file={s}", .{cfgs.clang_tidy}), src.path, "--" });
                try ti.appendSlice((try lintArgv(a, src.argv, true)).items);
                try tasks.append(.{ .tool = "clang-tidy", .argv = ti.items, .cwd = t.dir, .label = src.path });
                try tools_used.put("clang-tidy", {});
            };
        }
        if (inv.swift) |swift_argv| {
            // 4. Swift type-check with warnings on (one whole-module run)
            var argv = std.ArrayList([]const u8).init(a);
            for (swift_argv) |arg| if (!fsutil.oneOf(arg, &.{ "-suppress-warnings", "-warnings-as-errors" })) try argv.append(arg);
            try argv.appendSlice(t.lint.swift_flags);
            try argv.append("-typecheck");
            try tasks.append(.{ .tool = "swiftc", .argv = argv.items, .cwd = t.dir, .label = t.name });
            try tools_used.put("swiftc", {});
            // 5. swift-format style rules
            if (t.lint.swift_format) {
                const sf = swift_format orelse return diag.fail("{s}: lint.swift_format is on but swift-format was not found ({s})", .{ t.name, tc.cfg.swift_format });
                var files = std.ArrayList([]const u8).init(a);
                for (inv.swift_files) |f| if (!excludedBy(a, t, t.lint.exclude, f)) try files.append(f);
                for (try chunks(a, files.items, 60)) |chunk| {
                    var sl = std.ArrayList([]const u8).init(a);
                    try sl.appendSlice(&.{ sf, "lint", "--configuration", cfgs.swift_format });
                    try sl.appendSlice(chunk);
                    try tasks.append(.{ .tool = "swift-format", .argv = sl.items, .cwd = t.dir, .label = t.name });
                }
                try tools_used.put("swift-format", {});
            }
        }
    }
    if (clang_tidy == null) diag.info("note: clang-tidy not found ({s}); skipping that pass", .{tc.cfg.clang_tidy});
    diag.info("==> linting {d} target(s): {d} tool run(s) [{s}]", .{ targets.len, tasks.items.len, try std.mem.join(a, ", ", tools_used.keys()) });
    try runAll(a, tc, tasks.items, opts.jobs, opts.verbose);
    var diags = std.ArrayList(Diagnostic).init(a);
    for (tasks.items) |task| try collect(a, task, &diags);
    const ctx: ExcludeCtx = .{ .a = a, .targets = targets, .which = .lint };
    const final = try finalize(a, diags.items, root, excludedAny, &ctx);
    const totals = try report(a, final, root, opts.quiet, opts.max);
    return totals.errors == 0 and (!opts.werror or totals.warnings == 0);
}

// ------------------------------------------------------------------ test

pub const TestOptions = struct { verbose: bool = false };

const Issue = struct { severity: Severity, msg: []const u8 };

const BundleCheck = struct {
    a: Allocator,
    tc: *Toolchain,
    app: []const u8,
    app_id: []const u8,
    min_os: []const u8,
    signed: bool,
    /// Directories holding executables that start a process (app + appexes).
    exe_dirs: std.ArrayList([]const u8),
    issues: std.ArrayList(Issue),
    checked: usize = 0,

    fn add(b: *BundleCheck, sev: Severity, comptime f: []const u8, args: anytype) !void {
        try b.issues.append(.{ .severity = sev, .msg = try std.fmt.allocPrint(b.a, f, args) });
    }

    fn rel(b: *BundleCheck, path: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, path, b.app) and path.len > b.app.len) path[b.app.len + 1 ..] else path;
    }

    fn versionNumber(s: []const u8) u32 {
        var it = std.mem.splitScalar(u8, s, '.');
        var parts = [3]u32{ 0, 0, 0 };
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) if (i < 3) {
            parts[i] = std.fmt.parseInt(u32, p, 10) catch 0;
        };
        return (parts[0] << 16) | (parts[1] << 8) | parts[2];
    }

    /// Path of a system library's stub in the SDK (`.tbd`), if any.
    fn sdkStub(b: *BundleCheck, install: []const u8) !?[]const u8 {
        const sdk = b.tc.sdk orelse return null;
        const base = if (std.mem.endsWith(u8, install, ".dylib")) install[0 .. install.len - ".dylib".len] else install;
        const tbd = try std.fmt.allocPrint(b.a, "{s}{s}.tbd", .{ sdk, base });
        if (fsutil.kindFollow(tbd) == .file) return tbd;
        const raw = try std.fmt.allocPrint(b.a, "{s}{s}", .{ sdk, install });
        if (fsutil.kindFollow(raw) == .file) return raw;
        return null;
    }

    fn resolve(b: *BundleCheck, dep: []const u8, loader_dir: []const u8, rpaths: []const []const u8) !bool {
        // Already expanded to a path inside the bundle.
        if (std.mem.startsWith(u8, dep, b.app)) return fsutil.kind(dep) == .file;
        // A device path (e.g. rpath /usr/lib/swift): resolvable if the SDK has it.
        if (dep[0] == '/') return try b.sdkStub(dep) != null;
        if (std.mem.startsWith(u8, dep, "@rpath/")) {
            for (rpaths) |rp| if (try b.resolve(try std.fmt.allocPrint(b.a, "{s}/{s}", .{ rp, dep["@rpath/".len..] }), loader_dir, &.{})) return true;
            // The OS Swift runtime (iOS 12.2+) is found through the loading
            // chain's /usr/lib/swift rpath, not necessarily the image's own.
            const name = dep["@rpath/".len..];
            if (std.mem.startsWith(u8, name, "libswift") and std.mem.indexOfScalar(u8, name, '/') == null)
                return try b.sdkStub(try std.fmt.allocPrint(b.a, "/usr/lib/swift/{s}", .{name})) != null;
            return false;
        }
        if (std.mem.startsWith(u8, dep, "@loader_path/"))
            return fsutil.kind(try std.fs.path.resolve(b.a, &.{ loader_dir, dep["@loader_path/".len..] })) == .file;
        if (std.mem.startsWith(u8, dep, "@executable_path/")) {
            for (b.exe_dirs.items) |d| if (fsutil.kind(try std.fs.path.resolve(b.a, &.{ d, dep["@executable_path/".len..] })) == .file) return true;
            return false;
        }
        return false;
    }

    fn checkMachO(b: *BundleCheck, path: []const u8, bytes: []const u8) !void {
        b.checked += 1;
        const r = b.rel(path);
        const info = macho.parse(b.a, bytes) catch {
            try b.add(.@"error", "{s}: {s}", .{ r, diag.msg });
            return;
        };
        if (info.cputype != macho.cpu_arm64) try b.add(.@"error", "{s}: CPU type 0x{x} is not arm64", .{ r, info.cputype });
        if (info.platform) |p| {
            if (p != macho.platform_ios) try b.add(.@"error", "{s}: platform {s}, expected iOS", .{ r, macho.platformName(p) });
        } else try b.add(.warning, "{s}: no LC_BUILD_VERSION", .{r});
        if (b.signed and !info.has_code_signature) try b.add(.@"error", "{s}: not signed (no LC_CODE_SIGNATURE)", .{r});
        const in_appex = std.mem.indexOf(u8, r, ".appex/") != null;
        if (!in_appex) if (info.min_os) |v| if (v > versionNumber(b.min_os)) {
            var buf: [32]u8 = undefined;
            try b.add(.@"error", "{s}: minimum iOS {s} is above the app's MinimumOSVersion {s}", .{ r, macho.formatVersion(&buf, v), b.min_os });
        };
        const dir = std.fs.path.dirname(path).?;
        var rpaths = std.ArrayList([]const u8).init(b.a);
        for (info.rpaths) |rp| {
            if (std.mem.startsWith(u8, rp, "@loader_path")) {
                try rpaths.append(try std.fs.path.resolve(b.a, &.{ dir, rp["@loader_path".len..] }));
            } else if (std.mem.startsWith(u8, rp, "@executable_path")) {
                for (b.exe_dirs.items) |d| try rpaths.append(try std.fs.path.resolve(b.a, &.{ d, std.mem.trimLeft(u8, rp["@executable_path".len..], "/") }));
            } else try rpaths.append(rp);
        }
        for (info.dylibs) |dep| {
            const weak = for (info.weak_dylibs) |w| {
                if (std.mem.eql(u8, w, dep)) break true;
            } else false;
            if (dep[0] == '@') {
                if (!try b.resolve(dep, dir, rpaths.items))
                    try b.add(if (weak) .warning else .@"error", "{s}: cannot resolve {s}{s} inside the bundle", .{ r, dep, if (weak) " (weak)" else "" });
            } else if (std.mem.startsWith(u8, dep, "/System/Library/PrivateFrameworks/")) {
                try b.add(.warning, "{s}: links private framework {s}", .{ r, dep });
            } else if (std.mem.startsWith(u8, dep, "/usr/lib/") or std.mem.startsWith(u8, dep, "/System/Library/")) {
                if (try b.sdkStub(dep) == null)
                    try b.add(if (weak) .warning else .@"error", "{s}: {s} is not in the iOS SDK", .{ r, dep });
            } else try b.add(.@"error", "{s}: absolute dependency {s} does not exist on iOS", .{ r, dep });
        }
    }

    fn checkBundle(b: *BundleCheck, dir: []const u8) !void {
        const r = b.rel(dir);
        const label = if (r.len == 0 or std.mem.eql(u8, dir, b.app)) std.fs.path.basename(dir) else r;
        const info_path = try std.fs.path.join(b.a, &.{ dir, "Info.plist" });
        const info = plist.readFile(b.a, info_path) catch {
            try b.add(.@"error", "{s}: missing or unreadable Info.plist", .{label});
            return;
        };
        defer info.deinit();
        const exe = try info.getString(b.a, "CFBundleExecutable");
        if (exe) |e| {
            if (fsutil.kind(try std.fs.path.join(b.a, &.{ dir, e })) != .file) try b.add(.@"error", "{s}: CFBundleExecutable {s} does not exist", .{ label, e });
        } else try b.add(.@"error", "{s}: no CFBundleExecutable", .{label});
        for ([_][]const u8{ "CFBundleVersion", "CFBundleShortVersionString" }) |k| {
            const node = try info.get(b.a, k);
            if (node != null and plist.stringOf(node) == null) try b.add(.@"error", "{s}: {s} must be a string", .{ label, k });
        }
        const id = try info.getString(b.a, "CFBundleIdentifier");
        if (id == null) try b.add(.@"error", "{s}: no CFBundleIdentifier", .{label});
        if (std.mem.endsWith(u8, dir, ".appex")) {
            if (id) |i| if (!std.mem.startsWith(u8, i, b.app_id) or i.len <= b.app_id.len or i[b.app_id.len] != '.')
                try b.add(.@"error", "{s}: bundle ID {s} must start with {s}.", .{ label, i, b.app_id });
            if (try info.get(b.a, "NSExtension") == null and try info.get(b.a, "EXAppExtensionAttributes") == null)
                try b.add(.@"error", "{s}: no NSExtension / EXAppExtensionAttributes", .{label});
        }
    }

    fn walk(b: *BundleCheck, dir: []const u8) !void {
        var d = try std.fs.cwd().openDir(dir, .{ .iterate = true, .no_follow = true });
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            const p = try std.fs.path.join(b.a, &.{ dir, e.name });
            switch (e.kind) {
                .directory => {
                    if (fsutil.oneOf(fsutil.suffix(e.name), &.{ ".appex", ".framework" })) try b.checkBundle(p);
                    try b.walk(p);
                },
                .file => {
                    const f = try std.fs.cwd().openFile(p, .{});
                    defer f.close();
                    var magic: [4]u8 = undefined;
                    if (try f.readAll(&magic) < 4) continue;
                    const m = std.mem.readInt(u32, &magic, .little);
                    if (m == 0xfeedfacf or m == 0xfeedface or m == 0xbebafeca) try b.checkMachO(p, try std.fs.cwd().readFileAlloc(b.a, p, 1 << 30));
                },
                .sym_link => try b.add(.@"error", "{s}: symlink in bundle", .{b.rel(p)}),
                else => {},
            }
        }
    }
};

fn checkApp(a: Allocator, tc: *Toolchain, t: Target, app: []const u8) ![]const Issue {
    const info = try plist.readFile(a, try std.fs.path.join(a, &.{ app, "Info.plist" }));
    defer info.deinit();
    var b: BundleCheck = .{
        .a = a,
        .tc = tc,
        .app = app,
        .app_id = try a.dupe(u8, (try info.getString(a, "CFBundleIdentifier")) orelse t.bundle_id),
        .min_os = try a.dupe(u8, (try info.getString(a, "MinimumOSVersion")) orelse t.min_ios),
        .signed = t.signs(),
        .exe_dirs = std.ArrayList([]const u8).init(a),
        .issues = std.ArrayList(Issue).init(a),
    };
    try b.exe_dirs.append(app);
    const plugins = try std.fs.path.join(a, &.{ app, "PlugIns" });
    if (std.fs.cwd().openDir(plugins, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| if (std.mem.endsWith(u8, e.name, ".appex")) try b.exe_dirs.append(try std.fs.path.join(a, &.{ plugins, e.name }));
    } else |_| {}
    try b.checkBundle(app);
    try b.walk(app);
    if (b.checked == 0) try b.add(.@"error", "no Mach-O files found", .{});
    if (!@import("builtin").is_test) diag.info("  checked {d} Mach-O file(s)", .{b.checked});
    return b.issues.items;
}

/// Bundle checks for each app's built Payload, then its `tests:` commands.
/// The targets must already be built.
pub fn runTests(a: Allocator, tc: *Toolchain, apps: []const Target, opts: TestOptions) !bool {
    const w = std.io.getStdOut().writer();
    var failed: usize = 0;
    var passed: usize = 0;
    for (apps) |t| {
        const build_dir = try t.buildPath(a);
        const app = try std.fmt.allocPrint(a, "{s}/Payload/{s}.app", .{ build_dir, t.name });
        diag.info("==> {s}: bundle checks", .{t.name});
        if (fsutil.kind(app) != .dir) return diag.fail("{s} does not exist; build {s} first", .{ app, t.name });
        const issues = try checkApp(a, tc, t, app);
        var errors: usize = 0;
        for (issues) |i| {
            try w.print("  {s}: {s}\n", .{ @tagName(i.severity), i.msg });
            if (i.severity == .@"error") errors += 1;
        }
        if (errors > 0) {
            failed += 1;
            try w.print("FAIL {s} bundle checks ({d} error(s))\n", .{ t.name, errors });
        } else {
            passed += 1;
            try w.print("PASS {s} bundle checks\n", .{t.name});
        }
        var env = std.process.EnvMap.init(a);
        var it = tc.env.iterator();
        while (it.next()) |kv| try env.put(kv.key_ptr.*, kv.value_ptr.*);
        try env.put("IDL_IPA", try t.ipaPath(a));
        try env.put("IDL_APP", app);
        try env.put("IDL_BUILD_DIR", build_dir);
        try env.put("IDL_TARGET", t.name);
        try env.put("IDL", try std.fs.selfExePathAlloc(a));
        for (t.tests) |argv| {
            const label = try std.mem.join(a, " ", argv);
            diag.info("==> {s}: {s}", .{ t.name, label });
            if (opts.verbose) diag.info("  (cwd {s})", .{t.dir});
            var child = std.process.Child.init(argv, a);
            child.cwd = t.dir;
            child.env_map = &env;
            const ok = blk: {
                child.spawn() catch |err| {
                    diag.warn("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
                    break :blk false;
                };
                const term = try child.wait();
                break :blk term == .Exited and term.Exited == 0;
            };
            if (ok) passed += 1 else failed += 1;
            try w.print("{s} {s}: {s}\n", .{ if (ok) "PASS" else "FAIL", t.name, label });
        }
    }
    try w.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    return failed == 0;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "diagnostic headers, flags and details" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = std.ArrayList(Diagnostic).init(a);
    const text =
        \\Sources/a.m:12:5: warning: unused variable 'x' [-Wunused-variable]
        \\   12 |     int x;
        \\      |         ^
        \\Sources/a.m:3:1: note: previous declaration is here
        \\/abs/b.swift:7:9: error: cannot find 'y' in scope
        \\c.swift:2:1: warning: [TrailingWhitespace] remove trailing whitespace
        \\2 warnings generated.
        \\
    ;
    try testing.expectEqual(@as(usize, 3), try parseOutput(a, "clang", text, "/proj", &out));
    const d = out.items[0];
    try testing.expectEqualStrings("/proj/Sources/a.m", d.file);
    try testing.expectEqual(@as(u32, 12), d.line);
    try testing.expectEqualStrings("unused variable 'x'", d.message);
    try testing.expectEqualStrings("-Wunused-variable", d.flag);
    try testing.expect(std.mem.indexOf(u8, d.detail, "previous declaration") != null);
    try testing.expectEqual(Severity.@"error", out.items[1].severity);
    try testing.expectEqualStrings("TrailingWhitespace", out.items[2].flag);
    try testing.expectEqualStrings("", out.items[2].detail);
}

test "generated tool configs reflect YAML settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try config.parse(a,
        \\targets:
        \\  - name: App
        \\    bundle_id: com.example.app
        \\    format:
        \\      indent: 2
        \\      clang_format:
        \\        ColumnLimit: 100
        \\        BraceWrapping:
        \\          AfterClass: true
        \\      swift_format:
        \\        rules:
        \\          NeverForceUnwrap: true
        \\    lint:
        \\      clang_tidy_checks: ["-*", "bugprone-*"]
        \\
    , "/p/idlproj.yml");
    const t = cfg.targets[0];
    const cf = try clangFormatConfig(a, t);
    try testing.expect(std.mem.indexOf(u8, cf, "IndentWidth: 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, cf, "ColumnLimit: 100\n") != null);
    try testing.expect(std.mem.indexOf(u8, cf, "ColumnLimit: 0") == null);
    try testing.expect(std.mem.indexOf(u8, cf, "BraceWrapping: \n  AfterClass: true\n") != null);
    const sf = try std.json.parseFromSliceLeaky(std.json.Value, a, try swiftFormatConfig(a, t), .{});
    try testing.expectEqual(@as(i64, 2), sf.object.get("indentation").?.object.get("spaces").?.integer);
    try testing.expect(sf.object.get("rules").?.object.get("NeverForceUnwrap").?.bool);
    try testing.expect(std.mem.indexOf(u8, try clangTidyConfig(a, t), "Checks: '-*,bugprone-*'") != null);
}
