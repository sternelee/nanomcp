//! One connected MCP server the gateway proxies: the transport it speaks over,
//! the handshake it was given, and the tools it published.
const std = @import("std");
const Io = std.Io;
const auth = @import("auth.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const json = @import("json_util.zig");
const oauth_client = @import("oauth_client.zig");
const rpc = @import("rpc.zig");
const session = @import("session.zig");
const web = @import("http_client.zig");
const stdio = @import("transport_stdio.zig");
const http_transport = @import("transport_http.zig");
const sse = @import("transport_sse.zig");

/// The protocol revision the gateway offers an upstream.
pub const protocol_version = "2025-06-18";

/// The revisions the gateway knows how to speak.
pub const known_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

/// What connecting produced.
pub const Outcome = union(enum) {
    /// The server is up and its tools are known.
    ready: *Upstream,
    /// The server wants a sign-in the gateway can carry out; the text is the
    /// challenge it answered with, which names its authorization server.
    needs_auth: []const u8,
    /// It did not connect; the text says why.
    failed: []const u8,
};

/// How close to expiry a token is renewed, so a request that carries it
/// still lands before the server stops accepting it.
pub const refresh_skew_seconds = 60;

/// Whether a stored token should be traded for a fresh one before it goes on
/// the wire. A token that never expires, or one with no refresh token, is
/// left alone: there is nothing to trade.
pub fn needsRefresh(token: credentials.Token, now: i64) bool {
    if (token.expires_at == 0) return false;
    if (token.refresh_token == null or token.refresh_token.?.len == 0) return false;
    return token.isExpired(now) or now + refresh_skew_seconds >= token.expires_at;
}

/// Reads the token a sign-in produced, so every request to a server that has
/// one carries it. A token near expiry is renewed with its refresh token
/// first, so a long-lived connection does not start failing when the access
/// token runs out.
pub const Bearer = struct {
    creds: *credentials.CredentialStore,
    /// The credential key, worked out once rather than per request.
    key: []const u8,
    /// The gateway's allocator, for the discovery a renewal needs; and the
    /// clock, since a token's expiry is wall time.
    scratch: std.mem.Allocator,
    io: Io,
    server_id: []const u8,
    resource_url: []const u8,
    /// Serializes renewals, so a token near expiry is not refreshed once per
    /// request in flight.
    mu: Io.Mutex = .init,

    fn headerOf(ctx: *anyopaque, a: std.mem.Allocator) ?[]u8 {
        const self: *Bearer = @ptrCast(@alignCast(ctx));
        const raw = self.creds.text(a, self.key);
        defer if (raw.len > 0) a.free(raw);
        if (raw.len == 0) return null;
        const stored = tokenAt(json.parse(a, raw) catch return null);
        if (stored.access_token.len == 0) return null;
        var token = stored.access_token;
        if (needsRefresh(stored, auth.now(self.io))) {
            if (self.renew(a)) |fresh| token = fresh;
        }
        return std.fmt.allocPrint(a, "Bearer {s}", .{token}) catch null;
    }

    /// Trades the stored refresh token for a fresh access token and saves it.
    /// Returns the new token in `a`; null when the exchange fails, in which
    /// case the old token is still what goes on the wire.
    fn renew(self: *Bearer, a: std.mem.Allocator) ?[]u8 {
        if (self.resource_url.len == 0) return null;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);

        var arena_state = std.heap.ArenaAllocator.init(self.scratch);
        defer arena_state.deinit();
        const aa = arena_state.allocator();

        const raw = self.creds.text(aa, self.key);
        if (raw.len == 0) return null;
        const stored = tokenAt(json.parse(aa, raw) catch return null);
        // A request that waited on the lock may find the token renewed by the
        // one before it.
        if (!needsRefresh(stored, auth.now(self.io))) return a.dupe(u8, stored.access_token) catch null;
        const refresh_token = stored.refresh_token orelse return null;

        var client = web.Client.init(aa, self.io);
        defer client.deinit();
        const discovery = oauth_client.discover(aa, &client, self.resource_url, "") catch return null;
        const cc = self.creds.client(aa, self.server_id);
        var fresh = oauth_client.refresh(
            aa,
            self.io,
            &client,
            discovery,
            cc.client_id,
            cc.secret orelse "",
            refresh_token,
        ) catch return null;
        // A response that leaves the refresh token out means the one already
        // stored stays in use.
        if (fresh.refresh_token == null or fresh.refresh_token.?.len == 0) fresh.refresh_token = refresh_token;
        var store = self.creds.tokenStore(aa, self.server_id) catch return null;
        store.save(fresh) catch return null;
        return a.dupe(u8, fresh.access_token) catch null;
    }

    fn wire(b: *Bearer) web.Bearer {
        return .{ .ctx = b, .header = headerOf };
    }
};

/// A stored token, as the JSON it was saved as carries it.
fn tokenAt(doc: json.Value) credentials.Token {
    return .{
        .issuer = json.getString(doc, "issuer"),
        .access_token = json.getString(doc, "access_token") orelse "",
        .token_type = json.getString(doc, "token_type") orelse "",
        .refresh_token = json.getString(doc, "refresh_token"),
        .expires_in = json.getInt(doc, "expires_in") orelse 0,
        .scope = json.getString(doc, "scope"),
        .expires_at = json.getInt(doc, "expires_at") orelse 0,
    };
}

/// What connecting needs from the gateway that owns it.
pub const Options = struct {
    creds: ?*credentials.CredentialStore = null,
    redirect_uri: []const u8 = "",
    version: []const u8 = "0.1.0",
    /// The environment a subprocess server inherits, before its own.
    environ: ?*const std.process.Environ.Map = null,
    /// Connect with OAuth even when the configuration does not ask for it, for
    /// a server that has said it must be signed in to.
    force_oauth: bool = false,
};

/// Where a connected server's messages go.
const Link = union(enum) {
    stdio: *stdio.Stdio,
    http: *http_transport.Http,
    sse: *sse.Sse,

    fn wire(l: Link) session.Wire {
        return switch (l) {
            .stdio => |t| t.wire(),
            .http => |t| t.wire(),
            .sse => |t| t.wire(),
        };
    }

    fn destroy(l: Link) void {
        switch (l) {
            .stdio => |t| t.deinit(),
            .http => |t| t.deinit(),
            .sse => |t| t.deinit(),
        }
    }

    /// What a refused request said it wanted, for a sign-in to pick up.
    fn challenge(l: Link) ?[]const u8 {
        return switch (l) {
            .stdio => null,
            .http => |t| t.challenge,
            .sse => |t| t.challenge,
        };
    }

    /// The HTTP status of the last answer, when the transport is HTTP.
    fn status(l: Link) u16 {
        return switch (l) {
            .stdio => 0,
            .http => |t| t.last_status,
            .sse => 0,
        };
    }
};

/// One connected server.
pub const Upstream = struct {
    a: std.mem.Allocator,
    config: config.ServerConfig,
    link: Link,
    sess: session.Session,
    /// The tool definitions the server published, as it sent them.
    tools: []json.Value,
    /// Protected by the gateway's mutex: how many calls hold it, and whether
    /// it has been taken out of the registry. The last holder frees it, so a
    /// call is never running against freed memory.
    refs: usize = 1,
    retired: bool = false,

    pub fn close(u: *Upstream) void {
        u.sess.deinit();
    }

    pub fn destroy(u: *Upstream) void {
        const a = u.a;
        u.sess.deinit();
        u.link.destroy();
        for (u.tools) |tool| json.free(a, tool);
        a.free(u.tools);
        a.destroy(u);
    }

    /// Calls one of the server's tools by the name it knows.
    pub fn callTool(u: *Upstream, a: std.mem.Allocator, name: []const u8, args: ?json.Value) !json.Value {
        var params: json.Object = .empty;
        try params.put(a, "name", .{ .string = name });
        try params.put(a, "arguments", args orelse .{ .object = .empty });
        return u.sess.call(a, "tools/call", .{ .object = params });
    }

    /// The names of the tools the server published.
    pub fn toolNames(u: *Upstream, a: std.mem.Allocator) ![]const []const u8 {
        const names = try a.alloc([]const u8, u.tools.len);
        for (u.tools, 0..) |t, i| names[i] = json.getString(t, "name") orelse "";
        return names;
    }
};

/// Starts a server and lists its tools.
pub fn connect(a: std.mem.Allocator, io: Io, sc: config.ServerConfig, opts: Options) !Outcome {
    const link = startLink(a, io, sc, opts) catch |err| return .{ .failed = try why(a, err) };
    errdefer link.destroy();

    const up = try a.create(Upstream);
    up.* = .{
        .a = a,
        .config = sc,
        .link = link,
        .sess = session.Session.init(a, io, link.wire()),
        .tools = &.{},
    };
    errdefer a.destroy(up);

    // A subprocess answers on its standard output, so something has to be
    // reading it before the handshake starts waiting for an answer.
    attachReader(up) catch |err| {
        up.sess.deinit();
        link.destroy();
        a.destroy(up);
        return .{ .failed = try why(a, err) };
    };

    handshake(up, opts.version) catch |err| {
        // A refusal is what makes a server state its authorization
        // requirements, so it is kept before the connection goes away.
        const wanted: ?[]const u8 = if (err == error.AuthRequired) link.challenge() else null;
        const reason = if (wanted) |c| try a.dupe(u8, c) else null;
        const status = link.status();
        const logs = stderrOf(a, link);

        up.sess.deinit();
        link.destroy();
        a.destroy(up);
        if (reason) |c| return .{ .needs_auth = c };
        if (err == error.AuthRequired) return .{ .needs_auth = "the server wants a sign-in" };
        // A status is what says why a server refused, which the error name
        // alone does not.
        if (err == error.BadStatus) return .{ .failed = try std.fmt.allocPrint(a, "the server answered HTTP {d} to the handshake", .{status}) };
        // A subprocess that died says why on its own stderr.
        if (logs) |text| return .{ .failed = try std.fmt.allocPrint(a, "{s}: {s}", .{ try why(a, err), text }) };
        return .{ .failed = try why(a, err) };
    };

    up.tools = listTools(up) catch |err| {
        const status = up.link.status();
        const logs = stderrOf(a, up.link);
        up.sess.deinit();
        link.destroy();
        a.destroy(up);
        if (err == error.BadStatus) return .{ .failed = try std.fmt.allocPrint(a, "the server answered HTTP {d} while listing its tools", .{status}) };
        if (logs) |text| return .{ .failed = try std.fmt.allocPrint(a, "{s}: {s}", .{ try why(a, err), text }) };
        return .{ .failed = try why(a, err) };
    };
    return .{ .ready = up };
}

/// What a subprocess said on stderr, for a failure that would otherwise only
/// name the error.
fn stderrOf(a: std.mem.Allocator, link: Link) ?[]const u8 {
    return switch (link) {
        .stdio => |t| blk: {
            const text = t.logsText(a) catch break :blk null;
            break :blk if (text.len == 0) null else text;
        },
        else => null,
    };
}

/// Gives the transport the session its answers belong to: for a subprocess it
/// also starts reading its output, which the handshake then waits on.
fn attachReader(up: *Upstream) !void {
    switch (up.link) {
        .stdio => |t| try t.attach(&up.sess),
        // Every transport hands its answers to the session's pending calls.
        // Without the session, a remote answer is read and dropped, and the
        // handshake waits for it for ever.
        .http => |t| t.attach(&up.sess),
        .sse => |t| t.attach(&up.sess),
    }
}

fn why(a: std.mem.Allocator, err: anyerror) ![]const u8 {
    return std.fmt.allocPrint(a, "{t}", .{err});
}

/// Builds the transport the configuration calls for.
fn startLink(a: std.mem.Allocator, io: Io, sc: config.ServerConfig, opts: Options) !Link {
    const link: Link = switch (sc.transport) {
        .stdio => .{ .stdio = try stdio.Stdio.start(a, io, sc.command orelse "", sc.args orelse &.{}, sc.env orelse &.{}, opts.environ) },
        .http => blk: {
            const headers = try requestHeaders(a, sc, opts);
            defer a.free(headers);
            break :blk .{ .http = try http_transport.Http.init(a, io, sc.url orelse "", headers) };
        },
        .sse => blk: {
            const headers = try requestHeaders(a, sc, opts);
            defer a.free(headers);
            break :blk .{ .sse = try sse.Sse.start(a, io, sc.url orelse "", headers) };
        },
        .other => return error.UnknownTransport,
    };

    // A server that signs in carries the token its sign-in produced, on every
    // request, so the transport does not need to know about OAuth at all.
    if (opts.creds) |creds| {
        if (oauthFor(a, sc, opts)) {
            const bearer = try a.create(Bearer);
            bearer.* = .{
                .creds = creds,
                .key = try credentials.CredentialStore.tokenKey(a, sc.id),
                .scratch = a,
                .io = io,
                .server_id = sc.id,
                .resource_url = sc.url orelse "",
            };
            switch (link) {
                .stdio => {},
                .http => |t| t.setBearer(bearer.wire()),
                .sse => |t| t.setBearer(bearer.wire()),
            }
        }
    }
    return link;
}

/// The headers every request to a remote server carries: the configured ones,
/// plus the stored token when the server takes one.
pub fn requestHeaders(a: std.mem.Allocator, sc: config.ServerConfig, opts: Options) ![]web.Header {
    var out: std.ArrayList(web.Header) = .empty;
    errdefer out.deinit(a);
    if (sc.headers) |headers| {
        for (headers.map.keys(), headers.map.values()) |name, value| {
            try out.append(a, .{ .name = name, .value = value });
        }
    }
    if (sc.token_header) |header| {
        if (header.len > 0) {
            if (opts.creds) |creds| {
                const token = creds.upstreamToken(a, sc.id);
                defer a.free(token);
                if (token.len > 0) {
                    try out.append(a, .{ .name = header, .value = try tokenValue(a, sc.token_scheme, token) });
                }
            }
        }
    }
    return out.toOwnedSlice(a);
}

/// Renders a token as a header value, with the scheme the server expects.
pub fn tokenValue(a: std.mem.Allocator, scheme: ?[]const u8, token: []const u8) ![]u8 {
    const s = std.mem.trim(u8, scheme orelse "", " \t\r\n");
    if (s.len == 0) return a.dupe(u8, token);
    return std.fmt.allocPrint(a, "{s} {s}", .{ s, token });
}

/// Whether a server's client should carry an OAuth handler.
pub fn oauthFor(a: std.mem.Allocator, sc: config.ServerConfig, opts: Options) bool {
    if (sc.transport == .stdio) return false;
    if (opts.force_oauth) return true;
    if (sc.oauth) return opts.creds != null;
    const header: []const u8 = sc.token_header orelse "";
    if (opts.creds) |creds| {
        return header.len == 0 and creds.signedIn(a, sc.id, 0);
    }
    return false;
}

/// The initialize request, then the notification that closes the handshake.
fn handshake(u: *Upstream, version: []const u8) !void {
    const a = u.a;
    var params: json.Object = .empty;
    try params.put(a, "protocolVersion", .{ .string = protocol_version });
    try params.put(a, "capabilities", .{ .object = .empty });
    var info: json.Object = .empty;
    try info.put(a, "name", .{ .string = "nanomcp" });
    try info.put(a, "version", .{ .string = version });
    try params.put(a, "clientInfo", .{ .object = info });

    _ = try u.sess.call(a, "initialize", .{ .object = params });
    try u.sess.notify(a, "notifications/initialized", .{ .object = .empty });
}

/// Reads every page of the server's tool list.
fn listTools(u: *Upstream) ![]json.Value {
    const a = u.a;
    var out: std.ArrayList(json.Value) = .empty;
    errdefer out.deinit(a);
    var cursor: ?[]const u8 = null;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var params: json.Object = .empty;
        if (cursor) |c| try params.put(a, "cursor", .{ .string = c });
        const result = try u.sess.call(a, "tools/list", .{ .object = params });
        if (json.getArray(result, "tools")) |tools| {
            try out.appendSlice(a, tools.items);
        }
        cursor = json.getString(result, "nextCursor");
        if (cursor == null or cursor.?.len == 0) break;
    }
    return out.toOwnedSlice(a);
}

/// Whether a failure means the server wants a sign-in.
pub fn needsAuth(sc: config.ServerConfig, outcome: Outcome) bool {
    if (sc.transport == .stdio) return false;
    const header: []const u8 = sc.token_header orelse "";
    if (header.len > 0) return false;
    return switch (outcome) {
        .needs_auth => true,
        else => false,
    };
}

test "a token is rendered with the scheme the server expects" {
    const a = std.testing.allocator;
    const plain = try tokenValue(a, null, "abc");
    defer a.free(plain);
    try std.testing.expectEqualStrings("abc", plain);

    const bearer = try tokenValue(a, "Bearer", "abc");
    defer a.free(bearer);
    try std.testing.expectEqualStrings("Bearer abc", bearer);

    const blank = try tokenValue(a, "  ", "abc");
    defer a.free(blank);
    try std.testing.expectEqualStrings("abc", blank);
}

test "a server with a token of its own is not signed in to" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();

    const with_token: config.ServerConfig = .{
        .id = "s1",
        .name = "GitHub",
        .transport = .http,
        .url = "https://example.com/mcp",
        .token_header = "Authorization",
    };
    try std.testing.expect(!oauthFor(a, with_token, .{ .creds = &store }));

    const signing_in: config.ServerConfig = .{
        .id = "s2",
        .name = "Linear",
        .transport = .http,
        .url = "https://example.com/mcp",
        .oauth = true,
    };
    try std.testing.expect(oauthFor(a, signing_in, .{ .creds = &store }));
    try std.testing.expect(!oauthFor(a, signing_in, .{}));
}

test "a token is refreshed when it has expired or is about to" {
    try std.testing.expect(needsRefresh(.{ .access_token = "a", .refresh_token = "r", .expires_at = 1_000 }, 1_100));
    // The skew leaves time for the request to land before the server stops
    // accepting the token.
    try std.testing.expect(needsRefresh(.{ .access_token = "a", .refresh_token = "r", .expires_at = 1_030 }, 1_000));
    try std.testing.expect(!needsRefresh(.{ .access_token = "a", .refresh_token = "r", .expires_at = 2_000 }, 1_000));

    // A token with no refresh token, or one that never expires, is left alone.
    try std.testing.expect(!needsRefresh(.{ .access_token = "a", .expires_at = 1 }, 1_100));
    try std.testing.expect(!needsRefresh(.{ .access_token = "a", .refresh_token = "r", .expires_at = 0 }, 1_100));
}

test "configured headers and the stored token both go on the request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();
    try store.setUpstreamToken(a, "s1", "ghp_secret");

    var headers: std.json.ArrayHashMap([]const u8) = .{};
    try headers.map.put(a, "X-Api-Version", "2");

    const sc: config.ServerConfig = .{
        .id = "s1",
        .name = "GitHub",
        .transport = .http,
        .url = "https://example.com/mcp",
        .headers = headers,
        .token_header = "Authorization",
        .token_scheme = "Bearer",
    };
    const out = try requestHeaders(a, sc, .{ .creds = &store });
    try std.testing.expectEqual(@as(usize, 2), out.len);
    var saw_version = false;
    var saw_auth = false;
    for (out) |h| {
        if (std.mem.eql(u8, h.name, "X-Api-Version")) saw_version = std.mem.eql(u8, h.value, "2");
        if (std.mem.eql(u8, h.name, "Authorization")) saw_auth = std.mem.eql(u8, h.value, "Bearer ghp_secret");
    }
    try std.testing.expect(saw_version);
    try std.testing.expect(saw_auth);
}
