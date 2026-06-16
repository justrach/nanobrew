# Changelog

All notable changes to nanobrew are documented here.

## Unreleased

### Fixed
- **Linux-only dependencies are now resolved (`uses_from_macos` / `on_linux`) (#324)** — the resolver folds each formula's `uses_from_macos` entries into its runtime dependencies on every platform and, on Linux, prefers the already-expanded `variations.<arch>_linux.dependencies` list when present. So `nb install autoconf` now also installs `perl` (and `perl` → `libxcrypt`), and `git` resolves its full Linux closure (openssl@3, zlib-ng-compat, curl, …) instead of placing a binary whose interpreter/shared libraries are missing. The pinned bottle registry gets the same union via `nb_bottles.py`, and the 72 affected records were backfilled.
- **`nb install --deb` no longer reports success when nothing was placed (#327)** — `--deb` writes to system paths under `/`, so without root the place step failed with EACCES yet still printed `Installed N/N` and exited 0. Extraction now tracks per-file write failures, a package that lands zero of its files is counted as failed, and a partial/failed install exits non-zero with a `re-run with sudo` hint. Also fixed an uninitialized `installed_files` field that could free a wild pointer (segfault) now that a package can fail extraction. Root installs are unchanged.
- **`nb --version` / `nb version` / `nb -v`** — now print `nanobrew <version>` instead of erroring with `unknown command`; useful for scripting and bug reports (#327).
- **`nb update` / `nb update-registry` hardening (#314)** — `nb update` now validates the replacement is a real Mach-O/ELF executable before renaming it over the live `nb`, rejecting any other `nb*` file (e.g. a `.sha256` sidecar) in the release tarball. `nb update-registry` propagates a cache-write failure instead of printing "refreshed N records" while the next command silently serves the stale cache.

## [0.1.198] - 2026-06-12

### Security
- **Bottle vulnerability scanning + CVE revocation with version fallback** — `nb_bottles.py scan` extracts each pinned bottle (all four platforms), SBOMs it with syft, matches with grype, and exits non-zero at/above `--gate` (default high); the first full run caught a real finding (gh 2.91.0 ships Go 1.26.2 stdlib HIGH CVEs). `revoke`/`unrevoke` mark a CVE'd pin revoked and record the previous known-good version as `resolved.fallback`. The `nb` resolver installs a revoked pin's fallback with a warning naming the advisory (revoked without fallback fails closed); the live-API freshness override is disabled for fallbacks so it can't silently undo the deliberate downgrade. Revocations propagate via the remote registry (6h TTL) — no binary release needed. `push-evidence` attaches SBOM + scan report to the bottle's GHCR manifest as OCI referrer artifacts, and `bottles.yml` rescans every pinned bottle weekly against fresh CVE data, auto-opening a security-labeled issue on a gate hit.
- **`nb doctor` flags installed revoked versions** — kegs whose registry pin has since been revoked are reported with the advisory and the exact fix (remove + reinstall lands on the safe fallback), covering machines that installed before the revocation. Verified live against CVE-2026-33814 on gh 2.91.0.
- **Immutable version tags on the bottle registry** — `push_manifest` refuses to re-tag a different blob under an existing version tag (same-digest re-pushes stay idempotent); version tags are what humans audit, so bumps are new tags.
- **`nb_bottles.py attest` verifies provenance of pinned upstream assets** — ranks each release asset by the strongest upstream vouching available (`github-attestation` via sigstore/gh CLI > `checksum-file` > `pin-only`), dies on any disagreement between our pin and upstream's published checksums, and `--require` gates CI on a minimum level.

### Performance

| Operation | Before | After | Speedup |
|---|---:|---:|---:|
| ELF relocate phase (Linux) | 4,777 ms | 6 ms | **~800x** |
| Cached-bottle reinstall (macOS) | 534 ms | 4 ms | **~130x** |
| Warm `nb install` resolve | 147 ms | 1.8 ms | **~80x** |
| Linux cold install, fresh machine (hexyl) | 5,876 ms | 1,110 ms | **~5x** |

- **Linux cold installs ~5x faster on fresh machines (hexyl 5,876 ms → 1,110 ms; relocate phase 4,777 ms → 6 ms)** — ELF relocation is now native and in-place instead of shelling out to patchelf. A `/opt/nb → <prefix>` short symlink (created by `nb init` and lazily by the relocator) makes every `@@HOMEBREW_*@@` replacement strictly shorter than its placeholder, so RPATH/RUNPATH, DT_NEEDED, PT_INTERP, and `.rodata` strings are all rewritten in one read+write pass with '/' padding at the path boundary (valid for C-string and length-delimited consumers alike — perl bakes @INC entries with compile-time lengths, so NUL padding would corrupt them) — no section resizing, no subprocesses, and no `apt-get install patchelf` bootstrap (which alone cost ~4.8 s on every fresh machine and made installs *fail* where no package manager was available). PT_INTERP repair (missing glibc keg → system loader) is also native. patchelf remains only as a fallback when `/opt/nb` can't be created (non-root upgrades of old installs), bootstrapped lazily on first need. Also fixes a latent bug where only the first of several placeholders inside one colon-separated rpath string was rewritten.
- **Warm `nb install` ~80x faster (147 ms → 1.8 ms)** — resolving any package that isn't in the verified-upstream registry (the vast majority) re-downloaded the ~650 KB registry from GitHub on every resolve. Two fixes in `loadRecordWithOptions`: a fresh registry cache is now authoritative for misses too (no remote refetch inside the 6h TTL), and a fetched remote registry is cached even when the requested token isn't in it — previously the cache was only written on a token hit, so after TTL expiry every resolve of a non-registry token re-paid the remote fetch forever. Multi-dependency cold installs save one ~650 KB round trip per dep token.
- **Cached-bottle reinstalls no longer pay a GHCR token round trip (macOS reinstall 534 ms → 4 ms)** — the batch-shared bearer token was fetched whenever any package had a ghcr.io bottle URL, even when every blob was already in the local cache; it's now fetched only when at least one bottle actually needs downloading.
- `NB_BENCH=1` now reports per-phase timings (extract / materialize / relocate / placeholders+seal / snapshot / link / postinstall) for each package, not just download.

### Fixed
- **TLS works out of the box for brewed openssl/gnutls (Linux especially)** — Homebrew wires `<prefix>/etc/ca-certificates/cert.pem` (the path baked into openssl@3's OPENSSLDIR, curl's `--with-ca-bundle`, and gnutls' default trust store) in Ruby `post_install` blocks that nanobrew's heuristic script parser couldn't execute, so the file never existed and anything linking brewed TLS failed certificate verification on fresh machines. A native post-install step (`src/build/certs.zig`) now creates the symlinks itself: `etc/ca-certificates/cert.pem` → the ca-certificates keg's `cacert.pem` (or the system CA bundle when the keg isn't installed), and `etc/openssl@N|gnutls|libressl/cert.pem` → that shared store. Idempotent and converging — a later ca-certificates install repoints the store at the keg bundle; a user-placed regular `cert.pem` is never overwritten.
- **`@@HOMEBREW_PERL@@` shebangs are now relocated** — autoconf (and any formula whose scripts run under brewed perl) installed with a literal `#!@@HOMEBREW_PERL@@` interpreter line, which made the binary fail with "bad interpreter". The placeholder now maps to `<prefix>/opt/perl/bin/perl` in both text relocation passes. Known limitation surfaced while testing: on Macs with a real Homebrew install at `/opt/homebrew`, baked `.rodata` paths (e.g. perl's `@INC`) resolve into the real Homebrew because the compat symlink can't exist — fixing that needs the `/opt/nb` short-prefix rewrite on macOS plus re-codesigning, tracked as follow-up work.
- **Download retry classification hardened (#314)** — a transient failure during the GHCR token fetch no longer turns into a permanent `AuthFailed` (the 401-with-no-token case is now retried, re-fetching the token each attempt); `isRetryable` switched from `else => true` to an explicit transient whitelist, so deterministic failures (OOM, bad paths, rename `AccessDenied`, checksum mismatch) stop wasting 2 retries + 750 ms of backoff; a path-format failure after a successful download no longer drops the started telemetry event.
- **Parallel downloads of the same blob no longer corrupt each other (#314)** — two workers fetching the same sha shared one tmp path (`<sha>.dl`) and interleaved writes surfaced as a hard `ChecksumMismatch`; tmp files now carry a per-worker pid+tid suffix with the same atomic rename (first writer wins), and failed renames clean up their tmp file.
- **Env-shim kegs no longer relink on every install (#314)** — kegs linked through wrapper shims in global mode (e.g. git, whose wrapper sets `GIT_EXEC_PATH`) permanently failed `needsLinkRepair`'s check because the link targets `.nb-wrappers/…`, not the keg binary, so every `nb install` run relinked the whole keg. The repair check now mirrors the linker's env-shim detection and compares against the wrapper target it actually creates.

### Added
- **`scripts/bottles/nb_bottles.py` + `manage.md` + `bottles.yml` workflow** — nanobrew's own GHCR bottle registry (`ghcr.io/justrach/nb-bottles/<name>`): Tier-1 digest-preserving mirror of the pinned `homebrew_bottle` registry entries (instant OCI cross-repo mounts), Tier-2 repackaging of `github_release` binaries into bottles, publish/verify/record management verbs, and a weekly CI mirror cron. Consumed via `NANOBREW_BOTTLE_DOMAIN` or per-package registry records; verified end-to-end (anonymous pulls, digest match with Homebrew's pins, real `nb install` from the mirror).
- **37 new verified-upstream packages with pinned bottle digests for all four platforms** — bash, zsh, nginx, qemu, colima, postgresql@14/16/18, mysql, node@24, rustup, gradle, poetry, fastlane, tailscale, mkcert, sops, gitleaks, httpie, eza, btop, direnv, aria2, rsync, telnet, automake, expat, lcov, composer, ghostscript, hexyl, kubeconform, xclogparser, xcresultparser, flyctl, whisper-cpp, and summarize — mirrored into the embedded default registry.

## [0.1.197] - 2026-06-12

### Performance
- **`nb outdated` ~1,170x faster (3,640 ms → 3.1 ms), `nb leaves` ~1,140x faster (4,690 ms → 4.1 ms), `nb search` ~30x faster (93 ms → 3.1 ms)** — a TSV index sidecar (`name`, `version`, `desc`, plus entry byte offsets) is built once per bulk-list cache refresh (1h TTL) and replaces both the per-installed-package API round trips (`outdated`/`upgrade` checks, `leaves`) and the 46 MB JSON re-scan per `search`. Packages outside the bulk lists (taps, upstream-only) still use the parallel per-name fetch fallback.
- **Cold dependency resolution ~7x faster (1,077 ms → 150 ms for ffmpeg's graph)** — formula and cask metadata fetches slice the package's full API object out of the fresh bulk cache via one `pread` (using the sidecar's byte offsets) instead of a network round trip, then warm the per-name cache. `nb install` resolve, `nb info`, and the upstream freshness checks all ride this path; outputs verified byte-identical to network fetches.

### Added
- **`nb switch <pkg>@<version>`** — reactivate a previously-installed version. Instant when the keg is still in the Cellar (switch keeps the outgoing version on disk, unlike `rollback`); otherwise re-materializes from the content-addressed store, and suggests `nb install pkg@version` when the payload is gone. `nb list --versions` shows each package's install history with the switchable versions marked.

### Fixed
- **Failed installs no longer leave phantom DB entries, and downloads retry transient failures** — a package whose download/extract failed used to be recorded in the database at its declared version, tripping `nb doctor` and blocking reinstalls. Installs now only record kegs that actually landed in the Cellar, bottle downloads retry network blips/5xx/429 with linear backoff (checksum mismatches and 404/auth are not retried), and the install summary prints *why* each package failed instead of a bare ✗. (#311)
- **Intel casks read `version` from the same arch `variations` block as `url`/`sha256`** — previously the root (arm64) version leaked into artifact paths on Intel, breaking Caskroom paths and symlinks for casks like `gcc-arm-embedded`; the root version baked into artifact paths is rewritten (token-bounded) to the arch version. (#307)
- **Casks with `using: :post` download correctly** — `url_specs` (`data:`, `referer:`, `user_agent:`, `cookies:`, `header:`) are parsed and replayed, so license-gated casks like `segger-jlink` get the real payload instead of an HTML page that fails the checksum. (#305)
- **Stale verified-upstream pins no longer downgrade installs** — the registry pin is cross-checked against the live Homebrew API and the newer version wins (falling back to the pin offline); `python3` resolves 3.14.5 instead of the embedded 3.14.4, `claude-code` resolves latest instead of 2.1.109. Opt out with `NANOBREW_DISABLE_UPSTREAM_FRESHNESS=1`. The registry itself is refreshable via `nb update` / `nb update-registry`. (#308, #310)
- **`bin.install` parsing is strict** — `bin.install_symlink` is no longer mistaken for `bin.install`, and non-literal arguments (`#{version}` interpolation, `Dir[...]` globs, keg-rooted paths) drop the declared-binaries list so the source build keeps its generic whole-payload copy instead of failing.
- **Interrupted cask installs are only re-adopted at the exact on-disk version** — adoption no longer records the API's current version for a payload installed at an older one, which froze `nb upgrade` on a stale app. (#302 follow-up)

### CI
- **`zig build test` now actually runs `search.zig`'s tests** — the root test aggregation was silently skipping them; they're included, and the search/bulk-index tests run in CI.

## [0.1.196] - 2026-06-02

### Performance
- **Cask DMG mount ~23x faster on cold mounts** — `hdiutil attach` now runs with `-noverify -noautofsck -readonly`. The download path already SHA256-verifies the DMG bytes, so hdiutil's per-attach checksum was duplicate work that dominated cold-mount time on large DMGs (the deficits called out in #259: `bruno` -2123 ms, `raycast` -1858 ms, `orbstack` -691 ms). Measured on a 350 MB DMG: cold mount went 4983 ms → 215 ms. `hdiutil detach` also gets `-force` so a stuck handle on the mount can't hang cleanup. Refs #259.
- **DMG detach no longer blocks install return** — `hdiutil detach` is now spawned in the background and not awaited. The volume unmounts while `nb` is already returning to the user; the kernel reaps the still-running child on `nb` exit. Eliminates a 200–500 ms stall from the `cleanup` phase on every DMG cask.
- **Quarantine clear uses `removexattr(2)` directly on the non-recursive path** — the .dmg and .pkg quarantine-removal paths used to fork+exec `/usr/bin/xattr -p` to probe and then `/usr/bin/xattr -d` to remove, a 2-subprocess pattern that fired up to four times per cask. Replaced with a direct `removexattr` syscall, with the recursive .app path keeping the subprocess but dropping the redundant probe. Cuts ~40–60 ms per DMG cask off the `mount_dmg` and `artifacts` phases.
- **Batch installs share one HTTP client and GHCR token** — install workers now borrow a batch-wide `std.http.Client` (one TLS connection pool, no per-package handshake) and a single anonymous GHCR pull token fetched once per batch. The 16-slot install window also reclaims any finished worker slot instead of always joining the oldest, so a long source build scheduled first no longer stalls the pipeline. (#36)

### Fixed
- **Tap formulas with `def install / bin.install` now symlink correctly** — `parseRubyFormula` now extracts binaries named in a Ruby `def install` block and surfaces them via `Formula.install_binaries`. Previously, prebuilt-tarball tap formulas (e.g. `neurosnap/tap/zmx`, `steipete/tap/sag`) installed into the keg root with no `prefix/bin` symlink, so the binary was missing from `PATH`. Source-build now feeds these names through `installDeclaredBinaries` into `keg/bin/`, where the existing linker picks them up. (#286)
- **Casks installed via `nb bundle install` were missing from `nb list`** — the install now persists the database after each cask, and a cask whose payload is already on disk (e.g. from an interrupted run) is re-adopted into the database instead of silently skipped, so `nb list`, `nb bundle dump`, and `nb upgrade` stay in sync with the Caskroom. (#302)
- **Casks delivered via a `suite`/`artifact` stanza (e.g. KiCad) now install correctly** — the cask parser handles `suite` and `artifact` artifacts (previously dropped), `/Applications` payloads are copied and de-quarantined like `app` artifacts, and a `binary` symlink is no longer created when its source is absent — so a failed cask reports an error instead of falsely succeeding with broken symlinks. (#303)

## [0.1.195] - 2026-06-02

### Added
- **`nb install <pkg>@<version>`** — versioned installs resolved from GHCR/OCI bottle tags, with automatic pinning and an "offer latest" fallback when the requested version has no bottle for the current platform. (#300)

### Fixed
- **Post-install SIGSEGV on versioned install** — the daily update check now runs on a dedicated single-threaded HTTP client and `nb` exits cleanly, eliminating the crash during runtime teardown. (#298)
- **Relocate literal Homebrew paths in Mach-O binaries** — embedded `/opt/homebrew` and `/usr/local` paths are rewritten so relocated kegs work outside the default prefix, fixing packages such as imagemagick and libheif. (#297)
- **Misnamed binary inside release tarballs** — the notarize/packaging step stages the binary as `nb`, and the install / `nb update` paths fall back to an `nb-<arch>` entry when present. (#293, #296)
- **Linker shim promotion** — kegs that ship `libexec/git-core` are auto-promoted to a shim wrapper.

### Performance
- **GHCR pull token fetched once per versioned install** — a single anonymous pull token is reused across tag listing, manifest, and blob download, removing two cold round-trips per versioned install.

### Docs
- Documented the package-manager CLI policy in the upstream registry docs. (#253)

## [0.1.194] - 2026-05-25

### Fixed
- Tap symlink creation, the update banner, the `git` shim, and Linux CI. (#292)
- `nb update` now falls back to curl/wget for the SHA256 download when the primary fetch fails.

## [0.1.193] - 2026-05-11

### Added
- **`nb cleanup --prune-kegs`** — new flag that drops phantom DB entries pointing at kegs that no longer exist on disk, with a hint when the 256-entry batch cap is hit so users know to re-run. (#279)
- **Verified upstream speed registry path** — nanobrew can now resolve selected formulae and casks from a curated verified upstream registry before falling back to Homebrew metadata. GitHub Release formulae install through the native source-archive path with declared binary artifacts, Homebrew bottle formula locks install through the native bottle path, and GitHub/vendor casks reuse the native cask install pipeline. The registry is loaded from a local cache, then the hosted registry, then the embedded fallback.
- **Seeded upstream coverage** — embedded registry now includes 256 formula records (GitHub Release binaries, resolved vendor binaries, and generated Homebrew bottle locks) and 103 cask records. The current registry covers 100/100 Homebrew top formulae and 100/100 top casks for the April 25, 2026 analytics snapshot.
- **Programmatic upstream seeding tools** — added seeders for popular formulae and casks using Homebrew analytics, Homebrew bottle URL/SHA locks, dependency lists, optional formula dependency-closure seeding, GitHub release assets, pinned vendor URLs, direct binary downloads, checksums, platform matching, binary-only cask handling, Caskroom-relative binary normalization, cask binary target preservation, and artifact inference.
- **Coverage and benchmark tooling** — added scripts to report top-N upstream registry coverage, compare metadata resolution, and benchmark actual `nb install` wall time for verified upstream versus Homebrew fallback.
- **GitHub Actions install benchmarks for native upstream paths** — the upstream tooling workflow now benchmarks actual installs on macOS runners, uploads JSON artifacts for formula and cask install timings, and records cask phase traces for metadata, download, mount/extract, artifact copy, cleanup, and total command time.
- **Top-100 upstream gap report** — added `scripts/upstream-gap-report.mjs` to classify every unseeded top-N formula and cask by Homebrew rank, install count, current seeder skip bucket, artifact/source shape, likely resolver class, and checksum availability. The current top-100 gap report returns zero formula gaps and zero cask gaps.
- **Broader native cask artifacts** — verified upstream casks now support platform-specific artifact lists, pkg records, font installs, copied artifacts/suites, installer scripts, `.tar.xz` archives, extensionless pinned vendor URLs, and reviewed `no_check` vendor URL records.
- **Shimmed formula installs** — added `nb install --shims <formula>` and `NANOBREW_SHIMS=1` for packages such as `yt-dlp` that need dependency executables at runtime but should not expose those tools globally. The requested formula is linked through wrapper shims in `prefix/bin`, while dependency executables such as `deno` and `python3.14` stay private and are only added to the wrapper's `PATH`.
- **Anonymous download telemetry controls** — added best-effort, non-blocking download timing telemetry for formulae, casks, source archives, self-updates, and native Linux package downloads, plus `nb telemetry status`, `nb telemetry off`, and `nb telemetry on` controls. Events include package-like target name, operation kind, duration, byte count, OS, architecture, RAM, CPU count, and success, and exclude URLs, paths, usernames, hostnames, user IDs, full package lists, and command history.
- **Sandboxed package-manager comparison CI** — added an on-demand macOS Actions benchmark that compares `yt-dlp` across current nanobrew, nanobrew v0.1.191, Homebrew, and the pinned zerobrew v0.2.1 binary. Zerobrew runs under a short `/tmp/zbp` prefix so Mach-O rewriting remains valid without touching the runner's normal package-manager prefixes.
- **Upstream promotion gate** — added `scripts/upstream-promotion-check.mjs` to gate registry expansion batches against coverage deltas, registry shape validation, `no_check` review policy, and saved install benchmark JSON with a minimum speedup threshold.
- **Offline upstream tooling fixtures** — added deterministic fixtures and `scripts/test-upstream-tooling.mjs` covering coverage math, top-100 gap classification, release DB generation, formula seeder helper behavior, and promotion checks without live Homebrew or GitHub calls.

### Performance
- **Native upstream formula installs are faster for self-contained binaries** — cold package-cache install benchmarks show `actionlint` installing in 728 ms through verified upstream vs 4665 ms through Homebrew fallback (6.41x faster), and `fd` in 623 ms vs 1703 ms (2.74x faster).
- **Formula benchmark is faster for 6/7 expanded formulae locally after native `starship` promotion** — the current ReleaseFast local matrix covers `actionlint`, `fd`, `ripgrep`, `uv`, `starship`, `zoxide`, and `yq`. Verified upstream is faster for 6/7 formulae with a weighted speedup of 1.56x; `starship` now installs through its 3.9 MB GitHub release archive instead of the Homebrew bottle and measures 369 ms vs 518 ms in the matrix, with a focused 3-iteration run at 368 ms vs 636 ms (1.73x). `yq` remains bottle-backed until formula binary target/rename support lands.
- **CI cask benchmark now passes with 24 actual casks** — the latest macOS Actions cask run covers `iterm2`, `codex`, `font-hack-nerd-font`, `visual-studio-code`, `cursor`, `raycast`, `postman`, `firefox`, `google-chrome`, `brave-browser`, `orbstack`, `alacritty`, `alt-tab`, `maccy`, `rectangle`, `stats`, `ghostty`, `zed`, `obsidian`, `bitwarden`, `bruno`, `github`, `slack`, and `telegram`. Verified upstream is faster for 14/24 casks, averages 1.02x, and is effectively parity weighted at 0.99x while preserving per-phase timing data for the slower cases.
- **Verified source archive cache** — source-archive installs now reuse an existing cached archive when its SHA256 matches the resolved metadata, avoiding repeated downloads for verified upstream formula reinstalls.
- **Warm upstream formula reinstalls use cached metadata** — verified upstream binary and bottle formulae cache their resolved formula metadata per registry channel. Binary formulae also save and restore relocated keg snapshots keyed by source SHA256. Warm beta-registry reinstall benchmarks improved from `fd` losing to Homebrew (118 ms vs 22 ms) to `fd` slightly ahead (19.64 ms vs 21.45 ms), while `actionlint` improved to 19.74 ms vs 153.79 ms. Generated bottle formula smoke benchmarks now show `hello` at 453.57 ms vs 460.54 ms cold package cache and 19.57 ms vs 19.91 ms warm cache.
- **Shimmed `yt-dlp` installs benchmark faster than Homebrew, zerobrew, and prior nanobrew** — local same-path testing with Homebrew auto-update disabled measured cached reinstall of `nb install --shims yt-dlp` at 423.7 ms versus `brew install yt-dlp` at 18.901 s, or 44.61x faster. The already-installed no-op path now averages 41.4 ms over 10 runs versus Homebrew at 930.3 ms, about 22.5x faster. The sandboxed macOS Actions manager comparison measured current nanobrew v0.1.192 at 48.8 ms target reinstall / 5.8 ms no-op, nanobrew v0.1.191 at 3385.2 ms / 3183.7 ms, Homebrew 5.1.7 at 5827.7 ms / 916.9 ms, and zerobrew v0.2.1 at 1830.7 ms / 1083.2 ms.
- **Formula dependency resolution avoids full registry parses** — upstream formula lookup now scans the active registry JSON for the requested token and parses only that record, then caches the resolved formula. With generated dependency-closure records, `nb deps node` improved to 0.47 s on first upstream-cache fill and 0.03 s warm, versus 0.85 s for the Homebrew metadata fallback in the local comparison.

### Changed
- **Upstream registry scaling direction** — documented the speed-first registry shape: hosted resolved install locks, Zig local caching, and fallback to live metadata only when a token is not covered.
- **Beta-safe rollout policy** — documented stable vs beta binary and registry channels so experimental resolver work can soak without changing behavior for regular users.
- **Top-100 expansion workflow** — documented the methodical path to 100/100 coverage: measure coverage, classify gaps, implement one resolver class, generate records, smoke test through a beta registry URL, benchmark actual installs, run the promotion gate, then promote stable.

### Fixed
- **Cask install failures now fail the command and CI benchmark** — `nb install --cask ...` now exits non-zero when cask metadata fetch, database open, unsupported-platform, or cask payload install fails instead of allowing benchmark runs to count failed installs as successes.
- **Transient native cask download failures are retried** — cask artifact downloads now retry bounded `FetchFailed` errors before failing, while checksum mismatches still fail immediately. Download errors are reported separately from SHA256 verification errors.
- **Formula seeder no longer misses single-file release archives** — release assets containing one top-level binary, such as `starship`, are preserved instead of being mistaken for a common root directory. The seeder also avoids auto-promoting platform-suffixed single binaries such as `yq_darwin_arm64` until formula artifact target names are supported.
- **Already-installed formula installs avoid full relocation work** — no-op `nb install` runs now check whether public links need repair before relinking, instead of rerunning relocation, text placeholder scans, framework sealing, and link writes for every installed dependency.
- **Relocated-store reinstalls preserve actual bottle revision directories** — fast reinstalls now detect the real version directory from the raw store entry before cloning a relocated snapshot, fixing packages whose formula version differs from the bottle directory, such as `yt-dlp` `2026.3.17_1`.
- **`nb remove --deb` is now cwd-independent** — deb removal stores absolute paths in `state.json`, and tolerates older databases that recorded relative paths by prepending `/` when reading. Previously, removing from a directory other than `/` would silently no-op.
- **Process-wide threadsafe Io accessor** — call sites that previously reached for `std.Io.Threaded.global_single_threaded.io()` now share a process-wide threadsafe accessor seeded from `main`, fixing intermittent races during parallel extract/store operations. The default initializer falls back to the singleton so tests and pre-`main` use still see a valid Io.
- **Five correctness fixes in the apt-replacement path**, including: native xz decompression that releases its `Decompress` buffer through `deinit` rather than the original pointer; threading the caller's `Io` into postinst execution so subprocess spawns use the initialized IO instead of the failing global allocator; serialized `patchelf` auto-install across parallel workers; an `apt-get update` before patchelf auto-install; and repair of literal `/home/linuxbrew/` paths plus a symlinked `etc/` for #269.
- **DB parser partial-allocation leaks** — `pushHistory`, the DB parser, and several install paths now cascade-free already-successful dupes when a later step fails, preventing slow leaks during retries.
- **`@@HOMEBREW_*@@` relocation for files >1 MiB and locale directories** — the placeholder rewriter no longer skips large files or locale subtrees that previously slipped through.
- **`nb upgrade` rejects unknown flags and uninstalled package names** instead of silently no-op'ing.
- **`nb services list` memory leaks plugged**.
- **`nb install` thread io through the install path** to fix Linux `CopyFailed` (#276).
- **HTTP User-Agent override** — nanobrew now overrides Zig's default User-Agent instead of appending to it, so requests no longer leak `zig/0.16.0 (std.http)` to upstreams (#258).

### Known issues
- **`nb install --deb` exits with status 139 (SIGSEGV) on Linux even though files install correctly** — pre-existing since v0.1.190 and tracked under CI's `continue-on-error: true # Known Zig std.http.Client + musl TLS segfault`. The crash is in runtime/libc teardown after `main()` returns; install/extract/postinst all complete and files are present on disk. Reproducible cleanly under Apple `container`; usually masked in `tests/deb-parity.sh` by piping `nb` output through `tail`, which absorbs the signal. Tracked as a release-blocker for the next cycle. Workaround for Dockerfile users: pipe through `tail` or wrap in `( … ) || true` so a downstream `RUN` step doesn't fail.

### Release artifacts
- **macOS arm64 + x86_64 tarballs are signed (Developer ID Application: Rachit Pradhan, WWP9DLJ27P), hardened-runtime, and notarized via Apple's notary service.** Notary submission IDs `aa0dfb8f-47d1-4079-bff4-4907352cc116` (arm64) and `782b6fa4-03e5-4e50-8b95-2a95d75abc0c` (x86_64). Gatekeeper fetches the notarization ticket online on first run, so browser downloads no longer prompt as "unidentified developer".

### Coverage Planning
- **Top-100 formula and cask coverage completed** — generated and curated resolved records move formulae from 11/100 to 100/100 covered and casks from 18/100 to 100/100 covered. The latest local coverage run reports 5,125,336 / 5,125,336 formula installs and 1,609,375 / 1,609,375 cask installs covered in the top-100 30-day analytics sets.
- **Tap/manual gap closure** — the final top-100 formula gaps are covered by resolved records for `anomalyco/tap/opencode`, `hashicorp/tap/terraform`, `norwoodj/tap/helm-docs`, `steipete/tap/gogcli`, and `wix/brew/applesimutils`; the final cask gaps are covered by generated artifact support plus curated resolved tap records.

## [0.1.192] - 2026-04-21

### Fixed
- **Cask DMG installs failed with `error.MountFailed` / `error.ExtractFailed` after download** — the cask installer used Zig's static `std.Io.Threaded.global_single_threaded.io()` for `hdiutil`, `cp`, `unzip`, `tar`, checksum reads, and cask downloads. On Zig 0.16 that global IO is backed by a failing allocator, so `std.process.run` could fail before spawning `hdiutil` and surface as `error.MountFailed`. Cask install/remove now receive the initialized process IO from `main`, and cask downloads use the same IO-backed HTTP client. Verified with Raycast, Google Chrome, and Firefox casks. (#242)
- **Intel macOS release smoke coverage** — the v0.1.191 x86_64 release artifact could segfault at startup after hardened-runtime signing, and it was built with `minos 13.0` despite a macOS 12.7.6 report. The macOS release path now builds x86_64 as `x86_64-macos.12.0`, rejects newer x86 deployment targets, and runs the signed x86 usage path through Rosetta before packaging. (#243)

## [0.1.191] - 2026-04-20

### Added
- **macOS release notarization** — release tarballs for `darwin-arm64` and `darwin-x86_64` are now signed with a Developer ID Application certificate under the hardened runtime and notarized by Apple. Gatekeeper fetches the notarization ticket online on first run, so downloads via browser no longer prompt as "unidentified developer". Closes #118 for macOS consumers (Sigstore/cosign remains a separate option for cross-platform provenance). (#118, #228)
- **`nb where <pattern>`** — new diagnostic subcommand that aggregates three views for a given pattern: installed kegs/casks/debs that match, files in `$PREFIX/{bin,lib,opt}` that match, and Homebrew index hits. Replaces the common `nb list | grep X; ls $PREFIX/lib/ | grep X; nb search X` pipeline. (#228)
- **`scripts/notarize-macos.sh`** — local notarization helper that uses the `codedb-notary` keychain profile. Used for one-off releases and for reproducing CI behavior locally when CI secrets are unavailable. (#228)
- **`nb info <formula>` — rich output** — formula info now prints description, homepage, license, bottle/source URL + sha256, dependencies, build dependencies, and caveats (mirroring `nb info --cask`). Bottled formulae are tagged `(bottled)`; source-only formulae tag the URL as `(source)`. `Formula` struct gains `homepage` and `license` fields parsed from the Homebrew API. (#230, #231)

### Fixed
- **Python (and other framework-bundled formulae) crashed on `dlopen` with `Invalid Page` / `Code Signature Invalid`** — the Mach-O relocator only re-signed binaries it rewrote with `install_name_tool`, leaving every other Mach-O with whatever (often broken) signature the upstream bottle shipped. `install_name_tool` removes signatures unconditionally on invocation, and `*.framework` bundles carry a sealed-resource hash that invalidates on any nested file change. Additionally, the batch `codesign` call had a 4 KiB stdout capture limit that SIGPIPEd the subprocess mid-batch on packages with many Mach-O files (e.g. `python@3.14`'s 76 `.so` plugins), leaving most files unsigned. Now every Mach-O file in a keg is ad-hoc re-signed after relocation, and every `*.framework` bundle gets a final `codesign --deep` pass after `replaceKegPlaceholders` finishes all text-file rewrites. Fresh cold install of `python@3.14` went from **60/76 broken `.so`** + invalid framework + SIGKILL on `import sqlite3` to **0/76 broken** + valid framework + all imports succeed. (#239)
- **`nb outdated` and `nb upgrade` leaked heap memory every run** — `getOutdatedPackages` duped three per-item strings (`name`, `old_ver`, `new_ver`) without ever freeing them, and the chained `alloc.dupe … catch continue` construction could leak earlier allocations when a later dupe or the final `result.append` failed. `Outdated` struct gains a `deinit` method; both callers now free each item before freeing the list; partial-allocation failure paths cascade-free already-successful dupes. (#234, #236)
- **`nb info <alias>` leaked the parsed `Formula` on every invocation** — `runInfo` captured the `fetchFormula` result but never called `deinit`, so every field duped by `parseFormulaJson` (`bottle_url`, `bottle_sha256`, `dependencies`, `caveats`, …) leaked on exit. `defer f.deinit(alloc)` added immediately after the fetch; `nb info python` went from 22 DebugAllocator leaks to 0. New regression tests cover the alias parse + deinit round-trip under the leak-detecting `testing.allocator`. (#235, #237)

### Performance
- **`nb leaves` 10 s → under 1 s** on a typical developer install with ~100 packages. The command was issuing sequential `fetchFormula` calls per installed keg with no shared HTTP client, plus doing O(n³) membership scans via nested `for (kegs) |other|` loops. Now uses a bounded work-stealing thread pool (`@min(kegs.len, 8)` workers, each owning a persistent `std.http.Client`) for parallel metadata fetch, and a `StringHashMap(Keg)` for O(1) membership lookups. Output order preserved. (#232, #238)
- **Streaming JSON parse for search + alias lookup** — `nb search` and formula alias resolution use `std.json.Scanner` with `skipValue()` on ignored keys instead of materializing the full 29.5 MB `formula.json` / 14.2 MB `cask.json` into a `std.json.Value` tree. `nb search curl` drops from 190 ms to 106 ms (1.80×); `nb info python` drops from 168 ms to 100 ms (1.68×). No behavior change. (#229)
- **Dependency resolver reuses one HTTP client per worker thread** — the BFS parallel branch in `DepResolver` previously spawned one thread per frontier item, each creating a throwaway `std.http.Client`. Now runs a bounded work-stealing pool (`@min(batch_size, 8)` threads) where each worker keeps a persistent `std.http.Client` and pulls items via an atomic index. Cold `nb install graphviz` (15 deps): resolver phase drops from ~3123 ms to ~1766 ms (~43% faster). Improvement scales with frontier size. (#233, #240)

### Changed
- **Dependency resolver wording** — release copy now says `O(1) resolver queue` instead of implying whole-graph dependency resolution is constant time.

## [0.1.082] - 2026-04-01

### Fixed
- **macOS self-update downloads** — `nb update` now requests the actual macOS release asset names (`nb-<arch>-apple-darwin.tar.gz`) instead of the non-existent `...-darwin.tar.gz` variant. This fixes checksum-download failures on released macOS builds. (#99)

### Changed
- Release notes and landing-page version metadata were rolled forward for the self-update patch release.

## [0.1.081] - 2026-04-01

### Fixed
- **Installed-state drift** — `nb install <formula>` now reconciles already-present kegs back into `state.json`, including the fully-up-to-date path where nothing new is installed. This fixes cases where a package existed in `Cellar` but `nb list` / `nb remove` still treated it as missing. (#97)

## [0.1.080] - 2026-04-01

### Fixed
- **Tap cask installs from third-party repos** — `nb install --cask user/tap/cask` now resolves and parses casks directly from tap repositories. (#92)
- **Tap formulas stored at repo root** — third-party taps that place formula `.rb` files at the repository root now work in addition to `Formula/` layouts. (#94)
- **Linux ELF interpreter relocation** — placeholder interpreters like `@@HOMEBREW_PREFIX@@/lib/ld.so` now resolve to the real path before falling back to architecture-based system linker detection. (#89)
- **Homebrew formula checksum drift** — release formula checksums were corrected to match the live `v0.1.079` release assets. (#93)
- **macOS script package installs** — runtime dependencies from `uses_from_macos` are now resolved on macOS, fixing Python-backed installs like `awscli` in smoke tests.
- **Test runner coverage** — `zig build test` now completes and exercises the full root test set instead of silently missing API coverage.

### Changed
- Release branch now carries the current `codedb.snapshot` alongside the integrated issue-fix set.
- Smoke integration checks now print actionable diagnostics when a script-package install fails on CI.

## [0.1.076] - 2026-03-27

### Fixed
- **Python framework dylib crash** — Mach-O relocator now resolves symlinks in `Python.framework/`, fixing `_Py_Initialize symbol not found` for all Python-dependent packages (gyb, aws, pip3, etc.). (#65)
- **Third-party tap installs** — `nb install mongodb/brew/mongodb-community` now works: added `Hardware::CPU.intel?`/`else`/`end` parsing, filename version extraction (`-8.2.6.tgz`), and `prefix.install Dir["*"]` semantics for pre-built packages. (#68)
- **`--casks` silently ignored** — `--casks` (plural, Homebrew convention) now accepted as alias for `--cask`. Unknown flags error instead of being silently dropped. (#71)
- **`nb update` failed** — v0.1.075 release was missing build artifacts; now uploaded with SHA256 checksums. (#66)
- **Tap formula silent success** — `nb install user/tap/formula` now errors clearly when formula not found, instead of "Already installed (0 packages)". (#68)

### Added
- **`nb reinstall <pkg>`** — removes then reinstalls a package. (#73)
- **`NANOBREW_BOTTLE_DOMAIN`** / **`NANOBREW_API_DOMAIN`** env vars — override bottle and API mirrors for users behind proxies or in regions with limited GitHub access. Also supports `HOMEBREW_BOTTLE_DOMAIN` / `HOMEBREW_API_DOMAIN`. (#74)
- **Linux migrate path** — `nb migrate` now searches `/home/linuxbrew/.linuxbrew/` on Linux. (#72)
- **`:recommended` / `:optional` deps skipped** — tap formula parser no longer treats recommended dependencies as required.

## [0.1.075] - 2026-03-26

### Fixed
- **`nb install r` broken** — placeholder walker skipped symlinked scripts (e.g. `bin/r` → `bin/R`), leaving `@@HOMEBREW_CELLAR@@` unreplaced. Walker now resolves and processes symlink targets. (#62)
- **Cask install silent failure** — `nb install --cask firefox` reported success but left empty directories. Installer now validates the `.app` exists in the mounted DMG before copying and returns `error.ArtifactFailed` instead of silently continuing. (#60)
- **Placeholder early-exit bug** — probe check used fixed `512` instead of actual bytes read, risking skipped files on short reads.

## [0.1.067] - 2026-02-16

### Added
- **`nb nuke`** — completely uninstall nanobrew and all installed packages. Removes `/opt/nanobrew` and `~/.local/bin/nb`. Requires typing `yes` to confirm (or `--yes` to skip). Also available as `nb uninstall-self`.
- **Tap-aware `nb remove`** — `nb remove steipete/tap/sag` now works (resolves the tap ref to the short package name automatically).

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
