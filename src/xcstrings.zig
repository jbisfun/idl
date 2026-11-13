//! Convert an Xcode String Catalog (`.xcstrings`) into per-language
//! `Localizable.strings` / `Localizable.stringsdict` files. `xcstringstool` is
//! a macOS binary, so this is the Linux replacement.
const std = @import("std");
const plist = @import("plist.zig");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Table = std.StringArrayHashMapUnmanaged([]const u8);

fn obj(v: ?Json) ?std.json.ObjectMap {
    const value = v orelse return null;
    return if (value == .object) value.object else null;
}

fn str(v: ?Json) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}

/// First printf conversion in `s` (e.g. `lld` in "%1$lld items"), else "lld".
fn formatSpecifier(s: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '%')) |pct| : (i = pct + 1) {
        var j = pct + 1;
        var k = j;
        while (k < s.len and std.ascii.isDigit(s[k])) k += 1;
        if (k > j and k < s.len and s[k] == '$') j = k + 1;
        var ls: usize = 0;
        while (j + ls < s.len and s[j + ls] == 'l' and ls < 2) ls += 1;
        if (j + ls < s.len and std.mem.indexOfScalar(u8, "dui@fs", s[j + ls]) != null) return s[j .. j + ls + 1];
    }
    return "lld";
}

fn tableFor(a: Allocator, map: anytype, language: []const u8) !@TypeOf(&map.values()[0]) {
    const gop = try map.getOrPut(a, language);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

fn escapeStrings(writer: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        else => try writer.writeByte(c),
    };
}

fn lessThan(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

pub fn convert(a: Allocator, source: []const u8, out_dir: std.fs.Dir) !void {
    const root = std.json.parseFromSliceLeaky(Json, a, source, .{}) catch |err|
        return diag.fail("invalid xcstrings JSON: {s}", .{@errorName(err)});
    const catalog = obj(root) orelse return diag.fail("xcstrings root must be an object", .{});
    const source_language = str(catalog.get("sourceLanguage")) orelse "en";
    const entries = obj(catalog.get("strings")) orelse return diag.fail("xcstrings is missing \"strings\"", .{});

    var strings: std.StringArrayHashMapUnmanaged(Table) = .empty;
    // language -> libplist dict of stringsdict entries
    var plurals: std.StringArrayHashMapUnmanaged(plist.Plist) = .empty;
    defer for (plurals.values()) |p| p.deinit();

    var it = entries.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const entry = obj(e.value_ptr.*) orelse continue;
        const localizations = obj(entry.get("localizations")) orelse std.json.ObjectMap.init(a);
        const should_translate = if (entry.get("shouldTranslate")) |v| (v != .bool or v.bool) else true;
        if (localizations.get(source_language) == null and should_translate) {
            const t = try tableFor(a, &strings, source_language);
            try t.put(a, key, key);
        }
        var loc_it = localizations.iterator();
        while (loc_it.next()) |loc| {
            const language = loc.key_ptr.*;
            const localization = obj(loc.value_ptr.*) orelse continue;
            const plural_map: ?std.json.ObjectMap = if (obj(localization.get("variations"))) |v| obj(v.get("plural")) else null;
            if (plural_map) |plural| {
                const other_value = blk: {
                    const o = obj(plural.get("other")) orelse break :blk key;
                    const unit = obj(o.get("stringUnit")) orelse break :blk key;
                    break :blk str(unit.get("value")) orelse key;
                };
                const spec = formatSpecifier(other_value);
                const rule = plist.Plist.newDict();
                try rule.set(a, "NSStringFormatSpecTypeKey", try plist.newString(a, "NSStringPluralRuleType"));
                try rule.set(a, "NSStringFormatValueTypeKey", try plist.newString(a, spec));
                var cat_it = plural.iterator();
                while (cat_it.next()) |cat| {
                    const unit = obj((obj(cat.value_ptr.*) orelse continue).get("stringUnit")) orelse continue;
                    const text = str(unit.get("value")) orelse continue;
                    const replaced = try std.mem.replaceOwned(u8, a, text, "%arg", try std.fmt.allocPrint(a, "%{s}", .{spec}));
                    try rule.set(a, cat.key_ptr.*, try plist.newString(a, replaced));
                }
                const wrapper = plist.Plist.newDict();
                try wrapper.set(a, "NSStringLocalizedFormatKey", try plist.newString(a, "%#@value@"));
                try wrapper.set(a, "value", rule.node);
                const gop = try plurals.getOrPut(a, language);
                if (!gop.found_existing) gop.value_ptr.* = plist.Plist.newDict();
                try gop.value_ptr.set(a, key, wrapper.node);
                const t = try tableFor(a, &strings, language);
                try t.put(a, key, other_value);
            } else if (obj(localization.get("stringUnit"))) |unit| {
                const t = try tableFor(a, &strings, language);
                try t.put(a, key, str(unit.get("value")) orelse "");
            }
        }
    }

    for (strings.keys(), strings.values()) |language, table| {
        var dir = try out_dir.makeOpenPath(try std.fmt.allocPrint(a, "{s}.lproj", .{language}), .{});
        defer dir.close();
        var out = std.ArrayList(u8).init(a);
        const keys = try a.dupe([]const u8, table.keys());
        std.mem.sort([]const u8, keys, {}, lessThan);
        for (keys) |k| {
            try out.append('"');
            try escapeStrings(out.writer(), k);
            try out.appendSlice("\" = \"");
            try escapeStrings(out.writer(), table.get(k).?);
            try out.appendSlice("\";\n");
        }
        try dir.writeFile(.{ .sub_path = "Localizable.strings", .data = out.items });
    }
    for (plurals.keys(), plurals.values()) |language, table| {
        var dir = try out_dir.makeOpenPath(try std.fmt.allocPrint(a, "{s}.lproj", .{language}), .{});
        defer dir.close();
        try dir.writeFile(.{ .sub_path = "Localizable.stringsdict", .data = try table.toXml(a) });
    }
}

test "catalog conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try convert(a,
        \\{"sourceLanguage":"en","strings":{
        \\ "Hello":{"localizations":{"de":{"stringUnit":{"state":"translated","value":"Hallo \"du\""}}}},
        \\ "%lld items":{"localizations":{"en":{"variations":{"plural":{
        \\   "one":{"stringUnit":{"value":"%lld item"}},"other":{"stringUnit":{"value":"%lld items"}}}}}}},
        \\ "Bye":{"shouldTranslate":false}}}
    , tmp.dir);
    try std.testing.expectEqualStrings("\"Hello\" = \"Hallo \\\"du\\\"\";\n", try tmp.dir.readFileAlloc(a, "de.lproj/Localizable.strings", 4096));
    try std.testing.expectEqualStrings("\"%lld items\" = \"%lld items\";\n\"Hello\" = \"Hello\";\n", try tmp.dir.readFileAlloc(a, "en.lproj/Localizable.strings", 4096));
    const dict = try tmp.dir.readFileAlloc(a, "en.lproj/Localizable.stringsdict", 4096);
    try std.testing.expect(std.mem.indexOf(u8, dict, "<string>%lld item</string>") != null);
    try std.testing.expectEqualStrings("@", formatSpecifier("%1$@ things"));
    try std.testing.expectEqualStrings("d", formatSpecifier("%d"));
}
