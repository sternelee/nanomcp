//! The gateway's behaviour that needs more than one server to show: what a
//! caller sees when it names a tool that nobody offers, what the views say
//! about each server and tool, where the gateway says it serves, and which
//! agents have connected. The rest of the gateway's tests live in
//! `gateway_test.zig`, which this file reads its fixture and helpers from.
const std = @import("std");
const json = @import("json_util.zig");
const rpc = @import("rpc.zig");
const config = @import("config.zig");
const stdio = @import("transport_stdio.zig");
const credentials = @import("credentials.zig");
const web = @import("http_client.zig");
const gateway_mod = @import("gateway.zig");
const gateway_views = @import("gateway_views.zig");
const tools_mod = @import("tools.zig");

const core = @import("gateway_test.zig");
const Fixture = core.Fixture;
const helperServer = core.helperServer;
const listedTools = core.listedTools;
const hasTool = core.hasTool;
const callTool = core.callTool;
const resultText = core.resultText;
const activityText = core.activityText;

test "a call nobody can answer is refused as a tool error, not a protocol error" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const servers = [_]config.ServerConfig{
        try helperServer(a, "s1", "Helper", "helper"),
        .{
            .id = "s2",
            .name = "Search",
            .alias = "search",
            .transport = .http,
            .url = "https://example.com/mcp",
            .enabled = false,
        },
    };
    f.cfg.servers = &servers;
    try f.g.sync();

    // A tool that no server ever published.
    const unknown = try callTool(f, a, "nobody__nothing", null);
    try std.testing.expect(unknown.err == null);
    try std.testing.expect(json.getBool(unknown.result, "isError").?);
    try std.testing.expectEqualStrings("that tool does not exist", resultText(unknown.result));

    // A server that is configured but off offers nothing at all.
    try std.testing.expect(!hasTool(try listedTools(f, a), "search__anything"));

    // A tool whose server is not there any more is named as such, rather than
    // blamed on the tool.
    try f.g.tools.add(.{
        .name = "search__anything",
        .description = "From Search.",
        .schema = .{ .object = .empty },
        .server_id = "search",
        .upstream_name = "anything",
    });
    const gone = try callTool(f, a, "search__anything", null);
    try std.testing.expect(gone.err == null);
    try std.testing.expect(json.getBool(gone.result, "isError").?);
    try std.testing.expectEqualStrings("the server of that tool is not connected", resultText(gone.result));
}

test "a server that is taken out of the configuration takes its tools away" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const servers = [_]config.ServerConfig{try helperServer(a, "s1", "Filesystem", "filesystem")};
    f.cfg.servers = &servers;
    try f.g.sync();
    try std.testing.expect(hasTool(try listedTools(f, a), "filesystem__echo"));

    // The server goes away, and the gateway follows the configuration.
    try std.testing.expect(try f.cfg.remove(a, "s1"));
    try f.g.sync();

    // Its tools are no longer offered, and a caller who remembered the name is
    // told the tool does not exist...
    try std.testing.expect(!hasTool(try listedTools(f, a), "filesystem__echo"));
    const late = try callTool(f, a, "filesystem__echo", null);
    try std.testing.expectEqualStrings("that tool does not exist", resultText(late.result));

    // ...while the gateway's own tool still describes what is left, which is
    // nothing but the gateway itself.
    const meta = try callTool(f, a, tools_mod.meta_tool_name, null);
    try std.testing.expect(!json.getBool(meta.result, "isError").?);
    const described = json.parse(a, resultText(meta.result)) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), json.getArray(described, "servers").?.items.len);

    // The activity says the connection went away.
    try std.testing.expect(std.mem.indexOf(u8, try activityText(f, a), "disconnected Filesystem") != null);
}

test "the views say where each tool came from and which server is ready" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    const servers = [_]config.ServerConfig{
        try helperServer(a, "s1", "Filesystem", "filesystem"),
        .{
            .id = "s2",
            .name = "Search",
            .alias = "search",
            .transport = .http,
            .url = "https://example.com/mcp",
            .enabled = false,
        },
    };
    f.cfg.servers = &servers;
    try f.g.sync();

    // Every tool says which server it came from, by name and by alias, and
    // carries the schema its server published.
    const tools = try gateway_views.toolViews(&f.g, a);
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("filesystem__boom", tools[0].name);
    try std.testing.expectEqualStrings("boom", tools[0].upstream);
    try std.testing.expectEqualStrings("s1", tools[0].server_id);
    try std.testing.expectEqualStrings("Filesystem", tools[0].server_name);
    try std.testing.expect(std.mem.indexOf(u8, tools[0].description, "Filesystem") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools[0].schema, "object") != null);
    try std.testing.expectEqualStrings("filesystem__echo", tools[1].name);
    try std.testing.expectEqualStrings("echo", tools[1].upstream);
    try std.testing.expect(std.mem.indexOf(u8, tools[1].schema, "properties") != null);

    // The servers say who is ready and how much each one offers.
    const views = try gateway_views.servers(&f.g, a);
    try std.testing.expectEqual(@as(usize, 2), views.len);
    try std.testing.expectEqualStrings("s1", views[0].config.id);
    try std.testing.expectEqual(gateway_mod.Status.ready, views[0].status);
    try std.testing.expectEqualStrings("ready", views[0].status.label());
    try std.testing.expectEqual(@as(usize, 2), views[0].tools);
    try std.testing.expectEqualStrings("", views[0].err);
    try std.testing.expectEqual(gateway_mod.Status.disabled, views[1].status);
    try std.testing.expectEqualStrings("disabled", views[1].status.label());
    try std.testing.expectEqual(@as(usize, 0), views[1].tools);

    // And one server can be looked up on its own.
    const one = try gateway_views.serverOf(&f.g, a, "s2");
    try std.testing.expectEqualStrings("Search", one.?.config.name);
}

test "the endpoints stay on the loopback interface and use the configured port" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A gateway that is not serving names the port its configuration holds.
    var cfg = config.Config.default();
    cfg.port = 7100;
    var store: credentials.CredentialStore = .initMemory(a);
    defer store.deinit();
    var g = gateway_mod.Gateway.init(a, std.testing.io, &cfg, &store, "0.1.0");
    defer _ = g.deinit();

    const off = try gateway_views.endpoints(&g, a);
    try std.testing.expectEqual(@as(usize, 4), off.len);
    for (off) |endpoint| {
        try std.testing.expect(std.mem.startsWith(u8, endpoint, "http://127.0.0.1:7100/"));
    }
    try std.testing.expectEqualStrings("http://127.0.0.1:7100/healthz", off[3]);

    // One that is serving names the port it actually took.
    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();
    const live = try gateway_views.endpoints(&f.g, a);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/mcp", .{f.base}), live[0]);
    try std.testing.expect(std.mem.startsWith(u8, live[3], f.base));
}

test "the gateway follows the agents that connect and counts the calls they make" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try Fixture.start(a, std.testing.io);
    defer f.stop();

    // An agent introduces itself, and is remembered by what it said.
    var params: json.J = .object(a);
    params.put("protocolVersion", .str(a, "2024-11-05"));
    var info: json.J = .object(a);
    info.put("name", .str(a, "nanomcp"));
    info.put("version", .str(a, "test"));
    params.put("clientInfo", info);
    const hello = try f.request(.POST, "/mcp", &.{}, try rpc.request(a, .{ .number = 1 }, "initialize", params.v));
    try std.testing.expectEqual(@as(u16, 200), hello.status);

    // The gateway names the session, and the client carries the name from
    // then on, as the streamable transport says.
    const session = (try hello.headerValue(a, "mcp-session-id")) orelse return error.NoSessionId;
    try std.testing.expect(session.len > 0);

    const routes = try f.g.routes.list(a);
    try std.testing.expectEqual(@as(usize, 1), routes.len);
    try std.testing.expectEqualStrings("nanomcp", routes[0].client);
    try std.testing.expectEqualStrings("test", routes[0].version);
    try std.testing.expectEqualStrings("2024-11-05", routes[0].protocol);
    try std.testing.expectEqual(@as(u32, 0), routes[0].calls);

    // Every call it makes is counted against it, with the time of the last.
    const named = [_]web.Header{.{ .name = "mcp-session-id", .value = session }};
    for (0..2) |_| {
        var call: json.J = .object(a);
        call.put("name", .str(a, "nobody__nothing"));
        call.put("arguments", json.J.from(a, .{ .object = .empty }));
        const asked = try f.request(.POST, "/mcp", &named, try rpc.request(a, .{ .number = 2 }, "tools/call", call.v));
        try std.testing.expectEqual(@as(u16, 200), asked.status);
    }
    const after = try f.g.routes.list(a);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqual(@as(u32, 2), after[0].calls);
    try std.testing.expect(after[0].last_active != 0);

    // Ending the session takes the agent off the routes.
    const ended = try f.request(.DELETE, "/mcp", &named, null);
    try std.testing.expectEqual(@as(u16, 204), ended.status);
    const gone = try f.g.routes.list(a);
    try std.testing.expectEqual(@as(usize, 0), gone.len);
    try std.testing.expectEqual(@as(usize, 0), f.g.routes.connectedCount());
}

test "the log buffer keeps the most recent lines a command wrote" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var logs: stdio.Logs = .{ .a = a, .limit = 3, .io = std.testing.io };
    defer logs.deinit();

    // A line that has not been finished, and has no newline yet, is still a
    // line...
    logs.add("still writing");
    try std.testing.expectEqualStrings("still writing", try logs.text(a));
    logs.add("one");
    logs.add("two");
    logs.add("three");
    try std.testing.expectEqualStrings("one\ntwo\nthree", try logs.text(a));

    // ...but only the most recent ones are kept...
    logs.add("four");
    try std.testing.expectEqualStrings("two\nthree\nfour", try logs.text(a));

    // ...and an empty line says nothing, while a terminal's carriage return is
    // not part of the line.
    logs.add("five\r");
    logs.add("");
    try std.testing.expectEqualStrings("three\nfour\nfive", try logs.text(a));
}
