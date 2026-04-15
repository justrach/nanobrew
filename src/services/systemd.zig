// nanobrew — systemd service management (Linux)
//
// Discovers and controls systemd services for installed packages.
// Scans Cellar for .service files.

const std = @import("std");
const paths = @import("../platform/paths.zig");

pub const Service = struct {
    name: []const u8,
    label: []const u8,
    plist_path: []const u8, // actually .service path — named for API compat
    keg_name: []const u8,
    keg_version: []const u8,
};

pub fn discoverServices(alloc: std.mem.Allocator) ![]Service {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var services: std.ArrayList(Service) = .empty;
    defer services.deinit(alloc);

    var cellar = std.Io.Dir.openDirAbsolute(lib_io, paths.CELLAR_DIR, .{ .iterate = true }) catch return try services.toOwnedSlice(alloc);
    defer cellar.close(lib_io);

    var keg_iter = cellar.iterate();
    while (keg_iter.next(lib_io) catch null) |keg_entry| {
        if (keg_entry.kind != .directory) continue;
        const keg_name = keg_entry.name;

        var keg_dir_buf: [512]u8 = undefined;
        const keg_dir_path = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ paths.CELLAR_DIR, keg_name }) catch continue;
        var keg_dir = std.Io.Dir.openDirAbsolute(lib_io, keg_dir_path, .{ .iterate = true }) catch continue;
        defer keg_dir.close(lib_io);

        var ver_iter = keg_dir.iterate();
        while (ver_iter.next(lib_io) catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            const ver_name = ver_entry.name;

            // Search for .service files in lib/systemd/system/ and etc/systemd/system/
            const search_paths = [_][]const u8{
                "lib/systemd/system",
                "etc/systemd/system",
            };

            for (search_paths) |sub| {
                var search_buf: [1024]u8 = undefined;
                const search_path = std.fmt.bufPrint(&search_buf, "{s}/{s}/{s}", .{ keg_dir_path, ver_name, sub }) catch continue;

                var search_dir = std.Io.Dir.openDirAbsolute(lib_io, search_path, .{ .iterate = true }) catch continue;
                defer search_dir.close(lib_io);

                var file_iter = search_dir.iterate();
                while (file_iter.next(lib_io) catch null) |file_entry| {
                    if (file_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, file_entry.name, ".service")) continue;

                    // Label is full unit name (e.g. "postgresql@14-main.service")
                    const label = file_entry.name;
                    // Service name strips .service suffix
                    const svc_name = file_entry.name[0 .. file_entry.name.len - ".service".len];

                    var svc_path_buf: [1024]u8 = undefined;
                    const svc_path = std.fmt.bufPrint(&svc_path_buf, "{s}/{s}", .{ search_path, file_entry.name }) catch continue;

                    services.append(alloc, .{
                        .name = alloc.dupe(u8, svc_name) catch continue,
                        .label = alloc.dupe(u8, label) catch continue,
                        .plist_path = alloc.dupe(u8, svc_path) catch continue,
                        .keg_name = alloc.dupe(u8, keg_name) catch continue,
                        .keg_version = alloc.dupe(u8, ver_name) catch continue,
                    }) catch {};
                }
            }
        }
    }

    return try services.toOwnedSlice(alloc);
}

pub fn isRunning(alloc: std.mem.Allocator, label: []const u8) bool {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var unit_buf: [256]u8 = undefined;
    const unit = if (std.mem.endsWith(u8, label, ".service")) label else std.fmt.bufPrint(&unit_buf, "{s}.service", .{label}) catch return false;
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "is-active", "--quiet", unit },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return switch (result.term) { .exited => |c| c == 0, else => false };
}

pub fn start(alloc: std.mem.Allocator, plist_path: []const u8) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    // Install the service file and start it
    const basename = std.fs.path.basename(plist_path);
    var dest_buf: [512]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "/etc/systemd/system/{s}", .{basename}) catch return error.PathTooLong;

    // Copy service file to systemd directory
    const cp = std.process.run(alloc, lib_io, .{
        .argv = &.{ "cp", plist_path, dest },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(cp.stdout);
    alloc.free(cp.stderr);

    // Reload and start
    const reload = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "daemon-reload" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(reload.stdout);
    alloc.free(reload.stderr);

    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "start", basename },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.SystemdFailed;
}

pub fn stop(alloc: std.mem.Allocator, plist_path: []const u8) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const basename = std.fs.path.basename(plist_path);
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "systemctl", "stop", basename },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.SystemdFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.SystemdFailed;
}
