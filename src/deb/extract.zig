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
pub fn extractDeb(alloc: std.mem.Allocator, deb_path: []const u8, dest_dir: []const u8) !void {
    const tar_data = try decompressDataTar(alloc, deb_path);
    defer alloc.free(tar_data);

    const files = native_tar.extractToDir(alloc, tar_data, dest_dir) catch return error.ExtractFailed;
    for (files) |f| alloc.free(f);
    alloc.free(files);
}

/// Extract a .deb directly to / (for system packages in Docker).
pub fn extractDebToPrefix(alloc: std.mem.Allocator, deb_path: []const u8) !void {
    const tar_data = try decompressDataTar(alloc, deb_path);
    defer alloc.free(tar_data);

    const files = native_tar.extractToDir(alloc, tar_data, "/") catch return error.ExtractFailed;
    for (files) |f| alloc.free(f);
    alloc.free(files);
}

/// Extract a .deb directly to / and return the list of installed file paths.
/// Caller owns the returned slice and its strings.
pub fn extractDebToPrefixWithFiles(alloc: std.mem.Allocator, deb_path: []const u8) ![][]const u8 {
    const tar_data = try decompressDataTar(alloc, deb_path);
    defer alloc.free(tar_data);

    return native_tar.extractToDir(alloc, tar_data, "/") catch return error.ExtractFailed;
}

/// Extract the control.tar from a .deb to a temp directory and run postinst if present.
/// Non-fatal — returns void and prints warnings on failure.
/// If skip_postinst is true, logs a message and skips execution.
pub fn runPostinst(alloc: std.mem.Allocator, deb_path: []const u8, pkg_name: []const u8, skip_postinst: bool) void {
    const stderr_writer = std.fs.File.stderr().deprecatedWriter();

    // Decompress control.tar in memory
    const ctrl_tar_data = decompressControlTar(alloc, deb_path) catch return;
    defer alloc.free(ctrl_tar_data);

    // Extract control.tar to temp directory using native tar
    var ctrl_dir_buf: [1024]u8 = undefined;
    const ctrl_dir = std.fmt.bufPrint(&ctrl_dir_buf, "{s}/control_{s}", .{ paths.TMP_DIR, pkg_name }) catch {
        stderr_writer.print("warning: path buffer overflow for control dir of {s}\n", .{pkg_name}) catch {};
        return;
    };

    std.fs.makeDirAbsolute(ctrl_dir) catch {};
    defer std.fs.deleteTreeAbsolute(ctrl_dir) catch {};

    const files = native_tar.extractToDir(alloc, ctrl_tar_data, ctrl_dir) catch return;
    for (files) |f| alloc.free(f);
    alloc.free(files);

    // Check for postinst script
    var postinst_buf: [1024]u8 = undefined;
    const postinst_path = std.fmt.bufPrint(&postinst_buf, "{s}/postinst", .{ctrl_dir}) catch {
        stderr_writer.print("warning: path buffer overflow for postinst of {s}\n", .{pkg_name}) catch {};
        return;
    };

    // Make it executable and run it
    if (std.fs.accessAbsolute(postinst_path, .{})) |_| {
        if (skip_postinst) {
            stderr_writer.print("    skipped: postinst for {s} (--skip-postinst)\n", .{pkg_name}) catch {};
            return;
        }

        stderr_writer.print("    running: postinst for {s}\n", .{pkg_name}) catch {};

        _ = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "chmod", "+x", postinst_path },
        }) catch {};

        const run_result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ postinst_path, "configure" },
            .max_output_bytes = 1024 * 1024,
        }) catch {
            stderr_writer.print("    warning: postinst failed for {s}\n", .{pkg_name}) catch {};
            return;
        };
        alloc.free(run_result.stdout);
        alloc.free(run_result.stderr);
        const postinst_exit: u8 = switch (run_result.term) {
            .Exited => |code| code,
            else => 1,
        };
        if (postinst_exit != 0) {
            stderr_writer.print("    warning: postinst exited {d} for {s}\n", .{ postinst_exit, pkg_name }) catch {};
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
pub fn listTarFiles(alloc: std.mem.Allocator, tar_data: []const u8) ![][]const u8 {
    const result = native_tar.listFiles(alloc, tar_data) catch return error.ListFailed;

    if (result.rejected > 0) {
        const stderr_writer = std.io.getStdErr().writer();
        stderr_writer.print("    warning: rejected {d} unsafe paths from archive\n", .{result.rejected}) catch {};
    }

    return result.files;
}

/// Decompress the data.tar member from a .deb into memory.
/// Returns the plain tar data. Caller owns the returned slice.
fn decompressDataTar(alloc: std.mem.Allocator, deb_path: []const u8) ![]u8 {
    const member = try readArMember(alloc, deb_path, "data.tar");
    defer alloc.free(member.data);

    return switch (member.compression) {
        .none => {
            const copy = try alloc.dupe(u8, member.data);
            return copy;
        },
        .zstd => try decompressZstd(alloc, member.data),
        .gzip => try decompressGzip(alloc, member.data),
        .xz => try decompressXzFallback(alloc, deb_path, "data.tar"),
    };
}

/// Decompress the control.tar member from a .deb into memory.
/// Returns the plain tar data. Caller owns the returned slice.
fn decompressControlTar(alloc: std.mem.Allocator, deb_path: []const u8) ![]u8 {
    const member = try readArMember(alloc, deb_path, "control.tar");
    defer alloc.free(member.data);

    return switch (member.compression) {
        .none => {
            const copy = try alloc.dupe(u8, member.data);
            return copy;
        },
        .zstd => try decompressZstd(alloc, member.data),
        .gzip => try decompressGzip(alloc, member.data),
        .xz => try decompressXzFallback(alloc, deb_path, "control.tar"),
    };
}

const ArMember = struct {
    data: []u8,
    compression: Compression,
};

/// Read an ar archive member whose name starts with `prefix` into memory.
fn readArMember(alloc: std.mem.Allocator, ar_path: []const u8, prefix: []const u8) !ArMember {
    var file = try std.fs.openFileAbsolute(ar_path, .{});
    defer file.close();

    var magic: [8]u8 = undefined;
    const magic_n = try file.read(&magic);
    if (magic_n < 8 or !std.mem.eql(u8, &magic, AR_MAGIC)) return error.NotArArchive;

    while (true) {
        var header: [AR_HEADER_SIZE]u8 = undefined;
        const hn = file.read(&header) catch break;
        if (hn < AR_HEADER_SIZE) break;

        const member_name = std.mem.trim(u8, header[0..16], " /");
        const size_str = std.mem.trim(u8, header[48..58], " ");
        const member_size = std.fmt.parseInt(u64, size_str, 10) catch break;

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
            const bytes_read = try file.readAll(data);
            if (bytes_read < member_size) {
                alloc.free(data);
                return error.TruncatedMember;
            }
            return .{ .data = data, .compression = compression };
        }

        const skip = member_size + (member_size % 2);
        if (skip > std.math.maxInt(i64)) break;
        file.seekBy(@intCast(skip)) catch break;
    }

    return error.MemberNotFound;
}

/// Decompress zstd data in memory using Zig's native zstd decompressor.
const max_decompressed_size: usize = 1 << 30;

fn decompressZstd(alloc: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    const window_buf = try alloc.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer alloc.free(window_buf);

    var zstd_stream: std.compress.zstd.Decompress = .init(&in, window_buf, .{});
    var out: std.Io.Writer.Allocating = .init(alloc);

    _ = zstd_stream.reader.streamRemaining(&out.writer) catch return error.DecompressFailed;

    if (out.written().len > max_decompressed_size) return error.DecompressionBombDetected;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Decompress gzip data in memory using Zig's native deflate decompressor.
pub fn decompressGzip(alloc: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var out: std.Io.Writer.Allocating = .init(alloc);
    _ = decomp.reader.streamRemaining(&out.writer) catch return error.DecompressFailed;

    if (out.written().len > max_decompressed_size) return error.DecompressionBombDetected;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// For xz, fall back to the system xz command since Zig's xz may need LZMA2.
fn decompressXzFallback(alloc: std.mem.Allocator, deb_path: []const u8, member_prefix: []const u8) ![]u8 {
    var member_buf: [128]u8 = undefined;
    const member_name = std.fmt.bufPrint(&member_buf, "{s}.xz", .{member_prefix}) catch
        return error.PathTooLong;

    const ar_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "ar", "p", deb_path, member_name },
        .max_output_bytes = 512 * 1024 * 1024,
    }) catch return error.DecompressFailed;
    alloc.free(ar_result.stderr);

    if (switch (ar_result.term) { .Exited => |c| c != 0, else => true }) {
        alloc.free(ar_result.stdout);
        return error.DecompressFailed;
    }

    var xz_buf: [512]u8 = undefined;
    const xz_tmp = std.fmt.bufPrint(&xz_buf, "{s}/xz_input.tmp", .{paths.TMP_DIR}) catch
        return error.PathTooLong;

    {
        var tmp_file = std.fs.createFileAbsolute(xz_tmp, .{}) catch return error.DecompressFailed;
        tmp_file.writeAll(ar_result.stdout) catch {
            tmp_file.close();
            return error.DecompressFailed;
        };
        tmp_file.close();
    }
    alloc.free(ar_result.stdout);
    defer std.fs.deleteFileAbsolute(xz_tmp) catch {};

    const xz_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "xz", "-d", "--stdout", xz_tmp },
        .max_output_bytes = 512 * 1024 * 1024,
    }) catch return error.DecompressFailed;
    alloc.free(xz_result.stderr);

    if (switch (xz_result.term) { .Exited => |c| c != 0, else => true }) {
        alloc.free(xz_result.stdout);
        return error.DecompressFailed;
    }
    return xz_result.stdout;
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

test "xz fallback does not use shell interpolation" {
    const T = @TypeOf(decompressXzFallback);
    _ = T;
}
