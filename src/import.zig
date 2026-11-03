//! Reading the configuration MCP clients write, so a block can be pasted in as
//! it stands: a {"mcpServers": {…}} wrapper, a bare map of name to server, or a
//! single server object on its own.
const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const json = @import("json_util.zig");

/// The wrappers MCP clients put their servers under.
const container_keys = [_][]const u8{ "mcpServers", "servers", "mcp" };

/// The fields that mark an object as one server rather than a map of them.
const server_keys = [_][]const u8{ "command", "url", "type", "transport", "args", "env", "headers", "oauth" };

/// What reading a pasted configuration produced.
pub const Parsed = union(enum) {
    servers: []config.ServerConfig,
    /// Why it could not be read, as the interface shows it.
    failed: []const u8,
};

/// Reads the configuration MCP clients write.
pub fn parse(a: std.mem.Allocator, data: []const u8) !Parsed {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return fail(a, "there is nothing to import", .{});
    if (trimmed[0] != '{') return fail(a, "the configuration should be a JSON object", .{});

    const doc = json.parse(a, trimmed) catch
        return fail(a, "that is not valid JSON", .{});
    const fields = switch (doc) {
        .object => |o| o,
        else => return fail(a, "the configuration should be a JSON object", .{}),
    };
    if (fields.count() == 0) return fail(a, "no servers were found in that configuration", .{});

    for (container_keys) |key| {
        if (fields.get(key)) |inner| return parseServerMap(a, inner);
    }
    if (hasAnyKey(fields, &server_keys)) {
        // One server, pasted without the map around it.
        const server = try parseServer(a, "", doc);
        switch (server) {
            .failed => |m| return .{ .failed = m },
            .server => |sc| {
                const out = try a.alloc(config.ServerConfig, 1);
                out[0] = sc;
                return .{ .servers = out };
            },
        }
    }
    return parseServerMap(a, doc);
}

/// What an import changed.
pub const ImportResult = struct {
    added: []const []const u8 = &.{},
    updated: []const []const u8 = &.{},

    /// Describes an import in one line.
    pub fn summary(r: ImportResult, a: std.mem.Allocator) ![]u8 {
        if (r.added.len == 0 and r.updated.len == 0) return a.dupe(u8, "Nothing was imported");
        if (r.updated.len == 0) return std.fmt.allocPrint(a, "Imported {s}", .{try count(a, r.added.len)});
        if (r.added.len == 0) return std.fmt.allocPrint(a, "Updated {s}", .{try count(a, r.updated.len)});
        return std.fmt.allocPrint(a, "Imported {s} and updated {s}", .{
            try count(a, r.added.len),
            try count(a, r.updated.len),
        });
    }
};

/// Adds servers, replacing any that share a name with one already configured.
/// A replaced server keeps its identity and its alias, so the tool names
/// clients already hold stay the same.
pub fn importServers(
    a: std.mem.Allocator,
    io: Io,
    cfg: *config.Config,
    servers: []config.ServerConfig,
) !ImportResult {
    var added: std.ArrayList([]const u8) = .empty;
    var updated: std.ArrayList([]const u8) = .empty;
    for (servers) |entry| {
        var sc = entry;
        if (serverByName(cfg.*, sc.name)) |existing| {
            sc.id = existing.id;
            sc.alias = existing.alias;
            try updated.append(a, sc.name);
        } else {
            sc.id = try config.newId(a, io);
            try added.append(a, sc.name);
        }
        try cfg.upsert(a, sc);
    }
    _ = try cfg.ensureAliases(a);
    return .{ .added = try added.toOwnedSlice(a), .updated = try updated.toOwnedSlice(a) };
}

/// Finds a server by its display name, ignoring case.
pub fn serverByName(cfg: config.Config, name: []const u8) ?config.ServerConfig {
    for (cfg.servers) |sc| {
        if (std.ascii.eqlIgnoreCase(sc.name, name)) return sc;
    }
    return null;
}

/// Reads an object keyed by server name.
fn parseServerMap(a: std.mem.Allocator, data: json.Value) !Parsed {
    const entries = switch (data) {
        .object => |o| o,
        else => return fail(a, "the servers should be a JSON object keyed by name", .{}),
    };
    if (entries.count() == 0) return fail(a, "no servers were found in that configuration", .{});

    // Sorted, so an import of the same file twice lands in the same order.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(a);
    var it = entries.iterator();
    while (it.next()) |kv| try names.append(a, kv.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var out: std.ArrayList(config.ServerConfig) = .empty;
    errdefer out.deinit(a);
    for (names.items) |name| {
        const parsed = try parseServer(a, name, entries.get(name).?);
        switch (parsed) {
            .failed => |m| return .{ .failed = try std.fmt.allocPrint(a, "{s}: {s}", .{ try config.quoted(a, name), m }) },
            .server => |sc| try out.append(a, sc),
        }
    }
    return .{ .servers = try out.toOwnedSlice(a) };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const OneServer = union(enum) {
    server: config.ServerConfig,
    failed: []const u8,
};

/// Reads one server, taking its name from the key it was under.
fn parseServer(a: std.mem.Allocator, name: []const u8, data: json.Value) !OneServer {
    const o = switch (data) {
        .object => |o| o,
        else => return .{ .failed = try a.dupe(u8, "that is not a server object") },
    };

    const command = std.mem.trim(u8, json.getString(oValue(o), "command") orelse "", " \t\r\n");
    const url = std.mem.trim(u8, json.getString(oValue(o), "url") orelse "", " \t\r\n");
    var sc: config.ServerConfig = .{
        .name = std.mem.trim(u8, firstNonEmpty(&.{ name, json.getString(oValue(o), "name") orelse "" }), " \t\r\n"),
        .command = command,
        .args = try stringList(a, o.get("args")),
        .env = try keyValues(a, o.get("env")),
        .url = url,
        .headers = try textMap(a, o.get("headers")),
        .oauth = json.getBool(oValue(o), "oauth") orelse false,
        // A configuration the user pastes is one they want to use.
        .enabled = json.getBool(oValue(o), "enabled") orelse true,
    };

    // The transport may be given, or inferred from what the server has.
    const kind_raw = firstNonEmpty(&.{
        json.getString(oValue(o), "type") orelse "",
        json.getString(oValue(o), "transport") orelse "",
    });
    var kind_buf: [32]u8 = undefined;
    const kind = if (kind_raw.len <= kind_buf.len) blk: {
        for (kind_raw, 0..) |ch, i| kind_buf[i] = std.ascii.toLower(ch);
        break :blk kind_buf[0..kind_raw.len];
    } else kind_raw;

    if (kind.len == 0 or std.mem.eql(u8, kind, "stdio") or std.mem.eql(u8, kind, "command")) {
        if (command.len > 0) {
            sc.transport = .stdio;
        } else if (kind.len == 0 and url.len > 0) {
            // A remote server with no kind is streamable HTTP, the transport
            // current clients default to.
            sc.transport = .http;
        } else {
            return .{ .failed = try a.dupe(u8, "a stdio server needs a command") };
        }
    } else if (std.mem.eql(u8, kind, "sse") or std.mem.eql(u8, kind, "event-stream")) {
        sc.transport = .sse;
    } else if (std.mem.eql(u8, kind, "http") or std.mem.eql(u8, kind, "streamable-http") or
        std.mem.eql(u8, kind, "streamablehttp") or std.mem.eql(u8, kind, "streamable"))
    {
        sc.transport = .http;
    } else {
        return .{ .failed = try std.fmt.allocPrint(a, "unknown transport {s}", .{try config.quoted(a, kind)}) };
    }

    if (sc.name.len == 0) sc.name = try defaultName(a, sc);
    if (config.ServerConfig.validateMessage(a, sc)) |m| return .{ .failed = m };
    return .{ .server = sc };
}

fn oValue(o: json.Object) json.Value {
    return .{ .object = o };
}

/// Names a server that arrived without one.
pub fn defaultName(a: std.mem.Allocator, sc: config.ServerConfig) ![]const u8 {
    if (sc.command) |command| {
        if (command.len > 0) {
            const base = std.fs.path.basename(command);
            if (base.len > 0 and !std.mem.eql(u8, base, ".") and
                !std.mem.eql(u8, base, "/") and !std.mem.eql(u8, base, "\\"))
            {
                return a.dupe(u8, base);
            }
        }
    }
    if (sc.url) |url| {
        if (hostOf(url)) |host| return a.dupe(u8, host);
    }
    return a.dupe(u8, "Imported server");
}

/// The host of a URL, or null when there is none.
pub fn hostOf(url: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[marker + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0) return null;
    // A user name before the host is not part of it.
    const at = std.mem.lastIndexOfScalar(u8, authority, '@');
    const host = if (at) |i| authority[i + 1 ..] else authority;
    if (host.len == 0) return null;
    return host;
}

/// Reads a list of strings, or a single string, since configurations do both.
fn stringList(a: std.mem.Allocator, value: ?json.Value) !?[]const []const u8 {
    const v = value orelse return null;
    switch (v) {
        .null => return null,
        .string => |s| {
            if (s.len == 0) return null;
            const out = try a.alloc([]const u8, 1);
            out[0] = s;
            return out;
        },
        .array => |arr| {
            if (arr.items.len == 0) return null;
            const out = try a.alloc([]const u8, arr.items.len);
            for (arr.items, 0..) |item, i| {
                out[i] = switch (item) {
                    .string => |s| s,
                    else => return error.NotAStringList,
                };
            }
            return out;
        },
        else => return error.NotAStringList,
    }
}

/// Reads an object whose values are strings, numbers or booleans.
fn textMap(a: std.mem.Allocator, value: ?json.Value) !?std.json.ArrayHashMap([]const u8) {
    const v = value orelse return null;
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    if (o.count() == 0) return null;
    var out: std.json.ArrayHashMap([]const u8) = .{};
    var it = o.iterator();
    while (it.next()) |kv| {
        const key = std.mem.trim(u8, kv.key_ptr.*, " \t\r\n");
        if (key.len == 0) continue;
        try out.map.put(a, key, try text(a, kv.value_ptr.*));
    }
    if (out.map.count() == 0) return null;
    return out;
}

/// Writes an object's entries as "KEY=VALUE", in a stable order.
fn keyValues(a: std.mem.Allocator, value: ?json.Value) !?[]const []const u8 {
    const v = value orelse return null;
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    if (o.count() == 0) return null;

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(a);
    var it = o.iterator();
    while (it.next()) |kv| try keys.append(a, kv.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, lessThan);

    const out = try a.alloc([]const u8, keys.items.len);
    for (keys.items, 0..) |key, i| {
        out[i] = try std.fmt.allocPrint(a, "{s}={s}", .{ key, try text(a, o.get(key).?) });
    }
    return out;
}

/// Renders a JSON value as the text it stands for, without inventing quotes
/// around numbers and booleans.
fn text(a: std.mem.Allocator, value: json.Value) ![]const u8 {
    return switch (value) {
        .null => a.dupe(u8, ""),
        .string => |s| s,
        .bool => |b| a.dupe(u8, if (b) "true" else "false"),
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| s,
        else => try json.text(a, value),
    };
}

fn hasAnyKey(o: json.Object, keys: []const []const u8) bool {
    for (keys) |key| {
        if (o.get(key) != null) return true;
    }
    return false;
}

fn firstNonEmpty(values: []const []const u8) []const u8 {
    for (values) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len != 0) return value;
    }
    return "";
}

/// Writes "1 server" or "3 servers".
fn count(a: std.mem.Allocator, n: usize) ![]u8 {
    if (n == 1) return a.dupe(u8, "1 server");
    return std.fmt.allocPrint(a, "{d} servers", .{n});
}

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Parsed {
    return .{ .failed = try std.fmt.allocPrint(a, fmt, args) };
}

test "a wrapped map of servers is read, sorted by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const data =
        \\{"mcpServers": {
        \\  "zeta": {"command": "npx", "args": ["-y", "zeta"], "env": {"Z": "1", "A": 2}},
        \\  "alpha": {"url": "https://example.com/mcp", "type": "streamable-http"}
        \\}}
    ;
    const parsed = try parse(a, data);
    const servers = parsed.servers;
    try std.testing.expectEqual(@as(usize, 2), servers.len);
    try std.testing.expectEqualStrings("alpha", servers[0].name);
    try std.testing.expectEqual(config.Transport.http, servers[0].transport);
    // The key the server was under wins over anything it says about itself.
    try std.testing.expectEqualStrings("alpha", servers[0].name);
    try std.testing.expectEqualStrings("zeta", servers[1].name);
    try std.testing.expectEqual(config.Transport.stdio, servers[1].transport);
    try std.testing.expect(servers[1].enabled);
    try std.testing.expectEqualStrings("A=2", servers[1].env.?[0]);
    try std.testing.expectEqualStrings("Z=1", servers[1].env.?[1]);
}

test "a single server object is read on its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parsed = try parse(a, "{\"command\": \"/usr/local/bin/github-mcp\", \"enabled\": false}");
    const servers = parsed.servers;
    try std.testing.expectEqual(@as(usize, 1), servers.len);
    try std.testing.expectEqualStrings("github-mcp", servers[0].name);
    try std.testing.expect(!servers[0].enabled);
}

test "the things that are not configurations are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cases = .{
        .{ "   ", "there is nothing to import" },
        .{ "[]", "the configuration should be a JSON object" },
        .{ "{}", "no servers were found in that configuration" },
        .{ "{\"mcpServers\": {}}", "no servers were found in that configuration" },
        .{ "{\"mcpServers\": []}", "the servers should be a JSON object keyed by name" },
        .{ "{\"servers\": {\"x\": {\"type\": \"stdio\"}}}", "\"x\": a stdio server needs a command" },
        .{ "{\"servers\": {\"x\": {\"url\": \"https://a\", \"type\": \"carrier-pigeon\"}}}", "\"x\": unknown transport \"carrier-pigeon\"" },
    };
    inline for (cases) |case| {
        const parsed = try parse(a, case[0]);
        try std.testing.expect(parsed == .failed);
        try std.testing.expectEqualStrings(case[1], parsed.failed);
    }
}

test "a server without a name is named after its command or its host" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("server.js", try defaultName(a, .{ .command = "/opt/bin/server.js" }));
    try std.testing.expectEqualStrings("api.example.com", try defaultName(a, .{ .url = "https://api.example.com/mcp" }));
    try std.testing.expectEqualStrings("Imported server", try defaultName(a, .{}));
    try std.testing.expectEqualStrings("api.example.com:8443", hostOf("https://api.example.com:8443/mcp").?);
    try std.testing.expect(hostOf("not a url") == null);
}

test "importing keeps a replaced server's identity and alias" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    var cfg: config.Config = .{};
    try cfg.upsert(a, .{
        .id = "keep-me",
        .name = "GitHub",
        .alias = "github",
        .transport = .stdio,
        .command = "old",
        .enabled = true,
    });

    var incoming = [_]config.ServerConfig{
        .{ .name = "github", .transport = .stdio, .command = "new" },
        .{ .name = "Linear", .transport = .http, .url = "https://mcp.linear.app/mcp" },
    };
    const result = try importServers(a, io, &cfg, &incoming);
    try std.testing.expectEqual(@as(usize, 1), result.added.len);
    try std.testing.expectEqualStrings("Linear", result.added[0]);
    try std.testing.expectEqual(@as(usize, 1), result.updated.len);
    try std.testing.expectEqualStrings("github", result.updated[0]);
    try std.testing.expectEqualStrings("Imported 1 server and updated 1 server", try result.summary(a));

    const replaced = cfg.server("keep-me").?;
    try std.testing.expectEqualStrings("new", replaced.command.?);
    try std.testing.expectEqualStrings("github", replaced.alias);
    try std.testing.expectEqual(@as(usize, 2), cfg.servers.len);
}

test "an import that changes nothing says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("Nothing was imported", try (ImportResult{}).summary(a));
    try std.testing.expectEqualStrings("Imported 1 server", try (ImportResult{ .added = &.{"a"} }).summary(a));
    try std.testing.expectEqualStrings("Updated 2 servers", try (ImportResult{ .updated = &.{ "a", "b" } }).summary(a));
}

test "arguments are one string or a list of strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const one = (try parse(a, "{\"solo\": {\"command\": \"uvx\", \"args\": \"mcp-server-time\"}}")).servers;
    try std.testing.expectEqual(@as(usize, 1), one[0].args.?.len);
    try std.testing.expectEqualStrings("mcp-server-time", one[0].args.?[0]);

    const many = (try parse(a, "{\"solo\": {\"command\": \"npx\", \"args\": [\"-y\", \"solo\"]}}")).servers;
    try std.testing.expectEqual(@as(usize, 2), many[0].args.?.len);
    try std.testing.expectEqualStrings("-y", many[0].args.?[0]);
    try std.testing.expectEqualStrings("solo", many[0].args.?[1]);

    const none = (try parse(a, "{\"solo\": {\"command\": \"npx\", \"args\": null}}")).servers;
    try std.testing.expectEqual(@as(?[]const []const u8, null), none[0].args);
}

test "importing servers whose names would share an alias keeps them apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    var cfg: config.Config = .{};
    var incoming = [_]config.ServerConfig{
        .{ .name = "A B", .transport = .stdio, .command = "npx" },
        .{ .name = "A-B", .transport = .stdio, .command = "npx" },
    };
    _ = try importServers(a, io, &cfg, &incoming);

    try std.testing.expectEqual(@as(usize, 2), cfg.servers.len);
    try std.testing.expect(!std.mem.eql(u8, cfg.servers[0].alias, cfg.servers[1].alias));
    try std.testing.expectEqualStrings("A B", cfg.servers[0].name);
    try std.testing.expectEqualStrings("A-B", cfg.servers[1].name);
}
