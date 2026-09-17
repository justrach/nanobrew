# Intel macOS 12 Git pilot

This is an opt-in build and install experiment, not released Monterey support.
The workflow builds on Intel macOS 15 with deployment target 12.0, audits the
Mach-O minimum versions and linked libraries, installs the exact generated
bottles through Nanobrew, then runs library consumers and Git operations.
A successful run does not replace a runtime test on macOS 12.7.6 / Xcode 14.2.

## Coverage

Git, expat, json-c, readline, pcre2, libxml2, libssh2, openldap, curl, zlib and
OpenSSL 3. `monterey-git-recipes.json` pins every source digest and the six
patches that turn the readline 8.3 archive into 8.3.6.

These are CLI-focused pilot builds, not feature-equivalent Homebrew bottles:

- Git omits gettext translations and Tcl/Tk GUIs.
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
and uploads Actions artifacts only. There is no publish or deploy job.
The builder writes and removes only the new test kegs on a disposable Intel
GitHub Actions runner, and refuses to overwrite existing kegs.

Before promotion: test on actual Monterey, assess omitted features, scan the
binaries, publish immutable blobs, and update the registry only with evidence.
