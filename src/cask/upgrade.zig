const std = @import("std");
const builtin = @import("builtin");
const paths = @import("../platform/paths.zig");
const Cask = @import("../api/cask.zig").Cask;
const Database = @import("../db/database.zig").Database;
const CaskRecord = @import("../db/database.zig").CaskRecord;
const installer = @import("install.zig");
pub const transaction = @import("transaction.zig");

pub const Locations = struct {
    caskroom: []const u8 = paths.CASKROOM_DIR,
    applications: []const u8 = "/Applications",
    bin: []const u8 = paths.PREFIX ++ "/bin",
    database: []const u8 = paths.DB_PATH,
    journal: []const u8 = paths.ROOT ++ "/db/cask-upgrade",
};

fn component(s: []const u8) bool {
    return s.len > 0 and !std.mem.eql(u8, s, ".") and !std.mem.eql(u8, s, "..") and
        std.mem.indexOfAny(u8, s, "/\\\x00") == null;
}

fn relative(s: []const u8) bool {
    if (s.len == 0 or s[0] == '/' or s[0] == '$') return false;
    var parts = std.mem.splitScalar(u8, s, '/');
    while (parts.next()) |part| if (!component(part)) return false;
    return true;
}

/// Only declarative app/binary artifacts can participate. Installer scripts,
/// pkg receipts, fonts and arbitrary filesystem rules need their own undo data.
pub fn unsupportedReason(cask: Cask) ?[]const u8 {
    if (builtin.os.tag != .macos) return "casks require macOS";
    switch (cask.downloadFormat()) {
        .zip, .tar_gz, .tar_xz, .binary => {},
        .pkg, .shell_script => return "external installers cannot be rolled back",
        else => return "this download format does not support staged upgrades yet",
    }
    if (!component(cask.version) or installer.filesystemToken(cask.token) == null) return "unsafe cask identity";
    var count: usize = 0;
    for (cask.artifacts) |art| switch (art) {
        .app => |app| {
            if (!relative(app) or !std.mem.endsWith(u8, app, ".app")) return "unsafe app path";
            count += 1;
        },
        .binary => |bin| {
            if (!component(bin.target)) return "unsafe binary target";
            if (std.mem.startsWith(u8, bin.source, "$APPDIR/")) {
                if (!relative(bin.source[8..])) return "unsafe app binary path";
            } else if (!relative(bin.source)) return "external binary sources cannot be rolled back";
            count += 1;
        },
        .pkg, .installer_script => return "external installers cannot be rolled back",
        .uninstall => |uninstall| {
            if (uninstall.pkgutil.len > 0) return "package installer receipts cannot be rolled back";
        },
        else => return "artifact requires side effects without rollback support",
    };
    return if (count == 0) "no app or binary artifacts to upgrade" else null;
}

fn contains(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, std.fs.path.basename(item), value)) return true;
    return false;
}

fn within(path: []const u8, root: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

fn ownedBinary(io: std.Io, link: []const u8, old: CaskRecord, old_payload: []const u8, applications: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(io, link, &buf) catch return false;
    const target = buf[0..n];
    if (!relative(std.mem.trimStart(u8, target, "/"))) return false;
    if (within(target, old_payload)) return true;
    for (old.apps) |app| {
        var app_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = std.fmt.bufPrint(&app_buf, "{s}/{s}", .{ applications, std.fs.path.basename(app) }) catch return false;
        if (within(target, root)) return true;
    }
    return false;
}

fn addStep(alloc: std.mem.Allocator, io: std.Io, steps: *std.ArrayList(transaction.Step), destination: []const u8, owned: bool, remove_only: bool) !void {
    for (steps.items) |step| if (std.mem.eql(u8, step.destination, destination)) return error.DuplicateDestination;
    const had_old = try transaction.exists(io, destination);
    if (had_old and !owned) return error.DestinationAlreadyExists;
    const staged = try std.fmt.allocPrint(alloc, "{s}.nb-upgrade-new", .{destination});
    const backup = try std.fmt.allocPrint(alloc, "{s}.nb-upgrade-old", .{destination});
    if (try transaction.exists(io, staged) or try transaction.exists(io, backup)) return error.DestinationAlreadyExists;
    const old_inode = if (had_old) (try std.Io.Dir.cwd().statFile(io, destination, .{ .follow_symlinks = false })).inode else null;
    try steps.append(alloc, .{ .destination = destination, .staged = staged, .backup = backup, .had_old = had_old, .old_inode = old_inode, .remove_only = remove_only });
}

/// Caller owns the command lock. Take the existing DB lock as well so an older
/// binary's state writer cannot race the database replacement.
pub fn recover(alloc: std.mem.Allocator, io: std.Io, locations: Locations) !bool {
    if (!try transaction.exists(io, locations.journal)) return false;
    const lock_path = try std.fmt.allocPrint(alloc, "{s}.lock", .{locations.database});
    defer alloc.free(lock_path);
    const lock = try std.Io.Dir.createFileAbsolute(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    return transaction.recover(alloc, io, locations.journal);
}

pub const Checkpoint = enum { staged, database, activating, activated, committed };
/// Dependency injection for deterministic filesystem and interruption tests.
/// The CLI always uses the defaults; no environment variable enables faults.
pub const Hooks = struct {
    stage: *const fn (std.mem.Allocator, std.Io, Cask, []const u8, []const u8) anyerror!void = installer.stageUpgrade,
    checkpoint: ?*const fn (Checkpoint, usize) anyerror!void = null,
    fn check(self: Hooks, point: Checkpoint, index: usize) !void {
        if (self.checkpoint) |f| try f(point, index);
    }
};

pub fn upgrade(alloc: std.mem.Allocator, io: std.Io, requested: []const u8, cask: Cask, locations: Locations) !void {
    return upgradeWithHooks(alloc, io, requested, cask, locations, .{});
}

pub fn upgradeWithHooks(alloc: std.mem.Allocator, io: std.Io, requested: []const u8, cask: Cask, locations: Locations, hooks: Hooks) !void {
    if (unsupportedReason(cask) != null) return error.UnsupportedCaskUpgrade;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{locations.database});
    const lock = try std.Io.Dir.createFileAbsolute(io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    _ = try transaction.recover(a, io, locations.journal);
    var db = try Database.openAt(a, locations.database);
    // Candidate state must NEVER auto-save during failure/unwinding.
    defer {
        db.dirty = false;
        db.close();
    }
    const old = db.findCask(requested) orelse return error.NotInstalled;
    const canonical = if (old.canonical_token.len > 0) old.canonical_token else old.token;
    if (!std.mem.eql(u8, canonical, cask.token)) return error.CaskIdentityChanged;
    if (std.mem.eql(u8, old.version, cask.version)) return error.AlreadyInstalled;
    if (!component(old.version)) return error.UnsafePath;
    const token = installer.filesystemToken(canonical) orelse return error.UnsafePath;
    const parent = try std.fs.path.join(a, &.{ locations.caskroom, token });
    const old_payload = try std.fs.path.join(a, &.{ parent, old.version });
    const new_payload = try std.fs.path.join(a, &.{ parent, cask.version });
    if (!try transaction.exists(io, old_payload)) return error.MissingOldPayload;
    var steps: std.ArrayList(transaction.Step) = .empty;
    try addStep(a, io, &steps, new_payload, false, false);
    var apps: std.ArrayList([]const u8) = .empty;
    var bins: std.ArrayList([]const u8) = .empty;
    for (cask.artifacts) |art| switch (art) {
        .app => |app| {
            const base = std.fs.path.basename(app);
            const destination = try std.fs.path.join(a, &.{ locations.applications, base });
            try addStep(a, io, &steps, destination, contains(old.apps, base), false);
            try apps.append(a, base);
        },
        else => {},
    };
    for (cask.artifacts) |art| switch (art) {
        .binary => |bin| {
            const destination = try std.fs.path.join(a, &.{ locations.bin, bin.target });
            const owned = contains(old.binaries, bin.target) and ownedBinary(io, destination, old, old_payload, locations.applications);
            try addStep(a, io, &steps, destination, owned, false);
            try bins.append(a, bin.target);
        },
        else => {},
    };
    // Removed artifacts also participate, so renames in metadata leave no
    // dangling public links and rollback can restore the old artifact set.
    for (old.binaries) |bin| {
        if (!component(bin)) return error.UnsafePath;
        if (!contains(bins.items, bin)) {
            const destination = try std.fs.path.join(a, &.{ locations.bin, bin });
            try addStep(a, io, &steps, destination, ownedBinary(io, destination, old, old_payload, locations.applications), true);
        }
    }
    for (old.apps) |app| {
        if (!relative(app)) return error.UnsafePath;
        const base = std.fs.path.basename(app);
        if (!contains(apps.items, base)) try addStep(a, io, &steps, try std.fs.path.join(a, &.{ locations.applications, base }), true, true);
    }
    for (steps.items[1..]) |step| {
        if (within(step.destination, locations.applications) and step.had_old) {
            const st = try std.Io.Dir.cwd().statFile(io, step.destination, .{ .follow_symlinks = false });
            if (st.kind != .directory) return error.DestinationAlreadyExists;
        }
        for (db.casks.items) |other| {
            if (std.mem.eql(u8, other.token, old.token)) continue;
            const names = if (within(step.destination, locations.applications)) other.apps else other.binaries;
            if (contains(names, std.fs.path.basename(step.destination))) return error.DestinationAlreadyExists;
        }
    }
    try addStep(a, io, &steps, locations.database, true, false);
    var journal: transaction.Journal = .{ .steps = steps.items, .old_payload = old_payload };
    try std.Io.Dir.createDirAbsolute(io, locations.journal, .default_dir);
    try transaction.save(a, io, locations.journal, journal);
    run(a, io, cask, locations, &db, old.token, &journal, apps.items, bins.items, hooks) catch |err| {
        _ = transaction.recover(a, io, locations.journal) catch return error.CaskRecoveryRequired;
        // The commit-marker rename can succeed even if its following directory
        // sync reports an error. Recovery follows the marker actually on disk.
        var recovered_db = try Database.openAt(a, locations.database);
        defer recovered_db.close();
        if (recovered_db.findCask(requested)) |installed| {
            if (std.mem.eql(u8, installed.version, cask.version) and std.mem.eql(u8, installed.sha256, cask.sha256)) return;
        }
        return err;
    };
    // A cleanup failure leaves a committed journal for the next command; the
    // successful upgrade must not be described as rolled back in this case.
    _ = transaction.recover(a, io, locations.journal) catch {
        std.Io.File.stderr().writeStreamingAll(io, "nb: cask upgrade committed; old payload cleanup will retry on the next command\n") catch {};
    };
}

fn run(a: std.mem.Allocator, io: std.Io, cask: Cask, locations: Locations, db: *Database, requested: []const u8, journal: *transaction.Journal, apps: []const []const u8, bins: []const []const u8, hooks: Hooks) !void {
    const payload = journal.steps[0];
    const download = try std.fs.path.join(a, &.{ locations.journal, "download" });
    try hooks.stage(a, io, cask, payload.staged, download);
    try hooks.check(.staged, 0);
    var step_index: usize = 1;
    for (cask.artifacts) |art| if (art == .app) {
        const source = try std.fs.path.join(a, &.{ payload.staged, art.app });
        try requireWithin(io, source, payload.staged);
        const app_stat = try std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false });
        if (app_stat.kind != .directory) return error.ArtifactFailed;
        const result = try std.process.run(a, io, .{ .argv = &.{ "/bin/cp", "-R", source, journal.steps[step_index].staged } });
        if (result.term != .exited or result.term.exited != 0) return error.ArtifactFailed;
        step_index += 1;
    };
    for (cask.artifacts) |art| if (art == .binary) {
        const bin = art.binary;
        const source = if (std.mem.startsWith(u8, bin.source, "$APPDIR/")) blk: {
            const rel = bin.source[8..];
            var found = false;
            for (apps) |app| if (within(rel, app)) {
                found = true;
                break;
            };
            if (!found) return error.UnownedAppBinary;
            // Validate against the staged app, never the still-active old app.
            const slash = std.mem.indexOfScalar(u8, rel, '/') orelse return error.UnsafePath;
            const staged_app = try std.fmt.allocPrint(a, "{s}/{s}.nb-upgrade-new", .{ locations.applications, rel[0..slash] });
            const check = try std.fs.path.join(a, &.{ staged_app, rel[slash + 1 ..] });
            try requireWithin(io, check, staged_app);
            try std.Io.Dir.accessAbsolute(io, check, .{ .execute = true });
            break :blk try std.fs.path.join(a, &.{ locations.applications, rel });
        } else try std.fs.path.join(a, &.{ payload.destination, bin.source });
        try std.Io.Dir.symLinkAbsolute(io, source, journal.steps[step_index].staged, .{});
        step_index += 1;
    };
    try db.recordCaskInstall(requested, cask.token, cask.version, cask.sha256, apps, bins);
    try hooks.check(.database, journal.steps.len - 1);
    try db.writeSnapshot(journal.steps[journal.steps.len - 1].staged);
    for (journal.steps) |step| if (!step.remove_only) try syncTree(a, io, step.staged);
    journal.activating = true;
    try transaction.save(a, io, locations.journal, journal.*);
    try hooks.check(.activating, 0);
    for (journal.steps, 0..) |step, i| {
        try transaction.activateStep(io, step);
        try hooks.check(.activated, i);
    }
    journal.committed = true;
    try transaction.save(a, io, locations.journal, journal.*);
    try hooks.check(.committed, 0);
}

fn requireWithin(io: std.Io, path: []const u8, root: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(io, path, &path_buf);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = try std.Io.Dir.cwd().realPathFile(io, root, &root_buf);
    if (!within(path_buf[0..n], root_buf[0..r])) return error.UnsafePath;
}

extern "c" fn fsync(fd: c_int) c_int;
fn syncTree(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return;
    if (stat.kind == .file) {
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.sync(io);
        return;
    }
    if (stat.kind != .directory) return error.UnsupportedFileType;
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const child = try std.fs.path.join(a, &.{ path, entry.name });
        try syncTree(a, io, child);
    }
    if (fsync(dir.handle) != 0) return error.DirectorySyncFailed;
}
