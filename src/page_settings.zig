//! Settings page: the gateway's port and switch, which callers it lets in,
//! the URLs a client is given, and what the gateway has done.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const kit = @import("kit.zig");
const config = @import("config.zig");
const auth = @import("auth.zig");
const tokens = @import("tokens.zig");
const gateway_views = @import("gateway_views.zig");
const App = state_mod.App;

pub fn page(c: *ui.Context, s: *App, k: theme.Colors) void {
    const header = kit.header(c, k, "Settings", "Where the gateway listens, and what it has been doing.");
    header.end();

    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
    defer body.end();

    {
        const card = kit.card(c, k);
        defer card.end();
        gateway(c, s, k);
    }
    {
        const card = kit.card(c, k);
        defer card.end();
        callers(c, s, k);
    }
    {
        const card = kit.card(c, k);
        defer card.end();
        endpoints(c, s, k);
    }
    {
        const card = kit.card(c, k);
        defer card.end();
        activity(c, s, k);
    }
}

/// The port the gateway serves on, and the switch to start and stop it.
fn gateway(c: *ui.Context, s: *App, k: theme.Colors) void {
    kit.cardTitle(c, "bolt.fill", "Gateway", k.green);
    if (s.settings.busy.len > 0) {
        ui.text(c, s.settings.busy, .{ .size = 11, .color = k.secondary });
    }
    const live = s.gw.serving();

    {
        const row = ui.div(c).row().wFull().gap(12).itemsEnd().py(2);
        defer row.end();
        const field = ui.div(c).column().gap(3);
        ui.text(c, "Port", .{ .size = 11, .weight = .semibold, .color = k.secondary });
        const edited = ui.textField(c, &s.settings.port, .{ .placeholder = "7331", .width = .{ .px = 120 }, .size = 13 });
        field.end();

        const text = std.mem.trim(u8, s.settings.port.text(), " \n\r\t");
        const typed = std.fmt.parseInt(i32, text, 10) catch 0;
        const save = ui.button(c, "Save port", .{ .variant = .secondary, .size = 12, .disabled = typed == s.cfg.port });
        if (save.clicked or edited.submitted) setPort(s);

        ui.spacer(c);
        ui.badge(c, if (live) "serving" else "stopped", if (live) k.green else k.tertiary);
        if (live) {
            if (ui.button(c, "Stop", .{ .variant = .danger, .size = 12 }).clicked) stopGateway(s);
        } else {
            if (ui.button(c, "Start", .{ .variant = .primary, .size = 12 }).clicked) startGateway(s);
        }
    }

    ui.text(c, "Loopback only, so only this computer can reach it.", .{
        .size = 11,
        .color = k.tertiary,
    });
}

/// Saves the port, moving a serving gateway to it.
fn setPort(s: *App) void {
    const text = std.mem.trim(u8, s.settings.port.text(), " \n\r\t");
    const port = std.fmt.parseInt(i32, text, 10) catch 0;
    if (port < 1 or port > 65535) {
        s.notify("Choose a port between 1 and 65535", true);
        return;
    }
    s.cfg.port = @intCast(port);
    s.save();
    if (s.gw.serving()) {
        restartGateway(s, @intCast(port));
        return;
    }
    var buf: [64]u8 = undefined;
    s.notify(std.fmt.bufPrint(&buf, "Port set to {d}", .{port}) catch "Port saved", false);
}

fn startGateway(s: *App) void {
    const text = std.mem.trim(u8, s.settings.port.text(), " \n\r\t");
    const port = std.fmt.parseInt(i32, text, 10) catch 0;
    if (port < 1 or port > 65535) {
        s.notify("Choose a port between 1 and 65535", true);
        return;
    }
    s.cfg.port = @intCast(port);
    s.save();
    s.settings.busy = "Starting the gateway…";
    s.gw.startAsync(@intCast(port)) catch |e| {
        s.settings.busy = "";
        s.notify(errorText(e), true);
        return;
    };
    s.settings.busy = "";
    toastServing(s);
}

fn stopGateway(s: *App) void {
    s.settings.busy = "Stopping the gateway…";
    s.gw.stop();
    s.settings.busy = "";
    s.redisplay();
}

fn restartGateway(s: *App, port: u16) void {
    s.settings.busy = "Moving the gateway…";
    s.gw.stop();
    s.gw.startAsync(port) catch |e| {
        s.settings.busy = "";
        s.notify(errorText(e), true);
        return;
    };
    s.settings.busy = "";
    toastServing(s);
}

fn toastServing(s: *App) void {
    const base = gateway_views.baseURL(s.gw, s.gpa) catch {
        s.notify("Serving", false);
        return;
    };
    defer s.gpa.free(base);
    var buf: [96]u8 = undefined;
    s.notify(std.fmt.bufPrint(&buf, "Serving on {s}", .{base}) catch "Serving", false);
}

/// What a listener failure means to a person, in place of the error's name.
fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.AddressInUse => "That port is already in use.",
        error.AccessDenied, error.PermissionDenied => "The port needs a privilege this app does not have.",
        else => @errorName(e),
    };
}

/// Who may call the gateway: nobody, a token, or OAuth clients that sign in.
fn callers(c: *ui.Context, s: *App, k: theme.Colors) void {
    kit.cardTitle(c, "person.fill", "Callers", k.accent);
    const modes: [3][]const u8 = .{ "Off", "Token", "Token + OAuth" };
    var pick: usize = switch (s.cfg.inboundMode()) {
        .off => 0,
        .token => 1,
        .oauth => 2,
        else => 0,
    };
    if (ui.segmented(c, &modes, &pick)) {
        const mode: config.InboundMode = switch (pick) {
            1 => .token,
            2 => .oauth,
            else => .off,
        };
        setAuthMode(s, mode);
    }
    ui.text(c, explanation(s.cfg.inboundMode()), .{
        .size = 11,
        .color = k.secondary,
        .wrap = true,
    });

    if (!s.cfg.inboundMode().requiresToken()) return;

    ui.divider(c);
    tokenRow(c, s, k);

    if (s.cfg.inboundMode() == .oauth) {
        ui.divider(c);
        oauthRow(c, s, k);
    }
}

/// The exact words of the chosen mode.
fn explanation(mode: config.InboundMode) []const u8 {
    return switch (mode) {
        .token => "Callers must send the token below. Nothing else can reach the tools.",
        .oauth => "Callers must send the token below, and MCP clients that support OAuth can sign in for a token of their own. " ++
            "Because this gateway is the sign-in server, anything running on this computer can also ask to be approved, so the token mode is the tighter of the two.",
        else => "Anything that can reach the port may call the tools. The port is loopback only.",
    };
}

fn setAuthMode(s: *App, mode: config.InboundMode) void {
    if (mode.requiresToken() and s.inboundToken().len == 0) {
        const fresh = tokens.randomToken(s.gpa, s.io) catch {
            s.notify("Could not make a token", true);
            return;
        };
        defer s.gpa.free(fresh);
        s.gw.creds.setInboundToken(fresh) catch |e| {
            s.notify(errorText(e), true);
            return;
        };
        s.reloadInboundToken();
    }
    s.cfg.inbound = mode;
    s.save();
    s.gw.refreshCredentials();
    var buf: [64]u8 = undefined;
    s.notify(std.fmt.bufPrint(&buf, "Callers now need: {s}", .{mode.label()}) catch "Callers updated", false);
}

/// The token callers present, with the ways to copy or replace it.
fn tokenRow(c: *ui.Context, s: *App, k: theme.Colors) void {
    const token = s.inboundToken();
    const row = ui.div(c).row().wFull().gap(12).itemsEnd().py(2);
    defer row.end();

    const col = ui.div(c).column().grow().minW(0).gap(4);
    ui.text(c, "Token callers present", .{ .size = 11, .weight = .semibold, .color = k.secondary });
    if (token.len > 0) {
        const box = ui.div(c).row().wFull().px(10).py(7).rounded(8).bg(k.sidebar).border(k.border).clip();
        defer box.end();
        ui.text(c, token, .{ .size = 12, .mono = true, .color = k.text });
    } else {
        ui.text(c, "No token yet.", .{ .size = 12, .color = k.tertiary });
    }
    ui.text(c, "Send it as: Authorization: Bearer <token>", .{ .size = 11, .color = k.tertiary });
    col.end();

    if (token.len > 0) {
        if (ui.button(c, "Copy", .{ .variant = .secondary, .size = 12 }).clicked) {
            c.clipboard.write(c.clipboard.ctx, token);
            s.notify("Token copied", false);
        }
    }
    if (ui.button(c, "New token", .{ .variant = if (token.len == 0) .primary else .secondary, .size = 12 }).clicked) {
        rotateToken(s);
    }
}

fn rotateToken(s: *App) void {
    const fresh = tokens.randomToken(s.gpa, s.io) catch {
        s.notify("Could not make a token", true);
        return;
    };
    defer s.gpa.free(fresh);
    s.gw.creds.setInboundToken(fresh) catch |e| {
        s.notify(errorText(e), true);
        return;
    };
    s.reloadInboundToken();
    s.gw.refreshCredentials();
    s.notify("A new token was issued; callers must use it now", false);
}

/// The sign-in the gateway offers, and the tokens it has issued.
fn oauthRow(c: *ui.Context, s: *App, k: theme.Colors) void {
    const base = gateway_views.baseURL(s.gw, s.gpa) catch "";
    defer if (base.len > 0) s.gpa.free(base);
    const path = auth.metadataPath(s.gpa, "") catch "";
    defer if (path.len > 0) s.gpa.free(path);
    const metadata = if (base.len > 0 and path.len > 0) c.print("{s}{s}", .{ base, path }) else "";

    {
        const row = ui.div(c).row().wFull().gap(10).itemsCenter().py(2);
        defer row.end();
        const col = ui.div(c).column().grow().minW(0).gap(2);
        ui.text(c, "MCP clients can also sign in", .{ .size = 12, .weight = .bold, .color = k.text });
        if (metadata.len > 0) {
            ui.text(c, c.print("They discover it at {s} and are issued a token of their own.", .{metadata}), .{
                .size = 11,
                .color = k.secondary,
                .wrap = true,
            });
        }
        col.end();
        if (ui.button(c, "Copy discovery URL", .{ .variant = .secondary, .size = 12 }).clicked and metadata.len > 0) {
            c.clipboard.write(c.clipboard.ctx, metadata);
            s.notify("Discovery URL copied", false);
        }
    }

    const issued = s.gw.tokens.count(auth.now(s.io));
    const counts = ui.div(c).row().wFull().gap(10).itemsCenter().py(2);
    defer counts.end();
    const note = ui.div(c).grow().minW(0);
    ui.text(c, c.print("{d} issued token(s) are live.", .{issued}), .{ .size = 11, .color = k.secondary });
    note.end();
    const revoke = ui.button(c, "Revoke them all", .{ .variant = .secondary, .size = 12, .disabled = issued == 0 });
    if (revoke.clicked) {
        s.gw.tokens.revokeAll(auth.now(s.io));
        s.gw.changed();
        s.notify("Every issued token was revoked", false);
    }
}

/// The URLs a client is given, and the configuration to copy.
fn endpoints(c: *ui.Context, s: *App, k: theme.Colors) void {
    kit.cardTitle(c, "globe", "Endpoints", k.orange);
    const urls = gateway_views.endpoints(s.gw, s.gpa) catch &.{};
    defer if (urls.len > 0) {
        for (urls) |url| s.gpa.free(url);
        s.gpa.free(urls);
    };
    for (urls) |url| {
        // The list is freed when the card is built; the drawn text must
        // outlive the build, so it points at the frame's own copy.
        const line = c.print("{s}", .{url});
        const row = ui.div(c).row().wFull().gap(8).itemsCenter().py(2);
        defer row.end();
        const cell = ui.div(c).row().grow().minW(0).clip();
        ui.text(c, line, .{ .size = 12, .mono = true, .color = k.text });
        cell.end();
        if (ui.button(c, "Copy", .{ .variant = .ghost, .size = 11 }).clicked) {
            c.clipboard.write(c.clipboard.ctx, line);
            var buf: [256]u8 = undefined;
            s.notify(std.fmt.bufPrint(&buf, "Copied {s}", .{line}) catch "Copied", false);
        }
    }

    ui.divider(c);
    {
        const row = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer row.end();
        const note = ui.div(c).grow().minW(0);
        ui.text(c, "Paste the streamable HTTP endpoint into a client that speaks MCP.", .{
            .size = 11,
            .color = k.secondary,
            .wrap = true,
        });
        note.end();
        if (ui.button(c, "Copy client config", .{ .variant = .secondary, .size = 12 }).clicked) {
            c.clipboard.write(c.clipboard.ctx, clientConfig(c, s));
            s.notify("Client configuration copied", false);
        }
    }
    ui.text(c, serverLine(c, s), .{ .size = 11, .color = k.secondary, .wrap = true });
}

/// A ready-to-paste MCP client configuration, indented as JSON is.
fn clientConfig(c: *ui.Context, s: *App) []const u8 {
    const owned = gateway_views.baseURL(s.gw, s.gpa) catch null;
    defer if (owned) |base| s.gpa.free(base);
    const base = owned orelse "http://127.0.0.1:7331";
    return c.print(
        \\{{
        \\  "mcpServers": {{
        \\    "gateway": {{
        \\      "url": "{s}/mcp"
        \\    }}
        \\  }}
        \\}}
    , .{base});
}

/// Which tools a client sees, by how many servers are connected.
fn serverLine(c: *ui.Context, s: *App) []const u8 {
    const views = gateway_views.servers(s.gw, s.gpa) catch return "No server is connected yet, so clients would see only the gateway's own tool.";
    defer s.gpa.free(views);
    var ready: usize = 0;
    for (views) |v| {
        if (v.status == .ready) ready += 1;
    }
    if (ready == 0) return "No server is connected yet, so clients would see only the gateway's own tool.";
    return c.print("Clients now see the tools of {d} connected server(s).", .{ready});
}

/// What the gateway has done, newest first.
fn activity(c: *ui.Context, s: *App, k: theme.Colors) void {
    kit.cardTitle(c, "waveform.path.ecg", "Activity", k.accent);
    const events = gateway_views.eventsOf(s.gw, s.gpa) catch &.{};
    defer if (events.len > 0) s.gpa.free(events);

    if (events.len == 0) {
        ui.text(c, "Nothing yet.", .{ .size = 12, .color = k.tertiary });
        return;
    }
    var i = events.len;
    var shown: usize = 0;
    while (i > 0 and shown < 100) : (shown += 1) {
        i -= 1;
        const e = events[i];
        const row = ui.div(c).row().wFull().gap(10).itemsStart().py(2);
        defer row.end();
        const clock = clockText(c.arena.allocator(), e.time) catch "…";
        ui.text(c, clock, .{ .size = 11, .mono = true, .color = k.tertiary });
        const cell = ui.div(c).grow().minW(0);
        ui.text(c, e.text, .{ .size = 12, .color = if (e.is_err) k.red else k.secondary, .wrap = true });
        cell.end();
    }
}

/// The time of day of an instant, HH:MM:SS.
fn clockText(a: std.mem.Allocator, time: i64) ![]u8 {
    const secs: u32 = @intCast(@mod(@max(time, 0), 24 * 3600));
    return std.fmt.allocPrint(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        secs / 3600,
        secs % 3600 / 60,
        secs % 60,
    });
}

test "the activity clock is zero-padded and never signed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("00:00:07", try clockText(a, 7));
    try std.testing.expectEqualStrings("11:38:43", try clockText(a, 11 * 3600 + 38 * 60 + 43));
    try std.testing.expectEqualStrings("23:59:59", try clockText(a, 24 * 3600 - 1));
    try std.testing.expectEqualStrings("00:00:00", try clockText(a, -1));
}
