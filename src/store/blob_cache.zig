// nanobrew — Content-addressable blob cache
//
// Downloaded bottle tarballs are stored at:
//   /opt/nanobrew/cache/blobs/<sha256>
//
// This module provides path resolution and cache queries.

const std = @import("std");

const BLOBS_DIR = "/opt/nanobrew/cache/blobs";

/// Get the full path for a cached blob by SHA256.
pub fn blobPath(sha256: []const u8) []const u8 {
    return blobPathBuf(sha256) catch "";
}

var path_buf: [512]u8 = undefined;

fn blobPathBuf(sha256: []const u8) ![]const u8 {
    return std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ BLOBS_DIR, sha256 });
}

/// Check if a blob exists in the cache.
pub fn has(sha256: []const u8) bool {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ BLOBS_DIR, sha256 }) catch return false;
    std.fs.accessAbsolute(p, .{}) catch return false;
    return true;
}

/// Remove a blob from cache (e.g. after corruption).
pub fn evict(sha256: []const u8) void {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ BLOBS_DIR, sha256 }) catch return;
    std.fs.deleteFileAbsolute(p) catch {};
}
