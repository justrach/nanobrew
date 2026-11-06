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
const purge = @import("../platform/purge.zig");

/// Materialize a keg from the store into the Cellar.
pub fn materialize(io: std.Io, sha256: []const u8, name: []const u8, version: []const u8) !void {
    return materializeAt(io, paths.STORE_DIR, paths.CELLAR_DIR, sha256, name, version);
}

fn materializeAt(io: std.Io, store_dir: []const u8, cellar_dir: []const u8, sha256: []const u8, name: []const u8, version: []const u8) !void {
    var name_dir_buf: [512]u8 = undefined;
    const name_dir = std.fmt.bufPrint(&name_dir_buf, "{s}/{s}/{s}", .{ store_dir, sha256, name }) catch return error.PathTooLong;

    var ver_buf: [256]u8 = undefined;
    const actual_version = detectStoreVersion(name_dir, version, &ver_buf) orelse version;

    var src_buf: [512]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ name_dir, actual_version }) catch return error.PathTooLong;

    var dest_buf: [512]u8 = undefined;
    const dest_dir = std.fmt.bufPrint(&dest_buf, "{s}/{s}/{s}", .{ cellar_dir, name, actual_version }) catch return error.PathTooLong;

    // Ensure parent dir exists
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ cellar_dir, name }) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(io, parent_dir, .default_dir) catch {};

    try replaceKeg(io, src_dir, dest_dir);
}

const prev_suffix = ".nb-prev";

/// Copy `src_dir` into a hidden sibling of `dest_dir`, then swap it in with
/// renames. A keg already at `dest_dir` (same-version reinstall) is parked as
/// `.<version>.nb-prev` instead of being deleted first, so a failed copy or a
/// failed later install step (see settlePrevious) never leaves no keg.
pub fn replaceKeg(io: std.Io, src_dir: []const u8, dest_dir: []const u8) !void {
    const parent = std.fs.path.dirname(dest_dir) orelse return error.PathTooLong;
    const base = std.fs.path.basename(dest_dir);
    var src_buf: [512]u8 = undefined;
    const src_z = std.fmt.bufPrintZ(&src_buf, "{s}", .{src_dir}) catch return error.PathTooLong;
    var new_buf: [512]u8 = undefined;
    const new_dir = std.fmt.bufPrintZ(&new_buf, "{s}/.{s}.nb-new", .{ parent, base }) catch return error.PathTooLong;
    var prev_buf: [512]u8 = undefined;
    const prev_dir = std.fmt.bufPrint(&prev_buf, "{s}/.{s}" ++ prev_suffix, .{ parent, base }) catch return error.PathTooLong;
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, new_dir) catch {};
    // Try COW clone first (macOS clonefile / Linux: always false -> fallback)
    if (!copy.cloneTree(src_z, new_dir)) {
        // Fallback: cp (--reflink=auto on Linux, plain -R on macOS).
        // The caller's io must be used here; std.Io.Threaded.global_single_threaded
        // cannot be passed to std.process.run under Zig 0.16 (vtable mismatch
        // surfaces as error.CopyFailed). See issue #276.
        copy.cpFallback(io, src_dir, new_dir) catch |err| {
            cwd.deleteTree(io, new_dir) catch {};
            return err;
        };
    }

    cwd.deleteTree(io, prev_dir) catch {};
    std.Io.Dir.renameAbsolute(dest_dir, prev_dir, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            cwd.deleteTree(io, new_dir) catch {};
            return err;
        },
    };
    std.Io.Dir.renameAbsolute(new_dir, dest_dir, io) catch |err| {
        std.Io.Dir.renameAbsolute(prev_dir, dest_dir, io) catch {};
        cwd.deleteTree(io, new_dir) catch {};
        return err;
    };
}

/// Finish a `replaceKeg` for `name`: drop the parked keg once the install is
/// done, or move it back over the new keg when a later step failed.
pub fn settlePrevious(io: std.Io, name: []const u8, keep_new: bool) void {
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return;
    settlePreviousIn(io, parent, keep_new);
}

fn settlePreviousIn(io: std.Io, parent: []const u8, keep_new: bool) void {
    var prev_buf: [512]u8 = undefined;
    var keg_buf: [512]u8 = undefined;
    const prev, const keg = found: {
        var dir = std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            const n = entry.name;
            if (n.len < prev_suffix.len + 2 or n[0] != '.' or !std.mem.endsWith(u8, n, prev_suffix)) continue;
            break :found .{
                std.fmt.bufPrint(&prev_buf, "{s}/{s}", .{ parent, n }) catch return,
                std.fmt.bufPrint(&keg_buf, "{s}/{s}", .{ parent, n[1 .. n.len - prev_suffix.len] }) catch return,
            };
        }
        return;
    };
    if (keep_new) return purge.deferTreeRemoval(io, prev);
    purge.deferTreeRemoval(io, keg);
    std.Io.Dir.renameAbsolute(prev, keg, io) catch {};
}

/// Find the actual installed version for a keg in the Cellar.
pub fn detectKegVersion(name: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return null;
    return detectStoreVersion(parent_dir, version, result_buf);
}

/// Remove a keg from the Cellar.
pub fn remove(name: []const u8, version: []const u8) !void {
    const lib_io = paths.safe_io;
    var buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;
    if (std.Io.Dir.accessAbsolute(lib_io, keg_dir, .{})) |_| {
        purge.deferTreeRemoval(lib_io, keg_dir);
    } else |_| {}

    var parent_buf: [512]u8 = undefined;
    const parent_dir = std.fmt.bufPrint(&parent_buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return;
    if (std.Io.Dir.openDirAbsolute(lib_io, parent_dir, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        const empty = (iter.next(lib_io) catch null) == null;
        dir.close(lib_io);
        if (empty) {
            std.Io.Dir.deleteDirAbsolute(lib_io, parent_dir) catch {};
        }
    } else |_| {}
}

fn detectStoreVersion(name_dir: []const u8, version: []const u8, result_buf: *[256]u8) ?[]const u8 {
    const lib_io = paths.safe_io;
    var exact_buf: [512]u8 = undefined;
    const exact = std.fmt.bufPrint(&exact_buf, "{s}/{s}", .{ name_dir, version }) catch return null;
    if (std.Io.Dir.openDirAbsolute(lib_io, exact, .{})) |d| {
        var dir = d;
        dir.close(lib_io);
        return version;
    } else |_| {}

    if (std.Io.Dir.openDirAbsolute(lib_io, name_dir, .{ .iterate = true })) |d| {
        var dir = d;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, entry.name, version)) {
                if (entry.name.len == version.len or
                    (entry.name.len > version.len and entry.name[version.len] == '_'))
                {
                    if (entry.name.len <= result_buf.len) {
                        @memcpy(result_buf[0..entry.name.len], entry.name);
                        dir.close(lib_io);
                        return result_buf[0..entry.name.len];
                    }
                }
            }
        }
        dir.close(lib_io);
    } else |_| {}
    return null;
}

const testing = std.testing;

test "materialize - failed copy keeps the existing same-version keg" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.createDirPath(io, "Cellar/foo/1.0/bin");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "Cellar/foo/1.0/bin/foo", .data = "old" });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp_dir.dir.realPathFile(io, ".", &base_buf)];
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_buf, "{s}/store", .{base});
    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cellar_dir = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{base});

    // The store entry is missing, so the clone and the cp fallback both fail.
    const sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try testing.expectError(error.CopyFailed, materializeAt(io, store_dir, cellar_dir, sha, "foo", "1.0"));

    var out: [16]u8 = undefined;
    try testing.expectEqualStrings("old", try tmp_dir.dir.readFile(io, "Cellar/foo/1.0/bin/foo", &out));
}

test "materialize + settlePrevious - restore the old keg on failure, drop it on success" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    try tmp_dir.dir.createDirPath(io, "Cellar/foo/1.0/bin");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "Cellar/foo/1.0/bin/foo", .data = "old" });
    try tmp_dir.dir.createDirPath(io, "store/" ++ sha ++ "/foo/1.0/bin");
    try tmp_dir.dir.writeFile(io, .{ .sub_path = "store/" ++ sha ++ "/foo/1.0/bin/foo", .data = "new" });

    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = base_buf[0..try tmp_dir.dir.realPathFile(io, ".", &base_buf)];
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const store_dir = try std.fmt.bufPrint(&store_buf, "{s}/store", .{base});
    var cellar_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cellar_dir = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{base});
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent = try std.fmt.bufPrint(&parent_buf, "{s}/Cellar/foo", .{base});
    var out: [16]u8 = undefined;

    // A later install step failed: the old keg comes back.
    try materializeAt(io, store_dir, cellar_dir, sha, "foo", "1.0");
    try testing.expectEqualStrings("new", try tmp_dir.dir.readFile(io, "Cellar/foo/1.0/bin/foo", &out));
    settlePreviousIn(io, parent, false);
    try testing.expectEqualStrings("old", try tmp_dir.dir.readFile(io, "Cellar/foo/1.0/bin/foo", &out));

    // The install is done: the new keg stays and the parked one goes.
    try materializeAt(io, store_dir, cellar_dir, sha, "foo", "1.0");
    settlePreviousIn(io, parent, true);
    try testing.expectEqualStrings("new", try tmp_dir.dir.readFile(io, "Cellar/foo/1.0/bin/foo", &out));
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(io, "Cellar/foo/.1.0.nb-prev", .{}));
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(io, "Cellar/foo/.1.0.nb-new", .{}));
}
