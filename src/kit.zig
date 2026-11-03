//! The pieces nanomcp's pages are made of: a page header with controls,
//! cards with a colored chip and a title, status pills, and the keyboard
//! shortcuts, in nanomon's style.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const App = state_mod.App;

pub const header_h: f32 = 54;

/// A page header: name and subtitle; add controls, then `end`. Returns the
/// header row so controls can justify end.
pub fn header(c: *ui.Context, k: theme.Colors, name: []const u8, subtitle: []const u8) ui.Div {
    const h = ui.div(c).row().wFull().h(header_h).itemsCenter().gap(8).px(20);
    const t = ui.div(c).column().gap(2).clip();
    ui.text(c, name, .{ .size = 20, .weight = .bold, .color = k.text });
    if (subtitle.len > 0) ui.text(c, subtitle, .{ .size = 12, .color = k.secondary });
    t.end();
    ui.spacer(c);
    return h;
}

/// A card: column that grows, card fill, border, shadow; add children.
pub fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().gap(12).p(16).rounded(12).bg(k.card)
        .border(k.border).shadowSm();
}

pub fn cardTight(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().gap(8).p(12).rounded(10).bg(k.card)
        .border(k.border).shadowSm();
}

/// A colored square with a symbol in it.
pub fn chip(c: *ui.Context, icon: []const u8, color: ui.Color, size: f32, solid: bool) void {
    const d = ui.div(c).row().w(size).h(size).center().rounded(size * 0.3).bg(if (solid) color else color.alpha(0.16));
    defer d.end();
    ui.icon(c, icon, .{ .size = size * 0.5, .weight = .semibold, .color = if (solid) .white else color });
}

/// A card's title: chip and name. Closed before the card's body, so the body
/// sits under the title instead of beside it.
pub fn cardTitle(c: *ui.Context, icon: []const u8, name: []const u8, color: ui.Color) void {
    const r = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer r.end();
    chip(c, icon, color, 22, false);
    ui.text(c, name, .{ .size = 13, .weight = .semibold, .color = color });
    ui.spacer(c);
}

/// A server's figure: its initials on a color of its own, chosen from its
/// name so the same server keeps the same color.
pub fn avatar(c: *ui.Context, k: theme.Colors, name: []const u8, size: f32) void {
    const palette = [_]ui.Color{ k.blue, k.purple, k.teal, k.green, k.orange, k.red, k.accent, k.yellow };
    const color = palette[std.hash.Wyhash.hash(0, name) % palette.len];

    var initials: [8]u8 = undefined;
    var n: usize = 0;
    var words = std.mem.tokenizeAny(u8, name, " \t\r\n-_.");
    while (words.next()) |word| {
        if (n == 2) break;
        if (word.len == 0) continue;
        initials[n] = std.ascii.toUpper(word[0]);
        n += 1;
    }
    if (n == 0) {
        initials[0] = '?';
        n = 1;
    }

    const d = ui.div(c).w(size).h(size).center().rounded(size * 0.5).bg(color.alpha(0.18));
    defer d.end();
    ui.text(c, c.print("{s}", .{initials[0..n]}), .{ .size = size * 0.4, .weight = .semibold, .color = color });
}

/// An on/off switch without a visible label; the caller labels the row.
pub fn toggle(c: *ui.Context, value: *bool) bool {
    return ui.toggle(c, "", value);
}

pub fn pageEmpty(c: *ui.Context, k: theme.Colors, icon: []const u8, title_s: []const u8, sub: []const u8) void {
    const d = ui.div(c).column().wFull().grow().itemsCenter().gap(8).py(32);
    defer d.end();
    ui.icon(c, icon, .{ .size = 28, .color = k.secondary.alpha(0.5) });
    ui.text(c, title_s, .{ .size = 15, .weight = .semibold, .color = k.secondary });
    ui.text(c, sub, .{ .size = 12, .color = k.tertiary });
}

/// ⌘1–⌘5 pick a page; ⌘K searches tools; Escape goes to Servers, unless a
/// dialog is open over the page and takes it.
pub fn keys(c: *ui.Context, s: *App, dialog_open: bool) void {
    const pages = .{ .servers, .market, .routes, .tools, .settings };
    const all = comptime std.enums.values(state_mod.Page);
    inline for (all, 0..) |p, i| {
        if (c.shortcut(.{ .key = @as(u21, '0') + @as(u21, i) + 1, .cmd = true })) {
            s.page = p;
            s.redisplay();
        }
    }
    _ = pages;
    if (c.shortcut(.{ .key = 'k', .shift = true, .cmd = true })) s.redisplay();
    if (!dialog_open and c.shortcut(.{ .key = ui.Shortcut.escape })) {
        if (s.page != .servers) {
            s.page = .servers;
            s.redisplay();
        }
    }
}
