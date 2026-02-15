// nanobrew — Mach-O relocator
//
// Homebrew bottles embed @@HOMEBREW_PREFIX@@ and @@HOMEBREW_CELLAR@@
// placeholders in Mach-O load commands. This module replaces them with
// the real nanobrew paths using install_name_tool, then re-signs with
// ad-hoc codesign so the binaries work under macOS code-signing enforcement.

const std = @import("std");

const CELLAR_DIR = "/opt/nanobrew/prefix/Cellar";
const PREFIX = "/opt/nanobrew/prefix";

const PLACEHOLDER_PREFIX = "@@HOMEBREW_PREFIX@@";
const PLACEHOLDER_CELLAR = "@@HOMEBREW_CELLAR@@";

const REAL_PREFIX = PREFIX;
const REAL_CELLAR = PREFIX ++ "/Cellar";

// Mach-O magic numbers (little-endian on disk for native arm64/x86_64)
const MH_MAGIC_64: u32 = 0xFEEDFACF;
const MH_MAGIC_32: u32 = 0xFEEDFACE;
const FAT_MAGIC: u32 = 0xCAFEBABE;
const FAT_CIGAM: u32 = 0xBEBAFECA;
const MH_CIGAM_64: u32 = 0xCFFAEDFE;
const MH_CIGAM_32: u32 = 0xCEFAEDFE;

/// Relocate all Mach-O files in a keg, replacing Homebrew placeholders
/// with nanobrew paths.
pub fn relocateKeg(alloc: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    try walkAndRelocate(alloc, keg_dir);
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
            .sym_link => {
                // Cellar files are symlinks to the store. For Mach-O files,
                // we must replace the symlink with a real copy so
                // install_name_tool can modify it.
                if (isMachO(child_path)) {
                    materializeSymlink(child_path) catch continue;
                    relocateFile(alloc, child_path) catch {};
                }
            },
            else => {},
        }
    }
}

/// Replace a symlink with a copy of its target so the file can be modified in place.
fn materializeSymlink(path: []const u8) !void {
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsolute(path, &target_buf) catch return error.ReadLinkFailed;

    // Resolve relative symlinks against the parent directory
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source = if (std.fs.path.isAbsolute(target))
        target
    else blk: {
        const parent = std.fs.path.dirname(path) orelse return error.NoParent;
        break :blk std.fmt.bufPrint(&resolved_buf, "{s}/{s}", .{ parent, target }) catch return error.PathTooLong;
    };

    // Remove the symlink
    std.fs.deleteFileAbsolute(path) catch return error.DeleteFailed;
    // Copy the real file into its place
    std.fs.copyFileAbsolute(source, path, .{}) catch return error.CopyFailed;
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
    var did_change = false;

    // Phase 1: Fix LC_LOAD_DYLIB entries (linked libraries)
    {
        const result = runProcess(alloc, &.{ "otool", "-L", path }) catch return;
        defer alloc.free(result);

        var lines = std.mem.splitScalar(u8, result, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;

            // otool -L output: "\t/path/to/lib.dylib (compatibility ...)"
            // Extract the path before the " ("
            const paren = std.mem.indexOf(u8, trimmed, " (") orelse continue;
            const dylib_path = std.mem.trim(u8, trimmed[0..paren], " \t");

            if (std.mem.indexOf(u8, dylib_path, PLACEHOLDER_PREFIX) != null or
                std.mem.indexOf(u8, dylib_path, PLACEHOLDER_CELLAR) != null)
            {
                const new_path = replacePlaceholders(alloc, dylib_path) catch continue;
                defer alloc.free(new_path);

                _ = runProcess(alloc, &.{ "install_name_tool", "-change", dylib_path, new_path, path }) catch {};
                did_change = true;
            }
        }
    }

    // Phase 2: Fix LC_ID_DYLIB (the library's own install name)
    {
        const result = runProcess(alloc, &.{ "otool", "-D", path }) catch return;
        defer alloc.free(result);

        var lines = std.mem.splitScalar(u8, result, '\n');
        // Skip first line (filename header)
        _ = lines.next();
        if (lines.next()) |id_line| {
            const id = std.mem.trim(u8, id_line, " \t\n");
            if (id.len > 0 and
                (std.mem.indexOf(u8, id, PLACEHOLDER_PREFIX) != null or
                std.mem.indexOf(u8, id, PLACEHOLDER_CELLAR) != null))
            {
                const new_id = replacePlaceholders(alloc, id) catch return;
                defer alloc.free(new_id);

                _ = runProcess(alloc, &.{ "install_name_tool", "-id", new_id, path }) catch {};
                did_change = true;
            }
        }
    }

    // Phase 3: Fix LC_RPATH entries
    {
        const result = runProcess(alloc, &.{ "otool", "-l", path }) catch return;
        defer alloc.free(result);

        var lines = std.mem.splitScalar(u8, result, '\n');
        var in_rpath = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "cmd LC_RPATH")) {
                in_rpath = true;
                continue;
            }
            if (in_rpath and std.mem.startsWith(u8, trimmed, "path ")) {
                const after_path = trimmed[5..]; // skip "path "
                const paren = std.mem.indexOf(u8, after_path, " (") orelse continue;
                const rpath = after_path[0..paren];

                if (std.mem.indexOf(u8, rpath, PLACEHOLDER_PREFIX) != null or
                    std.mem.indexOf(u8, rpath, PLACEHOLDER_CELLAR) != null)
                {
                    const new_rpath = replacePlaceholders(alloc, rpath) catch continue;
                    defer alloc.free(new_rpath);

                    _ = runProcess(alloc, &.{ "install_name_tool", "-rpath", rpath, new_rpath, path }) catch {};
                    did_change = true;
                }
                in_rpath = false;
                continue;
            }
            if (in_rpath and std.mem.startsWith(u8, trimmed, "cmd ")) {
                in_rpath = false;
            }
        }
    }

    // Phase 4: Re-sign if anything changed
    if (did_change) {
        _ = runProcess(alloc, &.{ "codesign", "-f", "-s", "-", path }) catch {};
    }
}

fn replacePlaceholders(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    // Replace @@HOMEBREW_CELLAR@@ first (more specific, avoids partial match)
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
