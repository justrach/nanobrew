// nanobrew — Source build pipeline
//
// Builds formulae from source when no pre-built bottle is available.
// Downloads source tarball, verifies SHA256, detects build system, compiles.

const std = @import("std");
const Formula = @import("../api/formula.zig").Formula;
const fetch = @import("../net/fetch.zig");
const telemetry = @import("../telemetry/client.zig");

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

/// Upstream basename of a download URL (query string stripped). Raw
/// `using: :nounzip` assets are staged under this name so formula install
/// globs like `Dir["omp-*"]` match (#361).
fn urlBasename(url: []const u8) []const u8 {
    const path = blk: {
        if (std.mem.indexOfScalar(u8, url, '?')) |q| break :blk url[0..q];
        break :blk url;
    };
    const base = std.fs.path.basename(path);
    return if (base.len > 0) base else "payload";
}

/// Minimal shell-style glob: `*` matches any run, `?` any single byte.
/// Enough for the `Dir["name-*"]` patterns tap formulas use.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            mark = n;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const BuildSystem = enum {
    cmake,
    autotools,
    openssl,
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

pub fn buildFromSource(alloc: std.mem.Allocator, io: std.Io, formula: Formula) !void {
    const lib_io = io;
    if (formula.source_url.len == 0) return error.NoSourceUrl;

    // 1. Download source archive (extension follows URL — .tar.xz, .zip, etc.; #112)
    // `using: :nounzip` downloads are raw files, so the cache entry keeps the
    // upstream basename instead of a fabricated archive suffix (#361).
    var tarball_buf: [512]u8 = undefined;
    const tarball_path = if (formula.source_nounzip)
        std.fmt.bufPrint(&tarball_buf, "{s}/{s}-{s}-{s}", .{
            CACHE_TMP, formula.name, formula.version, urlBasename(formula.source_url),
        }) catch return error.PathTooLong
    else
        std.fmt.bufPrint(&tarball_buf, "{s}/{s}-{s}{s}", .{
            CACHE_TMP, formula.name, formula.version, archiveSuffixFromUrl(formula.source_url),
        }) catch return error.PathTooLong;

    std.Io.Dir.createDirAbsolute(lib_io, CACHE_TMP, .default_dir) catch {};

    const use_cached_archive = formula.source_sha256.len > 0 and fileSha256Matches(lib_io, tarball_path, formula.source_sha256);
    if (use_cached_archive) {
        printOut(lib_io, "==> Using cached source for {s} {s}...\n", .{ formula.name, formula.version });
    } else {
        std.Io.Dir.deleteFileAbsolute(lib_io, tarball_path) catch {};
        printOut(lib_io, "==> Downloading source for {s} {s}...\n", .{ formula.name, formula.version });
        printOut(lib_io, "    {s}\n", .{formula.source_url});
        var telemetry_event = telemetry.DownloadEvent.start(.formula, formula.name);
        fetch.download(alloc, formula.source_url, tarball_path) catch {
            telemetry_event.fail();
            return error.DownloadFailed;
        };
        telemetry_event.succeed(telemetry.fileSize(tarball_path));
    }

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

    // Clean previous build dir
    std.Io.Dir.cwd().deleteTree(lib_io, build_dir) catch {};
    std.Io.Dir.createDirAbsolute(lib_io, build_dir, .default_dir) catch {};

    if (formula.source_nounzip) {
        // Raw asset: stage it under its upstream basename, no extraction (#361).
        printOut(lib_io, "==> Staging raw asset...\n", .{});
        var staged_buf: [1024]u8 = undefined;
        const staged_path = std.fmt.bufPrint(&staged_buf, "{s}/{s}", .{
            build_dir, urlBasename(formula.source_url),
        }) catch return error.PathTooLong;
        std.Io.Dir.copyFileAbsolute(tarball_path, staged_path, lib_io, .{}) catch |err| {
            printErr(lib_io, "nb: staging raw asset failed: {}\n", .{err});
            return error.ExtractFailed;
        };
    } else {
        printOut(lib_io, "==> Extracting source...\n", .{});
        const argv: []const []const u8 = if (std.mem.endsWith(u8, tarball_path, ".zip"))
            &.{ "unzip", "-q", tarball_path, "-d", build_dir }
        else
            &.{ "tar", "xf", tarball_path, "-C", build_dir };
        runCommand(lib_io, .inherit, argv) catch |err| {
            printErr(lib_io, "nb: extract command failed: {}\n", .{err});
            return error.ExtractFailed;
        };
    }

    // 4. Find source root (tarballs often have one top-level directory)
    const src_root = findSourceRoot(alloc, lib_io, build_dir) catch build_dir;
    defer if (!std.mem.eql(u8, src_root, build_dir)) alloc.free(src_root);

    // 5. Detect build system
    const build_sys = detectBuildSystem(lib_io, src_root);
    if (build_sys == .autotools) {
        // Some source extraction paths lose executable mode bits. Repair only
        // the selected top-level autotools launcher, not the whole tree (#344).
        var configure_buf: [1024]u8 = undefined;
        const configure_path = std.fmt.bufPrint(&configure_buf, "{s}/configure", .{src_root}) catch return error.PathTooLong;
        runCommand(lib_io, .inherit, &.{ "chmod", "+x", configure_path }) catch return error.ConfigureNotExecutable;
    }
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
        .openssl => {
            const prefix_arg = try std.fmt.allocPrint(alloc, "--prefix={s}", .{keg_path});
            defer alloc.free(prefix_arg);
            const jobs_arg = try std.fmt.allocPrint(alloc, "-j{s}", .{ncpu_str});
            defer alloc.free(jobs_arg);
            const ssl_dir_arg = try std.fmt.allocPrint(alloc, "--openssldir={s}/etc/{s}", .{ @import("../platform/paths.zig").PREFIX, formula.name });
            defer alloc.free(ssl_dir_arg);
            try runBuildCmd(alloc, lib_io, src_root, &.{ "perl", "./Configure", prefix_arg, ssl_dir_arg });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "make", jobs_arg });
            try runBuildCmd(alloc, lib_io, src_root, &.{ "make", "install_sw", "install_ssldirs" });
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
            if (formula.install_binaries.len > 0 or formula.install_bin_renames.len > 0) {
                try installDeclaredBinaries(alloc, lib_io, src_root, keg_path, formula);
                printOut(lib_io, "==> Installed declared upstream binaries for {s}\n", .{formula.name});
                std.Io.Dir.cwd().deleteTree(lib_io, build_dir) catch {};
                return;
            }

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
                        if (switch (cp_result.term) {
                            .exited => |c| c == 0,
                            else => false,
                        }) found_anything = true;
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

fn fileSha256Matches(lib_io: std.Io, path: []const u8, expected: []const u8) bool {
    if (expected.len != 64) return false;
    var file = std.Io.Dir.openFileAbsolute(lib_io, path, .{}) catch return false;
    defer file.close(lib_io);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = file.readPositional(lib_io, &.{buf[0..]}, offset) catch return false;
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += @intCast(n);
    }

    const digest = hasher.finalResult();
    const charset = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, idx| {
        hex[idx * 2] = charset[byte >> 4];
        hex[idx * 2 + 1] = charset[byte & 0x0f];
    }
    return std.mem.eql(u8, &hex, expected);
}

fn findSourceRoot(alloc: std.mem.Allocator, lib_io: std.Io, dir_path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(lib_io, dir_path, .{ .iterate = true });

    var first_dir: ?[]const u8 = null;
    var total_entries: usize = 0;
    var dir_entries: usize = 0;
    var iter = dir.iterate();
    while (iter.next(lib_io) catch null) |entry| {
        total_entries += 1;
        if (entry.kind == .directory) {
            dir_entries += 1;
            if (first_dir == null) {
                first_dir = try alloc.dupe(u8, entry.name);
            }
        }
    }
    dir.close(lib_io);

    if (total_entries == 1 and dir_entries == 1) {
        if (first_dir) |name| {
            defer alloc.free(name);
            return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
        }
    }
    if (first_dir) |name| alloc.free(name);
    return error.NoSingleRoot;
}

fn detectBuildSystem(lib_io: std.Io, dir_path: []const u8) BuildSystem {
    // OpenSSL uses a Perl Configure script; it is not a prebuilt payload.
    var openssl_buf: [4096]u8 = undefined;
    const openssl_marker = std.fmt.bufPrint(&openssl_buf, "{s}/Configurations", .{dir_path}) catch return .unknown;
    if (std.Io.Dir.accessAbsolute(lib_io, openssl_marker, .{})) |_| {
        const configure = std.fmt.bufPrint(&openssl_buf, "{s}/Configure", .{dir_path}) catch return .unknown;
        if (std.Io.Dir.accessAbsolute(lib_io, configure, .{})) |_| return .openssl else |_| {}
    } else |_| {}

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
    _ = alloc;
    runCommand(lib_io, .{ .path = cwd }, argv) catch {
        printErr(lib_io, "nb: build command failed:", .{});
        for (argv) |a| printErr(lib_io, " {s}", .{a});
        printErr(lib_io, "\n", .{});
        return error.BuildFailed;
    };
}

fn installDeclaredBinaries(
    alloc: std.mem.Allocator,
    lib_io: std.Io,
    src_root: []const u8,
    keg_path: []const u8,
    formula: Formula,
) !void {
    _ = alloc;
    var bin_dir_buf: [512]u8 = undefined;
    const bin_dir = std.fmt.bufPrint(&bin_dir_buf, "{s}/bin", .{keg_path}) catch return error.PathTooLong;
    std.Io.Dir.createDirAbsolute(lib_io, bin_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    for (formula.install_binaries) |binary| {
        if (binary.len == 0 or binary[0] == '/' or std.mem.indexOf(u8, binary, "..") != null) {
            return error.InvalidBinaryArtifact;
        }

        var src_buf: [1024]u8 = undefined;
        const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ src_root, binary }) catch return error.PathTooLong;
        const target_name = std.fs.path.basename(binary);
        if (target_name.len == 0) return error.InvalidBinaryArtifact;

        var dst_buf: [1024]u8 = undefined;
        const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ bin_dir, target_name }) catch return error.PathTooLong;

        std.Io.Dir.copyFileAbsolute(src_path, dst_path, lib_io, .{}) catch return error.InstallBinaryFailed;
        runCommand(lib_io, .inherit, &.{ "chmod", "+x", dst_path }) catch return error.InstallBinaryFailed;
    }

    // `bin.install Dir["<glob>"].first => "<dest>"` (#361): install the first
    // staged file matching the glob under the destination name.
    for (formula.install_bin_renames) |rename| {
        if (rename.dest.len == 0 or rename.dest[0] == '/' or std.mem.indexOf(u8, rename.dest, "..") != null) {
            return error.InvalidBinaryArtifact;
        }
        if (rename.pattern.len == 0 or rename.pattern[0] == '/' or std.mem.indexOf(u8, rename.pattern, "..") != null) {
            return error.InvalidBinaryArtifact;
        }
        // Directory components in the pattern must be literal; only the
        // basename is globbed.
        const dir_part = std.fs.path.dirname(rename.pattern);
        const base_pattern = std.fs.path.basename(rename.pattern);
        if (dir_part) |d| {
            if (std.mem.indexOfScalar(u8, d, '*') != null or std.mem.indexOfScalar(u8, d, '?') != null) {
                return error.InvalidBinaryArtifact;
            }
        }

        var search_buf: [1024]u8 = undefined;
        const search_dir = if (dir_part) |d|
            std.fmt.bufPrint(&search_buf, "{s}/{s}", .{ src_root, d }) catch return error.PathTooLong
        else
            src_root;

        var matched = false;
        var dir = std.Io.Dir.openDirAbsolute(lib_io, search_dir, .{ .iterate = true }) catch
            return error.InstallBinaryFailed;
        var iter = dir.iterate();
        while (iter.next(lib_io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!globMatch(base_pattern, entry.name)) continue;

            var src_buf: [1024]u8 = undefined;
            const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ search_dir, entry.name }) catch {
                dir.close(lib_io);
                return error.PathTooLong;
            };
            var dst_buf: [1024]u8 = undefined;
            const dst_path = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ bin_dir, rename.dest }) catch {
                dir.close(lib_io);
                return error.PathTooLong;
            };
            std.Io.Dir.copyFileAbsolute(src_path, dst_path, lib_io, .{}) catch {
                dir.close(lib_io);
                return error.InstallBinaryFailed;
            };
            runCommand(lib_io, .inherit, &.{ "chmod", "+x", dst_path }) catch {
                dir.close(lib_io);
                return error.InstallBinaryFailed;
            };
            matched = true;
            break;
        }
        dir.close(lib_io);
        if (!matched) {
            printErr(lib_io, "nb: no staged file matches install glob '{s}'\n", .{rename.pattern});
            return error.InstallBinaryFailed;
        }
    }
}

const testing = std.testing;

test "globMatch - prefix wildcard matches raw asset name (#361)" {
    try testing.expect(globMatch("omp-*", "omp-darwin-arm64"));
    try testing.expect(!globMatch("omp-*", "other-darwin-arm64"));
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("a?c", "abc"));
    try testing.expect(!globMatch("a?c", "abbc"));
    try testing.expect(globMatch("pre-*-post", "pre-middle-post"));
    try testing.expect(!globMatch("pre-*-post", "pre-middle-past"));
}

test "urlBasename - strips query and keeps upstream file name (#361)" {
    try testing.expectEqualStrings(
        "omp-darwin-arm64",
        urlBasename("https://github.com/can1357/oh-my-pi/releases/download/v17.1.6/omp-darwin-arm64"),
    );
    try testing.expectEqualStrings("asset", urlBasename("https://example.com/asset?sig=abc"));
}

fn runCommand(lib_io: std.Io, cwd: std.process.Child.Cwd, argv: []const []const u8) !void {
    var child = try std.process.spawn(lib_io, .{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(lib_io);
    if (switch (term) {
        .exited => |code| code != 0,
        else => true,
    }) return error.CommandFailed;
}

test "OpenSSL Configure is recognized as source rather than a prebuilt payload (#375)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "Configurations", .default_dir);
    const file = try tmp.dir.createFile(io, "Configure", .{});
    file.close(io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    try std.testing.expectEqual(BuildSystem.openssl, detectBuildSystem(io, root_buf[0..n]));
}
