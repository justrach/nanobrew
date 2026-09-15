# Intel source bottles on GitHub

## Core library catalog

The `Intel core libraries` workflow extends the pilot to zlib, xz, lz4 and
OpenSSL 3. Each package builds and runs upstream tests on a separate native
Intel runner, installs through Nanobrew with the exact source-bottle digest,
and tests a dynamically linked consumer. xz and lz4 also round-trip compressed
data; OpenSSL checks its default CA bundle and generates/verifies a certificate.

Reviewed versions, source checksums, licenses and companion bottle metadata
are pinned in `scripts/bottles/intel-library-recipes.json`. The builder uses
Apple command-line tools, isolated staging, and no Homebrew build dependencies.
OpenSSL's runtime `ca-certificates` dependency still comes through Nanobrew's
normal resolver. Its config is packaged under `.bottle/etc`, using Nanobrew's
existing default-config and CA-store handling.

The combined prerelease includes the xz/lz4/OpenSSL corresponding source archives,
license notices, four Intel bottles, SBOMs and test evidence. All four native jobs
must pass before publication. The registry is assembled with matching-version
ARM/Linux companion pins; it never relabels an older platform binary with a new
global version. The companion platforms are metadata-pinned, not tested by this
Intel workflow. Missing companions or a revoked old record require review.

The combined release remains opt-in through `NANOBREW_UPSTREAM_REGISTRY_URL`.
The default catalog is not replaced by experimental source-library pins.

To reproduce a recipe locally with Python 3.12+:

```sh
python3 scripts/bottles/build_intel_library.py xz
python3 scripts/bottles/build_intel_library.py lz4
python3 scripts/bottles/build_intel_library.py openssl@3
```

The target is macOS 12+, with native execution tested on macOS 15 Intel. Local
Apple Silicon builds require Rosetta and are not publishable by this workflow.

## Original zlib pilot

The `Intel source bottles` workflow builds zlib 1.3.2 from pinned source on
`macos-15-intel`. It installs the resulting bottle through Nanobrew on the
disposable runner, tests a dynamically linked consumer, and scans the actual
archive before publication. No Homebrew compiler or build dependencies are used
by the zlib recipe. The deployment target is macOS 12; execution is currently
tested on macOS 15 Intel only.

Syft supplies the file inventory. Because it does not identify zlib from this
C library's binaries, the workflow adds an explicit SPDX package with the
recipe's verified source checksum, version, package URL and CPE before Grype
matches vulnerabilities. This avoids accepting an empty package inventory as
a meaningful scan.

Successful non-PR runs publish to `ghcr.io/justrach/nb-bottles/zlib`, verify a
public anonymous pull by checksum, and create a GitHub prerelease containing
the tarball, checksum, source/toolchain evidence, SBOM, scan report and complete
opt-in registry. Tags include the Actions run ID and attempt, so new source
builds do not overwrite existing mirrored bottles or earlier source builds.
PR runs build and test without publishing. The workflow can be dispatched
manually after it lands on main; recipe changes also trigger it.

To try a published build, use its `registry-intel.json` release asset URL:

```sh
export NANOBREW_UPSTREAM_REGISTRY_URL="https://github.com/justrach/nanobrew/releases/download/RELEASE_TAG/registry-intel.json"
nb update-registry
nb install zlib
```

Use a fresh Intel test installation for the pilot: an already installed zlib
at the same version is not automatically replaced. The default registry is
unchanged. To leave the pilot, unset `NANOBREW_UPSTREAM_REGISTRY_URL` and run
`nb update-registry` again; this changes future resolution, not installed kegs.

The source recipe is `scripts/bottles/build_zlib_intel.py`. Local builds need
macOS, Xcode command-line tools, Python 3.12+, and Rosetta on ARM. They stage
files in a temporary directory and only write the result to `dist/`.

This starts with one dependency-free library. Expansion requires reviewed
source/checksum pins, build dependencies and compiler flags, upstream and
consumer tests, and staged packaging including runtime libraries and licenses.
Use dependency order for larger libraries and language runtimes. Existing
mirrors preserve previously built packages; these recipes supply new builds.
