//! Guarding the gateway, and being an authorization server for the agents that
//! sign in to it: the RFC 9728 metadata a client discovers, the dynamic
//! registration, the consent page, and the token exchange.
const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const json = @import("json_util.zig");
const tokens_mod = @import("tokens.zig");
const server = @import("server.zig");

/// The scope the gateway advertises and issues.
pub const auth_scope = "mcp";

/// The endpoints that are protected resources in their own right. A client
/// names the one it addressed in the metadata path, because RFC 9728 requires
/// the resource identifier it reads back to match the URL it used, and the
/// gateway serves tools at more than one URL.
pub const resource_paths = [_][]const u8{ "mcp", "sse" };

/// The endpoint a bare well-known request describes.
pub const default_resource_path = "mcp";

/// RFC 9728's well-known prefix.
pub const protected_resource_path = "/.well-known/oauth-protected-resource";

/// Where the metadata for one endpoint is served: the well-known path with the
/// endpoint appended.
pub fn metadataPath(a: std.mem.Allocator, resource_path: []const u8) ![]u8 {
    const path = if (resource_path.len > 0) resource_path else default_resource_path;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ protected_resource_path, path });
}

/// How the gateway is guarding itself, for the interface.
pub const AuthState = struct {
    mode: config.InboundMode,
    has_token: bool,
    issued_tokens: usize,
    /// Where an MCP client discovers how to sign in.
    metadata_url: []const u8,
    /// The gateway can issue tokens itself.
    authorization_server: bool,
};

/// The token a caller presented, from its Authorization header.
pub fn bearerToken(req: *const server.Request) []const u8 {
    const header = req.header("authorization") orelse return "";
    const space = std.mem.indexOfScalar(u8, header, ' ') orelse return "";
    const scheme = header[0..space];
    if (!std.ascii.eqlIgnoreCase(scheme, "bearer")) return "";
    return std.mem.trim(u8, header[space + 1 ..], " \t\r\n");
}

/// Compares two tokens without giving away their contents by how long the
/// comparison takes.
pub fn sameToken(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    var diff: u8 = 0;
    for (left, right) |l, r| diff |= l ^ r;
    return diff == 0;
}

/// Checks a PKCE verifier against the challenge the client sent.
pub fn pkceMatches(verifier: []const u8, challenge: []const u8) bool {
    if (verifier.len == 0 or challenge.len == 0) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var buf: [std.base64.url_safe_no_pad.Encoder.calcSize(32)]u8 = undefined;
    const expected = std.base64.url_safe_no_pad.Encoder.encode(&buf, &digest);
    return sameToken(expected, challenge);
}

/// Whether a redirect URI is one a browser may be sent to.
pub fn validRedirectURI(uri: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return false;
    const scheme = uri[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const rest = uri[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return host_end > 0;
}

/// The host of a URL, for showing where a browser is about to go.
pub fn hostOf(uri: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return "";
    const rest = uri[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return rest[0..host_end];
}

/// Names a client in the activity list.
pub fn describeClient(name: []const u8) []const u8 {
    return if (std.mem.trim(u8, name, " \t\r\n").len == 0) "(unnamed)" else name;
}

/// The JSON body of a refusal: RFC 6749's error shape.
pub fn oauthError(a: std.mem.Allocator, code: []const u8, description: []const u8) ![]u8 {
    var body: json.J = .object(a);
    body.put("error", .str(a, code));
    body.put("error_description", .str(a, description));
    return body.dump();
}

/// The HTML of a sign-in page that failed before anything could be redirected.
pub fn authorizeErrorPage(a: std.mem.Allocator, code: []const u8, description: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Sign-in failed</title></head>
        \\<body style="font:16px -apple-system,system-ui,sans-serif;margin:4rem auto;max-width:34rem;color:#b00020">
        \\<h1 style="font-size:1.25rem">Sign-in failed</h1><p>{s}: {s}</p></body></html>
    , .{ try escape(a, code), try escape(a, description) });
}

/// The page that asks the user to approve a client.
pub fn consentPage(
    a: std.mem.Allocator,
    client_id: []const u8,
    redirect_uri: []const u8,
    fields: []const server.Header,
) ![]u8 {
    var hidden: std.ArrayList(u8) = .empty;
    for (fields) |field| {
        if (field.value.len == 0) continue;
        try hidden.appendSlice(a, try std.fmt.allocPrint(
            a,
            "<input type=\"hidden\" name=\"{s}\" value=\"{s}\">\n",
            .{ try escape(a, field.name), try escape(a, field.value) },
        ));
    }
    return std.fmt.allocPrint(a,
        \\<!doctype html>
        \\<html lang="en">
        \\<head><meta charset="utf-8"><title>Authorize</title></head>
        \\<body style="font:16px -apple-system,system-ui,sans-serif;margin:4rem auto;max-width:34rem;color:#111">
        \\<h1 style="font-size:1.25rem">Allow this client to use nanomcp?</h1>
        \\<p>"<strong>{s}</strong>" wants to call the tools this gateway serves, and will be sent back to
        \\<code>{s}</code>.</p>
        \\<form method="post" action="/oauth/authorize">
        \\{s}<button type="submit" style="font:inherit;padding:.5rem 1rem">Authorize</button>
        \\</form>
        \\<p style="color:#555;font-size:.875rem">Only authorize a client you started yourself.</p>
        \\</body>
        \\</html>
    , .{ try escape(a, client_id), try escape(a, hostOf(redirect_uri)), hidden.items });
}

/// The page that ends a sign-in started from the servers page.
pub fn callbackPage(a: std.mem.Allocator, title: []const u8, message: []const u8, failed: bool) ![]u8 {
    const color = if (failed) "#b00020" else "#111";
    return std.fmt.allocPrint(a,
        \\<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{s}</title></head>
        \\<body style="font:16px -apple-system,system-ui,sans-serif;margin:4rem auto;max-width:34rem;color:{s}">
        \\<h1 style="font-size:1.25rem">{s}</h1><p style="color:#555">{s}</p></body></html>
    , .{ try escape(a, title), color, try escape(a, title), try escape(a, message) });
}

/// Escapes text for HTML, so a client's name cannot inject markup into a page
/// the user is looking at.
pub fn escape(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            '\'' => try out.appendSlice(a, "&#39;"),
            else => try out.append(a, c),
        }
    }
    return out.toOwnedSlice(a);
}

/// RFC 8414 metadata for the gateway acting as its own authorization server.
pub fn authServerMetadata(a: std.mem.Allocator, base: []const u8) ![]u8 {
    var doc: json.J = .object(a);
    doc.put("issuer", .str(a, base));
    doc.put("authorization_endpoint", .str(a, try std.fmt.allocPrint(a, "{s}/oauth/authorize", .{base})));
    doc.put("token_endpoint", .str(a, try std.fmt.allocPrint(a, "{s}/oauth/token", .{base})));
    doc.put("registration_endpoint", .str(a, try std.fmt.allocPrint(a, "{s}/oauth/register", .{base})));
    doc.put("response_types_supported", .strings(a, &.{"code"}));
    doc.put("grant_types_supported", .strings(a, &.{ "authorization_code", "refresh_token" }));
    doc.put("code_challenge_methods_supported", .strings(a, &.{"S256"}));
    doc.put("token_endpoint_auth_methods_supported", .strings(a, &.{"none"}));
    doc.put("scopes_supported", .strings(a, &.{auth_scope}));
    return doc.dump();
}

/// RFC 9728 metadata for the gateway itself. `resource_path` names the endpoint
/// being described, so the resource identifier matches the URL the client used.
pub fn protectedResourceMetadata(a: std.mem.Allocator, base: []const u8, resource_path: []const u8, oauth: bool) ![]u8 {
    const path = if (resource_path.len > 0) resource_path else default_resource_path;
    var doc: json.J = .object(a);
    doc.put("resource", .str(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ base, path })));
    doc.put("resource_name", .str(a, "nanomcp"));
    doc.put("bearer_methods_supported", .strings(a, &.{"header"}));
    doc.put("scopes_supported", .strings(a, &.{auth_scope}));
    // The gateway can only point clients at an authorization server when it is
    // one, which is the mode that lets them sign in.
    if (oauth) doc.put("authorization_servers", .strings(a, &.{base}));
    return doc.dump();
}

/// The RFC 6749 token response.
pub fn tokenResponse(a: std.mem.Allocator, access: []const u8, refresh: ?[]const u8, expires_in: i64) ![]u8 {
    var doc: json.J = .object(a);
    doc.put("access_token", .str(a, access));
    doc.put("token_type", .str(a, "Bearer"));
    doc.put("expires_in", .int(a, @max(0, expires_in)));
    doc.put("scope", .str(a, auth_scope));
    if (refresh) |r| doc.put("refresh_token", .str(a, r));
    return doc.dump();
}

/// What a registration endpoint answers with.
pub fn registrationResponse(
    a: std.mem.Allocator,
    client_id: []const u8,
    client_name: []const u8,
    redirect_uris: []const []const u8,
) ![]u8 {
    var doc: json.J = .object(a);
    doc.put("client_id", .str(a, client_id));
    doc.put("client_name", .str(a, client_name));
    var uris: json.J = .array(a);
    for (redirect_uris) |uri| uris.add(.str(a, uri));
    doc.put("redirect_uris", uris);
    doc.put("token_endpoint_auth_method", .str(a, "none"));
    doc.put("grant_types", .strings(a, &.{ "authorization_code", "refresh_token" }));
    doc.put("response_types", .strings(a, &.{"code"}));
    return doc.dump();
}

/// Appends query parameters to a URL, which is how a code or an error is
/// carried back to a client.
pub fn withQuery(a: std.mem.Allocator, url: []const u8, pairs: []const Pair) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, url);
    var sep: u8 = if (std.mem.indexOfScalar(u8, url, '?')) |_| '&' else '?';
    for (pairs) |pair| {
        if (pair.value.len == 0) continue;
        try out.append(a, sep);
        sep = '&';
        try out.appendSlice(a, pair.name);
        try out.append(a, '=');
        try out.appendSlice(a, try percentEncode(a, pair.value));
    }
    return out.toOwnedSlice(a);
}

pub const Pair = struct { name: []const u8, value: []const u8 };

/// Percent-encodes a query value.
pub fn percentEncode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try out.append(a, c),
            else => try out.print(a, "%{X:0>2}", .{c}),
        }
    }
    return out.toOwnedSlice(a);
}

/// Reads one field of a form body, percent-decoded.
pub fn formValue(a: std.mem.Allocator, body: []const u8, name: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return try decode(a, pair[eq + 1 ..]);
    }
    return null;
}

/// Reads one field of a query string, percent-decoded.
pub fn queryValue(a: std.mem.Allocator, query: []const u8, name: []const u8) !?[]u8 {
    return formValue(a, query, name);
}

fn decode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '%' => {
                if (i + 2 >= text.len) return out.toOwnedSlice(a);
                const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch {
                    try out.append(a, text[i]);
                    i += 1;
                    continue;
                };
                try out.append(a, byte);
                i += 3;
            },
            '+' => {
                try out.append(a, ' ');
                i += 1;
            },
            else => {
                try out.append(a, text[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(a);
}

/// The current time in seconds, which every token check needs.
pub fn now(io: Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

test "the metadata names the endpoint it was asked about" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const mcp = try json.parse(a, try protectedResourceMetadata(a, "http://127.0.0.1:7331", "mcp", true));
    try std.testing.expectEqualStrings("http://127.0.0.1:7331/mcp", json.getString(mcp, "resource").?);
    try std.testing.expectEqualStrings("nanomcp", json.getString(mcp, "resource_name").?);
    const servers = json.getArray(mcp, "authorization_servers").?;
    try std.testing.expectEqualStrings("http://127.0.0.1:7331", servers.items[0].string);

    // Without OAuth the gateway is not an authorization server, so it names
    // none.
    const bare = try json.parse(a, try protectedResourceMetadata(a, "http://127.0.0.1:7331", "", false));
    try std.testing.expect(json.get(bare, "authorization_servers") == null);
    try std.testing.expectEqualStrings("http://127.0.0.1:7331/mcp", json.getString(bare, "resource").?);

    try std.testing.expectEqualStrings(
        "/.well-known/oauth-protected-resource/sse",
        try metadataPath(a, "sse"),
    );
}

test "a bearer token is read from its header" {
    var headers = [_]server.Header{
        .{ .name = "Authorization", .value = "Bearer abc123" },
    };
    var req: server.Request = .{
        .a = std.testing.allocator,
        .io = std.testing.io,
        .raw = undefined,
        .method = .GET,
        .target = "/",
        .path = "/",
        .query = "",
        .headers = &headers,
        .body = "",
        .keep_alive = false,
    };
    try std.testing.expectEqualStrings("abc123", bearerToken(&req));

    headers[0].value = "bearer  spaced  ";
    try std.testing.expectEqualStrings("spaced", bearerToken(&req));

    headers[0].value = "Basic abc123";
    try std.testing.expectEqualStrings("", bearerToken(&req));

    headers[0].value = "abc123";
    try std.testing.expectEqualStrings("", bearerToken(&req));
}

test "PKCE compares the verifier with the challenge" {
    // The RFC 7636 example: verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    // hashes to "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM".
    try std.testing.expect(pkceMatches(
        "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
    ));
    try std.testing.expect(!pkceMatches("wrong", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
    try std.testing.expect(!pkceMatches("", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
}

test "only http redirect URIs are trusted" {
    try std.testing.expect(validRedirectURI("http://127.0.0.1:33418/callback"));
    try std.testing.expect(validRedirectURI("https://example.com/cb?x=1"));
    try std.testing.expect(!validRedirectURI("ftp://example.com/cb"));
    try std.testing.expect(!validRedirectURI("http:///cb"));
    try std.testing.expect(!validRedirectURI("127.0.0.1/cb"));
    try std.testing.expectEqualStrings("127.0.0.1:33418", hostOf("http://127.0.0.1:33418/callback"));
}

test "a form body and a query string are read the same way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const body = "grant_type=authorization_code&code=ab%2Bc&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb&empty=";
    try std.testing.expectEqualStrings("authorization_code", (try formValue(a, body, "grant_type")).?);
    try std.testing.expectEqualStrings("ab+c", (try formValue(a, body, "code")).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/cb", (try formValue(a, body, "redirect_uri")).?);
    try std.testing.expect((try formValue(a, body, "nothing")) == null);

    const encoded = try percentEncode(a, "a b&c");
    try std.testing.expectEqualStrings("a%20b%26c", encoded);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:1/cb?code=x%2By&state=s",
        try withQuery(a, "http://127.0.0.1:1/cb", &.{
            .{ .name = "code", .value = "x+y" },
            .{ .name = "state", .value = "s" },
        }),
    );
}

test "a page never lets a client inject markup" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const page = try consentPage(a, "<script>", "http://127.0.0.1:1/cb", &.{
        .{ .name = "client_id", .value = "abc" },
        .{ .name = "empty", .value = "" },
    });
    try std.testing.expect(std.mem.indexOf(u8, page, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Allow this client to use nanomcp?") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "name=\"client_id\" value=\"abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "name=\"empty\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, "127.0.0.1:1") != null);
}

test "the token response carries the lifetime it has left" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const doc = try json.parse(a, try tokenResponse(a, "at", "rt", 3600));
    try std.testing.expectEqualStrings("at", json.getString(doc, "access_token").?);
    try std.testing.expectEqualStrings("Bearer", json.getString(doc, "token_type").?);
    try std.testing.expectEqualStrings("rt", json.getString(doc, "refresh_token").?);
    try std.testing.expectEqual(@as(i64, 3600), json.getInt(doc, "expires_in").?);
    try std.testing.expectEqualStrings("mcp", json.getString(doc, "scope").?);

    // A refreshed token has no refresh token of its own to hand out.
    const renewed = try json.parse(a, try tokenResponse(a, "at2", null, 60));
    try std.testing.expect(json.get(renewed, "refresh_token") == null);
}
