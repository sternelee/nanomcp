//! What the Servers page does: the actions its buttons, menu and dialogs
//! carry out, kept out of the drawing code.
const std = @import("std");
const nanoui = @import("nanoui");
const config = @import("config.zig");
const import_mod = @import("import.zig");
const oauth = @import("oauth.zig");
const editor = @import("editor.zig");
const state_mod = @import("state.zig");

const App = state_mod.App;

/// Opens the form for a new server, ready to paste a token into.
pub fn addServer(s: *App) void {
    s.servers.form.reset();
    s.servers.form_error = "";
    s.servers.focus_form = true;
    s.servers.menu = null;
    // The modal is keyed by the new server's id, which is not in the
    // configuration until the form is saved.
    s.servers.editing = config.newId(s.cfgAlloc(), s.io) catch {
        s.notify("could not make a server id", true);
        return;
    };
    s.redisplay();
}

/// Opens the form for an existing server, filled from it and its credentials.
pub fn editServer(s: *App, id: []const u8) void {
    const sc = s.cfg.server(id) orelse return;
    const cc = s.creds.client(s.gpa, sc.id);
    const has_token = s.creds.hasUpstreamToken(s.gpa, sc.id);
    s.servers.form.load(sc, cc, has_token);
    s.servers.form_error = "";
    s.servers.focus_form = true;
    s.servers.editing = sc.id;
    s.servers.menu = null;
    s.redisplay();
}

/// The server a form's modal edits: one from the configuration, or an empty
/// one when it is being added.
pub fn targetOf(s: *App, id: []const u8) ?config.ServerConfig {
    if (s.cfg.server(id)) |sc| return sc;
    if (s.servers.form.mode == .add) return .{ .id = id, .enabled = true };
    return null;
}

/// Validates the form, stores the server and whatever goes with it: a token
/// belongs in the credential store, never in the settings file.
pub fn saveForm(s: *App, target: config.ServerConfig) void {
    const edited = s.servers.form.save(s.cfgAlloc(), target) catch |e| {
        s.servers.form_error = @errorName(e);
        return;
    };
    if (config.ServerConfig.validateMessage(s.cfgAlloc(), edited)) |message| {
        s.servers.form_error = message;
        return;
    }
    s.servers.form_error = "";
    s.cfg.upsert(s.cfgAlloc(), edited) catch return;
    _ = s.cfg.ensureAliases(s.cfgAlloc()) catch false;
    s.save();

    if (edited.oauth) {
        const client_id = std.mem.trim(u8, s.servers.form.client_id.text(), " \t\r\n");
        oauth.setClientCredentials(s.gw, s.gpa, edited.id, client_id, s.servers.form.client_secret.text()) catch {
            s.servers.form_error = "Could not save credentials.";
            return;
        };
    } else {
        const token = std.mem.trim(u8, s.servers.form.token.text(), " \t\r\n");
        if (token.len > 0) {
            s.creds.setUpstreamToken(s.gpa, edited.id, token) catch {
                s.servers.form_error = "Could not save the token.";
                return;
            };
        }
    }

    s.gw.refreshCredentials();
    s.servers.editing = null;
    revealServer(s, edited.id);
    var toast_buf: [256]u8 = undefined;
    s.notify(std.fmt.bufPrint(&toast_buf, "{s} saved", .{edited.name}) catch "saved", false);
    s.resync();
}

/// Clears the filter and selects a server, so one that was just added or
/// edited is the row in view.
pub fn revealServer(s: *App, id: []const u8) void {
    s.servers.filter.clear();
    for (s.cfg.servers, 0..) |sc, i| {
        if (std.mem.eql(u8, sc.id, id)) {
            s.servers.selected = i;
            return;
        }
    }
    s.servers.selected = 0;
}

/// Switches a server on or off and stores the choice.
pub fn setEnabled(s: *App, id: []const u8, to: bool) void {
    const a = s.cfgAlloc();
    var new_list = std.ArrayList(config.ServerConfig).empty;
    defer new_list.deinit(a);
    for (s.cfg.servers) |sc| {
        var copy = sc;
        if (std.mem.eql(u8, sc.id, id)) copy.enabled = to;
        new_list.append(a, copy) catch return;
    }
    s.cfg.servers = new_list.toOwnedSlice(a) catch return;
    s.save();
    s.resync();
}

/// Switches a server on and connects it, or tries again when it is already
/// switched on but not connected.
pub fn connect(s: *App, id: []const u8) void {
    const sc = s.cfg.server(id) orelse return;
    if (sc.enabled) {
        reconnect(s, id);
        return;
    }
    setEnabled(s, id, true);
}

/// Drops a server's connection and leaves it off, so it is not connected
/// again at the next launch either.
pub fn disconnect(s: *App, id: []const u8) void {
    setEnabled(s, id, false);
}

/// Drops a server's connection and connects it again.
pub fn reconnect(s: *App, id: []const u8) void {
    if (id.len == 0 or s.window == null) return;
    s.gw.reconnectAsync(id);
}

/// Starts an OAuth sign-in and opens the browser at the authorization URL.
pub fn signIn(s: *App, id: []const u8) void {
    if (s.window == null) return;
    const url = oauth.beginAuth(s.gw, s.gpa, id) catch |err| {
        const text = switch (err) {
            error.NoSuchServer => "that server is gone",
            error.NotOAuth => "this server does not sign in with OAuth",
            error.NotServing => "start the gateway first, so that your browser can come back to it",
            error.NoOAuthDetails => "the server requires authorization but sent no OAuth details",
            // A refused sign-in leaves the reason on the server's row; say it
            // rather than the generic sentence.
            else => if (s.gw.errorOf(id).len > 0) s.gw.errorOf(id) else "the sign-in could not be started",
        };
        s.notify(text, true);
        return;
    };
    defer s.gpa.free(url);
    if (url.len == 0) {
        s.notify("Already signed in", false);
        return;
    }
    _ = nanoui.shell.openUrl(url);
    s.notify("Finish signing in in your browser", false);
}

/// Forgets a server's OAuth token, so the next connection asks to sign in
/// again, and reconnects it.
pub fn signOut(s: *App, id: []const u8) void {
    if (s.window == null) return;
    const sc = s.cfg.server(id) orelse return;
    s.creds.signOut(s.gpa, sc.id) catch {};
    s.gw.markSignedIn(sc.id, false);
    s.gw.note(sc.name, "signed out", false);
    s.gw.reconnectAsync(sc.id);
}

/// Removes a server's saved static token.
pub fn forgetToken(s: *App, id: []const u8) void {
    if (id.len == 0) return;
    s.creds.setUpstreamToken(s.gpa, id, "") catch {};
    s.servers.form.has_token = false;
    s.servers.form.token.clear();
    s.notify("The saved token was forgotten", false);
    reconnect(s, id);
}

/// Forgets a server and everything stored for it.
pub fn removeServer(s: *App, id: []const u8) void {
    const sc = s.cfg.server(id) orelse {
        s.servers.removing = null;
        return;
    };
    const enabled = sc.enabled;
    _ = s.cfg.remove(s.cfgAlloc(), id) catch false;
    s.save();
    s.creds.signOut(s.gpa, id) catch {};
    s.creds.setUpstreamToken(s.gpa, id, "") catch {};
    s.gw.markSignedIn(id, false);
    s.servers.removing = null;
    s.servers.menu = null;
    if (s.servers.editing) |editing| {
        if (std.mem.eql(u8, editing, id)) s.servers.editing = null;
    }
    if (enabled) s.resync() else s.redisplay();
    var toast_buf: [256]u8 = undefined;
    s.notify(std.fmt.bufPrint(&toast_buf, "{s} removed", .{sc.name}) catch "removed", false);
}

/// Opens the paste-a-configuration dialog.
pub fn openImport(s: *App) void {
    s.servers.import_open = true;
    s.servers.import_text.clear();
    s.servers.import_error = "";
    s.servers.focus_import = true;
    s.servers.menu = null;
    s.redisplay();
}

/// Parses the pasted configuration and adds the servers it holds.
pub fn doImport(s: *App) void {
    const parsed = import_mod.parse(s.cfgAlloc(), s.servers.import_text.text()) catch {
        s.servers.import_error = "That is not valid JSON.";
        return;
    };
    switch (parsed) {
        .failed => |message| {
            s.servers.import_error = message;
        },
        .servers => |servers| {
            const result = import_mod.importServers(s.cfgAlloc(), s.io, &s.cfg, servers) catch {
                s.servers.import_error = "The import could not be saved.";
                return;
            };
            s.save();
            s.servers.import_open = false;
            s.servers.import_text.clear();
            s.servers.import_error = "";
            s.resync();
            const summary = result.summary(s.gpa) catch null;
            defer if (summary) |text| s.gpa.free(text);
            s.notify(summary orelse "Imported", false);
        },
    }
}
