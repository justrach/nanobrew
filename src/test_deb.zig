//! Test entry point for the .deb subsystem (index, resolver, distro).
//! Note: deb/extract.zig is excluded from default tests because it pulls in
//! heavy compression code (flate, zstd). Run it explicitly with: zig build test-deb-extract
comptime {
    _ = @import("deb/index.zig");
    _ = @import("deb/resolver.zig");
    _ = @import("deb/distro.zig");
}
