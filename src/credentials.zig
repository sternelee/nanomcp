//! The secrets the gateway keeps: upstream OAuth tokens, the client
//! credentials dynamic registration handed out, static upstream tokens, and
//! the token callers of the gateway must present.
//!
//! There is no system credential store here; every value lives in a file under
//! `<user data>/credentials/`, written 0600 in a directory created 0700. The
//! gateway above it only knows this interface, so where the bytes are kept is
//! a detail of this module.
const std = @import("std");

/// Parsed strings are copied, not borrowed from the buffer they came in:
/// the buffer is freed before the value is used.
const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

/// The token an OAuth upstream issued.
pub const Token = struct {
    /// Trusted local provenance, not token endpoint metadata.
    issuer: ?[]const u8 = null,
    access_token: []const u8 = "",
    token_type: []const u8 = "",
    refresh_token: ?[]const u8 = null,
    expires_in: i64 = 0,
    scope: ?[]const u8 = null,
    /// Unix seconds; 0 means the token does not expire.
    expires_at: i64 = 0,

    /// Whether the token has expired by `now`, in Unix seconds. The caller
    /// passes the clock so a test can hold still.
    pub fn isExpired(t: Token, now: i64) bool {
        if (t.expires_at == 0) return false;
        return now > t.expires_at;
    }
};

/// What dynamic client registration returned, kept so a server is registered
/// once rather than at every sign-in.
pub const ClientCredentials = struct {
    client_id: []const u8 = "",
    secret: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    auth_method: ?[]const u8 = null,
};

/// Where a CredentialStore keeps its secrets.
pub const Backend = union(enum) {
    /// A directory of files: <dir>/<key>.json, 0600.
    files: struct { gpa: std.mem.Allocator, io: std.Io, dir: []const u8 },
    /// For tests, so they never reach the user's real directory.
    memory: struct {
        gpa: std.mem.Allocator,
        values: std.StringHashMapUnmanaged([]u8) = .empty,
    },
};

/// Keys are "/"-separated, so a key names a subdirectory and the file name
/// stays readable.
pub const CredentialStore = struct {
    backend: Backend,

    /// A store backed by files under `dir` (the app's credential directory).
    pub fn initFiles(alloc: std.mem.Allocator, io: std.Io, dir: []const u8) CredentialStore {
        return .{ .backend = .{ .files = .{ .gpa = alloc, .io = io, .dir = dir } } };
    }

    /// A store that keeps everything in this process.
    pub fn initMemory(alloc: std.mem.Allocator) CredentialStore {
        return .{ .backend = .{ .memory = .{ .gpa = alloc } } };
    }

    pub fn deinit(c: *CredentialStore) void {
        switch (c.backend) {
            .files => {},
            .memory => |*m| {
                var it = m.values.iterator();
                while (it.next()) |e| {
                    m.gpa.free(e.key_ptr.*);
                    m.gpa.free(e.value_ptr.*);
                }
                m.values.deinit(m.gpa);
            },
        }
    }

    /// Names the stored token of a server.
    pub fn tokenKey(a: std.mem.Allocator, server_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "oauth-token/{s}", .{server_id});
    }

    fn clientKey(a: std.mem.Allocator, server_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "oauth-client/{s}", .{server_id});
    }

    /// Names the stored static token of a server.
    pub fn upstreamTokenKey(a: std.mem.Allocator, server_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "upstream-token/{s}", .{server_id});
    }

    /// Names the bearer token callers of the gateway must present.
    pub const inbound_token_key = "inbound-token";

    /// The allocator the store was built with.
    fn allocatorOf(c: *CredentialStore) std.mem.Allocator {
        return switch (c.backend) {
            .files => |f| f.gpa,
            .memory => |m| m.gpa,
        };
    }

    /// Reads a value, or null when there is none. Caller frees.
    pub fn get(c: *CredentialStore, key: []const u8) !?[]u8 {
        switch (c.backend) {
            .files => |f| {
                const path = try c.pathOf(f, key);
                defer f.gpa.free(path);
                return std.Io.Dir.cwd().readFileAlloc(f.io, path, f.gpa, .limited(1 << 20)) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
            },
            .memory => |m| {
                const v = m.values.get(key) orelse return null;
                return try m.gpa.dupe(u8, v);
            },
        }
    }

    /// Writes a value, creating what it needs.
    pub fn set(c: *CredentialStore, key: []const u8, value: []const u8) !void {
        switch (c.backend) {
            .files => |f| {
                const path = try c.pathOf(f, key);
                defer f.gpa.free(path);
                if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(f.io, parent);
                var file = try std.Io.Dir.cwd().createFile(f.io, path, .{ .permissions = @enumFromInt(0o600) });
                defer file.close(f.io);
                try file.writeStreamingAll(f.io, value);
            },
            .memory => |*m| {
                // The map owns its keys: callers hand over a key they free.
                const gop = try m.values.getOrPut(m.gpa, key);
                const copy = try m.gpa.dupe(u8, value);
                if (gop.found_existing) {
                    m.gpa.free(gop.value_ptr.*);
                } else {
                    gop.key_ptr.* = try m.gpa.dupe(u8, key);
                }
                gop.value_ptr.* = copy;
            },
        }
    }

    /// Forgets a value; forgetting one that is not there is not an error.
    pub fn delete(c: *CredentialStore, key: []const u8) !void {
        switch (c.backend) {
            .files => |f| {
                const path = try c.pathOf(f, key);
                defer f.gpa.free(path);
                std.Io.Dir.cwd().deleteFile(f.io, path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            },
            .memory => |*m| {
                if (m.values.fetchRemove(key)) |old| {
                    m.gpa.free(old.key);
                    m.gpa.free(old.value);
                }
            },
        }
    }

    fn pathOf(c: *CredentialStore, f: anytype, key: []const u8) ![]u8 {
        _ = c;
        const name = try std.fmt.allocPrint(f.gpa, "{s}.json", .{key});
        defer f.gpa.free(name);
        const parts = try f.gpa.alloc([]const u8, 2);
        defer f.gpa.free(parts);
        parts[0] = f.dir;
        parts[1] = name;
        return std.fs.path.join(f.gpa, parts);
    }

    /// Reads a secret kept as plain text, copied into `a`, or "" when there is
    /// none. The store's own copy is freed here, so the caller only has its
    /// own to deal with.
    pub fn text(c: *CredentialStore, a: std.mem.Allocator, key: []const u8) []const u8 {
        const value = c.get(key) catch return "";
        const owned = value orelse return "";
        defer c.allocatorOf().free(owned);
        return a.dupe(u8, owned) catch "";
    }

    /// Writes a plain-text secret, forgetting it when it is blank. This is
    /// what keeps a secret out of the configuration file.
    pub fn setSecret(c: *CredentialStore, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "")) return c.delete(key);
        try c.set(key, value);
    }

    /// The static token saved for a server, or "".
    pub fn upstreamToken(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8) []const u8 {
        const key = upstreamTokenKey(a, server_id) catch return "";
        defer a.free(key);
        return c.text(a, key);
    }

    /// Whether a server has a static token, without revealing it.
    pub fn hasUpstreamToken(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8) bool {
        return c.upstreamToken(a, server_id).len != 0;
    }

    /// Saves a server's static token, or forgets it when blank.
    pub fn setUpstreamToken(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8, value: []const u8) !void {
        const key = try upstreamTokenKey(a, server_id);
        defer a.free(key);
        try c.setSecret(key, value);
    }

    /// The bearer token callers of the gateway must present, copied into `a`,
    /// or "".
    pub fn inboundToken(c: *CredentialStore, a: std.mem.Allocator) []const u8 {
        return c.text(a, inbound_token_key);
    }

    /// Saves the token callers must present, or clears it.
    pub fn setInboundToken(c: *CredentialStore, value: []const u8) !void {
        try c.setSecret(inbound_token_key, value);
    }

    /// The saved client credentials of a server, or an empty value.
    pub fn client(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8) ClientCredentials {
        const key = clientKey(a, server_id) catch return .{};
        defer a.free(key);
        const raw = (c.get(key) catch return .{}) orelse return .{};
        defer a.free(raw);
        return std.json.parseFromSliceLeaky(ClientCredentials, a, raw, parse_options) catch .{};
    }

    /// Stores the client credentials of a server.
    pub fn saveClient(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8, cc: ClientCredentials) !void {
        const key = try clientKey(a, server_id);
        defer a.free(key);
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        try std.json.Stringify.value(cc, .{ .emit_null_optional_fields = false }, &buf.writer);
        try c.set(key, buf.written());
    }

    /// Whether a server has a token that has not expired.
    pub fn signedIn(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8, now: i64) bool {
        const maybe = c.loadToken(a, server_id) catch return false;
        const t = maybe orelse return false;
        return t.access_token.len != 0 and !t.isExpired(now);
    }

    /// Forgets a server's token, keeping its registered client.
    pub fn signOut(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8) !void {
        const key = try tokenKey(a, server_id);
        defer a.free(key);
        try c.delete(key);
    }

    /// The token store an OAuth handler reads and writes.
    pub fn tokenStore(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8) !TokenStore {
        return .{ .store = c, .key = try tokenKey(a, server_id) };
    }

    /// Reads a server's token; null when there is none or it is unusable.
    pub fn loadToken(c: *CredentialStore, a: std.mem.Allocator, server_id: []const u8) !?Token {
        var store = try c.tokenStore(a, server_id);
        defer a.free(store.key);
        return store.get();
    }
};

/// transport.TokenStore: what an OAuth handler reads and writes.
pub const TokenStore = struct {
    store: *CredentialStore,
    key: []const u8,

    /// Returns error.NoToken when there is none, as transport.ErrNoToken did.
    pub fn get(s: TokenStore) !?Token {
        const gpa = s.store.allocatorOf();
        const raw = try s.store.get(s.key) orelse return null;
        defer gpa.free(raw);
        const t = std.json.parseFromSliceLeaky(Token, gpa, raw, parse_options) catch return null;
        if (t.access_token.len == 0) return null;
        return t;
    }

    pub fn save(s: TokenStore, value: Token) !void {
        const gpa = s.store.allocatorOf();
        // The store writes through its own backend; constness only guards
        // the pointer, not the file.
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &buf.writer);
        try s.store.set(s.key, buf.written());
    }
};

test "a fresh store has nothing, and forgetting a blank token clears it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var store: CredentialStore = .initMemory(a);
    defer store.deinit();

    try std.testing.expect(!store.hasUpstreamToken(a, "s1"));
    try std.testing.expectEqualStrings("", store.upstreamToken(a, "s1"));

    try store.setUpstreamToken(a, "s1", "ghp_secret");
    try std.testing.expectEqualStrings("ghp_secret", store.upstreamToken(a, "s1"));
    try std.testing.expectEqualStrings("", store.upstreamToken(a, "s2"));

    try store.setUpstreamToken(a, "s1", "   ");
    try std.testing.expect(!store.hasUpstreamToken(a, "s1"));
}

test "the inbound token is kept until it is cleared" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var store: CredentialStore = .initMemory(a);
    defer store.deinit();

    try std.testing.expectEqualStrings("", store.inboundToken(a));
    try store.setInboundToken("callers-must-present-this");
    try std.testing.expectEqualStrings("callers-must-present-this", store.inboundToken(a));
    try store.setInboundToken("");
    try std.testing.expectEqualStrings("", store.inboundToken(a));
}

test "reading a secret frees the store's copy" {
    const gpa = std.testing.allocator;
    var store: CredentialStore = .initMemory(gpa);
    defer store.deinit();

    try store.setInboundToken("callers-must-present-this");
    const got = store.inboundToken(gpa);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("callers-must-present-this", got);
}

test "a token is saved, read back and forgotten" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var store: CredentialStore = .initMemory(a);
    defer store.deinit();

    try std.testing.expect((try store.loadToken(a, "s1")) == null);
    try std.testing.expect(!store.signedIn(a, "s1", 1_000_000));

    var ts = try store.tokenStore(a, "s1");
    try ts.save(.{ .access_token = "access", .token_type = "Bearer", .refresh_token = "refresh", .issuer = "https://as.example" });
    const got = (try store.loadToken(a, "s1")).?;
    try std.testing.expectEqualStrings("access", got.access_token);
    try std.testing.expectEqualStrings("refresh", got.refresh_token.?);
    try std.testing.expectEqualStrings("https://as.example", got.issuer.?);
    try std.testing.expect(store.signedIn(a, "s1", 1_000_000));

    try store.signOut(a, "s1");
    try std.testing.expect((try store.loadToken(a, "s1")) == null);
    try std.testing.expect(!store.signedIn(a, "s1", 1_000_000));
}

test "client credentials survive a round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var store: CredentialStore = .initMemory(a);
    defer store.deinit();

    const want: ClientCredentials = .{ .client_id = "cid", .secret = "sec", .issuer = "https://as.example", .auth_method = "none" };
    try store.saveClient(a, "s1", want);
    const got = store.client(a, "s1");
    try std.testing.expectEqualStrings("cid", got.client_id);
    try std.testing.expectEqualStrings("sec", got.secret.?);
    try std.testing.expectEqualStrings("", store.client(a, "s2").client_id);
}

test "a file store writes 0600 under its directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanomcp-test-credentials";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var store: CredentialStore = .initFiles(gpa, io, dir);
    defer store.deinit();
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try store.setUpstreamToken(gpa, "s1", "ghp_secret");
    const got = store.upstreamToken(gpa, "s1");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ghp_secret", got);

    const path = dir ++ "/upstream-token/s1.json";
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("ghp_secret", data);

    try store.setUpstreamToken(gpa, "s1", "");
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16)));
}
