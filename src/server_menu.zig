//! The menu a server's … button opens: edit, reconnect, connect or
//! disconnect, and remove.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const gateway_views = @import("gateway_views.zig");
const state_mod = @import("state.zig");
const actions = @import("server_actions.zig");
const views = @import("server_views.zig");

const App = state_mod.App;

pub fn draw(c: *ui.Context, s: *App, k: theme.Colors) void {
    const menu = s.servers.menu orelse return;
    if (s.page != .servers) {
        s.servers.menu = null;
        return;
    }
    const sc = s.cfg.server(menu.id) orelse {
        s.servers.menu = null;
        return;
    };
    const view = gateway_views.serverOf(s.gw, c.arena.allocator(), menu.id) catch null;

    {
        const shade = ui.div(c).absolute().sizeFull().bg(k.page.alpha(0.05));
        const it = shade.interaction();
        shade.end();
        if (it.clicked) {
            s.servers.menu = null;
            c.changed = true;
            return;
        }
    }

    const panel = ui.div(c).absolute().column().w(190).p(4).gap(2).rounded(10)
        .bg(k.card).border(k.border).shadowLg().offset(menu.x, menu.y);
    defer panel.end();

    if (item(c, k, "Edit…", k.text)) {
        actions.editServer(s, sc.id);
        s.servers.menu = null;
    }
    divider(c, k);
    if (item(c, k, "Reconnect", k.text)) {
        actions.reconnect(s, sc.id);
        s.servers.menu = null;
    }
    if (view) |v| {
        if (views.signInOffered(v)) {
            if (v.signed_in) {
                if (item(c, k, "Disconnect", k.text)) {
                    actions.signOut(s, sc.id);
                    s.servers.menu = null;
                }
            } else {
                if (item(c, k, "Connect", k.text)) {
                    actions.signIn(s, sc.id);
                    s.servers.menu = null;
                }
            }
        }
    }
    divider(c, k);
    if (item(c, k, "Remove", k.red)) {
        s.servers.removing = sc.id;
        s.servers.menu = null;
        c.changed = true;
    }
}

fn item(c: *ui.Context, k: theme.Colors, label: []const u8, color: ui.Color) bool {
    const d = ui.div(c).row().wFull().h(26).itemsCenter().px(8).rounded(6).control().hover(k.hover);
    defer d.end();
    ui.text(c, label, .{ .size = 12, .color = color });
    const clicked = d.clicked();
    if (clicked) c.changed = true;
    return clicked;
}

fn divider(c: *ui.Context, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().py(3);
    defer d.end();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
}
