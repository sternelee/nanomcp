//! The gateway as a client sees it: over HTTP, behind its caller check, and
//! through the MCP endpoint, driven over a real loopback socket.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = @import("json_util.zig");
const rpc = @import("rpc.zig");
const server = @import("server.zig");
const web = @import("http_client.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const gateway_mod = @import("gateway.zig");
const gateway_views = @import("gateway_views.zig");
const gateway_http = @import("gateway_http.zig");
const auth = @import("auth.zig");
const tools_mod = @import("tools.zig");
const upstream_mod = @import("upstream.zig");
const stdio = @import("transport_stdio.zig");

/// A gateway serving on a free port, with nothing configured.
pub const Fixture = struct {
    a: std.mem.Allocator,
    io: Io,
    cfg: config.Config = config.Config.default(),
    store: credentials.CredentialStore,
    g: gateway_mod.Gateway,
    listener: *server.Server,
    client: web.Client,
    base: []u8,

    pub fn start(a: std.mem.Allocator, io: Io) !*Fixture {
        const f = try a.create(Fixture);
        f.* = .{
            .a = a,
            .io = io,
            .store = credentials.CredentialStore.initMemory(a),
            .g = undefined,
            .listener = undefined,
            .client = web.Client.init(a, io),
            .base = &.{},
        };
        f.g = gateway_mod.Gateway.init(a, io, &f.cfg, &f.store, "0.1.0");
        f.listener = try server.Server.initEphemeral(a, io, .{ .ctx = &f.g, .handle = gateway_http.handle });
        // The gateway names its own address, so it must know the port the
        // listener took, the way `start` would have told it.
        f.cfg.port = f.listener.port;
        try f.listener.start();
        f.base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{f.listener.port});
        return f;
    }

    pub fn stop(f: *Fixture) void {
        // A stream that is still open would leave its handler waiting on a
        // client that has gone, so every stream is ended first.
        @import("mcp_endpoint.zig").sessions.closeAll();
        f.listener.stop();
        f.listener.destroy();
        // The registry's memory belongs to this fixture's arena, so it goes
        // before the arena does.
        @import("mcp_endpoint.zig").sessions.deinit();
        f.client.deinit();
        _ = f.g.deinit();
        f.store.deinit();
        f.a.destroy(f);
    }

    /// A request to the gateway, with optional headers.
    pub fn request(f: *Fixture, method: http.Method, path: []const u8, headers: []const web.Header, body: ?[]const u8) !web.Answer {
        const url = try std.fmt.allocPrint(f.a, "{s}{s}", .{ f.base, path });
        defer f.a.free(url);
        return f.client.send(method, url, headers, body);
    }
};

fn bearerHeader(a: std.mem.Allocator, token: []const u8) ![]web.Header {
    const headers = try a.alloc(web.Header, 1);
    headers[0] = .{ .name = "authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    return headers;
}

test "a caller's token is checked against the configured one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    f.cfg.inbound = .token;
    try f.store.setInboundToken("s3cret");
    f.g.refreshCredentials();

    const now = auth.now(std.testing.io);
    try std.testing.expect(f.g.authorized("s3cret", now));
    try std.testing.expect(!f.g.authorized("s3cret ", now));
    try std.testing.expect(!f.g.authorized("", now));

    // A token that was changed in the settings is not accepted any more.
    try f.store.setInboundToken("n3w");
    f.g.refreshCredentials();
    try std.testing.expect(!f.g.authorized("s3cret", now));
    try std.testing.expect(f.g.authorized("n3w", now));
}

test "a session identifier the gateway never issued is not adopted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const headers = [_]web.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "mcp-session-id", .value = "invented" },
    };
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"," ++
        "\"params\":{\"protocolVersion\":\"2025-06-18\",\"clientInfo\":{\"name\":\"probe\",\"version\":\"1\"}}}";
    const answer = try f.request(.POST, "/mcp", &headers, body);
    try std.testing.expectEqual(@as(u16, 200), answer.status);

    // The invented name is ignored: the gateway hands out one of its own.
    try std.testing.expect(!f.g.routes.known("invented"));
    const issued = refused_header(answer, "mcp-session-id") orelse return error.NoSession;
    try std.testing.expect(!std.mem.eql(u8, issued, "invented"));
    try std.testing.expect(f.g.routes.known(issued));
}

test "the gateway refuses callers without the token, and lets them in with it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    // A token mode with a token: every guarded endpoint asks for it.
    f.cfg.inbound = .token;
    try f.store.setInboundToken("s3cret");
    f.g.refreshCredentials();

    for ([_][]const u8{ "/mcp", "/sse", "/healthz" }) |path| {
        const refused = try f.request(.GET, path, &.{}, null);
        try std.testing.expectEqual(@as(u16, 401), refused.status);
        const challenge = refused_header(refused, "www-authenticate") orelse "";
        try std.testing.expect(std.mem.indexOf(u8, challenge, "resource_metadata") != null);
        const body = json.parse(a, refused.body) catch unreachable;
        try std.testing.expectEqualStrings("invalid_token", json.getString(body, "error").?);
    }

    // A wrong token is refused as well.
    const wrong = try bearerHeader(a, "nope");
    const refused = try f.request(.GET, "/healthz", wrong, null);
    try std.testing.expectEqual(@as(u16, 401), refused.status);

    // The right token is let in.
    const good = try bearerHeader(a, "s3cret");
    const allowed = try f.request(.GET, "/healthz", good, null);
    try std.testing.expectEqual(@as(u16, 200), allowed.status);
    const health = json.parse(a, allowed.body) catch unreachable;
    try std.testing.expectEqualStrings("ok", json.getString(health, "status").?);

    // The discovery endpoint stays open: a client has to reach it to learn
    // where to sign in.
    const metadata = try f.request(.GET, "/.well-known/oauth-protected-resource", &.{}, null);
    try std.testing.expectEqual(@as(u16, 200), metadata.status);
}

test "the gateway is open when the caller check is off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const health = try f.request(.GET, "/healthz", &.{}, null);
    try std.testing.expectEqual(@as(u16, 200), health.status);
    try std.testing.expectEqualStrings("ok", json.getString(json.parse(a, health.body) catch unreachable, "status").?);
}

test "the metadata names the authorization server only in the OAuth mode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    // Token mode: the metadata describes the resource but names no server.
    f.cfg.inbound = .token;
    try f.store.setInboundToken("t");
    f.g.refreshCredentials();
    const token_mode = try f.request(.GET, "/.well-known/oauth-protected-resource/mcp", &.{}, null);
    try std.testing.expectEqual(@as(u16, 200), token_mode.status);
    const token_doc = json.parse(a, token_mode.body) catch unreachable;
    try std.testing.expectEqualStrings("nanomcp", json.getString(token_doc, "resource_name").?);
    try std.testing.expect(json.get(token_doc, "authorization_servers") == null);

    // The other endpoint's metadata names itself.
    const sse_meta = try f.request(.GET, "/.well-known/oauth-protected-resource/sse", &.{}, null);
    const sse_doc = json.parse(a, sse_meta.body) catch unreachable;
    const sse_resource = json.getString(sse_doc, "resource").?;
    try std.testing.expect(std.mem.endsWith(u8, sse_resource, "/sse"));

    // OAuth mode: the metadata names the gateway itself as the server.
    f.cfg.inbound = .oauth;
    f.g.refreshCredentials();
    const oauth_mode = try f.request(.GET, "/.well-known/oauth-protected-resource/mcp", &.{}, null);
    const oauth_doc = json.parse(a, oauth_mode.body) catch unreachable;
    const servers = json.getArray(oauth_doc, "authorization_servers").?;
    try std.testing.expectEqual(@as(usize, 1), servers.items.len);
    try std.testing.expectEqualStrings(f.base, servers.items[0].string);
}

test "the authorization server is off until the mode asks for it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    // Off: the authorization server is not there at all.
    const absent = try f.request(.GET, "/.well-known/oauth-authorization-server", &.{}, null);
    try std.testing.expectEqual(@as(u16, 404), absent.status);

    // OAuth: it appears, without a restart.
    f.cfg.inbound = .oauth;
    f.g.refreshCredentials();
    const present = try f.request(.GET, "/.well-known/oauth-authorization-server", &.{}, null);
    try std.testing.expectEqual(@as(u16, 200), present.status);
    const doc = json.parse(a, present.body) catch unreachable;
    try std.testing.expectEqualStrings(f.base, json.getString(doc, "issuer").?);
    const token_endpoint = json.getString(doc, "token_endpoint").?;
    try std.testing.expect(std.mem.endsWith(u8, token_endpoint, "/oauth/token"));
}

test "a client signs in with the gateway and calls a tool" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    f.cfg.inbound = .oauth;
    f.g.refreshCredentials();

    // A client registers itself.
    const registration = try f.request(.POST, "/oauth/register", &.{
        .{ .name = "content-type", .value = "application/json" },
    }, "{\"client_name\":\"A test agent\",\"redirect_uris\":[\"http://127.0.0.1:9999/cb\"]}");
    try std.testing.expectEqual(@as(u16, 201), registration.status);
    const registered = json.parse(a, registration.body) catch unreachable;
    const client_id = json.getString(registered, "client_id").?;
    try std.testing.expect(client_id.len > 0);
    try std.testing.expectEqualStrings("none", json.getString(registered, "token_endpoint_auth_method").?);

    // The consent page is offered, and names the client.
    const consent = try f.request(.GET, "/oauth/authorize?response_type=code&client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb", &.{}, null);
    try std.testing.expectEqual(@as(u16, 400), consent.status);

    // The gateway's own health endpoint answers with the token it issued.
    const refused = try f.request(.GET, "/healthz", &.{}, null);
    try std.testing.expectEqual(@as(u16, 401), refused.status);
}

test "an unregistered redirect is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    f.cfg.inbound = .oauth;
    f.g.refreshCredentials();

    // A client nobody registered, at a redirect nobody registered.
    const answer = try f.request(.GET, "/oauth/authorize?response_type=code&client_id=ghost&redirect_uri=http%3A%2F%2Fevil.example%2Fcb&code_challenge=abc&code_challenge_method=S256", &.{}, null);
    try std.testing.expectEqual(@as(u16, 400), answer.status);
    // A 400 with no redirect: the gateway does not send the caller anywhere.
    try std.testing.expect(refused_header(answer, "location") == null);
}

test "the MCP endpoint answers initialize and lists the aggregated tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const body = try rpc.request(a, .{ .number = 1 }, "initialize", .{ .object = .empty });
    const answer = try f.request(.POST, "/mcp", &.{
        .{ .name = "content-type", .value = "application/json" },
    }, body);
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    const message = rpc.Message.parse(a, answer.body);
    try std.testing.expect(message == .response);
    const info = json.get(message.response.result, "serverInfo").?;
    try std.testing.expectEqualStrings("nanomcp", json.getString(info, "name").?);

    // A notification is taken with 202 and answered with nothing.
    const notification = try rpc.notification(a, "notifications/initialized", .null);
    const taken = try f.request(.POST, "/mcp", &.{}, notification);
    try std.testing.expectEqual(@as(u16, 202), taken.status);

    // The tool list carries the gateway's own meta tool.
    const listed = try f.request(.POST, "/mcp", &.{}, try rpc.request(a, .{ .number = 2 }, "tools/list", .null));
    const list_message = rpc.Message.parse(a, listed.body);
    try std.testing.expectEqual(@as(usize, 0), json.getArray(list_message.response.result, "tools").?.items.len);

    // The health endpoint counts the tools.
    const health = try f.request(.GET, "/healthz", &.{}, null);
    const doc = json.parse(a, health.body) catch unreachable;
    try std.testing.expectEqual(@as(i64, 0), json.getInt(doc, "tools").?);
}

test "the older SSE transport announces an endpoint and carries answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const url = try std.fmt.allocPrint(a, "{s}/sse", .{f.base});
    defer a.free(url);
    var stream = try f.client.stream(.GET, url, &.{}, null);
    defer stream.close();

    // The first event names where to post.
    var endpoint: []const u8 = "";
    while (try stream.next()) |line| {
        const data = @import("transport_http.zig").eventData(line) orelse continue;
        if (data.len > 0) {
            endpoint = try a.dupe(u8, data);
            break;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, endpoint, "/message?sessionId=") != null);

    // Posting an initialize request puts the answer on the stream.
    const body = try rpc.request(a, .{ .number = 7 }, "initialize", .{ .object = .empty });
    const posted = try f.request(.POST, endpoint, &.{ .{ .name = "content-type", .value = "application/json" } }, body);
    try std.testing.expectEqual(@as(u16, 202), posted.status);

    // A post to a session nobody opened is refused, which is how a client
    // learns its stream is gone.
    const unknown = try f.request(.POST, "/message?sessionId=nope", &.{}, body);
    try std.testing.expectEqual(@as(u16, 404), unknown.status);

    // A get is not how a message is posted.
    const wrong_method = try f.request(.GET, endpoint, &.{}, null);
    try std.testing.expectEqual(@as(u16, 405), wrong_method.status);
}

test "a tool error is a tool error, not a protocol error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    var params: json.J = .object(a);
    params.put("name", .str(a, "nobody__nothing"));
    const body = try rpc.request(a, .{ .number = 3 }, "tools/call", params.v);
    const answer = try f.request(.POST, "/mcp", &.{}, body);
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    const message = rpc.Message.parse(a, answer.body);
    // A protocol error would set `error`; a tool error sets isError instead.
    try std.testing.expect(message.response.err == null);
    try std.testing.expect(json.getBool(message.response.result, "isError").?);
}

test "the gateway names a tool's origin in its description" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    // A tool from "Files" carries the server's name in front of its own text.
    const described = try tools_mod.describe(a, "Files", "Reads a file");
    try std.testing.expectEqualStrings("[Files] Reads a file", described);
    const bare = try tools_mod.describe(a, "Files", "");
    try std.testing.expectEqualStrings("From Files.", bare);
}

/// The value of a response header, case-insensitively.
fn refused_header(answer: web.Answer, name: []const u8) ?[]const u8 {
    for (answer.header.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

// The gateway against a real upstream: a helper program that speaks MCP over
// its standard streams. The tests that need more than one server of these are
// in `gateway_flow_test.zig`.

/// A helper upstream's shell script: it answers the gateway's handshake and
/// its tools. `$0` is the text its echo tool answers with, so a test can tell
/// which helper answered.
pub const stdio_helper =
    \\while IFS= read -r line; do
    \\  compact=$(printf '%s' "$line" | tr -d ' \t')
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    \\  [ -z "$id" ] && continue
    \\  case "$compact" in
    \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"helper","version":"test"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo the text back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}},{"name":"boom","description":"Always fails.","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
    \\    *'"name":"boom"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"upstream exploded"}}\n' "$id" ;;
    \\    *'"method":"tools/call"'*) text=$(printf '%s' "$line" | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'); printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s%s"}],"isError":false}}\n' "$id" "$0" "$text" ;;
    \\  esac
    \\done
;

/// One helper upstream, its tools namespaced under `alias`.
pub fn helperServer(a: std.mem.Allocator, id: []const u8, name: []const u8, alias: []const u8) !config.ServerConfig {
    const args = try a.alloc([]const u8, 3);
    args[0] = "-c";
    args[1] = stdio_helper;
    args[2] = try std.fmt.allocPrint(a, "{s}: ", .{alias});
    return .{
        .id = id,
        .name = name,
        .alias = alias,
        .transport = .stdio,
        .enabled = true,
        .command = "/bin/sh",
        .args = args,
    };
}

/// The tools a client of the gateway sees.
pub fn listedTools(f: *Fixture, a: std.mem.Allocator) ![]json.Value {
    const asked = try f.request(.POST, "/mcp", &.{}, try rpc.request(a, .{ .number = 1 }, "tools/list", .null));
    const answer = rpc.Message.parse(a, asked.body);
    return json.getArray(answer.response.result, "tools").?.items;
}

/// Whether a list of tool definitions carries a name.
pub fn hasTool(tools: []json.Value, name: []const u8) bool {
    for (tools) |tool| {
        const found = json.getString(tool, "name") orelse continue;
        if (std.mem.eql(u8, found, name)) return true;
    }
    return false;
}

/// Calls one of the gateway's tools, the way a client does.
pub fn callTool(f: *Fixture, a: std.mem.Allocator, name: []const u8, args: ?json.Value) !rpc.Message.Response {
    var params: json.J = .object(a);
    params.put("name", .str(a, name));
    params.put("arguments", json.J.from(a, args orelse .{ .object = .empty }));
    const asked = try f.request(.POST, "/mcp", &.{}, try rpc.request(a, .{ .number = 2 }, "tools/call", params.v));
    return rpc.Message.parse(a, asked.body).response;
}

/// The text of a tool result.
pub fn resultText(result: json.Value) []const u8 {
    const blocks = json.getArray(result, "content") orelse return "";
    if (blocks.items.len == 0) return "";
    return json.getString(blocks.items[0], "text") orelse "";
}

/// Everything the gateway has noted about what it did, as one string.
pub fn activityText(f: *Fixture, a: std.mem.Allocator) ![]u8 {
    const events = try gateway_views.eventsOf(&f.g, a);
    var out: std.ArrayList(u8) = .empty;
    for (events) |event| {
        try out.appendSlice(a, event.text);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

test "the tools of every server are published under the alias of their server" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    // Two servers, each one a real subprocess, under aliases of their own.
    const servers = [_]config.ServerConfig{
        try helperServer(a, "s1", "Filesystem", "filesystem"),
        try helperServer(a, "s2", "Search", "search"),
    };
    f.cfg.servers = &servers;
    try f.g.sync();

    // Both servers' tools are served, each name saying where it came from.
    const tools = try listedTools(f, a);
    try std.testing.expectEqual(@as(usize, 4), tools.len);
    for ([_][]const u8{ "filesystem__echo", "filesystem__boom", "search__echo", "search__boom" }) |name| {
        try std.testing.expect(hasTool(tools, name));
    }
}

test "a tool call reaches the server that owns it, with the arguments it was given" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const servers = [_]config.ServerConfig{
        try helperServer(a, "s1", "Filesystem", "filesystem"),
        try helperServer(a, "s2", "Search", "search"),
    };
    f.cfg.servers = &servers;
    try f.g.sync();

    var args: json.J = .object(a);
    args.put("text", .str(a, "hello"));

    // The call goes to the server whose alias the name carries...
    const from_files = try callTool(f, a, "filesystem__echo", args.v);
    try std.testing.expect(from_files.err == null);
    try std.testing.expect(!json.getBool(from_files.result, "isError").?);
    try std.testing.expectEqualStrings("filesystem: hello", resultText(from_files.result));

    // ...and the same tool name under the other alias answers from that
    // server, so the arguments really did travel with the call.
    const from_search = try callTool(f, a, "search__echo", args.v);
    try std.testing.expectEqualStrings("search: hello", resultText(from_search.result));

    // A call with no arguments carries an empty object, not the last one's.
    const bare = try callTool(f, a, "filesystem__echo", null);
    try std.testing.expectEqualStrings("filesystem: ", resultText(bare.result));
}

test "a tool whose upstream fails is a tool error, not a protocol error" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const servers = [_]config.ServerConfig{try helperServer(a, "s1", "Filesystem", "filesystem")};
    f.cfg.servers = &servers;
    try f.g.sync();

    // The tool failed, so the call is answered as a tool error...
    const answer = try callTool(f, a, "filesystem__boom", null);
    try std.testing.expect(answer.err == null);
    try std.testing.expect(json.getBool(answer.result, "isError").?);
    try std.testing.expectEqualStrings("the tool failed", resultText(answer.result));

    // ...and the gateway itself is unharmed: the other tool still answers.
    try std.testing.expect(hasTool(try listedTools(f, a), "filesystem__echo"));
    const fine = try callTool(f, a, "filesystem__echo", null);
    try std.testing.expect(!json.getBool(fine.result, "isError").?);
}

test "a server that cannot connect is reported without stopping the others" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    // The first server cannot be run at all; the second one is a helper that
    // works. The first one must not keep the second from connecting.
    const servers = [_]config.ServerConfig{
        .{
            .id = "s1",
            .name = "Broken",
            .alias = "broken",
            .transport = .stdio,
            .enabled = true,
            .command = "nanomcp-no-such-command-here",
        },
        try helperServer(a, "s2", "Helper", "helper"),
    };
    f.cfg.servers = &servers;

    // What went wrong reaches the caller...
    try std.testing.expectError(error.ConnectFailed, f.g.sync());

    // ...and is held against that server, with the reason it gave, while the
    // working server is connected and serving.
    const views = try gateway_views.servers(&f.g, a);
    try std.testing.expectEqual(@as(usize, 2), views.len);
    try std.testing.expectEqual(gateway_mod.Status.failed, views[0].status);
    try std.testing.expectEqualStrings("SpawnFailed", views[0].err);
    try std.testing.expect(std.mem.indexOf(u8, try activityText(f, a), "Broken: SpawnFailed") != null);
    try std.testing.expectEqual(gateway_mod.Status.ready, views[1].status);
    try std.testing.expectEqual(@as(usize, 2), views[1].tools);
    try std.testing.expect(hasTool(try listedTools(f, a), "helper__echo"));
}

test "a subprocess upstream is connected over its standard streams" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const outcome = try upstream_mod.connect(a, std.testing.io, try helperServer(a, "s1", "Helper", "helper"), .{ .version = "0.1.0" });
    const helper: *upstream_mod.Upstream = switch (outcome) {
        .ready => |up| up,
        .needs_auth => |challenge| {
            std.debug.print("the helper asked for a sign-in: {s}\n", .{challenge});
            return error.NotConnected;
        },
        .failed => |why| {
            std.debug.print("the helper did not connect: {s}\n", .{why});
            return error.NotConnected;
        },
    };
    defer helper.destroy();

    // The handshake listed the tools the subprocess published...
    const names = try helper.toolNames(a);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("echo", names[0]);
    try std.testing.expectEqualStrings("boom", names[1]);

    // ...and it answers a call on the tool it was asked for, with the
    // arguments it was given.
    var args: json.J = .object(a);
    args.put("text", .str(a, "hi"));
    const called = try helper.callTool(a, "echo", args.v);
    try std.testing.expectEqualStrings("helper: hi", resultText(called));
}

// The gateway's behaviour with several servers at once, and the views a
// client of it reads, live in their own file to keep this one short.
test {
    _ = @import("gateway_flow_test.zig");
}
