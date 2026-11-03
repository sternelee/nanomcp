//! What the gateway shows: the servers it aggregates, their tools, its
//! activity list, and the URLs and documents that describe it. Kept apart from
//! connecting and serving, which is what gateway.zig is for.
const std = @import("std");
const json = @import("json_util.zig");
const gateway_mod = @import("gateway.zig");

const Gateway = gateway_mod.Gateway;
pub const ServerView = gateway_mod.ServerView;
pub const ToolView = gateway_mod.ToolView;
pub const Event = gateway_mod.Event;
pub const Status = gateway_mod.Status;

/// The activity entries, oldest first.
pub fn eventsOf(g: *Gateway, a: std.mem.Allocator) ![]Event {
    g.mu.lockUncancelable(g.io);
    defer g.mu.unlock(g.io);
    return a.dupe(Event, g.events.items);
}

/// Every configured server with its live state.
pub fn servers(g: *Gateway, a: std.mem.Allocator) ![]ServerView {
    g.mu.lockUncancelable(g.io);
    defer g.mu.unlock(g.io);

    const views = try a.alloc(ServerView, g.cfg.servers.len);
    for (g.cfg.servers, 0..) |sc, i| {
        var status: Status = g.status.get(sc.id) orelse .disabled;
        if (!sc.enabled) status = .disabled;
        views[i] = .{
            .config = sc,
            .status = status,
            .err = g.errs.get(sc.id) orelse "",
            .tools = g.tools.countFor(sc.id),
            .signed_in = g.signed_in.get(sc.id) orelse false,
        };
    }
    return views;
}

/// One server's live state.
pub fn serverOf(g: *Gateway, id: []const u8) !?ServerView {
    const views = try servers(g, g.a);
    defer g.a.free(views);
    for (views) |v| {
        if (std.mem.eql(u8, v.config.id, id)) return v;
    }
    return null;
}

/// The aggregated tools, by name.
pub fn toolViews(g: *Gateway, a: std.mem.Allocator) ![]ToolView {
    const entries = try g.tools.list(a);
    const views = try a.alloc(ToolView, entries.len);
    for (entries, 0..) |entry, i| {
        views[i] = .{
            .name = entry.name,
            .upstream = entry.upstream_name,
            .server_id = entry.server_id,
            .server_name = g.serverName(entry.server_id),
            .description = entry.description,
            .schema = json.J.from(a, entry.schema).dumpIndent() catch "",
        };
    }
    a.free(entries);
    return views;
}

/// Where the gateway serves, or the configured port's URL when it is not.
pub fn baseURL(g: *Gateway, a: std.mem.Allocator) ![]u8 {
    const live = g.servingPort();
    const port = if (live != 0) live else g.cfg.port;
    return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
}

/// Where an authorization server sends the browser back.
pub fn redirectURI(g: *Gateway, a: std.mem.Allocator) ![]u8 {
    const base = try baseURL(g, a);
    defer a.free(base);
    return std.fmt.allocPrint(a, "{s}/oauth/callback", .{base});
}

/// The URLs the gateway serves, for the interface to show.
pub fn endpoints(g: *Gateway, a: std.mem.Allocator) ![]const []const u8 {
    const base = try baseURL(g, a);
    defer a.free(base);
    const out = try a.alloc([]const u8, 4);
    out[0] = try std.fmt.allocPrint(a, "{s}/mcp", .{base});
    out[1] = try std.fmt.allocPrint(a, "{s}/sse", .{base});
    out[2] = try std.fmt.allocPrint(a, "{s}/message", .{base});
    out[3] = try std.fmt.allocPrint(a, "{s}/healthz", .{base});
    return out;
}

/// The answer to the readiness probe.
pub fn healthJSON(g: *Gateway, a: std.mem.Allocator) ![]u8 {
    var doc: json.J = .object(a);
    doc.put("status", .str(a, "ok"));
    doc.put("tools", .int(a, @intCast(g.tools.count())));
    return doc.dump();
}

/// The answer to the gateway's own meta tool: the servers it aggregates.
pub fn metaToolJSON(g: *Gateway, a: std.mem.Allocator) ![]u8 {
    const views = try servers(g, a);
    var doc: json.J = .object(a);
    var list: json.J = .array(a);
    for (views) |v| {
        var row: json.J = .object(a);
        row.put("name", .str(a, v.config.name));
        row.put("transport", .str(a, v.config.transport.name()));
        row.put("status", .str(a, v.status.label()));
        row.put("tools", .int(a, @intCast(v.tools)));
        row.putText("error", v.err);
        list.add(row);
    }
    doc.put("servers", list);
    doc.put("tools", .int(a, @intCast(g.tools.count())));
    return doc.dumpIndent();
}

test "the activity list keeps what the gateway did" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const config = @import("config.zig");
    const credentials = @import("credentials.zig");

    var cfg = config.Config.default();
    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();

    var g = Gateway.init(a, std.testing.io, &cfg, &store, "0.1.0");
    defer _ = g.deinit();

    g.note("", "serving on http://127.0.0.1:7331", false);
    const events = try eventsOf(&g, a);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("serving on http://127.0.0.1:7331", events[0].text);
    try std.testing.expect(!events[0].is_err);

    try std.testing.expectEqualStrings("needs-auth", Status.needs_auth.label());
    try std.testing.expectEqualStrings("error", Status.failed.label());
    try std.testing.expect(!g.serving());
    try std.testing.expectEqual(@as(u16, 0), g.servingPort());
    try std.testing.expectEqualStrings("http://127.0.0.1:7331", try baseURL(&g, a));
    try std.testing.expectEqualStrings("http://127.0.0.1:7331/oauth/callback", try redirectURI(&g, a));
}

test "the meta tool describes the configured servers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const config = @import("config.zig");
    const credentials = @import("credentials.zig");

    var cfg = config.Config.default();
    try cfg.upsert(a, .{ .id = "s1", .name = "Files", .transport = .stdio, .command = "fs" });

    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();
    var g = Gateway.init(a, std.testing.io, &cfg, &store, "0.1.0");
    defer _ = g.deinit();

    const doc = try json.parse(a, try metaToolJSON(&g, a));
    const list = json.getArray(doc, "servers").?;
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("Files", json.getString(list.items[0], "name").?);
    try std.testing.expectEqualStrings("stdio", json.getString(list.items[0], "transport").?);
    try std.testing.expectEqualStrings("disabled", json.getString(list.items[0], "status").?);
    try std.testing.expectEqual(@as(i64, 0), json.getInt(doc, "tools").?);

    const views = try servers(&g, a);
    try std.testing.expectEqual(@as(usize, 1), views.len);
    try std.testing.expectEqual(@as(usize, 0), views[0].tools);
    const one = try serverOf(&g, "s1");
    try std.testing.expectEqualStrings("Files", one.?.config.name);
}
