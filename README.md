# nanobrew

The fastest macOS package manager. Written in Zig.

Inspired by [zerobrew](https://github.com/lucasgelfond/zerobrew) and [uv](https://github.com/astral-sh/uv) — proving that systems languages and smart caching can make package management feel instant.

## Benchmarks

See [BENCHMARKS.md](BENCHMARKS.md) for full methodology and results.

**Apple Silicon, single package (tree, 0 deps):**

|  | Homebrew | Zerobrew | nanobrew |
|---|---|---|---|
| **Cold** | 8.99s | 5.86s | **1.19s** |
| **Warm** | 2.25s | 0.35s | **0.19s** |

**Apple Silicon, multi-dep package (wget, 6 packages):**

|  | Homebrew | nanobrew |
|---|---|---|
| **Cold** | 16.84s | **11.26s** |
| **Warm** | 2.43s | **0.58s** |

nanobrew is **7.5x faster** than Homebrew and **5x faster** than Zerobrew on cold installs. Warm installs complete in under 200ms.

## Install

Requires [Zig 0.15+](https://ziglang.org/download/):

```bash
git clone https://github.com/justrach/nanobrew.git
cd nanobrew
zig build

# Create the directory tree
sudo mkdir -p /opt/nanobrew
sudo chown -R $(whoami) /opt/nanobrew
./zig-out/bin/nb init

# Add to your shell profile (.zshrc / .bashrc):
export PATH="/opt/nanobrew/prefix/bin:$PATH"
```

## Usage

```bash
nb install <formula> ...   # Install packages (with full dep resolution)
nb remove <formula> ...    # Uninstall packages
nb list                    # List installed packages
nb info <formula>          # Show formula info from Homebrew API
nb upgrade [formula]       # Upgrade packages
nb help                    # Show help
```

### Examples

```bash
nb install tree
nb install ripgrep wget curl
nb list
nb info jq
nb remove tree
```

## How it works

nanobrew uses Homebrew's bottle ecosystem (pre-built binaries) but replaces the entire Ruby toolchain with a single Zig binary.

```
nb install wget
  |
  v
1. Fetch formula metadata from formulae.brew.sh/api
  |
  v
2. Resolve transitive dependencies (Kahn's topological sort)
  |
  v
3. Download bottles from ghcr.io (with GHCR auth token)
     -> /opt/nanobrew/cache/blobs/<sha256>
  |
  v
4. Extract tarball into content-addressable store
     -> /opt/nanobrew/store/<sha256>/
  |
  v
5. Materialize into Cellar via APFS clonefile (COW)
     -> /opt/nanobrew/prefix/Cellar/<name>/<version>/
  |
  v
6. Symlink binaries into prefix/bin/
     -> /opt/nanobrew/prefix/bin/wget
  |
  v
7. Record in local JSON database
     -> /opt/nanobrew/db/state.json
```

### Why it's fast

- **Content-addressable store** — reinstalls are instant (skip download + extract, just clonefile)
- **APFS clonefile** — copy-on-write materialization, zero disk overhead
- **Arena allocators** — zero-malloc hot paths, no GC pressure
- **Single static binary** — no Ruby runtime, no interpreter startup, no config sprawl
- **SHA256 dedup** — bottles downloaded once, shared across versions

### Inspiration

- [zerobrew](https://github.com/lucasgelfond/zerobrew) — proved that a Rust rewrite of Homebrew's bottle pipeline could be 5-20x faster. nanobrew takes the same architecture (content-addressable store + APFS clonefile + parallel downloads) and pushes it further with Zig's comptime and zero-overhead abstractions.
- [uv](https://github.com/astral-sh/uv) — showed that rewriting a package manager in a systems language (Rust for pip) can deliver 10-100x speedups. Same philosophy here: the bottleneck in `brew install` isn't the network, it's the toolchain.

## Directory layout

```
/opt/nanobrew/
  cache/
    blobs/          # Downloaded bottles (content-addressable by SHA256)
    tmp/            # Partial downloads
  store/            # Extracted bottles (content-addressable by SHA256)
  prefix/
    Cellar/         # Installed kegs (cloned from store)
    bin/            # Symlinks to keg binaries
    opt/            # Symlinks to keg directories
  db/
    state.json      # Installed package state
  locks/            # (reserved for concurrent access)
```

## Architecture

```
src/
  main.zig              # CLI entry point and command dispatch
  root.zig              # Library root (re-exports all modules)
  api/
    client.zig          # Homebrew JSON API client (curl + std.json)
    formula.zig         # Formula struct and bottle tag constants
  resolve/
    deps.zig            # Dependency resolver (Kahn's topological sort)
  net/
    downloader.zig      # Bottle downloader with GHCR auth + SHA256 verify
  extract/
    tar.zig             # Tar/gzip extraction (v0: system tar, v1: mmap+SIMD)
  store/
    blob_cache.zig      # Blob cache path utilities
    store.zig           # Content-addressable store management
  cellar/
    cellar.zig          # APFS clonefile materialization
  linker/
    linker.zig          # Symlink creation for bin/ and opt/
  db/
    database.zig        # JSON-based install state tracking
  kernel/
    simd_scanner.zig    # Comptime SIMD byte/substring scanner
    mmap_reader.zig     # Zero-copy mmap file reader
  mem/
    arena.zig           # Thread-local arena allocator + ring buffer
  exec/
    thread_pool.zig     # Chase-Lev work-stealing thread pool
    dir_queue.zig       # Lock-free MPMC work queue
```

## License

MIT
