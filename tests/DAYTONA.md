# Daytona Linux Integration Tests

## What this does

Runs nanobrew's Linux smoke tests inside a [Daytona](https://daytona.io) sandbox — a real x86_64 Ubuntu VM with sudo, apt, and full ELF binary support. This lets us test ELF relocation, patchelf detection, and Linux-specific behavior from macOS.

## Setup

```bash
# 1. Create a venv and install the SDK
python3 -m venv tests/.venv
tests/.venv/bin/pip install -r tests/requirements.txt

# 2. Get an API key from https://app.daytona.io/dashboard/keys
#    Save it (gitignored):
echo 'DAYTONA_API_KEY=dtn_...' > tests/.env

# 3. Export it
export DAYTONA_API_KEY="dtn_..."
```

## Running tests

```bash
# Default: downloads Zig locally, uploads to sandbox (works with restricted networks)
tests/.venv/bin/python tests/linux-smoke.py

# With network allowlist (sandbox can download Zig directly):
tests/.venv/bin/python tests/linux-smoke.py --allowlist

# Keep sandbox alive after tests (for debugging):
tests/.venv/bin/python tests/linux-smoke.py --keep
```

## What it tests

| Test | What it verifies |
|------|-----------------|
| `nb help` | Binary runs on Linux |
| `nb doctor` (patchelf present) | Detects installed patchelf |
| ELF relocator strings | `patchelf not found` error message compiled into binary |
| `nb doctor` (patchelf hidden) | Error path when patchelf is missing |
| `nb install tree` | Full ELF relocation pipeline (only if Homebrew API reachable) |

## How it works

1. **Sandbox creation** — Spins up a default Daytona sandbox (Ubuntu x86_64)
2. **Dep install** — `sudo apt-get install patchelf git file binutils`
3. **Zig upload** — Downloads Zig 0.15.2 locally, uploads via `fs.upload_file` (bypasses sandbox network restrictions on `ziglang.org`)
4. **Clone & build** — `git clone` from GitHub (whitelisted), `zig build`
5. **Smoke tests** — Runs tests via uploaded bash scripts

## Network notes

Daytona sandboxes block most external HTTPS by default. GitHub is whitelisted, but `ziglang.org` and `formulae.brew.sh` are not. Two workarounds:

- **Default mode**: Download Zig locally, upload to sandbox. Homebrew API tests are skipped.
- **`--allowlist` mode**: Creates sandbox with `network_allow_list` to allow `ziglang.org` and `formulae.brew.sh`. Enables full end-to-end testing including `nb install`.

## Files

- `tests/linux-smoke.py` — Test runner
- `tests/requirements.txt` — Python deps (`daytona>=0.158.0`)
- `tests/.env` — API key (gitignored)
- `tests/.env.example` — Template
