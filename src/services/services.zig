// nanobrew — Service management
//
// Discovers and controls launchctl services for installed packages.
// Scans Cellar for homebrew.mxcl.*.plist files.

const std = @import("std");

const CELLAR_DIR = "/opt/nanobrew/prefix/Cellar";

pub const Service = struct {
    name: []const u8,
    label: []const u8,
    plist_path: []const u8,
    keg_name: []const u8,
    keg_version: []const u8,
};

pub fn discoverServices(alloc: std.mem.Allocator) ![]Service {
    var services: std.ArrayList(Service) = .empty;
    defer services.deinit(alloc);

    // Scan Cellar for installed kegs
    var cellar = std.fs.openDirAbsolute(CELLAR_DIR, .{ .iterate = true }) catch return try services.toOwnedSlice(alloc);
    defer cellar.close();

    var keg_iter = cellar.iterate();
    while (keg_iter.next() catch null) |keg_entry| {
        if (keg_entry.kind != .directory) continue;
        const keg_name = keg_entry.name;

        // Open keg dir to find version subdirs
        var keg_dir_buf: [512]u8 = undefined;
        const keg_dir_path = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ CELLAR_DIR, keg_name }) catch continue;
        var keg_dir = std.fs.openDirAbsolute(keg_dir_path, .{ .iterate = true }) catch continue;
        defer keg_dir.close();

        var ver_iter = keg_dir.iterate();
        while (ver_iter.next() catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            const ver_name = ver_entry.name;

            // Look for plist files in common locations
            const search_paths = [_][]const u8{
                "", // root of version dir
                "homebrew.mxcl",
            };

            for (search_paths) |sub| {
                var search_buf: [1024]u8 = undefined;
                const search_path = if (sub.len > 0)
                    std.fmt.bufPrint(&search_buf, "{s}/{s}/{s}", .{ keg_dir_path, ver_name, sub }) catch continue
                else
                    std.fmt.bufPrint(&search_buf, "{s}/{s}", .{ keg_dir_path, ver_name }) catch continue;

                var search_dir = std.fs.openDirAbsolute(search_path, .{ .iterate = true }) catch continue;
                defer search_dir.close();

                var file_iter = search_dir.iterate();
                while (file_iter.next() catch null) |file_entry| {
                    if (file_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, file_entry.name, ".plist")) continue;
                    if (!std.mem.startsWith(u8, file_entry.name, "homebrew.mxcl.")) continue;

                    // Extract label from filename (strip .plist)
                    const label = file_entry.name[0 .. file_entry.name.len - 6]; // strip ".plist"

                    // Extract service name from label (strip "homebrew.mxcl.")
                    const svc_name = if (label.len > 14) label[14..] else label;

                    var plist_buf: [1024]u8 = undefined;
                    const plist_path = std.fmt.bufPrint(&plist_buf, "{s}/{s}", .{ search_path, file_entry.name }) catch continue;

                    services.append(alloc, .{
                        .name = alloc.dupe(u8, svc_name) catch continue,
                        .label = alloc.dupe(u8, label) catch continue,
                        .plist_path = alloc.dupe(u8, plist_path) catch continue,
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
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "launchctl", "list", label },
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term.Exited == 0;
}

pub fn start(alloc: std.mem.Allocator, plist_path: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "launchctl", "load", "-w", plist_path },
    }) catch return error.LaunchctlFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (result.term.Exited != 0) return error.LaunchctlFailed;
}

pub fn stop(alloc: std.mem.Allocator, plist_path: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "launchctl", "unload", "-w", plist_path },
    }) catch return error.LaunchctlFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (result.term.Exited != 0) return error.LaunchctlFailed;
}
