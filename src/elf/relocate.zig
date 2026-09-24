// nanobrew — ELF relocator for Linux
//
// Native-first design (no patchelf for the common case):
// 1. Detect ELF files (0x7f ELF magic), read each file once.
// 2. Rewrite Homebrew placeholders and Linuxbrew literals IN PLACE with
//    strictly-shorter replacements, NUL-padding each containing C string's
//    tail. Because every replacement is shorter, .dynstr (RPATH/RUNPATH and
//    DT_NEEDED), PT_INTERP, and .rodata strings can all be patched without
//    moving a single byte offset — no section resizing, no patchelf.
//    The shorter-prefix guarantee comes from the /opt/nb → <PREFIX> symlink
//    (Nix-style short prefix): @@HOMEBREW_PREFIX@@ (19) → /opt/nb (7),
//    @@HOMEBREW_CELLAR@@ (19) → /opt/nb/Cellar (14),
//    @@HOMEBREW_REPOSITORY@@ (23) → /opt/nanobrew (13).
// 3. Repair PT_INTERP natively when the rewritten interpreter doesn't exist
//    (no glibc keg) by swapping in the system loader for the binary's arch.
// 4. patchelf remains only as a fallback for the case where the /opt/nb
//    symlink can't be created (non-root upgrade of an old install) — and is
//    bootstrapped lazily, on first actual need, instead of before every keg.
// 5. Replace placeholders in .pc, .cmake, .la text files (unchanged).
// 6. No codesign step (Linux doesn't need it).
//
// Note: every std.process.run call below threads the caller's `io` rather
// than paths.safe_io. Zig 0.16's process
// subsystem rejects the unsynchronized singleton with a vtable mismatch
// that surfaces as error.CopyFailed (see issue #276).

const std = @import("std");
const placeholder = @import("../platform/placeholder.zig");
const paths = @import("../platform/paths.zig");
const short = @import("../platform/short_prefix.zig");

const ELF_DIRS = [_][]const u8{ "bin", "sbin", "lib", "lib64", "libexec" };

// ELF magic: 0x7f 'E' 'L' 'F'
const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };

// Text config file extensions that may contain placeholders
const TEXT_EXTS = [_][]const u8{ ".pc", ".cmake", ".la", ".sh", ".cfg" };

const LINUXBREW_LITERAL = "/home/linuxbrew/.linuxbrew/";
const PREFIX_SLASH = paths.PREFIX ++ "/";

comptime {
    if (PREFIX_SLASH.len > LINUXBREW_LITERAL.len) {
        @compileError("ELF in-place linuxbrew relocation requires PREFIX_SLASH to be no longer than LINUXBREW_LITERAL");
    }
}
// SHORT_PREFIX / SHORT_CELLAR / REAL_REPOSITORY length guarantees and the
// /opt/nb → <PREFIX> symlink helper live in platform/short_prefix.zig,
// shared with the Mach-O relocator.

// Process-wide coordination for the auto-install path. When `nb install`
// fans out parallel workers and patchelf is missing, every worker would
// otherwise race to run `apt-get install` simultaneously — but apt holds
// /var/lib/dpkg/lock-frontend exclusively, so all but one worker would
// fail and skip relocation. We serialize the bootstrap with a mutex and
// memoize the result so subsequent workers find patchelf already present
// (or fail fast without re-running the package manager).
const PatchelfState = enum(u8) { unknown, present, install_failed };
var patchelf_mutex: std.Io.Mutex = .init;
var patchelf_state: PatchelfState = .unknown;

// Same memoization pattern for the /opt/nb short-prefix symlink lives in
// platform/short_prefix.zig now (shared with the Mach-O relocator).

/// Ensure patchelf is available, attempting a one-shot auto-install on
/// first call. Safe to call concurrently — only one caller drives the
/// install; the rest observe the cached outcome. Idempotent on success.
pub fn ensurePatchelf(alloc: std.mem.Allocator, io: std.Io) error{PatchelfNotFound}!void {
    patchelf_mutex.lockUncancelable(io);
    defer patchelf_mutex.unlock(io);

    switch (patchelf_state) {
        .present => return,
        .install_failed => return error.PatchelfNotFound,
        .unknown => {},
    }

    if (hasPatchelf(alloc, io)) |_| {
        patchelf_state = .present;
        return;
    } else |_| {}

    ({
        const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: patchelf not found — attempting auto-install...\n", .{}) catch "";
        defer std.heap.smp_allocator.free(_tmp);
        std.Io.File.stderr().writeStreamingAll(io, _tmp) catch {};
    });

    // Try without sudo first (works in containers/root), then with sudo.
    // Each entry is an optional refresh command (best-effort, e.g.
    // `apt-get update`) followed by the install command. apt in particular
    // requires a refresh on freshly-pulled container images where
    // /var/lib/apt/lists is empty.
    const Step = struct { refresh: ?[]const []const u8, install: []const []const u8 };
    const install_cmds = [_]Step{
        .{ .refresh = &.{ "apt-get", "update" }, .install = &.{ "apt-get", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "dnf", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "yum", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "apk", "add", "--no-cache", "patchelf" } },
        .{ .refresh = &.{ "pacman", "-Sy", "--noconfirm" }, .install = &.{ "pacman", "-S", "--noconfirm", "patchelf" } },
        .{ .refresh = &.{ "sudo", "apt-get", "update" }, .install = &.{ "sudo", "apt-get", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "sudo", "dnf", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "sudo", "yum", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "sudo", "apk", "add", "--no-cache", "patchelf" } },
        .{ .refresh = &.{ "sudo", "pacman", "-Sy", "--noconfirm" }, .install = &.{ "sudo", "pacman", "-S", "--noconfirm", "patchelf" } },
    };
    for (install_cmds) |step| {
        if (step.refresh) |refresh| {
            if (std.process.run(alloc, io, .{ .argv = refresh })) |r| {
                alloc.free(r.stdout);
                alloc.free(r.stderr);
            } else |_| {}
        }
        const result = std.process.run(alloc, io, .{
            .argv = step.install,
        }) catch continue;
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) break;
    }

    if (hasPatchelf(alloc, io)) |_| {
        ({
            const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: patchelf installed successfully\n", .{}) catch "";
            defer std.heap.smp_allocator.free(_tmp);
            std.Io.File.stderr().writeStreamingAll(io, _tmp) catch {};
        });
        patchelf_state = .present;
        return;
    } else |_| {
        patchelf_state = .install_failed;
        return error.PatchelfNotFound;
    }
}

/// Relocate all ELF files and text configs in a keg. Native in-place
/// patching needs no external tooling; patchelf is bootstrapped lazily
/// inside relocateFile only when a file actually requires it.
pub fn relocateKeg(alloc: std.mem.Allocator, io: std.Io, name: []const u8, version: []const u8) !void {
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

fn hasPatchelf(alloc: std.mem.Allocator, io: std.Io) !void {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "patchelf", "--version" },
    }) catch return error.PatchelfNotFound;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.PatchelfNotFound;
    }
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
                // null java_home: this supplementary pass has no formula
                // context; the deps-aware keg pass handles @@HOMEBREW_JAVA@@.
                _ = placeholder.relocateTextFile(io, file_path, null);
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
        _ = placeholder.relocateTextFile(io, file_path, null);
    }
}

fn hasElfMagic(data: []const u8) bool {
    return data.len >= ELF_MAGIC.len and std.mem.eql(u8, data[0..ELF_MAGIC.len], &ELF_MAGIC);
}

fn relocateFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    // Probe with a read-only open first: bottled payload sometimes ships
    // without the owner-write bit (perl's 0555 bin/ and lib/ payload on
    // Linux too), and an eager read-write open EACCES-skips exactly the
    // files the byte pass must rewrite (#347). Only confirmed ELF files get
    // the write-bit lift and the read-write reopen.
    const probe = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    var probe_open = true;
    defer if (probe_open) probe.close(io);

    const stat = probe.stat(io) catch return;
    if (stat.size < 16 or stat.size > 256 * 1024 * 1024) return;

    // Most regular files below lib/ are not ELF binaries. Probe the magic
    // first so they do not incur a full-file allocation and read.
    var header: [ELF_MAGIC.len]u8 = undefined;
    const header_n = probe.readPositional(io, &.{header[0..]}, 0) catch return;
    if (!hasElfMagic(header[0..header_n])) return;

    probe.close(io);
    probe_open = false;

    const orig_mode = stat.permissions.toMode();
    const lifted = short.liftOwnerWrite(io, path, orig_mode);
    const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch {
        if (lifted) short.restoreMode(io, path, orig_mode);
        return;
    };
    var file_open = true;
    defer if (file_open) {
        if (lifted) _ = std.c.fchmod(file.handle, @intCast(orig_mode));
        file.close(io);
    };

    const size: usize = @intCast(stat.size);
    const heap = std.heap.smp_allocator;
    const buf = heap.alloc(u8, size) catch return;
    defer heap.free(buf);
    const read_n = file.readPositionalAll(io, buf, 0) catch return;
    const data = buf[0..read_n];
    if (data.len < 16 or !hasElfMagic(data)) return;

    const has_placeholder = std.mem.indexOf(u8, data, "@@HOMEBREW") != null;
    const has_linuxbrew = std.mem.indexOf(u8, data, LINUXBREW_LITERAL) != null;
    if (!has_placeholder and !has_linuxbrew) return; // clean file: 1 read, 0 writes, 0 subprocesses

    var changed = false;

    // Linuxbrew bottles routinely bake the literal Linuxbrew prefix into
    // .rodata for compile-time MAGICKCORE_CONFIGURE_PATH-style strings
    // (imagemagick), pkg-config metadata embedded in tools, perl @INC,
    // python sys.path defaults, etc. The replacement is never longer, and
    // the freed bytes become '/' padding at the path boundary — valid for
    // C-string and length-delimited consumers alike, with every byte
    // offset in the binary untouched. See #269 and rewriteAllInPlace.
    if (has_linuxbrew) {
        short.rewriteAllInPlace(data, LINUXBREW_LITERAL, PREFIX_SLASH);
        changed = true;
    }

    // Placeholder rewrites (rpath, DT_NEEDED, interpreter, .rodata) — all
    // strictly shorter via the /opt/nb short prefix, so the same in-place
    // strategy covers everything patchelf used to do for us, in one pass.
    var needs_patchelf = false;
    if (has_placeholder) {
        short.rewriteAllInPlace(data, paths.PLACEHOLDER_REPOSITORY, paths.REAL_REPOSITORY);
        changed = true;
        if (short.ensureShortPrefixLink(io)) {
            short.rewriteAllInPlace(data, paths.PLACEHOLDER_CELLAR, short.SHORT_CELLAR);
            short.rewriteAllInPlace(data, paths.PLACEHOLDER_PREFIX, short.SHORT_PREFIX);
            // @@HOMEBREW_LIBRARY@@ and friends may remain in .rodata; they
            // are not linkage-relevant and were never patched before either.
        } else {
            // No short prefix available (e.g. non-root upgrade of an old
            // install): PREFIX/CELLAR can't shrink in place — fall back to
            // patchelf for rpath/needed/interp on this file. .rodata
            // placeholders stay foreign either way, so record the file as
            // incompletely relocated (#355/#356).
            needs_patchelf = true;
            short.noteIncompleteFile();
        }
    }

    // Repair PT_INTERP when the (rewritten) interpreter points into the
    // nanobrew tree but doesn't exist (no glibc keg installed): swap in the
    // system loader for the binary's actual architecture.
    if (!needs_patchelf) {
        if (fixInterpreterInPlace(io, data)) changed = true;
    }

    if (changed) {
        file.writePositionalAll(io, data, 0) catch return;
    }
    file.close(io);
    file_open = false;

    if (needs_patchelf) {
        ensurePatchelf(alloc, io) catch {
            ({
                const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: {s}: patchelf unavailable and /opt/nb not creatable — run `sudo $(command -v nb) init` and reinstall\n", .{path}) catch "";
                defer std.heap.smp_allocator.free(_tmp);
                std.Io.File.stderr().writeStreamingAll(io, _tmp) catch {};
            });
            if (lifted) short.restoreMode(io, path, orig_mode);
            return;
        };
        // patchelf may rewrite the file in place, so the write-bit lift
        // stays active until it is done.
        patchInterpreter(alloc, io, path);
        patchelfRelocateRpathAndNeeded(alloc, io, path);
    }
    if (lifted) short.restoreMode(io, path, orig_mode);
}

/// In-place byte rewriting (`short.rewriteAllInPlace`) lives in
/// platform/short_prefix.zig, shared with the Mach-O relocator. The
/// '/'-padding strategy is POSIX-valid for C-string consumers (ld.so,
/// dlopen, execve, dyld) and length-delimited ones (perl @INC sizes).
/// Find PT_INTERP in a 64-bit little-endian ELF and, when the interpreter
/// points into the nanobrew tree but the file doesn't exist, overwrite it
/// in place with the system loader for the binary's architecture. Returns
/// true when the buffer was modified.
fn fixInterpreterInPlace(io: std.Io, data: []u8) bool {
    if (data.len < 64) return false;
    if (data[4] != 2 or data[5] != 1) return false; // ELFCLASS64, little-endian only

    const e_phoff = std.mem.readInt(u64, data[32..40], .little);
    const e_phentsize = std.mem.readInt(u16, data[54..56], .little);
    const e_phnum = std.mem.readInt(u16, data[56..58], .little);
    if (e_phentsize < 56 or e_phnum == 0) return false;

    var idx: usize = 0;
    while (idx < e_phnum) : (idx += 1) {
        const off_u64 = e_phoff + @as(u64, idx) * e_phentsize;
        if (off_u64 + 56 > data.len) return false;
        const off: usize = @intCast(off_u64);
        const p_type = std.mem.readInt(u32, data[off..][0..4], .little);
        if (p_type != 3) continue; // PT_INTERP

        const p_offset = std.mem.readInt(u64, data[off + 8 ..][0..8], .little);
        const p_filesz = std.mem.readInt(u64, data[off + 32 ..][0..8], .little);
        if (p_filesz == 0 or p_filesz > 4096 or p_offset + p_filesz > data.len) return false;
        const seg = data[@intCast(p_offset)..][0..@intCast(p_filesz)];
        const interp_len = std.mem.indexOfScalar(u8, seg, 0) orelse return false;
        const interp = seg[0..interp_len];

        // Only repair interpreters that point into our tree; system loaders
        // and unrewritten (still-placeholder'd) paths are left alone.
        const ours = std.mem.startsWith(u8, interp, short.SHORT_PREFIX ++ "/") or
            std.mem.startsWith(u8, interp, paths.ROOT ++ "/");
        if (!ours) return false;

        if (std.Io.Dir.accessAbsolute(io, interp, .{})) |_| {
            return false; // exists (glibc keg installed) — keep it
        } else |_| {}

        const sys = systemInterpreterFor(data) orelse return false;
        if (sys.len + 1 > seg.len) return false;
        @memcpy(seg[0..sys.len], sys);
        @memset(seg[sys.len..], 0);
        return true;
    }
    return false;
}

/// System dynamic linker for the ELF buffer's e_machine.
fn systemInterpreterFor(data: []const u8) ?[]const u8 {
    if (data.len < 20) return null;
    const e_machine = std.mem.readInt(u16, data[18..20], .little);
    return switch (e_machine) {
        0xB7 => "/lib/ld-linux-aarch64.so.1", // EM_AARCH64
        0x3E => "/lib64/ld-linux-x86-64.so.2", // EM_X86_64
        0x03 => "/lib/ld-linux.so.2", // EM_386
        else => null,
    };
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

    return systemInterpreterFor(&header);
}

const testing = std.testing;

test "hasElfMagic identifies only complete ELF headers" {
    try testing.expect(hasElfMagic(&ELF_MAGIC));
    try testing.expect(!hasElfMagic("\x7fEL"));
    try testing.expect(!hasElfMagic("not an ELF file"));
}

test "rewriteAllInPlace - single occurrence pads with slashes, offsets and length preserved" {
    var buf = "xx@@HOMEBREW_PREFIX@@/lib\x00yy".*;
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_PREFIX@@", "/opt/nb");
    // Replacement + '/'-padding + untouched tail: same strlen as the original,
    // NUL in its original position, trailing bytes untouched.
    const expected = "/opt/nb" ++ @as([12]u8, @splat('/')) ++ "/lib";
    try testing.expectEqualStrings(expected, std.mem.sliceTo(buf[2..], 0));
    try testing.expectEqual(@as(u8, 0), buf[2 + expected.len]);
    try testing.expectEqual(@as(u8, 'y'), buf[buf.len - 2]);
    try testing.expectEqual(@as(u8, 'y'), buf[buf.len - 1]);
}

test "rewriteAllInPlace - two placeholders inside one colon-separated rpath string" {
    var buf = "@@HOMEBREW_CELLAR@@/x265/4.0/lib:@@HOMEBREW_PREFIX@@/lib\x00tail".*;
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_CELLAR@@", "/opt/nb/Cellar");
    short.rewriteAllInPlace(&buf, "@@HOMEBREW_PREFIX@@", "/opt/nb");
    const expected = "/opt/nb/Cellar" ++ @as([5]u8, @splat('/')) ++ "/x265/4.0/lib:/opt/nb" ++ @as([12]u8, @splat('/')) ++ "/lib";
    try testing.expectEqualStrings(expected, std.mem.sliceTo(&buf, 0));
    // bytes after the original string's NUL are untouched
    try testing.expectEqualStrings("tail", buf[buf.len - 4 ..]);
}

test "rewriteAllInPlace - linuxbrew literal pads at the path boundary" {
    var buf = "a/home/linuxbrew/.linuxbrew/lib\x00".*;
    short.rewriteAllInPlace(&buf, "/home/linuxbrew/.linuxbrew/", "/opt/nanobrew/prefix/");
    try testing.expectEqualStrings("/opt/nanobrew/prefix" ++ @as([7]u8, @splat('/')) ++ "lib", std.mem.sliceTo(buf[1..], 0));
}

test "rewriteAllInPlace - no NULs inside the rewritten string (perl @INC regression)" {
    // perl reads its compiled-in @INC entries with compile-time sizeof
    // lengths, not strlen — embedded NULs inside the original string extent
    // broke module resolution ("Can't locate strict.pm in @INC").
    var buf = "/home/linuxbrew/.linuxbrew/lib/perl5/site_perl/5.42.2\x00".*;
    short.rewriteAllInPlace(&buf, "/home/linuxbrew/.linuxbrew/", "/opt/nanobrew/prefix/");
    const extent = buf[0 .. buf.len - 1]; // original string, original length
    try testing.expect(std.mem.indexOfScalar(u8, extent, 0) == null);
    try testing.expectEqualStrings("/opt/nanobrew/prefix" ++ @as([7]u8, @splat('/')) ++ "lib/perl5/site_perl/5.42.2", extent);
}

test "fixInterpreterInPlace - swaps missing /opt/nb interpreter for system loader" {
    // Minimal synthetic ELF64-LE x86_64: ehdr (64B) + one PT_INTERP phdr
    // (56B) + interp segment.
    const interp = "/opt/nb/lib/ld.so";
    const ehdr_size = 64;
    const phdr_size = 56;
    const interp_off = ehdr_size + phdr_size;
    const interp_sz = interp.len + 8; // room for NUL + padding
    var img: [ehdr_size + phdr_size + interp_sz]u8 = @splat(0);

    @memcpy(img[0..4], &ELF_MAGIC);
    img[4] = 2; // ELFCLASS64
    img[5] = 1; // little-endian
    std.mem.writeInt(u16, img[18..20], 0x3E, .little); // EM_X86_64
    std.mem.writeInt(u64, img[32..40], ehdr_size, .little); // e_phoff
    std.mem.writeInt(u16, img[54..56], phdr_size, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 1, .little); // e_phnum

    std.mem.writeInt(u32, img[ehdr_size..][0..4], 3, .little); // PT_INTERP
    std.mem.writeInt(u64, img[ehdr_size + 8 ..][0..8], interp_off, .little); // p_offset
    std.mem.writeInt(u64, img[ehdr_size + 32 ..][0..8], interp_sz, .little); // p_filesz
    @memcpy(img[interp_off..][0..interp.len], interp);

    try testing.expect(fixInterpreterInPlace(testing.io, &img));
    try testing.expectEqualStrings("/lib64/ld-linux-x86-64.so.2", std.mem.sliceTo(img[interp_off..], 0));
    // last byte of the segment stays NUL (kernel requires it)
    try testing.expectEqual(@as(u8, 0), img[interp_off + interp_sz - 1]);
}

test "fixInterpreterInPlace - leaves existing system interpreter alone" {
    const interp = "/usr/lib/ld-something.so.2";
    const ehdr_size = 64;
    const phdr_size = 56;
    const interp_off = ehdr_size + phdr_size;
    const interp_sz = interp.len + 1;
    var img: [ehdr_size + phdr_size + interp_sz]u8 = @splat(0);

    @memcpy(img[0..4], &ELF_MAGIC);
    img[4] = 2;
    img[5] = 1;
    std.mem.writeInt(u16, img[18..20], 0x3E, .little);
    std.mem.writeInt(u64, img[32..40], ehdr_size, .little);
    std.mem.writeInt(u16, img[54..56], phdr_size, .little);
    std.mem.writeInt(u16, img[56..58], 1, .little);
    std.mem.writeInt(u32, img[ehdr_size..][0..4], 3, .little);
    std.mem.writeInt(u64, img[ehdr_size + 8 ..][0..8], interp_off, .little);
    std.mem.writeInt(u64, img[ehdr_size + 32 ..][0..8], interp_sz, .little);
    @memcpy(img[interp_off..][0..interp.len], interp);

    try testing.expect(!fixInterpreterInPlace(testing.io, &img));
    try testing.expectEqualStrings(interp, std.mem.sliceTo(img[interp_off..], 0));
}
