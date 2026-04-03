#!/bin/bash
# Test: Linux installs can relocate common ELF bottles even when patchelf is unavailable.
# Usage: bash tests/linux-relocation-failure.sh <path-to-nb-binary>
set -euo pipefail

NB_BIN="${1:?Usage: $0 <path-to-nb-binary>}"
NB_BIN_ABS="$(cd "$(dirname "$NB_BIN")" && pwd)/$(basename "$NB_BIN")"
PASS=0
FAIL=0

pass() { echo "    PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "    FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "==> Linux relocation fallback regression"
echo "    Binary: $NB_BIN_ABS"
echo ""

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "SKIP: requires root or passwordless sudo for /opt/nanobrew setup"
    exit 0
  fi
fi

run_root() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  else
    "$@"
  fi
}

run_root rm -rf /opt/nanobrew
run_root "$NB_BIN_ABS" init >/dev/null 2>&1

FAKEBIN="$(mktemp -d)"
trap 'rm -rf "$FAKEBIN"' EXIT
cat >"$FAKEBIN/patchelf" <<'EOF'
#!/bin/sh
exit 127
EOF
chmod +x "$FAKEBIN/patchelf"

echo "--- Test: install succeeds without patchelf for common ELF bottles ---"
set +e
INSTALL_OUTPUT="$(PATH="$FAKEBIN:$PATH" "$NB_BIN_ABS" install lz4 2>&1)"
INSTALL_STATUS=$?
set -e

if [ "$INSTALL_STATUS" -eq 0 ]; then
  pass "nb install lz4 exited zero without patchelf"
else
  fail "nb install lz4 failed without patchelf"
fi

if grep -q "relocate failed: error.PatchelfNotFound" <<<"$INSTALL_OUTPUT"; then
  fail "install still reported PatchelfNotFound"
  echo "$INSTALL_OUTPUT" | tail -20 | sed 's/^/      /'
else
  pass "install did not report PatchelfNotFound"
fi

if grep -q "✓ lz4" <<<"$INSTALL_OUTPUT"; then
  pass "install reported lz4 success"
else
  fail "install output missing lz4 success marker"
fi

echo ""
echo "--- Test: installed package is recorded, linked, and runnable ---"
LIST_OUTPUT="$("$NB_BIN_ABS" list 2>&1 || true)"
if grep -Eq '^lz4 ' <<<"$LIST_OUTPUT"; then
  pass "lz4 is present in nb list"
else
  fail "lz4 missing from nb list"
fi

if [ -e /opt/nanobrew/prefix/bin/lz4 ]; then
  pass "prefix/bin lz4 link exists"
else
  fail "/opt/nanobrew/prefix/bin/lz4 missing"
fi

LZ4_VERSION="$(/opt/nanobrew/prefix/bin/lz4 --version 2>&1 | head -n 1 || true)"
if grep -q "lz4 v1.10.0" <<<"$LZ4_VERSION"; then
  pass "lz4 runs without patchelf"
else
  fail "lz4 is not runnable after install"
  echo "      output: $LZ4_VERSION"
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
