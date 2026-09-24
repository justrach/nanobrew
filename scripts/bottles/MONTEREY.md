# Intel macOS 12 Git pilot

This is an opt-in build and install experiment, not released Monterey support.
The workflow builds on Intel macOS 15 with deployment target 12.0, audits the
Mach-O minimum versions and linked libraries, installs the exact generated
bottles through Nanobrew, then runs library consumers and Git operations.
A successful run does not replace a runtime test on macOS 12.7.6 / Xcode 14.2.

## Coverage

Git, expat, json-c, readline, pcre2, libxml2, libssh2, openldap, curl, zlib and
OpenSSL 3. `monterey-git-recipes.json` pins every source digest and the six
patches that turn the readline 8.3 archive into 8.3.6. OpenLDAP's Darwin
configure patch is pinned too. JSON-C's test input uses portable printf instead
of echo -n, with unchanged assertions. Two libxml2 test helpers missing from its
release archive are restored from its matching upstream tag with digest pins.
libssh2 runs standalone and local-sshd tests; its Docker integration tests need
a Docker host and are disabled on the macOS runner.
Its interactive-shell test explicitly exits the remote shell before blocking
channel cleanup, with timeouts that fail the build if the SSH test stalls.

These are CLI-focused pilot builds, not feature-equivalent Homebrew bottles:

- Git uses its supported C-only build and omits gettext translations and Tcl/Tk GUIs.
- curl uses OpenSSL, zlib and libssh2. It omits LDAP, libpsl, Brotli, Zstandard,
  libidn2 and HTTP/2/3 libraries. TLS uses `/etc/ssl/cert.pem`.
- OpenLDAP builds client libraries/tools, not slapd or Cyrus SASL integration.
- libxml2 omits Python and LZMA integration.

The opt-in registry contains only this Intel stack. It does not overwrite the
main catalog, change Apple Silicon assets or claim cross-platform parity.
Its example.invalid URLs intentionally prevent use without the exact cached
artifacts. Publication needs real immutable URLs and further validation.
Sources, patches and license notices accompany the artifact for inspection.

## Client fixes

- A source-only freshness result cannot replace a maintained bottle pin.
- API, tap and GHCR tag selection reject bottles requiring a newer running OS.
- Bottle pins can declare `minimum_macos_major`. Unknown legacy requirements
  remain allowed on the existing macOS 15+ baseline, but are rejected on older
  systems. A major-version field cannot express a minor-version requirement.
- No default registry pin is labelled macOS 12 compatible by this change.

## Run

Push the `codex/monterey-intel-git` branch or dispatch the
`Monterey Intel Git bottle pilot` workflow. It has read-only repository access
and uploads Actions artifacts only. Publishing is opt-in via the `publish`
dispatch input (below); there is no automatic publish or deploy job.
The builder writes and removes only the new test kegs on a disposable Intel
GitHub Actions runner, and refuses to overwrite existing kegs.

For an iterative pilot run, workflow dispatch can accept a prior `reuse_run`.
Use only a reviewed pilot run with unchanged build settings for reused packages.
The builder checks recipe metadata and bottle digests, then repeats the native
Mach-O audit before reusing those bottles. The original upstream test evidence
and source artifacts remain included; the final Nanobrew install tests run again.
Leave this input empty when changing compiler flags, build recipes or audits.

A Rosetta smoke job runs the same exact-bottle install and consumer checks on
an Apple Silicon macOS 15 runner via `arch -x86_64`. Its `installed-tests.json`
carries `host_arch` and `rosetta_translated` markers; it exercises the client
and payloads under translation but is not a Monterey runtime test.

Before promotion: test on actual Monterey, assess omitted features, scan the
binaries, publish immutable blobs, and update the registry only with evidence.

## Publishing

Dispatch the workflow with `publish: true` to run the opt-in publish job after
the Intel build. The scan gate (generic syft SBOM + grype `--fail-on high`, no
recipe CPE annotation) runs per bottle on the runner, then the publish job on
ubuntu-latest validates every bottle against its build evidence and recipe
digests, pushes each blob under `nb-bottles/<pkg>` tagged
`<version>-monterey-<run>-<attempt>`, verifies it with an anonymous pull, and
writes `dist/monterey/registry-monterey.json` with the real GHCR URLs plus
`SHA256SUMS`. A prerelease `monterey-git-<run>-<attempt>` hosts the bottles,
evidence, SBOMs, scan reports, rewritten registry and notes.

Promotion to the default catalog is a follow-up PR that copies the
`macos-x86_64` assets from `registry-monterey.json` into both
`registry_default.json` and `registry/upstream.json`.
