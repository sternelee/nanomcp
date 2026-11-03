//! The add/edit server form: what the user types, held in text buffers so
//! each frame sees it, and the server it saves to.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const config = @import("config.zig");
const credentials = @import("credentials.zig");

pub const Mode = enum { add, edit };

/// What the form asks the dialog to do after this frame.
pub const Action = enum { none, sign_in, forget_token };

pub const Form = struct {
    mode: Mode = .add,
    name: ui.TextBuffer = .{},
    transport: usize = 0,
    command: ui.TextBuffer = .{},
    args: ui.TextBuffer = .{},
    env: ui.TextBuffer = .{},
    url: ui.TextBuffer = .{},
    headers: ui.TextBuffer = .{},
    oauth: bool = false,
    token_header: ui.TextBuffer = .{},
    token_scheme: ui.TextBuffer = .{},
    token: ui.TextBuffer = .{},
    client_id: ui.TextBuffer = .{},
    client_secret: ui.TextBuffer = .{},
    enabled: bool = true,
    /// Whether a static token is already stored; the token itself is never
    /// read back into the form.
    has_token: bool = false,

    const Self = @This();

    /// Clears the form for a new server, ready to paste a token into.
    pub fn reset(s: *Self) void {
        s.* = .{};
        s.token_header.set("Authorization");
        s.token_scheme.set("Bearer");
    }

    /// Fills the form from a configured server and its stored credentials.
    pub fn load(s: *Self, sc: config.ServerConfig, cc: credentials.ClientCredentials, has_token: bool) void {
        s.reset();
        s.mode = .edit;
        s.name.set(sc.name);
        s.transport = switch (sc.transport) {
            .stdio => 0,
            .sse => 1,
            else => 2,
        };
        s.command.set(sc.command orelse "");
        setLines(&s.args, sc.args orelse &.{});
        setLines(&s.env, sc.env orelse &.{});
        s.url.set(sc.url orelse "");
        setPairs(&s.headers, sc.headers);
        s.oauth = sc.oauth;
        s.token_header.set(sc.token_header orelse "");
        s.token_scheme.set(sc.token_scheme orelse "");
        s.client_id.set(cc.client_id);
        s.client_secret.set(cc.secret orelse "");
        s.enabled = sc.enabled;
        s.has_token = has_token;
    }

    /// The server the form now describes. Strings come from `a`; the id and
    /// alias are kept, so tools clients already hold keep their names.
    pub fn save(s: *Self, a: std.mem.Allocator, target: config.ServerConfig) !config.ServerConfig {
        var out = config.ServerConfig{
            .id = target.id,
            .alias = target.alias,
            .name = try a.dupe(u8, std.mem.trim(u8, s.name.text(), " \t\r\n")),
            .enabled = s.enabled,
        };
        switch (s.transport) {
            0 => {
                out.transport = .stdio;
                out.command = try dupeTrimmed(a, s.command.text());
                out.args = try splitLines(a, s.args.text());
                out.env = try splitLines(a, s.env.text());
            },
            1 => {
                out.transport = .sse;
                try remoteFields(s, a, &out);
            },
            else => {
                out.transport = .http;
                try remoteFields(s, a, &out);
            },
        }
        return out;
    }
};

fn remoteFields(s: *Form, a: std.mem.Allocator, out: *config.ServerConfig) !void {
    out.url = try dupeTrimmed(a, s.url.text());
    out.oauth = s.oauth;
    // A server signs in with OAuth or with a token, never both.
    if (!s.oauth) {
        out.token_header = try dupeTrimmed(a, s.token_header.text());
        out.token_scheme = try dupeTrimmed(a, s.token_scheme.text());
        out.headers = try parsePairs(a, s.headers.text());
    }
}

fn dupeTrimmed(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try a.dupe(u8, trimmed);
}

/// Turns a text area's contents into non-empty trimmed lines.
fn splitLines(a: std.mem.Allocator, text: []const u8) !?[]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, text, '\n');
    while (parts.next()) |line| {
        const piece = std.mem.trim(u8, line, " \r\t");
        if (piece.len == 0) continue;
        try list.append(a, try a.dupe(u8, piece));
    }
    if (list.items.len == 0) return null;
    return list.items;
}

/// Reads "Key: value" lines into headers, skipping lines without a colon.
fn parsePairs(a: std.mem.Allocator, text: []const u8) !?std.json.ArrayHashMap([]const u8) {
    var out: std.json.ArrayHashMap([]const u8) = .{};
    var parts = std.mem.splitScalar(u8, text, '\n');
    while (parts.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (key.len == 0) continue;
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        try out.map.put(a, try a.dupe(u8, key), try a.dupe(u8, value));
    }
    if (out.map.count() == 0) return null;
    return out;
}

fn setLines(buffer: *ui.TextBuffer, items: []const []const u8) void {
    buffer.clear();
    for (items, 0..) |item, i| {
        if (i > 0) _ = buffer.insert(buffer.text().len, "\n");
        _ = buffer.insert(buffer.text().len, item);
    }
}

/// Writes a server's headers as "Key: value" lines, in a stable order.
fn setPairs(buffer: *ui.TextBuffer, headers: ?std.json.ArrayHashMap([]const u8)) void {
    buffer.clear();
    const h = headers orelse return;
    var keys: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = h.map.iterator();
    while (it.next()) |entry| {
        if (n == keys.len) break;
        keys[n] = entry.key_ptr.*;
        n += 1;
    }
    for (1..n) |i| {
        var j = i;
        while (j > 0 and std.mem.order(u8, keys[j - 1], keys[j]) == .gt) : (j -= 1) {
            std.mem.swap([]const u8, &keys[j - 1], &keys[j]);
        }
    }
    for (keys[0..n], 0..) |key, i| {
        if (i > 0) _ = buffer.insert(buffer.text().len, "\n");
        _ = buffer.insert(buffer.text().len, key);
        _ = buffer.insert(buffer.text().len, ": ");
        _ = buffer.insert(buffer.text().len, h.map.get(key) orelse "");
    }
}

/// The form itself: fields for what the chosen transport needs. When
/// `focus_name` is set, the name field takes the focus and the flag clears.
pub fn build(s: *Form, c: *ui.Context, k: theme.Colors, is_new: bool, focus_name: *bool) Action {
    var action: Action = .none;
    const modes: [3][]const u8 = .{ "stdio", "SSE", "HTTP" };
    var pick = s.transport;

    if (focus_name.*) {
        s.name.focus();
        focus_name.* = false;
    }
    field(c, k, "Name", &s.name, "Filesystem", false, "");
    {
        const d = ui.div(c).column().wFull().gap(5);
        defer d.end();
        label(c, k, "Transport");
        if (ui.segmented(c, &modes, &pick)) s.transport = pick;
    }

    if (pick == 0) {
        field(c, k, "Command", &s.command, "npx", false, "");
        area(c, k, "Arguments", &s.args, "-y\n@modelcontextprotocol/server-filesystem\n/tmp", 5, "One argument per line.");
        area(c, k, "Environment", &s.env, "API_KEY=…", 4, "KEY=VALUE, one per line.");
    } else {
        field(c, k, "URL", &s.url, "https://example.com/mcp", false, "");
        switchField(c, k, "Sign in with OAuth", &s.oauth, "The gateway opens your browser and stores the token in the system keychain.");
        if (s.oauth) {
            field(c, k, "Client ID", &s.client_id, "", false, "Leave empty when the server registers clients itself.");
            field(c, k, "Client secret", &s.client_secret, "", true, "");
            if (!is_new) {
                const r = ui.div(c).row().wFull().gap(10).itemsCenter();
                defer r.end();
                if (ui.button(c, "Sign in now", .{ .variant = .secondary, .size = 12 }).clicked) action = .sign_in;
                ui.text(c, "Your browser opens to approve it. The gateway must be serving.", .{ .size = 11, .color = k.secondary });
            }
        } else {
            field(c, k, "Token header", &s.token_header, "Authorization", false, "The header the token is sent in. Leave blank for a server that needs none.");
            field(c, k, "Token scheme", &s.token_scheme, "Bearer", false, "Prefixed to the token, as in \"Bearer\". Leave blank to send it alone.");
            field(c, k, "Token", &s.token, if (s.has_token) "•••••••• saved" else "Paste the token", true, if (s.has_token) "A token is saved in the system keychain. Type a new one to replace it." else "Kept in the system keychain, never in the settings file.");
            if (s.has_token) {
                if (ui.button(c, "Forget the saved token", .{ .variant = .secondary, .size = 12 }).clicked) action = .forget_token;
            }
            area(c, k, "Other headers", &s.headers, "X-Trace: 1", 3, "Key: value, one per line.");
        }
    }

    switchField(c, k, "Enabled", &s.enabled, "Connect this server when the gateway starts.");
    return action;
}

fn label(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    ui.text(c, text, .{ .size = 11, .weight = .semibold, .color = k.tertiary });
}

fn field(c: *ui.Context, k: theme.Colors, name: []const u8, buffer: *ui.TextBuffer, placeholder: []const u8, password: bool, description: []const u8) void {
    const d = ui.div(c).column().wFull().gap(5);
    defer d.end();
    label(c, k, name);
    _ = ui.textField(c, buffer, .{ .placeholder = placeholder, .width = .fill, .size = 13, .password = password });
    if (description.len > 0) ui.text(c, description, .{ .size = 11, .color = k.tertiary });
}

fn area(c: *ui.Context, k: theme.Colors, name: []const u8, buffer: *ui.TextBuffer, placeholder: []const u8, lines: u8, description: []const u8) void {
    const d = ui.div(c).column().wFull().gap(5);
    defer d.end();
    label(c, k, name);
    _ = ui.textArea(c, buffer, .{ .placeholder = placeholder, .width = .fill, .size = 13, .min_lines = lines, .max_lines = lines });
    if (description.len > 0) ui.text(c, description, .{ .size = 11, .color = k.tertiary });
}

fn switchField(c: *ui.Context, k: theme.Colors, name: []const u8, value: *bool, description: []const u8) void {
    const d = ui.div(c).column().wFull().gap(5);
    defer d.end();
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        label(c, k, name);
        _ = ui.toggle(c, "", value);
        r.end();
    }
    if (description.len > 0) ui.text(c, description, .{ .size = 11, .color = k.tertiary });
}
