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
and manual dispatch. Its separate install job validates the first selected batch
(`gh`, `uv`, `oras`) on native Intel and Apple Silicon. Ranking does not install
the top 100 packages automatically. Other packages remain untested by this job.
