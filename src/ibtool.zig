//! Interface Builder compiler: .xib -> .nib and .storyboard -> .storyboardc.
//!
//! A Zig port of davidquesada/ibtool (xibparser.py). It understands a subset
//! of UIKit; unknown elements are skipped. See docs/limitations.md.
const std = @import("std");
const sys = @import("sys.zig");
const diag = @import("diag.zig");
const nib = @import("nib.zig");
const plist = @import("plist.zig");
const xmldom = @import("xmldom.zig");

const Allocator = std.mem.Allocator;
const Element = xmldom.Element;
const Obj = nib.Obj;
const ObjMap = std.array_hash_map.String(*Obj);

/// Per-document state shared by every scene.
const Doc = struct {
    a: Allocator,
    name: []const u8,
    /// `<resources>` systemColor / namedColor definitions by name.
    colors: std.StringHashMapUnmanaged(*const Element) = .empty,
    placeholder_counter: usize = 0,
    warnings: usize = 0,

    fn warn(d: *Doc, e: ?*const Element, comptime fmt: []const u8, args: anytype) void {
        d.warnings += 1;
        const line = if (e) |el| el.line else 0;
        diag.warn("{s}:{d}: " ++ fmt, .{ d.name, line } ++ args);
    }

    /// Deterministic stand-in for ibtool's random `UpstreamPlaceholder-xxx-xx-xxx`.
    fn placeholderId(d: *Doc) ![]const u8 {
        d.placeholder_counter += 1;
        const n = d.placeholder_counter;
        return std.fmt.allocPrint(d.a, "UpstreamPlaceholder-idl-{d:0>2}-{d:0>3}", .{ (n / 1000) % 100, n % 1000 });
    }
};

const ViewRef = struct { id: []const u8, obj: *Obj, key: []const u8 };

const Ctx = struct {
    doc: *Doc,
    a: Allocator,
    connections: std.ArrayList(*Obj) = .empty,
    /// Scene-level objects. For storyboards this excludes the main view and its descendants.
    objects: ObjMap = .empty,
    view_objects: ObjMap = .empty,
    extra: std.ArrayList(*Obj) = .empty,
    is_storyboard: bool = false,
    view_controller: ?*Obj = null,
    parsing_view: bool = false,
    view_connections: []const *Obj = &.{},
    scene_connections: []const *Obj = &.{},
    segue_connections: std.ArrayList(*Obj) = .empty,
    is_prototype_list: bool = false,
    parent: ?*Ctx = null,
    /// placeholder identifier -> IB object id
    upstream: std.array_hash_map.String([]const u8) = .empty,
    view_refs: std.ArrayList(ViewRef) = .empty,
    layout_guides: std.ArrayList(*Obj) = .empty,

    fn init(doc: *Doc) Ctx {
        return .{ .doc = doc, .a = doc.a };
    }

    fn segueCtx(c: *Ctx) *Ctx {
        return if (c.is_prototype_list) c.parent.? else c;
    }

    fn addObject(c: *Ctx, id: []const u8, o: *Obj, force_scene: ?bool) !void {
        const scene = force_scene orelse !c.parsing_view;
        try (if (scene) &c.objects else &c.view_objects).put(c.a, id, o);
    }

    fn getObject(c: *Ctx, id: ?[]const u8) ?*Obj {
        const i = id orelse return null;
        if (i.len == 0) return null;
        return c.view_objects.get(i) orelse c.objects.get(i);
    }

    fn findObject(c: *Ctx, e: *const Element, id: ?[]const u8) !?*Obj {
        const i = id orelse return null;
        return c.getObject(i) orelse diag.fail("{s}:{d}: object with id {s} not found", .{ c.doc.name, e.line, i });
    }

    fn getObjectInCurrentContext(c: *Ctx, id: []const u8) ?*Obj {
        return if (c.parsing_view) c.view_objects.get(id) else c.objects.get(id);
    }

    fn resolveConnections(c: *Ctx) !void {
        if (c.is_storyboard) try c.resolveStoryboard() else try c.resolveXib();
        try c.resolveViewRefs();
    }

    fn resolveViewRefs(c: *Ctx) !void {
        for (c.view_refs.items) |r| {
            if (c.getObject(r.id)) |o| {
                try r.obj.set(c.a, r.key, .{ .obj = o });
            } else {
                c.doc.warn(r.obj.ib.elem, "constraint {s} refers to unknown item {s}; dropped", .{ r.obj.ib.id orelse "?", r.id });
                r.obj.ib.dropped = true;
            }
        }
        // Drop broken constraints from their views.
        var it = c.objects.iterator();
        while (it.next()) |e| try dropConstraints(e.value_ptr.*);
        var vit = c.view_objects.iterator();
        while (vit.next()) |e| try dropConstraints(e.value_ptr.*);
        for (c.extra.items) |o| try dropConstraints(o);
    }

    fn resolveXib(c: *Ctx) !void {
        for (c.connections.items) |con| {
            const dst = con.get("UIDestination") orelse continue;
            if (dst != .ref) continue;
            if (c.getObject(dst.ref)) |o| {
                try con.set(c.a, "UIDestination", .{ .obj = o });
                continue;
            }
            const phid = try c.doc.placeholderId();
            try con.set(c.a, "UIDestination", .{ .obj = try nib.proxy(c.a, phid) });
            try c.upstream.put(c.a, phid, dst.ref);
        }
    }

    fn resolveStoryboard(c: *Ctx) !void {
        const a = c.a;
        var view_cons: std.ArrayList(*Obj) = .empty;
        var scene_cons: std.ArrayList(*Obj) = .empty;
        // Objects reached across the scene/view nib boundary, by placeholder id.
        var extern_objects: std.array_hash_map.String(*Obj) = .empty;
        var proxies: std.AutoHashMapUnmanaged(*Obj, *Obj) = .empty;

        const proxyFor = struct {
            fn f(cx: *Ctx, ext: *std.array_hash_map.String(*Obj), px: *std.AutoHashMapUnmanaged(*Obj, *Obj), o: *Obj) !*Obj {
                if (px.get(o)) |p| return p;
                const phid = try cx.doc.placeholderId();
                try ext.put(cx.a, phid, o);
                const p = try nib.proxy(cx.a, phid);
                try px.put(cx.a, o, p);
                return p;
            }
        }.f;

        for (c.connections.items) |con| {
            const src = con.get("UISource").?.obj;
            var dst: *Obj = switch (con.get("UIDestination").?) {
                .obj => |o| o,
                .ref => |id| c.getObject(id) orelse return diag.fail("{s}: connection destination {s} not found", .{ c.doc.name, id }),
                else => unreachable,
            };
            try con.set(a, "UIDestination", .{ .obj = dst });
            const src_top = if (src.ib.id) |id| c.objects.contains(id) else false;
            const dst_top = if (dst.ib.id) |id| c.objects.contains(id) else false;
            if (src_top and !dst_top) {
                // Something outside the view (typically the view controller) pointing into it.
                try con.set(a, "UISource", .{ .obj = try proxyFor(c, &extern_objects, &proxies, src) });
                try view_cons.append(a, con);
            } else if (!src_top and dst_top) {
                dst = try proxyFor(c, &extern_objects, &proxies, dst);
                try con.set(a, "UIDestination", .{ .obj = dst });
                try view_cons.append(a, con);
            } else if (src_top and dst_top) {
                try scene_cons.append(a, con);
            } else {
                try view_cons.append(a, con);
            }
        }
        var up = c.upstream.iterator();
        while (up.next()) |e| {
            const o = c.objects.get(e.value_ptr.*) orelse return diag.fail("{s}: placeholder target {s} not found", .{ c.doc.name, e.value_ptr.* });
            try extern_objects.put(a, e.key_ptr.*, o);
        }
        const vc = c.view_controller.?;
        if (extern_objects.count() > 0) {
            const d = try vc.dict(a, "UIExternalObjectsTableForViewLoading");
            var it = extern_objects.iterator();
            while (it.next()) |e| try nib.dictPut(a, d, .{ .str = e.key_ptr.* }, .{ .obj = e.value_ptr.* });
        }
        try scene_cons.appendSlice(a, c.segue_connections.items);
        c.view_connections = view_cons.items;
        c.scene_connections = scene_cons.items;
        vc.ib.scene_connections = scene_cons.items;
    }
};

fn dropConstraints(o: *Obj) !void {
    const v = o.get("UIViewAutolayoutConstraints") orelse return;
    if (v != .list) return;
    var items = &v.list.items;
    var i: usize = 0;
    while (i < items.items.len) {
        const item = items.items[i];
        if (item == .obj and item.obj.ib.dropped) _ = items.orderedRemove(i) else i += 1;
    }
}

// ------------------------------------------------------------------ parsing

const Tag = enum {
    placeholder,
    viewController,
    navigationController,
    tableViewController,
    view,
    searchBar,
    imageView,
    textView,
    textField,
    scrollView,
    @"switch",
    slider,
    activityIndicatorView,
    progressView,
    label,
    button,
    navigationBar,
    visualEffectView,
    blurEffect,
    vibrancyEffect,
    tableView,
    state,
    subviews,
    prototypes,
    tableViewCell,
    tableViewCellContentView,
    connections,
    outlet,
    action,
    segue,
    layoutGuides,
    viewControllerLayoutGuide,
    viewLayoutGuide,
    constraints,
    constraint,
    items,
    navigationItem,
    barButtonItem,
    color,
    rect,
    inset,
    autoresizingMask,
    textInputTraits,
    fontDescription,
};

fn parseObject(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!?*Obj {
    const tag = std.meta.stringToEnum(Tag, e.tag) orelse return null;
    const o: ?*Obj = switch (tag) {
        .placeholder => try parsePlaceholder(c, e),
        .viewController => try parseViewController(c, e, "UIViewController"),
        .navigationController => try parseViewController(c, e, "UINavigationController"),
        .tableViewController => try parseViewController(c, e, "UITableViewController"),
        .view => try parseView(c, e, parent, "UIView"),
        .searchBar => try parseView(c, e, parent, "UISearchBar"),
        .imageView => try parseView(c, e, parent, "UIImageView"),
        .textView => try parseView(c, e, parent, "UITextView"),
        .textField => try parseView(c, e, parent, "UITextField"),
        .scrollView => try parseView(c, e, parent, "UIScrollView"),
        .@"switch" => try parseView(c, e, parent, "UISwitch"),
        .slider => try parseView(c, e, parent, "UISlider"),
        .activityIndicatorView => try parseView(c, e, parent, "UIActivityIndicatorView"),
        .progressView => try parseView(c, e, parent, "UIProgressView"),
        .label => try parseLabel(c, e, parent),
        .button => try parseButton(c, e, parent),
        .navigationBar => try parseNavigationBar(c, e, parent),
        .visualEffectView => try parseVisualEffectView(c, e, parent),
        .tableView => try parseTableView(c, e, parent),
        .tableViewCell => try parseTableViewCell(c, e, parent),
        .tableViewCellContentView => try parseTableViewCellContentView(c, e, parent),
        .navigationItem => try parseNavigationItem(c, e, parent),
        else => blk: {
            // Elements that only modify their parent.
            const p = parent orelse break :blk null;
            switch (tag) {
                .blurEffect => try parseBlurEffect(c, e, p),
                .vibrancyEffect => try parseVibrancyEffect(c, e, p),
                .state => try parseState(c, e, p),
                .subviews => try p.extend(c.a, "UISubviews", try parseChildren(c, e, p)),
                .prototypes => try parsePrototypes(c, e, p),
                .connections, .layoutGuides, .constraints => _ = try parseChildren(c, e, p),
                .outlet => try parseOutlet(c, e, p),
                .action => try parseAction(c, e, p),
                .segue => try parseSegue(c, e, p),
                .viewControllerLayoutGuide => try parseLayoutGuide(c, e),
                .viewLayoutGuide => try parseViewLayoutGuide(c, e, p),
                .constraint => try parseConstraint(c, e, p),
                .items => try parseItems(c, e, p),
                .barButtonItem => try parseBarButtonItem(c, e, p),
                .color => try parseColor(c, e, p),
                .rect => try parseRect(c, e, p),
                .inset => try parseInset(c, e, p),
                .autoresizingMask => try parseAutoresizingMask(c, e, p),
                .textInputTraits => try parseTextInputTraits(c, e, p),
                .fontDescription => try parseFontDescription(c, e, p),
                else => unreachable,
            }
            break :blk null;
        },
    };
    if (o) |obj| if (e.get("id")) |id| {
        obj.ib.id = id;
    };
    return o;
}

fn parseChildren(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror![]const *Obj {
    var out: std.ArrayList(*Obj) = .empty;
    for (e.children) |child| if (try parseObject(c, child, parent)) |o| try out.append(c.a, o);
    return out.items;
}

fn floatAttr(c: *Ctx, e: *const Element, name: []const u8) !?f64 {
    const v = e.nonEmpty(name) orelse return null;
    return std.fmt.parseFloat(f64, v) catch diag.fail("{s}:{d}: {s}=\"{s}\" is not a number", .{ c.doc.name, e.line, name, v });
}

fn intAttr(c: *Ctx, e: *const Element, name: []const u8) !?i64 {
    const v = e.nonEmpty(name) orelse return null;
    return std.fmt.parseInt(i64, v, 10) catch diag.fail("{s}:{d}: {s}=\"{s}\" is not an integer", .{ c.doc.name, e.line, name, v });
}

fn indexOf(comptime names: []const []const u8, value: []const u8) ?usize {
    inline for (names, 0..) |n, i| if (std.mem.eql(u8, n, value)) return i;
    return null;
}

/// customClass="X": encode as UIClassSwapper(UIClassName=X, UIOriginalClassName=<UIKit class>).
fn classSwap(c: *Ctx, e: *const Element, o: *Obj) anyerror!void {
    const custom = e.nonEmpty("customClass") orelse return;
    try o.setStr(c.a, "UIOriginalClassName", o.class);
    try o.setStr(c.a, "UIClassName", custom);
    o.ib.original_class = o.class;
    o.class = "UIClassSwapper";
}

fn ibProperties(c: *Ctx, e: *const Element, o: *Obj) anyerror!void {
    try o.setStr(c.a, "UIRestorationIdentifier", e.nonEmpty("restorationIdentifier"));
    if (e.nonEmpty("id")) |id| try c.addObject(id, o, null);
}

fn parsePlaceholder(c: *Ctx, e: *const Element) anyerror!*Obj {
    const ident = e.get("placeholderIdentifier") orelse return diag.fail("{s}:{d}: placeholder without placeholderIdentifier", .{ c.doc.name, e.line });
    const o = try nib.proxy(c.a, ident);
    o.ib.id = e.get("id");
    _ = try parseChildren(c, e, o);
    if (e.get("id")) |id| try c.addObject(id, o, null);
    return o;
}

fn parseViewController(c: *Ctx, e: *const Element, class: []const u8) anyerror!*Obj {
    const o = try nib.new(c.a, class);
    o.ib.elem = e;
    o.ib.id = e.get("id");
    if (e.is("sceneMemberID", "viewController")) c.view_controller = o;
    _ = try parseChildren(c, e, o);
    try ibProperties(c, e, o);
    try o.setStr(c.a, "UIStoryboardIdentifier", e.nonEmpty("storyboardIdentifier"));
    try classSwap(c, e, o);
    return o;
}

const content_modes = [_][]const u8{ "scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw", "center", "top", "bottom", "left", "right", "topLeft", "topRight", "bottomLeft", "bottomRight" };

fn parseView(c: *Ctx, e: *const Element, parent: ?*Obj, class: []const u8) anyerror!*Obj {
    const a = c.a;
    const o = try nib.new(a, class);
    o.ib.elem = e;
    o.ib.id = e.get("id");
    const key = e.get("key") orelse "";
    if (parent) |p| {
        if (std.mem.eql(u8, key, "view")) {
            try p.set(a, "UIView", .{ .obj = o });
        } else if (std.mem.eql(u8, key, "tableFooterView") or std.mem.eql(u8, key, "tableHeaderView")) {
            try p.set(a, if (key[5] == 'F') "UITableFooterView" else "UITableHeaderView", .{ .obj = o });
            try p.append(a, "UISubviews", o);
        } else if (std.mem.eql(u8, key, "contentView")) {
            if (std.mem.eql(u8, p.originalClass(), "UIVisualEffectView")) {
                try p.set(a, "UIVisualEffectViewContentView", .{ .obj = o });
                o.class = "_UIVisualEffectContentView";
            } else c.doc.warn(e, "contentView of {s} is not supported", .{p.originalClass()});
        }
    }
    const is_main_view = std.mem.eql(u8, key, "view");

    if (e.is("translatesAutoresizingMaskIntoConstraints", "NO"))
        try o.set(a, "UIViewDoesNotTranslateAutoresizingMaskIntoConstraints", .{ .boolean = true });
    if (e.get("contentMode")) |mode| {
        const idx = indexOf(&content_modes, mode) orelse return diag.fail("{s}:{d}: unknown contentMode {s}", .{ c.doc.name, e.line, mode });
        if (idx != 0) try o.set(a, "UIContentMode", .{ .int = @intCast(idx) });
    }
    try o.set(a, "UIClipsToBounds", .{ .boolean = e.is("clipsSubviews", "YES") });
    try o.set(a, "UIAutoresizingMask", .{ .int = 36 }); // flexible right + bottom margin
    try o.set(a, "UIAutoresizeSubviews", .{ .boolean = true });
    if (e.get("opaque") != null) try o.set(a, "UIOpaque", .{ .boolean = e.is("opaque", "YES") });
    if (e.is("hidden", "YES")) try o.set(a, "UIHidden", .{ .boolean = true });
    if (e.is("userInteractionEnabled", "NO")) try o.set(a, "UIUserInteractionDisabled", .{ .boolean = true });
    if (try floatAttr(c, e, "alpha")) |alpha| try o.set(a, "UIAlpha", .{ .double = alpha });
    if (try intAttr(c, e, "tag")) |t| try o.set(a, "UITag", .{ .int = t });
    try o.setStr(a, "UIText", e.nonEmpty("text"));

    if (is_main_view) c.parsing_view = true;
    try c.extra.append(a, o);
    // Register first, in case children point back at us.
    try ibProperties(c, e, o);
    _ = try parseChildren(c, e, o);
    if (is_main_view) c.parsing_view = false;
    try classSwap(c, e, o);
    return o;
}

fn parseLabel(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const o = try parseView(c, e, parent, if (c.is_prototype_list) "UITableViewLabel" else "UILabel");
    try o.setIfEmpty(c.a, "UIUserInteractionDisabled", .{ .boolean = true });
    try o.setIfEmpty(c.a, "UIViewContentHuggingPriority", .{ .str = "{251, 251}" });
    if (e.get("lineBreakMode")) |mode| {
        const index = indexOf(&.{ "wordWrap", "characterWrap", "clip", "headTruncation", "tailTruncation", "middleTruncation" }, mode) orelse return diag.fail("unknown lineBreakMode {s}", .{mode});
        try o.set(c.a, "UILineBreakMode", .{ .int = @intCast(index) });
    }
    if (try intAttr(c, e, "numberOfLines")) |n| try o.set(c.a, "UINumberOfLines", .{ .int = n });
    if (e.get("textAlignment")) |ta| if (indexOf(&.{ "natural", "left", "center", "right", "justified" }, ta)) |i| {
        // NSTextAlignment: left 0, center 1, right 2, justified 3, natural 4.
        const values = [_]i64{ 4, 0, 1, 2, 3 };
        try o.set(c.a, "UITextAlignment", .{ .int = values[i] });
    };
    return o;
}

fn parseButton(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const o = try parseView(c, e, parent, "UIButton");
    if (e.get("buttonType")) |bt| {
        var idx = indexOf(&.{ "custom", "system", "detailDisclosure", "infoLight", "infoDark", "contactAdd", "roundedRect" }, bt) orelse
            return diag.fail("{s}:{d}: unknown buttonType {s}", .{ c.doc.name, e.line, bt });
        if (idx == 6) idx = 1; // roundedRect became system in iOS 7
        try o.set(c.a, "UIButtonType", .{ .int = @intCast(idx) });
    }
    try o.set(c.a, "UIAdjustsImageWhenHighlighted", .{ .boolean = true });
    try o.set(c.a, "UIAdjustsImageWhenDisabled", .{ .boolean = true });
    return o;
}

fn parseNavigationBar(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const bar = try parseView(c, e, parent, "UINavigationBar");
    if (parent) |p| if (e.is("key", "navigationBar")) {
        try p.set(c.a, "UINavigationBar", .{ .obj = bar });
        try bar.set(c.a, "UIDelegate", .{ .obj = p });
    };
    try bar.set(c.a, "UIBarTranslucence", .{ .int = if (e.is("translucent", "NO")) 2 else 1 });
    if (e.is("barStyle", "black")) try bar.set(c.a, "UIBarStyle", .{ .int = 1 });
    return bar;
}

fn parseVisualEffectView(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const v = try parseView(c, e, parent, "UIVisualEffectView");
    if (!v.has("UIVisualEffectViewEffect")) c.doc.warn(e, "visualEffectView without a blur or vibrancy effect", .{});
    return v;
}

fn parseBlurEffect(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const style = indexOf(&.{ "extraLight", "light", "dark" }, e.get("style") orelse "") orelse {
        c.doc.warn(e, "unsupported blur style {s}", .{e.get("style") orelse ""});
        return;
    };
    const o = try nib.new(c.a, "UIBlurEffect");
    try o.set(c.a, "UIBlurEffectStyle", .{ .int = @intCast(style) });
    if (std.mem.eql(u8, parent.originalClass(), "UIVisualEffectView")) {
        try parent.set(c.a, "UIVisualEffectViewEffect", .{ .obj = o });
    } else if (std.mem.eql(u8, parent.originalClass(), "UIVibrancyEffect")) {
        try parent.set(c.a, "UIVibrancyEffectBlurStyle", .{ .int = @intCast(style) });
    }
}

fn parseVibrancyEffect(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const o = try nib.new(c.a, "UIVibrancyEffect");
    _ = try parseChildren(c, e, o);
    try parent.set(c.a, "UIVisualEffectViewEffect", .{ .obj = o });
}

fn parseTableView(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const t = try parseView(c, e, parent, "UITableView");
    const sep = e.get("separatorStyle") orelse "default";
    const styles: ?[2]i64 = if (std.mem.eql(u8, sep, "none"))
        null
    else if (std.mem.eql(u8, sep, "singleLineEtched")) .{ 1, 2 } else .{ 1, 1 };
    if (styles) |s| {
        try t.set(c.a, "UISeparatorStyle", .{ .int = s[0] });
        try t.set(c.a, "UISeparatorStyleIOS5AndLater", .{ .int = s[1] });
    }
    if (try floatAttr(c, e, "rowHeight")) |h| try t.set(c.a, "UIRowHeight", .{ .double = h });
    return t;
}

fn parseState(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    if (!std.mem.eql(u8, parent.originalClass(), "UIButton")) {
        c.doc.warn(e, "'state' is only supported on buttons (got {s})", .{parent.originalClass()});
        return;
    }
    const content = try nib.new(c.a, "UIButtonContent");
    try content.setStr(c.a, "UITitle", e.get("title"));
    var state = indexOf(&.{ "normal", "highlighted", "disabled", "selected" }, e.get("key") orelse "") orelse {
        c.doc.warn(e, "unknown button state {s}", .{e.get("key") orelse ""});
        return;
    };
    if (state != 0) state = @as(usize, 1) << @intCast(state - 1);
    try nib.dictPut(c.a, try parent.dict(c.a, "UIButtonStatefulContent"), .{ .int = @intCast(state) }, .{ .obj = content });
    _ = try parseChildren(c, e, content);
}

fn parsePrototypes(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const a = c.a;
    var prototypes: ?*nib.Dict = null;
    var externals: ?*nib.Dict = null;
    for (e.children) |cell| {
        const rid = cell.nonEmpty("reuseIdentifier") orelse {
            c.doc.warn(cell, "prototype cell {s} has no reuseIdentifier; skipped", .{cell.get("id") orelse "?"});
            continue;
        };
        var sub = Ctx.init(c.doc);
        sub.is_prototype_list = true;
        sub.parent = c;
        const root = try parseObjects(&sub, &.{cell}, true);
        var ext: ?*nib.Dict = null;
        var it = sub.upstream.iterator();
        while (it.next()) |u| {
            if (ext == null) {
                ext = try a.create(nib.Dict);
                ext.?.* = .{};
            }
            const target: *Obj = c.getObjectInCurrentContext(u.value_ptr.*) orelse blk: {
                const to_parent = try c.doc.placeholderId();
                try c.upstream.put(a, to_parent, u.value_ptr.*);
                break :blk try nib.proxy(a, to_parent);
            };
            try nib.dictPut(a, ext.?, .{ .str = u.key_ptr.* }, .{ .obj = target });
        }
        if (ext) |x| {
            if (externals == null) externals = try parent.dict(a, "UITableViewCellPrototypeNibExternalObjects");
            try nib.dictPut(a, externals.?, .{ .str = rid }, .{ .dict = x });
        }
        const cell_nib = try nib.new(a, "UINib");
        try cell_nib.set(a, "captureEnclosingNIBBundleOnDecode", .{ .boolean = true });
        const data = try nib.new(a, "NSData");
        try data.set(a, "NS.bytes", .{ .bytes = try nib.encode(a, root) });
        try cell_nib.set(a, "archiveData", .{ .obj = data });
        if (prototypes == null) prototypes = try parent.dict(a, "UITableViewCellPrototypeNibs");
        try nib.dictPut(a, prototypes.?, .{ .str = rid }, .{ .obj = cell_nib });
    }
}

fn parseTableViewCell(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const a = c.a;
    const cell = try parseView(c, e, parent, "UITableViewCell");
    try cell.setObj(a, "UITextLabel", try c.findObject(e, e.nonEmpty("textLabel")));
    try cell.setObj(a, "UIDetailTextLabel", try c.findObject(e, e.nonEmpty("detailTextLabel")));
    try cell.setObj(a, "UIImageView", try c.findObject(e, e.nonEmpty("imageView")));
    try cell.setStr(a, "UIReuseIdentifier", e.nonEmpty("reuseIdentifier"));
    if (e.get("style")) |s| if (indexOf(&.{ "IBUITableViewCellStyleDefault", "IBUITableViewCellStyleValue1", "IBUITableViewCellStyleValue2", "IBUITableViewCellStyleSubtitle" }, s)) |i| {
        if (i != 0) try cell.set(a, "UITableViewCellStyle", .{ .int = @intCast(i) });
    };
    if (e.get("selectionStyle")) |s| if (indexOf(&.{ "none", "blue", "gray" }, s)) |i|
        try cell.set(a, "UISelectionStyle", .{ .int = @intCast(i) });
    const width = (try floatAttr(c, e, "indentationWidth")) orelse 0;
    if (width != 10.0) try cell.set(a, "UIIndentationWidth", .{ .double = width });
    if (try intAttr(c, e, "indentationLevel")) |l| if (l != 0) try cell.set(a, "UIIndentationLevel", .{ .int = l });
    const accessories = [_][]const u8{ "none", "disclosureIndicator", "detailDisclosureButton", "checkmark", "detailButton" };
    if (e.get("accessoryType")) |s| if (indexOf(&accessories, s)) |i| if (i != 0) try cell.set(a, "UIAccessoryType", .{ .int = @intCast(i) });
    if (e.get("editingAccessoryType")) |s| if (indexOf(&accessories, s)) |i| if (i != 0) try cell.set(a, "UIEditingAccessoryType", .{ .int = @intCast(i) });
    if (e.is("showsReorderControl", "YES")) try cell.set(a, "UIShowsReorderControl", .{ .boolean = true });
    return cell;
}

fn parseTableViewCellContentView(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const v = try parseView(c, e, parent, "UITableViewCellContentView");
    if (parent) |p| {
        try p.set(c.a, "UIContentView", .{ .obj = v });
        try p.set(c.a, "UISubviews", .{ .list = try nib.listOf(c.a, &.{v}) });
    }
    return v;
}

fn parseOutlet(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const con = try nib.new(c.a, "UIRuntimeOutletConnection");
    try con.setStr(c.a, "UILabel", e.get("property"));
    try con.set(c.a, "UISource", .{ .obj = parent });
    try con.set(c.a, "UIDestination", .{ .ref = e.get("destination") orelse return diag.fail("{s}:{d}: outlet without destination", .{ c.doc.name, e.line }) });
    con.ib.id = e.get("id");
    try c.connections.append(c.a, con);
}

const event_masks = std.StaticStringMap(i64).initComptime(.{
    .{ "touchDown", 1 << 0 },        .{ "touchDownRepeat", 1 << 1 },         .{ "touchDragInside", 1 << 2 },
    .{ "touchDragOutside", 1 << 3 }, .{ "touchDragEnter", 1 << 4 },          .{ "touchDragExit", 1 << 5 },
    .{ "touchUpInside", 1 << 6 },    .{ "touchUpOutside", 1 << 7 },          .{ "touchCancel", 1 << 8 },
    .{ "valueChanged", 1 << 12 },    .{ "primaryActionTriggered", 1 << 13 }, .{ "editingDidBegin", 1 << 16 },
    .{ "editingChanged", 1 << 17 },  .{ "editingDidEnd", 1 << 18 },          .{ "editingDidEndOnExit", 1 << 19 },
});

fn parseAction(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const con = try nib.new(c.a, "UIRuntimeEventConnection");
    try con.setStr(c.a, "UILabel", e.get("selector") orelse return diag.fail("{s}:{d}: action without selector", .{ c.doc.name, e.line }));
    try con.set(c.a, "UISource", .{ .obj = parent });
    try con.set(c.a, "UIDestination", .{ .ref = e.get("destination") orelse return diag.fail("{s}:{d}: action without destination", .{ c.doc.name, e.line }) });
    if (e.get("eventType")) |t| {
        try con.set(c.a, "UIEventMask", .{ .int = event_masks.get(t) orelse return diag.fail("{s}:{d}: unknown eventType {s}", .{ c.doc.name, e.line, t }) });
    }
    try c.connections.append(c.a, con);
}

fn parseSegue(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const a = c.a;
    const kind = e.get("kind") orelse "";
    if (std.mem.eql(u8, kind, "relationship")) {
        parent.ib.relationship_segue = e;
        return;
    }
    const t = try nib.new(a, "UIStoryboardSegueTemplate");
    t.ib.id = e.get("id") orelse return diag.fail("{s}:{d}: segue without id", .{ c.doc.name, e.line });
    t.ib.segue_destination = e.get("destination") orelse return diag.fail("{s}:{d}: segue without destination", .{ c.doc.name, e.line });
    try t.setStr(a, "UIIdentifier", e.nonEmpty("identifier"));
    try t.setStr(a, "UIDestinationViewControllerIdentifier", t.ib.segue_destination);

    if (std.mem.eql(u8, kind, "presentation") or std.mem.eql(u8, kind, "modal")) {
        if (e.get("modalPresentationStyle")) |s| if (indexOf(&.{ "fullScreen", "pageSheet", "formSheet", "currentContext", "custom", "overFullScreen", "overCurrentContext" }, s)) |i|
            try t.set(a, "UIModalPresentationStyle", .{ .int = @intCast(i) });
        if (e.get("modalTransitionStyle")) |s| if (indexOf(&.{ "coverVertical", "flipHorizontal", "crossDissolve", "partialCurl" }, s)) |i|
            try t.set(a, "UIModalTransitionStyle", .{ .int = @intCast(i) });
        if (e.is("animates", "NO")) try t.set(a, "UIAnimates", .{ .boolean = false });
    }
    if (std.mem.eql(u8, kind, "show")) {
        t.class = "UIStoryboardShowSegueTemplate";
        try t.setStr(a, "UIActionName", "showViewController:sender:");
    } else if (std.mem.eql(u8, kind, "showDetail")) {
        t.class = "UIStoryboardShowSegueTemplate";
        try t.setStr(a, "UIActionName", "showDetailViewController:sender:");
    } else if (std.mem.eql(u8, kind, "presentation")) {
        t.class = "UIStoryboardPresentationSegueTemplate";
    } else if (std.mem.eql(u8, kind, "push")) {
        t.class = "UIStoryboardPushSegueTemplate";
        try t.set(a, "UIDestinationContainmentContext", .{ .int = 0 });
        try t.set(a, "UISplitViewControllerIndex", .{ .int = 0 });
    } else if (std.mem.eql(u8, kind, "modal")) {
        t.class = "UIStoryboardModalSegueTemplate";
    } else if (std.mem.eql(u8, kind, "replace")) {
        t.class = "UIStoryboardReplaceSegueTemplate";
        try t.set(a, "UIDestinationContainmentContext", .{ .int = 1 });
        try t.setInt(a, "UISplitViewControllerIndex", try intAttr(c, e, "splitViewControllerTargetIndex"));
    } else if (std.mem.eql(u8, kind, "custom")) {
        try t.setStr(a, "UISegueClassName", e.nonEmpty("customClass"));
    } else {
        c.doc.warn(e, "unknown segue kind '{s}'; skipped", .{kind});
        return;
    }

    const sctx = c.segueCtx();
    const controller = sctx.view_controller orelse return diag.fail("{s}:{d}: segue outside a storyboard scene", .{ c.doc.name, e.line });
    try controller.append(a, "UIStoryboardSegueTemplates", t);
    try sctx.addObject(t.ib.id.?, t, true);
    const vc_con = try nib.new(a, "UIRuntimeOutletConnection");
    try vc_con.setStr(a, "UILabel", "viewController");
    try vc_con.set(a, "UISource", .{ .obj = t });
    try vc_con.set(a, "UIDestination", .{ .obj = controller });
    try sctx.segue_connections.append(a, vc_con);
    try sctx.extra.append(a, t);

    const trigger = parent.originalClass();
    if (std.mem.eql(u8, trigger, "UIButton") or std.mem.eql(u8, trigger, "UITableViewCell")) {
        const phid = try c.doc.placeholderId();
        const is_button = std.mem.eql(u8, trigger, "UIButton");
        const con = try nib.new(a, if (is_button) "UIRuntimeEventConnection" else "UIRuntimeOutletConnection");
        try con.setStr(a, "UILabel", if (is_button)
            "perform:"
        else if (e.is("trigger", "accessoryAction")) "accessoryActionSegueTemplate" else "selectionSegueTemplate");
        try con.set(a, "UISource", .{ .obj = parent });
        try con.set(a, "UIDestination", .{ .obj = try nib.proxy(a, phid) });
        if (is_button) try con.set(a, "UIEventMask", .{ .int = 64 });
        try c.connections.append(a, con);
        try c.upstream.put(a, phid, t.ib.id.?);
    }
}

fn parseLayoutGuide(c: *Ctx, e: *const Element) anyerror!void {
    const a = c.a;
    const o = try nib.new(a, "_UILayoutGuide");
    o.ib.id = e.get("id") orelse return;
    try o.set(a, "UIOpaque", .{ .boolean = true });
    try o.set(a, "UIHidden", .{ .boolean = true });
    try o.set(a, "UIAutoresizeSubviews", .{ .boolean = true });
    try o.set(a, "UIViewDoesNotTranslateAutoresizingMaskIntoConstraints", .{ .boolean = true });
    if (e.is("type", "bottom")) try o.setStr(a, "_UILayoutGuideIdentifier", "_UIViewControllerBottom");
    if (e.is("type", "top")) try o.setStr(a, "_UILayoutGuideIdentifier", "_UIViewControllerTop");
    try c.addObject(o.ib.id.?, o, null);
    try c.layout_guides.append(a, o);
}

/// Modern documents constrain against `<viewLayoutGuide key="safeArea">`.
/// It has no nib equivalent here, so it aliases the owning view.
fn parseViewLayoutGuide(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    if (e.get("id")) |id| try c.addObject(id, parent, null);
    if (!e.is("key", "safeArea")) c.doc.warn(e, "layout guide '{s}' is treated as its view", .{e.get("key") orelse "?"});
}

const constraint_attributes = [_][]const u8{ "notAnAttribute", "left", "right", "top", "bottom", "leading", "trailing", "width", "height", "centerX", "centerY", "lastBaseline", "firstBaseline" };

fn constraintAttribute(c: *Ctx, e: *const Element, name: []const u8) anyerror!?i64 {
    const v = e.get(name) orelse return 0;
    if (std.mem.eql(u8, v, "baseline")) return 11;
    const i = indexOf(&constraint_attributes, v) orelse {
        c.doc.warn(e, "unsupported constraint attribute {s}", .{v});
        return null;
    };
    return @intCast(i);
}

fn parseConstraint(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const a = c.a;
    const con = try nib.new(a, "NSLayoutConstraint");
    con.ib.id = e.get("id") orelse return diag.fail("{s}:{d}: constraint without id", .{ c.doc.name, e.line });
    con.ib.elem = e;
    const first = try constraintAttribute(c, e, "firstAttribute");
    const second = try constraintAttribute(c, e, "secondAttribute");
    const constant = (try floatAttr(c, e, "constant")) orelse 0;
    if (e.nonEmpty("firstItem")) |id| {
        try con.set(a, "NSFirstItem", .{ .ref = id });
        try c.view_refs.append(a, .{ .id = id, .obj = con, .key = "NSFirstItem" });
    } else try con.set(a, "NSFirstItem", .{ .obj = parent });
    try con.setInt(a, "NSFirstAttribute", first);
    try con.setInt(a, "NSFirstAttributeV2", first);
    try con.setInt(a, "NSSecondAttribute", second);
    try con.setInt(a, "NSSecondAttributeV2", second);
    try con.set(a, "NSConstant", .{ .double = constant });
    try con.set(a, "NSConstantV2", .{ .double = constant });
    try con.set(a, "NSShouldBeArchived", .{ .boolean = true });
    if (try floatAttr(c, e, "priority")) |p| try con.set(a, "NSPriority", .{ .int = @intFromFloat(p) });
    if (try floatAttr(c, e, "multiplier")) |m| if (m != 1) try con.set(a, "NSMultiplier", .{ .double = m });
    if (e.get("relation")) |r| if (indexOf(&.{ "lessThanOrEqual", "equal", "greaterThanOrEqual" }, r)) |i| if (i != 1)
        try con.set(a, "NSRelation", .{ .int = @as(i64, @intCast(i)) - 1 });
    if (e.nonEmpty("secondItem")) |id| {
        try con.set(a, "NSSecondItem", .{ .ref = id });
        try c.view_refs.append(a, .{ .id = id, .obj = con, .key = "NSSecondItem" });
    }
    if (first == null or second == null) return;
    try parent.append(a, "UIViewAutolayoutConstraints", con);
    try c.addObject(con.ib.id.?, con, null);
}

fn parseItems(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    if (!std.mem.eql(u8, parent.originalClass(), "UINavigationBar")) {
        c.doc.warn(e, "'items' is only supported on navigation bars", .{});
        return;
    }
    const items = try parseChildren(c, e, null);
    try parent.set(c.a, "UIItems", .{ .list = try nib.listOf(c.a, items) });
}

fn parseNavigationItem(c: *Ctx, e: *const Element, parent: ?*Obj) anyerror!*Obj {
    const item = try nib.new(c.a, "UINavigationItem");
    try item.setStr(c.a, "UITitle", e.get("title"));
    if (parent) |p| if (e.is("key", "navigationItem")) try p.set(c.a, "UINavigationItem", .{ .obj = item });
    _ = try parseChildren(c, e, item);
    return item;
}

const system_items = [_][]const u8{ "done", "cancel", "edit", "save", "add", "flexibleSpace", "fixedSpace", "compose", "reply", "action", "organize", "bookmarks", "search", "refresh", "stop", "camera", "trash", "play", "pause", "rewind", "fastForward", "undo", "redo", "pageCurl", "close" };

fn parseBarButtonItem(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const a = c.a;
    const item = try nib.new(a, "UIBarButtonItem");
    item.ib.id = e.get("id");
    if (item.ib.id) |id| try c.addObject(id, item, null);
    try item.set(a, "UIStyle", .{ .int = if (e.is("style", "done")) 2 else 1 });
    try item.set(a, "UIEnabled", .{ .boolean = !e.is("enabled", "NO") });
    try item.setStr(a, "UITitle", e.nonEmpty("title"));
    if (e.get("systemItem")) |s| {
        const idx = indexOf(&system_items, s) orelse return diag.fail("{s}:{d}: unknown systemItem {s}", .{ c.doc.name, e.line, s });
        try item.set(a, "UIIsSystemItem", .{ .boolean = true });
        try item.set(a, "UISystemItem", .{ .int = @intCast(idx) });
    }
    const key = e.get("key") orelse "";
    if (std.mem.eql(u8, key, "backBarButtonItem")) {
        try parent.set(a, "UIBackBarButtonItem", .{ .obj = item });
    } else if (std.mem.eql(u8, key, "rightBarButtonItem")) {
        try parent.set(a, "UIRightBarButtonItem", .{ .obj = item });
        try parent.append(a, "UIRightBarButtonItems", item);
    } else if (std.mem.eql(u8, key, "leftBarButtonItem")) {
        try parent.set(a, "UILeftBarButtonItem", .{ .obj = item });
        try parent.append(a, "UILeftBarButtonItems", item);
    }
    _ = try parseChildren(c, e, item);
}

/// `<color>` -> UIColor. Handles RGB/white components, cocoaTouchSystemColor
/// presets and modern systemColor/name references resolved through the
/// document's `<resources>`.
fn colorObject(c: *Ctx, e: *const Element) anyerror!*Obj {
    const a = c.a;
    var el = e;
    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        const name = el.nonEmpty("systemColor") orelse el.nonEmpty("name") orelse break;
        const def = c.doc.colors.get(name) orelse {
            c.doc.warn(e, "color '{s}' is not defined in <resources>; using black", .{name});
            break;
        };
        el = def;
    }
    const obj = try nib.new(a, "UIColor");
    var rgb: ?[3]f64 = null;
    var alpha: ?f64 = null;
    if (el.get("cocoaTouchSystemColor")) |sc| {
        if (std.mem.eql(u8, sc, "darkTextColor")) {
            rgb = .{ 0, 0, 0 };
            alpha = 1;
        } else if (std.mem.eql(u8, sc, "groupTableViewBackgroundColor")) {
            try obj.setStr(a, "UISystemColorName", sc);
            try obj.setStr(a, "UIPatternSelector", sc);
            return obj;
        }
    }
    if (try floatAttr(c, el, "white")) |w| rgb = .{ w, w, w };
    if (rgb == null) rgb = .{ (try floatAttr(c, el, "red")) orelse 0, (try floatAttr(c, el, "green")) orelse 0, (try floatAttr(c, el, "blue")) orelse 0 };
    if (alpha == null) alpha = (try floatAttr(c, el, "alpha")) orelse 1;
    const v = rgb.?;
    try obj.set(a, "UIColorComponentCount", .{ .int = 4 });
    try obj.set(a, "UIRed", .{ .double = v[0] });
    try obj.set(a, "UIGreen", .{ .double = v[1] });
    try obj.set(a, "UIBlue", .{ .double = v[2] });
    try obj.set(a, "UIAlpha", .{ .double = alpha.? });
    try obj.set(a, "UIColorSpace", .{ .int = 2 });
    try obj.set(a, "NSRGB", .{ .bytes = try std.fmt.allocPrint(a, "{d:.3} {d:.3} {d:.3}", .{ v[0], v[1], v[2] }) });
    return obj;
}

const color_keys = std.StaticStringMap([]const u8).initComptime(.{
    .{ "backgroundColor", "UIBackgroundColor" }, .{ "textColor", "UITextColor" },
    .{ "titleShadowColor", "UIShadowColor" },    .{ "titleColor", "UITitleColor" },
    .{ "barTintColor", "UIBarTintColor" },       .{ "separatorColor", "UISeparatorColor" },
    .{ "tintColor", "UITintColor" },
});

fn parseColor(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const key = color_keys.get(e.get("key") orelse return) orelse return;
    try parent.set(c.a, key, .{ .obj = try colorObject(c, e) });
}

fn parseRect(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    if (!e.is("key", "frame")) return;
    const x = (try floatAttr(c, e, "x")) orelse 0;
    const y = (try floatAttr(c, e, "y")) orelse 0;
    const w = (try floatAttr(c, e, "width")) orelse 0;
    const h = (try floatAttr(c, e, "height")) orelse 0;
    try parent.set(c.a, "UICenter", .{ .doubles = try c.a.dupe(f64, &.{ x + w / 2, y + h / 2 }) });
    try parent.set(c.a, "UIBounds", .{ .doubles = try c.a.dupe(f64, &.{ 0, 0, w, h }) });
}

fn parseInset(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    if (!e.is("key", "separatorInset")) {
        c.doc.warn(e, "'inset' is only supported for separatorInset", .{});
        return;
    }
    const v = [4]f64{ (try floatAttr(c, e, "minY")) orelse 0, (try floatAttr(c, e, "minX")) orelse 0, (try floatAttr(c, e, "maxY")) orelse 0, (try floatAttr(c, e, "maxX")) orelse 0 };
    try parent.set(c.a, "UISeparatorInset", .{ .doubles = try c.a.dupe(f64, &v) });
}

fn parseAutoresizingMask(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    if (!e.is("key", "autoresizingMask")) return;
    var mask: i64 = 0;
    for ([_][]const u8{ "flexibleMinX", "widthSizable", "flexibleMaxX", "flexibleMinY", "heightSizable", "flexibleMaxY" }, 0..) |name, i| {
        if (e.is(name, "YES")) mask |= @as(i64, 1) << @intCast(i);
    }
    try parent.set(c.a, "UIAutoresizingMask", .{ .int = mask });
}

fn parseTextInputTraits(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    if (!e.is("key", "textInputTraits")) return;
    try parent.set(c.a, "UIReturnKeyType", .{ .int = 6 });
    try parent.set(c.a, "UIEnablesReturnKeyAutomatically", .{ .boolean = true });
    try parent.set(c.a, "UISecureTextEntry", .{ .boolean = e.is("secureTextEntry", "YES") });
}

const TextStyle = struct { size: f64, bold: bool = false };
const text_styles = std.StaticStringMap(TextStyle).initComptime(.{
    .{ "UICTFontTextStyleBody", TextStyle{ .size = 17 } },
    .{ "UICTFontTextStyleCallout", TextStyle{ .size = 16 } },
    .{ "UICTFontTextStyleCaption1", TextStyle{ .size = 12 } },
    .{ "UICTFontTextStyleCaption2", TextStyle{ .size = 11 } },
    .{ "UICTFontTextStyleFootnote", TextStyle{ .size = 13 } },
    .{ "UICTFontTextStyleHeadline", TextStyle{ .size = 17, .bold = true } },
    .{ "UICTFontTextStyleSubhead", TextStyle{ .size = 15 } },
    .{ "UICTFontTextStyleTitle1", TextStyle{ .size = 28 } },
    .{ "UICTFontTextStyleTitle2", TextStyle{ .size = 22 } },
    .{ "UICTFontTextStyleTitle3", TextStyle{ .size = 20 } },
    .{ "UICTFontTextStyleLargeTitle", TextStyle{ .size = 34 } },
});

fn parseFontDescription(c: *Ctx, e: *const Element, parent: *Obj) anyerror!void {
    const a = c.a;
    if (!e.is("key", "fontDescription")) return;
    const point_size = (try floatAttr(c, e, "pointSize")) orelse 0;
    var size = point_size;
    const font = try nib.new(a, "UIFont");
    try font.set(a, "UIFontTraits", .{ .int = 0 });
    var name: ?[]const u8 = null;
    const ftype = e.get("type");

    if (e.get("style")) |style| {
        const ts = text_styles.get(style) orelse {
            c.doc.warn(e, "unsupported text style {s}; font skipped", .{style});
            return;
        };
        name = if (ts.bold) ".SFUI-Semibold" else ".SFUI-Regular";
        try font.setStr(a, "UIIBTextStyle", style);
        try font.set(a, "UISystemFont", .{ .boolean = true });
        if (ts.bold) try font.set(a, "UIFontTraits", .{ .int = 2 });
        size = ts.size;
    } else if (ftype == null or std.mem.eql(u8, ftype.?, "custom")) {
        name = e.nonEmpty("name") orelse {
            c.doc.warn(e, "custom font without a name; font skipped", .{});
            return;
        };
        try font.set(a, "UISystemFont", .{ .boolean = false });
        const desc = try nib.new(a, "UIFontDescriptor");
        const attrs = try desc.dict(a, "UIFontDescriptorAttributes");
        try nib.dictPut(a, attrs, .{ .str = "NSFontSizeAttribute" }, if (@floor(point_size) == point_size) .{ .int = @intFromFloat(point_size) } else .{ .double = point_size });
        try nib.dictPut(a, attrs, .{ .str = "NSFontNameAttribute" }, .{ .str = name.? });
        try font.set(a, "UIFontDescriptor", .{ .obj = desc });
    } else {
        const t = ftype.?;
        const usage: []const u8 = if (std.mem.eql(u8, t, "system")) blk: {
            name = ".SFUI-Regular";
            break :blk "CTFontRegularUsage";
        } else if (std.mem.eql(u8, t, "boldSystem")) blk: {
            name = ".SFUI-Semibold";
            try font.set(a, "UIFontTraits", .{ .int = 2 });
            break :blk "CTFontEmphasizedUsage";
        } else if (std.mem.eql(u8, t, "italicSystem")) blk: {
            name = ".SFUI-Italic";
            try font.set(a, "UIFontTraits", .{ .int = 1 });
            break :blk "CTFontObliqueUsage";
        } else {
            c.doc.warn(e, "unsupported font type {s}; font skipped", .{t});
            return;
        };
        try font.set(a, "UISystemFont", .{ .boolean = true });
        const desc = try nib.new(a, "UIFontDescriptor");
        const attrs = try desc.dict(a, "UIFontDescriptorAttributes");
        try nib.dictPut(a, attrs, .{ .str = "NSFontSizeAttribute" }, .{ .double = size });
        try nib.dictPut(a, attrs, .{ .str = "NSCTFontUIUsageAttribute" }, .{ .str = usage });
        try font.set(a, "UIFontDescriptor", .{ .obj = desc });
    }
    try font.setStr(a, "UIFontName", name);
    try font.setStr(a, "NSName", name);
    try font.set(a, "UIFontPointSize", .{ .double = point_size });
    try font.set(a, "NSSize", .{ .double = size });
    try parent.set(a, "UIFont", .{ .obj = font });
}

/// Parse top-level elements into a nib root object.
fn parseObjects(c: *Ctx, elements: []const *const Element, resolve: bool) anyerror!*Obj {
    const a = c.a;
    var toplevel: std.ArrayList(*Obj) = .empty;
    for (elements) |el| if (try parseObject(c, el, null)) |o| try toplevel.append(a, o);
    if (resolve) try c.resolveConnections();
    const root = try nib.new(a, "NSObject");
    try root.set(a, "UINibTopLevelObjectsKey", .{ .list = try nib.listOf(a, toplevel.items) });
    try root.set(a, "UINibConnectionsKey", .{ .list = try nib.listOf(a, c.connections.items) });
    const all = try nib.listOf(a, toplevel.items);
    for (c.extra.items) |o| try all.items.append(a, .{ .obj = o });
    try root.set(a, "UINibObjectsKey", .{ .list = all });
    return root;
}

fn loadDoc(a: Allocator, path: []const u8) !struct { *Doc, *const Element } {
    const data = sys.readFile(a, path, 64 << 20) catch |err|
        return diag.fail("cannot read {s}: {s}", .{ path, @errorName(err) });
    const doc = try a.create(Doc);
    doc.* = .{ .a = a, .name = std.Io.Dir.path.basename(path) };
    const root = try xmldom.parse(a, data, doc.name);
    if (!std.mem.eql(u8, root.tag, "document")) return diag.fail("{s}: not an Interface Builder document", .{doc.name});
    if (root.get("targetRuntime")) |rt| if (std.mem.indexOf(u8, rt, "CocoaTouch") == null and !std.mem.eql(u8, rt, "iOS.CocoaTouch"))
        return diag.fail("{s}: only iOS (CocoaTouch) documents are supported, not {s}", .{ doc.name, rt });
    if (root.child("resources")) |res| for (res.children) |r| {
        if (!std.mem.eql(u8, r.tag, "systemColor") and !std.mem.eql(u8, r.tag, "namedColor")) continue;
        const name = r.get("name") orelse continue;
        if (r.child("color")) |col| try doc.colors.put(a, name, col);
    };
    return .{ doc, root };
}

pub const Result = struct { warnings: usize };

/// Compile a .xib into NIBArchive bytes.
pub fn compileXib(a: Allocator, path: []const u8) !struct { []u8, Result } {
    const doc, const root = try loadDoc(a, path);
    const objects = root.find("objects") orelse return diag.fail("{s}: no <objects>", .{doc.name});
    var c = Ctx.init(doc);
    const nib_root = try parseObjects(&c, objects.children, true);
    return .{ try nib.encode(a, nib_root), .{ .warnings = doc.warnings } };
}

const Scene = struct { vc: *Obj, root: *Obj, nib_name: []const u8 };

/// Compile a .storyboard into a .storyboardc directory at `out_dir` (replaced).
pub fn compileStoryboard(a: Allocator, path: []const u8, out_dir: []const u8) !Result {
    const doc, const root = try loadDoc(a, path);
    const scenes_el = root.find("scenes") orelse return diag.fail("{s}: no <scenes>", .{doc.name});
    try sys.deleteTree(out_dir);
    try sys.makePath(out_dir);
    var out = try sys.cwd().openDir(sys.io, out_dir, .{});
    defer out.close(sys.io);

    var id_to_nib = std.array_hash_map.String([]const u8).empty;
    var id_to_vc = std.array_hash_map.String(*Obj).empty;
    var identifiers = std.array_hash_map.String(void).empty;
    var scenes: std.ArrayList(Scene) = .empty;

    const owner = try nib.proxy(a, "IBFilesOwner");
    const sb_placeholder = try nib.proxy(a, "UIStoryboardPlaceholder");

    for (scenes_el.children) |scene| {
        if (!std.mem.eql(u8, scene.tag, "scene")) continue;
        const objects = scene.child("objects") orelse continue;
        var c = Ctx.init(doc);
        c.is_storyboard = true;
        var toplevel: std.ArrayList(*Obj) = .empty;
        for (objects.children) |el| if (try parseObject(&c, el, null)) |o| try toplevel.append(a, o);
        const vc = c.view_controller orelse {
            doc.warn(scene, "scene {s} has no view controller; skipped", .{scene.get("sceneID") orelse "?"});
            continue;
        };
        try c.resolveConnections();

        const vc_id = vc.ib.id orelse return diag.fail("{s}: view controller without id", .{doc.name});
        const nib_name = vc.ib.elem.?.nonEmpty("storyboardIdentifier") orelse try std.fmt.allocPrint(a, "UIViewController-{s}", .{vc_id});
        try identifiers.put(a, nib_name, {});
        try id_to_nib.put(a, vc_id, nib_name);
        try id_to_vc.put(a, vc_id, vc);

        if (vc.get("UIView")) |v| {
            const view = v.obj;
            vc.remove("UIView");
            for (c.extra.items, 0..) |o, i| if (o == view) {
                _ = c.extra.orderedRemove(i);
                break;
            };
            try view.extend(a, "UISubviews", c.layout_guides.items);
            const view_con = try nib.new(a, "UIRuntimeOutletConnection");
            try view_con.setStr(a, "UILabel", "view");
            try view_con.set(a, "UISource", .{ .obj = owner });
            try view_con.set(a, "UIDestination", .{ .obj = view });
            const view_nib = try std.fmt.allocPrint(a, "{s}-view-{s}", .{ vc_id, view.ib.id orelse "view" });
            const vroot = try nib.new(a, "NSObject");
            try vroot.set(a, "UINibTopLevelObjectsKey", .{ .list = try nib.listOf(a, &.{view}) });
            try vroot.set(a, "UINibObjectsKey", .{ .list = try nib.listOf(a, &.{view}) });
            const cons = try nib.listOf(a, &.{view_con});
            for (c.view_connections) |vc_| try cons.items.append(a, .{ .obj = vc_ });
            try vroot.set(a, "UINibConnectionsKey", .{ .list = cons });
            try out.writeFile(sys.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.nib", .{view_nib}), .data = try nib.encode(a, vroot) });
            try vc.setStr(a, "UINibName", view_nib);
        }

        try toplevel.append(a, owner);
        try toplevel.append(a, sb_placeholder);
        const owner_con = try nib.new(a, "UIRuntimeOutletConnection");
        try owner_con.setStr(a, "UILabel", "sceneViewController");
        try owner_con.set(a, "UISource", .{ .obj = owner });
        try owner_con.set(a, "UIDestination", .{ .obj = vc });
        const sb_con = try nib.new(a, "UIRuntimeOutletConnection");
        try sb_con.setStr(a, "UILabel", "storyboard");
        try sb_con.set(a, "UISource", .{ .obj = vc });
        try sb_con.set(a, "UIDestination", .{ .obj = sb_placeholder });
        var scene_cons: std.ArrayList(*Obj) = .empty;
        try scene_cons.append(a, sb_con);
        try scene_cons.appendSlice(a, vc.ib.scene_connections);
        vc.ib.scene_connections = scene_cons.items;

        const sroot = try nib.new(a, "NSObject");
        try sroot.set(a, "UINibTopLevelObjectsKey", .{ .list = try nib.listOf(a, toplevel.items) });
        const cons = try nib.listOf(a, &.{ owner_con, sb_con });
        for (c.scene_connections) |sc| try cons.items.append(a, .{ .obj = sc });
        try sroot.set(a, "UINibConnectionsKey", .{ .list = cons });
        const all = try nib.listOf(a, toplevel.items);
        // The view and its descendants live in the view nib only.
        for (c.extra.items) |o| {
            if (o.ib.id) |id| if (c.view_objects.contains(id)) continue;
            try all.items.append(a, .{ .obj = o });
        }
        try sroot.set(a, "UINibObjectsKey", .{ .list = all });
        try scenes.append(a, .{ .vc = vc, .root = sroot, .nib_name = nib_name });
    }

    // Second pass: segue destinations and relationship segues need every scene.
    for (scenes.items) |s| {
        if (s.vc.get("UIStoryboardSegueTemplates")) |templates| for (templates.list.items.items) |t| {
            const dest = t.obj.ib.segue_destination orelse continue;
            const name = id_to_nib.get(dest) orelse return diag.fail("{s}: segue destination {s} is not a view controller in this storyboard", .{ doc.name, dest });
            try t.obj.setStr(a, "UIDestinationViewControllerIdentifier", name);
        };
        var restore: ?struct { *Obj, std.ArrayList(nib.Prop) } = null;
        if (s.vc.ib.relationship_segue) |seg| {
            const rel = seg.get("relationship") orelse "";
            if (std.mem.eql(u8, rel, "rootViewController")) {
                const dest_id = seg.get("destination") orelse "";
                const child = id_to_vc.get(dest_id) orelse return diag.fail("{s}: relationship destination {s} not found", .{ doc.name, dest_id });
                try s.vc.set(a, "UIChildViewControllers", .{ .list = try nib.listOf(a, &.{child}) });
                try s.vc.set(a, "UIViewControllers", .{ .list = try nib.listOf(a, &.{child}) });
                const cons = s.root.get("UINibConnectionsKey").?.list;
                for (child.ib.scene_connections) |sc| try cons.items.append(a, .{ .obj = sc });
                restore = .{ child, try child.props.clone(a) };
                try child.set(a, "UIParentViewController", .{ .obj = s.vc });
            } else doc.warn(seg, "relationship '{s}' is not supported", .{rel});
        }
        try out.writeFile(sys.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.nib", .{s.nib_name}), .data = try nib.encode(a, s.root) });
        if (restore) |r| r[0].props = r[1];
    }

    const info = plist.Plist.newDict();
    defer info.deinit();
    const map = plist.c.plist_new_dict();
    for (identifiers.keys()) |k| _ = plist.c.plist_dict_set_item(map, try a.dupeSentinel(u8, k, 0), try plist.newString(a, k));
    try info.set(a, "UIViewControllerIdentifiersToNibNames", map);
    try info.set(a, "UIStoryboardVersion", plist.c.plist_new_int(1));
    if (root.nonEmpty("initialViewController")) |init_id| {
        try info.set(a, "UIStoryboardDesignatedEntryPointIdentifier", try plist.newString(a, id_to_nib.get(init_id) orelse init_id));
    }
    try out.writeFile(sys.io, .{ .sub_path = "Info.plist", .data = try info.toBinary(a) });
    return .{ .warnings = doc.warnings };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn writeTmp(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(sys.io, .{ .sub_path = name, .data = data });
}

fn dumpText(a: Allocator, bytes: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try nib.dump(a, bytes, &out.writer, false, "");
    return out.written();
}

test "compile a xib with outlets, actions, colors, fonts and constraints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "V.xib",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<document type="com.apple.InterfaceBuilder3.CocoaTouch.XIB" version="3.0" targetRuntime="iOS.CocoaTouch">
        \\  <objects>
        \\    <placeholder placeholderIdentifier="IBFilesOwner" id="-1" customClass="Owner">
        \\      <connections><outlet property="view" destination="v1" id="o1"/></connections>
        \\    </placeholder>
        \\    <placeholder placeholderIdentifier="IBFirstResponder" id="-2"/>
        \\    <view contentMode="scaleToFill" id="v1" customClass="MyView">
        \\      <rect key="frame" x="0" y="0" width="320" height="480"/>
        \\      <subviews>
        \\        <label text="Hi" textAlignment="center" translatesAutoresizingMaskIntoConstraints="NO" id="l1">
        \\          <fontDescription key="fontDescription" type="boldSystem" pointSize="20"/>
        \\          <color key="textColor" systemColor="labelColor"/>
        \\        </label>
        \\        <button buttonType="system" id="b1">
        \\          <state key="normal" title="Go"/>
        \\          <connections><action selector="go:" destination="-1" eventType="touchUpInside" id="a1"/></connections>
        \\        </button>
        \\      </subviews>
        \\      <viewLayoutGuide key="safeArea" id="sa"/>
        \\      <color key="backgroundColor" white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>
        \\      <constraints>
        \\        <constraint firstItem="l1" firstAttribute="centerX" secondItem="sa" secondAttribute="centerX" id="c1"/>
        \\        <constraint firstItem="l1" firstAttribute="top" secondItem="ghost" secondAttribute="top" id="c2"/>
        \\      </constraints>
        \\    </view>
        \\  </objects>
        \\  <resources><systemColor name="labelColor"><color red="0.1" green="0.2" blue="0.3" alpha="1" colorSpace="custom" customColorSpace="sRGB"/></systemColor></resources>
        \\</document>
    );
    const path = try tmp.dir.realPathFileAlloc(sys.io, "V.xib", a);
    const bytes, const res = try compileXib(a, path);
    try testing.expectEqual(@as(usize, 1), res.warnings); // the "ghost" constraint
    const text = try dumpText(a, bytes);
    for ([_][]const u8{
        "UIClassSwapper",                "UIClassName = @",      "\"MyView\"",
        "UIRuntimeEventConnection",      "\"go:\"",              "UIEventMask = 64",
        "UIRuntimeOutletConnection",     "\"view\"",             "UICenter = (160, 240)",
        "UIBounds = (0, 0, 320, 480)",   "UIFontTraits = 2",     "UIRed = 0.1",
        "NSRGB = \"1.000 1.000 1.000\"", "NSFirstAttribute = 9", "UIButtonContent",
        "\"Go\"",                        "UITextAlignment = 1",
    }) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("missing {s} in:\n{s}\n", .{ needle, text });
            return error.TestExpectedEqual;
        }
    }
    // The broken constraint is gone; the safe-area one points at the view itself.
    try testing.expect(std.mem.indexOf(u8, text, "NSFirstAttribute = 3") == null);
}

test "compile a storyboard with a navigation controller and a segue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "Main.storyboard",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" targetRuntime="iOS.CocoaTouch" initialViewController="nav">
        \\  <scenes>
        \\    <scene sceneID="s1">
        \\      <objects>
        \\        <navigationController id="nav" sceneMemberID="viewController">
        \\          <navigationBar key="navigationBar" contentMode="scaleToFill" id="bar">
        \\            <rect key="frame" x="0" y="20" width="320" height="44"/>
        \\          </navigationBar>
        \\          <connections><segue destination="vc" kind="relationship" relationship="rootViewController" id="r1"/></connections>
        \\        </navigationController>
        \\      </objects>
        \\    </scene>
        \\    <scene sceneID="s2">
        \\      <objects>
        \\        <viewController storyboardIdentifier="Home" id="vc" customClass="HomeViewController" sceneMemberID="viewController">
        \\          <view key="view" contentMode="scaleToFill" id="root">
        \\            <subviews>
        \\              <button buttonType="system" id="btn">
        \\                <connections><segue destination="vc2" kind="show" id="sg"/></connections>
        \\              </button>
        \\            </subviews>
        \\            <color key="backgroundColor" systemColor="systemBackgroundColor"/>
        \\          </view>
        \\          <navigationItem key="navigationItem" title="Home" id="ni"/>
        \\          <connections><outlet property="button" destination="btn" id="o1"/></connections>
        \\        </viewController>
        \\        <placeholder placeholderIdentifier="IBFirstResponder" id="fr" sceneMemberID="firstResponder"/>
        \\      </objects>
        \\    </scene>
        \\    <scene sceneID="s3">
        \\      <objects>
        \\        <viewController id="vc2" sceneMemberID="viewController">
        \\          <view key="view" contentMode="scaleToFill" id="v2"/>
        \\        </viewController>
        \\      </objects>
        \\    </scene>
        \\  </scenes>
        \\  <resources><systemColor name="systemBackgroundColor"><color white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/></systemColor></resources>
        \\</document>
    );
    const path = try tmp.dir.realPathFileAlloc(sys.io, "Main.storyboard", a);
    const out = try std.fmt.allocPrint(a, "{s}c", .{path});
    const res = try compileStoryboard(a, path, out);
    try testing.expectEqual(@as(usize, 0), res.warnings);
    var dir = try sys.cwd().openDir(sys.io, out, .{});
    defer dir.close(sys.io);
    for ([_][]const u8{ "Info.plist", "UIViewController-nav.nib", "Home.nib", "vc-view-root.nib", "UIViewController-vc2.nib", "vc2-view-v2.nib" }) |f|
        try dir.access(sys.io, f, .{});

    const info = try plist.readFile(a, try std.Io.Dir.path.join(a, &.{ out, "Info.plist" }));
    defer info.deinit();
    try testing.expectEqualStrings("UIViewController-nav", (try info.getString(a, "UIStoryboardDesignatedEntryPointIdentifier")).?);

    const home = try dumpText(a, try dir.readFileAlloc(sys.io, "Home.nib", a, .limited(1 << 20)));
    try testing.expect(std.mem.indexOf(u8, home, ": UIButton") == null); // only in the view nib
    for ([_][]const u8{ "UIStoryboardShowSegueTemplate", "\"UIViewController-vc2\"", "UIExternalObjectsTableForViewLoading", "\"vc-view-root\"", "\"HomeViewController\"" }) |needle|
        try testing.expect(std.mem.indexOf(u8, home, needle) != null);
    const view = try dumpText(a, try dir.readFileAlloc(sys.io, "vc-view-root.nib", a, .limited(1 << 20)));
    for ([_][]const u8{ "\"perform:\"", "UpstreamPlaceholder-idl-", "UIButton" }) |needle|
        try testing.expect(std.mem.indexOf(u8, view, needle) != null);
    const nav = try dumpText(a, try dir.readFileAlloc(sys.io, "UIViewController-nav.nib", a, .limited(1 << 20)));
    for ([_][]const u8{ "UINavigationController", "UIChildViewControllers", "UIParentViewController", "UINavigationBar" }) |needle|
        try testing.expect(std.mem.indexOf(u8, nav, needle) != null);
}

test "non-iOS documents are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTmp(tmp.dir, "Mac.xib", "<document targetRuntime=\"MacOSX.Cocoa\"><objects/></document>");
    const path = try tmp.dir.realPathFileAlloc(sys.io, "Mac.xib", arena.allocator());
    try testing.expectError(error.Invalid, compileXib(arena.allocator(), path));
}

test "strict validation rejects unsupported elements and unresolved outlets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.path.join(a, &.{ try tmp.dir.realPathFileAlloc(sys.io, ".", a), "Strict.xib" });
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "Strict.xib", .data = "<document><objects><stackView id=\"s\"/></objects></document>" });
    try testing.expectError(error.Invalid, validate(a, path, true));
    try testing.expect(std.mem.indexOf(u8, diag.msg, "stackView") != null);
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "Strict.xib", .data = "<document><objects><view id=\"v\"><connections><outlet property=\"missing\" destination=\"ghost\"/></connections></view></objects></document>" });
    try testing.expectError(error.Invalid, validate(a, path, true));
    try testing.expect(std.mem.indexOf(u8, diag.msg, "ghost") != null);
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "Strict.xib", .data = "<document><objects><view id=\"v\"><rect key=\"frame\" x=\"0\" y=\"0\" width=\"10\" height=\"10\"/></view></objects></document>" });
    try validate(a, path, true);
}

/// Scan the entire input, including children of unsupported objects. Permissive
/// builds diagnose omissions; strict builds reject them before app compilation.
pub fn validate(a: Allocator, path: []const u8, strict: bool) !void {
    const doc, const root = try loadDoc(a, path);
    var ids = std.StringHashMap(*const Element).init(a);
    try collectIds(doc, root, &ids);
    try validateElement(doc, root, &ids, strict);
    if (root.nonEmpty("initialViewController")) |id| {
        const entry = ids.get(id) orelse return diag.fail("{s}: initial view controller '{s}' does not exist", .{ doc.name, id });
        if (!inSet(entry.tag, &.{ "viewController", "navigationController", "tableViewController" }))
            return diag.fail("{s}: initial view controller '{s}' is not a supported controller", .{ doc.name, id });
    }
}

fn collectIds(doc: *Doc, e: *const Element, ids: *std.StringHashMap(*const Element)) anyerror!void {
    if (e.nonEmpty("id")) |id| {
        const entry = try ids.getOrPut(id);
        if (entry.found_existing) return diag.fail("{s}:{d}: duplicate IB object id '{s}'", .{ doc.name, e.line, id });
        entry.value_ptr.* = e;
    }
    for (e.children) |child| try collectIds(doc, child, ids);
}

fn issue(doc: *Doc, e: *const Element, strict: bool, comptime fmt: []const u8, args: anytype) !void {
    if (strict) return diag.fail("{s}:{d}: " ++ fmt, .{ doc.name, e.line } ++ args);
    doc.warn(e, fmt, args);
}

fn inSet(value: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, value, n)) return true;
    return false;
}

fn validateElement(doc: *Doc, e: *const Element, ids: *const std.StringHashMap(*const Element), strict: bool) anyerror!void {
    // IB design-time metadata and structural containers do not enter a nib.
    const metadata_tags = [_][]const u8{ "document", "objects", "scenes", "scene", "resources", "systemColor", "namedColor", "device", "dependencies", "deployment", "plugIn", "capability", "point", "size", "nil", "simulatedScreenMetrics", "simulatedOrientationMetrics", "simulatedStatusBarMetrics", "freeformSimulatedSizeMetrics" };
    const tag = std.meta.stringToEnum(Tag, e.tag);
    if (tag == null and !inSet(e.tag, &metadata_tags))
        try issue(doc, e, strict, "unsupported Interface Builder element <{s}>", .{e.tag});
    for ([_][]const u8{ "destination", "firstItem", "secondItem", "textLabel", "detailTextLabel", "imageView" }) |key| {
        if (e.nonEmpty(key)) |id| if (!ids.contains(id))
            try issue(doc, e, strict, "{s} refers to missing object '{s}'", .{ key, id });
    }
    if (tag) |t| {
        // Reject semantic attributes that the port cannot encode; design-time
        // IDs, canvas settings and inferred layout hints are intentionally ignored.
        const common = [_][]const u8{ "id", "key", "userLabel", "sceneMemberID", "customClass", "restorationIdentifier", "misplaced", "fixedFrame", "ambiguous", "horizontalHuggingPriority", "verticalHuggingPriority", "horizontalCompressionResistancePriority", "verticalCompressionResistancePriority" };
        const view_attrs = [_][]const u8{ "contentMode", "clipsSubviews", "translatesAutoresizingMaskIntoConstraints", "hidden", "userInteractionEnabled", "alpha", "tag", "text", "opaque" };
        const is_view = inSet(e.tag, &.{ "view", "label", "button", "imageView", "textView", "textField", "scrollView", "switch", "slider", "searchBar", "navigationBar", "visualEffectView", "tableView", "tableViewCell", "tableViewCellContentView", "activityIndicatorView", "progressView" });
        for (e.attrs) |attr| {
            if (inSet(attr.name, &common) or (is_view and inSet(attr.name, &view_attrs))) continue;
            const supported = switch (t) {
                .placeholder => inSet(attr.name, &.{"placeholderIdentifier"}),
                .viewController, .navigationController, .tableViewController => inSet(attr.name, &.{"storyboardIdentifier"}),
                .label => inSet(attr.name, &.{ "numberOfLines", "textAlignment", "lineBreakMode" }),
                .button => inSet(attr.name, &.{"buttonType"}),
                .navigationBar => inSet(attr.name, &.{ "translucent", "barStyle" }),
                .tableView => inSet(attr.name, &.{ "separatorStyle", "rowHeight", "dataMode" }),
                .tableViewCell => inSet(attr.name, &.{ "textLabel", "detailTextLabel", "imageView", "reuseIdentifier", "style", "selectionStyle", "indentationWidth", "indentationLevel", "accessoryType", "editingAccessoryType", "showsReorderControl" }),
                .state => inSet(attr.name, &.{"title"}),
                .outlet => inSet(attr.name, &.{ "property", "destination" }),
                .action => inSet(attr.name, &.{ "selector", "destination", "eventType" }),
                .segue => inSet(attr.name, &.{ "destination", "kind", "identifier", "relationship", "modalPresentationStyle", "modalTransitionStyle", "animates", "splitViewControllerTargetIndex", "trigger" }),
                .viewControllerLayoutGuide => inSet(attr.name, &.{"type"}),
                .constraint => inSet(attr.name, &.{ "firstItem", "firstAttribute", "secondItem", "secondAttribute", "constant", "priority", "multiplier", "relation" }),
                .navigationItem => inSet(attr.name, &.{"title"}),
                .barButtonItem => inSet(attr.name, &.{ "style", "enabled", "title", "systemItem" }),
                .blurEffect => inSet(attr.name, &.{"style"}),
                .color => inSet(attr.name, &.{ "red", "green", "blue", "white", "alpha", "colorSpace", "customColorSpace", "systemColor", "cocoaTouchSystemColor", "name" }),
                .rect => inSet(attr.name, &.{ "x", "y", "width", "height" }),
                .inset => inSet(attr.name, &.{ "minX", "maxX", "minY", "maxY" }),
                .autoresizingMask => inSet(attr.name, &.{ "flexibleMinX", "widthSizable", "flexibleMaxX", "flexibleMinY", "heightSizable", "flexibleMaxY" }),
                .textInputTraits => inSet(attr.name, &.{"secureTextEntry"}),
                .fontDescription => inSet(attr.name, &.{ "type", "style", "name", "pointSize", "family" }),
                else => false,
            };
            if (!supported) try issue(doc, e, strict, "unsupported attribute {s} on <{s}>", .{ attr.name, e.tag });
        }
    }
    for (e.children) |child| try validateElement(doc, child, ids, strict);
}

test "storyboard initial entry must be a controller not just an existing id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(sys.io, .{ .sub_path = "Bad.storyboard", .data = "<document initialViewController=\"label\"><scenes><scene><objects><viewController id=\"vc\" sceneMemberID=\"viewController\"><view key=\"view\" id=\"view\"><subviews><label id=\"label\"/></subviews></view></viewController></objects></scene></scenes></document>" });
    try testing.expectError(error.Invalid, validate(a, try tmp.dir.realPathFileAlloc(sys.io, "Bad.storyboard", a), true));
}
