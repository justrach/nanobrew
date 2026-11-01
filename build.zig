const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const checks = b.option(bool, "checks", "Run repository maintenance checks") orelse false;
    const windows_registry_opts = b.addOptions();
    windows_registry_opts.addOption([]const u8, "json", @embedFile("registry/windows.json"));

    // ── nanobrew library module ──
    const nb_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Main executable ──
    const is_windows = target.result.os.tag == .windows;
    const main_mod = b.createModule(.{
        .root_source_file = b.path(if (is_windows) "src/windows_main.zig" else "src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Linux: src/main.zig and the extract/tar paths reach extern "c"
        // symbols (read, symlink, fchmod, getenv, clock_gettime), so a
        // native Linux `zig build` needs libc linked explicitly — same as
        // the test and linux cross-compile modules below. macOS always
        // links libSystem, so null keeps the default there. Windows uses
        // the lightweight bridge entry point and does not need libc.
        .link_libc = if (target.result.os.tag == .linux or target.result.os.tag == .windows) true else null,
        .imports = if (is_windows) &.{} else &.{
            .{ .name = "nanobrew", .module = nb_mod },
        },
    });
    if (is_windows) main_mod.addOptions("windows_registry", windows_registry_opts);
    const exe = b.addExecutable(.{
        .name = "nb",
        .root_module = main_mod,
    });
    if (target.result.os.tag == .macos) {
        exe.headerpad_size = 0x1000;
    }
    b.installArtifact(exe);

    // ── Run step ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run nanobrew");
    run_step.dependOn(&run_cmd.step);

    // ── Tests (all-in-one) ──
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // Linux: extern "c" symbols (symlink, fchmod, getenv, ...) reached via
        // the extract/tar paths need an explicit libc link; macOS always links
        // libSystem so null keeps the default there.
        .link_libc = if (target.result.os.tag == .linux) true else null,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    // The Windows bridge's cache logic is plain std code, so its tests run on any host.
    const windows_test_mod = b.createModule(.{
        .root_source_file = b.path("src/windows_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    windows_test_mod.addOptions("windows_registry", windows_registry_opts);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = windows_test_mod })).step);

    // ── Repository maintenance checks ──
    // Zig 0.17 removed in-process custom build steps. Keep the public step
    // while the checks are moved to a small run artifact in a follow-up.
    const repo_checks_step = b.step("repo-checks", "Validate repository metadata and maintenance invariants");
    if (checks) test_step.dependOn(repo_checks_step);

    // ── Per-module test steps (atomic — one crash doesn't kill the rest) ──
    const test_modules = .{
        .{ "test-api", "src/api/client.zig", "Run API client tests" },
        .{ "test-tap", "src/api/tap.zig", "Run tap tests" },
        .{ "test-cask", "src/api/cask.zig", "Run cask tests" },
        .{ "test-deb-index", "src/deb/index.zig", "Run deb index tests" },
        .{ "test-deb-resolver", "src/deb/resolver.zig", "Run deb resolver tests" },
        .{ "test-deb-extract", "src/deb/extract.zig", "Run deb extract tests" },
        .{ "test-deb-distro", "src/deb/distro.zig", "Run deb distro tests" },
        .{ "test-deb-sources", "src/deb/sources.zig", "Run deb sources tests" },
        .{ "test-version", "src/version.zig", "Run version tests" },
        .{ "test-upstream-registry", "src/upstream/registry.zig", "Run upstream registry tests" },
        .{ "test-tar", "src/extract/tar.zig", "Run tar tests" },
        .{ "test-security", "src/security_test.zig", "Run security tests" },
        .{ "test-search", "src/api/search.zig", "Run search tests" },
        .{ "test-upstream-github", "src/upstream_github_test.zig", "Run GitHub upstream resolver tests" },
        .{ "test-macho", "src/macho/relocate.zig", "Run Mach-O relocate tests" },
    };
    inline for (test_modules) |entry| {
        const opts = b.addOptions();
        opts.addOption([]const u8, "step_name", entry[0]);

        const mod = b.createModule(.{
            .root_source_file = b.path("src/test_module.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = if (target.result.os.tag == .linux) true else null,
        });
        mod.addOptions("module_test_options", opts);

        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        const s = b.step(entry[0], entry[2]);
        s.dependOn(&run_t.step);
    }

    // ── Windows bridge convenience target ──
    const windows_x86 = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    const windows_mod = b.createModule(.{
        .root_source_file = b.path("src/windows_main.zig"),
        .target = windows_x86,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    windows_mod.addOptions("windows_registry", windows_registry_opts);
    const windows_exe = b.addExecutable(.{
        .name = "nb",
        .root_module = windows_mod,
    });
    windows_exe.root_module.strip = true;
    const windows_step = b.step("windows", "Build Windows package-manager bridge");
    windows_step.dependOn(&b.addInstallArtifact(windows_exe, .{}).step);

    // ── Linux cross-compilation convenience targets ──
    const linux_x86 = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const linux_arm = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });

    const linux_nb_x86 = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = linux_x86,
        .optimize = .ReleaseFast,
    });
    const linux_exe_x86 = b.addExecutable(.{
        .name = "nb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = linux_x86,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "nanobrew", .module = linux_nb_x86 },
            },
        }),
    });
    linux_exe_x86.root_module.strip = true;
    linux_exe_x86.root_module.link_libc = true;
    const linux_step_x86 = b.step("linux", "Cross-compile for x86_64-linux-musl");
    linux_step_x86.dependOn(&b.addInstallArtifact(linux_exe_x86, .{}).step);

    const linux_nb_arm = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = linux_arm,
        .optimize = .ReleaseFast,
    });
    const linux_exe_arm = b.addExecutable(.{
        .name = "nb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = linux_arm,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "nanobrew", .module = linux_nb_arm },
            },
        }),
    });
    linux_exe_arm.root_module.strip = true;
    linux_exe_arm.root_module.link_libc = true;
    const linux_step_arm = b.step("linux-arm", "Cross-compile for aarch64-linux-musl");
    linux_step_arm.dependOn(&b.addInstallArtifact(linux_exe_arm, .{}).step);
}

const RepoChecksStep = struct {
    step: std.Build.Step,
    root_path: []const u8,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *RepoChecksStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const alloc = b.allocator;
        const root = if (std.mem.eql(u8, self.root_path, "")) "." else self.root_path;

        try requireFile(step, root, "src/test_module.zig");
        try requireFile(step, root, "src/build/source.zig");
        try requireFile(step, root, "src/build/postinstall.zig");

        const snapshot_path = try std.fs.path.join(alloc, &.{ root, "codedb.snapshot" });
        defer alloc.free(snapshot_path);
        const snapshot = std.Io.Dir.cwd().readFileAlloc(io, snapshot_path, alloc, .limited(16 * 1024 * 1024)) catch |err| {
            return step.fail("codedb snapshot is missing or unreadable: {t}", .{err});
        };
        defer alloc.free(snapshot);

        try requireSnapshotEntry(step, snapshot, "src/build/source.zig");
        try requireSnapshotEntry(step, snapshot, "src/build/postinstall.zig");
        try requireSnapshotEntry(step, snapshot, "src/test_module.zig");
        try rejectSnapshotPathPrefix(step, snapshot, "worker/.wrangler");

        try rejectProcessRunWithGlobalIo(step, root, "src/build/postinstall.zig");
        try rejectProcessRunWithGlobalIo(step, root, "src/services/launchd.zig");
        try rejectProcessRunWithGlobalIo(step, root, "src/services/systemd.zig");
        try rejectProcessRunWithGlobalIo(step, root, "src/elf/relocate.zig");
        try rejectProcessRunWithGlobalIo(step, root, "src/cellar/cellar.zig");
        try rejectProcessRunWithGlobalIo(step, root, "src/store/store.zig");
    }
};

fn requireFile(step: *std.Build.Step, root: []const u8, rel_path: []const u8) !void {
    const b = step.owner;
    const full_path = try std.fs.path.join(b.allocator, &.{ root, rel_path });
    defer b.allocator.free(full_path);
    std.Io.Dir.cwd().access(b.graph.io, full_path, .{}) catch |err| {
        return step.fail("required repository file '{s}' is missing or inaccessible: {t}", .{ rel_path, err });
    };
}

fn requireSnapshotEntry(step: *std.Build.Step, snapshot: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, snapshot, needle) == null) {
        return step.fail("codedb snapshot is stale: missing '{s}'", .{needle});
    }
}

fn rejectSnapshotPathPrefix(step: *std.Build.Step, snapshot: []const u8, prefix: []const u8) !void {
    const b = step.owner;
    const needle = try std.fmt.allocPrint(b.allocator, "\"path\":\"{s}", .{prefix});
    defer b.allocator.free(needle);

    if (std.mem.indexOf(u8, snapshot, needle) != null) {
        return step.fail("codedb snapshot contains ignored/generated path prefix '{s}'", .{prefix});
    }
}

fn rejectProcessRunWithGlobalIo(step: *std.Build.Step, root: []const u8, rel_path: []const u8) !void {
    const b = step.owner;
    const full_path = try std.fs.path.join(b.allocator, &.{ root, rel_path });
    defer b.allocator.free(full_path);
    const source = std.Io.Dir.cwd().readFileAlloc(b.graph.io, full_path, b.allocator, .limited(2 * 1024 * 1024)) catch |err| {
        return step.fail("could not read '{s}' while checking process IO usage: {t}", .{ rel_path, err });
    };
    defer b.allocator.free(source);

    var search_from: usize = 0;
    var global_io_alias: ?[]const u8 = null;
    while (std.mem.indexOfPos(u8, source, search_from, "std.process.run")) |run_pos| {
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..run_pos], '\n')) |idx| idx + 1 else 0;
        const line_end = if (std.mem.indexOfScalarPos(u8, source, run_pos, '\n')) |idx| idx else source.len;
        const line = source[line_start..line_end];

        if (std.mem.indexOf(u8, line, "global_single_threaded.io()") != null) {
            return step.fail("'{s}' passes global_single_threaded IO into std.process.run", .{rel_path});
        }

        if (global_io_alias == null) {
            const prefix = source[0..run_pos];
            if (std.mem.indexOf(u8, prefix, "const _io = std.Io.Threaded.global_single_threaded.io()") != null) {
                global_io_alias = "_io";
            }
        }
        if (global_io_alias) |alias| {
            const alias_start = std.mem.indexOf(u8, line, alias) orelse {
                search_from = run_pos + "std.process.run".len;
                continue;
            };
            const alias_end = alias_start + alias.len;
            const before_ok = alias_start == 0 or !std.ascii.isAlphanumeric(line[alias_start - 1]) and line[alias_start - 1] != '_';
            const after_ok = alias_end == line.len or !std.ascii.isAlphanumeric(line[alias_end]) and line[alias_end] != '_';
            if (before_ok and after_ok) {
                return step.fail("'{s}' passes global_single_threaded IO into std.process.run", .{rel_path});
            }
        }
        search_from = run_pos + "std.process.run".len;
    }
}
