//! Test entry point for core modules (version, deps, database, store, kernel).
comptime {
    _ = @import("version.zig");
    _ = @import("resolve/deps.zig");
    _ = @import("db/database.zig");
    _ = @import("store/store.zig");
    _ = @import("store/blob_cache.zig");
    _ = @import("extract/tar.zig");
    _ = @import("kernel/simd_scanner.zig");
    _ = @import("kernel/mmap_reader.zig");
    _ = @import("mem/arena.zig");
    _ = @import("exec/thread_pool.zig");
}
