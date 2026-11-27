//! The configured servers written the way other MCP clients read them: the
//! {"mcpServers": {…}} block another client's file takes as it stands, and
//! that this app's own Paste JSON… reads back. Tokens are not in here: a
//! saved sign-in lives in the credential store, and an export is meant to be
//! pasted somewhere else.
const std = @import("std");
const config = @import("config.zig");
const json = @import("json_util.zig");

/// Every configured server as one indented document, with a closing newline.
pub fn write(a: std.mem.Allocator, servers: []const config.ServerConfig) ![]u8 {
    var root = json.J.object(a);
    var block = json.J.object(a);
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    for (servers) |sc| {
        block.put(try uniqueKey(a, &taken, sc.name), try one(a, sc));
    }
    root.put("mcpServers", block);

    const body = try root.dumpIndent();
    defer a.free(body);
    const out = try a.alloc(u8, body.len + 1);
    @memcpy(out[0..body.len], body);
    out[body.len] = '\n';
    return out;
}

/// One server, with only the fields it has: a stdio server has no URL, and a
/// remote one has no command.
fn one(a: std.mem.Allocator, sc: config.ServerConfig) !json.J {
    var out = json.J.object(a);
    out.putText("type", sc.transport.name());
    out.putText("command", sc.command orelse "");
    if (sc.args) |args| if (args.len > 0) out.put("args", json.J.strings(a, args));
    if (envObject(a, sc)) |env| out.put("env", env);
    out.putText("url", sc.url orelse "");
    if (headers(a, sc)) |h| out.put("headers", h);
    if (sc.oauth) out.put("oauth", json.J.boolean(a, true));
    // A server that is off here would come back switched on without this.
    if (!sc.enabled) out.put("enabled", json.J.boolean(a, false));
    return out;
}

/// The environment as the object clients write, `K=V` lines unpacked: a
/// line without an `=` keeps its whole text as the name.
fn envObject(a: std.mem.Allocator, sc: config.ServerConfig) ?json.J {
    const env = sc.env orelse return null;
    if (env.len == 0) return null;
    var out = json.J.object(a);
    for (env) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=');
        if (eq) |at| out.putText(line[0..at], line[at + 1 ..]) else out.putText(line, "");
    }
    return out;
}

fn headers(a: std.mem.Allocator, sc: config.ServerConfig) ?json.J {
    const h = sc.headers orelse return null;
    if (h.map.count() == 0) return null;
    var out = json.J.object(a);
    var it = h.map.iterator();
    while (it.next()) |kv| out.putText(kv.key_ptr.*, kv.value_ptr.*);
    return out;
}

/// The key a server is written under: its name, and a suffix when another
/// server already took it, since one JSON object cannot hold a key twice.
fn uniqueKey(a: std.mem.Allocator, taken: *std.StringHashMapUnmanaged(void), name: []const u8) ![]const u8 {
    const base = if (name.len > 0) name else "server";
    var key: []const u8 = base;
    var n: usize = 2;
    while (taken.contains(key)) : (n += 1) key = try std.fmt.allocPrint(a, "{s} {d}", .{ base, n });
    try taken.put(a, key, {});
    return key;
}

const import_mod = @import("import.zig");

/// The document builder is arena-minded: nothing in it is freed piecemeal, so
/// a test's arena is the allocator to hand it.
fn testArena() std.heap.ArenaAllocator {
    return .init(std.testing.allocator);
}

/// A stdio server with everything a stdio server can carry.
fn stdioServer() config.ServerConfig {
    return .{
        .id = "a",
        .name = "Filesystem",
        .alias = "filesystem",
        .command = "npx",
        .args = &.{ "-y", "@modelcontextprotocol/server-filesystem" },
        .env = &.{"ROOT=/tmp"},
        .enabled = true,
    };
}

test "a stdio server is written with the fields it has, and no others" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text = try write(a, &.{stdioServer()});

    try std.testing.expect(std.mem.indexOf(u8, text, "\"mcpServers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Filesystem\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\": \"stdio\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"command\": \"npx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"-y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ROOT\": \"/tmp\"") != null);
    // Nothing the server does not have.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"url\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"oauth\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"enabled\"") == null);
    // A document a client can read as it stands.
    try std.testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
    _ = json.parse(a, text) catch return error.NotJson;
}

test "a remote server keeps its URL, headers and sign-in" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var map: std.json.ArrayHashMap([]const u8) = .{};
    try map.map.put(a, "X-Key", "one");

    const text = try write(a, &.{.{
        .id = "b",
        .name = "Remote",
        .alias = "remote",
        .transport = .http,
        .url = "https://example.com/mcp",
        .headers = map,
        .oauth = true,
    }});

    try std.testing.expect(std.mem.indexOf(u8, text, "\"type\": \"http\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"url\": \"https://example.com/mcp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"X-Key\": \"one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"oauth\": true") != null);
}

test "a server that is switched off is written as off" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var off = stdioServer();
    off.enabled = false;
    const text = try write(a, &.{off});
    try std.testing.expect(std.mem.indexOf(u8, text, "\"enabled\": false") != null);
}

test "two servers with one name still make two keys" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var second = stdioServer();
    second.command = "uvx";
    const text = try write(a, &.{ stdioServer(), second });

    try std.testing.expect(std.mem.indexOf(u8, text, "\"Filesystem\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Filesystem 2\": {") != null);
}

test "what is exported is what Paste JSON reads back" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text = try write(a, &.{
        stdioServer(),
        .{
            .id = "b",
            .name = "Remote",
            .alias = "remote",
            .transport = .http,
            .url = "https://example.com/mcp",
            .oauth = true,
            .enabled = false,
        },
    });

    const parsed = try import_mod.parse(a, text);
    const servers = switch (parsed) {
        .servers => |list| list,
        .failed => |why| {
            std.debug.print("import failed: {s}\n", .{why});
            return error.NotImportable;
        },
    };
    try std.testing.expectEqual(@as(usize, 2), servers.len);

    const back_first = import_mod.serverByName(.{ .servers = servers }, "Filesystem") orelse return error.MissingServer;
    try std.testing.expectEqual(config.Transport.stdio, back_first.transport);
    try std.testing.expectEqualStrings("npx", back_first.command.?);
    try std.testing.expectEqual(@as(usize, 2), back_first.args.?.len);
    try std.testing.expectEqualStrings("ROOT=/tmp", back_first.env.?[0]);
    try std.testing.expect(back_first.enabled);

    const back_second = import_mod.serverByName(.{ .servers = servers }, "Remote") orelse return error.MissingServer;
    try std.testing.expectEqual(config.Transport.http, back_second.transport);
    try std.testing.expectEqualStrings("https://example.com/mcp", back_second.url.?);
    try std.testing.expect(back_second.oauth);
    try std.testing.expect(!back_second.enabled);
}
