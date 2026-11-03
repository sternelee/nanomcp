//! The frame around every page: the sidebar beside it, its fold, and where
//! the page starts once the sidebar's width settles.
const std = @import("std");
const ui = @import("nanoui").ui;
const config = @import("config.zig");
const ui_test = @import("ui_test.zig");

const Fixture = ui_test.Fixture;

/// Where the page starts, beside the sidebar and its divider.
fn bodyX(t: *ui.Tester) ?f32 {
    for (t.ctx.nodes.items) |n| {
        if (n.style.scroll and n.style.grow > 0.5) return n.rect.x;
    }
    return null;
}

test "the page fills the window beside the sidebar" {
    // The pages build their header, toolbar and body as siblings of the main
    // column. Closing the header with a deferred end put the whole page inside
    // the 54px header row, where everything overflowed and no click could land.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(bodyX(&t).? > 0);
    var found = false;
    var body = t.ctx.nodes.items[0].rect;
    for (t.ctx.nodes.items) |n| {
        if (n.style.scroll and n.style.grow > 0.5) {
            body = n.rect;
            found = true;
        }
    }
    if (!found) return error.NoBody;
    try std.testing.expect(body.w > 700);
    try std.testing.expect(body.h > 500);
    try std.testing.expectEqual(@as(f32, 221), body.x);
}

test "the sidebar folds to a rail, and the fold is remembered" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(!f.app.cfg.sidebar_collapsed);
    try std.testing.expect(t.hasText("Settings"));
    try std.testing.expect(t.hasText("0 of 1 ready"));

    try ui_test.clickIcon(&t, "sidebar.left", 0);
    try std.testing.expect(f.app.cfg.sidebar_collapsed);
    t.settle(1);
    // The rail keeps the icons alone, and the page starts beside it.
    try std.testing.expect(!t.hasText("Settings"));
    try std.testing.expect(!t.hasText("0 of 1 ready"));
    try std.testing.expectApproxEqAbs(@as(f32, 65), bodyX(&t).?, 0.01);

    // The fold is remembered across runs.
    const saved = try config.load(a, std.testing.io, f.app.data_dir);
    try std.testing.expect(saved.sidebar_collapsed);

    try ui_test.clickIcon(&t, "sidebar.left", 0);
    try std.testing.expect(!f.app.cfg.sidebar_collapsed);
    t.settle(1);
    try std.testing.expect(t.hasText("Settings"));
    try std.testing.expectApproxEqAbs(@as(f32, 221), bodyX(&t).?, 0.01);
}

