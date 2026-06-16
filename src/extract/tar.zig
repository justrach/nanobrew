// nanobrew — Tar/gzip extraction
//
// Extracts Homebrew bottle tarballs into the content-addressable store.
// Fast path: native std.compress.flate.Decompress + std.tar.pipeToFileSystem.
// Fallback: our own native_tar parser, which handles GNU long-name / pax /
// hardlink entries that std.tar rejects (unzip, perl, postgresql@17 use these).

const std = @import("std");
const paths = @import("../platform/paths.zig");
const store = @import("../store/store.zig");
const native_tar = @import("native_tar.zig");

const STORE_DIR = paths.STORE_DIR;

/// Extract a gzipped tar blob into the store at store/<sha256>/.
/// `io` must be threadsafe when invoked from a parallel install worker —
/// see `native_tar.extractToDir`'s docs.
pub fn extractToStore(alloc: std.mem.Allocator, io: std.Io, blob_path: []const u8, sha256: []const u8) !void {
    const lib_io = io;
    if (!store.isValidSha256(sha256)) return error.InvalidSha256;

    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return error.PathTooLong;

    // Skip if already extracted
    std.Io.Dir.accessAbsolute(lib_io, dest_dir, .{}) catch {
        try std.Io.Dir.createDirAbsolute(lib_io, dest_dir, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(lib_io, dest_dir) catch {};

        extractTarGzNative(lib_io, blob_path, dest_dir) catch {
            // std.tar rejected something it didn't support (typically hardlinks
            // or GNU long-name headers on bottles like unzip, perl,
            // postgresql@17). Retry with our own parser, which handles both.
            std.Io.Dir.cwd().deleteTree(lib_io, dest_dir) catch {};
            try std.Io.Dir.createDirAbsolute(lib_io, dest_dir, .default_dir);
            try extractTarGzOwnParser(alloc, lib_io, blob_path, dest_dir);
        };
        return;
    };
}

/// Native in-process extraction: open blob → flate decompress → tar write.
/// No subprocess, no fork/exec overhead. Saves ~10-20ms per package.
fn extractTarGzNative(io: std.Io, blob_path: []const u8, dest_dir: []const u8) !void {
    const blob = try std.Io.Dir.openFileAbsolute(io, blob_path, .{});
    defer blob.close(io);

    var read_buf: [65536]u8 = undefined;
    var file_reader = blob.readerStreaming(io, &read_buf);

    const flate = std.compress.flate;
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&file_reader.interface, .gzip, &window);

    var dest = try std.Io.Dir.openDirAbsolute(io, dest_dir, .{});
    defer dest.close(io);

    try std.tar.pipeToFileSystem(io, dest, &decomp.reader, .{
        .mode_mode = .executable_bit_only,
    });
}

/// Fallback extraction via nanobrew's own USTAR/GNU tar parser in
/// `native_tar.zig`. Handles hardlinks, GNU long-name headers, and pax entries
/// that `std.tar.pipeToFileSystem` currently rejects. Decompresses the blob
/// into a single buffer first, then walks the archive entries.
fn extractTarGzOwnParser(alloc: std.mem.Allocator, io: std.Io, blob_path: []const u8, dest_dir: []const u8) !void {
    const blob = try std.Io.Dir.openFileAbsolute(io, blob_path, .{});
    defer blob.close(io);

    var read_buf: [65536]u8 = undefined;
    var file_reader = blob.readerStreaming(io, &read_buf);

    const flate = std.compress.flate;
    var window: [flate.max_window_len]u8 = undefined;
    var decomp = flate.Decompress.init(&file_reader.interface, .gzip, &window);

    var tar_bytes: std.ArrayList(u8) = .empty;
    defer tar_bytes.deinit(alloc);

    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch |err| return err;
        if (n == 0) break;
        try tar_bytes.appendSlice(alloc, chunk[0..n]);
    }

    const files = try native_tar.extractToDir(alloc, io, tar_bytes.items, dest_dir, null);
    defer {
        for (files) |f| alloc.free(f);
        alloc.free(files);
    }
}

const testing = std.testing;

test "extractToStore rejects invalid sha256" {
    const lib_io = paths.safe_io;
    try testing.expectError(error.InvalidSha256, extractToStore(testing.allocator, lib_io, "/tmp/blob", "invalid"));
}
