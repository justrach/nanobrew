//! Recoverable multi-path activation. The journal is durable before staging;
//! each destination and its sidecars share a filesystem. Until the committed
//! marker is durable, recovery restores every old destination (including DB).
//! Callers hold the command lock and database writer lock throughout.
const std = @import("std");
const builtin = @import("builtin");

const max_journal_bytes = 1024 * 1024;

pub const Step = struct {
    destination: []const u8,
    staged: []const u8,
    backup: []const u8,
    had_old: bool,
    old_inode: ?std.Io.File.INode = null,
    remove_only: bool = false,
};

pub const Journal = struct {
    committed: bool = false,
    activating: bool = false,
    rolled_back: bool = false,
    steps: []const Step,
    old_payload: []const u8,
};

extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;

pub fn exists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn syncParent(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{});
    defer dir.close(io);
    if (fsync(dir.handle) != 0) return error.DirectorySyncFailed;
}

pub fn rename(io: std.Io, from: []const u8, to: []const u8) !void {
    try std.Io.Dir.renameAbsolute(from, to, io);
    try syncParent(io, to);
    if (!std.mem.eql(u8, std.fs.path.dirname(from) orelse ".", std.fs.path.dirname(to) orelse ".")) try syncParent(io, from);
}

fn renameNew(io: std.Io, from: []const u8, to: []const u8) !void {
    if (builtin.os.tag == .macos) {
        // Zig 0.16's generic preserve-rename uses link/unlink on Darwin,
        // which cannot move directories and is not an atomic rename.
        const from_z = try std.posix.toPosixPath(from);
        const to_z = try std.posix.toPosixPath(to);
        switch (std.posix.errno(renamex_np(&from_z, &to_z, 0x00000004))) { // RENAME_EXCL
            .SUCCESS => {},
            .EXIST => return error.DestinationAlreadyExists,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.RenameFailed,
        }
    } else {
        try std.Io.Dir.renamePreserve(.cwd(), from, .cwd(), to, io);
    }
    try syncParent(io, to);
}

fn remove(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, path);
    try syncParent(io, path);
}

pub fn save(alloc: std.mem.Allocator, io: std.Io, directory: []const u8, journal: Journal) !void {
    const path = try std.fs.path.join(alloc, &.{ directory, "journal.json" });
    defer alloc.free(path);
    const temp = try std.fs.path.join(alloc, &.{ directory, "journal.tmp" });
    defer alloc.free(temp);
    const bytes = try std.json.Stringify.valueAlloc(alloc, journal, .{});
    defer alloc.free(bytes);
    // Never publish a journal that recovery cannot read.
    if (bytes.len > max_journal_bytes) return error.JournalTooLarge;
    const file = try std.Io.Dir.createFileAbsolute(io, temp, .{});
    {
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try rename(io, temp, path);
    try syncParent(io, directory);
}

pub fn activateStep(io: std.Io, step: Step) !void {
    // Recheck just before activation: never overwrite a new foreign conflict.
    if (try exists(io, step.destination) != step.had_old) return error.DestinationChanged;
    if (try exists(io, step.backup)) return error.DestinationAlreadyExists;
    if (step.had_old) {
        const before = try std.Io.Dir.cwd().statFile(io, step.destination, .{ .follow_symlinks = false });
        if (step.old_inode) |inode| if (inode != before.inode) return error.DestinationChanged;
        try renameNew(io, step.destination, step.backup);
    }
    if (!step.remove_only) try renameNew(io, step.staged, step.destination);
}

pub fn rollback(io: std.Io, journal: Journal) !void {
    // Keep staged markers until a durable rolled_back marker is written.
    // This makes rollback itself restartable without mistaking a foreign
    // destination for an addition that we previously activated.
    var i = journal.steps.len;
    while (i > 0) {
        i -= 1;
        const step = journal.steps[i];
        if (try exists(io, step.backup)) {
            const backup = try std.Io.Dir.cwd().statFile(io, step.backup, .{ .follow_symlinks = false });
            if (step.old_inode) |inode| if (inode != backup.inode) return error.DestinationChanged;
            try remove(io, step.destination);
            try renameNew(io, step.backup, step.destination);
        } else if (journal.activating and !step.had_old and !step.remove_only and
            !try exists(io, step.staged) and try exists(io, step.destination))
        {
            try renameNew(io, step.destination, step.staged);
        }
    }
}

pub fn cleanup(io: std.Io, journal: Journal) !void {
    for (journal.steps) |step| {
        if (journal.committed) try remove(io, step.backup);
        try remove(io, step.staged);
    }
    if (journal.committed) try remove(io, journal.old_payload);
}

pub fn recover(alloc: std.mem.Allocator, io: std.Io, directory: []const u8) !bool {
    const path = try std.fs.path.join(alloc, &.{ directory, "journal.json" });
    defer alloc.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(max_journal_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            // Directory creation or initial journal write was interrupted;
            // staging cannot have begun before publication of journal.json.
            if (try exists(io, directory)) try remove(io, directory);
            return false;
        },
        else => return err,
    };
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(Journal, alloc, bytes, .{});
    defer parsed.deinit();
    if (!parsed.value.committed and !parsed.value.rolled_back) {
        try rollback(io, parsed.value);
        parsed.value.rolled_back = true;
        try save(alloc, io, directory, parsed.value);
    }
    try cleanup(io, parsed.value);
    try remove(io, directory);
    return true;
}

test "oversized journal cannot replace a recoverable journal" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const directory = buf[0..n];
    const original: Journal = .{ .steps = &.{}, .old_payload = "" };
    try save(a, io, directory, original);
    const large = try a.alloc(u8, max_journal_bytes);
    defer a.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.JournalTooLarge, save(a, io, directory, .{ .steps = &.{}, .old_payload = large }));
    const bytes = try tmp.dir.readFileAlloc(io, "journal.json", a, .limited(max_journal_bytes));
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Journal, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.old_payload);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.steps.len);
}
