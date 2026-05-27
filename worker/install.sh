#!/bin/bash
set -euo pipefail

REPO="justrach/nanobrew"
INSTALL_DIR="/opt/nanobrew"
BIN_DIR="$INSTALL_DIR/prefix/bin"

echo ""
echo "  nanobrew — the fastest package manager"
echo ""

# Detect OS and architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin)
        case "$ARCH" in
            arm64|aarch64) TARBALL_ARCH="arm64-apple-darwin" ;;
            x86_64)        TARBALL_ARCH="x86_64-apple-darwin" ;;
            *)
                echo "error: unsupported macOS architecture: $ARCH"
                exit 1
                ;;
        esac
        ;;
    Linux)
        case "$ARCH" in
            x86_64)          TARBALL_ARCH="x86_64-linux" ;;
            aarch64|arm64)   TARBALL_ARCH="aarch64-linux" ;;
            *)
                echo "error: unsupported Linux architecture: $ARCH"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "error: unsupported OS: $OS"
        exit 1
        ;;
esac

# Get latest release tag
echo "  Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
if [ -z "$LATEST" ]; then
    echo "error: could not find latest release"
    echo "hint: make sure https://github.com/$REPO has a release"
    exit 1
fi
# Validate tag format to prevent URL injection
if ! echo "$LATEST" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9._-]*$'; then
  echo "  Error: invalid release tag format: $LATEST"
  exit 1
fi
echo "  Found $LATEST"

# Download binary
TARBALL="nb-${TARBALL_ARCH}.tar.gz"
URL="https://github.com/$REPO/releases/download/$LATEST/$TARBALL"

echo "  Downloading nb ($TARBALL_ARCH)..."
TMPDIR_DL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DL"' EXIT

# Download checksum first (small, fail fast if release is incomplete)
SHA_URL="${URL}.sha256"
echo "  Fetching SHA256 checksum..."
if ! curl -fsSL "$SHA_URL" -o "$TMPDIR_DL/$TARBALL.sha256"; then
    echo "  Error: could not download SHA256 checksum file"
    exit 1
fi
EXPECTED=$(cut -d' ' -f1 < "$TMPDIR_DL/$TARBALL.sha256")
if ! echo "$EXPECTED" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  Error: invalid SHA256 format in checksum file"
    exit 1
fi

# Download tarball
curl -fsSL "$URL" -o "$TMPDIR_DL/$TARBALL"

# Verify integrity
echo "  Verifying SHA256 checksum..."
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "$TMPDIR_DL/$TARBALL" | cut -d" " -f1)
else
    ACTUAL=$(shasum -a 256 "$TMPDIR_DL/$TARBALL" | cut -d" " -f1)
fi
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "  Error: SHA256 verification failed!"
    echo "  Expected: $EXPECTED"
    echo "  Actual:   $ACTUAL"
    exit 1
fi
echo "  SHA256 verified."

tar --no-same-permissions -xzf "$TMPDIR_DL/$TARBALL" -C "$TMPDIR_DL"

# Create directories
echo "  Creating directories..."
if [ ! -d "$INSTALL_DIR" ]; then
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown -R "$(whoami)" "$INSTALL_DIR"
fi
mkdir -p "$BIN_DIR" \
    "$INSTALL_DIR/cache/blobs" \
    "$INSTALL_DIR/cache/tmp" \
    "$INSTALL_DIR/cache/tokens" \
    "$INSTALL_DIR/cache/api" \
    "$INSTALL_DIR/prefix/Cellar" \
    "$INSTALL_DIR/store" \
    "$INSTALL_DIR/db"

# Install binary — tarball may contain "nb" or "nb-<arch>"
NB_BIN="$TMPDIR_DL/nb"
if [ ! -f "$NB_BIN" ]; then
    NB_BIN="$(find "$TMPDIR_DL" -maxdepth 1 -name 'nb*' -type f ! -name '*.tar.gz' ! -name '*.sha256' | head -1)"
    if [ -z "$NB_BIN" ]; then
        echo "  Error: extracted binary not found in tarball"
        exit 1
    fi
fi
cp "$NB_BIN" "$BIN_DIR/nb"
chmod +x "$BIN_DIR/nb"
echo "  Installed nb to $BIN_DIR/nb"

# Add to PATH
SHELL_RC="$HOME/.zshrc"
if [ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

if ! grep -q '/opt/nanobrew/prefix/bin' "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# nanobrew" >> "$SHELL_RC"
    echo 'export PATH="/opt/nanobrew/prefix/bin:$PATH"' >> "$SHELL_RC"
fi

echo ""
echo "  Done! Run this to start using nanobrew:"
echo ""
echo "    export PATH=\"/opt/nanobrew/prefix/bin:\$PATH\""
echo ""
echo "  Then:"
echo ""
echo "    nb install ffmpeg"
echo ""
