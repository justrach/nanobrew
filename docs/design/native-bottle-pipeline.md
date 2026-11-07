# Native Bottle Pipeline — design doc

Status: **draft**, scoping only — no implementation in this doc.
Author: post-v0.1.193 audit pass, 2026-05-10.
Tracks: a future "nanobrew without Homebrew" milestone (no GH issue yet — open one when this doc lands).

---

## Goal

Today, `nb install <formula>` materializes bottles from
`ghcr.io/v2/homebrew/core/<name>/blobs/sha256:<digest>`. The metadata
arrives via the Homebrew formula API; the binaries arrive from
Homebrew's GHCR org. Nanobrew's claim of being "native and fast" is
true for the *runtime* (Zig pipeline, COW copy, native fetch
since v0.1.193), but the *supply chain* is still Homebrew end-to-end.

The goal is a credible, gradual path to **bottles built and hosted by
nanobrew**, with no daily dependence on Homebrew's infrastructure.

Non-goals:

- Forking `homebrew-core` and maintaining 7,000+ formula recipes
  ourselves. We continue to consume the formula DSL from
  Homebrew/upstream sources — only the *binary distribution* is
  replaced.
- Replacing the `homebrew_api` resolver class for unknown packages.
  It stays as the long-tail fallback.
- A new formula format. The existing upstream registry schema
  (`registry/upstream.json`) is rich enough for our purposes.

---

## What we already have

Before designing anything new, the existing pieces this plan rides on:

| Piece | File | What it does |
|---|---|---|
| Upstream registry runtime | `src/upstream/registry.zig` (1416 lines) | Resolves a package token to `(url, sha256, deps)` from a typed record; tries `homebrew_bottle`, `github_release`, `vendor_url`, `homebrew_api` (fallback) in order. |
| Embedded registry snapshot | `src/upstream/registry_default.json` (18,380 lines) | 256 formula + 103 cask records. Loaded with `@embedFile`. |
| Hosted registry channel | `registry/upstream.json` on `main` branch | Stable channel; released binaries fetch this without needing an update. Beta channel via `NANOBREW_UPSTREAM_REGISTRY_URL`. |
| Per-token cache | `/opt/nanobrew/cache/api/upstream-formula-<token>.json` | Avoids reparsing the full registry on warm installs. |
| Native fetch | `src/net/fetch.zig` | Bottle download with redirect following, SHA verification, gzip auto-decompress. After v0.1.193 also handles UA-gated CDNs (#258). |
| Store-relocated cache | `/opt/nanobrew/store-relocated/<sha256>/` | Already-relocated keg snapshots, keyed by source SHA. Reused across machines if you copy the dir. |
| Worker | `worker/src/index.js` at `nanobrew.trilok.ai` | Cloudflare Worker serving the install script. **No bottle proxying yet.** |

The thing the design needs to do is plug into the existing
`registry.zig` resolver order — not replace it.

---

## Phasing

### Phase 1 — bottle proxy + URL ownership

**Goal:** all bottle downloads flow through a `*.nanobrew.<domain>`
URL, even though the bytes still come from Homebrew's GHCR. Zero
build infrastructure required. First-class telemetry and CDN
ownership.

**Concrete pieces:**

1. New worker route on the existing `worker/` deployment:
   `bottles.nanobrew.trilok.ai/v1/<formula>/<sha256>` (or similar).
   On request, fetches `ghcr.io/v2/homebrew/core/<formula>/blobs/sha256:<sha>`,
   streams to client, caches in Cloudflare R2 keyed by `<sha>`.
2. New resolver class in `src/upstream/registry.zig`:
   `nanobrew_bottle` that produces a `bottles.nanobrew.<domain>` URL
   from `(formula, sha256, version, platform_keys)`. Same SHA
   verification path as today.
3. Generator script `scripts/generate-nanobrew-bottle-records.mjs`
   that takes the existing `homebrew_bottle` records and emits
   `nanobrew_bottle` records with rewritten URLs. SHAs unchanged
   (same bytes, different host).
4. Resolver order in `registry.zig` becomes:
   `nanobrew_bottle` → `github_release` → `vendor_url` → `homebrew_bottle` → `homebrew_api`.
   So registries that ship `nanobrew_bottle` records use them; everything
   else stays on the existing fallbacks.
5. Beta registry on `NANOBREW_UPSTREAM_REGISTRY_URL=...beta.json`
   for soaking. Once green, promote to `registry/upstream.json` on
   main.

**What this buys us:**

- We learn how much bandwidth the long tail actually uses (telemetry
  per package).
- ghcr.io can change auth, rate limit, deprecate, or disappear
  without breaking nanobrew users; we just point the worker
  somewhere else.
- We can later swap individual `<sha>` blobs in R2 with self-built
  bottles — the URL stays the same, so old `nb` versions in the
  field keep working.
- Cost is bounded: R2 storage is cheap; egress through a CF Worker
  is free up to the worker's plan limits.

**What it does NOT buy:**

- We are still functionally tied to Homebrew's bottle pipeline. If
  Homebrew breaks or changes their CI, our cache fills with broken
  bottles too.
- macOS notarization questions are deferred — the bytes are still
  Homebrew's.

**Cost estimate (rough):**

- Cloudflare Workers paid plan if free tier breaks: $5/mo + usage.
- R2 storage: $0.015/GB/mo. Holding the top 1000 bottles (~50 GB)
  is ~$0.75/mo. Egress is free on R2.
- Total: trivial, single-digit dollars/month at small scale.

**Effort estimate:** 1–2 weeks of focused work.

---

### Phase 2 — self-built bottles for top-N

**Goal:** for a small, curated set of packages, the bottle is built
by nanobrew CI on nanobrew's runners and uploaded to nanobrew's R2.
No Homebrew bytes in the path. Proves the pipeline end-to-end.

**Curated starter set (~10 packages):** `tree`, `jq`, `wget`,
`ripgrep`, `htop`, `fd`, `bat`, `fzf`, `tmux`, `zstd`. Picked because
they are:

- Small (single binary, few deps).
- Permissively licensed.
- Have stable upstream release tarballs (no Homebrew-only patches
  required).
- High-traffic enough to validate the flow.

**Concrete pieces:**

1. New CI matrix in `.github/workflows/build-bottles.yml` (separate
   from the existing release workflow). For each package and each
   platform `(arm64-darwin, x86_64-darwin, aarch64-linux, x86_64-linux)`,
   compile from upstream source, archive, compute SHA, upload to R2.
2. Bottle layout that matches what `cellar/cellar.zig` and
   `elf/relocate.zig` expect today. The relocator already handles
   `@@HOMEBREW_PREFIX@@` placeholders; we adopt the same convention so
   no install-time code changes.
3. Phase 1's `nanobrew_bottle` resolver class stays the same. The
   record now points to `bottles.nanobrew.<domain>/v1/built/<formula>/<sha>`
   (different prefix from the proxy path).
4. Beta soak on the same beta registry channel, then promote.

**Open questions for phase 2:**

- **macOS code signing** — Homebrew bottles are not code-signed, but
  Apple's notarization story for command-line binaries is fuzzy.
  Decide: ship unsigned (current state), Developer ID sign without
  notarization, or full notarization. The same constraint already
  affects nb itself today (`scripts/notarize-macos.sh`).
- **Linux libc target** — Homebrew Linux uses glibc and pins a
  specific Ubuntu LTS as the build host. We should match exactly so
  bottles work on the same range of distros. Or commit to a separate
  range (e.g. musl-only via Zig's cross-compile, like our own
  `nb-x86_64-linux` builds) and document it.
- **Source-archive caching** — upstream tarballs disappear (yt-dlp
  releases, GitHub deletions). Worth caching them in R2 too,
  separately from built bottles.
- **Build determinism** — Homebrew's bottles aren't bit-for-bit
  reproducible across runs. We can do better with a fixed Zig
  toolchain, but this is its own rabbit hole.

**Effort estimate:** 3–6 weeks for the first 10 packages, including
soak. Each subsequent batch of 10 is faster as the pipeline
stabilizes.

---

### Phase 3 — full coverage (long tail)

Out of scope for this doc. Numbers for context:

- Homebrew has ~7,200 formulae and ~6,800 casks.
- Top-100 formulae cover 5.1M / month of Homebrew's analytics
  installs (per `docs/upstream-registry.md`). Top-100 casks cover
  1.6M / month.
- A reasonable **coverage milestone** is the top-500, not full
  parity. Top-500 likely covers 90%+ of real-world installs.

Phase 3 only makes sense after Phase 2 has proven the pipeline on
the small set. Decisions about formula source forking, alternative
recipe formats, and full-time build infrastructure come up here, not
sooner.

---

## Risks and trip wires

- **Upstream license terms.** Some Homebrew formulae include
  vendor-provided binaries with redistribution restrictions
  (anything with a Java SDK in the dep tree, some commercial
  fonts, etc.). Phase 1's pure proxy is exactly as legal as a
  user `curl`-ing Homebrew themselves. Phase 2 has to enumerate
  which packages we are allowed to redistribute as a third party.
- **Homebrew etiquette.** A bottle proxy that hammers `ghcr.io`
  could attract attention. Mitigation: aggressive R2 caching means
  each (formula, sha) tuple is fetched at most once per cache
  generation. Set proper `User-Agent: nanobrew/<ver>` so they can
  identify and contact us if it becomes a problem.
- **Drift between proxied and built bottles.** Phase 1 and Phase 2
  bottles share the `nanobrew_bottle` resolver class. The SHAs
  must differ (Homebrew bytes vs our bytes), which means we either
  need a discriminator in the record (proxy vs built) or always
  re-derive the SHA from our built artifact and trust the resolver
  to use whichever URL is in the record. The latter is simpler;
  recording is a one-way door.
- **Telemetry policy.** The worker will see per-formula,
  per-machine-IP download patterns. Existing telemetry doc:
  `nb telemetry` command. Make sure phase 1 doesn't bypass that
  opt-out.

---

## What I'm NOT recommending

For the record, options I considered and rejected:

- **Forking homebrew-core.** Maintenance burden is enormous and
  Homebrew's rate of formula updates is faster than any small
  team can keep up with. Stay on their formula DSL, replace only
  the binary plane.
- **A new formula format.** Same reason — the upstream registry
  schema (`registry/upstream.json`) is already what we want.
  Adding "yet another" format fragments the ecosystem.
- **Full notarization day one.** Ship Phase 1 unsigned (matches
  Homebrew today). Address signing as a deliberate Phase 2.5
  decision once we control the bytes.
- **Self-hosted infrastructure.** A serverless Worker + R2 setup
  is two orders of magnitude cheaper than running our own build
  fleet. Phase 2 is the earliest point we need persistent compute,
  and even then GitHub Actions runners are sufficient until top-500.

---

## Suggested next steps

- File a tracking issue: "native bottle pipeline (phases 1–3)".
- File a phase 1 issue with the worker route + resolver class +
  generator script as concrete sub-tasks.
- Decide on a domain (`bottles.nanobrew.dev`?
  `bottles.nanobrew.trilok.ai`?) and provision the R2 bucket.
- Sanity-check phase 1 traffic projections from existing telemetry,
  if any. If the long tail of installs is sparse, even Phase 1's
  R2 footprint is essentially free.
- Reach out to Homebrew maintainers before turning the proxy on at
  scale — a 30-second message about identifiable User-Agent and
  caching behavior preempts a lot of awkwardness.
