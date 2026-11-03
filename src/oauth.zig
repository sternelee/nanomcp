//! Upstream OAuth 2.1 sign-in: beginAuth, handleCallback, signOut, and the
//! client credentials helpers the gateway reads and writes.
const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const json = @import("json_util.zig");
const server = @import("server.zig");
const upstream = @import("upstream.zig");
const oauth_client = @import("oauth_client.zig");
const gateway_mod = @import("gateway.zig");
const gateway_views = @import("gateway_views.zig");
const auth = @import("auth.zig");

pub const pending_ttl = 5 * 60;
pub const begin_timeout = 60;

pub const PendingEntry = struct {
    server_id: []const u8,
    verifier: []const u8,
    discovery: oauth_client.Discovery,
    client_id: []const u8,
    secret: []const u8,
    created: i64,
};

pub const Pending = struct {
    map: std.StringHashMapUnmanaged(*PendingEntry) = .empty,

    pub fn deinit(p: *Pending, a: std.mem.Allocator) void {
        p.clear(a);
    }

    pub fn clear(p: *Pending, a: std.mem.Allocator) void {
        var it = p.map.iterator();
        while (it.next()) |kv| {
            a.free(kv.key_ptr.*);
            freeEntry(a, kv.value_ptr.*);
        }
        p.map.deinit(a);
        p.map = .empty;
    }

    pub fn prune(p: *Pending, a: std.mem.Allocator, now: i64) void {
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(a);
        var it = p.map.iterator();
        while (it.next()) |kv| {
            if (now - kv.value_ptr.*.created > pending_ttl) {
                to_remove.append(a, kv.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            if (p.map.fetchRemove(k)) |kv| {
                freeEntry(a, kv.value);
                a.free(kv.key);
            }
        }
    }

    pub fn put(p: *Pending, a: std.mem.Allocator, state: []const u8, entry: PendingEntry) !void {
        const owned = try a.create(PendingEntry);
        owned.* = entry;
        const owned_state = try a.dupe(u8, state);
        errdefer a.free(owned_state);
        try p.map.put(a, owned_state, owned);
    }

    pub fn take(p: *Pending, a: std.mem.Allocator, state: []const u8) ?*PendingEntry {
        if (p.map.fetchRemove(state)) |kv| {
            a.free(kv.key);
            return kv.value;
        }
        return null;
    }

    /// Frees an entry that was taken out of the map.
    pub fn release(p: *Pending, a: std.mem.Allocator, e: *PendingEntry) void {
        _ = p;
        freeEntry(a, e);
    }

    fn freeEntry(a: std.mem.Allocator, e: *PendingEntry) void {
        a.free(e.server_id);
        a.free(e.verifier);
        a.free(e.discovery.issuer);
        a.free(e.discovery.authorization_endpoint);
        a.free(e.discovery.token_endpoint);
        a.free(e.discovery.registration_endpoint);
        a.free(e.discovery.scope);
        a.free(e.client_id);
        a.free(e.secret);
        a.destroy(e);
    }
};

pub const Error = error{ NoSuchServer, NotOAuth, NotServing, NoOAuthDetails, Refused, OutOfMemory };

/// Starts an OAuth sign-in for one server. Returns the authorization URL to open.
pub fn beginAuth(g: *gateway_mod.Gateway, a: std.mem.Allocator, server_id: []const u8) ![]u8 {
    const sc = g.cfg.server(server_id) orelse return error.NoSuchServer;
    if (sc.transport == .stdio) return error.NotOAuth;
    const header: []const u8 = sc.token_header orelse "";
    if (header.len > 0) return error.NotOAuth;
    if (!g.serving()) return error.NotServing;

    // Try connecting once with OAuth forced; if it connects straight away,
    // that means the server already has a token.
    const outcome = upstream.connect(a, g.io, sc, .{
        .creds = g.creds,
        .redirect_uri = try gateway_views.redirectURI(g, a),
        .version = g.version,
        .force_oauth = true,
    }) catch |err| {
        if (err == error.SignInRequired) {} else return err;
        // fall through
        return error.Refused;
    };

    switch (outcome) {
        .ready => |up| {
            up.destroy();
            // Connected without sign-in: register and note.
            g.refreshCredentials();
            g.reconnect(sc.id) catch {};
            g.note(sc.name, "connected without sign-in", false);
            return "";
        },
        .needs_auth => |challenge| {
            if (challenge.len == 0) return error.NoOAuthDetails;
            return startFlow(g, a, sc, challenge);
        },
        .failed => |why| {
            g.note(sc.name, why, true);
            a.free(why);
            return error.Refused;
        },
    }
}

/// Signs out a server: forgets its upstream token and reconnects it.
pub fn signOut(g: *gateway_mod.Gateway, a: std.mem.Allocator, server_id: []const u8) !void {
    const sc = g.cfg.server(server_id) orelse return error.NoSuchServer;
    g.creds.signOut(a, sc.id) catch {};
    g.markSignedIn(sc.id, false);
    g.note(sc.name, "signed out", false);
    g.reconnect(sc.id) catch |err| {
        if (err == error.SignInRequired) {} else return err;
    };
}

/// Sets the client credentials to use for a server's OAuth sign-in.
pub fn setClientCredentials(g: *gateway_mod.Gateway, a: std.mem.Allocator, server_id: []const u8, client_id: []const u8, secret: []const u8) !void {
    const sc = g.cfg.server(server_id) orelse return error.NoSuchServer;
    if (client_id.len == 0) {
        g.creds.saveClient(a, sc.id, .{}) catch {};
        return;
    }
    const cc = credentials.ClientCredentials{
        .client_id = client_id,
        .secret = secret,
        .auth_method = "none",
    };
    g.creds.saveClient(a, sc.id, cc) catch {};
}

/// Gets the client credentials stored for a server.
pub fn clientCredentials(g: *gateway_mod.Gateway, a: std.mem.Allocator, server_id: []const u8) credentials.ClientCredentials {
    const sc = g.cfg.server(server_id) orelse return .{};
    return g.creds.client(a, sc.id);
}

fn startFlow(g: *gateway_mod.Gateway, a: std.mem.Allocator, sc: config.ServerConfig, challenge: []const u8) ![]u8 {
    const web = @import("http_client.zig");
    var inner = web.Client.init(a, g.io);
    defer inner.deinit();

    const redirect_uri = try gateway_views.redirectURI(g, a);
    defer a.free(redirect_uri);

    const discovery = oauth_client.discover(a, &inner, sc.url orelse "", challenge) catch |err| {
        const reason = try std.fmt.allocPrint(a, "could not read its OAuth metadata ({t})", .{err});
        g.note(sc.name, reason, true);
        g.recordError(sc.id, reason);
        return error.Refused;
    };

    var cc = g.creds.client(a, sc.id);
    if (cc.client_id.len == 0) {
        cc = oauth_client.registerClient(a, &inner, discovery, redirect_uri, "nanomcp") catch |err| {
            const reason = "needs a client registration its authorization server does not offer; enter a client ID and secret for it and try again";
            g.note(sc.name, reason, true);
            g.recordError(sc.id, reason);
            return err;
        };
        g.creds.saveClient(a, sc.id, cc) catch {};
    }

    const state = try @import("tokens.zig").randomToken(a, g.io);
    defer a.free(state);
    const verifier = try @import("tokens.zig").randomToken(a, g.io);
    const auth_url = try oauth_client.authorizationUrl(a, discovery, cc.client_id, redirect_uri, state, verifier, discovery.scope);

    const entry = PendingEntry{
        .server_id = try a.dupe(u8, sc.id),
        .verifier = verifier,
        .discovery = discovery,
        .client_id = try a.dupe(u8, cc.client_id),
        .secret = try a.dupe(u8, cc.secret orelse ""),
        .created = auth.now(g.io),
    };
    g.mu.lockUncancelable(g.io);
    g.pending.prune(a, auth.now(g.io));
    g.pending.put(a, state, entry) catch {};
    g.mu.unlock(g.io);
    g.note(sc.name, "waiting for sign-in in the browser", false);
    return auth_url;
}

/// Finishes a sign-in when the browser comes back to the gateway's own port:
/// the code becomes a token, which is saved and used to connect the server.
pub fn handleCallback(g: *gateway_mod.Gateway, req: *server.Request) !void {
    const a = req.a;
    const query = req.query;
    const state = (try auth.formValue(a, query, "state")) orelse "";

    const refused = try auth.formValue(a, query, "error");
    if (refused) |code| {
        const description = (try auth.formValue(a, query, "error_description")) orelse "";
        const detail = if (description.len > 0)
            try std.fmt.allocPrint(a, "{s}: {s}", .{ code, description })
        else
            code;
        // The sign-in is over, so its entry goes, and the server's row says
        // why the browser came back empty-handed.
        if (state.len > 0) {
            g.mu.lockUncancelable(g.io);
            const taken = g.pending.take(g.a, state);
            g.mu.unlock(g.io);
            if (taken) |pending| {
                defer g.pending.release(g.a, pending);
                const reason = try std.fmt.allocPrint(a, "sign-in failed: {s}", .{detail});
                g.note(pending.server_id, try std.fmt.allocPrint(a, "{s}: {s}", .{ g.serverName(pending.server_id), reason }), true);
                g.recordError(pending.server_id, reason);
            }
        }
        return callbackPage(req, true, "Sign-in failed", detail);
    }

    const code = (try auth.formValue(a, query, "code")) orelse "";
    if (state.len == 0 or code.len == 0) {
        return callbackPage(req, true, "Sign-in failed", "The authorization server did not send an authorization code.");
    }

    // The pending entry was made with the gateway's own allocator and is
    // reached from both the window thread and this one, so it is taken under
    // the gateway's lock.
    const owner = g.a;
    g.mu.lockUncancelable(g.io);
    g.pending.prune(owner, auth.now(g.io));
    const taken = g.pending.take(owner, state);
    g.mu.unlock(g.io);

    const pending = taken orelse {
        return callbackPage(req, true, "Sign-in failed", "This sign-in has expired, or was already completed. Start it again from nanomcp.");
    };
    defer g.pending.release(owner, pending);

    const redirect_uri = try gateway_views.redirectURI(g, a);
    var inner = @import("http_client.zig").Client.init(a, g.io);
    defer inner.deinit();
    const token = oauth_client.exchangeCode(a, g.io, &inner, pending.discovery, pending.client_id, pending.secret, code, pending.verifier, redirect_uri) catch |err| {
        const reason = try std.fmt.allocPrint(a, "sign-in failed: {t}", .{err});
        g.note(pending.server_id, try std.fmt.allocPrint(a, "{s}: {s}", .{ g.serverName(pending.server_id), reason }), true);
        g.recordError(pending.server_id, reason);
        return callbackPage(req, true, "Sign-in failed", reason);
    };

    var store = g.creds.tokenStore(a, pending.server_id) catch null;
    if (store) |*s| {
        s.save(token) catch |err| {
            const reason = try std.fmt.allocPrint(a, "could not save the token: {t}", .{err});
            g.note(pending.server_id, reason, true);
            g.recordError(pending.server_id, reason);
            return callbackPage(req, true, "Sign-in failed", reason);
        };
    }

    // Keep the issuer discovery found, so a later sign-in reuses the client
    // against the same authorization server.
    const saved = g.creds.client(a, pending.server_id);
    g.creds.saveClient(a, pending.server_id, .{
        .client_id = saved.client_id,
        .secret = saved.secret,
        .issuer = pending.discovery.issuer,
        .auth_method = saved.auth_method,
    }) catch |err| {
        g.note(pending.server_id, try std.fmt.allocPrint(a, "could not save client credentials: {t}", .{err}), true);
    };

    g.markSignedIn(pending.server_id, true);
    g.note(pending.server_id, try std.fmt.allocPrint(a, "{s}: signed in", .{g.serverName(pending.server_id)}), false);
    g.changed();
    try req.respond(.{
        .content_type = "text/html; charset=utf-8",
        .body = try auth.callbackPage(a, "Signed in", "You can close this tab and return to nanomcp.", false),
    });

    // The browser has its answer; connecting the server may take a while, and
    // nothing else is waiting on this request.
    g.reconnect(pending.server_id) catch |err| {
        // The row holds what the connection actually said; the error name
        // alone would only read ConnectFailed.
        const kept = g.errorOf(pending.server_id);
        const reason = if (kept.len > 0)
            kept
        else
            try std.fmt.allocPrint(a, "could not connect after sign-in: {t}", .{err});
        g.note(pending.server_id, try std.fmt.allocPrint(a, "{s}: {s}", .{ g.serverName(pending.server_id), reason }), true);
        g.recordError(pending.server_id, reason);
    };
}

fn callbackPage(req: *server.Request, failed: bool, title: []const u8, detail: []const u8) !void {
    try req.respond(.{
        .status = if (failed) .bad_request else .ok,
        .content_type = "text/html; charset=utf-8",
        .body = try auth.callbackPage(req.a, title, detail, failed),
    });
}
