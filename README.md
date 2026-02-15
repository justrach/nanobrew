<p align="center">
  <img src="assets/logo.png" alt="nanobrew logo" width="200">
</p>

# nanobrew

The fastest macOS package manager. Written in Zig.

Inspired by [zerobrew](https://github.com/lucasgelfond/zerobrew) and [uv](https://github.com/astral-sh/uv) - proving that systems languages and smart caching can make package management feel instant.

nanobrew's warm installs complete in **under 4ms** - that's faster than `echo`.

## Performance snapshot

| Package | Homebrew | Zerobrew | nanobrew (cold) | nanobrew (warm) | Cold Speedup | Warm Speedup |
|---------|----------|----------|-----------------|-----------------|--------------|--------------|
| **ffmpeg** (11 deps) | ~24.5s | 36.2s | **22.4s** | **3.5ms** | 1.1x / 1.6x | **7000x / 86x** |
| **tree** (0 deps) | 8.99s | 5.86s | **1.19s** | **3.5ms** | 7.5x / 4.9x | **643x / 100x** |
| **wget** (6 deps) | 16.84s | - | **11.26s** | **3.5ms** | 1.5x | **4811x** |

> Cold speedups shown as vs Homebrew / vs Zerobrew. Warm speedups same format.
> All benchmarks on Apple Silicon (M-series), macOS 15, same network.

## Install

```bash
curl -fsSL https://nanobrew.trilok.ai/install | bash
```

Or with Homebrew:

```bash
brew tap justrach/nanobrew https://github.com/justrach/nanobrew
brew install nanobrew
```

Or build from source (requires [Zig 0.15+](https://ziglang.org/download/)):

```bash
git clone https://github.com/justrach/nanobrew.git
cd nanobrew
./install.sh
```

## Quick start

```bash
nb install jq                   # install one package
nb i ffmpeg wget curl           # short alias, multiple packages
nb install --cask firefox       # install macOS app (.dmg/.zip/.pkg)
nb remove jq                    # uninstall
nb remove --cask firefox        # uninstall macOS app
nb ui ffmpeg                    # short alias for uninstall
nb list                         # list installed packages and casks
nb info <formula>               # show formula info
nb help                         # show help
```

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
   Check Cellar for existing kegs - warm installs exit here (3.5ms)
  |
  v
3. Parallel download + extract (streaming)
   All bottles download concurrently via native HTTP (no curl)
   Streaming SHA256 verification during download (single pass)
   Each extracts immediately on completion
     -> /opt/nanobrew/store/<sha256>/
  |
  v
4. Parallel materialize + relocate
   APFS clonefile into Cellar (COW, zero disk cost)
   Native Mach-O header parsing (no otool subprocess)
   Batched codesign: single call for all modified binaries per keg
     -> /opt/nanobrew/prefix/Cellar/<name>/<version>/
  |
  v
5. Link + record
   Symlink binaries into prefix/bin/
   Record in local JSON database
     -> /opt/nanobrew/prefix/bin/ffmpeg
```

### Why it's fast

- **Skip-installed fast path** - already-installed packages detected in microseconds, warm installs complete in 3.5ms
- **Parallel everything** - downloads, extraction, materialization, relocation, and dependency resolution all run concurrently
- **Native HTTP downloads** - Zig's `std.http.Client` replaces curl subprocess spawns
- **Streaming SHA256** - hash verified during download in single pass, no re-read of file
- **Native Mach-O parsing** - reads load commands directly from binary headers, no otool
- **Content-addressable store** - SHA256-keyed dedup means reinstalls skip download + extract entirely
- **APFS clonefile** - copy-on-write materialization, zero disk overhead
- **Batched codesign** - one `codesign` call per keg (not per binary)
- **BFS parallel resolution** - dependency tree resolved in 2-3 parallel rounds instead of N serial API calls
- **API + GHCR token caching** - cached to disk with TTL, avoids redundant network calls
- **Single static binary** - no Ruby runtime, no interpreter startup, no config sprawl

### Inspiration

- [zerobrew](https://github.com/lucasgelfond/zerobrew) - proved that a Rust rewrite of Homebrew's bottle pipeline could be 2-20x faster. nanobrew takes the same architecture (content-addressable store + APFS clonefile + parallel downloads) and pushes it further with Zig's comptime and zero-overhead abstractions.
- [uv](https://github.com/astral-sh/uv) - showed that rewriting a package manager in a systems language (Rust for pip) can deliver 10-100x speedups. Same philosophy here: the bottleneck in `brew install` isn't the network, it's the toolchain.

## Relationship with Homebrew

nanobrew is a performance-optimized client for the Homebrew ecosystem. We rely on Homebrew's formula definitions, pre-built bottles (GHCR), cask definitions, and API infrastructure. nanobrew is experimental - we recommend running it alongside Homebrew rather than as a replacement. Source builds and post-install scripts are not yet supported.

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
    Caskroom/       # Installed casks (macOS apps)
    bin/            # Symlinks to keg binaries
    opt/            # Symlinks to keg directories
  db/
    state.json      # Installed package and cask state
```

## Architecture

```
src/
  main.zig              # CLI entry point, command dispatch, live progress UI
  api/
    client.zig          # Homebrew JSON API client (formula + cask)
    formula.zig         # Formula struct and bottle tag constants
    cask.zig            # Cask struct, Artifact types, DownloadFormat
  resolve/
    deps.zig            # BFS parallel dependency resolver (Kahn's topo sort)
  net/
    downloader.zig      # Native HTTP downloader with streaming SHA256
  extract/
    tar.zig             # Tar/gzip extraction
  store/
    store.zig           # Content-addressable store management
  cellar/
    cellar.zig          # APFS clonefile materialization
  cask/
    install.zig         # Cask install/remove pipeline (dmg/zip/pkg/tar.gz)
  linker/
    linker.zig          # Symlink creation for bin/ and opt/
  macho/
    relocate.zig        # Native Mach-O parsing + batched relocation
  db/
    database.zig        # JSON-based install state tracking
```

## Project status

- **Status:** Experimental, but already useful for many common Homebrew formulas.
- **Feedback:** If you hit incompatibilities, please open an issue or PR.
- **License:** [Apache 2.0](./LICENSE)

## Roadmap

- [x] Cask support (`nb install --cask <app>`) - install .app/.dmg/.pkg/.tar.gz bundles
- [ ] Source builds for formulae without bottles
- [ ] Post-install script execution
- [ ] `nb search` command
- [ ] `nb upgrade --all` with diff detection
