//! The HTTP server the gateway serves on: one thread per connection, and the
//! handler does the rest. Everything is plain HTTP/1.1, which is all a local
//! gateway and an MCP client need.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const net = std.Io.net;

/// A header, on the way in and on the way out.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// What a handler answers with: a whole response, written at once.
pub const Reply = struct {
    status: http.Status = .ok,
    content_type: ?[]const u8 = "application/json",
    headers: []const Header = &.{},
    body: []const u8 = "",
};

/// A response whose body keeps coming: what an event stream is.
pub const Stream = struct {
    io: Io,
    body: *http.BodyWriter,

    /// Sends a chunk. The client sees it before the next one is written.
    pub fn write(s: *Stream, bytes: []const u8) !void {
        try s.body.writer.writeAll(bytes);
        // The chunk's framing sits in the writer's own buffer until it is
        // pushed through, so flushing only the socket would send nothing.
        try s.body.writer.flush();
        try s.body.flush();
    }

    /// Ends the response.
    pub fn finish(s: *Stream) !void {
        try s.body.end();
    }
};

/// One request, and the way to answer it.
pub const Request = struct {
    a: std.mem.Allocator,
    io: Io,
    raw: *http.Server.Request,
    method: http.Method,
    target: []const u8,
    path: []const u8,
    query: []const u8,
    headers: []const Header,
    body: []const u8,
    keep_alive: bool,
    answered: bool = false,

    /// Answers with a whole response.
    pub fn respond(r: *Request, reply: Reply) !void {
        r.answered = true;
        const extra = try r.extraHeaders(reply);
        try r.raw.respond(reply.body, .{
            .status = reply.status,
            .extra_headers = extra,
            .keep_alive = r.keep_alive,
        });
    }

    /// Answers with a body that keeps coming. `finish` ends it.
    pub fn stream(r: *Request, status: http.Status, content_type: []const u8, headers: []const Header) !*Stream {
        r.answered = true;
        const extra = try r.a.alloc(http.Header, headers.len + 1);
        extra[0] = .{ .name = "content-type", .value = content_type };
        for (headers, 0..) |h, i| extra[i + 1] = .{ .name = h.name, .value = h.value };

        const body = try r.a.create(http.BodyWriter);
        body.* = try r.raw.respondStreaming(try r.a.alloc(u8, 8192), .{
            .content_length = null,
            .respond_options = .{
                .status = status,
                .extra_headers = extra,
                // A stream ends when the server says so, not when the client
                // has read a length: the connection carries it alone.
                .keep_alive = false,
            },
        });
        const out = try r.a.create(Stream);
        out.* = .{ .io = r.io, .body = body };
        return out;
    }

    /// A header of the request, by name, whatever its case.
    pub fn header(r: *const Request, name: []const u8) ?[]const u8 {
        for (r.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    fn extraHeaders(r: *Request, reply: Reply) ![]http.Header {
        var count: usize = reply.headers.len;
        if (reply.content_type != null) count += 1;
        const out = try r.a.alloc(http.Header, count);
        var i: usize = 0;
        if (reply.content_type) |ct| {
            out[0] = .{ .name = "content-type", .value = ct };
            i = 1;
        }
        for (reply.headers) |h| {
            out[i] = .{ .name = h.name, .value = h.value };
            i += 1;
        }
        return out;
    }
};

/// What a handler is: a function and the state it reads.
pub const Handler = struct {
    ctx: *anyopaque,
    handle: *const fn (ctx: *anyopaque, req: *Request) anyerror!void,
};

/// The largest request body the server reads: an MCP message or a
/// registration, never a file.
pub const max_body = 4 << 20;

/// The server itself: a listening socket and the thread that accepts on it.
pub const Server = struct {
    a: std.mem.Allocator,
    io: Io,
    listener: net.Server,
    port: u16,
    handler: Handler,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// The connections that are still being served, so a stop can shut them.
    mu: Io.Mutex = .init,
    live: std.ArrayList(net.Stream) = .empty,
    /// Connections still being served, guarded by `mu`; stopping waits for
    /// them so nothing is still writing when the caller tears down.
    handlers: usize = 0,
    cond: Io.Condition = .init,

    /// Listens on 127.0.0.1:port, which is the only address a gateway serves
    /// on: it is a local tool, and the browser comes back to it.
    pub fn init(a: std.mem.Allocator, io: Io, port: u16, handler: Handler) !*Server {
        const addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
        const listener = try addr.listen(io, .{ .reuse_address = true, .mode = .stream });

        const s = try a.create(Server);
        s.* = .{ .a = a, .io = io, .listener = listener, .port = port, .handler = handler };
        return s;
    }

    /// Listens on the first free port of a range, which is what a test wants:
    /// it does not care which port it got, only that it can reach it.
    pub fn initEphemeral(a: std.mem.Allocator, io: Io, handler: Handler) !*Server {
        var port: u16 = 47_800;
        while (port < 47_900) : (port += 1) {
            const s = init(a, io, port, handler) catch continue;
            return s;
        }
        return error.NoFreePort;
    }

    /// Starts accepting, in a thread of its own.
    pub fn start(s: *Server) !void {
        s.thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
    }

    /// Stops accepting, and drops the connections that are still open. A
    /// stream that is writing sees its socket go away, which is what makes an
    /// event stream end when the gateway stops.
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        // Closing the listener does not reliably wake a blocking accept on
        // every backend (a threaded one sits in accept4 until a connection
        // arrives), so knock on it once: the loop sees `stopping` and
        // closes the connection instead of serving it.
        const wake_addr: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(s.port) };
        if (wake_addr.connect(s.io, .{ .mode = .stream })) |wake| {
            wake.close(s.io);
        } else |_| {}
        s.listener.deinit(s.io);
        s.mu.lockUncancelable(s.io);
        for (s.live.items) |stream| stream.shutdown(s.io, .both) catch {};
        s.live.deinit(s.a);
        s.live = .empty;
        s.mu.unlock(s.io);
        if (s.thread) |t| {
            t.join();
            s.thread = null;
        }
        // Every connection is on its way out; wait for them to finish.
        s.mu.lockUncancelable(s.io);
        while (s.handlers > 0) s.cond.waitUncancelable(s.io, &s.mu);
        s.mu.unlock(s.io);
    }

    pub fn destroy(s: *Server) void {
        s.a.destroy(s);
    }

    fn acceptLoop(s: *Server) void {
        while (!s.stopping.load(.acquire)) {
            const stream = s.listener.accept(s.io) catch {
                if (s.stopping.load(.acquire)) return;
                continue;
            };
            s.mu.lockUncancelable(s.io);
            const tracked = !s.stopping.load(.acquire);
            if (tracked) {
                s.live.append(s.a, stream) catch {};
                // Counted here, not in the handler, so a stop that races the
                // spawn still waits for it.
                s.handlers += 1;
            }
            s.mu.unlock(s.io);
            if (!tracked) {
                stream.close(s.io);
                continue;
            }
            const thread = std.Thread.spawn(.{}, serveConnection, .{ s, stream }) catch {
                s.mu.lockUncancelable(s.io);
                s.handlers -= 1;
                s.cond.broadcast(s.io);
                s.mu.unlock(s.io);
                stream.close(s.io);
                continue;
            };
            thread.detach();
        }
    }

    fn serveConnection(s: *Server, stream: net.Stream) void {
        // Deferred in reverse: the stream leaves the list of live ones before
        // its socket goes away, so a stop never shuts a closed socket down,
        // and the count drops last so a stop can wait for the whole handler.
        defer {
            s.mu.lockUncancelable(s.io);
            s.handlers -= 1;
            s.cond.broadcast(s.io);
            s.mu.unlock(s.io);
        }
        defer stream.close(s.io);
        defer s.forget(stream);


        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(s.io, &read_buffer);
        var writer = stream.writer(s.io, &write_buffer);
        var http_server = http.Server.init(&reader.interface, &writer.interface);

        while (!s.stopping.load(.acquire)) {
            var arena_state = std.heap.ArenaAllocator.init(s.a);
            defer arena_state.deinit();
            const a = arena_state.allocator();

            var raw = http_server.receiveHead() catch return;
            // The head is copied before the body is started: starting it
            // invalidates the strings the head points at.
            const head_headers = readHeaders(a, &raw) catch return;
            const target = a.dupe(u8, raw.head.target) catch return;
            const body = raw.readerExpectContinue(&.{}) catch return;
            const payload = body.allocRemaining(a, .limited(max_body)) catch return;

            const req = a.create(Request) catch return;
            req.* = .{
                .a = a,
                .io = s.io,
                .raw = &raw,
                .method = raw.head.method,
                .target = target,
                .path = "",
                .query = "",
                .headers = head_headers,
                .body = payload,
                .keep_alive = raw.head.keep_alive,
            };
            splitTarget(req);

            s.handler.handle(s.handler.ctx, req) catch |err| {
                if (!req.answered) {
                    var text: [128]u8 = undefined;
                    const message = std.fmt.bufPrint(&text, "the gateway failed: {s}", .{@errorName(err)}) catch "the gateway failed";
                    req.respond(.{ .status = .internal_server_error, .body = message }) catch {};
                }
            };
            if (!req.keep_alive) return;
        }
    }

    fn forget(s: *Server, stream: net.Stream) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        for (s.live.items, 0..) |live, i| {
            if (live.socket.handle == stream.socket.handle) {
                _ = s.live.orderedRemove(i);
                return;
            }
        }
    }
};

fn readHeaders(a: std.mem.Allocator, raw: *http.Server.Request) ![]Header {
    var list: std.ArrayList(Header) = .empty;
    var it = raw.iterateHeaders();
    while (it.next()) |h| {
        try list.append(a, .{ .name = h.name, .value = h.value });
    }
    return list.toOwnedSlice(a);
}

/// Splits the request target into a path and a query.
fn splitTarget(req: *Request) void {
    if (std.mem.findScalar(u8, req.target, '?')) |i| {
        req.path = req.target[0..i];
        req.query = req.target[i + 1 ..];
    } else {
        req.path = req.target;
    }
}

/// The value of a query parameter, percent-decoded, with `+` as a space.
pub fn param(a: std.mem.Allocator, query: []const u8, name: []const u8) !?[]u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.findScalar(u8, pair, '=') orelse pair.len;
        const key = pair[0..eq];
        if (!std.mem.eql(u8, key, name)) continue;
        const value = if (eq < pair.len) pair[eq + 1 ..] else "";
        return try decode(a, value);
    }
    return null;
}

/// Percent-decoding, as a form or a query string carries it.
pub fn decode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '+') {
            try out.append(a, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < text.len) {
            const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch {
                try out.append(a, c);
                i += 1;
                continue;
            };
            try out.append(a, byte);
            i += 3;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

test "a query parameter is decoded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("a b", (try param(a, "q=a+b&x=1", "q")).?);
    try std.testing.expectEqualStrings("a/b", (try param(a, "q=a%2Fb", "q")).?);
    try std.testing.expectEqualStrings("", (try param(a, "q=", "q")).?);
    try std.testing.expect((try param(a, "q=1", "x")) == null);
    try std.testing.expect((try param(a, "", "q")) == null);
}

const web = @import("http_client.zig");

const Echo = struct {
    fn handle(ctx: *anyopaque, req: *Request) anyerror!void {
        _ = ctx;
        if (std.mem.eql(u8, req.path, "/echo")) {
            const body = try std.fmt.allocPrint(req.a, "{s} {s} {s}", .{ @tagName(req.method), req.path, req.body });
            try req.respond(.{ .body = body });
            return;
        }
        if (std.mem.eql(u8, req.path, "/missing")) {
            try req.respond(.{ .status = .not_found, .body = "nope" });
            return;
        }
        try req.respond(.{ .status = .bad_request });
    }
};

test "the server answers a request and closes when stopped" {
    const io = std.testing.io;
    var gpa_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa_state.deinit();
    const a = gpa_state.allocator();

    const srv = try Server.initEphemeral(a, io, .{ .ctx = undefined, .handle = Echo.handle });
    try srv.start();
    defer {
        srv.stop();
        srv.destroy();
    }

    var client = web.Client.init(a, io);
    defer client.deinit();

    const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{srv.port});
    const answer = try client.send(.POST, try std.fmt.allocPrint(a, "{s}/echo", .{base}), &.{}, "hello");
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    try std.testing.expectEqualStrings("POST /echo hello", answer.body);

    const missing = try client.send(.GET, try std.fmt.allocPrint(a, "{s}/missing", .{base}), &.{}, null);
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    try std.testing.expectEqualStrings("nope", missing.body);
}
