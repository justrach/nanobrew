// nanobrew — launchd service management (macOS)
//
// Discovers and controls launchctl services for installed packages.
// Scans Cellar for homebrew.mxcl.*.plist files.

const std = @import("std");
const paths = @import("../platform/paths.zig");

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

    var cellar = std.fs.openDirAbsolute(paths.CELLAR_DIR, .{ .iterate = true }) catch return try services.toOwnedSlice(alloc);
    defer cellar.close();

    var keg_iter = cellar.iterate();
    while (keg_iter.next() catch null) |keg_entry| {
        if (keg_entry.kind != .directory) continue;
        const keg_name = keg_entry.name;

        var keg_dir_buf: [512]u8 = undefined;
        const keg_dir_path = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ paths.CELLAR_DIR, keg_name }) catch continue;
        var keg_dir = std.fs.openDirAbsolute(keg_dir_path, .{ .iterate = true }) catch continue;
        defer keg_dir.close();

        var ver_iter = keg_dir.iterate();
        while (ver_iter.next() catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            const ver_name = ver_entry.name;

            const search_paths = [_][]const u8{ "", "homebrew.mxcl" };

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

                    const label = file_entry.name[0 .. file_entry.name.len - 6];
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

pub fn isPlistSafe(content: []const u8, keg_prefix: []const u8) bool {
    // Check for UserName root
    if (std.mem.indexOf(u8, content, "<key>UserName</key>")) |idx| {
        const after = content[idx..];
        if (std.mem.indexOf(u8, after, "<string>root</string>")) |_| return false;
    }

    // Check ProgramArguments — first <string> after the key must start with keg_prefix
    if (std.mem.indexOf(u8, content, "<key>ProgramArguments</key>")) |idx| {
        const after = content[idx..];
        if (std.mem.indexOf(u8, after, "<string>")) |s_idx| {
            const str_start = s_idx + "<string>".len;
            if (str_start < after.len) {
                const rest = after[str_start..];
                if (std.mem.indexOf(u8, rest, "</string>")) |end| {
                    const prog_path = rest[0..end];
                    if (!std.mem.startsWith(u8, prog_path, keg_prefix)) return false;
                }
            }
        }
    }

    return true;
}

pub fn start(alloc: std.mem.Allocator, plist_path: []const u8) !void {
    const plist_content = std.fs.cwd().readFileAlloc(alloc, plist_path, 64 * 1024) catch return error.LaunchctlFailed;
    defer alloc.free(plist_content);
    if (!isPlistSafe(plist_content, paths.CELLAR_DIR)) {
        const err_writer = std.io.getStdErr().writer();
        err_writer.print("nb: refusing to load unsafe plist: {s}\n", .{plist_path}) catch {};
        return error.LaunchctlFailed;
    }
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
