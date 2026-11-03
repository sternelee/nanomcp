//! The sign-in the gateway starts for an upstream that asks for one, and the
//! client it registers itself as: driven over real loopback sockets.
const std = @import("std");
const json = @import("json_util.zig");
const gateway_mod = @import("gateway.zig");
const gateway_views = @import("gateway_views.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const oauth = @import("oauth.zig");
const auth = @import("auth.zig");
const fixtures = @import("oauth_fixtures.zig");

const Status = gateway_mod.Status;
const upstream_token = fixtures.upstream_token;

test "an OAuth sign-in registers the gateway with the server and waits for the browser" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const upstream = try fixtures.FakeUpstream.start(std.testing.io);
    defer upstream.stop();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{.{
        .id = "s1",
        .name = "Protected",
        .alias = "protected",
        .transport = .http,
        .url = try upstream.mcpUrl(a),
        .oauth = true,
        .enabled = true,
    }});
    defer f.stop();

    // The server answers 401 with a metadata URL, so the gateway registers
    // itself and hands the browser an authorization URL.
    const url = try oauth.beginAuth(&f.g, a, "s1");
    try std.testing.expect(url.len > 0);
    try std.testing.expectEqual(@as(usize, 1), upstream.registrations);

    const query = try fixtures.queryOf(url);
    try std.testing.expectEqualStrings("registered-client", (try auth.queryValue(a, query, "client_id")).?);
    try std.testing.expectEqualStrings("code", (try auth.queryValue(a, query, "response_type")).?);
    try std.testing.expectEqualStrings("S256", (try auth.queryValue(a, query, "code_challenge_method")).?);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "{s}/oauth/callback", .{f.base}),
        (try auth.queryValue(a, query, "redirect_uri")).?,
    );
    const challenge = (try auth.queryValue(a, query, "code_challenge")).?;
    try std.testing.expect(challenge.len > 0);

    // The registration is kept, so the next sign-in does not repeat it.
    try std.testing.expectEqualStrings("registered-client", oauth.clientCredentials(&f.g, a, "s1").client_id);

    // The sign-in is remembered under its state, with the verifier that
    // matches the challenge, and a state is only good once.
    const state = (try auth.queryValue(a, query, "state")).?;
    const entry = f.g.pending.take(a, state).?;
    try std.testing.expectEqualStrings("s1", entry.server_id);
    try std.testing.expectEqualStrings("registered-client", entry.client_id);
    try std.testing.expect(auth.pkceMatches(entry.verifier, challenge));
    try std.testing.expect(f.g.pending.take(a, state) == null);

    const events = try gateway_views.eventsOf(&f.g, a);
    try std.testing.expect(std.mem.indexOf(u8, events[events.len - 1].text, "waiting for sign-in") != null);
}

test "the browser's callback stores the token and connects the server" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const upstream = try fixtures.FakeUpstream.start(std.testing.io);
    defer upstream.stop();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{.{
        .id = "s1",
        .name = "Protected",
        .alias = "protected",
        .transport = .http,
        .url = try upstream.mcpUrl(a),
        .oauth = true,
        .enabled = true,
    }});
    defer f.stop();

    const url = try oauth.beginAuth(&f.g, a, "s1");
    const state = (try auth.queryValue(a, try fixtures.queryOf(url), "state")).?;
    const callback = try std.fmt.allocPrint(a, "/oauth/callback?code=the-code&state={s}", .{state});

    // The browser comes back with a code, which the gateway exchanges.
    const answer = try f.request(.GET, callback, &.{}, null);
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    try std.testing.expect(std.mem.indexOf(u8, answer.body, "Signed in") != null);
    try std.testing.expectEqual(@as(usize, 1), upstream.tokens);

    // The token is kept under the server, and the server connects with it.
    try std.testing.expect(f.store.signedIn(a, "s1", auth.now(f.io)));
    const token = (try f.store.loadToken(a, "s1")).?;
    try std.testing.expectEqualStrings(upstream_token, token.access_token);
    try std.testing.expectEqualStrings("test-refresh-token", token.refresh_token.?);
    // The callback answers the browser before it connects the server, so the
    // connection lands a moment later.
    var waited: usize = 0;
    while (f.g.statusOf("s1") != .ready and waited < 300) : (waited += 1) {
        std.Io.sleep(f.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(Status.ready, f.g.statusOf("s1"));
    try std.testing.expectEqual(@as(usize, 1), f.g.toolCount("s1"));
    try std.testing.expectEqualStrings("Bearer " ++ upstream_token, upstream.sent.items);

    // The state is good once: coming back with it again changes nothing.
    const again = try f.request(.GET, callback, &.{}, null);
    try std.testing.expectEqual(@as(u16, 400), again.status);
    try std.testing.expect(std.mem.indexOf(u8, again.body, "expired") != null);
    try std.testing.expectEqual(@as(usize, 1), upstream.tokens);

    const events = try gateway_views.eventsOf(&f.g, a);
    var saw_signed_in = false;
    for (events) |e| {
        if (std.mem.indexOf(u8, e.text, "signed in") != null) saw_signed_in = true;
    }
    try std.testing.expect(saw_signed_in);
}

test "a callback that carries an error says what happened and keeps no token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const upstream = try fixtures.FakeUpstream.start(std.testing.io);
    defer upstream.stop();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{.{
        .id = "s1",
        .name = "Protected",
        .transport = .http,
        .url = try upstream.mcpUrl(a),
        .oauth = true,
        .enabled = true,
    }});
    defer f.stop();

    const url = try oauth.beginAuth(&f.g, a, "s1");
    const state = (try auth.queryValue(a, try fixtures.queryOf(url), "state")).?;
    const callback = try std.fmt.allocPrint(
        a,
        "/oauth/callback?error=access_denied&error_description=The+user+said+no&state={s}",
        .{state},
    );

    const answer = try f.request(.GET, callback, &.{}, null);
    try std.testing.expectEqual(@as(u16, 400), answer.status);
    try std.testing.expect(std.mem.indexOf(u8, answer.body, "access_denied: The user said no") != null);
    try std.testing.expect(!f.store.signedIn(a, "s1", auth.now(f.io)));
    try std.testing.expectEqual(@as(usize, 0), upstream.tokens);

    // The row says why the browser came back empty-handed, and the sign-in is
    // gone rather than left waiting.
    try std.testing.expectEqualStrings("sign-in failed: access_denied: The user said no", f.g.errorOf("s1"));
    try std.testing.expect(f.g.pending.take(a, state) == null);
}

test "a server that asks for authorization is recognized as needing a sign-in without OAuth in its configuration" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const upstream = try fixtures.FakeUpstream.start(std.testing.io);
    defer upstream.stop();

    // Nothing says this server is an OAuth one: the 401 does.
    const f = try fixtures.Serving.start(a, std.testing.io, &.{.{
        .id = "s1",
        .name = "Protected",
        .transport = .http,
        .url = try upstream.mcpUrl(a),
        .enabled = true,
    }});
    defer f.stop();

    f.g.sync() catch {};
    try std.testing.expectEqual(Status.needs_auth, f.g.statusOf("s1"));
    const view = (try gateway_views.serverOf(&f.g, "s1")).?;
    try std.testing.expect(!view.signed_in);
    // The interface is told, even though the configuration said nothing.
    const events = try gateway_views.eventsOf(&f.g, a);
    try std.testing.expect(std.mem.indexOf(u8, events[events.len - 1].text, "sign in required") != null);

    // And a sign-in can still be started for it.
    const url = try oauth.beginAuth(&f.g, a, "s1");
    try std.testing.expect(url.len > 0);
    const query = try fixtures.queryOf(url);
    try std.testing.expectEqualStrings("registered-client", (try auth.queryValue(a, query, "client_id")).?);
}

test "signing out forgets the token and the server asks for authorization again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const upstream = try fixtures.FakeUpstream.start(std.testing.io);
    defer upstream.stop();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{.{
        .id = "s1",
        .name = "Protected",
        .alias = "protected",
        .transport = .http,
        .url = try upstream.mcpUrl(a),
        .oauth = true,
        .enabled = true,
    }});
    defer f.stop();

    // The token a completed sign-in stores.
    const key = try credentials.CredentialStore.tokenKey(a, "s1");
    try f.store.set(key, "{\"access_token\":\"" ++ upstream_token ++ "\",\"token_type\":\"Bearer\"," ++
        "\"refresh_token\":\"a-refresh-token\",\"expires_in\":3600,\"expires_at\":0}");
    f.g.refreshCredentials();
    try std.testing.expect(f.store.signedIn(a, "s1", auth.now(f.io)));

    // The gateway connects, sends the token as a bearer header on every
    // request, and publishes the server's tool under its alias.
    try f.g.reconnect("s1");
    try std.testing.expectEqual(Status.ready, f.g.statusOf("s1"));
    try std.testing.expectEqual(@as(usize, 1), f.g.toolCount("s1"));
    try std.testing.expect((try gateway_views.serverOf(&f.g, "s1")).?.signed_in);
    try std.testing.expectEqualStrings("Bearer " ++ upstream_token, upstream.sent.items);
    const published = try f.g.tools.list(a);
    try std.testing.expectEqualStrings("protected__echo", published[0].name);

    // Signing out forgets the token, and the server goes back to asking.
    try oauth.signOut(&f.g, a, "s1");
    try std.testing.expect(!f.store.signedIn(a, "s1", auth.now(f.io)));
    try std.testing.expect(!(try gateway_views.serverOf(&f.g, "s1")).?.signed_in);
    try std.testing.expectEqual(Status.needs_auth, f.g.statusOf("s1"));
    try std.testing.expectEqual(@as(usize, 0), f.g.toolCount("s1"));
}

test "an expired upstream token is refreshed instead of failing the request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const upstream = try fixtures.FakeUpstream.start(std.testing.io);
    defer upstream.stop();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{.{
        .id = "s1",
        .name = "Protected",
        .alias = "protected",
        .transport = .http,
        .url = try upstream.mcpUrl(a),
        .oauth = true,
        .enabled = true,
    }});
    defer f.stop();

    // A token that expired long ago, with the refresh token and the client
    // registration a sign-in leaves behind.
    const key = try credentials.CredentialStore.tokenKey(a, "s1");
    try f.store.set(key, "{\"access_token\":\"stale-token\",\"token_type\":\"Bearer\"," ++
        "\"refresh_token\":\"test-refresh-token\",\"expires_in\":3600,\"expires_at\":1}");
    try f.store.saveClient(a, "s1", .{ .client_id = "registered-client" });

    // Connecting refreshes it first, so the request carries a token the
    // server still accepts.
    try f.g.reconnect("s1");
    try std.testing.expectEqual(Status.ready, f.g.statusOf("s1"));
    try std.testing.expectEqual(@as(usize, 1), upstream.refreshes);
    try std.testing.expectEqual(@as(usize, 0), upstream.tokens);
    try std.testing.expectEqualStrings("Bearer " ++ upstream_token, upstream.sent.items);

    // The fresh token replaces the stale one, and the refresh token the
    // response left out is the one already stored.
    const token = (try f.store.loadToken(a, "s1")).?;
    try std.testing.expectEqualStrings(upstream_token, token.access_token);
    try std.testing.expectEqualStrings("test-refresh-token", token.refresh_token.?);
    try std.testing.expect(token.expires_at > auth.now(f.io));
}

test "a server that does not sign in with OAuth cannot begin a flow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try fixtures.Serving.start(a, std.testing.io, &.{
        .{ .id = "s1", .name = "Files", .transport = .stdio, .command = "fs" },
        .{ .id = "s2", .name = "Headered", .transport = .http, .url = "http://127.0.0.1:1/mcp", .token_header = "X-Token" },
    });
    defer f.stop();

    // A stdio server has no browser to send anywhere, and a server with a
    // configured token header never asks anyone to sign in.
    try std.testing.expectError(error.NotOAuth, oauth.beginAuth(&f.g, a, "s1"));
    try std.testing.expectError(error.NotOAuth, oauth.beginAuth(&f.g, a, "s2"));
    try std.testing.expectError(error.NoSuchServer, oauth.beginAuth(&f.g, a, "ghost"));

    // A gateway that is not serving has no callback URL to hand over.
    var cfg = config.Config.default();
    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();
    var g = gateway_mod.Gateway.init(a, std.testing.io, &cfg, &store, "0.1.0");
    defer _ = g.deinit();
    try cfg.upsert(a, .{ .id = "s1", .name = "Protected", .transport = .http, .url = "http://127.0.0.1:1/mcp", .oauth = true });
    try std.testing.expectError(error.NotServing, oauth.beginAuth(&g, a, "s1"));
}
