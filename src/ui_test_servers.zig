//! The Servers page's tests: its menu, dialogs, grid, and filter. The
//! fixtures they build on live in ui_test.zig, which the test runner loads
//! alongside these.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const state = @import("state.zig");
const ui_test = @import("ui_test.zig");

const Fixture = ui_test.Fixture;

test "a row's … opens its menu, whose Edit opens the form" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try ui_test.clickIcon(&t, "ellipsis", 0);
    try std.testing.expectEqual(@as(usize, 2), ui_test.countText(&t, "Edit…"));
    try ui_test.clickNth(&t, "Edit…", 1);
    try std.testing.expect(t.hasText("Edit server"));
}

test "double-clicking a row opens the form" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    const r = t.findText("Filesystem") orelse return error.TextNotFound;
    t.doubleClick(r.x + 4, r.y + r.h / 2);
    try std.testing.expect(t.hasText("Edit server"));
}

test "removing a server asks first, then takes it away" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Remove");
    try std.testing.expect(t.hasText("Remove \u{201c}Filesystem\u{201d}?"));
    try t.clickText("Cancel");
    try std.testing.expect(ui_test.serverNamed(&f.app, "Filesystem") != null);

    try t.clickText("Remove");
    try ui_test.clickNth(&t, "Remove", 1);
    try std.testing.expect(ui_test.serverNamed(&f.app, "Filesystem") == null);
    try std.testing.expect(t.hasText("No servers yet"));
    try std.testing.expect(t.hasText("Filesystem removed"));
}

test "the add form shows its fields" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Add server…");
    try std.testing.expect(t.hasText("Add a server"));
    // The title alone is not the form: its fields must have room to show.
    // They sit in a scrolling body, which a zero height would clip away.
    for ([_][]const u8{ "Name", "Transport", "Command", "Arguments", "Environment", "Enabled" }) |label| {
        var found: ?usize = null;
        for (t.ctx.nodes.items, 0..) |n, j| {
            switch (n.content) {
                .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
                    found = j;
                    break;
                },
                else => {},
            }
        }
        var i = found orelse return error.TextNotFound;
        const r = t.ctx.nodes.items[i].rect;
        if (r.w <= 0 or r.h <= 0) return error.FieldHidden;
        while (t.ctx.nodes.items[i].parent != std.math.maxInt(u32)) {
            i = t.ctx.nodes.items[i].parent;
            if (!t.ctx.nodes.items[i].style.scroll) continue;
            if (t.ctx.nodes.items[i].rect.h <= 0 or t.ctx.nodes.items[i].rect.w <= 0)
                return error.FieldClipped;
            break;
        }
    }
}

test "pasting a configuration adds its servers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Paste a configuration…");
    try std.testing.expect(t.hasText("Paste a configuration"));
    // The area has the focus as it opens.
    t.typeText("{\"mcpServers\":{\"Example\":{\"command\":\"echo\",\"args\":[\"hi\"]}}}");
    try t.clickText("Import");
    try std.testing.expect(ui_test.serverNamed(&f.app, "Example") != null);
    try std.testing.expect(t.hasText("Example"));
}

/// Clicks just under a field's label, inside the field itself.
fn clickBelow(t: *ui.Tester, label: []const u8) !void {
    const r = t.findText(label) orelse return error.TextNotFound;
    t.click(r.x + 30, r.y + r.h + 24);
}

test "the add form saves arguments one per line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Add server…");
    // The name has the focus as the form opens.
    t.typeText("Example");
    try t.clickText("npx");
    t.typeText("echo");
    try clickBelow(&t, "Arguments");
    t.typeText("a\nb");
    try t.clickText("Save");

    const sc = ui_test.serverNamed(&f.app, "Example") orelse return error.ServerNotFound;
    try std.testing.expectEqualStrings("echo", sc.command.?);
    try std.testing.expectEqual(@as(usize, 2), sc.args.?.len);
    try std.testing.expectEqualStrings("a", sc.args.?[0]);
    try std.testing.expectEqualStrings("b", sc.args.?[1]);
}

test "the import area takes a configuration as it opens" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Paste a configuration…");
    // No click: the area is focused when the dialog opens.
    try std.testing.expect(t.ctx.focused_text != null);
    t.typeText("{\n\"mcpServers\": {\n\"Example\": {\"command\": \"echo\"}\n}\n}");
    try t.clickText("Import");
    try std.testing.expect(ui_test.serverNamed(&f.app, "Example") != null);
}

test "Escape dismisses a dialog instead of leaving its page" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    f.app.page = .tools;
    f.app.servers.editing = "new-id";
    f.app.servers.focus_form = true;
    t.frame();
    try std.testing.expect(t.hasText("Add a server"));

    t.key(.escape);
    try std.testing.expect(f.app.servers.editing == null);
    try std.testing.expectEqual(state.Page.tools, f.app.page);
    try std.testing.expect(!t.hasText("Add a server"));
}

test "a click outside the dialog closes it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Add server…");
    try std.testing.expect(t.hasText("Add a server"));
    t.click(8, 8);
    try std.testing.expect(f.app.servers.editing == null);
    try std.testing.expect(!t.hasText("Add a server"));
}

test "Escape cancels the removal question" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Remove");
    try std.testing.expect(t.hasText("Remove \u{201c}Filesystem\u{201d}?"));
    t.key(.escape);
    try std.testing.expect(!t.hasText("Remove \u{201c}Filesystem\u{201d}?"));
    try std.testing.expect(ui_test.serverNamed(&f.app, "Filesystem") != null);
}

test "the grid shows the same servers and drops the list's tip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ ui_test.stdioServer(), ui_test.secondRemoteServer() });
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try std.testing.expect(t.containsText("Double-click a server to edit it."));
    try t.clickText("Grid");
    try std.testing.expect(t.hasText("Filesystem"));
    try std.testing.expect(t.hasText("Remote"));
    try std.testing.expect(!t.containsText("Double-click a server to edit it."));
    try t.clickText("List");
    try std.testing.expect(t.containsText("Double-click a server to edit it."));
}

test "the status word survives its color change" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{ui_test.remoteServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    ui_test.setStatus(f, "s1", .ready);
    t.frame();
    try std.testing.expect(t.hasText("ready"));

    ui_test.setStatus(f, "s1", .failed);
    ui_test.setError(f, "s1", "the connection was refused");
    t.frame();
    try std.testing.expect(t.hasText("error"));
}

test "the filter narrows the rows and says when nothing matches" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ ui_test.stdioServer(), ui_test.secondRemoteServer() });
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Filter by name, command or URL…");
    t.typeText("remote");
    try std.testing.expect(!t.hasText("Filesystem"));
    try std.testing.expect(t.hasText("Remote"));
    t.typeText("zzz");
    try std.testing.expect(t.hasText("No servers match"));
    try std.testing.expect(t.hasText("Nothing matches \"remotezzz\"."));
    try t.clickText("Clear the filter");
    try std.testing.expect(t.hasText("Filesystem"));
}
