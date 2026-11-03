//! HTTP from the app: one-shot calls for the registry, and a streaming
//! response for the transports that stay open (SSE).
const std = @import("std");
const Io = std.Io;
const http = std.http;

/// A header to send with a request.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Where a transport gets the credential for a request it is about to make.
/// The header it returns is owned by the transport, which frees it.
pub const Bearer = struct {
    ctx: *anyopaque,
    header: *const fn (ctx: *anyopaque, a: std.mem.Allocator) ?[]u8,
};

/// What came back from a one-shot call.
pub const Answer = struct {
    status: u16,
    body: []u8,
    /// The response's headers, by lowercase name, for the callers that have
    /// to look at one (a challenge, a redirect).
    header: std.ArrayList(http.Header) = .empty,

    pub fn ok(self: Answer) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// The value of a header, case-insensitively.
    pub fn headerValue(self: Answer, a: std.mem.Allocator, name: []const u8) !?[]u8 {
        for (self.header.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return try a.dupe(u8, h.value);
        }
        return null;
    }
};

/// A watchdog that shuts a connection down when a request has taken too long.
/// `std.http` has no timeout of its own, and a server that accepts a request
/// and never answers would otherwise hold the caller for ever.
const Deadline = struct {
    io: Io = undefined,
    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    done: bool = false,
    fired: bool = false,
    stream: ?*Io.net.Stream = null,
    duration: Io.Duration = .{ .nanoseconds = 0 },
    thread: ?std.Thread = null,

    fn arm(d: *Deadline, io: Io, stream: ?*Io.net.Stream, duration: Io.Duration) void {
        if (stream == null or duration.nanoseconds <= 0) return;
        d.io = io;
        d.stream = stream;
        d.duration = duration;
        d.thread = std.Thread.spawn(.{}, run, .{d}) catch null;
    }

    fn run(d: *Deadline) void {
        const started = Io.Timestamp.now(d.io, .awake);
        const at: Io.Timeout = .{ .deadline = .{
            .raw = .{ .nanoseconds = started.nanoseconds + d.duration.nanoseconds },
            .clock = .awake,
        } };
        d.mu.lockUncancelable(d.io);
        defer d.mu.unlock(d.io);
        while (!d.done) {
            d.cond.waitTimeout(d.io, &d.mu, at) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return,
            };
            if (d.done) return;
            d.fired = true;
            if (d.stream) |stream| stream.shutdown(d.io, .both) catch {};
            return;
        }
    }

    /// Stops the watchdog; true when it fired and the connection was shut
    /// down, so the caller can report a timeout rather than a read failure.
    fn finish(d: *Deadline) bool {
        const thread = d.thread orelse return false;
        d.mu.lockUncancelable(d.io);
        d.done = true;
        d.cond.broadcast(d.io);
        d.mu.unlock(d.io);
        thread.join();
        return d.fired;
    }
};

/// A client for talking to the outside world. `a` must outlive it, and the
/// answers are owned by the caller.
pub const Client = struct {
    a: std.mem.Allocator,
    io: Io,
    inner: http.Client,
    /// How long a request may take, from connecting to the last body byte,
    /// before its connection is shut down. Zero disables it.
    timeout: Io.Duration = .{ .nanoseconds = 30 * std.time.ns_per_s },

    pub fn init(a: std.mem.Allocator, io: Io) Client {
        return .{ .a = a, .io = io, .inner = .{ .allocator = a, .io = io } };
    }

    pub fn deinit(c: *Client) void {
        c.inner.deinit();
    }

    /// Sends a request and reads the whole answer.
    pub fn send(c: *Client, method: http.Method, url: []const u8, headers: []const Header, payload: ?[]const u8) !Answer {
        const accept_given = hasHeader(headers, "accept");
        const agent_given = hasHeader(headers, "user-agent");
        const extra = try c.a.alloc(http.Header, headers.len + @intFromBool(!accept_given) + @intFromBool(!agent_given));
        defer c.a.free(extra);
        var n: usize = 0;
        for (headers) |h| {
            extra[n] = .{ .name = h.name, .value = h.value };
            n += 1;
        }
        if (!accept_given) {
            extra[n] = .{ .name = "Accept", .value = "application/json" };
            n += 1;
        }
        if (!agent_given) {
            extra[n] = .{ .name = "User-Agent", .value = "nanomcp/0.1" };
            n += 1;
        }

        var body: std.Io.Writer.Allocating = .init(c.a);
        errdefer body.deinit();

        // `fetch` hides the response head, which the caller of this function
        // needs (a challenge, a redirect), so the exchange is done by hand.
        var req = try c.inner.request(method, try std.Uri.parse(url), .{
            .extra_headers = extra,
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        var deadline: Deadline = .{};
        if (req.connection) |conn| deadline.arm(c.io, &conn.stream_reader.stream, c.timeout);

        const exchanged = exchange(c, &req, payload, &body);
        const fired = deadline.finish();
        if (exchanged) |answer| {
            if (fired) {
                freeAnswer(c.a, answer);
                if (req.connection) |conn| conn.closing = true;
                return error.Timeout;
            }
            return answer;
        } else |err| {
            if (fired) {
                if (req.connection) |conn| conn.closing = true;
                return error.Timeout;
            }
            return err;
        }
    }

    /// Frees a response: its body, and the headers its caller asked for.
    pub fn freeAnswer(a: std.mem.Allocator, answer: Answer) void {
        for (answer.header.items) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        if (answer.header.capacity > 0) a.free(answer.header.allocatedSlice());
        a.free(answer.body);
    }

    /// Sends the payload and reads the whole answer. It is a separate function
    /// so `send` can put a deadline around it.
    fn exchange(c: *Client, req: *http.Client.Request, payload: ?[]const u8, body: *std.Io.Writer.Allocating) !Answer {
        if (payload) |p| {
            req.transfer_encoding = .{ .content_length = p.len };
            var bw = try req.sendBodyUnflushed(&.{});
            try bw.writer.writeAll(p);
            try bw.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var response = try req.receiveHead(&.{});
        var header: std.ArrayList(http.Header) = .empty;
        errdefer {
            for (header.items) |h| {
                c.a.free(h.name);
                c.a.free(h.value);
            }
            header.deinit(c.a);
        }
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            try header.append(c.a, .{ .name = try c.a.dupe(u8, h.name), .value = try c.a.dupe(u8, h.value) });
        }
        // The client advertises the encodings it understands, and a server is
        // free to use them even when it was not asked to: Cloudflare gzips
        // metadata documents by itself. Reading the body raw would hand
        // compressed bytes to a JSON parser.
        const decompress_buffer = try decompressBuffer(c.a, response.head.content_encoding);
        defer if (decompress_buffer.len > 0) c.a.free(decompress_buffer);
        var decompress: http.Decompress = undefined;
        var transfer: [64]u8 = undefined;
        const reader = response.readerDecompressing(&transfer, &decompress, decompress_buffer);
        _ = try reader.streamRemaining(&body.writer);
        const status = @intFromEnum(response.head.status);
        return .{ .status = status, .body = try body.toOwnedSlice(), .header = header };
    }

    /// Sends a request and hands back the response while its body is still
    /// arriving; the caller reads it with `Stream.next`.
    pub fn stream(c: *Client, method: http.Method, url: []const u8, headers: []const Header, payload: ?[]const u8) !*Stream {
        const accept_given = hasHeader(headers, "accept");
        const extra = try c.a.alloc(http.Header, headers.len + @intFromBool(!accept_given));
        defer c.a.free(extra);
        var n: usize = 0;
        for (headers) |h| {
            extra[n] = .{ .name = h.name, .value = h.value };
            n += 1;
        }
        if (!accept_given) {
            extra[n] = .{ .name = "Accept", .value = "text/event-stream" };
            n += 1;
        }

        // The request has to live in the heap-allocated stream from the start:
        // its reader is what the body is read through, and a pointer into a
        // stack copy would dangle as soon as this function returned.
        const s = try c.a.create(Stream);
        // Written out whole: a `create`d value starts undefined, so fields
        // that rely on their declared default (the line buffer, the decoder)
        // must be given their defaults here.
        s.* = .{
            .req = undefined,
            .status = 0,
            .content_type = null,
            .session_id = null,
            .body = undefined,
            .a = c.a,
        };
        s.req = c.inner.request(method, try std.Uri.parse(url), .{
            .extra_headers = extra,
            .redirect_behavior = .unhandled,
        }) catch |err| {
            c.a.destroy(s);
            return err;
        };
        errdefer discardStream(c, s);

        var deadline: Deadline = .{};
        if (s.req.connection) |conn| deadline.arm(c.io, &conn.stream_reader.stream, c.timeout);

        // Only connecting and the response head are bounded: an event stream
        // then stays open for as long as its client does.
        var response = openResponse(&s.req, payload) catch |err| {
            if (deadline.finish()) {
                if (s.req.connection) |conn| conn.closing = true;
                return error.Timeout;
            }
            return err;
        };
        if (deadline.finish()) {
            if (s.req.connection) |conn| conn.closing = true;
            return error.Timeout;
        }
        s.status = @intFromEnum(response.head.status);
        s.content_type = try dupeHeader(c.a, response.head, "content-type");
        s.session_id = try dupeHeader(c.a, response.head, "mcp-session-id");
        s.challenge = try dupeHeader(c.a, response.head, "www-authenticate");
        // A server may compress the answer: the body has to be decoded before
        // it is read as events or JSON.
        s.decompress_buffer = try decompressBuffer(c.a, response.head.content_encoding);
        s.body = response.readerDecompressing(&s.transfer, &s.decompress, s.decompress_buffer);
        return s;
    }
};

/// Sends the payload, if any, and reads the response head. Split out so the
/// stream can put a deadline around it.
fn openResponse(req: *http.Client.Request, payload: ?[]const u8) !http.Client.Response {
    if (payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(p);
        try bw.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }
    return req.receiveHead(&.{});
}

/// Frees a stream that never made it out of `Client.stream`.
fn discardStream(c: *Client, s: *Stream) void {
    s.req.deinit();
    if (s.content_type) |ct| c.a.free(ct);
    if (s.session_id) |id| c.a.free(id);
    if (s.challenge) |ch| c.a.free(ch);
    if (s.decompress_buffer.len > 0) c.a.free(s.decompress_buffer);
    c.a.destroy(s);
}

/// The window a compressed answer needs, or an empty slice when it is plain.
fn decompressBuffer(a: std.mem.Allocator, encoding: http.ContentEncoding) ![]u8 {
    return switch (encoding) {
        .identity => &.{},
        .deflate, .gzip => try a.alloc(u8, std.compress.flate.max_window_len),
        .zstd => try a.alloc(u8, std.compress.zstd.default_window_len),
        .compress => error.UnsupportedCompressionMethod,
    };
}

/// A response whose body is read as it arrives.
pub const Stream = struct {
    req: http.Client.Request,
    status: u16,
    content_type: ?[]u8,
    /// The id the server gave this conversation, which later requests repeat.
    session_id: ?[]u8,
    /// What a 401 said it wanted, which is how a sign-in is discovered.
    challenge: ?[]u8 = null,
    body: *std.Io.Reader,
    transfer: [4096]u8 = undefined,
    /// The decoder for a compressed answer, and the window it uses; both
    /// live as long as the body is read.
    decompress: http.Decompress = undefined,
    decompress_buffer: []u8 = &.{},
    a: std.mem.Allocator,
    /// The bytes of the lines gathered so far; one event can be far longer
    /// than the reader's window (a tool list arrives as one huge line).
    line: std.ArrayList(u8) = .empty,
    /// Where the next line starts in `line`.
    line_start: usize = 0,
    /// Set once the body is spent, after the last partial line was handed out.
    ended: bool = false,

    pub fn ok(s: *Stream) bool {
        return s.status >= 200 and s.status < 300;
    }

    /// Drops the stream. A stream that carries events never ends on its own,
    /// so this closes the connection rather than reading the rest of a body
    /// that would never arrive.
    pub fn close(s: *Stream) void {
        s.req.deinit();
        if (s.content_type) |ct| s.a.free(ct);
        if (s.session_id) |id| s.a.free(id);
        if (s.challenge) |c| s.a.free(c);
        if (s.decompress_buffer.len > 0) s.a.free(s.decompress_buffer);
        s.line.deinit(s.a);
        s.a.destroy(s);
    }

    /// The next line of the body, without its newline; null at the end. The
    /// returned slice is valid until the next call.
    pub fn next(s: *Stream) !?[]u8 {
        // The line handed out last time is spent now, so the bytes under it
        // can go. Clearing it before handing it out would wipe the line the
        // caller is about to read.
        if (s.line_start == s.line.items.len) {
            s.line.clearRetainingCapacity();
            s.line_start = 0;
        }
        if (s.ended) return null;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, s.line.items, s.line_start, '\n')) |nl| {
                const out = s.line.items[s.line_start..nl];
                s.line_start = nl + 1;
                return out;
            }
            if (s.line_start > 0) {
                const kept = s.line.items.len - s.line_start;
                std.mem.copyForwards(u8, s.line.items[0..kept], s.line.items[s.line_start..]);
                s.line.shrinkRetainingCapacity(kept);
                s.line_start = 0;
            }
            // Whatever has arrived, not a whole window: an event stream may
            // stay open, so asking for a full window would wait for bytes
            // that are not coming yet.
            var chunk: [4096]u8 = undefined;
            var vec = [_][]u8{&chunk};
            const n = s.body.readVec(&vec) catch |err| switch (err) {
                error.EndOfStream => {
                    s.ended = true;
                    if (s.line.items.len == 0) return null;
                    return s.line.items[0..];
                },
                error.ReadFailed => return error.ReadFailed,
            };
            // Zero means the bytes are waiting in the reader's own buffer,
            // not that the body ended: the next call copies them out.
            if (n == 0) continue;
            try s.line.appendSlice(s.a, chunk[0..n]);
        }
    }

    /// The whole body, for a response that is not a stream.
    pub fn rest(s: *Stream) ![]u8 {
        return s.body.allocRemaining(s.a, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => |e| return e,
        };
    }
};

/// Copies one header of a response, before its buffer is reused.
pub fn dupeHeader(a: std.mem.Allocator, head: http.Client.Response.Head, name: []const u8) !?[]u8 {
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return try a.dupe(u8, h.value);
    }
    return null;
}

/// Whether a URL is one this client can fetch.
pub fn isRemote(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

/// Whether the caller already set a header, whatever its spelling.
pub fn hasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
    }
    return false;
}

/// The headers an MCP Streamable HTTP request carries: the caller's, plus the
/// JSON content type and the accept a server requires. The protocol asks for
/// both media types, and a server that enforces the spec answers 406 or 415
/// without them, which is what kept Linear and GitHub Copilot from connecting.
/// A header the caller already set is left alone. The caller frees the slice,
/// not the strings in it.
pub fn withMcpHeaders(a: std.mem.Allocator, headers: []const Header) ![]Header {
    const content_given = hasHeader(headers, "content-type");
    const accept_given = hasHeader(headers, "accept");
    const out = try a.alloc(Header, headers.len + @intFromBool(!content_given) + @intFromBool(!accept_given));
    @memcpy(out[0..headers.len], headers);
    var n = headers.len;
    if (!content_given) {
        out[n] = .{ .name = "content-type", .value = "application/json" };
        n += 1;
    }
    if (!accept_given) {
        out[n] = .{ .name = "accept", .value = "application/json, text/event-stream" };
        n += 1;
    }
    return out;
}

test "only http and https urls are remote" {
    try std.testing.expect(isRemote("http://example.com"));
    try std.testing.expect(isRemote("https://example.com/mcp"));
    try std.testing.expect(!isRemote("example.com"));
    try std.testing.expect(!isRemote("ftp://example.com"));
}

test "an MCP request gets the media types it needs, without replacing the caller's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const bare = try withMcpHeaders(a, &.{
        .{ .name = "authorization", .value = "Bearer t" },
    });
    try std.testing.expectEqual(@as(usize, 3), bare.len);
    try std.testing.expectEqualStrings("authorization", bare[0].name);
    try std.testing.expectEqualStrings("application/json", bare[1].value);
    try std.testing.expectEqualStrings("application/json, text/event-stream", bare[2].value);

    // A caller that already chose them keeps its values, and adds nothing.
    const set = try withMcpHeaders(a, &.{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "Accept", .value = "application/json" },
    });
    try std.testing.expectEqual(@as(usize, 2), set.len);
    try std.testing.expectEqualStrings("application/json; charset=utf-8", set[0].value);
    try std.testing.expectEqualStrings("application/json", set[1].value);
}

test "a streamed event longer than the window is read whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = @import("server.zig");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const Fixture = struct {
        body: []const u8,
        fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            var out = try req.stream(.ok, "text/event-stream", &.{});
            var at: usize = 0;
            while (at < f.body.len) : (at += 1000) {
                try out.write(f.body[at..@min(at + 1000, f.body.len)]);
            }
            try out.finish();
        }
    };
    const long = try a.alloc(u8, 20000);
    @memset(long, 'y');
    const body = try std.fmt.allocPrint(a, "event: message\ndata: {s}\n\n", .{long});
    var fixture: Fixture = .{ .body = body };
    const listener = try server.Server.initEphemeral(a, io, .{ .ctx = &fixture, .handle = Fixture.handle });
    defer {
        listener.stop();
        listener.destroy();
    }
    try listener.start();

    var client = Client.init(a, io);
    defer client.deinit();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp", .{listener.port});
    const stream = try client.stream(.POST, url, &.{}, "{}");
    defer stream.close();

    try std.testing.expectEqualStrings("event: message", (try stream.next()).?);
    const data = (try stream.next()).?;
    try std.testing.expectEqual(@as(usize, long.len + "data: ".len), data.len);
    try std.testing.expect(std.mem.startsWith(u8, data, "data: "));
    try std.testing.expect(std.mem.endsWith(u8, data, long));
}

test "a line longer than the reader's window is read whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = @import("server.zig");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A tool list arrives as one event whose data line is far longer than
    // the 4 KiB window the stream reads through; reading it by delimiter
    // used to fail with StreamTooLong and the answer was lost.
    const Fixture = struct {
        body: []const u8,
        fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            try req.respond(.{
                .headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
                .body = f.body,
            });
        }
    };
    const long = try a.alloc(u8, 20000);
    @memset(long, 'x');
    const body = try std.fmt.allocPrint(a, "event: message\ndata: {s}\n\n", .{long});
    var fixture: Fixture = .{ .body = body };
    const listener = try server.Server.initEphemeral(a, io, .{ .ctx = &fixture, .handle = Fixture.handle });
    defer {
        listener.stop();
        listener.destroy();
    }
    try listener.start();

    var client = Client.init(a, io);
    defer client.deinit();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp", .{listener.port});
    const stream = try client.stream(.POST, url, &.{}, "{}");
    defer stream.close();

    try std.testing.expectEqualStrings("event: message", (try stream.next()).?);
    const data = (try stream.next()).?;
    try std.testing.expectEqual(@as(usize, long.len + "data: ".len), data.len);
    try std.testing.expect(std.mem.startsWith(u8, data, "data: "));
    try std.testing.expect(std.mem.endsWith(u8, data, long));
    try std.testing.expectEqualStrings("", (try stream.next()).?);
    try std.testing.expect((try stream.next()) == null);
}

test "a gzipped answer is decoded before it is read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const server = @import("server.zig");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // An authorization server behind a CDN gzips its metadata whether or not
    // the request named the encoding, which is what broke Linear's sign-in.
    const document = "{\"issuer\":\"https://mcp.linear.app\"}";
    var encoded = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer encoded.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var flate = try std.compress.flate.Compress.init(&encoded.writer, window, .gzip, .default);
    try flate.writer.writeAll(document);
    try flate.finish();

    const Fixture = struct {
        gz: []const u8,
        fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            try req.respond(.{
                .headers = &.{.{ .name = "content-encoding", .value = "gzip" }},
                .body = f.gz,
            });
        }
    };
    var fixture: Fixture = .{ .gz = encoded.written() };
    const listener = try server.Server.initEphemeral(a, io, .{ .ctx = &fixture, .handle = Fixture.handle });
    defer {
        listener.stop();
        listener.destroy();
    }
    try listener.start();

    var client = Client.init(a, io);
    defer client.deinit();
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/document", .{listener.port});

    const answer = try client.send(.GET, url, &.{}, null);
    defer Client.freeAnswer(a, answer);
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    try std.testing.expectEqualStrings(document, answer.body);

    // A streamed body is decoded the same way.
    const streamed = try client.stream(.GET, url, &.{}, null);
    defer streamed.close();
    try std.testing.expectEqual(@as(u16, 200), streamed.status);
    try std.testing.expectEqualStrings(document, try streamed.rest());
}

test "a request that never hears back times out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // A port that accepts connections but never answers: the kernel completes
    // the handshake from the listen backlog, and the client waits forever.
    const address: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/silent", .{listener.socket.address.ip4.port});
    defer gpa.free(url);

    var client = Client.init(gpa, io);
    defer client.deinit();
    client.timeout = .fromMilliseconds(150);

    try std.testing.expectError(error.Timeout, client.send(.GET, url, &.{}, null));

    // The connect-and-head phase of a stream is bounded too.
    try std.testing.expectError(error.Timeout, client.stream(.GET, url, &.{}, null));
}
