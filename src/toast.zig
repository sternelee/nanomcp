//! A toast: one line over the bottom of the window, there for a few
//! seconds. It draws over whatever page is showing, and its box leaves the
//! pointer alone, so what is underneath stays clickable.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const state_mod = @import("state.zig");
const App = state_mod.App;

pub fn toast(c: *ui.Context, s: *App, k: theme.Colors) void {
    if (s.toast.len == 0) return;
    // The deadline starts on the first frame the toast is drawn: a notify
    // cannot know the frame clock, and drawing is when the clock is here.
    if (s.toast.until == 0) {
        const hold: f64 = if (s.toast.is_err) 4.5 else 3.2;
        s.toast.until = c.time + hold;
    }
    const left = s.toast.until - c.time;
    if (left <= 0) {
        s.toast.len = 0;
        s.toast.until = 0;
        return;
    }
    // One more frame when the time is up, so the toast goes away by itself.
    c.frameIn(@floatCast(left));

    const overlay = ui.div(c).absolute().sizeFull().column().itemsCenter().justifyEnd().pb(20).px(16);
    defer overlay.end();
    const box = ui.div(c).row().gap(8).itemsCenter().px(14).py(8).rounded(8)
        .bg(k.card).border(k.border).shadowMd();
    defer box.end();
    ui.icon(c, if (s.toast.is_err) "xmark.octagon" else "checkmark.circle.fill", .{
        .size = 13,
        .color = if (s.toast.is_err) k.red else k.green,
    });
    ui.text(c, s.toast.text(), .{ .size = 12, .color = if (s.toast.is_err) k.red else k.text });
}
