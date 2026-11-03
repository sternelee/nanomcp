//! The gateway's persisted settings: the servers it connects to, the port it
//! serves on, and how callers prove who they are. Ported from mcp-go's
//! internal/config; every string lives in the arena `load` is given.
const std = @import("std");

/// Where the gateway serves when the user has not chosen another.
pub const default_port: i32 = 7331;

/// How the gateway reaches an upstream MCP server.
pub const Transport = union(enum) {
    stdio,
    sse,
    http,
    /// A transport this build does not know; carried through so a settings
    /// file written by a newer version is not silently rewritten.
    other: []const u8,

    /// The transport as the settings file writes it.
    pub fn name(t: Transport) []const u8 {
        return switch (t) {
            .stdio => "stdio",
            .sse => "sse",
            .http => "http",
            .other => |s| s,
        };
    }

    /// Whether t is a transport the gateway can connect with.
    pub fn valid(t: Transport) bool {
        return t != .other;
    }

    /// The transport's name for the interface.
    pub fn label(t: Transport) []const u8 {
        return switch (t) {
            .stdio => "stdio",
            .sse => "SSE",
            .http => "HTTP",
            .other => |s| s,
        };
    }

    pub fn fromName(n: []const u8) Transport {
        if (std.mem.eql(u8, n, "stdio")) return .stdio;
        if (std.mem.eql(u8, n, "sse")) return .sse;
        if (std.mem.eql(u8, n, "http")) return .http;
        return .{ .other = n };
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Transport {
        _ = options;
        const token = try source.nextAlloc(allocator, .alloc_always);
        const s = switch (token) {
            .string, .allocated_string => |str| str,
            else => return error.UnexpectedToken,
        };
        return fromName(s);
    }

    pub fn jsonStringify(t: Transport, jw: anytype) !void {
        try jw.write(t.name());
    }
};

/// How callers of the gateway prove who they are.
pub const InboundMode = union(enum) {
    /// Leaves the gateway open to anything that can reach its port.
    off,
    /// Requires the bearer token the user set.
    token,
    /// Requires a bearer token, and lets MCP clients obtain one by signing
    /// in, the gateway acting as its own authorization server.
    oauth,
    other: []const u8,

    pub fn valid(m: InboundMode) bool {
        return m != .other;
    }

    /// The mode's name for the interface.
    pub fn label(m: InboundMode) []const u8 {
        return switch (m) {
            .token => "Token",
            .oauth => "Token + OAuth",
            else => "Off",
        };
    }

    /// Whether callers must present a credential.
    pub fn requiresToken(m: InboundMode) bool {
        return m == .token or m == .oauth;
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !InboundMode {
        _ = options;
        const token = try source.nextAlloc(allocator, .alloc_always);
        const s = switch (token) {
            .string, .allocated_string => |str| str,
            else => return error.UnexpectedToken,
        };
        if (std.mem.eql(u8, s, "off")) return .off;
        if (std.mem.eql(u8, s, "token")) return .token;
        if (std.mem.eql(u8, s, "oauth")) return .oauth;
        return .{ .other = s };
    }

    pub fn jsonStringify(m: InboundMode, jw: anytype) !void {
        const s = switch (m) {
            .off => "off",
            .token => "token",
            .oauth => "oauth",
            .other => |v| v,
        };
        try jw.write(s);
    }
};

pub const ValidateError = error{
    NameRequired,
    UnknownTransport,
    CommandRequiredForStdio,
    SignInIsRemoteOnly,
    URLRequired,
    URLScheme,
    OAuthAndToken,
    BadHeaderName,
};

/// One upstream MCP server.
pub const ServerConfig = struct {
    /// Stable identity, survives renames.
    id: []const u8 = "",
    /// What the interface shows.
    name: []const u8 = "",
    /// Namespaces this server's tools.
    alias: []const u8 = "",
    transport: Transport = .stdio,
    /// Connect on launch.
    enabled: bool = false,

    // stdio upstreams.
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    /// "KEY=VALUE"
    env: ?[]const []const u8 = null,

    // SSE and streamable HTTP upstreams.
    url: ?[]const u8 = null,
    /// Static, non-secret.
    headers: ?std.json.ArrayHashMap([]const u8) = null,
    /// Sign in with OAuth 2.1.
    oauth: bool = false,

    // A static credential: the token itself lives in the credential store,
    // only the header it goes in is written down here.
    token_header: ?[]const u8 = null,
    token_scheme: ?[]const u8 = null,

    /// Reports why the server cannot be connected, or null.
    pub fn validate(s: ServerConfig) ValidateError!void {
        if (std.mem.eql(u8, std.mem.trim(u8, s.name, " \t\r\n"), "")) return error.NameRequired;
        if (!s.transport.valid()) return error.UnknownTransport;
        if (s.transport == .stdio) {
            if (std.mem.eql(u8, std.mem.trim(u8, s.command orelse "", " \t\r\n"), ""))
                return error.CommandRequiredForStdio;
            const header: []const u8 = s.token_header orelse "";
            if (s.oauth or header.len != 0) return error.SignInIsRemoteOnly;
            return;
        }
        const url = std.mem.trim(u8, s.url orelse "", " \t\r\n");
        if (url.len == 0) return error.URLRequired;
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://"))
            return error.URLScheme;
        const header: []const u8 = s.token_header orelse "";
        if (s.oauth and header.len != 0) return error.OAuthAndToken;
        if (s.token_header) |h| {
            if (!validHeaderName(h)) return error.BadHeaderName;
        }
    }

    /// Reports why the server cannot be connected, or null. The message is
    /// the Go original's, allocated from `a`.
    pub fn validateMessage(a: std.mem.Allocator, s: ServerConfig) ?[]u8 {
        s.validate() catch |err| return switch (err) {
            error.NameRequired => a.dupe(u8, "name is required") catch null,
            error.UnknownTransport => std.fmt.allocPrint(a, "unknown transport {s}", .{quoted(a, s.transport.name()) catch return null}) catch null,
            error.CommandRequiredForStdio => a.dupe(u8, "command is required for stdio servers") catch null,
            error.SignInIsRemoteOnly => a.dupe(u8, "signing in is only for SSE and HTTP servers") catch null,
            error.URLRequired => std.fmt.allocPrint(a, "URL is required for {s} servers", .{s.transport.label()}) catch null,
            error.URLScheme => a.dupe(u8, "URL must start with http:// or https://") catch null,
            error.OAuthAndToken => a.dupe(u8, "a server signs in with OAuth or with a token, not both") catch null,
            error.BadHeaderName => std.fmt.allocPrint(a, "{s} is not a valid header name", .{quoted(a, s.token_header orelse "") catch return null}) catch null,
        };
        return null;
    }

    /// Whether s can be sent as an HTTP header name.
    pub fn validHeaderName(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |ch| {
            switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
                else => return false,
            }
        }
        return true;
    }

    pub fn jsonStringify(s: ServerConfig, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(s.id);
        try jw.objectField("name");
        try jw.write(s.name);
        try jw.objectField("alias");
        try jw.write(s.alias);
        try jw.objectField("transport");
        try jw.write(s.transport);
        try jw.objectField("enabled");
        try jw.write(s.enabled);
        if (s.command) |v| if (v.len > 0) {
            try jw.objectField("command");
            try jw.write(v);
        };
        if (s.args) |v| if (v.len > 0) {
            try jw.objectField("args");
            try jw.write(v);
        };
        if (s.env) |v| if (v.len > 0) {
            try jw.objectField("env");
            try jw.write(v);
        };
        if (s.url) |v| if (v.len > 0) {
            try jw.objectField("url");
            try jw.write(v);
        };
        if (s.headers) |h| if (h.map.count() > 0) {
            try jw.objectField("headers");
            try jw.write(h);
        };
        if (s.oauth) {
            try jw.objectField("oauth");
            try jw.write(true);
        }
        if (s.token_header) |v| if (v.len > 0) {
            try jw.objectField("token_header");
            try jw.write(v);
        };
        if (s.token_scheme) |v| if (v.len > 0) {
            try jw.objectField("token_scheme");
            try jw.write(v);
        };
        try jw.endObject();
    }
};

/// Everything the app persists outside the credential store.
pub const Config = struct {
    port: i32 = default_port,
    servers: []const ServerConfig = &.{},
    /// How callers of the gateway prove who they are.
    inbound: InboundMode = .off,
    /// Remembers the window sidebar's folded state.
    sidebar_collapsed: bool = false,

    /// The configuration a fresh install starts from.
    pub fn default() Config {
        return .{};
    }

    /// The configured mode, defaulting to open.
    pub fn inboundMode(c: Config) InboundMode {
        const m = c.inbound;
        return if (m.valid()) m else .off;
    }

    /// The server with id, or null.
    pub fn server(c: Config, id: []const u8) ?ServerConfig {
        for (c.servers) |s| if (std.mem.eql(u8, s.id, id)) return s;
        return null;
    }

    /// Adds sc, or replaces the server that shares its ID. Strings must
    /// already live in the caller's arena.
    pub fn upsert(c: *Config, a: std.mem.Allocator, entry: ServerConfig) !void {
        const mutable = try a.alloc(ServerConfig, c.servers.len);
        @memcpy(mutable, c.servers);
        for (mutable, 0..) |s, i| {
            if (std.mem.eql(u8, s.id, entry.id)) {
                mutable[i] = entry;
                c.servers = mutable;
                return;
            }
        }
        const grown = try a.alloc(ServerConfig, c.servers.len + 1);
        @memcpy(grown[0..mutable.len], mutable);
        grown[mutable.len] = entry;
        c.servers = grown;
    }

    /// Deletes the server with id and reports whether it was there. Strings
    /// live in the caller's arena, so the removed entry is only unlinked.
    pub fn remove(c: *Config, a: std.mem.Allocator, id: []const u8) !bool {
        for (c.servers, 0..) |s, i| {
            if (std.mem.eql(u8, s.id, id)) {
                const kept = try a.alloc(ServerConfig, c.servers.len - 1);
                @memcpy(kept[0..i], c.servers[0..i]);
                @memcpy(kept[i..], c.servers[i + 1 ..]);
                c.servers = kept;
                return true;
            }
        }
        return false;
    }

    /// Gives every server a unique, sanitized alias and reports when it
    /// changed one. Aliases name the tools a server contributes, so two
    /// servers sharing one would collide downstream.
    pub fn ensureAliases(c: *Config, a: std.mem.Allocator) !bool {
        var changed = false;
        var taken: std.StringHashMapUnmanaged(void) = .empty;
        defer taken.deinit(a);
        const mutable = try a.alloc(ServerConfig, c.servers.len);
        @memcpy(mutable, c.servers);
        c.servers = mutable;
        for (mutable) |*s| {
            var alias = try aliasFor(a, if (s.alias.len != 0) s.alias else s.name);
            if (taken.contains(alias)) alias = try uniqueAlias(a, alias, &taken);
            try taken.put(a, alias, {});
            if (!std.mem.eql(u8, alias, s.alias)) {
                s.alias = alias;
                changed = true;
            }
        }
        return changed;
    }

    pub fn jsonStringify(c: Config, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("port");
        try jw.write(c.port);
        try jw.objectField("servers");
        try jw.write(c.servers);
        try jw.objectField("inbound");
        try jw.write(c.inbound);
        if (c.sidebar_collapsed) {
            try jw.objectField("sidebarCollapsed");
            try jw.write(true);
        }
        try jw.endObject();
    }
};

/// Wraps s in double quotes, the way the messages the interface shows quote
/// the values they name.
pub fn quoted(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

/// Turns a display name into the alias tools are prefixed with.
pub fn aliasFor(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (name) |ch| {
        const lower = std.ascii.toLower(ch);
        switch (lower) {
            'a'...'z', '0'...'9' => try out.append(a, lower),
            '-', '_', ' ', '.' => try out.append(a, '_'),
            else => {},
        }
    }
    var alias = out.items;
    while (alias.len > 0 and alias[alias.len - 1] == '_') alias = alias[0 .. alias.len - 1];
    if (alias.len == 0) return try a.dupe(u8, "server");
    return try a.dupe(u8, alias);
}

fn uniqueAlias(a: std.mem.Allocator, base: []const u8, taken: *std.StringHashMapUnmanaged(void)) ![]u8 {
    var n: usize = 2;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, n });
        if (!taken.contains(candidate)) {
            try taken.put(a, candidate, {});
            return candidate;
        }
    }
}

/// An identifier for a server that does not have one yet.
pub fn newId(a: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return try std.fmt.allocPrint(a, "{x}", .{bytes});
}

/// The file the configuration lives in, inside dir. Caller frees.
pub fn filePath(a: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ dir, "servers.json" });
}

const Wire = struct {
    port: i32 = default_port,
    servers: []const ServerConfig = &.{},
    inbound: InboundMode = .off,
    sidebarCollapsed: bool = false,
};

/// Reads the saved configuration, or the default one when none is saved.
/// All of its strings live in `a`.
pub fn load(a: std.mem.Allocator, io: std.Io, dir: []const u8) !Config {
    const path = try filePath(a, dir);
    defer a.free(path);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, a, data, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidConfig;
    var cfg: Config = .{
        .port = wire.port,
        .servers = wire.servers,
        .inbound = wire.inbound,
        .sidebar_collapsed = wire.sidebarCollapsed,
    };
    if (cfg.port == 0) cfg.port = default_port;
    _ = try cfg.ensureAliases(a);
    return cfg;
}

/// Writes the configuration, replacing the previous one atomically.
pub fn save(io: std.Io, a: std.mem.Allocator, cfg: Config, dir: []const u8) !void {
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &buf.writer);
    try buf.writer.writeByte('\n');
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try filePath(a, dir);
    defer a.free(path);
    const tmp = try std.fs.path.join(a, &.{ dir, "servers-tmp.json" });
    defer a.free(tmp);
    var file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .permissions = @enumFromInt(0o600) });
    file.writeStreamingAll(io, buf.written()) catch |err| {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    file.close(io);
    // A relative data directory (as tests use) is renamed within the working
    // directory; renameAbsolute would refuse it, a bare rename takes both.
    std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
}

test "an alias is a name a tool prefix can carry" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("file_system", try aliasFor(a, "File System"));
    try std.testing.expectEqualStrings("my_server", try aliasFor(a, "My.Server!"));
    try std.testing.expectEqualStrings("server", try aliasFor(a, "  !  "));
    try std.testing.expectEqualStrings("a__b", try aliasFor(a, "a__b_"));
}
