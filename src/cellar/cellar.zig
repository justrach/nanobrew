// nanobrew — Cellar materialization via APFS clonefile(2)
//
// Materializes package kegs from the store into:
//   /opt/nanobrew/prefix/Cellar/<name>/<version>/
//
// Uses the macOS clonefile(2) syscall directly for zero-cost APFS copy-on-write.
// No process spawns — single syscall per package.

const std = @import("std");

const STORE_DIR = "/opt/nanobrew/store";
const CELLAR_DIR = "/opt/nanobrew/prefix/Cellar";

// macOS clonefile(2) — direct syscall, no process spawn
extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: c_uint) c_int;
const CLONE_NOFOLLOW: c_uint = 0x0001;
const CLONE_NOOWNERCOPY: c_uint = 0x0002;

/// Materialize a keg from the store into the Cellar.
pub fn materialize(sha256: []const u8, name: []const u8, version: []const u8) !void {
    var name_dir_buf: [512]u8 = undefined;
    const name_dir = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}/{s}", .{ STORE_DIR, sha256, name }) catch return error.PathTooLong;

    var ver_buf: [256]u8 = undefined;
    const actual_version = detectStoreVersion(name_dir, version, &ver_buf) orelse version;

    var src_buf: [512]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ name_dir, actual_version }) catch return error.PathTooLong;

    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, actual_version }) catch return error.PathTooLong;

    // Ensure parent dir exists
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ CELLAR_DIR, name }) catch return error.PathTooLong;
    std.fs.makeDirAbsolute(parent_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Remove existing keg if present
    std.fs.deleteTreeAbsolute(dest_dir) catch {};

    // clonefile(2) — single syscall, clones entire directory tree with APFS COW
    var src_z: [512:0]u8 = undefined;
    @memcpy(src_z[0..src_dir.len], src_dir);
    src_z[src_dir.len] = 0;

    var dst_z: [512:0]u8 = undefined;
    @memcpy(dst_z[0..dest_dir.len], dest_dir);
    dst_z[dest_dir.len] = 0;

    const rc = clonefile(&src_z, &dst_z, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY);
    if (rc == 0) return;

    // Fallback: cp -R if clonefile fails (non-APFS filesystem)
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "cp", "-R", src_dir, dest_dir },
    }) catch return error.CopyFailed;
    std.heap.page_allocator.free(result.stdout);
    std.heap.page_allocator.free(result.stderr);
}

/// Find the actual installed version for a keg in the Cellar.
pub fn detectKegVersion(name: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ CELLAR_DIR, name }) catch return null;
    return detectStoreVersion(parent_dir, version, result_buf);
}

/// Remove a keg from the Cellar.
pub fn remove(name: []const u8, version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;
    std.fs.deleteTreeAbsolute(keg_dir) catch {};

    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ CELLAR_DIR, name }) catch return;
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
