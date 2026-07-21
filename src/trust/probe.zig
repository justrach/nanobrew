const std = @import("std");
const builtin = @import("builtin");

const probe_args = [_][]const u8{ "--version", "version", "--help" };

/// One package-wide active-probe budget. Every executable and fallback argument
/// shares this absolute deadline, preventing an N-binary package from turning a
/// two-second policy into N × two seconds.
pub const Session = struct {
    io: std.Io,
    deadline: std.Io.Timeout,
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,

    pub fn init(io: std.Io, budget: std.Io.Clock.Duration) !Session {
        const relative_timeout: std.Io.Timeout = .{ .duration = budget };
        var session: Session = .{
            .io = io,
            .deadline = relative_timeout.toDeadline(io),
        };

        // Version/help commands are third-party code and can have surprising
        // side effects. Never inherit the caller's working directory.
        const env_name = if (builtin.os.tag == .windows) "TEMP" else "TMPDIR";
        const temp_root: []const u8 = if (std.c.getenv(env_name)) |raw|
            std.mem.sliceTo(raw, 0)
        else if (builtin.os.tag == .windows)
            return error.MissingTempDirectory
        else
            "/tmp";
        if (!std.fs.path.isAbsolute(temp_root)) return error.InvalidTempDirectory;
        const probe_cwd = try std.fmt.bufPrint(&session.cwd_buf, "{s}{c}nanobrew-probe-{d}-{d}", .{
            temp_root, std.fs.path.sep, std.c.getpid(), std.Thread.getCurrentId(),
        });
        session.cwd_len = probe_cwd.len;
        std.Io.Dir.cwd().deleteTree(io, probe_cwd) catch {};
        try std.Io.Dir.createDirAbsolute(io, probe_cwd, .default_dir);
        return session;
    }

    pub fn deinit(self: *Session) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.cwd_buf[0..self.cwd_len]) catch {};
    }

    pub fn timeout(self: *const Session) std.Io.Timeout {
        return self.deadline;
    }

    pub fn cwd(self: *const Session) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    pub fn executableAnswers(self: *Session, alloc: std.mem.Allocator, path: []const u8) bool {
        const probe_cwd = self.cwd_buf[0..self.cwd_len];
        for (probe_args) |arg| {
            const result = std.process.run(alloc, self.io, .{
                .argv = &.{ path, arg },
                .cwd = .{ .path = probe_cwd },
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
                .timeout = self.deadline,
            }) catch continue;
            defer alloc.free(result.stdout);
            defer alloc.free(result.stderr);

            switch (result.term) {
                .exited => |code| if (code == 0 or code == 1 or code == 2) return true,
                else => {},
            }
        }
        return false;
    }
};

pub fn executableAnswers(alloc: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    return executableAnswersWithin(alloc, io, path, .{
        .raw = std.Io.Duration.fromSeconds(2),
        .clock = .awake,
    });
}

fn executableAnswersWithin(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    budget: std.Io.Clock.Duration,
) bool {
    var session = Session.init(io, budget) catch return false;
    defer session.deinit();
    return session.executableAnswers(alloc, path);
}

test "executableAnswers accepts a responsive executable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(executableAnswers(std.testing.allocator, std.testing.io, "/usr/bin/false"));
}

test "probe side effects stay out of the caller working directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const marker = ".nanobrew-probe-isolation-test";
    std.Io.Dir.cwd().deleteFile(std.testing.io, marker) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, marker) catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\#!/bin/sh
        \\: > .nanobrew-probe-isolation-test
        \\exit 0
        \\
    ;
    var file = try tmp.dir.createFile(std.testing.io, "side-effect", .{});
    try file.writeStreamingAll(std.testing.io, script);
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "side-effect", &path_buf);
    try std.testing.expect(executableAnswers(std.testing.allocator, std.testing.io, path_buf[0..path_len]));
    const escaped = if (std.Io.Dir.cwd().access(std.testing.io, marker, .{})) |_| true else |_| false;
    try std.testing.expect(!escaped);
}

test "probe attempts share one absolute timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\i=0
        \\while [ "$i" -lt 40 ]; do
        \\  printf x
        \\  sleep 0.05
        \\  i=$((i + 1))
        \\done
        \\exit 3
        \\
    ;
    var file = try tmp.dir.createFile(std.testing.io, "slow-output", .{});
    try file.writeStreamingAll(std.testing.io, script);
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "slow-output", &path_buf);
    const path = path_buf[0..path_len];
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const passed = executableAnswersWithin(std.testing.allocator, std.testing.io, path, .{
        .raw = std.Io.Duration.fromMilliseconds(500),
        .clock = .awake,
    });
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));

    try std.testing.expect(!passed);
    // A relative timeout restarts for each output read and takes ~2s per
    // attempt. One deadline returns near 500ms, with generous CI headroom.
    try std.testing.expect(elapsed.raw.toMilliseconds() < 1500);
}
