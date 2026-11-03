//! The agents connected to the gateway: one entry per MCP session that has
//! introduced itself, with what it called and when.
const std = @import("std");
const Io = std.Io;
const nanoui = @import("nanoui");
const json = @import("json_util.zig");
const rpc = @import("rpc.zig");

pub const View = struct {
    id: []const u8 = "",
    client: []const u8 = "",
    version: []const u8 = "",
    protocol: []const u8 = "",
    connected: bool = false,
    /// When the gateway first saw the agent.
    connected_at: i64 = 0,
    last_active: i64 = 0,
    calls: u32 = 0,
};

const Entry = struct {
    id: []const u8,
    client: []const u8 = "",
    version: []const u8 = "",
    protocol: []const u8 = "",
    connected: bool = false,
    connected_at: i64 = 0,
    last_active: i64 = 0,
    calls: u32 = 0,
};

/// Every session the gateway has seen, keyed by its identifier.
pub const Registry = struct {
    a: std.mem.Allocator,
    io: Io,
    /// Requests are served on many threads; the interface reads on its own.
    mu: Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(*Entry) = .{},

    const Self = @This();

    pub fn init(a: std.mem.Allocator, io: Io) Self {
        return .{ .a = a, .io = io };
    }

    pub fn deinit(s: *Self) void {
        var it = s.map.valueIterator();
        while (it.next()) |slot| s.freeEntry(slot.*);
        var keys = s.map.keyIterator();
        while (keys.next()) |k| s.a.free(k.*);
        s.map.deinit(s.a);
    }

    /// Records a session that has just connected.
    pub fn connected(s: *Self, id: []const u8, now: i64) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const e = s.entry(id) catch return;
        if (!e.connected) e.connected_at = now;
        e.connected = true;
        e.last_active = now;
    }

    /// Records a session going away.
    pub fn disconnected(s: *Self, id: []const u8, now: i64) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const e = s.map.get(id) orelse return;
        e.connected = false;
        e.last_active = now;
    }

    /// Takes the name a client gave in `initialize`, and the protocol it speaks.
    /// Returns whether this is the first time that name was seen, which the
    /// gateway notes in the activity.
    pub fn introduce(s: *Self, id: []const u8, client: []const u8, version: []const u8, protocol: []const u8, now: i64) bool {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const e = s.entry(id) catch return false;
        const named = client.len > 0 and !std.mem.eql(u8, e.client, client);
        const name_copy = s.a.dupe(u8, client) catch "";
        const release = s.a.dupe(u8, version) catch "";
        const spoken = s.a.dupe(u8, protocol) catch "";
        s.freeStrings(e);
        e.client = name_copy;
        e.version = release;
        e.protocol = spoken;
        if (!e.connected) e.connected_at = now;
        e.connected = true;
        e.last_active = now;
        return named;
    }

    /// Counts a tool call from a session.
    pub fn called(s: *Self, id: []const u8, now: i64) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const e = s.map.get(id) orelse return;
        e.calls += 1;
        e.last_active = now;
    }

    /// Takes a session off the routes when its client goes away, and returns
    /// what it called itself, copied into `a`, for the activity note.
    pub fn remove(s: *Self, a: std.mem.Allocator, id: []const u8) ?[]const u8 {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const gone = s.map.fetchRemove(id) orelse return null;
        const label = a.dupe(u8, describe(gone.value.id, gone.value.client)) catch "";
        s.freeEntry(gone.value);
        s.a.free(gone.key);
        return label;
    }

    /// Every session, the connected ones first. The strings are copies, so a
    /// frame can paint them after a session has gone.
    pub fn list(s: *Self, a: std.mem.Allocator) ![]View {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var out: std.ArrayList(View) = .empty;
        errdefer out.deinit(a);
        var it = s.map.valueIterator();
        while (it.next()) |slot| {
            const e = slot.*;
            try out.append(a, .{
                .id = try a.dupe(u8, e.id),
                .client = try a.dupe(u8, e.client),
                .version = try a.dupe(u8, e.version),
                .protocol = try a.dupe(u8, e.protocol),
                .connected = e.connected,
                .connected_at = e.connected_at,
                .last_active = e.last_active,
                .calls = e.calls,
            });
        }
        std.mem.sort(View, out.items, {}, lessConnected);
        return out.toOwnedSlice(a);
    }

    fn lessConnected(_: void, left: View, right: View) bool {
        if (left.connected != right.connected) return left.connected;
        // Longest-connected first, as the Go gateway lists its sessions.
        return left.connected_at < right.connected_at;
    }

    /// Whether a session identifier is one this registry opened. A client that
    /// invents one is not recorded under it.
    pub fn known(s: *Self, id: []const u8) bool {
        if (id.len == 0) return false;
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.map.contains(id);
    }

    /// How many sessions there are, connected or not.
    pub fn count(s: *Self) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        return s.map.count();
    }

    /// How many agents are connected now.
    pub fn connectedCount(s: *Self) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var n: usize = 0;
        var it = s.map.valueIterator();
        while (it.next()) |slot| {
            if (slot.*.connected) n += 1;
        }
        return n;
    }

    /// Empties the table, for a fresh start.
    pub fn clear(s: *Self) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var it = s.map.valueIterator();
        while (it.next()) |slot| s.freeEntry(slot.*);
        var keys = s.map.keyIterator();
        while (keys.next()) |k| s.a.free(k.*);
        s.map.clearRetainingCapacity();
    }

    fn freeStrings(s: *Self, e: *Entry) void {
        freeOwned(s.a, e.client);
        freeOwned(s.a, e.version);
        freeOwned(s.a, e.protocol);
        e.client = "";
        e.version = "";
        e.protocol = "";
    }

    fn freeEntry(s: *Self, e: *Entry) void {
        s.freeStrings(e);
        s.a.destroy(e);
    }

    fn entry(s: *Self, id: []const u8) !*Entry {
        if (s.map.get(id)) |e| return e;
        s.pruneLocked();
        const key = try s.a.dupe(u8, id);
        errdefer s.a.free(key);
        const e = try s.a.create(Entry);
        errdefer s.a.destroy(e);
        e.* = .{ .id = key };
        try s.map.put(s.a, key, e);
        return e;
    }

    /// The most sessions the table keeps. A client that never says goodbye
    /// must not make the list grow without bound.
    const max_entries: usize = 512;

    /// Drops the longest-idle sessions that are no longer connected, and the
    /// longest-idle of all if every one is still connected.
    fn pruneLocked(s: *Self) void {
        while (s.map.count() >= max_entries) {
            var victim: ?[]const u8 = null;
            var oldest: i64 = std.math.maxInt(i64);
            var it = s.map.iterator();
            while (it.next()) |kv| {
                const e = kv.value_ptr.*;
                if (e.connected) continue;
                if (victim == null or e.last_active < oldest) {
                    oldest = e.last_active;
                    victim = kv.key_ptr.*;
                }
            }
            if (victim == null) {
                var all = s.map.iterator();
                while (all.next()) |kv| {
                    const e = kv.value_ptr.*;
                    if (e.last_active < oldest) {
                        oldest = e.last_active;
                        victim = kv.key_ptr.*;
                    }
                }
            }
            const id = victim orelse return;
            if (s.map.fetchRemove(id)) |gone| {
                s.freeEntry(gone.value);
                s.a.free(gone.key);
            }
        }
    }
};

/// What a session called itself in `initialize`, and what it speaks.
pub const Identity = struct {
    client: []const u8 = "",
    version: []const u8 = "",
    protocol: []const u8 = "",
};

/// Reads the identity out of an initialize request's params.
pub fn identityOf(params: ?json.Value) Identity {
    const p = params orelse return .{};
    var out: Identity = .{};
    if (json.getString(p, "protocolVersion")) |v| out.protocol = v;
    if (json.get(p, "clientInfo")) |info| {
        if (json.getString(info, "name")) |v| out.client = v;
        if (json.getString(info, "version")) |v| out.version = v;
    }
    return out;
}

/// What a client is called in a list: its own name, or its identifier.
pub fn describe(id: []const u8, client: []const u8) []const u8 {
    if (client.len > 0) return client;
    return id;
}

/// Frees a string an entry owns, unless it is the shared empty one.
fn freeOwned(a: std.mem.Allocator, s: []const u8) void {
    if (s.len > 0) a.free(s);
}
