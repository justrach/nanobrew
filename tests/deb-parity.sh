#!/bin/bash
# Test: verify nb install --deb produces correct, functional results
# and that extraction matches dpkg-deb for the same .deb files.
# Usage: ./tests/deb-parity.sh <path-to-nb-binary>
set -euo pipefail

NB_BIN="${1:?Usage: $0 <nb-binary>}"
NB_BIN_ABS="$(cd "$(dirname "$NB_BIN")" && pwd)/$(basename "$NB_BIN")"
PLATFORM="${PLATFORM:-linux/amd64}"
IMAGE="ubuntu:24.04"
PASS=0
FAIL=0

pass() { echo "    PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "    FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "==> Testing deb install parity"
echo "    Platform: $PLATFORM"
echo ""

# --- Test 1: All packages install successfully ---
echo "--- Test 1: nb install --deb curl (32/32 packages) ---"
INSTALL_OUTPUT=$(docker run --rm --platform "$PLATFORM" \
  --mount type=bind,source="$NB_BIN_ABS",target=/opt/nb \
  "$IMAGE" bash -c "
  /opt/nb init >/dev/null 2>&1
  /opt/nb install --deb curl 2>&1
")

INSTALLED=$(echo "$INSTALL_OUTPUT" | sed -n 's/.*Installed \([0-9]*\)\/\([0-9]*\).*/\1/p' | tail -1)
TOTAL=$(echo "$INSTALL_OUTPUT" | sed -n 's/.*Installed \([0-9]*\)\/\([0-9]*\).*/\2/p' | tail -1)
if [ "$INSTALLED" = "$TOTAL" ]; then
  pass "all $INSTALLED/$TOTAL packages installed"
else
  fail "only $INSTALLED/$TOTAL packages installed"
  echo "$INSTALL_OUTPUT" | grep "failed" | head -5 | sed 's/^/      /'
fi

# --- Test 2: Binary works ---
echo ""
echo "--- Test 2: curl --version works ---"
CURL_VER=$(docker run --rm --platform "$PLATFORM" \
  --mount type=bind,source="$NB_BIN_ABS",target=/opt/nb \
  "$IMAGE" bash -c "
  /opt/nb init >/dev/null 2>&1
  /opt/nb install --deb curl >/dev/null 2>&1
  curl --version 2>&1 | head -1
")

if echo "$CURL_VER" | grep -q "curl"; then
  pass "$CURL_VER"
else
  fail "curl not functional"
fi

# --- Test 3: Key files exist at correct paths ---
echo ""
echo "--- Test 3: key files exist ---"
FILE_CHECK=$(docker run --rm --platform "$PLATFORM" \
  --mount type=bind,source="$NB_BIN_ABS",target=/opt/nb \
  "$IMAGE" bash -c "
  /opt/nb init >/dev/null 2>&1
  /opt/nb install --deb curl >/dev/null 2>&1
  for f in /usr/bin/curl \
           /usr/lib/x86_64-linux-gnu/libcurl.so.4 \
           /usr/lib/x86_64-linux-gnu/libssl.so.3 \
           /usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
           /usr/lib/x86_64-linux-gnu/libbrotlidec.so.1 \
           /usr/lib/x86_64-linux-gnu/libz.so.1 \
           /usr/lib/x86_64-linux-gnu/libzstd.so.1; do
    if [ -f \"\$f\" ]; then
      echo \"OK \$f\"
    else
      echo \"MISSING \$f\"
    fi
  done
")

while IFS= read -r line; do
  status="${line%% *}"
  file="${line#* }"
  if [ "$status" = "OK" ]; then
    pass "$file exists"
  else
    fail "$file missing"
  fi
done <<< "$FILE_CHECK"

# --- Test 4: Extraction matches dpkg-deb for same .deb ---
echo ""
echo "--- Test 4: nb extraction matches dpkg-deb for same .deb ---"
DEB_COMPARE=$(docker run --rm --platform "$PLATFORM" \
  --mount type=bind,source="$NB_BIN_ABS",target=/opt/nb \
  "$IMAGE" bash -c "
  /opt/nb init >/dev/null 2>&1
  /opt/nb install --deb curl >/dev/null 2>&1

  # Find the curl .deb in blob cache using dpkg-deb --contents
  CURL_DEB=''
  for f in /opt/nanobrew/cache/blobs/*.deb; do
    if dpkg-deb --contents \"\$f\" 2>/dev/null | grep -q 'usr/bin/curl\$'; then
      CURL_DEB=\"\$f\"
      break
    fi
  done

  if [ -z \"\$CURL_DEB\" ]; then
    echo 'SKIP: could not find curl deb in cache'
    exit 0
  fi

  # Extract same .deb with dpkg-deb to a temp dir
  mkdir -p /tmp/dpkg-extract
  dpkg-deb -x \"\$CURL_DEB\" /tmp/dpkg-extract 2>/dev/null

  # Compare the curl binary from nb install vs dpkg-deb extraction
  if [ -f /tmp/dpkg-extract/usr/bin/curl ]; then
    NB_MD5=\$(md5sum /usr/bin/curl | cut -d' ' -f1)
    DPKG_MD5=\$(md5sum /tmp/dpkg-extract/usr/bin/curl | cut -d' ' -f1)
    if [ \"\$NB_MD5\" = \"\$DPKG_MD5\" ]; then
      echo \"MATCH /usr/bin/curl \$NB_MD5\"
    else
      echo \"MISMATCH /usr/bin/curl nb=\$NB_MD5 dpkg=\$DPKG_MD5\"
    fi
  else
    echo 'SKIP: dpkg-deb did not extract /usr/bin/curl'
  fi

  # Compare libcurl
  NB_LIB=\$(find /usr/lib -name 'libcurl.so.4.*' 2>/dev/null | head -1)
  DPKG_LIB=\$(find /tmp/dpkg-extract -name 'libcurl.so.4.*' 2>/dev/null | head -1)
  if [ -n \"\$NB_LIB\" ] && [ -n \"\$DPKG_LIB\" ]; then
    NB_MD5=\$(md5sum \"\$NB_LIB\" | cut -d' ' -f1)
    DPKG_MD5=\$(md5sum \"\$DPKG_LIB\" | cut -d' ' -f1)
    if [ \"\$NB_MD5\" = \"\$DPKG_MD5\" ]; then
      echo \"MATCH libcurl.so \$NB_MD5\"
    else
      echo \"MISMATCH libcurl.so nb=\$NB_MD5 dpkg=\$DPKG_MD5\"
    fi
  fi
")

while IFS= read -r line; do
  case "$line" in
    MATCH*)  pass "${line#MATCH }" ;;
    MISMATCH*) fail "${line#MISMATCH }" ;;
    SKIP*) echo "    SKIP: ${line#SKIP: }" ;;
  esac
done <<< "$DEB_COMPARE"

# --- Test 5: Multiple packages ---
echo ""
echo "--- Test 5: nb install --deb wget git ---"
MULTI_OUTPUT=$(docker run --rm --platform "$PLATFORM" \
  --mount type=bind,source="$NB_BIN_ABS",target=/opt/nb \
  "$IMAGE" bash -c "
  /opt/nb init >/dev/null 2>&1
  /opt/nb install --deb wget git >/dev/null 2>&1
  wget --version 2>&1 | head -1
  echo '---'
  git --version 2>&1
")

if echo "$MULTI_OUTPUT" | grep -q "Wget"; then
  pass "$(echo "$MULTI_OUTPUT" | grep Wget)"
else
  fail "wget not functional"
fi

if echo "$MULTI_OUTPUT" | grep -q "git version"; then
  pass "$(echo "$MULTI_OUTPUT" | grep 'git version')"
else
  fail "git not functional"
fi

# --- Summary ---
echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
