// nanobrew — Mach-O relocator
//
// Homebrew bottles embed @@HOMEBREW_PREFIX@@ and @@HOMEBREW_CELLAR@@
// placeholders in Mach-O load commands. This module replaces them with
// the real nanobrew paths using install_name_tool, then re-signs with
// ad-hoc codesign so the binaries work under macOS code-signing enforcement.
//
// Optimization: only walks bin/, lib/, sbin/, libexec/ — not share/, include/, etc.
// Files are real COW copies (via cp -c), so no symlink materialization needed.

const std = @import("std");

const CELLAR_DIR = "/opt/nanobrew/prefix/Cellar";
const PREFIX = "/opt/nanobrew/prefix";

const PLACEHOLDER_PREFIX = "@@HOMEBREW_PREFIX@@";
const PLACEHOLDER_CELLAR = "@@HOMEBREW_CELLAR@@";

const REAL_PREFIX = PREFIX;
const REAL_CELLAR = PREFIX ++ "/Cellar";

const MH_MAGIC_64: u32 = 0xFEEDFACF;
const MH_MAGIC_32: u32 = 0xFEEDFACE;
const FAT_MAGIC: u32 = 0xCAFEBABE;
const FAT_CIGAM: u32 = 0xBEBAFECA;
const MH_CIGAM_64: u32 = 0xCFFAEDFE;
const MH_CIGAM_32: u32 = 0xCEFAEDFE;

// Only walk directories that can contain Mach-O files
const MACHO_DIRS = [_][]const u8{ "bin", "sbin", "lib", "libexec" };

/// Relocate all Mach-O files in a keg, replacing Homebrew placeholders
/// with nanobrew paths. Only scans bin/, lib/, sbin/, libexec/.
pub fn relocateKeg(alloc: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    // Only walk directories likely to contain Mach-O files
    for (MACHO_DIRS) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocate(alloc, sub_path) catch {};
    }
}

fn walkAndRelocate(alloc: std.mem.Allocator, dir_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => {
                walkAndRelocate(alloc, child_path) catch {};
            },
            .file => {
                if (isMachO(child_path)) {
                    relocateFile(alloc, child_path) catch {};
                }
            },
            // Files are real COW copies (via cp -c), not symlinks.
            // No symlink materialization needed.
            else => {},
        }
    }
}

fn isMachO(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var magic: [4]u8 = undefined;
    const n = file.read(&magic) catch return false;
    if (n < 4) return false;

    const val = std.mem.readInt(u32, &magic, .big);
    return val == MH_MAGIC_64 or val == MH_MAGIC_32 or
        val == FAT_MAGIC or val == FAT_CIGAM or
        val == MH_CIGAM_64 or val == MH_CIGAM_32;
}

fn relocateFile(alloc: std.mem.Allocator, path: []const u8) !void {
    if (!binaryContainsPlaceholders(path)) return;

    const result = runProcess(alloc, &.{ "otool", "-l", path }) catch return;
    defer alloc.free(result);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    argv.append(alloc, "install_name_tool") catch return;

    var to_free: std.ArrayList([]u8) = .empty;
    defer {
        for (to_free.items) |s| alloc.free(s);
        to_free.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, result, '\n');
    var current_cmd: enum { none, load_dylib, id_dylib, rpath } = .none;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "cmd LC_LOAD_DYLIB") or
            std.mem.startsWith(u8, trimmed, "cmd LC_LOAD_WEAK_DYLIB") or
            std.mem.startsWith(u8, trimmed, "cmd LC_REEXPORT_DYLIB"))
        {
            current_cmd = .load_dylib;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "cmd LC_ID_DYLIB")) {
            current_cmd = .id_dylib;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "cmd LC_RPATH")) {
            current_cmd = .rpath;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "cmd ")) {
            current_cmd = .none;
            continue;
        }

        if ((current_cmd == .load_dylib or current_cmd == .id_dylib) and
            std.mem.startsWith(u8, trimmed, "name "))
        {
            const after_name = trimmed[5..];
            const paren = std.mem.indexOf(u8, after_name, " (") orelse continue;
            const dylib_path = after_name[0..paren];

            if (std.mem.indexOf(u8, dylib_path, PLACEHOLDER_PREFIX) != null or
                std.mem.indexOf(u8, dylib_path, PLACEHOLDER_CELLAR) != null)
            {
                const new_path = replacePlaceholders(alloc, dylib_path) catch continue;
                to_free.append(alloc, new_path) catch continue;

                if (current_cmd == .load_dylib) {
                    argv.append(alloc, "-change") catch continue;
                    argv.append(alloc, dylib_path) catch continue;
                    argv.append(alloc, new_path) catch continue;
                } else {
                    argv.append(alloc, "-id") catch continue;
                    argv.append(alloc, new_path) catch continue;
                }
            }
            current_cmd = .none;
        }

        if (current_cmd == .rpath and std.mem.startsWith(u8, trimmed, "path ")) {
            const after_path = trimmed[5..];
            const paren = std.mem.indexOf(u8, after_path, " (") orelse continue;
            const rpath = after_path[0..paren];

            if (std.mem.indexOf(u8, rpath, PLACEHOLDER_PREFIX) != null or
                std.mem.indexOf(u8, rpath, PLACEHOLDER_CELLAR) != null)
            {
                const new_rpath = replacePlaceholders(alloc, rpath) catch continue;
                to_free.append(alloc, new_rpath) catch continue;

                argv.append(alloc, "-rpath") catch continue;
                argv.append(alloc, rpath) catch continue;
                argv.append(alloc, new_rpath) catch continue;
            }
            current_cmd = .none;
        }
    }

    if (argv.items.len > 1) {
        argv.append(alloc, path) catch return;
        _ = runProcess(alloc, argv.items) catch {};
        _ = runProcess(alloc, &.{ "codesign", "-f", "-s", "-", path }) catch {};
    }
}

fn replacePlaceholders(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const pass1 = try std.mem.replaceOwned(u8, alloc, input, PLACEHOLDER_CELLAR, REAL_CELLAR);
    defer alloc.free(pass1);
    return try std.mem.replaceOwned(u8, alloc, pass1, PLACEHOLDER_PREFIX, REAL_PREFIX);
}

fn runProcess(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = child.stdout.?;
    const output = stdout.readToEndAlloc(alloc, 1024 * 1024) catch return error.ReadFailed;

    const term = child.wait() catch return error.WaitFailed;
    if (term.Exited != 0) {
        alloc.free(output);
        return error.ProcessFailed;
    }

    return output;
}

fn binaryContainsPlaceholders(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    const needle = "@@HOMEBREW";
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    while (true) {
        if (overlap > 0) {
            const src = buf[buf.len - overlap ..];
            std.mem.copyForwards(u8, buf[0..overlap], src);
        }
        const n = file.read(buf[overlap..]) catch return false;
        if (n == 0) break;
        const total = overlap + n;
        if (std.mem.indexOf(u8, buf[0..total], needle) != null) return true;
        overlap = @min(needle.len - 1, total);
    }
    return false;
}
