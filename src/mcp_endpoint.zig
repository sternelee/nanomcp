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
    var io: Io = undefined;
    /// The gateway to record routes on: set when the endpoint is first used.
    var gateway_ptr: ?*gateway_mod.Gateway = null;
    /// No session has an identifier until it has posted a message.
    var counter: u64 = 0;

    pub fn nextId(a: std.mem.Allocator) ![]u8 {
        counter += 1;
        return std.fmt.allocPrint(a, "agent-{d}", .{counter});
    }

    /// One open event stream: the queue of messages waiting to go out on it.
    /// Every open stream, so that stopping the gateway can end them all
    /// instead of leaving a handler waiting on a client that is gone.
    var live: std.ArrayListUnmanaged(*Stream) = .empty;

    /// Ends every open stream: the handlers finish and release their work.
    pub fn closeAll() void {
        if (live.items.len == 0) return;
        const wake = io_for_close;
        // The handler takes this lock before it drops a stream, so none of
        // them can be freed while they are being woken.
        sessions.mu.lockUncancelable(wake);
        defer sessions.mu.unlock(wake);
        for (live.items) |stream| {
            stream.mu.lockUncancelable(wake);
            stream.closed = true;
            stream.cond.broadcast(wake);
            stream.mu.unlock(wake);
        }
        live = .empty;
    }

    /// The io the streams were opened with, for waking them.
    var io_for_close: Io = undefined;

    pub const Stream = struct {
        a: std.mem.Allocator,
        id: []const u8,
        mu: Io.Mutex = .init,
        cond: Io.Condition = .init,
        queue: std.ArrayList([]const u8) = .empty,
        closed: bool = false,
    };
};

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
    // its initialize, and is expected to send it back from then on.
    var track: []const u8 = req.header("mcp-session-id") orelse "";
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
    const a = req.a;
    const id = try @import("tokens.zig").randomToken(a, g.io);

    const stream = try a.create(sessions.Stream);
    stream.* = .{ .a = a, .id = id };
    sessions.io = g.io;
    sessions.io_for_close = g.io;
    sessions.mu.lockUncancelable(g.io);
    try sessions.map.put(a, id, stream);
    sessions.live.append(g.a, stream) catch {};
    sessions.mu.unlock(g.io);

    const out = try req.stream(.ok, "text/event-stream", &.{.{ .name = "cache-control", .value = "no-store" }});
    // The endpoint names the session, so the client knows where to post.
    try out.write(try std.fmt.allocPrint(a, "event: endpoint\ndata: /message?sessionId={s}\n\n", .{id}));

    // Everything posted to that endpoint is queued here, so this loop is what
    // carries every answer.
    while (true) {
        const next = take(stream, g.io) orelse break;
        try out.write(try std.fmt.allocPrint(a, "event: message\ndata: {s}\n\n", .{next}));
    }
    out.finish() catch {};

    sessions.mu.lockUncancelable(g.io);
    if (sessions.map.fetchRemove(id)) |_| {}
    for (sessions.live.items, 0..) |open, i| {
        if (open == stream) {
            _ = sessions.live.orderedRemove(i);
            break;
        }
    }
    sessions.mu.unlock(g.io);
    if (g.routes.remove(a, id)) |who| {
        g.note("", try std.fmt.allocPrint(a, "agent disconnected: {s}", .{who}), false);
    }
    stream.queue.deinit(a);
    a.destroy(stream);
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
    const stream = sessions.map.get(session_id);
    sessions.mu.unlock(g.io);
    const open = stream orelse {
        return req.respond(.{ .status = .not_found, .content_type = "text/plain; charset=utf-8", .body = "no such session" });
    };

    if (try answerTracked(g, a, req.body, session_id)) |body| {
        open.mu.lockUncancelable(g.io);
        open.queue.append(a, body) catch {};
        open.cond.broadcast(g.io);
        open.mu.unlock(g.io);
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
        return rpc.result(a, id, try initializeResult(a, g));
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

fn initializeResult(a: std.mem.Allocator, g: *gateway_mod.Gateway) !json.Value {
    var result: json.J = .object(a);
    result.put("protocolVersion", .str(a, rpc.latest_version));

    var tools_capability: json.J = .object(a);
    tools_capability.put("listChanged", .boolean(a, false));
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

    // A notification has nothing to answer.
    try std.testing.expect((try answerMessage(&g, a, try rpc.notification(a, "notifications/initialized", .null))) == null);

    // An unknown method is a protocol error, not a crash.
    const unknown = (try answerMessage(&g, a, try rpc.request(a, .{ .number = 2 }, "resources/list", .null))).?;
    const failed = rpc.Message.parse(a, unknown);
    try std.testing.expectEqual(rpc.method_not_found, failed.response.err.?.code);
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
