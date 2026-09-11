# Trust Tiers — "works out of the box" tracking — design doc

Status: **implemented**. See the README section “Install trust and evidence” for
the signed envelope format, commands, configuration, telemetry privacy model,
and publication workflow. The sections below preserve the original design.
Author: post-v0.1.196 issues pass, 2026-06-12.
Tracks: the recurring class of issues where a package installs but doesn't
work (#286 missing PATH symlinks, #297 unrelocated binaries, #302 phantom DB
entries, #303 false-success casks, #305 checksum-failing POST casks, #307
wrong-arch versions, #311 phantom kegs) — versus packages that are *known* to
work because someone or something verified them end to end.

---

## Problem

nanobrew resolves packages from three metadata sources (verified upstream
registry → Homebrew API → tap parsing), but none of them answer the question a
user actually has: **"if I install this, will it work?"** The registry's
`verified: bool` means "the upstream source and checksum path were reviewed",
not "the installed artifact runs on your machine". Issues #308/#310 showed the
second-order failure: a registry pin that *was* verified goes stale, and the
trust marker quietly becomes a downgrade vector.

Separately, versioned installs (`nb install pkg@1.2.3`, since v0.1.195) mean
trust must be **per (token, version, platform)**, not per token: python@3.14.4
working says nothing about 3.14.5, and an arm64 success says nothing about
x86_64 (#307 is exactly this).

## Trust tiers

Tier is computed, never stored as a single field — it falls out of which
evidence exists for the (token, version, platform) triple:

| Tier | Name              | Meaning | Evidence source |
|------|-------------------|---------|-----------------|
| 0    | unknown           | metadata parsed, nothing verified | — |
| 1    | checksum-verified | artifact bytes match a published sha256 | Homebrew API / tap / registry (today's baseline — every install already requires it) |
| 2    | source-verified   | upstream source + domains + verification path reviewed by a human | registry record `upstream.verified` (today's `verified: bool`) |
| 3    | install-verified  | a real install of this exact version succeeded on this platform: artifacts landed, links resolved, binary executed | evidence channel (below) |

`nb info` prints the tier with its evidence date; `nb install --trusted-only`
(or config `min_trust = 3`) refuses below a threshold; plain `nb install`
behavior is unchanged.

## Evidence channel for tier 3

Three producers, one format:

1. **CI matrix runs** — a weekly workflow (same shape as `benchmark.yml`,
   which already installs top-N packages on macOS runners) installs the
   registry's seeded packages + top analytics packages, then runs the
   post-install probe (below). Output: signed `trust-evidence.json` published
   next to `registry/upstream.json` and fetched through the existing registry
   cache path (6h TTL, same env overrides).
2. **Maintainer attestation** — `nb trust attest <pkg>` after a manual
   verification; lands as a reviewed record in the published evidence file
   (same PR flow as registry seeding).
3. **Opt-in install telemetry** — nanobrew already ships anonymous download
   telemetry (`nb telemetry on|off`). Extend the event with install *outcome*
   (succeeded + probe result; no hostnames, no usernames — same privacy
   posture). Aggregated server-side; a version/platform becomes tier-3 from
   field data once distinct-success count ≥ N (e.g. 25) with failure rate
   < 2%. Field evidence is marked `source: "field"` vs `source: "ci"` /
   `"attested"` so consumers can weigh it.

### The post-install probe ("does it actually work")

Cheap, uniform, no package-specific scripting:

- formula: every declared binary in `prefix/bin` for the keg exists, is
  executable, and the dynamic loader can resolve it (run within a bounded package budget:
  `<bin> --version` || `<bin> version` || `<bin> --help`; accept exit 0/1/2 —
  the probe asserts "loads and runs", not CLI semantics). Executable attempts
  share one absolute deadline, within a ten-second package cap. Casks declaring
  one executable can spend the remaining package budget on cold startup; other
  executable probes retain two-second slices. Timeout, launch failure, and
  unsuccessful exit status are distinct diagnostics; a timeout never passes.
- cask: declared artifacts exist (`.app` bundle present, binaries symlinked),
  quarantine cleared, `codesign --verify` passes where applicable.
- both: the DB entry exists *and* the Cellar/Caskroom path exists (the #302/
  #311 phantom-entry class becomes a probe failure, not a doctor surprise).

`nb doctor --probe [pkg]` runs the same check on demand; the install path runs
it automatically and this is what feeds outcome telemetry.

## Version management tie-in

What exists already: `pkg@version` installs (auto-pinned), `pin`/`unpin`,
`rollback`, `outdated`, per-version kegs in the Cellar. Gaps this design
needs:

1. **`nb list --versions`** — show all installed kegs per token, mark the
   linked one.
2. **`nb switch pkg@version`** — relink an already-installed keg (`rollback`
   is the special case "switch to previous"). Cheap: kegs are already
   versioned; switch = unlink + link + DB update.
3. **Trusted-version resolution** — `nb install pkg@trusted` resolves to the
   newest tier-3 version for the platform; and when a plain install's version
   has *newer failing* tier-3 evidence, print a one-line warning naming the
   newest known-good version.
4. **Freshness vs. trust** — the #312 freshness check (live Homebrew API wins
   over a stale registry pin) gets a guardrail: if the live version has
   tier-3 *failure* evidence, prefer the newest tier-3 success and say why.
   Fresh beats stale; verified-working beats fresh-but-broken.

## Format sketch

```json
{
  "schema_version": 1,
  "generated": "2026-06-12T00:00:00Z",
  "evidence": [
    {
      "token": "ripgrep", "kind": "formula", "version": "14.1.1",
      "platform": "macos_arm64",
      "result": "pass", "probe": "binary_runs",
      "source": "ci", "run": "https://github.com/justrach/nanobrew/actions/runs/...",
      "nb_version": "0.1.196", "date": "2026-06-09"
    }
  ]
}
```

Signed the same way release artifacts are (minisign/sigstore — pick in the
implementation phase; the registry fetch path already trusts repo-hosted
JSON, so signing is an upgrade, not a blocker for phase 1).

## Phases

- **Phase 1 (cheap, high value, local-only):** post-install probe +
  `nb doctor --probe`; `nb list --versions` + `nb switch`; surface tier 1/2
  in `nb info`.
- **Phase 2:** CI evidence matrix + published `trust-evidence.json` + tier 3
  in `nb info` + `--trusted-only`.
- **Phase 3:** outcome telemetry + field evidence + `pkg@trusted` resolution
  and the freshness guardrail.

## Non-goals

- Sandboxed/source-rebuild verification (reproducible-builds territory).
- Package-specific test scripts in the registry (maintenance trap).
- Blocking installs by default — trust data informs; it only gates when the
  user opts in.
