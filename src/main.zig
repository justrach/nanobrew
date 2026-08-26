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
    reinstall,
    list,
    leaves,
    info,
    search,
    where,
    upgrade,
    update,
    update_registry,
    help,
    doctor,
    cleanup,
    outdated,
    pin,
    unpin,
    rollback,
    switch_version,
    link,
    unlink,
    bundle,
    deps,
    services,
    completions,
    telemetry,
    nuke,
    migrate,
};

fn shouldCheckForUpdate(cmd: Command) bool {
    // Keep the advisory on package-changing entry points, where its occasional
    // network refresh is negligible. Output-only and local maintenance commands
    // must never gain unrelated DNS/TLS tail latency after their work is done.
    return switch (cmd) {
        .init, .install, .reinstall, .upgrade => true,
        else => false,
    };
}

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

const ProbeMode = enum { structural, active };

const ProbeResult = enum(u8) {
    not_run,
    failed,
    passed,

    fn value(self: ProbeResult) ?bool {
        return switch (self) {
            .not_run => null,
            .failed => false,
            .passed => true,
        };
    }
};

// Persisted probe evidence is valid only for the platform and semantics that
// produced it. Bump the schema whenever probe acceptance rules materially change.
const LOCAL_PROBE_SCHEMA: u32 = 3;
const LOCAL_PROBE_PLATFORM: u32 = switch (builtin.os.tag) {
    .macos => switch (builtin.cpu.arch) {
        .aarch64 => 1,
        .x86_64 => 2,
        else => 0,
    },
    .linux => switch (builtin.cpu.arch) {
        .x86_64 => 3,
        .aarch64 => 4,
        else => 0,
    },
    else => 0,
};

var g_io: std.Io = undefined;

const StderrWriter = struct {
    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        _ = self;
        const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
        defer std.heap.smp_allocator.free(msg);
        std.Io.File.stderr().writeStreamingAll(g_io, msg) catch {};
    }
};
const StdoutWriter = struct {
    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        _ = self;
        const msg = std.fmt.allocPrint(std.heap.smp_allocator, fmt, args) catch return;
        defer std.heap.smp_allocator.free(msg);
        std.Io.File.stdout().writeStreamingAll(g_io, msg) catch {};
    }
};

const MonoTimer = struct {
    start_ns: u64,

    fn start() MonoTimer {
        return .{ .start_ns = monoNs() };
    }

    fn read(self: MonoTimer) u64 {
        return monoNs() - self.start_ns;
    }
};

fn monoNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn monoUnixSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const sec: i64 = @intCast(ts.sec);
    const nsec: i64 = @intCast(ts.nsec);
    return sec * 1000 + @divTrunc(nsec, 1_000_000);
}

const ROOT = paths.ROOT;
const PREFIX = paths.PREFIX;
const VERSION = "0.1.208";

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    // Publish a process-wide threadsafe Io for code paths called from
    // worker threads (downloader workers, api/client cache writers,
    // leaves/outdated checkers, etc.) that previously hit
    // `paths.safe_io` and crashed under
    // concurrent use. See paths.zig for the full rationale.
    paths.safe_io = init.io;
    const alloc = init.gpa;

    const args_raw = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try init.arena.allocator().alloc([]const u8, args_raw.len);
    for (args, args_raw) |*dst, src| dst.* = src;

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const cmd = parseCommand(args[1]) orelse {
        const stderr = StderrWriter{};
        stderr.print("nb: unknown command '{s}'\n\n", .{args[1]}) catch {};
        printUsage();
        std.process.exit(1);
    };

    switch (cmd) {
        .init => runInit(),
        .install => runInstall(alloc, args[2..]),
        .remove => runRemove(alloc, args[2..]),
        .reinstall => {
            runRemove(alloc, args[2..]);
            runInstall(alloc, args[2..]);
        },
        .list => runList(alloc, args[2..]),
        .leaves => runLeaves(alloc, args[2..]),
        .info => runInfo(alloc, args[2..]),
        .search => runSearch(alloc, args[2..]),
        .where => runWhere(alloc, args[2..]),
        .upgrade => runUpgrade(alloc, args[2..]),
        .update => runUpdate(alloc),
        .update_registry => runUpdateRegistry(alloc),
        .help => printUsage(),
        .doctor => runDoctor(alloc, args[2..]),
        .cleanup => runCleanup(alloc, args[2..]),
        .outdated => runOutdated(alloc),
        .pin => runPin(alloc, args[2..], true),
        .unpin => runPin(alloc, args[2..], false),
        .rollback => runRollback(alloc, args[2..]),
        .switch_version => runSwitch(alloc, args[2..]),
        .link => runLink(alloc, args[2..]),
        .unlink => runUnlink(alloc, args[2..]),
        .bundle => runBundle(alloc, args[2..]),
        .deps => runDeps(alloc, args[2..]),
        .services => runServices(alloc, args[2..]),
        .completions => runCompletions(args[2..]),
        .telemetry => runTelemetry(args[2..]),
        .nuke => runNuke(args[2..]),
        .migrate => runMigrate(alloc),
    }

    // The best-effort update request must not delay output-only commands.
    // Self-update also skips it to avoid a stale VERSION banner.
    if (shouldCheckForUpdate(cmd)) checkForUpdate(alloc);

    // Terminate immediately on success. Returning from main lets the Zig
    // runtime tear down the global `std.Io.Threaded` instance, and its
    // worker-pool future cancellation can SIGSEGV during group teardown on
    // Zig 0.16.0 (the crash reported in #298 fires *after* "Done"). All of our
    // output is written unbuffered straight to the underlying file, so there
    // is nothing to flush before exit.
    std.process.exit(0);
}

test "shouldCheckForUpdate only runs on package-changing entry points" {
    try std.testing.expect(shouldCheckForUpdate(.init));
    try std.testing.expect(shouldCheckForUpdate(.install));
    try std.testing.expect(shouldCheckForUpdate(.reinstall));
    try std.testing.expect(shouldCheckForUpdate(.upgrade));

    inline for (.{
        Command.update,
        Command.list,
        Command.leaves,
        Command.outdated,
        Command.help,
        Command.info,
        Command.search,
        Command.where,
        Command.doctor,
        Command.deps,
        Command.completions,
    }) |cmd| {
        try std.testing.expect(!shouldCheckForUpdate(cmd));
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
        .{ "leaves", Command.leaves },
        .{ "info", Command.info },
        .{ "search", Command.search },
        .{ "s", Command.search },
        .{ "where", Command.where },
        .{ "wh", Command.where },
        .{ "upgrade", Command.upgrade },
        .{ "update", Command.update },
        .{ "self-update", Command.update },
        .{ "update-registry", Command.update_registry },
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
        .{ "switch", Command.switch_version },
        .{ "link", Command.link },
        .{ "unlink", Command.unlink },
        .{ "bundle", Command.bundle },
        .{ "deps", Command.deps },
        .{ "services", Command.services },
        .{ "service", Command.services },
        .{ "telemetry", Command.telemetry },
        .{ "completions", Command.completions },
        .{ "nuke", Command.nuke },
        .{ "uninstall-self", Command.nuke },
        .{ "migrate", Command.migrate },
        .{ "reinstall", Command.reinstall },
    };
    inline for (cmds) |pair| {
        if (std.mem.eql(u8, arg, pair[0])) return pair[1];
    }
    return null;
}

// ── nb init ──

fn runInit() void {
    const stdout = StdoutWriter{};

    const dirs = [_][]const u8{
        ROOT,
        ROOT ++ "/store",
        PREFIX,
        PREFIX ++ "/Cellar",
        PREFIX ++ "/Caskroom",
        PREFIX ++ "/bin",
        PREFIX ++ "/opt",
        PREFIX ++ "/lib",
        PREFIX ++ "/include",
        PREFIX ++ "/share",
        ROOT ++ "/cache",
        ROOT ++ "/cache/blobs",
        ROOT ++ "/cache/tmp",
        ROOT ++ "/cache/api",
        ROOT ++ "/cache/tokens",
        paths.CONFIG_DIR,
        ROOT ++ "/db",
        ROOT ++ "/locks",
    };

    for (dirs) |dir| {
        std.Io.Dir.createDirAbsolute(g_io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            error.AccessDenied => {
                const stderr = StderrWriter{};
                stderr.print("nb: permission denied creating {s}\n", .{dir}) catch {};
                stderr.print("nb: try: sudo nb init\n", .{}) catch {};
                std.process.exit(1);
            },
            else => {
                const stderr = StderrWriter{};
                stderr.print("nb: error creating {s}: {}\n", .{ dir, err }) catch {};
                std.process.exit(1);
            },
        };
    }

    // Create /opt/homebrew -> /opt/nanobrew/prefix compatibility symlink
    // Homebrew bottles embed literal /opt/homebrew/ paths in binary data segments.
    // These can't be safely rewritten (different string lengths). The symlink
    // catches all such references without binary patching.
    std.Io.Dir.symLinkAbsolute(g_io, PREFIX, "/opt/homebrew", .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // /opt/homebrew already exists — check if it's our symlink or something else
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (std.Io.Dir.readLinkAbsolute(g_io, "/opt/homebrew", &target_buf)) |target_n| {
                const target = target_buf[0..target_n];
                if (!std.mem.eql(u8, target, PREFIX)) {
                    stdout.print("nb: note: /opt/homebrew is a symlink to {s} (not nanobrew)\n", .{target}) catch {};
                }
            } else |_| {
                // Not a symlink — likely a real Homebrew installation directory
                stdout.print("nb: note: /opt/homebrew exists (Homebrew installation detected), skipping compat symlink\n", .{}) catch {};
            }
            // Do NOT return — continue with remaining init steps
        },
        error.AccessDenied => {
            // nb init runs with sudo, so this shouldn't happen, but warn if it does
            std.Io.File.stderr().writeStreamingAll(g_io, "nb: warning: could not create /opt/homebrew compatibility symlink (permission denied)\n") catch {};
        },
        else => {},
    };

    // Create the /opt/nb -> PREFIX short-prefix symlink used by the native
    // relocator on BOTH Linux (ELF) and macOS (Mach-O). Placeholder and
    // literal-prefix replacements must be strictly shorter than their
    // source tokens for in-place binary patching; /opt/nb (7 bytes)
    // guarantees that where /opt/nanobrew/prefix (20 bytes) is one byte
    // too long for @@HOMEBREW_PREFIX@@ (19 bytes). On macOS this also lets
    // the Mach-O byte-pass rewrite .rodata compile-time defaults (OpenSSL
    // OPENSSLDIR, git --html-path, GIT_CONFIG_SYSTEM) that install_name_tool
    // never touches. See #347.
    if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos) {
        std.Io.Dir.symLinkAbsolute(g_io, PREFIX, "/opt/nb", .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {
                var nb_target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                if (std.Io.Dir.readLinkAbsolute(g_io, "/opt/nb", &nb_target_buf)) |target_n| {
                    if (!std.mem.eql(u8, nb_target_buf[0..target_n], PREFIX)) {
                        stdout.print("nb: note: /opt/nb points elsewhere — binary relocation will fall back to install_name_tool / patchelf\n", .{}) catch {};
                    }
                } else |_| {
                    stdout.print("nb: note: /opt/nb exists and is not a symlink — binary relocation will fall back to install_name_tool / patchelf\n", .{}) catch {};
                }
            },
            else => {},
        };
    }

    // If running as root (sudo), chown to the real user so nb install doesn't need sudo
    if (std.c.getenv("SUDO_USER")) |_sudo_cv| {
        const real_user = std.mem.sliceTo(_sudo_cv, 0);
        // Validate SUDO_USER contains only valid Unix username characters
        const valid = real_user.len > 0 and real_user.len <= 256 and for (real_user) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') break false;
        } else true;

        if (valid) {
            if (std.process.run(std.heap.smp_allocator, g_io, .{
                .argv = &.{ "chown", "-R", real_user, ROOT },
            })) |r| {
                std.heap.smp_allocator.free(r.stdout);
                std.heap.smp_allocator.free(r.stderr);
            } else |_| {}
        } else {
            const stderr = StderrWriter{};
            stderr.print("nb: warning: SUDO_USER contains invalid characters, skipping chown\n", .{}) catch {};
        }
    }

    stdout.print("nanobrew initialized at {s}\n", .{ROOT}) catch {};
    const shell: []const u8 = if (std.c.getenv("SHELL")) |cv| std.mem.sliceTo(cv, 0) else "";
    const is_fish = std.mem.endsWith(u8, shell, "/fish") or std.mem.eql(u8, shell, "fish");
    if (is_fish) {
        stdout.print("Add to your fish config: fish_add_path {s}/bin\n", .{PREFIX}) catch {};
    } else {
        stdout.print("Add to your shell: export PATH=\"{s}/bin:$PATH\"\n", .{PREFIX}) catch {};
    }
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

fn formulaArtifactSha(f: nb.formula.Formula) []const u8 {
    if (nb.store.isValidSha256(f.bottle_sha256)) return f.bottle_sha256;
    if (nb.store.isValidSha256(f.source_sha256)) return f.source_sha256;
    return "";
}

fn installedFormulaDeclarations(formula: ?nb.formula.Formula, keg: nb.database.Keg) []const []const u8 {
    const f = formula orelse return &.{};
    var version_buf: [256]u8 = undefined;
    if (!std.mem.eql(u8, f.effectiveVersion(&version_buf), keg.version)) return &.{};
    if (!std.mem.eql(u8, formulaArtifactSha(f), keg.sha256)) return &.{};
    return f.install_binaries;
}

// ── nb install <path>.rb ──
//
// Local Ruby formula install (#225). Reuses the tap parser for the Ruby DSL
// and the existing single-package install pipeline. Dependencies listed in
// the .rb file must already be installed — we deliberately do not fan out to
// the Homebrew API resolver, since a local .rb file is usually a private
// formula whose deps might themselves be private.

fn runLocalRbInstall(alloc: std.mem.Allocator, path: []const u8) void {
    const stderr = StderrWriter{};
    const stdout = StdoutWriter{};

    // Read the .rb source (small file — Homebrew formulas are a few KB).
    const max_src = 1 * 1024 * 1024;
    const src_opt: ?[]u8 = blk: {
        const f = (if (path.len > 0 and path[0] == '/')
            std.Io.Dir.openFileAbsolute(g_io, path, .{})
        else
            std.Io.Dir.cwd().openFile(g_io, path, .{})) catch break :blk null;
        defer f.close(g_io);
        const st = f.stat(g_io) catch break :blk null;
        if (st.size > max_src) {
            stderr.print("nb: .rb file too large ({d} bytes; max {d})\n", .{ st.size, max_src }) catch {};
            std.process.exit(1);
        }
        const buf = alloc.alloc(u8, @intCast(st.size)) catch break :blk null;
        const n = f.readPositionalAll(g_io, buf, 0) catch {
            alloc.free(buf);
            break :blk null;
        };
        break :blk buf[0..n];
    };
    const src = src_opt orelse {
        stderr.print("nb: failed to read '{s}'\n", .{path}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(src);

    // Derive the formula's short name from the basename (strip trailing ".rb").
    const basename = std.fs.path.basename(path);
    if (basename.len <= 3 or !std.mem.endsWith(u8, basename, ".rb")) {
        stderr.print("nb: '{s}' is not a .rb formula file\n", .{path}) catch {};
        std.process.exit(1);
    }
    const short_name = basename[0 .. basename.len - 3];

    var f = nb.tap.parseRubyFormula(alloc, short_name, src) catch |err| {
        stderr.print("nb: failed to parse '{s}': {}\n", .{ path, err }) catch {};
        std.process.exit(1);
    };
    defer f.deinit(alloc);

    if (f.bottle_url.len == 0 and f.source_url.len == 0) {
        stderr.print("nb: '{s}' has neither a bottle URL nor a source URL\n", .{path}) catch {};
        std.process.exit(1);
    }

    if (f.dependencies.len > 0) {
        stdout.print("==> Note: '{s}' declares {d} dependencies. Ensure they are already installed:\n", .{ f.name, f.dependencies.len }) catch {};
        for (f.dependencies) |dep| stdout.print("      - {s}\n", .{dep}) catch {};
        stdout.print("    Dependency resolution from local .rb files is not yet supported.\n", .{}) catch {};
    }

    // Pre-flight: /opt/nanobrew writable?
    const probe = std.Io.Dir.createFileAbsolute(g_io, ROOT ++ "/cache/.nb_write_test", .{}) catch null;
    if (probe) |pf| {
        pf.close(g_io);
        std.Io.Dir.deleteFileAbsolute(g_io, ROOT ++ "/cache/.nb_write_test") catch {};
    } else {
        stderr.print("nb: /opt/nanobrew is not writable. Run: sudo nb init\n", .{}) catch {};
        std.process.exit(1);
    }

    var version_buf: [256]u8 = undefined;
    const effective_version = f.effectiveVersion(&version_buf);
    stdout.print("==> Installing {s} {s} from {s}...\n", .{ f.name, effective_version, path }) catch {};

    var had_error = std.atomic.Value(bool).init(false);
    var phase = std.atomic.Value(u8).init(@intFromEnum(Phase.waiting));
    var fail_reason: ?[]const u8 = null;
    var probe_result: ProbeResult = .not_run;
    const local_formulae = [_]nb.formula.Formula{f};
    const local_requested = [_][]const u8{f.name};
    // Single-formula path: no batch token sharing benefit — pass null.
    fullInstallOne(alloc, f, &had_error, &phase, &fail_reason, &probe_result, false, &local_requested, &local_formulae, null);

    if (had_error.load(.acquire)) {
        if (fail_reason) |why| {
            stderr.print("nb: failed to install '{s}' ({s})\n", .{ f.name, why }) catch {};
        } else {
            stderr.print("nb: failed to install '{s}'\n", .{f.name}) catch {};
        }
        std.process.exit(1);
    }

    // Record in the database so `nb list` sees it.
    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: warning: could not open database\n", .{}) catch {};
        stdout.print("==> Done\n", .{}) catch {};
        return;
    };
    defer db.close();
    const artifact_sha = formulaArtifactSha(f);
    var recorded = true;
    db.recordInstall(f.name, effective_version, artifact_sha) catch |err| {
        recorded = false;
        stderr.print("nb: warning: failed to record {s} in database: {}\n", .{ f.name, err }) catch {};
    };
    if (recorded) {
        if (probe_result.value()) |passed| {
            db.recordKegProbe(f.name, effective_version, artifact_sha, passed, LOCAL_PROBE_SCHEMA, LOCAL_PROBE_PLATFORM) catch {};
        }
    }
    stdout.print("==> Done\n", .{}) catch {};
}

// ── nb install ──

/// A version spec looks like a version if it starts with a digit and contains
/// only version-ish characters. Distinguishes `hexyl@0.17.0` (version pin) from
/// arbitrary `@` usage. Note: real versioned formulae like `python@3.11` also
/// satisfy this — they're disambiguated separately by probing the formula API.
fn looksLikeVersion(spec: []const u8) bool {
    if (spec.len == 0 or !std.ascii.isDigit(spec[0])) return false;
    for (spec) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '+' and c != '-') return false;
    }
    return true;
}

/// Build a Formula for a version-pinned bottle: bottle URL/sha/version come from
/// the GHCR resolver, while dependencies/metadata are taken from the *current*
/// formula (see the dep-drift caveat in docs/design/versioned-install.md).
/// Returned Formula owns all fields; free with `Formula.deinit`.
fn buildPinnedFormula(
    alloc: std.mem.Allocator,
    base: []const u8,
    bottle: nb.ghcr.VersionedBottle,
    cur: nb.formula.Formula,
) !nb.formula.Formula {
    const deps = try alloc.alloc([]const u8, cur.dependencies.len);
    var filled: usize = 0;
    errdefer {
        for (deps[0..filled]) |d| alloc.free(d);
        alloc.free(deps);
    }
    for (cur.dependencies, 0..) |d, k| {
        deps[k] = try alloc.dupe(u8, d);
        filled = k + 1;
    }
    return .{
        .name = try alloc.dupe(u8, base),
        .version = try alloc.dupe(u8, bottle.version),
        .revision = 0,
        .rebuild = 0,
        .desc = try alloc.dupe(u8, cur.desc),
        .homepage = try alloc.dupe(u8, cur.homepage),
        .license = try alloc.dupe(u8, cur.license),
        .dependencies = deps,
        .bottle_url = try alloc.dupe(u8, bottle.url),
        .bottle_sha256 = try alloc.dupe(u8, bottle.sha256),
        .source_url = try alloc.dupe(u8, ""),
        .source_sha256 = try alloc.dupe(u8, ""),
        .build_deps = try alloc.alloc([]const u8, 0),
        .caveats = try alloc.dupe(u8, cur.caveats),
        .post_install_defined = cur.post_install_defined,
    };
}

/// Print the "version not available, here's what is" message for a failed
/// version pin, then return (caller exits). Best-effort — lists tags from GHCR
/// and the latest version from the formula API.
fn offerLatest(
    alloc: std.mem.Allocator,
    client: *std.http.Client,
    base: []const u8,
    requested: []const u8,
) void {
    const stderr = StderrWriter{};
    stderr.print("nb: {s} {s} is not available as a bottle for this platform.\n", .{ base, requested }) catch {};

    if (nb.ghcr.listTags(alloc, client, base)) |tags| {
        defer {
            for (tags) |t| alloc.free(t);
            alloc.free(tags);
        }
        if (tags.len > 0) {
            // Show the most recent handful (tags are returned oldest-first).
            const show: usize = @min(tags.len, 12);
            stderr.print("    available versions: ", .{}) catch {};
            for (tags[tags.len - show ..], 0..) |t, i| {
                if (i > 0) stderr.print(", ", .{}) catch {};
                stderr.print("{s}", .{t}) catch {};
            }
            stderr.print("\n", .{}) catch {};
        }
    } else |_| {}

    if (nb.api_client.fetchFormula(alloc, base)) |f| {
        defer f.deinit(alloc);
        var version_buf: [256]u8 = undefined;
        stderr.print("    latest is {s}; install it with:  nb install {s}\n", .{ f.effectiveVersion(&version_buf), base }) catch {};
    } else |_| {}
}

/// Handle a `name@version` argument as a version pin. Returns the base name
/// (a slice of `arg`) if `arg` was a version pin that has now been injected into
/// `resolver`; returns null if `arg` is not a version pin and should follow the
/// normal resolution path. Exits the process on hard errors (version/bottle not
/// found, OOM) after printing guidance.
fn resolveVersionPin(
    alloc: std.mem.Allocator,
    resolver: *nb.deps.DepResolver,
    arg: []const u8,
) ?[]const u8 {
    const stderr = StderrWriter{};
    const stdout = StdoutWriter{};

    const at = std.mem.indexOfScalar(u8, arg, '@') orelse return null;
    // Tap refs (user/tap/formula) are out of scope for version pinning.
    if (std.mem.indexOfScalar(u8, arg, '/') != null) return null;
    const base = arg[0..at];
    const spec = arg[at + 1 ..];
    if (base.len == 0 or !looksLikeVersion(spec)) return null;

    const client: *std.http.Client = if (resolver.client) |*c| c.ptr() else return null;

    // Disambiguate: if `name@spec` resolves as a real (versioned) formula, this
    // is not a version pin — let normal resolution handle it (e.g. python@3.11).
    if (nb.api_client.fetchFormulaWithClient(alloc, client, arg)) |vf| {
        vf.deinit(alloc);
        return null;
    } else |_| {}

    // Version pin: resolve this platform's bottle for the requested version.
    const bottle = nb.ghcr.resolveBottle(alloc, client, base, spec) catch |err| switch (err) {
        error.BottleVersionNotFound, error.NoBottleForPlatform => {
            offerLatest(alloc, client, base, spec);
            std.process.exit(1);
        },
        else => {
            stderr.print("nb: failed to resolve {s}@{s} from registry: {}\n", .{ base, spec, err }) catch {};
            std.process.exit(1);
        },
    };
    defer bottle.deinit(alloc);

    // Dependencies/metadata come from the current formula (dep-drift caveat).
    const cur = nb.api_client.fetchFormulaWithClient(alloc, client, base) catch {
        stderr.print("nb: formula not found: '{s}'\n", .{base}) catch {};
        std.process.exit(1);
    };
    defer cur.deinit(alloc);

    const pinned = buildPinnedFormula(alloc, base, bottle, cur) catch {
        stderr.print("nb: out of memory resolving {s}@{s}\n", .{ base, spec }) catch {};
        std.process.exit(1);
    };
    resolver.addResolved(pinned) catch |err| {
        stderr.print("nb: failed to resolve {s}@{s}: {}\n", .{ base, spec, err }) catch {};
        std.process.exit(1);
    };

    stdout.print("==> Pinning {s} to {s} (dependencies resolved against the latest formula)\n", .{ base, bottle.version }) catch {};
    return base;
}

fn runInstall(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stderr = StderrWriter{};

    // Check for --cask, --deb, --repo, --skip-postinst, --no-verify, and --shims flags
    var is_cask = false;
    var is_deb = false;
    var repo_spec: ?[]const u8 = null;
    var skip_postinst = false;
    var no_verify = false;
    var use_shims = shimLinksEnabledByEnv();
    var formulae: std.ArrayList([]const u8) = .empty;
    defer formulae.deinit(alloc);
    var arg_idx: usize = 0;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = args[arg_idx];
        if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            is_cask = true;
        } else if (std.mem.eql(u8, arg, "--deb") or std.mem.eql(u8, arg, "--debs")) {
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
        } else if (std.mem.eql(u8, arg, "--shims") or std.mem.eql(u8, arg, "--shim-links")) {
            use_shims = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            stderr.print("nb: unknown flag '{s}'\n", .{arg}) catch {};
            std.process.exit(1);
        } else {
            formulae.append(alloc, arg) catch {};
        }
    }

    if (formulae.items.len == 0) {
        stderr.print("nb: no formulae specified\n", .{}) catch {};
        std.process.exit(1);
    }

    // Local .rb formula install (#225). Detect a filesystem path that points
    // at a Ruby formula file and hand it off to the local-parse pipeline,
    // bypassing the Homebrew API lookup and the package-name safety check
    // (which intentionally rejects slashes beyond `user/tap/formula`).
    if (formulae.items.len == 1 and !is_cask and !is_deb) {
        const arg = formulae.items[0];
        if (std.mem.endsWith(u8, arg, ".rb")) {
            const exists = if (arg.len > 0 and arg[0] == '/')
                if (std.Io.Dir.accessAbsolute(g_io, arg, .{})) |_| true else |_| false
            else if (std.Io.Dir.cwd().access(g_io, arg, .{})) |_| true else |_| false;
            if (exists) {
                runLocalRbInstall(alloc, arg);
                return;
            }
        }
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

    // Homebrew accepts `brew install owner/tap/token` for tap casks as well
    // as tap formulae. Preserve formula precedence, but if a single tap token
    // has no formula and does have a cask, route it through the cask installer.
    if (formulae.items.len == 1 and tapInstallShouldUseCask(alloc, formulae.items[0])) {
        runCaskInstall(alloc, formulae.items);
        return;
    }

    const stdout = StdoutWriter{};

    var timer = MonoTimer.start();
    var phase_timer = MonoTimer.start();

    // Phase 1: Resolve all dependencies
    stdout.print("==> Resolving dependencies...\n", .{}) catch {};
    var resolver = nb.deps.DepResolver.init(alloc);
    defer resolver.deinit();

    // A `name@version` arg that is NOT itself a real versioned formula
    // (e.g. `hexyl@0.17.0`) is resolved as a version pin via GHCR; matching args
    // are rewritten to their base name for the rest of the pipeline and recorded
    // so we can auto-pin them after install (the user explicitly chose a version).
    var pinned_names: std.ArrayList([]const u8) = .empty;
    defer pinned_names.deinit(alloc);

    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(alloc);
    for (formulae.items, 0..) |name, i| {
        if (resolveVersionPin(alloc, &resolver, name)) |base| {
            formulae.items[i] = base;
            pinned_names.append(alloc, base) catch {};
            continue;
        }
        roots.append(alloc, name) catch {
            stderr.print("nb: failed to queue '{s}' for resolution\n", .{name}) catch {};
            std.process.exit(1);
        };
    }
    resolver.resolveMany(roots.items) catch |err| {
        stderr.print("nb: dependency resolution failed: {}\n", .{err}) catch {};
        std.process.exit(1);
    };

    // Verify all requested formulas were actually found (#68)
    {
        var any_missing = false;
        for (formulae.items) |name| {
            // Use hasFormulaOrAlias to handle aliases like "python" -> "python@3.14"
            if (!resolver.hasFormulaOrAlias(alloc, name)) {
                stderr.print("nb: formula not found: '{s}'\n", .{name}) catch {};
                any_missing = true;
            }
        }
        if (any_missing) std.process.exit(1);
    }

    const resolve_ms = @as(f64, @floatFromInt(phase_timer.read())) / 1_000_000.0;
    stdout.print("    [{d:.0}ms]\n", .{resolve_ms}) catch {};

    const all_formulae = resolver.topologicalSort() catch |err| {
        if (err == error.DependencyCycle) {
            stderr.print("nb: warning: circular dependency detected for '{s}', skipping\n", .{formulae.items[0]}) catch {};
        } else {
            stderr.print("nb: warning: dependency resolution failed for '{s}': {}, skipping\n", .{ formulae.items[0], err }) catch {};
        }
        return;
    };
    defer alloc.free(all_formulae);

    // The Cellar path identifies a formula revision, while the recorded digest
    // distinguishes source changes and bottle rebuilds at that same path.
    var filter_db: ?nb.database.Database = nb.database.Database.open(alloc) catch null;
    defer if (filter_db) |*db| db.close();

    // Filter out already-installed packages (keg exists in Cellar)
    var to_install: std.ArrayList(nb.formula.Formula) = .empty;
    defer to_install.deinit(alloc);
    for (all_formulae) |f| {
        var expected_buf: [256]u8 = undefined;
        const expected_ver = f.effectiveVersion(&expected_buf);
        var ver_buf: [256]u8 = undefined;
        const actual_ver = nb.cellar.detectKegVersion(f.name, expected_ver, &ver_buf) orelse expected_ver;
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
        if (std.Io.Dir.openDirAbsolute(g_io, ver_dir, .{})) |d| {
            var dir = d;
            dir.close(g_io);
            const expected_sha = formulaArtifactSha(f);
            const artifact_changed = if (filter_db) |*db| blk: {
                const installed = db.findKeg(f.name) orelse break :blk false;
                break :blk expected_sha.len > 0 and
                    std.mem.eql(u8, installed.version, actual_ver) and
                    installed.sha256.len > 0 and
                    !std.mem.eql(u8, installed.sha256, expected_sha);
            } else false;
            if (artifact_changed) {
                to_install.append(alloc, f) catch {};
                continue;
            }
            if (formulaLinkNeedsRepair(f.name, actual_ver, use_shims, formulae.items)) {
                linkFormulaKeg(alloc, f.name, actual_ver, use_shims, formulae.items, all_formulae) catch {};
            }
        } else |_| {
            to_install.append(alloc, f) catch {};
        }
    }
    const install_order = to_install.items;

    if (install_order.len == 0) {
        var db = nb.database.Database.open(alloc) catch {
            stderr.print("nb: warning: could not open database\n", .{}) catch {};
            return;
        };
        defer db.close();
        for (all_formulae) |f| {
            var expected_buf: [256]u8 = undefined;
            const expected_ver = f.effectiveVersion(&expected_buf);
            var ver_buf6: [256]u8 = undefined;
            const actual_ver = nb.cellar.detectKegVersion(f.name, expected_ver, &ver_buf6) orelse expected_ver;
            const existing = db.findKeg(f.name);
            if (existing) |keg| {
                if (std.mem.eql(u8, keg.version, actual_ver)) continue;
            }
            // A pre-existing untracked keg has unknown artifact provenance.
            db.recordInstall(f.name, actual_ver, "") catch |err| {
                stderr.print("nb: warning: failed to record {s} in database: {}\n", .{ f.name, err }) catch {};
            };
        }
        for (pinned_names.items) |base| db.setPinned(base, true) catch {};

        const elapsed_ns: u64 = timer.read();
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        stdout.print("==> Already installed ({d} packages up to date)\n", .{all_formulae.len}) catch {};
        stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
        return;
    }

    // Pre-flight check: verify /opt/nanobrew is writable
    const write_ok: ?std.Io.File = std.Io.Dir.createFileAbsolute(g_io, ROOT ++ "/cache/.nb_write_test", .{}) catch null;
    if (write_ok != null) {
        write_ok.?.close(g_io);
        std.Io.Dir.deleteFileAbsolute(g_io, ROOT ++ "/cache/.nb_write_test") catch {};
    } else {
        stderr.print("nb: /opt/nanobrew is not writable. Run: sudo nb init\n", .{}) catch {};
        std.process.exit(1);
    }

    stdout.print("==> Installing {d} package(s) ({d} already up to date):\n", .{ install_order.len, all_formulae.len - install_order.len }) catch {};
    for (install_order) |f| {
        var version_buf: [256]u8 = undefined;
        stdout.print("    {s} {s}\n", .{ f.name, f.effectiveVersion(&version_buf) }) catch {};
    }
    // Single merged phase: Download → Extract → Materialize → Relocate → Link (all parallel)
    phase_timer = MonoTimer.start();
    const pkg_count = install_order.len;
    const install_succeeded = alloc.alloc(bool, pkg_count) catch {
        stderr.print("nb: out of memory\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(install_succeeded);
    @memset(install_succeeded, false);
    const probe_results = alloc.alloc(ProbeResult, pkg_count) catch {
        stderr.print("nb: out of memory\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(probe_results);
    @memset(probe_results, .not_run);
    stdout.print("==> Downloading + installing {d} packages...\n", .{pkg_count}) catch {};
    // Remembered past the pipeline block so the process can exit nonzero when
    // any package failed (#361: `nb install` used to report failure text but
    // still exit 0).
    var pipeline_failed = false;
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

        // Per-package failure reason (static strings set by the worker), so the
        // final summary explains *why* each package failed instead of a bare ✗.
        const reasons = alloc.alloc(?[]const u8, pkg_count) catch {
            stderr.print("nb: out of memory\n", .{}) catch {};
            std.process.exit(1);
        };
        defer alloc.free(reasons);
        for (reasons) |*r| r.* = null;

        var had_error = std.atomic.Value(bool).init(false);

        // Batch-scoped GHCR token: one bearer-token lookup shared across
        // every ghcr.io bottle download. Each install worker owns its own
        // std.http.Client because individual requests are not thread-safe.
        const shared_ghcr_token: ?[]const u8 = blk: {
            var token_client = nb.proxy.Client.init(alloc, paths.safe_io);
            defer token_client.deinit();
            for (install_order) |f_check| {
                if (!std.mem.startsWith(u8, f_check.bottleUrl(), "https://ghcr.io")) continue;
                // Only pay the token round trip when some ghcr bottle will
                // actually be downloaded — with every blob already cached
                // (reinstalls, snapshot restores) the token is dead weight
                // (~300-500ms once its 4-min disk cache expires).
                var tok_blob_buf: [512]u8 = undefined;
                const tok_blob_path = std.fmt.bufPrint(&tok_blob_buf, "/opt/nanobrew/cache/blobs/{s}", .{f_check.bottle_sha256}) catch break :blk null;
                if (fileExists(tok_blob_path)) continue;
                break :blk nb.downloader.fetchGhcrToken(alloc, token_client.ptr(), f_check.bottleUrl()) catch null;
            }
            break :blk null;
        };
        defer if (shared_ghcr_token) |t| alloc.free(t);
        // Each in-flight slot carries the OS thread handle plus the task index
        // it owns. The task index lets us look up the matching `phases[ti]`
        // entry when scanning for a worker that has already reached a terminal
        // phase (`done` or `failed`), so we can reclaim its slot without
        // blocking on whichever task happened to be spawned first.
        const ThreadSlot = struct { handle: std.Thread, task_idx: usize };
        var slots: std.ArrayList(ThreadSlot) = .empty;
        defer slots.deinit(alloc);

        const max_concurrent: usize = 16;

        for (install_order, 0..) |f, pi| {
            // Sliding window: when at capacity, free a slot before spawning a
            // new worker. The original implementation always joined the oldest
            // (`slots.items[0]`), which stalled the pipeline whenever a long
            // task (e.g. a cmake source build) was scheduled first while
            // shorter bottle workers finished behind it. Now we first scan for
            // any worker whose phase has reached `done`/`failed` and reclaim
            // that slot; only when every slot is still mid-pipeline do we fall
            // back to blocking on the oldest. This keeps the window saturated
            // under skewed install times without busy-waiting. (#36)
            if (slots.items.len >= max_concurrent) {
                var reclaim_idx: ?usize = null;
                for (slots.items, 0..) |slot, si| {
                    const raw: u8 = phases[slot.task_idx].load(.acquire);
                    const ph: Phase = @enumFromInt(raw);
                    if (ph == .done or ph == .failed) {
                        reclaim_idx = si;
                        break;
                    }
                }
                const idx = reclaim_idx orelse 0;
                slots.items[idx].handle.join();
                _ = slots.orderedRemove(idx);
            }
            const t = std.Thread.spawn(.{}, fullInstallOne, .{ alloc, f, &had_error, &phases[pi], &reasons[pi], &probe_results[pi], use_shims, formulae.items, all_formulae, shared_ghcr_token }) catch {
                reasons[pi] = "could not spawn worker thread";
                had_error.store(true, .release);
                phases[pi].store(@intFromEnum(Phase.failed), .release);
                continue;
            };
            slots.append(alloc, .{ .handle = t, .task_idx = pi }) catch {
                // Couldn't track this handle. The worker is already running and
                // borrows `phases` / `formulae.items` / `names`; if we let it
                // outlive runInstall we get a use-after-free. Joining inline
                // serializes one slot but keeps lifetimes sound.
                t.join();
                had_error.store(true, .release);
                continue;
            };
        }

        // Live progress on TTY, plain wait otherwise
        const is_tty = std.Io.File.stdout().isTty(g_io) catch false;
        if (is_tty) {
            renderProgress(names, phases);
        }

        for (slots.items) |slot| slot.handle.join();

        // Non-TTY: print final status for each package
        if (!is_tty) {
            for (names, 0..) |name, i| {
                const raw: u8 = phases[i].load(.acquire);
                const phase: Phase = @enumFromInt(raw);
                if (phase == .done) {
                    stdout.print("    ✓ {s}\n", .{name}) catch {};
                } else if (phase == .failed) {
                    if (reasons[i]) |why| {
                        stdout.print("    ✗ {s} ({s})\n", .{ name, why }) catch {};
                    } else {
                        stdout.print("    ✗ {s}\n", .{name}) catch {};
                    }
                }
            }
        }

        if (had_error.load(.acquire)) {
            pipeline_failed = true;
            stderr.print("nb: some packages failed to install\n", .{}) catch {};
            // Re-print which packages failed so the user sees them after progress display
            for (names, 0..) |name, i| {
                const raw: u8 = phases[i].load(.acquire);
                const phase: Phase = @enumFromInt(raw);
                if (phase == .failed) {
                    if (reasons[i]) |why| {
                        stderr.print("    failed: {s} ({s})\n", .{ name, why }) catch {};
                    } else {
                        stderr.print("    failed: {s}\n", .{name}) catch {};
                    }
                }
            }
            stderr.print("nb: hint: check permissions with `nb doctor`\n", .{}) catch {};
        }
        for (phases, 0..) |*phase, i| {
            install_succeeded[i] = @as(Phase, @enumFromInt(phase.load(.acquire))) == .done;
        }
    }
    const pipeline_ms = @as(f64, @floatFromInt(phase_timer.read())) / 1_000_000.0;
    stdout.print("    [{d:.0}ms]\n", .{pipeline_ms}) catch {};

    // Record in database (must be serial — single file)
    // Also heal DB drift for packages that already existed in Cellar and were
    // therefore skipped from install_order during this run.
    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: warning: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();
    for (all_formulae) |f| {
        var expected_buf: [256]u8 = undefined;
        const expected_ver = f.effectiveVersion(&expected_buf);
        var ver_buf6: [256]u8 = undefined;
        // Only record packages that actually landed in the Cellar. If there is no
        // keg directory the install failed (download/extract/materialize), so
        // skipping here avoids writing phantom DB entries that later trip up
        // `nb doctor` / `nb cleanup --prune-kegs` (#311).
        const actual_ver = nb.cellar.detectKegVersion(f.name, expected_ver, &ver_buf6) orelse continue;

        var queued = false;
        var installed_successfully = false;
        var install_probe: ProbeResult = .not_run;
        for (install_order, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate.name, f.name)) {
                queued = true;
                installed_successfully = install_succeeded[i];
                install_probe = probe_results[i];
                break;
            }
        }
        // A failed reinstall can leave the previous same-version keg intact.
        // Never attach the new digest (or adopt a partial new keg) on failure.
        if (queued and !installed_successfully) continue;
        const record_sha = if (installed_successfully) formulaArtifactSha(f) else "";
        const probe_value = if (installed_successfully) install_probe.value() else null;
        const existing = db.findKeg(f.name);
        if (existing) |keg| {
            if (std.mem.eql(u8, keg.version, actual_ver) and !installed_successfully) continue;
            if (std.mem.eql(u8, keg.version, actual_ver) and
                std.mem.eql(u8, keg.sha256, record_sha))
            {
                // Same immutable artifact: retain the install record and only
                // attach newly collected probe evidence, avoiding fake history.
                if (probe_value) |passed| {
                    db.recordKegProbe(f.name, actual_ver, record_sha, passed, LOCAL_PROBE_SCHEMA, LOCAL_PROBE_PLATFORM) catch {};
                }
                continue;
            }
        }

        var recorded = true;
        db.recordInstall(f.name, actual_ver, record_sha) catch |err| {
            recorded = false;
            stderr.print("nb: warning: failed to record {s} in database: {}\n", .{ f.name, err }) catch {};
        };
        if (recorded) {
            if (probe_value) |passed| {
                db.recordKegProbe(f.name, actual_ver, record_sha, passed, LOCAL_PROBE_SCHEMA, LOCAL_PROBE_PLATFORM) catch {};
            }
        }
    }

    // Auto-pin version-pinned installs so a later `nb upgrade` won't silently
    // replace the explicitly chosen version. setPinned fails with NotFound when
    // the install never produced a keg record — don't claim "Pinned" then.
    for (pinned_names.items) |base| {
        if (db.setPinned(base, true)) {
            stdout.print("==> Pinned {s} (won't be upgraded; run `nb unpin {s}` to allow upgrades)\n", .{ base, base }) catch {};
        } else |_| {}
    }

    const elapsed_ns: u64 = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
    if (pipeline_failed) std.process.exit(1);
}

/// Render live progress UI with spinners and checkmarks.
/// Blocks until all packages reach .done or .failed.
fn renderProgress(
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

    const stdout = std.Io.File.stdout();

    // Hide cursor
    stdout.writeStreamingAll(g_io, "\x1b[?25l") catch {};

    // Reserve N lines
    for (0..n) |_| stdout.writeStreamingAll(g_io, "\n") catch {};

    while (true) {
        // Move cursor up N lines
        var esc_buf: [16]u8 = undefined;
        const esc = std.fmt.bufPrint(&esc_buf, "\x1b[{d}A", .{n}) catch "";
        stdout.writeStreamingAll(g_io, esc) catch {};

        var all_done = true;
        for (names, 0..) |name, i| {
            const raw: u8 = phases[i].load(.acquire);
            const phase: Phase = @enumFromInt(raw);

            // Clear line
            stdout.writeStreamingAll(g_io, "\x1b[2K") catch {};

            switch (phase) {
                .done => {
                    stdout.writeStreamingAll(g_io, "    \x1b[32m✓\x1b[0m ") catch {};
                    stdout.writeStreamingAll(g_io, name) catch {};
                    stdout.writeStreamingAll(g_io, "\n") catch {};
                },
                .failed => {
                    stdout.writeStreamingAll(g_io, "    \x1b[31m✗\x1b[0m ") catch {};
                    stdout.writeStreamingAll(g_io, name) catch {};
                    stdout.writeStreamingAll(g_io, "\n") catch {};
                },
                else => {
                    all_done = false;
                    const fi = tick % frame_count;
                    const start = fi * frame_bytes;
                    stdout.writeStreamingAll(g_io, "    ") catch {};
                    stdout.writeStreamingAll(g_io, spinner[start .. start + frame_bytes]) catch {};
                    stdout.writeStreamingAll(g_io, " ") catch {};
                    stdout.writeStreamingAll(g_io, name) catch {};
                    // Pad to align phase labels
                    var pad: usize = max_len - name.len + 1;
                    while (pad > 0) : (pad -= 1) stdout.writeStreamingAll(g_io, " ") catch {};
                    const label: []const u8 = switch (phase) {
                        .waiting => "waiting...",
                        .downloading => "downloading...",
                        .extracting => "extracting...",
                        .installing => "installing...",
                        .relocating => "relocating...",
                        .linking => "linking...",
                        .done, .failed => unreachable,
                    };
                    stdout.writeStreamingAll(g_io, label) catch {};
                    stdout.writeStreamingAll(g_io, "\n") catch {};
                },
            }
        }

        if (all_done) break;

        tick += 1;
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 80 * 1_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }

    // Show cursor
    stdout.writeStreamingAll(g_io, "\x1b[?25h") catch {};
}

fn truthyEnvValue(raw_or_null: ?[*:0]u8) bool {
    const raw = raw_or_null orelse return false;
    const value = std.mem.span(raw);
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

fn shimLinksEnabledByEnv() bool {
    return truthyEnvValue(std.c.getenv("NANOBREW_SHIMS")) or
        truthyEnvValue(std.c.getenv("NANOBREW_SHIM_LINKS"));
}

fn tapShortNameLocal(name: []const u8) []const u8 {
    var last_slash: ?usize = null;
    for (name, 0..) |c, i| {
        if (c == '/') last_slash = i;
    }
    if (last_slash) |pos| {
        if (pos + 1 < name.len) return name[pos + 1 ..];
    }
    return name;
}

fn tapInstallShouldUseCask(alloc: std.mem.Allocator, token: []const u8) bool {
    if (nb.tap.parseTapRef(token) == null) return false;

    if (nb.api_client.fetchFormula(alloc, token)) |formula_meta| {
        formula_meta.deinit(alloc);
        return false;
    } else |err| switch (err) {
        error.FormulaNotFound => {},
        else => return false,
    }

    if (nb.api_client.fetchCask(alloc, token)) |cask_meta| {
        cask_meta.deinit(alloc);
        return true;
    } else |_| {
        return false;
    }
}

fn isRequestedFormulaName(name: []const u8, requested: []const []const u8) bool {
    for (requested) |raw| {
        if (std.mem.eql(u8, name, raw)) return true;
        if (std.mem.eql(u8, name, tapShortNameLocal(raw))) return true;
    }
    return false;
}

fn buildShimPathEntries(
    alloc: std.mem.Allocator,
    root_name: []const u8,
    all_formulae: []const nb.formula.Formula,
) ![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (entries.items) |entry| alloc.free(entry);
        entries.deinit(alloc);
    }

    for (all_formulae) |formula| {
        if (std.mem.eql(u8, formula.name, root_name)) continue;
        try entries.append(alloc, try std.fmt.allocPrint(alloc, "{s}/opt/{s}/bin", .{ PREFIX, formula.name }));
        try entries.append(alloc, try std.fmt.allocPrint(alloc, "{s}/opt/{s}/sbin", .{ PREFIX, formula.name }));
    }
    return try entries.toOwnedSlice(alloc);
}

fn freeShimPathEntries(alloc: std.mem.Allocator, entries: []const []const u8) void {
    for (entries) |entry| alloc.free(entry);
    alloc.free(entries);
}

fn linkFormulaKeg(
    alloc: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    use_shims: bool,
    requested: []const []const u8,
    all_formulae: []const nb.formula.Formula,
) !void {
    if (!use_shims) return nb.linker.linkKeg(name, version);

    if (isRequestedFormulaName(name, requested)) {
        const entries = try buildShimPathEntries(alloc, name, all_formulae);
        defer freeShimPathEntries(alloc, entries);
        return nb.linker.linkKegWithOptions(name, version, .{
            .mode = .shim_root,
            .shim_path_entries = entries,
        });
    }

    return nb.linker.linkKegWithOptions(name, version, .{ .mode = .private_dependency });
}

fn formulaLinkNeedsRepair(
    name: []const u8,
    version: []const u8,
    use_shims: bool,
    requested: []const []const u8,
) bool {
    if (!use_shims) return nb.linker.needsLinkRepair(name, version, .{});
    if (isRequestedFormulaName(name, requested)) {
        return nb.linker.needsLinkRepair(name, version, .{ .mode = .shim_root });
    }
    return nb.linker.needsLinkRepair(name, version, .{ .mode = .private_dependency });
}

/// Short, human-readable reason for a bottle download failure, surfaced in the
/// install summary so a `✗` is actionable (#311).
fn downloadFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.BottleNotFound => "bottle not found upstream — version metadata may be stale",
        error.AuthFailed => "registry auth failed",
        error.RateLimited => "rate limited by registry — retry shortly",
        error.ChecksumMismatch => "checksum mismatch — download corrupted or metadata stale",
        else => "network error after retries",
    };
}

/// Full per-package pipeline: download → extract → materialize → relocate → link
/// Runs in its own thread — no barriers between phases.
///
/// `shared_ghcr_token`, when non-null, avoids a redundant GHCR token lookup
/// for each bottle. Each invocation owns its HTTP client because individual
/// std.http.Client requests are not thread-safe.
fn fullInstallOne(
    alloc: std.mem.Allocator,
    f: nb.formula.Formula,
    had_error: *std.atomic.Value(bool),
    phase: *std.atomic.Value(u8),
    // Set to a short, static reason string on failure so the final summary can
    // explain *why* a package failed instead of printing a bare ✗ (#311).
    fail_reason: *?[]const u8,
    probe_result: *ProbeResult,
    use_shims: bool,
    requested: []const []const u8,
    all_formulae: []const nb.formula.Formula,
    shared_ghcr_token: ?[]const u8,
) void {
    const stderr = StderrWriter{};
    const bench: bool = std.c.getenv("NB_BENCH") != null;
    var bench_t: i64 = 0;

    const is_source_build = f.bottle_url.len == 0 and f.source_url.len > 0;
    var expected_ver_buf: [256]u8 = undefined;
    const expected_ver = f.effectiveVersion(&expected_ver_buf);

    if (is_source_build) {
        const source_cache_key = if (f.install_binaries.len > 0 and nb.store.isValidSha256(f.source_sha256)) f.source_sha256 else "";
        fast: {
            if (source_cache_key.len == 0) break :fast;
            if (!nb.store.hasRelocatedEntry(g_io, source_cache_key)) break :fast;
            phase.store(@intFromEnum(Phase.installing), .release);
            nb.store.materializeFromRelocated(g_io, source_cache_key, f.name, expected_ver) catch break :fast;
            phase.store(@intFromEnum(Phase.linking), .release);
            linkFormulaKeg(alloc, f.name, expected_ver, use_shims, requested, all_formulae) catch |err| {
                stderr.print("nb: {s}: link failed: {}\n", .{ f.name, err }) catch {};
                fail_reason.* = "link failed";
                had_error.store(true, .release);
                phase.store(@intFromEnum(Phase.failed), .release);
                return;
            };
            nb.postinstall.runPostInstall(alloc, g_io, f) catch |err| {
                stderr.print("nb: {s}: post-install warning: {}\n", .{ f.name, err }) catch {};
            };
            // Cached reinstalls must still produce health evidence (#356).
            const fast_probe_passed = probeInstalledFormula(alloc, null, f.name, expected_ver, f.install_binaries, .active);
            probe_result.* = if (fast_probe_passed) .passed else .failed;
            if (!fast_probe_passed) {
                stderr.print("nb: {s}: post-install probe warning: declared binaries or linked executables missing\n", .{f.name}) catch {};
            }
            phase.store(@intFromEnum(Phase.done), .release);
            return;
        }

        // Source build path: download + compile from source
        phase.store(@intFromEnum(Phase.downloading), .release);
        nb.source_builder.buildFromSource(alloc, g_io, f) catch |err| {
            // Source builds create the keg directory before invoking the build.
            // Remove that staging directory on failure so DB healing cannot
            // mistake an empty payload for a completed install (#345).
            nb.cellar.remove(f.name, expected_ver) catch {};
            stderr.print("nb: {s}: source build failed: {}\n", .{ f.name, err }) catch {};
            fail_reason.* = "source build failed";
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
            fail_reason.* = "blob path too long";
            had_error.store(true, .release);
            phase.store(@intFromEnum(Phase.failed), .release);
            return;
        };

        if (!fileExists(blob_path)) {
            const dl_req: nb.downloader.DownloadRequest = .{
                .url = f.bottleUrl(),
                .expected_sha256 = f.bottle_sha256,
                .target_kind = .formula,
                .target_name = f.name,
            };
            var client = nb.proxy.Client.init(alloc, paths.safe_io);
            defer client.deinit();
            const dl_result = nb.downloader.downloadOneWithClient(alloc, client.ptr(), dl_req, shared_ghcr_token);
            dl_result catch |err| {
                fail_reason.* = downloadFailureReason(err);
                stderr.print("nb: {s}: download failed: {s} ({s})\n", .{ f.name, @errorName(err), fail_reason.*.? }) catch {};
                had_error.store(true, .release);
                phase.store(@intFromEnum(Phase.failed), .release);
                return;
            };
        }

        // 2. Extract into store (skip if already there)
        phase.store(@intFromEnum(Phase.extracting), .release);
        if (bench) bench_t = milliTimestamp();
        if (!nb.store.hasEntry(g_io, f.bottle_sha256)) {
            nb.store.ensureEntry(alloc, g_io, blob_path, f.bottle_sha256) catch |err| {
                stderr.print("nb: {s}: extract failed: {}\n", .{ f.name, err }) catch {};
                fail_reason.* = "extract failed";
                had_error.store(true, .release);
                phase.store(@intFromEnum(Phase.failed), .release);
                return;
            };
        }
        if (bench) std.debug.print("[nb-bench] {s} extract: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });

        // 3. Materialize (clonefile into Cellar)
        phase.store(@intFromEnum(Phase.installing), .release);
        fast: {
            if (!nb.store.hasRelocatedEntry(g_io, f.bottle_sha256)) break :fast;
            var detected_ver_buf: [256]u8 = undefined;
            const fv = nb.store.detectEntryVersion(g_io, f.bottle_sha256, f.name, expected_ver, &detected_ver_buf) orelse
                nb.cellar.detectKegVersion(f.name, expected_ver, &detected_ver_buf) orelse
                expected_ver;
            if (bench) bench_t = milliTimestamp();
            nb.store.materializeFromRelocated(g_io, f.bottle_sha256, f.name, fv) catch break :fast;
            if (bench) {
                std.debug.print("[nb-bench] {s} materialize: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
                bench_t = milliTimestamp();
            }
            // Relocated snapshot found — skip steps 4/4b, go straight to link+post-install
            phase.store(@intFromEnum(Phase.linking), .release);
            linkFormulaKeg(alloc, f.name, fv, use_shims, requested, all_formulae) catch |err| {
                stderr.print("nb: {s}: link failed: {}\n", .{ f.name, err }) catch {};
                fail_reason.* = "link failed";
                had_error.store(true, .release);
                phase.store(@intFromEnum(Phase.failed), .release);
                return;
            };
            if (bench) {
                std.debug.print("[nb-bench] {s} link: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
                bench_t = milliTimestamp();
            }
            nb.postinstall.runPostInstall(alloc, g_io, f) catch |err| {
                stderr.print("nb: {s}: post-install warning: {}\n", .{ f.name, err }) catch {};
            };
            // Cached reinstalls must still produce health evidence — a
            // poisoned or drifted snapshot otherwise sails through with a
            // 179ms "✓" and no probe at all (#356).
            const fast_probe_passed = probeInstalledFormula(alloc, null, f.name, fv, f.install_binaries, .active);
            probe_result.* = if (fast_probe_passed) .passed else .failed;
            if (!fast_probe_passed) {
                stderr.print("nb: {s}: post-install probe warning: declared binaries or linked executables missing\n", .{f.name}) catch {};
            }
            if (bench) std.debug.print("[nb-bench] {s} postinstall: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
            phase.store(@intFromEnum(Phase.done), .release);
            return;
        }
        if (bench) bench_t = milliTimestamp();
        nb.cellar.materialize(g_io, f.bottle_sha256, f.name, expected_ver) catch |err| {
            stderr.print("nb: {s}: materialize failed: {}\n", .{ f.name, err }) catch {};
            fail_reason.* = "materialize failed";
            had_error.store(true, .release);
            phase.store(@intFromEnum(Phase.failed), .release);
            return;
        };
        if (bench) std.debug.print("[nb-bench] {s} materialize: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
    }

    // 4. Relocate (fix Homebrew placeholders in Mach-O binaries)
    phase.store(@intFromEnum(Phase.relocating), .release);
    var ver_buf: [256]u8 = undefined;
    const actual_ver = nb.cellar.detectKegVersion(f.name, expected_ver, &ver_buf) orelse expected_ver;
    if (bench) bench_t = milliTimestamp();
    platform.relocate.short.resetIncompleteCount();
    platform.relocate.relocateKeg(alloc, g_io, f.name, actual_ver) catch |err| {
        stderr.print("nb: {s}: relocate failed: {}\n", .{ f.name, err }) catch {};
        fail_reason.* = "relocate failed";
        had_error.store(true, .release);
        phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };
    // Known-incomplete relocation must fail the package instead of warning
    // and continuing: a keg whose loadable files keep foreign runtime paths
    // silently borrows Homebrew's modules when both managers are installed,
    // or breaks outright when they aren't (#355). Failing here also keeps
    // the keg out of the relocated-snapshot cache (#356).
    if (platform.relocate.short.incompleteCount() > 0) {
        stderr.print(
            "nb: {s}: {d} file(s) kept foreign runtime paths because the /opt/nb short-prefix symlink is unavailable; run `sudo nb init`, then reinstall\n",
            .{ f.name, platform.relocate.short.incompleteCount() },
        ) catch {};
        nb.cellar.remove(f.name, actual_ver) catch {};
        fail_reason.* = "incomplete relocation (run `sudo nb init` and retry)";
        had_error.store(true, .release);
        phase.store(@intFromEnum(Phase.failed), .release);
        return;
    }
    if (bench) {
        std.debug.print("[nb-bench] {s} relocate: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
        bench_t = milliTimestamp();
    }
    // 4b. Replace @@HOMEBREW_*@@ placeholders in text files (shebangs, scripts, configs)
    platform.relocate.replaceKegPlaceholders(g_io, f.name, actual_ver, f.dependencies);
    // 4c. Re-seal framework bundles AFTER every file mutation so the
    //     sealed-resource signature matches the final on-disk state.
    platform.relocate.sealKegBundles(alloc, g_io, f.name, actual_ver);
    if (bench) {
        std.debug.print("[nb-bench] {s} placeholders+seal: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
        bench_t = milliTimestamp();
    }
    // Save post-relocation snapshot so future reinstalls skip steps 4/4b/4c (~1500ms → ~10ms)
    const relocated_cache_key = if (is_source_build and (f.install_binaries.len > 0 or f.install_bin_renames.len > 0) and nb.store.isValidSha256(f.source_sha256))
        f.source_sha256
    else
        f.bottle_sha256;
    nb.store.saveRelocatedEntry(g_io, relocated_cache_key, f.name, actual_ver) catch {};
    if (bench) {
        std.debug.print("[nb-bench] {s} snapshot: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
        bench_t = milliTimestamp();
    }

    // 5. Link binaries
    phase.store(@intFromEnum(Phase.linking), .release);
    linkFormulaKeg(alloc, f.name, actual_ver, use_shims, requested, all_formulae) catch |err| {
        stderr.print("nb: {s}: link failed: {}\n", .{ f.name, err }) catch {};
        fail_reason.* = "link failed";
        had_error.store(true, .release);
        phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };
    if (bench) {
        std.debug.print("[nb-bench] {s} link: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });
        bench_t = milliTimestamp();
    }

    // 6. Post-install (non-fatal)
    nb.postinstall.runPostInstall(alloc, g_io, f) catch |err| {
        stderr.print("nb: {s}: post-install warning: {}\n", .{ f.name, err }) catch {};
    };
    const probe_passed = probeInstalledFormula(alloc, null, f.name, actual_ver, f.install_binaries, .active);
    probe_result.* = if (probe_passed) .passed else .failed;
    if (!probe_passed) {
        stderr.print("nb: {s}: post-install probe warning: declared binaries or linked executables missing\n", .{f.name}) catch {};
    }
    if (bench) std.debug.print("[nb-bench] {s} postinstall: {d}ms\n", .{ f.name, milliTimestamp() - bench_t });

    phase.store(@intFromEnum(Phase.done), .release);
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(g_io, path, .{}) catch return false;
    return true;
}
fn runRemove(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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

/// One readdir of the content-addressed store into a sha256 set, replacing
/// one access(2) syscall per `nb list --versions` history row.
fn loadStoreBlobSet(alloc: std.mem.Allocator) ?std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(alloc);
    var dir = std.Io.Dir.openDirAbsolute(g_io, paths.STORE_DIR, .{ .iterate = true }) catch return null;
    defer dir.close(g_io);
    var iter = dir.iterate();
    while (iter.next(g_io) catch null) |entry| {
        if (entry.name.len != 64) continue; // sha256 hex blob dirs only
        const name = alloc.dupe(u8, entry.name) catch continue;
        set.put(name, {}) catch continue;
    }
    return set;
}

/// One readdir of a keg's Cellar dir into a version list, replacing one
/// readdir per history row for that keg.
fn loadKegVersionDirs(alloc: std.mem.Allocator, name: []const u8) ?[][]const u8 {
    var buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ paths.CELLAR_DIR, name }) catch return null;
    var versions: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.openDirAbsolute(g_io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(g_io);
    var iter = dir.iterate();
    while (iter.next(g_io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const v = alloc.dupe(u8, entry.name) catch continue;
        versions.append(alloc, v) catch continue;
    }
    return versions.toOwnedSlice(alloc) catch null;
}

fn runList(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    var show_versions = false;
    var names_only = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--versions")) {
            show_versions = true;
        } else if (std.mem.eql(u8, a, "--names")) {
            names_only = true;
        } else {
            stderr.print("nb: unknown list option '{s}'\nUsage: nb list [--versions|--names]\n", .{a}) catch {};
            std.process.exit(1);
        }
    }
    if (show_versions and names_only) {
        stderr.print("nb: --versions and --names cannot be combined\nUsage: nb list [--versions|--names]\n", .{}) catch {};
        std.process.exit(1);
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    const kegs = db.listInstalled(alloc) catch {
        stderr.print("nb: failed to list formulae\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(kegs);

    const casks = db.listInstalledCasks(alloc) catch {
        stderr.print("nb: failed to list casks\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(casks);

    const debs = db.listInstalledDebs(alloc) catch {
        stderr.print("nb: failed to list deb packages\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(debs);

    // --versions: per-row switchable flags, computed up front by a small
    // worker pool. A row is switchable when its blob is in the store (one
    // shared readdir, answered from a set) or its keg dir still exists (one
    // readdir per keg, not per row). On real inventories with long upgrade
    // histories that is ~900 existence checks down to ~200 dir scans.
    const VersionRow = struct { version: []const u8, sha256: []const u8, switchable: bool };
    var version_rows: ?[]?[]VersionRow = null;
    if (show_versions and kegs.len > 0) {
        if (alloc.alloc(?[]VersionRow, kegs.len) catch null) |rows| {
            version_rows = rows;
            @memset(rows, null);
            var any = false;
            for (kegs, 0..) |keg, ki| {
                const hist = db.getHistory(keg.name);
                if (hist.len == 0) continue;
                const r = alloc.alloc(VersionRow, hist.len) catch continue;
                for (hist, 0..) |h, hi| r[hi] = .{ .version = h.version, .sha256 = h.sha256, .switchable = false };
                rows[ki] = r;
                any = true;
            }
            if (any) {
                var store_set = loadStoreBlobSet(alloc);
                defer if (store_set) |*s| s.deinit();
                const VCtx = struct {
                    rows: []?[]VersionRow,
                    kegs: []const nb.database.Keg,
                    store_set: ?*std.StringHashMap(void),
                    next_idx: std.atomic.Value(usize),
                };
                const vWorker = struct {
                    fn run(ctx: *VCtx) void {
                        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                        defer arena.deinit();
                        const a = arena.allocator();
                        while (true) {
                            const ki = ctx.next_idx.fetchAdd(1, .monotonic);
                            if (ki >= ctx.kegs.len) break;
                            const keg = ctx.kegs[ki];
                            const r = ctx.rows[ki] orelse continue;
                            var versions_loaded = false;
                            var versions: [][]const u8 = &.{};
                            for (r) |*row| {
                                row.switchable = (row.sha256.len > 0 and if (ctx.store_set) |set|
                                    set.contains(row.sha256)
                                else
                                    row.sha256.len > 0 and nb.store.hasEntry(g_io, row.sha256)) or blk: {
                                    if (!versions_loaded) {
                                        versions = loadKegVersionDirs(a, keg.name) orelse &.{};
                                        versions_loaded = true;
                                    }
                                    for (versions) |v| {
                                        if (std.mem.eql(u8, v, row.version)) break :blk true;
                                    }
                                    break :blk false;
                                };
                            }
                        }
                    }
                }.run;
                var vctx: VCtx = .{ .rows = rows, .kegs = kegs, .store_set = if (store_set) |*s| s else null, .next_idx = std.atomic.Value(usize).init(0) };
                const n_workers = @min(@as(usize, 4), kegs.len);
                if (n_workers > 1) {
                    var handles: [4]std.Thread = undefined;
                    var spawned: usize = 0;
                    for (0..n_workers) |_| {
                        handles[spawned] = std.Thread.spawn(.{}, vWorker, .{&vctx}) catch break;
                        spawned += 1;
                    }
                    for (handles[0..spawned]) |h| h.join();
                } else {
                    vWorker(&vctx);
                }
            }
        }
    }

    if (kegs.len == 0 and casks.len == 0 and debs.len == 0) {
        if (!names_only) stdout.print("No packages installed.\n", .{}) catch {};
        return;
    }

    for (kegs, 0..) |keg, ki| {
        if (names_only) {
            stdout.print("{s}\n", .{keg.name}) catch {};
            continue;
        }
        const pin_tag = if (keg.pinned) " [pinned]" else "";
        stdout.print("{s} {s}{s}\n", .{ keg.name, keg.version, pin_tag }) catch {};
        if (show_versions) {
            // Newest history first; flags were precomputed above.
            const rows = if (version_rows) |vrs| vrs[ki] orelse &.{} else &.{};
            var idx = rows.len;
            while (idx > 0) {
                idx -= 1;
                const row = rows[idx];
                const avail = if (row.switchable) " (switchable)" else "";
                stdout.print("    {s}{s}\n", .{ row.version, avail }) catch {};
            }
        }
    }
    for (casks) |c| {
        if (names_only) {
            stdout.print("{s}\n", .{c.token}) catch {};
        } else {
            stdout.print("{s} {s} (cask)\n", .{ c.token, c.version }) catch {};
        }
    }
    for (debs) |d| {
        if (names_only) {
            stdout.print("{s}\n", .{d.name}) catch {};
        } else {
            stdout.print("{s} {s} (deb)\n", .{ d.name, d.version }) catch {};
        }
    }
}

// ── nb where ──

fn containsAsciiCaseless(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (needle_lower.len > haystack.len) return false;
    const end = haystack.len - needle_lower.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var j: usize = 0;
        while (j < needle_lower.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != needle_lower[j]) break;
        }
        if (j == needle_lower.len) return true;
    }
    return false;
}

fn runWhere(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    if (args.len == 0) {
        stderr.print("nb: no pattern specified\nUsage: nb where <pattern>\n", .{}) catch {};
        std.process.exit(1);
    }

    const pattern = args[0];
    var lower_buf: [256]u8 = undefined;
    const plen = @min(pattern.len, lower_buf.len);
    for (pattern[0..plen], 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const needle = lower_buf[0..plen];

    // 1. Installed (kegs, casks, debs)
    stdout.print("\x1b[1m==> installed matching \"{s}\":\x1b[0m\n", .{pattern}) catch {};
    var installed_hits: usize = 0;
    if (nb.database.Database.open(alloc)) |opened_db| {
        var db = opened_db;
        defer db.close();

        const kegs = db.listInstalled(alloc) catch &.{};
        defer if (kegs.len > 0) alloc.free(kegs);
        for (kegs) |k| {
            if (!containsAsciiCaseless(k.name, needle)) continue;
            const pin_tag = if (k.pinned) " [pinned]" else "";
            stdout.print("  {s} {s}{s}\n", .{ k.name, k.version, pin_tag }) catch {};
            installed_hits += 1;
        }

        if (db.listInstalledCasks(alloc)) |casks| {
            defer alloc.free(casks);
            for (casks) |c| {
                if (!containsAsciiCaseless(c.token, needle)) continue;
                stdout.print("  {s} {s} (cask)\n", .{ c.token, c.version }) catch {};
                installed_hits += 1;
            }
        } else |_| {}

        if (db.listInstalledDebs(alloc)) |debs| {
            defer alloc.free(debs);
            for (debs) |d| {
                if (!containsAsciiCaseless(d.name, needle)) continue;
                stdout.print("  {s} {s} (deb)\n", .{ d.name, d.version }) catch {};
                installed_hits += 1;
            }
        } else |_| {}
    } else |_| {
        stdout.print("  (could not open database)\n", .{}) catch {};
    }
    if (installed_hits == 0) stdout.print("  (none)\n", .{}) catch {};

    // 2. Files in prefix/{bin,lib,opt}
    const prefix_subs = [_][]const u8{ "bin", "lib", "opt" };
    for (prefix_subs) |sub| {
        var dir_buf: [256]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ PREFIX, sub }) catch continue;
        stdout.print("\x1b[1m==> {s}/ matching \"{s}\":\x1b[0m\n", .{ dir_path, pattern }) catch {};
        var file_hits: usize = 0;
        if (std.Io.Dir.openDirAbsolute(g_io, dir_path, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(g_io);
            var iter = dir.iterate();
            while (iter.next(g_io) catch null) |entry| {
                if (!containsAsciiCaseless(entry.name, needle)) continue;
                const kind_tag: []const u8 = switch (entry.kind) {
                    .directory => "/",
                    .sym_link => "@",
                    else => "",
                };
                if (file_hits < 50) {
                    stdout.print("  {s}{s}\n", .{ entry.name, kind_tag }) catch {};
                }
                file_hits += 1;
            }
        } else |_| {}
        if (file_hits == 0) {
            stdout.print("  (none)\n", .{}) catch {};
        } else if (file_hits > 50) {
            stdout.print("  ... and {d} more\n", .{file_hits - 50}) catch {};
        }
    }

    // 3. Formula/cask index hits
    stdout.print("\x1b[1m==> formula index matches for \"{s}\":\x1b[0m\n", .{pattern}) catch {};
    if (nb.search_api.search(alloc, pattern)) |results| {
        defer {
            for (results) |r| r.deinit(alloc);
            if (results.len > 0) alloc.free(results);
        }
        if (results.len == 0) {
            stdout.print("  (none)\n", .{}) catch {};
        } else {
            const cap = @min(results.len, 20);
            for (results[0..cap]) |r| {
                const tag = if (r.is_cask) " (cask)" else "";
                stdout.print("  {s} {s}{s} - {s}\n", .{ r.name, r.version, tag, r.desc }) catch {};
            }
            if (results.len > cap) {
                stdout.print("  ... and {d} more\n", .{results.len - cap}) catch {};
            }
        }
    } else |err| {
        stdout.print("  (search failed: {s})\n", .{@errorName(err)}) catch {};
    }
}

// ── nb leaves ──

fn runLeaves(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    const show_tree = for (args) |a| {
        if (std.mem.eql(u8, a, "--tree")) break true;
    } else false;

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

    if (kegs.len == 0) {
        stdout.print("No packages installed.\n", .{}) catch {};
        return;
    }

    // Build a set of all packages that are depended upon by other installed packages.
    // A "leaf" is an installed package that no other installed package depends on.
    var depended_on = std.StringHashMap(void).init(alloc);
    defer depended_on.deinit();

    // For tree mode, track each package's deps
    var pkg_deps = std.StringHashMap([]const []const u8).init(alloc);
    defer pkg_deps.deinit();

    // O(1) lookup from keg name -> Keg (version for tree output, membership test).
    // Keyed on borrowed slices from kegs, so lifetime follows `kegs`.
    var keg_set = std.StringHashMap(nb.database.Keg).init(alloc);
    defer keg_set.deinit();
    keg_set.ensureTotalCapacity(@intCast(kegs.len)) catch {};
    for (kegs) |k| keg_set.put(k.name, k) catch {};

    // Keep fetched formulae alive until both loops finish; depended_on and
    // pkg_deps hold slices that point into formula memory.
    var fetched_formulae: std.ArrayList(nb.formula.Formula) = .empty;
    defer {
        for (fetched_formulae.items) |f| f.deinit(alloc);
        fetched_formulae.deinit(alloc);
    }

    // The validated bulk sidecar carries dependency lists, so one scan can
    // answer almost every installed formula without parsing hundreds of JSON
    // objects. Only taps/upstream-only tokens enter the fallback worker queue.
    var dependency_index: ?nb.bulk_versions.DependencyIndex = null;
    defer if (dependency_index) |*idx| idx.deinit();
    const bulk_names = alloc.alloc([]const u8, kegs.len) catch null;
    defer if (bulk_names) |names| alloc.free(names);
    if (bulk_names) |names| {
        for (kegs, 0..) |keg, i| names[i] = keg.name;
        dependency_index = nb.bulk_versions.loadFormulaDependenciesForNames(alloc, names) catch null;
    }

    var fallback_indices: std.ArrayList(usize) = .empty;
    defer fallback_indices.deinit(alloc);
    for (kegs, 0..) |keg, i| {
        const in_bulk = if (dependency_index) |*idx| idx.get(keg.name) != null else false;
        if (!in_bulk) fallback_indices.append(alloc, i) catch {};
    }

    // Parallel fetch — each worker thread owns a persistent std.http.Client and
    // steals work from a shared atomic counter. Mirrors checkWorkerFn pattern.
    const SlotState = enum(u8) { empty, filled };
    const Slot = struct {
        state: SlotState = .empty,
        formula: nb.formula.Formula = undefined,
    };

    const slots = alloc.alloc(Slot, kegs.len) catch {
        stderr.print("nb: out of memory\n", .{}) catch {};
        return;
    };
    defer alloc.free(slots);
    for (slots) |*s| s.* = .{};

    const LeavesCtx = struct {
        kegs_: []const nb.database.Keg,
        fallback_indices_: []const usize,
        slots_: []Slot,
        bulk_snapshot_loaded_: bool,
        next_idx: *std.atomic.Value(usize),
        alloc_: std.mem.Allocator,
    };

    const leavesWorkerFn = struct {
        fn run(ctx: LeavesCtx) void {
            var client = nb.proxy.Client.init(ctx.alloc_, g_io);
            defer client.deinit();

            while (true) {
                const work_idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (work_idx >= ctx.fallback_indices_.len) break;
                const idx = ctx.fallback_indices_[work_idx];
                const keg = ctx.kegs_[idx];
                // A missing row is authoritative only when the validated bulk
                // snapshot loaded successfully. Local per-name caches still get
                // first refusal for taps and old/renamed formulae.
                const formula = nb.api_client.fetchFormulaLocal(ctx.alloc_, keg.name) orelse
                    (nb.api_client.fetchFormulaWithClientOptions(ctx.alloc_, client.ptr(), keg.name, .{
                        .check_upstream_freshness = !ctx.bulk_snapshot_loaded_,
                    }) catch continue);
                ctx.slots_[idx].formula = formula;
                ctx.slots_[idx].state = .filled;
            }
        }
    }.run;

    var next_idx = std.atomic.Value(usize).init(0);
    const ctx = LeavesCtx{
        .kegs_ = kegs,
        .fallback_indices_ = fallback_indices.items,
        .slots_ = slots,
        .bulk_snapshot_loaded_ = dependency_index != null,
        .next_idx = &next_idx,
        .alloc_ = alloc,
    };

    const n_threads = @min(fallback_indices.items.len, 8);
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..n_threads) |_| {
        threads[spawned] = std.Thread.spawn(.{}, leavesWorkerFn, .{ctx}) catch continue;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();

    // Collect results serially, preserving `kegs` order.
    var failed_names: std.ArrayList([]const u8) = .empty;
    defer failed_names.deinit(alloc);
    fetched_formulae.ensureTotalCapacity(alloc, fallback_indices.items.len) catch {};
    for (kegs, 0..) |keg, i| {
        var deps: []const []const u8 = undefined;
        if (if (dependency_index) |*idx| idx.get(keg.name) else null) |bulk_deps| {
            deps = bulk_deps;
        } else {
            if (slots[i].state != .filled) {
                failed_names.append(alloc, keg.name) catch {};
                continue;
            }
            fetched_formulae.append(alloc, slots[i].formula) catch {
                slots[i].formula.deinit(alloc);
                continue;
            };
            deps = fetched_formulae.items[fetched_formulae.items.len - 1].dependencies;
        }
        if (show_tree) pkg_deps.put(keg.name, deps) catch {};
        for (deps) |dep| {
            if (std.mem.eql(u8, dep, keg.name)) continue; // skip self-dep
            // O(1) membership test against installed kegs.
            if (keg_set.contains(dep)) depended_on.put(dep, {}) catch {};
        }
    }

    if (failed_names.items.len > 0) {
        stderr.print("nb: warning: could not fetch metadata for {d} package(s); results may be incomplete:\n", .{failed_names.items.len}) catch {};
        const max_show = @min(failed_names.items.len, 5);
        for (failed_names.items[0..max_show]) |n| {
            stderr.print("    {s}\n", .{n}) catch {};
        }
        if (failed_names.items.len > max_show) {
            stderr.print("    ... and {d} more\n", .{failed_names.items.len - max_show}) catch {};
        }
        stderr.print("    (run `nb cleanup --prune-kegs` to remove phantom DB entries — see #279)\n", .{}) catch {};
    }

    // Print leaves (packages not depended on by any other installed package)
    for (kegs) |keg| {
        if (!depended_on.contains(keg.name)) {
            const pin_tag = if (keg.pinned) " [pinned]" else "";
            stdout.print("{s} {s}{s}\n", .{ keg.name, keg.version, pin_tag }) catch {};

            if (show_tree) {
                if (pkg_deps.get(keg.name)) |deps| {
                    for (deps) |dep| {
                        // O(1) lookup — only show installed deps.
                        if (keg_set.get(dep)) |other| {
                            stdout.print("  {s} {s}\n", .{ dep, other.version }) catch {};
                        }
                    }
                }
            }
        }
    }
}

// ── nb info ──

/// Package-wide active-probe budget: bounds total probe wall time per keg.
const PROBE_PACKAGE_BUDGET: std.Io.Clock.Duration = .{
    .raw = std.Io.Duration.fromSeconds(10),
    .clock = .awake,
};
/// Per-executable slice so one interactive tool can't starve the rest (#317).
const PROBE_BINARY_BUDGET: std.Io.Clock.Duration = .{
    .raw = std.Io.Duration.fromSeconds(2),
    .clock = .awake,
};

const ExecProbeOutcome = enum { answered, unresponsive, skipped };
const ExecProbeSeverity = enum { fail, warn };

fn probeExecutableCommand(
    alloc: std.mem.Allocator,
    stdout: ?StdoutWriter,
    owner: []const u8,
    path: []const u8,
    session: *nb.trust_probe.Session,
    severity: ExecProbeSeverity,
) ExecProbeOutcome {
    // Restricted login shells never answer argv probes (#317 field note).
    if (nb.trust_probe.isInteractiveShellLike(std.fs.path.basename(path))) {
        if (stdout) |out| out.print("  - {s}: skipped interactive shell: {s}\n", .{ owner, path }) catch {};
        return .skipped;
    }
    switch (session.probe(alloc, path)) {
        .answered => return .answered,
        .budget_exhausted => {
            if (stdout) |out| out.print("  - {s}: package probe budget exhausted; skipped: {s}\n", .{ owner, path }) catch {};
            return .skipped;
        },
        .unresponsive => {
            switch (severity) {
                .fail => if (stdout) |out| out.print("  ✗ {s}: binary did not answer within its 2s probe slice: {s}\n", .{ owner, path }) catch {},
                .warn => if (stdout) |out| out.print("  ! {s}: discovered binary did not answer (informational): {s}\n", .{ owner, path }) catch {},
            }
            return .unresponsive;
        },
    }
}

fn verifyCaskSignature(alloc: std.mem.Allocator, stdout: ?StdoutWriter, token: []const u8, app_path: []const u8, session: *nb.trust_probe.Session) bool {
    if (comptime builtin.os.tag != .macos) return true;
    if (!std.mem.endsWith(u8, app_path, ".app")) return true;

    const res = std.process.run(alloc, g_io, .{
        .argv = &.{ "codesign", "--verify", "--deep", "--strict", app_path },
        .cwd = .{ .path = session.cwd() },
        .timeout = session.timeout(),
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        if (stdout) |out| out.print("  ✗ {s}: codesign verification could not run for {s}\n", .{ token, app_path }) catch {};
        return false;
    };
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    switch (res.term) {
        .exited => |code| {
            if (code == 0) return true;
        },
        else => {},
    }
    if (stdout) |out| out.print("  ✗ {s}: codesign verification failed for {s}\n", .{ token, app_path }) catch {};
    return false;
}

fn pathIsWithin(path: []const u8, root: []const u8) bool {
    var resolved_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = std.Io.Dir.cwd().realPathFile(g_io, path, &resolved_path_buf) catch return false;
    const resolved_path = resolved_path_buf[0..path_len];
    var resolved_root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = std.Io.Dir.cwd().realPathFile(g_io, root, &resolved_root_buf) catch return false;
    const resolved_root = resolved_root_buf[0..root_len];
    return std.mem.eql(u8, resolved_path, resolved_root) or
        (resolved_path.len > resolved_root.len and
            std.mem.startsWith(u8, resolved_path, resolved_root) and
            resolved_path[resolved_root.len] == '/');
}

fn symlinkTargetIsWithin(linked: []const u8, root: []const u8) bool {
    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_len = std.Io.Dir.readLinkAbsolute(g_io, linked, &target_buf) catch return false;
    return pathIsWithin(target_buf[0..target_len], root);
}

fn ownedCaskBinaryTarget(cask: nb.database.CaskRecord, linked: []const u8, target_buf: []u8) ?[]const u8 {
    const target_len = std.Io.Dir.readLinkAbsolute(g_io, linked, target_buf) catch return null;
    const target = target_buf[0..target_len];
    const canonical_token = if (cask.canonical_token.len > 0) cask.canonical_token else cask.token;
    const filesystem_token = nb.cask_installer.filesystemToken(canonical_token) orelse return null;
    var caskroom_buf: [1024]u8 = undefined;
    const caskroom = std.fmt.bufPrint(&caskroom_buf, "{s}/{s}/{s}", .{
        paths.CASKROOM_DIR, filesystem_token, cask.version,
    }) catch return null;
    if (pathIsWithin(target, caskroom)) return target;

    for (cask.apps) |app| {
        var app_buf: [1024]u8 = undefined;
        const app_path = std.fmt.bufPrint(&app_buf, "/Applications/{s}", .{app}) catch continue;
        if (pathIsWithin(target, app_path)) return target;
    }
    return null;
}

fn probeInstalledCask(
    alloc: std.mem.Allocator,
    stdout: ?StdoutWriter,
    cask: nb.database.CaskRecord,
    mode: ProbeMode,
) bool {
    var ok = true;
    var active_checks: usize = 0;
    var active_session: ?nb.trust_probe.Session = if (mode == .active)
        nb.trust_probe.Session.init(g_io, PROBE_PACKAGE_BUDGET, PROBE_BINARY_BUDGET) catch return false
    else
        null;
    defer if (active_session) |*session| session.deinit();
    const canonical_token = if (cask.canonical_token.len > 0) cask.canonical_token else cask.token;
    const caskroom_token = nb.cask_installer.filesystemToken(canonical_token) orelse return false;
    var caskroom_buf: [512]u8 = undefined;
    const caskroom_dir = std.fmt.bufPrint(&caskroom_buf, "{s}/{s}/{s}", .{ paths.CASKROOM_DIR, caskroom_token, cask.version }) catch return false;
    std.Io.Dir.accessAbsolute(g_io, caskroom_dir, .{}) catch {
        if (stdout) |out| out.print("  ✗ {s}: missing Caskroom payload {s}\n", .{ cask.token, caskroom_dir }) catch {};
        return false;
    };
    if (cask.apps.len == 0 and cask.binaries.len == 0) {
        if (stdout) |out| out.print("  ✗ {s}: no app or binary artifacts are recorded for verification\n", .{cask.token}) catch {};
        return false;
    }

    for (cask.apps) |app| {
        var app_buf: [1024]u8 = undefined;
        const app_path = std.fmt.bufPrint(&app_buf, "/Applications/{s}", .{app}) catch {
            ok = false;
            continue;
        };
        std.Io.Dir.accessAbsolute(g_io, app_path, .{}) catch {
            if (stdout) |out| out.print("  ✗ {s}: missing app artifact {s}\n", .{ cask.token, app_path }) catch {};
            ok = false;
            continue;
        };
        if (mode == .active) {
            active_checks += 1;
            if (active_session) |*session| {
                if (!verifyCaskSignature(alloc, stdout, cask.token, app_path, session)) ok = false;
            } else {
                ok = false;
            }
        }
    }

    for (cask.binaries) |bin| {
        const base = std.fs.path.basename(bin);
        var linked_buf: [512]u8 = undefined;
        const linked = std.fmt.bufPrint(&linked_buf, "{s}/bin/{s}", .{ PREFIX, base }) catch {
            ok = false;
            continue;
        };
        std.Io.Dir.accessAbsolute(g_io, linked, .{ .execute = true }) catch {
            if (stdout) |out| out.print("  ✗ {s}: linked binary not executable: {s}\n", .{ cask.token, linked }) catch {};
            ok = false;
            continue;
        };
        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const target = ownedCaskBinaryTarget(cask, linked, &target_buf) orelse {
            if (stdout) |out| out.print("  ✗ {s}: binary link is not owned by this cask: {s}\n", .{ cask.token, linked }) catch {};
            ok = false;
            continue;
        };
        std.Io.Dir.accessAbsolute(g_io, target, .{ .execute = true }) catch {
            ok = false;
            continue;
        };
        if (mode == .active) {
            if (active_session) |*session| {
                switch (probeExecutableCommand(alloc, stdout, cask.token, target, session, .fail)) {
                    .answered => active_checks += 1,
                    .unresponsive => {
                        active_checks += 1;
                        ok = false;
                    },
                    .skipped => {},
                }
            } else {
                ok = false;
            }
        }
    }

    if (mode == .active and active_checks == 0) {
        if (stdout) |out| out.print("  ✗ {s}: no executable or signed app artifact was actively checked\n", .{cask.token}) catch {};
        return false;
    }
    if (ok and mode == .active) {
        if (stdout) |out| out.print("  ✓ {s} {s}: cask probe passed\n", .{ cask.token, cask.version }) catch {};
    }
    return ok;
}

fn probeInstalledFormula(
    alloc: std.mem.Allocator,
    stdout: ?StdoutWriter,
    name: []const u8,
    version: []const u8,
    declared_binaries: []const []const u8,
    mode: ProbeMode,
) bool {
    var ok = true;
    var active_checks: usize = 0;
    var active_session: ?nb.trust_probe.Session = if (mode == .active)
        nb.trust_probe.Session.init(g_io, PROBE_PACKAGE_BUDGET, PROBE_BINARY_BUDGET) catch return false
    else
        null;
    defer if (active_session) |*session| session.deinit();
    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/Cellar/{s}/{s}", .{ PREFIX, name, version }) catch return false;
    std.Io.Dir.accessAbsolute(g_io, keg_dir, .{}) catch {
        if (stdout) |out| out.print("  ✗ {s}: missing Cellar dir {s}\n", .{ name, keg_dir }) catch {};
        return false;
    };
    if (declared_binaries.len > 0) {
        for (declared_binaries) |rel| {
            const base = std.fs.path.basename(rel);
            var cellar_bin_buf: [512]u8 = undefined;
            const cellar_bin = std.fmt.bufPrint(&cellar_bin_buf, "{s}/{s}", .{ keg_dir, rel }) catch {
                ok = false;
                continue;
            };
            std.Io.Dir.accessAbsolute(g_io, cellar_bin, .{ .execute = true }) catch {
                if (stdout) |out| out.print("  ✗ {s}: declared binary not executable: {s}\n", .{ name, cellar_bin }) catch {};
                ok = false;
            };
            // Leftover @@HOMEBREW_*@@ tokens mean an unrecognized placeholder
            // survived relocation (e.g. the pre-fix @@HOMEBREW_JAVA@@, #358).
            if (platform.relocate.placeholder.fileContainsPlaceholder(cellar_bin)) {
                if (stdout) |out| out.print("  ✗ {s}: unreplaced @@HOMEBREW_*@@ placeholder in {s}\n", .{ name, cellar_bin }) catch {};
                ok = false;
            }
            var linked_buf: [512]u8 = undefined;
            const linked = std.fmt.bufPrint(&linked_buf, "{s}/bin/{s}", .{ PREFIX, base }) catch {
                ok = false;
                continue;
            };
            std.Io.Dir.accessAbsolute(g_io, linked, .{ .execute = true }) catch {
                if (stdout) |out| out.print("  ✗ {s}: linked binary not executable: {s}\n", .{ name, linked }) catch {};
                ok = false;
                continue;
            };
            if (!symlinkTargetIsWithin(linked, keg_dir)) {
                if (stdout) |out| out.print("  ✗ {s}: public link is not owned by this keg: {s}\n", .{ name, linked }) catch {};
                ok = false;
                continue;
            }
            if (mode == .active) {
                if (active_session) |*session| {
                    // Declared binaries are the formula's own contract — an
                    // unresponsive one fails the package.
                    switch (probeExecutableCommand(alloc, stdout, name, cellar_bin, session, .fail)) {
                        .answered => active_checks += 1,
                        .unresponsive => {
                            active_checks += 1;
                            ok = false;
                        },
                        .skipped => {},
                    }
                } else {
                    ok = false;
                }
            }
        }
    } else {
        // No declared binaries in metadata: discover executable files in keg/bin
        // and verify any that exist are linked. Library-only kegs can pass the
        // structural check, but cannot produce active executable evidence.
        // Verdict policy (#317): discovered extras that don't answer are
        // warnings only — perl ships interactive utilities (cpan, instmodsh)
        // that never answer argv probes even on a healthy install. The package
        // fails when the primary binary (basename == formula name) is
        // unresponsive, or when nothing probed answers at all.
        var any_answered = false;
        var bin_buf: [512]u8 = undefined;
        const bin_dir = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{keg_dir}) catch return false;
        if (std.Io.Dir.openDirAbsolute(g_io, bin_dir, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(g_io);
            var iter = dir.iterate();
            while (iter.next(g_io) catch null) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                var keg_bin_buf: [512]u8 = undefined;
                const keg_bin = std.fmt.bufPrint(&keg_bin_buf, "{s}/{s}", .{ bin_dir, entry.name }) catch continue;
                std.Io.Dir.accessAbsolute(g_io, keg_bin, .{ .execute = true }) catch continue;
                if (platform.relocate.placeholder.fileContainsPlaceholder(keg_bin)) {
                    if (stdout) |out| out.print("  ✗ {s}: unreplaced @@HOMEBREW_*@@ placeholder in {s}\n", .{ name, keg_bin }) catch {};
                    ok = false;
                }
                var linked_buf: [512]u8 = undefined;
                const linked = std.fmt.bufPrint(&linked_buf, "{s}/bin/{s}", .{ PREFIX, entry.name }) catch {
                    ok = false;
                    continue;
                };
                std.Io.Dir.accessAbsolute(g_io, linked, .{ .execute = true }) catch {
                    if (stdout) |out| out.print("  ✗ {s}: discovered binary not linked/executable: {s}\n", .{ name, linked }) catch {};
                    ok = false;
                    continue;
                };
                if (!symlinkTargetIsWithin(linked, keg_dir)) {
                    if (stdout) |out| out.print("  ✗ {s}: public link is not owned by this keg: {s}\n", .{ name, linked }) catch {};
                    ok = false;
                    continue;
                }
                if (mode == .active) {
                    if (active_session) |*session| {
                        const is_primary = std.mem.eql(u8, entry.name, name);
                        const severity: ExecProbeSeverity = if (is_primary) .fail else .warn;
                        switch (probeExecutableCommand(alloc, stdout, name, keg_bin, session, severity)) {
                            .answered => {
                                active_checks += 1;
                                any_answered = true;
                            },
                            .unresponsive => {
                                active_checks += 1;
                                if (is_primary) ok = false;
                            },
                            .skipped => {},
                        }
                    } else {
                        ok = false;
                    }
                }
            }
        } else |_| {}

        if (mode == .active and active_checks > 0 and !any_answered) {
            if (stdout) |out| out.print("  ✗ {s}: no probed executable answered\n", .{name}) catch {};
            ok = false;
        }
    }

    // Static archives are byte-pass relocated at install time; a remaining
    // Homebrew prefix means the keg predates the fix or its relocation was
    // incomplete — reinstalling repairs it (#357).
    if (mode == .active) {
        var lib_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&lib_buf, "{s}/lib", .{keg_dir})) |lib_dir| {
            if (!scanStaticArchivesClean(stdout, name, lib_dir, 0)) ok = false;
        } else |_| {}
    }

    if (mode == .active and active_checks == 0) {
        if (stdout) |out| out.print("  ✗ {s}: no executable artifact was actively checked\n", .{name}) catch {};
        return false;
    }
    if (ok and mode == .active) {
        if (stdout) |out| out.print("  ✓ {s} {s}: local probe passed\n", .{ name, version }) catch {};
    }
    return ok;
}

/// Walk `dir_path` for static .a archives and report any that still carry a
/// foreign (Homebrew) prefix (#357). Returns false when at least one is found.
fn scanStaticArchivesClean(stdout: ?StdoutWriter, name: []const u8, dir_path: []const u8, depth: u32) bool {
    if (depth > 4) return true;
    var clean = true;
    var dir = std.Io.Dir.openDirAbsolute(g_io, dir_path, .{ .iterate = true }) catch return true;
    defer dir.close(g_io);
    var iter = dir.iterate();
    while (iter.next(g_io) catch null) |entry| {
        var child_buf: [1024]u8 = undefined;
        const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => {
                if (!scanStaticArchivesClean(stdout, name, child, depth + 1)) clean = false;
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".a")) continue;
                if (platform.relocate.placeholder.fileContainsForeignPrefix(child)) {
                    if (stdout) |out| out.print("  ✗ {s}: static archive retains a foreign prefix (reinstall to repair): {s}\n", .{ name, child }) catch {};
                    clean = false;
                }
            },
            else => {},
        }
    }
    return clean;
}

fn runInfo(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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

    // One command snapshot: multi-name info must not reparse the registry and
    // installation database for every token. Reusing the HTTP client also keeps
    // live metadata fallbacks on one connection pool.
    var registry: ?nb.upstream_registry.Registry = nb.upstream_registry.loadRegistry(alloc) catch null;
    defer if (registry) |*r| r.deinit(alloc);
    var db: ?nb.database.Database = nb.database.Database.open(alloc) catch null;
    defer if (db) |*d| d.close();
    var client = nb.proxy.Client.init(alloc, g_io);
    defer client.deinit();

    for (names.items) |name| {
        if (is_cask) {
            showCaskInfo(alloc, stdout, stderr, name, if (db) |*d| d else null);
        } else {
            // Try formula first; on failure, try cask as fallback for a hint.
            const f = nb.api_client.fetchFormulaWithClientAndUpstreamRegistry(
                alloc,
                client.ptr(),
                name,
                if (registry) |*r| r else null,
            ) catch {
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
            defer f.deinit(alloc);
            const bottled = f.bottle_url.len > 0;
            var version_buf: [256]u8 = undefined;
            const displayed_version = f.effectiveVersion(&version_buf);
            stdout.print("{s} {s}{s}\n", .{
                f.name,
                displayed_version,
                if (bottled) " (bottled)" else "",
            }) catch {};
            if (f.desc.len > 0) stdout.print("  {s}\n", .{f.desc}) catch {};
            if (f.homepage.len > 0) stdout.print("  homepage: {s}\n", .{f.homepage}) catch {};
            if (f.license.len > 0) stdout.print("  license: {s}\n", .{f.license}) catch {};
            const artifact_sha = formulaArtifactSha(f);
            var trust_tier: []const u8 = if (artifact_sha.len > 0) "checksum-verified" else "unverified";
            if (registry) |*loaded_registry| {
                if (loaded_registry.find(f.name, .formula)) |record| {
                    if (record.upstream.verified) trust_tier = "source-verified";
                }
            }
            var local_probe_status: []const u8 = "not recorded";
            var local_probe_time: i64 = 0;
            if (db) |*loaded_db| {
                if (loaded_db.findKeg(f.name)) |keg| {
                    // Install evidence is version/checksum/platform-specific: an
                    // older keg or a probe produced under different semantics must
                    // not promote the metadata currently displayed.
                    if (artifact_sha.len > 0 and
                        std.mem.eql(u8, keg.version, displayed_version) and
                        std.mem.eql(u8, keg.sha256, artifact_sha) and
                        keg.probed_at >= keg.installed_at and
                        keg.probed_at > 0)
                    {
                        local_probe_time = keg.probed_at;
                        const compatible = keg.probe_schema == LOCAL_PROBE_SCHEMA and
                            keg.probe_platform == LOCAL_PROBE_PLATFORM;
                        const structurally_valid = compatible and
                            keg.probe_success and
                            probeInstalledFormula(alloc, null, f.name, keg.version, f.install_binaries, .structural);
                        local_probe_status = if (!compatible)
                            "stale"
                        else if (!keg.probe_success)
                            "failed"
                        else if (structurally_valid)
                            "passed"
                        else
                            "invalidated";
                        if (structurally_valid) trust_tier = "install-verified";
                    }
                }
            }
            if (local_probe_time > 0) {
                stdout.print("  trust: {s} (local probe: {s}, {d})\n", .{ trust_tier, local_probe_status, local_probe_time }) catch {};
            } else {
                stdout.print("  trust: {s} (local probe: not recorded; run `nb doctor --probe {s}`)\n", .{ trust_tier, f.name }) catch {};
            }
            if (bottled) {
                stdout.print("  url: {s}\n", .{f.bottle_url}) catch {};
                if (f.bottle_sha256.len > 0) stdout.print("  sha256: {s}\n", .{f.bottle_sha256}) catch {};
            } else if (f.source_url.len > 0) {
                stdout.print("  url: {s} (source)\n", .{f.source_url}) catch {};
                if (f.source_sha256.len > 0) stdout.print("  sha256: {s}\n", .{f.source_sha256}) catch {};
            }
            stdout.print("  deps: ", .{}) catch {};
            for (f.dependencies, 0..) |dep, i| {
                if (i > 0) stdout.print(", ", .{}) catch {};
                stdout.print("{s}", .{dep}) catch {};
            }
            stdout.print("\n", .{}) catch {};
            if (f.build_deps.len > 0) {
                stdout.print("  build deps: ", .{}) catch {};
                for (f.build_deps, 0..) |dep, i| {
                    if (i > 0) stdout.print(", ", .{}) catch {};
                    stdout.print("{s}", .{dep}) catch {};
                }
                stdout.print("\n", .{}) catch {};
            }
            if (f.caveats.len > 0) {
                stdout.print("  caveats:\n", .{}) catch {};
                var line_it = std.mem.splitScalar(u8, f.caveats, '\n');
                while (line_it.next()) |line| {
                    stdout.print("    {s}\n", .{line}) catch {};
                }
            }
        }
    }
}

fn showCaskInfo(alloc: std.mem.Allocator, stdout: anytype, stderr: anytype, name: []const u8, db: ?*nb.database.Database) void {
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
    if (cask.metadata_source == .verified_upstream) {
        stdout.print("  source: verified upstream\n", .{}) catch {};
    } else {
        stdout.print("  source: homebrew metadata\n", .{}) catch {};
    }
    stdout.print("  url: {s}\n", .{cask.url}) catch {};

    // SHA256
    stdout.print("  sha256: {s}\n", .{cask.sha256}) catch {};

    const has_valid_sha256 = nb.store.isValidSha256(cask.sha256);
    var trust_tier: []const u8 = if (has_valid_sha256) "checksum-verified" else "unverified";
    if (cask.metadata_source == .verified_upstream) trust_tier = "source-verified";
    const has_immutable_identity = has_valid_sha256 and
        !cask.auto_updates and
        !std.mem.eql(u8, cask.version, "latest");
    var local_probe_status: []const u8 = "not recorded";
    var local_probe_time: i64 = 0;
    if (has_immutable_identity) {
        if (db) |loaded_db| {
            // Prefer a canonical record and fall back to the requested alias,
            // while requiring the stored canonical identity to still match.
            if (loaded_db.findCask(cask.token) orelse loaded_db.findCask(name)) |installed| {
                if (std.mem.eql(u8, installed.canonical_token, cask.token) and
                    std.mem.eql(u8, installed.version, cask.version) and
                    std.mem.eql(u8, installed.sha256, cask.sha256) and
                    installed.probed_at > 0)
                {
                    local_probe_time = installed.probed_at;
                    const compatible = installed.probe_schema == LOCAL_PROBE_SCHEMA and
                        installed.probe_platform == LOCAL_PROBE_PLATFORM;
                    const structurally_valid = compatible and
                        installed.probe_success and
                        probeInstalledCask(alloc, null, installed, .structural);
                    local_probe_status = if (!compatible)
                        "stale"
                    else if (!installed.probe_success)
                        "failed"
                    else if (structurally_valid)
                        "passed"
                    else
                        "invalidated";
                    if (structurally_valid) trust_tier = "install-verified";
                }
            }
        }
    }
    if (local_probe_time > 0) {
        stdout.print("  trust: {s} (local probe: {s}, {d})\n", .{ trust_tier, local_probe_status, local_probe_time }) catch {};
    } else {
        stdout.print("  trust: {s} (local probe: not recorded; run `nb doctor --probe {s}`)\n", .{ trust_tier, cask.token }) catch {};
    }

    printCaskSecurityWarnings(stdout, "  ", &cask);

    // Artifacts
    if (cask.artifacts.len > 0) {
        stdout.print("  artifacts:\n", .{}) catch {};
        for (cask.artifacts) |art| {
            switch (art) {
                .app => |a| stdout.print("    app: {s}\n", .{a}) catch {},
                .binary => |b| stdout.print("    binary: {s} -> {s}\n", .{ b.source, b.target }) catch {},
                .pkg => |p| stdout.print("    pkg: {s}\n", .{p}) catch {},
                .font => |f| stdout.print("    font: {s}\n", .{f}) catch {},
                .artifact => |a| stdout.print("    artifact: {s} -> {s}\n", .{ a.source, a.target }) catch {},
                .suite => |s| stdout.print("    suite: {s} -> {s}\n", .{ s.source, s.target }) catch {},
                .installer_script => |script| stdout.print("    installer: {s} ({d} args)\n", .{ script.executable, script.args.len }) catch {},
                .uninstall => |u| {
                    if (u.quit.len > 0) stdout.print("    uninstall quit: {s}\n", .{u.quit}) catch {};
                    if (u.pkgutil.len > 0) stdout.print("    uninstall pkgutil: {s}\n", .{u.pkgutil}) catch {};
                },
            }
        }
    }
}

fn printCaskSecurityWarnings(writer: anytype, indent: []const u8, cask: *const nb.cask.Cask) void {
    if (cask.security_warnings.len == 0) return;

    writer.print("{s}security warnings:\n", .{indent}) catch {};
    for (cask.security_warnings) |warning| {
        const severity = if (warning.severity.len > 0) warning.severity else "unknown";
        writer.print("{s}  [{s}]", .{ indent, severity }) catch {};
        if (warning.ghsa_id.len > 0) writer.print(" {s}", .{warning.ghsa_id}) catch {};
        if (warning.cve_id.len > 0) writer.print(" {s}", .{warning.cve_id}) catch {};
        writer.print(" {s}\n", .{warning.summary}) catch {};

        if (warning.affected_versions.len > 0) {
            writer.print("{s}    affected: {s}\n", .{ indent, warning.affected_versions }) catch {};
        }
        if (warning.patched_versions.len > 0) {
            writer.print("{s}    patched: {s}\n", .{ indent, warning.patched_versions }) catch {};
        }
        if (warning.url.len > 0) {
            writer.print("{s}    url: {s}\n", .{ indent, warning.url }) catch {};
        }
    }
}

// ── nb upgrade ──

// ── nb search ──

fn runSearch(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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

    pub fn deinit(self: *const @This(), alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.old_ver);
        alloc.free(self.new_ver);
    }
};

fn getOutdatedPackages(alloc: std.mem.Allocator, db: *nb.database.Database, filter_names: []const []const u8, check_casks: bool, check_kegs: bool) std.ArrayList(Outdated) {
    const stdout = StdoutWriter{};
    var result: std.ArrayList(Outdated) = .empty;

    // Collect all packages to check
    const CheckItem = struct {
        name: []const u8,
        old_ver: []const u8,
        is_cask: bool,
        is_pinned: bool,
    };
    var to_check: std.ArrayList(CheckItem) = .empty;
    defer to_check.deinit(alloc);

    if (check_casks) {
        const installed_casks = db.listInstalledCasks(alloc) catch &.{};
        defer alloc.free(installed_casks);
        for (installed_casks) |c| {
            if (filter_names.len > 0) {
                var found = false;
                for (filter_names) |n| {
                    if (std.mem.eql(u8, n, c.token) or
                        std.mem.eql(u8, n, c.canonical_token))
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }
            to_check.append(alloc, .{
                .name = if (c.canonical_token.len > 0) c.canonical_token else c.token,
                .old_ver = c.version,
                .is_cask = true,
                .is_pinned = false,
            }) catch {};
        }
    }

    if (check_kegs) {
        const installed_kegs = db.listInstalled(alloc) catch &.{};
        defer alloc.free(installed_kegs);
        for (installed_kegs) |k| {
            if (filter_names.len > 0) {
                var found = false;
                for (filter_names) |n| {
                    if (std.mem.eql(u8, n, k.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }
            to_check.append(alloc, .{
                .name = k.name,
                .old_ver = k.version,
                .is_cask = false,
                .is_pinned = k.pinned,
            }) catch {};
        }
    }

    if (to_check.items.len == 0) return result;

    stdout.print("==> Checking {d} package(s) for updates...\n", .{to_check.items.len}) catch {};

    // Bulk fast path: resolve available versions from the cached Homebrew
    // bulk lists (one streaming scan each, shared with `nb search`, 1h TTL)
    // instead of one API round trip per installed package. Packages missing
    // from the lists (tap formulas, upstream-only records) fall through to
    // the per-name fetch workers below.
    var formula_index: ?nb.bulk_versions.VersionIndex = null;
    defer if (formula_index) |*idx| idx.deinit();
    var cask_index: ?nb.bulk_versions.VersionIndex = null;
    defer if (cask_index) |*idx| idx.deinit();
    {
        var formula_names: std.ArrayList([]const u8) = .empty;
        defer formula_names.deinit(alloc);
        var cask_names: std.ArrayList([]const u8) = .empty;
        defer cask_names.deinit(alloc);
        var formula_names_complete = true;
        var cask_names_complete = true;
        for (to_check.items) |item| {
            if (item.is_cask) {
                cask_names.append(alloc, item.name) catch {
                    cask_names_complete = false;
                };
            } else {
                formula_names.append(alloc, item.name) catch {
                    formula_names_complete = false;
                };
            }
        }
        if (formula_names_complete and formula_names.items.len > 0) {
            formula_index = nb.bulk_versions.loadFormulaIndexForNames(alloc, formula_names.items) catch null;
        }
        // The bulk cask list exposes a single top-level version that can be
        // the arm64 variant. Intel must use per-cask parsing so architecture
        // conditionals select an actually installable version (#342).
        if (cask_names_complete and cask_names.items.len > 0 and builtin.cpu.arch != .x86_64) {
            cask_index = nb.bulk_versions.loadCaskIndexForNames(alloc, cask_names.items) catch null;
        }
    }

    // Parallel version check — each thread gets its own HTTP client
    const VersionResult = struct {
        new_ver_buf: [128]u8 = undefined,
        new_ver_len: usize = 0,
        has_update: bool = false,
    };

    const version_results = alloc.alloc(VersionResult, to_check.items.len) catch return result;
    defer alloc.free(version_results);
    for (version_results) |*r| r.* = .{};

    // Resolve what we can locally; queue only the misses for network fetch.
    // Freshness may be skipped only when a successfully loaded bulk index
    // positively proved that the token was absent.
    const FetchRequest = struct {
        item_idx: usize,
        proven_bulk_miss: bool,
    };
    var fetch_queue: std.ArrayList(FetchRequest) = .empty;
    defer fetch_queue.deinit(alloc);
    for (to_check.items, 0..) |item, i| {
        const idx_ref: ?*const nb.bulk_versions.VersionIndex = if (item.is_cask)
            (if (cask_index) |*ci| ci else null)
        else
            (if (formula_index) |*fi| fi else null);
        const latest: ?[]const u8 = if (idx_ref) |ir| ir.get(item.name) else null;
        if (latest) |new_ver| {
            if (nb.version.isNewer(new_ver, item.old_ver)) {
                const len = @min(new_ver.len, 128);
                @memcpy(version_results[i].new_ver_buf[0..len], new_ver[0..len]);
                version_results[i].new_ver_len = len;
                version_results[i].has_update = true;
            }
        } else {
            fetch_queue.append(alloc, .{
                .item_idx = i,
                .proven_bulk_miss = !item.is_cask and formula_index != null,
            }) catch {};
        }
    }

    const CheckCtx = struct {
        items: []const CheckItem,
        queue: []const FetchRequest,
        results: []VersionResult,
        next_idx: *std.atomic.Value(usize),
        alloc_: std.mem.Allocator,
    };

    const checkWorkerFn = struct {
        fn run(ctx: CheckCtx) void {
            var client = nb.proxy.Client.init(ctx.alloc_, g_io);
            defer client.deinit();

            while (true) {
                const qpos = ctx.next_idx.fetchAdd(1, .monotonic);
                if (qpos >= ctx.queue.len) break;
                const request = ctx.queue[qpos];
                const idx = request.item_idx;
                const item = ctx.items[idx];

                if (item.is_cask) {
                    const cask = nb.api_client.fetchCask(ctx.alloc_, item.name) catch continue;
                    defer cask.deinit(ctx.alloc_);
                    if (nb.version.isNewer(cask.version, item.old_ver)) {
                        const len = @min(cask.version.len, 128);
                        @memcpy(ctx.results[idx].new_ver_buf[0..len], cask.version[0..len]);
                        ctx.results[idx].new_ver_len = len;
                        ctx.results[idx].has_update = true;
                    }
                } else {
                    // A proven fresh-bulk miss may be a tap or a verified-
                    // upstream-only token. If the index failed to load, retain
                    // the normal live freshness cross-check for correctness.
                    const formula = nb.api_client.fetchFormulaWithClientOptions(ctx.alloc_, client.ptr(), item.name, .{
                        .check_upstream_freshness = !request.proven_bulk_miss,
                    }) catch continue;
                    defer formula.deinit(ctx.alloc_);
                    var latest_buf: [256]u8 = undefined;
                    const latest = formula.effectiveVersion(&latest_buf);
                    if (nb.version.isNewer(latest, item.old_ver)) {
                        const len = @min(latest.len, 128);
                        @memcpy(ctx.results[idx].new_ver_buf[0..len], latest[0..len]);
                        ctx.results[idx].new_ver_len = len;
                        ctx.results[idx].has_update = true;
                    }
                }
            }
        }
    }.run;

    if (fetch_queue.items.len > 0) {
        var next_idx = std.atomic.Value(usize).init(0);
        const ctx = CheckCtx{
            .items = to_check.items,
            .queue = fetch_queue.items,
            .results = version_results,
            .next_idx = &next_idx,
            .alloc_ = alloc,
        };

        const n_threads = @min(fetch_queue.items.len, 8);
        var threads: [8]std.Thread = undefined;
        var spawned: usize = 0;

        for (0..n_threads) |_| {
            threads[spawned] = std.Thread.spawn(.{}, checkWorkerFn, .{ctx}) catch continue;
            spawned += 1;
        }
        for (threads[0..spawned]) |t| t.join();
    }

    // Collect results
    for (to_check.items, 0..) |item, i| {
        if (version_results[i].has_update) {
            const new_ver = version_results[i].new_ver_buf[0..version_results[i].new_ver_len];
            const n = alloc.dupe(u8, item.name) catch continue;
            const ov = alloc.dupe(u8, item.old_ver) catch {
                alloc.free(n);
                continue;
            };
            const nv = alloc.dupe(u8, new_ver) catch {
                alloc.free(n);
                alloc.free(ov);
                continue;
            };
            result.append(alloc, .{
                .name = n,
                .old_ver = ov,
                .new_ver = nv,
                .is_cask_pkg = item.is_cask,
                .is_pinned = item.is_pinned,
            }) catch {
                alloc.free(n);
                alloc.free(ov);
                alloc.free(nv);
                continue;
            };
        }
    }

    return result;
}

fn runUpgrade(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    var timer = MonoTimer.start();

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
        } else if (std.mem.startsWith(u8, arg, "--") or std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.ascii.isDigit(arg[1])) {
            // Reject unknown flags so they don't silently become package
            // names (e.g. `nb upgrade --dry-run` previously upgraded a
            // ghost package called "--dry-run" → "all up to date").
            stderr.print("nb: upgrade: unknown flag '{s}' (supported: --cask, --deb)\n", .{arg}) catch {};
            std.process.exit(1);
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

    // If the user supplied package names, every one of them must be
    // installed (as a keg or, when --cask, as a cask). Without this
    // guard, `nb upgrade nonexistent-pkg` silently returned "all up
    // to date" because nothing matched the outdated set.
    if (names.items.len > 0) {
        for (names.items) |n| {
            const found = if (is_cask) (db.findCask(n) != null) else (db.findKeg(n) != null);
            if (!found) {
                const kind = if (is_cask) "cask" else "package";
                stderr.print("nb: upgrade: {s} '{s}' is not installed\n", .{ kind, n }) catch {};
                std.process.exit(1);
            }
        }
    }

    const check_casks = is_cask or names.items.len == 0;
    const check_kegs = !is_cask or names.items.len == 0;
    var outdated = getOutdatedPackages(alloc, &db, names.items, check_casks, check_kegs);
    defer {
        for (outdated.items) |*pkg| pkg.deinit(alloc);
        outdated.deinit(alloc);
    }

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
            // A cask cannot currently be staged while its app/binary destinations
            // are occupied. Never remove the working version first: a metadata or
            // install failure would leave the user with nothing (#348). Preserve
            // it until cask installation supports atomic replacement/rollback.
            stderr.print("nb: {s}: safe cask upgrade is not available yet; keeping {s}\n", .{ pkg.name, pkg.old_ver }) catch {};
            continue;
        } else {
            // Install new keg first; remove old tree only after upgrade succeeds (#153).
            const old_keg = db.findKeg(pkg.name);
            const names_slice: []const []const u8 = &.{pkg.name};
            runInstall(alloc, names_slice);

            if (old_keg) |keg| {
                var ver_buf: [256]u8 = undefined;
                const installed_new = nb.cellar.detectKegVersion(pkg.name, pkg.new_ver, &ver_buf);
                const upgraded = blk: {
                    if (installed_new) |nv| {
                        if (nb.version.isNewer(nv, keg.version)) break :blk true;
                        if (std.mem.eql(u8, nv, pkg.new_ver)) break :blk true;
                    }
                    break :blk false;
                };
                if (!upgraded) {
                    stderr.print("nb: {s}: upgrade did not install {s}; keeping {s}\n", .{ pkg.name, pkg.new_ver, keg.version }) catch {};
                    continue;
                }

                // `runInstall` already persisted the new version, artifact SHA,
                // and probe evidence through its own fresh Database instance.
                // Keep this outer snapshot read-only: rewriting it here would
                // overwrite that identity with the old SHA on close (#349).
                nb.linker.unlinkKeg(pkg.name, keg.version) catch {};
                nb.cellar.remove(pkg.name, keg.version) catch {};
            }
        }
        stdout.print("==> Upgraded {s} ({s} -> {s})\n", .{ pkg.name, pkg.old_ver, pkg.new_ver }) catch {};
    }

    const elapsed_ns: u64 = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
}

// ── nb update ──

/// Refresh the verified-upstream registry cache from the remote so pinned
/// versions stop going stale between binary releases (#308/#310). Best-effort:
/// prints a status line but never aborts the caller.
fn isValidSelfUpdateBinary(path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(g_io, path, .{}) catch return false;
    defer file.close(g_io);

    const st = file.stat(g_io) catch return false;
    if (st.size < 4) return false;

    var magic: [4]u8 = undefined;
    const n = file.readPositionalAll(g_io, &magic, 0) catch return false;
    if (n != magic.len) return false;

    return switch (builtin.os.tag) {
        .linux => magic[0] == 0x7f and magic[1] == 'E' and magic[2] == 'L' and magic[3] == 'F',
        .macos => std.mem.eql(u8, &magic, &.{ 0xcf, 0xfa, 0xed, 0xfe }) or
            std.mem.eql(u8, &magic, &.{ 0xca, 0xfe, 0xba, 0xbe }) or
            std.mem.eql(u8, &magic, &.{ 0xca, 0xfe, 0xba, 0xbf }),
        else => false,
    };
}

fn refreshUpstreamRegistry(alloc: std.mem.Allocator) void {
    const stdout = StdoutWriter{};
    if (nb.upstream_registry.refreshCache(alloc)) |count| {
        stdout.print("==> Refreshed upstream registry ({d} records)\n", .{count}) catch {};
    } else |err| switch (err) {
        error.RemoteRegistryDisabled => {},
        else => stdout.print("==> Could not refresh upstream registry ({s}); using cached/embedded data\n", .{@errorName(err)}) catch {},
    }
}

/// `nb update-registry` — refresh only the verified-upstream registry cache.
fn runUpdateRegistry(alloc: std.mem.Allocator) void {
    const stdout = StdoutWriter{};
    stdout.print("==> Refreshing upstream registry...\n", .{}) catch {};
    refreshUpstreamRegistry(alloc);
}

fn runUpdate(alloc: std.mem.Allocator) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    stdout.print("==> Updating nanobrew...\n", .{}) catch {};

    // Refresh pinned upstream metadata too — otherwise a current binary keeps
    // stale pins until the next rebuild (#308/#310).
    refreshUpstreamRegistry(alloc);

    // Detect OS and arch at comptime
    const os_name = comptime switch (@import("builtin").os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => @compileError("unsupported OS for self-update"),
    };
    const asset_os_name = comptime switch (@import("builtin").os.tag) {
        .macos => "apple-darwin",
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

    // Check if the remote release is strictly newer. This also prevents
    // prerelease/stale release feeds from downgrading a newer local binary.
    const latest_ver = nb.version.normalizeVersion(tag_name);
    if (!nb.version.isUpdateAvailable(VERSION, latest_ver)) {
        stdout.print("==> Already up to date (v{s})\n", .{VERSION}) catch {};
        return;
    }

    stdout.print("==> Downloading v{s} ({s}-{s})...\n", .{ latest_ver, arch_name, os_name }) catch {};

    // Build download URLs
    const tarball_name = "nb-" ++ arch_name ++ "-" ++ asset_os_name ++ ".tar.gz";
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

    // Download SHA256 checksum (native HTTP with curl/wget fallback).
    // The fallback tools inherit HTTP(S)_PROXY/ALL_PROXY from the parent
    // environment; do not duplicate those settings on their command lines.
    // The native std.http client can fail on GitHub's CDN redirect chain
    // (signed Azure blob URL); fall back to curl, then wget.
    stdout.print("==> Verifying checksum...\n", .{}) catch {};
    const sha_body: []u8 = sha_blk: {
        if (nb.fetch.get(alloc, sha_url)) |body| {
            break :sha_blk body;
        } else |_| {}
        if (std.process.run(alloc, g_io, .{
            .argv = &.{ "curl", "-fsSL", "--retry", "3", sha_url },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        })) |c| {
            defer alloc.free(c.stderr);
            const ok = switch (c.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok and c.stdout.len > 0) break :sha_blk c.stdout;
            alloc.free(c.stdout);
        } else |_| {}
        if (std.process.run(alloc, g_io, .{
            .argv = &.{ "wget", "-q", "--tries=3", "-O", "-", sha_url },
            .stdout_limit = .unlimited,
            .stderr_limit = .unlimited,
        })) |w| {
            defer alloc.free(w.stderr);
            const ok = switch (w.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (ok and w.stdout.len > 0) break :sha_blk w.stdout;
            alloc.free(w.stdout);
        } else |_| {}
        stderr.print("nb: update failed: could not download SHA256 checksum (tried native HTTP, curl, wget)\n", .{}) catch {};
        std.process.exit(1);
    };
    defer alloc.free(sha_body);

    // Parse expected SHA256 (first 64 hex chars)
    const sha_trimmed = std.mem.trimEnd(u8, sha_body, "\n \t");
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

    // Generate random suffix for temp paths to prevent symlink attacks
    var rand_buf: [8]u8 = undefined;
    // Use clock for temp file uniqueness (non-cryptographic randomness is fine for temp paths)
    {
        var _ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &_ts);
        const _seed: u64 = @as(u64, @bitCast(_ts.sec)) ^ (@as(u64, @bitCast(_ts.nsec)) << 32);
        @memcpy(&rand_buf, std.mem.asBytes(&_seed));
    }
    var rand_hex: [16]u8 = undefined;
    const rand_charset = "0123456789abcdef";
    for (rand_buf, 0..) |byte, i| {
        rand_hex[i * 2] = rand_charset[byte >> 4];
        rand_hex[i * 2 + 1] = rand_charset[byte & 0x0f];
    }
    var tmp_tar_buf: [256]u8 = undefined;
    const tmp_tar = std.fmt.bufPrint(&tmp_tar_buf, "{s}/cache/nb-update-{s}.tar.gz", .{ ROOT, &rand_hex }) catch {
        stderr.print("nb: update failed: path too long\n", .{}) catch {};
        std.process.exit(1);
    };
    var tmp_dir_buf: [256]u8 = undefined;
    const tmp_dir = std.fmt.bufPrint(&tmp_dir_buf, "{s}/cache/nb-update-{s}", .{ ROOT, &rand_hex }) catch {
        stderr.print("nb: update failed: path too long\n", .{}) catch {};
        std.process.exit(1);
    };

    // Download tarball to temp file (native HTTP with curl/wget fallback).
    // curl and wget inherit the process environment, including proxy variables.
    var update_telemetry = nb.telemetry.DownloadEvent.start(.self_update, "nanobrew");
    const download_ok: bool = blk: {
        nb.fetch.download(alloc, tarball_url, tmp_tar) catch {
            // Native download failed; try curl
            const curl = std.process.run(alloc, g_io, .{
                .argv = &.{ "curl", "-fsSL", "--retry", "3", "-o", tmp_tar, tarball_url },
            }) catch {
                // curl unavailable; try wget
                const wget = std.process.run(alloc, g_io, .{
                    .argv = &.{ "wget", "-q", "--tries=3", "-O", tmp_tar, tarball_url },
                }) catch {
                    break :blk false;
                };
                defer alloc.free(wget.stdout);
                defer alloc.free(wget.stderr);
                const wget_ok = switch (wget.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
                break :blk wget_ok;
            };
            defer alloc.free(curl.stdout);
            defer alloc.free(curl.stderr);
            const curl_ok = switch (curl.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (!curl_ok) {
                // curl failed; try wget
                const wget = std.process.run(alloc, g_io, .{
                    .argv = &.{ "wget", "-q", "--tries=3", "-O", tmp_tar, tarball_url },
                }) catch {
                    break :blk false;
                };
                defer alloc.free(wget.stdout);
                defer alloc.free(wget.stderr);
                const wget_ok = switch (wget.term) {
                    .exited => |code| code == 0,
                    else => false,
                };
                break :blk wget_ok;
            }
            break :blk true;
        };
        break :blk true;
    };
    if (!download_ok) {
        update_telemetry.fail();
        stderr.print("nb: update failed: could not download release tarball (tried native HTTP, curl, wget)\n", .{}) catch {};
        std.process.exit(1);
    }
    update_telemetry.succeed(nb.telemetry.fileSize(tmp_tar));

    // Compute SHA256 of downloaded tarball
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    {
        var file = std.Io.Dir.openFileAbsolute(g_io, tmp_tar, .{}) catch {
            stderr.print("nb: update failed: could not open downloaded tarball\n", .{}) catch {};
            std.process.exit(1);
        };
        defer file.close(g_io);
        var read_buf: [65536]u8 = undefined;
        var read_offset: u64 = 0;
        while (true) {
            const bytes_read = file.readPositional(g_io, &.{read_buf[0..]}, read_offset) catch {
                stderr.print("nb: update failed: could not read tarball\n", .{}) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
                std.process.exit(1);
            };
            if (bytes_read == 0) break;
            hasher.update(read_buf[0..bytes_read]);
            read_offset += @intCast(bytes_read);
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
        std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
        std.process.exit(1);
    }

    stdout.print("==> Checksum verified, extracting...\n", .{}) catch {};

    // Get current executable path for replacement
    var exe_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path: []const u8 = exe_path_blk: {
        if (comptime builtin.os.tag == .macos) {
            var exe_buf_size: u32 = @intCast(exe_buf.len);
            if (std.c._NSGetExecutablePath(@ptrCast(&exe_buf), &exe_buf_size) != 0) {
                stderr.print("nb: update failed: could not determine executable path\n", .{}) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
                std.process.exit(1);
            }
            break :exe_path_blk std.mem.sliceTo(&exe_buf, 0);
        } else {
            const n_signed = std.c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
            if (n_signed < 0) {
                stderr.print("nb: update failed: could not determine executable path\n", .{}) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
                std.process.exit(1);
            }
            break :exe_path_blk exe_buf[0..@as(usize, @intCast(n_signed))];
        }
    };

    // Extract tarball using tar (to a temp directory — must not already exist)
    std.Io.Dir.createDirAbsolute(g_io, tmp_dir, .default_dir) catch |err| {
        stderr.print("nb: update failed: could not create temp dir: {}\n", .{err}) catch {};
        std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
        std.process.exit(1);
    };

    const extract_result = std.process.run(std.heap.page_allocator, g_io, .{
        .argv = &.{ "tar", "xzf", tmp_tar, "-C", tmp_dir },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    }) catch {
        stderr.print("nb: update failed: could not extract tarball\n", .{}) catch {};
        std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
        std.process.exit(1);
    };
    defer std.heap.page_allocator.free(extract_result.stdout);
    defer std.heap.page_allocator.free(extract_result.stderr);
    switch (extract_result.term) {
        .exited => |code| {
            if (code != 0) {
                stderr.print("nb: update failed: tar exited with code {d}\n", .{code}) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
                std.process.exit(1);
            }
        },
        else => {
            stderr.print("nb: update failed: tar terminated abnormally\n", .{}) catch {};
            std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
            std.process.exit(1);
        },
    }

    // Replace current binary atomically: copy to staged temp, then rename
    var extracted_bin_buf: [512]u8 = undefined;
    const extracted_bin = std.fmt.bufPrint(&extracted_bin_buf, "{s}/nb", .{tmp_dir}) catch {
        std.process.exit(1);
    };

    // Fallback: accept only the expected release binary names, not an arbitrary
    // first "nb*" directory entry, then validate the binary magic before install.
    const bin_exists = blk: {
        const f = std.Io.Dir.openFileAbsolute(g_io, extracted_bin, .{}) catch break :blk false;
        f.close(g_io);
        break :blk true;
    };
    var fallback_bin_buf: [512]u8 = undefined;
    const final_extracted_bin = if (bin_exists) extracted_bin else fb: {
        const expected_fallback = "nb-" ++ arch_name ++ "-" ++ asset_os_name;
        const legacy_fallback = "nb-" ++ arch_name;
        var dir = std.Io.Dir.openDirAbsolute(g_io, tmp_dir, .{ .iterate = true }) catch {
            stderr.print("nb: update failed: could not open extract dir\n", .{}) catch {};
            std.process.exit(1);
        };
        defer dir.close(g_io);
        var iter = dir.iterate();
        while (iter.next(g_io) catch null) |entry| {
            if (entry.kind == .file and
                (std.mem.eql(u8, entry.name, expected_fallback) or std.mem.eql(u8, entry.name, legacy_fallback)))
            {
                break :fb std.fmt.bufPrint(&fallback_bin_buf, "{s}/{s}", .{ tmp_dir, entry.name }) catch {
                    std.process.exit(1);
                };
            }
        }
        stderr.print("nb: update failed: expected extracted binary not found\n", .{}) catch {};
        std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
        std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};
        std.process.exit(1);
    };
    if (!isValidSelfUpdateBinary(final_extracted_bin)) {
        stderr.print("nb: update failed: extracted binary failed validation\n", .{}) catch {};
        std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
        std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};
        std.process.exit(1);
    }

    // Stage: write to a temp location on the same filesystem as the executable
    var staged_buf: [512]u8 = undefined;
    const staged_path = std.fmt.bufPrint(&staged_buf, "{s}.new-{s}", .{ exe_path, &rand_hex }) catch {
        std.process.exit(1);
    };

    // Preserve the existing binary's permission mode; fall back to executable_file
    const existing_perms: std.Io.File.Permissions = blk: {
        const exe_file = std.Io.Dir.openFileAbsolute(g_io, exe_path, .{}) catch break :blk .executable_file;
        defer exe_file.close(g_io);
        const st = exe_file.stat(g_io) catch break :blk .executable_file;
        break :blk st.permissions;
    };

    // Copy extracted binary to staged path
    {
        const src = std.Io.Dir.openFileAbsolute(g_io, final_extracted_bin, .{}) catch {
            stderr.print("nb: update failed: extracted binary not found\n", .{}) catch {};
            std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
            std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};
            std.process.exit(1);
        };
        defer src.close(g_io);
        const dst = std.Io.Dir.createFileAbsolute(g_io, staged_path, .{ .permissions = existing_perms }) catch {
            stderr.print("nb: update failed: could not create staged binary\n", .{}) catch {};
            std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
            std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};
            std.process.exit(1);
        };
        defer dst.close(g_io);
        var copy_buf: [65536]u8 = undefined;
        var copy_offset: u64 = 0;
        while (true) {
            const n = src.readPositional(g_io, &.{copy_buf[0..]}, copy_offset) catch {
                stderr.print("nb: update failed: could not read extracted binary\n", .{}) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
                std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, staged_path) catch {};
                std.process.exit(1);
            };
            if (n == 0) break;
            dst.writeStreamingAll(g_io, copy_buf[0..n]) catch {
                stderr.print("nb: update failed: could not write staged binary\n", .{}) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
                std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};
                std.Io.Dir.deleteFileAbsolute(g_io, staged_path) catch {};
                std.process.exit(1);
            };
            copy_offset += @intCast(n);
        }
    }

    // Atomic rename: replaces the executable in one syscall
    std.Io.Dir.renameAbsolute(staged_path, exe_path, g_io) catch |err| {
        stderr.print("nb: update failed: could not rename binary: {}\n", .{err}) catch {};
        std.Io.Dir.deleteFileAbsolute(g_io, staged_path) catch {};
        std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
        std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};
        std.process.exit(1);
    };

    // Cleanup temp files
    std.Io.Dir.deleteFileAbsolute(g_io, tmp_tar) catch {};
    std.Io.Dir.cwd().deleteTree(g_io, tmp_dir) catch {};

    stdout.print("==> Updated nanobrew to v{s} (was v{s})\n", .{ latest_ver, VERSION }) catch {};
}

// ── nb install --cask ──

/// Collect the app and binary names a cask install records in the DB. App
/// artifacts contribute their app name; suite/artifact payloads that land in
/// /Applications contribute the target basename (so `nb remove` cleans them up).
fn collectCaskDbEntries(
    alloc: std.mem.Allocator,
    artifacts: []const nb.cask.Artifact,
    apps: *std.ArrayList([]const u8),
    binaries: *std.ArrayList([]const u8),
) void {
    for (artifacts) |art| {
        switch (art) {
            .app => |a| apps.append(alloc, a) catch {},
            .binary => |b| binaries.append(alloc, b.target) catch {},
            .suite => |s| if (nb.cask_installer.artifactInstallsToApplications(s.target)) {
                apps.append(alloc, std.fs.path.basename(s.target)) catch {};
            },
            .artifact => |a| if (nb.cask_installer.artifactInstallsToApplications(a.target)) {
                apps.append(alloc, std.fs.path.basename(a.target)) catch {};
            },
            .pkg, .font, .installer_script, .uninstall => {},
        }
    }
}

fn runCaskInstall(alloc: std.mem.Allocator, tokens: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    if (comptime builtin.os.tag == .linux) {
        stderr.print("nb: casks are not supported on Linux yet\n", .{}) catch {};
        std.process.exit(1);
    }

    var timer = MonoTimer.start();
    const cask_trace = nb.cask_installer.caskTraceEnabled();

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: warning: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    var had_error = false;
    for (tokens) |token| {
        const token_timer = MonoTimer.start();
        stdout.print("==> Fetching cask metadata for {s}...\n", .{token}) catch {};
        var phase_timer = MonoTimer.start();
        const cask_meta = nb.api_client.fetchCask(alloc, token) catch {
            stderr.print("nb: cask '{s}' not found\n", .{token}) catch {};
            had_error = true;
            continue;
        };
        defer cask_meta.deinit(alloc);
        nb.cask_installer.traceCaskPhase(cask_trace, token, "metadata", phase_timer.read());

        // Resolve aliases before deciding this is a no-op. A requested alias can
        // be retargeted to a different canonical cask over time; treating the old
        // record as the new cask would orphan payloads and transfer identity.
        if (db.findCask(token)) |existing| {
            const installed_canonical = if (existing.canonical_token.len > 0) existing.canonical_token else existing.token;
            if (std.mem.eql(u8, installed_canonical, cask_meta.token)) {
                stdout.print("==> {s} {s} is already installed\n", .{ token, existing.version }) catch {};
            } else {
                stderr.print("nb: cask alias '{s}' now resolves to '{s}', but the installed record resolves to '{s}'\n", .{
                    token, cask_meta.token, installed_canonical,
                }) catch {};
                stderr.print("    remove the existing cask explicitly before installing the retargeted alias\n", .{}) catch {};
                had_error = true;
            }
            continue;
        }
        if (db.findCask(cask_meta.token)) |existing| {
            stdout.print("==> {s} {s} is already installed\n", .{ cask_meta.token, existing.version }) catch {};
            continue;
        }

        if (cask_meta.metadata_source == .verified_upstream) {
            stdout.print("==> Using verified upstream release metadata for {s}\n", .{token}) catch {};
        }
        if (cask_meta.security_warnings.len > 0) {
            stderr.print("nb: warning: upstream security advisory data is present for {s} {s}\n", .{ cask_meta.name, cask_meta.version }) catch {};
            printCaskSecurityWarnings(stderr, "    ", &cask_meta);
        }

        var cask_conflict_buf: [1024]u8 = undefined;
        const cask_conflict = nb.cask_installer.firstInstallConflict(g_io, cask_meta, &cask_conflict_buf) catch |err| {
            stderr.print("nb: failed to check cask destinations for '{s}': {}\n", .{ token, err }) catch {};
            had_error = true;
            continue;
        };
        if (cask_conflict) |conflict| {
            // The destination already exists. If nanobrew owns this token's
            // Caskroom payload but the DB lost the record (e.g. an earlier
            // multi-cask run was interrupted before it flushed (#302), or only
            // an older version's payload survived), adopt that payload into the
            // DB under its REAL on-disk version instead of refusing. That keeps
            // the cask installable/removable and lets `nb upgrade` bring it
            // current. A foreign app (no Caskroom payload) is still refused so
            // `nb remove` never deletes something nanobrew didn't install.
            var disk_ver_buf: [256]u8 = undefined;
            if (nb.cask_installer.ownedCaskVersionOnDisk(g_io, paths.CASKROOM_DIR, cask_meta.token, cask_meta.version, &disk_ver_buf)) |disk_ver| {
                var apps: std.ArrayList([]const u8) = .empty;
                defer apps.deinit(alloc);
                var binaries: std.ArrayList([]const u8) = .empty;
                defer binaries.deinit(alloc);
                collectCaskDbEntries(alloc, cask_meta.artifacts, &apps, &binaries);
                // Adoption cannot prove which bytes produced an existing payload.
                db.recordCaskInstall(token, cask_meta.token, disk_ver, "", apps.items, binaries.items) catch |err| {
                    stderr.print("nb: could not record existing cask install: {}\n", .{err}) catch {};
                    had_error = true;
                    break;
                };
                db.flush() catch |err| {
                    stderr.print("nb: could not persist existing cask install: {}\n", .{err}) catch {};
                    had_error = true;
                    break;
                };
                if (std.mem.eql(u8, disk_ver, cask_meta.version)) {
                    stdout.print("==> {s} {s} already present on disk; recorded existing install\n", .{ token, disk_ver }) catch {};
                } else {
                    stdout.print("==> {s}: recovered existing install ({s}); run `nb upgrade {s}` to update to {s}\n", .{ token, disk_ver, token, cask_meta.version }) catch {};
                }
                continue;
            }
            stderr.print("nb: refusing to overwrite existing {s} at {s}\n", .{ conflict.kind, conflict.path }) catch {};
            stderr.print("    Move or remove that destination first, or keep {s} managed outside nanobrew.\n", .{cask_meta.name}) catch {};
            had_error = true;
            continue;
        }

        stdout.print("==> Downloading {s} {s}...\n", .{ cask_meta.name, cask_meta.version }) catch {};
        stdout.print("    {s}\n", .{cask_meta.url}) catch {};

        phase_timer = MonoTimer.start();
        nb.cask_installer.installCask(alloc, g_io, cask_meta) catch |err| {
            nb.cask_installer.traceCaskPhase(cask_trace, token, "payload_install_failed", phase_timer.read());
            stderr.print("nb: failed to install cask '{s}': {}\n", .{ token, err }) catch {};
            had_error = true;
            continue;
        };
        nb.cask_installer.traceCaskPhase(cask_trace, token, "payload_install", phase_timer.read());

        // Collect app/binary names from artifacts for the database.
        var apps: std.ArrayList([]const u8) = .empty;
        defer apps.deinit(alloc);
        var binaries: std.ArrayList([]const u8) = .empty;
        defer binaries.deinit(alloc);
        collectCaskDbEntries(alloc, cask_meta.artifacts, &apps, &binaries);

        phase_timer = MonoTimer.start();
        db.recordCaskInstall(token, cask_meta.token, cask_meta.version, cask_meta.sha256, apps.items, binaries.items) catch |err| {
            stderr.print("nb: payload installed but its database record failed: {}\n", .{err}) catch {};
            had_error = true;
            break;
        };
        // Persist after each cask so an interrupted multi-cask run keeps the
        // records for casks that already completed (issue #302).
        db.flush() catch |err| {
            stderr.print("nb: payload installed but its database record could not be persisted: {}\n", .{err}) catch {};
            had_error = true;
            break;
        };
        nb.cask_installer.traceCaskPhase(cask_trace, token, "db_record", phase_timer.read());
        nb.cask_installer.traceCaskPhase(cask_trace, token, "command_total", token_timer.read());

        stdout.print("==> Installed {s} {s}\n", .{ cask_meta.name, cask_meta.version }) catch {};
    }

    const elapsed_ns: u64 = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
    if (had_error) std.process.exit(1);
}

// ── nb remove --cask ──

fn runCaskRemove(alloc: std.mem.Allocator, tokens: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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

        const caskroom_token = if (record.canonical_token.len > 0) record.canonical_token else record.token;
        nb.cask_installer.removeCask(alloc, g_io, caskroom_token, record.version, record.apps, record.binaries) catch |err| {
            stderr.print("nb: failed to remove cask '{s}': {}\n", .{ token, err }) catch {};
            continue;
        };

        db.recordCaskRemoval(token, alloc) catch {};
        stdout.print("==> Removed {s}\n", .{token}) catch {};
    }
}

// ── Version display (compile-time; remote latest is only for `checkForUpdate`) ──

/// Version in `nb help` / usage banner: always this binary's build (#130).
fn getDisplayVersion() []const u8 {
    return VERSION;
}

fn printUsage() void {
    const stdout = StdoutWriter{};
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
        \\  install --shims <formula>
        \\                           Install with private dependency executables
        \\  install --cask <app>     Install macOS applications
        \\  install --deb <pkg>      Install .deb packages (Linux, replaces apt-get)
        \\  remove <formula>         Uninstall packages
        \\  remove --cask <app>      Uninstall macOS applications
        \\  remove --deb <pkg>       Uninstall .deb packages (Linux)
        \\  list [--versions|--names]
        \\                           List installed packages, casks, and debs
        \\  leaves [--tree]          List packages with no dependents
        \\  info <formula>           Show formula info from Homebrew API
        \\  info --cask <app>        Show cask info from Homebrew API
        \\  search <query>           Search for formulas and casks
        \\  where <pattern>          Show installed kegs, prefix files, and index hits matching pattern
        \\  upgrade [formula]        Upgrade packages (or all if none specified)
        \\  upgrade --cask [app]     Upgrade casks (or all if none specified)
        \\  upgrade --deb            Upgrade all installed .deb packages
        \\  update                   Self-update nanobrew (also refreshes the upstream registry)
        \\  update-registry          Refresh only the verified-upstream version registry
        \\  doctor [--probe [pkg]]   Check installation health / probe installed packages
        \\  cleanup [--dry-run]      Remove stale caches and orphaned files
        \\  outdated                 List packages with newer versions available
        \\  pin <package>            Pin a package (skip during upgrade)
        \\  unpin <package>          Unpin a package
        \\  rollback <package>       Rollback to previous version
        \\  switch <pkg>@<version>   Reactivate a previously-installed version
        \\  link <package>           Link an installed keg's binaries into the prefix
        \\  unlink <package>         Remove an installed keg's prefix links (keg stays)
        \\  bundle [dump|install]    Export/import package lists (Brewfile-compatible)
        \\  deps [--tree] <formula>  Show dependency tree
        \\  services [list|start|stop|restart] [name]
        \\                           Manage background services
        \\  completions [zsh|bash|fish]
        \\                           Generate shell completions
        \\  telemetry [status|on|off]
        \\                           Show or change anonymous download telemetry
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
        \\  nb where krun
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

fn runDoctor(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};
    var issues: usize = 0;

    if (args.len > 0 and std.mem.eql(u8, args[0], "--probe")) {
        var db = nb.database.Database.open(alloc) catch {
            stderr.print("nb: doctor --probe: could not open database\n", .{}) catch {};
            std.process.exit(1);
        };
        defer db.close();
        if (args.len > 1) {
            for (args[1..]) |name| {
                if (db.findKeg(name)) |keg| {
                    const f = nb.api_client.fetchFormula(alloc, name) catch null;
                    defer if (f) |formula| formula.deinit(alloc);
                    const declared = installedFormulaDeclarations(f, keg);
                    const passed = probeInstalledFormula(alloc, stdout, keg.name, keg.version, declared, .active);
                    db.recordKegProbe(keg.name, keg.version, keg.sha256, passed, LOCAL_PROBE_SCHEMA, LOCAL_PROBE_PLATFORM) catch {};
                    if (!passed) issues += 1;
                    continue;
                }
                if (db.findCask(name)) |cask| {
                    const passed = probeInstalledCask(alloc, stdout, cask, .active);
                    db.recordCaskProbe(cask.canonical_token, cask.version, cask.sha256, passed, LOCAL_PROBE_SCHEMA, LOCAL_PROBE_PLATFORM) catch {};
                    if (!passed) issues += 1;
                    continue;
                }
                stdout.print("  ✗ {s}: not installed\n", .{name}) catch {};
                issues += 1;
            }
        } else {
            const kegs = db.listInstalled(alloc) catch &.{};
            defer if (kegs.len > 0) alloc.free(kegs);
            for (kegs) |keg| {
                const f = nb.api_client.fetchFormula(alloc, keg.name) catch null;
                defer if (f) |formula| formula.deinit(alloc);
                const declared = installedFormulaDeclarations(f, keg);
                const passed = probeInstalledFormula(alloc, stdout, keg.name, keg.version, declared, .active);
                db.recordKegProbe(keg.name, keg.version, keg.sha256, passed, LOCAL_PROBE_SCHEMA, LOCAL_PROBE_PLATFORM) catch {};
                if (!passed) issues += 1;
            }
            for (db.casks.items) |cask| {
                const passed = probeInstalledCask(alloc, stdout, cask, .active);
                db.recordCaskProbe(cask.canonical_token, cask.version, cask.sha256, passed, LOCAL_PROBE_SCHEMA, LOCAL_PROBE_PLATFORM) catch {};
                if (!passed) issues += 1;
            }
        }
        // `std.process.exit` skips defers, so persist failed evidence before the
        // non-zero exit as well as successful results.
        db.flush() catch |err| {
            stderr.print("nb: doctor --probe: could not persist evidence: {} (package state changed; rerun the probe)\n", .{err}) catch {};
            issues += 1;
        };
        printDoctorSummary(stdout, issues);
        if (issues > 0) std.process.exit(1);
        return;
    }
    if (args.len > 0) {
        stderr.print("Usage: nb doctor [--probe [package...]]\n", .{}) catch {};
        std.process.exit(1);
    }

    stdout.print("==> Checking nanobrew installation...\n", .{}) catch {};

    // 1. Check /opt/nanobrew is writable
    if (std.Io.Dir.accessAbsolute(g_io, ROOT, .{ .write = true })) {
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
        if (std.Io.Dir.openDirAbsolute(g_io, dir, .{})) |d| {
            var dd = d;
            dd.close(g_io);
        } else |_| {
            stdout.print("  ✗ Missing directory: {s}\n", .{dir}) catch {};
            issues += 1;
        }
    }

    // 3. Check for broken symlinks in prefix/bin/
    {
        const LinkCheck = struct {
            name: []const u8,
            broken: bool = false,
            target: [std.Io.Dir.max_path_bytes]u8 = undefined,
            target_len: usize = 0,
        };
        var checks: std.ArrayList(LinkCheck) = .empty;
        defer checks.deinit(alloc);
        if (std.Io.Dir.openDirAbsolute(g_io, PREFIX ++ "/bin", .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(g_io);
            var iter = dir.iterate();
            while (iter.next(g_io) catch null) |entry| {
                if (entry.kind != .sym_link) continue;
                const name = alloc.dupe(u8, entry.name) catch continue;
                checks.append(alloc, .{ .name = name }) catch continue;
            }
        } else |_| {}

        // access(2) on the link path itself resolves the target, cutting the
        // per-link cost from readlink+access to a single syscall (readlink
        // only runs for broken links, to fill the report). A real install has
        // 800+ links here, so a small pool splits the syscall latency.
        const LinkCtx = struct {
            checks: []LinkCheck,
            next_idx: std.atomic.Value(usize),
        };
        const linkWorker = struct {
            fn run(ctx: *LinkCtx) void {
                while (true) {
                    const i = ctx.next_idx.fetchAdd(1, .monotonic);
                    if (i >= ctx.checks.len) break;
                    const c = &ctx.checks[i];
                    var link_buf: [1024]u8 = undefined;
                    const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ PREFIX, c.name }) catch continue;
                    std.Io.Dir.accessAbsolute(g_io, link_path, .{}) catch {
                        c.broken = true;
                        c.target_len = std.Io.Dir.readLinkAbsolute(g_io, link_path, &c.target) catch 0;
                    };
                }
            }
        }.run;
        var link_ctx: LinkCtx = .{ .checks = checks.items, .next_idx = std.atomic.Value(usize).init(0) };
        const n_workers = @min(@as(usize, 8), checks.items.len);
        if (n_workers > 1) {
            var handles: [8]std.Thread = undefined;
            var spawned: usize = 0;
            for (0..n_workers) |_| {
                handles[spawned] = std.Thread.spawn(.{}, linkWorker, .{&link_ctx}) catch break;
                spawned += 1;
            }
            for (handles[0..spawned]) |h| h.join();
        } else if (checks.items.len > 0) {
            linkWorker(&link_ctx);
        }

        var broken_links: usize = 0;
        for (checks.items) |*c| {
            if (!c.broken) continue;
            if (broken_links < 5) {
                stdout.print("  ✗ Broken symlink: {s} -> {s}\n", .{ c.name, c.target[0..c.target_len] }) catch {};
            }
            broken_links += 1;
        }
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
            if (!kegHasBackingCellar(keg.name, keg.version)) {
                stdout.print("  ✗ DB entry '{s}' has no Cellar dir (run `nb cleanup --prune-kegs` to remove)\n", .{keg.name}) catch {};
                issues += 1;
            }
        }

        if (std.Io.Dir.openDirAbsolute(g_io, ROOT ++ "/store", .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(g_io);
            var iter = dir.iterate();
            while (iter.next(g_io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                var found = false;
                for (kegs) |keg| {
                    if (std.mem.eql(u8, keg.sha256, entry.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    for (kegs) |keg| {
                        const hist = db.getHistory(keg.name);
                        for (hist) |h| {
                            if (std.mem.eql(u8, h.sha256, entry.name)) {
                                found = true;
                                break;
                            }
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

        // 5b. Installed versions whose registry pin has since been revoked
        // (CVE'd): new installs already fall back, but machines that
        // installed before the revocation only find out here. Per-keg
        // loadRecord rides the memoized registry snapshot (one pass to build
        // the token map, then O(1) per keg) instead of parsing all ~650KB of
        // records into a DOM just to look up the installed ones.
        {
            // Only registry records that actually carry a revocation get
            // parsed — most snapshots have none, so this sweep is one textual
            // pass instead of a full parse per installed keg.
            const revoked_records = nb.upstream_registry.revokedCandidateFormulaRecords(alloc) catch &.{};
            defer {
                for (revoked_records) |*r| r.deinit(alloc);
                if (revoked_records.len > 0) alloc.free(revoked_records);
            }
            for (kegs) |keg| {
                const record = blk: {
                    for (revoked_records) |*r| {
                        if (std.mem.eql(u8, r.token, keg.name)) break :blk r;
                    }
                    break :blk null;
                } orelse continue;
                const resolved = record.resolved orelse continue;
                const revoked = resolved.revoked orelse continue;
                if (!std.mem.startsWith(u8, keg.version, resolved.version)) continue;
                const advisory = if (revoked.advisory.len > 0) revoked.advisory else "security advisory";
                stdout.print("  ✗ {s} {s} is installed but its pin was revoked ({s})\n", .{ keg.name, keg.version, advisory }) catch {};
                if (revoked.reason.len > 0) {
                    stdout.print("      {s}\n", .{revoked.reason}) catch {};
                }
                if (resolved.fallback) |fallback| {
                    stdout.print("      fix: nb remove {s} && nb install {s}  (installs safe version {s})\n", .{ keg.name, keg.name, fallback.version }) catch {};
                } else {
                    stdout.print("      fix: nb remove {s}  (no safe fallback recorded yet)\n", .{keg.name}) catch {};
                }
                issues += 1;
            }
        }
    }

    // 6. Platform-specific checks
    if (comptime builtin.os.tag == .linux) {
        // Check for patchelf (needed for ELF relocation)
        const pe = std.process.run(alloc, g_io, .{
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
        switch (pe.term) {
            .exited => |code| {
                if (code == 0) {
                    stdout.print("  ✓ patchelf installed\n", .{}) catch {};
                } else {
                    stdout.print("  ✗ patchelf not working\n", .{}) catch {};
                    issues += 1;
                }
            },
            else => {
                stdout.print("  ✗ patchelf not working\n", .{}) catch {};
                issues += 1;
            },
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
    const stdout = StdoutWriter{};
    var dry_run = false;
    var prune_kegs = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) dry_run = true;
        if (std.mem.eql(u8, arg, "--prune-kegs")) prune_kegs = true;
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

    // 1b. Keg trees parked for deferred removal whose reaper never ran.
    if (!dry_run) nb.purge.sweep(g_io);

    // 2. Orphaned blobs and store entries
    stdout.print("  Checking orphaned entries...\n", .{}) catch {};
    cleanupOrphans(alloc, dry_run, &reclaimed, stdout);

    // 3. Phantom kegs (state.json entries with no Cellar dir anywhere) — opt-in
    //    because it mutates the DB. See #279.
    if (prune_kegs) {
        stdout.print("  Checking phantom kegs (state.json entries with no Cellar dir)...\n", .{}) catch {};
        const pruned = cleanupPhantomKegs(alloc, dry_run, stdout);
        if (pruned == 0) stdout.print("    (no phantom kegs found)\n", .{}) catch {};
    }

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
    if (!prune_kegs) {
        stdout.print("    (run with --prune-kegs to also remove phantom DB entries flagged by `nb doctor`)\n", .{}) catch {};
    }
}

/// True if the keg has a backing Cellar directory at any known location:
/// either nb's own prefix or one of the Homebrew cellars (#172 migrated kegs).
/// Shared by `nb doctor` and `nb cleanup --prune-kegs` so they always agree.
fn kegHasBackingCellar(name: []const u8, version: []const u8) bool {
    var nb_buf: [512]u8 = undefined;
    const nb_path = std.fmt.bufPrint(&nb_buf, "{s}/Cellar/{s}/{s}", .{ PREFIX, name, version }) catch return false;
    if (std.Io.Dir.accessAbsolute(g_io, nb_path, .{})) {
        return true;
    } else |_| {}

    const homebrew_cellars = [_][]const u8{
        "/opt/homebrew/Cellar",
        "/usr/local/Cellar",
        "/home/linuxbrew/.linuxbrew/Cellar",
    };
    for (homebrew_cellars) |hb| {
        var hb_buf: [512]u8 = undefined;
        const hb_path = std.fmt.bufPrint(&hb_buf, "{s}/{s}/{s}", .{ hb, name, version }) catch continue;
        if (std.Io.Dir.accessAbsolute(g_io, hb_path, .{})) {
            return true;
        } else |_| {}
    }
    return false;
}

/// Walk state.json kegs and remove any whose Cellar dir is missing in every
/// known location. Returns the count of pruned (or proposed-for-pruning) entries.
/// In dry-run mode, just lists them. See #279.
fn cleanupPhantomKegs(alloc: std.mem.Allocator, dry_run: bool, stdout: anytype) usize {
    var db = nb.database.Database.open(alloc) catch return 0;
    defer db.close();

    const kegs = db.listInstalled(alloc) catch return 0;
    defer if (kegs.len > 0) alloc.free(kegs);

    // Two-pass: collect names first (recordRemoval invalidates the slice),
    // then remove. Bound the buffer so we never blow the stack.
    var phantom_names: [256][]const u8 = undefined;
    var phantom_versions: [256][]const u8 = undefined;
    var n: usize = 0;
    var truncated = false;
    for (kegs) |keg| {
        if (kegHasBackingCellar(keg.name, keg.version)) continue;
        if (n >= phantom_names.len) {
            truncated = true;
            break;
        }
        phantom_names[n] = alloc.dupe(u8, keg.name) catch continue;
        phantom_versions[n] = alloc.dupe(u8, keg.version) catch {
            alloc.free(phantom_names[n]);
            continue;
        };
        n += 1;
    }
    if (truncated) {
        stdout.print("    (capped at {d} entries this pass; re-run `nb cleanup --prune-kegs` to continue)\n", .{phantom_names.len}) catch {};
    }
    defer for (phantom_names[0..n], phantom_versions[0..n]) |pn, pv| {
        alloc.free(pn);
        alloc.free(pv);
    };

    for (phantom_names[0..n], phantom_versions[0..n]) |pn, pv| {
        if (dry_run) {
            stdout.print("    Would prune phantom keg: {s} {s}\n", .{ pn, pv }) catch {};
        } else {
            db.recordRemoval(pn, alloc) catch |err| {
                stdout.print("    warning: could not prune {s}: {s}\n", .{ pn, @errorName(err) }) catch {};
                continue;
            };
            stdout.print("    Pruned phantom keg: {s} {s}\n", .{ pn, pv }) catch {};
        }
    }
    return n;
}

fn runNuke(args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    var force = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) force = true;
    }

    stdout.print("\n\x1b[31;1m  WARNING: This will completely remove nanobrew and all installed packages.\x1b[0m\n\n" ++
        "  The following will be deleted:\n" ++
        "    - /opt/nanobrew          (all packages, cache, database)\n" ++
        "    - ~/.local/bin/nb        (nanobrew binary)\n\n", .{}) catch {};

    if (!force) {
        stdout.print("  Type \x1b[1myes\x1b[0m to confirm: ", .{}) catch {};

        var buf: [16]u8 = undefined;
        const n_signed = std.c.read(std.posix.STDIN_FILENO, &buf, buf.len);
        if (n_signed < 0) {
            stderr.print("nb: failed to read input\n", .{}) catch {};
            std.process.exit(1);
        }
        const n: usize = @intCast(n_signed);
        const input = std.mem.trimEnd(u8, buf[0..n], "\n\r \t");
        if (!std.mem.eql(u8, input, "yes")) {
            stdout.print("\n  Aborted.\n", .{}) catch {};
            return;
        }
    }

    stdout.print("\n==> Removing nanobrew...\n", .{}) catch {};

    // 1. Remove /opt/nanobrew
    stdout.print("  Removing /opt/nanobrew...\n", .{}) catch {};
    std.Io.Dir.cwd().deleteTree(g_io, "/opt/nanobrew") catch |err| {
        stderr.print("nb: failed to remove /opt/nanobrew: {}\n", .{err}) catch {};
        stderr.print("nb: try: sudo nb nuke\n", .{}) catch {};
        std.process.exit(1);
    };

    // 2. Remove nb binary from ~/.local/bin
    stdout.print("  Removing ~/.local/bin/nb...\n", .{}) catch {};
    if (std.c.getenv("HOME")) |_home_cv| {
        const home = std.mem.sliceTo(_home_cv, 0);
        // Validate HOME to prevent path injection
        const home_valid = home.len > 0 and
            home[0] == '/' and
            std.mem.indexOf(u8, home, "..") == null;

        if (!home_valid) {
            stderr.print("nb: warning: HOME env var is invalid, skipping shell config cleanup\n", .{}) catch {};
        } else {
            // Verify HOME is an actual directory
            const home_is_dir = blk: {
                const stat = std.Io.Dir.cwd().statFile(g_io, home, .{}) catch break :blk false;
                break :blk stat.kind == .directory;
            };
            if (!home_is_dir) {
                stderr.print("nb: warning: HOME path does not exist or is not a directory, skipping shell config cleanup\n", .{}) catch {};
            } else {
                var path_buf: [512]u8 = undefined;
                const nb_path = std.fmt.bufPrint(&path_buf, "{s}/.local/bin/nb", .{home}) catch "";
                if (nb_path.len > 0) {
                    std.Io.Dir.deleteFileAbsolute(g_io, nb_path) catch {};
                }
            }
        }
    }

    stdout.print("\n\x1b[32;1m  nanobrew has been removed.\x1b[0m\n\n" ++
        "  You may also want to remove the PATH entry from your shell config:\n" ++
        "    ~/.zshrc or ~/.bashrc — delete the line containing /opt/nanobrew\n\n", .{}) catch {};
}

fn cleanupCacheDir(dir_path: []const u8, dry_run: bool, reclaimed: *u64, stdout: anytype) void {
    var dir = std.Io.Dir.openDirAbsolute(g_io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(g_io);
    var iter = dir.iterate();
    while (iter.next(g_io) catch null) |entry| {
        if (entry.kind == .directory) continue;
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        reclaimed.* += 1024;
        if (dry_run) {
            stdout.print("  Would remove: {s}\n", .{entry.name}) catch {};
        } else {
            std.Io.Dir.deleteFileAbsolute(g_io, path) catch {};
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

    if (std.Io.Dir.openDirAbsolute(g_io, ROOT ++ "/cache/blobs", .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(g_io);
        var iter = dir.iterate();
        while (iter.next(g_io) catch null) |entry| {
            if (!valid_shas.contains(entry.name)) {
                var path_buf: [1024]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/cache/blobs/{s}", .{ ROOT, entry.name }) catch continue;
                // Get actual file size instead of using a hardcoded estimate
                const file_size: u64 = blk: {
                    const f = std.Io.Dir.openFileAbsolute(g_io, path, .{}) catch break :blk 0;
                    defer f.close(g_io);
                    const stat = f.stat(g_io) catch break :blk 0;
                    break :blk stat.size;
                };
                reclaimed.* += file_size;
                if (dry_run) {
                    stdout.print("  Would remove orphaned blob: {s}\n", .{entry.name}) catch {};
                } else {
                    std.Io.Dir.deleteFileAbsolute(g_io, path) catch {};
                }
            }
        }
    } else |_| {}

    if (std.Io.Dir.openDirAbsolute(g_io, ROOT ++ "/store", .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(g_io);
        var iter = dir.iterate();
        while (iter.next(g_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!valid_shas.contains(entry.name)) {
                var path_buf: [1024]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buf, "{s}/store/{s}", .{ ROOT, entry.name }) catch continue;
                // Estimate store entry size by summing file sizes one level deep
                const store_size: u64 = blk: {
                    var sub = std.Io.Dir.openDirAbsolute(g_io, path, .{ .iterate = true }) catch break :blk 0;
                    defer sub.close(g_io);
                    var sub_iter = sub.iterate();
                    var total: u64 = 0;
                    while (sub_iter.next(g_io) catch null) |sub_entry| {
                        if (sub_entry.kind != .file and sub_entry.kind != .sym_link) continue;
                        var fbuf: [1024]u8 = undefined;
                        const fpath = std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ path, sub_entry.name }) catch continue;
                        const f = std.Io.Dir.openFileAbsolute(g_io, fpath, .{}) catch continue;
                        defer f.close(g_io);
                        const stat = f.stat(g_io) catch continue;
                        total += stat.size;
                    }
                    break :blk total;
                };
                reclaimed.* += store_size;
                if (dry_run) {
                    stdout.print("  Would remove orphaned store entry: {s}\n", .{entry.name}) catch {};
                } else {
                    std.Io.Dir.cwd().deleteTree(g_io, path) catch {};
                }
            }
        }
    } else |_| {}
}
// ── nb rollback ──

fn runRollback(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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

        if (prev.sha256.len > 0 and !nb.store.hasEntry(g_io, prev.sha256)) {
            stderr.print("nb: store entry for previous version of '{s}' is missing\n", .{name}) catch {};
            continue;
        }

        stdout.print("==> Rolling back {s} ({s} -> {s})\n", .{ name, keg.version, prev.version }) catch {};

        nb.linker.unlinkKeg(name, keg.version) catch {};
        nb.cellar.remove(name, keg.version) catch {};

        if (prev.sha256.len > 0) {
            nb.cellar.materialize(g_io, prev.sha256, name, prev.version) catch |err| {
                stderr.print("nb: {s}: materialize failed: {}\n", .{ name, err }) catch {};
                continue;
            };
        }

        var ver_buf: [256]u8 = undefined;
        const actual_ver = nb.cellar.detectKegVersion(name, prev.version, &ver_buf) orelse prev.version;
        platform.relocate.relocateKeg(alloc, g_io, name, actual_ver) catch {};
        platform.relocate.replaceKegPlaceholders(g_io, name, actual_ver, &.{});
        platform.relocate.sealKegBundles(alloc, g_io, name, actual_ver);
        nb.linker.linkKeg(name, actual_ver) catch {};
        db.recordInstall(name, prev.version, prev.sha256) catch {};
        stdout.print("==> Rolled back {s} to {s}\n", .{ name, prev.version }) catch {};
    }
}

// ── nb switch ──

/// `nb switch <pkg>@<version>` — reactivate a previously-installed version.
/// `rollback` is the special case "switch to the previous version"; switch
/// targets any version in the install history whose blob is still in the
/// content-addressed store. The currently-active keg is pushed onto history
/// by recordInstall, so switching back and forth works.
fn runSwitch(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    if (args.len == 0) {
        stderr.print("nb: no package specified\nUsage: nb switch <package>@<version>\n", .{}) catch {};
        std.process.exit(1);
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    var had_error = false;
    for (args) |spec| {
        const at = std.mem.lastIndexOfScalar(u8, spec, '@') orelse {
            stderr.print("nb: '{s}': expected <package>@<version> (see `nb list --versions`)\n", .{spec}) catch {};
            had_error = true;
            continue;
        };
        const name = spec[0..at];
        const want = spec[at + 1 ..];
        if (name.len == 0 or want.len == 0) {
            stderr.print("nb: '{s}': expected <package>@<version>\n", .{spec}) catch {};
            had_error = true;
            continue;
        }

        const keg = db.findKeg(name) orelse {
            stderr.print("nb: '{s}' is not installed\n", .{name}) catch {};
            had_error = true;
            continue;
        };
        if (std.mem.eql(u8, keg.version, want)) {
            stdout.print("==> {s} {s} is already active\n", .{ name, want }) catch {};
            continue;
        }

        // Latest matching history entry wins — versions repeat after A→B→A.
        const hist = db.getHistory(name);
        const prev: nb.database.HistoryEntry = blk: {
            var idx = hist.len;
            while (idx > 0) {
                idx -= 1;
                if (std.mem.eql(u8, hist[idx].version, want)) break :blk hist[idx];
            }
            stderr.print("nb: {s} {s} is not in the install history; try `nb install {s}@{s}`\n", .{ name, want, name, want }) catch {};
            had_error = true;
            continue;
        };

        // Fast path: the target keg is still in the Cellar (switch keeps the
        // outgoing version on disk, unlike rollback) — just relink.
        var ver_buf: [256]u8 = undefined;
        const on_disk = nb.cellar.detectKegVersion(name, want, &ver_buf);

        if (on_disk == null) {
            // Not in the Cellar — re-materialize from the content-addressed
            // store. An empty/pruned store entry means a re-download is needed.
            if (prev.sha256.len == 0 or !nb.store.hasEntry(g_io, prev.sha256)) {
                stderr.print("nb: the payload for {s} {s} is no longer on disk; try `nb install {s}@{s}`\n", .{ name, want, name, want }) catch {};
                had_error = true;
                continue;
            }
        }

        stdout.print("==> Switching {s} ({s} -> {s})\n", .{ name, keg.version, want }) catch {};
        nb.linker.unlinkKeg(name, keg.version) catch {};

        const actual_ver = on_disk orelse blk: {
            nb.cellar.materialize(g_io, prev.sha256, name, prev.version) catch |err| {
                stderr.print("nb: {s}: materialize failed: {}\n", .{ name, err }) catch {};
                // Re-link the version we just unlinked so the package isn't
                // left with no active links.
                nb.linker.linkKeg(name, keg.version) catch {};
                had_error = true;
                continue;
            };
            const v = nb.cellar.detectKegVersion(name, prev.version, &ver_buf) orelse prev.version;
            platform.relocate.relocateKeg(alloc, g_io, name, v) catch {};
            platform.relocate.replaceKegPlaceholders(g_io, name, v, &.{});
            platform.relocate.sealKegBundles(alloc, g_io, name, v);
            break :blk v;
        };

        nb.linker.linkKeg(name, actual_ver) catch {};
        db.recordInstall(name, prev.version, prev.sha256) catch {};
        stdout.print("==> Switched {s} to {s} (previous version kept in the Cellar; `nb cleanup` prunes it)\n", .{ name, prev.version }) catch {};
    }
    if (had_error) std.process.exit(1);
}
// ── nb link / nb unlink ──
//
// Manually (re)link or unlink an installed keg's binaries into the prefix,
// mirroring `brew link`/`brew unlink`. This lets a user swap which of two
// packages that install the same binary (e.g. sdl2 vs sdl2-compat) is the
// active one, without uninstall/reinstall churn (#335).
//
// `nb link <pkg>`    — relink the installed keg's binaries/symlinks into the
//                      prefix. Idempotent: already-linked kegs are a no-op.
// `nb unlink <pkg>`  — remove the keg's prefix links (opt/ symlink, bin/
//                      shims, managed wrappers). The Cellar keg is untouched,
//                      so a later `nb link <pkg>` (or `nb install`) restores it.

fn runLink(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    if (args.len == 0) {
        stderr.print("nb: no package specified\nUsage: nb link <package>...\n", .{}) catch {};
        std.process.exit(1);
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    var had_error = false;
    for (args) |raw_name| {
        const name = if (std.mem.lastIndexOfScalar(u8, raw_name, '/')) |pos| raw_name[pos + 1 ..] else raw_name;
        const keg = db.findKeg(name) orelse {
            stderr.print("nb: '{s}' is not installed\n", .{raw_name}) catch {};
            had_error = true;
            continue;
        };

        // Detect the real on-disk version (a keg dir may carry a revision suffix).
        var ver_buf: [256]u8 = undefined;
        const actual_ver = nb.cellar.detectKegVersion(name, keg.version, &ver_buf) orelse keg.version;

        // Verify the keg actually exists in the Cellar before linking, so we
        // don't claim success for a phantom DB entry.
        var keg_dir_buf: [512]u8 = undefined;
        const keg_dir = std.fmt.bufPrint(&keg_dir_buf, "{s}/Cellar/{s}/{s}", .{ PREFIX, name, actual_ver }) catch {
            stderr.print("nb: '{s}': path too long\n", .{name}) catch {};
            had_error = true;
            continue;
        };
        if (std.Io.Dir.accessAbsolute(g_io, keg_dir, .{})) |_| {} else |_| {
            stderr.print("nb: '{s}' {s} has no Cellar directory (run `nb cleanup --prune-kegs`)\n", .{ name, actual_ver }) catch {};
            had_error = true;
            continue;
        }

        // Unlink first (no-op if not linked) then link, so a keg that another
        // package shadowed — or that was linked with a different mode — ends up
        // cleanly linked. linkKeg is itself idempotent.
        nb.linker.unlinkKeg(name, actual_ver) catch {};
        nb.linker.linkKeg(name, actual_ver) catch |err| {
            stderr.print("nb: '{s}': link failed: {}\n", .{ name, err }) catch {};
            had_error = true;
            continue;
        };
        stdout.print("==> Linked {s} {s}\n", .{ name, actual_ver }) catch {};
    }
    if (had_error) std.process.exit(1);
}

fn runUnlink(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    if (args.len == 0) {
        stderr.print("nb: no package specified\nUsage: nb unlink <package>...\n", .{}) catch {};
        std.process.exit(1);
    }

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    var had_error = false;
    for (args) |raw_name| {
        const name = if (std.mem.lastIndexOfScalar(u8, raw_name, '/')) |pos| raw_name[pos + 1 ..] else raw_name;
        const keg = db.findKeg(name) orelse {
            stderr.print("nb: '{s}' is not installed\n", .{raw_name}) catch {};
            had_error = true;
            continue;
        };

        var ver_buf: [256]u8 = undefined;
        const actual_ver = nb.cellar.detectKegVersion(name, keg.version, &ver_buf) orelse keg.version;

        nb.linker.unlinkKeg(name, actual_ver) catch |err| {
            stderr.print("nb: '{s}': unlink failed: {}\n", .{ name, err }) catch {};
            had_error = true;
            continue;
        };
        stdout.print("==> Unlinked {s} {s}\n", .{ name, actual_ver }) catch {};
    }
    if (had_error) std.process.exit(1);
}

// ── nb bundle ──

fn runBundle(alloc: std.mem.Allocator, args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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
    const file_content = std.Io.Dir.cwd().readFileAlloc(g_io, file_path, alloc, .limited(1024 * 1024)) catch {
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
    var timer = MonoTimer.start();

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
        if (std.Io.Dir.openDirAbsolute(g_io, cellar_path, .{})) |d| {
            var dir = d;
            dir.close(g_io);
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
        const elapsed_ns: u64 = timer.read();
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

    const elapsed_ns: u64 = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    stdout.print("Installed {d} formulae, {d} casks. Skipped {d} unsupported entries.\n", .{ needs_formula.items.len, needs_cask.items.len, skipped }) catch {};
    stdout.print("==> Done in {d:.1}ms\n", .{elapsed_ms}) catch {};
}

// ── nb outdated ──

fn runOutdated(alloc: std.mem.Allocator) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        std.process.exit(1);
    };
    defer db.close();

    stdout.print("==> Checking for outdated packages...\n", .{}) catch {};
    var outdated = getOutdatedPackages(alloc, &db, &.{}, true, true);
    defer {
        for (outdated.items) |*pkg| pkg.deinit(alloc);
        outdated.deinit(alloc);
    }

    // Also check deb packages
    var deb_outdated: usize = 0;
    const installed_debs = db.listInstalledDebs(alloc) catch &.{};
    defer if (installed_debs.len > 0) alloc.free(installed_debs);

    if (installed_debs.len > 0) deb_check: {
        // Fetch indices from every configured APT source so we honour custom
        // mirrors and PPAs the user has set up via /etc/apt/sources.list[.d/*].
        const deb_arch = platform.deb_arch;

        var sources_buf: std.ArrayList(EffectiveSource) = .empty;
        defer sources_buf.deinit(alloc);
        var maybe_discovered: ?nb.deb_sources.Sources = null;
        defer if (maybe_discovered) |*s| s.deinit();
        discoverInstallSources(alloc, deb_arch, &sources_buf, &maybe_discovered);
        if (sources_buf.items.len == 0) break :deb_check;

        var client = nb.proxy.Client.init(alloc, g_io);
        defer client.deinit();

        var all_pkgs_list: std.ArrayList(nb.deb_index.DebPackage) = .empty;
        defer all_pkgs_list.deinit(alloc);

        var outdated_parsed: std.ArrayList(nb.deb_index.ParsedIndex) = .empty;
        defer {
            for (outdated_parsed.items) |*pi| pi.deinit();
            outdated_parsed.deinit(alloc);
        }

        for (sources_buf.items) |src| {
            for (src.components) |component| {
                var url_buf: [768]u8 = undefined;
                const index_url = std.fmt.bufPrint(&url_buf, "{s}/dists/{s}/{s}/binary-{s}/Packages.gz", .{
                    src.mirror, src.suite, component, deb_arch,
                }) catch continue;

                const index_gz = httpGetToMemory(alloc, client.ptr(), index_url) orelse continue;
                defer alloc.free(index_gz);

                const index_data = nb.deb_extract.decompressGzip(alloc, index_gz) catch continue;
                defer alloc.free(index_data);

                var parsed = nb.deb_index.parsePackagesIndexFromMirror(alloc, index_data, src.mirror) catch continue;
                for (parsed.packages) |pkg| all_pkgs_list.append(alloc, pkg) catch continue;
                outdated_parsed.append(alloc, parsed) catch {
                    parsed.deinit();
                    continue;
                };
            }
        }

        if (all_pkgs_list.items.len == 0) break :deb_check;

        var idx = nb.deb_index.buildIndex(alloc, all_pkgs_list.items) catch break :deb_check;
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
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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
        const sorted = resolver.topologicalSort() catch |err| {
            if (err == error.DependencyCycle) {
                stderr.print("nb: dependency cycle detected in '{s}' dependency graph\n", .{name}) catch {};
            } else {
                stderr.print("nb: failed to sort dependencies for '{s}': {}\n", .{ name, err }) catch {};
            }
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
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    const subcmd = if (args.len > 0) args[0] else "list";
    const svc_name = if (args.len > 1) args[1] else null;

    const services_list = nb.services.discoverServices(alloc, g_io) catch {
        stderr.print("nb: failed to discover services\n", .{}) catch {};
        return;
    };
    defer nb.services.freeServiceList(alloc, services_list);

    if (std.mem.eql(u8, subcmd, "list")) {
        if (services_list.len == 0) {
            stdout.print("No services found.\n", .{}) catch {};
            return;
        }
        stdout.print("==> Services:\n", .{}) catch {};
        for (services_list) |svc| {
            const status = if (nb.services.isRunning(alloc, g_io, svc.label)) "running" else "stopped";
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
            nb.services.stop(alloc, g_io, svc.plist_path) catch |err| {
                stderr.print("nb: failed to stop {s}: {}\n", .{ svc.name, err }) catch {};
                if (std.mem.eql(u8, subcmd, "stop")) return;
            };
            if (std.mem.eql(u8, subcmd, "stop")) {
                stdout.print("==> Stopped {s}\n", .{svc.name}) catch {};
                return;
            }
        }

        if (std.mem.eql(u8, subcmd, "start") or std.mem.eql(u8, subcmd, "restart")) {
            nb.services.start(alloc, g_io, svc.plist_path) catch |err| {
                stderr.print("nb: failed to start {s}: {}\n", .{ svc.name, err }) catch {};
                return;
            };
            stdout.print("==> Started {s}\n", .{svc.name}) catch {};
        }
    } else {
        stderr.print("nb: unknown services subcommand '{s}'\nUsage: nb services [list|start|stop|restart] [name]\n", .{subcmd}) catch {};
    }
}

// ── nb telemetry ──

fn runTelemetry(args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    const subcmd = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, subcmd, "status")) {
        const state = if (nb.telemetry.isEnabled()) "on" else "off";
        stdout.print("Telemetry is {s}.\n", .{state}) catch {};
        stdout.print("Setting file: {s}\n", .{nb.telemetry.settingPath()}) catch {};
        stdout.print("Use `nb telemetry off` to opt out or `nb telemetry on` to turn it back on.\n", .{}) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "off") or std.mem.eql(u8, subcmd, "disable")) {
        nb.telemetry.setEnabled(false) catch |err| {
            stderr.print("nb: failed to disable telemetry: {}\n", .{err}) catch {};
            stderr.print("nb: try `sudo nb init` if /opt/nanobrew is not writable\n", .{}) catch {};
            return;
        };
        stdout.print("==> Telemetry disabled\n", .{}) catch {};
        stdout.print("    Stored: {s}\n", .{nb.telemetry.settingPath()}) catch {};
        return;
    }

    if (std.mem.eql(u8, subcmd, "on") or std.mem.eql(u8, subcmd, "enable")) {
        nb.telemetry.setEnabled(true) catch |err| {
            stderr.print("nb: failed to enable telemetry: {}\n", .{err}) catch {};
            stderr.print("nb: try `sudo nb init` if /opt/nanobrew is not writable\n", .{}) catch {};
            return;
        };
        stdout.print("==> Telemetry enabled\n", .{}) catch {};
        stdout.print("    Stored: {s}\n", .{nb.telemetry.settingPath()}) catch {};
        return;
    }

    stderr.print("nb: unknown telemetry subcommand '{s}'\nUsage: nb telemetry [status|on|off]\n", .{subcmd}) catch {};
}

// ── nb completions ──

fn runCompletions(args: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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
            \\    'reinstall:Reinstall packages'
            \\    'list:List installed packages'
            \\    'leaves:List packages with no dependents'
            \\    'info:Show formula info'
            \\    'search:Search for packages'
            \\    'where:Find packages by pattern (installed, files, index)'
            \\    'upgrade:Upgrade packages'
            \\    'update:Self-update nanobrew'
            \\    'update-registry:Refresh the verified-upstream registry'
            \\    'doctor:Check installation health'
            \\    'cleanup:Remove stale caches'
            \\    'outdated:List outdated packages'
            \\    'pin:Pin a package'
            \\    'unpin:Unpin a package'
            \\    'rollback:Rollback to previous version'
            \\    'switch:Reactivate a previously-installed version'
            \\    'link:Link an installed keg into the prefix'
            \\    'unlink:Remove an installed keg prefix links'
            \\    'bundle:Export/import package lists'
            \\    'deps:Show dependency tree'
            \\    'services:Manage services'
            \\    'completions:Generate shell completions'
            \\    'telemetry:Manage anonymous download telemetry'
            \\    'nuke:Completely uninstall nanobrew'
            \\    'migrate:Import existing Homebrew packages'
            \\    'help:Show help'
            \\  )
            \\
            \\  if (( CURRENT == 2 )); then
            \\    _describe 'command' commands
            \\    return
            \\  fi
            \\
            \\  case "$words[2]" in
            \\    install|i)
            \\      _arguments '--cask[Install a cask]' '--deb[Install a deb package]' '--shims[Use private dependency executable shims]' '*:formula:' ;;
            \\    remove|uninstall|rm)
            \\      _arguments '--cask[Remove a cask]' '--deb[Remove a deb package]' '*:installed package:_nb_installed' ;;
            \\    upgrade)
            \\      _arguments '--cask[Upgrade casks]' '--deb[Upgrade debs]' '*:installed package:_nb_installed' ;;
            \\    info)
            \\      _arguments '--cask[Show cask info]' '*:formula:' ;;
            \\    pin|unpin|rollback|rb|link|unlink)
            \\      _arguments '*:installed package:_nb_installed' ;;
            \\    deps)
            \\      _arguments '--tree[Show as tree]' '*:formula:' ;;
            \\    services|service)
            \\      local -a subcmds
            \\      subcmds=('list:List services' 'start:Start a service' 'stop:Stop a service' 'restart:Restart a service')
            \\      _describe 'subcommand' subcmds ;;
            \\    completions)
            \\      _arguments '*:shell:(zsh bash fish)' ;;
            \\    telemetry)
            \\      _arguments '*:subcommand:(status on off)' ;;
            \\    bundle)
            \\      _arguments '*:subcommand:(dump install)' ;;
            \\    cleanup)
            \\      _arguments '--dry-run[Show what would be removed]' ;;
            \\  esac
            \\}}
            \\
            \\_nb_installed() {{
            \\  local -a pkgs
            \\  pkgs=(${{(f)"$(nb list --names 2>/dev/null)"}})
            \\  (( ${{#pkgs}} )) && _describe 'installed package' pkgs
            \\}}
            \\
            \\compdef _nb nb
            \\
        , .{}) catch {};
    } else if (std.mem.eql(u8, shell, "bash")) {
        stdout.print(
            \\_nb_completions() {{
            \\  local commands="init install remove list leaves info search where upgrade update doctor cleanup outdated pin unpin rollback switch bundle deps services completions telemetry nuke migrate help"
            \\  if [[ $COMP_CWORD -eq 1 ]]; then
            \\    COMPREPLY=($(compgen -W "$commands" -- "${{COMP_WORDS[COMP_CWORD]}}"))
            \\  else
            \\    case "${{COMP_WORDS[1]}}" in
            \\      remove|uninstall|upgrade|pin|unpin|rollback|link|unlink)
            \\        local installed="$(nb list --names 2>/dev/null)"
            \\        COMPREPLY=($(compgen -W "$installed" -- "${{COMP_WORDS[COMP_CWORD]}}")) ;;
            \\      install)
            \\        COMPREPLY=($(compgen -W "--cask --deb --shims" -- "${{COMP_WORDS[COMP_CWORD]}}")) ;;
            \\      info)
            \\        COMPREPLY=($(compgen -W "--cask" -- "${{COMP_WORDS[COMP_CWORD]}}")) ;;
            \\      completions)
            \\        COMPREPLY=($(compgen -W "zsh bash fish" -- "${{COMP_WORDS[COMP_CWORD]}}")) ;;
            \\      telemetry)
            \\        COMPREPLY=($(compgen -W "status on off" -- "${{COMP_WORDS[COMP_CWORD]}}")) ;;
            \\      services)
            \\        COMPREPLY=($(compgen -W "list start stop restart" -- "${{COMP_WORDS[COMP_CWORD]}}")) ;;
            \\    esac
            \\  fi
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
            \\complete -c nb -n '__fish_use_subcommand' -a 'reinstall' -d 'Reinstall packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'list' -d 'List installed packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'leaves' -d 'List packages with no dependents'
            \\complete -c nb -n '__fish_use_subcommand' -a 'info' -d 'Show formula info'
            \\complete -c nb -n '__fish_use_subcommand' -a 'search' -d 'Search for packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'where' -d 'Find packages by pattern'
            \\complete -c nb -n '__fish_use_subcommand' -a 'upgrade' -d 'Upgrade packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'update' -d 'Self-update nanobrew'
            \\complete -c nb -n '__fish_use_subcommand' -a 'update-registry' -d 'Refresh the verified-upstream registry'
            \\complete -c nb -n '__fish_use_subcommand' -a 'doctor' -d 'Check installation health'
            \\complete -c nb -n '__fish_use_subcommand' -a 'cleanup' -d 'Remove stale caches'
            \\complete -c nb -n '__fish_use_subcommand' -a 'outdated' -d 'List outdated packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'pin' -d 'Pin a package'
            \\complete -c nb -n '__fish_use_subcommand' -a 'unpin' -d 'Unpin a package'
            \\complete -c nb -n '__fish_use_subcommand' -a 'rollback' -d 'Rollback to previous version'
            \\complete -c nb -n '__fish_use_subcommand' -a 'link' -d 'Link an installed keg into the prefix'
            \\complete -c nb -n '__fish_use_subcommand' -a 'unlink' -d 'Remove an installed keg prefix links'
            \\complete -c nb -n '__fish_use_subcommand' -a 'bundle' -d 'Export/import package lists'
            \\complete -c nb -n '__fish_use_subcommand' -a 'deps' -d 'Show dependency tree'
            \\complete -c nb -n '__fish_use_subcommand' -a 'services' -d 'Manage services'
            \\complete -c nb -n '__fish_use_subcommand' -a 'completions' -d 'Generate shell completions'
            \\complete -c nb -n '__fish_use_subcommand' -a 'telemetry' -d 'Manage anonymous download telemetry'
            \\complete -c nb -n '__fish_use_subcommand' -a 'nuke' -d 'Completely uninstall nanobrew'
            \\complete -c nb -n '__fish_use_subcommand' -a 'migrate' -d 'Import existing Homebrew packages'
            \\complete -c nb -n '__fish_use_subcommand' -a 'help' -d 'Show help'
            \\complete -c nb -n '__fish_seen_subcommand_from remove uninstall upgrade pin unpin rollback link unlink' -a '(nb list --names 2>/dev/null)'
            \\complete -c nb -n '__fish_seen_subcommand_from install info' -l cask -d 'Cask mode'
            \\complete -c nb -n '__fish_seen_subcommand_from install' -l deb -d 'Deb mode'
            \\complete -c nb -n '__fish_seen_subcommand_from install' -l shims -d 'Use private dependency executable shims'
            \\complete -c nb -n '__fish_seen_subcommand_from services' -a 'list start stop restart'
            \\complete -c nb -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
            \\complete -c nb -n '__fish_seen_subcommand_from telemetry' -a 'status on off'
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

/// One row in the resolved set of APT sources to fetch from.
const EffectiveSource = struct {
    mirror: []const u8,
    suite: []const u8,
    components: []const []const u8,
};

/// Discover effective APT sources for a `nb --deb` operation:
///   1. Parse `/etc/apt/sources.list` and `/etc/apt/sources.list.d/*` and use
///      every enabled `deb` row whose `Architectures` list contains the
///      current target arch (or is empty / unspecified).
///   2. If discovery yields zero rows (non-Linux, missing files, parse
///      errors, no match for our arch), fall back to the hardcoded
///      distro defaults from `/etc/os-release`.
///
/// On success, the caller owns the returned slice (free with `alloc.free`)
/// and the optional `discovered_out` (call `.deinit()` to free the parse
/// arena that backs every string referenced by the slice).
fn discoverInstallSources(
    alloc: std.mem.Allocator,
    arch: []const u8,
    sources_out: *std.ArrayList(EffectiveSource),
    discovered_out: *?nb.deb_sources.Sources,
) void {
    if (nb.deb_sources.discover(alloc)) |discovered_val| {
        var discovered = discovered_val;
        var kept: usize = 0;
        for (discovered.repositories) |repo| {
            if (repo.architectures.len > 0) {
                var arch_match = false;
                for (repo.architectures) |a| if (std.mem.eql(u8, a, arch)) {
                    arch_match = true;
                    break;
                };
                if (!arch_match) continue;
            }
            sources_out.append(alloc, .{
                .mirror = repo.uri,
                .suite = repo.suite,
                .components = repo.components,
            }) catch continue;
            kept += 1;
        }
        if (kept == 0) {
            discovered.deinit();
        } else {
            discovered_out.* = discovered;
        }
    } else |_| {}

    if (sources_out.items.len == 0) {
        const distro = nb.deb_distro.detect(alloc);
        sources_out.append(alloc, .{
            .mirror = distro.mirror,
            .suite = distro.codename,
            .components = nb.deb_distro.getComponents(distro.id),
        }) catch {};
    }
}

/// Install .deb packages from Ubuntu/Debian repositories (Linux only).
fn runDebInstall(alloc: std.mem.Allocator, packages: []const []const u8, repo_spec: ?[]const u8, opts: DebInstallOptions) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    if (comptime builtin.os.tag != .linux) {
        stderr.print("nb: --deb is only supported on Linux\n", .{}) catch {};
        return;
    }

    var timer = MonoTimer.start();

    // --- Step 1: Fetch + decompress package index natively ---
    const t_start = milliTimestamp();
    stdout.print("==> Fetching package index...\n", .{}) catch {};

    const arch = platform.deb_arch;

    // Resolve sources: --repo override → /etc/apt/sources.list[.d/*] → distro defaults.
    var sources_buf: std.ArrayList(EffectiveSource) = .empty;
    defer sources_buf.deinit(alloc);

    var maybe_discovered: ?nb.deb_sources.Sources = null;
    defer if (maybe_discovered) |*s| s.deinit();

    var fallback_components_storage: [2][]const u8 = .{ "main", "universe" };

    if (repo_spec) |spec| {
        // Parse repo spec: "http://mirror/path codename comp1 comp2"
        var parts = std.mem.splitScalar(u8, spec, ' ');
        const m = parts.next() orelse {
            stderr.print("nb: invalid --repo spec (expected: mirror codename component...)\n", .{}) catch {};
            return;
        };
        const d = parts.next() orelse "noble";
        var comp_list: std.ArrayList([]const u8) = .empty;
        defer comp_list.deinit(alloc);
        while (parts.next()) |comp| comp_list.append(alloc, comp) catch {};
        const comps_slice: []const []const u8 = if (comp_list.items.len > 0)
            (comp_list.toOwnedSlice(alloc) catch fallback_components_storage[0..])
        else
            fallback_components_storage[0..];
        sources_buf.append(alloc, .{ .mirror = m, .suite = d, .components = comps_slice }) catch return;
    } else {
        discoverInstallSources(alloc, arch, &sources_buf, &maybe_discovered);
    }

    if (sources_buf.items.len == 0) {
        stderr.print("nb: no usable APT sources found\n", .{}) catch {};
        return;
    }

    // Validate every mirror URL.
    for (sources_buf.items) |*src| {
        if (!std.mem.startsWith(u8, src.mirror, "http://") and !std.mem.startsWith(u8, src.mirror, "https://")) {
            stderr.print("nb: invalid mirror URL (must start with http:// or https://): {s}\n", .{src.mirror}) catch {};
            return;
        }
        for (src.mirror) |c| {
            if (c < 0x20 or c == 0x7f) {
                stderr.print("nb: invalid mirror URL (contains control characters)\n", .{}) catch {};
                return;
            }
        }
        while (src.mirror.len > 0 and src.mirror[src.mirror.len - 1] == '/') {
            src.mirror = src.mirror[0 .. src.mirror.len - 1];
        }
    }

    stdout.print("    arch={s} sources={d}\n", .{ arch, sources_buf.items.len }) catch {};
    for (sources_buf.items) |src| {
        stdout.print("      {s} {s} ({d} comp)\n", .{ src.mirror, src.suite, src.components.len }) catch {};
    }

    // Native HTTP client for package-index requests. Download workers use
    // independent clients because std.http.Client requests are not thread-safe.
    var client = nb.proxy.Client.init(alloc, g_io);
    defer client.deinit();

    // Fetch and merge package indices from all (source, component) pairs.
    var all_pkgs_list: std.ArrayList(nb.deb_index.DebPackage) = .empty;
    defer all_pkgs_list.deinit(alloc);

    // Keep parsed indices alive — their arenas own the string data referenced by DebPackage
    var parsed_indices: std.ArrayList(nb.deb_index.ParsedIndex) = .empty;
    defer {
        for (parsed_indices.items) |*pi| pi.deinit();
        parsed_indices.deinit(alloc);
    }

    for (sources_buf.items) |src| {
        for (src.components) |component| {
            const key = nb.deb_index.cacheKeyForSource(src.mirror, src.suite, component, arch);

            if (nb.deb_index.readCachedBinaryIndexForSource(alloc, &key, src.suite, component, arch)) |cached| {
                stdout.print("    {s} {s}/{s}: cache hit ({d} pkgs)\n", .{ src.mirror, src.suite, component, cached.packages.len }) catch {};
                var parsed = cached;
                for (parsed.packages) |pkg| all_pkgs_list.append(alloc, pkg) catch continue;
                parsed_indices.append(alloc, parsed) catch {
                    parsed.deinit();
                    continue;
                };
                continue;
            }
            stdout.print("    {s} {s}/{s}: fetching...\n", .{ src.mirror, src.suite, component }) catch {};

            var url_buf: [768]u8 = undefined;
            const index_url = std.fmt.bufPrint(&url_buf, "{s}/dists/{s}/{s}/binary-{s}/Packages.gz", .{
                src.mirror, src.suite, component, arch,
            }) catch continue;

            const index_gz = httpGetToMemory(alloc, client.ptr(), index_url) orelse {
                stderr.print("nb: warning: failed to fetch {s} {s}/{s}\n", .{ src.mirror, src.suite, component }) catch {};
                continue;
            };
            defer alloc.free(index_gz);

            const index_data = nb.deb_extract.decompressGzip(alloc, index_gz) catch {
                stderr.print("nb: warning: failed to decompress {s} {s}/{s}\n", .{ src.mirror, src.suite, component }) catch {};
                continue;
            };
            defer alloc.free(index_data);

            var parsed = nb.deb_index.parsePackagesIndexFromMirror(alloc, index_data, src.mirror) catch continue;

            nb.deb_index.writeCachedBinaryIndexForSource(&key, src.suite, component, arch, alloc, parsed.packages);

            for (parsed.packages) |pkg| all_pkgs_list.append(alloc, pkg) catch continue;
            parsed_indices.append(alloc, parsed) catch {
                parsed.deinit();
                continue;
            };
        }
    }

    if (all_pkgs_list.items.len == 0) {
        stderr.print("nb: failed to fetch any package index\n", .{}) catch {};
        return;
    }

    const t_index = milliTimestamp();
    stdout.print("==> Fetched index ({d} packages) in {d}ms\n", .{ all_pkgs_list.items.len, t_index - t_start }) catch {};
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

    const t_resolve = milliTimestamp();
    stdout.print("==> Resolving deps for {d} package(s)... (index built in {d}ms)\n", .{ packages.len, t_resolve - t_index }) catch {};
    const resolved = nb.deb_resolver.resolveAll(alloc, packages, index_map, provides_map) catch {
        stderr.print("nb: dependency resolution failed\n", .{}) catch {};
        return;
    };
    defer alloc.free(resolved);

    const t_resolved = milliTimestamp();
    // --- Step 3: Download + extract (streaming SHA256 verification) ---
    stdout.print("==> Installing {d} package(s)... (resolved in {d}ms)\n", .{ resolved.len, t_resolved - t_resolve }) catch {};
    var installed: usize = 0;
    var cached: usize = 0;

    // --- Step 3a: Parallel download of uncached packages ---
    {
        const DebDlItem = struct {
            url_storage: [1024]u8,
            url_len: usize,
            name_storage: [128]u8,
            name_len: usize,
            sha256: []const u8,
            cache_path_storage: [512]u8,
            cache_path_len: usize,
        };

        var to_download: std.ArrayList(DebDlItem) = .empty;
        defer to_download.deinit(alloc);

        for (resolved) |pkg| {
            if (pkg.sha256.len == 0) continue;

            // Validate package name — skip unsafe names
            var unsafe = false;
            for (pkg.name) |c| {
                if (c == '/' or c == 0) {
                    unsafe = true;
                    break;
                }
            }
            if (unsafe) continue;
            if (std.mem.indexOf(u8, pkg.name, "..") != null) continue;

            var cache_buf: [512]u8 = undefined;
            const cache_path = std.fmt.bufPrint(&cache_buf, "{s}/{s}.deb", .{ paths.BLOBS_DIR, pkg.sha256 }) catch continue;

            // Skip if already cached
            if (std.Io.Dir.accessAbsolute(g_io, cache_path, .{})) |_| {
                continue;
            } else |_| {}

            var url_buf: [1024]u8 = undefined;
            const pkg_mirror = if (pkg.mirror.len > 0) pkg.mirror else sources_buf.items[0].mirror;
            const dl_url = std.fmt.bufPrint(&url_buf, "{s}/{s}", .{ pkg_mirror, pkg.filename }) catch continue;

            var item: DebDlItem = undefined;
            @memcpy(item.url_storage[0..dl_url.len], dl_url);
            item.url_len = dl_url.len;
            const name_len = @min(pkg.name.len, item.name_storage.len);
            @memcpy(item.name_storage[0..name_len], pkg.name[0..name_len]);
            item.name_len = name_len;
            item.sha256 = pkg.sha256;
            @memcpy(item.cache_path_storage[0..cache_path.len], cache_path);
            item.cache_path_len = cache_path.len;

            to_download.append(alloc, item) catch continue;
        }

        if (to_download.items.len > 0) {
            stdout.print("    downloading {d} package(s) in parallel...\n", .{to_download.items.len}) catch {};

            const DebWorkerCtx = struct {
                items: []const DebDlItem,
                next_idx: *std.atomic.Value(usize),
                had_error: *std.atomic.Value(bool),
                alloc_: std.mem.Allocator,
                verify: bool,
            };

            const debWorkerFn = struct {
                fn run(ctx: DebWorkerCtx) void {
                    // One HTTP client per thread — reuses TCP+TLS connections
                    var dl_client = nb.proxy.Client.init(ctx.alloc_, paths.safe_io);
                    defer dl_client.deinit();

                    while (true) {
                        const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                        if (idx >= ctx.items.len) break;
                        const item = ctx.items[idx];
                        const url = item.url_storage[0..item.url_len];
                        const dest = item.cache_path_storage[0..item.cache_path_len];
                        const name = item.name_storage[0..item.name_len];

                        var telemetry_event = nb.telemetry.DownloadEvent.start(.artifact, name);
                        downloadDebWithSha256(dl_client.ptr(), url, item.sha256, dest, ctx.verify) catch {
                            // Retry once with fresh client (connection may have been reset)
                            var retry_client = nb.proxy.Client.init(ctx.alloc_, paths.safe_io);
                            defer retry_client.deinit();
                            downloadDebWithSha256(retry_client.ptr(), url, item.sha256, dest, ctx.verify) catch {
                                telemetry_event.fail();
                                ctx.had_error.store(true, .release);
                                continue;
                            };
                        };
                        telemetry_event.succeed(nb.telemetry.fileSize(dest));
                    }
                }
            }.run;

            var had_dl_error = std.atomic.Value(bool).init(false);
            var next_dl_idx = std.atomic.Value(usize).init(0);

            const num_threads = @min(to_download.items.len, 8);
            const dl_ctx = DebWorkerCtx{
                .items = to_download.items,
                .next_idx = &next_dl_idx,
                .had_error = &had_dl_error,
                .alloc_ = alloc,
                .verify = !opts.no_verify,
            };

            var dl_threads: [8]std.Thread = undefined;
            var dl_spawned: usize = 0;

            for (0..num_threads) |_| {
                dl_threads[dl_spawned] = std.Thread.spawn(.{}, debWorkerFn, .{dl_ctx}) catch {
                    had_dl_error.store(true, .release);
                    continue;
                };
                dl_spawned += 1;
            }

            for (dl_threads[0..dl_spawned]) |t| {
                t.join();
            }

            if (had_dl_error.load(.acquire)) {
                stderr.print("nb: warning: some packages failed to download\n", .{}) catch {};
            }
        }
    }

    const t_downloaded = milliTimestamp();
    stdout.print("    download phase: {d}ms\n", .{t_downloaded - t_resolved}) catch {};

    // Open database for tracking installed debs
    var db: ?nb.database.Database = nb.database.Database.open(alloc) catch null;
    defer if (db) |*d| d.close();

    // --- Parallel extraction phase ---
    // Extract all cached .debs concurrently using a thread pool.
    // Packages that need downloading were already fetched in the parallel download phase above.
    // `installed_files` is `null` while the extract worker is in flight,
    // a non-null owned slice (each entry alloc'd via `alloc`) on success,
    // and stays `null` on extraction failure. Only items with non-null
    // `installed_files` are recorded in the DB. The slice is freed below
    // after `recordDebInstall` has dup'd the strings into the DB.
    const ExtractItem = struct {
        pkg_idx: usize,
        cache_path_storage: [512]u8,
        cache_path_len: usize,
        needs_download: bool,
        installed_files: ?[][]const u8 = null,
    };

    var extract_items: std.ArrayList(ExtractItem) = .empty;
    defer {
        // Belt-and-braces: anything still owned by an item at function
        // exit (e.g. an early return after extract but before record)
        // gets cleaned up here so we don't leak per-file strings on
        // every --deb install.
        for (extract_items.items) |item| {
            if (item.installed_files) |files| {
                for (files) |f| alloc.free(f);
                alloc.free(files);
            }
        }
        extract_items.deinit(alloc);
    }

    // Build extraction work list
    for (resolved, 0..) |pkg, idx| {
        // Validate package name
        var unsafe = false;
        for (pkg.name) |c| {
            if (c == '/' or c == 0) {
                unsafe = true;
                break;
            }
        }
        if (unsafe or std.mem.indexOf(u8, pkg.name, "..") != null) continue;

        if (pkg.sha256.len == 0) continue; // skip packages without checksum

        var item: ExtractItem = undefined;
        item.pkg_idx = idx;
        var cache_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&cache_buf, "{s}/{s}.deb", .{ paths.BLOBS_DIR, pkg.sha256 }) catch continue;
        @memcpy(item.cache_path_storage[0..cache_path.len], cache_path);
        item.cache_path_len = cache_path.len;
        item.needs_download = if (std.Io.Dir.accessAbsolute(g_io, cache_path, .{})) |_| false else |_| true;

        extract_items.append(alloc, item) catch continue;
    }

    // Count already-cached packages (downloaded in a previous run)
    for (extract_items.items) |item| {
        if (!item.needs_download) cached += 1;
    }

    // Thread pool for extraction. `items` is `[]ExtractItem` (mutable)
    // because each worker owns its own slot via the next_idx counter and
    // writes the resulting file list back into `installed_files`. No two
    // workers ever touch the same item, so no locking is needed.
    //
    // The `io` field is the main thread's `g_io` (a real threadsafe
    // Threaded executor); workers share it for createFile/writeStreaming/
    // deleteFile inside `native_tar.extractToDir`. Previously every
    // worker called `paths.safe_io` directly
    // from inside extractToDir/writeFile/makeDirRecursive — the singleton
    // is "init_single_threaded" by design and its vtable + internal pipe
    // state corrupted under concurrent use, surfacing as the `nb install
    // --deb cowsay` reinstall SIGSEGV. Threading g_io through is the fix.
    const ExtractCtx = struct {
        items: []ExtractItem,
        resolved: []const nb.deb_index.DebPackage,
        next_idx: *std.atomic.Value(usize),
        installed_count: *std.atomic.Value(usize),
        alloc_: std.mem.Allocator,
        io: std.Io,
    };

    const extractWorkerFn = struct {
        fn run(ctx: ExtractCtx) void {
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= ctx.items.len) break;
                const item_ptr = &ctx.items[idx];
                const cache_path = item_ptr.cache_path_storage[0..item_ptr.cache_path_len];

                // Extract .deb to prefix and persist the file list so the
                // main thread can hand it to recordDebInstall (which lets
                // `nb remove --deb` actually find these files later) and
                // so `nb list` only shows packages whose tarball really
                // landed on disk. Errors leave `installed_files = null`
                // and skip the installed-count bump.
                const files = nb.deb_extract.extractDebToPrefixWithFiles(ctx.alloc_, ctx.io, cache_path) catch continue;
                item_ptr.installed_files = files;
                _ = ctx.installed_count.fetchAdd(1, .monotonic);
            }
        }
    }.run;

    var next_extract_idx = std.atomic.Value(usize).init(0);
    var installed_atomic = std.atomic.Value(usize).init(0);

    const extract_ctx = ExtractCtx{
        .items = extract_items.items,
        .resolved = resolved,
        .next_idx = &next_extract_idx,
        .installed_count = &installed_atomic,
        .alloc_ = alloc,
        .io = g_io,
    };

    // Use up to 8 threads for extraction
    const n_extract_threads = @min(extract_items.items.len, 8);
    var extract_threads: [8]std.Thread = undefined;
    var extract_spawned: usize = 0;

    for (0..n_extract_threads) |_| {
        extract_threads[extract_spawned] = std.Thread.spawn(.{}, extractWorkerFn, .{extract_ctx}) catch continue;
        extract_spawned += 1;
    }

    for (extract_threads[0..extract_spawned]) |t| {
        t.join();
    }

    installed = installed_atomic.load(.acquire);
    const t_extracted = milliTimestamp();
    stdout.print("    extract phase: {d}ms ({d} packages)\n", .{ t_extracted - t_downloaded, installed }) catch {};

    // Run postinst scripts sequentially for the packages whose data.tar
    // actually landed (must be sequential — postinst scripts mutate global
    // state like /etc/alternatives and /etc/ld.so.cache that races would
    // corrupt). Skip items whose extraction failed, otherwise we'd run
    // postinst on a half-extracted package and either get a hard error
    // or leave the system in a worse state than no install at all.
    if (!opts.skip_postinst) {
        for (extract_items.items) |item| {
            if (item.installed_files == null) continue;
            const pkg = resolved[item.pkg_idx];
            const cache_path = item.cache_path_storage[0..item.cache_path_len];
            nb.deb_extract.runPostinst(alloc, g_io, cache_path, pkg.name, false);
        }
    }

    for (extract_items.items) |item| {
        const files = item.installed_files orelse continue;
        if (db) |*d| {
            const pkg = resolved[item.pkg_idx];
            d.recordDebInstall(pkg.name, pkg.version, pkg.sha256, files) catch {};
        }
    }

    // Run ldconfig after all packages are installed (makes shared libs discoverable)
    if (installed > 0) {
        if (comptime builtin.os.tag == .linux) {
            const ld_result = std.process.run(alloc, g_io, .{
                .argv = &.{"ldconfig"},
            }) catch null;
            if (ld_result) |r| {
                switch (r.term) {
                    .exited => |code| if (code != 0) {
                        const _sw = StderrWriter{};
                        _sw.print("warning: ldconfig exited with code {d}\n", .{code}) catch {};
                    },
                    else => {},
                }
                alloc.free(r.stdout);
                alloc.free(r.stderr);
            }
        }
    }

    const elapsed_ns: u64 = timer.read();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    if (cached > 0) {
        stdout.print("==> Installed {d}/{d} packages ({d} cached) in {d:.1}ms\n", .{ installed, resolved.len, cached, elapsed_ms }) catch {};
    } else {
        stdout.print("==> Installed {d}/{d} packages in {d:.1}ms\n", .{ installed, resolved.len, elapsed_ms }) catch {};
    }
}

fn runDebRemove(alloc: std.mem.Allocator, packages: []const []const u8) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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

        // Delete each installed file. New installs (post-1d5265d) store
        // absolute paths in the DB, but state.json files written by older
        // nb versions hold relative paths. Tolerate both so a user
        // upgrading nb without reinstalling can still cleanly remove
        // their existing debs. `deleteFileAbsolute` on a relative path
        // resolves against cwd, which is whatever the user's shell
        // happens to be in — so we always prepend `/` when absent.
        var removed_files: usize = 0;
        for (record.files) |file_path| {
            var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
            const abs_path = if (file_path.len > 0 and file_path[0] == '/')
                file_path
            else blk: {
                const slice = std.fmt.bufPrint(&abs_buf, "/{s}", .{file_path}) catch continue;
                break :blk slice;
            };
            std.Io.Dir.deleteFileAbsolute(g_io, abs_path) catch continue;
            removed_files += 1;
        }

        db.recordDebRemoval(name) catch {};
        stdout.print("==> Removed {s} ({d} files)\n", .{ name, removed_files }) catch {};
    }

    // Run ldconfig after removal
    if (comptime builtin.os.tag == .linux) {
        const ld_result = std.process.run(alloc, g_io, .{
            .argv = &.{"ldconfig"},
            .stdout_limit = .limited(256),
            .stderr_limit = .limited(256),
        }) catch null;
        if (ld_result) |r| {
            alloc.free(r.stdout);
            alloc.free(r.stderr);
        }
    }
}

fn runDebUpgrade(alloc: std.mem.Allocator) void {
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

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

    // Re-fetch package indices from every configured APT source.
    const arch = platform.deb_arch;
    var sources_buf: std.ArrayList(EffectiveSource) = .empty;
    defer sources_buf.deinit(alloc);
    var maybe_discovered: ?nb.deb_sources.Sources = null;
    defer if (maybe_discovered) |*s| s.deinit();
    discoverInstallSources(alloc, arch, &sources_buf, &maybe_discovered);
    if (sources_buf.items.len == 0) {
        stderr.print("nb: no usable APT sources found\n", .{}) catch {};
        return;
    }

    var client = nb.proxy.Client.init(alloc, g_io);
    defer client.deinit();

    var all_pkgs_list: std.ArrayList(nb.deb_index.DebPackage) = .empty;
    defer all_pkgs_list.deinit(alloc);

    var upgrade_parsed: std.ArrayList(nb.deb_index.ParsedIndex) = .empty;
    defer {
        for (upgrade_parsed.items) |*pi| pi.deinit();
        upgrade_parsed.deinit(alloc);
    }

    for (sources_buf.items) |src| {
        for (src.components) |component| {
            var url_buf: [768]u8 = undefined;
            const index_url = std.fmt.bufPrint(&url_buf, "{s}/dists/{s}/{s}/binary-{s}/Packages.gz", .{
                src.mirror, src.suite, component, arch,
            }) catch continue;

            const index_gz = httpGetToMemory(alloc, client.ptr(), index_url) orelse continue;
            defer alloc.free(index_gz);

            const index_data = nb.deb_extract.decompressGzip(alloc, index_gz) catch continue;
            defer alloc.free(index_data);

            var parsed = nb.deb_index.parsePackagesIndexFromMirror(alloc, index_data, src.mirror) catch continue;

            for (parsed.packages) |pkg| all_pkgs_list.append(alloc, pkg) catch continue;
            upgrade_parsed.append(alloc, parsed) catch {
                parsed.deinit();
                continue;
            };
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
    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch return null;
    return out.toOwnedSlice() catch return null;
}

/// Download a .deb with streaming SHA256 verification to content-addressable cache.
/// Pass `verify = false` (from --no-verify) to skip the SHA256 check while
/// still computing it, so the blob still lands in the content-addressable
/// cache under its real digest. The check itself becomes advisory: a hash
/// mismatch is reported but doesn't fail the install. We never skip the
/// "the upstream said this should have a sha256 at all" check — a missing
/// declared sha is always a hard error to keep `--no-verify` distinct from
/// "trust the upstream blindly".
fn downloadDebWithSha256(
    client: *std.http.Client,
    url: []const u8,
    expected_sha256: []const u8,
    dest_path: []const u8,
    verify: bool,
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
        var file = std.Io.Dir.createFileAbsolute(g_io, tmp_path, .{}) catch return error.DownloadFailed;
        var file_writer_buf: [65536]u8 = undefined;
        var file_writer = file.writer(g_io, &file_writer_buf);

        var reader = response.reader(&.{});
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var hash_buf: [65536]u8 = undefined;
        var hashed = reader.hashed(&hasher, &hash_buf);

        _ = hashed.reader.streamRemaining(&file_writer.interface) catch {
            file.close(g_io);
            std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
            return error.DownloadFailed;
        };
        file_writer.interface.flush() catch {
            file.close(g_io);
            std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
            return error.DownloadFailed;
        };
        file.close(g_io);

        // Verify SHA256 — always required
        if (expected_sha256.len < 64) {
            std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
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
            std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
            return error.ChecksumMissing;
        }
        if (!std.mem.eql(u8, &hex, expected_sha256[0..64])) {
            if (verify) {
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
                return error.ChecksumMismatch;
            }
            // --no-verify: warn but accept the blob. The blob still gets
            // renamed to dest_path (the expected-digest cache path) so a
            // subsequent run without --no-verify will re-detect the
            // mismatch on cache lookup; we accept the small risk of a
            // tampered .deb sitting in the cache because the user opted
            // into --no-verify explicitly.
            const _msg = std.fmt.allocPrint(std.heap.smp_allocator, "nb: --no-verify: sha256 mismatch for {s} (got {s}, expected {s}); continuing\n", .{ dest_path, hex, expected_sha256[0..64] }) catch "";
            defer std.heap.smp_allocator.free(_msg);
            std.Io.File.stderr().writeStreamingAll(g_io, _msg) catch {};
        }
    }

    // Atomic rename to blob cache
    std.Io.Dir.renameAbsolute(tmp_path, dest_path, g_io) catch |err| {
        if (err == error.PathAlreadyExists) {
            // Race condition fix (#15): verify existing file's SHA256 before trusting it
            const existing_ok = blk: {
                var existing = std.Io.Dir.openFileAbsolute(g_io, dest_path, .{}) catch break :blk false;
                defer existing.close(g_io);
                var verify_hasher = std.crypto.hash.sha2.Sha256.init(.{});
                var read_buf: [65536]u8 = undefined;
                var read_offset: u64 = 0;
                while (true) {
                    const bytes_read = existing.readPositional(g_io, &.{read_buf[0..]}, read_offset) catch break :blk false;
                    if (bytes_read == 0) break;
                    verify_hasher.update(read_buf[0..bytes_read]);
                    read_offset += bytes_read;
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
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
                return;
            }
            // Existing file is corrupt — delete it and retry the rename
            std.Io.Dir.deleteFileAbsolute(g_io, dest_path) catch {};
            std.Io.Dir.renameAbsolute(tmp_path, dest_path, g_io) catch {
                std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
                return error.DownloadFailed;
            };
            return;
        }
        std.Io.Dir.deleteFileAbsolute(g_io, tmp_path) catch {};
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

    var file = std.Io.Dir.createFileAbsolute(g_io, dest_path, .{}) catch return error.DownloadFailed;
    var file_writer_buf: [65536]u8 = undefined;
    var file_writer = file.writer(&file_writer_buf);

    var reader = response.reader(&.{});
    _ = reader.streamRemaining(&file_writer.interface) catch {
        file.close(g_io);
        std.Io.Dir.deleteFileAbsolute(g_io, dest_path) catch {};
        return error.DownloadFailed;
    };
    file_writer.interface.flush() catch {
        file.close(g_io);
        std.Io.Dir.deleteFileAbsolute(g_io, dest_path) catch {};
        return error.DownloadFailed;
    };
    file.close(g_io);
}

fn checkForUpdate(alloc: std.mem.Allocator) void {
    const cache_path = ROOT ++ "/cache/last_update_check";
    const now = monoUnixSeconds();

    // Only check once per day (86400 seconds)
    if (std.Io.Dir.openFileAbsolute(g_io, cache_path, .{})) |f| {
        defer f.close(g_io);
        var buf: [32]u8 = undefined;
        const n = f.readPositionalAll(g_io, &buf, 0) catch 0;
        if (n > 0) {
            const last_check = std.fmt.parseInt(i64, std.mem.trimEnd(u8, buf[0..n], "\n \t"), 10) catch 0;
            if (now - last_check < 86400) return;
        }
    } else |_| {}

    // Write current timestamp (best-effort)
    if (std.Io.Dir.createFileAbsolute(g_io, cache_path, .{})) |f| {
        defer f.close(g_io);
        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now}) catch return;
        f.writeStreamingAll(g_io, ts_str) catch {};
    } else |_| {}

    // Fetch latest version from Cloudflare worker (native HTTP, no curl).
    //
    // Use a single-threaded Io here instead of the shared Threaded `safe_io`:
    // this is a best-effort, single sequential request on the main thread
    // after every worker thread has already joined. The Threaded Io drives
    // std.http's connection pool through async futures, and cancelling those
    // futures in `client.deinit()` can SIGSEGV during group teardown on Zig
    // 0.16.0 (see #298). A single-threaded Io runs the request inline and
    // spawns no cancellable futures, so teardown is crash-free.
    var update_client = nb.proxy.Client.init(alloc, std.Io.Threaded.global_single_threaded.io());
    defer update_client.deinit();
    const body = nb.fetch.getWithClient(alloc, update_client.ptr(), "https://nanobrew.trilok.ai/version") catch return;
    defer alloc.free(body);
    const latest_ver = nb.version.normalizeVersion(body);
    if (latest_ver.len == 0 or std.mem.eql(u8, latest_ver, "error")) return;

    // Cache latest remote version (for future use / diagnostics; banner uses VERSION vs this)
    if (std.Io.Dir.createFileAbsolute(g_io, ROOT ++ "/cache/latest_version", .{})) |vf| {
        defer vf.close(g_io);
        vf.writeStreamingAll(g_io, latest_ver) catch {};
    } else |_| {}

    // Show the banner only for strict upgrades, never for stale feeds/downgrades.
    if (!nb.version.isUpdateAvailable(VERSION, latest_ver)) return;

    // New version available — print colored banner to stderr (not stdout,
    // so shell completion scripts that parse `nb list` output aren't polluted)
    const stderr = StderrWriter{};
    stderr.print("\n\x1b[33m╭─────────────────────────────────────────╮\x1b[0m\n" ++
        "\x1b[33m│\x1b[0m  \x1b[1mUpdate available!\x1b[0m " ++
        "\x1b[90m{s}\x1b[0m → \x1b[32;1m{s}\x1b[0m" ++
        "{s}" ++
        "  \x1b[33m│\x1b[0m\n" ++
        "\x1b[33m│\x1b[0m  Run \x1b[36;1mnb update\x1b[0m to upgrade" ++
        "                \x1b[33m│\x1b[0m\n" ++
        "\x1b[33m╰─────────────────────────────────────────╯\x1b[0m\n", .{
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
    const stdout = StdoutWriter{};
    const stderr = StderrWriter{};

    var db = nb.database.Database.open(alloc) catch {
        stderr.print("nb: could not open database\n", .{}) catch {};
        return;
    };
    defer db.close();

    var formula_count: usize = 0;
    var cask_count: usize = 0;

    // Scan Homebrew Cellar directories for formulae
    // Includes macOS paths and Linux Linuxbrew path (#72)
    const cellar_paths = [_][]const u8{ "/opt/homebrew/Cellar", "/usr/local/Cellar", "/home/linuxbrew/.linuxbrew/Cellar" };
    for (cellar_paths) |cellar_path| {
        var cellar_dir = std.Io.Dir.openDirAbsolute(g_io, cellar_path, .{ .iterate = true }) catch continue;
        defer cellar_dir.close(g_io);

        var formula_iter = cellar_dir.iterate();
        while (formula_iter.next(g_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.name;

            // Open the formula directory to find version subdirectories
            var formula_dir = cellar_dir.openDir(g_io, name, .{ .iterate = true }) catch continue;
            defer formula_dir.close(g_io);

            var ver_iter = formula_dir.iterate();
            while (ver_iter.next(g_io) catch null) |ver_entry| {
                if (ver_entry.kind != .directory or ver_entry.name.len == 0 or ver_entry.name[0] == '.') continue;
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
    const caskroom_paths = [_][]const u8{ "/opt/homebrew/Caskroom", "/usr/local/Caskroom", "/home/linuxbrew/.linuxbrew/Caskroom" };
    for (caskroom_paths) |caskroom_path| {
        var caskroom_dir = std.Io.Dir.openDirAbsolute(g_io, caskroom_path, .{ .iterate = true }) catch continue;
        defer caskroom_dir.close(g_io);

        var cask_iter = caskroom_dir.iterate();
        while (cask_iter.next(g_io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const token = entry.name;

            var cask_dir = caskroom_dir.openDir(g_io, token, .{ .iterate = true }) catch continue;
            defer cask_dir.close(g_io);

            var ver_iter = cask_dir.iterate();
            while (ver_iter.next(g_io) catch null) |ver_entry| {
                if (ver_entry.kind != .directory or ver_entry.name.len == 0 or ver_entry.name[0] == '.') continue;
                const version = ver_entry.name;

                const empty_apps: []const []const u8 = &.{};
                const empty_bins: []const []const u8 = &.{};
                db.recordCaskInstall(token, token, version, "", empty_apps, empty_bins) catch {
                    stderr.print("nb: failed to record cask {s} {s}\n", .{ token, version }) catch {};
                    continue;
                };
                stdout.print("Migrated: {s} {s} (cask)\n", .{ token, version }) catch {};
                cask_count += 1;
            }
        }
    }

    stdout.print("\nMigrated {d} formulae and {d} casks from Homebrew\n", .{ formula_count, cask_count }) catch {};
    if (formula_count > 0 or cask_count > 0) {
        stdout.print(
            "\nNote: migrate only records package names in nanobrew's database so commands\n" ++
                "      like `nb list`, `nb outdated`, and `nb bundle dump` know about them.\n" ++
                "      The actual binaries still live in Homebrew's prefix — `nb where <pkg>`\n" ++
                "      will show the package as installed but with no entry in /opt/nanobrew/prefix/bin/.\n" ++
                "      To install a migrated package fully under nanobrew, run `nb install <pkg>`.\n",
            .{},
        ) catch {};
    }
}
