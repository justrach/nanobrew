// nanobrew — Mach-O relocator (native header parsing, minimal subprocess spawns)
//
// Homebrew bottles embed @@HOMEBREW_PREFIX@@ and @@HOMEBREW_CELLAR@@
// placeholders in Mach-O load commands. This module:
//   1. Parses Mach-O headers natively (no otool subprocess)
//   2. Calls install_name_tool only when placeholders are found
//   3. Batches codesign into a single call for all modified binaries
//
// OLD: otool + install_name_tool + codesign = 3N process spawns
// NEW: install_name_tool + 1 codesign = N+1 process spawns (3x fewer)

const std = @import("std");
const paths = @import("../platform/paths.zig");
const ph = @import("../platform/placeholder.zig");

const CELLAR_DIR = paths.CELLAR_DIR;
const PREFIX = paths.PREFIX;

const PLACEHOLDER_PREFIX = paths.PLACEHOLDER_PREFIX;
const PLACEHOLDER_CELLAR = paths.PLACEHOLDER_CELLAR;

const REAL_PREFIX = paths.REAL_PREFIX;
const REAL_CELLAR = paths.REAL_CELLAR;

// Mach-O constants
const MH_MAGIC_64: u32 = 0xFEEDFACF;
const MH_CIGAM_64: u32 = 0xCFFAEDFE;
const FAT_MAGIC: u32 = 0xCAFEBABE;
const FAT_CIGAM: u32 = 0xBEBAFECA;

const LC_ID_DYLIB: u32 = 0x0D;
const LC_LOAD_DYLIB: u32 = 0x0C;
const LC_LOAD_WEAK_DYLIB: u32 = 0x80000018;
const LC_REEXPORT_DYLIB: u32 = 0x8000001F;
const LC_RPATH: u32 = 0x8000001C;

const MACHO_DIRS = [_][]const u8{ "bin", "sbin", "lib", "libexec", "Frameworks" };

/// Relocate all Mach-O files in a keg.
/// Collects modified files and codesigns them in a single batch call.
pub fn relocateKeg(alloc: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    var modified: std.ArrayList([]const u8) = .empty;
    defer {
        for (modified.items) |p| alloc.free(p);
        modified.deinit(alloc);
    }

    for (MACHO_DIRS) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocate(alloc, sub_path, &modified) catch {};
    }

    // Batch codesign all modified binaries in one call
    if (modified.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        argv.append(alloc, "codesign") catch return;
        argv.append(alloc, "-f") catch return;
        argv.append(alloc, "-s") catch return;
        argv.append(alloc, "-") catch return;
        for (modified.items) |p| argv.append(alloc, p) catch continue;

        const _io_k = std.Io.Threaded.global_single_threaded.io();
        if (std.process.run(alloc, _io_k, .{ .argv = argv.items, .stdout_limit = .limited(4096) })) |r| {
            alloc.free(r.stdout);
            alloc.free(r.stderr);
        } else |_| {}
    }
}

fn walkAndRelocate(alloc: std.mem.Allocator, dir_path: []const u8, modified: *std.ArrayList([]const u8)) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.openDirAbsolute(lib_io, dir_path, .{ .iterate = true }) catch return;

    var iter = dir.iterate();
    while (iter.next(lib_io) catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => walkAndRelocate(alloc, child_path, modified) catch {},
            .sym_link => {
                // Resolve symlink and process target if it's a Mach-O file
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_n = std.Io.Dir.readLinkAbsolute(lib_io, child_path, &target_buf) catch continue;
                const target = target_buf[0..target_n];
                const abs_target = if (target.len > 0 and target[0] == '/')
                    target
                else blk: {
                    // Relative symlink — resolve against parent directory
                    var resolve_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const last_slash = std.mem.lastIndexOf(u8, child_path, "/") orelse continue;
                    const resolved = std.fmt.bufPrint(&resolve_buf, "{s}/{s}", .{ child_path[0..last_slash], target }) catch continue;
                    break :blk resolved;
                };
                if (relocateFile(alloc, abs_target)) {
                    const dup = alloc.dupe(u8, abs_target) catch continue;
                    modified.append(alloc, dup) catch {
                        alloc.free(dup);
                        continue;
                    };
                }
            },
            .file => {
                if (relocateFile(alloc, child_path)) {
                    const dup = alloc.dupe(u8, child_path) catch continue;
                    modified.append(alloc, dup) catch {
                        alloc.free(dup);
                        continue;
                    };
                }
            },
            else => {},
        }
    }
    dir.close(lib_io);
}

/// Parse Mach-O headers natively and build install_name_tool args.
/// Returns true if the file was modified.
fn relocateFile(alloc: std.mem.Allocator, path: []const u8) bool {
    const lib_io_rf = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFileAbsolute(lib_io_rf, path, .{}) catch return false;

    // Read just the header region (load commands are in first ~32KB typically)
    var header_buf: [65536]u8 = undefined;
    const n = file.readPositional(lib_io_rf, &.{header_buf[0..]}, 0) catch {
        file.close(lib_io_rf);
        return false;
    };
    file.close(lib_io_rf);
    if (n < 32) return false;
    const data = header_buf[0..n];

    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != MH_MAGIC_64) {
        // Check for fat binary — use fallback scan
        const magic_be = std.mem.readInt(u32, data[0..4], .big);
        if (magic_be == FAT_MAGIC or magic_be == FAT_CIGAM) {
            return relocateFat(alloc, path, data);
        }
        return false;
    }

    return relocateMachO64(alloc, path, data);
}

fn relocateMachO64(alloc: std.mem.Allocator, path: []const u8, data: []const u8) bool {
    if (data.len < 32) return false;
    const ncmds = std.mem.readInt(u32, data[16..20], .little);
    const header_size: usize = 32;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    argv.append(alloc, "install_name_tool") catch return false;

    var to_free: std.ArrayList([]u8) = .empty;
    defer {
        for (to_free.items) |s| alloc.free(s);
        to_free.deinit(alloc);
    }

    var offset: usize = header_size;
    for (0..ncmds) |_| {
        if (offset + 8 > data.len) break;
        const cmd = std.mem.readInt(u32, data[offset..][0..4], .little);
        const cmdsize = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
        if (cmdsize < 8 or offset + cmdsize > data.len) break;

        switch (cmd) {
            LC_ID_DYLIB, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB => {
                if (cmdsize > 12) {
                    const str_off = std.mem.readInt(u32, data[offset + 8 ..][0..4], .little);
                    if (str_off < cmdsize) {
                        const str_start = offset + str_off;
                        const str_end = offset + cmdsize;
                        if (str_end <= data.len) {
                            const region = data[str_start..str_end];
                            const str_len = std.mem.indexOf(u8, region, &[_]u8{0}) orelse region.len;
                            const str = region[0..str_len];

                            if (hasPlaceholder(str)) {
                                const new_path = replacePlaceholders(alloc, str) catch continue;
                                to_free.append(alloc, new_path) catch {
                                    alloc.free(new_path);
                                    continue;
                                };
                                if (cmd == LC_ID_DYLIB) {
                                    argv.append(alloc, "-id") catch continue;
                                    argv.append(alloc, new_path) catch continue;
                                } else {
                                    argv.append(alloc, "-change") catch continue;
                                    argv.append(alloc, str) catch continue;
                                    argv.append(alloc, new_path) catch continue;
                                }
                            }
                        }
                    }
                }
            },
            LC_RPATH => {
                if (cmdsize > 12) {
                    const str_off = std.mem.readInt(u32, data[offset + 8 ..][0..4], .little);
                    if (str_off < cmdsize) {
                        const str_start = offset + str_off;
                        const str_end = offset + cmdsize;
                        if (str_end <= data.len) {
                            const region = data[str_start..str_end];
                            const str_len = std.mem.indexOf(u8, region, &[_]u8{0}) orelse region.len;
                            const str = region[0..str_len];

                            if (hasPlaceholder(str)) {
                                const new_rpath = replacePlaceholders(alloc, str) catch continue;
                                to_free.append(alloc, new_rpath) catch {
                                    alloc.free(new_rpath);
                                    continue;
                                };
                                argv.append(alloc, "-rpath") catch continue;
                                argv.append(alloc, str) catch continue;
                                argv.append(alloc, new_rpath) catch continue;
                            }
                        }
                    }
                }
            },
            else => {},
        }
        offset += cmdsize;
    }

    if (argv.items.len > 1) {
        argv.append(alloc, path) catch return false;
        const _io_m = std.Io.Threaded.global_single_threaded.io();
        const r = std.process.run(alloc, _io_m, .{ .argv = argv.items, .stdout_limit = .limited(4096) }) catch return false;
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);
        return switch (r.term) { .exited => |c| c == 0, else => false };
    }
    return false;
}

/// For fat/universal binaries, parse each architecture slice.
fn relocateFat(alloc: std.mem.Allocator, path: []const u8, data: []const u8) bool {
    _ = data;
    // Fat binaries: fall back to scanning file for placeholders, then use install_name_tool.
    // This is rare in practice (most arm64 bottles are thin Mach-O).
    if (!fileContainsPlaceholder(path)) return false;

    // Use install_name_tool with -change for discovered paths
    // For fat binaries, we need otool as fallback (rare case)
    const result = runProcess(alloc, &.{ "otool", "-l", path }) catch return false;
    defer alloc.free(result);
    return relocateWithOtool(alloc, path, result);
}

fn relocateWithOtool(alloc: std.mem.Allocator, path: []const u8, otool_output: []const u8) bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    argv.append(alloc, "install_name_tool") catch return false;

    var to_free: std.ArrayList([]u8) = .empty;
    defer {
        for (to_free.items) |s| alloc.free(s);
        to_free.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, otool_output, '\n');
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
        if (std.mem.startsWith(u8, trimmed, "cmd LC_ID_DYLIB")) { current_cmd = .id_dylib; continue; }
        if (std.mem.startsWith(u8, trimmed, "cmd LC_RPATH")) { current_cmd = .rpath; continue; }
        if (std.mem.startsWith(u8, trimmed, "cmd ")) { current_cmd = .none; continue; }

        if ((current_cmd == .load_dylib or current_cmd == .id_dylib) and std.mem.startsWith(u8, trimmed, "name ")) {
            const after = trimmed[5..];
            const paren = std.mem.indexOf(u8, after, " (") orelse continue;
            const dylib_path = after[0..paren];
            if (hasPlaceholder(dylib_path)) {
                const new_path = replacePlaceholders(alloc, dylib_path) catch continue;
                to_free.append(alloc, new_path) catch { alloc.free(new_path); continue; };
                if (current_cmd == .load_dylib) {
                    argv.append(alloc, "-change") catch continue;
                    argv.append(alloc, dylib_path) catch continue;
                } else {
                    argv.append(alloc, "-id") catch continue;
                }
                argv.append(alloc, new_path) catch continue;
            }
            current_cmd = .none;
        }
        if (current_cmd == .rpath and std.mem.startsWith(u8, trimmed, "path ")) {
            const after = trimmed[5..];
            const paren = std.mem.indexOf(u8, after, " (") orelse continue;
            const rpath = after[0..paren];
            if (hasPlaceholder(rpath)) {
                const new_rpath = replacePlaceholders(alloc, rpath) catch continue;
                to_free.append(alloc, new_rpath) catch { alloc.free(new_rpath); continue; };
                argv.append(alloc, "-rpath") catch continue;
                argv.append(alloc, rpath) catch continue;
                argv.append(alloc, new_rpath) catch continue;
            }
            current_cmd = .none;
        }
    }

    if (argv.items.len > 1) {
        argv.append(alloc, path) catch return false;
        const _io_o = std.Io.Threaded.global_single_threaded.io();
        const r = std.process.run(alloc, _io_o, .{ .argv = argv.items, .stdout_limit = .limited(4096) }) catch return false;
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);
        return switch (r.term) { .exited => |c| c == 0, else => false };
    }
    return false;
}

fn hasPlaceholder(s: []const u8) bool {
    return ph.hasPlaceholder(s);
}

fn replacePlaceholders(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    return ph.replacePlaceholders(alloc, input);
}

fn fileContainsPlaceholder(path: []const u8) bool {
    return ph.fileContainsPlaceholder(path);
}

fn runProcess(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const _io_r = std.Io.Threaded.global_single_threaded.io();
    const result = std.process.run(alloc, _io_r, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
    }) catch return error.ReadFailed;
    defer alloc.free(result.stderr);
    if (switch (result.term) { .exited => |c| c != 0, else => true }) {
        alloc.free(result.stdout);
        return error.ProcessFailed;
    }
    return result.stdout;
}

const testing = std.testing;

test "hasPlaceholder - detects HOMEBREW prefix" {
    try testing.expect(hasPlaceholder("@@HOMEBREW_PREFIX@@/lib/libfoo.dylib"));
    try testing.expect(hasPlaceholder("@@HOMEBREW_CELLAR@@/ffmpeg/7.1/lib/libavcodec.dylib"));
}

test "hasPlaceholder - rejects normal paths" {
    try testing.expect(!hasPlaceholder("/usr/lib/libSystem.B.dylib"));
    try testing.expect(!hasPlaceholder("/opt/nanobrew/prefix/lib/libfoo.dylib"));
    try testing.expect(!hasPlaceholder(""));
}

test "replacePlaceholders - PREFIX" {
    const result = try replacePlaceholders(testing.allocator, "@@HOMEBREW_PREFIX@@/lib/libz.dylib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/lib/libz.dylib", result);
}

test "replacePlaceholders - CELLAR" {
    const result = try replacePlaceholders(testing.allocator, "@@HOMEBREW_CELLAR@@/ffmpeg/7.1/lib/libavcodec.dylib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/ffmpeg/7.1/lib/libavcodec.dylib", result);
}

test "replacePlaceholders - both in one string" {
    const result = try replacePlaceholders(testing.allocator, "@@HOMEBREW_CELLAR@@/x265/4.0/lib:@@HOMEBREW_PREFIX@@/lib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/x265/4.0/lib:/opt/nanobrew/prefix/lib", result);
}

test "replacePlaceholders - no placeholders returns copy" {
    const result = try replacePlaceholders(testing.allocator, "/usr/lib/libSystem.B.dylib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/usr/lib/libSystem.B.dylib", result);
}
