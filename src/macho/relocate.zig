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

const CELLAR_DIR = "/opt/nanobrew/prefix/Cellar";
const PREFIX = "/opt/nanobrew/prefix";

const PLACEHOLDER_PREFIX = "@@HOMEBREW_PREFIX@@";
const PLACEHOLDER_CELLAR = "@@HOMEBREW_CELLAR@@";

const REAL_PREFIX = PREFIX;
const REAL_CELLAR = PREFIX ++ "/Cellar";

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

const MACHO_DIRS = [_][]const u8{ "bin", "sbin", "lib", "libexec" };

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

        var child = std.process.Child.init(argv.items, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return;
        _ = child.wait() catch {};
    }
}

fn walkAndRelocate(alloc: std.mem.Allocator, dir_path: []const u8, modified: *std.ArrayList([]const u8)) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => walkAndRelocate(alloc, child_path, modified) catch {},
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
}

/// Parse Mach-O headers natively and build install_name_tool args.
/// Returns true if the file was modified.
fn relocateFile(alloc: std.mem.Allocator, path: []const u8) bool {
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    // Read just the header region (load commands are in first ~32KB typically)
    var header_buf: [65536]u8 = undefined;
    const n = file.read(&header_buf) catch return false;
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
        var child = std.process.Child.init(argv.items, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return false;
        const term = child.wait() catch return false;
        return term.Exited == 0;
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
        var child = std.process.Child.init(argv.items, alloc);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch return false;
        const term = child.wait() catch return false;
        return term.Exited == 0;
    }
    return false;
}

fn hasPlaceholder(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "@@HOMEBREW") != null;
}

fn replacePlaceholders(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const pass1 = try std.mem.replaceOwned(u8, alloc, input, PLACEHOLDER_CELLAR, REAL_CELLAR);
    defer alloc.free(pass1);
    return try std.mem.replaceOwned(u8, alloc, pass1, PLACEHOLDER_PREFIX, REAL_PREFIX);
}

fn fileContainsPlaceholder(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
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

fn runProcess(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const stdout = child.stdout.?;
    const output = stdout.readToEndAlloc(alloc, 1024 * 1024) catch return error.ReadFailed;
    const term = child.wait() catch return error.WaitFailed;
    if (term.Exited != 0) { alloc.free(output); return error.ProcessFailed; }
    return output;
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
