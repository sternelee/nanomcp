//! Market page: search the official MCP registry for public servers, and add
//! one in a step by opening the add form filled in from what it found.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const kit = @import("kit.zig");
const config = @import("config.zig");
const registry = @import("registry.zig");
const App = state_mod.App;

/// How many servers one search asks the registry for.
const limit: u32 = 30;

pub fn page(c: *ui.Context, s: *App, k: theme.Colors) void {
    // The first visit shows the registry's latest before any searching. A
    // test never reaches the network; a headless run neither.
    if (!s.market.searched and !s.market.loading and s.market.err.len == 0 and
        std.mem.trim(u8, s.market.query.text(), " \t\r\n").len == 0 and
        !builtin.is_test and std.c.getenv("NANOMCP_TEST_DIR") == null)
    {
        search(s, false);
    }

    const header = kit.header(c, k, "Market", "Public servers from the official MCP registry, added in one step.");
    if (s.market.loading) ui.text(c, "Searching…", .{ .size = 12, .color = k.secondary });
    header.end();

    const bar = ui.div(c).row().wFull().gap(10).itemsCenter().px(20).pb(12);
    const found = ui.textField(c, &s.market.query, .{
        .placeholder = "Search public MCP servers…",
        .width = .{ .px = 320 },
        .size = 13,
    });
    if (found.changed) searchSoon(s);
    if (ui.button(c, "Search", .{ .variant = .primary, .size = 13 }).clicked) search(s, false);
    ui.spacer(c);
    if (s.market.searched and !s.market.loading) {
        ui.text(c, summary(c, s), .{ .size = 11, .color = k.tertiary });
    }
    bar.end();

    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(10);
    defer body.end();

    if (s.market.err.len > 0) {
        ui.text(c, s.market.err, .{ .size = 12, .color = k.red });
    }

    if (!s.market.searched) {
        kit.pageEmpty(c, k, "globe", "Find a server", "Search the official registry — filesystems, browsers, databases and more.");
        return;
    }
    if (!s.market.loading and s.market.results.len == 0) {
        nothingFound(c, s, k);
        return;
    }

    const surface = ui.div(c).column().wFull().gap(0).p(4).rounded(10).border(k.border).bg(k.card);
    for (s.market.results) |item| row(c, s, k, item);
    surface.end();

    if (s.market.cursor != null) {
        const more_row = ui.div(c).row().wFull().justifyCenter().pt(4);
        if (ui.button(c, "Show more", .{ .size = 12, .disabled = s.market.loading }).clicked) search(s, true);
        more_row.end();
    }
}

/// One registry server: its figure, name and description, how it runs, and
/// the way to add it.
fn row(c: *ui.Context, s: *App, k: theme.Colors, item: registry.Server) void {
    const d = ui.div(c).row().wFull().h(56).px(12).gap(12).itemsCenter();
    defer d.end();

    kit.avatar(c, k, item.shortName(), 32);

    {
        const col = ui.div(c).column().grow().w(0).minW(0).gap(1).clip();
        defer col.end();
        ui.text(c, item.shortName(), .{ .size = 13, .weight = .semibold, .color = k.text });
        ui.text(c, item.description, .{ .size = 11, .color = k.secondary });
    }

    const how = item.install();
    ui.badge(c, marketKind(how), k.secondary);
    if (item.version.len > 0) {
        ui.text(c, c.print("v{s}", .{item.version}), .{ .size = 11, .color = k.secondary });
    }

    if (alreadyHave(s, &item)) {
        ui.badge(c, "Added", k.green);
    } else if (how) |install| {
        const hit = ui.button(c, "Add…", .{ .variant = .primary, .size = 12 });
        if (hit.clicked) openForm(s, &item, install);
    } else {
        ui.text(c, "Manual", .{ .size = 11, .color = k.secondary });
    }
}

/// How a registry server runs: over the network, as a local command, or not
/// at all.
fn marketKind(how: ?registry.Install) []const u8 {
    const install = how orelse return "manual";
    if (install.remote) return "remote";
    return install.command;
}

/// What a search found, for the row above the list.
fn summary(c: *ui.Context, s: *App) []const u8 {
    const n = s.market.results.len;
    if (s.market.cursor != null) return c.print("{d} shown, more on the registry", .{n});
    return c.print("{d} found", .{n});
}

/// Shows when a search found nothing, with the way back to the latest.
fn nothingFound(c: *ui.Context, s: *App, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().grow().itemsCenter().gap(10).py(32);
    defer d.end();
    ui.icon(c, "globe", .{ .size = 28, .color = k.secondary.alpha(0.5) });
    ui.text(c, "Nothing found", .{ .size = 15, .weight = .semibold, .color = k.secondary });
    ui.text(c, c.print("No servers on the registry match \"{s}\".", .{std.mem.trim(u8, s.market.query.text(), " \t\r\n")}), .{
        .size = 12,
        .color = k.tertiary,
    });
    if (ui.button(c, "Show the latest", .{ .variant = .secondary, .size = 12 }).clicked) {
        s.market.query.clear();
        search(s, false);
    }
}

/// Whether a registry server is already among the configured ones: a
/// remote's URL, or a package among a command's arguments.
fn alreadyHave(s: *App, item: *const registry.Server) bool {
    for (s.cfg.servers) |sc| {
        for (item.remotes) |remote| {
            const url = sc.url orelse "";
            if (url.len > 0 and std.mem.eql(u8, url, remote.url)) return true;
        }
        for (item.packages) |package| {
            if (package.identifier.len == 0) continue;
            for (sc.args orelse &.{}) |arg| {
                if (std.mem.eql(u8, arg, package.identifier)) return true;
            }
        }
    }
    return false;
}

/// Opens the add form filled in from a registry entry, so its name, command
/// and environment can be reviewed before it is saved.
fn openForm(s: *App, item: *const registry.Server, how: registry.Install) void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    s.servers.form.reset();
    s.servers.form.name.set(item.shortName());
    s.servers.form.enabled = true;
    if (how.remote) {
        s.servers.form.transport = if (how.sse) 1 else 2;
        s.servers.form.url.set(how.url);
    } else {
        s.servers.form.transport = 0;
        s.servers.form.command.set(how.command);
        s.servers.form.args.set(arguments(a, how));
        s.servers.form.env.set(registry.envLines(a, how.env) catch "");
    }
    s.servers.form_error = "";
    s.servers.focus_form = true;
    s.servers.editing = config.newId(s.cfgAlloc(), s.io) catch {
        s.notify("could not make a server id", true);
        return;
    };
    s.redisplay();
}

/// A local install's whole argument line, one per line, the way the form
/// reads it: the runtime's arguments (as "docker run"), then the package's.
fn arguments(a: std.mem.Allocator, how: registry.Install) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var first = true;
    for (how.prefix) |arg| {
        if (!first) out.append(a, '\n') catch return "";
        out.appendSlice(a, arg) catch return "";
        first = false;
    }
    for (how.arguments) |arg| {
        if (!first) out.append(a, '\n') catch return "";
        out.appendSlice(a, arg) catch return "";
        first = false;
    }
    return out.items;
}

/// Searches the registry; `more` asks for the page after the one shown.
fn search(s: *App, more: bool) void {
    // A manual search is the last word: a pending keystroke search is stale.
    s.market.seq +%= 1;
    const a = s.gpa;
    const query = a.dupe(u8, std.mem.trim(u8, s.market.query.text(), " \t\r\n")) catch return;
    const cursor = a.dupe(u8, if (more) (s.market.cursor orelse "") else "") catch {
        a.free(query);
        return;
    };
    s.beginMarket();
    const thread = std.Thread.spawn(.{}, searchThread, .{ s, query, cursor, more }) catch {
        a.free(query);
        a.free(cursor);
        s.failMarket(a.dupe(u8, "The registry could not be reached.") catch "", more);
        return;
    };
    thread.detach();
}

fn searchThread(s: *App, query: []const u8, cursor: []const u8, more: bool) void {
    const a = s.gpa;
    defer a.free(query);
    defer a.free(cursor);

    const arena = a.create(std.heap.ArenaAllocator) catch {
        announceFailure(s, failureText(a, "out of memory"), more);
        return;
    };
    arena.* = .init(a);
    var client: registry.Client = .{
        .a = arena.allocator(),
        .io = s.io,
        .base_url = s.market.base_url,
    };
    const found = client.search(query, cursor, limit) catch |e| {
        arena.deinit();
        a.destroy(arena);
        announceFailure(s, failureText(a, why(e)), more);
        return;
    };
    announcePage(s, arena, found.servers, found.next_cursor, more);
}

/// What went wrong, in the words the Go gateway uses.
fn why(e: anyerror) []const u8 {
    return switch (e) {
        error.RegistryStatus => "the registry answered with an error",
        error.BadAnswer => "the registry's answer could not be read",
        else => @errorName(e),
    };
}

/// The line the page shows when a search could not run; owned by `a`.
fn failureText(a: std.mem.Allocator, reason: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "The registry could not be reached: {s}", .{reason}) catch "";
}

/// Waits for typing to pause before searching, so a word costs one request.
fn searchSoon(s: *App) void {
    s.market.seq +%= 1;
    const box = s.gpa.create(Soon) catch return;
    box.* = .{ .s = s, .seq = s.market.seq };
    const thread = std.Thread.spawn(.{}, soonThread, .{box}) catch {
        s.gpa.destroy(box);
        return;
    };
    thread.detach();
}

const Soon = struct {
    s: *App,
    seq: u32,
};

fn soonThread(box: *Soon) void {
    std.Io.sleep(box.s.io, .fromMilliseconds(400), .awake) catch {};
    if (comptime builtin.os.tag == .macos) {
        nanoui.objc.dispatchMain(box, soonFire);
    } else fireSoon(box);
}

fn soonFire(ctx: ?*anyopaque) callconv(.c) void {
    const box: *Soon = @ptrCast(@alignCast(ctx.?));
    fireSoon(box);
}

fn fireSoon(box: *Soon) void {
    const s = box.s;
    const due = s.market.seq == box.seq;
    s.gpa.destroy(box);
    if (due) search(s, false);
}

fn announcePage(s: *App, arena: *std.heap.ArenaAllocator, servers: []registry.Server, cursor: []const u8, more: bool) void {
    if (comptime builtin.os.tag == .macos) {
        const box = s.gpa.create(PageBox) catch {
            arena.deinit();
            s.gpa.destroy(arena);
            return;
        };
        box.* = .{ .s = s, .arena = arena, .servers = servers, .cursor = cursor, .more = more };
        nanoui.objc.dispatchMain(box, deliverPage);
    } else s.addMarket(arena, servers, cursor, more);
}

fn announceFailure(s: *App, text: []const u8, more: bool) void {
    if (comptime builtin.os.tag == .macos) {
        const box = s.gpa.create(FailureBox) catch {
            if (text.len > 0) s.gpa.free(text);
            return;
        };
        box.* = .{ .s = s, .text = text, .more = more };
        nanoui.objc.dispatchMain(box, deliverFailure);
    } else s.failMarket(text, more);
}

const PageBox = struct {
    s: *App,
    arena: *std.heap.ArenaAllocator,
    servers: []registry.Server,
    cursor: []const u8,
    more: bool,
};

fn deliverPage(ctx: ?*anyopaque) callconv(.c) void {
    const box: *PageBox = @ptrCast(@alignCast(ctx.?));
    const s = box.s;
    const arena = box.arena;
    const servers = box.servers;
    const cursor = box.cursor;
    const more = box.more;
    s.gpa.destroy(box);
    s.addMarket(arena, servers, cursor, more);
}

const FailureBox = struct {
    s: *App,
    text: []const u8,
    more: bool,
};

fn deliverFailure(ctx: ?*anyopaque) callconv(.c) void {
    const box: *FailureBox = @ptrCast(@alignCast(ctx.?));
    const s = box.s;
    const text = box.text;
    const more = box.more;
    s.gpa.destroy(box);
    s.failMarket(text, more);
}
