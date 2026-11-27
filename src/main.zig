//! nanomcp: an MCP gateway with a GUI, on nanoui.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const state_mod = @import("state.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const menubar = @import("menubar.zig");

pub fn main(init: std.process.Init) !void {
    // Closing the window leaves the gateway running: the menu bar icon brings
    // it back, so the gateway stays reachable while its window is away.
    const app = try nanoui.App.create(init, .{
        .name = "nanomcp",
        .quit_on_last_window_closed = false,
    });
    defer app.destroy();

    var state = try state_mod.App.init(init, app);
    defer state.deinit();

    state.window = try newMainWindow(app, state);

    // A second launch while the window is hidden arrives as a reopen of the
    // running app (with no Dock icon there is no second copy to start): show
    // the window again instead of doing nothing.
    app.options.ctx = @ptrCast(state);
    app.options.on_reopen = reopenFromSystem;

    // The menu bar: a bolt beside the clock, one click from either page a
    // gateway is looked at through. Headless runs (--nanoui-snapshot and
    // friends) leave the menu bar alone, and so does every platform nanoui
    // has no tray on yet: creating one there is an error, not a no-op.
    if (comptime builtin.os.tag == .macos) {
        if (!app.flags.hidden) {
            state.tray = try app.newTray(.{
                .symbol = menubar.icon_symbol,
                .tooltip = menubar.tooltip_base,
                .menu = &.{
                    .{ .label = "Open nanomcp", .click = nanoui.MenuClick.of(state, openServers) },
                    .{ .label = "Show Routes", .click = nanoui.MenuClick.of(state, openRoutes) },
                    .separator,
                    .{ .role = .quit },
                },
            });
        }
    }

    try app.run();
}

fn newMainWindow(app: *nanoui.App, state: *state_mod.App) !*nanoui.Window {
    return app.newWindow(.{
        .title = "nanomcp",
        .width = 1080,
        .height = 740,
        .min_width = 820,
        .min_height = 560,
        // The sidebar and the page run to the window's top edge; the window's
        // own buttons sit over the sidebar's strip, as nanoterm's do.
        .title_bar = if (builtin.os.tag == .macos) .hidden else .default,
        .theme = theme.ui(nanoui.isDark()),
        // The close button hides the window and leaves the menu bar icon
        // running; opening the window brings back both it and the Dock icon.
        .should_close = .{ .ctx = state, .func = hideOnClose },
        .content = .{ .view = .init(state, view.view) },
    });
}

/// Closing the window keeps the app running behind its menu bar icon, but
/// takes the Dock icon away with the window: without one it is an accessory
/// app, and it becomes regular again when the window comes back.
fn hideOnClose(_: *anyopaque, w: *nanoui.Window) bool {
    w.hide();
    setDockIcon(false);
    return false;
}

/// `NSApplicationActivationPolicy`: a regular app has a Dock icon and menus
/// of its own, an accessory one has neither.
const DockPolicy = enum(isize) { regular = 0, accessory = 1 };

fn dockPolicy(shown: bool) DockPolicy {
    return if (shown) .regular else .accessory;
}

test "the Dock icon is regular with a window and accessory without one" {
    try std.testing.expectEqual(DockPolicy.regular, dockPolicy(true));
    try std.testing.expectEqual(DockPolicy.accessory, dockPolicy(false));
}

/// Asks AppKit for a Dock icon (a regular app), or for none (an accessory
/// one, which keeps its menu bar icon).
fn setDockIcon(shown: bool) void {
    if (comptime builtin.os.tag == .macos) {
        const objc = nanoui.objc;
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, @intFromEnum(dockPolicy(shown)))});
    }
}

/// A launch while the app is already running, which is the way back in once
/// the Dock icon is gone.
fn reopenFromSystem(ctx: ?*anyopaque) void {
    const s: *state_mod.App = @ptrCast(@alignCast(ctx orelse return));
    openPage(s, s.page);
}

/// Bringing the window up on a page from the icon.
fn openServers(s: *state_mod.App, _: *nanoui.menu.Item) void {
    openPage(s, .servers);
}

fn openRoutes(s: *state_mod.App, _: *nanoui.menu.Item) void {
    openPage(s, .routes);
}

fn openPage(s: *state_mod.App, page: state_mod.Page) void {
    s.page = page;
    const w = s.window orelse blk: {
        const made = newMainWindow(s.app, s) catch return;
        s.window = made;
        break :blk made;
    };
    // Before focusing: an accessory app cannot come forward into a Dock it
    // is not in.
    setDockIcon(true);
    w.focus();
    w.redraw();
}
