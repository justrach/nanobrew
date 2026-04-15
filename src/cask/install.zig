// nanobrew — Cask install/remove pipeline
//
// Handles downloading, mounting/extracting, and installing macOS .app/.dmg/.pkg bundles.
// Apps are installed to /Applications/, binaries symlinked to prefix/bin/.

const std = @import("std");
const Cask = @import("../api/cask.zig").Cask;
const Artifact = @import("../api/cask.zig").Artifact;
const DownloadFormat = @import("../api/cask.zig").DownloadFormat;
const paths = @import("../platform/paths.zig");
const fetch = @import("../net/fetch.zig");
const builtin = @import("builtin");

const PREFIX = paths.PREFIX;
const CASKROOM_DIR = paths.CASKROOM_DIR;
const CACHE_TMP = paths.TMP_DIR;

pub fn installCask(alloc: std.mem.Allocator, cask: Cask) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();

    if (comptime builtin.os.tag == .linux) {
        std.Io.File.stderr().writeStreamingAll(lib_io, "nb: casks are not supported on Linux yet\n") catch {};
        return error.CaskNotSupported;
    }

    // For third-party taps, cask.token may contain slashes (e.g. "indaco/tap/sley").
    // Use only the basename for filesystem paths to avoid creating nested directories.
    const safe_token = if (std.mem.lastIndexOfScalar(u8, cask.token, '/')) |idx|
        cask.token[idx + 1 ..]
    else
        cask.token;

    // 1. Download artifact
    const ext: []const u8 = switch (cask.downloadFormat()) {
        .dmg => ".dmg",
        .zip => ".zip",
        .pkg => ".pkg",
        .tar_gz => ".tar.gz",
        .unknown => ".dmg", // try dmg as default
    };
    var dl_buf: [512]u8 = undefined;
    const dl_path = std.fmt.bufPrint(&dl_buf, "{s}/{s}{s}", .{ CACHE_TMP, safe_token, ext }) catch return error.PathTooLong;

    try downloadArtifact(alloc, cask.url, dl_path, cask);

    // 2. Create Caskroom entry
    var caskroom_buf: [512]u8 = undefined;
    const caskroom_path = cask.caskroomPath(&caskroom_buf);
    std.Io.Dir.createDirAbsolute(lib_io, CASKROOM_DIR, .default_dir) catch {};
    var token_dir_buf: [512]u8 = undefined;
    const token_dir = std.fmt.bufPrint(&token_dir_buf, "{s}/{s}", .{ CASKROOM_DIR, safe_token }) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(lib_io, token_dir, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(lib_io, caskroom_path, .default_dir) catch {};

    // 3. Mount/extract based on format
    const format = cask.downloadFormat();
    var mount_point_buf: [512]u8 = undefined;
    var mount_point: ?[]const u8 = null;
    var temp_extract_dir: ?[]const u8 = null;
    var temp_extract_buf: [512]u8 = undefined;

    switch (format) {
        .dmg, .unknown => {
            // Remove Gatekeeper quarantine from .dmg before mounting
            if (comptime builtin.os.tag == .macos) {
                if (std.process.run(alloc, lib_io, .{
                    .argv = &.{ "xattr", "-dr", "com.apple.quarantine", dl_path },
                })) |r| {
                    alloc.free(r.stdout);
                    alloc.free(r.stderr);
                } else |_| {}
            }
            mount_point = try mountDmg(alloc, dl_path, &mount_point_buf);
        },
        .zip => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
            std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
            try extractZip(alloc, dl_path, tmp_dir);
            temp_extract_dir = tmp_dir;
        },
        .tar_gz => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
            std.Io.Dir.createDirAbsolute(lib_io, tmp_dir, .default_dir) catch {};
            try extractTarGz(alloc, dl_path, tmp_dir);
            temp_extract_dir = tmp_dir;
        },
        .pkg => {}, // standalone, handled directly in artifact processing
    }

    defer {
        // Cleanup: unmount dmg
        if (mount_point) |mp| {
            unmountDmg(alloc, mp);
        }
        // Cleanup: remove temp extract dir
        if (temp_extract_dir) |td| {
            std.Io.Dir.cwd().deleteTree(lib_io, td) catch {};
        }
        // Cleanup: remove downloaded file
        std.Io.Dir.deleteFileAbsolute(lib_io, dl_path) catch {};
    }

    // 4. Process artifacts in order
    const source_dir: []const u8 = mount_point orelse temp_extract_dir orelse CACHE_TMP;

    var any_artifact_failed = false;

    for (cask.artifacts) |art| {
        switch (art) {
            .app => |app_name| {
                // Validate app name: must end with .app, no path traversal (#45)
                if (std.mem.indexOf(u8, app_name, "..") != null or
                    !std.mem.endsWith(u8, app_name, ".app"))
                {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: skipping unsafe app artifact: {s}\n", .{app_name}) catch "nb: skipping unsafe app artifact\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                var src_buf: [1024]u8 = undefined;
                const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ source_dir, app_name }) catch continue;
                var dst_buf: [512]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "/Applications/{s}", .{app_name}) catch continue;

                // Verify source app exists before attempting copy (#60)
                std.Io.Dir.accessAbsolute(lib_io, src, .{}) catch {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: error: {s} not found in {s} — DMG may not have mounted correctly\n", .{ app_name, source_dir }) catch "nb: error: app not found\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                };

                // Remove existing app first
                std.Io.Dir.cwd().deleteTree(lib_io, dst) catch {};

                // cp -R source to /Applications/
                const cp_result = std.process.run(alloc, lib_io, .{
                    .argv = &.{ "cp", "-R", src, dst },
                }) catch {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: failed to copy {s} to /Applications/\n", .{app_name}) catch "nb: failed to copy app\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                };
                alloc.free(cp_result.stdout);
                alloc.free(cp_result.stderr);
                const cp_exit_code: u8 = switch (cp_result.term) {
                    .exited => |code| code,
                    else => 1,
                };
                if (cp_exit_code != 0) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: cp failed for {s} (exit code {d})\n", .{ app_name, cp_exit_code }) catch "nb: cp failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    any_artifact_failed = true;
                    continue;
                }

                // Remove Gatekeeper quarantine so the app can launch without warning
                if (comptime builtin.os.tag == .macos) {
                    if (std.process.run(alloc, lib_io, .{
                        .argv = &.{ "xattr", "-dr", "com.apple.quarantine", dst },
                    })) |r| {
                        alloc.free(r.stdout);
                        alloc.free(r.stderr);
                    } else |_| {}
                }
            },
            .binary => |bin| {
                // Validate bin.target: no path traversal, no slashes (#45)
                if (std.mem.indexOf(u8, bin.target, "..") != null or
                    std.mem.indexOf(u8, bin.target, "/") != null)
                {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: skipping unsafe binary target: {s}\n", .{bin.target}) catch "nb: skipping unsafe binary target\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                var resolved_buf: [1024]u8 = undefined;
                var source: []const u8 = undefined;

                if (std.mem.startsWith(u8, bin.source, "$APPDIR")) {
                    // $APPDIR expansion for app-bundled binaries
                    source = std.fmt.bufPrint(&resolved_buf, "/Applications{s}", .{bin.source["$APPDIR".len..]}) catch continue;
                } else if (std.mem.startsWith(u8, bin.source, "/")) {
                    // Absolute path
                    source = bin.source;
                } else {
                    // Relative path — binary is in the extract/mount dir.
                    // Copy to Caskroom, then symlink from there.
                    var src_buf2: [1024]u8 = undefined;
                    const extract_src = std.fmt.bufPrint(&src_buf2, "{s}/{s}", .{ source_dir, bin.source }) catch continue;
                    var caskroom_bin_buf: [1024]u8 = undefined;
                    const caskroom_bin = std.fmt.bufPrint(&caskroom_bin_buf, "{s}/{s}", .{ caskroom_path, bin.target }) catch continue;

                    // Copy binary to Caskroom
                    const cp_result = std.process.run(alloc, lib_io, .{
                        .argv = &.{ "cp", extract_src, caskroom_bin },
                    }) catch {
                        var _b: [512]u8 = undefined;
                        const _m = std.fmt.bufPrint(&_b, "nb: failed to copy binary {s}\n", .{bin.source}) catch "nb: failed to copy binary\n";
                        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                        continue;
                    };
                    alloc.free(cp_result.stdout);
                    alloc.free(cp_result.stderr);

                    // Make executable
                    const chmod_result = std.process.run(alloc, lib_io, .{
                        .argv = &.{ "chmod", "+x", caskroom_bin },
                    }) catch {
                        var _b: [512]u8 = undefined;
                        const _m = std.fmt.bufPrint(&_b, "nb: failed to chmod binary {s}\n", .{bin.source}) catch "nb: failed to chmod binary\n";
                        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                        continue;
                    };
                    alloc.free(chmod_result.stdout);
                    alloc.free(chmod_result.stderr);

                    source = std.fmt.bufPrint(&resolved_buf, "{s}", .{caskroom_bin}) catch continue;
                }

                // Security: validate resolved source path to prevent symlink escape
                // Reject paths containing ".." components
                if (std.mem.indexOf(u8, source, "..") != null) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: refusing to symlink binary with path traversal: {s}\n", .{bin.source}) catch "nb: refusing to symlink binary\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                // Source must start with /Applications, the Caskroom, or be within extract dir
                const is_app_path = std.mem.startsWith(u8, source, "/Applications");
                const is_caskroom_path = std.mem.startsWith(u8, source, paths.CASKROOM_DIR);
                const is_extract_path = std.mem.startsWith(u8, source, source_dir);
                if (!is_app_path and !is_caskroom_path and !is_extract_path) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: refusing to symlink binary outside allowed directories: {s}\n", .{bin.source}) catch "nb: refusing to symlink binary\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }

                var link_buf: [512]u8 = undefined;
                const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, bin.target }) catch continue;

                std.Io.Dir.deleteFileAbsolute(lib_io, link_path) catch {};
                std.Io.Dir.symLinkAbsolute(lib_io, source, link_path, .{}) catch |err| {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: symlink failed for {s}: {}\n", .{ bin.target, err }) catch "nb: symlink failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                };
            },
            .pkg => |pkg_name| {
                // Validate pkg name: no path traversal, no absolute paths (#Task8)
                if (std.mem.indexOf(u8, pkg_name, "..") != null or
                    (pkg_name.len > 0 and pkg_name[0] == '/'))
                {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: skipping unsafe pkg artifact: {s}\n", .{pkg_name}) catch "nb: skipping unsafe pkg artifact\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                }
                var pkg_buf: [1024]u8 = undefined;
                const pkg_path = if (format == .pkg)
                    dl_path // standalone .pkg download
                else
                    std.fmt.bufPrint(&pkg_buf, "{s}/{s}", .{ source_dir, pkg_name }) catch continue;

                // Remove Gatekeeper quarantine from the .pkg before installing
                if (comptime builtin.os.tag == .macos) {
                    if (std.process.run(alloc, lib_io, .{
                        .argv = &.{ "xattr", "-dr", "com.apple.quarantine", pkg_path },
                    })) |r| {
                        alloc.free(r.stdout);
                        alloc.free(r.stderr);
                    } else |_| {}
                }

                const result = std.process.run(alloc, lib_io, .{
                    .argv = &.{ "sudo", "installer", "-pkg", pkg_path, "-target", "/" },
                }) catch {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: pkg install failed for {s}\n", .{pkg_name}) catch "nb: pkg install failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                    continue;
                };
                alloc.free(result.stdout);
                alloc.free(result.stderr);
                if (switch (result.term) { .exited => |c| c != 0, else => true }) {
                    var _b: [512]u8 = undefined;
                    const _m = std.fmt.bufPrint(&_b, "nb: installer failed for {s}\n", .{pkg_name}) catch "nb: installer failed\n";
                    std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
                }
            },
            .uninstall => {}, // only used during removal
        }
    }

    if (any_artifact_failed) return error.ArtifactFailed;
}

pub fn removeCask(
    _: std.mem.Allocator,
    token: []const u8,
    version: []const u8,
    apps: []const []const u8,
    binaries: []const []const u8,
) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();

    // 1. Delete apps from /Applications/
    for (apps) |app| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/Applications/{s}", .{app}) catch continue;
        std.Io.Dir.cwd().deleteTree(lib_io, path) catch |err| {
            var _b: [512]u8 = undefined;
            const _m = std.fmt.bufPrint(&_b, "nb: could not remove {s}: {}\n", .{ app, err }) catch "nb: could not remove app\n";
            std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
        };
    }

    // 2. Delete binary symlinks from prefix/bin/
    for (binaries) |bin| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/bin/{s}", .{ PREFIX, bin }) catch continue;
        std.Io.Dir.deleteFileAbsolute(lib_io, path) catch {};
    }

    // 3. Delete Caskroom entry
    var caskroom_buf: [512]u8 = undefined;
    const ver_dir = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{ PREFIX, token, version }) catch return;
    std.Io.Dir.cwd().deleteTree(lib_io, ver_dir) catch {};

    // Try to remove parent dir if empty
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Caskroom/{s}", .{ PREFIX, token }) catch return;
    std.Io.Dir.deleteDirAbsolute(lib_io, parent) catch {};
}

fn downloadArtifact(alloc: std.mem.Allocator, url: []const u8, dest: []const u8, cask: Cask) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();

    // Native HTTP download (no curl dependency)
    fetch.download(alloc, url, dest) catch return error.DownloadFailed;

    // Verify SHA256 if available
    if (cask.sha256.len == 0 or std.mem.eql(u8, cask.sha256, "no_check")) {
        var _b: [512]u8 = undefined;
        const _m = std.fmt.bufPrint(&_b, "nb: warning: skipping SHA256 verification for {s} (no checksum available)\n", .{cask.token}) catch "nb: warning: skipping SHA256 verification\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
        return;
    }

    verifySha256(alloc, dest, cask.sha256) catch |err| {
        var _b: [512]u8 = undefined;
        const _m = std.fmt.bufPrint(&_b, "nb: error: SHA256 verification failed for {s}\n", .{cask.token}) catch "nb: error: SHA256 verification failed\n";
        std.Io.File.stderr().writeStreamingAll(lib_io, _m) catch {};
        // Clean up the bad download
        std.Io.Dir.deleteFileAbsolute(lib_io, dest) catch {};
        return err;
    };
}

fn verifySha256(_: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return error.VerifyFailed;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const bytes_read = file.readPositional(lib_io, &.{buf[0..]}, offset) catch {
            file.close(lib_io);
            return error.VerifyFailed;
        };
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
        offset += @intCast(bytes_read);
    }
    file.close(lib_io);

    const digest = hasher.finalResult();
    const charset = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, idx| {
        hex[idx * 2] = charset[byte >> 4];
        hex[idx * 2 + 1] = charset[byte & 0x0f];
    }

    if (expected.len < 64) return error.VerifyFailed;
    if (!std.mem.eql(u8, &hex, expected[0..64])) return error.Sha256Mismatch;
}

fn mountDmg(alloc: std.mem.Allocator, dmg_path: []const u8, out_buf: []u8) ![]const u8 {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "hdiutil", "attach", "-nobrowse", "-noautoopen", "-plist", dmg_path },
        .stdout_limit = .limited(64 * 1024),
    }) catch return error.MountFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.MountFailed;

    // Parse mount point from hdiutil output — look for /Volumes/ path
    if (std.mem.indexOf(u8, result.stdout, "/Volumes/")) |start| {
        // Find end of path (newline, < for plist, or end of string)
        var end = start;
        while (end < result.stdout.len) : (end += 1) {
            if (result.stdout[end] == '\n' or result.stdout[end] == '<' or result.stdout[end] == '\t') break;
        }
        // Trim trailing whitespace
        while (end > start and (result.stdout[end - 1] == ' ' or result.stdout[end - 1] == '\r')) {
            end -= 1;
        }
        const mount = result.stdout[start..end];
        @memcpy(out_buf[0..mount.len], mount);
        return out_buf[0..mount.len];
    }

    return error.MountFailed;
}

fn unmountDmg(alloc: std.mem.Allocator, mount_point: []const u8) void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "hdiutil", "detach", mount_point, "-quiet" },
        .stdout_limit = .limited(1024),
    }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

fn extractZip(alloc: std.mem.Allocator, zip_path: []const u8, dest: []const u8) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    // Pre-list ZIP contents and check for path traversal
    const list_result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "unzip", "-l", zip_path },
        .stdout_limit = .limited(256 * 1024),
    }) catch return error.ExtractFailed;
    defer alloc.free(list_result.stdout);
    defer alloc.free(list_result.stderr);

    // Scan listed paths for traversal sequences ("../" or "/..")
    var lines = std.mem.splitScalar(u8, list_result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, std.mem.trimStart(u8, line, " "), " \r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "../") != null or
            std.mem.indexOf(u8, trimmed, "/..") != null)
        {
            return error.UnsafePath;
        }
    }

    // Now extract
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "unzip", "-o", "-q", zip_path, "-d", dest },
        .stdout_limit = .limited(4096),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.ExtractFailed;
}

fn extractTarGz(alloc: std.mem.Allocator, tar_path: []const u8, dest: []const u8) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();
    const result = std.process.run(alloc, lib_io, .{
        .argv = &.{ "tar", "-xzf", tar_path, "--no-same-permissions", "-C", dest },
        .stdout_limit = .limited(4096),
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) { .exited => |c| c != 0, else => true }) return error.ExtractFailed;
}
