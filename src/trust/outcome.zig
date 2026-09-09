const std = @import("std");
const evidence = @import("evidence.zig");
const paths = @import("../platform/paths.zig");
const telemetry = @import("../telemetry/client.zig");

pub const Outcome = struct {
    schema: u32 = 1,
    token: []const u8,
    kind: evidence.Kind,
    version: []const u8,
    platform: []const u8,
    sha256: []const u8,
    installed: bool,
    probe: ?bool,
    probe_schema: u32 = evidence.PROBE_SCHEMA,
    // Random installation secret hashed with this artifact identity. No host,
    // username, paths, IP address, or identifier shared across packages.
    reporter: []const u8 = "",
};
pub fn report(value: Outcome) void {
    if (!telemetry.outcomesEnabled() or !evidence.validSha(value.sha256)) return;
    send(value) catch {};
}
fn send(value: Outcome) !void {
    const a = std.heap.smp_allocator;
    const seed_path = evidence.env("NANOBREW_OUTCOME_SEED_PATH") orelse paths.CONFIG_DIR ++ "/outcome-seed";
    var seed: [32]u8 = undefined;
    if (evidence.read(a, seed_path)) |stored| {
        defer a.free(stored);
        if (stored.len != seed.len) return error.InvalidOutcomeSeed;
        @memcpy(&seed, stored);
    } else |err| switch (err) {
        error.FileNotFound => {
            try paths.safe_io.randomSecure(&seed);
            if (std.fs.path.dirname(seed_path)) |dir| try std.Io.Dir.cwd().createDirPath(paths.safe_io, dir);
            const file = try std.Io.Dir.cwd().createFile(paths.safe_io, seed_path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
            defer file.close(paths.safe_io);
            try file.writeStreamingAll(paths.safe_io, &seed);
        },
        else => return err,
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&seed);
    hasher.update(value.token);
    hasher.update(value.platform);
    hasher.update(value.sha256);
    const reporter = std.fmt.bytesToHex(hasher.finalResult(), .lower);
    var payload = value;
    payload.reporter = &reporter;
    const json = try std.json.Stringify.valueAlloc(a, payload, .{});
    if (evidence.env("NANOBREW_TELEMETRY_SYNC")) |v| {
        if (std.mem.eql(u8, v, "1")) {
            dispatch(json);
            return;
        }
    }
    const thread = std.Thread.spawn(.{}, dispatch, .{json}) catch {
        a.free(json);
        return;
    };
    thread.detach();
}
fn dispatch(json: []u8) void {
    defer std.heap.smp_allocator.free(json);
    telemetry.sendJson(json, evidence.env("NANOBREW_OUTCOME_ENDPOINT") orelse "https://nanobrew.trilok.ai/v1/install-outcomes") catch {};
}
