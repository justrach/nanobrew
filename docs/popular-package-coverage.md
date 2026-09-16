# Popular packages and compatibility

Run `python3 scripts/popularity-plan.py --top 100` to produce
`dist/popularity/plan.md` and `plan.json`, plus the source snapshots.
Use `--inputs DIR` to replay saved `formula-analytics.json`,
`cask-analytics.json`, `formulae.json` and `casks.json` snapshots offline.

The plan complements `upstream-coverage-report.mjs` and
`upstream-gap-report.mjs`: it distinguishes registry presence, platform pins,
current Homebrew Intel bottle availability, version differences, and required
work. It does not label metadata coverage as tested compatibility.

Formulas use Homebrew's 30-day install-on-request events, excluding dependency-only
installs. Casks use 30-day cask install events. These are reported events,
not unique users, exact downloads or Intel-only demand. Options are grouped by
package and counts must reconcile with the API total before ranking. Tap names
remain qualified; missing tap metadata stays unknown.

The Intel source-build list ranks packages by the summed demand of top formulas
whose current metadata dependency graph reaches them, counting each top formula
once per dependency. This finds shared libraries with more impact than their
own direct-install rank suggests. Totals overlap between dependencies and must
not be summed. Platform-specific dependencies and build dependencies still
require recipe review.

Use the resulting queue in this order:

1. Review direct upstream binaries and refresh checksum pins where available.
2. Test installs on Intel and ARM runners, including dependencies and CLI probes.
3. Preserve available Intel Homebrew bottles using the existing mirror workflow.
4. Add source recipes for popular packages and shared dependencies without current
   Intel bottles, using the Intel source-bottle pipeline.

Version differences require review: upstream releases can be newer than the
Homebrew API. Never blindly downgrade a pin to make versions match. Source-build
candidates may still have usable older mirrored bottles.

The `Popular package coverage` workflow refreshes this report on relevant changes
and manual dispatch. Its separate install job validates the selected batches
(`gh`, `uv`, `oras`, `ripgrep`, `just`, `fd`, `git-lfs`) on native Intel and Apple Silicon. Ranking does not install
the top 100 packages automatically. Other packages remain untested by this job.

The second batch refreshes ripgrep 15.2.0, just 1.58.0, fd 10.5.0, and
Git LFS 3.8.0 from their official GitHub release archives. It also adds the
missing Intel asset rule for fd. Both Mac architectures and both Linux
architectures have matching version pins; every archive was downloaded and
its SHA-256 compared with the upstream GitHub asset digest before promotion.
These records use upstream GitHub hosting directly.

The native macOS jobs cover exact upstream pins with freshness disabled, and
normal installs with the default freshness check enabled. Both paths must
install the exact registry digest and version and verify the executable
architecture. The resolver ignores Homebrew packaging revisions/rebuilds when
comparing a declared upstream binary; an actual newer upstream version still
triggers the freshness fallback. This prevents an unrelated Homebrew rebuild
from replacing a working upstream binary with different library dependencies.

The workflow also
searches text with ripgrep, finds a file with fd, executes a just recipe, and
round-trips a local Git LFS object through clean/smudge. Evidence is uploaded
per architecture. Linux archives receive download/checksum verification;
these macOS jobs do not establish Linux execution compatibility.

Existing users can fetch the catalog with `nb update-registry`, then run
`nb install ripgrep just fd git-lfs` (or `nb upgrade` for existing installs).
The resolver fix ships in Nanobrew v0.1.212. Updating only the registry
on v0.1.211 can still select a Homebrew rebuild; use the updated client for
the verified default installation behavior.

## CodeDB and Codegraff

The curated CLI list also includes `codedb` 0.2.5855 from `justrach/codedb`
and `codegraff` 0.0.298 from `justrach/codegraff`. Install with
`nb update-registry` followed by `nb install codedb codegraff` on v0.1.212.
The executable names are `codedb` and `graff`, respectively. This installs the
CLIs; MCP client registration and provider login remain explicit setup steps.

Codegraff uses checksum-pinned upstream CLI archives for Intel/Apple Silicon
macOS and x86_64/aarch64 Linux. CodeDB publishes bare executables, so
`scripts/bottles/package_codedb.py` wraps the pinned bytes and upstream BSD
license into reproducible bottles. `codedb-recipe.json` records every source
URL and checksum. The `CodeDB bottles` workflow publishes them to Nanobrew's
GitHub Container Registry and verifies anonymous downloads before promotion.
No source build or new Nanobrew client release is needed for these two entries.

Native package checks now cover nine tools, including CodeDB indexing,
search, and symbol outlining in a disposable fixture project, plus Codegraff's
schema and help commands without provider credentials or model calls. CodeDB's
telemetry is disabled in these tests. Linux companion bytes are verified;
the native CLI execution checks cover Intel macOS 15 and Apple Silicon macOS 26.
