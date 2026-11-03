//! The tokens the gateway hands to its own callers, kept across restarts so a
//! client does not have to sign in again every launch. Tokens are written down
//! by their hash, so the file by itself grants nothing.
const std = @import("std");
const Io = std.Io;
const json = @import("json_util.zig");

/// How long an access token the gateway issues stays good for.
pub const access_ttl: i64 = 12 * 60 * 60;

/// How long a client may renew its access token for.
pub const refresh_ttl: i64 = 30 * 24 * 60 * 60;

/// How long an authorization code may wait to be exchanged.
pub const code_ttl: i64 = 5 * 60;

/// The scope every token carries: the gateway is one resource.
pub const scope = "mcp";

/// One issued token.
pub const TokenRecord = struct {
    client_id: []const u8,
    scope: []const u8 = "",
    expires_at: i64,
};

/// A client that registered itself with the gateway.
pub const ClientRecord = struct {
    redirect_uris: []const []const u8,
    registered_at: i64,
};

/// A code waiting to be exchanged, bound to the client, the redirect URI and
/// the PKCE challenge it was asked for.
pub const AuthCode = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    challenge: []const u8,
    scope: []const u8,
    expires_at: i64,
};

/// What a code exchange produced.
pub const Issued = struct {
    access: []const u8,
    refresh: []const u8,
    expires_at: i64,
};

/// The tokens, clients and codes the gateway keeps. Every method takes the
/// current time, so a test can move it.
pub const IssuedTokens = struct {
    a: std.mem.Allocator,
    io: Io,
    /// Where the tokens are written, or empty for a store that only lives in
    /// memory.
    path: []const u8 = "",
    mu: Io.Mutex = .init,
    access: std.StringHashMapUnmanaged(TokenRecord) = .empty,
    refresh: std.StringHashMapUnmanaged(TokenRecord) = .empty,
    clients: std.StringHashMapUnmanaged(ClientRecord) = .empty,
    codes: std.StringHashMapUnmanaged(AuthCode) = .empty,

    /// A store that lives in memory only, which is what a test wants.
    pub fn initMemory(a: std.mem.Allocator, io: Io) IssuedTokens {
        return .{ .a = a, .io = io };
    }

    /// A store kept in dir/gateway-tokens.json. A file that cannot be read is
    /// ignored: losing the tokens only means clients sign in again.
    pub fn initFiles(a: std.mem.Allocator, io: Io, dir: []const u8, now: i64) !IssuedTokens {
        var store: IssuedTokens = .{ .a = a, .io = io, .path = try std.fs.path.join(a, &.{ dir, "gateway-tokens.json" }) };
        try store.load(now);
        return store;
    }

    pub fn deinit(s: *IssuedTokens) void {
        const a = s.a;
        var it = s.access.iterator();
        while (it.next()) |kv| {
            a.free(kv.key_ptr.*);
            a.free(kv.value_ptr.client_id);
            a.free(kv.value_ptr.scope);
        }
        s.access.deinit(a);

        var rit = s.refresh.iterator();
        while (rit.next()) |kv| {
            a.free(kv.key_ptr.*);
            a.free(kv.value_ptr.client_id);
            a.free(kv.value_ptr.scope);
        }
        s.refresh.deinit(a);

        var cit = s.clients.iterator();
        while (cit.next()) |kv| {
            a.free(kv.key_ptr.*);
            for (kv.value_ptr.redirect_uris) |uri| a.free(uri);
            a.free(kv.value_ptr.redirect_uris);
        }
        s.clients.deinit(a);

        var oit = s.codes.iterator();
        while (oit.next()) |kv| {
            a.free(kv.key_ptr.*);
            a.free(kv.value_ptr.client_id);
            a.free(kv.value_ptr.redirect_uri);
            a.free(kv.value_ptr.challenge);
            a.free(kv.value_ptr.scope);
        }
        s.codes.deinit(a);

        if (s.path.len > 0) a.free(s.path);
    }

    /// Mints an access token and a refresh token for a client.
    pub fn issue(s: *IssuedTokens, client_id: []const u8, token_scope: []const u8, now: i64) !Issued {
        const a = s.a;
        const access = try randomToken(a, s.io);
        errdefer a.free(access);
        const refresh = try randomToken(a, s.io);
        errdefer a.free(refresh);
        const expires_at = now + access_ttl;

        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        try s.pruneLocked(now);
        try s.putToken(&s.access, access, .{
            .client_id = try a.dupe(u8, client_id),
            .scope = try a.dupe(u8, token_scope),
            .expires_at = expires_at,
        });
        try s.putToken(&s.refresh, refresh, .{
            .client_id = try a.dupe(u8, client_id),
            .scope = try a.dupe(u8, token_scope),
            .expires_at = now + refresh_ttl,
        });
        s.saveLocked(now);
        return .{ .access = access, .refresh = refresh, .expires_at = expires_at };
    }

    /// Mints a fresh access token for a refresh token that is still good.
    pub fn renew(s: *IssuedTokens, refresh: []const u8, client_id: []const u8, now: i64) !Issued {
        const a = s.a;
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        try s.pruneLocked(now);

        const hash = try hashToken(a, refresh);
        defer a.free(hash);
        const record = s.refresh.get(hash) orelse return error.InvalidGrant;
        if (!std.mem.eql(u8, record.client_id, client_id)) return error.InvalidGrant;

        const access = try randomToken(a, s.io);
        errdefer a.free(access);
        const expires_at = now + access_ttl;
        try s.putToken(&s.access, access, .{
            .client_id = try a.dupe(u8, client_id),
            .scope = try a.dupe(u8, record.scope),
            .expires_at = expires_at,
        });
        s.saveLocked(now);
        // A renewal does not mint a new refresh token, so the caller keeps the
        // one it already has.
        return .{ .access = access, .refresh = try a.dupe(u8, refresh), .expires_at = expires_at };
    }

    /// Whether a presented token is one the gateway issued and is still good
    /// for.
    pub fn accepts(s: *IssuedTokens, token: []const u8, now: i64) bool {
        if (token.len == 0) return false;
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);

        const hash = hashToken(s.a, token) catch return false;
        defer s.a.free(hash);
        const record = s.access.get(hash) orelse return false;
        if (now > record.expires_at) {
            if (s.access.fetchRemove(hash)) |kv| {
                s.a.free(kv.key);
                s.a.free(kv.value.client_id);
                s.a.free(kv.value.scope);
            }
            s.saveLocked(now);
            return false;
        }
        return true;
    }

    /// How many callers currently hold a token.
    pub fn count(s: *IssuedTokens, now: i64) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        s.pruneLocked(now) catch {};
        return s.access.count();
    }

    /// Forgets every issued token, so callers have to sign in again. The
    /// clients that registered stay, so they need not register again.
    pub fn revokeAll(s: *IssuedTokens, now: i64) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var it = s.access.iterator();
        while (it.next()) |kv| {
            s.a.free(kv.key_ptr.*);
            s.a.free(kv.value_ptr.client_id);
            s.a.free(kv.value_ptr.scope);
        }
        s.access.clearRetainingCapacity();
        var rit = s.refresh.iterator();
        while (rit.next()) |kv| {
            s.a.free(kv.key_ptr.*);
            s.a.free(kv.value_ptr.client_id);
            s.a.free(kv.value_ptr.scope);
        }
        s.refresh.clearRetainingCapacity();
        s.saveLocked(now);
    }

    /// Records a client and hands it an identifier. Clients are public, so the
    /// identifier is all they get.
    pub fn registerClient(s: *IssuedTokens, redirect_uris: []const []const u8, now: i64) ![]u8 {
        const a = s.a;
        const client_id = try randomToken(a, s.io);
        errdefer a.free(client_id);

        const uris = try a.alloc([]const u8, redirect_uris.len);
        for (redirect_uris, 0..) |uri, i| uris[i] = try a.dupe(u8, uri);

        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        try s.clients.put(a, client_id, .{ .redirect_uris = uris, .registered_at = now });
        s.saveLocked(now);
        return client_id;
    }

    /// The redirect URIs a client registered, or null when it never did.
    pub fn clientRedirects(s: *IssuedTokens, client_id: []const u8) ?[]const []const u8 {
        if (client_id.len == 0) return null;
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        const record = s.clients.get(client_id) orelse return null;
        return record.redirect_uris;
    }

    /// Issues an authorization code, bound to the client, the redirect URI and
    /// the PKCE challenge it was asked for.
    pub fn newCode(s: *IssuedTokens, code: AuthCode, now: i64) ![]u8 {
        const a = s.a;
        const value = try randomToken(a, s.io);
        errdefer a.free(value);

        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        try s.pruneCodesLocked(now);
        try s.codes.put(a, value, .{
            .client_id = try a.dupe(u8, code.client_id),
            .redirect_uri = try a.dupe(u8, code.redirect_uri),
            .challenge = try a.dupe(u8, code.challenge),
            .scope = try a.dupe(u8, code.scope),
            .expires_at = now + code_ttl,
        });
        return value;
    }

    /// Takes a code out of the store, so it can be exchanged exactly once. A
    /// code is burned whether or not the exchange succeeds, which is what
    /// stops a client guessing at the verifier.
    pub fn takeCode(s: *IssuedTokens, code: []const u8, now: i64) ?AuthCode {
        if (code.len == 0) return null;
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        s.pruneCodesLocked(now) catch {};
        const kv = s.codes.fetchRemove(code) orelse return null;
        s.a.free(kv.key);
        return kv.value;
    }

    fn putToken(s: *IssuedTokens, map: *std.StringHashMapUnmanaged(TokenRecord), token: []const u8, record: TokenRecord) !void {
        const a = s.a;
        const hash = try hashToken(a, token);
        if (map.fetchRemove(hash)) |old| {
            a.free(old.key);
            a.free(old.value.client_id);
            a.free(old.value.scope);
        }
        try map.put(a, hash, record);
    }

    /// Forgets the tokens that have expired.
    fn pruneLocked(s: *IssuedTokens, now: i64) !void {
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(s.a);
        var it = s.access.iterator();
        while (it.next()) |kv| {
            if (now > kv.value_ptr.expires_at) try stale.append(s.a, kv.key_ptr.*);
        }
        for (stale.items) |hash| {
            if (s.access.fetchRemove(hash)) |kv| {
                s.a.free(kv.key);
                s.a.free(kv.value.client_id);
                s.a.free(kv.value.scope);
            }
        }

        stale.clearRetainingCapacity();
        var rit = s.refresh.iterator();
        while (rit.next()) |kv| {
            if (now > kv.value_ptr.expires_at) try stale.append(s.a, kv.key_ptr.*);
        }
        for (stale.items) |hash| {
            if (s.refresh.fetchRemove(hash)) |kv| {
                s.a.free(kv.key);
                s.a.free(kv.value.client_id);
                s.a.free(kv.value.scope);
            }
        }
    }

    fn pruneCodesLocked(s: *IssuedTokens, now: i64) !void {
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(s.a);
        var it = s.codes.iterator();
        while (it.next()) |kv| {
            if (now > kv.value_ptr.expires_at) try stale.append(s.a, kv.key_ptr.*);
        }
        for (stale.items) |code| {
            if (s.codes.fetchRemove(code)) |kv| {
                s.a.free(kv.key);
                s.a.free(kv.value.client_id);
                s.a.free(kv.value.redirect_uri);
                s.a.free(kv.value.challenge);
                s.a.free(kv.value.scope);
            }
        }
    }

    /// Reads the tokens that were written down, dropping the expired ones.
    fn load(s: *IssuedTokens, now: i64) !void {
        if (s.path.len == 0) return;
        const data = std.Io.Dir.cwd().readFileAlloc(s.io, s.path, s.a, .limited(8 << 20)) catch return;
        defer s.a.free(data);

        const doc = json.parse(s.a, data) catch return;
        if (!json.isObject(doc)) return;

        if (json.getObject(doc, "access")) |access| try s.loadTokens(&s.access, access);
        if (json.getObject(doc, "refresh")) |refresh| try s.loadTokens(&s.refresh, refresh);
        if (json.getObject(doc, "clients")) |clients| {
            var it = clients.iterator();
            while (it.next()) |kv| {
                if (!json.isObject(kv.value_ptr.*)) continue;
                const uris_value = json.getArray(kv.value_ptr.*, "redirect_uris") orelse continue;
                const uris = try s.a.alloc([]const u8, uris_value.items.len);
                for (uris_value.items, 0..) |uri, i| {
                    uris[i] = switch (uri) {
                        .string => |t| try s.a.dupe(u8, t),
                        else => try s.a.dupe(u8, ""),
                    };
                }
                try s.clients.put(s.a, try s.a.dupe(u8, kv.key_ptr.*), .{
                    .redirect_uris = uris,
                    .registered_at = json.getInt(kv.value_ptr.*, "registered_at") orelse now,
                });
            }
        }
        s.pruneLocked(now) catch {};
    }

    fn loadTokens(s: *IssuedTokens, map: *std.StringHashMapUnmanaged(TokenRecord), o: json.Object) !void {
        var it = o.iterator();
        while (it.next()) |kv| {
            if (!json.isObject(kv.value_ptr.*)) continue;
            try map.put(s.a, try s.a.dupe(u8, kv.key_ptr.*), .{
                .client_id = try s.a.dupe(u8, json.getString(kv.value_ptr.*, "client_id") orelse ""),
                .scope = try s.a.dupe(u8, json.getString(kv.value_ptr.*, "scope") orelse ""),
                .expires_at = json.getInt(kv.value_ptr.*, "expires_at") orelse 0,
            });
        }
    }

    /// Writes the tokens down, dropping the expired ones first.
    fn saveLocked(s: *IssuedTokens, now: i64) void {
        if (s.path.len == 0) return;
        s.pruneLocked(now) catch {};
        s.writeFile() catch {};
    }

    fn writeFile(s: *IssuedTokens) !void {
        const a = s.a;
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        const doc = s.toJson(a);
        try std.json.Stringify.value(doc.v, .{ .whitespace = .indent_2 }, &buf.writer);
        const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{s.path});
        defer a.free(tmp);

        const file = try std.Io.Dir.cwd().createFile(s.io, tmp, .{ .permissions = @enumFromInt(0o600) });
        var closed = false;
        defer if (!closed) file.close(s.io);
        try file.writeStreamingAll(s.io, buf.written());
        try file.writeStreamingAll(s.io, "\n");
        file.close(s.io);
        closed = true;
        try std.Io.Dir.renameAbsolute(tmp, s.path, s.io);
    }

    /// The tokens as they are written down: keyed by hash, so the file is not
    /// a way in.
    fn toJson(s: *IssuedTokens, a: std.mem.Allocator) json.J {
        var doc: json.J = .object(a);
        doc.put("access", tokensJson(a, &s.access));
        doc.put("refresh", tokensJson(a, &s.refresh));
        doc.put("clients", clientsJson(a, &s.clients));
        return doc;
    }
};

fn tokensJson(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(TokenRecord)) json.J {
    var out: json.J = .object(a);
    var it = map.iterator();
    while (it.next()) |kv| {
        var record: json.J = .object(a);
        record.putText("client_id", kv.value_ptr.client_id);
        if (kv.value_ptr.scope.len > 0) record.putText("scope", kv.value_ptr.scope);
        record.put("expires_at", .int(a, kv.value_ptr.expires_at));
        out.put(kv.key_ptr.*, record);
    }
    return out;
}

fn clientsJson(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(ClientRecord)) json.J {
    var out: json.J = .object(a);
    var it = map.iterator();
    while (it.next()) |kv| {
        var record: json.J = .object(a);
        var uris: json.J = .array(a);
        for (kv.value_ptr.redirect_uris) |uri| uris.add(.str(a, uri));
        record.put("redirect_uris", uris);
        record.put("registered_at", .int(a, kv.value_ptr.registered_at));
        out.put(kv.key_ptr.*, record);
    }
    return out;
}

/// What the store is keyed by.
pub fn hashToken(a: std.mem.Allocator, token: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const out = try a.alloc(u8, digest.len * 2);
    return std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

/// A token with 256 bits behind it.
pub fn randomToken(a: std.mem.Allocator, io: Io) ![]u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const out = try a.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &bytes);
    return out;
}

test "an issued token is accepted until it expires" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var store = IssuedTokens.initMemory(a, std.testing.io);
    defer store.deinit();

    const now: i64 = 1_000_000;
    const issued = try store.issue("client-a", scope, now);
    try std.testing.expect(issued.access.len > 0);
    try std.testing.expect(!std.mem.eql(u8, issued.access, issued.refresh));
    try std.testing.expect(store.accepts(issued.access, now));
    try std.testing.expect(store.accepts(issued.access, now + access_ttl - 1));
    try std.testing.expect(!store.accepts(issued.access, now + access_ttl + 1));
    try std.testing.expect(!store.accepts("", now));
    try std.testing.expect(!store.accepts("never-issued", now));
    try std.testing.expectEqual(@as(usize, 0), store.count(now + access_ttl + 1));
}

test "a refresh token renews a token, and belongs to one client" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var store = IssuedTokens.initMemory(a, std.testing.io);
    defer store.deinit();

    const now: i64 = 5_000;
    const issued = try store.issue("client-a", scope, now);
    const renewed = try store.renew(issued.refresh, "client-a", now + 10);
    try std.testing.expect(!std.mem.eql(u8, renewed.access, issued.access));
    try std.testing.expect(store.accepts(renewed.access, now + 10));

    try std.testing.expectError(error.InvalidGrant, store.renew(issued.refresh, "client-b", now + 10));
    try std.testing.expectError(error.InvalidGrant, store.renew("not-a-token", "client-a", now + 10));
}

test "a code is exchanged exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var store = IssuedTokens.initMemory(a, std.testing.io);
    defer store.deinit();

    const now: i64 = 42;
    const code = try store.newCode(.{
        .client_id = "client-a",
        .redirect_uri = "http://127.0.0.1:9999/cb",
        .challenge = "abc",
        .scope = scope,
        .expires_at = 0,
    }, now);
    const taken = store.takeCode(code, now).?;
    try std.testing.expectEqualStrings("client-a", taken.client_id);
    try std.testing.expectEqualStrings("abc", taken.challenge);
    try std.testing.expect(store.takeCode(code, now) == null);

    const expired = try store.newCode(.{
        .client_id = "client-a",
        .redirect_uri = "http://127.0.0.1:9999/cb",
        .challenge = "abc",
        .scope = scope,
        .expires_at = 0,
    }, now);
    try std.testing.expect(store.takeCode(expired, now + code_ttl + 1) == null);
}

test "revoking every token leaves the registered clients" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var store = IssuedTokens.initMemory(a, std.testing.io);
    defer store.deinit();

    const client_id = try store.registerClient(&.{"http://127.0.0.1:9999/cb"}, 1);
    const issued = try store.issue(client_id, scope, 1);
    try std.testing.expect(store.accepts(issued.access, 1));

    store.revokeAll(2);
    try std.testing.expect(!store.accepts(issued.access, 2));
    try std.testing.expectEqual(@as(usize, 0), store.count(2));
    try std.testing.expect(store.clientRedirects(client_id) != null);
    try std.testing.expect(store.clientRedirects("nobody") == null);
    try std.testing.expect(store.clientRedirects("") == null);
}

test "the tokens are written down by hash and read back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    const dir = "/tmp/nanomcp-tokens-test";

    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    const now: i64 = 1_700_000_000;
    var store = try IssuedTokens.initFiles(a, io, dir, now);
    defer store.deinit();

    const client_id = try store.registerClient(&.{"http://127.0.0.1:9999/cb"}, now);
    const issued = try store.issue(client_id, scope, now);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, store.path, a, .limited(1 << 20));
    // The token itself is nowhere in the file, only its hash.
    try std.testing.expect(std.mem.indexOf(u8, data, issued.access) == null);
    try std.testing.expect(std.mem.indexOf(u8, data, "client_id") != null);

    var reloaded = try IssuedTokens.initFiles(a, io, dir, now);
    defer reloaded.deinit();
    try std.testing.expect(reloaded.accepts(issued.access, now));
    try std.testing.expect(reloaded.clientRedirects(client_id) != null);
    try std.testing.expectEqual(@as(usize, 1), reloaded.count(now));

    // A file that is not there is not an error: the clients sign in again.
    var missing = try IssuedTokens.initFiles(a, io, "/tmp/nanomcp-tokens-nope", now);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.count(now));
}

test "a hash is not the token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hash = try hashToken(a, "secret");
    try std.testing.expectEqual(@as(usize, 64), hash.len);
    try std.testing.expectEqualStrings(
        "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b",
        hash,
    );
}
