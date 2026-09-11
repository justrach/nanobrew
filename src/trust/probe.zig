const std = @import("std");
const builtin = @import("builtin");

const probe_args = [_][]const u8{ "--version", "version", "--help" };

/// Per-executable outcome of an active probe (#317).
pub const Outcome = enum {
    /// The binary ran and exited with an accepted status.
    answered,
    /// Every fallback exited unsuccessfully or was terminated by a signal.
    unresponsive,
    timed_out,
    launch_failed,
    /// The package-wide budget was already spent before this binary got a
    /// slice — no evidence either way. A required artifact remains unverified.
    budget_exhausted,
};

/// Restricted login shells (git-shell and friends) ignore argv probes and
/// wait for their command loop; probing them wastes a slice and produces no
/// install-health signal (#317 field note).
pub fn isInteractiveShellLike(basename: []const u8) bool {
    if (std.mem.eql(u8, basename, "git-shell")) return true;
    if (std.mem.endsWith(u8, basename, "-sh")) return true;
    return false;
}

/// Package-wide probe budget with a per-executable slice. The slice keeps one
/// interactive tool (perl's cpan, instmodsh) from starving every later binary
/// of the package, while the package cap still prevents an N-binary keg from
/// turning the policy into N × slice (#317).
pub const Session = struct {
    io: std.Io,
    started: std.Io.Clock.Timestamp,
    package_budget: std.Io.Clock.Duration,
    per_binary_budget: std.Io.Clock.Duration,
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,
    last_arg: []const u8 = "--version",
    last_error: ?anyerror = null,
    last_term: ?std.process.Child.Term = null,
    last_elapsed_ms: i64 = 0,

    /// A single declared cask executable may use the cold-start allowance.
    /// Multiple executables retain slices so a hung command cannot monopolize it.
    pub fn initCask(io: std.Io, executable_count: usize) !Session {
        const package: std.Io.Clock.Duration = .{ .raw = std.Io.Duration.fromSeconds(10), .clock = .awake };
        const slice: std.Io.Clock.Duration = .{ .raw = std.Io.Duration.fromSeconds(if (executable_count == 1) 10 else 2), .clock = .awake };
        return init(io, package, slice);
    }

    pub fn init(
        io: std.Io,
        package_budget: std.Io.Clock.Duration,
        per_binary_budget: std.Io.Clock.Duration,
    ) !Session {
        var session: Session = .{
            .io = io,
            .started = std.Io.Clock.Timestamp.now(io, .awake),
            .package_budget = package_budget,
            .per_binary_budget = per_binary_budget,
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

    /// Milliseconds left in the package-wide budget (may be negative).
    fn remainingMs(self: *const Session) i64 {
        const now_ts = std.Io.Clock.Timestamp.now(self.io, .awake);
        const elapsed: i64 = @intCast(self.started.durationTo(now_ts).raw.toMilliseconds());
        const total: i64 = @intCast(self.package_budget.raw.toMilliseconds());
        return total - elapsed;
    }

    /// Absolute deadline for the next check: the per-binary slice, clamped to
    /// whatever remains of the package budget.
    pub fn timeout(self: *const Session) std.Io.Timeout {
        const remaining = @max(self.remainingMs(), 1);
        const per_binary: i64 = @intCast(self.per_binary_budget.raw.toMilliseconds());
        const slice_ms = @min(per_binary, remaining);
        const slice: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(slice_ms)),
            .clock = .awake,
        } };
        return slice.toDeadline(self.io);
    }

    pub fn cwd(self: *const Session) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    pub fn probe(self: *Session, _: std.mem.Allocator, path: []const u8) Outcome {
        if (self.remainingMs() <= 0) return .budget_exhausted;
        self.last_error = null;
        self.last_term = null;
        const started = std.Io.Clock.Timestamp.now(self.io, .awake);
        defer self.last_elapsed_ms = @intCast(started.durationTo(std.Io.Clock.Timestamp.now(self.io, .awake)).raw.toMilliseconds());
        const deadline = self.timeout();
        const probe_cwd = self.cwd_buf[0..self.cwd_len];
        for (probe_args) |arg| {
            self.last_arg = arg;
            const term = runProbe(self.io, path, arg, probe_cwd, deadline) catch |err| {
                self.last_error = err;
                if (err == error.Timeout) return .timed_out;
                return .launch_failed;
            };
            self.last_term = term;
            switch (term) {
                .exited => |code| if (code == 0 or code == 1 or code == 2) return .answered,
                else => {},
            }
        }
        return .unresponsive;
    }

    pub fn executableAnswers(self: *Session, alloc: std.mem.Allocator, path: []const u8) bool {
        return self.probe(alloc, path) == .answered;
    }
};

/// Bound process exit by the same absolute deadline as fallback arguments.
/// Waiting only for stdout/stderr is insufficient: a program can close both
/// streams and then hang. Probe output is intentionally discarded.
fn runProbe(io: std.Io, path: []const u8, arg: []const u8, cwd: []const u8, deadline: std.Io.Timeout) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = &.{ path, arg },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    if (builtin.os.tag != .windows) return waitProbePosix(io, &child, deadline);
    defer child.kill(io);
    const Event = union(enum) {
        exited: std.process.Child.WaitError!std.process.Child.Term,
        timed_out: std.Io.Cancelable!void,
    };
    var buffer: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.exited, std.process.Child.wait, .{ &child, io });
    try select.concurrent(.timed_out, std.Io.Timeout.sleep, .{ deadline, io });
    return switch (try select.await()) {
        .exited => |result| try result,
        .timed_out => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
    };
}

extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;

fn waitProbePosix(io: std.Io, child: *std.process.Child, deadline: std.Io.Timeout) !std.process.Child.Term {
    // Zig 0.16's canceled Child.wait clears child.id without killing/reaping it.
    // Keep sole ownership of the PID and use nonblocking waits instead. No
    // concurrent waiter can reap and allow PID reuse before timeout cleanup.
    defer if (child.id) |pid| {
        // Child.kill uses SIGTERM, which an executable can ignore.
        std.posix.kill(pid, .KILL) catch {};
        child.kill(io);
    };
    const end = deadline.toTimestamp(io).?;
    while (true) {
        var status: c_int = undefined;
        const result = waitpid(child.id.?, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result != 0) {
                child.id = null;
                const bits: u32 = @bitCast(status);
                if (std.posix.W.IFEXITED(bits)) return .{ .exited = std.posix.W.EXITSTATUS(bits) };
                if (std.posix.W.IFSIGNALED(bits)) return .{ .signal = std.posix.W.TERMSIG(bits) };
                return .{ .unknown = bits };
            },
            .INTR => continue,
            else => return error.ProcessWaitFailed,
        }
        const now = std.Io.Clock.Timestamp.now(io, end.clock);
        if (now.compare(.gte, end)) return error.Timeout;
        const remaining = now.durationTo(end).raw.toNanoseconds();
        try std.Io.sleep(io, .fromNanoseconds(@min(remaining, 10 * std.time.ns_per_ms)), end.clock);
    }
}

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
    var session = Session.init(io, budget, budget) catch return false;
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

test "isInteractiveShellLike flags restricted shells only (#317)" {
    try std.testing.expect(isInteractiveShellLike("git-shell"));
    try std.testing.expect(isInteractiveShellLike("rksh-sh"));
    try std.testing.expect(!isInteractiveShellLike("git"));
    try std.testing.expect(!isInteractiveShellLike("perl"));
    try std.testing.expect(!isInteractiveShellLike("bash"));
}

test "per-binary slice keeps one hung binary from starving the package (#317)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script =
        \\#!/bin/sh
        \\i=0
        \\while [ "$i" -lt 40 ]; do
        \\  sleep 0.05
        \\  i=$((i + 1))
        \\done
        \\exit 3
        \\
    ;
    var file = try tmp.dir.createFile(std.testing.io, "hang", .{});
    try file.writeStreamingAll(std.testing.io, script);
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "hang", &path_buf);
    const path = path_buf[0..path_len];

    var session = try Session.init(std.testing.io, .{
        .raw = std.Io.Duration.fromMilliseconds(400),
        .clock = .awake,
    }, .{
        .raw = std.Io.Duration.fromMilliseconds(100),
        .clock = .awake,
    });
    defer session.deinit();

    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var unresponsive: usize = 0;
    var exhausted: usize = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        switch (session.probe(std.testing.allocator, path)) {
            .answered => return error.TestUnexpectedResult,
            .unresponsive, .timed_out, .launch_failed => unresponsive += 1,
            .budget_exhausted => exhausted += 1,
        }
    }
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));

    // Each hung binary loses only its own slice; once the package budget is
    // spent, later binaries are skipped without failing. Eight probes of a
    // hung binary under the old one-shared-deadline design would either take
    // one slice total (starvation) or 8 × the slice; with slices + cap we see
    // both unresponsive and exhausted outcomes, quickly.
    try std.testing.expect(unresponsive >= 1);
    try std.testing.expect(exhausted >= 1);
    try std.testing.expect(unresponsive + exhausted == 8);
    try std.testing.expect(elapsed.raw.toMilliseconds() < 3000);
}

test "single cask executable receives cold-start allowance (#386)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "cold", .{});
    try file.writeStreamingAll(std.testing.io,
        \\#!/bin/sh
        \\if [ ! -f warmed ]; then sleep 2.2; touch warmed; fi
        \\exit 0
        \\
    );
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(std.testing.io, "cold", &buf);
    var session = try Session.initCask(std.testing.io, 1);
    defer session.deinit();
    try std.testing.expectEqual(Outcome.answered, session.probe(std.testing.allocator, buf[0..n]));
    try std.testing.expect(session.last_elapsed_ms > 2000);
    try std.testing.expect(session.last_elapsed_ms < 10000);
    try std.testing.expectEqual(Outcome.answered, session.probe(std.testing.allocator, buf[0..n]));
}

test "probe distinguishes timeout launch and exit failures (#386)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "fail", .{});
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\nexit 42\n");
    try file.setPermissions(std.testing.io, .executable_file);
    file.close(std.testing.io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(std.testing.io, "fail", &buf);
    var session = try Session.initCask(std.testing.io, 2);
    defer session.deinit();
    try std.testing.expectEqual(@as(i64, 2000), session.per_binary_budget.raw.toMilliseconds());
    try std.testing.expectEqual(Outcome.unresponsive, session.probe(std.testing.allocator, buf[0..n]));
    try std.testing.expectEqual(@as(u8, 42), session.last_term.?.exited);
    try std.testing.expectEqualStrings("--help", session.last_arg);
    try std.testing.expectEqual(Outcome.launch_failed, session.probe(std.testing.allocator, "/nonexistent/nb-probe"));
    try std.testing.expect(session.last_error != null);
    file = try tmp.dir.createFile(std.testing.io, "fail", .{});
    try file.writeStreamingAll(std.testing.io, "#!/bin/sh\nwhile :; do sleep 0.05; done\n");
    file.close(std.testing.io);
    session.per_binary_budget.raw = std.Io.Duration.fromMilliseconds(100);
    try std.testing.expectEqual(Outcome.timed_out, session.probe(std.testing.allocator, buf[0..n]));
    try std.testing.expectEqualStrings("--version", session.last_arg);
    try std.testing.expect(session.last_elapsed_ms < 1500);
}

test "probe deadline bounds a process that closes its output streams" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var file = try tmp.dir.createFile(io, "closed-streams", .{});
    try file.writeStreamingAll(io, "#!/bin/sh\nexec 1>&- 2>&-\nwhile :; do sleep 0.05; done\n");
    try file.setPermissions(io, .executable_file);
    file.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "closed-streams", &buf);
    var session = try Session.initCask(io, 1);
    defer session.deinit();
    session.per_binary_budget.raw = std.Io.Duration.fromMilliseconds(100);
    try std.testing.expectEqual(Outcome.timed_out, session.probe(std.testing.allocator, buf[0..n]));
    try std.testing.expect(session.last_elapsed_ms < 1500);
}

test "fallback arguments spend the remaining executable deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var file = try tmp.dir.createFile(io, "fallback", .{});
    try file.writeStreamingAll(io, "#!/bin/sh\ncase \"$1\" in --version) sleep 0.6 ;; version) sleep 3 ;; esac\nexit 42\n");
    try file.setPermissions(io, .executable_file);
    file.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "fallback", &buf);
    var session = try Session.initCask(io, 2);
    defer session.deinit();
    session.per_binary_budget.raw = std.Io.Duration.fromMilliseconds(3300);
    try std.testing.expectEqual(Outcome.timed_out, session.probe(std.testing.allocator, buf[0..n]));
    try std.testing.expectEqualStrings("version", session.last_arg);
    try std.testing.expect(session.last_elapsed_ms < 5000);
    // The hung fallback has not consumed the next executable's allowance.
    try std.testing.expectEqual(Outcome.answered, session.probe(std.testing.allocator, "/usr/bin/true"));
}

test "timeout kills and reaps a process that ignores SIGTERM" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "ignore-term", .{});
    try file.writeStreamingAll(io, "#!/bin/sh\ntrap '' TERM\necho $$ > child.pid\nwhile :; do :; done\n");
    try file.setPermissions(io, .executable_file);
    file.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "ignore-term", &buf);
    var session = try Session.initCask(io, 1);
    defer session.deinit();
    session.per_binary_budget.raw = std.Io.Duration.fromMilliseconds(500);
    try std.testing.expectEqual(Outcome.timed_out, session.probe(a, buf[0..n]));
    const pid_path = try std.fs.path.join(a, &.{ session.cwd(), "child.pid" });
    defer a.free(pid_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, pid_path, a, .limited(64));
    defer a.free(bytes);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, "\r\n "), 10);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
    try std.testing.expect(session.last_elapsed_ms < 1500);
}
