//! The OAuth 2.1 client the gateway uses to sign in to a server that asks for
//! it: discovery of the authorization server, dynamic client registration, the
//! authorization URL, and the token exchange.
//!
//! Everything here is plain HTTP and JSON, so it can be exercised against a
//! local server in a test.
const std = @import("std");
const Io = std.Io;
const json = @import("json_util.zig");
const web = @import("http_client.zig");
const credentials = @import("credentials.zig");
const auth = @import("auth.zig");

/// The client name the gateway registers itself under.
pub const client_name = "nanomcp";

/// What discovery found.
pub const Discovery = struct {
    /// The issuer the metadata was fetched for.
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    /// Empty when the authorization server does not register clients on
    /// demand, in which case the user supplies a client ID.
    registration_endpoint: []const u8 = "",
    /// The scope to ask for, empty when the server advertises none.
    scope: []const u8 = "",
};

pub const Error = error{
    NoMetadata,
    BadMetadata,
    Refused,
    OutOfMemory,
};

/// Finds the authorization server of a resource that answered 401.
///
/// The challenge names the resource metadata document when the server
/// publishes one (RFC 9728); otherwise the well-known path of the resource's
/// own origin is tried, which is where the specification says it lives.
pub fn discover(
    a: std.mem.Allocator,
    client: *web.Client,
    resource_url: []const u8,
    wanted: []const u8,
) !Discovery {
    const urls = try resourceMetadataURLs(a, resource_url, wanted);
    var document: json.Value = undefined;
    var found = false;
    for (urls) |metadata_url| {
        const answer = client.send(.GET, metadata_url, &.{}, null) catch continue;
        if (!answer.ok()) continue;
        document = json.parse(a, answer.body) catch continue;
        found = true;
        break;
    }
    if (!found) return error.NoMetadata;

    // The metadata names the authorization servers this resource trusts.
    const servers = json.getArray(document, "authorization_servers");
    const issuer = if (servers) |list|
        if (list.items.len > 0) switch (list.items[0]) {
            .string => |s| s,
            else => try origin(a, resource_url),
        } else try origin(a, resource_url)
    else
        try origin(a, resource_url);

    const metadata = try authServerMetadata(a, client, issuer);
    // The resource says which scopes it wants; asking for only the first one
    // its authorization server supports would leave tools that need the
    // others (Linear's write access among them) out of reach.
    const scope = (try scopesText(a, document)) orelse
        (if (parameter(wanted, "scope")) |asked| try a.dupe(u8, asked) else metadata.scope);
    return .{
        .issuer = issuer,
        .authorization_endpoint = metadata.authorization_endpoint,
        .token_endpoint = metadata.token_endpoint,
        .registration_endpoint = metadata.registration_endpoint,
        .scope = scope,
    };
}

/// Every scope a document lists, joined as an authorization request wants
/// them. Null when it names none.
fn scopesText(a: std.mem.Allocator, document: json.Value) !?[]const u8 {
    const scopes = json.getArray(document, "scopes_supported") orelse return null;
    var out: std.ArrayList(u8) = .empty;
    for (scopes.items) |item| {
        if (item != .string) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, item.string);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(a);
}

/// The resource metadata URLs to try, the challenge's own first. RFC 9728
/// mounts the well-known path before the resource's path; some deployments
/// publish it at the bare origin instead, which is tried second.
fn resourceMetadataURLs(a: std.mem.Allocator, resource_url: []const u8, challenge: []const u8) ![]const []const u8 {
    if (parameter(challenge, "resource_metadata")) |named| {
        const one = try a.alloc([]const u8, 1);
        one[0] = try a.dupe(u8, named);
        return one;
    }
    const base = try origin(a, resource_url);
    const path = pathOf(resource_url);
    var out: std.ArrayList([]const u8) = .empty;
    if (path.len > 1 and !std.mem.eql(u8, path, "/")) {
        try out.append(a, try std.fmt.allocPrint(a, "{s}/.well-known/oauth-protected-resource{s}", .{ base, path }));
    }
    try out.append(a, try std.fmt.allocPrint(a, "{s}/.well-known/oauth-protected-resource", .{base}));
    return out.toOwnedSlice(a);
}

/// The path of a URL, without its query or fragment. Empty when it has none.
fn pathOf(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[scheme_end + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "";
    const tail = rest[slash..];
    const end = std.mem.indexOfAny(u8, tail, "?#") orelse tail.len;
    return tail[0..end];
}

/// The resource metadata URL, from the challenge when it names one.
fn resourceMetadataURL(a: std.mem.Allocator, resource_url: []const u8, challenge: []const u8) ![]u8 {
    if (parameter(challenge, "resource_metadata")) |named| return a.dupe(u8, named);
    return std.fmt.allocPrint(a, "{s}/.well-known/oauth-protected-resource", .{try origin(a, resource_url)});
}

/// Reads a `name="value"` parameter out of a challenge header.
pub fn parameter(challenge: []const u8, name: []const u8) ?[]const u8 {
    var rest = challenge;
    while (std.mem.indexOf(u8, rest, name)) |at| {
        const after = rest[at + name.len ..];
        const trimmed = std.mem.trimStart(u8, after, " \t=");
        if (trimmed.len > 0 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
            const quote = trimmed[0];
            const body = trimmed[1..];
            if (std.mem.indexOfScalar(u8, body, quote)) |end| return body[0..end];
        }
        rest = after;
    }
    return null;
}

/// The scheme and host of a URL: what a well-known path hangs off.
pub fn origin(a: std.mem.Allocator, url: []const u8) ![]u8 {
    const parsed = std.Uri.parse(url) catch return a.dupe(u8, url);
    const scheme = parsed.scheme;
    const host = parsed.host orelse return a.dupe(u8, url);
    const component = switch (host) {
        .raw => |raw| raw,
        .percent_encoded => |text| text,
    };
    if (parsed.port) |port| {
        return std.fmt.allocPrint(a, "{s}://{s}:{d}", .{ scheme, component, port });
    }
    return std.fmt.allocPrint(a, "{s}://{s}", .{ scheme, component });
}

const ServerMetadata = struct {
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: []const u8 = "",
    scope: []const u8 = "",
};

/// RFC 8414 metadata, at the well-known path of the issuer.
fn authServerMetadata(a: std.mem.Allocator, client: *web.Client, issuer: []const u8) !ServerMetadata {
    const paths = [_][]const u8{
        "/.well-known/oauth-authorization-server",
        "/.well-known/openid-configuration",
    };
    for (paths) |path| {
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ issuer, path });
        const answer = client.send(.GET, url, &.{}, null) catch continue;
        if (!answer.ok()) continue;
        const document = json.parse(a, answer.body) catch continue;
        const authorization_endpoint = json.getString(document, "authorization_endpoint") orelse continue;
        const token_endpoint = json.getString(document, "token_endpoint") orelse continue;
        var scope: []const u8 = "";
        if (json.getArray(document, "scopes_supported")) |scopes| {
            if (scopes.items.len > 0) {
                if (scopes.items[0] == .string) scope = scopes.items[0].string;
            }
        }
        return .{
            .authorization_endpoint = authorization_endpoint,
            .token_endpoint = token_endpoint,
            .registration_endpoint = json.getString(document, "registration_endpoint") orelse "",
            .scope = scope,
        };
    }
    return error.NoMetadata;
}

/// Registers the gateway as a public client, which is what a local app is: it
/// cannot keep a secret, so it proves itself with PKCE instead.
pub fn registerClient(
    a: std.mem.Allocator,
    client: *web.Client,
    discovery: Discovery,
    redirect_uri: []const u8,
    name: []const u8,
) !credentials.ClientCredentials {
    if (discovery.registration_endpoint.len == 0) return error.Refused;

    var doc: json.J = .object(a);
    doc.put("client_name", .str(a, name));
    var uris: json.J = .array(a);
    uris.add(.str(a, redirect_uri));
    doc.put("redirect_uris", uris);
    var types: json.J = .array(a);
    types.add(.str(a, "authorization_code"));
    doc.put("grant_types", types);
    var responses: json.J = .array(a);
    responses.add(.str(a, "code"));
    doc.put("response_types", responses);
    var methods: json.J = .array(a);
    methods.add(.str(a, "none"));
    doc.put("token_endpoint_auth_methods_supported", methods);

    const payload = try doc.dump();
    const answer = client.send(.POST, discovery.registration_endpoint, &.{}, payload) catch return error.Refused;
    if (!answer.ok()) return error.Refused;
    const reply = json.parse(a, answer.body) catch return error.BadMetadata;
    const client_id = json.getString(reply, "client_id") orelse return error.BadMetadata;
    return .{
        .client_id = client_id,
        .secret = json.getString(reply, "client_secret"),
        .issuer = discovery.issuer,
        .auth_method = json.getString(reply, "token_endpoint_auth_method"),
    };
}

/// Where the user has to go to approve the sign-in.
pub fn authorizationUrl(
    a: std.mem.Allocator,
    discovery: Discovery,
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    verifier: []const u8,
    scope: []const u8,
) ![]u8 {
    const pairs = [_]auth.Pair{
        .{ .name = "response_type", .value = "code" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "state", .value = state },
        .{ .name = "code_challenge", .value = try pkceChallenge(a, verifier) },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "scope", .value = scope },
    };
    return auth.withQuery(a, discovery.authorization_endpoint, &pairs);
}

/// The PKCE challenge of a verifier: its SHA-256, base64url, unpadded.
pub fn pkceChallenge(a: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const out = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(32));
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &digest);
    return out;
}

/// Turns an authorization code into a token.
pub fn exchangeCode(
    a: std.mem.Allocator,
    io: Io,
    client: *web.Client,
    discovery: Discovery,
    client_id: []const u8,
    secret: []const u8,
    code: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
) !credentials.Token {
    const body = try formBody(a, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "code", .value = code },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "code_verifier", .value = verifier },
        .{ .name = "client_secret", .value = secret },
    });
    return tokenRequest(a, io, client, discovery, body, discovery.issuer);
}

/// Trades a refresh token for a fresh access token.
pub fn refresh(
    a: std.mem.Allocator,
    io: Io,
    client: *web.Client,
    discovery: Discovery,
    client_id: []const u8,
    secret: []const u8,
    refresh_token: []const u8,
) !credentials.Token {
    const body = try formBody(a, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "client_secret", .value = secret },
    });
    return tokenRequest(a, io, client, discovery, body, discovery.issuer);
}

fn tokenRequest(
    a: std.mem.Allocator,
    io: Io,
    client: *web.Client,
    discovery: Discovery,
    body: []const u8,
    issuer: []const u8,
) !credentials.Token {
    const answer = client.send(.POST, discovery.token_endpoint, &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
    }, body) catch return error.Refused;
    if (!answer.ok()) return error.Refused;
    const document = json.parse(a, answer.body) catch return error.BadMetadata;

    const access = json.getString(document, "access_token") orelse return error.BadMetadata;
    const expires_in = json.getInt(document, "expires_in") orelse 0;
    return .{
        .issuer = issuer,
        .access_token = access,
        .token_type = json.getString(document, "token_type") orelse "Bearer",
        .refresh_token = json.getString(document, "refresh_token"),
        .expires_in = expires_in,
        .scope = json.getString(document, "scope"),
        .expires_at = if (expires_in > 0) auth.now(io) + expires_in else 0,
    };
}

/// A form body, with every value escaped.
pub fn formBody(a: std.mem.Allocator, pairs: []const auth.Pair) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (pairs) |pair| {
        // A secret that is not there is left out entirely, so a public client
        // sends no client_secret at all.
        if (std.mem.eql(u8, pair.name, "client_secret") and pair.value.len == 0) continue;
        if (!first) try out.append(a, '&');
        first = false;
        try out.appendSlice(a, try auth.percentEncode(a, pair.name));
        try out.append(a, '=');
        try out.appendSlice(a, try auth.percentEncode(a, pair.value));
    }
    return out.toOwnedSlice(a);
}

test "the metadata url comes from the challenge, or from the resource's origin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "https://example.com/.well-known/oauth-protected-resource",
        try resourceMetadataURL(a, "https://example.com/mcp", ""),
    );
    try std.testing.expectEqualStrings(
        "https://as.example/prm",
        try resourceMetadataURL(
            a,
            "https://example.com/mcp",
            "Bearer resource_metadata=\"https://as.example/prm\", error=\"invalid_token\"",
        ),
    );
    try std.testing.expectEqualStrings("https://example.com:8443", try origin(a, "https://example.com:8443/mcp"));
    try std.testing.expectEqualStrings("http://127.0.0.1:7331", try origin(a, "http://127.0.0.1:7331/oauth/callback"));
}

test "resource metadata is tried at the resource's path, then at its origin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const urls = try resourceMetadataURLs(a, "https://example.com/mcp?x=1", "");
    try std.testing.expectEqual(@as(usize, 2), urls.len);
    try std.testing.expectEqualStrings("https://example.com/.well-known/oauth-protected-resource/mcp", urls[0]);
    try std.testing.expectEqualStrings("https://example.com/.well-known/oauth-protected-resource", urls[1]);

    // A challenge that names its metadata document is followed as it is.
    const named = try resourceMetadataURLs(
        a,
        "https://example.com/mcp",
        "Bearer resource_metadata=\"https://as.example/prm\"",
    );
    try std.testing.expectEqual(@as(usize, 1), named.len);
    try std.testing.expectEqualStrings("https://as.example/prm", named[0]);
}

test "every scope the resource supports is asked for" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const doc = try json.parse(a, "{\"scopes_supported\":[\"read\",\"write\"]}");
    try std.testing.expectEqualStrings("read write", (try scopesText(a, doc)).?);
    const none = try json.parse(a, "{}");
    try std.testing.expect((try scopesText(a, none)) == null);
}

test "a challenge parameter is read out of the header" {
    const header = "Bearer resource_metadata=\"https://as.example/prm\", error=\"invalid_token\"";
    try std.testing.expectEqualStrings("https://as.example/prm", parameter(header, "resource_metadata").?);
    try std.testing.expectEqualStrings("invalid_token", parameter(header, "error").?);
    try std.testing.expect(parameter(header, "scope") == null);
    try std.testing.expect(parameter("Bearer", "resource_metadata") == null);
}

test "the authorization url carries the state and the challenge" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const discovery: Discovery = .{
        .issuer = "https://as.example",
        .authorization_endpoint = "https://as.example/authorize",
        .token_endpoint = "https://as.example/token",
    };
    const url = try authorizationUrl(a, discovery, "cid", "http://127.0.0.1:7331/oauth/callback", "st", "ver", "mcp");
    try std.testing.expect(std.mem.startsWith(u8, url, "https://as.example/authorize?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "state=st") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A7331%2Foauth%2Fcallback") != null);

    // The challenge is the SHA-256 of the verifier, base64url, unpadded, and
    // it is what the token endpoint will check the verifier against.
    const expected = try pkceChallenge(a, "ver");
    try std.testing.expect(std.mem.indexOf(u8, url, expected) != null);
    try std.testing.expect(auth.pkceMatches("ver", expected));
    try std.testing.expect(!auth.pkceMatches("other", expected));
}

test "a form body leaves out a secret that is not there" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const public = try formBody(a, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "code", .value = "a b" },
        .{ .name = "client_secret", .value = "" },
    });
    try std.testing.expectEqualStrings("grant_type=authorization_code&code=a%20b", public);

    const confidential = try formBody(a, &.{
        .{ .name = "client_id", .value = "cid" },
        .{ .name = "client_secret", .value = "s" },
    });
    try std.testing.expectEqualStrings("client_id=cid&client_secret=s", confidential);
}

