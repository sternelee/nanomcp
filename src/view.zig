//! nanomcp's window: a sidebar of pages with a figure beside each, and the
//! page: servers, the market, the routes, the tools, and settings.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("kit.zig");
const state_mod = @import("state.zig");
const servers = @import("page_servers.zig");
const market = @import("page_market.zig");
const routes = @import("page_routes.zig");
const tools = @import("page_tools.zig");
const settings = @import("page_settings.zig");
const menubar = @import("menubar.zig");
const toast = @import("toast.zig");
const server_menu = @import("server_menu.zig");
const server_dialogs = @import("server_dialogs.zig");
const gateway_views = @import("gateway_views.zig");
const App = state_mod.App;

const sidebar_width: f32 = 220;
const sidebar_rail: f32 = 64;
const sidebar_tile: f32 = 32;

pub fn view(s: *App, c: *ui.Context) void {
    const dark = nanoui.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);

    // A server's row menu belongs to the page that opened it: going elsewhere
    // leaves no menu hanging over the new page. Dialogs stay: they can be
    // opened from another page, as the Market's add form is.
    if (s.page != .servers) s.servers.menu = null;

    c.frameIn(0.5);
    kit.keys(c, s, server_dialogs.anyOpen(s));
    const root = ui.div(c).row().sizeFull().bg(k.page);
    defer root.end();
    sidebar(c, s, k);
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.separator }, .none, null);
    {
        const main = ui.div(c).column().grow().w(0).hFull().clip();
        defer main.end();
        switch (s.page) {
            .servers => servers.page(c, s, k),
            .market => market.page(c, s, k),
            .routes => routes.page(c, s, k),
            .tools => tools.page(c, s, k),
            .settings => settings.page(c, s, k),
        }
    }
    // Overlays of the Servers page: its menu first, then its dialogs.
    server_menu.draw(c, s, k);
    server_dialogs.draw(c, s, k);
    // The toast belongs to the window, not a page: it shows wherever the
    // change that raised it happened.
    toast.toast(c, s, k);
    // The icon beside the clock counts the agents the gateway is serving.
    if (s.tray) |tray| {
        const agents = s.gw.routes.connectedCount();
        if (agents != s.tray_agents) {
            s.tray_agents = agents;
            var buf: [24]u8 = undefined;
            tray.setTitle(menubar.titleInto(&buf, agents));
        }
    }
}

/// The pages, the mark, and the gateway's state: the sidebar beside every
/// page, folded to a rail when the user asks.
fn sidebar(c: *ui.Context, s: *App, k: theme.Colors) void {
    const folded = s.cfg.sidebar_collapsed;
    var col = ui.div(c).column().hFull().bg(k.sidebar).py(8).gap(6);
    col = if (folded) col.px(6) else col.px(10);
    // The fold eases between the two widths, so the page beside it does not
    // jump.
    const target: f32 = if (folded) sidebar_rail else sidebar_width;
    const width = c.animate(c.node(col.index).id, 0, target, 20);
    col = col.w(width);
    defer col.end();

    if (folded) headFolded(c, s, k) else head(c, s, k);

    item(c, s, "square.grid.2x2", "Servers", .servers, k, folded);
    item(c, s, "globe", "Market", .market, k, folded);
    item(c, s, "list.bullet", "Routes", .routes, k, folded);
    item(c, s, "checklist", "Tools", .tools, k, folded);
    item(c, s, "slider.horizontal.3", "Settings", .settings, k, folded);

    ui.spacer(c);
    status(c, s, k, folded);
}

/// The mark, the build it runs, and the fold toggle.
fn head(c: *ui.Context, s: *App, k: theme.Colors) void {
    const row = ui.div(c).row().wFull().h(34).itemsCenter().gap(8).px(8);
    defer row.end();
    ui.icon(c, "terminal.fill", .{ .size = 16, .color = k.accent });
    ui.text(c, "nanomcp", .{ .size = 13, .weight = .bold, .color = k.text });
    ui.text(c, "v" ++ state_mod.version, .{ .size = 10, .color = k.tertiary });
    ui.spacer(c);
    collapseButton(c, s, k, false);
}

/// The folded rail keeps only the toggle, on the icons' line.
fn headFolded(c: *ui.Context, s: *App, k: theme.Colors) void {
    const row = ui.div(c).row().wFull().h(34).itemsCenter().justifyCenter();
    defer row.end();
    collapseButton(c, s, k, true);
}

/// The fold toggle: a quiet square with the sidebar's mark, lit under the
/// pointer. Its size matches the page tiles when the sidebar is folded.
fn collapseButton(c: *ui.Context, s: *App, k: theme.Colors, folded: bool) void {
    const size: f32 = if (folded) sidebar_tile else 24;
    const b = ui.div(c).row().w(size).h(size).center().rounded(6).control().hover(k.hover);
    defer b.end();
    ui.icon(c, "sidebar.left", .{ .size = 15, .color = k.text.alpha(0.72) });
    if (b.clicked()) {
        s.cfg.sidebar_collapsed = !folded;
        s.save();
        s.redisplay();
    }
}

fn item(c: *ui.Context, s: *App, icon: []const u8, name: []const u8, p: state_mod.Page, k: theme.Colors, folded: bool) void {
    ui.key(c, name);
    const on = s.page == p;
    if (folded) {
        // The rail has no room for the name: a tile around the icon alone.
        const wrap = ui.div(c).row().wFull().justifyCenter();
        defer wrap.end();
        var tile = ui.div(c).row().w(sidebar_tile).h(sidebar_tile).center().rounded(7).control();
        tile = if (on) tile.bg(k.picked) else tile.hover(k.hover);
        defer tile.end();
        if (tile.clicked()) {
            s.page = p;
            s.redisplay();
        }
        kit.chip(c, icon, if (on) k.on_picked else k.accent, 18, on);
        return;
    }
    var d = ui.div(c).row().wFull().h(28).itemsCenter().gap(9).px(7).rounded(7).control();
    d = if (on) d.bg(k.picked) else d.hover(k.hover);
    defer d.end();
    if (d.clicked()) {
        s.page = p;
        s.redisplay();
    }
    kit.chip(c, icon, if (on) k.on_picked else k.accent, 18, on);
    ui.text(c, name, .{ .size = 13, .weight = if (on) .semibold else .regular, .color = if (on) k.on_picked else k.text });
}

fn status(c: *ui.Context, s: *App, k: theme.Colors, folded: bool) void {
    const serving = s.gw.serving();
    if (folded) {
        const d = ui.div(c).row().wFull().justifyCenter().pb(6);
        defer d.end();
        liveDot(c, serving, k);
        return;
    }
    const d = ui.div(c).row().wFull().gap(7).itemsCenter().px(8).pb(6);
    defer d.end();
    liveDot(c, serving, k);
    const color = if (serving) k.green else k.secondary;
    ui.text(c, if (serving) "serving" else "stopped", .{ .size = 11, .color = color });
    {
        const cell = ui.div(c).grow().w(0).minW(0).clip();
        defer cell.end();
        ui.text(c, summary(c, s), .{ .size = 11, .color = k.tertiary });
    }
}

fn liveDot(c: *ui.Context, serving: bool, k: theme.Colors) void {
    _ = c.leaf(.{
        .width = .{ .px = 7 },
        .height = .{ .px = 7 },
        .radius = 3.5,
        .background = if (serving) k.green else k.secondary,
    }, .none, null);
}

/// How many of the configured servers are ready, for the sidebar's foot.
fn summary(c: *ui.Context, s: *App) []const u8 {
    const views = gateway_views.servers(s.gw, c.arena.allocator()) catch &.{};
    var ready: usize = 0;
    for (views) |v| {
        if (v.status == .ready) ready += 1;
    }
    if (s.cfg.servers.len == 0) return "No servers configured";
    return c.print("{d} of {d} ready", .{ ready, s.cfg.servers.len });
}
