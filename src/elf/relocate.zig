// nanobrew — ELF relocator for Linux
//
// Mirrors the Mach-O relocator architecture:
// 1. Detect ELF files (0x7f ELF magic)
// 2. Parse ELF headers natively to check for placeholders
// 3. Use patchelf --set-rpath when changes needed
// 4. Replace placeholders in .pc, .cmake, .la text files
// 5. No codesign step (Linux doesn't need it)

const std = @import("std");
const placeholder = @import("../platform/placeholder.zig");
const paths = @import("../platform/paths.zig");

const ELF_DIRS = [_][]const u8{ "bin", "sbin", "lib", "lib64", "libexec" };

// ELF magic: 0x7f 'E' 'L' 'F'
const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };

// Text config file extensions that may contain placeholders
const TEXT_EXTS = [_][]const u8{ ".pc", ".cmake", ".la", ".sh", ".cfg" };

fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// Check whether `patchelf --version` runs successfully. Public so callers can
/// fail fast on Linux installs *before* downloading anything.
pub fn hasPatchelf(alloc: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "patchelf", "--version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

/// Relocate all ELF files and text configs in a keg.
pub fn relocateKeg(alloc: std.mem.Allocator, io: std.Io, name: []const u8, version: []const u8) !void {
    if (!hasPatchelf(alloc, io)) {
        writeStderr(io, "nb: patchelf not found — attempting auto-install...\n");

        // Try without sudo first (works in containers/root), then with sudo
        const install_cmds = [_][]const []const u8{
            &.{ "apt-get", "install", "-y", "patchelf" },
            &.{ "dnf", "install", "-y", "patchelf" },
            &.{ "yum", "install", "-y", "patchelf" },
            &.{ "apk", "add", "--no-cache", "patchelf" },
            &.{ "pacman", "-S", "--noconfirm", "patchelf" },
            &.{ "sudo", "apt-get", "install", "-y", "patchelf" },
            &.{ "sudo", "dnf", "install", "-y", "patchelf" },
            &.{ "sudo", "yum", "install", "-y", "patchelf" },
            &.{ "sudo", "apk", "add", "--no-cache", "patchelf" },
            &.{ "sudo", "pacman", "-S", "--noconfirm", "patchelf" },
        };
        for (install_cmds) |cmd| {
            const result = std.process.run(alloc, io, .{
                .argv = cmd,
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
            }) catch continue;
            alloc.free(result.stdout);
            alloc.free(result.stderr);
            if (result.term == .exited and result.term.exited == 0) break;
        }

        // Always recheck — handles race condition in parallel installs
        if (!hasPatchelf(alloc, io)) {
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "nb: {s}: could not install patchelf — ELF binary relocation skipped\n", .{name})) |msg| {
                writeStderr(io, msg);
            } else |_| {}
            if (std.fmt.bufPrint(&buf, "nb: install patchelf manually (e.g. apt install patchelf) and re-run: nb reinstall {s}\n", .{name})) |msg| {
                writeStderr(io, msg);
            } else |_| {}
            return error.PatchelfNotFound;
        }
        writeStderr(io, "nb: patchelf installed successfully\n");
    }

    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;

    // Walk standard directories for ELF binaries
    for (ELF_DIRS) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocate(alloc, io, sub_path) catch {};
    }

    // Also relocate text config files in lib/pkgconfig, lib/cmake, etc.
    const text_dirs = [_][]const u8{ "lib/pkgconfig", "lib/cmake", "share/pkgconfig", "lib64/pkgconfig" };
    for (text_dirs) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocateText(io, sub_path) catch {};
    }

    // Also check .la files in lib/ directly
    var lib_buf: [512]u8 = undefined;
    const lib_path = std.fmt.bufPrint(&lib_buf, "{s}/lib", .{keg_dir}) catch return;
    relocateLaFiles(io, lib_path) catch {};
}

fn walkAndRelocate(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => walkAndRelocate(alloc, io, child_path) catch {},
            .file => relocateFile(alloc, io, child_path),
            else => {},
        }
    }
}

fn walkAndRelocateText(io: std.Io, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            var child_buf: [2048]u8 = undefined;
            const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            walkAndRelocateText(io, child_path) catch {};
            continue;
        }
        if (entry.kind != .file) continue;

        for (TEXT_EXTS) |ext| {
            if (std.mem.endsWith(u8, entry.name, ext)) {
                var path_buf: [2048]u8 = undefined;
                const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch break;
                _ = placeholder.relocateTextFile(io, file_path);
                break;
            }
        }
    }
}

fn relocateLaFiles(io: std.Io, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".la")) continue;
        var path_buf: [2048]u8 = undefined;
        const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        _ = placeholder.relocateTextFile(io, file_path);
    }
}

fn relocateFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);

    // Read ELF header to detect format
    var header: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return;
    if (n < 16) return;
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) return;

    // Always attempt interpreter fixup — bottles may have hardcoded
    // /home/linuxbrew/.linuxbrew/ paths without @@HOMEBREW markers
    patchInterpreter(alloc, io, path);

    // Only do rpath/needed if placeholders are present (saves subprocess cost)
    if (!elfContainsPlaceholder(io, file)) return;

    patchelfRelocateRpathAndNeeded(alloc, io, path);
}

fn elfContainsPlaceholder(io: std.Io, file: std.Io.File) bool {
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    const needle = "@@HOMEBREW";
    while (true) {
        if (overlap > 0) {
            const src = buf[buf.len - overlap ..];
            std.mem.copyForwards(u8, buf[0..overlap], src);
        }
        const n = file.readStreaming(io, &.{buf[overlap..]}) catch return false;
        if (n == 0) break;
        const total = overlap + n;
        if (std.mem.indexOf(u8, buf[0..total], needle) != null) return true;
        overlap = @min(needle.len - 1, total);
    }
    return false;
}

fn patchelfRelocateRpathAndNeeded(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    // 1. Fix RPATH
    const rpath_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--print-rpath", path } }) catch return;
    defer alloc.free(rpath_result.stderr);
    defer alloc.free(rpath_result.stdout);

    if (rpath_result.term == .exited and rpath_result.term.exited == 0) {
        const current_rpath = std.mem.trim(u8, rpath_result.stdout, " \t\n\r");
        if (current_rpath.len > 0 and placeholder.hasPlaceholder(current_rpath)) {
            const new_rpath = placeholder.replacePlaceholders(alloc, current_rpath) catch return;
            defer alloc.free(new_rpath);

            const set_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--set-rpath", new_rpath, path } }) catch return;
            alloc.free(set_result.stdout);
            alloc.free(set_result.stderr);
        }
    }

    // 2. Fix DT_NEEDED entries with placeholders
    const needed_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--print-needed", path } }) catch return;
    defer alloc.free(needed_result.stderr);

    var lines_iter = std.mem.splitScalar(u8, needed_result.stdout, '\n');
    while (lines_iter.next()) |line| {
        const lib = std.mem.trim(u8, line, " \t\r");
        if (lib.len == 0) continue;
        if (placeholder.hasPlaceholder(lib)) {
            const new_lib = placeholder.replacePlaceholders(alloc, lib) catch continue;
            defer alloc.free(new_lib);
            const replace_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--replace-needed", lib, new_lib, path } }) catch continue;
            alloc.free(replace_result.stdout);
            alloc.free(replace_result.stderr);
        }
    }
    alloc.free(needed_result.stdout);
}

fn patchInterpreter(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--print-interpreter", path } }) catch return;
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);

    if (result.term != .exited or result.term.exited != 0) return; // not an executable (shared lib)

    const current = std.mem.trim(u8, result.stdout, " \t\n\r");
    if (!placeholder.hasPlaceholder(current)) {
        // Also fix hardcoded Linuxbrew interpreter paths (no @@HOMEBREW marker)
        const linuxbrew_prefix = "/home/linuxbrew/.linuxbrew/";
        if (!std.mem.startsWith(u8, current, linuxbrew_prefix)) return;
        // Fall through to detectInterpreter for the correct system path
    } else if (placeholder.replacePlaceholders(alloc, current)) |resolved| {
        defer alloc.free(resolved);
        if (std.Io.Dir.accessAbsolute(io, resolved, .{})) |_| {
            const set_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--set-interpreter", resolved, path } }) catch return;
            alloc.free(set_result.stdout);
            alloc.free(set_result.stderr);
            return;
        } else |_| {}
    } else |_| {}

    const new_interp = detectInterpreter(io, path) orelse return;

    const set_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--set-interpreter", new_interp, path } }) catch return;
    alloc.free(set_result.stdout);
    alloc.free(set_result.stderr);
}

/// Read the ELF e_machine field to pick the correct dynamic linker for the
/// binary's actual architecture (not the architecture nb was compiled for).
fn detectInterpreter(io: std.Io, path: []const u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var header: [20]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return null;
    if (n < 20) return null;
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) return null;

    // e_machine is at offset 18, little-endian u16
    const e_machine = std.mem.readInt(u16, header[18..20], .little);
    return switch (e_machine) {
        0xB7 => "/lib/ld-linux-aarch64.so.1", // EM_AARCH64
        0x3E => "/lib64/ld-linux-x86-64.so.2", // EM_X86_64
        0x03 => "/lib/ld-linux.so.2", // EM_386
        else => null,
    };
}
