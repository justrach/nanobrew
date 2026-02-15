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
        nb.cellar.materialize(f.bottle_sha256, f.name, f.version) catch |err| {
            stderr.print("nb: materialize failed for {s}: {}\n", .{ f.name, err }) catch {};
        };
    }

    // Phase 5: Link binaries
    stdout.print("==> Linking...\n", .{}) catch {};
    for (install_order) |f| {
        nb.linker.linkKeg(f.name, f.version) catch |err| {
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
        db.recordInstall(f.name, f.version, f.bottle_sha256) catch {};
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
