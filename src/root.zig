// nanobrew — A faster-than-zerobrew Homebrew replacement
//
// Built with:
//   1. Comptime SIMD byte scanning (tar header detection, JSON parsing)
//   2. mmap zero-copy file access (bottle extraction from page cache)
//   3. Arena allocators (zero-malloc hot paths)
//   4. Lock-free MPMC queues for parallel download+extract
//   5. Platform-specific COW copy (APFS clonefile / btrfs reflink)
//   6. Direct kqueue/epoll syscalls (no async runtime)
//
// Architecture:
//   1. Fetch formula metadata from Homebrew JSON API
//   2. Resolve transitive dependencies → topological sort
//   3. Parallel download bottles from CDN (racing connections)
//   4. Stream extract via mmap + gzip/tar into content-addressable store
//   5. COW copy from store into Cellar (clonefile on macOS, reflink on Linux)
//   6. Symlink binaries into prefix/bin/

pub const api_client = @import("api/client.zig");
pub const formula = @import("api/formula.zig");
pub const deps = @import("resolve/deps.zig");
pub const downloader = @import("net/downloader.zig");
pub const tar = @import("extract/tar.zig");
pub const blob_cache = @import("store/blob_cache.zig");
pub const store = @import("store/store.zig");
pub const cellar = @import("cellar/cellar.zig");
pub const linker = @import("linker/linker.zig");
pub const database = @import("db/database.zig");
pub const cask = @import("api/cask.zig");
pub const cask_installer = @import("cask/install.zig");
pub const source_builder = @import("build/source.zig");
pub const postinstall = @import("build/postinstall.zig");
pub const search_api = @import("api/search.zig");
pub const services = @import("services/services.zig");

// Platform abstraction layer
pub const platform = @import("platform/platform.zig");
pub const relocate = @import("platform/relocate.zig");

// Phase B: .deb package support (Linux)
pub const deb_index = @import("deb/index.zig");
pub const deb_resolver = @import("deb/resolver.zig");
pub const deb_extract = @import("deb/extract.zig");

// Reused from zigrep
pub const simd_scanner = @import("kernel/simd_scanner.zig");
pub const mmap_reader = @import("kernel/mmap_reader.zig");
pub const arena = @import("mem/arena.zig");
pub const thread_pool = @import("exec/thread_pool.zig");
