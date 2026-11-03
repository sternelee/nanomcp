//! Routes page: the agents connected to the gateway, and how they use it.
//! One row per live session: who it is, the protocol it speaks, how many
//! tools it has called, and how long it has been connected.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const kit = @import("kit.zig");
const sessions_mod = @import("sessions.zig");
const auth = @import("auth.zig");

const App = state_mod.App;

pub fn page(c: *ui.Context, s: *App, k: theme.Colors) void {
    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const all = s.gw.routes.list(arena_state.allocator()) catch &.{};

    var live: std.ArrayList(sessions_mod.View) = .empty;
    defer live.deinit(s.gpa);
    for (all) |agent| {
        if (agent.connected) live.append(s.gpa, agent) catch {};
    }

    const header = kit.header(c, k, "Routes", "Agents connected to the gateway, and how they use it.");
    ui.text(c, c.print("{d} connected", .{live.items.len}), .{ .size = 12, .color = k.secondary });
    header.end();

    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(6);
    defer body.end();

    if (live.items.len == 0) {
        empty(c, s, k);
        return;
    }

    const now = auth.now(s.io);
    for (live.items) |agent| routeRow(c, k, agent, now);
}

/// One connected agent: its figure, name, session ID, protocol, calls and
/// when it joined.
fn routeRow(c: *ui.Context, k: theme.Colors, agent: sessions_mod.View, now: i64) void {
    const label = sessions_mod.describe(agent.id, agent.client);
    const d = ui.div(c).row().wFull().h(56).px(12).gap(12).itemsCenter()
        .rounded(10).border(k.border).bg(k.card);
    defer d.end();

    kit.avatar(c, k, label, 32);

    {
        const col = ui.div(c).column().grow().w(0).gap(1).clip();
        {
            const r = ui.div(c).row().gap(8).itemsCenter();
            ui.text(c, label, .{ .size = 13, .weight = .semibold, .color = k.text });
            if (agent.version.len > 0) {
                ui.text(c, c.print("v{s}", .{agent.version}), .{ .size = 11, .color = k.secondary });
            }
            r.end();
        }
        ui.text(c, agent.id, .{ .size = 10, .mono = true, .color = k.tertiary });
        col.end();
    }

    if (agent.protocol.len > 0) ui.badge(c, agent.protocol, k.tertiary);

    {
        const col = ui.div(c).column().w(150).gap(1).itemsEnd();
        ui.text(c, callsText(c, agent.calls), .{ .size = 12, .color = k.text });
        ui.text(c, c.print("connected {s}", .{relativeTime(c, now, agent.connected_at)}), .{
            .size = 10,
            .color = k.secondary,
        });
        col.end();
    }
}

/// Shows when no agent has joined yet, with the way to bring one in.
fn empty(c: *ui.Context, s: *App, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().grow().center().gap(10).p(40);
    defer d.end();
    ui.text(c, "No agents connected", .{ .size = 15, .weight = .bold, .color = k.text });
    {
        const wrap = ui.div(c).w(460).column();
        ui.text(c, "Point an MCP client at the gateway's endpoints on Settings. Its session shows up here as soon as it connects.", .{
            .size = 12,
            .color = k.secondary,
            .wrap = true,
        });
        wrap.end();
    }
    if (ui.button(c, "Open Settings", .{ .variant = .secondary, .size = 12 }).clicked) {
        s.page = .settings;
        s.redisplay();
    }
}

fn callsText(c: *ui.Context, calls: u32) []const u8 {
    if (calls == 0) return "no calls yet";
    if (calls == 1) return "1 call";
    return c.print("{d} calls", .{calls});
}

/// "just now", "4m ago", "2h ago", "3d ago".
fn relativeTime(c: *ui.Context, now: i64, at: i64) []const u8 {
    const d = if (now > at) now - at else 0;
    if (d < 60) return "just now";
    if (d < 3600) return c.print("{d}m ago", .{@divTrunc(d, 60)});
    if (d < 24 * 3600) return c.print("{d}h ago", .{@divTrunc(d, 3600)});
    return c.print("{d}d ago", .{@divTrunc(d, 24 * 3600)});
}
