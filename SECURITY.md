# Security Policy

## Reporting Vulnerabilities

If you find a security vulnerability in nanobrew, please email **security@trilok.ai** or open a GitHub issue.

We take security seriously — in v0.1.073 alone we found and fixed 21 vulnerabilities through adversarial self-auditing.

## What we've fixed

### Critical (P0)
- **Shell injection RCE** — xz decompression fallback used `/bin/sh -c` (#21)
- **JSON injection** — unescaped package names in database (#22)
- **Tar extraction to /** — no path traversal validation (#10)
- **Unsandboxed postinst** — .deb postinst scripts ran without opt-out (#9)
- **No SHA256 verification** — packages installed without integrity check (#12)
- **HTTP redirect follows** — no protocol/domain validation (#11)
- **Self-update was curl|bash** — no binary verification (#27)
- **Package name path traversal** — `../../etc/passwd` flowed into cache paths (#48)
- **Binary corruption** — placeholder replacement destroyed Python framework (#50)

### High (P1)
- **Decompression bomb** — unbounded memory allocation in zstd/gzip (#24)
- **Resolver stack overflow** — recursive deps with no depth limit (#23)
- **Race condition** — cache blob download/rename (#15)
- **Silent error swallowing** — package removal and DB writes (#14)
- **Path traversal** — unsanitized package names in file paths (#13)
- **Symlink target escapes** — cask binary installation (#28)
- **HOME env injection** — `nb nuke` trusted $HOME without validation (#29)
- **Cask bin.target traversal** — no validation on symlink targets (#44)
- **Deb tar absolute paths** — `isPathSafe` defined but not used (#47)

### Medium (P2)
- **Global buffer race** — mutable `var path_buf` in blob_cache (#30)
- **Buffer overflow risk** — HTTP headers and path construction (#16)
- **Mirror URL injection** — no scheme/control char validation (#17)
- **Silent DB corruption** — parse failure returned empty DB (#25)
- **Placeholder binary corruption** — binaries without nulls in first 512 bytes (#46)
- **Brewfile injection** — quoted names bypassed validation (#45)

## Security measures in v0.1.073

- **SHA256 verification** on all downloads (bottles, .debs, self-update)
- **Package name validation** — rejects `..`, control chars, null bytes at all entry points
- **Path traversal protection** — tar `--exclude`, `--no-absolute-filenames`, `isPathSafe`
- **JSON escaping** — all special characters escaped in database writes
- **Binary guard** — ELF/Mach-O magic byte detection prevents text replacement on binaries
- **Thread safety** — threadlocal buffers replace global mutable state
- **Depth limits** — dependency resolver capped at 64 levels
- **Decompression limits** — 1GB cap on zstd/gzip output
- **No Gatekeeper quarantine** — cask installs strip `com.apple.quarantine`
- **`--skip-postinst`** — opt out of .deb postinst script execution
- **`--no-verify`** — required flag to install packages without checksums
- **HTTPS with system CA verification** — all API and download connections use TLS with the OS certificate store; certificate pinning is not implemented as it is not standard practice for package managers

## Testing

150 tests including an adversarial security suite covering:
- Path traversal patterns
- Null byte injection
- JSON injection payloads
- Version string attacks (shell injection, backticks, pipes)
- Deep recursion protection

## Known open issues

| # | Severity | Issue |
|---|----------|-------|
| [#52](https://github.com/justrach/nanobrew/issues/52) | Info | Placeholder walk adds ~24ms per install (correctness tradeoff, won't fix) |
| [#54](https://github.com/justrach/nanobrew/issues/54) | P2 | SUDO_USER env var not validated before use in chown |
| [#55](https://github.com/justrach/nanobrew/issues/55) | P3 | Cask download not SHA256 verified before extraction |
| [#56](https://github.com/justrach/nanobrew/issues/56) | P3 | No HTTPS certificate pinning — accepted risk; standard for package managers (brew, apt, npm rely on CA verification, not pinning) |

## Audit history

| Date | Version | Findings | Fixed |
|------|---------|----------|-------|
| 2026-03-24 | v0.1.069 | Round 1: 12 vulnerabilities (P0-P2) | All 12 |
| 2026-03-24 | v0.1.070 | Round 2: 9 vulnerabilities + test suite | All 9 |
| 2026-03-25 | v0.1.072 | Round 3: 8 vulnerabilities (HN feedback) | All 8 |
| 2026-03-25 | v0.1.073 | Round 4: 5 vulnerabilities (adversarial agents) + binary corruption | All 5 + #50 |

Total: **34 vulnerabilities found and fixed** across 4 audit rounds.
