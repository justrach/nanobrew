# nanobrew — Agent Handoff Document

A faster-than-zerobrew Homebrew replacement, written in Zig 0.15.

**Binary**: `nb` — built via `zig build`, output at `zig-out/bin/nb`
**Target**: macOS arm64, bottles-only (pre-built binaries from Homebrew CDN)
**Install prefix**: `/opt/nanobrew/` (requires `sudo mkdir -p /opt/nanobrew && sudo chown -R $(whoami) /opt/nanobrew` first)

## Current State (v0 — working)

The binary compiles and runs. `nb help` and `nb info <formula>` work end-to-end (fetches live data from Homebrew API). The full install pipeline (resolve → download → extract → materialize → link → record) is wired up but **has not been tested end-to-end yet** because `/opt/nanobrew/` requires root to create.

### What works
- `nb help` — prints usage
- `nb info <formula>` — fetches formula metadata from Homebrew JSON API, shows version + deps
- Full 6-phase install pipeline is wired (resolve deps → download bottles → extract → cellar materialize → link bins → record in DB)
- Dependency resolution with Kahn's topological sort
- SHA256 verification on downloads
- JSON state database at `/opt/nanobrew/db/state.json`

### What hasn't been tested
- `nb install <formula>` — the full pipeline end-to-end (blocked on creating `/opt/nanobrew/`)
- `nb remove <formula>`
- `nb list`

## Architecture

```
nb (CLI)
 │
 ├── src/main.zig              CLI entry point, command dispatch, 6-phase install pipeline
 │
 ├── src/api/
 │   ├── client.zig            Homebrew JSON API client (curl + std.json.parseFromSlice)
 │   └── formula.zig           Formula struct, bottle tag resolution (arm64_sonoma + fallbacks)
 │
 ├── src/resolve/
 │   └── deps.zig              Recursive dep fetcher + Kahn's topological sort
 │
 ├── src/net/
 │   └── downloader.zig        Parallel bottle downloader (curl, SHA256 verify, atomic writes)
 │
 ├── src/extract/
 │   └── tar.zig               v0: shells out to `tar xzf`. v1: mmap + flate.Decompress
 │
 ├── src/store/
 │   ├── blob_cache.zig        Content-addressable blob cache at cache/blobs/<sha256>
 │   └── store.zig             Extracted store at store/<sha256>/ (deduped)
 │
 ├── src/cellar/
 │   └── cellar.zig            APFS clonefile materialization → prefix/Cellar/<name>/<ver>/
 │
 ├── src/linker/
 │   └── linker.zig            Symlinks bin/sbin into prefix/bin/, creates opt/ symlinks
 │
 ├── src/db/
 │   └── database.zig          JSON state file (installed kegs list)
 │
 ├── src/exec/
 │   ├── dir_queue.zig         Lock-free MPMC queue (from zigrep)
 │   └── thread_pool.zig       Chase-Lev work-stealing thread pool (from zigrep)
 │
 ├── src/kernel/
 │   ├── simd_scanner.zig      Comptime SIMD byte scanner — @Vector(N, u8) (from zigrep)
 │   └── mmap_reader.zig       Zero-copy mmap file access (from zigrep)
 │
 ├── src/mem/
 │   └── arena.zig             ScratchArena bump allocator + RingBuffer (from zigrep)
 │
 ├── src/root.zig              Module re-exports (nanobrew library)
 └── build.zig                 Build system — `nb` exe + nanobrew library module
```

### Install Pipeline (6 phases in main.zig:runInstall)

```
1. RESOLVE    — DepResolver.resolve() fetches formula JSON for target + all transitive deps
               → topologicalSort() produces install order (leaves first)

2. DOWNLOAD   — ParallelDownloader.enqueue() checks blob cache, skips if cached
               → downloadAll() curls each bottle to cache/tmp/<sha>.partial
               → SHA256 verify → atomic rename to cache/blobs/<sha>

3. EXTRACT    — store.ensureEntry() calls tar.extractToStore()
               → v0: `tar xzf <blob> -C store/<sha>/`
               → result: store/<sha256>/ contains unpacked keg

4. MATERIALIZE — cellar.materialize() copies from store → prefix/Cellar/<name>/<ver>/
               → tries APFS clonefile (CoW, zero-cost), falls back to symlink then copy

5. LINK       — linker.linkKeg() symlinks keg/bin/* → prefix/bin/*, creates prefix/opt/<name>

6. RECORD     — database.recordInstall() writes to db/state.json
```

### Directory Layout

```
/opt/nanobrew/
├── cache/
│   ├── blobs/<sha256>         Downloaded bottle tarballs (content-addressed)
│   └── tmp/<sha256>.partial   In-progress downloads
├── store/<sha256>/            Extracted bottle contents (deduplicated)
├── prefix/
│   ├── Cellar/<name>/<ver>/   Materialized kegs (APFS clone from store)
│   ├── bin/                   Symlinks to keg binaries
│   └── opt/<name>             Symlinks to active keg versions
├── db/state.json              Installed packages database
└── locks/                     (reserved for future file locking)
```

## Zig 0.15 Gotchas (critical for the next agent)

These bit us hard during initial development. Zig 0.15 changed a lot from 0.13/0.14:

1. **stdout/stderr**: `std.io.getStdOut()` is gone. Use `std.fs.File.stdout().deprecatedWriter()`
2. **ArrayList is unmanaged**: `std.ArrayList(T).init(alloc)` doesn't exist. Use `var list: std.ArrayList(T) = .empty;` and pass allocator per-call: `.append(alloc, item)`, `.deinit(alloc)`, `.toOwnedSlice(alloc)`
3. **StringHashMap is still managed**: `std.StringHashMap(T).init(alloc)` still works normally
4. **std.http.Client**: The `.open()` method is removed. We shell out to curl instead
5. **std.compress.gzip**: Doesn't exist. Only `std.compress.flate` with `.gzip` Container enum
6. **symLinkAbsolute**: Takes 3 args now: `(target, path, .{})` — the third is `Dir.SymLinkFlags`
7. **readLinkAbsolute**: Buffer must be `*[std.fs.max_path_bytes]u8`, not a fixed `*[2048]u8`
8. **Capture patterns**: `|*dir|` from if-captures gives const pointer. Use `|d| var dir = d;` instead
9. **Function returns**: Functions that `print` via deprecatedWriter should return `void` not `!void`, and use `catch {}` on each print call

## What to Build Next (priority order)

### P0 — Make it actually work end-to-end
1. **Make root path configurable**: Currently hardcoded to `/opt/nanobrew/` everywhere. Either:
   - Support `NANOBREW_ROOT` env var, OR
   - Fall back to `~/.nanobrew` when `/opt/nanobrew` isn't writable
   - All modules (downloader, tar, blob_cache, store, cellar, linker, database) hardcode paths — they all need updating
2. **Test `nb install tree`** (or `jq` — something small with no/few deps) end-to-end
3. **Fix Homebrew bottle nesting**: Bottles extract as `<name>/<version>/` inside the tar. The cellar/linker may need to walk into this nested structure to find the actual `bin/` directory

### P1 — Performance (beat zerobrew)
4. **Native HTTP client**: Replace curl subprocess with Zig's `std.http.Client` (once API stabilizes) or raw TLS + HTTP/2 with connection pooling
5. **Parallel downloads**: Use the thread_pool + WorkQueue to download multiple bottles concurrently (currently sequential)
6. **mmap tar extraction**: Replace `tar xzf` shell-out with mmap + `std.compress.flate.Decompress` (.gzip container) + streaming tar parser using simd_scanner for header detection
7. **Parallel extract + materialize**: Pipeline phases 2-4 concurrently using the MPMC queue

### P2 — Features
8. **`nb upgrade`**: Compare installed versions against API, reinstall if newer
9. **`nb search`**: Search formulae (use the Homebrew search API or local formula cache)
10. **Lock files**: Use `/opt/nanobrew/locks/` for concurrent install protection
11. **Rollback**: Keep previous version in store, allow `nb rollback <formula>`
12. **Formula cache**: Comptime-embedded popular formulae metadata (avoid API call for common packages)

### P3 — Polish
13. **Progress bars**: Show download progress (curl has `--progress-bar`)
14. **Colored output**: ANSI escape codes for status messages
15. **Shell completions**: Generate bash/zsh/fish completions
16. **`nb doctor`**: Diagnose broken symlinks, orphaned store entries, etc.

## Modules Reused from zigrep

These 4 files were copied from `~/pgp/zigrep/` and should be kept in sync:

- `src/kernel/simd_scanner.zig` — SIMD byte scanning (findFirst, countByte, findSubstring, findLineStarts)
- `src/kernel/mmap_reader.zig` — MappedFile (mmap + madvise) and StreamReader
- `src/mem/arena.zig` — ScratchArena bump allocator + RingBuffer
- `src/exec/thread_pool.zig` — Chase-Lev work-stealing thread pool + TaskGroup

These are currently imported via root.zig but **not yet used by nanobrew's hot paths**. They're wired up for the v1 mmap+SIMD tar extraction and parallel download phases.

## Key Design Decisions

- **Bottles only**: No source compilation. Homebrew already builds bottles for arm64 — we just fetch and install them
- **Content-addressable store**: Same SHA256 = same content. Deduplication is free
- **APFS clonefile**: macOS copy-on-write means materializing from store to Cellar is nearly instant and uses zero extra disk space
- **JSON database**: Simple `state.json` file instead of SQLite (zerobrew uses SQLite). Good enough for v0, can upgrade later
- **curl for HTTP**: Zig 0.15's HTTP client API is still in flux. curl is battle-tested and handles redirects/TLS/HTTP2 out of the box. Replace with native Zig HTTP once the API stabilizes

## Build & Run

```bash
cd ~/nanobrew
zig build                           # builds zig-out/bin/nb
./zig-out/bin/nb help               # print usage
./zig-out/bin/nb info ripgrep       # fetch formula info (works now)

# First time setup (needs sudo once):
sudo mkdir -p /opt/nanobrew && sudo chown -R $(whoami) /opt/nanobrew
./zig-out/bin/nb init               # creates directory tree

# Then install:
./zig-out/bin/nb install tree       # full pipeline (untested as of this handoff)
```

## Reference Projects

- **zerobrew** (`lucasgelfond/zerobrew`): The project we're trying to beat. 5-phase streaming pipeline, SQLite DB, ParallelDownloader with HTTP/2 racing, APFS clonefile. Use DeepWiki to query its architecture
- **zigrep** (`~/pgp/zigrep`): Our sibling project — source of the SIMD scanner, mmap reader, arena allocator, and thread pool. Use the zigrep binary at `~/pgp/zigrep/zig-out/bin/zigrep` for searching files on this system
- **Homebrew JSON API**: `https://formulae.brew.sh/api/formula/<name>.json` — the data source for all formula metadata
