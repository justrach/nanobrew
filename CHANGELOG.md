# Changelog

All notable changes to nanobrew are documented here.

## [0.1.065] - 2026-02-16

### Added
- **Third-party tap support** — `nb install user/tap/formula` now works. nanobrew is the only fast Homebrew client that supports third-party taps. Example: `nb install steipete/tap/sag` installs in ~2s.
- **Ruby formula parser** (`src/api/tap.zig`) — line-by-line parser for `.rb` formula files. Extracts version, url, sha256, dependencies, bottle blocks, and handles `#{version}` interpolation and `on_macos`/`on_linux` platform conditionals.
- **Tap formula fetching** — fetches formulas directly from `raw.githubusercontent.com/<user>/homebrew-<tap>/HEAD/Formula/<name>.rb`. Falls back to `Formula/<letter>/<name>.rb` for sharded repos.
- **Pre-built binary detection** — when a tap formula has no build system (common for pre-built binary taps), nanobrew scans the extracted tarball for executables and copies them to the keg `bin/` directory.
- **Native HTTP everywhere** — replaced all remaining curl subprocess calls with Zig's native `std.http.Client`. Zero external dependencies for network operations. Shared HTTP client in dependency resolver for TLS connection reuse.

### Changed
- Dependency resolver now shares a single HTTP client across all API fetches for TLS connection reuse, reducing resolve time for multi-dep packages.
- `fetchFormulaWithClient` routes tap refs (names with 2 slashes) to the Ruby formula pipeline automatically — no special flags needed.

## [0.1.06] - 2026-02-16

### Added
- **Linux support** — nanobrew now runs natively on Linux (x86_64 and aarch64). Same 1.2 MB static binary.
- **`nb install --deb <pkg>`** — Install packages from Ubuntu repositories. Native `.deb` extraction without `dpkg`, `ar`, or `zstd` binaries — only needs `tar`. 2.8x faster than `apt-get install` in Docker containers.
- **Platform abstraction layer** (`src/platform/`) — centralized path constants, comptime platform detection, COW copy abstraction (`clonefile` on macOS, `cp --reflink=auto` on Linux).
- **ELF relocator** (`src/elf/relocate.zig`) — detects ELF binaries, parses headers, uses `patchelf` for RPATH/interpreter fixups, replaces `@@HOMEBREW_PREFIX@@` placeholders in `.pc`/`.cmake`/`.la` config files.
- **Deb package index parser** (`src/deb/index.zig`) — native RFC 822-style parser for Ubuntu `Packages.gz` indices.
- **Deb dependency resolver** (`src/deb/resolver.zig`) — BFS + topological sort with support for alternatives and virtual packages.
- **Native ar + decompression** (`src/deb/extract.zig`) — parses ar archive headers, decompresses `data.tar` with Zig's native zstd and gzip decompressors.
- **Native HTTP for deb downloads** — `std.http.Client` with connection reuse across all package downloads. Streaming SHA256 verification in a single pass.
- **Content-addressable deb cache** — downloaded `.deb` files cached by SHA256 hash. Warm installs skip download entirely.
- **systemd service management** (`src/services/systemd.zig`) — discovers `.service` files in Cellar, wraps `systemctl start/stop/restart`.
- **Comptime bottle tags** for Linux — `x86_64_linux` and `aarch64_linux` bottle selection in `formula.zig`.
- **Cross-compilation targets** — `zig build linux` and `zig build linux-arm` in `build.zig`.
- **Deb parity test** (`tests/deb-parity.sh`) — Docker-based integration test verifying byte-identical extraction vs `dpkg-deb` across 5 test categories.
- **Linux CI** — `build-linux` job with deb parity test, cross-compile job for both architectures.
- **Deb benchmark workflow** — automated `nb --deb` vs `apt-get` benchmarks in CI, auto-updates README.

### Changed
- `install.sh` detects OS and uses `.bashrc` on Linux.
- Services dispatcher now routes to launchd (macOS) or systemd (Linux) at comptime.
- Cask commands show a clear error on Linux (casks are macOS-only).
- Mach-O relocator refactored to share placeholder logic with ELF relocator.
- `tar` extraction uses `--skip-old-files` for safe overlay in Docker containers.

### Fixed
- **zstd decompression for large packages** — buffer sized at `default_window_len + block_size_max` (8MB + 128KB). Previously failed on packages like libc6.
- **HTTP connection reuse failures** — retry with fresh client after ~20 sequential downloads.

## [0.1.052] - 2026-02-16

### Added
- **Update checker** — `nb` now checks for new versions once per day (via Cloudflare edge cache) and shows a colored banner when an update is available.
- **Version display** — `nb help` header shows the current version.
- **Cloudflare `/version` endpoint** — Worker returns latest release version with 5-min CF cache, so the Zig client never hits GitHub directly.
- **GitHub Actions benchmark workflow** — Weekly CI job benchmarks `nb install` vs `brew install` for tree, wget, ffmpeg and auto-updates the README table.

### Fixed
- Release workflow no longer generates duplicate `license` lines in Formula.

## [0.1.05] - 2026-02-16

### Added
- **`nb doctor`** — Health check that scans for broken symlinks, missing Cellar dirs, orphaned store entries, and permission issues. Alias: `nb dr`.
- **`nb cleanup`** — Removes expired API/token caches, temp files, and orphaned blobs/store entries. Supports `--dry-run` to preview and `--all` to include history-referenced entries.
- **`nb outdated`** — Lists packages with newer versions available. Shows `[pinned]` tag for pinned packages.
- **`nb pin <pkg>` / `nb unpin <pkg>`** — Pin a package to prevent `nb upgrade` from touching it.
- **`nb rollback <pkg>`** — Revert a package to its previous version using the install history. Alias: `nb rb`.
- **`nb bundle dump`** — Export all installed kegs and casks to a Brewfile-compatible `Nanobrew` file.
- **`nb bundle install [file]`** — Install everything listed in a bundle file. Defaults to `./Nanobrew`.
- **`nb deps [--tree] <formula>`** — Show dependencies. `--tree` renders an ASCII dependency tree with box-drawing characters.
- **`nb services [list|start|stop|restart] [name]`** — Discover and control launchctl services from installed packages. Scans Cellar for `homebrew.mxcl.*.plist` files.
- **`nb completions [zsh|bash|fish]`** — Print shell completion scripts to stdout.
- **Pinned packages** — `pinned` field added to database. Pinned packages are skipped by `nb upgrade` and tagged `[pinned]` in `nb list` and `nb outdated`.
- **Install history** — Database now tracks previous versions of each package. Used by `nb rollback` and protected by `nb cleanup`.

### Changed
- `nb list` now shows `[pinned]` tag for pinned packages.
- `nb upgrade` skips pinned packages (use `nb unpin` first).
- `nb cleanup` protects store entries referenced by install history.
- Extracted `getOutdatedPackages` helper used by both `nb upgrade` and `nb outdated`.
- Database schema extended with `pinned`, `installed_at`, and `history` fields (backward-compatible with older `state.json` files).

## [0.1.03] - 2026-02-16

### Added
- **Source builds** — Formulae without pre-built bottles are now compiled from source automatically. Supports cmake, autotools, meson, and make build systems. Source tarballs are SHA256-verified before building.
- **`nb search <query>`** — Search across all Homebrew formulae and casks. Case-insensitive substring matching on name and description. Results show version, `[installed]` status, and `(cask)` tag. Alias: `nb s`.
- **`nb upgrade`** — Upgrade outdated packages. Compares installed versions against the Homebrew API and reinstalls any that are behind. Works with both kegs and casks.
  - `nb upgrade` — upgrade all outdated packages
  - `nb upgrade <name>` — upgrade a specific package
  - `nb upgrade --cask` — upgrade all casks
  - `nb upgrade --cask <name>` — upgrade a specific cask
- **Post-install scripts** — Common Ruby post-install patterns (`system`, `mkdir_p`, `ln_sf`) are parsed from Homebrew formula source and executed after install.
- **Caveat display** — Formulae with caveats (e.g. postgresql, openssh) now display their instructions after installation with an `==> Caveats` header.

### Changed
- Formula parser now reads `urls.stable.url`, `urls.stable.checksum`, `build_dependencies`, `caveats`, and `post_install_defined` from the Homebrew API.
- Install pipeline gracefully falls back to source build when no arm64 bottle exists, instead of failing with `NoArm64Bottle`.
- Search results are cached for 1 hour to avoid repeated large API fetches.

## [0.1.02] - 2025-06-15

### Added
- **Cask support** — `nb install --cask <app>` installs macOS applications from .dmg, .zip, .pkg, and .tar.gz bundles. `nb remove --cask <app>` uninstalls them.
- Cask tracking in database (apps, binaries, version).
- `nb list` now shows installed casks alongside kegs.

## [0.1.01] - 2025-06-14

### Added
- `nb update` / `nb self-update` — Self-update nanobrew to the latest release.
- Error logging throughout the install pipeline.
- Unit tests for all pure functions.

## [0.1.00] - 2025-06-13

### Added
- Initial release.
- BFS parallel dependency resolution with topological sort.
- Parallel bottle download with streaming SHA256 verification.
- Content-addressable store with APFS clonefile materialization.
- Native Mach-O relocation (no otool subprocess).
- Batched codesign per keg.
- Symlink management for bin/ and opt/.
- JSON-based install state database.
- Commands: `init`, `install`, `remove`, `list`, `info`, `help`.
- Warm installs in under 4ms.
