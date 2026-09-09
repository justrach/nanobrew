const std = @import("std");
const paths = @import("platform/paths.zig");
const autoupdate = @import("autoupdate.zig");
pub fn main(init: std.process.Init) !void {
    paths.safe_io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.process.exit(try autoupdate.run(init.gpa, args[1], .upgrade));
}
