<p align="center">
  <img src="assets/logo.png" alt="nanobrew logo" width="200">
</p>

# nanobrew

A fast package manager for macOS and Linux. Written in Zig. Uses Homebrew's bottles and formulas under the hood, plus native .deb support for Docker containers.

## Why nanobrew?

- **Fast warm installs** — packages already in the local store reinstall in ~3.5ms
- **Parallel downloads** — all dependencies download and extract at the same time
- **No Ruby runtime** — single static binary, instant startup
- **Drop-in Homebrew replacement** — same formulas, same bottles, same casks
- **Linux + Docker** — native .deb support, 2.8x faster than apt-get

| Package | Homebrew | zerobrew (cold) | zerobrew (warm) | nanobrew (cold) | nanobrew (warm) |
|---------|----------|-----------------|-----------------|-----------------|-----------------|
| **tree** (0 deps) | 5.527s | 2.280s | 0.238s | **0.681s** | **0.010s** |
| **ffmpeg** (11 deps) | 19.571s | 5.552s | 3.386s | **2.117s** | **0.564s** |
| **wget** (6 deps) | 5.849s | 9.364s | 1.056s | **3.090s** | **0.033s** | 3.859s | — | — | **2.527s** | **0.026s** |

> Benchmarks on Apple Silicon (GitHub Actions macos-14), 2026-02-16. Auto-updated weekly.

| | nanobrew | zerobrew | Homebrew |
|---|---------|----------|----------|
| **Binary size** | **1.2 MB** | 7.9 MB | 57 MB (Ruby runtime) |

> nanobrew is **6.8x smaller** than zerobrew and **47x smaller** than Homebrew. See how these are measured in the [benchmark workflow](.github/workflows/benchmark.yml).

### Linux / Docker (deb packages vs apt-get)

| Command | apt-get | nanobrew --deb | Speedup |
|---------|---------|----------------|---------|
| **curl** (32 deps) | 34.1s | 12.2s | **2.8x** |
| **curl wget git** (60+ deps) | 49.7s | 25.0s | **2.0x** |

> Benchmarks in Docker (ubuntu:24.04, GitHub Actions ubuntu-latest), 2026-02-16. Auto-updated weekly.

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

### macOS Apps (Casks)

```bash
nb install --cask firefox     # install a .dmg/.pkg/.zip app
nb remove --cask firefox      # uninstall it
nb upgrade --cask             # upgrade all casks
```

### Linux / Docker (deb packages)

```bash
nb install --deb curl wget git    # install from Ubuntu repos (2.8x faster than apt-get)
```

```dockerfile
# Replace slow apt-get in Dockerfiles
COPY --from=nanobrew/nb /nb /usr/local/bin/nb
RUN nb init && nb install --deb curl wget git
```

- Resolves dependencies, downloads .debs with streaming SHA256 verification
- Content-addressable cache — warm installs are instant
- Produces byte-identical files to `dpkg-deb` extraction

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
  ├─ 1. Fetch + decompress package index (native gzip)
  ├─ 2. Resolve dependencies (BFS topological sort)
  ├─ 3. Download .debs with streaming SHA256 verification
  ├─ 4. Parse ar archive, decompress data.tar natively (zstd/gzip)
  └─ 5. Extract to / (tar --skip-old-files)
```

Key design choices:
- **Content-addressable store** — deduplicates bottles by SHA256. Reinstalls are instant because the data is already there.
- **APFS clonefile** — copy-on-write on macOS means no extra disk space when materializing from the store.
- **Streaming SHA256** — hash is verified during download, no second pass over the file.
- **Native binary parsing** — reads Mach-O (macOS) and ELF (Linux) headers directly instead of spawning `otool`/`patchelf`.
- **Native ar + decompression** — .deb extraction without `dpkg`, `ar`, or `zstd` binaries. Only needs `tar`.
- **Single static binary** — no runtime dependencies. 1.2 MB.

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

## Relationship with Homebrew

nanobrew uses Homebrew's formulas, bottles, and cask definitions. It's a faster client for the same ecosystem — not a fork. We recommend running it alongside Homebrew. Source builds work for formulae without pre-built bottles.

## Project status

**Experimental** — works well for common packages. If something breaks, [open an issue](https://github.com/justrach/nanobrew/issues).

License: [Apache 2.0](./LICENSE)

## All commands

| Command | Short | What it does |
|---------|-------|-------------|
| `nb install <pkg>` | `nb i` | Install packages |
| `nb install --cask <app>` | | Install macOS apps |
| `nb install --deb <pkg>` | | Install .deb packages (Linux/Docker) |
| `nb remove <pkg>` | `nb ui` | Uninstall packages |
| `nb list` | `nb ls` | List installed packages |
| `nb info <pkg>` | | Show package details |
| `nb search <query>` | `nb s` | Search formulas and casks |
| `nb upgrade [pkg]` | | Upgrade packages |
| `nb outdated` | | List outdated packages |
| `nb pin <pkg>` | | Prevent upgrades |
| `nb unpin <pkg>` | | Allow upgrades |
| `nb rollback <pkg>` | `nb rb` | Revert to previous version |
| `nb bundle dump` | | Export installed packages |
| `nb bundle install` | | Import from bundle file |
| `nb doctor` | `nb dr` | Health check |
| `nb cleanup` | `nb clean` | Remove old caches |
| `nb deps [--tree] <pkg>` | | Show dependencies |
| `nb services` | | Manage launchctl services |
| `nb completions <shell>` | | Print shell completions |
| `nb update` | | Self-update nanobrew |
| `nb init` | | Create directory structure |
| `nb help` | | Show help |

See [CHANGELOG.md](./CHANGELOG.md) for version history.
