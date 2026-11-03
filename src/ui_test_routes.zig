//! The Routes page's tests: only live agents are listed, with what they have
//! called and how long they have been connected.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const state = @import("state.zig");
const auth = @import("auth.zig");
const ui_test = @import("ui_test.zig");

const Fixture = ui_test.Fixture;

test "the routes page names the live agents and counts their calls" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();

    const now = auth.now(std.testing.io);
    _ = f.app.gw.routes.introduce("sess-1", "Cline", "0.1.0", "2025-06-18", now - 120);
    f.app.gw.routes.called("sess-1", now - 60);
    f.app.gw.routes.called("sess-1", now - 30);
    // An agent that has gone away is no longer a route.
    f.app.gw.routes.connected("sess-2", now - 10);
    f.app.gw.routes.disconnected("sess-2", now - 5);

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .routes;
    t.frame();

    try std.testing.expect(t.hasText("1 connected"));
    try std.testing.expect(t.hasText("Cline"));
    try std.testing.expect(t.hasText("v0.1.0"));
    try std.testing.expect(t.hasText("sess-1"));
    try std.testing.expect(t.hasText("2025-06-18"));
    try std.testing.expect(t.hasText("2 calls"));
    try std.testing.expect(t.hasText("connected 2m ago"));
    try std.testing.expect(!t.hasText("sess-2"));
}

test "the empty routes page points at Settings" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .routes;
    t.frame();

    try std.testing.expect(t.hasText("No agents connected"));
    try std.testing.expect(t.hasText("Point an MCP client at the gateway's endpoints on Settings. Its session shows up here as soon as it connects."));
    try t.clickText("Open Settings");
    try std.testing.expectEqual(state.Page.settings, f.app.page);
}
