# nanobrew

The fastest macOS package manager. Written in Zig.

Inspired by [zerobrew](https://github.com/lucasgelfond/zerobrew) and [uv](https://github.com/astral-sh/uv) — proving that systems languages and smart caching can make package management feel instant.

## Performance snapshot

| Package | Homebrew | Zerobrew | nanobrew (cold) | nanobrew (warm) | Cold Speedup | Warm Speedup |
|---------|----------|----------|-----------------|-----------------|--------------|--------------|
| **ffmpeg** (11 deps) | ~24.5s | 36.2s | **22.4s** | **3.5ms** | 1.1x / 1.6x | **7000x / 86x** |
| **tree** (0 deps) | 8.99s | 5.86s | **1.19s** | **3.5ms** | 7.5x / 4.9x | **643x / 100x** |
| **wget** (6 deps) | 16.84s | — | **11.26s** | **3.5ms** | 1.5x | **4811x** |

> Cold speedups shown as vs Homebrew / vs Zerobrew. Warm speedups same format.
> All benchmarks on Apple Silicon (M-series), macOS 15, same network.

nanobrew's warm installs complete in **under 4ms** — that's faster than `echo`.

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

## Quick start

```bash
nb install jq                   # install one package
nb install ffmpeg wget curl     # install multiple (parallel deps)
nb remove jq                    # uninstall
nb list                         # list installed packages
nb info <formula>               # show formula info
nb help                         # show help
```

## Relationship with Homebrew

nanobrew is a performance-optimized client for the Homebrew ecosystem. We rely on:

- Homebrew's formula definitions (homebrew-core)
- Homebrew's pre-built bottles (hosted on GHCR)
- Homebrew's package metadata and API infrastructure

Our innovations focus on:

- **Parallel pipeline** — concurrent downloads, extraction, and relocation
- **Content-addressable storage** for deduplication (reinstalls skip everything)
- **APFS clonefiles** for zero-overhead copying
- **BFS parallel dependency resolution** — fetch all deps per level concurrently
- **Batched Mach-O relocation** — single `otool` + single `install_name_tool` per binary
- **Built-in SHA256** — no process spawns for verification
- **API + token caching** — avoid redundant network calls

nanobrew is experimental. We recommend running it alongside Homebrew rather than as a replacement. Homebrew formulas that require source builds, cask installs, or post-install scripts are not yet supported.

## How it works

```
nb install ffmpeg
  |
  v
1. BFS parallel dependency resolution
   Fetch formula metadata from formulae.brew.sh/api
   Each BFS level fetches all deps concurrently
  |
  v
2. Skip already-installed packages
   Check Cellar for existing kegs — warm installs exit here (3.5ms)
  |
  v
3. Parallel download + extract (streaming)
   All bottles download concurrently via GHCR
   Each extracts immediately on completion
   Built-in SHA256 verification (no shasum process)
     -> /opt/nanobrew/store/<sha256>/
  |
  v
4. Parallel materialize + relocate
   APFS clonefile into Cellar (COW, zero disk cost)
   Batch Mach-O relocation: single otool + install_name_tool per binary
   Ad-hoc codesign for macOS enforcement
     -> /opt/nanobrew/prefix/Cellar/<name>/<version>/
  |
  v
5. Link + record
   Symlink binaries into prefix/bin/
   Record in local JSON database
     -> /opt/nanobrew/prefix/bin/ffmpeg
```

### Why it's fast

- **Skip-installed fast path** — already-installed packages detected in microseconds, warm installs complete in 3.5ms
- **Parallel everything** — downloads, extraction, materialization, relocation, and dependency resolution all run concurrently
- **Content-addressable store** — SHA256-keyed dedup means reinstalls skip download + extract entirely
- **APFS clonefile** — copy-on-write materialization, zero disk overhead
- **Batched process spawns** — one `otool -l` + one `install_name_tool` per binary (not 5+ calls)
- **Built-in SHA256** — Zig's `std.crypto.hash.sha2` instead of spawning `shasum`
- **BFS parallel resolution** — dependency tree resolved in 2-3 parallel rounds instead of N serial API calls
- **API + GHCR token caching** — cached to disk with TTL, avoids redundant network calls
- **Single static binary** — no Ruby runtime, no interpreter startup, no config sprawl

### Inspiration

- [zerobrew](https://github.com/lucasgelfond/zerobrew) — proved that a Rust rewrite of Homebrew's bottle pipeline could be 2-20x faster. nanobrew takes the same architecture (content-addressable store + APFS clonefile + parallel downloads) and pushes it further with Zig's comptime and zero-overhead abstractions.
- [uv](https://github.com/astral-sh/uv) — showed that rewriting a package manager in a systems language (Rust for pip) can deliver 10-100x speedups. Same philosophy here: the bottleneck in `brew install` isn't the network, it's the toolchain.

## Directory layout

```
/opt/nanobrew/
  cache/
    blobs/          # Downloaded bottles (content-addressable by SHA256)
    api/            # Cached formula metadata (5-min TTL)
    tokens/         # Cached GHCR auth tokens (4-min TTL)
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
    deps.zig            # BFS parallel dependency resolver (Kahn's topo sort)
  net/
    downloader.zig      # Parallel bottle downloader with GHCR auth + SHA256
  extract/
    tar.zig             # Tar/gzip extraction
  store/
    blob_cache.zig      # Blob cache path utilities
    store.zig           # Content-addressable store management
  cellar/
    cellar.zig          # APFS clonefile materialization
  linker/
    linker.zig          # Symlink creation for bin/ and opt/
  macho/
    relocate.zig        # Mach-O binary relocation (batched)
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

## Project status

- **Status:** Experimental, but already useful for many common Homebrew formulas.
- **Feedback:** If you hit incompatibilities, please open an issue or PR.
- **License:** [MIT](./LICENSE)
