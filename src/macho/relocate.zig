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

/// Top-level keg subdirectories explicitly known to never contain Mach-O
/// binaries. We skip these to avoid wasting syscalls on header / docs /
/// locale trees. Anything else gets walked — handles non-standard
/// layouts like vulkan-loader's `loader/vulkan.framework/`.
const NON_MACHO_TOP_DIRS = [_][]const u8{ "include", "share", "etc", "var", "doc" };

fn isNonMachoTopDir(name: []const u8) bool {
    for (NON_MACHO_TOP_DIRS) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// Relocate all Mach-O files in a keg. Rewrites @@HOMEBREW_*@@ placeholders
/// in load commands via install_name_tool, then ad-hoc re-signs every Mach-O
/// file encountered — `install_name_tool` unconditionally invalidates a
/// binary's code signature when run, and some upstream bottles ship with
/// signatures that drift in transit, so every Mach-O gets a fresh adhoc sig.
///
/// Framework bundles (*.framework) carry a SEPARATE sealed-resource signature
/// at `<bundle>/Versions/<ver>/_CodeSignature/` that tracks the hashes of
/// every file inside the bundle. Re-signing inner binaries invalidates that
/// seal. We therefore do NOT re-deep-sign frameworks here, because the
/// caller still needs to run `replaceKegPlaceholders` (which rewrites text
/// files inside Info.plist, .pc, etc. and would invalidate the seal again).
/// Instead, the caller is expected to invoke `sealKegBundles` as the final
/// step of the install pipeline, after every file mutation is done.
pub fn relocateKeg(alloc: std.mem.Allocator, io: std.Io, name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    var macho_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (macho_files.items) |p| alloc.free(p);
        macho_files.deinit(alloc);
    }

    // Frameworks collected here are only recorded; signing happens in
    // sealKegBundles after all file mutation is complete.
    var frameworks_unused: std.ArrayList([]const u8) = .empty;
    defer {
        for (frameworks_unused.items) |p| alloc.free(p);
        frameworks_unused.deinit(alloc);
    }

    {
        var keg = std.Io.Dir.openDirAbsolute(io, keg_dir, .{ .iterate = true }) catch return;
        defer keg.close(io);
        var iter = keg.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (isNonMachoTopDir(entry.name)) continue;
            var sub_buf: [512]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, entry.name }) catch continue;
            walkAndRelocate(alloc, io, sub_path, &macho_files, &frameworks_unused) catch {};
        }
    }

    // Batch ad-hoc re-sign every Mach-O file in one codesign call. Capture
    // limits are generous because codesign prints "<file>: replacing existing
    // signature" per file — ~100 chars × N files can exceed a small buffer
    // and SIGPIPE the subprocess mid-batch, leaving most files unsigned.
    if (macho_files.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        argv.append(alloc, "codesign") catch return;
        argv.append(alloc, "-f") catch return;
        argv.append(alloc, "-s") catch return;
        argv.append(alloc, "-") catch return;
        for (macho_files.items) |p| argv.append(alloc, p) catch continue;

        if (std.process.run(alloc, io, .{ .argv = argv.items, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) })) |r| {
            alloc.free(r.stdout);
            alloc.free(r.stderr);
        } else |_| {}
    }
}

/// Re-seal every *.framework bundle in the keg with `codesign --deep -f -s -`.
/// Run AFTER relocateKeg AND replaceKegPlaceholders, so the final seal
/// covers every file mutation. This is the last step before linking.
pub fn sealKegBundles(alloc: std.mem.Allocator, io: std.Io, name: []const u8, version: []const u8) void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return;

    var frameworks: std.ArrayList([]const u8) = .empty;
    defer {
        for (frameworks.items) |p| alloc.free(p);
        frameworks.deinit(alloc);
    }

    // Discover frameworks under each Mach-O-bearing subdir.
    {
        var keg = std.Io.Dir.openDirAbsolute(io, keg_dir, .{ .iterate = true }) catch return;
        defer keg.close(io);
        var iter = keg.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (isNonMachoTopDir(entry.name)) continue;
            var sub_buf: [512]u8 = undefined;
            const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, entry.name }) catch continue;
            collectFrameworks(alloc, io, sub_path, &frameworks);
        }
    }

    // `--deep` walks every nested Mach-O and prints one line per file;
    // use generous buffers so the pipe never SIGPIPEs the subprocess.
    for (frameworks.items) |fw| {
        const argv = [_][]const u8{ "codesign", "-f", "-s", "-", "--deep", fw };
        if (std.process.run(alloc, io, .{ .argv = &argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) })) |r| {
            alloc.free(r.stdout);
            alloc.free(r.stderr);
        } else |_| {}
    }
}

fn collectFrameworks(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8, frameworks: *std.ArrayList([]const u8)) void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        if (std.mem.endsWith(u8, entry.name, ".framework")) {
            const dup = alloc.dupe(u8, child_path) catch continue;
            frameworks.append(alloc, dup) catch alloc.free(dup);
            // Do not recurse into a framework; --deep handles interior.
            continue;
        }
        collectFrameworks(alloc, io, child_path, frameworks);
    }
}

fn walkAndRelocate(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    modified: *std.ArrayList([]const u8),
    frameworks: *std.ArrayList([]const u8),
) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => {
                // Record *.framework bundles so the keg-level pass can re-seal
                // them with `codesign --deep` after interior Mach-O rewrites.
                if (std.mem.endsWith(u8, entry.name, ".framework")) {
                    const dup_fw = alloc.dupe(u8, child_path) catch null;
                    if (dup_fw) |fw| {
                        frameworks.append(alloc, fw) catch alloc.free(fw);
                    }
                }
                walkAndRelocate(alloc, io, child_path, modified, frameworks) catch {};
            },
            .sym_link => {
                // Resolve symlink and process target if it's a Mach-O file
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target_n = std.Io.Dir.readLinkAbsolute(io, child_path, &target_buf) catch continue;
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
                if (relocateFile(alloc, io, abs_target)) {
                    const dup = alloc.dupe(u8, abs_target) catch continue;
                    modified.append(alloc, dup) catch {
                        alloc.free(dup);
                        continue;
                    };
                }
            },
            .file => {
                if (relocateFile(alloc, io, child_path)) {
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

/// Inspect `path`; if it is a Mach-O binary, run install_name_tool for any
/// @@HOMEBREW_*@@ placeholders found and return `true`. Returns `true` even
/// when no install_name_tool invocation was needed, as long as the file is
/// a Mach-O binary — the caller then ad-hoc re-signs every Mach-O in the
/// keg, because install_name_tool unconditionally invalidates a file's
/// code signature when invoked, AND some upstream bottles ship with sealed
/// framework resources whose hashes drift after any bundled file changes.
/// Returns `false` only when the file is not a Mach-O (or unreadable).
fn relocateFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;

    // Read just the header region (load commands are in first ~32KB typically)
    var header_buf: [65536]u8 = undefined;
    const n = file.readPositional(io, &.{header_buf[0..]}, 0) catch {
        file.close(io);
        return false;
    };
    file.close(io);
    if (n < 32) return false;
    const data = header_buf[0..n];

    const magic = std.mem.readInt(u32, data[0..4], .little);
    if (magic != MH_MAGIC_64) {
        // Check for fat binary — use fallback scan
        const magic_be = std.mem.readInt(u32, data[0..4], .big);
        if (magic_be == FAT_MAGIC or magic_be == FAT_CIGAM) {
            _ = relocateFat(alloc, io, path, data);
            return true;
        }
        return false;
    }

    _ = relocateMachO64(alloc, io, path, data);
    return true;
}

fn relocateMachO64(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) bool {
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
        const r = std.process.run(alloc, io, .{ .argv = argv.items, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return false;
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);
        return switch (r.term) { .exited => |c| c == 0, else => false };
    }
    return false;
}

/// For fat/universal binaries, parse each architecture slice.
fn relocateFat(alloc: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) bool {
    _ = data;
    // Fat binaries: fall back to scanning file for placeholders, then use install_name_tool.
    // This is rare in practice (most arm64 bottles are thin Mach-O).
    if (!fileContainsPlaceholder(path)) return false;

    // Use install_name_tool with -change for discovered paths
    // For fat binaries, we need otool as fallback (rare case)
    const result = runProcess(alloc, io, &.{ "otool", "-l", path }) catch return false;
    defer alloc.free(result);
    return relocateWithOtool(alloc, io, path, result);
}

fn relocateWithOtool(alloc: std.mem.Allocator, io: std.Io, path: []const u8, otool_output: []const u8) bool {
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
        const r = std.process.run(alloc, io, .{ .argv = argv.items, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return false;
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);
        return switch (r.term) { .exited => |c| c == 0, else => false };
    }
    return false;
}

fn needsRelocation(s: []const u8) bool {
    return ph.hasPlaceholder(s) or hasLiteralHomebrewPath(s);
}

fn hasLiteralHomebrewPath(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "/opt/homebrew/") != null or
        std.mem.indexOf(u8, s, "/usr/local/Cellar/") != null or
        std.mem.indexOf(u8, s, "/usr/local/opt/") != null or
        std.mem.indexOf(u8, s, "/home/linuxbrew/.linuxbrew/") != null;
}

fn hasPlaceholder(s: []const u8) bool {
    return needsRelocation(s);
}

fn replacePlaceholders(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    const pass1 = try ph.replacePlaceholders(alloc, input);
    if (!hasLiteralHomebrewPath(pass1)) return pass1;
    defer alloc.free(pass1);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    const replace = paths.REAL_PREFIX ++ "/";
    const prefixes = [_][]const u8{
        "/opt/homebrew/",
        "/home/linuxbrew/.linuxbrew/",
        "/usr/local/Cellar/",
        "/usr/local/opt/",
    };
    var i: usize = 0;
    while (i < pass1.len) {
        var matched = false;
        inline for (prefixes) |needle| {
            if (!matched and i + needle.len <= pass1.len and
                std.mem.eql(u8, pass1[i..][0..needle.len], needle))
            {
                if (comptime std.mem.eql(u8, needle, "/usr/local/Cellar/")) {
                    try result.appendSlice(alloc, paths.REAL_CELLAR ++ "/");
                } else if (comptime std.mem.eql(u8, needle, "/usr/local/opt/")) {
                    try result.appendSlice(alloc, paths.REAL_PREFIX ++ "/opt/");
                } else {
                    try result.appendSlice(alloc, replace);
                }
                i += needle.len;
                matched = true;
            }
        }
        if (!matched) {
            try result.append(alloc, pass1[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(alloc);
}

fn fileContainsPlaceholder(path: []const u8) bool {
    if (ph.fileContainsPlaceholder(path)) return true;
    return fileContainsLiteral(path, "/opt/homebrew/") or
        fileContainsLiteral(path, "/usr/local/Cellar/") or
        fileContainsLiteral(path, "/home/linuxbrew/.linuxbrew/");
}

fn fileContainsLiteral(path: []const u8, needle: []const u8) bool {
    const lib_io = paths.safe_io;
    var file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return false;
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    var file_offset: u64 = 0;
    const result: bool = blk: {
        while (true) {
            if (overlap > 0) {
                const src = buf[buf.len - overlap ..];
                std.mem.copyForwards(u8, buf[0..overlap], src);
            }
            const n = file.readPositional(lib_io, &.{buf[overlap..]}, file_offset) catch break :blk false;
            if (n == 0) break;
            const total = overlap + n;
            if (std.mem.indexOf(u8, buf[0..total], needle) != null) break :blk true;
            overlap = @min(needle.len - 1, total);
            file_offset += @intCast(n);
        }
        break :blk false;
    };
    file.close(lib_io);
    return result;
}

fn runProcess(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(alloc, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4096),
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

test "hasPlaceholder - detects literal /opt/homebrew/ paths" {
    try testing.expect(hasPlaceholder("/opt/homebrew/lib/libheif.19.dylib"));
    try testing.expect(hasPlaceholder("/opt/homebrew/Cellar/imagemagick/7.1.2-21/lib/libMagickCore.dylib"));
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

test "replacePlaceholders - rewrites literal /opt/homebrew/ paths" {
    const result = try replacePlaceholders(testing.allocator, "/opt/homebrew/lib/libheif.19.dylib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/lib/libheif.19.dylib", result);
}

test "replacePlaceholders - rewrites literal /opt/homebrew/Cellar/ paths" {
    const result = try replacePlaceholders(testing.allocator, "/opt/homebrew/Cellar/imagemagick/7.1.2-21/lib/libMagickCore.dylib");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/opt/nanobrew/prefix/Cellar/imagemagick/7.1.2-21/lib/libMagickCore.dylib", result);
}
