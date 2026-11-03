//! The Market page against the real widgets: how a search's servers are
//! shown, how each says it runs, and that adding one opens the add form
//! filled in from what the registry said, for review before saving.
const std = @import("std");
const ui = @import("nanoui").ui;
const config = @import("config.zig");
const registry = @import("registry.zig");
const state = @import("state.zig");

const ui_test = @import("ui_test.zig");
const Fixture = ui_test.Fixture;

fn remoteRow() registry.Server {
    return .{
        .name = "io.github.acme/filesystem",
        .description = "Files on disk, in a sandbox.",
        .version = "1.2.3",
        .remotes = &.{.{ .kind = "streamable-http", .url = "https://example.com/mcp" }},
    };
}

fn packageRow() registry.Server {
    return .{
        .name = "io.github.acme/tool",
        .description = "A local package.",
        .version = "0.4.0",
        .packages = &.{.{
            .registry_type = "npm",
            .identifier = "@acme/tool",
            .runtime_hint = "",
            .arguments = &.{ "-y", "@acme/tool", "--flag" },
            .env = &.{
                .{ .name = "API_KEY", .required = true },
                .{ .name = "MODE", .default = "on" },
            },
        }},
    };
}

test "a search lists its servers with how each one runs" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();

    var rows = [_]registry.Server{
        remoteRow(),
        packageRow(),
        .{ .name = "io.github.acme/manual", .description = "Nothing the gateway can run." },
    };
    f.app.market.results = &rows;
    f.app.market.searched = true;

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try std.testing.expect(t.hasText("3 found"));
    try std.testing.expect(t.hasText("filesystem"));
    try std.testing.expect(t.hasText("Files on disk, in a sandbox."));
    try std.testing.expect(t.hasText("remote"));
    try std.testing.expect(t.hasText("v1.2.3"));
    try std.testing.expect(t.hasText("tool"));
    try std.testing.expect(t.hasText("npx"));
    try std.testing.expect(t.hasText("manual"));
    try std.testing.expect(t.hasText("Manual"));
    try std.testing.expect(t.hasText("Add…"));
}

test "adding from the market opens the form filled in, for review" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();

    var rows = [_]registry.Server{remoteRow()};
    f.app.market.results = &rows;
    f.app.market.searched = true;

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try t.clickText("Add…");
    t.frame();
    try std.testing.expect(f.app.servers.editing != null);
    try std.testing.expect(t.hasText("Add a server"));
    try std.testing.expectEqualStrings("filesystem", f.app.servers.form.name.text());
    try std.testing.expectEqual(@as(usize, 2), f.app.servers.form.transport);
    try std.testing.expectEqualStrings("https://example.com/mcp", f.app.servers.form.url.text());
    try std.testing.expect(f.app.servers.form.enabled);

    // Nothing is saved until the form says so.
    try std.testing.expect(f.app.cfg.servers.len == 0);
}

test "a local registry server arrives with its command, arguments and environment" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();

    var rows = [_]registry.Server{packageRow()};
    f.app.market.results = &rows;
    f.app.market.searched = true;

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try t.clickText("Add…");
    t.frame();
    try std.testing.expectEqual(@as(usize, 0), f.app.servers.form.transport);
    try std.testing.expectEqualStrings("npx", f.app.servers.form.command.text());
    try std.testing.expectEqualStrings("-y\n@acme/tool\n--flag", f.app.servers.form.args.text());
    try std.testing.expectEqualStrings("API_KEY=\nMODE=on", f.app.servers.form.env.text());
}

test "a configured server's remote is marked Added" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const already = config.ServerConfig{
        .id = "s1",
        .name = "Filesystem",
        .alias = "filesystem",
        .transport = .http,
        .enabled = true,
        .url = "https://example.com/mcp",
    };
    const f = try Fixture.init(a, &.{already});
    defer f.deinit();

    var rows = [_]registry.Server{remoteRow()};
    f.app.market.results = &rows;
    f.app.market.searched = true;

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try std.testing.expect(t.hasText("Added"));
    try std.testing.expect(!t.hasText("Add…"));
}

test "a page with a cursor offers more, and the last page ends it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    defer f.app.freeMarket();

    const first_arena = try a.create(std.heap.ArenaAllocator);
    first_arena.* = .init(a);
    const first = try first_arena.allocator().alloc(registry.Server, 1);
    first[0] = remoteRow();
    f.app.addMarket(first_arena, first, "page-2", false);

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try std.testing.expect(t.hasText("1 shown, more on the registry"));
    try std.testing.expect(t.hasText("Show more"));

    // The registry's last page brought nothing and named no next cursor: the
    // offer goes rather than asking for the same page again.
    const last_arena = try a.create(std.heap.ArenaAllocator);
    last_arena.* = .init(a);
    f.app.addMarket(last_arena, &.{}, "", true);
    t.frame();

    try std.testing.expect(!t.hasText("Show more"));
    try std.testing.expect(t.hasText("1 found"));
}

test "a next page adds to what was already found" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    defer f.app.freeMarket();

    const first_arena = try a.create(std.heap.ArenaAllocator);
    first_arena.* = .init(a);
    const first = try first_arena.allocator().alloc(registry.Server, 1);
    first[0] = remoteRow();
    f.app.addMarket(first_arena, first, "page-2", false);

    const second_arena = try a.create(std.heap.ArenaAllocator);
    second_arena.* = .init(a);
    const second = try second_arena.allocator().alloc(registry.Server, 1);
    second[0] = packageRow();
    f.app.addMarket(second_arena, second, "", true);

    try std.testing.expectEqual(@as(usize, 2), f.app.market.results.len);
    try std.testing.expectEqualStrings("io.github.acme/filesystem", f.app.market.results[0].name);
    try std.testing.expectEqualStrings("io.github.acme/tool", f.app.market.results[1].name);
    try std.testing.expect(f.app.market.cursor == null);

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try std.testing.expect(t.hasText("filesystem"));
    try std.testing.expect(t.hasText("tool"));
    try std.testing.expect(t.hasText("2 found"));
}

test "a search that found nothing says what it looked for and offers the latest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    f.app.market.query.set("nothing here");
    f.app.market.searched = true;

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try std.testing.expect(t.hasText("Nothing found"));
    try std.testing.expect(t.hasText("No servers on the registry match \"nothing here\"."));
    try std.testing.expect(t.hasText("Show the latest"));
    try std.testing.expect(t.hasText("0 found"));
}

test "a registry that could not be reached says so" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();
    f.app.market.searched = true;
    f.app.market.err = "The registry could not be reached: the registry answered with an error";

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();
    f.app.page = .market;
    t.frame();

    try std.testing.expect(t.hasText("The registry could not be reached: the registry answered with an error"));
}

fn marketPageOf(s: *state.App) void {
    s.page = .market;
    s.redisplay();
}

test "choosing the market keeps whatever the form was doing" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.init(a, &.{});
    defer f.deinit();

    var t: ui.Tester = undefined;
    try ui_test.openWindow(&t, f, a);
    defer t.deinit();

    marketPageOf(&f.app);
    f.app.servers.editing = "new-id";
    f.app.servers.form.reset();
    f.app.servers.form.name.set("From the market");
    t.frame();
    try std.testing.expect(t.hasText("Add a server"));
    try std.testing.expectEqualStrings("new-id", f.app.servers.editing.?);
}
