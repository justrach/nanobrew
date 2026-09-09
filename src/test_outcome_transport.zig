const std = @import("std");
const paths = @import("platform/paths.zig");
const outcome = @import("trust/outcome.zig");
pub fn main(init: std.process.Init) !void {
    paths.safe_io = init.io;
    @import("net/proxy.zig").environment = init.environ_map;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const passed = args.len < 3;
    outcome.report(.{ .token = args[1], .kind = .formula, .version = "1", .platform = @import("trust/evidence.zig").platform(), .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", .installed = passed, .probe = if (passed) true else null });
    outcome.flush();
}
