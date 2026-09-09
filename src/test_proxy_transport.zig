// Integration harness used by scripts/test_proxy_transport.py.
const std = @import("std");
const proxy = @import("net/proxy.zig");
const fetch = @import("net/fetch.zig");
const paths = @import("platform/paths.zig");
pub fn main(init: std.process.Init) !void {
    paths.safe_io = init.io;
    proxy.environment = init.environ_map;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (std.mem.eql(u8, args[1], "get")) {
        const body = try fetch.getWithHeaders(a, args[2], &.{.{ .name = "Authorization", .value = "Bearer origin-only" }});
        try std.Io.File.stdout().writeStreamingAll(init.io, body);
    } else if (std.mem.eql(u8, args[1], "post")) {
        const body = try proxy.request(a, args[2], null, &.{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }}, "accepted=yes");
        try std.Io.File.stdout().writeStreamingAll(init.io, body);
    } else {
        try proxy.download(a, args[2], args[3], args[4], &.{}, null);
    }
    std.process.exit(0);
}
