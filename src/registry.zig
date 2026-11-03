//! Searching the official MCP registry for public servers, and turning what it
//! finds into something the gateway can connect to.
const std = @import("std");
const Io = std.Io;
const json = @import("json_util.zig");
const web = @import("http_client.zig");

/// The official MCP registry.
pub const default_base_url = "https://registry.modelcontextprotocol.io";

/// A registry server the gateway would host itself.
pub const Remote = struct {
    /// "streamable-http" or "sse".
    kind: []const u8,
    url: []const u8,
};

/// A server that runs locally as a command.
pub const Package = struct {
    registry_type: []const u8 = "",
    identifier: []const u8 = "",
    version: []const u8 = "",
    runtime_hint: []const u8 = "",
    /// The whole argument line, in order.
    arguments: []const []const u8 = &.{},
    env: []const EnvVar = &.{},

    /// The way this package would be added: a program to run, with its
    /// arguments. `null` for a kind of package the gateway cannot run.
    pub fn install(p: Package) ?Install {
        var how = Install{ .arguments = p.arguments, .env = p.env };
        if (std.mem.eql(u8, p.registry_type, "npm")) {
            how.command = if (p.runtime_hint.len > 0) p.runtime_hint else "npx";
        } else if (std.mem.eql(u8, p.registry_type, "pypi")) {
            how.command = if (p.runtime_hint.len > 0) p.runtime_hint else "uvx";
        } else if (std.mem.eql(u8, p.registry_type, "oci")) {
            // A container runs detached from any terminal the gateway lacks.
            how.command = "docker";
            how.prefix = &.{ "run", "-i", "--rm" };
        } else return null;
        return how;
    }
};

/// An environment variable a package asks for.
pub const EnvVar = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    default: []const u8 = "",
    required: bool = false,
    secret: bool = false,
};

/// One entry of the registry.
pub const Server = struct {
    /// The registry name, "io.github.owner/repo".
    name: []const u8 = "",
    description: []const u8 = "",
    version: []const u8 = "",
    /// The repository's URL, when there is one.
    homepage: []const u8 = "",
    remotes: []const Remote = &.{},
    packages: []const Package = &.{},
    updated_at: []const u8 = "",

    /// The part of the name after the slash, for showing.
    pub fn shortName(s: Server) []const u8 {
        const i = std.mem.lastIndexOfScalar(u8, s.name, '/') orelse return s.name;
        return s.name[i + 1 ..];
    }

    /// How this server would be added: a hosted remote when the registry knows
    /// one, a local command otherwise. `null` when it lists neither.
    pub fn install(s: Server) ?Install {
        for (s.remotes) |remote| {
            if (std.mem.eql(u8, remote.kind, "streamable-http") and remote.url.len > 0) {
                return .{ .remote = true, .url = remote.url };
            }
        }
        for (s.remotes) |remote| {
            if (std.mem.eql(u8, remote.kind, "sse") and remote.url.len > 0) {
                return .{ .remote = true, .url = remote.url, .sse = true };
            }
        }
        for (s.packages) |package| {
            if (package.install()) |how| return how;
        }
        return null;
    }
};

/// The way a registry server would be added.
pub const Install = struct {
    remote: bool = false,
    /// Remote: the endpoint.
    url: []const u8 = "",
    /// Remote: it speaks SSE rather than streamable HTTP.
    sse: bool = false,
    /// Local: the program, "npx" or "uvx" or "docker".
    command: []const u8 = "",
    /// Local: arguments that go before the package's own, as in "docker run".
    prefix: []const []const u8 = &.{},
    arguments: []const []const u8 = &.{},
    env: []const EnvVar = &.{},
};

/// One page of search results.
pub const Page = struct {
    servers: []Server = &.{},
    /// Empty when this page is the last.
    next_cursor: []const u8 = "",
};

/// Talks to a registry. The base URL is a field so a test can point it at a
/// stub.
pub const Client = struct {
    a: std.mem.Allocator,
    io: Io,
    base_url: []const u8 = default_base_url,
    inner: ?*web.Client = null,

    /// Finds servers by name and description. An empty query lists the
    /// registry, newest first; `cursor` continues an earlier search.
    pub fn search(c: *Client, query: []const u8, cursor: []const u8, limit: u32) !Page {
        const a = c.a;
        const trimmed = std.mem.trim(u8, c.base_url, "/");
        var url: std.ArrayList(u8) = .empty;
        try url.appendSlice(a, trimmed);
        try url.appendSlice(a, "/v0/servers");
        var sep: u8 = '?';
        const q = std.mem.trim(u8, query, " \t\r\n");
        if (q.len > 0) {
            try url.append(a, sep);
            sep = '&';
            try url.appendSlice(a, "search=");
            try url.appendSlice(a, try encode(a, q));
        }
        if (cursor.len > 0) {
            try url.append(a, sep);
            sep = '&';
            try url.appendSlice(a, "cursor=");
            try url.appendSlice(a, try encode(a, cursor));
        }
        if (limit > 0) {
            try url.append(a, sep);
            try url.print(a, "limit={d}", .{limit});
        }

        var owned: ?*web.Client = null;
        const client = c.inner orelse blk: {
            owned = try a.create(web.Client);
            owned.?.* = web.Client.init(a, c.io);
            break :blk owned.?;
        };
        defer if (owned) |o| {
            o.deinit();
            a.destroy(o);
        };

        const answer = try client.send(.GET, url.items, &.{}, null);
        if (answer.status != 200) return error.RegistryStatus;
        const doc = json.parse(a, answer.body) catch return error.BadAnswer;

        const entries = json.getArray(doc, "servers") orelse return error.BadAnswer;
        var servers: std.ArrayList(Server) = .empty;
        for (entries.items) |entry| {
            // Every version of a server is listed; only the latest interests
            // us.
            const meta = json.get(entry, "_meta") orelse continue;
            const official = json.get(meta, "io.modelcontextprotocol.registry/official") orelse continue;
            if (json.getBool(official, "isLatest") orelse false == false) continue;

            const raw = json.get(entry, "server") orelse continue;
            var server: Server = .{
                .name = json.getString(raw, "name") orelse "",
                .description = json.getString(raw, "description") orelse "",
                .version = json.getString(raw, "version") orelse "",
                .updated_at = json.getString(official, "updatedAt") orelse "",
            };
            if (json.get(raw, "repository")) |repository| {
                server.homepage = json.getString(repository, "url") orelse "";
            }
            server.remotes = try readRemotes(a, raw);
            server.packages = try readPackages(a, raw);
            try servers.append(a, server);
        }

        var page: Page = .{ .servers = try servers.toOwnedSlice(a) };
        if (json.get(doc, "metadata")) |metadata| {
            page.next_cursor = json.getString(metadata, "nextCursor") orelse "";
        }
        return page;
    }
};

fn readRemotes(a: std.mem.Allocator, raw: json.Value) ![]Remote {
    const list = json.getArray(raw, "remotes") orelse return &.{};
    var out: std.ArrayList(Remote) = .empty;
    for (list.items) |item| {
        try out.append(a, .{
            .kind = json.getString(item, "type") orelse "",
            .url = json.getString(item, "url") orelse "",
        });
    }
    return out.toOwnedSlice(a);
}

fn readPackages(a: std.mem.Allocator, raw: json.Value) ![]Package {
    const list = json.getArray(raw, "packages") orelse return &.{};
    var out: std.ArrayList(Package) = .empty;
    for (list.items) |item| {
        var package: Package = .{
            .registry_type = json.getString(item, "registryType") orelse "",
            .identifier = json.getString(item, "identifier") orelse "",
            .version = json.getString(item, "version") orelse "",
            .runtime_hint = json.getString(item, "runtimeHint") orelse "",
        };

        var arguments: std.ArrayList([]const u8) = .empty;
        if (json.getArray(item, "runtimeArguments")) |args| {
            for (args.items) |arg| try arguments.append(a, try argument(a, arg));
        }
        // The identifier sits between the runtime's and the package's
        // arguments, as in "npx -y <identifier> --flag".
        try arguments.append(a, package.identifier);
        if (json.getArray(item, "packageArguments")) |args| {
            for (args.items) |arg| try arguments.append(a, try argument(a, arg));
        }
        package.arguments = try arguments.toOwnedSlice(a);

        if (json.getArray(item, "environmentVariables")) |vars| {
            var env: std.ArrayList(EnvVar) = .empty;
            for (vars.items) |v| {
                try env.append(a, .{
                    .name = json.getString(v, "name") orelse "",
                    .description = json.getString(v, "description") orelse "",
                    .default = json.getString(v, "default") orelse "",
                    .required = json.getBool(v, "isRequired") orelse false,
                    .secret = json.getBool(v, "isSecret") orelse false,
                });
            }
            package.env = try env.toOwnedSlice(a);
        }
        try out.append(a, package);
    }
    return out.toOwnedSlice(a);
}

/// One of a package's arguments: a positional one is its value, a named one its
/// name, with a value glued on when there is one.
pub fn argument(a: std.mem.Allocator, v: json.Value) ![]const u8 {
    const kind = json.getString(v, "type") orelse "";
    const name = json.getString(v, "name") orelse "";
    const value = json.getString(v, "value") orelse "";
    if (std.mem.eql(u8, kind, "named") and name.len > 0) {
        // "--flag=value" when there is a value, the bare name when there is
        // not.
        if (value.len == 0) return name;
        return std.fmt.allocPrint(a, "{s}={s}", .{ name, value });
    }
    return value;
}

/// The environment as "KEY=VALUE" lines, one per variable the package names:
/// its default when it has one, empty when it is required and still to be
/// filled in. Optional variables without a default are left out.
pub fn envLines(a: std.mem.Allocator, vars: []const EnvVar) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (vars) |v| {
        if (v.default.len > 0) {
            try out.appendSlice(a, v.name);
            try out.append(a, '=');
            try out.appendSlice(a, v.default);
            try out.append(a, '\n');
        } else if (v.required) {
            try out.appendSlice(a, v.name);
            try out.appendSlice(a, "=\n");
        }
    }
    if (out.items.len > 0) _ = out.pop();
    return out.toOwnedSlice(a);
}

/// Percent-encodes a query value.
fn encode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try out.append(a, c),
            ' ' => try out.append(a, '+'),
            else => try out.print(a, "%{X:0>2}", .{c}),
        }
    }
    return out.toOwnedSlice(a);
}

test "named arguments glue their value on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var named: json.J = .object(a);
    named.put("type", .str(a, "named"));
    named.put("name", .str(a, "--config"));
    named.put("value", .str(a, "x.json"));
    try std.testing.expectEqualStrings("--config=x.json", try argument(a, named.v));

    var positional: json.J = .object(a);
    positional.put("type", .str(a, "positional"));
    positional.put("value", .str(a, "-y"));
    try std.testing.expectEqualStrings("-y", try argument(a, positional.v));

    var bare: json.J = .object(a);
    bare.put("type", .str(a, "named"));
    bare.put("name", .str(a, "--verbose"));
    try std.testing.expectEqualStrings("--verbose", try argument(a, bare.v));
}

test "a package chooses its runtime" {
    // A Python package runs through uvx when the registry gives no hint.
    const pypi = Package{ .registry_type = "pypi", .identifier = "mcp-server-x" };
    try std.testing.expectEqualStrings("uvx", pypi.install().?.command);

    // A container image runs through docker, with its arguments after run.
    const oci = Package{ .registry_type = "oci", .identifier = "example/image:1", .arguments = &.{"example/image:1"} };
    const docker = oci.install().?;
    try std.testing.expectEqualStrings("docker", docker.command);
    try std.testing.expectEqualStrings("run", docker.prefix[0]);
    try std.testing.expectEqualStrings("example/image:1", docker.arguments[0]);

    // A kind the gateway cannot run is not installable.
    const nuget = Package{ .registry_type = "nuget", .identifier = "x" };
    try std.testing.expect(nuget.install() == null);
}

test "the environment is one line per variable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lines = try envLines(a, &.{
        .{ .name = "ROOT", .required = true },
        .{ .name = "DEBUG", .default = "false" },
        .{ .name = "OPTIONAL" },
    });
    try std.testing.expectEqualStrings("ROOT=\nDEBUG=false", lines);
}

test "a page is read from the registry" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const server = @import("server.zig");
    const Stub = struct {
        fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
            const page: []const u8 = @as(*const []const u8, @ptrCast(@alignCast(ctx))).*;
            if (!std.mem.eql(u8, req.path, "/v0/servers")) {
                try req.respond(.{ .status = .not_found });
                return;
            }
            try req.respond(.{ .body = page });
        }
    };

    var page: []const u8 = sample_page;
    const srv = try server.Server.initEphemeral(a, io, .{ .ctx = @ptrCast(&page), .handle = Stub.handle });
    try srv.start();
    defer {
        srv.stop();
        srv.destroy();
    }

    var client = web.Client.init(a, io);
    defer client.deinit();

    var c = Client{
        .a = a,
        .io = io,
        .base_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{srv.port}),
        .inner = &client,
    };
    const found = try c.search("files", "", 10);
    // The older of the two filesystem versions is dropped.
    try std.testing.expectEqual(@as(usize, 2), found.servers.len);
    try std.testing.expectEqualStrings("io.github.example/hosted:1.0.0", found.next_cursor);

    const fs = found.servers[0];
    try std.testing.expectEqualStrings("io.github.example/filesystem", fs.name);
    try std.testing.expectEqualStrings("filesystem", fs.shortName());
    try std.testing.expectEqualStrings("0.1.5", fs.version);
    try std.testing.expectEqualStrings("https://github.com/example/fs", fs.homepage);

    const install = fs.install().?;
    try std.testing.expect(!install.remote);
    try std.testing.expectEqualStrings("npx", install.command);
    try std.testing.expectEqual(@as(usize, 2), install.arguments.len);
    try std.testing.expectEqualStrings("-y", install.arguments[0]);
    try std.testing.expectEqualStrings("@example/fs-mcp", install.arguments[1]);
    try std.testing.expectEqualStrings("ROOT=\nDEBUG=false", try envLines(a, install.env));

    const hosted = found.servers[1];
    const remote = hosted.install().?;
    try std.testing.expect(remote.remote);
    try std.testing.expect(!remote.sse);
    try std.testing.expectEqualStrings("https://mcp.example.com/mcp", remote.url);
}

test "the registry answering badly is an error" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const server = @import("server.zig");
    const Stub = struct {
        fn handle(ctx: *anyopaque, req: *server.Request) anyerror!void {
            _ = ctx;
            try req.respond(.{ .status = .bad_gateway });
        }
    };

    const srv = try server.Server.initEphemeral(a, io, .{ .ctx = undefined, .handle = Stub.handle });
    try srv.start();
    defer {
        srv.stop();
        srv.destroy();
    }

    var client = web.Client.init(a, io);
    defer client.deinit();

    var c = Client{
        .a = a,
        .io = io,
        .base_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{srv.port}),
        .inner = &client,
    };
    try std.testing.expectError(error.RegistryStatus, c.search("x", "", 10));
}

/// A trimmed-down registry answer: an installable npm server in two versions,
/// and a hosted one.
const sample_page =
    \\{
    \\  "servers": [
    \\    {"server": {
    \\      "name": "io.github.example/filesystem",
    \\      "description": "Read and write files.",
    \\      "version": "0.1.2",
    \\      "repository": {"url": "https://github.com/example/fs"},
    \\      "packages": [{
    \\        "registryType": "npm",
    \\        "identifier": "@example/fs-mcp",
    \\        "version": "0.1.2",
    \\        "runtimeHint": "npx",
    \\        "runtimeArguments": [{"value": "-y", "type": "positional"}],
    \\        "environmentVariables": [
    \\          {"name": "ROOT", "isRequired": true},
    \\          {"name": "DEBUG", "default": "false"}
    \\        ]
    \\      }]
    \\    }, "_meta": {"io.modelcontextprotocol.registry/official": {"isLatest": false}}},
    \\    {"server": {
    \\      "name": "io.github.example/filesystem",
    \\      "description": "Read and write files.",
    \\      "version": "0.1.5",
    \\      "repository": {"url": "https://github.com/example/fs"},
    \\      "packages": [{
    \\        "registryType": "npm",
    \\        "identifier": "@example/fs-mcp",
    \\        "version": "0.1.5",
    \\        "runtimeHint": "npx",
    \\        "runtimeArguments": [{"value": "-y", "type": "positional"}],
    \\        "environmentVariables": [
    \\          {"name": "ROOT", "isRequired": true},
    \\          {"name": "DEBUG", "default": "false"}
    \\        ]
    \\      }]
    \\    }, "_meta": {"io.modelcontextprotocol.registry/official": {"isLatest": true}}},
    \\    {"server": {
    \\      "name": "io.github.example/hosted",
    \\      "description": "A hosted server.",
    \\      "version": "1.0.0",
    \\      "remotes": [{"type": "streamable-http", "url": "https://mcp.example.com/mcp"}]
    \\    }, "_meta": {"io.modelcontextprotocol.registry/official": {"isLatest": true}}}
    \\  ],
    \\  "metadata": {"nextCursor": "io.github.example/hosted:1.0.0", "count": 3}
    \\}
;
