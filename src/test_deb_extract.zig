//! Heavy test: deb extraction with compression (flate, zstd).
//! Separated because compilation is slow (~2min). Run with: zig build test-deb-extract
comptime {
    _ = @import("deb/extract.zig");
}
