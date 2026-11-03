//! Serving: the gateway's listener, starting and stopping it, and the
//! background threads that connect servers. Split from gateway.zig to keep
//! each file under the line limit.
const std = @import("std");
const gateway = @import("gateway.zig");
const views = @import("gateway_views.zig");
const server = @import("server.zig");
const http_dispatch = @import("gateway_http.zig");
const upstream = @import("upstream.zig");

const Gateway = gateway.Gateway;

/// Starts serving on `port` and connects the configured servers.
/// Connecting is reported per server, on its row and in the activity
/// list: a server that wants a sign-in, or is simply down, is not a
/// failure to serve.
pub fn start(g: *Gateway, port: u16) !void {
    try serve(g, port);
    g.sync() catch {};
}

/// Starts serving on `port`, connecting the servers on their own thread:
/// a server that never answers must not hold the caller (the window) up.
pub fn startAsync(g: *Gateway, port: u16) !void {
    try serve(g, port);
    syncAsync(g);
}

/// Runs `sync` on its own thread, so a server that is slow to answer
/// does not hold the caller up; each server's status changes as it
/// connects. Syncs are serialized, so one already running is joined.
pub fn syncAsync(g: *Gateway) void {
    const thread = std.Thread.spawn(.{}, syncWorker, .{g}) catch {
        g.sync() catch {};
        return;
    };
    thread.detach();
}

fn syncWorker(g: *Gateway) void {
    g.sync() catch {};
}

/// Reconnects a server on its own thread; the answer may be a sign-in
/// prompt or a server that never answers, and neither may freeze the
/// caller.
pub fn reconnectAsync(g: *Gateway, id: []const u8) void {
    const thread = std.Thread.spawn(.{}, reconnectWorker, .{ g, id }) catch {
        g.reconnect(id) catch {};
        return;
    };
    thread.detach();
}

fn reconnectWorker(g: *Gateway, id: []const u8) void {
    g.reconnect(id) catch {};
}

/// Starts the listener on `port`; connecting the servers is the caller's
/// choice of `sync` or `syncAsync`.
fn serve(g: *Gateway, port: u16) !void {
    g.mu.lockUncancelable(g.io);
    g.closing = false; // serving again after a stop
    const already = g.listener != null;
    g.mu.unlock(g.io);
    if (already) return error.AlreadyServing;

    const listener = try server.Server.init(g.a, g.io, port, .{
        .ctx = g,
        .handle = http_dispatch.handle,
    });
    errdefer listener.destroy();

    g.mu.lockUncancelable(g.io);
    g.listener = listener;
    g.port = port;
    g.mu.unlock(g.io);

    listener.start() catch |err| {
        g.mu.lockUncancelable(g.io);
        g.listener = null;
        g.port = 0;
        g.mu.unlock(g.io);
        listener.destroy();
        return err;
    };

    const base = try views.baseURL(g, g.a);
    defer g.a.free(base);
    const note_text = try std.fmt.allocPrint(g.a, "serving on {s}", .{base});
    defer g.a.free(note_text);
    g.note("", note_text, false);
    g.changed();
}

/// Stops serving and disconnects every server.
pub fn stop(g: *Gateway) void {
    g.setClosing();
    wakeWaiters(g);
    g.sync_mu.lockUncancelable(g.io);
    defer g.sync_mu.unlock(g.io);

    g.mu.lockUncancelable(g.io);
    const listener = g.listener;
    g.listener = null;
    g.port = 0;
    g.mu.unlock(g.io);

    // The listener goes first: a handler may still be calling a tool, and
    // disconnecting its server out from under it would free it mid-call.
    if (listener) |l| {
        // An event stream waits on its client, so it is ended before the
        // listener waits for the connections that were serving it.
        @import("mcp_endpoint.zig").sessions.closeAll();
        l.stop();
        l.destroy();
        @import("mcp_endpoint.zig").sessions.deinit();
    }

    disconnectAll(g);
    g.pending.clear(g.a);
    g.note("", "gateway stopped", false);
    g.changed();
}

/// Wakes every call still waiting on an upstream's answer, so workers and
/// client handlers end now instead of at the session's timeout.
pub fn wakeWaiters(g: *Gateway) void {
    g.mu.lockUncancelable(g.io);
    defer g.mu.unlock(g.io);
    var it = g.upstreams.iterator();
    while (it.next()) |kv| kv.value_ptr.*.sess.markClosed("gateway closing");
}

/// Disconnects every upstream and drops its tools and status. A connection
/// that a call is still using stays alive until that call releases it.
pub fn disconnectAll(g: *Gateway) void {
    g.mu.lockUncancelable(g.io);
    const count = g.upstreams.count();
    const ups = g.a.alloc(*upstream.Upstream, count) catch {
        g.mu.unlock(g.io);
        return;
    };
    const last = g.a.alloc(bool, count) catch {
        g.a.free(ups);
        g.mu.unlock(g.io);
        return;
    };
    var i: usize = 0;
    var it = g.upstreams.iterator();
    while (it.next()) |kv| : (i += 1) {
        const up = kv.value_ptr.*;
        ups[i] = up;
        up.retired = true;
        up.refs -= 1;
        last[i] = up.refs == 0;
        g.tools.removeServer(kv.key_ptr.*);
        g.forgetStatus(kv.key_ptr.*);
    }
    var keys = g.upstreams.keyIterator();
    while (keys.next()) |k| g.a.free(k.*);
    g.upstreams.clearRetainingCapacity();
    g.mu.unlock(g.io);
    if (i > 0) @import("mcp_endpoint.zig").notifyToolsChanged(g);

    for (ups[0..i], last[0..i]) |up, is_last| {
        if (is_last) {
            up.close();
            up.destroy();
        } else {
            up.sess.markClosed("gateway closing");
        }
    }
    g.a.free(ups);
    g.a.free(last);
}

/// Whether the gateway is listening.
pub fn serving(g: *Gateway) bool {
    g.mu.lockUncancelable(g.io);
    defer g.mu.unlock(g.io);
    return g.listener != null;
}

/// The port the gateway serves on, or 0 when it is not serving.
pub fn servingPort(g: *Gateway) u16 {
    g.mu.lockUncancelable(g.io);
    defer g.mu.unlock(g.io);
    return if (g.listener == null) 0 else g.port;
}
