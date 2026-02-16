// nanobrew — Cellar materialization via platform-specific COW copy
//
// Materializes package kegs from the store into:
//   /opt/nanobrew/prefix/Cellar/<name>/<version>/
//
// macOS: Uses clonefile(2) for zero-cost APFS copy-on-write.
// Linux: Uses cp --reflink=auto for btrfs/xfs COW, regular cp otherwise.

const std = @import("std");
const paths = @import("../platform/paths.zig");
const copy = @import("../platform/copy.zig");

/// Materialize a keg from the store into the Cellar.
pub fn materialize(sha256: []const u8, name: []const u8, version: []const u8) !void {
    var name_dir_buf: [512]u8 = undefined;
    const name_dir = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}/{s}", .{ paths.STORE_DIR, sha256, name }) catch return error.PathTooLong;

    var ver_buf: [256]u8 = undefined;
    const actual_version = detectStoreVersion(name_dir, version, &ver_buf) orelse version;

    var src_buf: [512]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ name_dir, actual_version }) catch return error.PathTooLong;

    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, actual_version }) catch return error.PathTooLong;

    // Ensure parent dir exists
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return error.PathTooLong;
    std.fs.makeDirAbsolute(parent_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Remove existing keg if present
    std.fs.deleteTreeAbsolute(dest_dir) catch {};

    // Try COW clone first (macOS clonefile / Linux: always false -> fallback)
    var src_z: [512:0]u8 = undefined;
    @memcpy(src_z[0..src_dir.len], src_dir);
    src_z[src_dir.len] = 0;

    var dst_z: [512:0]u8 = undefined;
    @memcpy(dst_z[0..dest_dir.len], dest_dir);
    dst_z[dest_dir.len] = 0;

    if (copy.cloneTree(&src_z, &dst_z)) return;

    // Fallback: cp (--reflink=auto on Linux, plain -R on macOS)
    try copy.cpFallback(src_dir, dest_dir);
}

/// Find the actual installed version for a keg in the Cellar.
pub fn detectKegVersion(name: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return null;
    return detectStoreVersion(parent_dir, version, result_buf);
}

/// Remove a keg from the Cellar.
pub fn remove(name: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;
    std.fs.deleteTreeAbsolute(keg_dir) catch {};

    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return;
    var dir = std.fs.openDirAbsolute(parent_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    if ((iter.next() catch null) == null) {
        std.fs.deleteDirAbsolute(parent_dir) catch {};
    }
}

fn detectStoreVersion(name_dir: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    var exact_buf: [512]u8 = undefined;
    const exact = std.fmt.bufPrint(&exact_buf, "{s}/{s}", .{ name_dir, version }) catch return null;
    if (std.fs.openDirAbsolute(exact, .{})) |d| {
        var dir = d;
        dir.close();
        return version;
    } else |_| {}

    var dir = std.fs.openDirAbsolute(name_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, version)) {
            if (entry.name.len == version.len or
                (entry.name.len > version.len and entry.name[version.len] == '_'))
            {
                if (entry.name.len <= result_buf.len) {
                    @memcpy(result_buf[0..entry.name.len], entry.name);
                    return result_buf[0..entry.name.len];
                }
            }
        }
    }
    return null;
}
