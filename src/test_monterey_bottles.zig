const std = @import("std");
test {
    std.testing.refAllDecls(@import("api/formula.zig"));
    std.testing.refAllDecls(@import("api/ghcr.zig"));
}
