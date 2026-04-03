const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── nanobrew library module ──
    const nb_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Main executable ──
    const exe = b.addExecutable(.{
        .name = "nb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nanobrew", .module = nb_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // ── Run step ──
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run nanobrew");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──
    // Each subsystem is a separate binary. "zig build test" runs them sequentially
    // to avoid CPU spikes from parallel compilation. Run individually with
    // "zig build test-api", "zig build test-deb", etc.
    const test_suites = [_]struct { name: []const u8, src: []const u8, desc: []const u8 }{
        .{ .name = "test-platform", .src = "src/test_platform.zig", .desc = "Run platform layer tests" },
        .{ .name = "test-core", .src = "src/test_core.zig", .desc = "Run core module tests (version, deps, db, store, kernel)" },
        .{ .name = "test-api", .src = "src/test_api.zig", .desc = "Run API tests (client, formula, cask, tap)" },
        .{ .name = "test-security", .src = "src/test_security.zig", .desc = "Run security tests" },
        .{ .name = "test-deb", .src = "src/test_deb.zig", .desc = "Run .deb subsystem tests" },
    };

    const test_step = b.step("test", "Run all unit tests (sequentially)");

    var last_run: ?*std.Build.Step = null;
    for (test_suites) |suite| {
        const suite_mod = b.createModule(.{
            .root_source_file = b.path(suite.src),
            .target = target,
            .optimize = optimize,
        });
        const suite_tests = b.addTest(.{ .root_module = suite_mod });
        const run_suite = b.addRunArtifact(suite_tests);
        // Chain sequentially: each suite waits for the previous one
        if (last_run) |prev| run_suite.step.dependOn(prev);
        last_run = &run_suite.step;
        // Individual targets (zig build test-api, etc.)
        const suite_step = b.step(suite.name, suite.desc);
        suite_step.dependOn(&run_suite.step);
    }
    // "zig build test" depends on the last suite (which chains to all previous)
    if (last_run) |last| test_step.dependOn(last);

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
    const linux_step_arm = b.step("linux-arm", "Cross-compile for aarch64-linux-musl");
    linux_step_arm.dependOn(&b.addInstallArtifact(linux_exe_arm, .{}).step);
}
