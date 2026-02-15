// nanobrew — Tar/gzip extraction
//
// Extracts Homebrew bottle tarballs into the content-addressable store.
// v0: Uses system `tar` for extraction (correctness first).
// v1: Will use mmap + Zig flate.Decompress with Container.gzip for zero-copy.

const std = @import("std");

const STORE_DIR = "/opt/nanobrew/store";

/// Extract a gzipped tar blob into the store at store/<sha256>/
pub fn extractToStore(alloc: std.mem.Allocator, blob_path: []const u8, sha256: []const u8) !void {
    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return error.PathTooLong;

    // Skip if already extracted
    std.fs.accessAbsolute(dest_dir, .{}) catch {
        // Doesn't exist — create and extract
        try std.fs.makeDirAbsolute(dest_dir);
        try extractTarGz(alloc, blob_path, dest_dir);
        return;
    };
}

fn extractTarGz(alloc: std.mem.Allocator, blob_path: []const u8, dest_dir: []const u8) !void {
    // v0: shell out to tar for correctness
    // v1: mmap + std.compress.flate.Decompress with .gzip container
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "xzf", blob_path, "-C", dest_dir },
    }) catch return error.TarFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) {
        return error.ExtractionFailed;
    }
}
