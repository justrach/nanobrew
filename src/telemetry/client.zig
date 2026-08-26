const std = @import("std");
const builtin = @import("builtin");
const paths = @import("../platform/paths.zig");
const proxy = @import("../net/proxy.zig");

const DEFAULT_ENDPOINT = "https://backend.trilok.ai/v1/telemetry/system";
const CONFIG_PATH = paths.CONFIG_DIR ++ "/telemetry";
const RING_CAPACITY = 16;
const MAX_TARGET_NAME = 120;

pub const TargetKind = enum {
    formula,
    cask,
    registry,
    self_update,
    artifact,
    unknown,
};

const Payload = struct {
    target_kind: TargetKind,
    target_name: [MAX_TARGET_NAME]u8 = undefined,
    target_name_len: usize = 0,
    duration_ms: u64,
    download_bytes: ?u64,
    success: bool,
};

var ring_mutex: std.atomic.Mutex = .unlocked;
var ring: [RING_CAPACITY]Payload = undefined;
var ring_cursor: usize = 0;
var ring_count: usize = 0;

pub const DownloadEvent = struct {
    target_kind: TargetKind,
    target_name: [MAX_TARGET_NAME]u8 = undefined,
    target_name_len: usize = 0,
    start_ms: u64,
    finished: bool = false,

    pub fn start(target_kind: TargetKind, target_name: []const u8) DownloadEvent {
        var event = DownloadEvent{
            .target_kind = target_kind,
            .start_ms = if (enabled()) monotonicMs() else 0,
        };
        event.target_name_len = copyTargetName(&event.target_name, target_name);
        return event;
    }

    pub fn succeed(self: *DownloadEvent, download_bytes: ?u64) void {
        self.finish(true, download_bytes);
    }

    pub fn fail(self: *DownloadEvent) void {
        self.finish(false, null);
    }

    fn finish(self: *DownloadEvent, success: bool, download_bytes: ?u64) void {
        if (self.finished) return;
        self.finished = true;
        if (!enabled()) return;

        const now = monotonicMs();
        const duration_ms = if (now >= self.start_ms) now - self.start_ms else 0;
        var payload = Payload{
            .target_kind = self.target_kind,
            .target_name_len = self.target_name_len,
            .duration_ms = duration_ms,
            .download_bytes = download_bytes,
            .success = success,
        };
        if (self.target_name_len > 0) {
            @memcpy(payload.target_name[0..self.target_name_len], self.target_name[0..self.target_name_len]);
        }

        pushRing(payload);
        dispatch(payload);
    }
};

pub fn fileSize(path: []const u8) ?u64 {
    const io = paths.safe_io;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    return stat.size;
}

pub fn isEnabled() bool {
    return enabled();
}

pub fn settingPath() []const u8 {
    return CONFIG_PATH;
}

pub fn setEnabled(value: bool) !void {
    const io = paths.safe_io;
    std.Io.Dir.createDirAbsolute(io, paths.CONFIG_DIR, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var file = try std.Io.Dir.createFileAbsolute(io, CONFIG_PATH, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, if (value) "on\n" else "off\n");
}

fn enabled() bool {
    if (std.c.getenv("NANOBREW_NO_TELEMETRY") != null) return false;
    if (std.c.getenv("NANOBREW_TELEMETRY")) |raw| return envValueEnabled(std.mem.span(raw));
    return readStoredEnabled() orelse true;
}

fn envValueEnabled(value_or_null: ?[]const u8) bool {
    const value = value_or_null orelse return true;
    if (std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return false;
    }
    return true;
}

fn readStoredEnabled() ?bool {
    const io = paths.safe_io;
    var file = std.Io.Dir.openFileAbsolute(io, CONFIG_PATH, .{}) catch return null;
    defer file.close(io);

    var buf: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return null;
    const value = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (value.len == 0) return null;
    if (std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return false;
    }
    if (std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on"))
    {
        return true;
    }
    return null;
}

fn syncEnabled() bool {
    const raw = std.c.getenv("NANOBREW_TELEMETRY_SYNC") orelse return false;
    const value = std.mem.span(raw);
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

fn endpoint() []const u8 {
    const raw = std.c.getenv("NANOBREW_TELEMETRY_ENDPOINT") orelse return DEFAULT_ENDPOINT;
    const value = std.mem.span(raw);
    if (std.mem.startsWith(u8, value, "https://") or std.mem.startsWith(u8, value, "http://")) {
        return value;
    }
    return DEFAULT_ENDPOINT;
}

fn dispatch(payload: Payload) void {
    if (syncEnabled()) {
        sendPayload(payload) catch {};
        return;
    }

    const alloc = std.heap.smp_allocator;
    const boxed = alloc.create(Payload) catch return;
    boxed.* = payload;
    const thread = std.Thread.spawn(.{}, sendPayloadThread, .{boxed}) catch {
        alloc.destroy(boxed);
        return;
    };
    thread.detach();
}

fn sendPayloadThread(payload: *Payload) void {
    const alloc = std.heap.smp_allocator;
    defer alloc.destroy(payload);
    sendPayload(payload.*) catch {};
}

fn sendPayload(payload: Payload) !void {
    const alloc = std.heap.smp_allocator;
    var body_buf: [1024]u8 = undefined;
    const body = try formatPayload(&body_buf, payload);

    const uri = std.Uri.parse(endpoint()) catch return error.TelemetrySendFailed;
    var client = proxy.Client.init(alloc, paths.safe_io);
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "nanobrew/telemetry" },
    };
    var req = client.ptr().request(.POST, uri, .{
        .redirect_behavior = @enumFromInt(1),
        .extra_headers = &headers,
    }) catch return error.TelemetrySendFailed;
    defer req.deinit();

    req.sendBodyComplete(body) catch return error.TelemetrySendFailed;
    var head_buf: [4096]u8 = undefined;
    const response = req.receiveHead(&head_buf) catch return error.TelemetrySendFailed;
    if (response.head.status != .accepted and response.head.status != .ok) {
        return error.TelemetrySendFailed;
    }
}

fn formatPayload(out: []u8, payload: Payload) ![]u8 {
    var ram_buf: [32]u8 = undefined;
    const ram_json = if (systemRamGb()) |ram_gb|
        try std.fmt.bufPrint(&ram_buf, "{d}", .{ram_gb})
    else
        "null";

    var cpu_buf: [32]u8 = undefined;
    const cpu_json = if (systemCpuCount()) |cpu_count|
        try std.fmt.bufPrint(&cpu_buf, "{d}", .{cpu_count})
    else
        "null";

    var bytes_buf: [32]u8 = undefined;
    const bytes_json = if (payload.download_bytes) |download_bytes|
        try std.fmt.bufPrint(&bytes_buf, "{d}", .{download_bytes})
    else
        "null";

    var target_buf: [MAX_TARGET_NAME + 2]u8 = undefined;
    const target_json = if (payload.target_name_len > 0)
        try std.fmt.bufPrint(&target_buf, "\"{s}\"", .{payload.target_name[0..payload.target_name_len]})
    else
        "null";

    return std.fmt.bufPrint(
        out,
        "{{\"schema\":1,\"source\":\"nanobrew\",\"event\":\"download\",\"os\":\"{s}\",\"arch\":\"{s}\",\"ram_gb\":{s},\"cpu_count\":{s},\"operation\":\"download\",\"target_kind\":\"{s}\",\"target_name\":{s},\"duration_ms\":{d},\"download_bytes\":{s},\"success\":{s}}}",
        .{
            osName(),
            archName(),
            ram_json,
            cpu_json,
            @tagName(payload.target_kind),
            target_json,
            payload.duration_ms,
            bytes_json,
            if (payload.success) "true" else "false",
        },
    );
}

fn pushRing(payload: Payload) void {
    while (!ring_mutex.tryLock()) std.atomic.spinLoopHint();
    defer ring_mutex.unlock();
    ring[ring_cursor] = payload;
    ring_cursor = (ring_cursor + 1) % RING_CAPACITY;
    ring_count = @min(ring_count + 1, RING_CAPACITY);
}

fn copyTargetName(dest: *[MAX_TARGET_NAME]u8, target_name: []const u8) usize {
    if (target_name.len == 0 or target_name.len > MAX_TARGET_NAME) return 0;
    if (!std.ascii.isAlphanumeric(target_name[0])) return 0;
    for (target_name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '@' or c == '.' or c == '_' or c == '+' or c == '/' or c == '-')) {
            return 0;
        }
    }
    if (std.mem.indexOf(u8, target_name, "://") != null) return 0;
    @memcpy(dest[0..target_name.len], target_name);
    return target_name.len;
}

fn systemRamGb() ?u64 {
    const bytes = std.process.totalSystemMemory() catch return null;
    const gib = 1024 * 1024 * 1024;
    const rounded = (bytes + (gib / 2)) / gib;
    if (rounded == 0 or rounded > 4096) return null;
    return rounded;
}

fn systemCpuCount() ?usize {
    return std.Thread.getCpuCount() catch null;
}

fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "unknown",
    };
}

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => "unknown",
    };
}

fn monotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(u64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

test "DownloadEvent keeps package-like target names only" {
    var good = DownloadEvent.start(.formula, "owner/tap/pkg");
    try std.testing.expectEqualStrings("owner/tap/pkg", good.target_name[0..good.target_name_len]);

    const url = DownloadEvent.start(.formula, "https://example.com/pkg.tgz");
    try std.testing.expectEqual(@as(usize, 0), url.target_name_len);

    const spaces = DownloadEvent.start(.formula, "has spaces");
    try std.testing.expectEqual(@as(usize, 0), spaces.target_name_len);
}

test "formatPayload writes exact numeric telemetry fields" {
    var payload = Payload{
        .target_kind = .cask,
        .duration_ms = 410,
        .download_bytes = 98_000_000,
        .success = true,
    };
    payload.target_name_len = copyTargetName(&payload.target_name, "firefox");

    var buf: [1024]u8 = undefined;
    const json = try formatPayload(&buf, payload);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_kind\":\"cask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target_name\":\"firefox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"duration_ms\":410") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"download_bytes\":98000000") != null);
}

test "telemetry env defaults to enabled and supports opt-out values" {
    try std.testing.expect(envValueEnabled(null));
    try std.testing.expect(envValueEnabled("1"));
    try std.testing.expect(envValueEnabled("true"));
    try std.testing.expect(!envValueEnabled("0"));
    try std.testing.expect(!envValueEnabled("false"));
    try std.testing.expect(!envValueEnabled("no"));
    try std.testing.expect(!envValueEnabled("off"));
}

test "live telemetry send smoke" {
    if (std.c.getenv("NANOBREW_TELEMETRY_LIVE_TEST") == null) return error.SkipZigTest;
    var event = DownloadEvent.start(.formula, "nanobrew-smoke");
    event.succeed(1234);
}
