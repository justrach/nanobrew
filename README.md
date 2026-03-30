<p align="center">
  <img src="assets/logo.png" alt="nanobrew logo" width="200">
</p>

# nanobrew

A fast package manager for macOS and Linux. Written in Zig. Uses Homebrew's bottles and formulas under the hood, plus native .deb support for Docker containers.

## Why nanobrew?

- **Fast warm installs** — packages already in the local store reinstall in ~3.5ms
- **Parallel downloads** — all dependencies download and extract at the same time
- **No Ruby runtime** — single static binary, instant startup
- **No auto-update** — `nb install` just installs; self-update is explicit via `nb update`
- **No quarantine** — cask installs skip `com.apple.quarantine`, so apps open without Gatekeeper prompts
- **Third-party taps** — `nb install user/tap/formula` just works. The only fast Homebrew client with tap support
- **Drop-in Homebrew replacement** — same formulas, same bottles, same casks
- **Linux + Docker** — native .deb support, **up to 13x faster** than apt-get on warm installs

## nanobrew vs Homebrew

Homebrew is great software and powers millions of dev machines. nanobrew makes different tradeoffs:

| | Homebrew | nanobrew |
|---|---------|----------|
| **Auto-update** | `brew install` runs `brew update` first (can take minutes) | `nb install` just installs. Self-update is explicit via `nb update`. |
| **Gatekeeper quarantine** | Casks get `com.apple.quarantine` — triggers "Are you sure?" dialog | No quarantine flag — apps open immediately |
| **Parallel downloads** | Sequential by default; set `HOMEBREW_DOWNLOAD_CONCURRENCY` to change | All dependencies download simultaneously out of the box |
| **Runtime** | Ruby (~57 MB) | Single 1.2 MB static binary. Instant startup, no bootstrapping. |
| **Brewfile no-ops** | `brew bundle` rechecks everything (~10s even when satisfied) | `nb bundle install` returns instantly when nothing to do |

If you rely on `post_install` hooks, build-from-source options, or Mac App Store integration, Homebrew is still the right choice. nanobrew covers the fast path: bottles, casks, and bundles.

| Package | Homebrew | zerobrew (cold) | zerobrew (warm) | nanobrew (cold) | nanobrew (warm) |
|---------|----------|-----------------|-----------------|-----------------|-----------------|
| **tree** (0 deps) | 4.070s | 1.254s | 0.242s | **0.507s** | **0.009s** |
| **ffmpeg** (11 deps) | 14.252s | 3.986s | 2.147s | **1.624s** | **0.287s** |
| **wget** (6 deps) | 3.935s | 5.502s | 0.587s | **3.211s** | **0.027s** | 3.801s | 7.911s | 0.825s | **3.822s** | **0.043s** | 4.184s | 6.080s | 0.572s | **3.484s** | **0.024s** | 4.329s | 6.427s | 0.493s | **2.329s** | **0.023s** | 5.672s | 8.485s | 0.755s | **4.356s** | **0.043s** | 5.849s | 9.364s | 1.056s | **3.090s** | **0.033s** |

> Benchmarks on Apple Silicon (GitHub Actions macos-14), 2026-03-23. Auto-updated weekly.

| | nanobrew | zerobrew | Homebrew |
|---|---------|----------|----------|
| **Binary size** | **1.2 MB** | 7.9 MB | 57 MB (Ruby runtime) |

> nanobrew is **6.8x smaller** than zerobrew and **47x smaller** than Homebrew. See how these are measured in the [benchmark workflow](.github/workflows/benchmark.yml).

### Linux / Docker — nanobrew vs apt-get

nanobrew's `--deb` mode is a full apt-get replacement: fetches APT package indices, resolves dependencies, downloads and extracts `.deb` files — all in pure Zig with no subprocess calls.

| Package set | Deps | apt-get | nanobrew (warm) | Speedup |
|-------------|------|---------|-----------------|---------|
| **curl wget** | 35 | 3,426ms | **448ms** | **7.6x** |
| **curl wget tree jq htop tmux** | 53 | 3,584ms | **521ms** | **6.9x** |
| **git vim build-essential** | 116 | 43,833ms | **3,402ms** | **12.9x** |
| **nginx redis-server postgresql-client** | 78 | 5,501ms | **1,402ms** | **3.9x** |

> Verified benchmarks on Ubuntu 24.04.4 LTS (aarch64, Docker/Colima), median of 3 runs. Warm = NBIX binary index cache + cached .deb blobs, `--skip-postinst`. See `bench/` for reproduction.

**What makes it fast:**
- **NBIX binary index cache** — 70K packages deserialized in 32ms (vs 3s HTTP + 72MB gzip decompress + text parse)
- **8-thread parallel .deb downloads** with HTTP connection reuse
- **8-thread parallel extraction** — concurrent ar/gzip/tar parsing via native Zig tar
- **Arena allocator** — single `deinit()` frees all 70K parsed packages

## Install

```bash
# One-liner
curl -fsSL https://nanobrew.trilok.ai/install | bash

# Or via Homebrew
brew tap justrach/nanobrew https://github.com/justrach/nanobrew
brew install nanobrew

# Or build from source (needs Zig 0.15+)
git clone https://github.com/justrach/nanobrew.git
cd nanobrew && ./install.sh
```

## Usage

### Basics

```bash
nb install tree               # install a package
nb install ffmpeg wget curl   # install multiple at once
nb remove tree                # uninstall
nb list                       # see what's installed
nb info jq                    # show package details
nb search ripgrep             # search formulas and casks
```

### Third-Party Taps

```bash
nb install steipete/tap/sag   # install from a third-party tap
nb install indirect/tap/bpb   # taps with bottles work too
```

nanobrew fetches the Ruby formula directly from GitHub, parses it, and installs — no `brew tap` step needed. Supports bottles, source builds, and pre-built binaries.

### macOS Apps (Casks)

```bash
nb install --cask firefox     # install a .dmg/.pkg/.zip app
nb remove --cask firefox      # uninstall it
nb upgrade --cask             # upgrade all casks
```

### Linux / Docker (deb packages)

```bash
nb install --deb curl wget git    # install from Ubuntu/Debian repos (2.8x faster than apt-get)
nb remove --deb curl              # remove a deb package
nb upgrade --deb                  # upgrade all installed deb packages
nb list                           # shows deb packages alongside brew packages
nb outdated                       # checks deb packages for newer versions too
```

```dockerfile
# Replace slow apt-get in Dockerfiles
COPY --from=nanobrew/nb /nb /usr/local/bin/nb
RUN nb init && nb install --deb curl wget git
```

- Auto-detects distro and architecture (Ubuntu/Debian, amd64/arm64)
- Resolves virtual packages via `Provides:` field (e.g. `build-essential` works)
- Picks the best alternative when multiple packages satisfy a dependency
- Runs `postinst` scripts and `ldconfig` so shared libraries work out of the box
- Tracks installed files in `state.json` for clean removal
- Content-addressable cache — warm installs are instant
### Keep packages up to date

```bash
nb outdated                   # see what's behind
nb upgrade                    # upgrade everything
nb upgrade tree               # upgrade one package
nb pin tree                   # prevent a package from upgrading
nb unpin tree                 # allow upgrades again
```

### Undo and backup

```bash
nb rollback tree              # revert to the previous version
nb bundle dump                # export installed packages to a Nanobrew file
nb bundle install             # reinstall everything from a Nanobrew file
```

### Diagnostics

```bash
nb doctor                     # check for common problems
nb cleanup                    # remove old caches and orphaned files
nb cleanup --dry-run          # see what would be removed first
```

### Dependencies and services

```bash
nb deps ffmpeg                # list all dependencies
nb deps --tree ffmpeg         # show dependency tree
nb services list              # show launchctl services from installed packages
nb services start postgresql  # start a service
nb services stop postgresql   # stop a service
```

### Shell completions

```bash
nb completions zsh >> ~/.zshrc
nb completions bash >> ~/.bashrc
nb completions fish > ~/.config/fish/completions/nb.fish
```

### Other

```bash
nb update                     # self-update nanobrew
nb init                       # create directory structure (run once)
nb help                       # show all commands
```

## How it works

```
nb install ffmpeg                        # macOS: Homebrew bottles
  │
  ├─ 1. Resolve dependencies (BFS, parallel API calls)
  ├─ 2. Skip anything already installed (warm path: ~3.5ms)
  ├─ 3. Download bottles in parallel (native HTTP, streaming SHA256)
  ├─ 4. Extract into content-addressable store (/opt/nanobrew/store/<sha>)
  ├─ 5. Clone into Cellar via APFS clonefile (zero-copy, instant)
  ├─ 6. Relocate Mach-O headers + batch codesign
  └─ 7. Symlink binaries into /opt/nanobrew/prefix/bin/

nb install --deb curl                    # Linux: .deb packages
  │
  ├─ 1. Detect distro from /etc/os-release (Ubuntu/Debian, amd64/arm64)
  ├─ 2. Fetch + decompress package index (main + universe components)
  ├─ 3. Build provides map for virtual package resolution
  ├─ 4. Resolve dependencies (topological sort, index-aware alternatives)
  ├─ 5. Download .debs with streaming SHA256 verification
  ├─ 6. Parse ar archive, decompress data.tar natively (zstd/gzip)
  ├─ 7. Extract to / and track installed files in state.json
  ├─ 8. Run postinst scripts (ca-certificates, ldconfig, etc.)
  └─ 9. Run ldconfig for shared library registration

nb install steipete/tap/sag              # Third-party taps
  │
  ├─ 1. Detect tap syntax (user/tap/formula)
  ├─ 2. Fetch Ruby formula from GitHub (raw.githubusercontent.com)
  ├─ 3. Parse .rb file (version, url, sha256, deps, bottle blocks)
  ├─ 4. Resolve dependencies normally (they're homebrew-core names)
  └─ 5. Install via bottle or source path (same pipeline as above)
```

Key design choices:
- **Content-addressable store** — deduplicates bottles by SHA256. Reinstalls are instant because the data is already there.
- **APFS clonefile** — copy-on-write on macOS means no extra disk space when materializing from the store.
- **Streaming SHA256** — hash is verified during download, no second pass over the file.
- **Native binary parsing** — reads Mach-O (macOS) and ELF (Linux) headers directly instead of spawning `otool`/`patchelf`.
- **Native ar + decompression** — .deb extraction without `dpkg`, `ar`, or `zstd` binaries. Only needs `tar`.
- **Single static binary** — no runtime dependencies. 1.2 MB.

## Testing

```bash
# Run all tests (macOS — native)
zig build test

# Run individual module tests with verbose output
zig test src/deb/index.zig         # 7 tests: package parsing, provides map
zig test src/deb/resolver.zig      # 17 tests: dependency resolution, virtual packages

# Cross-compile and run on Linux via Colima/Docker
zig build test -Dtarget=aarch64-linux   # cross-compile to static ELF
docker run --rm -v .zig-cache/o/<hash>/test:/test alpine /test

# Or as a one-liner (find the binary automatically)
docker run --rm -v "$(find .zig-cache -name test -newer build.zig | head -1):/t:ro" alpine /t
```

Zig's cross-compilation produces a statically-linked binary that runs directly in any Linux container — no need to install Zig or any toolchain inside Docker.


## Directory layout

```
/opt/nanobrew/
  cache/
    blobs/      # downloaded bottles (by SHA256)
    api/        # cached formula metadata (5-min TTL)
    tokens/     # GHCR auth tokens (4-min TTL)
    tmp/        # partial downloads
  store/        # extracted bottles (by SHA256)
  prefix/
    Cellar/     # installed packages
    Caskroom/   # installed casks
    bin/        # symlinks to binaries
    opt/        # symlinks to keg dirs
  db/
    state.json  # installed package state
```

## Homebrew Compatibility

nanobrew uses Homebrew's formulas, bottles, and cask definitions. It's a faster client for the same ecosystem — not a fork.

### What works

- **Bottle installs** — all pre-built Homebrew bottles install correctly
- **Cask installs** — `.dmg`, `.zip`, `.pkg`, and `.tar.gz` casks
- **Dependency resolution** — same transitive deps as Homebrew
- **Third-party taps** — `nb install user/tap/formula` fetches from GitHub
- **Shared Cellar** — packages install to `/opt/nanobrew/prefix/Cellar/` (same layout as Homebrew)
- **Bundle/Brewfile** — `nb bundle dump` and `nb bundle install` for common `brew "pkg"` and `cask "pkg"` lines

### What doesn't work (yet)

- **Ruby `post_install` hooks** — Homebrew formulae with Ruby `post_install` blocks won't run those hooks. Most bottles don't need them.
- **Build from source with custom options** — `args: ["with-feature"]` in Brewfiles is ignored
- **`tap` command** — nanobrew auto-fetches taps inline; standalone `brew tap` is not needed
- **Mac App Store (`mas`)** — not supported
- **Complex Ruby DSL in Brewfiles** — conditional blocks, custom Ruby code

### Migration from Homebrew

```bash
nb migrate    # scan /opt/homebrew/Cellar and Caskroom, import into nanobrew's DB
```

After migration, `nb list`, `nb outdated`, and `nb upgrade` will see your existing packages.

### Switching back to Homebrew

Packages installed by nanobrew live in `/opt/nanobrew/prefix/Cellar/` — they don't interfere with Homebrew's `/opt/homebrew/Cellar/`. You can safely remove nanobrew with `nb nuke` without affecting Homebrew.

## Project status

**Experimental** — works well for common packages. If something breaks, [open an issue](https://github.com/justrach/nanobrew/issues).

License: [Apache 2.0](./LICENSE)
License: [Apache 2.0](./LICENSE)

## All commands
| `nb info --cask <app>` | | Show cask details |
| `nb migrate` | | Import packages from Homebrew |
| Command | Short | What it does |
|---------|-------|-------------|
| `nb install <pkg>` | `nb i` | Install packages |
| `nb install --cask <app>` | | Install macOS apps |
| `nb install --deb <pkg>` | | Install .deb packages (Linux/Docker) |
| `nb install user/tap/formula` | | Install from a third-party tap |
| `nb remove <pkg>` | `nb ui` | Uninstall packages |
| `nb remove --deb <pkg>` | | Remove a .deb package (Linux/Docker) |
| `nb list` | `nb ls` | List installed packages (brew + deb) |
| `nb info <pkg>` | | Show package details |
| `nb search <query>` | `nb s` | Search formulas and casks |
| `nb upgrade [pkg]` | | Upgrade packages |
| `nb upgrade --deb` | | Upgrade all installed .deb packages |
| `nb outdated` | | List outdated packages (brew + deb) |
| `nb pin <pkg>` | | Prevent upgrades |
| `nb unpin <pkg>` | | Allow upgrades |
| `nb rollback <pkg>` | `nb rb` | Revert to previous version |
| `nb bundle dump` | | Export installed packages |
| `nb bundle install` | | Import from bundle file |
| `nb doctor` | `nb dr` | Health check |
| `nb cleanup` | `nb clean` | Remove old caches |
| `nb deps [--tree] <pkg>` | | Show dependencies |
| `nb services` | | Manage services (launchctl/systemd) |
| `nb completions <shell>` | | Print shell completions |
| `nb update` | | Self-update nanobrew |
| `nb init` | | Create directory structure |
| `nb help` | | Show help |

See [CHANGELOG.md](./CHANGELOG.md) for version history.
