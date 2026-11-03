//! nanomcp: an MCP gateway with a GUI, on nanoui.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const state_mod = @import("state.zig");
const view = @import("view.zig");
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
        // The close button hides the window; the menu bar and the Dock icon
        // show it again.
        .should_close = .{ .ctx = state, .func = hideOnClose },
        .content = .{ .view = .init(state, view.view) },
    });
}

fn hideOnClose(_: *anyopaque, w: *nanoui.Window) bool {
    w.hide();
    return false;
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
    w.focus();
    w.redraw();
}
