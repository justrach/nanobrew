<p align="center">
  <img src="assets/logo.png" alt="nanobrew logo" width="200">
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/25937" target="_blank"><img src="https://trendshift.io/api/badge/repositories/25937" alt="justrach%2Fnanobrew | Trendshift" style="width: 250px; height: 55px;" width="250" height="55"/></a>
</p>

# nanobrew

A fast package manager for macOS and Linux. Written in Zig. Native install pipeline for the top 100 Homebrew formulae and top 100 casks (no `brew`, no Ruby), with verified Homebrew fallback for everything else and native `.deb` support for Linux/Docker.

## Why nanobrew?

- **Fast warm installs** — already-installed no-ops return in milliseconds (5.8ms on the v0.1.192 sandboxed `yt-dlp` benchmark)
- **Parallel downloads** — all dependencies download and extract at the same time
- **No Ruby runtime** — single static binary, instant startup
- **No auto-update** — `nb install` just installs; self-update is explicit via `nb update`
- **No quarantine** — cask installs skip `com.apple.quarantine`, so apps open without Gatekeeper prompts
- **Native installs** — top 100 formulae and top 100 casks install without Homebrew, Ruby, or `brew` subprocess (v0.1.192)
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
| **wget** (6 deps) | 3.935s | 5.502s | 0.587s | **3.211s** | **0.027s** |

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

# Or build from source (needs Zig 0.16.0+)
git clone https://github.com/justrach/nanobrew.git
cd nanobrew && ./install.sh
```

### Upgrading

```bash
# v0.1.193 and later: self-update works in one call
nb update
```

If you're on **v0.1.192 or older** and `nb update` errors with
`could not download SHA256 checksum`, the self-updater on your installed
binary can't reach past a redirect-chain bug in its native HTTP client
(fixed in v0.1.193). Re-run the installer once to get unstuck, then
`nb update` will work for all future releases:

```bash
curl -fsSL https://nanobrew.trilok.ai/install | bash
```

The same bug also affected exactly v0.1.190 via a different code path
(file-naming bug in the extract step); the same one-liner unsticks it.

## Usage

### Basics

```bash
nb install tree               # install a package
nb install ffmpeg wget curl   # install multiple at once
nb install --shims yt-dlp     # expose yt-dlp, keep dependency tools private
nb remove tree                # uninstall
nb list                       # see what's installed
nb info jq                    # show package details
nb search ripgrep             # search formulas and casks
```

### Installing a specific version

Pin any Homebrew formula to an exact version with `name@version`:

```bash
nb install hexyl@0.17.0       # install exactly hexyl 0.17.0
nb install wget@1.21.3        # install exactly wget 1.21.3
```

nanobrew resolves the requested version from the bottles Homebrew keeps in its
container registry. Versioned installs are **auto-pinned** so a later
`nb upgrade` won't replace your chosen version — run `nb unpin <pkg>` to allow
upgrades again.

Notes and limitations:

- Works for **Homebrew formulae** (macOS + Linux bottles). Casks (`--cask`) and
  deb packages (`--deb`) don't support version pinning yet.
- If the exact version isn't available as a bottle for your platform (old
  bottles can be garbage-collected), nb lists the available versions and points
  you at the latest instead of guessing.
- Dependencies are resolved against the **latest** formula, not the historical
  one — fine for typical CLI tools; see
  [`docs/design/versioned-install.md`](docs/design/versioned-install.md) for
  details.

Homebrew's **versioned formulae** (separate packages whose name contains `@`)
also work as before, and take precedence over version pinning:

```bash
nb install python@3.11        # the python@3.11 formula (distinct from python)
nb install node@22            # the node@22 formula
nb install openssl@3          # the openssl@3 formula
```

Related version controls once a package is installed:

```bash
nb pin tree                   # hold tree at its current version (skip upgrades)
nb unpin tree                 # allow upgrades again
nb rollback tree              # revert to the previously installed version
```

### Shimmed Installs

```bash
nb install --shims yt-dlp
```

Shimmed installs are an experimental link mode for packages whose dependencies ship command-line tools you do not want exposed globally. The requested formula gets wrapper shims in `/opt/nanobrew/prefix/bin`; dependency executables are kept out of `prefix/bin` and are only added to that wrapper's private `PATH`. This keeps commands like `deno` or `python` available to the requested tool without making those dependency executables first-class shell commands. You can also enable this mode for formula installs with `NANOBREW_SHIMS=1`.

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

Cask upgrades currently support ZIP/tar archives and direct binaries with app
or binary artifacts. The replacement is staged with all companion files before
activation. App destinations, binary links, and installed state commit together.
Failures roll back immediately; interrupted upgrades recover on the next command.
Old payloads are removed only after commit. Disk images, `.pkg`/script installers,
and other artifact rules are reported separately as unsupported and kept intact.

Cask executable probes share a ten-second package budget. A cask declaring one
binary can use the remaining budget for cold startup; multiple binaries retain
two-second slices. Timeouts leave runtime health unverified and include the
command and elapsed time in both installation and `nb doctor --probe` output.

As of v0.1.192, the top 100 casks install through nanobrew's native pipeline — no `brew` subprocess, no Homebrew prefix, no Ruby. Native cask support covers apps, `.pkg`, fonts, binaries, suites, copied artifacts, installer scripts, `.tar.xz`, and extensionless vendor URLs. Casks outside the top 100 still fall back to the verified Homebrew path.

### Linux / Docker (deb packages)

```bash
nb install --deb curl wget git    # install from Ubuntu/Debian repos
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

### Download Telemetry

```bash
nb telemetry status
nb telemetry off
nb telemetry on
```

nanobrew sends anonymized, best-effort download timing events to `https://backend.trilok.ai/v1/telemetry/system`. This helps prioritize which packages and casks should get native nanobrew support first, based on real download/install demand and slow paths.

The exact event shape is:

```json
{
  "schema": 1,
  "source": "nanobrew",
  "event": "download",
  "os": "macos",
  "arch": "arm64",
  "ram_gb": 128,
  "cpu_count": 10,
  "operation": "download",
  "target_kind": "formula",
  "target_name": "uv",
  "duration_ms": 120,
  "download_bytes": 33000000,
  "success": true
}
```

It does not send URLs, paths, hostnames, usernames, IPs, user IDs, full package lists, or command history. `target_name` is only a package-like token such as `uv`, `firefox`, or `owner/tap/pkg`. You can opt out with `nb telemetry off`, `NANOBREW_NO_TELEMETRY=1`, or `NANOBREW_TELEMETRY=0`.

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

Dependency ordering walks the explicit formula graph and topologically sorts it in `O(V+E)`. The `O(1)` resolver improvement in v0.1.190 refers to queue dequeue during that sort, not solving arbitrary version constraints.

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

## Contributing

Follow [CONTRIBUTING.md](./CONTRIBUTING.md) for all future issues and PRs.

The short version:

- every PR must be tied to an issue
- every fix must show red-to-green proof
- every non-trivial branch must be rebased onto current `main`
- PRs over 500 changed lines will usually be rejected unless they are clearly justified, tightly scoped, and good enough to survive strict review


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

## All commands

| Command | Short | What it does |
|---------|-------|-------------|
| `nb install <pkg>` | `nb i` | Install packages |
| `nb install --cask <app>` | | Install macOS apps |
| `nb install --deb <pkg>` | | Install .deb packages (Linux/Docker) |
| `nb install user/tap/formula` | | Install from a third-party tap |
| `nb remove <pkg>` | `nb ui` | Uninstall packages |
| `nb remove --deb <pkg>` | | Remove a .deb package (Linux/Docker) |
| `nb list [--versions\|--names]` | `nb ls` | List installed packages, version history, or names-only output |
| `nb leaves [--tree]` | | List installed formulae with no dependents |
| `nb where <pattern>` | `nb wh` | Show installed kegs, prefix files, and index hits matching pattern |
| `nb info <pkg>` | | Show package details |
| `nb info --cask <app>` | | Show cask details |
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
| `nb telemetry [status\|on\|off]` | | View or change telemetry opt-in |
| `nb nuke` | | Remove all of nanobrew's state |
| `nb migrate` | | Import packages from Homebrew |
| `nb update` | | Self-update nanobrew |
| `nb autoupdate enable [--upgrade]` | | Opt in to daily updates at 03:00 |
| `nb autoupdate status` / `disable` | | Inspect or remove the user schedule |
| `nb version` / `--version` / `-v` | | Print the installed version |
| `nb init` | | Create directory structure |
| `nb help` | | Show help |

See [CHANGELOG.md](./CHANGELOG.md) for version history.

### Proxy environments

When `http_proxy`, `https_proxy`, or `all_proxy` is configured, nanobrew uses the
system `curl` executable for HTTP transport. Uppercase variants are accepted;
lowercase takes precedence. `HTTP_PROXY` is ignored in CGI environments
(`REQUEST_METHOD` is set). `NO_PROXY` / `no_proxy` bypass rules are applied on
redirects too. Credentials stay in the child environment or its stdin, not its
command-line arguments. HTTPS keeps certificate verification and cannot redirect
to HTTP. Without proxy settings, downloads use the native Zig HTTP client.

Install curl if proxy requests report `ProxyTransportUnavailable`. Corporate CA
certificates can be configured using curl's `CURL_CA_BUNDLE`. Proxy matching follows
[curl's documented environment rules](https://curl.se/docs/manpage.html#ENVIRONMENT).
POST downloads follow 301/302/303 as GET without forwarding form headers or
credentials; 307/308 are rejected rather than replaying the body.

### Opt-in scheduled updates

`nb autoupdate enable` schedules `nb update` daily at 03:00 local time.
`nb autoupdate enable --upgrade` also upgrades packages after a successful update,
using the newly installed executable. Nothing is scheduled by installation.
Use `nb autoupdate status`, `nb autoupdate disable`, or `nb autoupdate run [--upgrade]`.

macOS uses a per-user LaunchAgent and writes logs under
`~/Library/Logs/nanobrew`. Linux uses a systemd user timer under
`$XDG_CONFIG_HOME/systemd/user` (default `~/.config/systemd/user`), with logs in
`journalctl --user -u nanobrew-autoupdate`. A running user service manager is
required; Linux timers catch up after a missed run. Keep the executable at the
path used when enabling the schedule, and re-enable after moving it. The scheduler
runs with your user's permissions and does not grant permission to update root-owned files.

### Install trust and evidence

`nb info <pkg>` reports checksum, source-review, and install evidence for the
exact version, platform, and artifact SHA-256. `nb doctor --probe <pkg>` checks
the installed payload and records local evidence. A probe verifies that an
executable loads and responds; it does not certify every feature or the absence
of malicious behavior.

```sh
nb install --trusted-only jq      # require tier 3, including dependencies
nb install ripgrep@trusted        # newest signed passing artifact for this platform
nb info ripgrep
nb trust attest ripgrep --output registry/attestations/ripgrep-linux.json
nb trust verify registry/trust-evidence.json
```

To require trust on subsequent installs, put `min_trust = 3` in
`/opt/nanobrew/config/config.toml`. Values 0 through 3 are accepted;
`NANOBREW_CONFIG` selects another file and `NANOBREW_MIN_TRUST` overrides the
setting. Tier 2 requires a matching source-reviewed artifact. Local Ruby and
APT/deb installs reject nonzero trust requirements because they do not yet
produce compatible evidence. Normal installs retain their existing policy,
except that fresh failure evidence selects a known working version when one
is available. Explicit version pins are not silently replaced.

Published evidence is an Ed25519-signed envelope containing a JSON payload and
hex signature. It is cached for six hours under the API cache directory and
expires after 30 days. Invalid signatures, changed checksums, other platforms,
and incompatible probe schemas cannot confer trust. An unavailable feed falls
back to still-valid cached evidence; without evidence, `@trusted` fails and
ordinary installs continue. Upstream revocations take precedence over install
success. Set `NANOBREW_TRUST_EVIDENCE_URL`, `NANOBREW_TRUST_EVIDENCE_CACHE`, and
`NANOBREW_TRUST_PUBLIC_KEY` only when deliberately choosing a different evidence
publisher. The public-key override changes who is trusted to approve artifacts.

The weekly **Trust evidence** workflow installs the packages in
`registry/trust-seeds.json` plus the top ten Homebrew analytics packages on
native macOS arm64/x86_64 and Linux aarch64/x86_64 runners. It opens a PR with
fresh signed observations. Maintainer attestations run the same probe, require
metadata to match the installed bytes, and produce reviewable records; they do
not publish themselves. Add reviewed records under `registry/attestations/`
and run the workflow to include them in the signed feed. The signing key lives
in the repository's `TRUST_SIGNING_KEY` Actions secret.

Install outcome telemetry requires explicit `nb telemetry on` (or
`NANOBREW_TELEMETRY=1`), even though legacy download telemetry defaults on.
`nb telemetry off` and `NANOBREW_NO_TELEMETRY=1` disable both. Outcomes contain
package, version, platform, checksum, install/probe results, probe schema, and
an artifact-specific hash derived from a random local secret. They contain no
hostname, username, filesystem paths, or identifier shared across packages.
The server uses the connection IP transiently for rate limiting; the outcome
database stores no IP addresses. Opted-in installs allow up to one second for
best-effort reports to finish before exit; disabled reporting adds no wait.
Records expire after 30 days. The public
aggregate exposes only counts, never reporter identifiers.

Field evidence requires at least 25 distinct successful reporters and a failure
rate below 2%. A failure rate of at least 2% among 25 or more reporters is failure
evidence. Repeated reports from one installation count once per artifact, with
failure winning conflicting reports during the retention window. Anonymous
reports are a reliability signal, not Sybil-resistant proof: resetting the local
secret can create another reporter. Field data can only promote artifacts whose
metadata was already collected by CI or reviewed by a maintainer; it cannot
supply new download URLs. Provenance remains visible as `ci`, `attested`, or
`field` in the signed feed.
