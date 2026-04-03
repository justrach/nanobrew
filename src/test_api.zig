//! Test entry point for the API subsystem (client, formula, cask, tap, search).
comptime {
    _ = @import("api/client.zig");
    _ = @import("api/formula.zig");
    _ = @import("api/cask.zig");
    _ = @import("api/tap.zig");
}
