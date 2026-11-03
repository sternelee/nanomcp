//! The menu bar: an icon beside the clock whose panel shows what the gateway
//! serves and who is using it, one click away from the full window.
//!
//! This is the part that can be said without a screen: which icon the system
//! is asked for, what the menu offers, how the title counts the agents, and
//! the panel's size and state. The window and the menu themselves come from
//! the app, which is why nothing here imports the toolkit.
const std = @import("std");

/// The neater surface is a bolt, as the system draws its own.
pub const icon_symbol = "bolt.fill";

/// What the pointer says when it rests on the icon.
pub const tooltip_base = "nanomcp";

/// The panel hangs under the icon.
pub const panel_width: f64 = 360;
pub const panel_height: f64 = 480;
pub const panel_gap: f64 = 4;

pub const page_servers = "/servers";
pub const page_routes = "/routes";

/// One entry of the menu the icon opens.
pub const Entry = union(enum) {
    /// Brings the window up on a page.
    open: struct { label: []const u8, page: []const u8 },
    separator,
    quit,
};

/// The menu, in order: the two pages a gateway is looked at through, and the
/// way out.
pub const menu = [_]Entry{
    .{ .open = .{ .label = "Open nanomcp", .page = page_servers } },
    .{ .open = .{ .label = "Show Routes", .page = page_routes } },
    .separator,
    .quit,
};

/// Says "agent" or "agents" for n.
pub fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// What the menu bar shows: a bare count of the agents while any are
/// connected, and the whole story in the tooltip.
pub const Status = struct {
    title: []const u8,
    tooltip: []const u8,

    pub fn deinit(s: Status, a: std.mem.Allocator) void {
        a.free(s.title);
        a.free(s.tooltip);
    }
};

/// The title and tooltip for the state the app has just reloaded.
pub fn status(a: std.mem.Allocator, summary: []const u8, agents: usize) !Status {
    const title = if (agents > 0)
        try std.fmt.allocPrint(a, "{d}", .{agents})
    else
        try a.dupe(u8, "");
    errdefer a.free(title);
    const tooltip = if (agents > 0)
        try std.fmt.allocPrint(a, "{s} · {s} · {d} agent{s} connected", .{
            tooltip_base, summary, agents, plural(agents),
        })
    else
        try std.fmt.allocPrint(a, "{s} · {s}", .{ tooltip_base, summary });
    return .{ .title = title, .tooltip = tooltip };
}

/// The title of the icon: a bare count of the agents while any are
/// connected, and nothing at all when the gateway is quiet.
pub fn titleInto(buf: []u8, agents: usize) []const u8 {
    if (agents == 0) return "";
    return std.fmt.bufPrint(buf, "{d}", .{agents}) catch "";
}

test "the icon counts the agents, and says nothing when there are none" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("", titleInto(&buf, 0));
    try std.testing.expectEqualStrings("1", titleInto(&buf, 1));
    try std.testing.expectEqualStrings("12", titleInto(&buf, 12));
}

/// The panel under the icon, and which of its two lists is showing.
pub const Panel = struct {
    open: bool = false,
    tab: Tab = .servers,

    pub const Tab = enum { servers, agents };

    /// Opens the panel, or closes the one that is open.
    pub fn toggle(p: *Panel) void {
        p.open = !p.open;
    }

    pub fn show(p: *Panel) void {
        p.open = true;
    }

    /// Closes the panel, which is what opening a page from it does first.
    pub fn close(p: *Panel) void {
        p.open = false;
    }

    /// A row of the panel opens the main window on a page.
    pub fn pageFor(p: *Panel, row: Row) []const u8 {
        p.close();
        return switch (row) {
            .servers => page_servers,
            .agents => page_routes,
        };
    }

    pub const Row = enum { servers, agents };
};

test "the icon is a bolt, and the pointer says what it is" {
    try std.testing.expectEqualStrings("bolt.fill", icon_symbol);
    try std.testing.expectEqualStrings("nanomcp", tooltip_base);
}

test "the menu opens each page and quits" {
    try std.testing.expectEqual(@as(usize, 4), menu.len);
    const first = menu[0].open;
    try std.testing.expectEqualStrings("Open nanomcp", first.label);
    try std.testing.expectEqualStrings("/servers", first.page);
    const second = menu[1].open;
    try std.testing.expectEqualStrings("Show Routes", second.label);
    try std.testing.expectEqualStrings("/routes", second.page);
    try std.testing.expect(menu[2] == .separator);
    try std.testing.expect(menu[3] == .quit);
}

test "an agent is an agent, and more of them are agents" {
    try std.testing.expectEqualStrings("", plural(1));
    try std.testing.expectEqualStrings("s", plural(0));
    try std.testing.expectEqualStrings("s", plural(2));
}

test "the title counts the agents, and the tooltip says what the gateway serves" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const quiet = try status(a, "2 servers, 5 tools", 0);
    try std.testing.expectEqualStrings("", quiet.title);
    try std.testing.expectEqualStrings("nanomcp · 2 servers, 5 tools", quiet.tooltip);

    const one = try status(a, "2 servers, 5 tools", 1);
    try std.testing.expectEqualStrings("1", one.title);
    try std.testing.expectEqualStrings("nanomcp · 2 servers, 5 tools · 1 agent connected", one.tooltip);

    const many = try status(a, "1 server, 3 tools", 3);
    try std.testing.expectEqualStrings("3", many.title);
    try std.testing.expectEqualStrings("nanomcp · 1 server, 3 tools · 3 agents connected", many.tooltip);
}

test "the panel hangs under the icon, and a click toggles it" {
    try std.testing.expectEqual(@as(f64, 360), panel_width);
    try std.testing.expectEqual(@as(f64, 480), panel_height);
    try std.testing.expectEqual(@as(f64, 4), panel_gap);

    var panel: Panel = .{};
    try std.testing.expect(!panel.open);
    panel.toggle();
    try std.testing.expect(panel.open);
    panel.toggle();
    try std.testing.expect(!panel.open);
}

test "a panel row opens the window on its page and closes the panel" {
    var panel: Panel = .{};
    panel.toggle();
    try std.testing.expectEqualStrings("/servers", panel.pageFor(.servers));
    try std.testing.expect(!panel.open);
    panel.show();
    try std.testing.expectEqualStrings("/routes", panel.pageFor(.agents));
    try std.testing.expect(!panel.open);
}
