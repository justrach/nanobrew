//! Isolated cask transaction driver; never touches the real nanobrew prefix.
const std = @import("std");
const upgrade = @import("cask/upgrade.zig");
const Cask = @import("api/cask.zig").Cask;
const installer = @import("cask/install.zig");
var archive: []const u8 = undefined;
var fault: []const u8 = undefined;
var added_link: []const u8 = undefined;
var db_staged: []const u8 = undefined;
var test_io: std.Io = undefined;

fn stage(a: std.mem.Allocator, io: std.Io, cask: Cask, directory: []const u8, _: []const u8) !void {
    try installer.stageUpgradeArchive(a, io, cask, directory, archive);
}
fn checkpoint(point: upgrade.Checkpoint, index: usize) !void {
    var buf: [80]u8 = undefined;
    const key = try std.fmt.bufPrint(&buf, "{s}-{d}", .{ @tagName(point), index });
    if (std.mem.eql(u8, fault, "late-conflict") and point == .activating) {
        const file = try std.Io.Dir.createFileAbsolute(test_io, added_link, .{ .exclusive = true });
        defer file.close(test_io);
        try file.writeStreamingAll(test_io, "foreign");
    }
    if (std.mem.eql(u8, fault, "database-failure") and point == .database) {
        try std.Io.Dir.createDirAbsolute(test_io, db_staged, .default_dir);
        return;
    }
    if (std.mem.startsWith(u8, fault, "fail-") and std.mem.eql(u8, fault[5..], key)) return error.InjectedFailure;
    if (std.mem.startsWith(u8, fault, "crash-") and std.mem.eql(u8, fault[6..], key)) std.process.exit(75);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return error.Usage;
    @import("platform/paths.zig").safe_io = init.io;
    test_io = init.io;
    const root = args[1];
    const locations: upgrade.Locations = .{
        .caskroom = try std.fs.path.join(a, &.{ root, "Caskroom" }),
        .applications = try std.fs.path.join(a, &.{ root, "Applications" }),
        .bin = try std.fs.path.join(a, &.{ root, "bin" }),
        .database = try std.fs.path.join(a, &.{ root, "state.json" }),
        .journal = try std.fs.path.join(a, &.{ root, "transaction" }),
    };
    if (std.mem.eql(u8, args[4], "recover")) {
        _ = try upgrade.recover(a, init.io, locations);
        return;
    }
    archive = args[2];
    fault = args[4];
    added_link = try std.fs.path.join(a, &.{ root, "bin/added" });
    db_staged = try std.fmt.allocPrint(a, "{s}.nb-upgrade-new", .{locations.database});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], a, .limited(1024 * 1024));
    const cask = try std.json.parseFromSlice(Cask, a, bytes, .{ .allocate = .alloc_always });
    try upgrade.upgradeWithHooks(a, init.io, "fixture", cask.value, locations, .{ .stage = stage, .checkpoint = checkpoint });
}
