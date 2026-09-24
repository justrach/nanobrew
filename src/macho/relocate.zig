// nanobrew — Mach-O relocator (native byte-pass, install_name_tool fallback)
//
// Homebrew bottles embed @@HOMEBREW_*@@ placeholders in Mach-O load commands
// AND bake literal /opt/homebrew/… paths into .rodata / __DATA as compile-time
// defaults (OpenSSL OPENSSLDIR/ENGINESDIR, git --html-path/--man-path,
// GIT_CONFIG_SYSTEM/GIT_ATTR_SYSTEM, …). install_name_tool only rewrites load
// commands, so .rodata survives broken — the root cause of #347.
//
// This module mirrors the ELF relocator's native-first design:
//   1. Read the whole Mach-O (or fat/universal) file once.
//   2. When /opt/nb → <PREFIX> is available, rewrite every @@HOMEBREW_*@@
//      placeholder and literal /opt/homebrew/… / /usr/local/… IN PLACE with
//      strictly-shorter replacements, '/'-padding the freed bytes. One pass
//      covers .rodata, load-command dylib IDs/rpaths/loads, and every fat
//      slice uniformly — no install_name_tool, no otool. dyld and the kernel
//      both collapse '/' runs; every byte offset is unchanged, so only a
//      re-sign is needed afterward.
//   3. When /opt/nb can't be created (non-root upgrade of an old install),
//      fall back to install_name_tool for load commands only (.rodata stays
//      as-is — no regression vs the previous behavior) and warn to run
//      `sudo nb init`.
//   4. Batch ad-hoc re-sign every Mach-O in the keg in one codesign call.
//
// The short-prefix guarantee and rewriteAllInPlace live in
// platform/short_prefix.zig, shared with the ELF relocator. See #347.

const std = @import("std");
const paths = @import("../platform/paths.zig");
const ph = @import("../platform/placeholder.zig");
const short = @import("../platform/short_prefix.zig");

const CELLAR_DIR = paths.CELLAR_DIR;
const PREFIX = paths.PREFIX;

const PLACEHOLDER_PREFIX = paths.PLACEHOLDER_PREFIX;
const PLACEHOLDER_CELLAR = paths.PLACEHOLDER_CELLAR;

const REAL_PREFIX = paths.REAL_PREFIX;
const REAL_CELLAR = paths.REAL_CELLAR;

// Short-prefix replacements (via /opt/nb → <PREFIX>) and literal Homebrew
// prefixes baked into .rodata. Every replacement is strictly shorter than
// its source so the in-place byte pass never shifts an offset.
const SHORT_PREFIX = short.SHORT_PREFIX; // /opt/nb (7)  < @@HOMEBREW_PREFIX@@ (19)
const SHORT_CELLAR = short.SHORT_CELLAR; // /opt/nb/Cellar (14) < @@HOMEBREW_CELLAR@@ (19)
const SHORT_PREFIX_SLASH = SHORT_PREFIX ++ "/"; // /opt/nb/ (8) < /opt/homebrew/ (14)
const SHORT_CELLAR_SLASH = SHORT_CELLAR ++ "/"; // /opt/nb/Cellar/ (15) < /usr/local/Cellar/ (18)
const SHORT_OPT_SLASH = SHORT_PREFIX ++ "/opt/"; // /opt/nb/opt/ (12) < /usr/local/opt/ (14)

const HOMEBREW_LITERAL_PREFIX = "/opt/homebrew/";
const INTEL_CELLAR_LITERAL = "/usr/local/Cellar/";
const INTEL_OPT_LITERAL = "/usr/local/opt/";

/// BSD ar archive magic — static .a libraries. Their Mach-O members carry
/// the same baked .rodata paths as dylibs, and the length-preserving byte
/// pass is valid inside an archive too: no member offset and no symbol-table
/// index entry ever shifts (#357).
const AR_MAGIC = "!<arch>\n";

comptime {
    if (SHORT_PREFIX_SLASH.len > HOMEBREW_LITERAL_PREFIX.len or
        SHORT_CELLAR_SLASH.len > INTEL_CELLAR_LITERAL.len or
        SHORT_OPT_SLASH.len > INTEL_OPT_LITERAL.len)
    {
        @compileError("Mach-O in-place literal relocation requires every short replacement to be no longer than its source");
    }
}

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

/// Inspect `path`; if it is a Mach-O (or fat/universal) binary containing
/// @@HOMEBREW_*@@ placeholders or literal /opt/homebrew/… / /usr/local/…
/// paths, rewrite them in place and return `true` so the caller re-signs
/// the file. Returns `false` for non-Mach-O files and for clean Mach-O
/// files (nothing to rewrite → no re-sign needed).
///
/// Primary path: a whole-file byte pass via /opt/nb (strictly-shorter
/// replacements, '/'-padded) covers .rodata compile-time defaults AND
/// load-command dylib IDs/rpaths/loads AND every fat slice in one go —
/// no install_name_tool, no otool. dyld and the kernel both collapse '/'
/// runs; every byte offset is unchanged, so only a re-sign is needed.
/// Falls back to install_name_tool for load commands only when /opt/nb
/// can't be created (#347).
fn relocateFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    // Probe with a read-only open first: bottled payload sometimes ships
    // without the owner-write bit (perl: 0555 bin/perl, libperl.dylib), and
    // an eager read-write open EACCES-skips exactly the files the byte pass
    // must rewrite (#347). Only confirmed Mach-O files get the write-bit
    // lift and the read-write reopen.
    const probe = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    var probe_open = true;
    defer if (probe_open) probe.close(io);

    const stat = probe.stat(io) catch return false;
    if (stat.size < 32 or stat.size > 256 * 1024 * 1024) return false;

    // Probe magic before allocating/reading the whole file: most files under
    // lib/ are not Mach-O.
    var magic_buf: [8]u8 = undefined;
    const magic_n = probe.readPositional(io, &.{magic_buf[0..]}, 0) catch return false;
    if (magic_n < 4) return false;
    const magic_le = std.mem.readInt(u32, magic_buf[0..4], .little);
    const magic_be = std.mem.readInt(u32, magic_buf[0..4], .big);
    const is_macho_64 = magic_le == MH_MAGIC_64 or magic_le == MH_CIGAM_64;
    const is_fat = magic_be == FAT_MAGIC or magic_be == FAT_CIGAM;
    const is_archive = magic_n >= AR_MAGIC.len and std.mem.eql(u8, magic_buf[0..AR_MAGIC.len], AR_MAGIC);
    if (!is_macho_64 and !is_fat and !is_archive) return false;

    probe.close(io);
    probe_open = false;

    const orig_mode = stat.permissions.toMode();
    const lifted = short.liftOwnerWrite(io, path, orig_mode);
    var file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch {
        if (lifted) short.restoreMode(io, path, orig_mode);
        return false;
    };
    var file_open = true;
    defer if (file_open) {
        if (lifted) _ = std.c.fchmod(file.handle, @intCast(orig_mode));
        file.close(io);
    };

    const size: usize = @intCast(stat.size);
    const heap = std.heap.smp_allocator;
    const buf = heap.alloc(u8, size) catch return false;
    defer heap.free(buf);
    const read_n = file.readPositionalAll(io, buf, 0) catch return false;
    const data = buf[0..read_n];
    if (data.len < 32) return false;

    const has_placeholder = std.mem.indexOf(u8, data, "@@HOMEBREW") != null;
    const has_homebrew_literal =
        std.mem.indexOf(u8, data, HOMEBREW_LITERAL_PREFIX) != null or
        std.mem.indexOf(u8, data, INTEL_CELLAR_LITERAL) != null or
        std.mem.indexOf(u8, data, INTEL_OPT_LITERAL) != null;
    if (!has_placeholder and !has_homebrew_literal) return false; // clean: 1 read, 0 writes, 0 subprocesses

    // Primary path: /opt/nb short prefix available → one in-place byte pass
    // over the whole file (.rodata + load commands + fat slices).
    if (short.ensureShortPrefixLink(io)) {
        var changed = false;
        if (std.mem.indexOf(u8, data, paths.PLACEHOLDER_REPOSITORY) != null) {
            short.rewriteAllInPlace(data, paths.PLACEHOLDER_REPOSITORY, paths.REAL_REPOSITORY);
            changed = true;
        }
        if (std.mem.indexOf(u8, data, paths.PLACEHOLDER_CELLAR) != null) {
            short.rewriteAllInPlace(data, paths.PLACEHOLDER_CELLAR, SHORT_CELLAR);
            changed = true;
        }
        if (std.mem.indexOf(u8, data, paths.PLACEHOLDER_PREFIX) != null) {
            short.rewriteAllInPlace(data, paths.PLACEHOLDER_PREFIX, SHORT_PREFIX);
            changed = true;
        }
        if (std.mem.indexOf(u8, data, HOMEBREW_LITERAL_PREFIX) != null) {
            short.rewriteAllInPlace(data, HOMEBREW_LITERAL_PREFIX, SHORT_PREFIX_SLASH);
            changed = true;
        }
        if (std.mem.indexOf(u8, data, INTEL_CELLAR_LITERAL) != null) {
            short.rewriteAllInPlace(data, INTEL_CELLAR_LITERAL, SHORT_CELLAR_SLASH);
            changed = true;
        }
        if (std.mem.indexOf(u8, data, INTEL_OPT_LITERAL) != null) {
            short.rewriteAllInPlace(data, INTEL_OPT_LITERAL, SHORT_OPT_SLASH);
            changed = true;
        }
        // @@HOMEBREW_LIBRARY@@ / @@HOMEBREW_PERL@@ are intentionally NOT
        // rewritten here: REAL_LIBRARY is longer than its placeholder (can't
        // shrink in place) and neither is linkage-relevant — mirrors the ELF
        // relocator. Text-file shebangs/.pc are handled by the placeholder
        // walker, which skips binaries.
        if (changed) file.writePositionalAll(io, data, 0) catch return false;
        // Static archives carry no code signature — report them unmodified so
        // the caller's batch codesign pass skips them (#357).
        if (is_archive) return false;
        return changed;
    }

    // Fallback: no /opt/nb (non-root upgrade of an old install). install_name_tool
    // resizes load commands to the long REAL_PREFIX form — load commands are
    // fixed, but .rodata compile-time defaults are left as-is (no regression vs
    // the previous behavior; run `sudo nb init` to enable the full byte pass).
    // Close our handle before install_name_tool rewrites the file; restore
    // the original mode first so the fresh file install_name_tool renames
    // into place inherits it.
    if (lifted) _ = std.c.fchmod(file.handle, @intCast(orig_mode));
    file.close(io);
    file_open = false;
    warnNoShortPrefix(io);
    // Whatever the fallback fixes (load commands at most), the .rodata
    // compile-time paths in this file stay foreign — record it so the
    // install is neither snapshot-cached nor reported successful (#355/#356).
    short.noteIncompleteFile();
    // Only the byte pass can rewrite ar members; install_name_tool cannot.
    // Without /opt/nb the archive is left as-is, like .rodata (#357).
    if (is_archive) return false;
    if (is_macho_64) return relocateMachO64(alloc, io, path, data);
    return relocateFat(alloc, io, path, data);
}

var warned_no_short_prefix = std.atomic.Value(bool).init(false);

fn warnNoShortPrefix(io: std.Io) void {
    if (warned_no_short_prefix.swap(true, .acq_rel)) return; // already warned this process
    const msg = "nb: note: /opt/nb short-prefix symlink unavailable — Mach-O .rodata not relocated; run `sudo $(command -v nb) init` and reinstall affected packages\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
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
        return switch (r.term) {
            .exited => |c| c == 0,
            else => false,
        };
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

        if ((current_cmd == .load_dylib or current_cmd == .id_dylib) and std.mem.startsWith(u8, trimmed, "name ")) {
            const after = trimmed[5..];
            const paren = std.mem.indexOf(u8, after, " (") orelse continue;
            const dylib_path = after[0..paren];
            if (hasPlaceholder(dylib_path)) {
                const new_path = replacePlaceholders(alloc, dylib_path) catch continue;
                to_free.append(alloc, new_path) catch {
                    alloc.free(new_path);
                    continue;
                };
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
                to_free.append(alloc, new_rpath) catch {
                    alloc.free(new_rpath);
                    continue;
                };
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
        return switch (r.term) {
            .exited => |c| c == 0,
            else => false,
        };
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
        fileContainsLiteral(path, "/usr/local/opt/") or
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
            const n = file.readPositional(lib_io, &.{buf[overlap..]}, file_offset) catch break :blk false;
            if (n == 0) break;
            const total = overlap + n;
            if (std.mem.indexOf(u8, buf[0..total], needle) != null) break :blk true;
            // Carry the tail of the *valid data* (buf[total-carry..total], not
            // buf[buf.len-carry..]) so a needle spanning the chunk boundary is
            // found even after a short read leaves the buffer tail stale.
            const carry = @min(needle.len - 1, total);
            std.mem.copyForwards(u8, buf[0..carry], buf[total - carry .. total]);
            overlap = carry;
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
    if (switch (result.term) {
        .exited => |c| c != 0,
        else => true,
    }) {
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

// ── byte-pass (short.rewriteAllInPlace) tests ─────────────────────────────
// These exercise the in-place path that relocateFile now uses for .rodata +
// load commands when /opt/nb is available. Replacements are strictly shorter
// and '/'-padded so byte length and every offset are preserved (#347).

test "byte-pass - PREFIX placeholder pads with slashes, length preserved" {
    var buf = "@@HOMEBREW_PREFIX@@/lib/libz.dylib\x00tail".*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_PREFIX@@", "/opt/nb");
    try testing.expectEqual(before_len, buf.len);
    // /opt/nb (7) + 12 slashes + /lib/libz.dylib\x00tail
    try testing.expect(std.mem.startsWith(u8, &buf, "/opt/nb/////////////lib/libz.dylib"));
    try testing.expect(std.mem.indexOf(u8, &buf, "@@HOMEBREW") == null);
}

test "byte-pass - liftOwnerWrite opens 0555 payload for rewrite, restoreMode puts the bit back" {
    // perl's bottle ships bin/perl and libperl.dylib as 0555; the eager
    // read-write open used to EACCES-skip them silently (#347).
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const f = tmp_dir.dir.createFile(testing.io, "ro_payload", .{}) catch unreachable;
    f.writeStreamingAll(testing.io, "@@HOMEBREW_PREFIX@@/opt/perl/lib/libperl.dylib") catch unreachable;
    f.close(testing.io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = tmp_dir.dir.realPathFile(testing.io, "ro_payload", &path_buf) catch unreachable;
    const abs_path = path_buf[0..path_n];
    const ro = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{}) catch unreachable;
    _ = std.c.fchmod(ro.handle, 0o555);
    ro.close(testing.io);

    // Read-write open is denied while the file is 0555 …
    try testing.expectError(error.AccessDenied, std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{ .mode = .read_write }));
    // … the lift makes the same open succeed …
    try testing.expect(short.liftOwnerWrite(testing.io, abs_path, 0o555));
    const rw = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{ .mode = .read_write }) catch unreachable;
    var payload: [64]u8 = undefined;
    const n = rw.readPositionalAll(testing.io, &payload, 0) catch unreachable;
    short.rewriteAllInPlace(payload[0..n], "@@HOMEBREW_PREFIX@@", short.SHORT_PREFIX);
    rw.writePositionalAll(testing.io, payload[0..n], 0) catch unreachable;
    rw.close(testing.io);
    // … and the restore returns the original mode for the later batch codesign.
    short.restoreMode(testing.io, abs_path, 0o555);

    const v = std.Io.Dir.openFileAbsolute(testing.io, abs_path, .{}) catch unreachable;
    defer v.close(testing.io);
    const mode = (v.stat(testing.io) catch unreachable).permissions.toMode();
    try testing.expect((mode & 0o200) == 0);
    var out: [64]u8 = undefined;
    const on = v.readPositionalAll(testing.io, &out, 0) catch unreachable;
    try testing.expect(std.mem.startsWith(u8, out[0..on], "/opt/nb/"));
    try testing.expect(std.mem.indexOf(u8, out[0..on], "@@HOMEBREW") == null);
}

test "byte-pass - CELLAR placeholder pads with slashes" {
    var buf = "@@HOMEBREW_CELLAR@@/openssl@3/3.6.2/lib/libssl.3.dylib".*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_CELLAR@@", "/opt/nb/Cellar");
    try testing.expectEqual(before_len, buf.len);
    try testing.expect(std.mem.startsWith(u8, &buf, "/opt/nb/Cellar"));
    try testing.expect(std.mem.indexOf(u8, &buf, "openssl@3/3.6.2/lib/libssl.3.dylib") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "@@HOMEBREW") == null);
}

test "byte-pass - REPOSITORY placeholder (no short symlink needed)" {
    var buf = "@@HOMEBREW_REPOSITORY@@/Library/Taps".*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_REPOSITORY@@", "/opt/nanobrew");
    try testing.expectEqual(before_len, buf.len);
    try testing.expect(std.mem.startsWith(u8, &buf, "/opt/nanobrew"));
    try testing.expect(std.mem.indexOf(u8, &buf, "Library/Taps") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "@@HOMEBREW") == null);
}

test "byte-pass - literal /opt/homebrew/ .rodata default (openssl OPENSSLDIR, #347)" {
    // Mirrors a compile-time default baked into .rodata: openssl's OPENSSLDIR.
    var buf = "OPENSSLDIR: \"/opt/homebrew/etc/openssl@3\"\x00".*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, "/opt/homebrew/", "/opt/nb/");
    try testing.expectEqual(before_len, buf.len);
    try testing.expect(std.mem.indexOf(u8, &buf, "/opt/homebrew/") == null);
    try testing.expect(std.mem.indexOf(u8, &buf, "/opt/nb") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "etc/openssl@3") != null);
    // No NULs introduced inside the rewritten run (NUL terminator preserved).
    const rewritten = std.mem.sliceTo(&buf, 0);
    try testing.expect(std.mem.indexOfScalar(u8, rewritten, 0) == null);
}

test "byte-pass - literal /opt/homebrew/ subsumes Cellar/opt subpaths" {
    var buf = "/opt/homebrew/Cellar/git/2.54.0/libexec/git-core\x00".*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, "/opt/homebrew/", "/opt/nb/");
    try testing.expectEqual(before_len, buf.len);
    // The single /opt/homebrew/ -> /opt/nb/ rewrite covers the Cellar subpath.
    try testing.expect(std.mem.indexOf(u8, &buf, "/opt/homebrew/") == null);
    try testing.expect(std.mem.indexOf(u8, &buf, "/opt/nb") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "Cellar/git/2.54.0/libexec/git-core") != null);
}

test "byte-pass - two placeholders inside one colon-separated rpath" {
    var buf = "@@HOMEBREW_CELLAR@@/x265/4.0/lib:@@HOMEBREW_PREFIX@@/lib\x00tail".*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_CELLAR@@", "/opt/nb/Cellar");
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_PREFIX@@", "/opt/nb");
    try testing.expectEqual(before_len, buf.len);
    try testing.expect(std.mem.indexOf(u8, &buf, "@@HOMEBREW") == null);
    try testing.expect(std.mem.startsWith(u8, &buf, "/opt/nb/Cellar"));
    try testing.expect(std.mem.indexOf(u8, &buf, "x265/4.0/lib:") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "/lib\x00tail") != null);
}

test "byte-pass - LIBRARY placeholder is intentionally left in place" {
    // Mirrors the ELF relocator: @@HOMEBREW_LIBRARY@@ is not linkage-relevant
    // and REAL_LIBRARY is longer than the placeholder, so it is NOT rewritten.
    var buf = "@@HOMEBREW_LIBRARY@@/Homebrew\x00".*;
    const before_len = buf.len;
    // relocateFile does not call rewriteAllInPlace for LIBRARY; simulate by
    // confirming the placeholder survives a pass that only handles the others.
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_PREFIX@@", "/opt/nb");
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_CELLAR@@", "/opt/nb/Cellar");
    try testing.expectEqual(before_len, buf.len);
    try testing.expect(std.mem.indexOf(u8, &buf, "@@HOMEBREW_LIBRARY@@") != null);
}

test "byte-pass - ar archive member paths rewritten in place, offsets preserved (#357)" {
    // A minimal BSD ar layout: global magic, one member header (60 bytes),
    // then member data with a baked .rodata Homebrew path. The byte pass must
    // keep every offset identical (ar member headers and the symbol table
    // index the file by absolute offset) and leave the magic intact.
    var buf = ("!<arch>\n" ++
        "libcrypto.o    0           0     0     100644  64        `\n" ++
        "OPENSSLDIR: \"/opt/homebrew/etc/openssl@3\"\x00/usr/local/opt/x\x00").*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, HOMEBREW_LITERAL_PREFIX, SHORT_PREFIX_SLASH);
    short.rewriteAllInPlace(&buf, INTEL_CELLAR_LITERAL, SHORT_CELLAR_SLASH);
    short.rewriteAllInPlace(&buf, INTEL_OPT_LITERAL, SHORT_OPT_SLASH);
    try testing.expectEqual(before_len, buf.len);
    try testing.expect(std.mem.startsWith(u8, &buf, AR_MAGIC));
    try testing.expect(std.mem.indexOf(u8, &buf, "libcrypto.o") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "/opt/homebrew/") == null);
    try testing.expect(std.mem.indexOf(u8, &buf, "/usr/local/opt/") == null);
    try testing.expect(std.mem.indexOf(u8, &buf, "/opt/nb") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "etc/openssl@3") != null);
    // NUL terminators inside member data stay where they were.
    try testing.expectEqual(@as(u8, 0), buf[buf.len - 1]);
}

test "byte-pass - whole-file pass mirrors relocateFile (placeholder + literal)" {
    // A tiny stand-in for a Mach-O file body: a placeholder dylib id plus a
    // literal /opt/homebrew/ .rodata default. relocateFile rewrites both in
    // one pass without shifting any byte offset.
    var buf = ("LC_ID:@@HOMEBREW_CELLAR@@/openssl@3/3.6.2/lib/libssl.3.dylib" ++ "|OPENSSLDIR=\"/opt/homebrew/etc/openssl@3\"\x00").*;
    const before_len = buf.len;
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_REPOSITORY@@", "/opt/nanobrew");
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_CELLAR@@", "/opt/nb/Cellar");
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_PREFIX@@", "/opt/nb");
    short.rewriteAllInPlace(&buf, "/opt/homebrew/", "/opt/nb/");
    try testing.expectEqual(before_len, buf.len);
    try testing.expect(std.mem.indexOf(u8, &buf, "@@HOMEBREW") == null);
    try testing.expect(std.mem.indexOf(u8, &buf, "/opt/homebrew/") == null);
    try testing.expect(std.mem.indexOf(u8, &buf, "openssl@3/3.6.2/lib/libssl.3.dylib") != null);
    try testing.expect(std.mem.indexOf(u8, &buf, "etc/openssl@3") != null);
}
