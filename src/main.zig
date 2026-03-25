// nanobrew — Faster-than-zerobrew Homebrew replacement
//
// Usage:
//   nb init                    # Create /opt/nanobrew/ directory tree
//   nb install <formula> ...   # Install packages with full dep resolution
//   nb remove <formula> ...    # Uninstall packages
//   nb list                    # List installed packages
//   nb info <formula>          # Show formula info from Homebrew API
//   nb info --cask <app>       # Show cask info from Homebrew API
//   nb search <query>          # Search for formulas and casks
//   nb upgrade [formula]       # Upgrade packages
//   nb update                  # Self-update nanobrew
const std = @import("std");
const nb = @import("nanobrew");
const builtin = @import("builtin");
const platform = nb.platform;
const paths = platform.paths;
const Command = enum {
    init,
    install,
    remove,
    list,
    info,
    search,
    upgrade,
    update,
    help,
    doctor,
    cleanup,
    outdated,
    pin,
    unpin,
    rollback,
    bundle,
    deps,
    services,
    completions,
    nuke,
    migrate,
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

const ROOT = paths.ROOT;
const PREFIX = paths.PREFIX;
const VERSION = "0.1.074";

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
        .search => runSearch(alloc, args[2..]),
        .upgrade => runUpgrade(alloc, args[2..]),
        .update => runUpdate(alloc),
        .help => printUsage(),
        .doctor => runDoctor(alloc),
        .cleanup => runCleanup(alloc, args[2..]),
        .outdated => runOutdated(alloc),
        .pin => runPin(alloc, args[2..], true),
        .unpin => runPin(alloc, args[2..], false),
        .rollback => runRollback(alloc, args[2..]),
        .bundle => runBundle(alloc, args[2..]),
        .deps => runDeps(alloc, args[2..]),
        .services => runServices(alloc, args[2..]),
        .completions => runCompletions(args[2..]),
        .nuke => runNuke(args[2..]),
        .migrate => runMigrate(alloc),
    }

    // Check for updates (once per day, non-blocking)
    checkForUpdate(alloc);
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
        .{ "search", Command.search },
        .{ "s", Command.search },
        .{ "upgrade", Command.upgrade },
        .{ "update", Command.update },
        .{ "self-update", Command.update },
        .{ "help", Command.help },
        .{ "--help", Command.help },
        .{ "-h", Command.help },
        .{ "doctor", Command.doctor },
        .{ "dr", Command.doctor },
        .{ "cleanup", Command.cleanup },
        .{ "clean", Command.cleanup },
        .{ "outdated", Command.outdated },
        .{ "pin", Command.pin },
        .{ "unpin", Command.unpin },
        .{ "rollback", Command.rollback },
        .{ "rb", Command.rollback },
        .{ "bundle", Command.bundle },
        .{ "deps", Command.deps },
        .{ "services", Command.services },
        .{ "service", Command.services },
        .{ "completions", Command.completions },
        .{ "nuke", Command.nuke },
        .{ "uninstall-self", Command.nuke },
        .{ "migrate", Command.migrate },
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
        PREFIX ++ "/Caskroom",
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

    // If running as root (sudo), chown to the real user so nb install doesn't need sudo
    if (std.posix.getenv("SUDO_USER")) |real_user| {
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "chown", "-R", real_user, ROOT },
        }) catch {};
    }

    stdout.print("nanobrew initialized at {s}\n", .{ROOT}) catch {};
    stdout.print("Add to your shell: export PATH=\"{s}/bin:$PATH\"\n", .{PREFIX}) catch {};
}

/// Validate a package name is safe (no path traversal, no control chars, no null bytes).
fn isPackageNameSafe(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    var slash_count: usize = 0;
    for (name) |c| {
        if (c == '/') {
            slash_count += 1;
        } else if (c < 0x20 or c == 0x7f or c == 0) {
            return false;
        } else if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '@' and c != '.' and c != '+') {
            return false;
        }
    }
    return slash_count == 0 or slash_count == 2;
}

// ── nb install ──

fn runInstall(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Check for --cask, --deb, --repo, --skip-postinst, and --no-verify flags
    var is_cask = false;
    var is_deb = false;
    var repo_spec: ?[]const u8 = null;
    var skip_postinst = false;
    var no_verify = false;
    var formulae: std.ArrayList([]const u8) = .empty;
    defer formulae.deinit(alloc);
    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--cask")) {
            is_cask = true;
        } else if (std.mem.eql(u8, arg, "--deb")) {
            is_deb = true;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            if (arg_idx + 1 < args.len) {
                arg_idx += 1;
                repo_spec = args[arg_idx];
            }
        } else if (std.mem.eql(u8, arg, "--skip-postinst")) {
            skip_postinst = true;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            no_verify = true;
        } else {
            formulae.append(alloc, arg) catch {};
        }
    }

    if (formulae.items.len == 0) {
        stderr.print("nb: no formulae specified\n", .{}) catch {};
        std.process.exit(1);
    }

    // Validate all package names before proceeding (#44)
    for (formulae.items) |name| {
        if (!isPackageNameSafe(name)) {
            stderr.print("nb: refusing to install package with unsafe name: {s}\n", .{name}) catch {};
            std.process.exit(1);
        }
    }

    if (is_deb) {
        runDebInstall(alloc, formulae.items, repo_spec, .{
            .skip_postinst = skip_postinst,
            .no_verify = no_verify,
        });
        return;
    }

    if (is_cask) {
        runCaskInstall(alloc, formulae.items);
        return;
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();

    var timer = std.time.Timer.start() catch null;
    var phase_timer = std.time.Timer.start() catch null;

    // Phase 1: Resolve all dependencies
    stdout.print("==> Resolving dependencies...\n", .{}) catch {};
    var resolver = nb.deps.DepResolver.init(alloc);
    defer resolver.deinit();

    for (formulae.items) |name| {
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

    // Pre-flight check: verify /opt/nanobrew is writable
    const write_ok: ?std.fs.File = std.fs.createFileAbsolute(ROOT ++ "/cache/.nb_write_test", .{}) catch null;
    if (write_ok != null) {
        write_ok.?.close();
        std.fs.deleteFileAbsolute(ROOT ++ "/cache/.nb_write_test") catch {};
    } else {
        stderr.print("nb: /opt/nanobrew is not writable. Run: sudo nb init\n", .{}) catch {};
        std.process.exit(1);
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
        for (install_order, 0..) |f, idx| names[idx] = f.name;

        var had_error = std.atomic.Value(bool).init(false);
        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(alloc);

        const max_concurrent: usize = 16;

        for (install_order, 0..) |f, pi| {
            // Sliding window: when at capacity, wait for the oldest thread to finish
            // before spawning a new one. This keeps ~16 threads running at all times
            // instead of bursting 16, waiting for all, then bursting 16 again. (#36)
            if (threads.items.len >= max_concurrent) {
                threads.items[0].join();
                _ = threads.orderedRemove(0);
            }
            const t = std.Thread.spawn(.{}, fullInstallOne, .{ alloc, f, &had_error, &phases[pi] }) catch {
                had_error.store(true, .release);
                phases[pi].store(@intFromEnum(Phase.failed), .release);
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
            // Re-print which packages failed so the user sees them after progress display
            for (names, 0..) |name, i| {
                const raw: u8 = phases[i].load(.acquire);
                const phase: Phase = @enumFromInt(raw);
                if (phase == .failed) {
                    stderr.print("    failed: {s}\n", .{name}) catch {};
                }
            }
            stderr.print("nb: hint: check permissions with `nb doctor`\n", .{}) catch {};
        }
    }
    const pipeline_ms = if (phase_timer) |*pt| @as(f64, @floatFromInt(pt.read())) / 1_000_000.0 else 0;
    stdout.print("    [{d:.0}ms]\n", .{pipeline_ms}) catch {};

    // Record in database (must be serial — single file)
    var db = nb.database.Database.open(alloc) catch {
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

    const is_source_build = f.bottle_url.len == 0 and f.source_url.len > 0;

    if (is_source_build) {
        // Source build path: download + compile from source
        phase.store(@intFromEnum(Phase.downloading), .release);
        nb.source_builder.buildFromSource(alloc, f) catch |err| {
            stderr.print("nb: {s}: source build failed: {}\n", .{ f.name, err }) catch {};
            had_error.store(true, .release);
            phase.store(@intFromEnum(Phase.failed), .release);
            return;
        };
    } else {
        // Bottle path: download pre-built binary
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
    }

    // 4. Relocate (fix Homebrew placeholders in Mach-O binaries)
    phase.store(@intFromEnum(Phase.relocating), .release);
    var ver_buf: [256]u8 = undefined;
    const actual_ver = nb.cellar.detectKegVersion(f.name, f.version, &ver_buf) orelse f.version;
    platform.relocate.relocateKeg(alloc, f.name, actual_ver) catch |err| {
        stderr.print("nb: {s}: relocate failed: {}\n", .{ f.name, err }) catch {};
    };

    // 4b. Replace @@HOMEBREW_*@@ placeholders in text files (shebangs, scripts, configs)
    platform.relocate.replaceKegPlaceholders(f.name, actual_ver);

    // 5. Link binaries
    phase.store(@intFromEnum(Phase.linking), .release);
    nb.linker.linkKeg(f.name, actual_ver) catch |err| {
        stderr.print("nb: {s}: link failed: {}\n", .{ f.name, err }) catch {};
    };

    // 6. Post-install (non-fatal)
    nb.postinstall.runPostInstall(alloc, f) catch |err| {
        stderr.print("nb: {s}: post-install warning: {}\n", .{ f.name, err }) catch {};
    };

    phase.store(@intFromEnum(Phase.done), .release);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
fn runRemove(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Check for --cask and --deb flags
    var is_cask = false;
    var is_deb = false;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(alloc);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask")) {
            is_cask = true;
        } else if (std.mem.eql(u8, arg, "--deb")) {
            is_deb = true;
        } else {
            tokens.append(alloc, arg) catch {};
        }
    }

    if (tokens.items.len == 0) {
        stderr.print("nb: no formulae specified\n", .{}) catch {};
        std.process.exit(1);
    }

    if (is_cask) {
        runCaskRemove(alloc, tokens.items);
        return;
    }

    if (is_deb) {
        runDebRemove(alloc, tokens.items);
        return;
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    for (tokens.items) |raw_name| {
        // Support tap refs: "user/tap/formula" -> look up "formula"
        const name = if (std.mem.lastIndexOfScalar(u8, raw_name, '/')) |pos| raw_name[pos + 1 ..] else raw_name;
        const keg = db.findKeg(name) orelse {
            stderr.print("nb: '{s}' is not installed\n", .{raw_name}) catch {};
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

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();

    const kegs = db.listInstalled(alloc) catch {
        stderr.print("nb: failed to list packages\n", .{}) catch {};
        return;
    };
    defer alloc.free(kegs);

    const casks_result = db.listInstalledCasks(alloc);
    const casks: []const nb.database.CaskRecord = if (casks_result) |c| c else |_| &.{};
    defer if (casks_result) |c| alloc.free(c) else |_| {};

    const debs_result = db.listInstalledDebs(alloc);
    const debs: []const nb.database.DebRecord = if (debs_result) |d| d else |_| &.{};
    defer if (debs_result) |d| alloc.free(d) else |_| {};

    if (kegs.len == 0 and casks.len == 0 and debs.len == 0) {
        stdout.print("No packages installed.\n", .{}) catch {};
        return;
    }

    for (kegs) |keg| {
        const pin_tag = if (keg.pinned) " [pinned]" else "";
        stdout.print("{s} {s}{s}\n", .{ keg.name, keg.version, pin_tag }) catch {};
    }
    for (casks) |c| {
        stdout.print("{s} {s} (cask)\n", .{ c.token, c.version }) catch {};
    }
    for (debs) |d| {
        stdout.print("{s} {s} (deb)\n", .{ d.name, d.version }) catch {};
    }
}

// ── nb info ──

fn runInfo(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    // Parse --cask flag
    var is_cask = false;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask")) {
            is_cask = true;
        } else {
            names.append(alloc, arg) catch {};
        }
    }

    if (names.items.len == 0) {
        stderr.print("nb: no package specified\n", .{}) catch {};
        std.process.exit(1);
    }

    for (names.items) |name| {
        if (is_cask) {
            showCaskInfo(alloc, stdout, stderr, name);
        } else {
            // Try formula first; on failure, try cask as fallback for a hint
            const f = nb.api_client.fetchFormula(alloc, name) catch {
                // Formula not found — try cask API to give a helpful hint
                if (nb.api_client.fetchCask(alloc, name)) |cask| {
                    defer cask.deinit(alloc);
                    stderr.print("nb: formula '{s}' not found\n", .{name}) catch {};
                    stderr.print("    Did you mean: nb info --cask {s}?\n", .{name}) catch {};
                } else |_| {
                    stderr.print("nb: formula '{s}' not found\n", .{name}) catch {};
                }
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
}

fn showCaskInfo(alloc: std.mem.Allocator, stdout: anytype, stderr: anytype, name: []const u8) void {
    const cask = nb.api_client.fetchCask(alloc, name) catch {
        stderr.print("nb: cask '{s}' not found\n", .{name}) catch {};
        return;
    };
    defer cask.deinit(alloc);

    // Name and description
    stdout.print("{s} {s}\n", .{ cask.name, cask.version }) catch {};
    if (cask.desc.len > 0) {
        stdout.print("  {s}\n", .{cask.desc}) catch {};
    }

    // Homepage
    if (cask.homepage.len > 0) {
        stdout.print("  homepage: {s}\n", .{cask.homepage}) catch {};
    }

    // Download URL
    stdout.print("  url: {s}\n", .{cask.url}) catch {};

    // SHA256
    stdout.print("  sha256: {s}\n", .{cask.sha256}) catch {};

    // Artifacts
    if (cask.artifacts.len > 0) {
        stdout.print("  artifacts:\n", .{}) catch {};
        for (cask.artifacts) |art| {
            switch (art) {
                .app => |a| stdout.print("    app: {s}\n", .{a}) catch {},
                .binary => |b| stdout.print("    binary: {s} -> {s}\n", .{ b.source, b.target }) catch {},
                .pkg => |p| stdout.print("    pkg: {s}\n", .{p}) catch {},
                .uninstall => |u| {
                    if (u.quit.len > 0) stdout.print("    uninstall quit: {s}\n", .{u.quit}) catch {};
                    if (u.pkgutil.len > 0) stdout.print("    uninstall pkgutil: {s}\n", .{u.pkgutil}) catch {};
                },
            }
        }
    }
}

// ── nb upgrade ──

// ── nb search ──

fn runSearch(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len == 0) {
        stderr.print("nb: no search query specified\nUsage: nb search <query>\n", .{}) catch {};
        std.process.exit(1);
    }

    const query = args[0];
    stdout.print("==> Searching for \"{s}\"...\n", .{query}) catch {};

    const results = nb.search_api.search(alloc, query) catch |err| {
        stderr.print("nb: search failed: {}\n", .{err}) catch {};
        std.process.exit(1);
    };
    defer {
        for (results) |r| r.deinit(alloc);
        alloc.free(results);
    }

    if (results.len == 0) {
        stdout.print("No results found for \"{s}\"\n", .{query}) catch {};
        return;
    }

    // Check installed status
    var db = nb.database.Database.open(alloc) catch {
        // Can still show results without install status
        for (results) |r| {
            if (r.is_cask) {
                stdout.print("{s} {s} (cask) - {s}\n", .{ r.name, r.version, r.desc }) catch {};
            } else {
                stdout.print("{s} {s} - {s}\n", .{ r.name, r.version, r.desc }) catch {};
            }
        }
        return;
    };
    defer db.close();

    for (results) |r| {
        const installed = if (r.is_cask)
            db.findCask(r.name) != null
        else
            db.findKeg(r.name) != null;

        const install_tag = if (installed) " [installed]" else "";

        if (r.is_cask) {
            stdout.print("{s} {s}{s} (cask) - {s}\n", .{ r.name, r.version, install_tag, r.desc }) catch {};
        } else {
            stdout.print("{s} {s}{s} - {s}\n", .{ r.name, r.version, install_tag, r.desc }) catch {};
        }
    }

    stdout.print("\n==> {d} result(s)\n", .{results.len}) catch {};
}

const Outdated = struct {
    name: []const u8,
    old_ver: []const u8,
    new_ver: []const u8,
    is_cask_pkg: bool,
    is_pinned: bool,
};

fn getOutdatedPackages(alloc: std.mem.Allocator, db: *nb.database.Database, filter_names: []const []const u8, check_casks: bool, check_kegs: bool) std.ArrayList(Outdated) {
    var result: std.ArrayList(Outdated) = .empty;

    if (check_casks) {
        const installed_casks = db.listInstalledCasks(alloc) catch &.{};
        defer alloc.free(installed_casks);
        for (installed_casks) |c| {
            if (filter_names.len > 0) {
                var found = false;
                for (filter_names) |n| {
                    if (std.mem.eql(u8, n, c.token)) { found = true; break; }
                }
                if (!found) continue;
            }
            const latest = nb.api_client.fetchCask(alloc, c.token) catch continue;
            defer latest.deinit(alloc);
            if (nb.version.isNewer(latest.version, c.version)) {
                result.append(alloc, .{
                    .name = alloc.dupe(u8, c.token) catch continue,
                    .old_ver = alloc.dupe(u8, c.version) catch continue,
                    .new_ver = alloc.dupe(u8, latest.version) catch continue,
                    .is_cask_pkg = true,
                    .is_pinned = false,
                }) catch {};
            }
        }
    }

    if (check_kegs) {
        const installed_kegs = db.listInstalled(alloc) catch &.{};
        defer alloc.free(installed_kegs);
        for (installed_kegs) |k| {
            if (filter_names.len > 0) {
                var found = false;
                for (filter_names) |n| {
                    if (std.mem.eql(u8, n, k.name)) { found = true; break; }
                }
                if (!found) continue;
            }
            const latest = nb.api_client.fetchFormula(alloc, k.name) catch continue;
            defer latest.deinit(alloc);
            if (nb.version.isNewer(latest.version, k.version)) {
                result.append(alloc, .{
                    .name = alloc.dupe(u8, k.name) catch continue,
                    .old_ver = alloc.dupe(u8, k.version) catch continue,
                    .new_ver = alloc.dupe(u8, latest.version) catch continue,
                    .is_cask_pkg = false,
                    .is_pinned = k.pinned,
                }) catch {};
            }
        }
    }

    return result;
}

fn runUpgrade(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var timer = std.time.Timer.start() catch null;

    // Parse --cask and --deb flags
    var is_cask = false;
    var is_deb = false;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask")) {
            is_cask = true;
        } else if (std.mem.eql(u8, arg, "--deb")) {
            is_deb = true;
        } else {
            names.append(alloc, arg) catch {};
        }
    }

    if (is_deb) {
        runDebUpgrade(alloc);
        return;
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    const check_casks = is_cask or names.items.len == 0;
    const check_kegs = !is_cask or names.items.len == 0;
    var outdated = getOutdatedPackages(alloc, &db, names.items, check_casks, check_kegs);
    defer outdated.deinit(alloc);

    // Filter out pinned packages
    var upgradeable: std.ArrayList(Outdated) = .empty;
    defer upgradeable.deinit(alloc);
    var pinned_count: usize = 0;
    for (outdated.items) |pkg| {
        if (pkg.is_pinned) {
            pinned_count += 1;
            stdout.print("    {s} ({s} -> {s}) [pinned, skipping]\n", .{ pkg.name, pkg.old_ver, pkg.new_ver }) catch {};
        } else {
            upgradeable.append(alloc, pkg) catch {};
        }
    }

    if (upgradeable.items.len == 0) {
        if (pinned_count > 0) {
            stdout.print("==> All packages are up to date ({d} pinned)\n", .{pinned_count}) catch {};
        } else {
            stdout.print("==> All packages are up to date\n", .{}) catch {};
        }
        return;
    }

    // Print upgrade plan
    stdout.print("==> Upgrading {d} package(s):\n", .{upgradeable.items.len}) catch {};
    for (upgradeable.items) |pkg| {
        const tag = if (pkg.is_cask_pkg) " (cask)" else "";
        stdout.print("    {s} ({s} -> {s}){s}\n", .{ pkg.name, pkg.old_ver, pkg.new_ver, tag }) catch {};
    }

    // Execute upgrades
    for (upgradeable.items) |pkg| {
        if (pkg.is_cask_pkg) {
            if (db.findCask(pkg.name)) |record| {
                nb.cask_installer.removeCask(alloc, pkg.name, record.version, record.apps, record.binaries) catch |err| {
                    stderr.print("nb: {s}: remove failed: {}\n", .{ pkg.name, err }) catch {};
                    continue;
                };
                db.recordCaskRemoval(pkg.name, alloc) catch {};
            }
            const names_slice: []const []const u8 = &.{pkg.name};
            runCaskInstall(alloc, names_slice);
        } else {
            if (db.findKeg(pkg.name)) |keg| {
                nb.linker.unlinkKeg(pkg.name, keg.version) catch {};
                nb.cellar.remove(pkg.name, keg.version) catch {};
                db.recordRemoval(pkg.name, alloc) catch {};
            }
            const names_slice: []const []const u8 = &.{pkg.name};
            runInstall(alloc, names_slice);
        }
        stdout.print("==> Upgraded {s} ({s} -> {s})\n", .{ pkg.name, pkg.old_ver, pkg.new_ver }) catch {};
    }

    const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
}

// ── nb update ──

fn runUpdate(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    stdout.print("==> Updating nanobrew...\n", .{}) catch {};

    // Detect OS and arch at comptime
    const os_name = comptime switch (@import("builtin").os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => @compileError("unsupported OS for self-update"),
    };
    const arch_name = comptime switch (@import("builtin").cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => @compileError("unsupported arch for self-update"),
    };

    // Fetch latest release tag from GitHub API
    const api_url = "https://api.github.com/repos/justrach/nanobrew/releases/latest";
    const api_body = nb.fetch.get(alloc, api_url) catch {
        stderr.print("nb: update failed: could not fetch latest release info\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(api_body);

    // Parse the tag_name from JSON response
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, api_body, .{}) catch {
        stderr.print("nb: update failed: invalid release JSON\n", .{}) catch {};
        std.process.exit(1);
    };
    defer parsed.deinit();

    const tag_name = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("tag_name")) |v| {
                if (v == .string) break :blk v.string;
            }
        }
        stderr.print("nb: update failed: could not find release tag\n", .{}) catch {};
        std.process.exit(1);
    };

    // Check if already up to date (strip leading 'v' if present)
    const latest_ver = if (tag_name.len > 0 and tag_name[0] == 'v') tag_name[1..] else tag_name;
    if (std.mem.eql(u8, latest_ver, VERSION)) {
        stdout.print("==> Already up to date (v{s})\n", .{VERSION}) catch {};
        return;
    }

    stdout.print("==> Downloading v{s} ({s}-{s})...\n", .{ latest_ver, arch_name, os_name }) catch {};

    // Build download URLs
    const tarball_name = "nb-" ++ arch_name ++ "-" ++ os_name ++ ".tar.gz";
    const base_url = "https://github.com/justrach/nanobrew/releases/download/";
    var url_buf: [512]u8 = undefined;
    const tarball_url = std.fmt.bufPrint(&url_buf, "{s}{s}/{s}", .{ base_url, tag_name, tarball_name }) catch {
        stderr.print("nb: update failed: URL too long\n", .{}) catch {};
        std.process.exit(1);
    };
    var sha_url_buf: [512]u8 = undefined;
    const sha_url = std.fmt.bufPrint(&sha_url_buf, "{s}{s}/{s}.sha256", .{ base_url, tag_name, tarball_name }) catch {
        stderr.print("nb: update failed: URL too long\n", .{}) catch {};
        std.process.exit(1);
    };

    // Download SHA256 checksum
    stdout.print("==> Verifying checksum...\n", .{}) catch {};
    const sha_body = nb.fetch.get(alloc, sha_url) catch {
        stderr.print("nb: update failed: could not download SHA256 checksum\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(sha_body);

    // Parse expected SHA256 (first 64 hex chars)
    const sha_trimmed = std.mem.trimRight(u8, sha_body, "\n \t");
    // SHA256 file may be "hash  filename" or just "hash"
    const expected_sha: []const u8 = if (sha_trimmed.len >= 64) sha_trimmed[0..64] else {
        stderr.print("nb: update failed: invalid SHA256 file (too short)\n", .{}) catch {};
        std.process.exit(1);
    };

    // Validate that expected_sha is hex
    for (expected_sha) |c| {
        if (!std.ascii.isHex(c)) {
            stderr.print("nb: update failed: invalid SHA256 checksum format\n", .{}) catch {};
            std.process.exit(1);
        }
    }

    // Download tarball to temp file
    const tmp_tar = ROOT ++ "/cache/nb-update.tar.gz";
    nb.fetch.download(alloc, tarball_url, tmp_tar) catch {
        stderr.print("nb: update failed: could not download release tarball\n", .{}) catch {};
        std.process.exit(1);
    };

    // Compute SHA256 of downloaded tarball
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    {
        var file = std.fs.openFileAbsolute(tmp_tar, .{}) catch {
            stderr.print("nb: update failed: could not open downloaded tarball\n", .{}) catch {};
            std.process.exit(1);
        };
        defer file.close();
        var read_buf: [65536]u8 = undefined;
        while (true) {
            const bytes_read = file.read(&read_buf) catch {
                stderr.print("nb: update failed: could not read tarball\n", .{}) catch {};
                std.fs.deleteFileAbsolute(tmp_tar) catch {};
                std.process.exit(1);
            };
            if (bytes_read == 0) break;
            hasher.update(read_buf[0..bytes_read]);
        }
    }
    const digest = hasher.finalResult();
    const charset = "0123456789abcdef";
    var actual_hex: [64]u8 = undefined;
    for (digest, 0..) |byte, idx| {
        actual_hex[idx * 2] = charset[byte >> 4];
        actual_hex[idx * 2 + 1] = charset[byte & 0x0f];
    }

    if (!std.mem.eql(u8, &actual_hex, expected_sha)) {
        stderr.print("nb: update ABORTED: SHA256 verification failed!\n", .{}) catch {};
        stderr.print("  expected: {s}\n", .{expected_sha}) catch {};
        stderr.print("  actual:   {s}\n", .{&actual_hex}) catch {};
        std.fs.deleteFileAbsolute(tmp_tar) catch {};
        std.process.exit(1);
    }

    stdout.print("==> Checksum verified, extracting...\n", .{}) catch {};

    // Get current executable path for replacement
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch {
        stderr.print("nb: update failed: could not determine executable path\n", .{}) catch {};
        std.fs.deleteFileAbsolute(tmp_tar) catch {};
        std.process.exit(1);
    };

    // Extract tarball using tar (to a temp directory)
    const tmp_dir = ROOT ++ "/cache/nb-update-extract";
    std.fs.makeDirAbsolute(tmp_dir) catch {};

    var extract = std.process.Child.init(
        &.{ "tar", "xzf", tmp_tar, "-C", tmp_dir },
        std.heap.page_allocator,
    );
    extract.stdout_behavior = .Ignore;
    extract.stderr_behavior = .Inherit;

    extract.spawn() catch {
        stderr.print("nb: update failed: could not extract tarball\n", .{}) catch {};
        std.fs.deleteFileAbsolute(tmp_tar) catch {};
        std.process.exit(1);
    };

    const extract_term = extract.wait() catch {
        stderr.print("nb: update failed: tar extraction error\n", .{}) catch {};
        std.fs.deleteFileAbsolute(tmp_tar) catch {};
        std.process.exit(1);
    };

    switch (extract_term) {
        .Exited => |code| {
            if (code != 0) {
                stderr.print("nb: update failed: tar exited with code {d}\n", .{code}) catch {};
                std.fs.deleteFileAbsolute(tmp_tar) catch {};
                std.process.exit(1);
            }
        },
        else => {
            stderr.print("nb: update failed: tar terminated abnormally\n", .{}) catch {};
            std.fs.deleteFileAbsolute(tmp_tar) catch {};
            std.process.exit(1);
        },
    }

    // Replace current binary — use cp to handle cross-device moves
    const extracted_bin = tmp_dir ++ "/nb";
    var replace = std.process.Child.init(
        &.{ "cp", "-f", extracted_bin, exe_path },
        std.heap.page_allocator,
    );
    replace.stdout_behavior = .Ignore;
    replace.stderr_behavior = .Inherit;

    replace.spawn() catch {
        stderr.print("nb: update failed: could not replace binary\n", .{}) catch {};
        std.fs.deleteFileAbsolute(tmp_tar) catch {};
        std.process.exit(1);
    };

    const replace_term = replace.wait() catch {
        stderr.print("nb: update failed: binary replacement error\n", .{}) catch {};
        std.fs.deleteFileAbsolute(tmp_tar) catch {};
        std.process.exit(1);
    };

    switch (replace_term) {
        .Exited => |code| {
            if (code != 0) {
                stderr.print("nb: update failed: could not replace binary (exit {d})\n", .{code}) catch {};
                std.fs.deleteFileAbsolute(tmp_tar) catch {};
                std.process.exit(1);
            }
        },
        else => {
            stderr.print("nb: update failed: binary replacement terminated abnormally\n", .{}) catch {};
            std.fs.deleteFileAbsolute(tmp_tar) catch {};
            std.process.exit(1);
        },
    }

    // Cleanup temp files
    std.fs.deleteFileAbsolute(tmp_tar) catch {};
    std.fs.deleteFileAbsolute(extracted_bin) catch {};
    std.fs.deleteDirAbsolute(tmp_dir) catch {};

    stdout.print("==> Updated nanobrew to v{s} (was v{s})\n", .{ latest_ver, VERSION }) catch {};
}

// ── nb install --cask ──

fn runCaskInstall(alloc: std.mem.Allocator, tokens: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (comptime builtin.os.tag == .linux) {
        stderr.print("nb: casks are not supported on Linux yet\n", .{}) catch {};
        return;
    }

    var timer = std.time.Timer.start() catch null;

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: warning: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();

    for (tokens) |token| {
        // Check if already installed
        if (db.findCask(token)) |existing| {
            stdout.print("==> {s} {s} is already installed\n", .{ token, existing.version }) catch {};
            continue;
        }

        stdout.print("==> Fetching cask metadata for {s}...\n", .{token}) catch {};
        const cask_meta = nb.api_client.fetchCask(alloc, token) catch {
            stderr.print("nb: cask '{s}' not found\n", .{token}) catch {};
            continue;
        };
        defer cask_meta.deinit(alloc);

        stdout.print("==> Downloading {s} {s}...\n", .{ cask_meta.name, cask_meta.version }) catch {};
        stdout.print("    {s}\n", .{cask_meta.url}) catch {};

        nb.cask_installer.installCask(alloc, cask_meta) catch |err| {
            stderr.print("nb: failed to install cask '{s}': {}\n", .{ token, err }) catch {};
            continue;
        };

        // Collect app/binary names from artifacts for database
        var apps: std.ArrayList([]const u8) = .empty;
        defer apps.deinit(alloc);
        var binaries: std.ArrayList([]const u8) = .empty;
        defer binaries.deinit(alloc);

        for (cask_meta.artifacts) |art| {
            switch (art) {
                .app => |a| apps.append(alloc, a) catch {},
                .binary => |b| binaries.append(alloc, b.target) catch {},
                .pkg, .uninstall => {},
            }
        }

        db.recordCaskInstall(token, cask_meta.version, apps.items, binaries.items) catch {
            stderr.print("nb: warning: could not record cask install\n", .{}) catch {};
        };

        stdout.print("==> Installed {s} {s}\n", .{ cask_meta.name, cask_meta.version }) catch {};
    }

    const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
}

// ── nb remove --cask ──

fn runCaskRemove(alloc: std.mem.Allocator, tokens: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    for (tokens) |token| {
        const record = db.findCask(token) orelse {
            stderr.print("nb: cask '{s}' is not installed\n", .{token}) catch {};
            continue;
        };

        nb.cask_installer.removeCask(alloc, token, record.version, record.apps, record.binaries) catch |err| {
            stderr.print("nb: failed to remove cask '{s}': {}\n", .{ token, err }) catch {};
            continue;
        };

        db.recordCaskRemoval(token, alloc) catch {};
        stdout.print("==> Removed {s}\n", .{token}) catch {};
    }
}

// ── Version display (cached from endpoint) ──

var display_version_buf: [32]u8 = undefined;
var display_version_len: usize = 0;
var display_version_loaded: bool = false;

/// Returns the latest known version: reads from cache file written by checkForUpdate(),
/// falls back to compile-time VERSION if cache doesn't exist yet.
fn getDisplayVersion() []const u8 {
    if (display_version_loaded) {
        if (display_version_len > 0) return display_version_buf[0..display_version_len];
        return VERSION;
    }
    display_version_loaded = true;

    const cache_path = ROOT ++ "/cache/latest_version";
    const f = std.fs.openFileAbsolute(cache_path, .{}) catch return VERSION;
    defer f.close();
    const n = f.readAll(&display_version_buf) catch return VERSION;
    if (n == 0) return VERSION;
    const trimmed = std.mem.trimRight(u8, display_version_buf[0..n], "\n \t\x00");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "error")) return VERSION;
    display_version_len = trimmed.len;
    return display_version_buf[0..display_version_len];
}


fn printUsage() void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print("\x1b[1mnanobrew\x1b[0m \x1b[90mv{s}\x1b[0m — The fastest package manager\n", .{getDisplayVersion()}) catch {};
    stdout.print(
        \\
        \\  Faster than zerobrew. Faster than homebrew. Written in Zig.
        \\  SIMD extraction + mmap + arena allocators + platform COW copy.
        \\  Works on macOS and Linux.
        \\
        \\USAGE:
        \\  nb <command> [arguments]
        \\
        \\COMMANDS:
        \\  init                     Create /opt/nanobrew/ directory tree
        \\  install <formula>        Install packages (with full dep resolution)
        \\  install --cask <app>     Install macOS applications
        \\  install --deb <pkg>      Install .deb packages (Linux, replaces apt-get)
        \\  remove <formula>         Uninstall packages
        \\  remove --cask <app>      Uninstall macOS applications
        \\  remove --deb <pkg>       Uninstall .deb packages (Linux)
        \\  list                     List installed packages, casks, and debs
        \\  info <formula>           Show formula info from Homebrew API
        \\  info --cask <app>        Show cask info from Homebrew API
        \\  search <query>           Search for formulas and casks
        \\  upgrade [formula]        Upgrade packages (or all if none specified)
        \\  upgrade --cask [app]     Upgrade casks (or all if none specified)
        \\  upgrade --deb            Upgrade all installed .deb packages
        \\  update                   Self-update nanobrew to the latest version
        \\  doctor                   Check installation health
        \\  cleanup [--dry-run]      Remove stale caches and orphaned files
        \\  outdated                 List packages with newer versions available
        \\  pin <package>            Pin a package (skip during upgrade)
        \\  unpin <package>          Unpin a package
        \\  rollback <package>       Rollback to previous version
        \\  bundle [dump|install]    Export/import package lists (Brewfile-compatible)
        \\  deps [--tree] <formula>  Show dependency tree
        \\  services [list|start|stop|restart] [name]
        \\                           Manage background services
        \\  completions [zsh|bash|fish]
        \\                           Generate shell completions
        \\  nuke                     Completely uninstall nanobrew and all packages
        \\  migrate                  Import existing Homebrew packages into nanobrew
        \\  help                     Show this help
        \\
        \\EXAMPLES:
        \\  sudo nb init
        \\  nb install ripgrep
        \\  nb install ffmpeg python node
        \\  nb install --cask firefox
        \\  nb install --deb curl wget git
        \\  nb install steipete/tap/sag
        \\  nb upgrade
        \\  nb upgrade tree
        \\  nb upgrade --cask
        \\  nb upgrade --deb
        \\  nb list
        \\  nb remove ripgrep
        \\  nb remove --cask firefox
        \\  nb remove --deb curl
        \\  nb doctor
        \\  nb cleanup --dry-run
        \\  nb pin tree
        \\  nb rollback ffmpeg
        \\  nb bundle dump > Nanobrew
        \\  nb deps --tree ffmpeg
        \\  nb services list
        \\  nb completions zsh >> ~/.zshrc
        \\
    , .{}) catch {};
}

// ── nb doctor ──

// ── nb doctor ──

fn runDoctor(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var issues: usize = 0;

    stdout.print("==> Checking nanobrew installation...\n", .{}) catch {};

    // 1. Check /opt/nanobrew is writable
    if (std.fs.accessAbsolute(ROOT, .{ .mode = .read_write })) {
        stdout.print("  ✓ {s} is writable\n", .{ROOT}) catch {};
    } else |_| {
        stdout.print("  ✗ {s} is not writable\n", .{ROOT}) catch {};
        issues += 1;
    }

    // 2. Check key dirs exist
    const key_dirs = [_][]const u8{
        ROOT ++ "/cache/api",
        ROOT ++ "/cache/blobs",
        ROOT ++ "/store",
        PREFIX ++ "/Cellar",
        PREFIX ++ "/bin",
        ROOT ++ "/db",
    };
    for (key_dirs) |dir| {
        if (std.fs.openDirAbsolute(dir, .{})) |d| {
            var dd = d;
            dd.close();
        } else |_| {
            stdout.print("  ✗ Missing directory: {s}\n", .{dir}) catch {};
            issues += 1;
        }
    }

    // 3. Check for broken symlinks in prefix/bin/
    {
        var broken_links: usize = 0;
        if (std.fs.openDirAbsolute(PREFIX ++ "/bin", .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .sym_link) continue;
                var link_buf: [1024]u8 = undefined;
                const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, entry.name }) catch continue;
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = std.fs.readLinkAbsolute(link_path, &target_buf) catch continue;
                std.fs.accessAbsolute(target, .{}) catch {
                    if (broken_links < 5) {
                        stdout.print("  ✗ Broken symlink: {s} -> {s}\n", .{ entry.name, target }) catch {};
                    }
                    broken_links += 1;
                };
            }
        } else |_| {}
        if (broken_links > 5) {
            stdout.print("  ✗ ...and {d} more broken symlinks\n", .{broken_links - 5}) catch {};
        }
        if (broken_links > 0) issues += broken_links;
    }

    // 4. DB entries with missing Cellar dirs + 5. Orphaned store entries
    {
        var db = nb.database.Database.open(alloc) catch {
            stdout.print("  ✗ Could not open database\n", .{}) catch {};
            issues += 1;
            printDoctorSummary(stdout, issues);
            return;
        };
        defer db.close();

        const kegs = db.listInstalled(alloc) catch &.{};
        defer if (kegs.len > 0) alloc.free(kegs);
        for (kegs) |keg| {
            var buf: [512]u8 = undefined;
            const cellar_path = std.fmt.bufPrint(&buf, "{s}/Cellar/{s}/{s}", .{ PREFIX, keg.name, keg.version }) catch continue;
            std.fs.accessAbsolute(cellar_path, .{}) catch {
                stdout.print("  ✗ DB entry '{s}' has no Cellar dir\n", .{keg.name}) catch {};
                issues += 1;
            };
        }

        if (std.fs.openDirAbsolute(ROOT ++ "/store", .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind != .directory) continue;
                var found = false;
                for (kegs) |keg| {
                    if (std.mem.eql(u8, keg.sha256, entry.name)) { found = true; break; }
                }
                if (!found) {
                    for (kegs) |keg| {
                        const hist = db.getHistory(keg.name);
                        for (hist) |h| {
                            if (std.mem.eql(u8, h.sha256, entry.name)) { found = true; break; }
                        }
                        if (found) break;
                    }
                }
                if (!found) {
                    stdout.print("  ✗ Orphaned store entry: {s}\n", .{entry.name}) catch {};
                    issues += 1;
                }
            }
        } else |_| {}
    }

    // 6. Platform-specific checks
    if (comptime builtin.os.tag == .linux) {
        // Check for patchelf (needed for ELF relocation)
        const pe = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "patchelf", "--version" },
        }) catch {
            stdout.print("  ✗ patchelf not found (needed for binary relocation)\n", .{}) catch {};
            stdout.print("    Install with: apt install patchelf\n", .{}) catch {};
            issues += 1;
            printDoctorSummary(stdout, issues);
            return;
        };
        alloc.free(pe.stdout);
        alloc.free(pe.stderr);
        if (pe.term.Exited == 0) {
            stdout.print("  ✓ patchelf installed\n", .{}) catch {};
        } else {
            stdout.print("  ✗ patchelf not working\n", .{}) catch {};
            issues += 1;
        }
    }

    printDoctorSummary(stdout, issues);
}

fn printDoctorSummary(stdout: anytype, issues: usize) void {
    if (issues == 0) {
        stdout.print("\n==> No issues found. Your nanobrew installation is healthy!\n", .{}) catch {};
    } else {
        stdout.print("\n==> Found {d} issue(s). Run `nb cleanup` to fix some of them.\n", .{issues}) catch {};
    }
}
// ── nb cleanup ──

fn runCleanup(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var dry_run = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) dry_run = true;
    }
    var reclaimed: u64 = 0;

    stdout.print("==> Cleaning up...\n", .{}) catch {};

    // 1. Clean cache dirs
    stdout.print("  Checking API cache...\n", .{}) catch {};
    cleanupCacheDir(ROOT ++ "/cache/api", dry_run, &reclaimed, stdout);

    stdout.print("  Checking token cache...\n", .{}) catch {};
    cleanupCacheDir(ROOT ++ "/cache/tokens", dry_run, &reclaimed, stdout);

    stdout.print("  Checking tmp files...\n", .{}) catch {};
    cleanupCacheDir(ROOT ++ "/cache/tmp", dry_run, &reclaimed, stdout);

    // 2. Orphaned blobs and store entries
    stdout.print("  Checking orphaned entries...\n", .{}) catch {};
    cleanupOrphans(alloc, dry_run, &reclaimed, stdout);

    if (reclaimed > 0) {
        const mb = @as(f64, @floatFromInt(reclaimed)) / (1024.0 * 1024.0);
        if (dry_run) {
            stdout.print("\n==> Would reclaim {d:.1} MB\n", .{mb}) catch {};
        } else {
            stdout.print("\n==> Reclaimed {d:.1} MB\n", .{mb}) catch {};
        }
    } else {
        stdout.print("\n==> Nothing to clean up\n", .{}) catch {};
    }
}

fn runNuke(args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) force = true;
    }

    stdout.print(
        "\n\x1b[31;1m  WARNING: This will completely remove nanobrew and all installed packages.\x1b[0m\n\n" ++
        "  The following will be deleted:\n" ++
        "    - /opt/nanobrew          (all packages, cache, database)\n" ++
        "    - ~/.local/bin/nb        (nanobrew binary)\n\n"
    , .{}) catch {};

    if (!force) {
        stdout.print("  Type \x1b[1myes\x1b[0m to confirm: ", .{}) catch {};

        var buf: [16]u8 = undefined;
        const stdin = std.fs.File.stdin();
        const n = stdin.read(&buf) catch {
            stderr.print("nb: failed to read input\n", .{}) catch {};
            std.process.exit(1);
        };
        const input = std.mem.trimRight(u8, buf[0..n], "\n\r \t");
        if (!std.mem.eql(u8, input, "yes")) {
            stdout.print("\n  Aborted.\n", .{}) catch {};
            return;
        }
    }

    stdout.print("\n==> Removing nanobrew...\n", .{}) catch {};

    // 1. Remove /opt/nanobrew
    stdout.print("  Removing /opt/nanobrew...\n", .{}) catch {};
    std.fs.deleteTreeAbsolute("/opt/nanobrew") catch |err| {
        stderr.print("nb: failed to remove /opt/nanobrew: {}\n", .{err}) catch {};
        stderr.print("nb: try: sudo nb nuke\n", .{}) catch {};
        std.process.exit(1);
    };

    // 2. Remove nb binary from ~/.local/bin
    stdout.print("  Removing ~/.local/bin/nb...\n", .{}) catch {};
    if (std.posix.getenv("HOME")) |home| {
        // Validate HOME to prevent path injection
        const home_valid = home.len > 0 and
            home[0] == '/' and
            std.mem.indexOf(u8, home, "..") == null;

        if (!home_valid) {
            stderr.print("nb: warning: HOME env var is invalid, skipping shell config cleanup\n", .{}) catch {};
        } else {
            // Verify HOME is an actual directory
            const home_is_dir = blk: {
                const stat = std.fs.cwd().statFile(home) catch break :blk false;
                break :blk stat.kind == .directory;
            };
            if (!home_is_dir) {
                stderr.print("nb: warning: HOME path does not exist or is not a directory, skipping shell config cleanup\n", .{}) catch {};
            } else {
                var path_buf: [512]u8 = undefined;
                const nb_path = std.fmt.bufPrint(&path_buf, "{s}/.local/bin/nb", .{home}) catch "";
                if (nb_path.len > 0) {
                    std.fs.deleteFileAbsolute(nb_path) catch {};
                }
            }
        }
    }

    stdout.print(
        "\n\x1b[32;1m  nanobrew has been removed.\x1b[0m\n\n" ++
        "  You may also want to remove the PATH entry from your shell config:\n" ++
        "    ~/.zshrc or ~/.bashrc — delete the line containing /opt/nanobrew\n\n"
    , .{}) catch {};
}

fn cleanupCacheDir(dir_path: []const u8, dry_run: bool, reclaimed: *u64, stdout: anytype) void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) continue;
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        reclaimed.* += 1024;
        if (dry_run) {
            stdout.print("  Would remove: {s}\n", .{entry.name}) catch {};
        } else {
            std.fs.deleteFileAbsolute(path) catch {};
        }
    }
}

fn cleanupOrphans(alloc: std.mem.Allocator, dry_run: bool, reclaimed: *u64, stdout: anytype) void {
    var db = nb.database.Database.open(alloc) catch return;
    defer db.close();

    const kegs = db.listInstalled(alloc) catch return;
    defer alloc.free(kegs);

    var valid_shas = std.StringHashMap(void).init(alloc);
    defer valid_shas.deinit();
    for (kegs) |keg| {
        if (keg.sha256.len > 0) valid_shas.put(keg.sha256, {}) catch {};
        const hist = db.getHistory(keg.name);
        for (hist) |h| {
            if (h.sha256.len > 0) valid_shas.put(h.sha256, {}) catch {};
        }
    }

    if (std.fs.openDirAbsolute(ROOT ++ "/cache/blobs", .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (!valid_shas.contains(entry.name)) {
                var path_buf: [1024]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/cache/blobs/{s}", .{ ROOT, entry.name }) catch continue;
                reclaimed.* += 10 * 1024 * 1024;
                if (dry_run) {
                    stdout.print("  Would remove orphaned blob: {s}\n", .{entry.name}) catch {};
                } else {
                    std.fs.deleteFileAbsolute(path) catch {};
                }
            }
        }
    } else |_| {}

    if (std.fs.openDirAbsolute(ROOT ++ "/store", .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!valid_shas.contains(entry.name)) {
                if (dry_run) {
                    stdout.print("  Would remove orphaned store entry: {s}\n", .{entry.name}) catch {};
                } else {
                    var path_buf: [1024]u8 = undefined;
                    const path = std.fmt.bufPrint(&path_buf, "{s}/store/{s}", .{ ROOT, entry.name }) catch continue;
                    std.fs.deleteTreeAbsolute(path) catch {};
                }
            }
        }
    } else |_| {}
}
// ── nb rollback ──

fn runRollback(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len == 0) {
        stderr.print("nb: no package specified\nUsage: nb rollback <package>\n", .{}) catch {};
        std.process.exit(1);
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    for (args) |name| {
        const keg = db.findKeg(name) orelse {
            stderr.print("nb: '{s}' is not installed\n", .{name}) catch {};
            continue;
        };

        const hist = db.getHistory(name);
        if (hist.len == 0) {
            stderr.print("nb: no previous version found for '{s}'\n", .{name}) catch {};
            continue;
        }

        const prev = hist[hist.len - 1];

        if (prev.sha256.len > 0 and !nb.store.hasEntry(prev.sha256)) {
            stderr.print("nb: store entry for previous version of '{s}' is missing\n", .{name}) catch {};
            continue;
        }

        stdout.print("==> Rolling back {s} ({s} -> {s})\n", .{ name, keg.version, prev.version }) catch {};

        nb.linker.unlinkKeg(name, keg.version) catch {};
        nb.cellar.remove(name, keg.version) catch {};

        if (prev.sha256.len > 0) {
            nb.cellar.materialize(prev.sha256, name, prev.version) catch |err| {
                stderr.print("nb: {s}: materialize failed: {}\n", .{ name, err }) catch {};
                continue;
            };
        }

        var ver_buf: [256]u8 = undefined;
        const actual_ver = nb.cellar.detectKegVersion(name, prev.version, &ver_buf) orelse prev.version;
        platform.relocate.relocateKeg(alloc, name, actual_ver) catch {};
        platform.relocate.replaceKegPlaceholders(name, actual_ver);
        nb.linker.linkKeg(name, actual_ver) catch {};
        db.recordInstall(name, prev.version, prev.sha256) catch {};

        stdout.print("==> Rolled back {s} to {s}\n", .{ name, prev.version }) catch {};
    }
}
// ── nb bundle ──

fn runBundle(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const subcmd = if (args.len > 0) args[0] else "dump";

    if (std.mem.eql(u8, subcmd, "dump")) {
        runBundleDump(alloc, stdout, stderr);
    } else if (std.mem.eql(u8, subcmd, "install")) {
        const file_path = if (args.len > 1) args[1] else "Nanobrew";
        runBundleInstall(alloc, file_path, stdout, stderr);
    } else {
        stderr.print("nb: unknown bundle subcommand '{s}'\nUsage: nb bundle [dump|install] [file]\n", .{subcmd}) catch {};
        std.process.exit(1);
    }
}

fn runBundleDump(alloc: std.mem.Allocator, stdout: anytype, stderr: anytype) void {
    _ = stderr;
    var db = nb.database.Database.open(alloc) catch {
        return;
    };
    defer db.close();

    const kegs = db.listInstalled(alloc) catch &.{};
    defer if (kegs.len > 0) alloc.free(kegs);
    const casks_result = db.listInstalledCasks(alloc);
    const casks_list: []const nb.database.CaskRecord = if (casks_result) |c| c else |_| &.{};
    defer if (casks_result) |c| alloc.free(c) else |_| {};

    stdout.print("# Nanobrew\n", .{}) catch {};
    for (kegs) |keg| {
        stdout.print("brew \"{s}\"\n", .{keg.name}) catch {};
    }
    for (casks_list) |c| {
        stdout.print("cask \"{s}\"\n", .{c.token}) catch {};
    }
}

fn runBundleInstall(alloc: std.mem.Allocator, file_path: []const u8, stdout: anytype, stderr: anytype) void {
    const file_content = std.fs.cwd().readFileAlloc(alloc, file_path, 1024 * 1024) catch {
        stderr.print("nb: could not read '{s}'\n", .{file_path}) catch {};
        return;
    };
    defer alloc.free(file_content);

    var formulas: std.ArrayList([]const u8) = .empty;
    defer formulas.deinit(alloc);
    var cask_tokens: std.ArrayList([]const u8) = .empty;
    defer cask_tokens.deinit(alloc);
    var skipped: usize = 0;

    var lines = std.mem.splitScalar(u8, file_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "brew \"")) {
            const after_q = trimmed[6..];
            if (std.mem.indexOf(u8, after_q, "\"")) |end| {
                const pkg_name = after_q[0..end];
                if (!isPackageNameSafe(pkg_name)) {
                    stderr.print("nb: skipping unsafe package name in Brewfile: {s}\n", .{pkg_name}) catch {};
                    skipped += 1;
                    continue;
                }
                formulas.append(alloc, pkg_name) catch {};
                // Check for args after the closing quote (e.g. brew "pkg", args: [...])
                const rest = after_q[end + 1 ..];
                const rest_trimmed = std.mem.trim(u8, rest, " \t\r");
                if (rest_trimmed.len > 0 and rest_trimmed[0] == ',') {
                    stderr.print("nb: warning: ignoring unsupported args for '{s}'\n", .{after_q[0..end]}) catch {};
                }
            }
        } else if (std.mem.startsWith(u8, trimmed, "cask \"")) {
            const after_q = trimmed[6..];
            if (std.mem.indexOf(u8, after_q, "\"")) |end| {
                const cask_name = after_q[0..end];
                if (!isPackageNameSafe(cask_name)) {
                    stderr.print("nb: skipping unsafe cask name in Brewfile: {s}\n", .{cask_name}) catch {};
                    skipped += 1;
                    continue;
                }
                cask_tokens.append(alloc, cask_name) catch {};
            }
        } else if (std.mem.startsWith(u8, trimmed, "tap \"")) {
            const after_q = trimmed[5..];
            if (std.mem.indexOf(u8, after_q, "\"")) |end| {
                stderr.print("nb: warning: taps not yet supported: {s}\n", .{after_q[0..end]}) catch {};
            }
            skipped += 1;
        } else if (std.mem.startsWith(u8, trimmed, "mas \"")) {
            stderr.print("nb: warning: Mac App Store not supported\n", .{}) catch {};
            skipped += 1;
        } else if (std.mem.startsWith(u8, trimmed, "vscode \"")) {
            stderr.print("nb: warning: VS Code extensions not supported\n", .{}) catch {};
            skipped += 1;
        } else {
            // Bare word: treat as formula name (backwards compat)
            // Validate it looks like a package name (alphanumeric, hyphens, underscores, @)
            var valid = trimmed.len > 0;
            for (trimmed) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '@' and ch != '/') {
                    valid = false;
                    break;
                }
            }
            if (valid) {
                formulas.append(alloc, trimmed) catch {};
            }
        }
    }

    // Fast path: check if all packages are already installed before calling
    // the full install pipeline (which does API fetches and dep resolution).
    // This makes no-op bundle installs instant (<100ms).
    var timer = std.time.Timer.start() catch null;

    var needs_formula: std.ArrayList([]const u8) = .empty;
    defer needs_formula.deinit(alloc);
    var needs_cask: std.ArrayList([]const u8) = .empty;
    defer needs_cask.deinit(alloc);

    // Check formulae against Cellar (same approach as runInstall)
    for (formulas.items) |name| {
        var check_buf: [512]u8 = undefined;
        const cellar_path = std.fmt.bufPrint(&check_buf, "/opt/nanobrew/prefix/Cellar/{s}", .{name}) catch {
            needs_formula.append(alloc, name) catch {};
            continue;
        };
        if (std.fs.openDirAbsolute(cellar_path, .{})) |d| {
            var dir = d;
            dir.close();
            // Already installed in Cellar, skip
        } else |_| {
            needs_formula.append(alloc, name) catch {};
        }
    }

    // Check casks against database
    if (cask_tokens.items.len > 0) blk: {
        var db = nb.database.Database.open(alloc) catch {
            // DB unavailable — assume all casks need install
            for (cask_tokens.items) |token| {
                needs_cask.append(alloc, token) catch {};
            }
            break :blk;
        };
        defer db.close();
        for (cask_tokens.items) |token| {
            if (db.findCask(token) != null) {
                continue; // Already installed
            }
            needs_cask.append(alloc, token) catch {};
        }
    }

    const total_parsed = formulas.items.len + cask_tokens.items.len;
    const total_needed = needs_formula.items.len + needs_cask.items.len;

    if (total_needed == 0) {
        const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        stdout.print("Already up to date ({d} packages)\n", .{total_parsed}) catch {};
        stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
        return;
    }

    stdout.print("==> Installing from bundle: {d} formulae, {d} casks ({d} already installed)\n", .{ needs_formula.items.len, needs_cask.items.len, total_parsed - total_needed }) catch {};

    if (needs_formula.items.len > 0) {
        runInstall(alloc, needs_formula.items);
    }
    if (needs_cask.items.len > 0) {
        runCaskInstall(alloc, needs_cask.items);
    }

    const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("Installed {d} formulae, {d} casks. Skipped {d} unsupported entries.\n", .{ needs_formula.items.len, needs_cask.items.len, skipped }) catch {};
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
}

// ── nb outdated ──

fn runOutdated(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    stdout.print("==> Checking for outdated packages...\n", .{}) catch {};
    var outdated = getOutdatedPackages(alloc, &db, &.{}, true, true);
    defer outdated.deinit(alloc);

    // Also check deb packages
    var deb_outdated: usize = 0;
    const installed_debs = db.listInstalledDebs(alloc) catch &.{};
    defer if (installed_debs.len > 0) alloc.free(installed_debs);

    if (installed_debs.len > 0) deb_check: {
        // Quick index fetch to compare versions
        const distro_info = nb.deb_distro.detect(alloc);
        const deb_arch = platform.deb_arch;

        var client: std.http.Client = .{ .allocator = alloc };
        defer client.deinit();

        var url_buf: [512]u8 = undefined;
        const index_url = std.fmt.bufPrint(&url_buf, "{s}/dists/{s}/main/binary-{s}/Packages.gz", .{
            distro_info.mirror, distro_info.codename, deb_arch,
        }) catch break :deb_check;

        const index_gz = httpGetToMemory(alloc, &client, index_url) orelse break :deb_check;
        defer alloc.free(index_gz);

        const index_data = nb.deb_extract.decompressGzip(alloc, index_gz) catch break :deb_check;
        defer alloc.free(index_data);

        const pkgs = nb.deb_index.parsePackagesIndex(alloc, index_data) catch break :deb_check;
        defer {
            for (pkgs) |p| p.deinit(alloc);
            alloc.free(pkgs);
        }

        var idx = nb.deb_index.buildIndex(alloc, pkgs) catch break :deb_check;
        defer idx.deinit();

        for (installed_debs) |deb| {
            if (idx.get(deb.name)) |idx_pkg| {
                if (nb.version.isNewer(idx_pkg.version, deb.version)) {
                    stdout.print("{s} ({s} -> {s}) (deb)\n", .{ deb.name, deb.version, idx_pkg.version }) catch {};
                    deb_outdated += 1;
                }
            }
        }
    }

    if (outdated.items.len == 0 and deb_outdated == 0) {
        stdout.print("All packages are up to date.\n", .{}) catch {};
        return;
    }

    for (outdated.items) |pkg| {
        const tag = if (pkg.is_cask_pkg) " (cask)" else "";
        const pin_tag = if (pkg.is_pinned) " [pinned]" else "";
        stdout.print("{s} ({s} -> {s}){s}{s}\n", .{ pkg.name, pkg.old_ver, pkg.new_ver, tag, pin_tag }) catch {};
    }

    stdout.print("\n==> {d} outdated package(s)\n", .{outdated.items.len + deb_outdated}) catch {};
}

// ── nb pin / nb unpin ──

fn runPin(alloc: std.mem.Allocator, args: []const []const u8, pin: bool) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (args.len == 0) {
        const verb = if (pin) "pin" else "unpin";
        stderr.print("nb: no package specified\nUsage: nb {s} <package>\n", .{verb}) catch {};
        std.process.exit(1);
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    for (args) |name| {
        db.setPinned(name, pin) catch |err| {
            if (err == error.NotFound) {
                stderr.print("nb: '{s}' is not installed\n", .{name}) catch {};
            } else {
                stderr.print("nb: failed to update '{s}': {}\n", .{ name, err }) catch {};
            }
            continue;
        };
        if (pin) {
            stdout.print("==> Pinned {s}\n", .{name}) catch {};
        } else {
            stdout.print("==> Unpinned {s}\n", .{name}) catch {};
        }
    }
}

// ── nb deps ──

fn runDeps(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var tree_mode = false;
    var formula_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--tree") or std.mem.eql(u8, arg, "-t")) {
            tree_mode = true;
        } else {
            formula_name = arg;
        }
    }

    const name = formula_name orelse {
        stderr.print("nb: no formula specified\nUsage: nb deps [--tree] <formula>\n", .{}) catch {};
        std.process.exit(1);
    };

    stdout.print("==> Resolving dependencies for {s}...\n", .{name}) catch {};

    var resolver = nb.deps.DepResolver.init(alloc);
    defer resolver.deinit();

    resolver.resolve(name) catch |err| {
        stderr.print("nb: failed to resolve '{s}': {}\n", .{ name, err }) catch {};
        std.process.exit(1);
    };

    if (tree_mode) {
        renderDepTree(stdout, &resolver, name, "", true);
    } else {
        const sorted = resolver.topologicalSort() catch {
            stderr.print("nb: dependency cycle detected\n", .{}) catch {};
            std.process.exit(1);
        };
        defer alloc.free(sorted);

        var count: usize = 0;
        for (sorted) |f| {
            if (std.mem.eql(u8, f.name, name)) continue;
            stdout.print("{s}\n", .{f.name}) catch {};
            count += 1;
        }
        if (count == 0) {
            stdout.print("(no dependencies)\n", .{}) catch {};
        }
    }
}

fn renderDepTree(stdout: anytype, resolver: *nb.deps.DepResolver, name: []const u8, prefix: []const u8, is_root: bool) void {
    if (is_root) {
        stdout.print("{s}\n", .{name}) catch {};
    }

    const empty_deps = &[_][]const u8{};
    const dep_list = resolver.edges.get(name) orelse empty_deps;
    for (dep_list, 0..) |dep, idx| {
        const is_last = (idx == dep_list.len - 1);
        const connector = if (is_last) "└── " else "├── ";
        stdout.print("{s}{s}{s}\n", .{ prefix, connector, dep }) catch {};

        var child_prefix_buf: [512]u8 = undefined;
        const extension = if (is_last) "    " else "│   ";
        const child_prefix = std.fmt.bufPrint(&child_prefix_buf, "{s}{s}", .{ prefix, extension }) catch continue;
        renderDepTree(stdout, resolver, dep, child_prefix, false);
    }
}

// ── nb services ──

fn runServices(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const subcmd = if (args.len > 0) args[0] else "list";
    const svc_name = if (args.len > 1) args[1] else null;

    const services_list = nb.services.discoverServices(alloc) catch {
        stderr.print("nb: failed to discover services\n", .{}) catch {};
        return;
    };
    defer alloc.free(services_list);

    if (std.mem.eql(u8, subcmd, "list")) {
        if (services_list.len == 0) {
            stdout.print("No services found.\n", .{}) catch {};
            return;
        }
        stdout.print("==> Services:\n", .{}) catch {};
        for (services_list) |svc| {
            const status = if (nb.services.isRunning(alloc, svc.label)) "running" else "stopped";
            stdout.print("  {s} ({s}) [{s}]\n", .{ svc.name, svc.keg_name, status }) catch {};
        }
    } else if (std.mem.eql(u8, subcmd, "start") or std.mem.eql(u8, subcmd, "stop") or std.mem.eql(u8, subcmd, "restart")) {
        const target = svc_name orelse {
            stderr.print("nb: no service specified\nUsage: nb services {s} <name>\n", .{subcmd}) catch {};
            return;
        };

        var found_svc: ?nb.services.Service = null;
        for (services_list) |svc| {
            if (std.mem.eql(u8, svc.name, target) or std.mem.eql(u8, svc.keg_name, target)) {
                found_svc = svc;
                break;
            }
        }

        const svc = found_svc orelse {
            stderr.print("nb: service '{s}' not found\n", .{target}) catch {};
            return;
        };

        if (std.mem.eql(u8, subcmd, "stop") or std.mem.eql(u8, subcmd, "restart")) {
            nb.services.stop(alloc, svc.plist_path) catch |err| {
                stderr.print("nb: failed to stop {s}: {}\n", .{ svc.name, err }) catch {};
                if (std.mem.eql(u8, subcmd, "stop")) return;
            };
            if (std.mem.eql(u8, subcmd, "stop")) {
                stdout.print("==> Stopped {s}\n", .{svc.name}) catch {};
                return;
            }
        }

        if (std.mem.eql(u8, subcmd, "start") or std.mem.eql(u8, subcmd, "restart")) {
            nb.services.start(alloc, svc.plist_path) catch |err| {
                stderr.print("nb: failed to start {s}: {}\n", .{ svc.name, err }) catch {};
                return;
            };
            stdout.print("==> Started {s}\n", .{svc.name}) catch {};
        }
    } else {
        stderr.print("nb: unknown services subcommand '{s}'\nUsage: nb services [list|start|stop|restart] [name]\n", .{subcmd}) catch {};
    }
}

// ── nb completions ──

fn runCompletions(args: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    const shell = if (args.len > 0) args[0] else "zsh";

    if (std.mem.eql(u8, shell, "zsh")) {
        stdout.print(
            \\#compdef nb
            \\
            \\_nb() {{
            \\  local -a commands
            \\  commands=(
            \\    'init:Create /opt/nanobrew/ directory tree'
            \\    'install:Install packages'
            \\    'remove:Uninstall packages'
            \\    'list:List installed packages'
            \\    'info:Show formula info'
            \\    'search:Search for packages'
            \\    'upgrade:Upgrade packages'
            \\    'update:Self-update nanobrew'
            \\    'doctor:Check installation health'
            \\    'cleanup:Remove stale caches'
            \\    'outdated:List outdated packages'
            \\    'pin:Pin a package'
            \\    'unpin:Unpin a package'
            \\    'rollback:Rollback to previous version'
            \\    'bundle:Export/import package lists'
            \\    'deps:Show dependency tree'
            \\    'services:Manage services'
            \\    'completions:Generate shell completions'
            \\    'help:Show help'
            \\  )
            \\  _describe 'command' commands
            \\}}
            \\
            \\compdef _nb nb
            \\
        , .{}) catch {};
    } else if (std.mem.eql(u8, shell, "bash")) {
        stdout.print(
            \\_nb_completions() {{
            \\  local commands="init install remove list info search upgrade update doctor cleanup outdated pin unpin rollback bundle deps services completions help"
            \\  COMPREPLY=($(compgen -W "$commands" -- "${{COMP_WORDS[COMP_CWORD]}}"))
            \\}}
            \\
            \\complete -F _nb_completions nb
            \\
        , .{}) catch {};
    } else if (std.mem.eql(u8, shell, "fish")) {
        stdout.print(
            \\complete -c nb -f
            \\complete -c nb -n '__fish_use_subcommand' -a 'init' -d 'Create /opt/nanobrew/ directory tree'
            \\complete -c nb -n '__fish_use_subcommand' -a 'install' -d 'Install packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'remove' -d 'Uninstall packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'list' -d 'List installed packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'info' -d 'Show formula info'
            \\complete -c nb -n '__fish_use_subcommand' -a 'search' -d 'Search for packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'upgrade' -d 'Upgrade packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'update' -d 'Self-update nanobrew'
            \\complete -c nb -n '__fish_use_subcommand' -a 'doctor' -d 'Check installation health'
            \\complete -c nb -n '__fish_use_subcommand' -a 'cleanup' -d 'Remove stale caches'
            \\complete -c nb -n '__fish_use_subcommand' -a 'outdated' -d 'List outdated packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'pin' -d 'Pin a package'
            \\complete -c nb -n '__fish_use_subcommand' -a 'unpin' -d 'Unpin a package'
            \\complete -c nb -n '__fish_use_subcommand' -a 'rollback' -d 'Rollback to previous version'
            \\complete -c nb -n '__fish_use_subcommand' -a 'bundle' -d 'Export/import package lists'
            \\complete -c nb -n '__fish_use_subcommand' -a 'deps' -d 'Show dependency tree'
            \\complete -c nb -n '__fish_use_subcommand' -a 'services' -d 'Manage services'
            \\complete -c nb -n '__fish_use_subcommand' -a 'completions' -d 'Generate shell completions'
            \\complete -c nb -n '__fish_use_subcommand' -a 'help' -d 'Show help'
            \\
        , .{}) catch {};
    } else {
        stderr.print("nb: unknown shell '{s}'\nUsage: nb completions [zsh|bash|fish]\n", .{shell}) catch {};
    }
}

// ── Version update check ──

const DebInstallOptions = struct {
    skip_postinst: bool = false,
    no_verify: bool = false,
};


/// Install .deb packages from Ubuntu/Debian repositories (Linux only).
fn runDebInstall(alloc: std.mem.Allocator, packages: []const []const u8, repo_spec: ?[]const u8, opts: DebInstallOptions) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (comptime builtin.os.tag != .linux) {
        stderr.print("nb: --deb is only supported on Linux\n", .{}) catch {};
        return;
    }

    var timer = std.time.Timer.start() catch null;

    // --- Step 1: Fetch + decompress package index natively ---
    stdout.print("==> Fetching package index...\n", .{}) catch {};

    // Use --repo override or auto-detect distro
    var mirror: []const u8 = undefined;
    var dist: []const u8 = undefined;
    const arch = platform.deb_arch;
    var components: []const []const u8 = undefined;

    if (repo_spec) |spec| {
        // Parse repo spec: "http://mirror/path codename comp1 comp2"
        var parts = std.mem.splitScalar(u8, spec, ' ');
        mirror = parts.next() orelse {
            stderr.print("nb: invalid --repo spec (expected: mirror codename component...)\n", .{}) catch {};
            return;
        };
        dist = parts.next() orelse "noble";
        var comp_list: std.ArrayList([]const u8) = .empty;
        defer comp_list.deinit(alloc);
        while (parts.next()) |comp| {
            comp_list.append(alloc, comp) catch {};
        }
        components = if (comp_list.items.len > 0)
            (comp_list.toOwnedSlice(alloc) catch &.{ "main", "universe" })
        else
            &.{ "main", "universe" };
    } else {
        const distro = nb.deb_distro.detect(alloc);
        mirror = distro.mirror;
        dist = distro.codename;
        components = nb.deb_distro.getComponents(distro.id);
    }

    // Validate mirror URL
    if (!std.mem.startsWith(u8, mirror, "http://") and !std.mem.startsWith(u8, mirror, "https://")) {
        stderr.print("nb: invalid mirror URL (must start with http:// or https://): {s}\n", .{mirror}) catch {};
        return;
    }
    for (mirror) |c| {
        if (c < 0x20 or c == 0x7f) {
            stderr.print("nb: invalid mirror URL (contains control characters)\n", .{}) catch {};
            return;
        }
    }
    // Strip trailing slashes
    while (mirror.len > 0 and mirror[mirror.len - 1] == '/') {
        mirror = mirror[0 .. mirror.len - 1];
    }

    stdout.print("    mirror={s} codename={s} arch={s}\n", .{ mirror, dist, arch }) catch {};

    // Native HTTP client — shared across all downloads (connection reuse)
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    // Fetch and merge package indices from all components (main + universe)
    var all_pkgs_list: std.ArrayList(nb.deb_index.DebPackage) = .empty;
    defer {
        for (all_pkgs_list.items) |p| p.deinit(alloc);
        all_pkgs_list.deinit(alloc);
    }

    for (components) |component| {
        var url_buf: [512]u8 = undefined;
        const index_url = std.fmt.bufPrint(&url_buf, "{s}/dists/{s}/{s}/binary-{s}/Packages.gz", .{
            mirror, dist, component, arch,
        }) catch continue;

        const index_gz = httpGetToMemory(alloc, &client, index_url) orelse {
            // universe may not exist on all mirrors — warn but continue
            stderr.print("nb: warning: failed to fetch {s} index\n", .{component}) catch {};
            continue;
        };
        defer alloc.free(index_gz);

        const index_data = nb.deb_extract.decompressGzip(alloc, index_gz) catch {
            stderr.print("nb: warning: failed to decompress {s} index\n", .{component}) catch {};
            continue;
        };
        defer alloc.free(index_data);

        const pkgs = nb.deb_index.parsePackagesIndex(alloc, index_data) catch continue;
        defer alloc.free(pkgs);

        for (pkgs) |pkg| {
            all_pkgs_list.append(alloc, pkg) catch continue;
        }
    }

    if (all_pkgs_list.items.len == 0) {
        stderr.print("nb: failed to fetch any package index\n", .{}) catch {};
        return;
    }

    stdout.print("==> Parsing package index ({d} packages)...\n", .{all_pkgs_list.items.len}) catch {};

    // --- Step 2: Parse index + resolve deps ---
    var index_map = nb.deb_index.buildIndex(alloc, all_pkgs_list.items) catch {
        stderr.print("nb: failed to build package index\n", .{}) catch {};
        return;
    };
    defer index_map.deinit();

    // Build virtual package → real package lookup
    var provides_map = nb.deb_index.buildProvidesMap(alloc, all_pkgs_list.items) catch blk: {
        stderr.print("nb: warning: failed to build provides map\n", .{}) catch {};
        break :blk std.StringHashMap([]const u8).init(alloc);
    };
    defer provides_map.deinit();

    stdout.print("==> Resolving dependencies for {d} package(s)...\n", .{packages.len}) catch {};

    const resolved = nb.deb_resolver.resolveAll(alloc, packages, index_map, provides_map) catch {
        stderr.print("nb: dependency resolution failed\n", .{}) catch {};
        return;
    };
    defer alloc.free(resolved);

    // --- Step 3: Download + extract (streaming SHA256 verification) ---
    stdout.print("==> Installing {d} package(s)...\n", .{resolved.len}) catch {};
    var installed: usize = 0;
    var cached: usize = 0;

    // Open database for tracking installed debs
    var db: ?nb.database.Database = nb.database.Database.open(alloc) catch null;
    defer if (db) |*d| d.close();

    for (resolved) |pkg| {
        // Validate package name — reject path traversal characters
        for (pkg.name) |c| {
            if (c == '/' or c == 0) {
                stderr.print("nb: refusing to install package with unsafe name: {s}\n", .{pkg.name}) catch {};
                continue;
            }
        }
        if (std.mem.indexOf(u8, pkg.name, "..") != null) {
            stderr.print("nb: refusing to install package with unsafe name: {s}\n", .{pkg.name}) catch {};
            continue;
        }

        var cache_buf: [512]u8 = undefined;
        var deb_path_for_postinst: ?[]const u8 = null;
        var file_list: [][]const u8 = &.{};

        // Content-addressable cache: check blob store by SHA256
        if (pkg.sha256.len > 0) {
            const cache_path = std.fmt.bufPrint(&cache_buf, "{s}/{s}.deb", .{ paths.BLOBS_DIR, pkg.sha256 }) catch continue;

            // Cache hit — extract directly from blob store
            if (std.fs.accessAbsolute(cache_path, .{})) |_| {
                file_list = nb.deb_extract.extractDebToPrefixWithFiles(alloc, cache_path) catch {
                    stderr.print("nb: failed to extract {s}\n", .{pkg.name}) catch {};
                    continue;
                };
                deb_path_for_postinst = cache_path;
                installed += 1;
                cached += 1;
            } else |_| {
                // Cache miss — download with native HTTP + streaming SHA256
                stdout.print("    {s}...\n", .{pkg.name}) catch {};
                var url_buf: [1024]u8 = undefined;
                const dl_url = std.fmt.bufPrint(&url_buf, "{s}/{s}", .{ mirror, pkg.filename }) catch continue;

                downloadDebWithSha256(&client, dl_url, pkg.sha256, cache_path) catch {
                    // Connection may have gone stale — retry with fresh client
                    var retry_client: std.http.Client = .{ .allocator = alloc };
                    defer retry_client.deinit();
                    downloadDebWithSha256(&retry_client, dl_url, pkg.sha256, cache_path) catch {
                        stderr.print("nb: failed to download {s}\n", .{pkg.name}) catch {};
                        continue;
                    };
                };

                // Extract from blob cache
                file_list = nb.deb_extract.extractDebToPrefixWithFiles(alloc, cache_path) catch {
                    stderr.print("nb: failed to extract {s}\n", .{pkg.name}) catch {};
                    continue;
                };
                deb_path_for_postinst = cache_path;
                installed += 1;
            }
        } else {
            // No SHA256 — refuse unless --no-verify is set
            if (!opts.no_verify) {
                stderr.print("nb: refusing to install {s} without checksum (use --no-verify to override)\n", .{pkg.name}) catch {};
                continue;
            }
            stderr.print("    warning: installing {s} WITHOUT checksum verification\n", .{pkg.name}) catch {};
            var tmp_buf: [512]u8 = undefined;
            const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}/{s}.deb", .{ paths.TMP_DIR, pkg.name }) catch continue;

            var url_buf: [1024]u8 = undefined;
            const dl_url = std.fmt.bufPrint(&url_buf, "{s}/{s}", .{ mirror, pkg.filename }) catch continue;

            downloadDebToFile(&client, dl_url, tmp_path) catch {
                var retry_client: std.http.Client = .{ .allocator = alloc };
                defer retry_client.deinit();
                downloadDebToFile(&retry_client, dl_url, tmp_path) catch {
                    stderr.print("nb: failed to download {s}\n", .{pkg.name}) catch {};
                    continue;
                };
            };

            file_list = nb.deb_extract.extractDebToPrefixWithFiles(alloc, tmp_path) catch {
                stderr.print("nb: failed to extract {s}\n", .{pkg.name}) catch {};
                std.fs.deleteFileAbsolute(tmp_path) catch {};
                continue;
            };
            deb_path_for_postinst = tmp_path;
            installed += 1;
        }

        // Run postinst script if available (non-fatal)
        if (deb_path_for_postinst) |deb_path| {
            nb.deb_extract.runPostinst(alloc, deb_path, pkg.name, opts.skip_postinst);
            // Clean up tmp file after postinst (cache files are kept)
            if (!std.mem.startsWith(u8, deb_path, paths.BLOBS_DIR)) {
                std.fs.deleteFileAbsolute(deb_path) catch {};
            }
        }

        // Record install in database
        if (db) |*d| {
            d.recordDebInstall(pkg.name, pkg.version, pkg.sha256, file_list) catch {};
        }
    }

    // Run ldconfig after all packages are installed (makes shared libs discoverable)
    if (installed > 0) {
        if (comptime builtin.os.tag == .linux) {
            const ld_result = std.process.Child.run(.{
                .allocator = alloc,
                .argv = &.{"ldconfig"},
            }) catch null;
            if (ld_result) |r| {
                if (r.term.Exited != 0) {
                    std.fs.File.stderr().deprecatedWriter().print("warning: ldconfig exited with code {d}\n", .{r.term.Exited}) catch {};
                }
                alloc.free(r.stdout);
                alloc.free(r.stderr);
            }
        }
    }

    const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    if (cached > 0) {
        stdout.print("==> Installed {d}/{d} packages ({d} cached) in {d:.1}ms\n", .{ installed, resolved.len, cached, elapsed_ms }) catch {};
    } else {
        stdout.print("==> Installed {d}/{d} packages in {d:.1}ms\n", .{ installed, resolved.len, elapsed_ms }) catch {};
    }
}

fn runDebRemove(alloc: std.mem.Allocator, packages: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    for (packages) |name| {
        const record = db.findDeb(name) orelse {
            stderr.print("nb: '{s}' is not installed (deb)\n", .{name}) catch {};
            continue;
        };

        // Delete each installed file
        var removed_files: usize = 0;
        for (record.files) |file_path| {
            std.fs.deleteFileAbsolute(file_path) catch continue;
            removed_files += 1;
        }

        db.recordDebRemoval(name) catch {};
        stdout.print("==> Removed {s} ({d} files)\n", .{ name, removed_files }) catch {};
    }

    // Run ldconfig after removal
    if (comptime builtin.os.tag == .linux) {
        const ld_result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{"ldconfig"},
        }) catch null;
        if (ld_result) |r| {
            alloc.free(r.stdout);
            alloc.free(r.stderr);
        }
    }
}

fn runDebUpgrade(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    const installed_debs = db.listInstalledDebs(alloc) catch {
        stderr.print("nb: failed to list installed debs\n", .{}) catch {};
        return;
    };
    defer alloc.free(installed_debs);

    if (installed_debs.len == 0) {
        stdout.print("No deb packages installed.\n", .{}) catch {};
        return;
    }

    // Re-fetch package index to compare versions
    const distro = nb.deb_distro.detect(alloc);
    const mirror = distro.mirror;
    const dist = distro.codename;
    const arch = platform.deb_arch;
    const components = nb.deb_distro.getComponents(distro.id);

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var all_pkgs_list: std.ArrayList(nb.deb_index.DebPackage) = .empty;
    defer {
        for (all_pkgs_list.items) |p| p.deinit(alloc);
        all_pkgs_list.deinit(alloc);
    }

    for (components) |component| {
        var url_buf: [512]u8 = undefined;
        const index_url = std.fmt.bufPrint(&url_buf, "{s}/dists/{s}/{s}/binary-{s}/Packages.gz", .{
            mirror, dist, component, arch,
        }) catch continue;

        const index_gz = httpGetToMemory(alloc, &client, index_url) orelse continue;
        defer alloc.free(index_gz);

        const index_data = nb.deb_extract.decompressGzip(alloc, index_gz) catch continue;
        defer alloc.free(index_data);

        const pkgs = nb.deb_index.parsePackagesIndex(alloc, index_data) catch continue;
        defer alloc.free(pkgs);

        for (pkgs) |pkg| {
            all_pkgs_list.append(alloc, pkg) catch continue;
        }
    }

    var index_map = nb.deb_index.buildIndex(alloc, all_pkgs_list.items) catch {
        stderr.print("nb: failed to build package index\n", .{}) catch {};
        return;
    };
    defer index_map.deinit();

    // Find outdated packages
    var outdated: std.ArrayList(struct { name: []const u8, old_ver: []const u8, new_ver: []const u8 }) = .empty;
    defer outdated.deinit(alloc);

    for (installed_debs) |deb| {
        if (index_map.get(deb.name)) |idx_pkg| {
            if (nb.version.isNewer(idx_pkg.version, deb.version)) {
                outdated.append(alloc, .{
                    .name = deb.name,
                    .old_ver = deb.version,
                    .new_ver = idx_pkg.version,
                }) catch {};
            }
        }
    }

    if (outdated.items.len == 0) {
        stdout.print("==> All deb packages are up to date.\n", .{}) catch {};
        return;
    }

    stdout.print("==> Upgrading {d} deb package(s):\n", .{outdated.items.len}) catch {};
    for (outdated.items) |pkg| {
        stdout.print("    {s} ({s} -> {s})\n", .{ pkg.name, pkg.old_ver, pkg.new_ver }) catch {};
    }

    // Re-install outdated packages (will overwrite files and update database)
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for (outdated.items) |pkg| {
        names.append(alloc, pkg.name) catch {};
    }

    runDebInstall(alloc, names.items, null, .{});
}

/// Download a URL to memory using Zig's native HTTP client.
fn httpGetToMemory(alloc: std.mem.Allocator, client: *std.http.Client, url: []const u8) ?[]u8 {
    const uri = std.Uri.parse(url) catch return null;
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
    }) catch return null;
    defer req.deinit();

    req.sendBodiless() catch return null;

    var redirect_buf: [16384]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return null;
    if (response.head.status != .ok) return null;

    // Stream response body to memory
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch return null;
    return out.toOwnedSlice() catch return null;
}

/// Download a .deb with streaming SHA256 verification to content-addressable cache.
fn downloadDebWithSha256(
    client: *std.http.Client,
    url: []const u8,
    expected_sha256: []const u8,
    dest_path: []const u8,
) !void {
    const uri = std.Uri.parse(url) catch return error.DownloadFailed;
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
    }) catch return error.DownloadFailed;
    defer req.deinit();

    req.sendBodiless() catch return error.DownloadFailed;

    var redirect_buf: [16384]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.DownloadFailed;
    if (response.head.status != .ok) return error.DownloadFailed;

    // Stream to tmp file with SHA256 hashing in single pass
    var tmp_buf: [600]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.dl", .{dest_path}) catch return error.DownloadFailed;

    {
        var file = std.fs.createFileAbsolute(tmp_path, .{}) catch return error.DownloadFailed;
        var file_writer_buf: [65536]u8 = undefined;
        var file_writer = file.writer(&file_writer_buf);

        var reader = response.reader(&.{});
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var hash_buf: [65536]u8 = undefined;
        var hashed = reader.hashed(&hasher, &hash_buf);

        _ = hashed.reader.streamRemaining(&file_writer.interface) catch {
            file.close();
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.DownloadFailed;
        };
        file_writer.interface.flush() catch {
            file.close();
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.DownloadFailed;
        };
        file.close();

        // Verify SHA256 — always required
        if (expected_sha256.len < 64) {
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.ChecksumMissing;
        }
        const digest = hasher.finalResult();
        const charset = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, idx| {
            hex[idx * 2] = charset[byte >> 4];
            hex[idx * 2 + 1] = charset[byte & 0x0f];
        }
        if (expected_sha256.len < 64) {
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.ChecksumMissing;
        }
        if (!std.mem.eql(u8, &hex, expected_sha256[0..64])) {
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return error.ChecksumMismatch;
        }
    }

    // Atomic rename to blob cache
    std.fs.renameAbsolute(tmp_path, dest_path) catch |err| {
        if (err == error.PathAlreadyExists) {
            // Race condition fix (#15): verify existing file's SHA256 before trusting it
            const existing_ok = blk: {
                var existing = std.fs.openFileAbsolute(dest_path, .{}) catch break :blk false;
                defer existing.close();
                var verify_hasher = std.crypto.hash.sha2.Sha256.init(.{});
                var read_buf: [65536]u8 = undefined;
                while (true) {
                    const bytes_read = existing.read(&read_buf) catch break :blk false;
                    if (bytes_read == 0) break;
                    verify_hasher.update(read_buf[0..bytes_read]);
                }
                const verify_digest = verify_hasher.finalResult();
                const charset2 = "0123456789abcdef";
                var verify_hex: [64]u8 = undefined;
                for (verify_digest, 0..) |byte, idx| {
                    verify_hex[idx * 2] = charset2[byte >> 4];
                    verify_hex[idx * 2 + 1] = charset2[byte & 0x0f];
                }
                break :blk (expected_sha256.len >= 64 and std.mem.eql(u8, &verify_hex, expected_sha256[0..64]));
            };
            if (existing_ok) {
                // Existing file matches — clean up tmp and return success
                std.fs.deleteFileAbsolute(tmp_path) catch {};
                return;
            }
            // Existing file is corrupt — delete it and retry the rename
            std.fs.deleteFileAbsolute(dest_path) catch {};
            std.fs.renameAbsolute(tmp_path, dest_path) catch {
                std.fs.deleteFileAbsolute(tmp_path) catch {};
                return error.DownloadFailed;
            };
            return;
        }
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return error.DownloadFailed;
    };
}

/// Download a URL to a file using Zig's native HTTP client (no SHA256 check).
fn downloadDebToFile(
    client: *std.http.Client,
    url: []const u8,
    dest_path: []const u8,
) !void {
    const uri = std.Uri.parse(url) catch return error.DownloadFailed;
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(3),
    }) catch return error.DownloadFailed;
    defer req.deinit();

    req.sendBodiless() catch return error.DownloadFailed;

    var redirect_buf: [16384]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.DownloadFailed;
    if (response.head.status != .ok) return error.DownloadFailed;

    var file = std.fs.createFileAbsolute(dest_path, .{}) catch return error.DownloadFailed;
    var file_writer_buf: [65536]u8 = undefined;
    var file_writer = file.writer(&file_writer_buf);

    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&file_writer.interface) catch {
        file.close();
        std.fs.deleteFileAbsolute(dest_path) catch {};
        return error.DownloadFailed;
    };
    file_writer.interface.flush() catch {
        file.close();
        std.fs.deleteFileAbsolute(dest_path) catch {};
        return error.DownloadFailed;
    };
    file.close();
}

fn checkForUpdate(alloc: std.mem.Allocator) void {
    const cache_path = ROOT ++ "/cache/last_update_check";
    const now = std.time.timestamp();

    // Only check once per day (86400 seconds)
    if (std.fs.openFileAbsolute(cache_path, .{})) |f| {
        defer f.close();
        var buf: [32]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        if (n > 0) {
            const last_check = std.fmt.parseInt(i64, std.mem.trimRight(u8, buf[0..n], "\n \t"), 10) catch 0;
            if (now - last_check < 86400) return;
        }
    } else |_| {}

    // Write current timestamp (best-effort)
    if (std.fs.createFileAbsolute(cache_path, .{})) |f| {
        defer f.close();
        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now}) catch return;
        f.writeAll(ts_str) catch {};
    } else |_| {}

    // Fetch latest version from Cloudflare worker (native HTTP, no curl)
    const body = nb.fetch.get(alloc, "https://nanobrew.trilok.ai/version") catch return;
    defer alloc.free(body);


    const latest_ver = std.mem.trimRight(u8, body, "\n \t");
    if (latest_ver.len == 0 or std.mem.eql(u8, latest_ver, "error")) return;

    // Cache latest version for getDisplayVersion()
    if (std.fs.createFileAbsolute(ROOT ++ "/cache/latest_version", .{})) |vf| {
        defer vf.close();
        vf.writeAll(latest_ver) catch {};
    } else |_| {}

    // Compare with current version
    if (std.mem.eql(u8, latest_ver, VERSION)) return;

    // New version available — print colored banner
    const stdout = std.fs.File.stdout().deprecatedWriter();
    stdout.print(
        "\n\x1b[33m╭─────────────────────────────────────────╮\x1b[0m\n" ++
        "\x1b[33m│\x1b[0m  \x1b[1mUpdate available!\x1b[0m " ++
        "\x1b[90m{s}\x1b[0m → \x1b[32;1m{s}\x1b[0m" ++
        "{s}" ++
        "  \x1b[33m│\x1b[0m\n" ++
        "\x1b[33m│\x1b[0m  Run \x1b[36;1mnb update\x1b[0m to upgrade" ++
        "                \x1b[33m│\x1b[0m\n" ++
        "\x1b[33m╰─────────────────────────────────────────╯\x1b[0m\n"
    , .{
        VERSION,
        latest_ver,
        padSpaces(VERSION.len + latest_ver.len),
    }) catch {};
}

fn padSpaces(used: usize) []const u8 {
    const target = 19;
    if (used >= target) return "";
    const spaces = "                   ";
    return spaces[0 .. target - used];
}

fn runMigrate(alloc: std.mem.Allocator) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();

    var formula_count: usize = 0;
    var cask_count: usize = 0;

    // Scan Homebrew Cellar directories for formulae
    const cellar_paths = [_][]const u8{ "/opt/homebrew/Cellar", "/usr/local/Cellar" };
    for (cellar_paths) |cellar_path| {
        var cellar_dir = std.fs.openDirAbsolute(cellar_path, .{ .iterate = true }) catch continue;
        defer cellar_dir.close();

        var formula_iter = cellar_dir.iterate();
        while (formula_iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.name;

            // Open the formula directory to find version subdirectories
            var formula_dir = cellar_dir.openDir(name, .{ .iterate = true }) catch continue;
            defer formula_dir.close();

            var ver_iter = formula_dir.iterate();
            while (ver_iter.next() catch null) |ver_entry| {
                if (ver_entry.kind != .directory) continue;
                const version = ver_entry.name;

                db.recordInstall(name, version, "") catch {
                    stderr.print("nb: failed to record {s} {s}\n", .{ name, version }) catch {};
                    continue;
                };
                stdout.print("Migrated: {s} {s}\n", .{ name, version }) catch {};
                formula_count += 1;
            }
        }
    }

    // Scan Homebrew Caskroom directories for casks
    const caskroom_paths = [_][]const u8{ "/opt/homebrew/Caskroom", "/usr/local/Caskroom" };
    for (caskroom_paths) |caskroom_path| {
        var caskroom_dir = std.fs.openDirAbsolute(caskroom_path, .{ .iterate = true }) catch continue;
        defer caskroom_dir.close();

        var cask_iter = caskroom_dir.iterate();
        while (cask_iter.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const token = entry.name;

            var cask_dir = caskroom_dir.openDir(token, .{ .iterate = true }) catch continue;
            defer cask_dir.close();

            var ver_iter = cask_dir.iterate();
            while (ver_iter.next() catch null) |ver_entry| {
                if (ver_entry.kind != .directory) continue;
                const version = ver_entry.name;

                const empty_apps: []const []const u8 = &.{};
                const empty_bins: []const []const u8 = &.{};
                db.recordCaskInstall(token, version, empty_apps, empty_bins) catch {
                    stderr.print("nb: failed to record cask {s} {s}\n", .{ token, version }) catch {};
                    continue;
                };
                stdout.print("Migrated: {s} {s} (cask)\n", .{ token, version }) catch {};
                cask_count += 1;
            }
        }
    }

    stdout.print("\nMigrated {d} formulae and {d} casks from Homebrew\n", .{ formula_count, cask_count }) catch {};
}
