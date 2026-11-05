//! A server on the network that keeps a stream open: MCP's older SSE
//! transport, where the server announces an endpoint and the answers come
//! back on a long-lived event stream.
const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = @import("json_util.zig");
const session = @import("session.zig");
const web = @import("http_client.zig");

pub const StartError = error{
    ConnectFailed,
    AuthRequired,
    BadStatus,
    NoEndpoint,
    OutOfMemory,
};

/// A connection to one server over server-sent events.
pub const Sse = struct {
    a: std.mem.Allocator,
    io: Io,
    client: web.Client,
    url: []const u8,
    headers: []web.Header,
    /// Where requests are posted, as the server announced it.
    endpoint: ?[]u8 = null,
    /// Where the credential comes from, once a sign-in produced one.
    bearer: ?web.Bearer = null,
    /// What a 401 said it wanted.
    challenge: ?[]u8 = null,
    /// Why the stream ended, once it did.
    failure: ?[]const u8 = null,
    sess: ?*session.Session = null,
    thread: ?std.Thread = null,
    dead: bool = false,

    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,

    /// Opens the stream and waits until the server says where to post.
    pub fn start(a: std.mem.Allocator, io: Io, url: []const u8, headers: []const web.Header) !*Sse {
        const self = try a.create(Sse);
        self.* = .{
            .a = a,
            .io = io,
            .client = web.Client.init(a, io),
            .url = try a.dupe(u8, url),
            .headers = try cloneHeaders(a, headers),
        };
        errdefer self.deinit();

        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        // The first request needs the endpoint, so start waits for it.
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        while (self.endpoint == null and !self.dead) self.cond.waitUncancelable(io, &self.mu);
        if (self.endpoint == null) return error.NoEndpoint;
        return self;
    }

    pub fn deinit(s: *Sse) void {
        const a = s.a;
        s.close();
        a.free(s.url);
        for (s.headers) |h| {
            a.free(h.name);
            a.free(h.value);
        }
        a.free(s.headers);
        if (s.endpoint) |e| a.free(e);
        if (s.challenge) |c| a.free(c);
        if (s.failure) |f| a.free(f);
        s.client.deinit();
        a.destroy(s);
    }

    pub fn close(s: *Sse) void {
        s.mu.lockUncancelable(s.io);
        s.dead = true;
        s.mu.unlock(s.io);
        s.cond.broadcast(s.io);
        if (s.thread) |t| t.join();
        s.thread = null;
    }

    pub fn wire(s: *Sse) session.Wire {
        return .{ .ctx = s, .send = sendBytes, .close = closeWire };
    }

    /// Points the transport at a credential, for a server that signed in.
    pub fn setBearer(s: *Sse, bearer: web.Bearer) void {
        s.bearer = bearer;
    }

    /// The session whose pending calls the answers on the stream belong to.
    pub fn attach(s: *Sse, sess: *session.Session) void {
        s.sess = sess;
    }

    /// What one request's headers are, and the token among them the caller
    /// owns and has to free.
    const Outbound = struct {
        list: []web.Header,
        bearer: ?[]u8,
    };

    /// The headers every request and the stream itself carry.
    fn headersFor(s: *Sse, a: std.mem.Allocator) !Outbound {
        const bearer: ?[]u8 = if (s.bearer) |b| b.header(b.ctx, a) else null;
        errdefer if (bearer) |value| a.free(value);

        const extra: usize = if (bearer == null) 0 else 1;
        const out = try a.alloc(web.Header, s.headers.len + extra);
        for (s.headers, 0..) |h, i| out[i] = h;
        // The token the bearer made lives until the request is on its way out;
        // freeing it here would leave the header naming freed bytes.
        if (bearer) |value| out[s.headers.len] = .{ .name = "authorization", .value = value };
        return .{ .list = out, .bearer = bearer };
    }

    fn closeWire(ctx: *anyopaque) void {
        const s: *Sse = @ptrCast(@alignCast(ctx));
        s.close();
    }

    fn sendBytes(ctx: *anyopaque, a: std.mem.Allocator, bytes: []const u8) session.Error!void {
        const s: *Sse = @ptrCast(@alignCast(ctx));
        if (s.dead) return error.Closed;
        const endpoint = s.endpoint orelse return error.WriteFailed;
        const outbound = s.headersFor(a) catch return error.OutOfMemory;
        defer {
            if (outbound.bearer) |value| a.free(value);
            a.free(outbound.list);
        }

        const answer = blk: {
            // The message a POST carries is JSON, and an SSE server that
            // enforces the media type refuses it otherwise.
            const wired = web.withMcpHeaders(a, outbound.list) catch return error.OutOfMemory;
            defer a.free(wired);
            break :blk s.client.send(.POST, endpoint, wired, bytes) catch
                return error.WriteFailed;
        };
        // The client allocated the body; it is the client's allocator that
        // frees it, not whichever one the caller handed `send`.
        defer s.a.free(answer.body);
        if (answer.status == 401) return error.AuthRequired;
        // The answer itself arrives on the stream, so the reply to a post only
        // says that it was taken.
        if (!answer.ok()) return error.BadStatus;
    }

    fn readLoop(s: *Sse) void {
        const a = s.a;
        const outbound = s.headersFor(a) catch {
            s.finish("the request headers could not be built");
            return;
        };
        defer {
            if (outbound.bearer) |value| a.free(value);
            a.free(outbound.list);
        }

        var stream = s.client.stream(.GET, s.url, outbound.list, null) catch {
            s.finish("could not open the event stream");
            return;
        };
        defer stream.close();
        if (stream.status == 401) {
            s.mu.lockUncancelable(s.io);
            if (stream.challenge) |c| s.challenge = s.a.dupe(u8, c) catch null;
            s.mu.unlock(s.io);
            return s.finish("the server wants a sign-in");
        }
        if (!stream.ok()) return s.finish("the server refused the event stream");

        var event_name: []const u8 = "message";
        var name_buf = std.ArrayList(u8).empty;
        defer name_buf.deinit(a);
        var data_buf = std.ArrayList(u8).empty;
        defer data_buf.deinit(a);

        while (true) {
            const maybe_line = stream.next() catch break;
            const line = maybe_line orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) {
                // A blank line ends the event, which is then handed over.
                if (data_buf.items.len > 0) s.handleEvent(event_name, data_buf.items);
                data_buf.clearRetainingCapacity();
                name_buf.clearRetainingCapacity();
                event_name = "message";
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "event:")) {
                const value = std.mem.trim(u8, trimmed["event:".len..], " \t");
                name_buf.clearRetainingCapacity();
                name_buf.appendSlice(a, value) catch continue;
                event_name = name_buf.items;
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "data:")) {
                const value = std.mem.trim(u8, trimmed["data:".len..], " \t");
                if (data_buf.items.len > 0) data_buf.append(a, '\n') catch continue;
                data_buf.appendSlice(a, value) catch continue;
            }
        }
        s.finish("the event stream ended");
    }

    fn handleEvent(s: *Sse, name: []const u8, data: []const u8) void {
        if (std.mem.eql(u8, name, "endpoint")) {
            const resolved = joinUrl(s.a, s.url, data) catch return;
            s.mu.lockUncancelable(s.io);
            if (s.endpoint) |old| s.a.free(old);
            s.endpoint = resolved;
            s.mu.unlock(s.io);
            s.cond.broadcast(s.io);
            return;
        }
        if (s.sess) |sess| sess.handleBytes(data);
    }

    fn finish(s: *Sse, reason: []const u8) void {
        s.mu.lockUncancelable(s.io);
        const first = s.failure == null;
        if (first) s.failure = s.a.dupe(u8, reason) catch null;
        s.dead = true;
        s.mu.unlock(s.io);
        s.cond.broadcast(s.io);
        if (s.sess) |sess| sess.markClosed(reason);
    }
};

/// Turns the endpoint a server announced into an address to post to.
pub fn joinUrl(a: std.mem.Allocator, base: []const u8, reference: []const u8) ![]u8 {
    if (web.isRemote(reference)) return a.dupe(u8, reference);
    const origin_end = originEnd(base);
    const origin = base[0..origin_end];
    if (std.mem.startsWith(u8, reference, "/")) {
        return std.fmt.allocPrint(a, "{s}{s}", .{ origin, reference });
    }
    const path_end = std.mem.lastIndexOfScalar(u8, base, '/') orelse base.len;
    const dir = if (path_end > origin_end) base[0..path_end] else origin;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, reference });
}

/// Where the scheme and host of a URL end.
fn originEnd(url: []const u8) usize {
    const marker = std.mem.indexOf(u8, url, "://") orelse return 0;
    const after = marker + 3;
    const slash = std.mem.indexOfScalarPos(u8, url, after, '/') orelse url.len;
    return slash;
}

fn cloneHeaders(a: std.mem.Allocator, headers: []const web.Header) ![]web.Header {
    const out = try a.alloc(web.Header, headers.len);
    for (headers, 0..) |h, i| {
        out[i] = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
    }
    return out;
}

test "an announced endpoint is resolved against the stream's address" {
    const a = std.testing.allocator;
    const absolute = try joinUrl(a, "https://example.com/sse", "https://other.com/messages");
    defer a.free(absolute);
    try std.testing.expectEqualStrings("https://other.com/messages", absolute);

    const rooted = try joinUrl(a, "https://example.com/sse", "/messages?session=1");
    defer a.free(rooted);
    try std.testing.expectEqualStrings("https://example.com/messages?session=1", rooted);

    const relative = try joinUrl(a, "https://example.com/api/sse", "messages");
    defer a.free(relative);
    try std.testing.expectEqualStrings("https://example.com/api/messages", relative);

    const plain = try joinUrl(a, "https://example.com/sse", "messages");
    defer a.free(plain);
    try std.testing.expectEqualStrings("https://example.com/messages", plain);
}
