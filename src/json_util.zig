//! JSON for the protocol: documents built by hand, parsed without a schema.
const std = @import("std");

pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;
pub const Array = std.json.Array;

/// Parses a document, borrowing from `text` for its strings.
pub fn parse(a: std.mem.Allocator, source: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, source, .{});
}

/// A document being built: every node carries the allocator that makes it.
pub const J = struct {
    a: std.mem.Allocator,
    v: Value,

    pub fn object(a: std.mem.Allocator) J {
        return .{ .a = a, .v = .{ .object = .empty } };
    }

    pub fn array(a: std.mem.Allocator) J {
        return .{ .a = a, .v = .{ .array = .init(a) } };
    }

    pub fn str(a: std.mem.Allocator, s: []const u8) J {
        return .{ .a = a, .v = .{ .string = s } };
    }

    pub fn int(a: std.mem.Allocator, n: i64) J {
        return .{ .a = a, .v = .{ .integer = n } };
    }

    pub fn boolean(a: std.mem.Allocator, b: bool) J {
        return .{ .a = a, .v = .{ .bool = b } };
    }

    pub fn nil(a: std.mem.Allocator) J {
        return .{ .a = a, .v = .null };
    }

    /// An array of strings.
    pub fn strings(a: std.mem.Allocator, items: []const []const u8) J {
        var list: J = .array(a);
        for (items) |item| list.add(str(a, item));
        return list;
    }

    /// Wraps a value that was already built.
    pub fn from(a: std.mem.Allocator, v: Value) J {
        return .{ .a = a, .v = v };
    }

    /// Adds a field to an object.
    pub fn put(self: *J, key: []const u8, child: J) void {
        self.v.object.put(self.a, key, child.v) catch {};
    }

    /// Adds a field only when the text is not empty.
    pub fn putText(self: *J, key: []const u8, s: []const u8) void {
        if (s.len == 0) return;
        self.put(key, str(self.a, s));
    }

    /// Appends to an array.
    pub fn add(self: *J, child: J) void {
        self.v.array.append(child.v) catch {};
    }

    /// A compact document, as the wire carries it.
    pub fn dump(self: J) ![]u8 {
        return dumpWith(self.a, self.v, .{});
    }

    /// An indented document, as a human reads it.
    pub fn dumpIndent(self: J) ![]u8 {
        return dumpWith(self.a, self.v, .{ .whitespace = .indent_2 });
    }
};

fn dumpWith(a: std.mem.Allocator, v: Value, options: std.json.Stringify.Options) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(a);
    errdefer buf.deinit();
    try std.json.Stringify.value(v, options, &buf.writer);
    return buf.toOwnedSlice();
}

/// A field of an object, or null when it is missing or of another type.
pub fn get(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// A string field, or null.
pub fn getString(v: Value, key: []const u8) ?[]const u8 {
    return switch (get(v, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn getBool(v: Value, key: []const u8) ?bool {
    return switch (get(v, key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getInt(v: Value, key: []const u8) ?i64 {
    return switch (get(v, key) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

pub fn getObject(v: Value, key: []const u8) ?Object {
    return switch (get(v, key) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

pub fn getArray(v: Value, key: []const u8) ?Array {
    return switch (get(v, key) orelse return null) {
        .array => |a| a,
        else => null,
    };
}

/// The text of a value: a string without its quotes, null as nothing, and
/// anything else as the JSON it is written as.
pub fn text(a: std.mem.Allocator, v: Value) ![]u8 {
    return switch (v) {
        .string => |s| a.dupe(u8, s),
        .null => a.dupe(u8, ""),
        else => dumpWith(a, v, .{}),
    };
}

/// Whether a value is an object.
pub fn isObject(v: Value) bool {
    return v == .object;
}

/// Copies a value into `a`, so it no longer depends on the buffer it was
/// parsed from.
pub fn clone(a: std.mem.Allocator, v: Value) !Value {
    switch (v) {
        .null, .bool, .integer, .float, .number_string => return v,
        .string => |s| return .{ .string = try a.dupe(u8, s) },
        .array => |arr| {
            var out: Array = .init(a);
            errdefer {
                for (out.items) |item| free(a, item);
                out.deinit();
            }
            for (arr.items) |item| try out.append(try clone(a, item));
            return .{ .array = out };
        },
        .object => |o| {
            var out: Object = .empty;
            errdefer {
                var it = out.iterator();
                while (it.next()) |kv| {
                    a.free(kv.key_ptr.*);
                    free(a, kv.value_ptr.*);
                }
                out.deinit(a);
            }
            var it = o.iterator();
            while (it.next()) |kv| {
                try out.put(a, try a.dupe(u8, kv.key_ptr.*), try clone(a, kv.value_ptr.*));
            }
            return .{ .object = out };
        },
    }
}

/// Frees a value made by `clone`.
pub fn free(a: std.mem.Allocator, v: Value) void {
    switch (v) {
        .null, .bool, .integer, .float, .number_string => {},
        .string => |s| a.free(s),
        .array => |arr| {
            var out = arr;
            for (out.items) |item| free(a, item);
            out.deinit();
        },
        .object => |o| {
            var out = o;
            var it = out.iterator();
            while (it.next()) |kv| {
                a.free(kv.key_ptr.*);
                free(a, kv.value_ptr.*);
            }
            out.deinit(a);
        },
    }
}

test "a document is written compactly and read back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var params = J.object(a);
    params.put("name", J.str(a, "tools/call"));
    var list = J.array(a);
    list.add(J.str(a, "a"));
    list.add(J.boolean(a, true));
    params.put("args", list);

    var v = J.object(a);
    v.put("jsonrpc", J.str(a, "2.0"));
    v.put("id", J.int(a, 1));
    v.put("params", params);

    const written = try v.dump();
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"params\":{\"name\":\"tools/call\",\"args\":[\"a\",true]}}",
        written,
    );

    const back = try parse(a, written);
    try std.testing.expectEqualStrings("2.0", getString(back, "jsonrpc").?);
    try std.testing.expectEqual(@as(i64, 1), getInt(back, "id").?);
    try std.testing.expectEqualStrings("tools/call", getString(get(back, "params").?, "name").?);
    try std.testing.expectEqual(@as(usize, 2), getArray(get(back, "params").?, "args").?.items.len);
}

test "the text of a value keeps strings bare and null empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("hello", try text(a, J.str(a, "hello").v));
    try std.testing.expectEqualStrings("", try text(a, J.nil(a).v));
    try std.testing.expectEqualStrings("42", try text(a, J.int(a, 42).v));
    try std.testing.expectEqualStrings("false", try text(a, J.boolean(a, false).v));
}

test "an indented document is readable, and an empty field is left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var v = J.object(a);
    v.put("name", J.str(a, "x"));
    v.putText("empty", "");
    try std.testing.expectEqualStrings("{\n  \"name\": \"x\"\n}", try v.dumpIndent());
}
