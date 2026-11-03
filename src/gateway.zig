//! The gateway: it connects the configured MCP servers, publishes their tools
//! under names that say which server they came from, and serves one MCP
//! endpoint that aggregates them.
const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const json = @import("json_util.zig");
const upstream = @import("upstream.zig");
const tools_mod = @import("tools.zig");
const tokens_mod = @import("tokens.zig");
const auth = @import("auth.zig");
const views = @import("gateway_views.zig");
const server = @import("server.zig");
const lifecycle = @import("gateway_serve.zig");

/// How one configured server is doing.
pub const Status = enum {
    disabled,
    connecting,
    ready,
    needs_auth,
    failed,

    /// The word the interface and the meta tool show.
    pub fn label(s: Status) []const u8 {
        return switch (s) {
            .disabled => "disabled",
            .connecting => "connecting",
            .ready => "ready",
            .needs_auth => "needs-auth",
            .failed => "error",
        };
    }
};

/// How many activity entries are kept.
pub const max_events = 500;

/// One configured server with its live state.
pub const ServerView = struct {
    config: config.ServerConfig,
    status: Status = .disabled,
    err: []const u8 = "",
    tools: usize = 0,
    signed_in: bool = false,
};

/// One aggregated tool, as the interface shows it.
pub const ToolView = struct {
    /// The namespaced name clients call.
    name: []const u8,
    /// The name at its own server.
    upstream: []const u8,
    server_id: []const u8,
    server_name: []const u8,
    description: []const u8,
    /// The input schema as indented JSON.
    schema: []const u8,
};

/// Something the gateway did, for the activity list.
pub const Event = struct {
    time: i64,
    server_id: []const u8,
    text: []const u8,
    is_err: bool = false,
};

/// The gateway itself.
pub const Gateway = struct {
    a: std.mem.Allocator,
    io: Io,
    cfg: *config.Config,
    creds: *credentials.CredentialStore,
    version: []const u8,
    /// The environment this app was started with, which a stdio server
    /// inherits before its own configured variables are applied on top.
    environ: ?*const std.process.Environ.Map = null,

    /// Serializes reconciliation, so two syncs never connect the same server
    /// twice.
    sync_mu: Io.Mutex = .init,
    /// Set when the gateway is going away: no new connects, loops end early.
    closing: bool = false,
    /// Guards everything below it.
    mu: Io.Mutex = .init,
    upstreams: std.StringHashMapUnmanaged(*upstream.Upstream) = .empty,
    tools: tools_mod.Registry,
    status: std.StringHashMapUnmanaged(Status) = .empty,
    errs: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The credential store is far too slow to read while drawing a frame, so
    /// the sign-in state is cached here and refreshed by `refreshCredentials`.
    signed_in: std.StringHashMapUnmanaged(bool) = .empty,
    /// The bearer token callers must present, cached for the same reason.
    auth_token: []const u8 = "",
    /// The credentials the gateway issues to its own callers.
    tokens: tokens_mod.IssuedTokens,
    /// The agents that have connected over MCP, with what they called.
    routes: @import("sessions.zig").Registry = undefined,
    events: std.ArrayList(Event) = .empty,
    /// The upstream sign-ins that are waiting for a browser.
    pending: @import("oauth.zig").Pending = .{},

    /// The listener, or null when the gateway is not serving.
    listener: ?*server.Server = null,
    port: u16 = 0,

    on_change: ?*const fn (ctx: *anyopaque) void = null,
    on_change_ctx: ?*anyopaque = null,

    pub fn init(
        a: std.mem.Allocator,
        io: Io,
        cfg: *config.Config,
        creds: *credentials.CredentialStore,
        version: []const u8,
    ) Gateway {
        return .{
            .a = a,
            .io = io,
            .cfg = cfg,
            .creds = creds,
            .version = version,
            .tools = tools_mod.Registry.init(a, io),
            .tokens = tokens_mod.IssuedTokens.initMemory(a, io),
            .routes = @import("sessions.zig").Registry.init(a, io),
        };
    }

    /// Marks the gateway as going away: no new connects, loops end early.
    pub fn setClosing(g: *Gateway) void {
        g.mu.lockUncancelable(g.io);
        g.closing = true;
        g.mu.unlock(g.io);
    }

    /// Whether the gateway is going away.
    pub fn isClosing(g: *Gateway) bool {
        g.mu.lockUncancelable(g.io);
        defer g.mu.unlock(g.io);
        return g.closing;
    }

    /// Tears the gateway down. Returns false when a connect that could not
    /// be woken still holds sync_mu: the gateway is then left for the
    /// operating system to reclaim rather than holding the process's exit
    /// for the session's whole timeout, and the caller must not free it.
    pub fn deinit(g: *Gateway) bool {
        g.setClosing();
        lifecycle.wakeWaiters(g);
        var spins: u32 = 0;
        while (!g.sync_mu.tryLock()) {
            spins += 1;
            if (spins > 200) return false;
            std.Io.sleep(g.io, .fromMilliseconds(10), .awake) catch {};
        }
        defer g.sync_mu.unlock(g.io);
        g.mu.lockUncancelable(g.io);
        const listener = g.listener;
        g.listener = null;
        g.port = 0;
        g.mu.unlock(g.io);
        lifecycle.disconnectAll(g);
        g.pending.clear(g.a);
        if (listener) |l| {
            // An event stream waits on its client, so it is ended before the
            // listener waits for the connections that were serving it.
            @import("mcp_endpoint.zig").sessions.closeAll();
            l.stop();
            l.destroy();
        }
        g.tools.deinit();
        g.tokens.deinit();
        g.routes.deinit();
        if (g.auth_token.len > 0) g.a.free(@constCast(g.auth_token));
        for (g.events.items) |e| {
            g.a.free(e.server_id);
            g.a.free(e.text);
        }
        g.events.deinit(g.a);
        g.pending.deinit(g.a);
        freeStatusMap(g);
        freeMap(g.a, &g.errs);
        freeBoolMap(g.a, &g.signed_in);
        return true;
    }

    /// Sets the function called whenever something the window shows has
    /// changed. It may run on any thread.
    pub fn setOnChange(g: *Gateway, ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void) void {
        g.mu.lockUncancelable(g.io);
        defer g.mu.unlock(g.io);
        g.on_change = f;
        g.on_change_ctx = ctx;
    }

    /// Tells the window to redraw.
    pub fn changed(g: *Gateway) void {
        g.mu.lockUncancelable(g.io);
        const f = g.on_change;
        const ctx = g.on_change_ctx;
        g.mu.unlock(g.io);
        if (f) |fun| fun(ctx.?);
    }

    /// Records an activity entry.
    pub fn note(g: *Gateway, server_id: []const u8, text: []const u8, is_err: bool) void {
        const a = g.a;
        const copy = a.dupe(u8, text) catch return;
        const owner = a.dupe(u8, server_id) catch {
            a.free(copy);
            return;
        };

        g.mu.lockUncancelable(g.io);
        defer g.mu.unlock(g.io);
        g.events.append(a, .{
            .time = auth.now(g.io),
            .server_id = owner,
            .text = copy,
            .is_err = is_err,
        }) catch {
            a.free(copy);
            a.free(owner);
            return;
        };
        if (g.events.items.len > max_events) {
            const drop = g.events.items.len - max_events;
            for (g.events.items[0..drop]) |e| {
                a.free(e.text);
                a.free(e.server_id);
            }
            std.mem.copyForwards(Event, g.events.items[0 .. g.events.items.len - drop], g.events.items[drop..]);
            g.events.shrinkRetainingCapacity(g.events.items.len - drop);
        }
    }

    /// A configured token header, or nothing when the server has none.
    fn headerText(header: ?[]const u8) []const u8 {
        const text: []const u8 = header orelse "";
        return text;
    }

    pub fn serverName(g: *Gateway, id: []const u8) []const u8 {
        if (g.cfg.server(id)) |sc| return sc.name;
        return id;
    }

    /// The current status of one configured server, or disabled when off.
    pub fn statusFor(g: *Gateway, sc: config.ServerConfig) Status {
        if (!sc.enabled) return .disabled;
        return g.status.get(sc.id) orelse .disabled;
    }

    /// The current status of one configured server, or disabled when off.
    pub fn statusOf(g: *Gateway, id: []const u8) Status {
        const sc = for (g.cfg.servers) |s| {
            if (std.mem.eql(u8, s.id, id)) break s;
        } else return .disabled;
        return g.statusFor(sc);
    }

    /// The last error text kept for a server, empty when there is none.
    pub fn errorOf(g: *Gateway, id: []const u8) []const u8 {
        return g.errs.get(id) orelse "";
    }

    /// Records why a server could not connect or sign in, for its row.
    pub fn recordError(g: *Gateway, id: []const u8, text: []const u8) void {
        g.mu.lockUncancelable(g.io);
        g.setErrLocked(id, text);
        g.mu.unlock(g.io);
        g.changed();
    }

    /// How many tools a connected server contributes right now.
    pub fn toolCount(g: *Gateway, id: []const u8) usize {
        return g.tools.countFor(id);
    }

    /// Invokes an aggregated tool by its namespaced name. A tool that fails at
    /// its upstream is an error here, which the endpoint reports as a tool
    /// error so the calling model sees it and can react.
    pub fn callTool(g: *Gateway, a: std.mem.Allocator, name: []const u8, args: ?json.Value) !json.Value {
        const entry = g.tools.find(name) orelse return error.UnknownTool;

        g.mu.lockUncancelable(g.io);
        const up = g.upstreams.get(entry.server_id);
        g.mu.unlock(g.io);
        const connected = up orelse return error.NotConnected;
        return connected.callTool(a, entry.upstream_name, args);
    }

    /// Reads the credential store: which servers can sign in, and the token
    /// callers of the gateway must present.
    pub fn refreshCredentials(g: *Gateway) void {
        const a = g.a;
        for (g.cfg.servers) |sc| {
            // A remote server with no token of its own is one that signs in.
            if (sc.transport != .stdio and headerText(sc.token_header).len == 0) {
                const signed = g.creds.signedIn(a, sc.id, auth.now(g.io));
                g.putMap(bool, &g.signed_in, sc.id, signed);
            }
        }

        const needs = g.cfg.inboundMode().requiresToken();
        const token = if (needs) (g.creds.get(credentials.CredentialStore.inbound_token_key) catch null) else null;
        defer if (token) |t| a.free(t);

        g.mu.lockUncancelable(g.io);
        defer g.mu.unlock(g.io);
        if (token != null or !needs) {
            g.a.free(@constCast(g.auth_token));
            g.auth_token = g.a.dupe(u8, token orelse "") catch "";
        }
    }

    /// Records a server's sign-in state without reading the credential store,
    /// for a change the gateway itself just made.
    pub fn markSignedIn(g: *Gateway, server_id: []const u8, signed: bool) void {
        g.putMap(bool, &g.signed_in, server_id, signed);
    }

    /// Reconciles the connected servers with the configuration: gone and
    /// disabled ones are dropped, enabled ones that are not connected are
    /// connected.
    pub fn sync(g: *Gateway) !void {
        g.sync_mu.lockUncancelable(g.io);
        defer g.sync_mu.unlock(g.io);
        if (g.isClosing()) return error.Canceled;
        g.refreshCredentials();

        var stale: std.ArrayList(*upstream.Upstream) = .empty;
        defer stale.deinit(g.a);
        var todo: std.ArrayList(config.ServerConfig) = .empty;
        defer todo.deinit(g.a);

        g.mu.lockUncancelable(g.io);
        {
            var it = g.upstreams.iterator();
            while (it.next()) |kv| {
                const sc = g.cfg.server(kv.key_ptr.*) orelse {
                    stale.append(g.a, kv.value_ptr.*) catch {};
                    continue;
                };
                if (sc.enabled) continue;
                stale.append(g.a, kv.value_ptr.*) catch {};
            }
            for (stale.items) |up| {
                _ = g.upstreams.fetchRemove(up.config.id);
                g.forgetStatus(up.config.id);
                g.tools.removeServer(up.config.id);
            }
            for (g.cfg.servers) |sc| {
                if (!sc.enabled) {
                    g.setStatusLocked(sc.id, .disabled, "");
                    continue;
                }
                if (g.upstreams.get(sc.id) != null) continue;
                g.setStatusLocked(sc.id, .connecting, "");
                todo.append(g.a, sc) catch {};
            }
        }
        g.mu.unlock(g.io);
        g.changed();

        for (stale.items) |up| {
            g.note(up.config.id, try std.fmt.allocPrint(g.a, "disconnected {s}", .{up.config.name}), false);
            up.close();
            up.destroy();
        }

        // One server that cannot connect does not stop the others: its reason
        // is recorded against it, and the first such reason is what the
        // caller hears about.
        var refused: ?anyerror = null;
        for (todo.items) |sc| {
            if (g.isClosing()) break;
            g.connectOne(sc) catch |err| {
                if (refused == null) refused = err;
            };
        }
        if (refused) |err| return err;
    }

    /// Drops a server's connection and connects it again.
    pub fn reconnect(g: *Gateway, id: []const u8) !void {
        g.sync_mu.lockUncancelable(g.io);
        defer g.sync_mu.unlock(g.io);
        if (g.isClosing()) return error.Canceled;
        g.refreshCredentials();

        g.mu.lockUncancelable(g.io);
        const old = g.upstreams.fetchRemove(id);
        g.forgetStatus(id);
        g.tools.removeServer(id);
        const sc = g.cfg.server(id);
        g.mu.unlock(g.io);

        if (old) |kv| {
            kv.value.close();
            kv.value.destroy();
        }
        const target = sc orelse return error.NoSuchServer;
        if (!target.enabled) {
            g.setStatus(id, .disabled, "");
            g.changed();
            return;
        }
        defer g.changed();
        return g.connectOne(target);
    }

    /// Connects one server and publishes its tools.
    fn connectOne(g: *Gateway, sc: config.ServerConfig) !void {
        const a = g.a;
        const outcome = try upstream.connect(a, g.io, sc, .{
            .creds = g.creds,
            .redirect_uri = try views.redirectURI(g, a),
            .version = g.version,
            .environ = g.environ,
        });

        switch (outcome) {
            .needs_auth => {
                g.setStatus(sc.id, .needs_auth, "");
                g.note(sc.id, try std.fmt.allocPrint(a, "{s}: sign in required", .{sc.name}), false);
                return error.SignInRequired;
            },
            .failed => |why| {
                g.setStatus(sc.id, .failed, why);
                g.note(sc.id, try std.fmt.allocPrint(a, "{s}: {s}", .{ sc.name, why }), true);
                return error.ConnectFailed;
            },
            .ready => |up| {
                g.mu.lockUncancelable(g.io);
                g.upstreams.put(a, try a.dupe(u8, sc.id), up) catch {};
                g.setStatusLocked(sc.id, .ready, "");
                g.mu.unlock(g.io);

                g.register(up);
                g.note(sc.id, try std.fmt.allocPrint(a, "{s}: {d} tools", .{ sc.name, up.tools.len }), false);
                g.changed();
            },
        }
    }

    /// Publishes an upstream's tools under its alias.
    pub fn register(g: *Gateway, up: *upstream.Upstream) void {
        const a = g.a;
        for (up.tools) |tool| {
            const upstream_name = json.getString(tool, "name") orelse continue;
            const name = tools_mod.prefixedName(a, up.config.alias, upstream_name) catch continue;
            g.tools.add(.{
                .name = name,
                .description = tools_mod.describe(a, up.config.name, json.getString(tool, "description") orelse "") catch continue,
                .schema = json.get(tool, "inputSchema") orelse .null,
                .server_id = up.config.id,
                .upstream_name = upstream_name,
            }) catch continue;
        }
    }

    fn setStatus(g: *Gateway, id: []const u8, status: Status, err_text: []const u8) void {
        g.mu.lockUncancelable(g.io);
        g.setStatusLocked(id, status, err_text);
        g.mu.unlock(g.io);
        g.changed();
    }

    fn setStatusLocked(g: *Gateway, id: []const u8, status: Status, err_text: []const u8) void {
        g.putMap(Status, &g.status, id, status);
        if (err_text.len == 0) {
            g.forgetErrLocked(id);
        } else {
            g.setErrLocked(id, err_text);
        }
    }

    /// Keeps a copy of the reason: the caller's may be a frame or call buffer.
    fn setErrLocked(g: *Gateway, id: []const u8, err_text: []const u8) void {
        const owned = g.a.dupe(u8, err_text) catch return;
        if (g.errs.getEntry(id)) |entry| {
            g.a.free(entry.value_ptr.*);
            entry.value_ptr.* = owned;
            return;
        }
        const key = g.a.dupe(u8, id) catch {
            g.a.free(owned);
            return;
        };
        g.errs.put(g.a, key, owned) catch {
            g.a.free(key);
            g.a.free(owned);
        };
    }

    fn forgetErrLocked(g: *Gateway, id: []const u8) void {
        if (g.errs.fetchRemove(id)) |kv| {
            g.a.free(kv.key);
            g.a.free(kv.value);
        }
    }

    /// Forgets a server's status and its last error.
    pub fn forgetStatus(g: *Gateway, id: []const u8) void {
        if (g.status.fetchRemove(id)) |kv| g.a.free(kv.key);
        g.forgetErrLocked(id);
    }

    /// Inserts into a string-keyed map, copying the key and replacing what was
    /// there.
    fn putMap(g: *Gateway, comptime T: type, map: *std.StringHashMapUnmanaged(T), key: []const u8, value: T) void {
        const a = g.a;
        if (map.getEntry(key)) |entry| {
            entry.value_ptr.* = value;
            return;
        }
        const owned = a.dupe(u8, key) catch return;
        map.put(a, owned, value) catch a.free(owned);
    }

    fn freeMap(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]const u8)) void {
        var it = map.iterator();
        while (it.next()) |kv| {
            a.free(kv.key_ptr.*);
            a.free(kv.value_ptr.*);
        }
        map.deinit(a);
    }

    fn freeBoolMap(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(bool)) void {
        var it = map.iterator();
        while (it.next()) |kv| a.free(kv.key_ptr.*);
        map.deinit(a);
    }

    fn freeStatusMap(g: *Gateway) void {
        var it = g.status.iterator();
        while (it.next()) |kv| g.a.free(kv.key_ptr.*);
        g.status.deinit(g.a);
    }

    /// Starts serving on `port` and connects the configured servers.
    pub fn start(g: *Gateway, port: u16) !void {
        return lifecycle.start(g, port);
    }

    /// Starts serving on `port`, connecting the servers on their own thread:
    /// a server that never answers must not hold the caller (the window) up.
    pub fn startAsync(g: *Gateway, port: u16) !void {
        return lifecycle.startAsync(g, port);
    }

    /// Runs `sync` on its own thread, so a server that is slow to answer
    /// does not hold the caller up; each server's status changes as it
    /// connects.
    pub fn syncAsync(g: *Gateway) void {
        lifecycle.syncAsync(g);
    }

    /// Reconnects a server on its own thread; the answer may be a sign-in
    /// prompt or a server that never answers, and neither may freeze the
    /// caller.
    pub fn reconnectAsync(g: *Gateway, id: []const u8) void {
        lifecycle.reconnectAsync(g, id);
    }

    /// Stops serving and disconnects every server.
    pub fn stop(g: *Gateway) void {
        lifecycle.stop(g);
    }

    /// Disconnects every upstream and drops its tools and status.
    pub fn disconnectAll(g: *Gateway) void {
        lifecycle.disconnectAll(g);
    }

    /// Whether the gateway is listening.
    pub fn serving(g: *Gateway) bool {
        return lifecycle.serving(g);
    }

    /// The port the gateway serves on, or 0 when it is not serving.
    pub fn servingPort(g: *Gateway) u16 {
        return lifecycle.servingPort(g);
    }

};
