//! The nanomcp application state.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const config = @import("config.zig");
pub const credentials = @import("credentials.zig");
pub const gateway = @import("gateway.zig");
pub const registry = @import("registry.zig");
pub const editor = @import("editor.zig");

pub const Page = enum { servers, market, routes, tools, settings };

/// What the gateway reports to the servers it connects to, and the build the
/// sidebar names.
pub const version = "0.1.0";

pub const Toast = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    is_err: bool = false,
    until: f64 = 0,

    pub fn text(t: *const Toast) []const u8 {
        return t.buf[0..t.len];
    }
};

/// The row menu a server's … button opens, and where it opens, in window
/// coordinates.
pub const ServerMenu = struct {
    id: []const u8,
    x: f32 = 0,
    y: f32 = 0,
};

pub const ServersUi = struct {
    filter: ui.TextBuffer = .{},
    grid: bool = false,
    editing: ?[]const u8 = null,
    form: editor.Form = .{ .mode = .add },
    form_error: []const u8 = "",
    /// Gives the form's name field the focus as it opens.
    focus_form: bool = false,
    import_open: bool = false,
    import_text: ui.TextBuffer = .{},
    import_error: []const u8 = "",
    /// Gives the import area the focus as it opens.
    focus_import: bool = false,
    removing: ?[]const u8 = null,
    selected: usize = 0,
    menu: ?ServerMenu = null,
};

pub const MarketUi = struct {
    query: ui.TextBuffer = .{},
    results: []registry.Server = &.{},
    cursor: ?[]const u8 = null,
    searched: bool = false,
    loading: bool = false,
    err: []const u8 = "",
    selected: usize = 0,
    /// Counts keystrokes, so only the last one of a burst searches.
    seq: u32 = 0,
    /// The arenas every result points into, one per page. Freed when the
    /// results are replaced, never while they are on screen.
    holds: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .empty,
    /// The registry searched; a test points it at a stub.
    base_url: []const u8 = registry.default_base_url,
};

pub const ToolsUi = struct {
    filter: ui.TextBuffer = .{},
    /// The chosen row's place in the filtered list; null when there is none.
    selected: ?usize = null,
    call_args: ui.TextBuffer = .{},
    /// What the last call answered, or why it could not run. Owned by the app
    /// when `result_owned`, so a new call can free the last answer.
    call_result: []const u8 = "",
    call_err: bool = false,
    calling: bool = false,
    result_owned: bool = false,
};

pub const SettingsUi = struct {
    port: ui.TextBuffer = .{},
    port_loaded: bool = false,
    busy: []const u8 = "",
    copied: []const u8 = "",
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The application, for the windows the menu bar opens again after one
    /// has been closed.
    app: *nanoui.App,
    data_dir: []const u8,
    /// Owns every string and list inside `cfg`: the configuration changes
    /// hands often, so its memory is freed all at once when the app exits.
    cfg_arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    creds: credentials.CredentialStore,
    gw: *gateway.Gateway,
    window: ?*nanoui.Window = null,
    /// The icon beside the clock, when the app is not running headless.
    tray: ?*nanoui.Tray = null,
    /// The agent count the icon is currently showing.
    tray_agents: usize = 0,
    page: Page = .servers,
    dark: bool = false,
    toast: Toast = .{},
    /// The token callers present, kept here so a frame can draw it without
    /// reading (and leaking) the credential store each time.
    inbound_token: ?[]u8 = null,

    servers: ServersUi = .{},
    market: MarketUi = .{},
    tools: ToolsUi = .{},
    settings: SettingsUi = .{},

    const Self = @This();

    pub fn init(proc: std.process.Init, app: *nanoui.App) !*Self {
        const gpa = proc.gpa;
        const io_inst = proc.io;

        const test_dir = std.c.getenv("NANOMCP_TEST_DIR");
        const base = if (test_dir) |td| blk: {
            break :blk try gpa.dupe(u8, std.mem.span(td));
        } else blk: {
            migrateOldDataDir(io_inst, gpa);
            break :blk try homeDataDir(gpa);
        };
        const data_dir = try std.fs.path.join(gpa, &.{ base, "userdata" });
        defer gpa.free(base);
        std.Io.Dir.cwd().createDirPath(io_inst, data_dir) catch {};

        var cfg_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer cfg_arena.deinit();

        var cfg = config.Config.default();
        if (config.load(cfg_arena.allocator(), io_inst, data_dir)) |loaded| {
            cfg = loaded;
        } else |e| std.debug.print("load config: {s}\n", .{@errorName(e)});

        const store: credentials.CredentialStore = .initFiles(gpa, io_inst, data_dir);

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io_inst,
            .app = app,
            .data_dir = data_dir,
            .cfg_arena = cfg_arena,
            .cfg = cfg,
            .creds = store,
            .gw = undefined,
        };

        // The gateway reads the configuration and credentials through the
        // app's own fields: pointing it at locals would leave it looking at
        // this function's frame after it returned, and at copies the window
        // never updates.
        const gw = try gpa.create(gateway.Gateway);
        errdefer gpa.destroy(gw);
        gw.* = gateway.Gateway.init(gpa, io_inst, &self.cfg, &self.creds, version);
        // A stdio server is a child process that needs the same PATH and HOME
        // as this app, plus whatever its configuration adds.
        gw.environ = proc.environ_map;
        errdefer _ = gw.deinit();
        self.gw = gw;

        self.reloadInboundToken();

        // Serving starts now; the servers connect on their own thread, so a
        // server that never answers does not hold the window up: its row
        // shows "connecting" until the session's timeout fails it.
        gw.startAsync(@intCast(@max(0, cfg.port))) catch |e| std.debug.print("start: {s}\n", .{@errorName(e)});

        gw.setOnChange(self, changedFromAnyThread);
        // The buffer copies what it is given, so the text comes off the stack.
        var port_text: [16]u8 = undefined;
        self.settings.port.set(std.fmt.bufPrint(&port_text, "{d}", .{self.cfg.port}) catch "");
        self.settings.port_loaded = true;
        return self;
    }

    /// The allocator everything in `cfg` comes from; freeing it is the
    /// arena's job when the app exits, so cfg memory is never freed piecemeal.
    pub fn cfgAlloc(s: *Self) std.mem.Allocator {
        return s.cfg_arena.allocator();
    }

    pub fn deinit(s: *Self) void {
        s.freeMarket();
        s.freeCall();
        if (s.inbound_token) |token| s.gpa.free(token);
        // deinit stops the listener, wakes waiting calls, and joins the
        // workers; false means a stuck connect kept the gateway, which the
        // operating system reclaims as the process exits.
        if (s.gw.deinit()) s.gpa.destroy(s.gw);
        s.creds.deinit();
        s.gpa.free(s.data_dir);
        s.cfg_arena.deinit(); // after the gateway: it reads cfg through us
        s.gpa.destroy(s);
    }

    /// Renames the pre-rename data directory, once, so servers and tokens
    /// survive the name change.
    fn migrateOldDataDir(io: std.Io, a: std.mem.Allocator) void {
        const home = std.c.getenv("HOME") orelse return;
        const h = std.mem.span(home);
        const old = std.fs.path.join(a, &.{ h, ".local", "share", "mcp-go" }) catch return;
        defer a.free(old);
        const new = std.fs.path.join(a, &.{ h, ".local", "share", "nanomcp" }) catch return;
        defer a.free(new);
        std.Io.Dir.accessAbsolute(io, old, .{}) catch return;
        std.Io.Dir.accessAbsolute(io, new, .{}) catch {
            std.Io.Dir.renameAbsolute(old, new, io) catch {};
        };
    }

    fn homeDataDir(a: std.mem.Allocator) ![]const u8 {
        const home = std.c.getenv("HOME");
        const h = if (home) |hv| try a.dupe(u8, std.mem.span(hv)) else ".";
        defer a.free(h);
        return try std.fs.path.join(a, &.{ h, ".local", "share", "nanomcp" });
    }

    pub fn save(s: *Self) void {
        _ = config.save(s.io, s.gpa, s.cfg, s.data_dir) catch {
            s.notify("save failed", true);
            return;
        };
    }

    pub fn resync(s: *Self) void {
        // Nothing is drawn without a window, so connecting the servers waits
        // for the moment there is one to show them in. The connection itself
        // runs off the main thread: a server that never answers must not
        // freeze the window.
        if (s.window == null) return;
        s.gw.syncAsync();
        s.redisplay();
    }

    pub fn redisplay(s: *Self) void {
        if (s.window) |w| w.redraw();
    }

    /// The token callers of the gateway present, as the last reload read it.
    pub fn inboundToken(s: *Self) []const u8 {
        return s.inbound_token orelse "";
    }

    /// Reads the inbound token again after it was set or rotated.
    pub fn reloadInboundToken(s: *Self) void {
        if (s.inbound_token) |token| s.gpa.free(token);
        s.inbound_token = s.creds.get(credentials.CredentialStore.inbound_token_key) catch null;
    }

    pub fn notify(s: *Self, text: []const u8, is_err: bool) void {
        // The caller's text may live on a frame's stack: the toast keeps its
        // own copy until it fades.
        const n = @min(text.len, s.toast.buf.len);
        @memcpy(s.toast.buf[0..n], text[0..n]);
        s.toast.len = n;
        s.toast.is_err = is_err;
        s.toast.until = 0;
        s.redisplay();
    }

    pub fn freeMarket(s: *Self) void {
        if (s.market.results.len > 0) s.gpa.free(s.market.results);
        s.market.results = &.{};
        s.market.cursor = null;
        for (s.market.holds.items) |arena| {
            arena.deinit();
            s.gpa.destroy(arena);
        }
        s.market.holds.deinit(s.gpa);
        s.market.holds = .empty;
    }

    fn freeMarketError(s: *Self) void {
        if (s.market.err.len > 0) s.gpa.free(s.market.err);
        s.market.err = "";
    }

    /// Marks a search as running; the results already shown stay up.
    pub fn beginMarket(s: *Self) void {
        s.market.loading = true;
        s.freeMarketError();
        s.redisplay();
    }

    /// Takes one page of search results. `more` appends it to the page
    /// already shown; otherwise it replaces everything, the way a new search
    /// starts over. The page's strings live in `arena`, which the market
    /// keeps until the results are replaced.
    pub fn addMarket(s: *Self, arena: *std.heap.ArenaAllocator, results: []registry.Server, cursor: []const u8, more: bool) void {
        // The page's strings live in `arena`. It is kept only once whatever
        // refers to it is in place.
        var kept = false;
        defer if (!kept) {
            arena.deinit();
            s.gpa.destroy(arena);
        };

        if (!more) {
            // The slice itself belongs to the market, so a later page can
            // free it; the server strings stay in the arena.
            var owned: []registry.Server = &.{};
            if (results.len > 0) {
                owned = s.gpa.alloc(registry.Server, results.len) catch {
                    s.failMarket(s.gpa.dupe(u8, "The registry's answer could not be kept: out of memory") catch "", false);
                    return;
                };
                @memcpy(owned, results);
            }
            s.freeMarket();
            s.market.results = owned;
            s.market.holds.append(s.gpa, arena) catch {
                if (owned.len > 0) s.gpa.free(owned);
                s.market.results = &.{};
                s.market.searched = true;
                s.market.loading = false;
                s.freeMarketError();
                s.redisplay();
                return;
            };
            kept = true;
            s.market.selected = 0;
        } else if (results.len > 0) {
            const old = s.market.results;
            const merged = s.gpa.alloc(registry.Server, old.len + results.len) catch {
                s.failMarket(s.gpa.dupe(u8, "The registry's answer could not be kept: out of memory") catch "", true);
                return;
            };
            @memcpy(merged[0..old.len], old);
            @memcpy(merged[old.len..], results);
            s.market.holds.append(s.gpa, arena) catch {
                s.gpa.free(merged);
                return;
            };
            kept = true;
            if (old.len > 0) s.gpa.free(old);
            s.market.results = merged;
        }
        // A page without a next cursor ends the list, even when it added
        // nothing: "Show more" must not stay.
        s.market.cursor = if (cursor.len > 0) cursor else null;
        s.market.searched = true;
        s.market.loading = false;
        s.freeMarketError();
        s.redisplay();
    }

    /// Forgets the last tool call's answer, and any call still marked as
    /// running, so a new one starts from an empty pane.
    pub fn freeCall(s: *Self) void {
        if (s.tools.result_owned and s.tools.call_result.len > 0) s.gpa.free(s.tools.call_result);
        s.tools.call_result = "";
        s.tools.result_owned = false;
        s.tools.call_err = false;
        s.tools.calling = false;
    }

    pub fn beginCall(s: *Self) void {
        s.freeCall();
        s.tools.calling = true;
        s.redisplay();
    }

    /// Takes the call's answer; `text` is owned by the app from now on.
    pub fn finishCall(s: *Self, text: []const u8, is_err: bool) void {
        s.freeCall();
        s.tools.call_result = text;
        s.tools.result_owned = true;
        s.tools.call_err = is_err;
        s.redisplay();
    }

    /// Records why a search could not run.
    pub fn failMarket(s: *Self, text: []const u8, more: bool) void {
        s.market.loading = false;
        s.market.searched = true;
        s.freeMarketError();
        s.market.err = text;
        if (!more) {
            s.freeMarket();
            s.market.searched = true;
        }
        s.redisplay();
    }

    /// The gateway calls this from whatever thread it is on: the redraw is
    /// queued for the main thread, where windows live. Only AppKit needs the
    /// hop; the other backends are called where they are.
    fn changedFromAnyThread(ctx: *anyopaque) void {
        const s: *Self = @ptrCast(@alignCast(ctx));
        if (@import("builtin").os.tag == .macos) {
            nanoui.objc.dispatchMain(s, redrawNow);
        } else s.redisplay();
    }

    fn redrawNow(ctx: ?*anyopaque) callconv(.c) void {
        const s: *Self = @ptrCast(@alignCast(ctx.?));
        s.redisplay();
    }
};
