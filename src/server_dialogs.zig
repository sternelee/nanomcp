//! The Servers page's dialogs: removing a server, pasting a configuration,
//! and adding or editing one. They open over the whole window.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const editor = @import("editor.zig");
const actions = @import("server_actions.zig");

const App = state_mod.App;

const import_placeholder =
    \\{
    \\  "mcpServers": {
    \\    "filesystem": {
    \\      "command": "npx",
    \\      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    \\    },
    \\    "remote": {
    \\      "type": "http",
    \\      "url": "https://example.com/mcp"
    \\    }
    \\  }
    \\}
;

/// Whether a dialog covers the page, so Escape closes it rather than
/// leaving the page.
pub fn anyOpen(s: *App) bool {
    return s.servers.removing != null or s.servers.import_open or s.servers.editing != null;
}

/// Draws whichever dialog is open, on top of the window.
pub fn draw(c: *ui.Context, s: *App, k: theme.Colors) void {
    if (s.servers.removing) |id| {
        if (s.cfg.server(id) != null) {
            removeDialog(c, s, k, id);
            return;
        }
        s.servers.removing = null;
    }
    if (s.servers.import_open) {
        importDialog(c, s, k);
        return;
    }
    if (s.servers.editing) |id| editorDialog(c, s, k, id);
}

/// A dimmed overlay behind a dialog. It takes the events, so nothing under
/// the dialog is pressed; a click on it, or Escape, dismisses the dialog.
fn scrim(c: *ui.Context, k: theme.Colors) bool {
    const d = ui.div(c).absolute().sizeFull().bg(k.page.alpha(0.45));
    const it = d.interaction();
    d.end();
    return it.clicked or dismissed(c);
}

fn dismissed(c: *ui.Context) bool {
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) return true;
    if (c.input.key) |key| if (key == .escape) {
        c.input.key = null;
        return true;
    };
    return false;
}

fn removeDialog(c: *ui.Context, s: *App, k: theme.Colors, id: []const u8) void {
    const sc = s.cfg.server(id) orelse return;
    if (scrim(c, k)) {
        s.servers.removing = null;
        return;
    }
    const overlay = ui.div(c).absolute().sizeFull().center().px(24).py(40);
    defer overlay.end();
    const win = ui.div(c).column().w(400).p(20).rounded(12).bg(k.page).border(k.border).shadowLg().gap(12);
    defer win.end();
    _ = win.interaction();

    ui.text(c, c.print("Remove \u{201c}{s}\u{201d}?", .{sc.name}), .{ .size = 16, .weight = .bold, .color = k.text });
    ui.text(c, "Its tools are withdrawn from the gateway, and its saved sign-in is forgotten.", .{ .size = 12, .color = k.secondary });
    const buttons = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer buttons.end();
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 13 }).clicked) s.servers.removing = null;
    if (ui.button(c, "Remove", .{ .variant = .danger, .size = 13 }).clicked) actions.removeServer(s, id);
}

fn importDialog(c: *ui.Context, s: *App, k: theme.Colors) void {
    if (scrim(c, k)) {
        s.servers.import_open = false;
        return;
    }
    const overlay = ui.div(c).absolute().sizeFull().center().px(24).py(40);
    defer overlay.end();
    const win = ui.div(c).column().w(520).p(20).rounded(12).bg(k.page).border(k.border).shadowLg().gap(12);
    defer win.end();
    _ = win.interaction();

    {
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        ui.text(c, "Paste a configuration", .{ .size = 18, .weight = .bold, .color = k.text });
        ui.spacer(c);
        const x = ui.div(c).row().w(26).h(26).center().rounded(7).hover(k.hover).control();
        ui.icon(c, "xmark", .{ .size = 13, .color = k.secondary });
        const closed = x.clicked();
        x.end();
        if (closed) s.servers.import_open = false;
    }
    ui.text(c, "The mcpServers block from Claude Desktop, Cursor or VS Code works as it stands. A server whose name is already here is replaced.", .{
        .size = 12,
        .color = k.secondary,
    });

    ui.text(c, "Configuration", .{ .size = 11, .weight = .semibold, .color = k.tertiary });
    {
        _ = ui.textArea(c, &s.servers.import_text, .{ .placeholder = import_placeholder, .size = 12, .width = .fill, .min_lines = 15, .max_lines = 15 });
        if (s.servers.focus_import) {
            c.focus = s.servers.import_text.last_id;
            c.changed = true;
            s.servers.focus_import = false;
        }
    }

    if (s.servers.import_error.len > 0) ui.text(c, s.servers.import_error, .{ .size = 12, .color = k.red });

    const buttons = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer buttons.end();
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 13 }).clicked) s.servers.import_open = false;
    const empty = std.mem.trim(u8, s.servers.import_text.text(), " \t\r\n").len == 0;
    if (ui.button(c, "Import", .{ .variant = .primary, .size = 13, .disabled = empty }).clicked) actions.doImport(s);
}

fn editorDialog(c: *ui.Context, s: *App, k: theme.Colors, id: []const u8) void {
    const target = actions.targetOf(s, id) orelse {
        s.servers.editing = null;
        return;
    };
    if (scrim(c, k)) {
        s.servers.editing = null;
        return;
    }
    const overlay = ui.div(c).absolute().sizeFull().center().px(24).py(40);
    defer overlay.end();
    const win = ui.div(c).column().w(540).maxH(@max(320, c.size.h - 80)).p(20).rounded(12)
        .bg(k.page).border(k.border).shadowLg().gap(14);
    defer win.end();
    _ = win.interaction();

    {
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        const title = if (s.servers.form.mode == .add) "Add a server" else "Edit server";
        ui.text(c, title, .{ .size = 18, .weight = .bold, .color = k.text });
        ui.spacer(c);
        const x = ui.div(c).row().w(26).h(26).center().rounded(7).hover(k.hover).control();
        ui.icon(c, "xmark", .{ .size = 13, .color = k.secondary });
        const closed = x.clicked();
        x.end();
        if (closed) s.servers.editing = null;
    }

    // The body sizes to its fields, up to the room the window leaves; a
    // scrolling box without a ceiling measures zero high and clips the form.
    const scroll = ui.div(c).column().wFull().maxH(@max(240, c.size.h - 260)).pr(8).scrollY().gap(12);
    const action = editor.build(&s.servers.form, c, k, s.servers.form.mode == .add, &s.servers.focus_form);
    scroll.end();

    if (s.servers.form_error.len > 0) ui.text(c, s.servers.form_error, .{ .size = 12, .color = k.red });

    const buttons = ui.div(c).row().wFull().gap(8).itemsCenter().pt(2);
    defer buttons.end();
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 13 }).clicked) s.servers.editing = null;
    if (ui.button(c, "Save", .{ .variant = .primary, .size = 13 }).clicked) actions.saveForm(s, target);

    switch (action) {
        .none => {},
        .sign_in => actions.signIn(s, id),
        .forget_token => actions.forgetToken(s, id),
    }
}
