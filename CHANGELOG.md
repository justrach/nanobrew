# Changelog

All notable changes to nanobrew are documented here.

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
