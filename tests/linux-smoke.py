#!/usr/bin/env python3
"""
nanobrew Linux integration tests via Daytona sandboxes.

Spins up a Linux sandbox, builds nanobrew from source,
and runs smoke tests including ELF relocation verification.

Usage:
    export DAYTONA_API_KEY="your-key"
    python tests/linux-smoke.py

Requires: pip install daytona
"""

import argparse
import os
import sys
import tempfile

from daytona import Daytona, DaytonaConfig, CreateSandboxFromImageParams

# ── Zig download URLs (0.15.2) ──────────────────────────────────────
ZIG_URLS = {
    "aarch64": "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz",
    "x86_64":  "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz",
}
ZIG_DIRS = {
    "aarch64": "zig-aarch64-linux-0.15.2",
    "x86_64":  "zig-x86_64-linux-0.15.2",
}

# Domains the sandbox needs access to
NETWORK_ALLOWLIST = "ziglang.org,github.com,formulae.brew.sh,ghcr.io"


def get_repo_info():
    """Get current branch and repo URL from git."""
    import subprocess
    branch = subprocess.check_output(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True
    ).strip()
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True
    ).strip()
    if url.startswith("git@github.com:"):
        url = url.replace("git@github.com:", "https://github.com/")
    if not url.endswith(".git"):
        url = url + ".git"
    return branch, url


def run_script(sandbox, script, label, timeout=300):
    """Upload a shell script to the sandbox and run it."""
    print(f"\n==> {label}")
    sys.stdout.flush()
    with tempfile.NamedTemporaryFile(mode='w', suffix='.sh', delete=False) as f:
        f.write(script)
        local_path = f.name
    try:
        sandbox.fs.upload_file(local_path, '/tmp/_nb_test.sh')
        result = sandbox.process.exec('bash /tmp/_nb_test.sh', timeout=timeout)
    finally:
        os.unlink(local_path)
    if result.result:
        print(result.result)
    if result.exit_code != 0:
        print(f"  [exit code: {result.exit_code}]")
    return result


def download_zig(arch):
    """Download Zig for the target arch if not already cached locally."""
    import urllib.request
    local = f"/tmp/zig-{arch}-linux-0.15.2.tar.xz"
    if os.path.exists(local) and os.path.getsize(local) > 1_000_000:
        print(f"    Using cached Zig: {local}")
        return local
    url = ZIG_URLS[arch]
    print(f"    Downloading Zig from {url}...")
    sys.stdout.flush()
    urllib.request.urlretrieve(url, local)
    print(f"    Downloaded: {os.path.getsize(local) / 1_000_000:.0f} MB")
    return local


def main():
    parser = argparse.ArgumentParser(description="nanobrew Linux smoke tests via Daytona")
    parser.add_argument("--keep", action="store_true",
                        help="Don't delete sandbox after tests")
    parser.add_argument("--allowlist", action="store_true",
                        help="Use network allowlist instead of uploading Zig")
    args = parser.parse_args()

    api_key = os.environ.get("DAYTONA_API_KEY")
    if not api_key:
        print("Error: set DAYTONA_API_KEY environment variable")
        print("Get one at: https://app.daytona.io/dashboard/keys")
        sys.exit(1)

    branch, repo_url = get_repo_info()

    print(f"==> nanobrew Linux smoke tests (Daytona)")
    print(f"    branch: {branch}")
    print(f"    repo:   {repo_url}")
    print()

    # Initialize Daytona
    config = DaytonaConfig(api_key=api_key)
    daytona = Daytona(config)

    print("==> Creating Daytona sandbox...")
    if args.allowlist:
        sandbox = daytona.create(
            CreateSandboxFromImageParams(
                image="ubuntu:24.04",
                network_allow_list=NETWORK_ALLOWLIST,
            ),
            timeout=120,
        )
    else:
        sandbox = daytona.create(timeout=120)
    print(f"    Sandbox ID: {sandbox.id}")

    # Detect architecture
    arch_result = sandbox.process.exec("uname -m")
    arch = (arch_result.result or "").strip()
    arch = "aarch64" if arch == "aarch64" else "x86_64"
    zig_dir = ZIG_DIRS[arch]
    print(f"    Architecture: {arch}")

    try:
        # ── Phase 1: Install dependencies ──
        run_script(sandbox, """
set -e
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq curl xz-utils patchelf file binutils git readelf 2>/dev/null || \
sudo apt-get install -y -qq curl xz-utils patchelf file binutils git 2>/dev/null
echo "DEPS_OK"
""", "Phase 1a: Install dependencies", timeout=120)

        # ── Phase 1b: Install Zig ──
        if args.allowlist:
            # Download directly in sandbox
            run_script(sandbox, f"""
set -e
curl -sL '{ZIG_URLS[arch]}' -o /tmp/zig.tar.xz
sudo tar xf /tmp/zig.tar.xz -C /opt
/opt/{zig_dir}/zig version
echo "ZIG_OK"
""", "Phase 1b: Download Zig (in-sandbox)", timeout=300)
        else:
            # Upload from local
            print(f"\n==> Phase 1b: Upload Zig")
            local_zig = download_zig(arch)
            print(f"    Uploading to sandbox...")
            sys.stdout.flush()
            sandbox.fs.upload_file(local_zig, '/tmp/zig.tar.xz', timeout=300)
            r = sandbox.process.exec(
                f'sudo tar xf /tmp/zig.tar.xz -C /opt && /opt/{zig_dir}/zig version',
                timeout=120
            )
            print(f"    Zig: {(r.result or '').strip()}")

        # ── Phase 1c: Clone and build ──
        result = run_script(sandbox, f"""
set -e
cd /tmp
git clone --depth=1 --branch={branch} {repo_url} nanobrew 2>&1 | tail -2
export PATH="/opt/{zig_dir}:$PATH"
cd nanobrew
zig build 2>&1
file zig-out/bin/nb
echo "BUILD_OK"
""", "Phase 1c: Clone & Build", timeout=600)

        if result.exit_code != 0 or "BUILD_OK" not in (result.result or ""):
            print("\nBuild failed!")
            sys.exit(1)

        # ── Phase 2: Smoke tests ──
        result = run_script(sandbox, f"""
set -e
export PATH="/opt/{zig_dir}:/opt/nanobrew/prefix/bin:$PATH"
cd /tmp/nanobrew

NB="./zig-out/bin/nb"
PASS=0
FAIL=0

pass() {{ echo "  PASS: $1"; PASS=$((PASS + 1)); }}
fail() {{ echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }}

echo "==> Linux smoke tests"
echo ""

# Test 1: Binary runs
echo "--- Test: nb help ---"
if $NB help 2>&1 | grep -q "nanobrew"; then
  pass "nb help works"
else
  fail "nb help broken"
fi

# Test 2: Init + Doctor
echo "--- Test: nb init + doctor ---"
sudo mkdir -p /opt/nanobrew && sudo chmod 777 /opt/nanobrew
sudo $NB init >/dev/null 2>&1 || true
DOCTOR=$($NB doctor 2>&1)
if echo "$DOCTOR" | grep -q "patchelf installed"; then
  pass "nb doctor detects patchelf"
else
  fail "nb doctor did not detect patchelf"
  echo "$DOCTOR"
fi

# Test 3: ELF relocator compiled in
echo "--- Test: ELF relocator compiled in ---"
if strings $NB | grep -q "patchelf not found"; then
  pass "ELF relocator error strings present"
else
  fail "ELF relocator strings missing"
fi

# Test 4: patchelf-missing error
echo "--- Test: patchelf-missing error path ---"
REAL_PE=$(which patchelf)
sudo mv "$REAL_PE" "$REAL_PE.bak"
ERR=$($NB doctor 2>&1)
if echo "$ERR" | grep -q "patchelf not found"; then
  pass "patchelf-missing detected by doctor"
else
  fail "patchelf-missing not detected"
fi
sudo mv "$REAL_PE.bak" "$REAL_PE"

# Test 5: Install tree (if API reachable)
echo "--- Test: install tree ---"
if curl -sf 'https://formulae.brew.sh/api/formula/tree.json' -o /dev/null 2>/dev/null; then
  if $NB install tree 2>&1; then
    if tree --version 2>&1 | grep -qi "tree"; then
      pass "tree works on Linux"
    else
      fail "tree --version failed"
    fi

    CELLAR="/opt/nanobrew/prefix/Cellar"
    HITS=$(grep -rl '@@HOMEBREW_CELLAR@@\\|@@HOMEBREW_PREFIX@@' "$CELLAR" 2>/dev/null | head -5) || true
    if [ -z "$HITS" ]; then
      pass "no leftover @@HOMEBREW_*@@ placeholders"
    else
      fail "found leftover placeholders"
      echo "$HITS"
    fi
  else
    fail "nb install tree failed"
  fi
else
  echo "  SKIP: Homebrew API not reachable (sandbox network restriction)"
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
""", "Phase 2: Smoke Tests", timeout=300)

        if result.exit_code != 0:
            print("\nSome tests failed!")
            sys.exit(1)
        else:
            print("\nAll tests passed!")

    finally:
        if not args.keep:
            print("\n==> Cleaning up sandbox...")
            sandbox.delete()
        else:
            print(f"\n==> Sandbox kept: {sandbox.id}")


if __name__ == "__main__":
    main()
