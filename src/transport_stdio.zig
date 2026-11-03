//! A server the gateway starts itself: a child process speaking MCP over its
//! standard streams, one JSON-RPC message per line.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const rpc = @import("rpc.zig");
const json = @import("json_util.zig");
const session = @import("session.zig");

pub const Error = error{
    SpawnFailed,
    WriteFailed,
    ReadFailed,
    OutOfMemory,
};

/// A running child process and the pipes to it.
pub const Stdio = struct {
    a: std.mem.Allocator,
    io: Io,
    child: std.process.Child,
    in: Io.File.Writer,
    /// What the child wrote to stderr, so a failure can quote it.
    logs: Logs,
    dead: bool = false,
    read_thread: ?std.Thread = null,
    log_thread: ?std.Thread = null,
    session: ?*session.Session = null,

    /// Starts a command, with the environment it was configured with.
    pub fn start(
        a: std.mem.Allocator,
        io: Io,
        command: []const u8,
        args: []const []const u8,
        env: []const []const u8,
        parent_env: ?*const std.process.Environ.Map,
    ) !*Stdio {
        var argv = try a.alloc([]const u8, args.len + 1);
        defer a.free(argv);
        argv[0] = command;
        for (args, 0..) |arg, i| argv[i + 1] = arg;

        var env_map: ?std.process.Environ.Map = null;
        defer if (env_map) |*m| m.deinit();
        // The child gets this app's environment, with the configured
        // variables applied on top: PATH and HOME matter even when nothing is
        // configured, and a variable such as an API key is the only thing a
        // stdio server may need to start at all.
        if (parent_env) |parent| {
            env_map = try copyEnv(a, parent);
        } else if (env.len > 0) {
            env_map = std.process.Environ.Map.init(a);
        }
        if (env_map) |*m| {
            for (env) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                try m.put(pair[0..eq], pair[eq + 1 ..]);
            }
        }

        var child = std.process.spawn(io, .{
            .argv = argv,
            .environ_map = if (env_map) |*m| m else null,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .expand_arg0 = .expand,
        }) catch return error.SpawnFailed;

        const self = try a.create(Stdio);
        self.* = .{
            .a = a,
            .io = io,
            .child = child,
            .in = child.stdin.?.writerStreaming(io, try a.alloc(u8, 4096)),
            .logs = .{ .a = a, .io = io },
        };
        return self;
    }

    /// Reads stdout and stderr until the child goes away.
    pub fn attach(s: *Stdio, sess: *session.Session) !void {
        s.session = sess;
        const out_file = s.child.stdout.?;
        s.read_thread = try std.Thread.spawn(.{}, readLoop, .{ s, out_file });
        const err_file = s.child.stderr.?;
        s.log_thread = try std.Thread.spawn(.{}, logLoop, .{ s, err_file });
    }

    fn readLoop(s: *Stdio, file: Io.File) void {
        const buf = s.a.alloc(u8, 64 * 1024) catch return;
        defer s.a.free(buf);
        var reader = file.readerStreaming(s.io, buf);
        var line_buf = std.ArrayList(u8).empty;
        defer line_buf.deinit(s.a);
        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch break orelse break;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            line_buf.clearRetainingCapacity();
            line_buf.appendSlice(s.a, trimmed) catch break;
            const text = line_buf.items;
            const arena = session.newArena(s.a) catch break;
            const message = rpc.Message.parse(arena.allocator(), text);
            if (s.session) |sess| {
                sess.handleMessage(.{ .message = message, .arena = arena });
            } else session.freeArena(s.a, arena);
        }
        if (s.session) |sess| sess.markClosed("the server closed its output");
    }

    fn logLoop(s: *Stdio, file: Io.File) void {
        const buf = s.a.alloc(u8, 4096) catch return;
        defer s.a.free(buf);
        var reader = file.readerStreaming(s.io, buf);
        while (true) {
            const line = reader.interface.takeDelimiter('\n') catch break orelse break;
            s.logs.add(line);
        }
    }

    /// The wire a session writes through.
    pub fn wire(s: *Stdio) session.Wire {
        return .{ .ctx = s, .send = sendBytes, .close = closeWire };
    }

    fn sendBytes(ctx: *anyopaque, a: std.mem.Allocator, bytes: []const u8) session.Error!void {
        _ = a;
        const s: *Stdio = @ptrCast(@alignCast(ctx));
        if (s.dead) return error.Closed;
        s.in.interface.writeAll(bytes) catch return error.WriteFailed;
        s.in.interface.writeAll("\n") catch return error.WriteFailed;
        s.in.interface.flush() catch return error.WriteFailed;
    }

    fn closeWire(ctx: *anyopaque) void {
        const s: *Stdio = @ptrCast(@alignCast(ctx));
        s.close();
    }

    pub fn deinit(s: *Stdio) void {
        s.close();
        const a = s.a;
        a.destroy(s);
    }

    /// Ends the conversation: closes the pipes and waits for the child.
    pub fn close(s: *Stdio) void {
        if (s.dead) return;
        s.dead = true;
        if (s.child.stdin) |f| {
            f.close(s.io);
            s.child.stdin = null;
        }
        if (s.child.id != null) s.child.kill(s.io);
        if (s.read_thread) |t| t.join();
        if (s.log_thread) |t| t.join();
        if (s.child.stdout) |f| f.close(s.io);
        if (s.child.stderr) |f| f.close(s.io);
        s.logs.deinit();
    }

    /// Whether the child is still running.
    pub fn alive(s: *Stdio) bool {
        return !s.dead and s.child.id != null;
    }

    /// What the child said on stderr, for a failure message.
    pub fn logsText(s: *Stdio, a: std.mem.Allocator) ![]u8 {
        return s.logs.text(a);
    }
};

/// The last lines a child wrote to stderr, capped like Go's ring buffer.
pub const Logs = struct {
    a: std.mem.Allocator,
    mu: Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,
    limit: usize = 50,
    io: Io = undefined,

    pub fn add(l: *Logs, line: []const u8) void {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) return;
        const kept = l.a.dupe(u8, trimmed) catch return;
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        l.lines.append(l.a, kept) catch {
            l.a.free(kept);
            return;
        };
        while (l.lines.items.len > l.limit) {
            const old = l.lines.orderedRemove(0);
            l.a.free(old);
        }
    }

    pub fn text(l: *Logs, a: std.mem.Allocator) ![]u8 {
        l.mu.lockUncancelable(l.io);
        defer l.mu.unlock(l.io);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        for (l.lines.items, 0..) |line, i| {
            if (i > 0) try out.append(a, '\n');
            try out.appendSlice(a, line);
        }
        return out.toOwnedSlice(a);
    }

    pub fn deinit(l: *Logs) void {
        for (l.lines.items) |line| l.a.free(line);
        l.lines.deinit(l.a);
    }
};

fn copyEnv(a: std.mem.Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(a);
    errdefer out.deinit();
    for (parent.keys(), parent.values()) |key, value| {
        try out.put(key, value);
    }
    return out;
}

test "a stdio server gets the app environment with its own values on top" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var parent: std.process.Environ.Map = .init(a);
    defer parent.deinit();
    try parent.put("PROBE_PARENT", "from-parent");

    const configured = [_][]const u8{"PROBE_CONFIG=from-config"};
    const s = try Stdio.start(a, std.testing.io, "/bin/sh", &.{
        "-c",
        "printf '%s %s\\n' \"$PROBE_PARENT\" \"$PROBE_CONFIG\"",
    }, &configured, &parent);
    defer s.deinit();

    var buf: [256]u8 = undefined;
    var reader = s.child.stdout.?.readerStreaming(std.testing.io, &buf);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.NoOutput;
    try std.testing.expectEqualStrings("from-parent from-config", line);
}
