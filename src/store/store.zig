// nanobrew — Content-addressable store
//
// Extracted bottle contents live at:
//   /opt/nanobrew/store/<sha256>/
//
// Each entry contains the full unpacked Homebrew keg.
// The store is deduplicated: same SHA256 = same content.

const std = @import("std");
const tar = @import("../extract/tar.zig");

const STORE_DIR = "/opt/nanobrew/store";

/// Ensure a store entry exists for the given SHA256.
/// If not, extract the blob tarball into the store.
pub fn ensureEntry(alloc: std.mem.Allocator, blob_path: []const u8, sha256: []const u8) !void {
    var dir_buf: [512]u8 = undefined;
    const store_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return error.PathTooLong;

    // Already extracted?
    std.fs.accessAbsolute(store_path, .{}) catch {
        // Need to extract
        try tar.extractToStore(alloc, blob_path, sha256);
        return;
    };
}

/// Check if a store entry exists.
pub fn hasEntry(sha256: []const u8) bool {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return false;
    std.fs.accessAbsolute(p, .{}) catch return false;
    return true;
}

/// Get the store path for an entry.
pub fn entryPath(sha256: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch "";
}

/// Remove a store entry (when refcount drops to 0).
pub fn removeEntry(sha256: []const u8) void {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ STORE_DIR, sha256 }) catch return;
    std.fs.deleteTreeAbsolute(p) catch {};
}
