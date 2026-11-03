//! nanomcp's tests: behavior kept from the Go original, plus the modules that
//! only have inline tests.
const std = @import("std");

const modules = .{
    @import("config.zig"),
    @import("credentials.zig"),
    @import("json_util.zig"),
    @import("rpc.zig"),
    @import("http_client.zig"),
    @import("session.zig"),
    @import("transport_stdio.zig"),
    @import("transport_http.zig"),
    @import("transport_sse.zig"),
    @import("upstream.zig"),
    @import("import.zig"),
    @import("tokens.zig"),
    @import("server.zig"),
    @import("registry.zig"),
    @import("tools.zig"),
    @import("auth.zig"),
    @import("gateway.zig"),
    @import("gateway_views.zig"),
    @import("gateway_http.zig"),
    @import("mcp_endpoint.zig"),
    @import("oauth_client.zig"),
    @import("oauth.zig"),
    @import("sessions.zig"),
    @import("state.zig"),
    @import("menubar.zig"),
};

test {
    inline for (modules) |m| std.testing.refAllDecls(m);
    _ = @import("config_test.zig");
    _ = @import("gateway_test.zig");
    _ = @import("gateway_flow_test.zig");
    _ = @import("oauth_test.zig");
    _ = @import("oauth_server_test.zig");
    _ = @import("ui_test.zig");
    _ = @import("ui_test_servers.zig");
    _ = @import("ui_test_routes.zig");
    _ = @import("ui_test_market.zig");
    _ = @import("ui_test_tools.zig");
    _ = @import("ui_test_window.zig");
}

test "the routes registry records a session, longest connected first" {
    var registry = @import("sessions.zig").Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    _ = registry.introduce("a", "Claude Code", "1.2.3", "2025-06-18", 100);
    registry.connected("b", 50);
    registry.called("a", 200);

    const list = try registry.list(a);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    // "b" connected first; "a" has all fields recorded.
    try std.testing.expect(std.mem.eql(u8, list[0].id, "b"));
    try std.testing.expectEqualStrings(list[0].id, @import("sessions.zig").describe(list[0].id, list[0].client));
    try std.testing.expect(std.mem.eql(u8, list[1].id, "a"));
    try std.testing.expectEqualStrings("Claude Code", list[1].client);
    try std.testing.expectEqual(@as(u32, 1), list[1].calls);
    try std.testing.expectEqual(@as(i64, 200), list[1].last_active);
    try std.testing.expectEqual(@as(i64, 100), list[1].connected_at);

    // A session that ends takes its strings with it, and is named on the way.
    const who = registry.remove(a, "a") orelse return error.StillThere;
    try std.testing.expectEqualStrings("Claude Code", who);
    const left = try registry.list(a);
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("b", left[0].id);
    try std.testing.expect(registry.remove(a, "a") == null);
}

test "a session identifier is only known once the gateway opens it" {
    var registry = @import("sessions.zig").Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();

    try std.testing.expect(!registry.known(""));
    try std.testing.expect(!registry.known("invented"));
    registry.connected("sess-1", 10);
    try std.testing.expect(registry.known("sess-1"));
}

test "the routes table drops the longest-idle sessions once it is full" {
    var registry = @import("sessions.zig").Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();

    var buf: [32]u8 = undefined;
    for (0..600) |i| {
        const id = try std.fmt.bufPrint(&buf, "sess-{d}", .{i});
        registry.connected(id, @intCast(i));
        registry.disconnected(id, @intCast(i));
    }
    try std.testing.expect(registry.count() <= 512);
    try std.testing.expect(!registry.known("sess-0"));
    try std.testing.expect(registry.known("sess-599"));
}
