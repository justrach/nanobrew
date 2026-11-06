// nanobrew — bounded, cancelable TCP connect for std.http.Client (#503).
//
// Zig 0.16's Threaded Io connects with a blocking connect() and has no connect
// timeout yet (`ConnectOptions.timeout` panics with a TODO). A SYN that never
// gets an answer therefore blocks for the kernel's own limit. When the host name
// has several addresses, `HostName.connect` races them and then cancels the
// losers; on macOS that cancel waited on a blocked IPv6 connect for minutes
// while nb held the operation lock (#503).
//
// `withConnectTimeout` returns the same Io with only `netConnectIp` replaced:
// a nonblocking connect polled in short slices, so it gives up after
// `connect_timeout_ms` (the curl transport's `connect-timeout = 30`), and a
// canceled attempt (a losing address family) ends within one slice.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.Io.net;

/// Matches `connect-timeout = 30` in the curl transport (proxy.zig).
pub var connect_timeout_ms: u64 = 30_000;
/// How often a pending connect checks for cancellation.
const slice_ms: u64 = 25;

const supported = switch (builtin.os.tag) {
    .linux, .macos => true,
    else => false,
};

var wrapped_vtable: std.Io.VTable = undefined;
var base_connect: @TypeOf(@as(std.Io.VTable, undefined).netConnectIp) = undefined;

/// `io` with the bounded connect. Other operations are unchanged. Call once,
/// at startup; on unsupported platforms `io` is returned as is.
pub fn withConnectTimeout(io: std.Io) std.Io {
    if (!supported) return io;
    if (io.vtable == &wrapped_vtable) return io;
    wrapped_vtable = io.vtable.*;
    base_connect = io.vtable.netConnectIp;
    wrapped_vtable.netConnectIp = connectIp;
    return .{ .userdata = io.userdata, .vtable = &wrapped_vtable };
}

fn connectIp(userdata: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket {
    // Only plain TCP streams are bounded here; anything else keeps std's path.
    if (options.mode != .stream or options.timeout != .none or
        (options.protocol != null and options.protocol.? != .tcp))
    {
        return base_connect(userdata, address, options);
    }
    const io: std.Io = .{ .userdata = userdata, .vtable = &wrapped_vtable };
    return connectBounded(io, address, connect_timeout_ms);
}

const Storage = extern union {
    any: posix.sockaddr,
    in: posix.sockaddr.in,
    in6: posix.sockaddr.in6,
};

fn toPosix(address: *const net.IpAddress, storage: *Storage) posix.socklen_t {
    switch (address.*) {
        .ip4 => |a| {
            storage.* = .{ .in = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) } };
            return @sizeOf(posix.sockaddr.in);
        },
        .ip6 => |a| {
            storage.* = .{ .in6 = .{
                .port = std.mem.nativeToBig(u16, a.port),
                .flowinfo = a.flow,
                .addr = a.bytes,
                .scope_id = a.interface.index,
            } };
            return @sizeOf(posix.sockaddr.in6);
        },
    }
}

fn fromPosix(storage: *const Storage) net.IpAddress {
    if (storage.any.family == posix.AF.INET6) return .{ .ip6 = .{
        .port = std.mem.bigToNative(u16, storage.in6.port),
        .bytes = storage.in6.addr,
        .flow = storage.in6.flowinfo,
        .interface = .{ .index = storage.in6.scope_id },
    } };
    return .{ .ip4 = .{
        .port = std.mem.bigToNative(u16, storage.in.port),
        .bytes = @bitCast(storage.in.addr),
    } };
}

fn connectError(err: posix.E) net.IpAddress.ConnectError {
    return switch (err) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .ACCES, .PERM => error.AccessDenied,
        .NETDOWN => error.NetworkDown,
        .NOBUFS, .NOMEM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => error.Unexpected,
    };
}

fn setNonblocking(fd: posix.fd_t, on: bool) !void {
    const flags = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(flags) != .SUCCESS) return error.Unexpected;
    const bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    const current: usize = @intCast(flags);
    const next = if (on) current | bit else current & ~bit;
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, next)) != .SUCCESS) return error.Unexpected;
}

/// Connect within `timeout_ms`; `error.Canceled` within one slice of a cancel.
pub fn connectBounded(io: std.Io, address: *const net.IpAddress, timeout_ms: u64) net.IpAddress.ConnectError!net.Socket {
    var storage: Storage = undefined;
    const len = toPosix(address, &storage);
    const rc = posix.system.socket(storage.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    if (posix.errno(rc) != .SUCCESS) return connectError(posix.errno(rc));
    const fd: posix.fd_t = @intCast(rc);
    var keep = false;
    defer if (!keep) {
        _ = posix.system.close(fd);
    };
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) return error.Unexpected;
    try setNonblocking(fd, true);

    switch (posix.errno(posix.system.connect(fd, &storage.any, len))) {
        .SUCCESS => {},
        .INPROGRESS, .INTR, .AGAIN => {
            const started = std.Io.Clock.Timestamp.now(io, .awake);
            while (true) {
                const elapsed: u64 = @intCast(started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds());
                if (elapsed >= timeout_ms) return error.Timeout;
                var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                const wait: i32 = @intCast(@min(slice_ms, timeout_ms - elapsed));
                const n = posix.system.poll(&fds, 1, wait);
                switch (posix.errno(n)) {
                    .SUCCESS => if (n > 0) break,
                    .INTR => {},
                    else => |e| return connectError(e),
                }
                try io.checkCancel();
            }
            var so_error: i32 = 0;
            var so_len: posix.socklen_t = @sizeOf(i32);
            if (posix.errno(posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&so_error), &so_len)) != .SUCCESS) return error.Unexpected;
            if (so_error != 0) return connectError(@enumFromInt(so_error));
        },
        else => |e| return connectError(e),
    }
    // std's reads and writes on this socket expect a blocking descriptor.
    try setNonblocking(fd, false);
    var local: Storage = undefined;
    var local_len: posix.socklen_t = @sizeOf(Storage);
    if (posix.errno(posix.system.getsockname(fd, &local.any, &local_len)) != .SUCCESS) return error.Unexpected;
    keep = true;
    return .{ .handle = fd, .address = fromPosix(&local) };
}

// ── tests: local listeners whose accept queue is full drop new SYNs, so a
// connect to them stays pending, like a route that drops the traffic ──

/// IPV6_V6ONLY; std does not define it for Darwin.
const ipv6_v6only: u32 = if (builtin.os.tag == .macos) 27 else posix.IPV6.V6ONLY;

const Blackhole = struct {
    listener: posix.fd_t,
    fillers: [16]posix.fd_t = @splat(-1),
    port: u16,

    fn open(family: u32, port: u16) !Blackhole {
        const ip: net.IpAddress = if (family == posix.AF.INET6) .{ .ip6 = .{ .port = port, .bytes = net.Ip6Address.loopback(0).bytes } } else .{ .ip4 = .loopback(port) };
        var storage: Storage = undefined;
        const len = toPosix(&ip, &storage);
        const rc = posix.system.socket(storage.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        if (posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
        var self: Blackhole = .{ .listener = @intCast(rc), .port = 0 };
        errdefer self.close();
        const one: i32 = 1;
        _ = posix.system.setsockopt(self.listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, @ptrCast(&one), @sizeOf(i32));
        if (family == posix.AF.INET6) _ = posix.system.setsockopt(self.listener, posix.IPPROTO.IPV6, ipv6_v6only, @ptrCast(&one), @sizeOf(i32));
        if (posix.errno(posix.system.bind(self.listener, &storage.any, len)) != .SUCCESS) return error.SkipZigTest;
        // Backlog 1, not 0: XNU turns a backlog of 0 into `somaxconn` (128),
        // so 0 left room for every filler on macOS and nothing was dropped.
        if (posix.errno(posix.system.listen(self.listener, 1)) != .SUCCESS) return error.SkipZigTest;
        var bound: Storage = undefined;
        var bound_len: posix.socklen_t = @sizeOf(Storage);
        _ = posix.system.getsockname(self.listener, &bound.any, &bound_len);
        self.port = fromPosix(&bound).getPort();
        // Fill the accept queue; later SYNs are dropped and stay unanswered.
        const target: net.IpAddress = if (family == posix.AF.INET6) .{ .ip6 = .{ .port = self.port, .bytes = net.Ip6Address.loopback(0).bytes } } else .{ .ip4 = .loopback(self.port) };
        var tstorage: Storage = undefined;
        const tlen = toPosix(&target, &tstorage);
        for (&self.fillers) |*f| {
            const s = posix.system.socket(tstorage.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
            if (posix.errno(s) != .SUCCESS) continue;
            f.* = @intCast(s);
            setNonblocking(f.*, true) catch {};
            _ = posix.system.connect(f.*, &tstorage.any, tlen);
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(300), .awake);
        // Prove the fixture: one more connect must still be pending after
        // 300 ms. Otherwise the tests below would pass without testing anything.
        const probe = posix.system.socket(tstorage.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        if (posix.errno(probe) != .SUCCESS) return error.SkipZigTest;
        const probe_fd: posix.fd_t = @intCast(probe);
        defer _ = posix.system.close(probe_fd);
        try setNonblocking(probe_fd, true);
        _ = posix.system.connect(probe_fd, &tstorage.any, tlen);
        var fds = [_]posix.pollfd{.{ .fd = probe_fd, .events = posix.POLL.OUT, .revents = 0 }};
        if (posix.system.poll(&fds, 1, 300) != 0) return error.BlackholeFixtureAnswered;
        return self;
    }

    fn close(self: *Blackhole) void {
        for (self.fillers) |f| if (f >= 0) {
            _ = posix.system.close(f);
        };
        _ = posix.system.close(self.listener);
    }
};

fn elapsedMs(io: std.Io, started: std.Io.Clock.Timestamp) i64 {
    return @intCast(started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds());
}

test "a connect that never gets an answer gives up at the limit (#503)" {
    if (comptime !supported) return error.SkipZigTest;
    const io = std.testing.io;
    var hole = Blackhole.open(posix.AF.INET, 0) catch |e| {
        std.debug.print("NATIVE-PROOF-SKIP #503 blackhole ipv4: fixture {s}\n", .{@errorName(e)});
        return e;
    };
    defer hole.close();
    const address: net.IpAddress = .{ .ip4 = .loopback(hole.port) };
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, connectBounded(io, &address, 400));
    const ms = elapsedMs(io, started);
    try std.testing.expect(ms >= 350 and ms < 3000);
    std.debug.print("NATIVE-PROOF #503 blackhole ipv4 os={s}: probe stayed pending, connectBounded(400ms) -> Timeout after {d} ms\n", .{ @tagName(builtin.os.tag), ms });
}

test "the bounded connect still connects and refuses like connect() (#503)" {
    if (comptime !supported) return error.SkipZigTest;
    const io = std.testing.io;
    var server = try (net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer server.deinit(io);
    const stream = try connectBounded(io, &server.socket.address, 2000);
    _ = posix.system.close(stream.handle);
    const port = server.socket.address.getPort();
    server.deinit(io);
    server = try (net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    // The old port has no listener now.
    const closed: net.IpAddress = .{ .ip4 = .loopback(port) };
    try std.testing.expectError(error.ConnectionRefused, connectBounded(io, &closed, 2000));
    std.debug.print("NATIVE-PROOF #503 bounded connect os={s}: connected, then ConnectionRefused\n", .{@tagName(builtin.os.tag)});
}

test "a losing address family does not hold up the winner (#503)" {
    if (comptime !supported) return error.SkipZigTest;
    const io = withConnectTimeout(std.testing.io);
    const saved = connect_timeout_ms;
    defer connect_timeout_ms = saved;
    connect_timeout_ms = 20_000;
    // ::1 drops the SYN, 127.0.0.1 accepts, both on the same port: what a
    // dual-stack host with a dead IPv6 route looks like to HostName.connect.
    var hole = Blackhole.open(posix.AF.INET6, 0) catch |e| {
        std.debug.print("NATIVE-PROOF-SKIP #503 dual-stack: ipv6 fixture {s}\n", .{@errorName(e)});
        return e;
    };
    defer hole.close();
    var server = (net.IpAddress{ .ip4 = .loopback(hole.port) }).listen(io, .{ .reuse_address = true }) catch |e| {
        std.debug.print("NATIVE-PROOF-SKIP #503 dual-stack: ipv4 listen {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer server.deinit(io);
    const host = try net.HostName.init("localhost");
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    const stream = host.connect(io, hole.port, .{ .mode = .stream }) catch |err| {
        // No dual-stack "localhost" on this machine.
        if (err == error.ConnectionRefused or err == error.UnknownHostName) {
            std.debug.print("NATIVE-PROOF-SKIP #503 dual-stack: localhost connect {s}\n", .{@errorName(err)});
            return error.SkipZigTest;
        }
        return err;
    };
    stream.close(io);
    // The IPv6 attempt is canceled within a slice instead of after 20 s.
    const ms = elapsedMs(io, started);
    try std.testing.expect(ms < 3000);
    std.debug.print("NATIVE-PROOF #503 dual-stack os={s}: ::1 blackholed (probe pending), localhost connected via 127.0.0.1 in {d} ms with a 20 s limit\n", .{ @tagName(builtin.os.tag), ms });
}
