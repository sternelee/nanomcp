//! The Tools page against the real widgets: the table, the filter, the chosen
//! tool's detail, and a call's answer.
const std = @import("std");
const ui = @import("nanoui").ui;
const json = @import("json_util.zig");
const page_tools = @import("page_tools.zig");

const ui_test = @import("ui_test.zig");
const Fixture = ui_test.Fixture;

const object_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}";
const search_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}";

/// Publishes a tool as a connected server would.
fn addTool(f: *Fixture, name: []const u8, upstream: []const u8, description: []const u8, schema_text: []const u8) !void {
    try f.gw.tools.add(.{
        .name = name,
        .description = description,
        .schema = try json.parse(f.a, schema_text),
        .server_id = "s1",
        .upstream_name = upstream,
    });
}

/// A window on the Tools page with the two tools the tests read. The tester
/// stays in the caller's frame: it refers to itself.
fn openTools(a: std.mem.Allocator, f: **Fixture, t: *ui.Tester) !void {
    f.* = try Fixture.init(a, &.{ui_test.stdioServer()});
    try addTool(f.*, "filesystem__read_file", "read_file", "Read a file.", object_schema);
    try addTool(f.*, "github__search_code", "search_code", "Find code.", search_schema);

    try ui_test.openWindow(t, f.*, a);
    f.*.app.page = .tools;
    t.frame();
}

test "the page lists every tool, and the chosen one's schema" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: *Fixture = undefined;
    var t: ui.Tester = undefined;
    try openTools(a, &f, &t);
    defer f.deinit();
    defer t.deinit();

    try std.testing.expect(t.hasText("2 tools"));
    try std.testing.expect(t.hasText("filesystem__read_file"));
    try std.testing.expect(t.hasText("github__search_code"));
    try std.testing.expect(t.hasText("Read a file."));

    // The first tool, by name, is chosen: its own server, upstream name and
    // transport sit above its schema.
    try std.testing.expectEqual(@as(?usize, 0), f.app.tools.selected);
    try std.testing.expect(t.hasText("Filesystem · read_file at stdio"));
    try std.testing.expect(t.hasText("Input schema"));
    try std.testing.expect(t.containsText("\"properties\""));
    try std.testing.expect(t.containsText("\"path\""));
    try std.testing.expect(t.hasText("Test call"));
    try std.testing.expect(t.hasText("Call tool"));
}

test "choosing another tool shows its own detail" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: *Fixture = undefined;
    var t: ui.Tester = undefined;
    try openTools(a, &f, &t);
    defer f.deinit();
    defer t.deinit();

    try t.clickText("github__search_code");
    t.frame();
    try std.testing.expectEqual(@as(?usize, 1), f.app.tools.selected);
    try std.testing.expect(t.hasText("Filesystem · search_code at stdio"));
    try std.testing.expect(t.containsText("\"query\""));
}

test "up and down move the choice" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: *Fixture = undefined;
    var t: ui.Tester = undefined;
    try openTools(a, &f, &t);
    defer f.deinit();
    defer t.deinit();

    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expectEqual(@as(?usize, 1), f.app.tools.selected);
    try std.testing.expect(t.hasText("Filesystem · search_code at stdio"));

    _ = t.shortcut(.{ .key = ui.Shortcut.up });
    try std.testing.expectEqual(@as(?usize, 0), f.app.tools.selected);
    try std.testing.expect(t.hasText("Filesystem · read_file at stdio"));
}

test "the filter matches a tool's server and description too" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: *Fixture = undefined;
    var t: ui.Tester = undefined;
    try openTools(a, &f, &t);
    defer f.deinit();
    defer t.deinit();

    try t.clickText("Filter by tool or server…");
    t.typeText("find code");
    try std.testing.expect(t.hasText("1 of 2 tools shown"));
    try std.testing.expect(t.hasText("github__search_code"));
    try std.testing.expect(!t.hasText("filesystem__read_file"));

    t.typeText("zzz");
    try std.testing.expect(t.hasText("No tools match"));
    try std.testing.expect(t.hasText("Nothing matches \"find codezzz\"."));

    try t.clickText("Clear the filter");
    try std.testing.expect(t.hasText("2 tools"));
}

test "arguments that are not JSON are reported before any call" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: *Fixture = undefined;
    var t: ui.Tester = undefined;
    try openTools(a, &f, &t);
    defer f.deinit();
    defer t.deinit();

    f.app.tools.call_args.set("{\"path\": ");
    t.frame();
    try t.clickText("Call tool");

    try std.testing.expect(f.app.tools.call_err);
    try std.testing.expect(!f.app.tools.calling);
    try std.testing.expect(t.containsText("Arguments are not valid JSON"));

    try t.clickText("Clear");
    try std.testing.expectEqualStrings("", f.app.tools.call_result);
    try std.testing.expect(!f.app.tools.call_err);
}

test "a tool answer keeps its text, or shows its JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const joined = try json.parse(a, "{\"content\":[{\"type\":\"text\",\"text\":\"one\"},{\"type\":\"text\",\"text\":\"two\"}]}");
    try std.testing.expectEqualStrings("one\ntwo", try page_tools.format(a, joined));

    const failed = try json.parse(a, "{\"content\":[{\"type\":\"text\",\"text\":\"nope\"}],\"isError\":true}");
    try std.testing.expectEqualStrings("error: nope", try page_tools.format(a, failed));

    // A block that is not text leaves the whole answer to JSON.
    const picture = try json.parse(a, "{\"content\":[{\"type\":\"image\",\"data\":\"x\"}]}");
    const shown = try page_tools.format(a, picture);
    try std.testing.expect(std.mem.indexOf(u8, shown, "\"image\"") != null);
}

test "leaving the page keeps its choice" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f: *Fixture = undefined;
    var t: ui.Tester = undefined;
    try openTools(a, &f, &t);
    defer f.deinit();
    defer t.deinit();

    f.app.tools.selected = 1;
    f.app.page = .servers;
    t.frame();
    f.app.page = .tools;
    t.frame();

    try std.testing.expectEqual(@as(?usize, 1), f.app.tools.selected);
    try std.testing.expect(t.hasText("Filesystem · search_code at stdio"));
}

