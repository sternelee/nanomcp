//! The gateway's HTTP surface: the endpoints that serve tools behind the
//! caller check, the discovery endpoints a client reaches before it has a
//! credential, and the sign-in endpoints of the gateway's own authorization
//! server.
const std = @import("std");
const Io = std.Io;
const json = @import("json_util.zig");
const server = @import("server.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const gateway_mod = @import("gateway.zig");
const mcp_endpoint = @import("mcp_endpoint.zig");
const oauth = @import("oauth.zig");
const gateway_views = @import("gateway_views.zig");

/// Answers one request, whichever endpoint it is for.
pub fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
    const g: *gateway_mod.Gateway = @ptrCast(@alignCast(ctx));
    const path = req.path;

    // Everything that serves the tool surface is behind the caller check. The
    // discovery endpoints below stay open, since a client has to reach them in
    // order to obtain the credential in the first place. Each guarded endpoint
    // names itself, so its challenge points at metadata that describes it.
    if (std.mem.eql(u8, path, "/mcp")) return guarded(g, req, "mcp", mcp_endpoint.handle);
    if (std.mem.eql(u8, path, "/sse")) return guarded(g, req, "sse", mcp_endpoint.handleSse);
    if (std.mem.eql(u8, path, "/message")) return guarded(g, req, "sse", mcp_endpoint.handleMessage);
    if (std.mem.eql(u8, path, "/healthz")) return guarded(g, req, "mcp", handleHealth);

    // The gateway's own sign-in with an upstream, and the endpoints that let
    // callers sign in with the gateway. These stay mounted whatever the mode,
    // so turning the authorization server on takes effect without a restart.
    if (std.mem.eql(u8, path, "/oauth/callback")) return oauth.handleCallback(g, req);
    if (std.mem.eql(u8, path, auth.protected_resource_path)) return handleProtectedResource(g, req, "");
    for (auth.resource_paths) |resource_path| {
        const full = try auth.metadataPath(req.a, resource_path);
        if (std.mem.eql(u8, path, full)) return handleProtectedResource(g, req, resource_path);
    }
    if (std.mem.eql(u8, path, "/.well-known/oauth-authorization-server")) return asAuthServer(g, req, handleAuthServerMetadata);
    if (std.mem.eql(u8, path, "/oauth/register")) return asAuthServer(g, req, handleRegister);
    if (std.mem.eql(u8, path, "/oauth/authorize")) return asAuthServer(g, req, handleAuthorize);
    if (std.mem.eql(u8, path, "/oauth/token")) return asAuthServer(g, req, handleToken);

    try req.respond(.{ .status = .not_found, .body = "not found" });
}

/// Wraps an endpoint so that callers must identify themselves when the
/// configuration asks them to. `resource_path` names the endpoint being
/// guarded, so the challenge can point at the right metadata.
fn guarded(
    g: *gateway_mod.Gateway,
    req: *server.Request,
    resource_path: []const u8,
    next: *const fn (g: *gateway_mod.Gateway, req: *server.Request) anyerror!void,
) !void {
    const mode = g.cfg.inboundMode();
    if (!mode.requiresToken()) return next(g, req);

    g.mu.lockUncancelable(g.io);
    const want = g.auth_token;
    g.mu.unlock(g.io);

    const presented = auth.bearerToken(req);
    if (presented.len > 0 and (auth.sameToken(presented, want) or g.tokens.accepts(presented, auth.now(g.io)))) {
        return next(g, req);
    }
    return rejectUnauthorized(g, req, resource_path);
}

/// Tells the caller what it needs, and where to get it. The 401 and the
/// resource metadata URL are what make an MCP client start a sign-in of its
/// own.
fn rejectUnauthorized(g: *gateway_mod.Gateway, req: *server.Request, resource_path: []const u8) !void {
    const base = try gateway_views.baseURL(g, req.a);
    const challenge = try std.fmt.allocPrint(
        req.a,
        "Bearer resource_metadata=\"{s}{s}\"",
        .{ base, try auth.metadataPath(req.a, resource_path) },
    );
    const body = try auth.oauthError(req.a, "invalid_token", "this gateway requires a bearer token");
    try req.respond(.{
        .status = .unauthorized,
        .headers = &.{.{ .name = "www-authenticate", .value = challenge }},
        .body = body,
    });
}

/// Mounts an endpoint that only answers when the gateway is in the mode where
/// it issues tokens itself.
fn asAuthServer(
    g: *gateway_mod.Gateway,
    req: *server.Request,
    next: *const fn (g: *gateway_mod.Gateway, req: *server.Request) anyerror!void,
) !void {
    if (g.cfg.inboundMode() != .oauth) {
        try req.respond(.{ .status = .not_found, .body = "not found" });
        return;
    }
    return next(g, req);
}

fn handleHealth(g: *gateway_mod.Gateway, req: *server.Request) !void {
        try req.respond(.{ .body = try gateway_views.healthJSON(g, req.a) });
}

/// RFC 9728 metadata for the gateway itself. The path it was asked for names
/// the endpoint being described, so the resource identifier matches the URL the
/// client used.
fn handleProtectedResource(g: *gateway_mod.Gateway, req: *server.Request, resource_path: []const u8) !void {
    const base = try gateway_views.baseURL(g, req.a);
    const oauth_mode = g.cfg.inboundMode() == .oauth;
    try req.respond(.{ .body = try auth.protectedResourceMetadata(req.a, base, resource_path, oauth_mode) });
}

/// RFC 8414 metadata for the gateway acting as its own authorization server.
fn handleAuthServerMetadata(g: *gateway_mod.Gateway, req: *server.Request) !void {
    try req.respond(.{ .body = try auth.authServerMetadata(req.a, try gateway_views.baseURL(g, req.a)) });
}

/// Dynamic client registration. Clients are public: they get an identifier and
/// nothing else.
fn handleRegister(g: *gateway_mod.Gateway, req: *server.Request) !void {
    if (req.method != .POST) return methodNotAllowed(req, "POST");

    const doc = json.parse(req.a, req.body) catch {
        return oauthError(req, .bad_request, "invalid_client_metadata", "the registration is not valid JSON");
    };
    const client_name = json.getString(doc, "client_name") orelse "";
    const uris = json.getArray(doc, "redirect_uris") orelse {
        return oauthError(req, .bad_request, "invalid_redirect_uri", "at least one redirect_uri is required");
    };
    if (uris.items.len == 0) {
        return oauthError(req, .bad_request, "invalid_redirect_uri", "at least one redirect_uri is required");
    }
    const redirects = try req.a.alloc([]const u8, uris.items.len);
    for (uris.items, 0..) |uri, i| {
        const text = switch (uri) {
            .string => |s| s,
            else => "",
        };
        if (!auth.validRedirectURI(text)) {
            return oauthError(
                req,
                .bad_request,
                "invalid_redirect_uri",
                try std.fmt.allocPrint(req.a, "{s} is not an http or https URL", .{try config.quoted(req.a, text)}),
            );
        }
        redirects[i] = text;
    }

    const client_id = g.tokens.registerClient(redirects, auth.now(g.io)) catch {
        return oauthError(req, .internal_server_error, "server_error", "the client could not be registered");
    };
    g.note("", try std.fmt.allocPrint(req.a, "registered OAuth client {s}", .{auth.describeClient(client_name)}), false);
    g.changed();

    try req.respond(.{
        .status = .created,
        .body = try auth.registrationResponse(req.a, client_id, client_name, redirects),
    });
}

/// Asks the user to approve a client, then hands out a code. Nothing is ever
/// redirected to before its redirect URI has been checked.
fn handleAuthorize(g: *gateway_mod.Gateway, req: *server.Request) !void {
    if (req.method != .GET and req.method != .POST) return methodNotAllowed(req, "GET, POST");

    const a = req.a;
    // A GET carries its parameters in the query, a POST in the form body.
    const source = if (req.method == .POST) req.body else req.query;
    const client_id = (try auth.formValue(a, source, "client_id")) orelse "";
    const redirect_uri = (try auth.formValue(a, source, "redirect_uri")) orelse "";
    const state = (try auth.formValue(a, source, "state")) orelse "";

    // A redirect URI is only ever trusted once it has been matched against the
    // one the client registered.
    const registered = g.tokens.clientRedirects(client_id) orelse {
        return authorizeError(req, "invalid_request", "the client is not registered, or the redirect_uri was not one of its own");
    };
    var known = false;
    for (registered) |uri| {
        if (std.mem.eql(u8, uri, redirect_uri)) known = true;
    }
    if (!known) {
        return authorizeError(req, "invalid_request", "the client is not registered, or the redirect_uri was not one of its own");
    }

    const response_type = (try auth.formValue(a, source, "response_type")) orelse "";
    if (!std.mem.eql(u8, response_type, "code")) {
        return authorizeRedirectError(req, redirect_uri, state, "unsupported_response_type", "only response_type=code is supported");
    }
    const challenge = (try auth.formValue(a, source, "code_challenge")) orelse "";
    const method = (try auth.formValue(a, source, "code_challenge_method")) orelse "";
    if (challenge.len == 0 or !std.mem.eql(u8, method, "S256")) {
        return authorizeRedirectError(req, redirect_uri, state, "invalid_request", "PKCE with code_challenge_method=S256 is required");
    }

    if (req.method == .GET) {
        var fields: std.ArrayList(server.Header) = .empty;
        for ([_][]const u8{ "client_id", "redirect_uri", "response_type", "code_challenge", "code_challenge_method", "scope", "state" }) |name| {
            const value = (try auth.formValue(a, source, name)) orelse "";
            try fields.append(a, .{ .name = name, .value = value });
        }
        const page = try auth.consentPage(a, client_id, redirect_uri, fields.items);
        try req.respond(.{ .content_type = "text/html; charset=utf-8", .body = page });
        return;
    }

    const code = g.tokens.newCode(.{
        .client_id = client_id,
        .redirect_uri = redirect_uri,
        .challenge = challenge,
        .scope = auth.auth_scope,
        .expires_at = 0,
    }, auth.now(g.io)) catch {
        return authorizeRedirectError(req, redirect_uri, state, "server_error", "the code could not be issued");
    };

    g.note("", "authorized an OAuth client", false);
    g.changed();
    const target = try auth.withQuery(a, redirect_uri, &.{
        .{ .name = "code", .value = code },
        .{ .name = "state", .value = state },
    });
    try req.respond(.{ .status = .found, .content_type = null, .headers = &.{.{ .name = "location", .value = target }} });
}

/// Exchanges a code, or a refresh token, for an access token.
fn handleToken(g: *gateway_mod.Gateway, req: *server.Request) !void {
    if (req.method != .POST) return methodNotAllowed(req, "POST");

    const a = req.a;
    const client_id = (try auth.formValue(a, req.body, "client_id")) orelse "";
    const grant = (try auth.formValue(a, req.body, "grant_type")) orelse "";

    if (std.mem.eql(u8, grant, "authorization_code")) return exchangeCode(g, req, client_id);
    if (!std.mem.eql(u8, grant, "refresh_token")) {
        return oauthError(req, .bad_request, "unsupported_grant_type", "only authorization_code and refresh_token are supported");
    }

    const refresh = (try auth.formValue(a, req.body, "refresh_token")) orelse "";
    const issued = g.tokens.renew(refresh, client_id, auth.now(g.io)) catch {
        return oauthError(req, .bad_request, "invalid_grant", "the refresh token is not valid for this client");
    };
    return tokenResponse(req, issued.access, null, issued.expires_at - auth.now(g.io));
}

/// Turns an authorization code into tokens, checking that the code went to the
/// client that asked for it and that PKCE matches. The code is taken before
/// anything is checked, so a failed attempt burns it: an attacker who
/// intercepted a code but not the verifier gets one guess.
fn exchangeCode(g: *gateway_mod.Gateway, req: *server.Request, client_id: []const u8) !void {
    const a = req.a;
    const code = (try auth.formValue(a, req.body, "code")) orelse "";
    const record = g.tokens.takeCode(code, auth.now(g.io)) orelse {
        return oauthError(req, .bad_request, "invalid_grant", "the code is unknown, expired or already used");
    };
    if (!std.mem.eql(u8, record.client_id, client_id)) {
        return oauthError(req, .bad_request, "invalid_grant", "the code was issued to another client");
    }
    const redirect_uri = (try auth.formValue(a, req.body, "redirect_uri")) orelse "";
    if (!std.mem.eql(u8, record.redirect_uri, redirect_uri)) {
        return oauthError(req, .bad_request, "invalid_grant", "the redirect_uri does not match the one the code was issued for");
    }
    const verifier = (try auth.formValue(a, req.body, "code_verifier")) orelse "";
    if (!auth.pkceMatches(verifier, record.challenge)) {
        return oauthError(req, .bad_request, "invalid_grant", "the code_verifier does not match the code_challenge");
    }

    const issued = g.tokens.issue(client_id, record.scope, auth.now(g.io)) catch {
        return oauthError(req, .internal_server_error, "server_error", "the token could not be issued");
    };
    g.note("", "issued an access token to an OAuth client", false);
    g.changed();
    return tokenResponse(req, issued.access, issued.refresh, issued.expires_at - auth.now(g.io));
}

fn tokenResponse(req: *server.Request, access: []const u8, refresh: ?[]const u8, expires_in: i64) !void {
    try req.respond(.{
        .headers = &.{.{ .name = "cache-control", .value = "no-store" }},
        .body = try auth.tokenResponse(req.a, access, refresh, expires_in),
    });
}

/// A page for a request that can never be redirected, because its redirect URI
/// was not trusted.
fn authorizeError(req: *server.Request, code: []const u8, description: []const u8) !void {
    try req.respond(.{
        .status = .bad_request,
        .content_type = "text/html; charset=utf-8",
        .body = try auth.authorizeErrorPage(req.a, code, description),
    });
}

/// Sends the failure back to the client, now that its redirect URI is known to
/// be trustworthy.
fn authorizeRedirectError(
    req: *server.Request,
    redirect_uri: []const u8,
    state: []const u8,
    code: []const u8,
    description: []const u8,
) !void {
    const target = try auth.withQuery(req.a, redirect_uri, &.{
        .{ .name = "error", .value = code },
        .{ .name = "error_description", .value = description },
        .{ .name = "state", .value = state },
    });
    try req.respond(.{ .status = .found, .content_type = null, .headers = &.{.{ .name = "location", .value = target }} });
}

/// RFC 6749's error response.
fn oauthError(req: *server.Request, status: std.http.Status, code: []const u8, description: []const u8) !void {
    try req.respond(.{
        .status = status,
        .headers = &.{.{ .name = "cache-control", .value = "no-store" }},
        .body = try auth.oauthError(req.a, code, description),
    });
}

fn methodNotAllowed(req: *server.Request, allowed: []const u8) !void {
    try req.respond(.{
        .status = .method_not_allowed,
        .content_type = "text/plain; charset=utf-8",
        .headers = &.{.{ .name = "allow", .value = allowed }},
        .body = "method not allowed",
    });
}
