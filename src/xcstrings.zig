//! Convert an Xcode String Catalog (`.xcstrings`) into per-language
//! `Localizable.strings` / `Localizable.stringsdict` files. `xcstringstool` is
//! a macOS binary, so this is the Linux replacement.
const std = @import("std");
const sys = @import("sys.zig");
const plist = @import("plist.zig");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Table = std.array_hash_map.String([]const u8);

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
    if (!gop.found_existing) gop.value_ptr.* = .empty;
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

fn validateLanguage(language: []const u8) !void {
    if (language.len == 0) return diag.fail("empty String Catalog language", .{});
    for (language) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_')
        return diag.fail("invalid String Catalog language '{s}'; expected a language identifier, not a path", .{language});
}

/// NSStringPluralRuleType dictionary for one plural variation map.
fn pluralRule(a: Allocator, plural: std.json.ObjectMap, spec: []const u8) !plist.c.plist_t {
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
    return rule.node;
}

pub fn convert(a: Allocator, source: []const u8, out_dir: std.Io.Dir) !void {
    const root = std.json.parseFromSliceLeaky(Json, a, source, .{}) catch |err|
        return diag.fail("invalid xcstrings JSON: {s}", .{@errorName(err)});
    const catalog = obj(root) orelse return diag.fail("xcstrings root must be an object", .{});
    const source_language = str(catalog.get("sourceLanguage")) orelse "en";
    try validateLanguage(source_language);
    const entries = obj(catalog.get("strings")) orelse return diag.fail("xcstrings is missing \"strings\"", .{});

    var strings: std.array_hash_map.String(Table) = .empty;
    // language -> libplist dict of stringsdict entries
    var plurals: std.array_hash_map.String(plist.Plist) = .empty;
    defer for (plurals.values()) |p| p.deinit();

    var it = entries.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const entry = obj(e.value_ptr.*) orelse continue;
        const localizations = obj(entry.get("localizations")) orelse std.json.ObjectMap.empty;
        const should_translate = if (entry.get("shouldTranslate")) |v| (v != .bool or v.bool) else true;
        if (localizations.get(source_language) == null and should_translate) {
            const t = try tableFor(a, &strings, source_language);
            try t.put(a, key, key);
        }
        var loc_it = localizations.iterator();
        while (loc_it.next()) |loc| {
            const language = loc.key_ptr.*;
            try validateLanguage(language);
            const localization = obj(loc.value_ptr.*) orelse continue;
            const plural_map: ?std.json.ObjectMap = if (obj(localization.get("variations"))) |v| obj(v.get("plural")) else null;
            if (obj(localization.get("substitutions"))) |subs| {
                // Multi-argument plurals: "Moved %#@arg1@ and %#@arg2@."
                var format: []const u8 = if (obj(localization.get("stringUnit"))) |unit| str(unit.get("value")) orelse key else key;
                const wrapper = plist.Plist.newDict();
                var sub_it = subs.iterator();
                while (sub_it.next()) |sub| {
                    const name = sub.key_ptr.*;
                    const s = obj(sub.value_ptr.*) orelse continue;
                    const spec = str(s.get("formatSpecifier")) orelse "lld";
                    const plural = (if (obj(s.get("variations"))) |v| obj(v.get("plural")) else null) orelse continue;
                    try wrapper.set(a, name, try pluralRule(a, plural, spec));
                    if (s.get("argNum")) |n| if (n == .integer) {
                        format = try std.mem.replaceOwned(u8, a, format, try std.fmt.allocPrint(a, "%#@{s}@", .{name}), try std.fmt.allocPrint(a, "%{d}$#@{s}@", .{ n.integer, name }));
                    };
                }
                try wrapper.set(a, "NSStringLocalizedFormatKey", try plist.newString(a, format));
                const gop = try plurals.getOrPut(a, language);
                if (!gop.found_existing) gop.value_ptr.* = plist.Plist.newDict();
                try gop.value_ptr.set(a, key, wrapper.node);
                const t = try tableFor(a, &strings, language);
                try t.put(a, key, format);
            } else if (plural_map) |plural| {
                const other_value = blk: {
                    const o = obj(plural.get("other")) orelse break :blk key;
                    const unit = obj(o.get("stringUnit")) orelse break :blk key;
                    break :blk str(unit.get("value")) orelse key;
                };
                const wrapper = plist.Plist.newDict();
                try wrapper.set(a, "NSStringLocalizedFormatKey", try plist.newString(a, "%#@value@"));
                try wrapper.set(a, "value", try pluralRule(a, plural, formatSpecifier(other_value)));
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
        var dir = try out_dir.createDirPathOpen(sys.io, try std.fmt.allocPrint(a, "{s}.lproj", .{language}), .{});
        defer dir.close(sys.io);
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        const keys = try a.dupe([]const u8, table.keys());
        std.mem.sort([]const u8, keys, {}, lessThan);
        for (keys) |k| {
            try w.writeByte('"');
            try escapeStrings(w, k);
            try w.writeAll("\" = \"");
            try escapeStrings(w, table.get(k).?);
            try w.writeAll("\";\n");
        }
        try dir.writeFile(sys.io, .{ .sub_path = "Localizable.strings", .data = out.written() });
    }
    for (plurals.keys(), plurals.values()) |language, table| {
        var dir = try out_dir.createDirPathOpen(sys.io, try std.fmt.allocPrint(a, "{s}.lproj", .{language}), .{});
        defer dir.close(sys.io);
        try dir.writeFile(sys.io, .{ .sub_path = "Localizable.stringsdict", .data = try table.toXml(a) });
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
    try std.testing.expectEqualStrings("\"Hello\" = \"Hallo \\\"du\\\"\";\n", try tmp.dir.readFileAlloc(sys.io, "de.lproj/Localizable.strings", a, .limited(4096)));
    try std.testing.expectEqualStrings("\"%lld items\" = \"%lld items\";\n\"Hello\" = \"Hello\";\n", try tmp.dir.readFileAlloc(sys.io, "en.lproj/Localizable.strings", a, .limited(4096)));
    const dict = try tmp.dir.readFileAlloc(sys.io, "en.lproj/Localizable.stringsdict", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, dict, "<string>%lld item</string>") != null);
    try std.testing.expectEqualStrings("@", formatSpecifier("%1$@ things"));
    try std.testing.expectEqualStrings("d", formatSpecifier("%d"));
}

test "string catalog language must be a single safe directory name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(error.Invalid, convert(arena.allocator(), "{\"sourceLanguage\":\"bad/lang\",\"strings\":{\"Hello\":{}}}", tmp.dir));
}

test "multi-argument plural substitutions become positional stringsdict rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try convert(a,
        \\{"sourceLanguage":"en","strings":{"moved %lld %lld":{"localizations":{"en":{
        \\ "stringUnit":{"value":"Moved %#@a@ and %#@b@."},
        \\ "substitutions":{
        \\  "a":{"argNum":1,"formatSpecifier":"lld","variations":{"plural":{"one":{"stringUnit":{"value":"%arg file"}},"other":{"stringUnit":{"value":"%arg files"}}}}},
        \\  "b":{"argNum":2,"formatSpecifier":"lld","variations":{"plural":{"other":{"stringUnit":{"value":"%arg dirs"}}}}}}}}}}}
    , tmp.dir);
    const dict = try plist.parse(try tmp.dir.readFileAlloc(sys.io, "en.lproj/Localizable.stringsdict", a, .limited(4096)));
    defer dict.deinit();
    const entry = try dict.get(a, "moved %lld %lld");
    try std.testing.expectEqualStrings("Moved %1$#@a@ and %2$#@b@.", plist.stringOf(plist.c.plist_dict_get_item(entry, "NSStringLocalizedFormatKey")).?);
    const rule = plist.c.plist_dict_get_item(entry, "a");
    try std.testing.expectEqualStrings("%lld file", plist.stringOf(plist.c.plist_dict_get_item(rule, "one")).?);
}
