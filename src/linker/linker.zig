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
const ETC_DIR = paths.ETC_DIR;
const FORTUNE_NAME = "fortune";
const FORTUNE_DEFAULT_DIR = SHARE_DIR ++ "/games/fortunes";
const WRAPPER_DIR = "libexec/.nanobrew-wrappers";

const SubdirMapping = struct {
    src: []const u8,
    dest: []const u8,
    /// Don't overwrite a regular file that already exists at the destination.
    /// Used for `etc/` so that first install symlinks the keg's defaults into
    /// `<prefix>/etc/` (so packages like imagemagick can find delegates.xml,
    /// pkg-config can find its system pc/, etc.) but a subsequent reinstall or
    /// upgrade leaves a user-edited config file alone, matching Homebrew's
    /// `etc/` semantics.
    preserve_user_edits: bool = false,
};

pub const LinkMode = enum {
    global,
    shim_root,
    private_dependency,
};

pub const LinkOptions = struct {
    mode: LinkMode = .global,
    shim_path_entries: []const []const u8 = &.{},
};

const subdir_mappings = [_]SubdirMapping{
    .{ .src = "bin", .dest = BIN_DIR },
    .{ .src = "sbin", .dest = BIN_DIR },
    .{ .src = "lib", .dest = LIB_DIR },
    .{ .src = "include", .dest = INCLUDE_DIR },
    .{ .src = "share", .dest = SHARE_DIR },
    .{ .src = "etc", .dest = ETC_DIR, .preserve_user_edits = true },
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

fn isExecutableSubdir(subdir: []const u8) bool {
    return std.mem.eql(u8, subdir, "bin") or std.mem.eql(u8, subdir, "sbin");
}

fn symlinkTargetEquals(path: []const u8, expected: []const u8) bool {
    const lib_io = paths.safe_io;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_n = std.Io.Dir.readLinkAbsolute(lib_io, path, &target_buf) catch return false;
    return std.mem.eql(u8, target_buf[0..target_n], expected);
}

fn symlinkTargetStartsWith(path: []const u8, prefix: []const u8) bool {
    const lib_io = paths.safe_io;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_n = std.Io.Dir.readLinkAbsolute(lib_io, path, &target_buf) catch return false;
    return std.mem.startsWith(u8, target_buf[0..target_n], prefix);
}

/// Recursively link files from keg_subdir into prefix_dest, with conflict detection.
/// When `preserve_user_edits` is true, an existing regular file (i.e. not a
/// symlink we control) at the destination is left untouched. This matches
/// Homebrew's `etc/` semantics: first install drops the keg's default config
/// in via a symlink, but anything the user has actually edited (or another
/// package has placed) is preserved.
fn linkSubdirOpts(keg_subdir: []const u8, prefix_dest: []const u8, keg_dir: []const u8, preserve_user_edits: bool) void {
    const lib_io = paths.safe_io;

    // Ensure destination directory exists
    std.Io.Dir.createDirAbsolute(lib_io, prefix_dest, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "warning: failed to create {s}: {}\n", .{ prefix_dest, err }) catch "warning: failed to create directory\n";
            std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
            return;
        }
    };

    var dir = std.Io.Dir.openDirAbsolute(lib_io, keg_subdir, .{ .iterate = true }) catch return;
    defer dir.close(lib_io);
    var iter = dir.iterate();

    while (iter.next(lib_io) catch null) |entry| {
        var src_buf: [1024]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ keg_subdir, entry.name }) catch continue;

        var dest_buf: [1024]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ prefix_dest, entry.name }) catch continue;

        if (entry.kind == .directory) {
            // Recurse into subdirectory
            linkSubdirOpts(src, dest, keg_dir, preserve_user_edits);
            continue;
        }

        if (entry.kind != .file and entry.kind != .sym_link) continue;

        // Check if dest already exists as a symlink
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const maybe_target_n = std.Io.Dir.readLinkAbsolute(lib_io, dest, &target_buf);
        if (maybe_target_n) |target_n| {
            const existing_target = target_buf[0..target_n];
            if (isConflict(existing_target, keg_dir)) {
                var msg_buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "warning: {s} is already linked by {s}, skipping\n", .{
                    entry.name,
                    extractKegName(existing_target),
                }) catch "warning: conflict detected, skipping\n";
                std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
                continue;
            }
            // Same package — overwrite
            std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
        } else |_| {
            // Not a symlink — could be a regular file (user-edited config)
            // or it doesn't exist. For etc/ we preserve user edits; for
            // everything else we clobber the regular file (e.g. a stray
            // bin/<binary> from a manual install) so the keg's symlink wins.
            if (preserve_user_edits) {
                if (std.Io.Dir.accessAbsolute(lib_io, dest, .{})) |_| {
                    // Regular file already exists at dest — leave it alone.
                    continue;
                } else |_| {}
            } else {
                std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
            }
        }

        std.Io.Dir.symLinkAbsolute(lib_io, src, dest, .{}) catch |err| {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "warning: failed to link {s}: {}\n", .{ entry.name, err }) catch "warning: failed to link\n";
            std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
        };
    }
}

/// Backwards-compatible wrapper: link with no user-edit preservation.
fn linkSubdir(keg_subdir: []const u8, prefix_dest: []const u8, keg_dir: []const u8) void {
    linkSubdirOpts(keg_subdir, prefix_dest, keg_dir, false);
}

fn renderShimWrapper(
    alloc: std.mem.Allocator,
    actual_bin: []const u8,
    path_entries: []const []const u8,
    extra_env: []const [2][]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
        \\#!/bin/sh
        \\set -eu
        \\PATH="
    );
    for (path_entries, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(":");
        try writer.writeAll(entry);
    }
    if (path_entries.len > 0) try writer.writeAll(":");
    try writer.writeAll(
        \\$PATH"
        \\export PATH
        \\
    );
    for (extra_env) |kv| {
        try writer.writeAll(kv[0]);
        try writer.writeAll("=\"");
        try writer.writeAll(kv[1]);
        try writer.writeAll("\"\nexport ");
        try writer.writeAll(kv[0]);
        try writer.writeAll("\n");
    }
    try writer.writeAll("exec \"");
    try writer.writeAll(actual_bin);
    try writer.writeAll(
        \\" "$@"
        \\
    );

    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn installShimLink(
    keg_dir: []const u8,
    source: []const u8,
    dest: []const u8,
    entry_name: []const u8,
    path_entries: []const []const u8,
) void {
    const lib_io = paths.safe_io;
    var libexec_dir_buf: [512]u8 = undefined;
    const libexec_dir = std.fmt.bufPrint(&libexec_dir_buf, "{s}/libexec", .{keg_dir}) catch return;
    std.Io.Dir.createDirAbsolute(lib_io, libexec_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    var wrapper_dir_buf: [512]u8 = undefined;
    const wrapper_dir = std.fmt.bufPrint(&wrapper_dir_buf, "{s}/{s}", .{ keg_dir, WRAPPER_DIR }) catch return;
    std.Io.Dir.createDirAbsolute(lib_io, wrapper_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    var wrapper_path_buf: [1024]u8 = undefined;
    const wrapper_path = std.fmt.bufPrint(&wrapper_path_buf, "{s}/{s}", .{ wrapper_dir, entry_name }) catch return;

    // Detect per-package env vars (e.g. GIT_EXEC_PATH for git)
    var extra_env_buf: [4][2][]const u8 = undefined;
    var extra_env_count: usize = 0;
    var git_core_buf: [512]u8 = undefined;
    const git_core_path = std.fmt.bufPrint(&git_core_buf, "{s}/libexec/git-core", .{keg_dir}) catch "";
    if (git_core_path.len > 0) {
        if (std.Io.Dir.openDirAbsolute(lib_io, git_core_path, .{})) |d| {
            var bd = d;
            bd.close(lib_io);
            extra_env_buf[extra_env_count] = .{ "GIT_EXEC_PATH", git_core_path };
            extra_env_count += 1;
        } else |_| {}
    }
    var git_tpl_buf: [512]u8 = undefined;
    const git_tpl_path = std.fmt.bufPrint(&git_tpl_buf, "{s}/share/git-core/templates", .{keg_dir}) catch "";
    if (git_tpl_path.len > 0) {
        if (std.Io.Dir.openDirAbsolute(lib_io, git_tpl_path, .{})) |d| {
            var bd = d;
            bd.close(lib_io);
            extra_env_buf[extra_env_count] = .{ "GIT_TEMPLATE_DIR", git_tpl_path };
            extra_env_count += 1;
        } else |_| {}
    }

    const alloc = std.heap.smp_allocator;
    const wrapper_content = renderShimWrapper(alloc, source, path_entries, extra_env_buf[0..extra_env_count]) catch return;
    defer alloc.free(wrapper_content);

    std.Io.Dir.deleteFileAbsolute(lib_io, wrapper_path) catch {};
    const wrapper_file = std.Io.Dir.createFileAbsolute(lib_io, wrapper_path, .{ .permissions = .executable_file }) catch return;
    defer wrapper_file.close(lib_io);
    wrapper_file.writeStreamingAll(lib_io, wrapper_content) catch return;

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(lib_io, dest, &target_buf)) |target_n| {
        const existing_target = target_buf[0..target_n];
        if (isConflict(existing_target, keg_dir) and !std.mem.startsWith(u8, existing_target, keg_dir)) {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "warning: {s} is already linked by {s}, skipping shim\n", .{
                entry_name,
                extractKegName(existing_target),
            }) catch "warning: conflict detected, skipping shim\n";
            std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
            return;
        }
        std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
    } else |_| {
        std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
    }

    std.Io.Dir.symLinkAbsolute(lib_io, wrapper_path, dest, .{}) catch |err| {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "warning: failed to install {s} shim: {}\n", .{ entry_name, err }) catch "warning: failed to install shim\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
    };
}

fn linkSubdirAsShims(keg_subdir: []const u8, prefix_dest: []const u8, keg_dir: []const u8, path_entries: []const []const u8) void {
    const lib_io = paths.safe_io;

    std.Io.Dir.createDirAbsolute(lib_io, prefix_dest, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    var dir = std.Io.Dir.openDirAbsolute(lib_io, keg_subdir, .{ .iterate = true }) catch return;
    defer dir.close(lib_io);
    var iter = dir.iterate();

    while (iter.next(lib_io) catch null) |entry| {
        var src_buf: [1024]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ keg_subdir, entry.name }) catch continue;

        var dest_buf: [1024]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ prefix_dest, entry.name }) catch continue;

        if (entry.kind == .directory) {
            linkSubdirAsShims(src, dest, keg_dir, path_entries);
            continue;
        }

        if (entry.kind != .file and entry.kind != .sym_link) continue;
        installShimLink(keg_dir, src, dest, entry.name, path_entries);
    }
}

/// Recursively unlink symlinks in prefix_dest that point into keg_subdir,
/// then remove empty parent directories.
fn unlinkSubdir(keg_subdir: []const u8, prefix_dest: []const u8) void {
    const lib_io = paths.safe_io;

    var dir = std.Io.Dir.openDirAbsolute(lib_io, prefix_dest, .{ .iterate = true }) catch return;
    defer dir.close(lib_io);
    var iter = dir.iterate();

    while (iter.next(lib_io) catch null) |entry| {
        var dest_path_buf: [1024]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ prefix_dest, entry.name }) catch continue;

        if (entry.kind == .directory) {
            var sub_keg_buf: [1024]u8 = undefined;
            const sub_keg = std.fmt.bufPrint(&sub_keg_buf, "{s}/{s}", .{ keg_subdir, entry.name }) catch continue;
            unlinkSubdir(sub_keg, dest_path);
            // Try to remove the directory if it's now empty
            std.Io.Dir.deleteDirAbsolute(lib_io, dest_path) catch {};
            continue;
        }

        if (entry.kind != .sym_link) continue;

        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_n = std.Io.Dir.readLinkAbsolute(lib_io, dest_path, &target_buf) catch continue;
        const target = target_buf[0..target_n];

        // Remove if the symlink points into our keg_subdir
        if (std.mem.startsWith(u8, target, keg_subdir)) {
            std.Io.Dir.deleteFileAbsolute(lib_io, dest_path) catch {};
        }
    }
}

fn unlinkShimLinks(keg_dir: []const u8) void {
    const lib_io = paths.safe_io;
    var wrapper_prefix_buf: [512]u8 = undefined;
    const wrapper_prefix = std.fmt.bufPrint(&wrapper_prefix_buf, "{s}/{s}", .{ keg_dir, WRAPPER_DIR }) catch return;

    var dir = std.Io.Dir.openDirAbsolute(lib_io, BIN_DIR, .{ .iterate = true }) catch return;
    defer dir.close(lib_io);
    var iter = dir.iterate();

    while (iter.next(lib_io) catch null) |entry| {
        if (entry.kind != .sym_link) continue;
        var dest_buf: [1024]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ BIN_DIR, entry.name }) catch continue;

        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_n = std.Io.Dir.readLinkAbsolute(lib_io, dest, &target_buf) catch continue;
        const target = target_buf[0..target_n];
        if (std.mem.startsWith(u8, target, wrapper_prefix)) {
            std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
        }
    }
}

fn needsManagedWrapper(pkg_name: []const u8, subdir: []const u8, entry_name: []const u8) bool {
    return std.mem.eql(u8, pkg_name, FORTUNE_NAME) and
        std.mem.eql(u8, subdir, "bin") and
        std.mem.eql(u8, entry_name, FORTUNE_NAME);
}

fn renderFortuneWrapper(buf: []u8, actual_bin: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        \\#!/bin/sh
        \\set -eu
        \\
        \\default_dir="{s}"
        \\need_default=1
        \\expect_value=0
        \\for arg in "$@"; do
        \\  if [ "$expect_value" -eq 1 ]; then
        \\    expect_value=0
        \\    continue
        \\  fi
        \\  case "$arg" in
        \\    -n|-m)
        \\      expect_value=1
        \\      ;;
        \\    -n*|-m*)
        \\      ;;
        \\    -[acefilosuw]*)
        \\      ;;
        \\    -*)
        \\      need_default=0
        \\      break
        \\      ;;
        \\    *)
        \\      need_default=0
        \\      break
        \\      ;;
        \\  esac
        \\done
        \\if [ "$need_default" -eq 1 ] && [ -d "{s}" ]; then
        \\  exec "{s}" "$@" "{s}"
        \\fi
        \\exec "{s}" "$@"
        \\
    , .{ FORTUNE_DEFAULT_DIR, FORTUNE_DEFAULT_DIR, actual_bin, FORTUNE_DEFAULT_DIR, actual_bin });
}

fn installManagedWrapper(pkg_name: []const u8, keg_dir: []const u8) void {
    if (!needsManagedWrapper(pkg_name, "bin", FORTUNE_NAME)) return;

    const lib_io = paths.safe_io;

    var libexec_dir_buf: [512]u8 = undefined;
    const libexec_dir = std.fmt.bufPrint(&libexec_dir_buf, "{s}/libexec", .{keg_dir}) catch return;
    std.Io.Dir.createDirAbsolute(lib_io, libexec_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    var wrapper_dir_buf: [512]u8 = undefined;
    const wrapper_dir = std.fmt.bufPrint(&wrapper_dir_buf, "{s}/{s}", .{ keg_dir, WRAPPER_DIR }) catch return;
    std.Io.Dir.createDirAbsolute(lib_io, wrapper_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return;
    };

    var actual_bin_buf: [512]u8 = undefined;
    const actual_bin = std.fmt.bufPrint(&actual_bin_buf, "{s}/bin/{s}", .{ keg_dir, FORTUNE_NAME }) catch return;

    var wrapper_path_buf: [512]u8 = undefined;
    const wrapper_path = std.fmt.bufPrint(&wrapper_path_buf, "{s}/{s}", .{ wrapper_dir, FORTUNE_NAME }) catch return;

    var content_buf: [2048]u8 = undefined;
    const wrapper_content = renderFortuneWrapper(&content_buf, actual_bin) catch return;

    const wrapper_file = std.Io.Dir.createFileAbsolute(lib_io, wrapper_path, .{ .permissions = .executable_file }) catch return;
    defer wrapper_file.close(lib_io);
    wrapper_file.writeStreamingAll(lib_io, wrapper_content) catch return;

    var dest_buf: [512]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ BIN_DIR, FORTUNE_NAME }) catch return;

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(lib_io, dest, &target_buf)) |target_n| {
        const existing_target = target_buf[0..target_n];
        if (isConflict(existing_target, keg_dir)) {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "warning: {s} is already linked by {s}, skipping wrapper\n", .{
                FORTUNE_NAME,
                extractKegName(existing_target),
            }) catch "warning: conflict detected, skipping wrapper\n";
            std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
            return;
        }
        std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
    } else |_| {}

    std.Io.Dir.symLinkAbsolute(lib_io, wrapper_path, dest, .{}) catch |err| {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "warning: failed to install {s} wrapper: {}\n", .{ FORTUNE_NAME, err }) catch "warning: failed to install wrapper\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
    };
}

fn removeManagedWrapper(pkg_name: []const u8, keg_dir: []const u8) void {
    if (!needsManagedWrapper(pkg_name, "bin", FORTUNE_NAME)) return;

    const lib_io = paths.safe_io;
    var dest_buf: [512]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ BIN_DIR, FORTUNE_NAME }) catch return;

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_n = std.Io.Dir.readLinkAbsolute(lib_io, dest, &target_buf) catch return;
    const target = target_buf[0..target_n];
    if (std.mem.startsWith(u8, target, keg_dir)) {
        std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
    }
}

/// Link a keg's files and create opt/ symlink.
pub fn linkKeg(name: []const u8, version: []const u8) !void {
    return linkKegWithOptions(name, version, .{});
}

pub fn linkKegWithOptions(name: []const u8, version: []const u8, options: LinkOptions) !void {
    const lib_io = paths.safe_io;
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    if (options.mode == .private_dependency) unlinkShimLinks(keg_dir);

    // Detect kegs that need wrapper shims for env vars even in global mode
    // (e.g. git with libexec/git-core needs GIT_EXEC_PATH)
    var needs_env_shim = false;
    if (options.mode == .global) {
        var git_core_buf: [512]u8 = undefined;
        const git_core_path = std.fmt.bufPrint(&git_core_buf, "{s}/libexec/git-core", .{keg_dir}) catch "";
        if (git_core_path.len > 0) {
            if (std.Io.Dir.openDirAbsolute(lib_io, git_core_path, .{})) |d| {
                var bd = d;
                bd.close(lib_io);
                needs_env_shim = true;
            } else |_| {}
        }
        if (!needs_env_shim) {
            var git_tpl_buf2: [512]u8 = undefined;
            const git_tpl_path2 = std.fmt.bufPrint(&git_tpl_buf2, "{s}/share/git-core/templates", .{keg_dir}) catch "";
            if (git_tpl_path2.len > 0) {
                if (std.Io.Dir.openDirAbsolute(lib_io, git_tpl_path2, .{})) |d| {
                    var bd = d;
                    bd.close(lib_io);
                    needs_env_shim = true;
                } else |_| {}
            }
        }
    }

    for (subdir_mappings) |mapping| {
        var sub_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
        if (isExecutableSubdir(mapping.src)) {
            switch (options.mode) {
                .global => {
                    if (needs_env_shim) {
                        linkSubdirAsShims(keg_subdir, mapping.dest, keg_dir, &.{});
                    } else {
                        linkSubdir(keg_subdir, mapping.dest, keg_dir);
                    }
                },
                .shim_root => linkSubdirAsShims(keg_subdir, mapping.dest, keg_dir, options.shim_path_entries),
                .private_dependency => unlinkSubdir(keg_subdir, mapping.dest),
            }
        } else {
            linkSubdirOpts(keg_subdir, mapping.dest, keg_dir, mapping.preserve_user_edits);
        }
    }

    if (options.mode == .global) installManagedWrapper(name, keg_dir);

    // Create opt/ symlink: prefix/opt/<name> -> Cellar/<name>/<version>
    std.Io.Dir.createDirAbsolute(lib_io, OPT_DIR, .default_dir) catch {};
    var opt_buf: [512]u8 = undefined;
    const opt_link = std.fmt.bufPrint(&opt_buf, "{s}/{s}", .{ OPT_DIR, name }) catch return error.PathTooLong;
    std.Io.Dir.deleteFileAbsolute(lib_io, opt_link) catch {};
    std.Io.Dir.symLinkAbsolute(lib_io, keg_dir, opt_link, .{}) catch |err| {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "warning: failed to link {s}: {}\n", .{ name, err }) catch "warning: failed to link\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
    };
}

fn executableLinksNeedRepair(keg_subdir: []const u8, prefix_dest: []const u8, keg_dir: []const u8, mode: LinkMode) bool {
    const lib_io = paths.safe_io;
    var dir = std.Io.Dir.openDirAbsolute(lib_io, keg_subdir, .{ .iterate = true }) catch return false;
    defer dir.close(lib_io);
    var iter = dir.iterate();

    while (iter.next(lib_io) catch null) |entry| {
        var src_buf: [1024]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ keg_subdir, entry.name }) catch continue;

        var dest_buf: [1024]u8 = undefined;
        const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ prefix_dest, entry.name }) catch continue;

        if (entry.kind == .directory) {
            if (executableLinksNeedRepair(src, dest, keg_dir, mode)) return true;
            continue;
        }

        if (entry.kind != .file and entry.kind != .sym_link) continue;

        switch (mode) {
            .global => {
                if (!symlinkTargetEquals(dest, src)) return true;
            },
            .shim_root => {
                var wrapper_path_buf: [1024]u8 = undefined;
                const wrapper_path = std.fmt.bufPrint(&wrapper_path_buf, "{s}/{s}/{s}", .{ keg_dir, WRAPPER_DIR, entry.name }) catch return true;
                if (!symlinkTargetEquals(dest, wrapper_path)) return true;
            },
            .private_dependency => {
                if (symlinkTargetStartsWith(dest, keg_dir)) return true;
            },
        }
    }

    return false;
}

/// Return true when the public links for an installed keg do not match the
/// requested link mode. This is intentionally much cheaper than a full relink
/// and is used to keep already-installed `nb install` calls on the fast path.
pub fn needsLinkRepair(name: []const u8, version: []const u8, options: LinkOptions) bool {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return true;

    var opt_buf: [512]u8 = undefined;
    const opt_link = std.fmt.bufPrint(&opt_buf, "{s}/{s}", .{ OPT_DIR, name }) catch return true;
    if (!symlinkTargetEquals(opt_link, keg_dir)) return true;

    for (subdir_mappings) |mapping| {
        if (!isExecutableSubdir(mapping.src)) continue;
        var sub_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
        if (executableLinksNeedRepair(keg_subdir, mapping.dest, keg_dir, options.mode)) return true;
    }

    return false;
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

    unlinkShimLinks(keg_dir);
    removeManagedWrapper(name, keg_dir);

    // Remove opt/ symlink
    const lib_io = paths.safe_io;
    var opt_buf: [512]u8 = undefined;
    const opt_link = std.fmt.bufPrint(&opt_buf, "{s}/{s}", .{ OPT_DIR, name }) catch return;
    std.Io.Dir.deleteFileAbsolute(lib_io, opt_link) catch {};
}

test "needsManagedWrapper only wraps fortune binary" {
    try std.testing.expect(needsManagedWrapper("fortune", "bin", "fortune"));
    try std.testing.expect(!needsManagedWrapper("fortune", "share", "fortune"));
    try std.testing.expect(!needsManagedWrapper("wget", "bin", "fortune"));
    try std.testing.expect(!needsManagedWrapper("fortune", "bin", "strfile"));
}

test "renderFortuneWrapper injects default fortunes dir" {
    var buf: [2048]u8 = undefined;
    const script = try renderFortuneWrapper(&buf, "/opt/nanobrew/prefix/Cellar/fortune/9708/bin/fortune");

    try std.testing.expect(std.mem.indexOf(u8, script, "default_dir=\"" ++ FORTUNE_DEFAULT_DIR ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "exec \"/opt/nanobrew/prefix/Cellar/fortune/9708/bin/fortune\" \"$@\" \"" ++ FORTUNE_DEFAULT_DIR ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "-n|-m") != null);
}

test "renderShimWrapper prepends private PATH entries and execs actual binary" {
    const entries = [_][]const u8{
        "/opt/nanobrew/prefix/opt/deno/bin",
        "/opt/nanobrew/prefix/opt/python@3.14/bin",
    };
    const script = try renderShimWrapper(std.testing.allocator, "/opt/nanobrew/prefix/Cellar/yt-dlp/1.0/bin/yt-dlp", &entries, &.{});
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "PATH=\"/opt/nanobrew/prefix/opt/deno/bin:/opt/nanobrew/prefix/opt/python@3.14/bin:$PATH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "exec \"/opt/nanobrew/prefix/Cellar/yt-dlp/1.0/bin/yt-dlp\" \"$@\"") != null);
}

test "renderShimWrapper includes extra env vars" {
    const env = [_][2][]const u8{
        .{ "GIT_EXEC_PATH", "/opt/nanobrew/prefix/Cellar/git/2.47.0/libexec/git-core" },
        .{ "GIT_TEMPLATE_DIR", "/opt/nanobrew/prefix/Cellar/git/2.47.0/share/git-core/templates" },
    };
    const script = try renderShimWrapper(std.testing.allocator, "/opt/nanobrew/prefix/Cellar/git/2.47.0/bin/git", &.{}, &env);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "GIT_EXEC_PATH=\"/opt/nanobrew/prefix/Cellar/git/2.47.0/libexec/git-core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "export GIT_EXEC_PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "GIT_TEMPLATE_DIR=\"/opt/nanobrew/prefix/Cellar/git/2.47.0/share/git-core/templates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "export GIT_TEMPLATE_DIR") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "exec \"/opt/nanobrew/prefix/Cellar/git/2.47.0/bin/git\" \"$@\"") != null);
}
