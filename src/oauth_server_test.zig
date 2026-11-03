//! The gateway as its own authorization server: the authorization-server cases
//! of the Go original's auth_test.go, driven over real loopback sockets.
const std = @import("std");
const json = @import("json_util.zig");
const oauth_client = @import("oauth_client.zig");
const auth = @import("auth.zig");
const tokens = @import("tokens.zig");
const fixtures = @import("oauth_fixtures.zig");

const redirect_uri = fixtures.redirect_uri;
const authorizeFields = fixtures.authorizeFields;

test "the gateway registers a client, approves it, and issues tokens that open the gateway" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{});
    defer f.stop();
    f.serveAsAuthServer("s3cret");

    // A client registers itself, and gets an identifier and nothing else.
    const client = try f.register(a);
    try std.testing.expect(client.client_id.len > 0);

    // A GET shows the consent page; a POST hands out a code.
    const location = try f.approve(a, client.client_id, client.challenge, "the-state");
    try std.testing.expect(std.mem.startsWith(u8, location, redirect_uri));
    try std.testing.expectEqualStrings("127.0.0.1:9999", auth.hostOf(location));
    try std.testing.expectEqualStrings("the-state", (try auth.queryValue(a, try fixtures.queryOf(location), "state")).?);
    const code = try fixtures.codeOf(a, location);
    try std.testing.expect(code.len > 0);

    // The code becomes a token.
    const answer = try f.exchange(client.client_id, code, client.verifier);
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    const doc = try json.parse(a, answer.body);
    const access = json.getString(doc, "access_token").?;
    const refresh = json.getString(doc, "refresh_token").?;
    try std.testing.expect(access.len > 0);
    try std.testing.expect(refresh.len > 0);
    try std.testing.expectEqualStrings("Bearer", json.getString(doc, "token_type").?);
    try std.testing.expectEqualStrings("no-store", (try answer.headerValue(a, "cache-control")).?);

    // The access token opens the gateway.
    try std.testing.expectEqual(@as(u16, 200), (try f.request(.GET, "/healthz", try fixtures.bearerHeader(a, access), null)).status);

    // The code is spent: a second exchange is refused.
    const replayed = try f.exchange(client.client_id, code, client.verifier);
    try std.testing.expectEqual(@as(u16, 400), replayed.status);
    try std.testing.expectEqualStrings("invalid_grant", json.getString(try json.parse(a, replayed.body), "error").?);

    // A refresh token produces a fresh access token that also opens it.
    const refreshed_fields = [_]auth.Pair{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh },
        .{ .name = "client_id", .value = client.client_id },
    };
    const refreshed = try f.postForm("/oauth/token", &refreshed_fields);
    try std.testing.expectEqual(@as(u16, 200), refreshed.status);
    const renewed = json.getString(try json.parse(a, refreshed.body), "access_token").?;
    try std.testing.expect(!std.mem.eql(u8, renewed, access));
    try std.testing.expectEqual(@as(u16, 200), (try f.request(.GET, "/healthz", try fixtures.bearerHeader(a, renewed), null)).status);

    // Revoking the issued tokens leaves the configured one alone.
    f.g.tokens.revokeAll(auth.now(f.io));
    try std.testing.expectEqual(@as(u16, 401), (try f.request(.GET, "/healthz", try fixtures.bearerHeader(a, renewed), null)).status);
    try std.testing.expectEqual(@as(u16, 200), (try f.request(.GET, "/healthz", try fixtures.bearerHeader(a, "s3cret"), null)).status);
}

test "a form that never saw the consent page is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{});
    defer f.stop();
    f.serveAsAuthServer("s3cret");

    const client = try f.register(a);

    // A page open elsewhere can post the fields, but not the token the consent
    // page carried, so no code is handed out.
    const fields = authorizeFields(client.client_id, client.challenge, "the-state");
    const refused = try f.postForm("/oauth/authorize", &fields);
    try std.testing.expectEqual(@as(u16, 302), refused.status);
    const location = (try refused.headerValue(a, "location")).?;
    try std.testing.expect(std.mem.startsWith(u8, location, redirect_uri));
    try std.testing.expectEqualStrings("invalid_request", (try auth.queryValue(a, try fixtures.queryOf(location), "error")).?);
    try std.testing.expect((try auth.queryValue(a, try fixtures.queryOf(location), "code")) == null);

    // A made-up token is no better.
    var forged_fields: [fields.len + 1]auth.Pair = undefined;
    for (fields, 0..) |field, i| forged_fields[i] = field;
    forged_fields[fields.len] = .{ .name = "consent_token", .value = "made-up" };
    const forged = try f.postForm("/oauth/authorize", &forged_fields);
    try std.testing.expectEqual(@as(u16, 302), forged.status);
    try std.testing.expectEqualStrings("invalid_request", (try auth.queryValue(a, try fixtures.queryOf((try forged.headerValue(a, "location")).?), "error")).?);
}

test "a token exchange checks the proof, and a failed exchange burns the code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{});
    defer f.stop();
    f.serveAsAuthServer("s3cret");

    const client = try f.register(a);
    const code = try fixtures.codeOf(a, try f.approve(a, client.client_id, client.challenge, "the-state"));

    // The wrong verifier is refused, and the code is burnt on the way: an
    // attacker who intercepted the code gets one guess.
    const wrong = try f.exchange(client.client_id, code, "not-the-verifier");
    try std.testing.expectEqual(@as(u16, 400), wrong.status);
    try std.testing.expectEqualStrings("invalid_grant", json.getString(try json.parse(a, wrong.body), "error").?);

    const after = try f.exchange(client.client_id, code, client.verifier);
    try std.testing.expectEqual(@as(u16, 400), after.status);
    try std.testing.expectEqualStrings("invalid_grant", json.getString(try json.parse(a, after.body), "error").?);

    // A refresh token belongs to the client it was issued to.
    const mine = try f.register(a);
    const other = try f.register(a);
    try std.testing.expect(!std.mem.eql(u8, mine.client_id, other.client_id));
    const my_code = try fixtures.codeOf(a, try f.approve(a, mine.client_id, mine.challenge, "the-state"));
    const issued = try f.exchange(mine.client_id, my_code, mine.verifier);
    try std.testing.expectEqual(@as(u16, 200), issued.status);
    const refresh = json.getString(try json.parse(a, issued.body), "refresh_token").?;

    const stolen_fields = [_]auth.Pair{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh },
        .{ .name = "client_id", .value = other.client_id },
    };
    const stolen = try f.postForm("/oauth/token", &stolen_fields);
    try std.testing.expectEqual(@as(u16, 400), stolen.status);
    try std.testing.expectEqualStrings("invalid_grant", json.getString(try json.parse(a, stolen.body), "error").?);
}

test "an OAuth client signs in with the gateway's authorization server and opens it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{});
    defer f.stop();
    f.serveAsAuthServer("s3cret");

    // The client discovers the gateway's authorization server from its
    // protected-resource metadata, and registers itself.
    const discovery = try oauth_client.discover(a, &f.client, f.base, "");
    try std.testing.expectEqualStrings(f.base, discovery.issuer);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/oauth/token", .{f.base}), discovery.token_endpoint);
    const client = try oauth_client.registerClient(a, &f.client, discovery, redirect_uri, oauth_client.client_name);
    try std.testing.expect(client.client_id.len > 0);

    // The browser approves the authorization URL the client built.
    const verifier = try tokens.randomToken(a, f.io);
    const url = try oauth_client.authorizationUrl(a, discovery, client.client_id, redirect_uri, "the-state", verifier, discovery.scope);
    const page = try f.requestUrl(.GET, url, &.{}, null);
    try std.testing.expectEqual(@as(u16, 200), page.status);
    const visible = authorizeFields(client.client_id, try oauth_client.pkceChallenge(a, verifier), "the-state");
    var fields: [visible.len + 1]auth.Pair = undefined;
    for (visible, 0..) |field, i| fields[i] = field;
    fields[visible.len] = .{ .name = "consent_token", .value = try fixtures.consentTokenOf(page.body) };
    const approved = try f.postForm("/oauth/authorize", &fields);
    try std.testing.expectEqual(@as(u16, 302), approved.status);
    const code = try fixtures.codeOf(a, (try approved.headerValue(a, "location")).?);

    // The client exchanges the code for a token, which opens the gateway.
    const token = try oauth_client.exchangeCode(a, f.io, &f.client, discovery, client.client_id, "", code, verifier, redirect_uri);
    try std.testing.expect(token.access_token.len > 0);
    try std.testing.expectEqual(@as(u16, 200), (try f.request(.GET, "/healthz", try fixtures.bearerHeader(a, token.access_token), null)).status);
}
