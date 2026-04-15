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

    // ── Tests (all-in-one) ──
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ── Per-module test steps (atomic — one crash doesn't kill the rest) ──
    const test_modules = .{
        .{ "test-api", "src/api/client.zig", "Run API client tests" },
        .{ "test-tap", "src/api/tap.zig", "Run tap tests" },
        .{ "test-cask", "src/api/cask.zig", "Run cask tests" },
        .{ "test-deb-index", "src/deb/index.zig", "Run deb index tests" },
        .{ "test-deb-resolver", "src/deb/resolver.zig", "Run deb resolver tests" },
        .{ "test-deb-extract", "src/deb/extract.zig", "Run deb extract tests" },
        .{ "test-deb-distro", "src/deb/distro.zig", "Run deb distro tests" },
        .{ "test-version", "src/version.zig", "Run version tests" },
        .{ "test-tar", "src/extract/tar.zig", "Run tar tests" },
        .{ "test-security", "src/security_test.zig", "Run security tests" },
        .{ "test-search", "src/api/search.zig", "Run search tests" },
    };
    inline for (test_modules) |entry| {
        const mod = b.createModule(.{
            .root_source_file = b.path(entry[1]),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        const s = b.step(entry[0], entry[2]);
        s.dependOn(&run_t.step);
    }

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
