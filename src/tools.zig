//! The tools the gateway offers: every upstream tool, under a name that says
//! which server it came from, in one table.
const std = @import("std");
const Io = std.Io;
const json = @import("json_util.zig");

/// What separates the server's name from the tool's in a gateway tool name.
pub const separator = "__";

/// The name of the tool that lists the servers, which is the gateway's own.
pub const meta_tool_name = "gateway" ++ separator ++ "list_servers";

/// One tool, as the gateway offers it.
pub const Entry = struct {
    /// The name a client calls, "filesystem__read_file".
    name: []const u8,
    description: []const u8,
    /// The tool's input schema, as the upstream sent it.
    schema: json.Value,
    /// Which server it came from.
    server_id: []const u8,
    /// The name the upstream knows it by.
    upstream_name: []const u8,
};

/// The tools of every server that is connected.
pub const Registry = struct {
    a: std.mem.Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn init(a: std.mem.Allocator, io: Io) Registry {
        return .{ .a = a, .io = io };
    }

    pub fn deinit(r: *Registry) void {
        r.clear();
        r.map.deinit(r.a);
    }

    /// Adds a tool, replacing one of the same name.
    pub fn add(r: *Registry, entry: Entry) !void {
        const a = r.a;
        const name = try a.dupe(u8, entry.name);
        errdefer a.free(name);

        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);
        if (r.map.fetchRemove(entry.name)) |old| freeEntry(a, old.value);
        try r.map.put(a, name, .{
            .name = name,
            .description = try a.dupe(u8, entry.description),
            .schema = entry.schema,
            .server_id = try a.dupe(u8, entry.server_id),
            .upstream_name = try a.dupe(u8, entry.upstream_name),
        });
    }

    /// Forgets every tool a server offered, which is what disconnecting it
    /// means.
    pub fn removeServer(r: *Registry, server_id: []const u8) void {
        const a = r.a;
        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);

        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(a);
        var it = r.map.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.server_id, server_id)) stale.append(a, kv.key_ptr.*) catch {};
        }
        for (stale.items) |name| {
            if (r.map.fetchRemove(name)) |kv| {
                a.free(kv.key);
                freeEntry(a, kv.value);
            }
        }
    }

    /// How many tools a server offers.
    pub fn countFor(r: *Registry, server_id: []const u8) usize {
        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);
        var n: usize = 0;
        var it = r.map.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.server_id, server_id)) n += 1;
        }
        return n;
    }

    /// Every tool, by name.
    pub fn list(r: *Registry, a: std.mem.Allocator) ![]Entry {
        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);
        const out = try a.alloc(Entry, r.map.count());
        var i: usize = 0;
        var it = r.map.valueIterator();
        while (it.next()) |entry| : (i += 1) out[i] = entry.*;
        std.mem.sort(Entry, out, {}, byName);
        return out;
    }

    /// One tool, or null when no server offers it.
    pub fn find(r: *Registry, name: []const u8) ?Entry {
        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);
        return r.map.get(name);
    }

    pub fn clear(r: *Registry) void {
        const a = r.a;
        r.mu.lockUncancelable(r.io);
        defer r.mu.unlock(r.io);
        var it = r.map.iterator();
        while (it.next()) |kv| {
            a.free(kv.key_ptr.*);
            freeEntry(a, kv.value_ptr.*);
        }
        r.map.clearRetainingCapacity();
    }

    fn byName(_: void, left: Entry, right: Entry) bool {
        return std.mem.lessThan(u8, left.name, right.name);
    }

    fn freeEntry(a: std.mem.Allocator, entry: Entry) void {
        a.free(entry.name);
        a.free(entry.description);
        a.free(entry.server_id);
        a.free(entry.upstream_name);
    }
};

/// The name a gateway tool goes by.
pub fn prefixedName(a: std.mem.Allocator, alias: []const u8, tool_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ alias, separator, tool_name });
}

/// The description a gateway tool carries: the server's name first, so a
/// client can see where it came from.
pub fn describe(a: std.mem.Allocator, server_name: []const u8, description: []const u8) ![]u8 {
    if (description.len == 0) return std.fmt.allocPrint(a, "From {s}.", .{server_name});
    return std.fmt.allocPrint(a, "[{s}] {s}", .{ server_name, description });
}

test "a tool is added under its prefixed name and found again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var r = Registry.init(a, std.testing.io);
    defer r.deinit();

    var schema: json.J = .object(a);
    schema.put("type", .str(a, "object"));
    try r.add(.{
        .name = try prefixedName(a, "filesystem", "read_file"),
        .description = try describe(a, "Files", "Read a file."),
        .schema = schema.v,
        .server_id = "s1",
        .upstream_name = "read_file",
    });
    try r.add(.{
        .name = try prefixedName(a, "git", "status"),
        .description = "",
        .schema = schema.v,
        .server_id = "s2",
        .upstream_name = "status",
    });

    try std.testing.expectEqual(@as(usize, 1), r.countFor("s1"));
    try std.testing.expectEqual(@as(usize, 2), r.map.count());

    const list = try r.list(a);
    try std.testing.expectEqualStrings("filesystem__read_file", list[0].name);
    try std.testing.expectEqualStrings("[Files] Read a file.", list[0].description);
    try std.testing.expectEqualStrings("git__status", list[1].name);

    const found = r.find("git__status").?;
    try std.testing.expectEqualStrings("status", found.upstream_name);
    try std.testing.expect(r.find("nothing") == null);

    r.removeServer("s1");
    try std.testing.expectEqual(@as(usize, 0), r.countFor("s1"));
    try std.testing.expect(r.find("filesystem__read_file") == null);
    try std.testing.expect(r.find("git__status") != null);
}

test "a description with no upstream text still says where it came from" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("From Git.", try describe(a, "Git", ""));
    try std.testing.expectEqualStrings("[Git] Commit.", try describe(a, "Git", "Commit."));
    try std.testing.expectEqualStrings("files__ls", try prefixedName(a, "files", "ls"));
}
