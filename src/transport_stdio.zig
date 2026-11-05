//! A server the gateway starts itself: a child process speaking MCP over its
//! standard streams, one JSON-RPC message per line.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const json = @import("json_util.zig");
const session = @import("session.zig");

pub const Error = error{
    SpawnFailed,
    WriteFailed,
    ReadFailed,
    OutOfMemory,
};

/// The longest line a child may send. A longer one is dropped rather than
/// buffered, so a malformed server cannot exhaust the gateway's memory.
const max_message_bytes: usize = 8 << 20;

/// stderr is only kept to quote in a failure message.
const max_log_bytes: usize = 64 << 10;

/// How much of one stderr line is kept.
const kept_log_bytes: usize = 512;

/// A running child process and the pipes to it.
pub const Stdio = struct {
    a: std.mem.Allocator,
    io: Io,
    child: std.process.Child,
    in: Io.File.Writer,
    /// What the child wrote to stderr, so a failure can quote it.
    logs: Logs,
    /// Serializes the messages written to the child's stdin, which arrive on
    /// whichever thread a request happened to run on.
    write_mu: Io.Mutex = .init,
    dead: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
        var own_path: ?[]u8 = null;
        defer if (own_path) |p| a.free(p);
        if (env_map) |*m| {
            for (env) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                try m.put(pair[0..eq], pair[eq + 1 ..]);
            }
            own_path = try childPath(a, m.get("PATH") orelse "", m.get("HOME"));
            try m.put("PATH", own_path.?);
        }

        // A command with no slash is a name for PATH to resolve. Resolving it
        // here uses the PATH the child is given, not this process's, so a
        // server configured on a GUI launch can still start.
        var resolved: ?[]u8 = null;
        defer if (resolved) |r| a.free(r);
        if (comptime builtin.os.tag != .windows) {
            if (own_path) |p| {
                if (std.mem.indexOfScalar(u8, command, '/') == null) {
                    resolved = try resolveCommand(a, io, command, p);
                    if (resolved) |r| argv[0] = r;
                }
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
        var line_buf: Io.Writer.Allocating = .init(s.a);
        defer line_buf.deinit();
        while (true) {
            const more = readLine(&reader.interface, &line_buf, max_message_bytes) catch break;
            if (!more) break;
            const trimmed = std.mem.trim(u8, line_buf.written(), " \t\r");
            if (trimmed.len == 0) continue;
            if (s.session) |sess| sess.handleBytes(trimmed);
        }
        if (s.session) |sess| sess.markClosed("the server closed its output");
    }

    fn logLoop(s: *Stdio, file: Io.File) void {
        const buf = s.a.alloc(u8, 4096) catch return;
        defer s.a.free(buf);
        var reader = file.readerStreaming(s.io, buf);
        var line_buf: Io.Writer.Allocating = .init(s.a);
        defer line_buf.deinit();
        while (true) {
            const more = readLine(&reader.interface, &line_buf, max_log_bytes) catch break;
            if (!more) break;
            s.logs.add(line_buf.written());
        }
    }

    /// The wire a session writes through.
    pub fn wire(s: *Stdio) session.Wire {
        return .{ .ctx = s, .send = sendBytes, .close = closeWire };
    }

    fn sendBytes(ctx: *anyopaque, a: std.mem.Allocator, bytes: []const u8) session.Error!void {
        _ = a;
        const s: *Stdio = @ptrCast(@alignCast(ctx));
        s.write_mu.lockUncancelable(s.io);
        defer s.write_mu.unlock(s.io);
        if (s.dead.load(.acquire)) return error.Closed;
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

    /// Ends the conversation: closes the pipes and waits for the child. The
    /// mutex is held across the check and the close, so no writer can be part
    /// way through a message when its pipe goes away.
    pub fn close(s: *Stdio) void {
        s.write_mu.lockUncancelable(s.io);
        if (s.dead.load(.acquire)) {
            s.write_mu.unlock(s.io);
            return;
        }
        s.dead.store(true, .release);
        if (s.child.stdin) |f| {
            f.close(s.io);
            s.child.stdin = null;
        }
        s.write_mu.unlock(s.io);
        if (s.child.id != null) s.child.kill(s.io);
        if (s.read_thread) |t| t.join();
        if (s.log_thread) |t| t.join();
        if (s.child.stdout) |f| f.close(s.io);
        if (s.child.stderr) |f| f.close(s.io);
        s.logs.deinit();
    }

    /// Whether the child is still running.
    pub fn alive(s: *Stdio) bool {
        return !s.dead.load(.acquire) and s.child.id != null;
    }

    /// What the child said on stderr, for a failure message.
    pub fn logsText(s: *Stdio, a: std.mem.Allocator) ![]u8 {
        return s.logs.text(a);
    }
};

/// The last lines a child wrote to stderr, kept in a capped ring buffer.
pub const Logs = struct {
    a: std.mem.Allocator,
    mu: Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,
    limit: usize = 50,
    io: Io = undefined,

    pub fn add(l: *Logs, line: []const u8) void {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) return;
        const kept = l.keep(trimmed) orelse return;
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

    /// A line as it is kept: shortened to kept_log_bytes, on a character
    /// boundary, with an ellipsis when something was cut.
    fn keep(l: *Logs, line: []const u8) ?[]u8 {
        if (line.len <= kept_log_bytes) return l.a.dupe(u8, line) catch null;
        var end = kept_log_bytes;
        while (end > 0 and (line[end] & 0xc0) == 0x80) end -= 1;
        const out = l.a.alloc(u8, end + 3) catch return null;
        @memcpy(out[0..end], line[0..end]);
        @memcpy(out[end..], "...");
        return out;
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

/// Reads one line into `out`, however long it is, and consumes its newline.
/// Returns false at the end of the stream. A line longer than `cap` is
/// swallowed whole and left out of `out`, so the next call starts at the
/// following line.
fn readLine(reader: *Io.Reader, out: *Io.Writer.Allocating, cap: usize) !bool {
    out.writer.end = 0;
    _ = reader.streamDelimiterLimit(&out.writer, '\n', .limited(cap)) catch |err| switch (err) {
        error.StreamTooLong => {
            out.writer.end = 0;
            _ = reader.discardDelimiterInclusive('\n') catch {};
            return true;
        },
        else => return err,
    };
    // A found delimiter is the next buffered byte; a stream that ended before
    // one leaves its last line in `out`.
    const next = reader.peekByte() catch |err| switch (err) {
        error.EndOfStream => return out.written().len > 0,
        else => return err,
    };
    if (next == '\n') reader.toss(1);
    return true;
}

fn copyEnv(a: std.mem.Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(a);
    errdefer out.deinit();
    for (parent.keys(), parent.values()) |key, value| {
        try out.put(key, value);
    }
    return out;
}

fn onPath(path: []const u8, dir: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, dir)) return true;
    }
    return false;
}

/// Directories a login shell has on PATH but a Finder launch does not: an app
/// opened from the Dock gets "/usr/bin:/bin:/usr/sbin:/sbin", so a server
/// configured as `npx -y ...` could not even be found. They are appended, so
/// whatever the app was started with still takes precedence.
const fallback_path_dirs = [_][]const u8{
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/opt/homebrew/sbin",
    "/usr/local/sbin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
};

fn childPath(a: std.mem.Allocator, incoming: []const u8, home: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, incoming);
    for (fallback_path_dirs) |dir| {
        if (onPath(out.items, dir)) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != ':') try out.append(a, ':');
        try out.appendSlice(a, dir);
    }
    if (home) |h| {
        if (h.len > 0) {
            const local = try std.fs.path.join(a, &.{ h, ".local", "bin" });
            defer a.free(local);
            if (!onPath(out.items, local)) {
                if (out.items.len > 0 and out.items[out.items.len - 1] != ':') try out.append(a, ':');
                try out.appendSlice(a, local);
            }
        }
    }
    return out.toOwnedSlice(a);
}

/// Finds `command` on `path` when it is a bare name. The spawn options'
/// environ_map does not take part in argv[0] resolution, so with a GUI
/// launch's PATH a name like `npx` would never be found without this.
fn resolveCommand(a: std.mem.Allocator, io: Io, command: []const u8, path: []const u8) !?[]u8 {
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(a, &.{ dir, command });
        if (std.Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| {
            return candidate;
        } else |_| {}
        a.free(candidate);
    }
    return null;
}

test "a line longer than the cap is dropped, and the next one is still read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var reader = Io.Reader.fixed("a-line-that-is-much-too-long\nshort\nend-with-no-newline");
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();

    try std.testing.expect(try readLine(&reader, &out, 20));
    // The over-long line is consumed, and contributes nothing.
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    try std.testing.expect(try readLine(&reader, &out, 20));
    try std.testing.expectEqualStrings("short", out.written());

    try std.testing.expect(try readLine(&reader, &out, 20));
    try std.testing.expectEqualStrings("end-with-no-newline", out.written());

    try std.testing.expect(!(try readLine(&reader, &out, 20)));
}

test "a long stderr line is shortened before it is shown" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var logs: Logs = .{ .a = a, .io = std.testing.io };
    defer logs.deinit();

    const huge = try a.alloc(u8, 5000);
    @memset(huge, 'x');
    logs.add(huge);

    const text = try logs.text(a);
    try std.testing.expectEqual(@as(usize, 512 + 3), text.len);
    try std.testing.expect(std.mem.endsWith(u8, text, "..."));
    try std.testing.expect(std.mem.indexOf(u8, text, "\n") == null);
}

test "two threads writing to the child do not interleave their lines" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const s = try Stdio.start(a, std.testing.io, "/bin/sh", &.{ "-c", "cat" }, &.{}, null);
    defer s.deinit();

    const Writer = struct {
        fn run(st: *Stdio, fill: u8, count: usize) void {
            var line: [128]u8 = undefined;
            @memset(&line, fill);
            for (0..count) |_| Stdio.sendBytes(st, undefined, &line) catch return;
        }
    };
    const t1 = try std.Thread.spawn(.{}, Writer.run, .{ s, 'a', 100 });
    const t2 = try std.Thread.spawn(.{}, Writer.run, .{ s, 'b', 100 });
    t1.join();
    t2.join();
    // The pipe can hold what was written, so the child is read only now.
    s.child.stdin.?.close(s.io);
    s.child.stdin = null;

    var buf: [8192]u8 = undefined;
    var reader = s.child.stdout.?.readerStreaming(s.io, &buf);
    var seen_a: usize = 0;
    var seen_b: usize = 0;
    for (0..200) |_| {
        const line = (try reader.interface.takeDelimiter('\n')) orelse return error.NoLine;
        try std.testing.expectEqual(@as(usize, 128), line.len);
        for (line) |c| try std.testing.expectEqual(line[0], c);
        if (line[0] == 'a') {
            seen_a += 1;
        } else if (line[0] == 'b') {
            seen_b += 1;
        } else return error.UnexpectedByte;
    }
    try std.testing.expectEqual(@as(usize, 100), seen_a);
    try std.testing.expectEqual(@as(usize, 100), seen_b);
}

test "a GUI launch's bare PATH gains the usual install directories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const path = try childPath(a, "/usr/bin:/bin", "/Users/someone");
    try std.testing.expect(std.mem.startsWith(u8, path, "/usr/bin:/bin:"));
    try std.testing.expect(onPath(path, "/opt/homebrew/bin"));
    try std.testing.expect(onPath(path, "/usr/local/bin"));
    try std.testing.expect(onPath(path, "/Users/someone/.local/bin"));
    // What was already there is not listed twice.
    try std.testing.expectEqual(@as(usize, 1), countPathEntries(path, "/usr/bin"));
    try std.testing.expectEqual(@as(usize, 1), countPathEntries(path, "/bin"));
}

test "a bare command resolves through the configured PATH, not the app's" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nanomcp-probe",
        .data = "#!/bin/sh\nprintf 'resolved\\n'\n",
        .flags = .{ .permissions = .executable_file },
    });
    const dir_path = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var parent: std.process.Environ.Map = .init(a);
    defer parent.deinit();
    try parent.put("PATH", dir_path);

    const s = try Stdio.start(a, std.testing.io, "nanomcp-probe", &.{}, &.{}, &parent);
    defer s.deinit();

    var buf: [256]u8 = undefined;
    var reader = s.child.stdout.?.readerStreaming(std.testing.io, &buf);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.NoOutput;
    try std.testing.expectEqualStrings("resolved", line);
}

fn countPathEntries(path: []const u8, entry: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |e| {
        if (std.mem.eql(u8, e, entry)) n += 1;
    }
    return n;
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
