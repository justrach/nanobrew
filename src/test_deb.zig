//! Test entry point for the .deb subsystem (index, resolver, extract, distro).
comptime {
    _ = @import("deb/index.zig");
    _ = @import("deb/resolver.zig");
    _ = @import("deb/extract.zig");
    _ = @import("deb/distro.zig");
}
