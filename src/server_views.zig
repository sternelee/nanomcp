//! How a server looks on the Servers page: its row, its card, its status
//! pill, and the line under its name.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const config = @import("config.zig");
const gateway_views = @import("gateway_views.zig");
const state_mod = @import("state.zig");
const kit = @import("kit.zig");
const actions = @import("server_actions.zig");

const App = state_mod.App;
const Status = gateway_views.Status;

/// The word a server's state is shown as.
pub fn statusLabel(st: Status) []const u8 {
    return switch (st) {
        .ready => "ready",
        .connecting => "connecting",
        .needs_auth => "sign in",
        .failed => "error",
        .disabled => "off",
    };
}

fn statusColor(k: theme.Colors, st: Status) ui.Color {
    return switch (st) {
        .ready => k.green,
        .connecting => k.orange,
        .needs_auth => k.accent,
        .failed => k.red,
        .disabled => k.secondary,
    };
}

/// A dot and a word in the state's color.
pub fn statusPill(c: *ui.Context, k: theme.Colors, st: Status) void {
    const color = statusColor(k, st);
    const r = ui.div(c).row().gap(6).itemsCenter();
    defer r.end();
    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = color }, .none, null);
    ui.text(c, statusLabel(st), .{ .size = 11, .color = color });
}

/// The line under a server's name: what it is, and how it is doing when that
/// is not simply "ready".
pub fn detail(c: *ui.Context, sc: config.ServerConfig, st: Status, err: []const u8) []const u8 {
    if (err.len > 0) return err;
    var target: []const u8 = sc.url orelse "";
    if (sc.transport == .stdio) {
        target = sc.command orelse "";
        if (sc.args) |args| {
            for (args) |arg| target = c.print("{s} {s}", .{ target, arg });
        }
    }
    const prefix: []const u8 = switch (st) {
        .disabled => "Off",
        .connecting => "Connecting",
        .needs_auth => "Sign in required",
        else => "",
    };
    if (prefix.len == 0) return target;
    if (target.len == 0) return prefix;
    return c.print("{s} \u{00b7} {s}", .{ prefix, target });
}

/// Whether a server can be signed in to: a remote one that carries no token
/// of its own. It is offered once the server has asked for authorization, and
/// whenever the configuration already expects OAuth, so a server the gateway
/// discovers needs signing in to still gets a button.
pub fn signInOffered(v: gateway_views.ServerView) bool {
    const sc = v.config;
    if (sc.transport == .stdio or sc.token_header != null) return false;
    return sc.oauth or v.signed_in or v.status == .needs_auth;
}

fn connectButton(c: *ui.Context, s: *App, v: gateway_views.ServerView) void {
    if (!signInOffered(v)) return;
    // Authorizing is the one step a switch cannot express, so it keeps a
    // button, whatever the connection state: it can be authorized before it
    // is switched on.
    if (v.signed_in) {
        if (ui.button(c, "Disconnect", .{ .variant = .secondary, .size = 12 }).clicked) actions.signOut(s, v.config.id);
    } else {
        if (ui.button(c, "Connect", .{ .variant = .primary, .size = 12 }).clicked) actions.signIn(s, v.config.id);
    }
}

fn serverSwitch(c: *ui.Context, s: *App, sc: config.ServerConfig) void {
    var on = sc.enabled;
    if (kit.toggle(c, &on)) {
        if (on) actions.connect(s, sc.id) else actions.disconnect(s, sc.id);
    }
}

/// A row's … button: opens the server's menu beneath it, or closes it.
fn menuButton(c: *ui.Context, s: *App, k: theme.Colors, id: []const u8, size: f32) void {
    const b = ui.div(c).w(size).h(size).center().rounded(6).hover(k.hover).control();
    defer b.end();
    ui.icon(c, "ellipsis", .{ .size = 13, .color = k.secondary });
    const it = b.interaction();
    if (!it.clicked) return;
    const r = it.rect orelse return;
    if (s.servers.menu) |menu| {
        if (std.mem.eql(u8, menu.id, id)) {
            s.servers.menu = null;
            c.changed = true;
            return;
        }
    }
    const w: f32 = 190;
    const h: f32 = 240;
    const max_x = @max(8, c.size.w - w - 8);
    const max_y = @max(8, c.size.h - h - 8);
    const x = std.math.clamp(r.x + r.w - w, 8, max_x);
    const below = r.y + r.h + 4;
    const y = if (below + h <= c.size.h - 8) below else r.y - h - 4;
    s.servers.menu = .{ .id = id, .x = x, .y = std.math.clamp(y, 8, max_y) };
    c.changed = true;
}

fn toolsCount(c: *ui.Context, k: theme.Colors, count: usize, width: ?f32) void {
    if (width) |w| {
        const d = ui.div(c).row().w(w).justifyEnd();
        defer d.end();
        ui.textf(c, .{ .size = 11, .color = k.secondary }, "{d} tools", .{count});
    } else {
        ui.textf(c, .{ .size = 11, .color = k.secondary }, "{d} tools", .{count});
    }
}

/// One server as a row: its figure, name, detail, status, transport and tool
/// count, with the controls for it. `row_index` is its place among the rows
/// the filter keeps.
pub fn row(c: *ui.Context, s: *App, k: theme.Colors, v: gateway_views.ServerView, row_index: usize) void {
    const sc = v.config;
    const selected = row_index == s.servers.selected;
    ui.key(c, sc.id);
    const d = ui.div(c).row().wFull().h(56).itemsCenter().gap(12).px(12).rounded(8).control()
        .bg(if (selected) k.selection else k.page.alpha(0))
        .border(if (selected) k.accent else k.border.alpha(0))
        .hover(k.hover);
    defer d.end();

    const it = d.interaction();
    if (it.double_clicked) {
        actions.editServer(s, sc.id);
        c.changed = true;
    } else if (it.clicked) {
        s.servers.selected = row_index;
        c.changed = true;
    }

    kit.avatar(c, k, sc.name, 34);
    {
        const col = ui.div(c).column().grow().w(0).gap(1).clip();
        ui.text(c, sc.name, .{ .size = 13, .weight = .semibold, .color = k.text });
        ui.text(c, detail(c, sc, v.status, v.err), .{ .size = 11, .color = k.secondary });
        col.end();
    }
    statusPill(c, k, v.status);
    ui.badge(c, sc.transport.label(), k.secondary);
    toolsCount(c, k, v.tools, 54);
    connectButton(c, s, v);
    {
        // A fixed column keeps every row's switch in line, with or without
        // a Connect button beside it.
        const track = ui.div(c).row().w(64).justifyEnd();
        serverSwitch(c, s, sc);
        track.end();
    }
    menuButton(c, s, k, sc.id, 24);
}

/// One server as a card: the row's content reflowed for scanning a wall of
/// them rather than reading one.
pub fn card(c: *ui.Context, s: *App, k: theme.Colors, v: gateway_views.ServerView, item: usize) void {
    const sc = v.config;
    const selected = item == s.servers.selected;
    ui.key(c, sc.id);
    const d = ui.div(c).column().w(280).h(128).p(14).gap(8).rounded(12).control()
        .bg(if (selected) k.marked else k.card)
        .border(if (selected) k.accent else k.border)
        .shadowSm();
    defer d.end();

    const it = d.interaction();
    const lift = c.animate(it.id, 7, if (it.hovered) 1 else 0, 18);
    _ = d.offset(0, -3 * lift);
    if (it.double_clicked) {
        actions.editServer(s, sc.id);
        c.changed = true;
    } else if (it.clicked) {
        s.servers.selected = item;
        c.changed = true;
    }

    {
        const top = ui.div(c).row().wFull().gap(10).itemsCenter();
        kit.avatar(c, k, sc.name, 30);
        {
            const col = ui.div(c).column().grow().w(0).gap(1).clip();
            ui.text(c, sc.name, .{ .size = 13, .weight = .bold, .color = k.text });
            statusPill(c, k, v.status);
            col.end();
        }
        ui.badge(c, sc.transport.label(), k.secondary);
        menuButton(c, s, k, sc.id, 22);
        top.end();
    }
    {
        const line = ui.div(c).row().wFull().clip();
        defer line.end();
        ui.text(c, detail(c, sc, v.status, v.err), .{ .size = 11, .color = k.secondary });
    }
    ui.spacer(c);
    {
        const bottom = ui.div(c).row().wFull().gap(8).itemsCenter();
        toolsCount(c, k, v.tools, null);
        ui.spacer(c);
        connectButton(c, s, v);
        serverSwitch(c, s, sc);
        bottom.end();
    }
}
