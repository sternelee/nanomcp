//! Servers page: the gateway's configured servers as rows or cards, with a
//! header of actions, a filter and a summary of how they are doing.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const kit = @import("kit.zig");
const gateway_views = @import("gateway_views.zig");
const config = @import("config.zig");
const actions = @import("server_actions.zig");
const views = @import("server_views.zig");

const App = state_mod.App;

pub fn page(c: *ui.Context, s: *App, k: theme.Colors) void {
    const list = gateway_views.servers(s.gw, c.arena.allocator()) catch &.{};
    const shown = visibleViews(s.gpa, s, list) catch &.{};
    defer if (shown.len > 0) s.gpa.free(shown);
    clampSelection(s, shown.len);

    const selected_view: ?gateway_views.ServerView = if (shown.len > 0) list[shown[s.servers.selected]] else null;
    const selected_id: ?[]const u8 = if (selected_view) |v| v.config.id else null;

    // Enter opens the chosen server. It is left to the field while the
    // filter has the keyboard.
    if (c.focused_text == null and c.shortcut(.{ .key = ui.Shortcut.enter })) {
        if (selected_id) |id| actions.editServer(s, id);
    }

    const header = kit.header(c, k, "Servers", "Upstream MCP servers whose tools this gateway serves as one.");
    headerActions(c, s, k, selected_id);
    header.end();

    if (list.len == 0) {
        emptyState(c, s, k);
        return;
    }

    toolbar(c, s, k, list);

    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(10);
    if (shown.len == 0) {
        noMatch(c, s, k);
    } else if (s.servers.grid) {
        gridBody(c, s, k, list, shown, body);
    } else {
        listBody(c, s, k, list, shown);
    }
    body.end();

    // The list's own tip, under it rather than scrolling with the rows.
    if (!s.servers.grid) if (selected_view) |v| {
        const hint = ui.div(c).row().wFull().px(20).pb(14);
        defer hint.end();
        ui.text(c, c.print("Double-click a server to edit it. Its tools are named {s}__…", .{v.config.alias}), .{
            .size = 11,
            .color = k.secondary,
        });
    };
}

/// The page's actions: the chosen server's own, and adding or importing.
fn headerActions(c: *ui.Context, s: *App, k: theme.Colors, selected_id: ?[]const u8) void {
    _ = k;
    const has = selected_id != null;
    if (ui.button(c, "Edit…", .{ .variant = .secondary, .size = 12, .disabled = !has }).clicked) {
        if (selected_id) |id| actions.editServer(s, id);
    }
    if (ui.button(c, "Reconnect", .{ .variant = .secondary, .size = 12, .disabled = !has }).clicked) {
        if (selected_id) |id| actions.reconnect(s, id);
    }
    if (ui.button(c, "Remove", .{ .variant = .secondary, .size = 12, .disabled = !has }).clicked) {
        if (selected_id) |id| s.servers.removing = id;
    }
    if (ui.button(c, "Paste JSON…", .{ .variant = .secondary, .size = 12 }).clicked) actions.openImport(s);
    if (ui.button(c, "Add server…", .{ .variant = .primary, .size = 12 }).clicked) actions.addServer(s);
}

/// The filter, the counts, and the choice between rows and cards.
fn toolbar(c: *ui.Context, s: *App, k: theme.Colors, list: []const gateway_views.ServerView) void {
    const r = ui.div(c).row().wFull().gap(10).itemsCenter().px(20).pb(2);
    defer r.end();

    const result = ui.textField(c, &s.servers.filter, .{ .placeholder = "Filter by name, command or URL…", .width = .{ .px = 280 }, .size = 13 });
    if (result.changed) s.servers.selected = 0;

    ui.spacer(c);
    ui.text(c, summary(c, list), .{ .size = 11, .color = k.secondary });
    const modes: [2][]const u8 = .{ "List", "Grid" };
    var pick: usize = if (s.servers.grid) 1 else 0;
    if (ui.segmented(c, &modes, &pick)) {
        s.servers.grid = pick == 1;
        s.redisplay();
    }
}

/// "N ready · N need sign-in · N failed · N off", leaving out what is zero.
fn summary(c: *ui.Context, list: []const gateway_views.ServerView) []const u8 {
    var ready: usize = 0;
    var auth: usize = 0;
    var failed: usize = 0;
    var off: usize = 0;
    for (list) |v| switch (v.status) {
        .ready => ready += 1,
        .needs_auth => auth += 1,
        .failed => failed += 1,
        else => off += 1,
    };
    const parts = [_]?[]const u8{
        c.print("{d} ready", .{ready}),
        if (auth > 0) c.print("{d} need sign-in", .{auth}) else null,
        if (failed > 0) c.print("{d} failed", .{failed}) else null,
        if (off > 0) c.print("{d} off", .{off}) else null,
    };
    var out: []const u8 = "";
    for (parts) |part| {
        const piece = part orelse continue;
        out = if (out.len == 0) piece else c.print("{s} \u{00b7} {s}", .{ out, piece });
    }
    return out;
}

/// The views the filter keeps, as indices into `list`, in order. An empty
/// filter keeps every one of them. Caller frees.
fn visibleViews(a: std.mem.Allocator, s: *App, list: []const gateway_views.ServerView) ![]usize {
    const query = std.mem.trim(u8, s.servers.filter.text(), " \t\r\n");
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(a);
    for (list, 0..) |v, i| {
        if (query.len == 0 or matches(v.config, query)) try out.append(a, i);
    }
    return try out.toOwnedSlice(a);
}

/// Whether a server matches a query, by its name, alias, transport, command
/// or URL. The comparison ignores case.
fn matches(sc: config.ServerConfig, query: []const u8) bool {
    const fields = [_][]const u8{
        sc.name,
        sc.alias,
        sc.transport.label(),
        sc.command orelse "",
        sc.url orelse "",
    };
    for (fields) |field| {
        if (containsIgnoreCase(field, query)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var same = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

/// Keeps the selection on a row while there is one, so the filter or a
/// removal never leaves it pointing at one that is gone.
fn clampSelection(s: *App, n: usize) void {
    if (n == 0) {
        s.servers.selected = 0;
    } else if (s.servers.selected >= n) {
        s.servers.selected = n - 1;
    }
}

fn listBody(c: *ui.Context, s: *App, k: theme.Colors, list: []const gateway_views.ServerView, shown: []const usize) void {
    const panel = ui.div(c).column().wFull().p(4).gap(2).rounded(10).border(k.border).bg(k.card).shadowSm();
    defer panel.end();
    for (shown, 0..) |view_index, row| views.row(c, s, k, list[view_index], row);
}

fn gridBody(c: *ui.Context, s: *App, k: theme.Colors, list: []const gateway_views.ServerView, shown: []const usize, body: ui.Div) void {
    const cols = gridColumns(c, body);
    var start: usize = 0;
    while (start < shown.len) : (start += cols) {
        const line = ui.div(c).row().wFull().gap(10).itemsStart();
        const end = @min(start + cols, shown.len);
        for (shown[start..end], start..) |view_index, item| views.card(c, s, k, list[view_index], item);
        line.end();
    }
}

/// How many 280px cards fit beside each other, from the body's last frame.
fn gridColumns(c: *ui.Context, body: ui.Div) usize {
    const rect = c.rects.get(c.node(body.index).id);
    const avail = if (rect) |r| r.w - 40 else c.size.w - 221 - 40;
    return @max(1, @as(usize, @intFromFloat(@floor(@max(0.0, (avail + 10) / 290)))));
}

fn emptyState(c: *ui.Context, s: *App, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().grow().center().gap(10).p(40);
    defer d.end();
    ui.text(c, "No servers yet", .{ .size = 15, .weight = .bold, .color = k.text });
    {
        const wrap = ui.div(c).w(460).column();
        ui.text(c, "Add a stdio command or a remote URL by hand, or paste a configuration from Claude Desktop, Cursor or VS Code.", .{
            .size = 12,
            .color = k.secondary,
            .wrap = true,
        });
        wrap.end();
    }
    const row = ui.div(c).row().gap(8);
    defer row.end();
    if (ui.button(c, "Paste a configuration…", .{ .variant = .secondary, .size = 12 }).clicked) actions.openImport(s);
    if (ui.button(c, "Add your first server…", .{ .variant = .primary, .size = 12 }).clicked) actions.addServer(s);
}

/// What the page shows when the filter keeps nothing.
fn noMatch(c: *ui.Context, s: *App, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().grow().center().gap(10).p(40);
    defer d.end();
    ui.text(c, "No servers match", .{ .size = 15, .weight = .bold, .color = k.text });
    const query = std.mem.trim(u8, s.servers.filter.text(), " \t\r\n");
    ui.text(c, c.print("Nothing matches \"{s}\".", .{query}), .{ .size = 12, .color = k.secondary });
    if (ui.button(c, "Clear the filter", .{ .variant = .secondary, .size = 12 }).clicked) {
        s.servers.filter.clear();
        s.servers.selected = 0;
    }
}
