// nanobrew — Keg linker
//
// Creates symlinks for installed packages:
//   - Executables from Cellar/<name>/<ver>/bin/,sbin/ -> prefix/bin/
//   - Libraries from Cellar/<name>/<ver>/lib/        -> prefix/lib/
//   - Headers  from Cellar/<name>/<ver>/include/     -> prefix/include/
//   - Data     from Cellar/<name>/<ver>/share/       -> prefix/share/
//   - Package dir -> prefix/opt/<name>
//
// Detects conflicts (another package owns the same file) and warns.

const std = @import("std");
const paths = @import("../platform/paths.zig");

const CELLAR_DIR = paths.CELLAR_DIR;
const BIN_DIR = paths.BIN_DIR;
const OPT_DIR = paths.OPT_DIR;
const LIB_DIR = paths.LIB_DIR;
const INCLUDE_DIR = paths.INCLUDE_DIR;
const SHARE_DIR = paths.SHARE_DIR;

const SubdirMapping = struct {
    src: []const u8,
    dest: []const u8,
};

const subdir_mappings = [_]SubdirMapping{
    .{ .src = "bin", .dest = BIN_DIR },
    .{ .src = "sbin", .dest = BIN_DIR },
    .{ .src = "lib", .dest = LIB_DIR },
    .{ .src = "include", .dest = INCLUDE_DIR },
    .{ .src = "share", .dest = SHARE_DIR },
};

/// Extract the package name from a Cellar path.
/// Input:  "/opt/nanobrew/prefix/Cellar/wget/1.24.5/lib/foo.so"
/// Output: "wget"
/// Returns "" if path doesn't start with CELLAR_DIR.
pub fn extractKegName(path: []const u8) []const u8 {
    const prefix = CELLAR_DIR ++ "/";
    if (!std.mem.startsWith(u8, path, prefix)) return "";

    const after_cellar = path[prefix.len..];
    // Find the next '/' to isolate the package name
    if (std.mem.indexOfScalar(u8, after_cellar, '/')) |slash| {
        return after_cellar[0..slash];
    }
    // No slash found — the entire remainder is the name
    return after_cellar;
}

/// Check if an existing symlink target belongs to a different package.
/// Same package name (any version) is NOT a conflict.
/// Different package name IS a conflict.
/// Non-cellar paths are always conflicts.
pub fn isConflict(existing_target: []const u8, keg_dir: []const u8) bool {
    const existing_name = extractKegName(existing_target);
    const keg_name = extractKegName(keg_dir);

    // If existing target is not in Cellar, it's a conflict
    if (existing_name.len == 0) return true;

    // If keg_dir is not in Cellar, it's a conflict (shouldn't happen in practice)
    if (keg_name.len == 0) return true;

    // Same package name (any version) is not a conflict
    return !std.mem.eql(u8, existing_name, keg_name);
}

/// Recursively link files from keg_subdir into prefix_dest, with conflict detection.
fn linkSubdir(keg_subdir: []const u8, prefix_dest: []const u8, keg_dir: []const u8) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Ensure destination directory exists
    std.fs.makeDirAbsolute(prefix_dest) catch |err| {
        if (err != error.PathAlreadyExists) {
            stderr.print("warning: failed to create {s}: {}\n", .{ prefix_dest, err }) catch {};
            return;
        }
    };

    var dir = std.fs.openDirAbsolute(keg_subdir, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();

    while (iter.next() catch null) |entry| {
        var src_buf: [1024]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ keg_subdir, entry.name }) catch continue;

        var dest_buf: [1024]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ prefix_dest, entry.name }) catch continue;

        if (entry.kind == .directory) {
            // Recurse into subdirectory
            linkSubdir(src, dest, keg_dir);
            continue;
        }

        if (entry.kind != .file and entry.kind != .sym_link) continue;

        // Check if dest already exists as a symlink
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.readLinkAbsolute(dest, &target_buf)) |existing_target| {
            if (isConflict(existing_target, keg_dir)) {
                stderr.print("warning: {s} is already linked by {s}, skipping\n", .{
                    entry.name,
                    extractKegName(existing_target),
                }) catch {};
                continue;
            }
            // Same package — overwrite
            std.fs.deleteFileAbsolute(dest) catch {};
        } else |_| {
            // Not a symlink or doesn't exist — try to remove in case it's a regular file
            std.fs.deleteFileAbsolute(dest) catch {};
        }

        std.fs.symLinkAbsolute(src, dest, .{}) catch |err| {
            stderr.print("warning: failed to link {s}: {}\n", .{ entry.name, err }) catch {};
        };
    }
}

/// Recursively unlink symlinks in prefix_dest that point into keg_subdir,
/// then remove empty parent directories.
fn unlinkSubdir(keg_subdir: []const u8, prefix_dest: []const u8) void {
    var dir = std.fs.openDirAbsolute(prefix_dest, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();

    while (iter.next() catch null) |entry| {
        var dest_path_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ prefix_dest, entry.name }) catch continue;

        if (entry.kind == .directory) {
            var sub_keg_buf: [1024]u8 = undefined;
            const sub_keg = std.fmt.bufPrint(&sub_keg_buf, "{s}/{s}", .{ keg_subdir, entry.name }) catch continue;
            unlinkSubdir(sub_keg, dest_path);
            // Try to remove the directory if it's now empty
            std.fs.deleteDirAbsolute(dest_path) catch {};
            continue;
        }

        if (entry.kind != .sym_link) continue;

        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.readLinkAbsolute(dest_path, &target_buf) catch continue;

        // Remove if the symlink points into our keg_subdir
        if (std.mem.startsWith(u8, target, keg_subdir)) {
            std.fs.deleteFileAbsolute(dest_path) catch {};
        }
    }
}

/// Link a keg's files and create opt/ symlink.
pub fn linkKeg(name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    for (subdir_mappings) |mapping| {
        var sub_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
        linkSubdir(keg_subdir, mapping.dest, keg_dir);
    }

    // Create opt/ symlink: prefix/opt/<name> -> Cellar/<name>/<version>
    std.fs.makeDirAbsolute(OPT_DIR) catch {};
    var opt_buf: [512]u8 = undefined;
    const opt_link = std.fmt.bufPrint(&opt_buf, "{s}/{s}", .{ OPT_DIR, name }) catch return error.PathTooLong;
    std.fs.deleteFileAbsolute(opt_link) catch {};
    std.fs.symLinkAbsolute(keg_dir, opt_link, .{}) catch |err| {
        std.fs.File.stderr().deprecatedWriter().print("warning: failed to link {s}: {}\n", .{ name, err }) catch {};
    };
}

/// Unlink a keg's files and remove opt/ symlink.
pub fn unlinkKeg(name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    for (subdir_mappings) |mapping| {
        var sub_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
        unlinkSubdir(keg_subdir, mapping.dest);
    }

    // Remove opt/ symlink
    var opt_buf: [512]u8 = undefined;
    const opt_link = std.fmt.bufPrint(&opt_buf, "{s}/{s}", .{ OPT_DIR, name }) catch return;
    std.fs.deleteFileAbsolute(opt_link) catch {};
}
