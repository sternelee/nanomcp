//! Starting at login, on macOS: a LaunchAgent beside the user's other login
//! items, pointing at this executable. launchd reads that folder when the
//! user logs in, so the file is the whole setting — nothing else has to be
//! told, and none of the system's own registration has to succeed first.
//!
//! The file is written by name, so the app must not be moved afterwards: a
//! stale path is fixed by turning the switch off and on again.
const std = @import("std");

/// Names the login item to the system; the app's bundle identifier.
pub const label = "com.justrach.nanomcp";

/// The file launchd looks for, inside the LaunchAgents folder.
pub fn fileName() []const u8 {
    return label ++ ".plist";
}

/// `<home>/Library/LaunchAgents`: where a user's own login items live.
pub fn dirPath(a: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ home, "Library", "LaunchAgents" });
}

/// The login item itself: this executable, started when the user logs in to
/// a desktop session, and not restarted if it is quit afterwards.
pub fn plist(a: std.mem.Allocator, exe: []const u8) ![]u8 {
    const escaped = try escapeXml(a, exe);
    defer a.free(escaped);
    return std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>LimitLoadToSessionType</key>
        \\    <string>Aqua</string>
        \\</dict>
        \\</plist>
        \\
    , .{ label, escaped });
}

/// XML has five characters that cannot stand for themselves, and a path may
/// hold any of them.
fn escapeXml(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for (s) |ch| switch (ch) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        else => try out.append(a, ch),
    };
    return out.toOwnedSlice(a);
}

/// Whether the login item is in place. A folder that cannot be opened has
/// none, which is also what it means.
pub fn enabled(io: std.Io, dir: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return false;
    defer d.close(io);
    _ = d.statFile(io, fileName(), .{}) catch return false;
    return true;
}

/// Puts the login item in place, or takes it away. The plist is written under
/// a temporary name and renamed, so a write that dies part-way leaves the
/// old file (or none) rather than half of one.
pub fn setEnabled(io: std.Io, a: std.mem.Allocator, dir: []const u8, exe: []const u8, on: bool) !void {
    if (dir.len == 0) return error.NoLoginItems;
    const path = try std.fs.path.join(a, &.{ dir, fileName() });
    defer a.free(path);

    if (!on) {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return;
    }

    const body = try plist(a, exe);
    defer a.free(body);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const tmp = try std.fs.path.join(a, &.{ dir, label ++ ".plist.tmp" });
    defer a.free(tmp);
    var file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .permissions = @enumFromInt(0o644) });
    file.writeStreamingAll(io, body) catch |err| {
        file.close(io);
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    file.close(io);
    // A relative test directory is renamed within the working directory;
    // renameAbsolute would refuse it, a bare rename takes both.
    std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
}

test "a login item names the executable and only runs at login" {
    const a = std.testing.allocator;
    const body = try plist(a, "/Applications/nanomcp.app/Contents/MacOS/nanomcp");
    defer a.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "<string>com.justrach.nanomcp</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<string>/Applications/nanomcp.app/Contents/MacOS/nanomcp</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<key>RunAtLoad</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<string>Aqua</string>") != null);
    // Not KeepAlive: quitting the app is meant to keep it quit.
    try std.testing.expect(std.mem.indexOf(u8, body, "KeepAlive") == null);
}

test "a path with XML's own characters is escaped, not pasted in" {
    const a = std.testing.allocator;
    const body = try plist(a, "/Users/ann & bob/<dev>/nanomcp");
    defer a.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "/Users/ann &amp; bob/&lt;dev&gt;/nanomcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ann & bob") == null);
}

test "the login item lives in the user's LaunchAgents folder" {
    const a = std.testing.allocator;
    const dir = try dirPath(a, "/Users/ann");
    defer a.free(dir);
    try std.testing.expectEqualStrings("/Users/ann/Library/LaunchAgents", dir);
    try std.testing.expectEqualStrings("com.justrach.nanomcp.plist", fileName());
}

test "turning the login item on writes it, and off takes the file away" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sub: []const u8 = &tmp.sub_path;
    const dir = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", sub, "LaunchAgents" });
    defer a.free(dir);

    try std.testing.expect(!enabled(std.testing.io, dir));
    try setEnabled(std.testing.io, a, dir, "/opt/nanomcp", true);
    try std.testing.expect(enabled(std.testing.io, dir));

    const path = try std.fs.path.join(a, &.{ dir, fileName() });
    defer a.free(path);
    const body = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4096));
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "<string>/opt/nanomcp</string>") != null);
    // No temporary file is left beside it.
    const tmp_path = try std.fs.path.join(a, &.{ dir, "com.justrach.nanomcp.plist.tmp" });
    defer a.free(tmp_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, tmp_path, .{}));

    try setEnabled(std.testing.io, a, dir, "/opt/nanomcp", false);
    try std.testing.expect(!enabled(std.testing.io, dir));
    // Turning it off twice is not an error.
    try setEnabled(std.testing.io, a, dir, "/opt/nanomcp", false);
}

test "a build with nowhere to put a login item says so instead of writing one" {
    try std.testing.expectError(
        error.NoLoginItems,
        setEnabled(std.testing.io, std.testing.allocator, "", "/opt/nanomcp", true),
    );
}
