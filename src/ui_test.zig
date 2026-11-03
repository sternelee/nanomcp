//! The Go original's UI tests, ported: the same behaviour, the same
//! assertions, against the real widgets instead of a terminal, run
//! offscreen by nanoui's tester (see the repository's AGENTS.md: native UI
//! is tested with `ui.Tester`, never by opening a window).
//!
//! The Go tests build an app with a gateway and a credential store and no
//! window; this does the same, by hand, the way the gateway's own tests do.
//! Two things the Go tests had are missing from this UI, so the cases that
//! need them are not ported: the right-click context menus (the Connect and
//! Disconnect entries), and the status-bar panel with its tabs.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const gateway = @import("gateway.zig");
const gateway_views = @import("gateway_views.zig");
const registry = @import("registry.zig");
const theme = @import("theme.zig");
const state = @import("state.zig");
const editor = @import("editor.zig");
const page_servers = @import("page_servers.zig");
const server_views = @import("server_views.zig");
const view = @import("view.zig").view;

const App = state.App;

/// The only switch on the page: the 40×24 control the rows and cards draw.
/// It has no label of its own, so tests find it by its shape.
fn findSwitch(t: *ui.Tester) ?ui.Rect {
    for (t.ctx.nodes.items) |n| {
        if (!n.interactive) continue;
        // The pressable is the 40×24 switch plus its 10px empty-label gap.
        if (n.rect.w >= 49 and n.rect.w <= 51 and n.rect.h >= 23 and n.rect.h <= 25) return n.rect;
    }
    return null;
}

/// Clicks the only switch on the page.
fn clickSwitch(t: *ui.Tester) !void {
    const r = findSwitch(t) orelse return error.SwitchNotFound;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
}

/// The window the Go tests open.
const window_w: f32 = 1080;
const window_h: f32 = 740;

/// The standard-library server the Go tests start from.
pub fn stdioServer() config.ServerConfig {
    return .{
        .id = "s1",
        .name = "Filesystem",
        .alias = "filesystem",
        .transport = .stdio,
        .enabled = true,
        .command = "npx",
        .args = &.{ "-y", "server" },
    };
}

/// The Go tests' remote server: HTTP, with a static bearer token.
pub fn remoteServer() config.ServerConfig {
    return .{
        .id = "s1",
        .name = "Remote",
        .alias = "remote",
        .transport = .http,
        .enabled = true,
        .url = "https://example.com/mcp",
        .token_header = "Authorization",
        .token_scheme = "Bearer",
    };
}

/// A server an OAuth sign-in authorizes. It carries no token header, which is
/// what a server that takes a pasted token has: only then does the row offer a
/// Connect button next to the switch.
fn oauthServer() config.ServerConfig {
    return .{
        .id = "s1",
        .name = "Remote",
        .alias = "remote",
        .transport = .http,
        .enabled = true,
        .url = "https://example.com/mcp",
        .oauth = true,
    };
}

pub fn secondRemoteServer() config.ServerConfig {
    var sc = remoteServer();
    sc.id = "s2";
    return sc;
}

/// An app with a gateway and a credential store and no window, built by hand
/// the way the gateway's own tests build one: `App.init` starts a real
/// server, and connects everything it is given.
pub const Fixture = struct {
    a: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []const u8,
    app: App,
    gw: gateway.Gateway,

    pub fn init(a: std.mem.Allocator, servers: []const config.ServerConfig) !*Fixture {
        const f = try a.create(Fixture);
        f.* = .{
            .a = a,
            .tmp = std.testing.tmpDir(.{}),
            .data_dir = "",
            .app = undefined,
            .gw = undefined,
        };
        const sub: []const u8 = &f.tmp.sub_path;
        f.data_dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", sub });
        f.app = .{
            .gpa = a,
            .io = std.testing.io,
            .app = undefined,
            .data_dir = f.data_dir,
            .cfg_arena = std.heap.ArenaAllocator.init(a),
            .cfg = config.Config.default(),
            .creds = credentials.CredentialStore.initMemory(a),
            .gw = &f.gw,
        };
        f.app.cfg.servers = try a.dupe(config.ServerConfig, servers);
        _ = f.app.cfg.ensureAliases(a) catch false;
        f.gw = gateway.Gateway.init(a, std.testing.io, &f.app.cfg, &f.app.creds, "test");
        return f;
    }

    pub fn deinit(f: *Fixture) void {
        _ = f.gw.deinit();
        f.app.creds.deinit();
        f.app.cfg_arena.deinit();
        f.tmp.cleanup();
        f.a.destroy(f);
    }
};

/// A tester over the whole window, with the options given.
fn openWindowWith(t: *ui.Tester, f: *Fixture, a: std.mem.Allocator, opts: ui.TesterOptions) !void {
    var options = opts;
    options.width = window_w;
    options.height = window_h;
    try t.init(a, .init(&f.app, view), options);
}

/// A tester over the whole window, as the Go tests open one.
pub fn openWindow(t: *ui.Tester, f: *Fixture, a: std.mem.Allocator) !void {
    try openWindowWith(t, f, a, .{});
}

/// Puts a server in a state, as connecting to it would.
pub fn setStatus(f: *Fixture, id: []const u8, st: gateway_views.Status) void {
    // The gateway owns and frees its keys, so a test cannot hand it a literal.
    const key = f.a.dupe(u8, id) catch return;
    f.gw.status.put(f.a, key, st) catch {};
}

/// Notes why a server is not connecting, as the gateway would.
pub fn setError(f: *Fixture, id: []const u8, why: []const u8) void {
    // The gateway owns both the key and the reason, so both are copies.
    const key = f.a.dupe(u8, id) catch return;
    const value = f.a.dupe(u8, why) catch return;
    f.gw.errs.put(f.a, key, value) catch {};
}

/// Marks a server as signed in, as the OAuth flow would.
fn setSignedIn(f: *Fixture, id: []const u8, yes: bool) void {
    const key = f.a.dupe(u8, id) catch return;
    f.gw.signed_in.put(f.a, key, yes) catch {};
}

/// The configured server with a name, if it is there.
pub fn serverNamed(s: *App, name: []const u8) ?config.ServerConfig {
    for (s.cfg.servers) |sc| {
        if (std.mem.eql(u8, sc.name, name)) return sc;
    }
    return null;
}

/// The rectangle of the `index`th text drawn with a name, in the last frame.
fn findTextNth(t: *ui.Tester, s: []const u8, index: usize) ?ui.Rect {
    var seen: usize = 0;
    for (t.ctx.nodes.items) |n| {
        switch (n.content) {
            .text => |tx| {
                if (std.mem.eql(u8, tx.str, s)) {
                    if (seen == index) return n.rect;
                    seen += 1;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Clicks the middle of the `index`th text drawn with a name: the toolbar and
/// a modal can carry the same word, and the one that is meant is the later.
pub fn clickNth(t: *ui.Tester, s: []const u8, index: usize) !void {
    const r = findTextNth(t, s, index) orelse return error.TextNotFound;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
}

/// The rectangle of the `index`th icon drawn with a name.
fn findIcon(t: *ui.Tester, name: []const u8, index: usize) ?ui.Rect {
    var seen: usize = 0;
    for (t.ctx.nodes.items) |n| {
        switch (n.content) {
            .icon => |ic| {
                if (std.mem.eql(u8, ic.name, name)) {
                    if (seen == index) return n.rect;
                    seen += 1;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Clicks the middle of the `index`th icon drawn with a name, which the box
/// around it answers.
pub fn clickIcon(t: *ui.Tester, name: []const u8, index: usize) !void {
    const r = findIcon(t, name, index) orelse return error.IconNotFound;
    t.click(r.x + r.w / 2, r.y + r.h / 2);
}

/// Whether a rectangle is inside the window.
fn insideWindow(r: ui.Rect) bool {
    return r.x >= 0 and r.y >= 0 and r.x + r.w <= window_w and r.y + r.h <= window_h;
}

/// How many pieces of text are drawn with a name.
pub fn countText(t: *ui.Tester, s: []const u8) usize {
    var seen: usize = 0;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s)) {
            seen += 1;
        },
        else => {},
    };
    return seen;
}

test "the servers page shows its empty state" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(t.hasText("No servers yet"));
}

test "the servers page lists a server with its transport" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(t.hasText("Filesystem"));
    try std.testing.expect(t.hasText("stdio"));
}

test "a server that is off shows an off switch" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var off = stdioServer();
    off.enabled = false;
    const f = try Fixture.init(a, &.{off});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(findSwitch(&t) != null);
    try std.testing.expect(!t.hasText("Connect"));
    try std.testing.expect(!t.hasText("Disconnect"));
    try std.testing.expect(t.hasText("Off · npx -y server"));
}

test "the switch is drawn inside the window" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    const r = findSwitch(&t) orelse return error.SwitchNotFound;
    try std.testing.expect(r.w > 0 and r.h > 0);
    try std.testing.expect(insideWindow(r));
}

test "a connected server has no connect button" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{remoteServer()});
    defer f.deinit();
    setStatus(f, "s1", .ready);
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(!t.hasText("Connect"));
    try std.testing.expect(!t.hasText("Disconnect"));
    try std.testing.expect(findSwitch(&t) != null);
    try std.testing.expect(t.hasText("ready"));
}

test "turning a server on changes the setting" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var off = stdioServer();
    off.enabled = false;
    const f = try Fixture.init(a, &.{off});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try clickSwitch(&t);
    try std.testing.expect(f.app.cfg.servers[0].enabled);
}

test "the switch connects and disconnects a server" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try clickSwitch(&t);
    try std.testing.expect(!f.app.cfg.servers[0].enabled);
    try clickSwitch(&t);
    try std.testing.expect(f.app.cfg.servers[0].enabled);
}

test "the switch turns an oauth server on" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sc = oauthServer();
    sc.enabled = false;
    const f = try Fixture.init(a, &.{sc});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try clickSwitch(&t);
    try std.testing.expect(f.app.cfg.servers[0].enabled);
}

test "the sign-in decision follows the server and its state" {
    const Case = struct { sc: config.ServerConfig, view: gateway_views.ServerView, want: bool };
    const token_remote = remoteServer();
    const plain_remote = blk: {
        var sc = remoteServer();
        sc.token_header = null;
        sc.token_scheme = null;
        break :blk sc;
    };
    var oauth_remote = plain_remote;
    oauth_remote.oauth = true;

    const cases = [_]Case{
        // A stdio server never signs in, even when it says it needs to.
        .{ .sc = stdioServer(), .view = .{ .config = stdioServer(), .status = .needs_auth }, .want = false },
        // A server that carries a token of its own has nothing to sign in to.
        .{ .sc = token_remote, .view = .{ .config = token_remote, .status = .needs_auth }, .want = false },
        // One configured for OAuth is offered it before it is switched on.
        .{ .sc = oauth_remote, .view = .{ .config = oauth_remote, .status = .disabled }, .want = true },
        // A plain server that asked for authorization is offered it.
        .{ .sc = plain_remote, .view = .{ .config = plain_remote, .status = .needs_auth }, .want = true },
        // And one already signed in keeps the offer, to sign out again.
        .{ .sc = plain_remote, .view = .{ .config = plain_remote, .status = .ready, .signed_in = true }, .want = true },
        // A plain server that connected is not.
        .{ .sc = plain_remote, .view = .{ .config = plain_remote, .status = .ready }, .want = false },
    };
    for (cases) |c| {
        _ = c.sc;
        try std.testing.expectEqual(c.want, server_views.signInOffered(c.view));
    }
}

test "a signed-in oauth server offers disconnect" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sc = oauthServer();
    const f = try Fixture.init(a, &.{sc});
    defer f.deinit();
    setStatus(f, "s1", .ready);
    setSignedIn(f, "s1", true);
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(!t.hasText("Connect"));
    try std.testing.expect(t.hasText("Disconnect"));
}

test "connect does not change the switch" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sc = oauthServer();
    sc.enabled = false;
    const f = try Fixture.init(a, &.{sc});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Connect");
    try std.testing.expect(!f.app.cfg.servers[0].enabled);
}

test "a server that needs authorization offers connect and says why" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const sc = oauthServer();
    const f = try Fixture.init(a, &.{sc});
    defer f.deinit();
    setStatus(f, "s1", .needs_auth);
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(t.hasText("Connect"));
    try std.testing.expect(t.hasText("Sign in required · https://example.com/mcp"));
}

test "a server with a token is not offered sign-in" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{remoteServer()});
    defer f.deinit();
    setStatus(f, "s1", .needs_auth);
    setError(f, "s1", "authorization required");
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(!t.hasText("Connect"));
    try std.testing.expect(t.hasText("authorization required"));
}

test "an oauth server is offered connect" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sc = oauthServer();
    sc.enabled = false;
    const f = try Fixture.init(a, &.{sc});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(t.hasText("Connect"));
    try std.testing.expect(findSwitch(&t) != null);
}

test "the sidebar navigates to tools" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Tools");
    try std.testing.expectEqual(state.Page.tools, f.app.page);
    try std.testing.expect(t.hasText("No tools yet"));
}

test "the keyboard shortcuts go to each page" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    const pages = [_]state.Page{ .servers, .market, .routes, .tools, .settings };
    for (pages, 0..) |p, i| {
        const key: u21 = '1' + @as(u21, @intCast(i));
        _ = t.shortcut(.{ .key = key, .cmd = true });
        try std.testing.expectEqual(p, f.app.page);
    }
}

test "each page names itself" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try openWindow(&t, f, a);
    defer t.deinit();

    const Case = struct { page: state.Page, says: []const u8 };
    const cases = [_]Case{
        .{ .page = .servers, .says = "Add server…" },
        .{ .page = .market, .says = "Public servers from the official MCP registry, added in one step." },
        .{ .page = .routes, .says = "Agents connected to the gateway, and how they use it." },
        .{ .page = .tools, .says = "What clients of the gateway see, named after the server each tool comes from." },
        .{ .page = .settings, .says = "Where the gateway listens, and what it has been doing." },
    };
    for (cases) |c| {
        f.app.page = c.page;
        t.frame();
        try std.testing.expect(t.hasText(c.says));
    }
}
