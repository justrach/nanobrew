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

/// Relocate all ELF files and text configs in a keg.
pub fn relocateKeg(alloc: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    hasPatchelf(alloc) catch |err| switch (err) {
        error.PatchelfNotFound => {
            relocateKegWithoutPatchelf(alloc, name, version) catch {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("nb: {s}: patchelf not found; install it and rerun `nb reinstall {s}`\n", .{ name, name }) catch {};
                return error.PatchelfNotFound;
            };
            return;
        },
        else => return err,
    };

    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;

    // Walk standard directories for ELF binaries
    for (ELF_DIRS) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocate(alloc, sub_path) catch {};
    }

    // Also relocate text config files in lib/pkgconfig, lib/cmake, etc.
    const text_dirs = [_][]const u8{ "lib/pkgconfig", "lib/cmake", "share/pkgconfig", "lib64/pkgconfig" };
    for (text_dirs) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocateText(sub_path) catch {};
    }

    // Also check .la files in lib/ directly
    var lib_buf: [512]u8 = undefined;
    const lib_path = std.fmt.bufPrint(&lib_buf, "{s}/lib", .{keg_dir}) catch return;
    relocateLaFiles(lib_path) catch {};
}

fn relocateKegWithoutPatchelf(alloc: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;

    var unresolved_any = false;

    for (ELF_DIRS) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocateWithoutPatchelf(alloc, sub_path, &unresolved_any) catch {};
    }

    const text_dirs = [_][]const u8{ "lib/pkgconfig", "lib/cmake", "share/pkgconfig", "lib64/pkgconfig" };
    for (text_dirs) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocateText(sub_path) catch {};
    }

    var lib_buf: [512]u8 = undefined;
    const lib_path = std.fmt.bufPrint(&lib_buf, "{s}/lib", .{keg_dir}) catch return;
    relocateLaFiles(lib_path) catch {};

    if (unresolved_any) return error.PatchelfNotFound;
}

fn hasPatchelf(alloc: std.mem.Allocator) !void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "patchelf", "--version" },
    }) catch return error.PatchelfNotFound;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.PatchelfNotFound;
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
            .directory => walkAndRelocate(alloc, child_path) catch {},
            .file => relocateFile(alloc, child_path),
            else => {},
        }
    }
}

fn walkAndRelocateWithoutPatchelf(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    unresolved_any: *bool,
) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => walkAndRelocateWithoutPatchelf(alloc, child_path, unresolved_any) catch {},
            .file => {
                const result = relocateFileWithoutPatchelf(alloc, child_path);
                unresolved_any.* = unresolved_any.* or result.unresolved;
            },
            else => {},
        }
    }
}

fn walkAndRelocateText(dir_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            var child_buf: [2048]u8 = undefined;
            const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            walkAndRelocateText(child_path) catch {};
            continue;
        }
        if (entry.kind != .file) continue;

        for (TEXT_EXTS) |ext| {
            if (std.mem.endsWith(u8, entry.name, ext)) {
                var path_buf: [2048]u8 = undefined;
                const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch break;
                _ = placeholder.relocateTextFile(file_path);
                break;
            }
        }
    }
}

fn relocateLaFiles(dir_path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".la")) continue;
        var path_buf: [2048]u8 = undefined;
        const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        _ = placeholder.relocateTextFile(file_path);
    }
}

fn relocateFile(alloc: std.mem.Allocator, path: []const u8) void {
    var file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();

    // Read ELF header to detect format
    var header: [16]u8 = undefined;
    const n = file.read(&header) catch return;
    if (n < 16) return;
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) return;

    // It's an ELF file — check if it contains placeholders
    file.seekTo(0) catch return;
    if (!elfContainsPlaceholder(file)) return;

    // Use patchelf to fix rpath
    patchelfRelocate(alloc, path);
}

const NativeRelocateResult = struct {
    unresolved: bool = false,
};

fn relocateFileWithoutPatchelf(alloc: std.mem.Allocator, path: []const u8) NativeRelocateResult {
    var result = NativeRelocateResult{};

    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch return result;
    defer file.close();

    var header: [16]u8 = undefined;
    const n = file.read(&header) catch return result;
    if (n < 16) return result;
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) return result;

    file.seekTo(0) catch return result;
    const data = file.readToEndAlloc(alloc, 32 * 1024 * 1024) catch return result;
    defer alloc.free(data);

    if (std.mem.indexOf(u8, data, "@@HOMEBREW") == null) return result;

    const interp = detectInterpreterFromBytes(data) orelse {
        result.unresolved = true;
        return result;
    };

    if (!replaceElfPlaceholderStringsInPlace(data, interp)) {
        result.unresolved = true;
        return result;
    }

    file.seekTo(0) catch return result;
    file.writeAll(data) catch return result;

    if (std.mem.indexOf(u8, data, "@@HOMEBREW") != null) {
        result.unresolved = true;
    }
    return result;
}

fn replaceElfPlaceholderStringsInPlace(data: []u8, interp: []const u8) bool {
    var i: usize = 0;
    while (i < data.len) {
        const end_rel = std.mem.indexOfScalar(u8, data[i..], 0) orelse break;
        const end = i + end_rel;
        if (end > i and std.mem.indexOf(u8, data[i..end], "@@HOMEBREW") != null) {
            const src = data[i..end];
            var buf: [8192]u8 = undefined;
            if (src.len > buf.len) return false;
            const replaced = replaceElfString(buf[0..src.len], src, interp) orelse return false;
            @memset(data[i..end], 0);
            @memcpy(data[i..][0..replaced.len], replaced);
        }
        i = end + 1;
    }
    return true;
}

fn replaceElfString(buf: []u8, src: []const u8, interp: []const u8) ?[]const u8 {
    const interp_placeholder = "@@HOMEBREW_PREFIX@@/lib/ld.so";

    var out_len: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], interp_placeholder)) {
            if (out_len + interp.len > buf.len) return null;
            @memcpy(buf[out_len..][0..interp.len], interp);
            out_len += interp.len;
            i += interp_placeholder.len;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], paths.PLACEHOLDER_PREFIX)) {
            if (out_len + paths.ELF_FALLBACK_PREFIX.len > buf.len) return null;
            @memcpy(buf[out_len..][0..paths.ELF_FALLBACK_PREFIX.len], paths.ELF_FALLBACK_PREFIX);
            out_len += paths.ELF_FALLBACK_PREFIX.len;
            i += paths.PLACEHOLDER_PREFIX.len;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], paths.PLACEHOLDER_REPOSITORY)) {
            if (out_len + paths.ELF_FALLBACK_REPOSITORY.len > buf.len) return null;
            @memcpy(buf[out_len..][0..paths.ELF_FALLBACK_REPOSITORY.len], paths.ELF_FALLBACK_REPOSITORY);
            out_len += paths.ELF_FALLBACK_REPOSITORY.len;
            i += paths.PLACEHOLDER_REPOSITORY.len;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], paths.PLACEHOLDER_CELLAR)) return null;
        if (out_len >= buf.len) return null;
        buf[out_len] = src[i];
        out_len += 1;
        i += 1;
    }
    return buf[0..out_len];
}

fn elfContainsPlaceholder(file: std.fs.File) bool {
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    const needle = "@@HOMEBREW";
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

fn patchelfRelocate(alloc: std.mem.Allocator, path: []const u8) void {
    // 1. Fix interpreter (PT_INTERP) — critical for executables
    patchInterpreter(alloc, path);

    // 2. Fix RPATH
    const rpath_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "patchelf", "--print-rpath", path },
    }) catch return;
    defer alloc.free(rpath_result.stderr);
    defer alloc.free(rpath_result.stdout);

    if (rpath_result.term == .Exited and rpath_result.term.Exited == 0) {
        const current_rpath = std.mem.trim(u8, rpath_result.stdout, " \t\n\r");
        if (current_rpath.len > 0 and placeholder.hasPlaceholder(current_rpath)) {
            const new_rpath = placeholder.replacePlaceholders(alloc, current_rpath) catch return;
            defer alloc.free(new_rpath);

            const set_result = std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{ "patchelf", "--set-rpath", new_rpath, path },
            }) catch return;
            alloc.free(set_result.stdout);
            alloc.free(set_result.stderr);
        }
    }

    // 3. Fix DT_NEEDED entries with placeholders
    const needed_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "patchelf", "--print-needed", path },
    }) catch return;
    defer alloc.free(needed_result.stderr);

    var lines_iter = std.mem.splitScalar(u8, needed_result.stdout, '\n');
    while (lines_iter.next()) |line| {
        const lib = std.mem.trim(u8, line, " \t\r");
        if (lib.len == 0) continue;
        if (placeholder.hasPlaceholder(lib)) {
            const new_lib = placeholder.replacePlaceholders(alloc, lib) catch continue;
            defer alloc.free(new_lib);
            const replace_result = std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{ "patchelf", "--replace-needed", lib, new_lib, path },
            }) catch continue;
            alloc.free(replace_result.stdout);
            alloc.free(replace_result.stderr);
        }
    }
    alloc.free(needed_result.stdout);
}

fn patchInterpreter(alloc: std.mem.Allocator, path: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "patchelf", "--print-interpreter", path },
    }) catch return;
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);

    if (result.term != .Exited or result.term.Exited != 0) return; // not an executable (shared lib)

    const current = std.mem.trim(u8, result.stdout, " \t\n\r");
    if (!placeholder.hasPlaceholder(current)) return;

    if (placeholder.replacePlaceholders(alloc, current)) |resolved| {
        defer alloc.free(resolved);
        if (std.fs.accessAbsolute(resolved, .{})) |_| {
            const set_result = std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{ "patchelf", "--set-interpreter", resolved, path },
            }) catch return;
            alloc.free(set_result.stdout);
            alloc.free(set_result.stderr);
            return;
        } else |_| {}
    } else |_| {}

    const new_interp = detectInterpreter(path) orelse return;

    const set_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "patchelf", "--set-interpreter", new_interp, path },
    }) catch return;
    alloc.free(set_result.stdout);
    alloc.free(set_result.stderr);
}

/// Read the ELF e_machine field to pick the correct dynamic linker for the
/// binary's actual architecture (not the architecture nb was compiled for).
fn detectInterpreter(path: []const u8) ?[]const u8 {
    var file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var header: [20]u8 = undefined;
    const n = file.read(&header) catch return null;
    if (n < 20) return null;
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) return null;

    // e_machine is at offset 18, little-endian u16
    const e_machine = std.mem.readInt(u16, header[18..20], .little);
    return interpreterForMachine(e_machine);
}

fn detectInterpreterFromBytes(data: []const u8) ?[]const u8 {
    if (data.len < 20) return null;
    if (!std.mem.eql(u8, data[0..4], &ELF_MAGIC)) return null;
    const e_machine = std.mem.readInt(u16, data[18..20], .little);
    return interpreterForMachine(e_machine);
}

fn interpreterForMachine(e_machine: u16) ?[]const u8 {
    return switch (e_machine) {
        0xB7 => "/lib/ld-linux-aarch64.so.1", // EM_AARCH64
        0x3E => "/lib64/ld-linux-x86-64.so.2", // EM_X86_64
        0x03 => "/lib/ld-linux.so.2", // EM_386
        else => null,
    };
}
