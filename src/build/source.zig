// nanobrew — Source build pipeline
//
// Builds formulae from source when no pre-built bottle is available.
// Downloads source tarball, verifies SHA256, detects build system, compiles.

const std = @import("std");
const Formula = @import("../api/formula.zig").Formula;

const CACHE_TMP = "/opt/nanobrew/cache/tmp";

const BuildSystem = enum {
    cmake,
    autotools,
    meson,
    make,
    unknown,
};

pub fn buildFromSource(alloc: std.mem.Allocator, formula: Formula) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (formula.source_url.len == 0) return error.NoSourceUrl;

    // 1. Download source tarball
    var tarball_buf: [512]u8 = undefined;
    const tarball_path = std.fmt.bufPrint(&tarball_buf, "{s}/{s}-{s}.tar.gz", .{
        CACHE_TMP, formula.name, formula.version,
    }) catch return error.PathTooLong;

    stdout.print("==> Downloading source for {s} {s}...\n", .{ formula.name, formula.version }) catch {};
    stdout.print("    {s}\n", .{formula.source_url}) catch {};

    std.fs.makeDirAbsolute(CACHE_TMP) catch {};

    {
        const dl = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "curl", "-sL", "-o", tarball_path, formula.source_url },
        }) catch return error.CurlFailed;
        alloc.free(dl.stdout);
        alloc.free(dl.stderr);
        if (dl.term.Exited != 0) return error.DownloadFailed;
    }

    // 2. Verify SHA256
    if (formula.source_sha256.len > 0) {
        stdout.print("==> Verifying SHA256...\n", .{}) catch {};
        const verify = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "shasum", "-a", "256", tarball_path },
        }) catch return error.VerifyFailed;
        defer alloc.free(verify.stderr);
        defer alloc.free(verify.stdout);

        if (verify.term.Exited != 0) return error.VerifyFailed;
        // shasum output: "<hash>  <path>\n"
        if (verify.stdout.len < 64) return error.VerifyFailed;
        const actual_hash = verify.stdout[0..64];
        if (!std.mem.eql(u8, actual_hash, formula.source_sha256)) {
            stderr.print("nb: SHA256 mismatch for {s}\n    expected: {s}\n    got:      {s}\n", .{
                formula.name, formula.source_sha256, actual_hash,
            }) catch {};
            return error.Sha256Mismatch;
        }
    }

    // 3. Extract
    var build_dir_buf: [512]u8 = undefined;
    const build_dir = std.fmt.bufPrint(&build_dir_buf, "{s}/{s}-{s}-build", .{
        CACHE_TMP, formula.name, formula.version,
    }) catch return error.PathTooLong;

    stdout.print("==> Extracting source...\n", .{}) catch {};
    // Clean previous build dir
    std.fs.deleteTreeAbsolute(build_dir) catch {};
    std.fs.makeDirAbsolute(build_dir) catch {};

    {
        const extract = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "tar", "xzf", tarball_path, "-C", build_dir },
        }) catch return error.ExtractFailed;
        alloc.free(extract.stdout);
        alloc.free(extract.stderr);
        if (extract.term.Exited != 0) return error.ExtractFailed;
    }

    // 4. Find source root (tarballs often have one top-level directory)
    const src_root = findSourceRoot(alloc, build_dir) catch build_dir;
    defer if (!std.mem.eql(u8, src_root, build_dir)) alloc.free(src_root);

    // 5. Detect build system
    const build_sys = detectBuildSystem(src_root);
    stdout.print("==> Building {s} (detected: {s})...\n", .{
        formula.name, @tagName(build_sys),
    }) catch {};

    // 6. Build with prefix set to keg path
    var keg_buf: [512]u8 = undefined;
    var ver_buf: [128]u8 = undefined;
    const eff_ver = formula.effectiveVersion(&ver_buf);
    const keg_path = std.fmt.bufPrint(&keg_buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}", .{
        formula.name, eff_ver,
    }) catch return error.PathTooLong;

    // Ensure keg dir exists
    std.fs.makeDirAbsolute("/opt/nanobrew/prefix/Cellar") catch {};
    var keg_parent_buf: [512]u8 = undefined;
    const keg_parent = std.fmt.bufPrint(&keg_parent_buf, "/opt/nanobrew/prefix/Cellar/{s}", .{formula.name}) catch return error.PathTooLong;
    std.fs.makeDirAbsolute(keg_parent) catch {};
    std.fs.makeDirAbsolute(keg_path) catch {};

    // Get CPU count for -j flag
    var ncpu_buf: [8]u8 = undefined;
    const ncpu_str = std.fmt.bufPrint(&ncpu_buf, "{d}", .{std.Thread.getCpuCount() catch 4}) catch "4";

    switch (build_sys) {
        .cmake => {
            try runBuildCmd(alloc, src_root, &.{ "cmake", "-B", "build", std.fmt.allocPrint(alloc, "-DCMAKE_INSTALL_PREFIX={s}", .{keg_path}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, src_root, &.{ "cmake", "--build", "build", "-j", ncpu_str });
            try runBuildCmd(alloc, src_root, &.{ "cmake", "--install", "build" });
        },
        .autotools => {
            try runBuildCmd(alloc, src_root, &.{ "./configure", std.fmt.allocPrint(alloc, "--prefix={s}", .{keg_path}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, src_root, &.{ "make", std.fmt.allocPrint(alloc, "-j{s}", .{ncpu_str}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, src_root, &.{ "make", "install" });
        },
        .meson => {
            try runBuildCmd(alloc, src_root, &.{ "meson", "setup", "build", std.fmt.allocPrint(alloc, "--prefix={s}", .{keg_path}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, src_root, &.{ "meson", "compile", "-C", "build" });
            try runBuildCmd(alloc, src_root, &.{ "meson", "install", "-C", "build" });
        },
        .make => {
            try runBuildCmd(alloc, src_root, &.{ "make", std.fmt.allocPrint(alloc, "PREFIX={s}", .{keg_path}) catch return error.OutOfMemory, std.fmt.allocPrint(alloc, "-j{s}", .{ncpu_str}) catch return error.OutOfMemory });
            try runBuildCmd(alloc, src_root, &.{ "make", std.fmt.allocPrint(alloc, "PREFIX={s}", .{keg_path}) catch return error.OutOfMemory, "install" });
        },
        .unknown => {
            stderr.print("nb: {s}: no recognized build system found\n", .{formula.name}) catch {};
            return error.UnknownBuildSystem;
        },
    }

    stdout.print("==> Built {s} {s} from source\n", .{ formula.name, formula.version }) catch {};

    // 7. Cleanup build dir
    std.fs.deleteTreeAbsolute(build_dir) catch {};
}

fn findSourceRoot(alloc: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var first_entry: ?[]const u8 = null;
    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            count += 1;
            if (first_entry == null) {
                first_entry = try alloc.dupe(u8, entry.name);
            }
        }
    }

    if (count == 1) {
        if (first_entry) |name| {
            return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, name });
        }
    }
    if (first_entry) |name| alloc.free(name);
    return error.NoSingleRoot;
}

fn detectBuildSystem(dir_path: []const u8) BuildSystem {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return .unknown;
    defer dir.close();

    var has_makefile = false;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, "CMakeLists.txt")) return .cmake;
        if (std.mem.eql(u8, entry.name, "configure")) return .autotools;
        if (std.mem.eql(u8, entry.name, "meson.build")) return .meson;
        if (std.mem.eql(u8, entry.name, "Makefile") or std.mem.eql(u8, entry.name, "makefile"))
            has_makefile = true;
    }
    if (has_makefile) return .make;
    return .unknown;
}

fn runBuildCmd(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const run = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
    }) catch return error.BuildFailed;
    alloc.free(run.stdout);
    alloc.free(run.stderr);
    if (run.term.Exited != 0) {
        stderr.print("nb: build command failed: ", .{}) catch {};
        for (argv) |a| stderr.print("{s} ", .{a}) catch {};
        stderr.print("\n", .{}) catch {};
        return error.BuildFailed;
    }
}
