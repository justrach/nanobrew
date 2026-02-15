const REPO = "justrach/nanobrew";

const INSTALL_SCRIPT = `#!/bin/bash
set -euo pipefail

REPO="${REPO}"
INSTALL_DIR="/opt/nanobrew"
BIN_DIR="$INSTALL_DIR/prefix/bin"

echo ""
echo "  nanobrew — the fastest macOS package manager"
echo ""

# Check macOS
if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: nanobrew only supports macOS"
    exit 1
fi

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64) ARCH_LABEL="arm64" ;;
    x86_64)        ARCH_LABEL="x86_64" ;;
    *)
        echo "error: unsupported architecture: $ARCH"
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
echo "  Found $LATEST"

# Download binary
TARBALL="nb-\${ARCH_LABEL}-apple-darwin.tar.gz"
URL="https://github.com/$REPO/releases/download/$LATEST/$TARBALL"

echo "  Downloading nb (\${ARCH_LABEL})..."
TMPDIR_DL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DL"' EXIT

curl -fsSL "$URL" -o "$TMPDIR_DL/$TARBALL"
tar -xzf "$TMPDIR_DL/$TARBALL" -C "$TMPDIR_DL"

# Create directories
echo "  Creating directories..."
if [ ! -d "$INSTALL_DIR" ]; then
    sudo mkdir -p "$INSTALL_DIR"
    sudo chown -R "$(whoami)" "$INSTALL_DIR"
fi
mkdir -p "$BIN_DIR" \\
    "$INSTALL_DIR/cache/blobs" \\
    "$INSTALL_DIR/cache/tmp" \\
    "$INSTALL_DIR/cache/tokens" \\
    "$INSTALL_DIR/cache/api" \\
    "$INSTALL_DIR/prefix/Cellar" \\
    "$INSTALL_DIR/store" \\
    "$INSTALL_DIR/db"

# Install binary
cp "$TMPDIR_DL/nb" "$BIN_DIR/nb"
chmod +x "$BIN_DIR/nb"
echo "  Installed nb to $BIN_DIR/nb"

# Add to PATH
SHELL_RC="$HOME/.zshrc"
if [ -n "\${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ]; then
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
echo "    export PATH=\\"/opt/nanobrew/prefix/bin:\\$PATH\\""
echo ""
echo "  Then:"
echo ""
echo "    nb install ffmpeg"
echo ""
`;

const LANDING_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nanobrew</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    background: #0a0a0a;
    color: #e5e5e5;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 2rem;
  }
  h1 {
    font-size: 3rem;
    font-weight: 700;
    margin-bottom: 0.5rem;
    background: linear-gradient(135deg, #60a5fa, #a78bfa);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
  }
  .tagline {
    font-size: 1.15rem;
    color: #a3a3a3;
    margin-bottom: 2.5rem;
  }
  .install-box {
    background: #171717;
    border: 1px solid #262626;
    border-radius: 12px;
    padding: 1.25rem 1.75rem;
    font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', monospace;
    font-size: 0.95rem;
    color: #e5e5e5;
    position: relative;
    max-width: 600px;
    width: 100%;
    cursor: pointer;
    transition: border-color 0.2s;
  }
  .install-box:hover { border-color: #404040; }
  .prompt { color: #737373; }
  .cmd { color: #60a5fa; }
  .url { color: #a78bfa; }
  .copy-btn {
    position: absolute;
    right: 1rem;
    top: 50%;
    transform: translateY(-50%);
    background: none;
    border: 1px solid #333;
    border-radius: 6px;
    color: #737373;
    padding: 0.35rem 0.5rem;
    cursor: pointer;
    font-size: 0.8rem;
    transition: all 0.2s;
  }
  .copy-btn:hover { color: #e5e5e5; border-color: #555; }
  .note {
    margin-top: 1.5rem;
    font-size: 0.9rem;
    color: #737373;
  }
  .note code {
    background: #171717;
    padding: 0.15rem 0.4rem;
    border-radius: 4px;
  }
  .links {
    margin-top: 2rem;
    display: flex;
    gap: 1.5rem;
    font-size: 0.9rem;
  }
  .links a {
    color: #60a5fa;
    text-decoration: none;
    transition: color 0.2s;
  }
  .links a:hover { color: #93c5fd; }
</style>
</head>
<body>
  <h1>nanobrew</h1>
  <p class="tagline">The fastest macOS package manager. Written in Zig.</p>
  <div class="install-box" onclick="copyCmd()">
    <span class="prompt">$</span> <span class="cmd">curl -fsSL</span> <span class="url">https://nanobrew.trilok.ai/install</span> <span class="cmd">| bash</span>
    <button class="copy-btn" id="copyBtn">copy</button>
  </div>
  <p class="note">After install, run the <code>export</code> command it prints (or restart your terminal).</p>
  <div class="links">
    <a href="https://github.com/justrach/nanobrew">GitHub</a>
    <a href="https://github.com/justrach/nanobrew#performance-snapshot">Benchmarks</a>
    <a href="https://github.com/justrach/nanobrew#how-it-works">How it works</a>
  </div>
  <script>
    function copyCmd() {
      navigator.clipboard.writeText('curl -fsSL https://nanobrew.trilok.ai/install | bash');
      const btn = document.getElementById('copyBtn');
      btn.textContent = 'copied!';
      setTimeout(() => btn.textContent = 'copy', 1500);
    }
  </script>
</body>
</html>`;

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const ua = (request.headers.get("user-agent") || "").toLowerCase();
    const isCurl = ua.includes("curl") || ua.includes("wget");

    if (url.pathname === "/install" || (url.pathname === "/" && isCurl)) {
      return new Response(INSTALL_SCRIPT, {
        headers: {
          "content-type": "text/plain; charset=utf-8",
          "cache-control": "public, max-age=300",
        },
      });
    }

    if (url.pathname === "/") {
      return new Response(LANDING_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=3600",
        },
      });
    }

    return Response.redirect("https://github.com/justrach/nanobrew", 302);
  },
};
