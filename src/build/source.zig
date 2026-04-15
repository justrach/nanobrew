// nanobrew — Source build pipeline
//
// Builds formulae from source when no pre-built bottle is available.
// Downloads source tarball, verifies SHA256, detects build system, compiles.

const std = @import("std");
const Formula = @import("../api/formula.zig").Formula;
const fetch = @import("../net/fetch.zig");

const CACHE_TMP = @import("../platform/paths.zig").TMP_DIR;

fn archiveSuffixFromUrl(url: []const u8) []const u8 {
    const path = blk: {
        if (std.mem.indexOfScalar(u8, url, '?')) |q| break :blk url[0..q];
        break :blk url;
    };
    const suffixes: []const []const u8 = &.{
        ".tar.xz", ".tar.bz2", ".tar.gz", ".txz", ".tbz2", ".tgz", ".zip",
    };
    for (suffixes) |s| {
        if (path.len >= s.len and std.mem.endsWith(u8, path, s)) return s;
    }
    return ".tar.gz";
}

const BuildSystem = enum {
    cmake,
    autotools,
    meson,
    make,
    unknown,
};

fn printOut(lib_io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.stdout().writeStreamingAll(lib_io, msg) catch {};
}

fn printErr(lib_io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.Io.File.stderr().writeStreamingAll(lib_io, msg) catch {};
}

pub fn buildFromSource(alloc: std.mem.Allocator, formula: Formula) !void {
    const lib_io = std.Io.Threaded.global_single_threaded.io();

    if (formula.source_url.len == 0) return error.NoSourceUrl;

    // 1. Download source archive (extension follows URL — .tar.xz, .zip, etc.; #112)
    var tarball_buf: [512]u8 = undefined;
    const arc_suffix = archiveSuffixFromUrl(formula.source_url);
    const tarball_path = std.fmt.bufPrint(&tarball_buf, "{s}/{s}-{s}{s}", .{
        CACHE_TMP, formula.name, formula.version, arc_suffix,
    }) catch return error.PathTooLong;

    printOut(lib_io, "==> Downloading source for {s} {s}...\n", .{ formula.name, formula.version });
    printOut(lib_io, "    {s}\n", .{formula.source_url});

    std.Io.Dir.createDirAbsolute(lib_io, CACHE_TMP, .default_dir) catch {};

    fetch.download(alloc, formula.source_url, tarball_path) catch return error.DownloadFailed;

    // 2. Verify SHA256
    if (formula.source_sha256.len > 0) {
        printOut(lib_io, "==> Verifying SHA256...\n", .{});
        var file = std.Io.Dir.openFileAbsolute(lib_io, tarball_path, .{}) catch return error.VerifyFailed;

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [65536]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = file.readPositional(lib_io, &.{buf[0..]}, offset) catch {
                file.close(lib_io);
                return error.VerifyFailed;
            };
            if (n == 0) break;
            hasher.update(buf[0..n]);
            offset += @intCast(n);
        }
        file.close(lib_io);

        const digest = hasher.finalResult();
        const charset = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, idx| {
            hex[idx * 2] = charset[byte >> 4];
            hex[idx * 2 + 1] = charset[byte & 0x0f];
        }

        if (formula.source_sha256.len != 64) return error.VerifyFailed;
        if (!std.mem.eql(u8, &hex, formula.source_sha256)) {
            printErr(lib_io, "nb: SHA256 mismatch for {s}\n", .{formula.name});
            printErr(lib_io, "    expected: {s}\n    got:      {s}\n", .{ formula.source_sha256, &hex });
            return error.Sha256Mismatch;
        }
    }

    // 3. Extract
    var build_dir_buf: [512]u8 = undefined;
    const build_dir = std.fmt.bufPrint(&build_dir_buf, "{s}/{s}-{s}-build", .{
        CACHE_TMP, formula.name, formula.version,
    }) catch return error.PathTooLong;

    printOut(lib_io, "==> Extracting source...\n", .{});
    // Clean previous build dir
    std.Io.Dir.cwd().deleteTree(lib_io, build_dir) catch {};
    std.Io.Dir.createDirAbsolute(lib_io, build_dir, .default_dir) catch {};

    {
        const argv: []const []const u8 = if (std.mem.endsWith(u8, tarball_path, ".zip"))
            &.{ "unzip", "-q", tarball_path, "-d", build_dir }
        else
            &.{ "tar", "xf", tarball_path, "-C", build_dir };
        const run = std.process.run(alloc, lib_io, .{
            .argv = argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch return error.ExtractFailed;
        defer alloc.free(run.stdout);
        defer alloc.free(run.stderr);
        if (switch (run.term) { .exited => |c| c != 0, else => true }) return error.ExtractFailed;
    }

    // 4. Find source root (tarballs often have one top-level directory)
    const src_root = findSourceRoot(alloc, lib_io, build_dir) catch build_dir;
    defer if (!std.mem.eql(u8, src_root, build_dir)) alloc.free(src_root);

    // 5. Detect build system
    const build_sys = detectBuildSystem(lib_io, src_root);
    printOut(lib_io, "==> Building {s} (detected: {s})...\n", .{ formula.name, @tagName(build_sys) });

    // 6. Build with prefix set to keg path
    var keg_buf: [512]u8 = undefined;
    var ver_buf: [128]u8 = undefined;
    const eff_ver = formula.effectiveVersion(&ver_buf);
    const keg_path = std.fmt.bufPrint(&keg_buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}", .{
        formula.name, eff_ver,
    }) catch return error.PathTooLong;

    // Ensure keg dir exists
    std.Io.Dir.createDirAbsolute(lib_io, "/opt/nanobrew/prefix/Cellar", .default_dir) catch {};
    var keg_parent_buf: [512]u8 = undefined;
    const keg_parent = std.fmt.bufPrint(&keg_parent_buf, "/opt/nanobrew/prefix/Cellar/{s}", .{formula.name}) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(lib_io, keg_parent, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(lib_io, keg_path, .default_dir) catch {};

    // Get CPU count for -j flag
    var ncpu_buf: [8]u8 = undefined;
    const ncpu_str = std.fmt.bufPrint(&ncpu_buf, "{d}", .{std.Thread.getCpuCount() catch 4}) catch "4";

    switch (build_sys) {
        .cmake => {
            try runBuildCmd(alloc, lib_io, src_root, &.{ "cmake", "-B", "build", std.fmt.allocPrint(alloc, "-DCMAKE_INSTALL_PREFIX={s}", .{keg_path}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "cmake", "--build", "build", "-j", ncpu_str });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "cmake", "--install", "build" });
        },
        .autotools => {
            try runBuildCmd(alloc, lib_io, src_root, &.{ "./configure", std.fmt.allocPrint(alloc, "--prefix={s}", .{keg_path}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "make", std.fmt.allocPrint(alloc, "-j{s}", .{ncpu_str}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "make", "install" });
        },
        .meson => {
            try runBuildCmd(alloc, lib_io, src_root, &.{ "meson", "setup", "build", std.fmt.allocPrint(alloc, "--prefix={s}", .{keg_path}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "meson", "compile", "-C", "build" });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "meson", "install", "-C", "build" });
        },
        .make => {
            try runBuildCmd(alloc, lib_io, src_root, &.{ "make", std.fmt.allocPrint(alloc, "PREFIX={s}", .{keg_path}) catch return error.OutOfMemory, std.fmt.allocPrint(alloc, "-j{s}", .{ncpu_str}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "make", std.fmt.allocPrint(alloc, "PREFIX={s}", .{keg_path}) catch return error.OutOfMemory, "install" });
        },
        .unknown => {
            // No build system — assume pre-built package (common in tap formulas).
            // Copy entire contents into keg (equivalent to Homebrew's `prefix.install Dir["*"]`).
            var found_anything = false;

            // First, try copying bin/ subdirectory executables directly
            var src_bin_dir_buf: [512]u8 = undefined;
            const src_bin_dir = std.fmt.bufPrint(&src_bin_dir_buf, "{s}/bin", .{src_root}) catch "";
            if (src_bin_dir.len > 0) {
                if (std.Io.Dir.openDirAbsolute(lib_io, src_bin_dir, .{})) |d| {
                    var bd = d;
                    bd.close(lib_io);
                    found_anything = true;
                } else |_| {}
            }

            // Copy all top-level entries from source root into keg path
            if (std.Io.Dir.openDirAbsolute(lib_io, src_root, .{ .iterate = true })) |d| {
                var dir = d;
                var iter = dir.iterate();
                while (iter.next(lib_io) catch null) |entry| {
                    var src_path_buf: [1024]u8 = undefined;
                    const src_path = std.fmt.bufPrint(&src_path_buf, "{s}/{s}", .{ src_root, entry.name }) catch continue;
                    var dst_path_buf: [1024]u8 = undefined;
                    const dst_path = std.fmt.bufPrint(&dst_path_buf, "{s}/{s}", .{ keg_path, entry.name }) catch continue;

                    if (entry.kind == .directory) {
                        const cp_result = std.process.run(alloc, lib_io, .{
                            .argv = &.{ "cp", "-R", src_path, dst_path },
                            .stdout_limit = .limited(4096),
                            .stderr_limit = .limited(4096),
                        }) catch continue;
                        defer alloc.free(cp_result.stdout);
                        defer alloc.free(cp_result.stderr);
                        if (switch (cp_result.term) { .exited => |c| c == 0, else => false }) found_anything = true;
                    } else if (entry.kind == .file) {
                        std.Io.Dir.copyFileAbsolute(src_path, dst_path, lib_io, .{}) catch continue;
                        found_anything = true;
                    }
                }
                dir.close(lib_io);
            } else |_| {
                return error.UnknownBuildSystem;
            }

            if (!found_anything) {
                printErr(lib_io, "nb: {s}: no recognized build system or installable files found\n", .{formula.name});
                return error.UnknownBuildSystem;
            }
        },
    }

    printOut(lib_io, "==> Built {s} {s} from source\n", .{ formula.name, formula.version });

    // 7. Cleanup build dir
    std.Io.Dir.cwd().deleteTree(lib_io, build_dir) catch {};
}

fn findSourceRoot(alloc: std.mem.Allocator, lib_io: std.Io, dir_path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(lib_io, dir_path, .{ .iterate = true });

    var first_entry: ?[]const u8 = null;
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(lib_io) catch null) |entry| {
        if (entry.kind == .directory) {
            count += 1;
            if (first_entry == null) {
                first_entry = try alloc.dupe(u8, entry.name);
            }
        }
    }
    dir.close(lib_io);

    if (count == 1) {
        if (first_entry) |name| {
            return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
        }
    }
    if (first_entry) |name| alloc.free(name);
    return error.NoSingleRoot;
}

fn detectBuildSystem(lib_io: std.Io, dir_path: []const u8) BuildSystem {
    if (std.Io.Dir.openDirAbsolute(lib_io, dir_path, .{ .iterate = true })) |d| {
        var dir = d;
        var has_makefile = false;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.name, "CMakeLists.txt")) {
                dir.close(lib_io);
                return .cmake;
            }
            if (std.mem.eql(u8, entry.name, "configure")) {
                dir.close(lib_io);
                return .autotools;
            }
            if (std.mem.eql(u8, entry.name, "meson.build")) {
                dir.close(lib_io);
                return .meson;
            }
            if (std.mem.eql(u8, entry.name, "Makefile") or std.mem.eql(u8, entry.name, "makefile"))
                has_makefile = true;
        }
        dir.close(lib_io);
        if (has_makefile) return .make;
    } else |_| {}
    return .unknown;
}

fn runBuildCmd(alloc: std.mem.Allocator, lib_io: std.Io, cwd: []const u8, argv: []const []const u8) !void {
    const run = std.process.run(alloc, lib_io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.BuildFailed;
    defer alloc.free(run.stdout);
    defer alloc.free(run.stderr);
    if (switch (run.term) { .exited => |c| c != 0, else => true }) {
        printErr(lib_io, "nb: build command failed:", .{});
        for (argv) |a| printErr(lib_io, " {s}", .{a});
        printErr(lib_io, "\n", .{});
        return error.BuildFailed;
    }
}
