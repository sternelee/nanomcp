//! JSON-RPC 2.0 as MCP speaks it: requests, responses and notifications.
const std = @import("std");
const json = @import("json_util.zig");

pub const Value = json.Value;
pub const J = json.J;

/// The protocol version this gateway speaks, and the ones it accepts.
pub const latest_version = "2025-06-18";
pub const supported_versions = [_][]const u8{ latest_version, "2025-03-26", "2024-11-05" };

/// The error codes JSON-RPC defines.
pub const parse_error: i64 = -32700;
pub const invalid_request: i64 = -32600;
pub const method_not_found: i64 = -32601;
pub const invalid_params: i64 = -32602;
pub const internal_error: i64 = -32603;

/// A request or response id: a number or a string, both are legal.
pub const Id = union(enum) {
    number: i64,
    text: []const u8,

    pub fn parse(v: Value) ?Id {
        return switch (v) {
            .integer => |n| .{ .number = n },
            .string => |s| .{ .text = s },
            else => null,
        };
    }

    pub fn toJson(id: Id, a: std.mem.Allocator) J {
        return switch (id) {
            .number => |n| J.int(a, n),
            .text => |s| J.str(a, s),
        };
    }

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .number => |n| b == .number and b.number == n,
            .text => |s| b == .text and std.mem.eql(u8, b.text, s),
        };
    }
};

/// A message that arrived, sorted by what it asks for.
pub const Message = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
    /// Bytes that are not JSON-RPC at all, kept so a server can answer.
    malformed,

    pub const Request = struct {
        id: Id,
        method: []const u8,
        params: Value = .null,
    };

    pub const Response = struct {
        id: ?Id,
        result: Value = .null,
        err: ?Error = null,
    };

    pub const Notification = struct {
        method: []const u8,
        params: Value = .null,
    };

    /// Reads a document into a message, borrowing its strings from `text`.
    pub fn parse(a: std.mem.Allocator, text: []const u8) Message {
        const doc = json.parse(a, text) catch return .malformed;
        if (!json.isObject(doc)) return .malformed;
        const method = json.getString(doc, "method");
        const id_value = json.get(doc, "id");
        const params = json.get(doc, "params") orelse Value.null;

        if (method) |m| {
            if (id_value) |iv| {
                const id = Id.parse(iv) orelse return .malformed;
                return .{ .request = .{ .id = id, .method = m, .params = params } };
            }
            return .{ .notification = .{ .method = m, .params = params } };
        }
        if (json.get(doc, "error")) |ev| {
            return .{ .response = .{
                .id = if (id_value) |iv| Id.parse(iv) else null,
                .err = Error.parse(ev),
            } };
        }
        if (json.get(doc, "result")) |rv| {
            return .{ .response = .{
                .id = if (id_value) |iv| Id.parse(iv) else null,
                .result = rv,
            } };
        }
        return .malformed;
    }
};

/// The error member of a response.
pub const Error = struct {
    code: i64,
    message: []const u8,
    data: ?Value = null,

    pub fn parse(v: Value) Error {
        return .{
            .code = json.getInt(v, "code") orelse internal_error,
            .message = json.getString(v, "message") orelse "unknown error",
            .data = json.get(v, "data"),
        };
    }

    pub fn toJson(e: Error, a: std.mem.Allocator) J {
        var v = J.object(a);
        v.put("code", J.int(a, e.code));
        v.put("message", J.str(a, e.message));
        if (e.data) |d| v.put("data", J.from(a, d));
        return v;
    }
};

/// Writes a request.
pub fn request(a: std.mem.Allocator, id: Id, method: []const u8, params: Value) ![]u8 {
    var v = J.object(a);
    v.put("jsonrpc", J.str(a, "2.0"));
    v.put("id", id.toJson(a));
    v.put("method", J.str(a, method));
    if (params != .null) v.put("params", J.from(a, params));
    return v.dump();
}

/// Writes a notification: a request with nothing to answer.
pub fn notification(a: std.mem.Allocator, method: []const u8, params: Value) ![]u8 {
    var v = J.object(a);
    v.put("jsonrpc", J.str(a, "2.0"));
    v.put("method", J.str(a, method));
    if (params != .null) v.put("params", J.from(a, params));
    return v.dump();
}

/// Writes a successful response.
pub fn result(a: std.mem.Allocator, id: Id, value: Value) ![]u8 {
    var v = J.object(a);
    v.put("jsonrpc", J.str(a, "2.0"));
    v.put("id", id.toJson(a));
    v.put("result", J.from(a, value));
    return v.dump();
}

/// Writes a failed response.
pub fn failure(a: std.mem.Allocator, id: ?Id, code: i64, message: []const u8) ![]u8 {
    var v = J.object(a);
    v.put("jsonrpc", J.str(a, "2.0"));
    v.put("id", if (id) |i| i.toJson(a) else J.nil(a));
    const err: Error = .{ .code = code, .message = message };
    v.put("error", err.toJson(a));
    return v.dump();
}

test "a request is written and read back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var params = J.object(a);
    params.put("name", J.str(a, "x"));
    const written = try request(a, .{ .number = 7 }, "tools/list", params.v);

    const message = Message.parse(a, written);
    try std.testing.expect(message == .request);
    try std.testing.expectEqualStrings("tools/list", message.request.method);
    try std.testing.expect(message.request.id.eql(.{ .number = 7 }));
}

test "a notification has no id, a response has a result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const note = try notification(a, "notifications/initialized", .null);
    try std.testing.expect(Message.parse(a, note) == .notification);

    var res = J.object(a);
    res.put("ok", J.boolean(a, true));
    const answered = try result(a, .{ .text = "abc" }, res.v);
    const message = Message.parse(a, answered);
    try std.testing.expect(message == .response);
    try std.testing.expect(message.response.err == null);
    try std.testing.expectEqualStrings("true", try json.text(a, json.get(message.response.result, "ok").?));
}

test "an error response carries its code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const failed = try failure(a, .{ .number = 1 }, method_not_found, "no such method");
    const message = Message.parse(a, failed);
    try std.testing.expect(message == .response);
    try std.testing.expectEqual(method_not_found, message.response.err.?.code);
    try std.testing.expectEqualStrings("no such method", message.response.err.?.message);
}

test "garbage is not a message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expect(Message.parse(a, "not json") == .malformed);
    try std.testing.expect(Message.parse(a, "[1,2,3]") == .malformed);
    try std.testing.expect(Message.parse(a, "{\"jsonrpc\":\"2.0\"}") == .malformed);
}
