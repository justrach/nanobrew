# Benchmarks

All benchmarks run on Apple Silicon (M-series), macOS, with a stable internet connection.

**Tools compared:**
- [Homebrew](https://brew.sh/) (Ruby) — the standard macOS package manager
- [Zerobrew](https://github.com/lucasgelfond/zerobrew) v0.1.0 (Rust) — a 5-20x faster Homebrew alternative
- **nanobrew** (Zig) — this project

## Results

### Single package, no dependencies (`tree`)

| | Homebrew | Zerobrew | nanobrew | Speedup vs brew |
|---|---|---|---|---|
| **Cold install** | 8.99s | 5.86s | **1.19s** | **7.6x** |
| **Warm install** | 2.25s | 0.35s | **0.19s** | **11.8x** |

### Multi-dep package (`wget` — 6 packages total)

wget depends on: libunistring, ca-certificates, gettext, openssl@3, libidn2

| | Homebrew | Zerobrew | nanobrew | Speedup vs brew |
|---|---|---|---|---|
| **Cold install** | 16.84s | failed* | **11.26s** | **1.5x** |
| **Warm install** | 2.43s | failed* | **0.58s** | **4.2x** |

*Zerobrew failed on wget with: `zerobrew prefix "/opt/zerobrew/prefix" (20 bytes) is longer than "/opt/homebrew" (13 bytes)` — a Mach-O binary patching limitation.

## Definitions

- **Cold install**: No local cache. Bottles must be downloaded from ghcr.io, extracted, and installed from scratch.
- **Warm install**: Bottles already downloaded and extracted in the content-addressable store. Only materialization (APFS clonefile) and linking required.

## Where the time goes

### Homebrew (`brew install tree`, cold)

```
Total: 8.99s
  - Ruby startup + config loading:   ~1.5s
  - API metadata fetch:              ~0.5s
  - Bottle download:                 ~1.5s
  - Extraction + pour:               ~1.0s
  - Linking + cleanup:               ~4.5s
```

Homebrew spends most of its time in Ruby overhead — loading configs, running cleanup hooks, and post-install checks.

### nanobrew (`nb install tree`, cold)

```
Total: 1.19s
  - API metadata fetch (curl):       ~0.3s
  - GHCR token + bottle download:    ~0.7s
  - Extraction (tar):                ~0.1s
  - Materialize (clonefile):         ~0.05s
  - Link + DB write:                 ~0.04s
```

nanobrew has near-zero overhead. No interpreter startup, no cleanup passes, no config loading.

### nanobrew (`nb install tree`, warm)

```
Total: 0.19s
  - API metadata fetch (curl):       ~0.15s
  - Download skip (blob cached):     ~0s
  - Extraction skip (store cached):  ~0s
  - Materialize (clonefile):         ~0.03s
  - Link + DB write:                 ~0.01s
```

Warm installs are dominated by the API fetch. The actual install is ~40ms.

## Methodology

Each benchmark was run with:

1. Full cleanup between cold runs (remove cached bottles, store entries, installed kegs)
2. For warm runs, kegs removed but caches preserved
3. `time` used for wall-clock measurement
4. Single run per data point (not averaged — these are representative, not statistical)

### Reproducing

```bash
# Cold install benchmark
brew uninstall tree 2>/dev/null
rm -rf /opt/nanobrew/store/* /opt/nanobrew/cache/blobs/*
time nb install tree

# Warm install benchmark
nb remove tree
time nb install tree

# Compare with Homebrew
brew uninstall tree 2>/dev/null
time brew install tree
```

## Known limitations

- **Multi-dep cold installs** are slower relative to Homebrew than single-package installs because nanobrew downloads bottles sequentially (parallel downloads not yet wired up — the thread pool infrastructure exists but isn't integrated).
- **Mach-O patching** is not implemented. Bottles with hardcoded `/opt/homebrew` library paths won't work at runtime. This affects packages with dynamic library dependencies (e.g., wget, ffmpeg) but not standalone binaries (e.g., tree, ripgrep).

## Future improvements

- Wire up the existing thread pool for parallel bottle downloads (should cut multi-dep cold installs by 3-5x)
- Replace `curl` shell-outs with native HTTP client
- Replace `tar` shell-out with mmap + SIMD extraction
- Add Mach-O binary patching for library path fixups
