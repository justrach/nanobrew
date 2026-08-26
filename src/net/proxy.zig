// nanobrew — HTTP proxy environment support
//
// Zig's std.http.Client has native proxy support, but it requires callers to
// opt in by calling initDefaultProxies. Keep that setup in one place so every
// network path uses the same HTTP_PROXY/HTTPS_PROXY/ALL_PROXY behavior.

const std = @import("std");

const http_proxy_names = [_][:0]const u8{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" };
const https_proxy_names = [_][:0]const u8{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" };

/// An HTTP client paired with the arena that owns its proxy configuration.
/// Keep this value alive until all requests using `ptr()` are complete.
pub const Client = struct {
    inner: std.http.Client,
    proxy_arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Client {
        var client: Client = .{
            .inner = .{ .allocator = alloc, .io = io },
            .proxy_arena = std.heap.ArenaAllocator.init(alloc),
        };
        initDefaultProxies(&client.inner, client.proxy_arena.allocator());
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.inner.deinit();
        self.proxy_arena.deinit();
    }

    pub fn ptr(self: *Client) *std.http.Client {
        return &self.inner;
    }
};

fn envValue(comptime name: [:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name.ptr) orelse return null;
    const value = std.mem.sliceTo(raw, 0);
    return if (value.len == 0) null else value;
}

fn firstNonEmpty(comptime names: []const [:0]const u8) ?[]const u8 {
    inline for (names) |name| {
        if (envValue(name)) |value| return value;
    }
    return null;
}

/// Configure a client from the conventional proxy environment variables.
///
/// `arena` must outlive `client`, because std.http.Client stores pointers to
/// proxy records and their host/authentication strings. Invalid proxy values
/// and allocation failures leave the client unproxied rather than preventing
/// a direct request from working.
pub fn initDefaultProxies(client: *std.http.Client, arena: std.mem.Allocator) void {
    var environ_map = std.process.Environ.Map.init(arena);

    // The standard-library parser may retain raw host bytes from an
    // environment-map value. Keep the map allocations alive in `arena` until
    // the client is deinitialized instead of freeing them here.
    // Populate one canonical key for each scheme. This preserves the usual
    // lowercase-first precedence even on Windows, where environment names are
    // case-insensitive and cannot reliably coexist in a Map.
    if (firstNonEmpty(&http_proxy_names)) |value| {
        environ_map.put("http_proxy", value) catch return;
    }
    if (firstNonEmpty(&https_proxy_names)) |value| {
        environ_map.put("https_proxy", value) catch return;
    }

    initProxiesFromMap(client, arena, &environ_map);
}

fn initProxiesFromMap(
    client: *std.http.Client,
    arena: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) void {
    client.initDefaultProxies(arena, environ_map) catch {};

    // Zig 0.16's HTTP CONNECT path returns the proxy's plain connection for
    // an HTTPS origin without layering TLS over the tunnel. Use the standard
    // absolute-form request path instead; an HTTP(S) forward proxy then owns
    // the TLS connection to the origin. Without this, HTTPS requests fail
    // after CONNECT with an EOF/truncated response.
    if (client.https_proxy) |https_proxy| https_proxy.supports_connect = false;
}

// Keep these tests focused on the environment-variable precedence supplied to
// the standard library, plus the HTTPS proxy compatibility setting above.
test "proxy environment names prefer scheme-specific values" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("http_proxy", "http://http.example:8080");
    try map.put("https_proxy", "http://https.example:8080");
    try map.put("all_proxy", "http://all.example:8080");

    var proxy_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer proxy_arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    initProxiesFromMap(&client, proxy_arena.allocator(), &map);

    try std.testing.expect(client.http_proxy != null);
    try std.testing.expectEqualStrings("http.example", client.http_proxy.?.host.bytes);
    try std.testing.expect(client.https_proxy != null);
    try std.testing.expectEqualStrings("https.example", client.https_proxy.?.host.bytes);
    try std.testing.expect(!client.https_proxy.?.supports_connect);
}

test "proxy environment names fall back to all_proxy" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("all_proxy", "http://all.example:8080");

    var proxy_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer proxy_arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    initProxiesFromMap(&client, proxy_arena.allocator(), &map);

    try std.testing.expect(client.http_proxy != null);
    try std.testing.expectEqualStrings("all.example", client.http_proxy.?.host.bytes);
    try std.testing.expect(client.https_proxy != null);
    try std.testing.expectEqualStrings("all.example", client.https_proxy.?.host.bytes);
    try std.testing.expect(!client.https_proxy.?.supports_connect);
}
