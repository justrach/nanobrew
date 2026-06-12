# nb-bottles — operating guide

How to run nanobrew's own bottle registry on GHCR. Everything lives under
`ghcr.io/justrach/nb-bottles/<package>`; public packages are free on GHCR
(storage and egress), so the running cost is $0.

Tooling: `scripts/bottles/nb_bottles.py` (stdlib-only Python, no deps).
CI: `.github/workflows/bottles.yml` (weekly mirror cron + manual dispatch).

```
ghcr.io/justrach/nb-bottles/<name>          one OCI repo per package
  blobs/sha256:<digest>                     the bottle tarball (what nb downloads)
  manifests/<version>.<platform>            tag that pins the blob against GC
```

Bottles are content-addressed: the `sha256` in a registry record is both the
download path and the integrity check, so a mirror that preserves digests is
transparently trustworthy — nb verifies the same hash either way.

---

## The two tiers

**Tier 1 — mirror.** Byte-identical copies of the Homebrew bottles already
pinned in `src/upstream/registry_default.json` (the 231 `homebrew_bottle`
records). Insurance against upstream GC/renames; no speed change. Digests are
unchanged, so the existing registry records work against the mirror via the
URL rewrite (below) with zero edits.

**Tier 2 — repackage.** Take a `github_release` record's upstream binaries
(gh, ripgrep, fd, bat, … — single-binary Rust/Go tools), re-layout them into
bottle form (`<name>/<version>/bin/<binary>`), and publish under our
namespace. These get the fastest install path nb has (blob cache → store →
COW materialize → link) and contain no Homebrew placeholders at all, so the
relocate phase does nothing. Each repackage prints the registry snippet with
the **new** digests — paste it into the registry to switch that package over.

Start list (permissive licenses, no dep closures): ripgrep, fd, bat, jq, gh,
fzf, hexyl, just, mise, uv, lazygit, git-delta, atuin, zoxide, eza,
hyperfine, dust, chezmoi, fastfetch, shellcheck. Defer the C ecosystem
(openssl, gettext, python — dep graphs + LGPL/GPL source-offer duties); the
Tier-1 mirror covers those.

---

## One-time setup

1. **Local pushes need a token with `write:packages`:**
   ```bash
   gh auth refresh -h github.com -s write:packages,read:packages
   ```
   (CI needs nothing — the workflow grants `packages: write` to
   `GITHUB_TOKEN`.)

2. **Visibility.** A package's first publish decides how painful this is:
   - **Published from CI (preferred):** packages created by `GITHUB_TOKEN`
     in a workflow are linked to this (public) repo and inherit its
     visibility — public from birth, nothing to click. Run the bulk mirror
     through the `bottles` workflow dispatch for exactly this reason.
     (Verify on the first CI-created package before trusting it for the
     fleet — GitHub has changed this behavior before.)
   - **Published locally (PAT):** lands PRIVATE, and there is provably no
     API to flip it — the REST PATCH 404s and GraphQL has no visibility
     mutation (probed 2026-06-12). One-time browser step per package:
     *github.com → profile → Packages → `nb-bottles/<name>` → settings →
     Change visibility → Public.*
   Until a package is public, anonymous pulls (i.e. `nb install`) fail with
   401; `verify` (below) detects exactly this and prints the flip URL.

3. The manifests carry `org.opencontainers.image.source` pointing at this
   repo, so packages appear on the repo's Packages page.

## Commands

All commands honor `GHCR_USER` (default `justrach`), `GHCR_REPO_PREFIX`
(default `nb-bottles`), `GHCR_TOKEN` (default: `gh auth token`).

```bash
# Tier 1 — mirror all pinned homebrew bottles (idempotent; re-runs skip
# existing blobs). Tries a cross-repo OCI mount first (instant), falls back
# to pull+push (~650 MB total for all 231 packages × 4 platforms, one-time).
python3 scripts/bottles/nb_bottles.py mirror
python3 scripts/bottles/nb_bottles.py mirror --only ansible,cmake --dry-run

# Tier 2 — repackage one github_release package and publish all platforms;
# prints the registry snippet to paste when done.
python3 scripts/bottles/nb_bottles.py repackage gh
python3 scripts/bottles/nb_bottles.py repackage ripgrep --no-publish  # build to dist/ only

# Push a single tarball by hand (rare; repackage normally does this)
python3 scripts/bottles/nb_bottles.py publish gh 2.91.0 macos-arm64 dist/gh-2.91.0.macos-arm64.tar.gz

# Add ANY Homebrew formula to the registry from the live API: builds the
# homebrew_bottle record (4 platforms, sha256 pins), --add appends it to
# registry_default.json, --mirror pushes its blobs to our namespace too.
python3 scripts/bottles/nb_bottles.py pin hexyl --add --mirror

# Prove a package is consumable: anonymous pull of every platform blob +
# digest verification. This is the "is it public and intact" check.
python3 scripts/bottles/nb_bottles.py verify ansible

# Print the registry snippet for a Tier-1 mirrored package (same digests,
# our URLs). For Tier-2, use the snippet repackage prints (new digests).
python3 scripts/bottles/nb_bottles.py record ansible
```

## CI (`.github/workflows/bottles.yml`)

- **Weekly cron** (Mon 04:23 UTC): full `mirror` run. Idempotent — only new
  pins (after `nb update-registry` bumps) actually transfer.
- **Manual dispatch**: `mirror` (optionally `--only`/dry-run) or `repackage`
  with a comma-separated package list; repackaged tarballs are also attached
  as a build artifact.

## How nb consumes the mirror

Two independent mechanisms:

1. **Whole-fleet redirect (Tier 1):** `NANOBREW_BOTTLE_DOMAIN` rewrites any
   `https://ghcr.io/v2/homebrew/core/<rest>` bottle URL:
   ```bash
   export NANOBREW_BOTTLE_DOMAIN="https://ghcr.io/v2/justrach/nb-bottles"
   nb install wget   # downloads identical blobs from our namespace
   ```
   Digests are unchanged, so sha256 verification passes untouched.

2. **Per-package registry records (Tier 2):** records whose
   `resolved.assets[].url` points at `ghcr.io/v2/justrach/nb-bottles/...`
   are fetched directly (nb's GHCR token logic is namespace-agnostic). Ship
   them in `registry_default.json` (embedded at build) and
   `registry/upstream.json` (fetched by `nb update-registry`).

## Routine operations

| Task | How |
|---|---|
| New pins after a registry refresh | wait for the weekly cron, or dispatch `mirror` |
| Add a Tier-2 package | `repackage <name>` → flip visibility public → `verify <name>` → paste snippet into registry |
| Upstream released a new version | re-run `repackage` after the registry's resolved version bumps (`nb update-registry` tooling) |
| Check a package end-to-end | `verify <name>`, then `NANOBREW_BOTTLE_DOMAIN=… nb install <name>` on a scratch machine |
| Storage hygiene | none needed — old blobs stay referenced by their version tags; delete old tags in the UI if you ever care |

## Rules of thumb

- **Never re-tag a different blob under an existing version tag.** Digests
  are the contract; a version bump is a new tag + new registry record.
- **Licensing:** the start list is MIT/Apache — redistribution is fine with
  the license text (upstream archives include it; tarballs we build keep only
  the binary, so link upstream in the package description if asked). If a
  GPL package (wget, gettext) ever moves to Tier 2, the mirror must point at
  a source-availability note. Tier-1 byte-identical mirroring of Homebrew's
  public bottles is the same act Homebrew itself performs.
- **Don't mirror what you don't pin.** The mirror follows
  `registry_default.json`; resist mirroring all of homebrew/core (7k
  formulae × versions) — it's free but unmanageable.
