//! A server on the network: MCP's Streamable HTTP, where every request is a
//! POST and the answer comes back as JSON or as a stream of events.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = @import("json_util.zig");
const session = @import("session.zig");
const web = @import("http_client.zig");

/// A connection to one server over HTTP.
pub const Http = struct {
    a: std.mem.Allocator,
    io: Io,
    client: web.Client,
    url: []const u8,
    /// The headers the server was configured with, copied.
    headers: []web.Header,
    /// Where the credential comes from, once a sign-in produced one.
    bearer: ?web.Bearer = null,
    /// What the last 401 said it wanted.
    challenge: ?[]u8 = null,
    /// The id the server handed out for this conversation, once it did.
    session_id: ?[]u8 = null,
    /// The status of the last answer, for a refusal the gateway will report.
    last_status: u16 = 0,
    sess: ?*session.Session = null,
    /// One exchange at a time: the stream that carries an answer is read to
    /// its end before the next request goes out.
    mu: Io.Mutex = .init,
    dead: bool = false,

    pub fn init(a: std.mem.Allocator, io: Io, url: []const u8, headers: []const web.Header) !*Http {
        const self = try a.create(Http);
        self.* = .{
            .a = a,
            .io = io,
            .client = web.Client.init(a, io),
            .url = try a.dupe(u8, url),
            .headers = try cloneHeaders(a, headers),
        };
        return self;
    }

    pub fn deinit(t: *Http) void {
        const a = t.a;
        t.client.deinit();
        a.free(t.url);
        for (t.headers) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(t.headers);
        if (t.session_id) |id| a.free(id);
        if (t.challenge) |c| a.free(c);
        a.destroy(t);
    }

    /// Points the transport at a credential, for a server that signed in.
    pub fn setBearer(t: *Http, bearer: web.Bearer) void {
        t.bearer = bearer;
    }

    /// The session whose pending calls the answers belong to.
    pub fn attach(t: *Http, sess: *session.Session) void {
        t.sess = sess;
    }

    pub fn wire(t: *Http) session.Wire {
        return .{ .ctx = t, .send = sendBytes, .close = closeWire };
    }

    pub fn close(t: *Http) void {
        t.dead = true;
    }

    fn closeWire(ctx: *anyopaque) void {
        const t: *Http = @ptrCast(@alignCast(ctx));
        t.close();
    }

    fn sendBytes(ctx: *anyopaque, a: std.mem.Allocator, bytes: []const u8) session.Error!void {
        const t: *Http = @ptrCast(@alignCast(ctx));
        if (t.dead) return error.Closed;

        // The headers, and the bearer token they carry, live until the request
        // has been written and answered. The token used to be freed as soon as
        // the headers were built, while the head that names it was still on its
        // way out, which sent the server a header of freed bytes.
        const outbound = t.headersFor(a) catch return error.OutOfMemory;
        defer {
            if (outbound.bearer) |value| a.free(value);
            a.free(outbound.list);
        }
        // Every POST is a JSON-RPC message, and the protocol wants the answer
        // as either JSON or events; a server that enforces it refuses the
        // request without both.
        const wired = web.withMcpHeaders(a, outbound.list) catch return error.OutOfMemory;
        defer a.free(wired);

        t.mu.lockUncancelable(t.io);
        defer t.mu.unlock(t.io);

        var stream = t.client.stream(.POST, t.url, wired, bytes) catch return error.WriteFailed;
        defer stream.close();
        t.last_status = stream.status;

        // A 401 is how a server says it wants a sign-in: keep what it asked
        // for, so the gateway can discover its authorization server.
        if (stream.status == 401) {
            if (t.challenge) |old| t.a.free(old);
            t.challenge = null;
            if (stream.challenge) |c| t.challenge = t.a.dupe(u8, c) catch null;
            return error.AuthRequired;
        }
        if (!stream.ok()) return error.BadStatus;

        // The server may name the conversation it just started; later requests
        // repeat the name so it finds the same session.
        if (stream.session_id) |id| {
            if (t.session_id) |old| t.a.free(old);
            t.session_id = t.a.dupe(u8, id) catch null;
        }

        const is_events = if (stream.content_type) |ct|
            std.mem.indexOf(u8, ct, "text/event-stream") != null
        else
            false;

        if (is_events) {
            // A server may keep the stream open after the answer it carried,
            // so reading to the end would wait until the call times out. The
            // read stops as soon as nothing is left waiting for an answer;
            // with no session attached there is nothing to stop it early, so
            // the stream is read to its end.
            if (t.sess) |sess| {
                if (!sess.awaitsAnswer()) return;
            }
            while (true) {
                const maybe_line = stream.next() catch return error.ReadFailed;
                const line = maybe_line orelse break;
                const body = eventData(line) orelse continue;
                if (t.sess) |sess| sess.handleBytes(body);
                if (t.sess) |sess| {
                    if (!sess.awaitsAnswer()) break;
                }
            }
            return;
        }

        const body = stream.rest() catch return error.ReadFailed;
        // The client allocated the body; it is the client's allocator that
        // frees it, not whichever one the caller handed `send`.
        defer t.a.free(body);
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return;
        if (t.sess) |sess| sess.handleBytes(trimmed);
    }

    /// What one request's headers are, and the token among them the caller
    /// owns and has to free.
    const Outbound = struct {
        list: []web.Header,
        bearer: ?[]u8,
    };

    /// The configured headers plus the ones every request carries.
    fn headersFor(t: *Http, a: std.mem.Allocator) !Outbound {
        const bearer: ?[]u8 = if (t.bearer) |b| b.header(b.ctx, a) else null;

        var extra: usize = 0;
        if (t.session_id != null) extra += 1;
        if (bearer != null) extra += 1;

        const out = try a.alloc(web.Header, t.headers.len + extra);
        for (t.headers, 0..) |h, i| out[i] = h;
        var next = t.headers.len;
        if (bearer) |value| {
            out[next] = .{ .name = "authorization", .value = value };
            next += 1;
        }
        if (t.session_id) |id| {
            out[next] = .{ .name = "Mcp-Session-Id", .value = id };
        }
        return .{ .list = out, .bearer = bearer };
    }
};

/// The payload of one event-stream line, if it carries any.
pub fn eventData(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;
    if (!std.mem.startsWith(u8, trimmed, "data:")) return null;
    const rest = std.mem.trim(u8, trimmed["data:".len..], " \t");
    if (rest.len == 0) return null;
    return rest;
}

fn cloneHeaders(a: std.mem.Allocator, headers: []const web.Header) ![]web.Header {
    const out = try a.alloc(web.Header, headers.len);
    for (headers, 0..) |h, i| {
        out[i] = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
    }
    return out;
}

test "only data lines carry a message" {
    try std.testing.expectEqualStrings("{\"a\":1}", eventData("data: {\"a\":1}").?);
    try std.testing.expectEqualStrings("{\"a\":1}", eventData("data:{\"a\":1}\r").?);
    try std.testing.expect(eventData("event: message") == null);
    try std.testing.expect(eventData(": keep-alive") == null);
    try std.testing.expect(eventData("") == null);
    try std.testing.expect(eventData("data:   ") == null);
}

test "a request names the media types the protocol requires" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const server = @import("server.zig");

    // A server that enforces the spec, as Linear and GitHub Copilot do: the
    // request has to accept both media types and say it carries JSON.
    const Fixture = struct {
        content_type: [64]u8 = undefined,
        content_len: usize = 0,
        accept: [64]u8 = undefined,
        accept_len: usize = 0,

        fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            const ct = req.header("content-type") orelse "";
            f.content_len = @min(ct.len, f.content_type.len);
            @memcpy(f.content_type[0..f.content_len], ct[0..f.content_len]);
            const accept = req.header("accept") orelse "";
            f.accept_len = @min(accept.len, f.accept.len);
            @memcpy(f.accept[0..f.accept_len], accept[0..f.accept_len]);
            if (!std.mem.eql(u8, f.content_type[0..f.content_len], "application/json"))
                return req.respond(.{ .status = .unsupported_media_type, .content_type = "text/plain", .body = "wrong content type" });
            if (!std.mem.eql(u8, f.accept[0..f.accept_len], "application/json, text/event-stream"))
                return req.respond(.{ .status = .not_acceptable, .content_type = "text/plain", .body = "wrong accept" });
            try req.respond(.{ .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}" });
        }
    };
    var fixture: Fixture = .{};
    const listener = try server.Server.initEphemeral(a, io, .{ .ctx = &fixture, .handle = Fixture.handle });
    defer {
        listener.stop();
        listener.destroy();
    }
    try listener.start();

    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp", .{listener.port});
    const t = try Http.init(a, io, url, &.{});
    defer t.deinit();

    var w = t.wire();
    try w.send(w.ctx, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
    try std.testing.expectEqualStrings("application/json", fixture.content_type[0..fixture.content_len]);
    try std.testing.expectEqualStrings("application/json, text/event-stream", fixture.accept[0..fixture.accept_len]);
}

test "an answer the session frees is built with the session's allocator" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = @import("server.zig");

    // The caller's allocator is a request-scoped arena, as it is when an
    // external client's tool call reaches the gateway; the session has its own.
    // The arena an answer is parsed into is freed later by the session, so it
    // has to come from the session's allocator, not the caller's: freeing it
    // with the other one is what SafeAllocator reports as "free of invalid
    // memory".
    var caller_state: std.heap.ArenaAllocator = .init(gpa);
    defer caller_state.deinit();
    const ca = caller_state.allocator();

    const Fixture = struct {
        fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
            _ = ctx;
            try req.respond(.{ .content_type = "application/json", .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}" });
        }
    };
    var fixture: u8 = 0;
    const listener = try server.Server.initEphemeral(ca, io, .{ .ctx = &fixture, .handle = Fixture.handle });
    defer {
        listener.stop();
        listener.destroy();
    }
    try listener.start();

    const url = try std.fmt.allocPrint(ca, "http://127.0.0.1:{d}/mcp", .{listener.port});
    const t = try Http.init(ca, io, url, &.{});
    defer t.deinit();

    var session_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = session_state.deinit();
    var sess = session.Session.init(session_state.allocator(), io, t.wire());
    defer sess.deinit();
    t.attach(&sess);

    const answer = try sess.call(ca, "tools/list", .{ .object = .empty });
    try std.testing.expect(answer == .object);
}
