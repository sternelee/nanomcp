//! The fixtures the OAuth tests share: a gateway listening on a loopback
//! socket, and a protected upstream with the authorization server it points at.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = @import("json_util.zig");
const server = @import("server.zig");
const web = @import("http_client.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const gateway_mod = @import("gateway.zig");
const gateway_http = @import("gateway_http.zig");
const oauth_client = @import("oauth_client.zig");
const auth = @import("auth.zig");
const tokens = @import("tokens.zig");

/// Where a client asks the browser to come back to.
pub const redirect_uri = "http://127.0.0.1:9999/callback";

/// The token the fake upstream accepts.
pub const upstream_token = "test-access-token";

/// The fields a client sends to the authorize endpoint, in the order the
/// consent page carries them back.
pub fn authorizeFields(client_id: []const u8, challenge: []const u8, state: []const u8) [6]auth.Pair {
    return .{
        .{ .name = "response_type", .value = "code" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "state", .value = state },
    };
}

/// The URL a browser is sent to, as a client builds it.
pub fn authorizeUrl(a: std.mem.Allocator, base: []const u8, client_id: []const u8, challenge: []const u8, state: []const u8) ![]u8 {
    const fields = authorizeFields(client_id, challenge, state);
    return auth.withQuery(a, try std.fmt.allocPrint(a, "{s}/oauth/authorize", .{base}), &fields);
}

/// The token the consent page carries in its form, which proves the form came
/// from a page the user was shown.
pub fn consentTokenOf(page: []const u8) ![]const u8 {
    const marker = "name=\"consent_token\" value=\"";
    const start = (std.mem.indexOf(u8, page, marker) orelse return error.NoConsent) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, page, start, '"') orelse return error.NoConsent;
    return page[start..end];
}

/// The authorization code a redirect carried back.
pub fn codeOf(a: std.mem.Allocator, location: []const u8) ![]const u8 {
    const start = std.mem.findScalar(u8, location, '?') orelse return error.NoQuery;
    return (try auth.queryValue(a, location[start + 1 ..], "code")) orelse error.NoCode;
}

/// The URL of an authorization URL's query, as a client would read it back.
pub fn queryOf(url: []const u8) ![]const u8 {
    return url[(std.mem.findScalar(u8, url, '?') orelse return error.NoQuery) + 1 ..];
}

/// A port nothing is listening on yet. The server opens its sockets with the
/// reuse option that lets two listeners share one, so a port is probed without
/// it: two fixtures in the same test would otherwise be handed the same port
/// and split the requests between them.
pub fn freePort(io: Io) !u16 {
    var port: u16 = 47_900;
    while (port < 47_999) : (port += 1) {
        const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
        var probe = addr.listen(io, .{ .mode = .stream }) catch continue;
        probe.deinit(io);
        return port;
    }
    return error.NoFreePort;
}

pub fn bearerHeader(a: std.mem.Allocator, token: []const u8) ![]web.Header {
    const headers = try a.alloc(web.Header, 1);
    headers[0] = .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    return headers;
}

/// The gateway, listening on a free port, with a client to reach it. The
/// listener is handed to the gateway so it believes it is serving, which is
/// what a sign-in started from the interface requires.
pub const Serving = struct {
    a: std.mem.Allocator,
    /// The listener's own arena. Its handler threads allocate from it, and
    /// they must never share the arena the test itself allocates from: two
    /// threads in one arena corrupt it.
    server_a: std.heap.ArenaAllocator,
    io: Io,
    cfg: config.Config,
    store: credentials.CredentialStore,
    g: gateway_mod.Gateway,
    listener: *server.Server,
    client: web.Client,
    base: []u8,

    pub fn start(a: std.mem.Allocator, io: Io, servers: []const config.ServerConfig) !*Serving {
        const f = try a.create(Serving);
        f.* = .{
            .a = a,
            .server_a = .init(std.testing.allocator),
            .io = io,
            .cfg = config.Config.default(),
            .store = credentials.CredentialStore.initMemory(a),
            .g = undefined,
            .listener = undefined,
            .client = web.Client.init(a, io),
            .base = "",
        };
        for (servers) |sc| try f.cfg.upsert(a, sc);
        f.g = gateway_mod.Gateway.init(a, io, &f.cfg, &f.store, "0.1.0");
        f.listener = try server.Server.init(f.server_a.allocator(), io, try freePort(io), .{ .ctx = &f.g, .handle = gateway_http.handle });
        f.cfg.port = f.listener.port;
        f.g.listener = f.listener;
        f.g.port = f.listener.port;
        try f.listener.start();
        f.base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.port});
        return f;
    }

    /// The gateway stops the listener it was given, so it is not destroyed
    /// twice here.
    pub fn stop(f: *Serving) void {
        f.g.stop();
        f.client.deinit();
        _ = f.g.deinit();
        f.store.deinit();
        f.server_a.deinit();
    }

    /// Signs in with a fixed token, as the gateway's own authorization server.
    pub fn serveAsAuthServer(f: *Serving, token: []const u8) void {
        f.cfg.inbound = .oauth;
        f.store.setInboundToken(token) catch {};
        f.g.refreshCredentials();
    }

    pub fn requestUrl(f: *Serving, method: http.Method, url: []const u8, headers: []const web.Header, body: ?[]const u8) !web.Answer {
        return f.client.send(method, url, headers, body);
    }

    pub fn request(f: *Serving, method: http.Method, path: []const u8, headers: []const web.Header, body: ?[]const u8) !web.Answer {
        return f.requestUrl(method, try std.fmt.allocPrint(f.a, "{s}{s}", .{ f.base, path }), headers, body);
    }

    pub fn postForm(f: *Serving, path: []const u8, fields: []const auth.Pair) !web.Answer {
        const headers = [_]web.Header{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }};
        return f.request(.POST, path, &headers, try oauth_client.formBody(f.a, fields));
    }

    /// Registers a client the way a client does, checks the registration
    /// response, and makes the PKCE verifier that goes with it.
    pub fn register(f: *Serving, a: std.mem.Allocator) !Registered {
        const body = try std.fmt.allocPrint(a, "{{\"client_name\":\"A test client\",\"redirect_uris\":[\"{s}\"]}}", .{redirect_uri});
        const headers = [_]web.Header{.{ .name = "content-type", .value = "application/json" }};
        const answer = try f.request(.POST, "/oauth/register", &headers, body);
        try std.testing.expectEqual(@as(u16, 201), answer.status);
        const doc = try json.parse(a, answer.body);
        const verifier = try tokens.randomToken(a, f.io);
        return .{
            .client_id = json.getString(doc, "client_id").?,
            .verifier = verifier,
            .challenge = try oauth_client.pkceChallenge(a, verifier),
        };
    }

    /// Plays the browser: reads the consent page, approves the client, and
    /// answers with the location it was redirected to.
    pub fn approve(f: *Serving, a: std.mem.Allocator, client_id: []const u8, challenge: []const u8, state: []const u8) ![]const u8 {
        const page = try f.requestUrl(.GET, try authorizeUrl(a, f.base, client_id, challenge, state), &.{}, null);
        try std.testing.expectEqual(@as(u16, 200), page.status);
        try std.testing.expect(std.mem.indexOf(u8, page.body, "Allow this client") != null);
        try std.testing.expect(std.mem.indexOf(u8, page.body, client_id) != null);

        const visible = authorizeFields(client_id, challenge, state);
        var fields: [visible.len + 1]auth.Pair = undefined;
        for (visible, 0..) |field, i| fields[i] = field;
        fields[visible.len] = .{ .name = "consent_token", .value = try consentTokenOf(page.body) };
        const approved = try f.postForm("/oauth/authorize", &fields);
        try std.testing.expectEqual(@as(u16, 302), approved.status);
        return (try approved.headerValue(a, "location")).?;
    }

    pub fn exchange(f: *Serving, client_id: []const u8, code: []const u8, verifier: []const u8) !web.Answer {
        const fields = [_]auth.Pair{
            .{ .name = "grant_type", .value = "authorization_code" },
            .{ .name = "code", .value = code },
            .{ .name = "redirect_uri", .value = redirect_uri },
            .{ .name = "client_id", .value = client_id },
            .{ .name = "code_verifier", .value = verifier },
        };
        return f.postForm("/oauth/token", &fields);
    }
};

/// A client that registered itself, with the proof that goes with its code.
pub const Registered = struct {
    client_id: []const u8,
    verifier: []const u8,
    challenge: []const u8,
};

/// The upstream of the Go original's oauth_test.go: a protected MCP server that
/// answers 401 without its token, and the authorization server it points at.
pub const FakeUpstream = struct {
    /// Everything this server touches is its own: its handler runs on a
    /// thread of the server's, so it allocates from an arena of its own.
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    listener: *server.Server,
    base: []u8,
    /// The last authorization a protected request carried.
    sent: std.ArrayList(u8) = .empty,
    /// How many times a client registered itself.
    registrations: usize = 0,
    /// How many codes were exchanged for a token.
    tokens: usize = 0,
    /// How many refresh tokens were exchanged for a fresh access token.
    refreshes: usize = 0,

    pub fn start(io: Io) !*FakeUpstream {
        const gpa = std.testing.allocator;
        const f = try gpa.create(FakeUpstream);
        f.* = .{ .arena = .init(gpa), .a = undefined, .listener = undefined, .base = "" };
        f.a = f.arena.allocator();
        f.listener = try server.Server.init(f.a, io, try freePort(io), .{ .ctx = f, .handle = handle });
        try f.listener.start();
        f.base = try std.fmt.allocPrint(f.a, "http://127.0.0.1:{d}", .{f.listener.port});
        return f;
    }

    pub fn stop(f: *FakeUpstream) void {
        f.listener.stop();
        f.listener.destroy();
        const gpa = f.arena.child_allocator;
        f.arena.deinit();
        gpa.destroy(f);
    }

    pub fn mcpUrl(f: *FakeUpstream, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/mcp", .{f.base});
    }

    /// The protected resource: it refuses anything but its own token, and says
    /// where its authorization server is when it does.
    fn mcp(f: *FakeUpstream, req: *server.Request) !void {
        const authorization = req.header("authorization") orelse "";
        if (!std.mem.eql(u8, authorization, "Bearer " ++ upstream_token)) {
            const challenge = try std.fmt.allocPrint(
                req.a,
                "Bearer resource_metadata=\"{s}/.well-known/oauth-protected-resource\"",
                .{f.base},
            );
            return req.respond(.{
                .status = .unauthorized,
                .headers = &.{.{ .name = "www-authenticate", .value = challenge }},
                .body = "{\"error\":\"invalid_token\"}",
            });
        }
        f.sent.clearRetainingCapacity();
        try f.sent.appendSlice(f.a, authorization);

        const doc = try json.parse(req.a, req.body);
        const method = json.getString(doc, "method") orelse "";
        // A notification, like notifications/initialized, has no id and no
        // answer.
        const id = json.getInt(doc, "id") orelse {
            return req.respond(.{ .status = .accepted, .content_type = null, .body = "" });
        };
        const result = if (std.mem.eql(u8, method, "initialize"))
            "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"protected\",\"version\":\"1.0\"}}"
        else if (std.mem.eql(u8, method, "tools/list"))
            "{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo the text back.\",\"inputSchema\":{\"type\":\"object\"}}]}"
        else
            "{}";
        try req.respond(.{ .body = try std.fmt.allocPrint(req.a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result }) });
    }

    fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
        const f: *FakeUpstream = @ptrCast(@alignCast(ctx));

        if (std.mem.eql(u8, req.path, "/mcp")) return f.mcp(req);

        if (std.mem.eql(u8, req.path, "/.well-known/oauth-protected-resource")) {
            const body = try std.fmt.allocPrint(
                req.a,
                "{{\"resource\":\"{s}\",\"authorization_servers\":[\"{s}\"]}}",
                .{ f.base, f.base },
            );
            return req.respond(.{ .body = body });
        }

        if (std.mem.eql(u8, req.path, "/.well-known/oauth-authorization-server")) {
            const body = try std.fmt.allocPrint(
                req.a,
                "{{\"issuer\":\"{s}\",\"authorization_endpoint\":\"{s}/authorize\",\"token_endpoint\":\"{s}/token\"," ++
                    "\"registration_endpoint\":\"{s}/register\",\"scopes_supported\":[\"mcp\"]," ++
                    "\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"refresh_token\"]," ++
                    "\"code_challenge_methods_supported\":[\"S256\"],\"token_endpoint_auth_methods_supported\":[\"none\"]}}",
                .{ f.base, f.base, f.base, f.base },
            );
            return req.respond(.{ .body = body });
        }

        if (std.mem.eql(u8, req.path, "/register")) {
            f.registrations += 1;
            return req.respond(.{
                .status = .created,
                .body = "{\"client_id\":\"registered-client\",\"token_endpoint_auth_method\":\"none\"}",
            });
        }

        // The code exchange: the code is accepted once, and the token it
        // yields is the one the protected resource accepts.
        if (std.mem.eql(u8, req.path, "/token")) {
            const grant = (try auth.formValue(req.a, req.body, "grant_type")) orelse "";
            if (std.mem.eql(u8, grant, "refresh_token")) {
                const refresh_token = (try auth.formValue(req.a, req.body, "refresh_token")) orelse "";
                if (!std.mem.eql(u8, refresh_token, "test-refresh-token")) {
                    return req.respond(.{ .status = .bad_request, .body = "{\"error\":\"invalid_grant\"}" });
                }
                f.refreshes += 1;
                // A refresh may leave the refresh token out, which means the
                // one the client already has stays in use.
                return req.respond(.{
                    .headers = &.{.{ .name = "cache-control", .value = "no-store" }},
                    .body = "{\"access_token\":\"" ++ upstream_token ++ "\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
                });
            }
            const code = (try auth.formValue(req.a, req.body, "code")) orelse "";
            if (code.len == 0) return req.respond(.{ .status = .bad_request, .body = "{\"error\":\"invalid_grant\"}" });
            f.tokens += 1;
            return req.respond(.{
                .headers = &.{.{ .name = "cache-control", .value = "no-store" }},
                .body = "{\"access_token\":\"" ++ upstream_token ++ "\",\"token_type\":\"Bearer\"," ++
                    "\"refresh_token\":\"test-refresh-token\",\"expires_in\":3600}",
            });
        }

        try req.respond(.{ .status = .not_found, .body = "{}" });
    }
};
