// nanobrew — Faster-than-zerobrew Homebrew replacement
//
// Usage:
//   nb init                    # Create /opt/nanobrew/ directory tree
//   nb install <formula> ...   # Install packages with full dep resolution
//   nb remove <formula> ...    # Uninstall packages
//   nb list                    # List installed packages
//   nb info <formula>          # Show formula info from Homebrew API
//   nb upgrade [formula]       # Upgrade packages

const std = @import("std");
const nb = @import("nanobrew");

const Command = enum {
    init,
    install,
    remove,
    list,
    info,
    upgrade,
    help,
};

const Phase = enum(u8) {
    waiting = 0,
    downloading,
    extracting,
    installing,
    relocating,
    linking,
    done,
    failed,
};

const ROOT = "/opt/nanobrew";
const PREFIX = ROOT ++ "/prefix";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const cmd = parseCommand(args[1]) orelse {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("nb: unknown command '{s}'\n\n", .{args[1]}) catch {};
        printUsage();
        std.process.exit(1);
    };

    switch (cmd) {
        .init => runInit(),
        .install => runInstall(alloc, args[2..]),
        .remove => runRemove(alloc, args[2..]),
        .list => runList(alloc),
        .info => runInfo(alloc, args[2..]),
        .upgrade => runUpgrade(alloc, args[2..]),
        .help => printUsage(),
    }
}

fn parseCommand(arg: []const u8) ?Command {
    const cmds = .{
        .{ "init", Command.init },
        .{ "install", Command.install },
        .{ "i", Command.install },
        .{ "remove", Command.remove },
        .{ "uninstall", Command.remove },
        .{ "rm", Command.remove },
        .{ "ui", Command.remove },
        .{ "list", Command.list },
        .{ "ls", Command.list },
        .{ "info", Command.info },
        .{ "upgrade", Command.upgrade },
        .{ "help", Command.help },
        .{ "--help", Command.help },
        .{ "-h", Command.help },
    };
    inline for (cmds) |pair| {
        if (std.mem.eql(u8, arg, pair[0])) return pair[1];
    }
    return null;
}

// ── nb init ──

fn runInit() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const dirs = [_][]const u8{
        ROOT,
        ROOT ++ "/store",
        PREFIX,
        PREFIX ++ "/Cellar",
        PREFIX ++ "/bin",
        PREFIX ++ "/opt",
        ROOT ++ "/cache",
        ROOT ++ "/cache/blobs",
        ROOT ++ "/cache/tmp",
        ROOT ++ "/cache/api",
        ROOT ++ "/cache/tokens",
        ROOT ++ "/db",
        ROOT ++ "/locks",
    };

    for (dirs) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            error.AccessDenied => {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("nb: permission denied creating {s}\n", .{dir}) catch {};
                stderr.print("nb: try: sudo nb init\n", .{}) catch {};
                std.process.exit(1);
            },
            else => {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("nb: error creating {s}: {}\n", .{ dir, err }) catch {};
                std.process.exit(1);
            },
        };
    }

    stdout.print("nanobrew initialized at {s}\n", .{ROOT}) catch {};
    stdout.print("Add to your shell: export PATH=\"{s}/bin:$PATH\"\n", .{PREFIX}) catch {};
}

// ── nb install ──

fn runInstall(alloc: std.mem.Allocator, formulae: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (formulae.len == 0) {
        stderr.print("nb: no formulae specified\n", .{}) catch {};
        std.process.exit(1);
    }

    var timer = std.time.Timer.start() catch null;
    var phase_timer = std.time.Timer.start() catch null;

    // Phase 1: Resolve all dependencies
    stdout.print("==> Resolving dependencies...\n", .{}) catch {};
    var resolver = nb.deps.DepResolver.init(alloc);
    defer resolver.deinit();

    for (formulae) |name| {
        resolver.resolve(name) catch |err| {
            stderr.print("nb: failed to resolve '{s}': {}\n", .{ name, err }) catch {};
            std.process.exit(1);
        };
    }

    const resolve_ms = if (phase_timer) |*pt| @as(f64, @floatFromInt(pt.read())) / 1_000_000.0 else 0;
    stdout.print("    [{d:.0}ms]\n", .{resolve_ms}) catch {};

    const all_formulae = resolver.topologicalSort() catch {
        stderr.print("nb: dependency cycle detected\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(all_formulae);

    // Filter out already-installed packages (keg exists in Cellar)
    var to_install: std.ArrayList(nb.formula.Formula) = .empty;
    defer to_install.deinit(alloc);
    for (all_formulae) |f| {
        var ver_buf: [256]u8 = undefined;
        const actual_ver = nb.cellar.detectKegVersion(f.name, f.version, &ver_buf) orelse f.version;
        var keg_buf: [512]u8 = undefined;
        const keg_path = std.fmt.bufPrint(&keg_buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}/bin", .{ f.name, actual_ver }) catch {
            to_install.append(alloc, f) catch {};
            continue;
        };
        // Check if keg has content (bin/ dir or at least the version dir exists)
        var check_buf: [512]u8 = undefined;
        const ver_dir = std.fmt.bufPrint(&check_buf, "/opt/nanobrew/prefix/Cellar/{s}/{s}", .{ f.name, actual_ver }) catch {
            to_install.append(alloc, f) catch {};
            continue;
        };
        _ = keg_path;
        if (std.fs.openDirAbsolute(ver_dir, .{})) |d| {
            var dir = d;
            dir.close();
            // Already installed, skip
        } else |_| {
            to_install.append(alloc, f) catch {};
        }
    }
    const install_order = to_install.items;

    if (install_order.len == 0) {
        const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        stdout.print("==> Already installed ({d} packages up to date)\n", .{all_formulae.len}) catch {};
        stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
        return;
    }

    stdout.print("==> Installing {d} package(s) ({d} already up to date):\n", .{ install_order.len, all_formulae.len - install_order.len }) catch {};
    for (install_order) |f| {
        stdout.print("    {s} {s}\n", .{ f.name, f.version }) catch {};
    }

    // Single merged phase: Download → Extract → Materialize → Relocate → Link (all parallel)
    phase_timer = std.time.Timer.start() catch null;
    const pkg_count = install_order.len;
    stdout.print("==> Downloading + installing {d} packages...\n", .{pkg_count}) catch {};
    {
        // Allocate per-package phase tracking
        const phases = alloc.alloc(std.atomic.Value(u8), pkg_count) catch {
            stderr.print("nb: out of memory\n", .{}) catch {};
            std.process.exit(1);
        };
        defer alloc.free(phases);
        for (phases) |*p| p.* = std.atomic.Value(u8).init(@intFromEnum(Phase.waiting));

        // Collect package names for display
        const names = alloc.alloc([]const u8, pkg_count) catch {
            stderr.print("nb: out of memory\n", .{}) catch {};
            std.process.exit(1);
        };
        defer alloc.free(names);
        for (install_order, 0..) |f, i| names[i] = f.name;

        var had_error = std.atomic.Value(bool).init(false);
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(alloc);
        for (install_order, 0..) |f, i| {
            const t = std.Thread.spawn(.{}, fullInstallOne, .{ alloc, f, &had_error, &phases[i] }) catch {
                had_error.store(true, .release);
                phases[i].store(@intFromEnum(Phase.failed), .release);
                continue;
            };
            threads.append(alloc, t) catch continue;
        }

        // Live progress on TTY, plain wait otherwise
        const is_tty = std.posix.isatty(std.posix.STDOUT_FILENO);
        if (is_tty) {
            renderProgress(std.fs.File.stdout(), names, phases);
        }

        for (threads.items) |t| t.join();

        // Non-TTY: print final status for each package
        if (!is_tty) {
            for (names, 0..) |name, i| {
                const raw: u8 = phases[i].load(.acquire);
                const phase: Phase = @enumFromInt(raw);
                if (phase == .done) {
                    stdout.print("    ✓ {s}\n", .{name}) catch {};
                } else if (phase == .failed) {
                    stdout.print("    ✗ {s}\n", .{name}) catch {};
                }
            }
        }

        if (had_error.load(.acquire)) {
            stderr.print("nb: some packages failed to install\n", .{}) catch {};
        }
    }
    const pipeline_ms = if (phase_timer) |*pt| @as(f64, @floatFromInt(pt.read())) / 1_000_000.0 else 0;
    stdout.print("    [{d:.0}ms]\n", .{pipeline_ms}) catch {};

    // Record in database (must be serial — single file)
    var db = nb.database.Database.open() catch {
        stderr.print("nb: warning: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();
    for (install_order) |f| {
        var ver_buf6: [256]u8 = undefined;
        const actual_ver = nb.cellar.detectKegVersion(f.name, f.version, &ver_buf6) orelse f.version;
        db.recordInstall(f.name, actual_ver, f.bottle_sha256) catch {};
    }

    const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
}



/// Render live progress UI with spinners and checkmarks.
/// Blocks until all packages reach .done or .failed.
fn renderProgress(
    stdout_file: std.fs.File,
    names: []const []const u8,
    phases: []std.atomic.Value(u8),
) void {
    const n = names.len;

    // Compute max name length for alignment
    var max_len: usize = 0;
    for (names) |name| {
        if (name.len > max_len) max_len = name.len;
    }

    const spinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏";
    const frame_bytes: usize = 3; // each braille char is 3 UTF-8 bytes
    const frame_count: usize = spinner.len / frame_bytes;
    var tick: usize = 0;

    // Hide cursor
    stdout_file.writeAll("\x1b[?25l") catch {};

    // Reserve N lines
    for (0..n) |_| stdout_file.writeAll("\n") catch {};

    while (true) {
        // Move cursor up N lines
        var esc_buf: [16]u8 = undefined;
        const esc = std.fmt.bufPrint(&esc_buf, "\x1b[{d}A", .{n}) catch "";
        stdout_file.writeAll(esc) catch {};

        var all_done = true;
        for (names, 0..) |name, i| {
            const raw: u8 = phases[i].load(.acquire);
            const phase: Phase = @enumFromInt(raw);

            // Clear line
            stdout_file.writeAll("\x1b[2K") catch {};

            switch (phase) {
                .done => {
                    stdout_file.writeAll("    \x1b[32m✓\x1b[0m ") catch {};
                    stdout_file.writeAll(name) catch {};
                    stdout_file.writeAll("\n") catch {};
                },
                .failed => {
                    stdout_file.writeAll("    \x1b[31m✗\x1b[0m ") catch {};
                    stdout_file.writeAll(name) catch {};
                    stdout_file.writeAll("\n") catch {};
                },
                else => {
                    all_done = false;
                    const fi = tick % frame_count;
                    const start = fi * frame_bytes;
                    stdout_file.writeAll("    ") catch {};
                    stdout_file.writeAll(spinner[start .. start + frame_bytes]) catch {};
                    stdout_file.writeAll(" ") catch {};
                    stdout_file.writeAll(name) catch {};
                    // Pad to align phase labels
                    var pad: usize = max_len - name.len + 1;
                    while (pad > 0) : (pad -= 1) stdout_file.writeAll(" ") catch {};
                    const label: []const u8 = switch (phase) {
                        .waiting => "waiting...",
                        .downloading => "downloading...",
                        .extracting => "extracting...",
                        .installing => "installing...",
                        .relocating => "relocating...",
                        .linking => "linking...",
                        .done, .failed => unreachable,
                    };
                    stdout_file.writeAll(label) catch {};
                    stdout_file.writeAll("\n") catch {};
                },
            }
        }

        if (all_done) break;

        tick += 1;
        std.Thread.sleep(80 * std.time.ns_per_ms);
    }

    // Show cursor
    stdout_file.writeAll("\x1b[?25h") catch {};
}

/// Full per-package pipeline: download → extract → materialize → relocate → link
/// Runs in its own thread — no barriers between phases.
fn fullInstallOne(alloc: std.mem.Allocator, f: nb.formula.Formula, had_error: *std.atomic.Value(bool), phase: *std.atomic.Value(u8)) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // 1. Download (skip if blob cached)
    phase.store(@intFromEnum(Phase.downloading), .release);
    const blob_dir = "/opt/nanobrew/cache/blobs";
    var blob_buf: [512]u8 = undefined;
    const blob_path = std.fmt.bufPrint(&blob_buf, "{s}/{s}", .{ blob_dir, f.bottle_sha256 }) catch {
        stderr.print("nb: {s}: path too long for blob\n", .{f.name}) catch {};
        had_error.store(true, .release);
        phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };

    if (!fileExists(blob_path)) {
        nb.downloader.downloadOne(alloc, .{ .url = f.bottleUrl(), .expected_sha256 = f.bottle_sha256 }) catch |err| {
            stderr.print("nb: {s}: download failed: {}\n", .{ f.name, err }) catch {};
            had_error.store(true, .release);
            phase.store(@intFromEnum(Phase.failed), .release);
            return;
        };
    }

    // 2. Extract into store (skip if already there)
    phase.store(@intFromEnum(Phase.extracting), .release);
    if (!nb.store.hasEntry(f.bottle_sha256)) {
        nb.store.ensureEntry(alloc, blob_path, f.bottle_sha256) catch |err| {
            stderr.print("nb: {s}: extract failed: {}\n", .{ f.name, err }) catch {};
            had_error.store(true, .release);
            phase.store(@intFromEnum(Phase.failed), .release);
            return;
        };
    }

    // 3. Materialize (clonefile into Cellar)
    phase.store(@intFromEnum(Phase.installing), .release);
    nb.cellar.materialize(f.bottle_sha256, f.name, f.version) catch |err| {
        stderr.print("nb: {s}: materialize failed: {}\n", .{ f.name, err }) catch {};
        had_error.store(true, .release);
        phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };

    // 4. Relocate (fix Homebrew placeholders in Mach-O binaries)
    phase.store(@intFromEnum(Phase.relocating), .release);
    var ver_buf: [256]u8 = undefined;
    const actual_ver = nb.cellar.detectKegVersion(f.name, f.version, &ver_buf) orelse f.version;
    nb.relocate.relocateKeg(alloc, f.name, actual_ver) catch |err| {
        stderr.print("nb: {s}: relocate failed: {}\n", .{ f.name, err }) catch {};
    };

    // 5. Link binaries
    phase.store(@intFromEnum(Phase.linking), .release);
    nb.linker.linkKeg(f.name, actual_ver) catch |err| {
        stderr.print("nb: {s}: link failed: {}\n", .{ f.name, err }) catch {};
    };

    phase.store(@intFromEnum(Phase.done), .release);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
fn runRemove(alloc: std.mem.Allocator, formulae: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (formulae.len == 0) {
        stderr.print("nb: no formulae specified\n", .{}) catch {};
        std.process.exit(1);
    }

    var db = nb.database.Database.open() catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    for (formulae) |name| {
        const keg = db.findKeg(name) orelse {
            stderr.print("nb: '{s}' is not installed\n", .{name}) catch {};
            continue;
        };

        nb.linker.unlinkKeg(name, keg.version) catch {};
        nb.cellar.remove(name, keg.version) catch {};
        db.recordRemoval(name, alloc) catch {};
        stdout.print("==> Removed {s}\n", .{name}) catch {};
    }
}

// ── nb list ──

fn runList(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var db = nb.database.Database.open() catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();

    const kegs = db.listInstalled(alloc) catch {
        stderr.print("nb: failed to list packages\n", .{}) catch {};
        return;
    };
    defer alloc.free(kegs);

    if (kegs.len == 0) {
        stdout.print("No packages installed.\n", .{}) catch {};
        return;
    }

    for (kegs) |keg| {
        stdout.print("{s} {s}\n", .{ keg.name, keg.version }) catch {};
    }
}

// ── nb info ──

fn runInfo(alloc: std.mem.Allocator, formulae: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (formulae.len == 0) {
        stderr.print("nb: no formula specified\n", .{}) catch {};
        std.process.exit(1);
    }

    for (formulae) |name| {
        const f = nb.api_client.fetchFormula(alloc, name) catch {
            stderr.print("nb: formula '{s}' not found\n", .{name}) catch {};
            continue;
        };
        stdout.print("{s} {s}\n", .{ f.name, f.version }) catch {};
        stdout.print("  deps: ", .{}) catch {};
        for (f.dependencies, 0..) |dep, i| {
            if (i > 0) stdout.print(", ", .{}) catch {};
            stdout.print("{s}", .{dep}) catch {};
        }
        stdout.print("\n", .{}) catch {};
    }
}

// ── nb upgrade ──

fn runUpgrade(alloc: std.mem.Allocator, formulae: []const []const u8) void {
    _ = alloc;
    _ = formulae;
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print("nb: upgrade not yet implemented\n", .{}) catch {};
}

fn printUsage() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print(
        \\nanobrew — The fastest macOS package manager
        \\
        \\  Faster than zerobrew. Faster than homebrew. Written in Zig.
        \\  SIMD extraction + mmap + arena allocators + APFS clonefile.
        \\
        \\USAGE:
        \\  nb <command> [arguments]
        \\
        \\COMMANDS:
        \\  init                Create /opt/nanobrew/ directory tree
        \\  install <formula>   Install packages (with full dep resolution)
        \\  remove <formula>    Uninstall packages
        \\  list                List installed packages
        \\  info <formula>      Show formula info from Homebrew API
        \\  upgrade [formula]   Upgrade packages (or all if none specified)
        \\  help                Show this help
        \\
        \\EXAMPLES:
        \\  sudo nb init
        \\  nb install ripgrep
        \\  nb install ffmpeg python node
        \\  nb list
        \\  nb remove ripgrep
        \\
    , .{}) catch {};
}
