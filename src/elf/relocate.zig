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

fn printErr(lib_io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
}

fn run(alloc: std.mem.Allocator, lib_io: std.Io, argv: []const []const u8) ?std.process.RunResult {
    const r = std.process.run(alloc, lib_io, .{
        .argv = argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(4096),
    }) catch return null;
    return r;
}

/// Relocate all ELF files and text configs in a keg.
pub fn relocateKeg(alloc: std.mem.Allocator, io: std.Io, name: []const u8, version: []const u8) !void {
    const lib_io = io;
    hasPatchelf(alloc, lib_io) catch {
        printErr(lib_io, "nb: patchelf not found — attempting auto-install...\n", .{});

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
            if (run(alloc, lib_io, cmd)) |r| {
                const ok = switch (r.term) { .exited => |c| c == 0, else => false };
                alloc.free(r.stdout);
                alloc.free(r.stderr);
                if (ok) break;
            }
        }

        // Always recheck — handles race condition in parallel installs
        hasPatchelf(alloc, lib_io) catch {
            printErr(lib_io, "nb: {s}: could not install patchelf — ELF binary relocation skipped\n", .{name});
            printErr(lib_io, "nb: install patchelf manually (e.g. apt install patchelf) and re-run: nb reinstall {s}\n", .{name});
            return error.PatchelfNotFound;
        };
        printErr(lib_io, "nb: patchelf installed successfully\n", .{});
    };

    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;

    // Walk standard directories for ELF binaries
    for (ELF_DIRS) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocate(alloc, lib_io, sub_path) catch {};
    }

    // Also relocate text config files in lib/pkgconfig, lib/cmake, etc.
    const text_dirs = [_][]const u8{ "lib/pkgconfig", "lib/cmake", "share/pkgconfig", "lib64/pkgconfig" };
    for (text_dirs) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocateText(lib_io, sub_path) catch {};
    }

    // Also check .la files in lib/ directly
    var lib_buf: [512]u8 = undefined;
    const lib_path = std.fmt.bufPrint(&lib_buf, "{s}/lib", .{keg_dir}) catch return;
    relocateLaFiles(lib_io, lib_path) catch {};
}

fn hasPatchelf(alloc: std.mem.Allocator, lib_io: std.Io) !void {
    const r = std.process.run(alloc, lib_io, .{
        .argv = &.{ "patchelf", "--version" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return error.PatchelfNotFound;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (switch (r.term) { .exited => |c| c != 0, else => true }) return error.PatchelfNotFound;
}

fn walkAndRelocate(alloc: std.mem.Allocator, lib_io: std.Io, dir_path: []const u8) !void {
    if (std.Io.Dir.openDirAbsolute(lib_io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            var child_buf: [2048]u8 = undefined;
            const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            switch (entry.kind) {
                .directory => walkAndRelocate(alloc, lib_io, child_path) catch {},
                .file => relocateFile(alloc, lib_io, child_path),
                else => {},
            }
        }
        dir.close(lib_io);
    } else |_| {}
}

fn walkAndRelocateText(lib_io: std.Io, dir_path: []const u8) !void {
    if (std.Io.Dir.openDirAbsolute(lib_io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind == .directory) {
                var child_buf: [2048]u8 = undefined;
                const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
                walkAndRelocateText(lib_io, child_path) catch {};
                continue;
            }
            if (entry.kind != .file) continue;
            for (TEXT_EXTS) |ext| {
                if (std.mem.endsWith(u8, entry.name, ext)) {
                    var path_buf: [2048]u8 = undefined;
                    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch break;
                    _ = placeholder.relocateTextFile(lib_io, file_path);
                    break;
                }
            }
        }
        dir.close(lib_io);
    } else |_| {}
}

fn relocateLaFiles(lib_io: std.Io, dir_path: []const u8) !void {
    if (std.Io.Dir.openDirAbsolute(lib_io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".la")) continue;
            var path_buf: [2048]u8 = undefined;
            const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            _ = placeholder.relocateTextFile(lib_io, file_path);
        }
        dir.close(lib_io);
    } else |_| {}
}

fn relocateFile(alloc: std.mem.Allocator, lib_io: std.Io, path: []const u8) void {
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return;

    // Read ELF header to detect format
    var header: [16]u8 = undefined;
    const n = file.readPositionalAll(lib_io, &header, 0) catch { file.close(lib_io); return; };
    if (n < 16) { file.close(lib_io); return; }
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) { file.close(lib_io); return; }

    // It's an ELF file — check if it contains placeholders
    const has_placeholder = elfContainsPlaceholder(lib_io, file);
    file.close(lib_io);
    if (!has_placeholder) return;

    // Use patchelf to fix rpath
    patchelfRelocate(alloc, lib_io, path);
}

fn elfContainsPlaceholder(lib_io: std.Io, file: std.Io.File) bool {
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    const needle = "@@HOMEBREW";
    var offset: u64 = 0;
    while (true) {
        if (overlap > 0) {
            const src = buf[buf.len - overlap ..];
            std.mem.copyForwards(u8, buf[0..overlap], src);
        }
        const n = file.readPositionalAll(lib_io, buf[overlap..], offset) catch return false;
        if (n == 0) break;
        offset += @intCast(n);
        const total = overlap + n;
        if (std.mem.indexOf(u8, buf[0..total], needle) != null) return true;
        overlap = @min(needle.len - 1, total);
    }
    return false;
}

fn patchelfRelocate(alloc: std.mem.Allocator, lib_io: std.Io, path: []const u8) void {
    // 1. Fix interpreter (PT_INTERP) — critical for executables
    patchInterpreter(alloc, lib_io, path);

    // 2. Fix RPATH
    if (run(alloc, lib_io, &.{ "patchelf", "--print-rpath", path })) |rpath_result| {
        defer alloc.free(rpath_result.stderr);
        defer alloc.free(rpath_result.stdout);
        if (switch (rpath_result.term) { .exited => |c| c == 0, else => false }) {
            const current_rpath = std.mem.trim(u8, rpath_result.stdout, " \t\n\r");
            if (current_rpath.len > 0 and placeholder.hasPlaceholder(current_rpath)) {
                const new_rpath = placeholder.replacePlaceholders(alloc, current_rpath) catch return;
                defer alloc.free(new_rpath);
                if (run(alloc, lib_io, &.{ "patchelf", "--set-rpath", new_rpath, path })) |r| {
                    alloc.free(r.stdout);
                    alloc.free(r.stderr);
                }
            }
        }
    }

    // 3. Fix DT_NEEDED entries with placeholders
    const needed_result = run(alloc, lib_io, &.{ "patchelf", "--print-needed", path }) orelse return;
    defer alloc.free(needed_result.stderr);

    var lines_iter = std.mem.splitScalar(u8, needed_result.stdout, '\n');
    while (lines_iter.next()) |line| {
        const lib = std.mem.trim(u8, line, " \t\r");
        if (lib.len == 0) continue;
        if (placeholder.hasPlaceholder(lib)) {
            const new_lib = placeholder.replacePlaceholders(alloc, lib) catch continue;
            defer alloc.free(new_lib);
            if (run(alloc, lib_io, &.{ "patchelf", "--replace-needed", lib, new_lib, path })) |r| {
                alloc.free(r.stdout);
                alloc.free(r.stderr);
            }
        }
    }
    alloc.free(needed_result.stdout);
}

fn patchInterpreter(alloc: std.mem.Allocator, lib_io: std.Io, path: []const u8) void {
    const result = run(alloc, lib_io, &.{ "patchelf", "--print-interpreter", path }) orelse return;
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);

    if (switch (result.term) { .exited => |c| c != 0, else => true }) return;

    const current = std.mem.trim(u8, result.stdout, " \t\n\r");
    if (!placeholder.hasPlaceholder(current)) return;

    if (placeholder.replacePlaceholders(alloc, current)) |resolved| {
        defer alloc.free(resolved);
        if (std.Io.Dir.accessAbsolute(lib_io, resolved, .{})) |_| {
            if (run(alloc, lib_io, &.{ "patchelf", "--set-interpreter", resolved, path })) |r| {
                alloc.free(r.stdout);
                alloc.free(r.stderr);
            }
            return;
        } else |_| {}
    } else |_| {}

    const new_interp = detectInterpreter(lib_io, path) orelse return;
    if (run(alloc, lib_io, &.{ "patchelf", "--set-interpreter", new_interp, path })) |r| {
        alloc.free(r.stdout);
        alloc.free(r.stderr);
    }
}

/// Read the ELF e_machine field to pick the correct dynamic linker for the
/// binary's actual architecture (not the architecture nb was compiled for).
fn detectInterpreter(lib_io: std.Io, path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return null;

    var header: [20]u8 = undefined;
    const n = file.readPositionalAll(lib_io, &header, 0) catch { file.close(lib_io); return null; };
    file.close(lib_io);
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
