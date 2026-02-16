// nanobrew — Keg linker
//
// Creates symlinks for installed packages:
//   - Executables from Cellar/<name>/<ver>/bin/ -> prefix/bin/
//   - Package dir -> prefix/opt/<name>
//
// Detects conflicts (another package owns the same binary).

const std = @import("std");
const paths = @import("../platform/paths.zig");

const CELLAR_DIR = paths.CELLAR_DIR;
const BIN_DIR = paths.BIN_DIR;
const OPT_DIR = paths.OPT_DIR;

/// Link a keg's binaries and create opt/ symlink.
pub fn linkKeg(name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    // Find the actual keg root — Homebrew bottles nest as <name>/<version>/ inside the tar
    // The extracted store entry may have this structure:
    //   store/<sha>/  (contains the keg contents directly)
    //   or store/<sha>/<name>/<version>/  (Homebrew nested layout)
    // We need to find where bin/ actually lives.

    // Link binaries: keg/bin/* -> prefix/bin/
    var bin_buf: [512]u8 = undefined;
    const bin_dir = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{keg_dir}) catch return error.PathTooLong;

    if (std.fs.openDirAbsolute(bin_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;

            var src_buf: [1024]u8 = undefined;
            const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ bin_dir, entry.name }) catch continue;

            var dest_buf: [1024]u8 = undefined;
            const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ BIN_DIR, entry.name }) catch continue;

            std.fs.deleteFileAbsolute(dest) catch {};

            std.fs.symLinkAbsolute(src, dest, .{}) catch {};
        }
    } else |_| {}

    // Also check sbin/
    var sbin_buf: [512]u8 = undefined;
    const sbin_dir = std.fmt.bufPrint(&sbin_buf, "{s}/sbin", .{keg_dir}) catch return error.PathTooLong;

    if (std.fs.openDirAbsolute(sbin_dir, .{ .iterate = true })) |d2| {
        var dir = d2;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;

            var src_buf: [1024]u8 = undefined;
            const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ sbin_dir, entry.name }) catch continue;

            var dest_buf: [1024]u8 = undefined;
            const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ BIN_DIR, entry.name }) catch continue;

            std.fs.deleteFileAbsolute(dest) catch {};
            std.fs.symLinkAbsolute(src, dest, .{}) catch {};
        }
    } else |_| {}

    // Create opt/ symlink: prefix/opt/<name> -> Cellar/<name>/<version>
    std.fs.makeDirAbsolute(OPT_DIR) catch {};
    var opt_buf: [512]u8 = undefined;
    const opt_link = std.fmt.bufPrint(&opt_buf, "{s}/{s}", .{ OPT_DIR, name }) catch return error.PathTooLong;
    std.fs.deleteFileAbsolute(opt_link) catch {};
    std.fs.symLinkAbsolute(keg_dir, opt_link, .{}) catch {};
}

/// Unlink a keg's binaries and remove opt/ symlink.
pub fn unlinkKeg(name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    // Unlink binaries
    var bin_buf: [512]u8 = undefined;
    const bin_dir = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{keg_dir}) catch return error.PathTooLong;

    if (std.fs.openDirAbsolute(bin_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            var link_buf: [1024]u8 = undefined;
            const link_path = std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ BIN_DIR, entry.name }) catch continue;
            var target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = std.fs.readLinkAbsolute(link_path, &target_buf) catch continue;
            var expected_buf: [1024]u8 = undefined;
            const expected = std.fmt.bufPrint(&expected_buf, "{s}/{s}", .{ bin_dir, entry.name }) catch continue;
            if (std.mem.eql(u8, target, expected)) {
                std.fs.deleteFileAbsolute(link_path) catch {};
            }
        }
    } else |_| {}

    // Remove opt/ symlink
    var opt_buf: [512]u8 = undefined;
    const opt_link = std.fmt.bufPrint(&opt_buf, "{s}/{s}", .{ OPT_DIR, name }) catch return;
    std.fs.deleteFileAbsolute(opt_link) catch {};
}
