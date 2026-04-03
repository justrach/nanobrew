//! Lightweight path safety checks — no heavy dependencies.
//! Used by deb/extract.zig and security_test.zig.
const std = @import("std");

pub fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}
