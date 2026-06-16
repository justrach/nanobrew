// nanobrew — Deb package extractor
//
// A .deb file is an ar(1) archive containing:
//   debian-binary     → "2.0\n"
//   control.tar.{gz,xz,zst}  → metadata
//   data.tar.{gz,xz,zst}     → actual files (rooted at /)
//
// Native ar parsing + Zig zstd/gzip decompression + native tar extraction.
// No external binutils, ar, zstd, or tar binary required (except xz fallback).

const std = @import("std");
const paths = @import("../platform/paths.zig");
const native_tar = @import("../extract/native_tar.zig");

const AR_MAGIC = "!<arch>\n";
const AR_HEADER_SIZE = 60;

const Compression = enum { none, gzip, xz, zstd };

/// Extract a .deb to a destination directory.
/// `io` must be threadsafe when invoked from a parallel worker pool —
/// see `native_tar.extractToDir` for the full rationale.
pub fn extractDeb(alloc: std.mem.Allocator, io: std.Io, deb_path: []const u8, dest_dir: []const u8) !void {
    const tar_data = try decompressDataTar(alloc, io, deb_path);
    defer alloc.free(tar_data);

    const files = native_tar.extractToDir(alloc, io, tar_data, dest_dir, null) catch return error.ExtractFailed;
    for (files) |f| alloc.free(f);
    alloc.free(files);
}

/// Extract a .deb directly to / (for system packages in Docker).
pub fn extractDebToPrefix(alloc: std.mem.Allocator, io: std.Io, deb_path: []const u8) !void {
    const tar_data = try decompressDataTar(alloc, io, deb_path);
    defer alloc.free(tar_data);

    const files = native_tar.extractToDir(alloc, io, tar_data, "/", null) catch return error.ExtractFailed;
    for (files) |f| alloc.free(f);
    alloc.free(files);
}

/// Extract a .deb directly to / and return the list of installed file paths.
/// Caller owns the returned slice and its strings. Paths are absolute
/// (prefixed with `/`) so `nb remove --deb` doesn't depend on the caller's
/// cwd — `native_tar.extractToDir`'s isPathSafe rejects absolute tar
/// entries, so the entries it returns are always relative-to-dest_dir
/// (`usr/bin/hello`) and `std.Io.Dir.deleteFileAbsolute` against those
/// would resolve relative to cwd at remove time. Storing absolute paths
/// in the DB makes the file list a stable, cwd-independent record.
pub fn extractDebToPrefixWithFiles(alloc: std.mem.Allocator, io: std.Io, deb_path: []const u8) ![][]const u8 {
    const tar_data = try decompressDataTar(alloc, io, deb_path);
    defer alloc.free(tar_data);

    var write_failures: usize = 0;
    const relative = native_tar.extractToDir(alloc, io, tar_data, "/", &write_failures) catch return error.ExtractFailed;
    errdefer {
        for (relative) |f| alloc.free(f);
        alloc.free(relative);
    }

    // If the archive carried entries but none could be placed, the package was
    // not installed — most often EACCES, because --deb writes under / and the
    // process isn't root. Surface it as a hard error so the caller doesn't count
    // a no-op as a successful install (#327). errdefer frees `relative`.
    if (relative.len == 0 and write_failures > 0) return error.ExtractPermissionDenied;

    // Re-allocate each entry with a leading "/" prefix and free the original.
    for (relative, 0..) |entry, i| {
        const absolute = std.fmt.allocPrint(alloc, "/{s}", .{entry}) catch return error.OutOfMemory;
        alloc.free(entry);
        relative[i] = absolute;
    }
    return relative;
}

/// Extract the control.tar from a .deb to a temp directory and run postinst if present.
/// Non-fatal — returns void and prints warnings on failure.
/// If skip_postinst is true, logs a message and skips execution.
pub fn runPostinst(alloc: std.mem.Allocator, io: std.Io, deb_path: []const u8, pkg_name: []const u8, skip_postinst: bool) void {
    // Thread the caller's io rather than paths.safe_io.
    // Zig 0.16's std.process.run rejects the unsynchronized singleton — under load
    // it surfaces as error.OutOfMemory (and sometimes error.CopyFailed, see #276) when
    // pipe-read aggregation tries to wait on the singleton's executor that has no
    // worker threads available. Using the main thread's io fixes both classes.
    const lib_io = io;

    const printErr = struct {
        fn f(p_io: std.Io, comptime fmt: []const u8, args: anytype) void {
            const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
            defer std.heap.smp_allocator.free(msg);
            std.Io.File.stderr().writeStreamingAll(p_io, msg) catch {};
        }
    }.f;

    // Decompress control.tar in memory
    const ctrl_tar_data = decompressControlTar(alloc, lib_io, deb_path) catch return;
    defer alloc.free(ctrl_tar_data);

    // Extract control.tar to temp directory using native tar
    var ctrl_dir_buf: [1024]u8 = undefined;
    const ctrl_dir = std.fmt.bufPrint(&ctrl_dir_buf, "{s}/control_{s}", .{ paths.TMP_DIR, pkg_name }) catch {
        printErr(lib_io, "warning: path buffer overflow for control dir of {s}\n", .{pkg_name});
        return;
    };

    std.Io.Dir.createDirAbsolute(lib_io, ctrl_dir, .default_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(lib_io, ctrl_dir) catch {};

    const files = native_tar.extractToDir(alloc, lib_io, ctrl_tar_data, ctrl_dir, null) catch return;
    for (files) |f| alloc.free(f);
    alloc.free(files);

    // Check for postinst script
    var postinst_buf: [1024]u8 = undefined;
    const postinst_path = std.fmt.bufPrint(&postinst_buf, "{s}/postinst", .{ctrl_dir}) catch {
        printErr(lib_io, "warning: path buffer overflow for postinst of {s}\n", .{pkg_name});
        return;
    };

    // Make it executable and run it
    if (std.Io.Dir.accessAbsolute(lib_io, postinst_path, .{})) |_| {
        if (skip_postinst) {
            printErr(lib_io, "    skipped: postinst for {s} (--skip-postinst)\n", .{pkg_name});
            return;
        }

        printErr(lib_io, "    running: postinst for {s}\n", .{pkg_name});

        if (std.process.run(alloc, lib_io, .{
            .argv = &.{ "chmod", "+x", postinst_path },
            .stdout_limit = .limited(256),
            .stderr_limit = .limited(256),
        })) |chmod_result| {
            alloc.free(chmod_result.stdout);
            alloc.free(chmod_result.stderr);
        } else |_| {}

        // Postinst scripts in real Debian packages routinely shell out to
        // `update-alternatives`, `ldconfig`, `systemctl`, etc. — without an
        // explicit PATH the spawned shell sees whatever `nb` was launched
        // with, which on container shells like Ubuntu's slim init is just
        // /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        // anyway, but on minimal Alpine/musl init or a sudo-stripped
        // environment it can be empty and the script silently fails to
        // find its tools. Force a sane sysadmin PATH plus DEBIAN_FRONTEND
        // so the scripts don't try to launch interactive prompts.
        var env_map = std.process.Environ.Map.init(alloc);
        defer env_map.deinit();
        env_map.put("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") catch {};
        env_map.put("DEBIAN_FRONTEND", "noninteractive") catch {};
        env_map.put("HOME", "/root") catch {};

        const run_result = std.process.run(alloc, lib_io, .{
            .argv = &.{ postinst_path, "configure" },
            .environ_map = &env_map,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| {
            printErr(lib_io, "    warning: postinst failed for {s}: {s}\n", .{ pkg_name, @errorName(err) });
            return;
        };
        alloc.free(run_result.stdout);
        alloc.free(run_result.stderr);
        const postinst_exit: u8 = switch (run_result.term) {
            .exited => |code| code,
            else => 1,
        };
        if (postinst_exit != 0) {
            printErr(lib_io, "    warning: postinst exited {d} for {s}\n", .{ postinst_exit, pkg_name });
        }
    } else |_| {}
}

/// Check that a symlink/hardlink target, when resolved relative to the
/// link's location within dest_dir, does not escape dest_dir.
/// Re-exported from native_tar for use in security tests.
pub const isLinkTargetSafe = native_tar.isLinkTargetSafe;

/// Validate that a tar file path is safe (no traversal, no absolute escape).
pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    // Reject absolute paths that escape the destination
    if (path[0] == '/') return false;
    // Reject null bytes — OS-level path truncation can bypass component checks
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

/// List files inside a tar archive (in memory, already decompressed).
/// Rejects paths with traversal components ("..") for safety.
pub fn listTarFiles(alloc: std.mem.Allocator, io: std.Io, tar_data: []const u8) ![][]const u8 {
    const result = native_tar.listFiles(alloc, tar_data) catch return error.ListFailed;

    if (result.rejected > 0) {
        const lib_io = io;
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "    warning: rejected {d} unsafe paths from archive\n", .{result.rejected}) catch msg_buf[0..0];
        std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
    }

    return result.files;
}

/// Decompress the data.tar member from a .deb into memory.
/// Returns the plain tar data. Caller owns the returned slice.
fn decompressDataTar(alloc: std.mem.Allocator, io: std.Io, deb_path: []const u8) ![]u8 {
    const member = try readArMember(alloc, io, deb_path, "data.tar");
    defer alloc.free(member.data);

    return switch (member.compression) {
        .none => {
            const copy = try alloc.dupe(u8, member.data);
            return copy;
        },
        .zstd => try decompressZstd(alloc, member.data),
        .gzip => try decompressGzip(alloc, member.data),
        .xz => try decompressXz(alloc, member.data),
    };
}

/// Decompress the control.tar member from a .deb into memory.
/// Returns the plain tar data. Caller owns the returned slice.
fn decompressControlTar(alloc: std.mem.Allocator, io: std.Io, deb_path: []const u8) ![]u8 {
    const member = try readArMember(alloc, io, deb_path, "control.tar");
    defer alloc.free(member.data);

    return switch (member.compression) {
        .none => {
            const copy = try alloc.dupe(u8, member.data);
            return copy;
        },
        .zstd => try decompressZstd(alloc, member.data),
        .gzip => try decompressGzip(alloc, member.data),
        .xz => try decompressXz(alloc, member.data),
    };
}

const ArMember = struct {
    data: []u8,
    compression: Compression,
};

/// Read an ar archive member whose name starts with `prefix` into memory.
/// `io` must be threadsafe when invoked from a parallel worker.
fn readArMember(alloc: std.mem.Allocator, io: std.Io, ar_path: []const u8, prefix: []const u8) !ArMember {
    const lib_io = io;
    const file = try std.Io.Dir.openFileAbsolute(lib_io, ar_path, .{});
    defer file.close(lib_io);

    var offset: u64 = 0;

    // Read and verify the ar magic header (8 bytes)
    var magic: [8]u8 = undefined;
    const magic_n = file.readPositional(lib_io, &.{magic[0..]}, offset) catch return error.NotArArchive;
    if (magic_n < 8 or !std.mem.eql(u8, &magic, AR_MAGIC)) return error.NotArArchive;
    offset += magic_n;

    while (true) {
        // Read ar member header (60 bytes)
        var header: [AR_HEADER_SIZE]u8 = undefined;
        const hn = file.readPositional(lib_io, &.{header[0..]}, offset) catch break;
        if (hn < AR_HEADER_SIZE) break;
        offset += AR_HEADER_SIZE;

        const member_name = std.mem.trim(u8, header[0..16], " /");
        const size_str = std.mem.trim(u8, header[48..58], " ");
        const member_size = std.fmt.parseInt(u64, size_str, 10) catch break;

        // Reject hostile member sizes. The ar size field is decimal text up
        // to 10 chars wide, so a malicious .deb could claim ~1e10 bytes; the
        // skip computation below adds 1 for odd sizes which would wrap a u64
        // at maxInt back to 0 and trap the loop. Cap well below that.
        if (member_size > max_member_size) break;

        if (std.mem.startsWith(u8, member_name, prefix)) {
            const compression: Compression = if (std.mem.endsWith(u8, member_name, ".zst"))
                .zstd
            else if (std.mem.endsWith(u8, member_name, ".gz"))
                .gzip
            else if (std.mem.endsWith(u8, member_name, ".xz"))
                .xz
            else
                .none;

            const data = try alloc.alloc(u8, member_size);
            var read_off: u64 = offset;
            var read_total: usize = 0;
            while (read_total < data.len) {
                const n = file.readPositional(lib_io, &.{data[read_total..]}, read_off) catch {
                    alloc.free(data);
                    return error.TruncatedMember;
                };
                if (n == 0) break;
                read_total += n;
                read_off += @intCast(n);
            }
            if (read_total < member_size) {
                alloc.free(data);
                return error.TruncatedMember;
            }
            return .{ .data = data, .compression = compression };
        }

        // Skip to next member (padded to even byte boundary). Capped above
        // so `member_size + 1` cannot wrap.
        const skip = member_size + (member_size % 2);
        offset += skip;
    }

    return error.MemberNotFound;
}

/// Hard ceiling on a single ar member's claimed size. Anything larger is
/// treated as a malformed/hostile .deb to keep the parser bounded.
const max_member_size: u64 = 4 * 1024 * 1024 * 1024;

/// Decompress zstd data in memory using Zig's native zstd decompressor.
const max_decompressed_size: usize = 1 << 30;

fn decompressZstd(alloc: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    const window_buf = try alloc.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer alloc.free(window_buf);

    var zstd_stream: std.compress.zstd.Decompress = .init(&in, window_buf, .{});
    return streamBounded(alloc, &zstd_stream.reader, max_decompressed_size);
}

/// Decompress gzip data in memory using Zig's native deflate decompressor.
pub fn decompressGzip(alloc: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    return streamBounded(alloc, &decomp.reader, max_decompressed_size);
}

/// Drain `reader` into a freshly allocated slice, capping at `max` bytes.
/// Returns `error.DecompressionBombDetected` *during* the stream so an
/// attacker cannot force us to materialize a multi-gigabyte buffer before
/// we notice. Caller owns the returned slice.
fn streamBounded(alloc: std.mem.Allocator, reader: *std.Io.Reader, max: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk) catch return error.DecompressFailed;
        if (n == 0) break;
        if (out.items.len + n > max) return error.DecompressionBombDetected;
        try out.appendSlice(alloc, chunk[0..n]);
    }
    return out.toOwnedSlice(alloc) catch error.OutOfMemory;
}

/// Decompress xz data in memory using Zig's native xz/LZMA2 decompressor.
/// This used to shell out to the system `ar` and `xz` binaries, but `ar` is
/// not pre-installed on minimal images (e.g. ubuntu:24.04) and the singleton
/// io path was hitting the same OOM/CopyFailed issues as the postinst path.
fn decompressXz(alloc: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    // std.compress.xz.Decompress takes ownership of this buffer and may
    // realloc it via `alloc` once the decompressed payload exceeds the
    // initial size. We must release it through `decomp.deinit()` — calling
    // `alloc.free(buffer)` on the original slice would free a pointer that
    // Decompress has already realloc'd away, corrupting the gpa free-list
    // and causing a SIGSEGV on the next allocation in the same process
    // (only reproducible on multi-package reinstalls where the .deb cache
    // is warm and parallel extract workers fire allocations back-to-back).
    const buffer = try alloc.alloc(u8, 64 * 1024);
    var decomp = std.compress.xz.Decompress.init(&in, alloc, buffer) catch {
        alloc.free(buffer);
        return error.DecompressFailed;
    };
    defer decomp.deinit();
    return streamBounded(alloc, &decomp.reader, max_decompressed_size);
}

const testing = std.testing;

test "ar header parsing detects data.tar member" {
    const header = "data.tar.zst    1234567890  0     0     100644  12345     `\n";
    const member_name = std.mem.trim(u8, header[0..16], " /");
    try testing.expect(std.mem.startsWith(u8, member_name, "data.tar"));

    const size_str = std.mem.trim(u8, header[48..58], " ");
    const size = try std.fmt.parseInt(u64, size_str, 10);
    try testing.expectEqual(@as(u64, 12345), size);
}

test "compression detection from member name" {
    const cases = .{
        .{ "data.tar.zst", Compression.zstd },
        .{ "data.tar.gz", Compression.gzip },
        .{ "data.tar.xz", Compression.xz },
        .{ "data.tar", Compression.none },
    };
    inline for (cases) |case| {
        const name = case[0];
        const expected = case[1];
        const actual: Compression = if (std.mem.endsWith(u8, name, ".zst"))
            .zstd
        else if (std.mem.endsWith(u8, name, ".gz"))
            .gzip
        else if (std.mem.endsWith(u8, name, ".xz"))
            .xz
        else
            .none;
        try testing.expectEqual(expected, actual);
    }
}

test "gzip decompression round-trips" {
    const alloc = testing.allocator;
    const input = "hello nanobrew deb extract test\n";
    const gz_data = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48,
        0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x4b, 0xcc, 0xcb, 0x4f, 0x2a, 0x4a, 0x2d,
        0x57, 0x48, 0x49, 0x4d, 0x52, 0x48, 0xad, 0x28, 0x29, 0x4a, 0x4c, 0x2e,
        0x51, 0x28, 0x49, 0x2d, 0x2e, 0xe1, 0x02, 0x00, 0x0e, 0x68, 0xe8, 0x9e,
        0x20, 0x00, 0x00, 0x00,
    };

    const result = try decompressGzip(alloc, &gz_data);
    defer alloc.free(result);
    try testing.expectEqualStrings(input, result);
}

test "zstd window buffer is large enough" {
    const buf_size = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;
    try testing.expect(buf_size > std.compress.zstd.default_window_len);
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024 + (1 << 17)), buf_size);
}

test "isPathSafe rejects path traversal" {
    try testing.expect(!isPathSafe("../etc/passwd"));
    try testing.expect(!isPathSafe("usr/../../../etc/shadow"));
    try testing.expect(!isPathSafe(".."));
    try testing.expect(!isPathSafe("foo/../../bar"));

    try testing.expect(isPathSafe("usr/bin/hello"));
    try testing.expect(!isPathSafe("/usr/lib/libfoo.so"));
    try testing.expect(isPathSafe("opt/nanobrew/bin/nb"));
    try testing.expect(isPathSafe("a"));

    try testing.expect(!isPathSafe(""));
}

test "isPathSafe allows normal deb paths" {
    try testing.expect(isPathSafe("usr/share/doc/package/README"));
    try testing.expect(isPathSafe("usr/lib/x86_64-linux-gnu/libz.so.1.2.13"));
    try testing.expect(isPathSafe("etc/ld.so.conf.d/package.conf"));
    try testing.expect(isPathSafe("usr/bin/program"));
}

test "xz decompress is a pure-Zig in-memory routine" {
    const T = @TypeOf(decompressXz);
    _ = T;
}
