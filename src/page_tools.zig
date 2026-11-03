//! Tools page: the tools the gateway aggregates, a filter over them, the
//! chosen tool's schema, and a call to try it.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const kit = @import("kit.zig");
const json = @import("json_util.zig");
const gateway_views = @import("gateway_views.zig");
const ToolView = gateway_views.ToolView;
const App = state_mod.App;

pub fn page(c: *ui.Context, s: *App, k: theme.Colors) void {
    // The views and their schemas are read while the frame is laid out and
    // painted, so they live in the context's arena, which the frame keeps
    // until the next one begins.
    const a = c.arena.allocator();

    const all = gateway_views.toolViews(s.gw, a) catch &.{};
    const visible = visibleTools(a, s, all) catch &.{};
    keys(c, s, visible.len);
    const chosen = choose(s, visible.len);

    const header = kit.header(c, k, "Tools", "What clients of the gateway see, named after the server each tool comes from.");
    if (s.settings.busy.len > 0) {
        ui.text(c, s.settings.busy, .{ .size = 11, .color = k.secondary });
    }
    header.end();

    if (all.len == 0) {
        noTools(c, s, k);
        return;
    }

    {
        const bar = ui.div(c).row().wFull().gap(10).itemsCenter().px(20).pb(2);
        defer bar.end();
        _ = ui.textField(c, &s.tools.filter, .{
            .placeholder = "Filter by tool or server…",
            .width = .{ .px = 280 },
            .size = 13,
        });
        ui.spacer(c);
        ui.text(c, summary(c, s, visible.len, all.len), .{ .size = 11, .color = k.secondary });
    }

    if (visible.len == 0) {
        noMatch(c, s, k);
        return;
    }

    const body = ui.div(c).row().wFull().grow().gap(14).itemsStretch().px(20).pb(20);
    defer body.end();
    table(c, s, k, all, visible, chosen.?);
    detail(c, s, k, all[visible[chosen.?]]);
}

/// The chosen row, kept on a row while one is there and moved to the first
/// when the filter leaves it behind.
fn choose(s: *App, n: usize) ?usize {
    if (n == 0) {
        s.tools.selected = null;
        return null;
    }
    const clamped = @min(s.tools.selected orelse 0, n - 1);
    s.tools.selected = clamped;
    return clamped;
}

/// Up and down move the choice, as the table does in the Go original. The
/// filter keeps the keyboard while it is focused.
fn keys(c: *ui.Context, s: *App, n: usize) void {
    if (c.focused_text != null or n == 0) return;
    const selected = s.tools.selected orelse 0;
    if (c.shortcut(.{ .key = ui.Shortcut.up })) {
        s.tools.selected = if (selected > 0) selected - 1 else 0;
        s.redisplay();
    }
    if (c.shortcut(.{ .key = ui.Shortcut.down })) {
        s.tools.selected = @min(selected + 1, n - 1);
        s.redisplay();
    }
}

/// The tools the filter keeps, as places in `all`, in order. An empty filter
/// keeps every one. Caller frees.
fn visibleTools(a: std.mem.Allocator, s: *App, all: []const ToolView) ![]usize {
    const query = std.mem.trim(u8, s.tools.filter.text(), " \t\r\n");
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(a);
    for (all, 0..) |tool, i| {
        if (query.len == 0 or matches(tool, query)) try out.append(a, i);
    }
    return out.toOwnedSlice(a);
}

/// Whether a tool matches a query, by its name, its server's name, or its
/// description. The comparison ignores case.
fn matches(tool: ToolView, query: []const u8) bool {
    return containsIgnoreCase(tool.name, query) or
        containsIgnoreCase(tool.server_name, query) or
        containsIgnoreCase(tool.description, query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// What the filter leaves, for the row above the table.
fn summary(c: *ui.Context, s: *App, shown: usize, total: usize) []const u8 {
    if (std.mem.trim(u8, s.tools.filter.text(), " \t\r\n").len == 0) {
        return c.print("{d} tools", .{total});
    }
    return c.print("{d} of {d} tools shown", .{ shown, total });
}

/// The table: a column header and one row per tool the filter keeps.
fn table(c: *ui.Context, s: *App, k: theme.Colors, all: []const ToolView, visible: []const usize, chosen: usize) void {
    const panel = ui.div(c).column().grow().minW(0).rounded(8).border(k.border).bg(k.card).clip();
    defer panel.end();

    {
        const head = ui.div(c).row().wFull().h(30).itemsCenter().gap(10).px(10).bg(k.well);
        defer head.end();
        cell(c, "Tool", 200, .{ .size = 10, .weight = .semibold, .color = k.tertiary });
        cell(c, "Server", 110, .{ .size = 10, .weight = .semibold, .color = k.tertiary });
        cell(c, "Description", null, .{ .size = 10, .weight = .semibold, .color = k.tertiary });
    }

    var rows = ui.list(c, .{ .count = visible.len, .row_height = 32 });
    while (rows.next()) |row_index| {
        const tool = all[visible[row_index]];
        row(c, s, k, tool, row_index, row_index == chosen);
    }
    rows.end();
}

/// One tool's row: its namespaced name, the server it comes from, and what it
/// does. The chosen row is painted in the accent color, so its other columns
/// are drawn for a dark background.
fn row(c: *ui.Context, s: *App, k: theme.Colors, tool: ToolView, row_index: usize, selected: bool) void {
    const muted = if (selected) k.on_picked.alpha(0.82) else k.secondary;
    const d = ui.div(c).row().wFull().h(32).itemsCenter().gap(10).px(10)
        .bg(if (selected) k.picked else k.page.alpha(0))
        .hover(k.hover)
        .control();
    defer d.end();
    cell(c, tool.name, 200, .{ .size = 13, .color = if (selected) k.on_picked else k.text });
    cell(c, tool.server_name, 110, .{ .size = 12, .color = muted });
    cell(c, tool.description, null, .{ .size = 12, .color = muted });
    if (d.interaction().clicked) {
        s.tools.selected = row_index;
        s.redisplay();
    }
}

/// A cell of the table, clipped to its column: a fixed width, or the rest of
/// the row when there is none.
fn cell(c: *ui.Context, text: []const u8, width: ?f32, opts: ui.TextStyle) void {
    const d = if (width) |w| ui.div(c).w(w).minW(w).clip() else ui.div(c).grow().w(0).minW(0).clip();
    defer d.end();
    ui.text(c, text, opts);
}

/// The chosen tool: where it comes from, its schema, and a call to try.
fn detail(c: *ui.Context, s: *App, k: theme.Colors, tool: ToolView) void {
    const panel = ui.div(c).column().w(380).p(16).gap(8).rounded(12).bg(k.card)
        .border(k.border).shadowSm().scrollY();
    defer panel.end();

    ui.text(c, tool.name, .{ .size = 14, .weight = .bold, .color = k.text });
    ui.text(c, c.print("{s} · {s} at {s}", .{ tool.server_name, tool.upstream, transportWord(s, tool.server_id) }), .{
        .size = 11,
        .color = k.secondary,
    });
    if (std.mem.trim(u8, tool.description, " \t\r\n").len > 0) {
        ui.text(c, tool.description, .{ .size = 12, .color = k.secondary, .wrap = true });
    }

    {
        const buttons = ui.div(c).row().gap(8);
        defer buttons.end();
        if (ui.button(c, "Copy name", .{ .variant = .secondary, .size = 11 }).clicked) {
            c.clipboard.write(c.clipboard.ctx, tool.name);
            s.notify("Tool name copied", false);
        }
        if (ui.button(c, "Copy schema", .{ .variant = .secondary, .size = 11 }).clicked) {
            c.clipboard.write(c.clipboard.ctx, tool.schema);
            s.notify("Schema copied", false);
        }
    }

    ui.divider(c);

    ui.text(c, "Input schema", .{ .size = 12, .weight = .bold, .color = k.text });
    {
        const box = ui.div(c).column().wFull().p(8).rounded(6).bg(k.sidebar).maxH(220).scrollY();
        defer box.end();
        const schema = if (std.mem.trim(u8, tool.schema, " \t\r\n").len == 0) "No parameters." else tool.schema;
        ui.text(c, schema, .{ .size = 11, .mono = true, .color = k.secondary, .wrap = true });
    }

    ui.divider(c);

    ui.text(c, "Test call", .{ .size = 12, .weight = .bold, .color = k.text });
    _ = ui.textField(c, &s.tools.call_args, .{
        .placeholder = "{\"path\": \"/tmp\"}",
        .size = 11,
        .width = .fill,
    });

    {
        const buttons = ui.div(c).row().gap(8).itemsCenter();
        defer buttons.end();
        if (s.tools.calling) {
            ui.text(c, "Calling…", .{ .size = 11, .color = k.secondary });
        } else if (ui.button(c, "Call tool", .{ .variant = .primary, .size = 12 }).clicked) {
            run(s, tool.name);
        }
        if (s.tools.call_result.len > 0) {
            if (ui.button(c, "Clear", .{ .variant = .secondary, .size = 12 }).clicked) {
                s.freeCall();
                s.redisplay();
            }
        }
        ui.spacer(c);
    }

    if (s.tools.call_result.len > 0) {
        const out = ui.div(c).column().wFull().h(130).p(8).rounded(6).border(k.border).scrollY();
        defer out.end();
        ui.text(c, s.tools.call_result, .{
            .size = 11,
            .mono = true,
            .color = if (s.tools.call_err) k.red else k.secondary,
            .wrap = true,
        });
    }
}

/// The transport a tool's server uses, as the form names it.
fn transportWord(s: *App, server_id: []const u8) []const u8 {
    const sc = s.cfg.server(server_id) orelse return "unknown";
    return sc.transport.label();
}

fn noTools(c: *ui.Context, s: *App, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().grow().center().gap(10).p(40);
    defer d.end();
    ui.icon(c, "cube", .{ .size = 28, .color = k.secondary.alpha(0.5) });
    ui.text(c, "No tools yet", .{ .size = 15, .weight = .semibold, .color = k.secondary });
    {
        const wrap = ui.div(c).w(460).column();
        defer wrap.end();
        ui.text(c, "Connect a server on the Servers page and its tools show up here. Enable the gateway on Settings to serve them.", .{
            .size = 12,
            .color = k.tertiary,
            .wrap = true,
        });
    }
    if (ui.button(c, "Go to Servers", .{ .variant = .primary, .size = 12 }).clicked) {
        s.page = .servers;
        s.redisplay();
    }
}

/// What the page shows when the filter keeps nothing.
fn noMatch(c: *ui.Context, s: *App, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().grow().center().gap(10).p(40);
    defer d.end();
    ui.text(c, "No tools match", .{ .size = 15, .weight = .semibold, .color = k.text });
    const query = std.mem.trim(u8, s.tools.filter.text(), " \t\r\n");
    ui.text(c, c.print("Nothing matches \"{s}\".", .{query}), .{ .size = 12, .color = k.secondary });
    if (ui.button(c, "Clear the filter", .{ .variant = .secondary, .size = 12 }).clicked) {
        s.tools.filter.clear();
        s.redisplay();
    }
}

/// Calls the tool with the arguments in the box, off the drawing thread.
fn run(s: *App, name: []const u8) void {
    const a = s.gpa;
    const text = std.mem.trim(u8, s.tools.call_args.text(), " \t\r\n");

    // Bad JSON is the one failure known before the call starts.
    if (text.len > 0) {
        var probe = std.heap.ArenaAllocator.init(a);
        defer probe.deinit();
        _ = json.parse(probe.allocator(), text) catch |e| {
            const message = std.fmt.allocPrint(a, "Arguments are not valid JSON: {s}", .{@errorName(e)}) catch return;
            s.finishCall(message, true);
            return;
        };
    }

    const args_text = a.dupe(u8, text) catch return;
    const tool_name = a.dupe(u8, name) catch {
        a.free(args_text);
        return;
    };
    s.beginCall();
    const thread = std.Thread.spawn(.{}, callThread, .{ s, tool_name, args_text }) catch {
        a.free(tool_name);
        a.free(args_text);
        s.finishCall(a.dupe(u8, "the call could not be started") catch "", true);
        return;
    };
    thread.detach();
}

fn callThread(s: *App, name: []const u8, args_text: []const u8) void {
    const a = s.gpa;
    defer a.free(name);
    defer a.free(args_text);

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args: ?json.Value = if (args_text.len == 0) null else json.parse(arena, args_text) catch {
        announce(s, a.dupe(u8, "Arguments are not valid JSON") catch "", true);
        return;
    };
    const answer = s.gw.callTool(arena, name, args) catch |e| {
        announce(s, a.dupe(u8, @errorName(e)) catch "", true);
        return;
    };
    const shown = format(a, answer) catch {
        announce(s, a.dupe(u8, "the answer could not be read") catch "", true);
        return;
    };
    announce(s, shown, json.getBool(answer, "isError") orelse false);
}

/// A tool's answer as text: its content blocks when every one of them is
/// text, its JSON otherwise. A tool error keeps its "error:" prefix.
pub fn format(a: std.mem.Allocator, answer: json.Value) ![]const u8 {
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(a);
    var all_text = true;
    if (json.getArray(answer, "content")) |blocks| {
        for (blocks.items) |block| {
            const text = json.getString(block, "text") orelse {
                all_text = false;
                break;
            };
            try texts.append(a, text);
        }
    } else all_text = false;

    if (texts.items.len > 0 and all_text) {
        var out: std.ArrayList(u8) = .empty;
        for (texts.items, 0..) |text, i| {
            if (i > 0) try out.append(a, '\n');
            try out.appendSlice(a, text);
        }
        const joined = try out.toOwnedSlice(a);
        if (json.getBool(answer, "isError") orelse false) {
            defer a.free(joined);
            return std.fmt.allocPrint(a, "error: {s}", .{joined});
        }
        return joined;
    }
    return json.J.from(a, answer).dumpIndent();
}

fn announce(s: *App, text: []const u8, is_err: bool) void {
    if (comptime builtin.os.tag == .macos) {
        const box = s.gpa.create(CallBox) catch {
            if (text.len > 0) s.gpa.free(text);
            return;
        };
        box.* = .{ .s = s, .text = text, .is_err = is_err };
        nanoui.objc.dispatchMain(box, deliver);
    } else s.finishCall(text, is_err);
}

const CallBox = struct {
    s: *App,
    text: []const u8,
    is_err: bool,
};

fn deliver(ctx: ?*anyopaque) callconv(.c) void {
    const box: *CallBox = @ptrCast(@alignCast(ctx.?));
    const s = box.s;
    const text = box.text;
    const is_err = box.is_err;
    s.gpa.destroy(box);
    s.finishCall(text, is_err);
}
