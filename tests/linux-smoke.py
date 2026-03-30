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

from daytona import Daytona, DaytonaConfig, CreateSandboxFromImageParams

# ── Zig download URL (0.15.2) ──────────────────────────────────────
ZIG_URL = "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz"
ZIG_DIR = "zig-aarch64-linux-0.15.2"

# ── Test definitions ────────────────────────────────────────────────
SETUP_SCRIPT = """
set -e
export DEBIAN_FRONTEND=noninteractive

# Install deps
apt-get update -qq
apt-get install -y -qq curl xz-utils patchelf file binutils git >/dev/null 2>&1

# Download and install Zig
curl -sL '{zig_url}' -o /tmp/zig.tar.xz
tar xf /tmp/zig.tar.xz -C /opt
export PATH="/opt/{zig_dir}:$PATH"
zig version

# Clone the repo at the current branch
cd /tmp
git clone --depth=1 --branch={branch} {repo_url} nanobrew
cd nanobrew

# Build
zig build
file zig-out/bin/nb
echo "BUILD_OK"
"""

TEST_SCRIPT = """
set -e
export PATH="/opt/{zig_dir}:/opt/nanobrew/prefix/bin:$PATH"
cd /tmp/nanobrew

NB="./zig-out/bin/nb"
PASS=0
FAIL=0

pass() {{ echo "  PASS: $1"; PASS=$((PASS + 1)); }}
fail() {{ echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }}

echo "==> Linux smoke tests (Daytona sandbox)"
echo ""

# Test 1: Binary runs
echo "--- Test: nb help ---"
if $NB help 2>&1 | grep -q "nanobrew"; then
  pass "nb help works"
else
  fail "nb help broken"
fi

# Test 2: Doctor detects patchelf
echo "--- Test: nb doctor (patchelf detection) ---"
mkdir -p /opt/nanobrew && chmod 777 /opt/nanobrew
$NB init >/dev/null 2>&1 || true
DOCTOR=$($NB doctor 2>&1)
if echo "$DOCTOR" | grep -q "patchelf installed"; then
  pass "nb doctor detects patchelf"
else
  fail "nb doctor did not detect patchelf"
  echo "$DOCTOR" | grep -i patchelf || true
fi

# Test 3: ELF relocator strings present in binary
echo "--- Test: ELF relocator compiled in ---"
if strings $NB | grep -q "patchelf not found"; then
  pass "ELF relocator error strings present"
else
  fail "ELF relocator strings missing from binary"
fi

# Test 4: patchelf missing error (temporarily hide patchelf)
echo "--- Test: patchelf-missing error path ---"
REAL_PE=$(which patchelf)
mv "$REAL_PE" "$REAL_PE.bak"
ERR=$($NB doctor 2>&1)
if echo "$ERR" | grep -q "patchelf not found"; then
  pass "patchelf-missing detected by doctor"
else
  fail "patchelf-missing not detected"
fi
mv "$REAL_PE.bak" "$REAL_PE"

# Test 5: Install a small formula (tree) and verify no leftover placeholders
echo "--- Test: install tree + placeholder check ---"
if $NB install tree 2>&1; then
  if tree --version 2>&1 | grep -qi "tree"; then
    pass "tree --version works on Linux"
  else
    fail "tree --version failed"
  fi

  # Check for leftover placeholders
  CELLAR="/opt/nanobrew/prefix/Cellar"
  HITS=$(grep -rl '@@HOMEBREW_CELLAR@@\\|@@HOMEBREW_PREFIX@@' "$CELLAR" 2>/dev/null | head -5) || true
  if [ -z "$HITS" ]; then
    pass "no leftover @@HOMEBREW_*@@ placeholders"
  else
    fail "found leftover placeholders"
    echo "$HITS"
  fi

  # Check ELF interpreter specifically
  TREE_BIN=$(ls "$CELLAR"/tree/*/bin/tree 2>/dev/null | head -1)
  if [ -n "$TREE_BIN" ] && file "$TREE_BIN" | grep -q "ELF"; then
    INTERP=$(readelf -l "$TREE_BIN" 2>/dev/null | grep "interpreter" || true)
    if echo "$INTERP" | grep -q "@@HOMEBREW"; then
      fail "ELF interpreter still contains @@HOMEBREW placeholder"
      echo "  $INTERP"
    else
      pass "ELF interpreter is properly relocated"
      echo "  $INTERP"
    fi
  fi
else
  fail "nb install tree failed"
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
"""


def get_repo_info():
    """Get current branch and repo URL from git."""
    import subprocess
    branch = subprocess.check_output(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], text=True
    ).strip()
    url = subprocess.check_output(
        ["git", "remote", "get-url", "origin"], text=True
    ).strip()
    # Convert SSH to HTTPS for cloning inside sandbox
    if url.startswith("git@github.com:"):
        url = url.replace("git@github.com:", "https://github.com/")
    if not url.endswith(".git"):
        url = url + ".git"
    return branch, url


def run_in_sandbox(sandbox, script, label, timeout=300):
    """Run a shell script in the sandbox by writing it to a temp file first."""
    import base64
    print(f"\n==> {label}")
    # Encode script as base64 to avoid any quoting issues
    b64 = base64.b64encode(script.encode()).decode()
    result = sandbox.process.exec(
        f'echo "{b64}" | base64 -d > /tmp/_nb_test.sh && bash /tmp/_nb_test.sh',
        timeout=timeout,
    )
    if result.result:
        print(result.result)
    if result.exit_code != 0:
        print(f"  [exit code: {result.exit_code}]")
    return result
def main():
    parser = argparse.ArgumentParser(description="nanobrew Linux smoke tests via Daytona")
    parser.add_argument("--keep", action="store_true",
                        help="Don't delete sandbox after tests")
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
    sandbox = daytona.create(
        CreateSandboxFromImageParams(
            image="debian:bookworm",
            language="bash",
        )
    )
    print(f"    Sandbox ID: {sandbox.id}")

    try:
        # Phase 1: Setup (install deps, build nanobrew)
        setup = SETUP_SCRIPT.format(
            zig_url=ZIG_URL,
            zig_dir=ZIG_DIR,
            branch=branch,
            repo_url=repo_url,
        )
        result = run_in_sandbox(sandbox, setup, "Phase 1: Setup & Build", timeout=600)
        if result.exit_code != 0 or "BUILD_OK" not in (result.result or ""):
            print(f"\nSetup failed!")
            sys.exit(1)

        # Phase 2: Run tests
        tests = TEST_SCRIPT.format(zig_dir=ZIG_DIR)
        result = run_in_sandbox(sandbox, tests, "Phase 2: Smoke Tests", timeout=300)

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
