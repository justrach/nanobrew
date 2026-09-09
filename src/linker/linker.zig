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
const builtin = @import("builtin");
const paths = @import("../platform/paths.zig");

const CELLAR_DIR = paths.CELLAR_DIR;
const BIN_DIR = paths.BIN_DIR;
const OPT_DIR = paths.OPT_DIR;
const LIB_DIR = paths.LIB_DIR;
const INCLUDE_DIR = paths.INCLUDE_DIR;

/// Duplicate `s` into the arena as a NUL-terminated string. Replaces the
/// `std.mem.Allocator.dupeZ` helper removed in Zig 0.17 (allocSentinel +
/// memcpy is the 0.17 idiom, already used via allocPrintSentinel below).
fn dupeZ(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![:0]u8 {
    const z = try arena.allocSentinel(u8, s.len, 0);
    @memcpy(z, s);
    return z;
}
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
    /// Homebrew bottles ship mutable runtime payload (config under `etc/`,
    /// runtime state under `var/`) beneath a `.bottle/` prefix rather than the
    /// keg root, so pour can install it into the *shared* prefix instead of
    /// leaving it pinned to one keg version. When set, the linker also links
    /// from `<keg>/<bottle_src>` into `dest` using the same bucket logic — a
    /// graceful no-op when the keg has no `.bottle/` payload (e.g. source
    /// builds, or bottles that ship `etc/` at the root). See #347.
    bottle_src: ?[]const u8 = null,
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
    .{ .src = "etc", .dest = ETC_DIR, .preserve_user_edits = true, .bottle_src = ".bottle/etc" },
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

    // Detect per-package env vars (e.g. GIT_EXEC_PATH for git,
    // ImageMagick config/module paths for bottles whose libMagickCore embeds
    // /opt/homebrew Cellar paths that cannot be length-rewritten in-place).
    var extra_env_buf: [5][2][]const u8 = undefined;
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

    var git_templates_buf: [512]u8 = undefined;
    const git_templates = std.fmt.bufPrint(&git_templates_buf, "{s}/share/git-core/templates", .{keg_dir}) catch "";
    if (git_templates.len > 0) {
        if (std.Io.Dir.openDirAbsolute(lib_io, git_templates, .{})) |d| {
            var dir = d;
            dir.close(lib_io);
            extra_env_buf[extra_env_count] = .{ "GIT_TEMPLATE_DIR", git_templates };
            extra_env_count += 1;
        } else |_| {}
    }

    var magick_config_buf: [1024]u8 = undefined;
    var magick_coder_buf: [512]u8 = undefined;
    var magick_filter_buf: [512]u8 = undefined;
    if (imageMagickNeedsEnv(keg_dir)) {
        const magick_config = std.fmt.bufPrint(&magick_config_buf, "{s}/etc/ImageMagick-7:{s}/share/ImageMagick-7:{s}/lib/ImageMagick/config-Q16HDRI", .{ keg_dir, keg_dir, keg_dir }) catch "";
        const magick_coder = std.fmt.bufPrint(&magick_coder_buf, "{s}/lib/ImageMagick/modules-Q16HDRI/coders", .{keg_dir}) catch "";
        const magick_filter = std.fmt.bufPrint(&magick_filter_buf, "{s}/lib/ImageMagick/modules-Q16HDRI/filters", .{keg_dir}) catch "";
        if (magick_config.len > 0) {
            extra_env_buf[extra_env_count] = .{ "MAGICK_CONFIGURE_PATH", magick_config };
            extra_env_count += 1;
        }
        if (magick_coder.len > 0) {
            extra_env_buf[extra_env_count] = .{ "MAGICK_CODER_MODULE_PATH", magick_coder };
            extra_env_count += 1;
        }
        if (magick_filter.len > 0) {
            extra_env_buf[extra_env_count] = .{ "MAGICK_FILTER_MODULE_PATH", magick_filter };
            extra_env_count += 1;
        }
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

fn imageMagickNeedsEnv(keg_dir: []const u8) bool {
    const lib_io = paths.safe_io;
    var config_buf: [512]u8 = undefined;
    const config_dir = std.fmt.bufPrint(&config_buf, "{s}/etc/ImageMagick-7", .{keg_dir}) catch return false;
    if (std.Io.Dir.openDirAbsolute(lib_io, config_dir, .{})) |d| {
        var dir = d;
        dir.close(lib_io);
    } else |_| return false;

    var coders_buf: [512]u8 = undefined;
    const coders_dir = std.fmt.bufPrint(&coders_buf, "{s}/lib/ImageMagick/modules-Q16HDRI/coders", .{keg_dir}) catch return false;
    if (std.Io.Dir.openDirAbsolute(lib_io, coders_dir, .{})) |d| {
        var dir = d;
        dir.close(lib_io);
        return true;
    } else |_| return false;
}

fn needsManagedWrapper(pkg_name: []const u8, subdir: []const u8, entry_name: []const u8) bool {
    return std.mem.eql(u8, pkg_name, FORTUNE_NAME) and
        std.mem.eql(u8, subdir, "bin") and
        std.mem.eql(u8, entry_name, FORTUNE_NAME);
}

fn renderFortuneWrapper(buf: []u8, actual_bin: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
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
// ── Parallel dirfd link/unlink engine ───────────────────────────────
//
// Hot path for large kegs (openssl@3 links ~7.6k files). The serial
// walkers above pay 2–3 absolute-path syscalls per file single-threaded
// (~35–55 µs/file). Here the keg tree is scanned once (batched readdir
// through std.Io), destination dirs are created serially (parents first),
// and the per-leaf work (readlink probe + unlink + symlink) runs across a
// small worker pool with a dirfd per work chunk, so each hot syscall
// resolves only a basename. Semantics match linkSubdirOpts/unlinkSubdir
// exactly; only the order of independent leaf operations changes.

/// std.c *at-syscalls are unavailable on Windows/WASI; those targets keep
/// the serial walkers. Comptime-known so the POSIX code is pruned there.
const fast_link_posix = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

/// Below this many leaves, thread-spawn overhead outweighs the win.
const PARALLEL_LINK_MIN_LEAVES = 256;
/// Leaves per work item; each chunk gets its own dirfd.
const LINK_CHUNK_SIZE = 256;
/// Sweet spot is ~4 on Apple Silicon under load; 6+ syscall-heavy threads
/// contend and regress below serial speed (measured: 147ms @4 vs 465ms @8
/// for a 7.6k-file keg).
const MAX_LINK_WORKERS = 4;

fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const sec: i64 = @intCast(ts.sec);
    const nsec: i64 = @intCast(ts.nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

const LinkLeaf = struct {
    /// Absolute keg path — becomes the symlink target (sentinel for symlinkat).
    src: [:0]const u8,
    /// Basename inside the destination dir (sentinel for the *at syscalls).
    name: [:0]const u8,
};

const LinkBucket = struct {
    dest_dir: [:0]const u8,
    preserve_user_edits: bool,
    leaves: std.ArrayListUnmanaged(LinkLeaf) = .empty,
};

const LinkChunk = struct {
    dest_dir: [:0]const u8,
    preserve_user_edits: bool,
    leaves: []const LinkLeaf,
};

const UnlinkBucket = struct {
    dest_dir: [:0]const u8,
    keg_prefix: []const u8,
    names: std.ArrayListUnmanaged([:0]const u8) = .empty,
};

const UnlinkChunk = struct {
    dest_dir: [:0]const u8,
    keg_prefix: []const u8,
    names: []const [:0]const u8,
};

/// Warning messages collected from workers and printed once, sorted, from
/// the calling thread (workers must not touch the single-threaded safe_io).
const WarningList = struct {
    // Simple spinlock — warnings are rare (conflicts/failures only), and
    // workers run on raw threads without an Io handle for std.Io.Mutex.
    locked: std.atomic.Value(bool) = .init(false),
    items: std.ArrayListUnmanaged([]u8) = .empty,

    fn add(self: *WarningList, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer self.locked.store(false, .release);
        self.items.append(std.heap.smp_allocator, msg) catch std.heap.smp_allocator.free(msg);
    }

    fn flush(self: *WarningList) void {
        std.mem.sort([]u8, self.items.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        const lib_io = paths.safe_io;
        for (self.items.items) |msg| {
            std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
            std.heap.smp_allocator.free(msg);
        }
        self.items.deinit(std.heap.smp_allocator);
    }
};

const LinkPlan = struct {
    arena: std.heap.ArenaAllocator,
    buckets: std.ArrayListUnmanaged(LinkBucket) = .empty,
    /// Destination dirs in pre-order so parents are created before children.
    dest_dirs: std.ArrayListUnmanaged([:0]const u8) = .empty,
    total_leaves: usize = 0,

    fn init() LinkPlan {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator) };
    }

    fn deinit(self: *LinkPlan) void {
        self.arena.deinit();
    }
};

const UnlinkPlan = struct {
    arena: std.heap.ArenaAllocator,
    buckets: std.ArrayListUnmanaged(UnlinkBucket) = .empty,
    /// Mirrored dest dirs (excluding mapping roots), pre-order; rmdir runs
    /// in reverse so children go before parents.
    rmdir_dirs: std.ArrayListUnmanaged([:0]const u8) = .empty,
    total_names: usize = 0,

    fn init() UnlinkPlan {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator) };
    }

    fn deinit(self: *UnlinkPlan) void {
        self.arena.deinit();
    }
};

fn collectLinkBucket(
    plan: *LinkPlan,
    keg_subdir: []const u8,
    prefix_dest: []const u8,
    preserve_user_edits: bool,
) void {
    const lib_io = paths.safe_io;
    const arena = plan.arena.allocator();

    var dir = std.Io.Dir.openDirAbsolute(lib_io, keg_subdir, .{ .iterate = true }) catch return;
    defer dir.close(lib_io);

    var bucket = LinkBucket{
        .dest_dir = dupeZ(arena, prefix_dest) catch return,
        .preserve_user_edits = preserve_user_edits,
    };
    var subdirs: std.ArrayListUnmanaged([2][:0]const u8) = .empty;

    var iter = dir.iterate();
    while (iter.next(lib_io) catch null) |entry| {
        if (entry.kind == .directory) {
            const keg_child = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ keg_subdir, entry.name }, 0) catch continue;
            const dest_child = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ prefix_dest, entry.name }, 0) catch continue;
            subdirs.append(arena, .{ keg_child, dest_child }) catch continue;
            continue;
        }
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const src = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ keg_subdir, entry.name }, 0) catch continue;
        const leaf_name = dupeZ(arena, entry.name) catch continue;
        bucket.leaves.append(arena, .{ .src = src, .name = leaf_name }) catch continue;
        plan.total_leaves += 1;
    }

    const dest_z = dupeZ(arena, prefix_dest) catch return;
    plan.dest_dirs.append(arena, dest_z) catch return;
    plan.buckets.append(arena, bucket) catch return;

    for (subdirs.items) |pair| collectLinkBucket(plan, pair[0], pair[1], preserve_user_edits);
}

const LinkContext = struct {
    chunks: []const LinkChunk,
    next: std.atomic.Value(usize) = .init(0),
    keg_dir: []const u8,
    warnings: *WarningList,
};

fn runLinkChunk(ctx: *LinkContext, chunk: LinkChunk) void {
    const fd = std.c.open(chunk.dest_dir.ptr, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return; // dest dir creation failed earlier; nothing meaningful to do
    defer _ = std.c.close(fd);

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (chunk.leaves) |leaf| {
        // Symlink-first: on the common clean-install path the entry does not
        // exist, so one syscall per file suffices. Only an EEXIST collision
        // pays for the readlink probe + unlink + retry (same end state as
        // the probe-first order in linkSubdirOpts).
        if (std.c.symlinkat(leaf.src.ptr, fd, leaf.name.ptr) == 0) continue;
        const first_err = std.c.errno(@as(c_int, -1));
        if (first_err != .EXIST) {
            ctx.warnings.add("warning: failed to link {s}: {s}\n", .{ leaf.name, @tagName(first_err) });
            continue;
        }

        const rc = std.c.readlinkat(fd, leaf.name.ptr, &target_buf, target_buf.len);
        if (rc >= 0) {
            const existing = target_buf[0..@intCast(rc)];
            if (isConflict(existing, ctx.keg_dir)) {
                if (std.c.getenv("NB_DEBUG_LINK") != null) std.debug.print("conflict: {s} -> {s}\n", .{ leaf.name, existing });
                ctx.warnings.add("warning: {s} is already linked by {s}, skipping\n", .{ leaf.name, extractKegName(existing) });
                continue;
            }
            // Same package — overwrite
            _ = std.c.unlinkat(fd, leaf.name.ptr, 0);
        } else {
            switch (std.c.errno(rc)) {
                .NOENT => {}, // raced removal — just retry the symlink
                // Exists but is not a symlink (regular file / dir). etc/
                // preserves user edits; everything else is clobbered so the
                // keg's symlink wins — same rule as linkSubdirOpts.
                else => {
                    if (chunk.preserve_user_edits) continue;
                    _ = std.c.unlinkat(fd, leaf.name.ptr, 0);
                },
            }
        }
        const retry_rc = std.c.symlinkat(leaf.src.ptr, fd, leaf.name.ptr);
        if (retry_rc != 0) {
            ctx.warnings.add("warning: failed to link {s}: {s}\n", .{ leaf.name, @tagName(std.c.errno(retry_rc)) });
        }
    }
}

fn linkWorker(ctx: *LinkContext) void {
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.chunks.len) break;
        runLinkChunk(ctx, ctx.chunks[i]);
    }
}

fn executeLinkPlan(plan: *LinkPlan, keg_dir: []const u8) void {
    const lib_io = paths.safe_io;
    const arena = plan.arena.allocator();
    const bench = std.c.getenv("NB_BENCH") != null;
    var t0 = milliTimestamp();

    // Destination dirs first, parents before children (serial: this is the
    // directory count, not the file count — hundreds at most).
    for (plan.dest_dirs.items) |dest| {
        std.Io.Dir.createDirAbsolute(lib_io, dest, .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                var msg_buf: [512:0]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "warning: failed to create {s}: {}\n", .{ dest, err }) catch "warning: failed to create directory\n";
                std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
            }
        };
    }
    if (plan.total_leaves == 0) return;
    if (bench) {
        std.debug.print("[nb-bench] link mkdirs: {d}ms ({d} dirs)\n", .{ milliTimestamp() - t0, plan.dest_dirs.items.len });
        t0 = milliTimestamp();
    }

    // Split buckets into fixed-size chunks so a huge flat dir (share/man/man3
    // with thousands of pages) still spreads across workers — symlinkat is
    // per-syscall overhead-bound, not directory-lock-bound, so intra-dir
    // parallelism pays off (~1.4x at 4 threads, measured). Big chunks first
    // keep workers balanced; each chunk reopens its dirfd.
    var chunks: std.ArrayListUnmanaged(LinkChunk) = .empty;
    for (plan.buckets.items) |*bucket| {
        var off: usize = 0;
        while (off < bucket.leaves.items.len) : (off += LINK_CHUNK_SIZE) {
            const end = @min(off + LINK_CHUNK_SIZE, bucket.leaves.items.len);
            chunks.append(arena, .{
                .dest_dir = bucket.dest_dir,
                .preserve_user_edits = bucket.preserve_user_edits,
                .leaves = bucket.leaves.items[off..end],
            }) catch return;
        }
    }
    std.mem.sort(LinkChunk, chunks.items, {}, struct {
        fn biggerFirst(_: void, a: LinkChunk, b: LinkChunk) bool {
            return a.leaves.len > b.leaves.len;
        }
    }.biggerFirst);

    var warnings: WarningList = .{};
    var ctx = LinkContext{ .chunks = chunks.items, .keg_dir = keg_dir, .warnings = &warnings };
    runChunks(chunks.items.len, plan.total_leaves, &ctx, linkWorker);
    if (bench) std.debug.print("[nb-bench] link chunks: {d}ms ({d} chunks)\n", .{ milliTimestamp() - t0, chunks.items.len });
    warnings.flush();
}

fn runChunks(chunk_count: usize, leaf_count: usize, ctx: anytype, worker: fn (@TypeOf(ctx)) void) void {
    const cpu = std.Thread.getCpuCount() catch 2;
    var want: usize = @min(@min(cpu, MAX_LINK_WORKERS), chunk_count);
    if (std.c.getenv("NB_LINK_WORKERS")) |v| {
        const n = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
        if (n >= 1 and n <= 32) want = @min(n, chunk_count);
    }
    if (leaf_count < PARALLEL_LINK_MIN_LEAVES or want < 2) {
        // Small keg: stay on the calling thread (still dirfd-fast).
        worker(ctx);
        return;
    }
    var threads: [MAX_LINK_WORKERS]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..want) |_| {
        threads[spawned] = std.Thread.spawn(.{}, worker, .{ctx}) catch break;
        spawned += 1;
    }
    if (spawned == 0) {
        worker(ctx);
        return;
    }
    for (threads[0..spawned]) |t| t.join();
}

fn fastLinkKegGlobal(keg_dir: []const u8) void {
    const bench = std.c.getenv("NB_BENCH") != null;
    var t0 = milliTimestamp();
    var plan = LinkPlan.init();
    defer plan.deinit();
    for (subdir_mappings) |mapping| {
        var sub_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
        collectLinkBucket(&plan, keg_subdir, mapping.dest, mapping.preserve_user_edits);
        if (mapping.bottle_src) |bsrc| {
            var bbuf: [512]u8 = undefined;
            const bottle_subdir = std.fmt.bufPrint(&bbuf, "{s}/{s}", .{ keg_dir, bsrc }) catch continue;
            collectLinkBucket(&plan, bottle_subdir, mapping.dest, mapping.preserve_user_edits);
        }
    }
    if (bench) {
        std.debug.print("[nb-bench] link collect: {d}ms ({d} leaves)\n", .{ milliTimestamp() - t0, plan.total_leaves });
        t0 = milliTimestamp();
    }
    executeLinkPlan(&plan, keg_dir);
    if (bench) std.debug.print("[nb-bench] link exec: {d}ms\n", .{milliTimestamp() - t0});
}

fn collectUnlinkBucket(
    plan: *UnlinkPlan,
    keg_subdir: []const u8,
    prefix_dest: []const u8,
    is_root: bool,
) void {
    const lib_io = paths.safe_io;
    const arena = plan.arena.allocator();

    // Enumerate subdirectories from the KEG side: nb only links into dest
    // dirs that mirror keg dirs, so scanning the rest of the (shared)
    // prefix tree — as the serial walker did — is pure waste.
    var subdirs: std.ArrayListUnmanaged([2][:0]const u8) = .empty;
    if (std.Io.Dir.openDirAbsolute(lib_io, keg_subdir, .{ .iterate = true })) |d| {
        var kdir = d;
        defer kdir.close(lib_io);
        var iter = kdir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const keg_child = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ keg_subdir, entry.name }, 0) catch continue;
            const dest_child = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ prefix_dest, entry.name }, 0) catch continue;
            subdirs.append(arena, .{ keg_child, dest_child }) catch continue;
        }
    } else |_| return;

    var bucket = UnlinkBucket{
        .dest_dir = dupeZ(arena, prefix_dest) catch return,
        .keg_prefix = arena.dupe(u8, keg_subdir) catch return,
    };
    if (std.Io.Dir.openDirAbsolute(lib_io, prefix_dest, .{ .iterate = true })) |d| {
        var dest_dir = d;
        defer dest_dir.close(lib_io);
        var iter = dest_dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .sym_link) continue;
            const name_z = dupeZ(arena, entry.name) catch continue;
            bucket.names.append(arena, name_z) catch continue;
            plan.total_names += 1;
        }
    } else |_| {}
    plan.buckets.append(arena, bucket) catch return;

    if (!is_root) {
        const dest_z = dupeZ(arena, prefix_dest) catch return;
        plan.rmdir_dirs.append(arena, dest_z) catch {};
    }

    for (subdirs.items) |pair| collectUnlinkBucket(plan, pair[0], pair[1], false);
}

const UnlinkContext = struct {
    chunks: []const UnlinkChunk,
    next: std.atomic.Value(usize) = .init(0),
};

fn runUnlinkChunk(chunk: UnlinkChunk) void {
    const fd = std.c.open(chunk.dest_dir.ptr, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return;
    defer _ = std.c.close(fd);

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (chunk.names) |name| {
        const rc = std.c.readlinkat(fd, name.ptr, &target_buf, target_buf.len);
        if (rc < 0) continue;
        const target = target_buf[0..@intCast(rc)];
        if (std.mem.startsWith(u8, target, chunk.keg_prefix)) {
            _ = std.c.unlinkat(fd, name.ptr, 0);
        }
    }
}

fn unlinkWorker(ctx: *UnlinkContext) void {
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.chunks.len) break;
        runUnlinkChunk(ctx.chunks[i]);
    }
}

fn executeUnlinkPlan(plan: *UnlinkPlan) void {
    const lib_io = paths.safe_io;
    const arena = plan.arena.allocator();

    // Whole-bucket work items, big first (see executeLinkPlan for why).
    var chunks: std.ArrayListUnmanaged(UnlinkChunk) = .empty;
    for (plan.buckets.items) |*bucket| {
        if (bucket.names.items.len == 0) continue;
        chunks.append(arena, .{
            .dest_dir = bucket.dest_dir,
            .keg_prefix = bucket.keg_prefix,
            .names = bucket.names.items,
        }) catch return;
    }
    std.mem.sort(UnlinkChunk, chunks.items, {}, struct {
        fn biggerFirst(_: void, a: UnlinkChunk, b: UnlinkChunk) bool {
            return a.names.len > b.names.len;
        }
    }.biggerFirst);

    var ctx = UnlinkContext{ .chunks = chunks.items };
    runChunks(chunks.items.len, plan.total_names, &ctx, unlinkWorker);

    // Remove now-empty mirrored dirs, deepest first (mapping roots stay).
    var i = plan.rmdir_dirs.items.len;
    while (i > 0) {
        i -= 1;
        std.Io.Dir.deleteDirAbsolute(lib_io, plan.rmdir_dirs.items[i]) catch {};
    }
}

fn fastUnlinkKeg(keg_dir: []const u8) void {
    const bench = std.c.getenv("NB_BENCH") != null;
    const t0 = milliTimestamp();
    var plan = UnlinkPlan.init();
    defer plan.deinit();
    for (subdir_mappings) |mapping| {
        var sub_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
        collectUnlinkBucket(&plan, keg_subdir, mapping.dest, true);
        if (mapping.bottle_src) |bsrc| {
            var bbuf: [512]u8 = undefined;
            const bottle_subdir = std.fmt.bufPrint(&bbuf, "{s}/{s}", .{ keg_dir, bsrc }) catch continue;
            collectUnlinkBucket(&plan, bottle_subdir, mapping.dest, true);
        }
    }
    executeUnlinkPlan(&plan);
    if (bench) std.debug.print("[nb-bench] unlink: {d}ms ({d} candidates)\n", .{ milliTimestamp() - t0, plan.total_names });
}

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
        if (imageMagickNeedsEnv(keg_dir)) needs_env_shim = true;
    }

    if (fast_link_posix and
        ((options.mode == .global and !needs_env_shim) or options.mode == .private_dependency))
    {
        // Fast path: one keg scan, serial dir creation, parallel dirfd leaf
        // work. Shim modes keep the serial walkers (bin/ is small and the
        // wrapper logic lives there).
        if (options.mode == .private_dependency) {
            fastUnlinkKeg(keg_dir);
        } else {
            fastLinkKegGlobal(keg_dir);
        }
    } else {
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
            // Homebrew mutable payload (.bottle/etc) is never executable, so
            // link it with the same preserve-user-edits rule as etc/ (#347).
            if (mapping.bottle_src) |bsrc| {
                var bbuf: [512]u8 = undefined;
                const bottle_subdir = std.fmt.bufPrint(&bbuf, "{s}/{s}", .{ keg_dir, bsrc }) catch continue;
                linkSubdirOpts(bottle_subdir, mapping.dest, keg_dir, mapping.preserve_user_edits);
            }
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

fn executableLinksNeedRepair(keg_subdir: []const u8, prefix_dest: []const u8, keg_dir: []const u8, mode: LinkMode, env_shim: bool) bool {
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
            if (executableLinksNeedRepair(src, dest, keg_dir, mode, env_shim)) return true;
            continue;
        }

        if (entry.kind != .file and entry.kind != .sym_link) continue;

        switch (mode) {
            .global => {
                if (env_shim) {
                    // Env-shim kegs (git's GIT_EXEC_PATH, …) link through
                    // .nb-wrappers/, not at the keg binary — that IS the
                    // correct global end state. Comparing against the keg
                    // binary made these kegs permanently "need repair" and
                    // relinked on every install: pure churn (#314).
                    var wrapper_path_buf: [1024]u8 = undefined;
                    const wrapper_path = std.fmt.bufPrint(&wrapper_path_buf, "{s}/{s}/{s}", .{ keg_dir, WRAPPER_DIR, entry.name }) catch return true;
                    if (!symlinkTargetEquals(dest, wrapper_path)) return true;
                } else if (!symlinkTargetEquals(dest, src)) return true;
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

    // Mirror linkKegWithOptions' env-shim detection so the repair check
    // compares against the same link target the linker actually creates.
    var env_shim = false;
    if (options.mode == .global) {
        var git_core_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&git_core_buf, "{s}/libexec/git-core", .{keg_dir})) |git_core_path| {
            if (std.Io.Dir.openDirAbsolute(paths.safe_io, git_core_path, .{})) |d| {
                var bd = d;
                bd.close(paths.safe_io);
                env_shim = true;
            } else |_| {}
        } else |_| {}
    }

    for (subdir_mappings) |mapping| {
        if (!isExecutableSubdir(mapping.src)) continue;
        var sub_buf: [512]u8 = undefined;
        const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
        if (executableLinksNeedRepair(keg_subdir, mapping.dest, keg_dir, options.mode, env_shim)) return true;
    }

    return false;
}

/// Unlink a keg's files and remove opt/ symlink.
pub fn unlinkKeg(name: []const u8, version: []const u8) !void {
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ CELLAR_DIR, name, version }) catch return error.PathTooLong;

    if (fast_link_posix) {
        fastUnlinkKeg(keg_dir);
    } else {
        for (subdir_mappings) |mapping| {
            var sub_buf: [512]u8 = undefined;
            const keg_subdir = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, mapping.src }) catch continue;
            unlinkSubdir(keg_subdir, mapping.dest);
            if (mapping.bottle_src) |bsrc| {
                var bbuf: [512]u8 = undefined;
                const bottle_subdir = std.fmt.bufPrint(&bbuf, "{s}/{s}", .{ keg_dir, bsrc }) catch continue;
                unlinkSubdir(bottle_subdir, mapping.dest);
            }
        }
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
    };
    const script = try renderShimWrapper(std.testing.allocator, "/opt/nanobrew/prefix/Cellar/git/2.47.0/bin/git", &.{}, &env);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "GIT_EXEC_PATH=\"/opt/nanobrew/prefix/Cellar/git/2.47.0/libexec/git-core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "export GIT_EXEC_PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "exec \"/opt/nanobrew/prefix/Cellar/git/2.47.0/bin/git\" \"$@\"") != null);
}

test "renderShimWrapper includes ImageMagick env vars" {
    const env = [_][2][]const u8{
        .{ "MAGICK_CONFIGURE_PATH", "/opt/nanobrew/prefix/Cellar/imagemagick/7.1.2-26/etc/ImageMagick-7" },
        .{ "MAGICK_CODER_MODULE_PATH", "/opt/nanobrew/prefix/Cellar/imagemagick/7.1.2-26/lib/ImageMagick/modules-Q16HDRI/coders" },
    };
    const script = try renderShimWrapper(std.testing.allocator, "/opt/nanobrew/prefix/Cellar/imagemagick/7.1.2-26/bin/magick", &.{}, &env);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "MAGICK_CONFIGURE_PATH=\"/opt/nanobrew/prefix/Cellar/imagemagick/7.1.2-26/etc/ImageMagick-7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "export MAGICK_CODER_MODULE_PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "exec \"/opt/nanobrew/prefix/Cellar/imagemagick/7.1.2-26/bin/magick\" \"$@\"") != null);
}

// ── .bottle/ mutable-payload linking (#347) ──────────────────────────────
//
// Homebrew bottles ship config under `.bottle/etc/` (and runtime state under
// `.bottle/var/`) rather than the keg root, so pour can install it into the
// *shared* prefix. The linker now links that payload into `<prefix>/etc/` so
// relocated binaries find their config — e.g. OpenSSL's OPENSSLDIR resolves to
// `<prefix>/etc/openssl@3/openssl.cnf` instead of a non-existent path. The
// tests below drive the link/unlink mechanisms with a `.bottle/etc` source
// path (what the subdir_mappings loop now routes to them) and check that a
// non-keg symlink added by a postinstall step (cert.pem -> ca-certificates)
// survives unlink.

fn testWriteFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}

/// Create `abs_path` and every missing ancestor (ignores already-exists).
fn testMkPath(io: std.Io, abs_path: []const u8) void {
    var i: usize = 1;
    while (std.mem.indexOfScalarPos(u8, abs_path, i, '/')) |slash| {
        std.Io.Dir.createDirAbsolute(io, abs_path[0..slash], .default_dir) catch {};
        i = slash + 1;
    }
    std.Io.Dir.createDirAbsolute(io, abs_path, .default_dir) catch {};
}

const BottleFixture = struct {
    root: []const u8,
    keg_dir: []const u8,
    keg_etc: []const u8,
    keg_cfg: []const u8,
    keg_misc: []const u8,
    elsewhere: []const u8,
    dest_etc: []const u8,
    dest_cfg: []const u8,
    dest_cert: []const u8,
};

/// Builds a fake keg carrying `.bottle/etc/openssl@3/{openssl.cnf,misc/foo.cnf}`
/// plus an `elsewhere/cert.pem` (the target a postinstall cert.pem symlink
/// would point at). `dest/` is left empty for link tests; unlink tests populate
/// it themselves before calling.
fn makeBottleFixture(a: std.mem.Allocator, io: std.Io, tag: []const u8) !BottleFixture {
    var root_buf: [128]u8 = undefined;
    const root_tmp = try std.fmt.bufPrint(&root_buf, "/tmp/nb-test-bottle-{s}-{d}", .{ tag, std.c.getpid() });
    const root = try a.dupe(u8, root_tmp);
    std.Io.Dir.createDirAbsolute(io, root, .default_dir) catch {};

    const keg_dir = try std.fmt.allocPrint(a, "{s}/keg", .{root});
    const keg_etc = try std.fmt.allocPrint(a, "{s}/.bottle/etc", .{keg_dir});
    const keg_pkg = try std.fmt.allocPrint(a, "{s}/openssl@3", .{keg_etc});
    const keg_misc_dir = try std.fmt.allocPrint(a, "{s}/misc", .{keg_pkg});
    const keg_cfg = try std.fmt.allocPrint(a, "{s}/openssl.cnf", .{keg_pkg});
    const keg_misc = try std.fmt.allocPrint(a, "{s}/foo.cnf", .{keg_misc_dir});
    const elsewhere_dir = try std.fmt.allocPrint(a, "{s}/elsewhere", .{root});
    const elsewhere = try std.fmt.allocPrint(a, "{s}/cert.pem", .{elsewhere_dir});
    const dest_etc = try std.fmt.allocPrint(a, "{s}/dest/etc", .{root});
    const dest_cfg = try std.fmt.allocPrint(a, "{s}/openssl@3/openssl.cnf", .{dest_etc});
    const dest_cert = try std.fmt.allocPrint(a, "{s}/openssl@3/cert.pem", .{dest_etc});

    testMkPath(io, keg_misc_dir);
    try testWriteFile(io, keg_cfg, "# openssl config\n");
    try testWriteFile(io, keg_misc, "# misc\n");
    testMkPath(io, elsewhere_dir);
    try testWriteFile(io, elsewhere, "ca-cert\n");

    return .{
        .root = root,
        .keg_dir = keg_dir,
        .keg_etc = keg_etc,
        .keg_cfg = keg_cfg,
        .keg_misc = keg_misc,
        .elsewhere = elsewhere,
        .dest_etc = dest_etc,
        .dest_cfg = dest_cfg,
        .dest_cert = dest_cert,
    };
}

test "subdir_mappings: etc carries .bottle/etc fallback, others do not" {
    var found_etc = false;
    for (subdir_mappings) |mapping| {
        if (std.mem.eql(u8, mapping.src, "etc")) {
            found_etc = true;
            try std.testing.expect(mapping.preserve_user_edits);
            try std.testing.expect(mapping.bottle_src != null);
            if (mapping.bottle_src) |bsrc| {
                try std.testing.expectEqualStrings(".bottle/etc", bsrc);
            }
        } else {
            try std.testing.expect(mapping.bottle_src == null);
        }
    }
    try std.testing.expect(found_etc);
}

test "bottle payload: fast-path links .bottle/etc into shared prefix (#347)" {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try makeBottleFixture(arena.allocator(), lib_io, "fastlink");
    defer std.Io.Dir.cwd().deleteTree(lib_io, f.root) catch {};

    // linkSubdirOpts/executeLinkPlan create the leaf dest dir but not its
    // parent (<root>/dest); create the dest tree up front.
    testMkPath(lib_io, f.dest_etc);

    var plan = LinkPlan.init();
    defer plan.deinit();
    collectLinkBucket(&plan, f.keg_etc, f.dest_etc, true);
    try std.testing.expectEqual(@as(usize, 2), plan.total_leaves); // openssl.cnf + misc/foo.cnf
    executeLinkPlan(&plan, f.keg_dir);

    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n_cfg = try std.Io.Dir.readLinkAbsolute(lib_io, f.dest_cfg, &tbuf);
    try std.testing.expectEqualStrings(f.keg_cfg, tbuf[0..n_cfg]);

    const dest_misc = try std.fmt.allocPrint(arena.allocator(), "{s}/openssl@3/misc/foo.cnf", .{f.dest_etc});
    const n_misc = try std.Io.Dir.readLinkAbsolute(lib_io, dest_misc, &tbuf);
    try std.testing.expectEqualStrings(f.keg_misc, tbuf[0..n_misc]);
}

test "bottle payload: slow-path links .bottle/etc into shared prefix (#347)" {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try makeBottleFixture(arena.allocator(), lib_io, "slowlink");
    defer std.Io.Dir.cwd().deleteTree(lib_io, f.root) catch {};

    testMkPath(lib_io, f.dest_etc);

    linkSubdirOpts(f.keg_etc, f.dest_etc, f.keg_dir, true);

    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n_cfg = try std.Io.Dir.readLinkAbsolute(lib_io, f.dest_cfg, &tbuf);
    try std.testing.expectEqualStrings(f.keg_cfg, tbuf[0..n_cfg]);

    const dest_misc = try std.fmt.allocPrint(arena.allocator(), "{s}/openssl@3/misc/foo.cnf", .{f.dest_etc});
    const n_misc = try std.Io.Dir.readLinkAbsolute(lib_io, dest_misc, &tbuf);
    try std.testing.expectEqualStrings(f.keg_misc, tbuf[0..n_misc]);
}

test "bottle payload: fast-path unlink removes keg symlinks, keeps non-keg (#347)" {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try makeBottleFixture(arena.allocator(), lib_io, "fastunlink");
    defer std.Io.Dir.cwd().deleteTree(lib_io, f.root) catch {};

    // Populate dest as if a prior link + a postinstall cert.pem had run.
    testMkPath(lib_io, std.fmt.allocPrint(arena.allocator(), "{s}/openssl@3", .{f.dest_etc}) catch unreachable);
    std.Io.Dir.symLinkAbsolute(lib_io, f.keg_cfg, f.dest_cfg, .{}) catch {};
    std.Io.Dir.symLinkAbsolute(lib_io, f.elsewhere, f.dest_cert, .{}) catch {};

    var plan = UnlinkPlan.init();
    defer plan.deinit();
    collectUnlinkBucket(&plan, f.keg_etc, f.dest_etc, true);
    executeUnlinkPlan(&plan);

    // keg symlink gone ...
    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(lib_io, f.dest_cfg, &tbuf)) |_| {
        return error.TestUnexpectedKegSymlinkSurvived;
    } else |_| {}
    // ... non-keg symlink preserved.
    const n_cert = try std.Io.Dir.readLinkAbsolute(lib_io, f.dest_cert, &tbuf);
    try std.testing.expectEqualStrings(f.elsewhere, tbuf[0..n_cert]);
}

test "bottle payload: slow-path unlink removes keg symlinks, keeps non-keg (#347)" {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try makeBottleFixture(arena.allocator(), lib_io, "slowunlink");
    defer std.Io.Dir.cwd().deleteTree(lib_io, f.root) catch {};

    testMkPath(lib_io, std.fmt.allocPrint(arena.allocator(), "{s}/openssl@3", .{f.dest_etc}) catch unreachable);
    std.Io.Dir.symLinkAbsolute(lib_io, f.keg_cfg, f.dest_cfg, .{}) catch {};
    std.Io.Dir.symLinkAbsolute(lib_io, f.elsewhere, f.dest_cert, .{}) catch {};

    unlinkSubdir(f.keg_etc, f.dest_etc);

    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(lib_io, f.dest_cfg, &tbuf)) |_| {
        return error.TestUnexpectedKegSymlinkSurvived;
    } else |_| {}
    const n_cert = try std.Io.Dir.readLinkAbsolute(lib_io, f.dest_cert, &tbuf);
    try std.testing.expectEqualStrings(f.elsewhere, tbuf[0..n_cert]);
}

test "git shim uses the keg's templates during git init" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrint(a, "/tmp/nb-git-template-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const keg = try std.fmt.allocPrint(a, "{s}/keg", .{root});
    const templates = try std.fmt.allocPrint(a, "{s}/share/git-core/templates", .{keg});
    testMkPath(io, templates);
    const marker = try std.fmt.allocPrint(a, "{s}/nanobrew-template", .{templates});
    try testWriteFile(io, marker, "from the keg\n");
    const shim = try std.fmt.allocPrint(a, "{s}/git", .{root});
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{root});
    installShimLink(keg, "/usr/bin/git", shim, "git", &.{});
    const result = try std.process.run(a, io, .{ .argv = &.{ shim, "init", "--quiet", repo } });
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const installed = try std.fmt.allocPrint(a, "{s}/.git/nanobrew-template", .{repo});
    const file = try std.Io.Dir.openFileAbsolute(io, installed, .{});
    file.close(io);
}
