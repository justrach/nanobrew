// nanobrew — Faster-than-zerobrew Homebrew replacement
//
// Usage:
//   nb init                    # Create /opt/nanobrew/ directory tree
//   nb install <formula> ...   # Install packages with full dep resolution
//   nb remove <formula> ...    # Uninstall packages
//   nb list                    # List installed packages
//   nb info <name>              # Show formula/cask info from Homebrew API
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
        .{ "remove", Command.remove },
        .{ "uninstall", Command.remove },
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

    const install_order = resolver.topologicalSort() catch {
        stderr.print("nb: dependency cycle detected\n", .{}) catch {};
        std.process.exit(1);
    };

    stdout.print("==> Installing {d} package(s):\n", .{install_order.len}) catch {};
    for (install_order) |f| {
        stdout.print("    {s} {s}\n", .{ f.name, f.version }) catch {};
    }

    // Phase 2: Download bottles
    stdout.print("==> Downloading bottles...\n", .{}) catch {};
    var dl = nb.downloader.ParallelDownloader.init(alloc);
    defer dl.deinit();

    for (install_order) |f| {
        dl.enqueue(f.bottleUrl(), f.bottle_sha256) catch |err| {
            stderr.print("nb: enqueue failed for {s}: {}\n", .{ f.name, err }) catch {};
        };
    }
    dl.downloadAll() catch |err| {
        stderr.print("nb: download failed: {}\n", .{err}) catch {};
        std.process.exit(1);
    };

    // Phase 3: Extract into store
    stdout.print("==> Extracting...\n", .{}) catch {};
    for (install_order) |f| {
        const blob_path = nb.blob_cache.blobPath(f.bottle_sha256);
        nb.store.ensureEntry(alloc, blob_path, f.bottle_sha256) catch |err| {
            stderr.print("nb: extract failed for {s}: {}\n", .{ f.name, err }) catch {};
        };
    }

    // Phase 4: Materialize into Cellar
    stdout.print("==> Installing...\n", .{}) catch {};
    for (install_order) |f| {
        var ver_buf: [128]u8 = undefined;
        const ver = f.effectiveVersion(&ver_buf);
        nb.cellar.materialize(f.bottle_sha256, f.name, ver) catch |err| {
            stderr.print("nb: materialize failed for {s}: {}\n", .{ f.name, err }) catch {};
        };
    }

    // Phase 5: Link binaries
    stdout.print("==> Linking...\n", .{}) catch {};
    for (install_order) |f| {
        var ver_buf: [128]u8 = undefined;
        const ver = f.effectiveVersion(&ver_buf);
        nb.linker.linkKeg(f.name, ver) catch |err| {
            stderr.print("nb: link failed for {s}: {}\n", .{ f.name, err }) catch {};
        };
    }

    // Phase 6: Record in database
    var db = nb.database.Database.open() catch {
        stderr.print("nb: warning: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();
    for (install_order) |f| {
        var ver_buf: [128]u8 = undefined;
        const ver = f.effectiveVersion(&ver_buf);
        db.recordInstall(f.name, ver, f.bottle_sha256) catch {};
    }

    const elapsed_ns: u64 = if (timer) |*t| t.read() else 0;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
}

// ── nb remove ──

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
        stderr.print("nb: no formula or cask specified\n", .{}) catch {};
        std.process.exit(1);
    }

    for (formulae) |name| {
        // Try formula first
        if (nb.api_client.fetchFormula(alloc, name)) |f| {
            stdout.print("{s} {s}\n", .{ f.name, f.version }) catch {};
            if (f.desc.len > 0) stdout.print("  {s}\n", .{f.desc}) catch {};
            stdout.print("  deps: ", .{}) catch {};
            for (f.dependencies, 0..) |dep, i| {
                if (i > 0) stdout.print(", ", .{}) catch {};
                stdout.print("{s}", .{dep}) catch {};
            }
            stdout.print("\n", .{}) catch {};
        } else |_| {
            // Try cask
            if (nb.cask_client.fetchCask(alloc, name)) |c| {
                stdout.print("{s} ({s}) {s}\n", .{ c.token, c.name, c.version }) catch {};
                if (c.desc.len > 0) stdout.print("  {s}\n", .{c.desc}) catch {};
                if (c.homepage.len > 0) stdout.print("  {s}\n", .{c.homepage}) catch {};
            } else |_| {
                stderr.print("nb: '{s}' not found as formula or cask\n", .{name}) catch {};
            }
        }
    }
}

// ── nb upgrade ──

fn runUpgrade(alloc: std.mem.Allocator, formulae: []const []const u8) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    var db = nb.database.Database.open() catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    // If specific formulae given, upgrade those; otherwise upgrade all installed
    const targets: []const nb.database.Keg = if (formulae.len > 0) blk: {
        var list: std.ArrayList(nb.database.Keg) = .empty;
        for (formulae) |name| {
            if (db.findKeg(name)) |keg| {
                list.append(alloc, keg) catch {};
            } else {
                stderr.print("nb: '{s}' is not installed\n", .{name}) catch {};
            }
        }
        break :blk list.items;
    } else blk: {
        break :blk db.listInstalled(alloc) catch {
            stderr.print("nb: failed to list packages\n", .{}) catch {};
            return;
        };
    };

    if (targets.len == 0) {
        stdout.print("No packages to upgrade.\n", .{}) catch {};
        return;
    }

    var upgraded: u32 = 0;
    for (targets) |keg| {
        const remote = nb.api_client.fetchFormula(alloc, keg.name) catch {
            stderr.print("nb: could not fetch info for '{s}'\n", .{keg.name}) catch {};
            continue;
        };

        const installed_ver = keg.version;

        // Build effective remote version
        var remote_buf: [128]u8 = undefined;
        const remote_ver = remote.effectiveVersion(&remote_buf);

        if (!nb.version.isNewer(installed_ver, remote_ver)) {
            stdout.print("{s} {s} (up to date)\n", .{ keg.name, installed_ver }) catch {};
            continue;
        }

        stdout.print("==> Upgrading {s} {s} -> {s}\n", .{ keg.name, installed_ver, remote_ver }) catch {};

        // Download
        var dl = nb.downloader.ParallelDownloader.init(alloc);
        defer dl.deinit();
        dl.enqueue(remote.bottleUrl(), remote.bottle_sha256) catch {
            stderr.print("nb: download enqueue failed for {s}\n", .{keg.name}) catch {};
            continue;
        };
        dl.downloadAll() catch {
            stderr.print("nb: download failed for {s}\n", .{keg.name}) catch {};
            continue;
        };

        // Extract
        const blob_path = nb.blob_cache.blobPath(remote.bottle_sha256);
        nb.store.ensureEntry(alloc, blob_path, remote.bottle_sha256) catch {
            stderr.print("nb: extract failed for {s}\n", .{keg.name}) catch {};
            continue;
        };

        // Unlink old, materialize new, relink
        nb.linker.unlinkKeg(keg.name, keg.version) catch {};
        nb.cellar.remove(keg.name, keg.version) catch {};
        nb.cellar.materialize(remote.bottle_sha256, remote.name, remote_ver) catch {
            stderr.print("nb: materialize failed for {s}\n", .{keg.name}) catch {};
            continue;
        };
        nb.linker.linkKeg(remote.name, remote_ver) catch {
            stderr.print("nb: link failed for {s}\n", .{keg.name}) catch {};
            continue;
        };
        db.recordInstall(remote.name, remote_ver, remote.bottle_sha256) catch {};
        upgraded += 1;
    }

    if (upgraded == 0) {
        stdout.print("All packages are up to date.\n", .{}) catch {};
    } else {
        stdout.print("==> Upgraded {d} package(s)\n", .{upgraded}) catch {};
    }
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
        \\  info <name>         Show formula or cask info from Homebrew API
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
