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

## Testing

150 tests including an adversarial security suite covering:
- Path traversal patterns
- Null byte injection
- JSON injection payloads
- Version string attacks (shell injection, backticks, pipes)
- Binary magic byte detection
- Long string / buffer overflow
- Deep recursion protection
