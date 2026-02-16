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

    // 1. Download artifact
    const ext: []const u8 = switch (cask.downloadFormat()) {
        .dmg => ".dmg",
        .zip => ".zip",
        .pkg => ".pkg",
        .tar_gz => ".tar.gz",
        .unknown => ".dmg", // try dmg as default
    };
    var dl_buf: [512]u8 = undefined;
    const dl_path = std.fmt.bufPrint(&dl_buf, "{s}/{s}{s}", .{ CACHE_TMP, cask.token, ext }) catch return error.PathTooLong;

    try downloadArtifact(alloc, cask.url, dl_path, cask);

    // 2. Create Caskroom entry
    var caskroom_buf: [512]u8 = undefined;
    const caskroom_path = cask.caskroomPath(&caskroom_buf);
    std.fs.makeDirAbsolute("/opt/nanobrew/prefix/Caskroom") catch {};
    var token_dir_buf: [512]u8 = undefined;
    const token_dir = std.fmt.bufPrint(&token_dir_buf, "/opt/nanobrew/prefix/Caskroom/{s}", .{cask.token}) catch return error.PathTooLong;
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
            mount_point = try mountDmg(alloc, dl_path, &mount_point_buf);
        },
        .zip => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, cask.token }) catch return error.PathTooLong;
            std.fs.makeDirAbsolute(tmp_dir) catch {};
            try extractZip(alloc, dl_path, tmp_dir);
            temp_extract_dir = tmp_dir;
        },
        .tar_gz => {
            const tmp_dir = std.fmt.bufPrint(&temp_extract_buf, "{s}/{s}-extract", .{ CACHE_TMP, cask.token }) catch return error.PathTooLong;
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

    for (cask.artifacts) |art| {
        switch (art) {
            .app => |app_name| {
                var src_buf: [1024]u8 = undefined;
                const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ source_dir, app_name }) catch continue;
                var dst_buf: [512]u8 = undefined;
                const dst = std.fmt.bufPrint(&dst_buf, "/Applications/{s}", .{app_name}) catch continue;

                // Remove existing app first
                std.fs.deleteTreeAbsolute(dst) catch {};

                // cp -R source to /Applications/
                const cp_result = std.process.Child.run(.{
                    .allocator = alloc,
                    .argv = &.{ "cp", "-R", src, dst },
                }) catch {
                    stderr.print("nb: failed to copy {s} to /Applications/\n", .{app_name}) catch {};
                    continue;
                };
                alloc.free(cp_result.stdout);
                alloc.free(cp_result.stderr);
                if (cp_result.term.Exited != 0) {
                    stderr.print("nb: cp failed for {s}\n", .{app_name}) catch {};
                }
            },
            .binary => |bin| {
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
                    }) catch continue;
                    alloc.free(chmod_result.stdout);
                    alloc.free(chmod_result.stderr);

                    source = std.fmt.bufPrint(&resolved_buf, "{s}", .{caskroom_bin}) catch continue;
                }

                var link_buf: [512]u8 = undefined;
                const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, bin.target }) catch continue;

                std.fs.deleteFileAbsolute(link_path) catch {};
                std.fs.symLinkAbsolute(source, link_path, .{}) catch |err| {
                    stderr.print("nb: symlink failed for {s}: {}\n", .{ bin.target, err }) catch {};
                };
            },
            .pkg => |pkg_name| {
                var pkg_buf: [1024]u8 = undefined;
                const pkg_path = if (format == .pkg)
                    dl_path // standalone .pkg download
                else
                    std.fmt.bufPrint(&pkg_buf, "{s}/{s}", .{ source_dir, pkg_name }) catch continue;

                const result = std.process.Child.run(.{
                    .allocator = alloc,
                    .argv = &.{ "sudo", "installer", "-pkg", pkg_path, "-target", "/" },
                }) catch {
                    stderr.print("nb: pkg install failed for {s}\n", .{pkg_name}) catch {};
                    continue;
                };
                alloc.free(result.stdout);
                alloc.free(result.stderr);
                if (result.term.Exited != 0) {
                    stderr.print("nb: installer failed for {s}\n", .{pkg_name}) catch {};
                }
            },
            .uninstall => {}, // only used during removal
        }
    }
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
    // Native HTTP download (no curl dependency)
    fetch.download(alloc, url, dest) catch return error.DownloadFailed;

    // Verify SHA256 if needed
    if (cask.shouldVerifySha()) {
        try verifySha256(alloc, dest, cask.sha256);
    }
}

fn verifySha256(alloc: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "shasum", "-a", "256", path },
    }) catch return error.VerifyFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) return error.VerifyFailed;

    // shasum output: "<hash>  <filename>\n"
    if (result.stdout.len < 64) return error.VerifyFailed;
    const actual = result.stdout[0..64];
    if (!std.mem.eql(u8, actual, expected)) return error.Sha256Mismatch;
}

fn mountDmg(alloc: std.mem.Allocator, dmg_path: []const u8, out_buf: []u8) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "hdiutil", "attach", "-nobrowse", "-noautoopen", "-plist", dmg_path },
        .max_output_bytes = 64 * 1024,
    }) catch return error.MountFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) return error.MountFailed;

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
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "unzip", "-o", "-q", zip_path, "-d", dest },
        .max_output_bytes = 4096,
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) return error.ExtractFailed;
}

fn extractTarGz(alloc: std.mem.Allocator, tar_path: []const u8, dest: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "xzf", tar_path, "-C", dest },
        .max_output_bytes = 4096,
    }) catch return error.ExtractFailed;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term.Exited != 0) return error.ExtractFailed;
}
