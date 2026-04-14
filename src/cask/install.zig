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
const CACHE_TMP = paths.TMP_DIR;

pub fn installCask(alloc: std.mem.Allocator, cask: Cask) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (comptime builtin.os.tag == .linux) {
        stderr.print("nb: casks are not supported on Linux yet\n", .{}) catch {};
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
    std.fs.makeDirAbsolute("/opt/nanobrew/prefix/Caskroom") catch {};
    var token_dir_buf: [512]u8 = undefined;
    const token_dir = std.fmt.bufPrint(&token_dir_buf, "/opt/nanobrew/prefix/Caskroom/{s}", .{safe_token}) catch return error.PathTooLong;
    std.fs.makeDirAbsolute(token_dir) catch {};
    std.fs.makeDirAbsolute(caskroom_path) catch {};

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
                _ = std.process.Child.run(.{
                    .allocator = alloc,
                    .argv = &.{ "xattr", "-dr", "com.apple.quarantine", dl_path },
                }) catch {};
            }
            mount_point = try mountDmg(alloc, dl_path, &mount_point_buf);
        },
        .zip => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
            std.fs.makeDirAbsolute(tmp_dir) catch {};
            try extractZip(alloc, dl_path, tmp_dir);
            temp_extract_dir = tmp_dir;
        },
        .tar_gz => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, safe_token }) catch return error.PathTooLong;
            std.fs.makeDirAbsolute(tmp_dir) catch {};
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
            std.fs.deleteTreeAbsolute(td) catch {};
        }
        // Cleanup: remove downloaded file
        std.fs.deleteFileAbsolute(dl_path) catch {};
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
                    stderr.print("nb: skipping unsafe app artifact: {s}\n", .{app_name}) catch {};
                    continue;
                }
                var src_buf: [1024]u8 = undefined;
                const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ source_dir, app_name }) catch continue;
                var dst_buf: [512]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "/Applications/{s}", .{app_name}) catch continue;

                // Verify source app exists before attempting copy (#60)
                std.fs.accessAbsolute(src, .{}) catch {
                    stderr.print("nb: error: {s} not found in {s} — DMG may not have mounted correctly\n", .{ app_name, source_dir }) catch {};
                    any_artifact_failed = true;
                    continue;
                };

                // Remove existing app first
                std.fs.deleteTreeAbsolute(dst) catch {};

                // cp -R source to /Applications/
                const cp_result = std.process.Child.run(.{
                    .allocator = alloc,
                    .argv = &.{ "cp", "-R", src, dst },
                }) catch {
                    stderr.print("nb: failed to copy {s} to /Applications/\n", .{app_name}) catch {};
                    any_artifact_failed = true;
                    continue;
                };
                alloc.free(cp_result.stdout);
                alloc.free(cp_result.stderr);
                const cp_exit_code: u8 = switch (cp_result.term) {
                    .Exited => |code| code,
                    else => 1,
                };
                if (cp_exit_code != 0) {
                    stderr.print("nb: cp failed for {s} (exit code {d})\n", .{ app_name, cp_exit_code }) catch {};
                    any_artifact_failed = true;
                    continue;
                }

                // Remove Gatekeeper quarantine so the app can launch without warning
                if (comptime builtin.os.tag == .macos) {
                    _ = std.process.Child.run(.{
                        .allocator = alloc,
                        .argv = &.{ "xattr", "-dr", "com.apple.quarantine", dst },
                    }) catch {};
                }
            },
            .binary => |bin| {
                // Validate bin.target: no path traversal, no slashes (#45)
                if (std.mem.indexOf(u8, bin.target, "..") != null or
                    std.mem.indexOf(u8, bin.target, "/") != null)
                {
                    stderr.print("nb: skipping unsafe binary target: {s}\n", .{bin.target}) catch {};
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
                    const cp_result = std.process.Child.run(.{
                        .allocator = alloc,
                        .argv = &.{ "cp", extract_src, caskroom_bin },
                    }) catch {
                        stderr.print("nb: failed to copy binary {s}\n", .{bin.source}) catch {};
                        continue;
                    };
                    alloc.free(cp_result.stdout);
                    alloc.free(cp_result.stderr);

                    // Make executable
                    const chmod_result = std.process.Child.run(.{
                        .allocator = alloc,
                        .argv = &.{ "chmod", "+x", caskroom_bin },
                    }) catch {
                        stderr.print("nb: failed to chmod binary {s}\n", .{bin.source}) catch {};
                        continue;
                    };
                    alloc.free(chmod_result.stdout);
                    alloc.free(chmod_result.stderr);

                    source = std.fmt.bufPrint(&resolved_buf, "{s}", .{caskroom_bin}) catch continue;
                }

                // Security: validate resolved source path to prevent symlink escape
                // Reject paths containing ".." components
                if (std.mem.indexOf(u8, source, "..") != null) {
                    stderr.print("nb: refusing to symlink binary with path traversal: {s}\n", .{bin.source}) catch {};
                    continue;
                }
                // Source must start with /Applications, the Caskroom, or be within extract dir
                const is_app_path = std.mem.startsWith(u8, source, "/Applications");
                const is_caskroom_path = std.mem.startsWith(u8, source, paths.CASKROOM_DIR);
                const is_extract_path = std.mem.startsWith(u8, source, source_dir);
                if (!is_app_path and !is_caskroom_path and !is_extract_path) {
                    stderr.print("nb: refusing to symlink binary outside allowed directories: {s}\n", .{bin.source}) catch {};
                    continue;
                }

                var link_buf: [512]u8 = undefined;
                const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, bin.target }) catch continue;

                std.fs.deleteFileAbsolute(link_path) catch {};
                std.fs.symLinkAbsolute(source, link_path, .{}) catch |err| {
                    stderr.print("nb: symlink failed for {s}: {}\n", .{ bin.target, err }) catch {};
                };
            },
            .pkg => |pkg_name| {
                // Validate pkg name: no path traversal, no absolute paths (#Task8)
                if (std.mem.indexOf(u8, pkg_name, "..") != null or
                    (pkg_name.len > 0 and pkg_name[0] == '/'))
                {
                    stderr.print("nb: skipping unsafe pkg artifact: {s}\n", .{pkg_name}) catch {};
                    continue;
                }
                var pkg_buf: [1024]u8 = undefined;
                const pkg_path = if (format == .pkg)
                    dl_path // standalone .pkg download
                else
                    std.fmt.bufPrint(&pkg_buf, "{s}/{s}", .{ source_dir, pkg_name }) catch continue;

                // Remove Gatekeeper quarantine from the .pkg before installing
                if (comptime builtin.os.tag == .macos) {
                    _ = std.process.Child.run(.{
                        .allocator = alloc,
                        .argv = &.{ "xattr", "-dr", "com.apple.quarantine", pkg_path },
                    }) catch {};
                }

                const result = std.process.Child.run(.{
                    .allocator = alloc,
                    .argv = &.{ "sudo", "installer", "-pkg", pkg_path, "-target", "/" },
                }) catch {
                    stderr.print("nb: pkg install failed for {s}\n", .{pkg_name}) catch {};
                    continue;
                };
                alloc.free(result.stdout);
                alloc.free(result.stderr);
                if (switch (result.term) { .Exited => |c| c != 0, else => true }) {
                    stderr.print("nb: installer failed for {s}\n", .{pkg_name}) catch {};
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
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // 1. Delete apps from /Applications/
    for (apps) |app| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "/Applications/{s}", .{app}) catch continue;
        std.fs.deleteTreeAbsolute(path) catch |err| {
            stderr.print("nb: could not remove {s}: {}\n", .{ app, err }) catch {};
        };
    }

    // 2. Delete binary symlinks from prefix/bin/
    for (binaries) |bin| {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/bin/{s}", .{ PREFIX, bin }) catch continue;
        std.fs.deleteFileAbsolute(path) catch {};
    }

    // 3. Delete Caskroom entry
    var caskroom_buf: [512]u8 = undefined;
    const ver_dir = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{ PREFIX, token, version }) catch return;
    std.fs.deleteTreeAbsolute(ver_dir) catch {};

    // Try to remove parent dir if empty
    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Caskroom/{s}", .{ PREFIX, token }) catch return;
    std.fs.deleteDirAbsolute(parent) catch {};
}

fn downloadArtifact(alloc: std.mem.Allocator, url: []const u8, dest: []const u8, cask: Cask) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Native HTTP download (no curl dependency)
    fetch.download(alloc, url, dest) catch return error.DownloadFailed;

    // Verify SHA256 if available
    if (cask.sha256.len == 0 or std.mem.eql(u8, cask.sha256, "no_check")) {
        stderr.print("nb: warning: skipping SHA256 verification for {s} (no checksum available)\n", .{cask.token}) catch {};
        return;
    }

    verifySha256(alloc, dest, cask.sha256) catch |err| {
        stderr.print("nb: error: SHA256 verification failed for {s}\n", .{cask.token}) catch {};
        // Clean up the bad download
        std.fs.deleteFileAbsolute(dest) catch {};
        return err;
    };
}

fn verifySha256(_: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    // In-process SHA256 using std.crypto (no external shasum dependency)
    var file = std.fs.openFileAbsolute(path, .{}) catch return error.VerifyFailed;
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const bytes_read = file.read(&buf) catch return error.VerifyFailed;
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
    }

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
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "hdiutil", "attach", "-nobrowse", "-noautoopen", "-plist", dmg_path },
        .max_output_bytes = 64 * 1024,
    }) catch return error.MountFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) { .Exited => |c| c != 0, else => true }) return error.MountFailed;

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
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "hdiutil", "detach", mount_point, "-quiet" },
        .max_output_bytes = 1024,
    }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

fn extractZip(alloc: std.mem.Allocator, zip_path: []const u8, dest: []const u8) !void {
    // Pre-list ZIP contents and check for path traversal
    const list_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "unzip", "-l", zip_path },
        .max_output_bytes = 256 * 1024,
    }) catch return error.ExtractFailed;
    defer alloc.free(list_result.stdout);
    defer alloc.free(list_result.stderr);

    // Scan listed paths for traversal sequences ("../" or "/..")
    var lines = std.mem.splitScalar(u8, list_result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, std.mem.trimLeft(u8, line, " "), " \r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "../") != null or
            std.mem.indexOf(u8, trimmed, "/..") != null)
        {
            return error.UnsafePath;
        }
    }

    // Now extract
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "unzip", "-o", "-q", zip_path, "-d", dest },
        .max_output_bytes = 4096,
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (switch (result.term) { .Exited => |c| c != 0, else => true }) return error.ExtractFailed;
}

fn extractTarGz(alloc: std.mem.Allocator, tar_path: []const u8, dest: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "-xzf", tar_path, "--no-same-permissions", "-C", dest },
        .max_output_bytes = 4096,
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (switch (result.term) { .Exited => |c| c != 0, else => true }) return error.ExtractFailed;
}
