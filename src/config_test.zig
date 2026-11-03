//! The settings tests the Go original had, kept as they behaved.
const std = @import("std");
const config = @import("config.zig");

const test_dir = "/tmp/nanomcp-test-config";

fn freshArena() std.heap.ArenaAllocator {
    return .init(std.testing.allocator);
}

fn sc(id: []const u8, name: []const u8) config.ServerConfig {
    return .{ .id = id, .name = name };
}

test "aliases are safe and unique, and running it twice changes nothing" {
    var arena_state = freshArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var servers = [_]config.ServerConfig{
        sc("a", "My Server!"),
        sc("b", "My Server!"),
        sc("c", "  "),
        .{ .id = "d", .name = "Filesystem", .alias = "filesystem" },
    };
    var cfg: config.Config = .{ .servers = &servers };

    try std.testing.expect(try cfg.ensureAliases(a));
    const want = [_]struct { id: []const u8, alias: []const u8 }{
        .{ .id = "a", .alias = "my_server" },
        .{ .id = "b", .alias = "my_server_2" },
        .{ .id = "c", .alias = "server" },
        .{ .id = "d", .alias = "filesystem" },
    };
    for (cfg.servers) |s| {
        for (want) |w| {
            if (std.mem.eql(u8, s.id, w.id)) try std.testing.expectEqualStrings(w.alias, s.alias);
        }
    }
    try std.testing.expect(!try cfg.ensureAliases(a));
}

test "a chosen alias that does not collide is kept" {
    var arena_state = freshArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var servers = [_]config.ServerConfig{
        .{ .id = "a", .name = "GitHub", .alias = "gh" },
        sc("b", "GitLab"),
    };
    var cfg: config.Config = .{ .servers = &servers };
    _ = try cfg.ensureAliases(a);
    try std.testing.expectEqualStrings("gh", cfg.servers[0].alias);
    try std.testing.expectEqualStrings("gitlab", cfg.servers[1].alias);
}

test "a configuration survives being saved and loaded" {
    const io = std.testing.io;
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    var arena_state = freshArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var servers = [_]config.ServerConfig{.{
        .id = "s1",
        .name = "Filesystem",
        .transport = .stdio,
        .command = "npx",
        .args = &.{ "-y", "server" },
        .env = &.{"A=B"},
        .enabled = true,
    }};
    var cfg: config.Config = .{ .port = 7444, .servers = &servers };
    _ = try cfg.ensureAliases(a);
    try config.save(io, a, cfg, test_dir);

    const loaded = try config.load(a, io, test_dir);
    try std.testing.expectEqual(@as(i32, 7444), loaded.port);
    try std.testing.expectEqual(@as(usize, 1), loaded.servers.len);
    const got = loaded.servers[0];
    try std.testing.expectEqualStrings("Filesystem", got.name);
    try std.testing.expectEqualStrings("npx", got.command.?);
    try std.testing.expectEqual(@as(usize, 2), got.args.?.len);
    try std.testing.expect(got.enabled);
    try std.testing.expectEqualStrings("filesystem", got.alias);
}

test "no saved configuration means the defaults" {
    const io = std.testing.io;
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    var arena_state = freshArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg = try config.load(a, io, test_dir);
    try std.testing.expectEqual(config.default_port, cfg.port);
    try std.testing.expectEqual(@as(usize, 0), cfg.servers.len);
}

test "a server is validated before it can be connected" {
    const Case = struct { name: []const u8, server: config.ServerConfig, want_err: bool };
    const cases = [_]Case{
        .{ .name = "stdio is complete", .server = .{ .name = "a", .transport = .stdio, .command = "npx" }, .want_err = false },
        .{ .name = "stdio needs a command", .server = .{ .name = "a", .transport = .stdio }, .want_err = true },
        .{ .name = "a name is required", .server = .{ .transport = .stdio, .command = "npx" }, .want_err = true },
        .{ .name = "the transport must be known", .server = .{ .name = "a", .transport = .{ .other = "carrier-pigeon" } }, .want_err = true },
        .{ .name = "http is complete", .server = .{ .name = "a", .transport = .http, .url = "https://example.com/mcp" }, .want_err = false },
        .{ .name = "http needs a URL", .server = .{ .name = "a", .transport = .http }, .want_err = true },
        .{ .name = "http needs a real scheme", .server = .{ .name = "a", .transport = .http, .url = "example.com" }, .want_err = true },
        .{ .name = "sse is complete", .server = .{ .name = "a", .transport = .sse, .url = "http://example.com/sse", .oauth = true }, .want_err = false },
        .{ .name = "a token is fine on a remote server", .server = .{ .name = "a", .transport = .http, .url = "https://example.com/mcp", .token_header = "X-API-Key" }, .want_err = false },
        .{ .name = "signing in and a token conflict", .server = .{ .name = "a", .transport = .http, .url = "https://example.com/mcp", .oauth = true, .token_header = "Authorization" }, .want_err = true },
        .{ .name = "a header name must be sendable", .server = .{ .name = "a", .transport = .http, .url = "https://example.com/mcp", .token_header = "Not A Header" }, .want_err = true },
        .{ .name = "a stdio server takes its credentials in the environment", .server = .{ .name = "a", .transport = .stdio, .command = "npx", .token_header = "Authorization" }, .want_err = true },
        .{ .name = "a stdio server has nothing to sign in to", .server = .{ .name = "a", .transport = .stdio, .command = "npx", .oauth = true }, .want_err = true },
    };
    for (cases) |c| {
        if (c.want_err) {
            if (c.server.validate()) |_| {
                std.debug.print("case {s} was accepted\n", .{c.name});
                return error.TestExpectedError;
            } else |_| {}
        } else {
            c.server.validate() catch |err| {
                std.debug.print("case {s} failed: {t}\n", .{ c.name, err });
                return err;
            };
        }
    }
}

test "a server is found, replaced and removed by its id" {
    var arena_state = freshArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var servers = [_]config.ServerConfig{ sc("a", "a"), sc("b", "b") };
    var cfg: config.Config = .{ .servers = &servers };

    try std.testing.expect(cfg.server("a") != null);
    try std.testing.expect(cfg.server("zzz") == null);

    try cfg.upsert(a, .{ .id = "a", .name = "renamed" });
    try std.testing.expectEqual(@as(usize, 2), cfg.servers.len);
    try std.testing.expectEqualStrings("renamed", cfg.server("a").?.name);

    try std.testing.expect(try cfg.remove(a, "a"));
    try std.testing.expect(!try cfg.remove(a, "a"));
    try std.testing.expectEqual(@as(usize, 1), cfg.servers.len);
    try std.testing.expectEqualStrings("b", cfg.servers[0].id);
}

test "transports have labels, and an unknown one is not valid" {
    const sse: config.Transport = .sse;
    const http: config.Transport = .http;
    const stdio: config.Transport = .stdio;
    try std.testing.expectEqualStrings("SSE", sse.label());
    try std.testing.expectEqualStrings("HTTP", http.label());
    try std.testing.expectEqualStrings("stdio", stdio.label());
    try std.testing.expect(!config.Transport.fromName("carrier-pigeon").valid());
}

test "an inbound mode defaults to open, and an unknown one does too" {
    const cfg = config.Config.default();
    try std.testing.expectEqual(config.InboundMode.off, cfg.inboundMode());
    var unknown: config.Config = .{ .inbound = .{ .other = "something-else" } };
    try std.testing.expectEqual(config.InboundMode.off, unknown.inboundMode());
    unknown.inbound = .oauth;
    try std.testing.expectEqual(config.InboundMode.oauth, unknown.inboundMode());
}

test "inbound modes agree about needing a token, and have labels" {
    const off: config.InboundMode = .off;
    const oauth: config.InboundMode = .oauth;
    const token: config.InboundMode = .token;
    try std.testing.expect(!off.requiresToken());
    try std.testing.expect(oauth.requiresToken());
    try std.testing.expect(token.requiresToken());
    try std.testing.expectEqualStrings("Off", off.label());
    try std.testing.expectEqualStrings("Token + OAuth", oauth.label());
    const nonsense: config.InboundMode = .{ .other = "nonsense" };
    try std.testing.expect(!nonsense.valid());
}

test "the inbound mode survives being saved and loaded" {
    const io = std.testing.io;
    std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, test_dir) catch {};

    var arena_state = freshArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cfg: config.Config = .{ .port = 7331, .inbound = .oauth };
    try config.save(io, a, cfg, test_dir);
    const loaded = try config.load(a, io, test_dir);
    try std.testing.expectEqual(config.InboundMode.oauth, loaded.inboundMode());
}
