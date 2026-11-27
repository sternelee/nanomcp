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

    // The row's own menu: the header carries no Remove, so a server is only
    // removed from the row it is in.
    try ui_test.clickIcon(&t, "ellipsis", 0);
    try t.clickText("Remove");
    try std.testing.expect(t.hasText("Remove \u{201c}Filesystem\u{201d}?"));
    try t.clickText("Cancel");
    try std.testing.expect(ui_test.serverNamed(&f.app, "Filesystem") != null);

    try ui_test.clickIcon(&t, "ellipsis", 0);
    try t.clickText("Remove"); // the menu's
    try t.clickText("Remove"); // the question's
    try std.testing.expect(ui_test.serverNamed(&f.app, "Filesystem") == null);
    try std.testing.expect(t.hasText("No servers yet"));
    try std.testing.expect(t.hasText("Filesystem removed"));
}

test "Export shows the block another client reads, and the header has no Remove" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    // Removing a server is the row menu's business now.
    try std.testing.expectEqual(@as(usize, 0), ui_test.countText(&t, "Remove"));

    try t.clickText("Export…");
    try std.testing.expect(t.hasText("Export configuration"));

    // The block the dialog shows is the one the action wrote: a wrapper the
    // importing side reads, with this server in it.
    const text = f.app.servers.export_text;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mcpServers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Filesystem\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"command\": \"npx\"") != null);
    var shown = false;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, text)) {
            shown = true;
        },
        else => {},
    };
    try std.testing.expect(shown);

    try t.clickText("Close");
    try std.testing.expect(!t.hasText("Export configuration"));
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
    t.typeText("{\n\"mcpServers\": {\n\"Example\": {\"command\": \"npx\"}\n}\n}");
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

    try ui_test.clickIcon(&t, "ellipsis", 0);
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

test "an idle window asks for no frames" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    t.advance(1);
    t.frame();
    try std.testing.expect(t.ctx.frame_in == null);
}

test "a focused field keeps a fine, steady beat for its caret" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Paste a configuration…");
    t.frame();
    try std.testing.expect(t.ctx.frame_in != null);
    // A caret sampled twice a second aliases its own blink: the dialog
    // appears to flicker. While a field has the focus the window keeps a
    // beat fine enough to show the caret on and off regularly.
    try std.testing.expect(t.ctx.frame_in.? <= 1.0 / 15.0 + 1e-6);
}

test "the paste dialog's description wraps inside the dialog" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Paste a configuration…");
    t.frame();
    const r = t.findText("The mcpServers block from Claude Desktop, Cursor or VS Code works as it stands. A server whose name is already here is replaced.") orelse
        return error.TextNotFound;
    // The dialog is 520 points wide, with 20 points of padding each side.
    try std.testing.expectApproxEqAbs(@as(f32, 480), r.w, 1);
}

test "the remove dialog's description wraps inside the dialog" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ui_test.stdioServer()});
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try ui_test.clickIcon(&t, "ellipsis", 0);
    try t.clickText("Remove");
    t.frame();
    const r = t.findText("Its tools are withdrawn from the gateway, and its saved sign-in is forgotten.") orelse
        return error.TextNotFound;
    // The dialog is 400 points wide, with 20 points of padding each side.
    try std.testing.expectApproxEqAbs(@as(f32, 360), r.w, 1);
}

/// The box a grid card is drawn in: the only boxes 280 by 128 on the page.
fn cardBox(t: *ui.Tester, nth: usize) ?struct { rect: ui.Rect, index: u32 } {
    var seen: usize = 0;
    for (t.ctx.nodes.items, 0..) |n, i| {
        const w = n.style.width;
        const h = n.style.height;
        if (w != .px or h != .px or w.px != 280 or h.px != 128) continue;
        if (seen == nth) return .{ .rect = n.rect, .index = @intCast(i) };
        seen += 1;
    }
    return null;
}

/// The top of the box that scrolls around a node.
fn scrollTop(t: *ui.Tester, start: u32) f32 {
    var i = start;
    while (t.ctx.nodes.items[i].parent != std.math.maxInt(u32)) {
        i = t.ctx.nodes.items[i].parent;
        if (t.ctx.nodes.items[i].style.scroll) return t.ctx.nodes.items[i].rect.y;
    }
    return -std.math.inf(f32);
}

test "a grid card lifts under the pointer and keeps its top inside the list" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try Fixture.init(a, &.{ ui_test.stdioServer(), ui_test.secondRemoteServer() });
    defer f.deinit();
    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    try t.clickText("Grid");
    t.frame();
    const rest = cardBox(&t, 0) orelse return error.CardNotFound;
    // The first card starts below the top of the list, not on it.
    try std.testing.expect(rest.rect.y > scrollTop(&t, rest.index));

    const name = t.findText("Filesystem") orelse return error.TextNotFound;
    t.moveTo(name.x + name.w / 2, name.y + name.h / 2);
    t.settle(1);
    const lifted = cardBox(&t, 0) orelse return error.CardNotFound;
    try std.testing.expectApproxEqAbs(rest.rect.y - 3, lifted.rect.y, 0.5);

    // Lifted, it is still inside the list: the top is not cut away.
    try std.testing.expect(lifted.rect.y >= scrollTop(&t, lifted.index));
}
