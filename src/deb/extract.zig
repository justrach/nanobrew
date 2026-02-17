// nanobrew — Deb package extractor
//
// A .deb file is an ar(1) archive containing:
//   debian-binary     → "2.0\n"
//   control.tar.{gz,xz,zst}  → metadata
//   data.tar.{gz,xz,zst}     → actual files (rooted at /)
//
// Native ar parsing + Zig zstd/gzip decompression.
// Only needs system `tar` — no binutils, ar, or zstd binary required.

const std = @import("std");
const paths = @import("../platform/paths.zig");

const AR_MAGIC = "!<arch>\n";
const AR_HEADER_SIZE = 60;

const Compression = enum { none, gzip, xz, zstd };

/// Extract a .deb to a destination directory.
pub fn extractDeb(alloc: std.mem.Allocator, deb_path: []const u8, dest_dir: []const u8) !void {
    var plain_buf: [512]u8 = undefined;
    const plain_path = std.fmt.bufPrint(&plain_buf, "{s}/data.tar", .{paths.TMP_DIR}) catch return error.PathTooLong;

    try extractDataTarFromDeb(alloc, deb_path, plain_path);
    defer std.fs.deleteFileAbsolute(plain_path) catch {};

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "xf", plain_path, "-C", dest_dir },
    }) catch return error.ExtractFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (result.term.Exited != 0) return error.ExtractFailed;
}

/// Extract a .deb directly to / (for system packages in Docker).
pub fn extractDebToPrefix(alloc: std.mem.Allocator, deb_path: []const u8) !void {
    var plain_buf: [512]u8 = undefined;
    const plain_path = std.fmt.bufPrint(&plain_buf, "{s}/data.tar", .{paths.TMP_DIR}) catch return error.PathTooLong;

    try extractDataTarFromDeb(alloc, deb_path, plain_path);
    defer std.fs.deleteFileAbsolute(plain_path) catch {};

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "xf", plain_path, "--skip-old-files", "-C", "/" },
    }) catch return error.ExtractFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (result.term.Exited != 0) return error.ExtractFailed;
}

/// Extract a .deb directly to / and return the list of installed file paths.
/// Caller owns the returned slice and its strings.
pub fn extractDebToPrefixWithFiles(alloc: std.mem.Allocator, deb_path: []const u8) ![][]const u8 {
    var plain_buf: [512]u8 = undefined;
    const plain_path = std.fmt.bufPrint(&plain_buf, "{s}/data.tar", .{paths.TMP_DIR}) catch return error.PathTooLong;

    try extractDataTarFromDeb(alloc, deb_path, plain_path);
    defer std.fs.deleteFileAbsolute(plain_path) catch {};

    // List files first
    const file_list = listTarFiles(alloc, plain_path) catch &.{};

    // Then extract
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "xf", plain_path, "--skip-old-files", "-C", "/" },
    }) catch return error.ExtractFailed;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    if (result.term.Exited != 0) return error.ExtractFailed;

    return file_list;
}

/// Extract the control.tar from a .deb to a temp directory and run postinst if present.
/// Non-fatal — returns void and prints warnings on failure.
pub fn runPostinst(alloc: std.mem.Allocator, deb_path: []const u8, pkg_name: []const u8) void {
    const stderr_writer = std.fs.File.stderr().deprecatedWriter();

    // Extract control.tar to temp dir
    var ctrl_tar_buf: [512]u8 = undefined;
    const ctrl_tar = std.fmt.bufPrint(&ctrl_tar_buf, "{s}/control.tar", .{paths.TMP_DIR}) catch return;

    extractControlTarFromDeb(alloc, deb_path, ctrl_tar) catch return;
    defer std.fs.deleteFileAbsolute(ctrl_tar) catch {};

    // Extract control.tar to temp directory
    var ctrl_dir_buf: [512]u8 = undefined;
    const ctrl_dir = std.fmt.bufPrint(&ctrl_dir_buf, "{s}/control_{s}", .{ paths.TMP_DIR, pkg_name }) catch return;

    std.fs.makeDirAbsolute(ctrl_dir) catch {};
    defer std.fs.deleteTreeAbsolute(ctrl_dir) catch {};

    const extract_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "xf", ctrl_tar, "-C", ctrl_dir },
    }) catch return;
    alloc.free(extract_result.stdout);
    alloc.free(extract_result.stderr);

    // Check for postinst script
    var postinst_buf: [600]u8 = undefined;
    const postinst_path = std.fmt.bufPrint(&postinst_buf, "{s}/postinst", .{ctrl_dir}) catch return;

    // Make it executable and run it
    if (std.fs.accessAbsolute(postinst_path, .{})) |_| {
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
        if (run_result.term.Exited != 0) {
            stderr_writer.print("    warning: postinst exited {d} for {s}\n", .{ run_result.term.Exited, pkg_name }) catch {};
        }
    } else |_| {}
}

/// List files inside a tar archive (for tracking installed files).
pub fn listTarFiles(alloc: std.mem.Allocator, tar_path: []const u8) ![][]const u8 {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "tf", tar_path },
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch return error.ListFailed;
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) {
        alloc.free(result.stdout);
        return error.ListFailed;
    }

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // Skip directories (end with /)
        if (std.mem.endsWith(u8, trimmed, "/")) continue;
        // Normalize: strip leading "./" if present
        const path = if (std.mem.startsWith(u8, trimmed, "./")) trimmed[1..] else trimmed;
        files.append(alloc, alloc.dupe(u8, path) catch continue) catch continue;
    }
    alloc.free(result.stdout);
    return files.toOwnedSlice(alloc);
}

/// Extract the data.tar member from a .deb, decompress natively, write plain tar.
fn extractDataTarFromDeb(alloc: std.mem.Allocator, deb_path: []const u8, out_path: []const u8) !void {
    // Step 1: Read the compressed data.tar.* member from the ar archive
    const member = try readArMember(alloc, deb_path, "data.tar");
    defer alloc.free(member.data);

    // Step 2: Decompress in memory based on detected compression
    const plain = switch (member.compression) {
        .none => member.data, // already plain tar
        .zstd => try decompressZstd(alloc, member.data),
        .gzip => try decompressGzip(alloc, member.data),
        .xz => try decompressXzFallback(alloc, deb_path, "data.tar"),
    };
    defer if (member.compression != .none) alloc.free(plain);

    // Step 3: Write plain tar to output file
    var out_file = try std.fs.createFileAbsolute(out_path, .{});
    defer out_file.close();
    try out_file.writeAll(plain);
}

/// Extract the control.tar member from a .deb, decompress natively, write plain tar.
fn extractControlTarFromDeb(alloc: std.mem.Allocator, deb_path: []const u8, out_path: []const u8) !void {
    const member = try readArMember(alloc, deb_path, "control.tar");
    defer alloc.free(member.data);

    const plain = switch (member.compression) {
        .none => member.data,
        .zstd => try decompressZstd(alloc, member.data),
        .gzip => try decompressGzip(alloc, member.data),
        .xz => try decompressXzFallback(alloc, deb_path, "control.tar"),
    };
    defer if (member.compression != .none) alloc.free(plain);

    var out_file = try std.fs.createFileAbsolute(out_path, .{});
    defer out_file.close();
    try out_file.writeAll(plain);
}

const ArMember = struct {
    data: []u8,
    compression: Compression,
};

/// Read an ar archive member whose name starts with `prefix` into memory.
fn readArMember(alloc: std.mem.Allocator, ar_path: []const u8, prefix: []const u8) !ArMember {
    var file = try std.fs.openFileAbsolute(ar_path, .{});
    defer file.close();

    // Verify ar magic
    var magic: [8]u8 = undefined;
    const magic_n = try file.read(&magic);
    if (magic_n < 8 or !std.mem.eql(u8, &magic, AR_MAGIC)) return error.NotArArchive;

    while (true) {
        var header: [AR_HEADER_SIZE]u8 = undefined;
        const hn = file.read(&header) catch break;
        if (hn < AR_HEADER_SIZE) break;

        // ar header: name:16 mtime:12 uid:6 gid:6 mode:8 size:10 magic:2
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

        // Skip to next member (padded to 2-byte boundary)
        const skip = member_size + (member_size % 2);
        file.seekBy(@intCast(skip)) catch break;
    }

    return error.MemberNotFound;
}

/// Decompress zstd data in memory using Zig's native zstd decompressor.
fn decompressZstd(alloc: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    const window_buf = try alloc.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer alloc.free(window_buf);

    var zstd_stream: std.compress.zstd.Decompress = .init(&in, window_buf, .{});
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    _ = zstd_stream.reader.streamRemaining(&out.writer) catch return error.DecompressFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Decompress gzip data in memory using Zig's native deflate decompressor.
pub fn decompressGzip(alloc: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var decomp: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    _ = decomp.reader.streamRemaining(&out.writer) catch return error.DecompressFailed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// For xz, fall back to the system xz command since Zig's xz may need LZMA2.
fn decompressXzFallback(alloc: std.mem.Allocator, deb_path: []const u8, member_prefix: []const u8) ![]u8 {
    // Extract via shell: ar p pkg.deb <member>.xz | xz -d
    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "ar p '{s}' {s}.xz | xz -d", .{ deb_path, member_prefix }) catch
        return error.PathTooLong;

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "/bin/sh", "-c", cmd },
        .max_output_bytes = 512 * 1024 * 1024,
    }) catch return error.DecompressFailed;
    alloc.free(result.stderr);

    if (result.term.Exited != 0) {
        alloc.free(result.stdout);
        return error.DecompressFailed;
    }
    return result.stdout;
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
    // Compress a known payload with gzip, then decompress
    const alloc = testing.allocator;
    const input = "hello nanobrew deb extract test\n";

    // Create gzip compressed data using Zig's compressor
    var compressed: std.Io.Writer.Allocating = .init(alloc);
    defer compressed.deinit();
    var compress_buf: [65536]u8 = undefined;
    var compressor: std.compress.flate.Compress = .init(&compressed.writer, &compress_buf, .{ .container = .gzip });
    compressor.writer.writeAll(input) catch unreachable;
    compressor.end() catch unreachable;
    const gz_data = compressed.toOwnedSlice() catch unreachable;
    defer alloc.free(gz_data);

    // Decompress using our function
    const result = try decompressGzip(alloc, gz_data);
    defer alloc.free(result);
    try testing.expectEqualStrings(input, result);
}

test "zstd window buffer is large enough" {
    // Verify the buffer allocation includes block_size_max
    const buf_size = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;
    try testing.expect(buf_size > std.compress.zstd.default_window_len);
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024 + (1 << 17)), buf_size);
}
