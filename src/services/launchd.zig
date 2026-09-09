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

pub fn discoverServices(alloc: std.mem.Allocator, io: std.Io) ![]Service {
    var services: std.ArrayList(Service) = .empty;
    defer services.deinit(alloc);
    const lib_io = io;

    var cellar = std.Io.Dir.openDirAbsolute(lib_io, paths.CELLAR_DIR, .{ .iterate = true }) catch return try services.toOwnedSlice(alloc);
    defer cellar.close(lib_io);

    var keg_iter = cellar.iterate();
    while (keg_iter.next(lib_io) catch null) |keg_entry| {
        if (keg_entry.kind != .directory) continue;
        if (keg_entry.name.len == 0 or keg_entry.name[0] == '.') continue; // skip .purge/
        const keg_name = keg_entry.name;

        var keg_dir_buf: [512]u8 = undefined;
        const keg_dir_path = std.fmt.bufPrint(&keg_dir_buf, "{s}/{s}", .{ paths.CELLAR_DIR, keg_name }) catch continue;
        var keg_dir = std.Io.Dir.openDirAbsolute(lib_io, keg_dir_path, .{ .iterate = true }) catch continue;
        defer keg_dir.close(lib_io);

        var ver_iter = keg_dir.iterate();
        while (ver_iter.next(lib_io) catch null) |ver_entry| {
            if (ver_entry.kind != .directory) continue;
            const ver_name = ver_entry.name;

            const search_paths = [_][]const u8{ "", "homebrew.mxcl" };

            for (search_paths) |sub| {
                var search_buf: [1024]u8 = undefined;
                const search_path = if (sub.len > 0)
                    std.fmt.bufPrint(&search_buf, "{s}/{s}/{s}", .{ keg_dir_path, ver_name, sub }) catch continue
                else
                    std.fmt.bufPrint(&search_buf, "{s}/{s}", .{ keg_dir_path, ver_name }) catch continue;

                var search_dir = std.Io.Dir.openDirAbsolute(lib_io, search_path, .{ .iterate = true }) catch continue;
                defer search_dir.close(lib_io);

                var file_iter = search_dir.iterate();
                while (file_iter.next(lib_io) catch null) |file_entry| {
                    if (file_entry.kind != .file) continue;
                    if (!std.mem.endsWith(u8, file_entry.name, ".plist")) continue;
                    if (!std.mem.startsWith(u8, file_entry.name, "homebrew.mxcl.")) continue;

                    const label = file_entry.name[0 .. file_entry.name.len - 6];
                    const svc_name = if (label.len > 14) label[14..] else label;

                    var plist_buf: [1024]u8 = undefined;
                    const plist_path = std.fmt.bufPrint(&plist_buf, "{s}/{s}", .{ search_path, file_entry.name }) catch continue;

                    // All-or-nothing: if any dupe or the append fails,
                    // free everything we already allocated for this entry
                    // so we never leak a partial Service.
                    const name_owned = alloc.dupe(u8, svc_name) catch continue;
                    const label_owned = alloc.dupe(u8, label) catch {
                        alloc.free(name_owned);
                        continue;
                    };
                    const plist_path_owned = alloc.dupe(u8, plist_path) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        continue;
                    };
                    const keg_name_owned = alloc.dupe(u8, keg_name) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        alloc.free(plist_path_owned);
                        continue;
                    };
                    const keg_version_owned = alloc.dupe(u8, ver_name) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        alloc.free(plist_path_owned);
                        alloc.free(keg_name_owned);
                        continue;
                    };
                    services.append(alloc, .{
                        .name = name_owned,
                        .label = label_owned,
                        .plist_path = plist_path_owned,
                        .keg_name = keg_name_owned,
                        .keg_version = keg_version_owned,
                    }) catch {
                        alloc.free(name_owned);
                        alloc.free(label_owned);
                        alloc.free(plist_path_owned);
                        alloc.free(keg_name_owned);
                        alloc.free(keg_version_owned);
                    };
                }
            }
        }
    }

    return try services.toOwnedSlice(alloc);
}

pub fn isRunning(alloc: std.mem.Allocator, io: std.Io, label: []const u8) bool {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "launchctl", "list", label },
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

pub fn isPlistSafe(content: []const u8, keg_prefix: []const u8) bool {
    return isPlistSafeImpl(null, content, keg_prefix);
}

fn executableWithin(io: ?std.Io, path: []const u8, root: []const u8) bool {
    if (io) |lib_io| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPathFile(lib_io, path, &path_buf) catch return false;
        const r = std.Io.Dir.cwd().realPathFile(lib_io, root, &root_buf) catch return false;
        return executableWithin(null, path_buf[0..n], root_buf[0..r]);
    }
    return std.mem.startsWith(u8, path, root) and path.len > root.len and
        path[root.len] == '/' and std.mem.indexOf(u8, path, "..") == null;
}

fn isPlistSafeImpl(io: ?std.Io, content: []const u8, keg_prefix: []const u8) bool {
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
                    if (!executableWithin(io, prog_path, keg_prefix)) return false;
                }
            }
        }
    }

    // Check Program — single <string> value must also start with keg_prefix
    if (std.mem.indexOf(u8, content, "<key>Program</key>")) |idx| {
        const after = content[idx..];
        if (std.mem.indexOf(u8, after, "<string>")) |s_idx| {
            const str_start = s_idx + "<string>".len;
            if (str_start < after.len) {
                const rest = after[str_start..];
                if (std.mem.indexOf(u8, rest, "</string>")) |end| {
                    const prog_path = rest[0..end];
                    if (!executableWithin(io, prog_path, keg_prefix)) return false;
                }
            }
        }
    }

    return true;
}

pub fn start(alloc: std.mem.Allocator, io: std.Io, plist_path: []const u8) !void {
    const lib_io = io;

    // Read and validate the plist file before loading
    const plist_file = std.Io.Dir.openFileAbsolute(lib_io, plist_path, .{}) catch return error.LaunchctlFailed;
    const plist_stat = plist_file.stat(lib_io) catch {
        plist_file.close(lib_io);
        return error.LaunchctlFailed;
    };
    const plist_size = @min(plist_stat.size, 64 * 1024);
    const plist_buf = alloc.alloc(u8, plist_size) catch {
        plist_file.close(lib_io);
        return error.LaunchctlFailed;
    };
    defer alloc.free(plist_buf);
    const plist_n = plist_file.readPositionalAll(lib_io, plist_buf, 0) catch {
        plist_file.close(lib_io);
        return error.LaunchctlFailed;
    };
    plist_file.close(lib_io);
    const plist_content = plist_buf[0..plist_n];

    if (!isPlistSafeImpl(lib_io, plist_content, paths.CELLAR_DIR)) {
        var msg_buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "nb: refusing to load unsafe plist: {s}\n", .{plist_path}) catch "nb: refusing to load unsafe plist\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
        return error.LaunchctlFailed;
    }

    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "launchctl", "load", "-w", plist_path },
    }) catch return error.LaunchctlFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.LaunchctlFailed;
}

pub fn stop(alloc: std.mem.Allocator, io: std.Io, plist_path: []const u8) !void {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "launchctl", "unload", "-w", plist_path },
    }) catch return error.LaunchctlFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) return error.LaunchctlFailed;
}

test "launchd follows chained symlinks and rejects escapes (#374)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const setup = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "sh", "-eu", "-c", "mkdir -p Cellar/pkg/1/bin Cellar/pkg/1/libexec/bin opt; touch Cellar/pkg/1/libexec/bin/daemon outside; ln -s ../Cellar/pkg/1 opt/pkg; ln -s ../libexec/bin/daemon Cellar/pkg/1/bin/daemon; ln -s ../../../../outside Cellar/pkg/1/bin/escape" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer std.testing.allocator.free(setup.stdout);
    defer std.testing.allocator.free(setup.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, setup.term);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..n];
    const cellar = try std.fmt.allocPrint(std.testing.allocator, "{s}/Cellar", .{root});
    defer std.testing.allocator.free(cellar);
    for ([_][]const u8{ "daemon", "escape", "missing" }, 0..) |bin, i| {
        const plist = try std.fmt.allocPrint(std.testing.allocator, "<key>ProgramArguments</key><array><string>{s}/opt/pkg/bin/{s}</string></array>", .{ root, bin });
        defer std.testing.allocator.free(plist);
        try std.testing.expectEqual(i == 0, isPlistSafeImpl(io, plist, cellar));
    }
    try std.testing.expect(!executableWithin(null, "/tmp/Cellar-other/bin/tool", "/tmp/Cellar"));
}
