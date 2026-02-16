#!/bin/bash
set -e

NANOBREW_PREFIX="/opt/nanobrew/prefix"
NANOBREW_BIN="$NANOBREW_PREFIX/bin"
NANOBREW_CACHE="/opt/nanobrew/cache"

echo "==> Installing nanobrew..."

# Check for zig
if ! command -v zig &>/dev/null; then
    echo "error: zig 0.15+ is required."
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "       Install with: brew install zig"
    else
        echo "       Install from: https://ziglang.org/download/"
    fi
    exit 1
fi
# Build
echo "    Building..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
zig build -Doptimize=ReleaseFast 2>&1

# Create directories
echo "    Creating directories..."
sudo mkdir -p "$NANOBREW_BIN" "$NANOBREW_CACHE/blobs" "$NANOBREW_CACHE/tmp" "$NANOBREW_CACHE/tokens" "$NANOBREW_CACHE/api" "$NANOBREW_PREFIX/Cellar" "$NANOBREW_PREFIX/opt" "/opt/nanobrew/store" "/opt/nanobrew/db" "/opt/nanobrew/locks"
sudo chown -R "$(whoami)" /opt/nanobrew

# Install binary
echo "    Installing nb binary..."
cp zig-out/bin/nb "$NANOBREW_BIN/nb"

# Detect shell config file
if [ "$(uname -s)" = "Linux" ]; then
    SHELL_RC="$HOME/.bashrc"
    if [ -n "$ZSH_VERSION" ]; then
        SHELL_RC="$HOME/.zshrc"
    fi
else
    SHELL_RC="$HOME/.zshrc"
    if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
        SHELL_RC="$HOME/.bashrc"
    fi
fi

if ! grep -q '/opt/nanobrew/prefix/bin' "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# nanobrew" >> "$SHELL_RC"
    echo 'export PATH="/opt/nanobrew/prefix/bin:$PATH"' >> "$SHELL_RC"
    echo "    Added /opt/nanobrew/prefix/bin to PATH in $SHELL_RC"
else
    echo "    PATH already configured in $SHELL_RC"
fi

echo ""
echo "==> nanobrew installed successfully!"
echo "    Run 'source $SHELL_RC' or open a new terminal, then:"
echo "    nb install <formula>"
