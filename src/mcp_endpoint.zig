//! The MCP endpoint the gateway serves: JSON-RPC over streamable HTTP at /mcp,
//! and the older HTTP+SSE transport at /sse and /message. Both answer with the
//! aggregated tools.
const std = @import("std");
const Io = std.Io;
const json = @import("json_util.zig");
const rpc = @import("rpc.zig");
const server = @import("server.zig");
const gateway_mod = @import("gateway.zig");
const tools_mod = @import("tools.zig");
const gateway_views = @import("gateway_views.zig");

/// The sessions the older SSE transport keeps, keyed by the identifier in the
/// endpoint event.
pub const sessions = struct {
    var map: std.StringHashMapUnmanaged(*Stream) = .empty;
    var mu: Io.Mutex = .init;
    /// The allocator that owns the streams and everything queued on them.
    /// A stream outlives the request that opened it, so none of this may come
    /// from that request's arena.
    var owner: std.mem.Allocator = undefined;
    /// Every open stream, so that stopping the gateway can end them all
    /// instead of leaving a handler waiting on a client that is gone.
    var live: std.ArrayListUnmanaged(*Stream) = .empty;
    /// The io the streams were opened with, for waking them.
    var io_for_close: Io = undefined;

    /// Ends every open stream: the handlers finish and release their work.
    pub fn closeAll() void {
        const wake = io_for_close;
        // The handler takes this lock before it drops a stream, so none of
        // them can be freed while they are being woken.
        mu.lockUncancelable(wake);
        defer mu.unlock(wake);
        for (live.items) |stream| {
            stream.mu.lockUncancelable(wake);
            stream.closed = true;
            stream.cond.broadcast(wake);
            stream.mu.unlock(wake);
        }
        if (live.capacity > 0) live.clearAndFree(owner);
    }

    /// Frees the registry itself, once every handler has ended.
    pub fn deinit() void {
        if (map.capacity() > 0) {
            map.deinit(owner);
            map = .empty;
        }
        if (live.capacity > 0) live.clearAndFree(owner);
    }

    pub const Stream = struct {
        a: std.mem.Allocator,
        id: []const u8,
        mu: Io.Mutex = .init,
        cond: Io.Condition = .init,
        queue: std.ArrayList([]const u8) = .empty,
        closed: bool = false,

        /// Copies a message into the stream's own memory and queues it, so
        /// it outlives the request that produced it.
        pub fn enqueue(s: *Stream, io: Io, body: []const u8) !void {
            const copy = try s.a.dupe(u8, body);
            s.mu.lockUncancelable(io);
            if (s.closed) {
                s.mu.unlock(io);
                s.a.free(copy);
                return error.Closed;
            }
            s.queue.append(s.a, copy) catch |err| {
                s.mu.unlock(io);
                s.a.free(copy);
                return err;
            };
            s.cond.broadcast(io);
            s.mu.unlock(io);
        }
    };
};

/// Tells every open stream that the aggregated tools changed, so a client
/// knows to list them again. A stream that is closing is skipped.
pub fn notifyToolsChanged(g: *gateway_mod.Gateway) void {
    const body = rpc.notification(g.a, "notifications/tools/list_changed", .null) catch return;
    defer g.a.free(body);
    sessions.mu.lockUncancelable(g.io);
    defer sessions.mu.unlock(g.io);
    for (sessions.live.items) |stream| stream.enqueue(g.io, body) catch {};
}

/// Answers a streamable HTTP request: one JSON-RPC message in, one out.
pub fn handle(g: *gateway_mod.Gateway, req: *server.Request) !void {
    // A client that is done with its session ends it, as the Go gateway's
    // server unregisters a session that goes away.
    if (req.method == .DELETE) {
        if (req.header("mcp-session-id")) |id| {
            if (g.routes.remove(req.a, id)) |who| {
                g.note("", try std.fmt.allocPrint(req.a, "agent disconnected: {s}", .{who}), false);
            }
        }
        return req.respond(.{ .status = .no_content, .content_type = null });
    }
    if (req.method != .POST) {
        return req.respond(.{
            .status = .method_not_allowed,
            .content_type = "text/plain; charset=utf-8",
            .headers = &.{.{ .name = "allow", .value = "POST, DELETE" }},
            .body = "method not allowed",
        });
    }

    // The session names the route. A client that has none yet gets one with
    // its initialize, and is expected to send it back from then on. An
    // identifier the gateway never handed out is ignored, so a client cannot
    // fill the route table with names of its own.
    var track: []const u8 = req.header("mcp-session-id") orelse "";
    if (track.len > 128 or (track.len > 0 and !g.routes.known(track))) track = "";
    var reply_headers: []const server.Header = &.{};
    if (track.len == 0) {
        const message = rpc.Message.parse(req.a, req.body);
        switch (message) {
            .request => |request| if (std.mem.eql(u8, request.method, "initialize")) {
                const id = try @import("tokens.zig").randomToken(req.a, g.io);
                track = id;
                const headers = try req.a.alloc(server.Header, 1);
                headers[0] = .{ .name = "mcp-session-id", .value = id };
                reply_headers = headers;
            },
            else => {},
        }
        if (track.len == 0) track = anonymous;
    }

    const answer = try answerTracked(g, req.a, req.body, track);
    const body = answer orelse {
        // A notification has nothing to answer: 202 says it was taken.
        try req.respond(.{ .status = .accepted, .content_type = null, .headers = reply_headers });
        return;
    };
    try req.respond(.{ .body = body, .headers = reply_headers });
}

/// Opens the event stream of the older transport, which carries an endpoint for
/// the client to post its messages to, and then the answers to them.
pub fn handleSse(g: *gateway_mod.Gateway, req: *server.Request) !void {
    const id = try @import("tokens.zig").randomToken(req.a, g.io);

    // The stream serves this request for as long as the client stays, which
    // is far longer than the request's arena lives: it and its queue belong
    // to the gateway.
    sessions.owner = g.a;
    sessions.io_for_close = g.io;
    const stream = try sessions.owner.create(sessions.Stream);
    const owned_id = sessions.owner.dupe(u8, id) catch |err| {
        sessions.owner.destroy(stream);
        return err;
    };
    stream.* = .{ .a = sessions.owner, .id = owned_id };

    sessions.mu.lockUncancelable(g.io);
    sessions.map.put(sessions.owner, stream.id, stream) catch |err| {
        sessions.mu.unlock(g.io);
        sessions.owner.free(owned_id);
        sessions.owner.destroy(stream);
        return err;
    };
    sessions.live.append(sessions.owner, stream) catch {};
    sessions.mu.unlock(g.io);
    defer endStream(g, stream);

    const out = try req.stream(.ok, "text/event-stream", &.{.{ .name = "cache-control", .value = "no-store" }});
    // The endpoint names the session, so the client knows where to post.
    out.write("event: endpoint\ndata: /message?sessionId=") catch return;
    out.write(id) catch return;
    out.write("\n\n") catch return;

    // Everything posted to that endpoint is queued here, so this loop is what
    // carries every answer.
    while (true) {
        const next = take(stream, g.io) orelse break;
        defer stream.a.free(next);
        out.write("event: message\ndata: ") catch break;
        out.write(next) catch break;
        out.write("\n\n") catch break;
    }
    out.finish() catch {};
}

/// Removes a stream from the registry and frees everything it owns. The
/// registry lock is held throughout, so a POST that found the stream cannot
/// be queueing onto it while it is freed.
fn endStream(g: *gateway_mod.Gateway, stream: *sessions.Stream) void {
    sessions.mu.lockUncancelable(g.io);
    defer sessions.mu.unlock(g.io);

    if (sessions.map.fetchRemove(stream.id)) |kv| sessions.owner.free(kv.key);
    for (sessions.live.items, 0..) |open, i| {
        if (open == stream) {
            _ = sessions.live.orderedRemove(i);
            break;
        }
    }
    if (g.routes.remove(stream.a, stream.id)) |who| {
        defer stream.a.free(who);
        g.note("", std.fmt.allocPrint(g.a, "agent disconnected: {s}", .{who}) catch "", false);
    }

    stream.mu.lockUncancelable(g.io);
    stream.closed = true;
    for (stream.queue.items) |m| stream.a.free(m);
    stream.queue.deinit(stream.a);
    stream.mu.unlock(g.io);
    stream.a.free(stream.id);
    stream.a.destroy(stream);
}

/// Takes one message from a stream's queue, waiting until there is one.
fn take(stream: *sessions.Stream, io: Io) ?[]const u8 {
    stream.mu.lockUncancelable(io);
    defer stream.mu.unlock(io);
    while (stream.queue.items.len == 0 and !stream.closed) {
        stream.cond.waitUncancelable(io, &stream.mu);
    }
    if (stream.queue.items.len == 0) return null;
    return stream.queue.orderedRemove(0);
}

/// Answers a message posted to the endpoint of an open stream.
pub fn handleMessage(g: *gateway_mod.Gateway, req: *server.Request) !void {
    if (req.method != .POST) {
        return req.respond(.{
            .status = .method_not_allowed,
            .content_type = "text/plain; charset=utf-8",
            .headers = &.{.{ .name = "allow", .value = "POST" }},
            .body = "method not allowed",
        });
    }

    const a = req.a;
    const session_id = (try @import("auth.zig").queryValue(a, req.query, "sessionId")) orelse "";

    sessions.mu.lockUncancelable(g.io);
    const known = sessions.map.get(session_id) != null;
    sessions.mu.unlock(g.io);
    if (!known) {
        return req.respond(.{ .status = .not_found, .content_type = "text/plain; charset=utf-8", .body = "no such session" });
    }

    if (try answerTracked(g, a, req.body, session_id)) |body| {
        // The body lives in this POST's arena, which ends when the handler
        // returns; the stream takes its own copy while the registry lock
        // keeps the stream from being freed mid-queue.
        sessions.mu.lockUncancelable(g.io);
        if (sessions.map.get(session_id)) |open| open.enqueue(g.io, body) catch {};
        sessions.mu.unlock(g.io);
    }
    try req.respond(.{ .status = .accepted, .content_type = null });
}

/// Answers one JSON-RPC message, or null when it was a notification. Whoever
/// is asking is recorded as a route: its identity when it introduces itself,
/// and every tool call it makes.
fn answerMessage(g: *gateway_mod.Gateway, a: std.mem.Allocator, body: []const u8) !?[]u8 {
    return answerTracked(g, a, body, anonymous);
}

fn answerTracked(g: *gateway_mod.Gateway, a: std.mem.Allocator, body: []const u8, track: []const u8) !?[]u8 {
    const message = rpc.Message.parse(a, body);
    switch (message) {
        .request => |request| {
            const now = @import("auth.zig").now(g.io);
            if (std.mem.eql(u8, request.method, "initialize")) {
                const identity = @import("sessions.zig").identityOf(request.params);
                if (g.routes.introduce(track, identity.client, identity.version, identity.protocol, now)) {
                    g.note("", try std.fmt.allocPrint(a, "agent connected: {s}", .{identity.client}), false);
                }
                g.changed();
            } else if (std.mem.eql(u8, request.method, "tools/call")) {
                g.routes.called(track, now);
                g.changed();
            }
        },
        else => {},
    }
    return switch (message) {
        .notification => null,
        .request => |request| try answerRequest(g, a, request),
        .response => null,
        .malformed => try rpc.failure(a, null, rpc.parse_error, "that is not a JSON-RPC message"),
    };
}

/// The route a message belongs to when its client has no session identifier
/// yet and it is not an initialize: all such messages share one.
const anonymous: []const u8 = "agent";

fn answerRequest(g: *gateway_mod.Gateway, a: std.mem.Allocator, request: rpc.Message.Request) ![]u8 {
    const id = request.id;
    if (std.mem.eql(u8, request.method, "initialize")) {
        return rpc.result(a, id, try initializeResult(a, g, request.params));
    }
    if (std.mem.eql(u8, request.method, "ping")) {
        return rpc.result(a, id, .{ .object = .empty });
    }
    if (std.mem.eql(u8, request.method, "tools/list")) {
        return rpc.result(a, id, try toolsList(a, g));
    }
    if (std.mem.eql(u8, request.method, "tools/call")) {
        return callTool(g, a, id, request.params);
    }
    return rpc.failure(a, id, rpc.method_not_found, "no such method");
}

fn initializeResult(a: std.mem.Allocator, g: *gateway_mod.Gateway, params: json.Value) !json.Value {
    const asked = json.getString(params, "protocolVersion") orelse "";
    var result: json.J = .object(a);
    result.put("protocolVersion", .str(a, rpc.negotiateVersion(asked)));

    var tools_capability: json.J = .object(a);
    tools_capability.put("listChanged", .boolean(a, true));
    var capabilities: json.J = .object(a);
    capabilities.put("tools", tools_capability);
    result.put("capabilities", capabilities);

    var info: json.J = .object(a);
    info.put("name", .str(a, "nanomcp"));
    info.put("version", .str(a, g.version));
    result.put("serverInfo", info);
    result.put("instructions", .str(a,
        "A gateway that aggregates the tools of several MCP servers. Tool names are prefixed with the server they come from."));
    return result.v;
}

fn toolsList(a: std.mem.Allocator, g: *gateway_mod.Gateway) !json.Value {
    const entries = try g.tools.list(a);
    var list: json.J = .array(a);
    for (entries) |entry| {
        var tool: json.J = .object(a);
        tool.put("name", .str(a, entry.name));
        tool.put("description", .str(a, entry.description));
        tool.put("inputSchema", .from(a, entry.schema));
        list.add(tool);
    }
    var result: json.J = .object(a);
    result.put("tools", list);
    return result.v;
}

/// Calls one tool. A tool that fails at its upstream is reported as a tool
/// error, so the calling model sees the failure and can react, rather than as a
/// protocol error.
fn callTool(g: *gateway_mod.Gateway, a: std.mem.Allocator, id: rpc.Id, params: json.Value) ![]u8 {
    const name = json.getString(params, "name") orelse "";
    const args = json.get(params, "arguments");

    // The gateway's own tool describes the servers, so it never reaches an
    // upstream.
    if (std.mem.eql(u8, name, tools_mod.meta_tool_name)) {
        const text = gateway_views.metaToolJSON(g, a) catch |err| return toolError(a, id, err);
        var answer: json.J = .object(a);
        answer.put("content", try textResult(a, text));
        answer.put("isError", .boolean(a, false));
        return rpc.result(a, id, answer.v);
    }

    const called = g.callTool(a, name, args) catch |err| return toolError(a, id, err);
    var result: json.J = .object(a);
    if (json.getArray(called, "content")) |content| {
        result.put("content", .from(a, .{ .array = content }));
    } else {
        result.put("content", try textResult(a, ""));
    }
    if (json.get(called, "structuredContent")) |structured| {
        result.put("structuredContent", .from(a, structured));
    }
    result.put("isError", .boolean(a, json.getBool(called, "isError") orelse false));
    return rpc.result(a, id, result.v);
}

fn toolError(a: std.mem.Allocator, id: rpc.Id, err: anyerror) ![]u8 {
    const text = switch (err) {
        error.UnknownTool => "that tool does not exist",
        error.NotConnected => "the server of that tool is not connected",
        else => "the tool failed",
    };
    var result: json.J = .object(a);
    result.put("content", try textResult(a, text));
    result.put("isError", .boolean(a, true));
    return rpc.result(a, id, result.v);
}

fn textResult(a: std.mem.Allocator, text: []const u8) !json.J {
    var content: json.J = .array(a);
    var block: json.J = .object(a);
    block.put("type", .str(a, "text"));
    block.put("text", .str(a, text));
    content.add(block);
    return content;
}

test "an initialize request is answered with the gateway's identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg_mod = @import("config.zig");
    const credentials = @import("credentials.zig");
    var cfg = cfg_mod.Config.default();
    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();
    var g = gateway_mod.Gateway.init(a, std.testing.io, &cfg, &store, "0.1.0");
    defer _ = g.deinit();

    var params: json.J = .object(a);
    params.put("protocolVersion", .str(a, rpc.latest_version));
    const body = try rpc.request(a, .{ .number = 1 }, "initialize", params.v);

    const answer = (try answerMessage(&g, a, body)).?;
    const message = rpc.Message.parse(a, answer);
    try std.testing.expect(message == .response);
    try std.testing.expect(message.response.err == null);
    const info = json.get(message.response.result, "serverInfo").?;
    try std.testing.expectEqualStrings("nanomcp", json.getString(info, "name").?);
    try std.testing.expectEqualStrings("0.1.0", json.getString(info, "version").?);
    try std.testing.expectEqualStrings(rpc.latest_version, json.getString(message.response.result, "protocolVersion").?);
    // The gateway announces tool-list changes, so a client may rely on them.
    const tools_capability = json.get(json.get(message.response.result, "capabilities").?, "tools").?;
    try std.testing.expect(json.getBool(tools_capability, "listChanged") orelse false);

    // A version the gateway speaks is answered as it was asked; one it does
    // not know falls back to the newest it does.
    for (rpc.supported_versions) |version| {
        var asked: json.J = .object(a);
        asked.put("protocolVersion", .str(a, version));
        const request = try rpc.request(a, .{ .number = 3 }, "initialize", asked.v);
        const answer_for = (try answerMessage(&g, a, request)).?;
        const answered = rpc.Message.parse(a, answer_for);
        try std.testing.expectEqualStrings(version, json.getString(answered.response.result, "protocolVersion").?);
    }
    var unknown_version: json.J = .object(a);
    unknown_version.put("protocolVersion", .str(a, "1999-01-01"));
    const asked_unknown = try rpc.request(a, .{ .number = 4 }, "initialize", unknown_version.v);
    const fell_back = rpc.Message.parse(a, (try answerMessage(&g, a, asked_unknown)).?);
    try std.testing.expectEqualStrings(rpc.latest_version, json.getString(fell_back.response.result, "protocolVersion").?);

    // A notification has nothing to answer.
    try std.testing.expect((try answerMessage(&g, a, try rpc.notification(a, "notifications/initialized", .null))) == null);

    // An unknown method is a protocol error, not a crash.
    const unknown = (try answerMessage(&g, a, try rpc.request(a, .{ .number = 2 }, "resources/list", .null))).?;
    const failed = rpc.Message.parse(a, unknown);
    try std.testing.expectEqual(rpc.method_not_found, failed.response.err.?.code);
}

test "a tool change is announced to every open stream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg_mod = @import("config.zig");
    const credentials = @import("credentials.zig");
    var cfg = cfg_mod.Config.default();
    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();
    var g = gateway_mod.Gateway.init(a, std.testing.io, &cfg, &store, "0.1.0");
    defer _ = g.deinit();

    // The registry is a global the other tests share, so this one borrows it
    // with a list of its own and puts it back untouched.
    var stream: sessions.Stream = .{ .a = a, .id = "open" };
    const saved_live = sessions.live;
    const saved_owner = sessions.owner;
    sessions.live = .empty;
    sessions.owner = a;
    defer {
        sessions.live.deinit(a);
        sessions.live = saved_live;
        sessions.owner = saved_owner;
        for (stream.queue.items) |queued| a.free(queued);
        stream.queue.deinit(a);
    }

    sessions.mu.lockUncancelable(g.io);
    try sessions.live.append(a, &stream);
    sessions.mu.unlock(g.io);

    notifyToolsChanged(&g);

    try std.testing.expectEqual(@as(usize, 1), stream.queue.items.len);
    const message = rpc.Message.parse(a, stream.queue.items[0]);
    try std.testing.expect(message == .notification);
    try std.testing.expectEqualStrings("notifications/tools/list_changed", message.notification.method);
}

test "the tool list is empty until a server is connected, and the meta tool answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg_mod = @import("config.zig");
    const credentials = @import("credentials.zig");
    var cfg = cfg_mod.Config.default();
    try cfg.upsert(a, .{ .id = "s1", .name = "Files", .transport = .stdio, .command = "fs" });
    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();
    var g = gateway_mod.Gateway.init(a, std.testing.io, &cfg, &store, "0.1.0");
    defer _ = g.deinit();

    const listed = (try answerMessage(&g, a, try rpc.request(a, .{ .number = 1 }, "tools/list", .null))).?;
    const message = rpc.Message.parse(a, listed);
    try std.testing.expectEqual(@as(usize, 0), json.getArray(message.response.result, "tools").?.items.len);

    var params: json.J = .object(a);
    params.put("name", .str(a, tools_mod.meta_tool_name));
    const called = (try answerMessage(&g, a, try rpc.request(a, .{ .number = 2 }, "tools/call", params.v))).?;
    const answer = rpc.Message.parse(a, called);
    try std.testing.expect(!json.getBool(answer.response.result, "isError").?);
    const blocks = json.getArray(answer.response.result, "content").?;
    const text = json.getString(blocks.items[0], "text").?;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Files\"") != null);

    // A tool nobody published is a tool error, not a protocol error.
    var missing: json.J = .object(a);
    missing.put("name", .str(a, "nobody__nothing"));
    const failed = (try answerMessage(&g, a, try rpc.request(a, .{ .number = 3 }, "tools/call", missing.v))).?;
    const refusal = rpc.Message.parse(a, failed);
    try std.testing.expect(json.getBool(refusal.response.result, "isError").?);
}

test "a message queued for an open stream outlives the request that produced it" {
    const gpa = std.testing.allocator;

    // The answer to a POST lives in that POST's arena, which is freed as soon
    // as the handler returns; the stream that will carry it is still open.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const post = arena_state.allocator();
    const body = try post.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}");

    var stream = sessions.Stream{ .a = gpa, .id = "agent-1" };
    defer {
        for (stream.queue.items) |m| gpa.free(m);
        stream.queue.deinit(gpa);
    }

    try stream.enqueue(std.testing.io, body);
    // The queue owns its own copy rather than the caller's buffer.
    try std.testing.expect(stream.queue.items[0].ptr != body.ptr);
    arena_state.deinit();
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", stream.queue.items[0]);
}

test "closing every stream frees the list that held them" {
    const gpa = std.testing.allocator;
    sessions.owner = gpa;
    sessions.io_for_close = std.testing.io;

    const stream = try gpa.create(sessions.Stream);
    stream.* = .{ .a = gpa, .id = "agent-1" };
    defer gpa.destroy(stream);

    try sessions.live.append(gpa, stream);
    sessions.closeAll();
    try std.testing.expectEqual(@as(usize, 0), sessions.live.items.len);
    try std.testing.expect(stream.closed);
}
