// nanobrew - opt-in scheduled self-update support

const std = @import("std");
const builtin = @import("builtin");
const paths = @import("platform/paths.zig");

pub const Mode = enum {
    self,
    upgrade,
};

pub const Status = struct {
    installed: bool,
    loaded: bool,
};

const label = "ai.trilok.nanobrew.autoupdate";
const systemd_service = "nanobrew-autoupdate.service";
const systemd_timer = "nanobrew-autoupdate.timer";

/// Start each action separately so upgrade uses the replacement executable.
pub fn run(alloc: std.mem.Allocator, exe_path: []const u8, mode: Mode) !u8 {
    _ = alloc;
    const io = paths.safe_io;
    for ([_][]const u8{ "update", "upgrade" }, 0..) |command, i| {
        if (i == 1 and mode != .upgrade) break;
        var child = try std.process.spawn(io, .{ .argv = &.{ exe_path, command } });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| if (code != 0) {
                return code;
            },
            else => return error.CommandFailed,
        }
    }
    return 0;
}

pub fn enable(alloc: std.mem.Allocator, exe_path: []const u8, mode: Mode) !void {
    switch (builtin.os.tag) {
        .macos => try enableLaunchd(alloc, exe_path, mode),
        .linux => try enableSystemd(alloc, exe_path, mode),
        else => return error.UnsupportedPlatform,
    }
}

pub fn disable(alloc: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .macos => try disableLaunchd(alloc),
        .linux => try disableSystemd(alloc),
        else => return error.UnsupportedPlatform,
    }
}

pub fn status(alloc: std.mem.Allocator) !Status {
    return switch (builtin.os.tag) {
        .macos => try statusLaunchd(alloc),
        .linux => try statusSystemd(alloc),
        else => error.UnsupportedPlatform,
    };
}

pub fn schedulePath(alloc: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => try launchdPlistPath(alloc),
        .linux => try systemdTimerPath(alloc),
        else => error.UnsupportedPlatform,
    };
}

fn enableLaunchd(alloc: std.mem.Allocator, exe_path: []const u8, mode: Mode) !void {
    const plist_path = try launchdPlistPath(alloc);
    defer alloc.free(plist_path);

    const launch_agents = try launchdDir(alloc);
    defer alloc.free(launch_agents);
    try ensureDir(launch_agents);

    const home = try homeDir(alloc);
    defer alloc.free(home);
    const log_dir = try std.fmt.allocPrint(alloc, "{s}/Library/Logs/nanobrew", .{home});
    defer alloc.free(log_dir);
    try ensureDir(log_dir);
    const escaped_exe = try escape(alloc, exe_path, .xml);
    defer alloc.free(escaped_exe);
    const escaped_log = try escape(alloc, log_dir, .xml);
    defer alloc.free(escaped_log);
    const extra_arg = if (mode == .upgrade) "\n        <string>--upgrade</string>" else "";
    const plist = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\        <string>autoupdate</string>
        \\        <string>run</string>{s}
        \\    </array>
        \\    <key>StartCalendarInterval</key>
        \\    <dict>
        \\        <key>Hour</key>
        \\        <integer>3</integer>
        \\        <key>Minute</key>
        \\        <integer>0</integer>
        \\    </dict>
        \\    <key>StandardOutPath</key>
        \\    <string>{s}/autoupdate.log</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>{s}/autoupdate.err</string>
        \\</dict>
        \\</plist>
        \\
    , .{ label, escaped_exe, extra_arg, escaped_log, escaped_log });
    defer alloc.free(plist);

    try writeFile(plist_path, plist);
    _ = runQuiet(alloc, &.{ "launchctl", "unload", "-w", plist_path }) catch false;
    if (!try runQuiet(alloc, &.{ "launchctl", "load", "-w", plist_path })) return error.LaunchctlFailed;
}

fn disableLaunchd(alloc: std.mem.Allocator) !void {
    const plist_path = try launchdPlistPath(alloc);
    defer alloc.free(plist_path);

    if (!fileExists(plist_path)) return;
    const loaded = try runQuiet(alloc, &.{ "launchctl", "list", label });
    if (loaded and !try runQuiet(alloc, &.{ "launchctl", "unload", "-w", plist_path })) return error.LaunchctlFailed;
    try deleteFileIfExists(plist_path);
}

fn statusLaunchd(alloc: std.mem.Allocator) !Status {
    const plist_path = try launchdPlistPath(alloc);
    defer alloc.free(plist_path);
    return .{
        .installed = fileExists(plist_path),
        .loaded = runQuiet(alloc, &.{ "launchctl", "list", label }) catch false,
    };
}

fn enableSystemd(alloc: std.mem.Allocator, exe_path: []const u8, mode: Mode) !void {
    try ensureSystemdDirs(alloc);

    const service_path = try systemdServicePath(alloc);
    defer alloc.free(service_path);
    const timer_path = try systemdTimerPath(alloc);
    defer alloc.free(timer_path);

    const escaped_exe = try escape(alloc, exe_path, .systemd);
    defer alloc.free(escaped_exe);
    const extra_arg = if (mode == .upgrade) " --upgrade" else "";
    const service_body = try std.fmt.allocPrint(alloc,
        \\[Unit]
        \\Description=nanobrew auto-update
        \\
        \\[Service]
        \\Type=oneshot
        \\ExecStart="{s}" autoupdate run{s}
        \\
    , .{ escaped_exe, extra_arg });
    defer alloc.free(service_body);

    const timer_body =
        \\[Unit]
        \\Description=Run nanobrew auto-update daily
        \\
        \\[Timer]
        \\OnCalendar=*-*-* 03:00:00
        \\Persistent=true
        \\Unit=nanobrew-autoupdate.service
        \\
        \\[Install]
        \\WantedBy=timers.target
        \\
    ;

    try writeFile(service_path, service_body);
    try writeFile(timer_path, timer_body);

    if (!try runQuiet(alloc, &.{ "systemctl", "--user", "daemon-reload" })) return error.SystemdFailed;
    if (!try runQuiet(alloc, &.{ "systemctl", "--user", "enable", "--now", systemd_timer })) return error.SystemdFailed;
}

fn disableSystemd(alloc: std.mem.Allocator) !void {
    const service_path = try systemdServicePath(alloc);
    defer alloc.free(service_path);
    const timer_path = try systemdTimerPath(alloc);
    defer alloc.free(timer_path);

    if (!fileExists(timer_path) and !fileExists(service_path)) return;
    if (!try runQuiet(alloc, &.{ "systemctl", "--user", "disable", "--now", systemd_timer })) return error.SystemdFailed;
    try deleteFileIfExists(timer_path);
    try deleteFileIfExists(service_path);
    if (!try runQuiet(alloc, &.{ "systemctl", "--user", "daemon-reload" })) return error.SystemdFailed;
}

fn statusSystemd(alloc: std.mem.Allocator) !Status {
    const timer_path = try systemdTimerPath(alloc);
    defer alloc.free(timer_path);
    return .{
        .installed = fileExists(timer_path),
        .loaded = runQuiet(alloc, &.{ "systemctl", "--user", "is-enabled", "--quiet", systemd_timer }) catch false,
    };
}

fn launchdDir(alloc: std.mem.Allocator) ![]const u8 {
    const home = try homeDir(alloc);
    defer alloc.free(home);
    return try std.fmt.allocPrint(alloc, "{s}/Library/LaunchAgents", .{home});
}

fn launchdPlistPath(alloc: std.mem.Allocator) ![]const u8 {
    const dir = try launchdDir(alloc);
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/{s}.plist", .{ dir, label });
}

fn systemdUserDir(alloc: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |value| {
        const config = std.mem.span(value);
        if (std.fs.path.isAbsolute(config)) return std.fmt.allocPrint(alloc, "{s}/systemd/user", .{config});
    }
    const home = try homeDir(alloc);
    defer alloc.free(home);
    return std.fmt.allocPrint(alloc, "{s}/.config/systemd/user", .{home});
}

fn systemdServicePath(alloc: std.mem.Allocator) ![]const u8 {
    const dir = try systemdUserDir(alloc);
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, systemd_service });
}

fn systemdTimerPath(alloc: std.mem.Allocator) ![]const u8 {
    const dir = try systemdUserDir(alloc);
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, systemd_timer });
}

fn ensureSystemdDirs(alloc: std.mem.Allocator) !void {
    const dir = try systemdUserDir(alloc);
    defer alloc.free(dir);
    try ensureDir(dir);
}

fn homeDir(alloc: std.mem.Allocator) ![]const u8 {
    const home = std.c.getenv("HOME") orelse return error.HomeMissing;
    if (!std.fs.path.isAbsolute(std.mem.span(home))) return error.InvalidHome;
    return try alloc.dupe(u8, std.mem.span(home));
}

fn ensureDir(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(paths.safe_io, path);
}

fn writeFile(path: []const u8, body: []const u8) !void {
    const io = paths.safe_io;
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

fn deleteFileIfExists(path: []const u8) !void {
    const io = paths.safe_io;
    std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn fileExists(path: []const u8) bool {
    const io = paths.safe_io;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn runQuiet(alloc: std.mem.Allocator, argv: []const []const u8) !bool {
    const result = try std.process.run(alloc, paths.safe_io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const Escape = enum { xml, systemd };
fn escape(alloc: std.mem.Allocator, value: []const u8, kind: Escape) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (value) |c| {
        if (c < 32 or c == 127) return error.InvalidPath;
        const replacement: ?[]const u8 = switch (kind) {
            .xml => switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => null,
            },
            .systemd => switch (c) {
                '%' => "%%",
                '$' => "$$",
                '"' => "\\\"",
                '\\' => "\\\\",
                else => null,
            },
        };
        if (replacement) |r| try out.appendSlice(alloc, r) else try out.append(alloc, c);
    }
    return out.toOwnedSlice(alloc);
}

test "scheduler paths escape markup and systemd expansions" {
    const a = std.testing.allocator;
    const xml = try escape(a, "/Users/A & B/<nb>", .xml);
    defer a.free(xml);
    try std.testing.expectEqualStrings("/Users/A &amp; B/&lt;nb&gt;", xml);
    const unit = try escape(a, "/home/50%/$nb", .systemd);
    defer a.free(unit);
    try std.testing.expectEqualStrings("/home/50%%/$$nb", unit);
    try std.testing.expectError(error.InvalidPath, escape(a, "bad\npath", .systemd));
}
