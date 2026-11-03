//! The conversation with one upstream: requests are written, answers arrive
//! on a reader thread and wake the caller waiting for them.
const std = @import("std");
const Io = std.Io;
const rpc = @import("rpc.zig");
const json = @import("json_util.zig");

pub const Error = error{
    Closed,
    TimedOut,
    WriteFailed,
    ReadFailed,
    ProtocolError,
    OutOfMemory,
    Canceled,
    /// The upstream wants the user to sign in before it answers.
    AuthRequired,
    /// The upstream answered with a status that is not a success.
    BadStatus,
};

/// How a transport moves bytes: writing a message, and ending the connection.
pub const Wire = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, a: std.mem.Allocator, bytes: []const u8) Error!void,
    close: *const fn (ctx: *anyopaque) void,
};

/// What a notification from the upstream means to the gateway.
pub const Listener = struct {
    ctx: *anyopaque,
    /// Called on the reader thread; it must hand work to the main thread.
    onNotification: *const fn (ctx: *anyopaque, method: []const u8, params: json.Value) void,
    /// Called on the reader thread when the connection ends.
    onClose: *const fn (ctx: *anyopaque) void,
};

/// A message that arrived, with the memory it was parsed into. Whoever takes
/// it over frees the arena.
pub const Incoming = struct {
    message: rpc.Message,
    arena: *std.heap.ArenaAllocator,
};

const Waiting = struct {
    response: rpc.Message.Response,
    arena: *std.heap.ArenaAllocator,
    /// Set by the reader thread when the answer has arrived. Until then the
    /// entry is only a place for it, and a waiter must keep waiting.
    answered: bool = false,
};

/// One connection to one upstream, with its requests and their answers.
pub const Session = struct {
    /// How long a call waits for its answer by default: a server that never
    /// answers fails the call, it does not freeze whoever asked.
    pub const default_call_timeout: Io.Clock.Duration = .{ .raw = .fromSeconds(30), .clock = .awake };

    a: std.mem.Allocator,
    io: Io,
    wire: Wire,
    listener: ?Listener = null,
    /// How long a call waits for its answer before failing with TimedOut.
    timeout: Io.Clock.Duration = default_call_timeout,

    mu: Io.Mutex = .init,
    cond: Io.Condition = .init,
    pending: std.AutoHashMapUnmanaged(i64, Waiting) = .empty,
    next_id: i64 = 1,
    closed: bool = false,
    /// Calls currently waiting for their answer; deinit joins them.
    waiters: usize = 0,
    /// Set once the session has been torn down, so closing a connection and
    /// then destroying it does not free the same memory twice.
    dead: bool = false,
    /// The last thing the connection said when it failed.
    failure: ?[]const u8 = null,

    pub fn init(a: std.mem.Allocator, io: Io, wire: Wire) Session {
        return .{ .a = a, .io = io, .wire = wire };
    }

    pub fn deinit(s: *Session) void {
        if (s.dead) return;
        s.dead = true;
        s.wire.close(s.wire.ctx);
        // Callers waiting on an answer leave before anything they wait with
        // is freed from under them.
        s.mu.lockUncancelable(s.io);
        s.closed = true;
        s.cond.broadcast(s.io);
        while (s.waiters > 0) s.cond.waitUncancelable(s.io, &s.mu);
        var it = s.pending.valueIterator();
        while (it.next()) |w| freeArena(s.a, w.arena);
        s.pending.deinit(s.a);
        if (s.failure) |f| s.a.free(f);
        s.mu.unlock(s.io);
    }

    /// Sends a request and waits for its answer. `a` owns the result. A
    /// server that does not answer within `timeout` fails the call.
    pub fn call(s: *Session, a: std.mem.Allocator, method: []const u8, params: json.Value) !json.Value {
        const id = try s.begin();
        const bytes = try rpc.request(a, .{ .number = id }, method, params);
        defer a.free(bytes);
        s.wire.send(s.wire.ctx, a, bytes) catch |err| {
            s.dropWaiting(id);
            return err;
        };
        return s.await(a, id);
    }

    /// Sends a notification, which nothing answers.
    pub fn notify(s: *Session, a: std.mem.Allocator, method: []const u8, params: json.Value) !void {
        const bytes = try rpc.notification(a, method, params);
        defer a.free(bytes);
        try s.wire.send(s.wire.ctx, a, bytes);
    }

    /// Takes the next id and makes room for its answer before it is sent, so
    /// an answer that arrives quickly still finds its place.
    fn begin(s: *Session) !i64 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const id = s.next_id;
        s.next_id += 1;
        try s.pending.put(s.a, id, .{
            .response = .{ .id = .{ .number = id } },
            .arena = try newArena(s.a),
        });
        return id;
    }

    fn dropWaiting(s: *Session, id: i64) void {
        s.mu.lockUncancelable(s.io);
        const kv = s.pending.fetchRemove(id);
        s.mu.unlock(s.io);
        if (kv) |w| freeArena(s.a, w.value.arena);
    }

    fn await(s: *Session, a: std.mem.Allocator, id: i64) !json.Value {
        s.mu.lockUncancelable(s.io);
        s.waiters += 1;
        defer {
            s.waiters -= 1;
            if (s.waiters == 0) s.cond.broadcast(s.io);
            s.mu.unlock(s.io);
        }
        const deadline: Io.Timeout = .{ .deadline = .fromNow(s.io, s.timeout) };
        while (true) {
            if (s.pending.fetchRemove(id)) |kv| {
                if (!kv.value.answered) {
                    // The place was made, but the answer is not in it yet.
                    s.pending.put(s.a, id, kv.value) catch {};
                    if (s.closed) return error.Closed;
                    s.wait(deadline) catch |err| {
                        s.dropWaitingLocked(id);
                        return err;
                    };
                    continue;
                }
                defer freeArena(s.a, kv.value.arena);
                if (kv.value.response.err) |e| {
                    std.log.debug("upstream refused {d}: {s}", .{ e.code, e.message });
                    return error.ProtocolError;
                }
                // The answer lives in the arena, which goes away here, so it is
                // copied into the caller's allocator first.
                return clone(a, kv.value.response.result);
            }
            if (s.closed) return error.Closed;
            s.wait(deadline) catch |err| {
                s.dropWaitingLocked(id);
                return err;
            };
        }
    }

    /// Waits for the answer or the connection's end, until the deadline.
    fn wait(s: *Session, deadline: Io.Timeout) Error!void {
        s.cond.waitTimeout(s.io, &s.mu, deadline) catch |err| switch (err) {
            error.Timeout => return error.TimedOut,
            error.Canceled => return error.Canceled,
        };
    }

    /// Drops the call a caller has stopped waiting for. The mutex is held.
    fn dropWaitingLocked(s: *Session, id: i64) void {
        if (s.pending.fetchRemove(id)) |w| freeArena(s.a, w.value.arena);
    }

    /// Called by a transport's reader thread for every message that arrived.
    pub fn handleMessage(s: *Session, incoming: Incoming) void {
        switch (incoming.message) {
            .response => |r| {
                const id = r.id orelse return freeArena(s.a, incoming.arena);
                const key = switch (id) {
                    .number => |n| n,
                    .text => return freeArena(s.a, incoming.arena),
                };
                s.mu.lockUncancelable(s.io);
                defer s.mu.unlock(s.io);
                if (s.pending.getPtr(key)) |slot| {
                    freeArena(s.a, slot.arena);
                    slot.* = .{ .response = r, .arena = incoming.arena, .answered = true };
                } else {
                    freeArena(s.a, incoming.arena);
                }
                s.cond.broadcast(s.io);
            },
            .notification => |n| {
                if (s.listener) |l| {
                    l.onNotification(l.ctx, n.method, n.params);
                }
                freeArena(s.a, incoming.arena);
            },
            else => freeArena(s.a, incoming.arena),
        }
    }

    /// Marks the connection as ended, waking everyone waiting on it.
    pub fn markClosed(s: *Session, reason: ?[]const u8) void {
        s.mu.lockUncancelable(s.io);
        const already = s.closed;
        s.closed = true;
        if (reason) |r| {
            if (s.failure) |old| s.a.free(old);
            s.failure = s.a.dupe(u8, r) catch null;
        }
        s.mu.unlock(s.io);
        s.cond.broadcast(s.io);
        if (!already) {
            if (s.listener) |l| l.onClose(l.ctx);
        }
    }

    /// Whether the connection has ended, and why.
    pub fn closedReason(s: *Session) ?[]const u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return if (s.closed) s.failure orelse "connection closed" else null;
    }

    /// Whether a call is waiting for an answer that has not arrived yet. A
    /// transport that reads a stream stops once this is false: a server may
    /// keep an event stream open after the answer it carried.
    pub fn awaitsAnswer(s: *Session) bool {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var it = s.pending.valueIterator();
        while (it.next()) |w| {
            if (!w.answered) return true;
        }
        return false;
    }
};

pub fn newArena(a: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try a.create(std.heap.ArenaAllocator);
    arena.* = .init(a);
    return arena;
}

pub fn freeArena(a: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    a.destroy(arena);
}

/// Copies a value into another allocator, so it outlives the buffer it came in.
pub fn clone(a: std.mem.Allocator, v: json.Value) !json.Value {
    switch (v) {
        .null, .bool, .integer, .float, .number_string => return v,
        .string => |s| return .{ .string = try a.dupe(u8, s) },
        .array => |arr| {
            var out: json.Array = .init(a);
            for (arr.items) |item| try out.append(try clone(a, item));
            return .{ .array = out };
        },
        .object => |o| {
            var out: json.Object = .empty;
            var it = o.iterator();
            while (it.next()) |kv| {
                try out.put(a, try a.dupe(u8, kv.key_ptr.*), try clone(a, kv.value_ptr.*));
            }
            return .{ .object = out };
        },
    }
}

/// A wire that answers every request on the spot, the way a fast server would.
const EchoWire = struct {
    sess: ?*Session = null,
    a: std.mem.Allocator,
    seen: std.ArrayList([]u8) = .empty,

    const Self = @This();

    fn wire(self: *EchoWire) Wire {
        return .{ .ctx = self, .send = send, .close = close };
    }

    fn send(ctx: *anyopaque, a: std.mem.Allocator, bytes: []const u8) Error!void {
        _ = a;
        const self: *EchoWire = @ptrCast(@alignCast(ctx));
        try self.seen.append(self.a, self.a.dupe(u8, bytes) catch return error.OutOfMemory);
        const sess = self.sess.?;
        const arena = newArena(self.a) catch return error.OutOfMemory;
        const message = rpc.Message.parse(arena.allocator(), bytes);
        switch (message) {
            .request => |req| {
                const result_arena = arena.allocator();
                var result: json.Object = .empty;
                result.put(result_arena, "echo", .{ .string = req.method }) catch
                    return error.OutOfMemory;
                sess.handleMessage(.{
                    .message = .{ .response = .{
                        .id = req.id,
                        .result = .{ .object = result },
                    } },
                    .arena = arena,
                });
            },
            else => freeArena(self.a, arena),
        }
    }

    fn close(ctx: *anyopaque) void {
        const self: *EchoWire = @ptrCast(@alignCast(ctx));
        for (self.seen.items) |item| self.a.free(item);
        self.seen.deinit(self.a);
    }
};

test "an answer that arrives while sending still reaches the caller" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var echo = EchoWire{ .a = a };
    var sess = Session.init(a, std.testing.io, echo.wire());
    echo.sess = &sess;
    defer sess.deinit();

    const result = try sess.call(a, "tools/list", .{ .object = .empty });
    try std.testing.expectEqualStrings("tools/list", json.getString(result, "echo").?);
    try std.testing.expectEqual(@as(usize, 1), echo.seen.items.len);
    try std.testing.expect(std.mem.indexOf(u8, echo.seen.items[0], "\"id\":1") != null);
}

/// A wire that swallows every request and never answers.
const SilentWire = struct {
    fn wire(self: *SilentWire) Wire {
        return .{ .ctx = self, .send = send, .close = close };
    }
    fn send(ctx: *anyopaque, a: std.mem.Allocator, bytes: []const u8) Error!void {
        _ = ctx;
        _ = a;
        _ = bytes;
    }
    fn close(ctx: *anyopaque) void {
        _ = ctx;
    }
};

test "a call whose answer never comes times out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var silent = SilentWire{};
    var sess = Session.init(a, std.testing.io, silent.wire());
    sess.timeout = .{ .raw = .fromMilliseconds(50), .clock = .awake };
    defer sess.deinit();

    try std.testing.expectError(error.TimedOut, sess.call(a, "initialize", .{ .object = .empty }));
}

test "a closed connection wakes the caller with an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var echo = EchoWire{ .a = a };
    var sess = Session.init(a, std.testing.io, echo.wire());
    defer sess.deinit();

    sess.markClosed("the server went away");
    try std.testing.expectEqualStrings("the server went away", sess.closedReason().?);
    try std.testing.expectError(error.Closed, sess.await(a, 99));
}

test "a value is copied out of the buffer it arrived in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var source_buf: [64]u8 = undefined;
    const text = "{\"a\":[1,\"two\",{\"b\":true}]}";
    @memcpy(source_buf[0..text.len], text);
    const parsed = try json.parse(a, source_buf[0..text.len]);

    var other = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer other.deinit();
    const copy = try clone(other.allocator(), parsed);
    @memset(source_buf[0..], 'x');

    try std.testing.expectEqualStrings("two", json.getArray(copy, "a").?.items[1].string);
    try std.testing.expect(json.getArray(copy, "a").?.items[2].object.get("b").?.bool);
}
