const REPO = "justrach/nanobrew";

const INSTALL_SCRIPT = `#!/bin/bash
set -euo pipefail

REPO="${REPO}"
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
            arm64|aarch64) TARBALL="nb-arm64-apple-darwin.tar.gz" ;;
            x86_64)        TARBALL="nb-x86_64-apple-darwin.tar.gz" ;;
            *) echo "error: unsupported architecture: $ARCH"; exit 1 ;;
        esac
        ;;
    Linux)
        case "$ARCH" in
            aarch64) TARBALL="nb-aarch64-linux.tar.gz" ;;
            x86_64)  TARBALL="nb-x86_64-linux.tar.gz" ;;
            *) echo "error: unsupported architecture: $ARCH"; exit 1 ;;
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
echo "  Found $LATEST"

# Download binary + SHA256 checksum
URL="https://github.com/$REPO/releases/download/$LATEST/$TARBALL"
SHA_URL="$URL.sha256"

echo "  Downloading $TARBALL..."
TMPDIR_DL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DL"' EXIT

curl -fsSL "$URL" -o "$TMPDIR_DL/$TARBALL"
curl -fsSL "$SHA_URL" -o "$TMPDIR_DL/$TARBALL.sha256" 2>/dev/null || true

# Verify SHA256 if checksum file was downloaded
if [ -s "$TMPDIR_DL/$TARBALL.sha256" ]; then
    EXPECTED=$(awk '{print $1}' "$TMPDIR_DL/$TARBALL.sha256")
    if command -v sha256sum &>/dev/null; then
        ACTUAL=$(sha256sum "$TMPDIR_DL/$TARBALL" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        ACTUAL=$(shasum -a 256 "$TMPDIR_DL/$TARBALL" | awk '{print $1}')
    else
        echo "  warning: no sha256sum/shasum found, skipping verification"
        ACTUAL="$EXPECTED"
    fi
    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "error: SHA256 checksum mismatch!"
        echo "  expected: $EXPECTED"
        echo "  actual:   $ACTUAL"
        exit 1
    fi
    echo "  SHA256 verified ✓"
fi

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
if [ "$OS" = "Linux" ]; then
    SHELL_RC="$HOME/.bashrc"
elif [ -n "\${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
else
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
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#FFFFFF">
<title>nanobrew — the fastest macOS package manager</title>
<meta name="description" content="Install macOS packages 7,000x faster than Homebrew. APFS clonefile, parallel deps, native Mach-O parsing. Written in Zig.">
<meta property="og:title" content="nanobrew">
<meta property="og:description" content="The fastest macOS package manager. 3.5ms warm installs. Written in Zig.">
<meta property="og:type" content="website">
<meta property="og:url" content="https://nanobrew.trilok.ai">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>⚡</text></svg>">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Syne:wght@700;800&family=IBM+Plex+Mono:ital,wght@0,400;0,500;0,600&display=swap" rel="stylesheet">
<style>
  :root {
    --gold: #FFB800;
    --gold-soft: rgba(255, 184, 0, 0.12);
    --gold-glow: rgba(255, 184, 0, 0.06);
    --bg: #FFFFFF;
    --surface: #F7F7F7;
    --surface-raised: #F0F0F0;
    --border: #E5E5E5;
    --border-bright: #D0D0D0;
    --text: #404040;
    --bright: #111111;
    --muted: #777;
    --dim: #AAAAAA;
    --dim-2: #D5D5D5;
    --brew-bar: #E8E8E8;
    --fd: 'Syne', system-ui, sans-serif;
    --fm: 'IBM Plex Mono', 'SF Mono', 'Fira Code', monospace;
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }
  html { scroll-behavior: smooth; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--fm);
    font-size: 15px;
    line-height: 1.65;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
    overflow-x: hidden;
  }

  /* Noise grain */
  body::after {
    content: '';
    position: fixed;
    inset: 0;
    background: url("data:image/svg+xml,%3Csvg viewBox='0 0 512 512' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.75' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.03'/%3E%3C/svg%3E");
    pointer-events: none;
    z-index: 9999;
  }

  .wrap { max-width: 820px; margin: 0 auto; padding: 0 2rem; }

  /* ── Nav ── */
  nav {
    padding: 1.5rem 0;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .nav-mark {
    font-family: var(--fd);
    font-weight: 800;
    font-size: 1rem;
    color: var(--bright);
    text-decoration: none;
    letter-spacing: 0.03em;
  }
  .nav-links { display: flex; gap: 1.75rem; font-size: 0.82rem; }
  .nav-links a { color: var(--muted); text-decoration: none; transition: color 0.2s; }
  .nav-links a:hover { color: var(--text); }

  /* ── Hero ── */
  .hero {
    padding: 7rem 0 5rem;
    text-align: center;
    position: relative;
  }
  .hero::before {
    content: '';
    position: absolute;
    top: -100px;
    left: 50%;
    transform: translateX(-50%);
    width: 700px;
    height: 500px;
    background: radial-gradient(ellipse, var(--gold-glow), transparent 70%);
    pointer-events: none;
    z-index: 0;
  }
  .hero > * { position: relative; z-index: 1; }

  .hero h1 {
    font-family: var(--fd);
    font-weight: 800;
    font-size: clamp(3.2rem, 9vw, 6rem);
    color: var(--bright);
    letter-spacing: -0.03em;
    line-height: 0.95;
    margin-bottom: 1.25rem;
    animation: fadeUp 0.7s ease-out both;
  }
  .hero .sub {
    font-size: 1.05rem;
    color: var(--muted);
    margin-bottom: 3rem;
    animation: fadeUp 0.7s ease-out 0.08s both;
  }
  .hero .sub strong { color: var(--gold); font-weight: 500; }

  /* Install box */
  .install {
    display: inline-flex;
    align-items: center;
    gap: 1rem;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 1rem 1.25rem 1rem 1.5rem;
    cursor: pointer;
    transition: border-color 0.3s, box-shadow 0.3s;
    animation: fadeUp 0.7s ease-out 0.16s both;
    font-size: 0.9rem;
  }
  .install:hover {
    border-color: var(--dim);
    box-shadow: 0 0 40px var(--gold-glow);
  }
  .install .p { color: var(--dim); user-select: none; }
  .install .c { color: var(--text); }
  .install .u { color: var(--gold); }
  .install .cp {
    background: none;
    border: 1px solid var(--border);
    border-radius: 5px;
    color: var(--muted);
    padding: 0.2rem 0.55rem;
    font-family: var(--fm);
    font-size: 0.72rem;
    cursor: pointer;
    transition: all 0.2s;
    flex-shrink: 0;
  }
  .install .cp:hover { color: var(--text); border-color: var(--dim); }
  .install-note {
    font-size: 0.78rem;
    color: var(--dim);
    margin-top: 1rem;
    animation: fadeUp 0.7s ease-out 0.24s both;
  }

  /* ── Big stat ── */
  .stat {
    padding: 5.5rem 0;
    text-align: center;
    border-top: 1px solid var(--border);
  }
  .stat-num {
    font-family: var(--fd);
    font-weight: 800;
    font-size: clamp(4.5rem, 14vw, 9rem);
    line-height: 1;
    letter-spacing: -0.04em;
    color: var(--gold);
    display: block;
    text-shadow: 0 0 80px var(--gold-soft);
    animation: fadeUp 0.8s ease-out 0.3s both;
  }
  .stat-label {
    font-size: 1rem;
    color: var(--muted);
    margin-top: 0.6rem;
    display: block;
    animation: fadeUp 0.8s ease-out 0.38s both;
  }
  .stat-ctx {
    font-size: 0.82rem;
    color: var(--dim);
    margin-top: 1.5rem;
    animation: fadeUp 0.8s ease-out 0.44s both;
  }
  .stat-ctx em { color: var(--muted); font-style: normal; font-weight: 500; }

  /* ── Benchmarks ── */
  .bench {
    padding: 5rem 0;
    border-top: 1px solid var(--border);
  }
  .bench h2 {
    font-family: var(--fd);
    font-weight: 700;
    font-size: 1.4rem;
    color: var(--bright);
    margin-bottom: 0.5rem;
    letter-spacing: -0.01em;
  }
  .bench-sub {
    font-size: 0.8rem;
    color: var(--dim);
    margin-bottom: 2.5rem;
  }
  .bg {
    margin-bottom: 2.25rem;
  }
  .bg-title {
    font-weight: 500;
    font-size: 0.88rem;
    color: var(--text);
    margin-bottom: 0.6rem;
  }
  .bg-title span { color: var(--dim); font-weight: 400; font-size: 0.82rem; }
  .br {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    margin-bottom: 0.35rem;
    height: 30px;
  }
  .br-l {
    width: 3rem;
    text-align: right;
    font-size: 0.72rem;
    color: var(--muted);
    flex-shrink: 0;
  }
  .br-t {
    flex: 1;
    height: 100%;
    background: var(--surface);
    border-radius: 4px;
    overflow: hidden;
  }
  .br-b {
    height: 100%;
    border-radius: 4px;
    display: flex;
    align-items: center;
    padding: 0 0.7rem;
    font-size: 0.72rem;
    font-weight: 500;
    white-space: nowrap;
    width: 0;
    transition: width 1.2s cubic-bezier(0.22, 1, 0.36, 1);
  }
  .br-b.brew { background: var(--brew-bar); color: var(--muted); }
  .br-b.nb { background: var(--gold); color: var(--bg); }

  .bg.visible .br:nth-child(2) .br-b { transition-delay: 0s; }
  .bg.visible .br:nth-child(3) .br-b { transition-delay: 0.12s; }
  .bg.visible .br:nth-child(4) .br-b { transition-delay: 0.24s; }

  .bg-note {
    font-size: 0.72rem;
    color: var(--gold);
    margin-top: 0.35rem;
    padding-left: 3.6rem;
    font-weight: 500;
    opacity: 0;
    transition: opacity 0.5s 0.6s;
  }
  .bg.visible .bg-note { opacity: 1; }

  /* ── Terminal demo ── */
  .demo {
    padding: 4.5rem 0;
    border-top: 1px solid var(--border);
  }
  .demo h2 {
    font-family: var(--fd);
    font-weight: 700;
    font-size: 1.4rem;
    color: var(--bright);
    margin-bottom: 2rem;
    letter-spacing: -0.01em;
  }
  .term {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
    font-size: 0.82rem;
    line-height: 1.7;
  }
  .term-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0.7rem 1rem;
    background: var(--surface-raised);
    border-bottom: 1px solid var(--border);
  }
  .term-dot { width: 10px; height: 10px; border-radius: 50%; }
  .term-dot.r { background: #FF5F57; }
  .term-dot.y { background: #FEBC2E; }
  .term-dot.g { background: #28C840; }
  .term-body { padding: 1.25rem 1.5rem; }
  .term-body .line { opacity: 0; animation: termLine 0.3s ease-out forwards; }
  .term-body .prompt-line { color: var(--bright); }
  .term-body .dim { color: var(--dim); }
  .term-body .gold { color: var(--gold); }
  .term-body .grn { color: #4ADE80; }
  .term-body .cmt { color: var(--dim); }

  /* ── Features ── */
  .feat {
    padding: 5rem 0;
    border-top: 1px solid var(--border);
  }
  .feat h2 {
    font-family: var(--fd);
    font-weight: 700;
    font-size: 1.4rem;
    color: var(--bright);
    margin-bottom: 2rem;
    letter-spacing: -0.01em;
  }
  .feat-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 1px;
    background: var(--border);
    border: 1px solid var(--border);
    border-radius: 10px;
    overflow: hidden;
  }
  .feat-card {
    background: var(--surface);
    padding: 1.5rem;
    transition: background 0.25s;
  }
  .feat-card:hover { background: var(--surface-raised); }
  .feat-card h3 {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--bright);
    margin-bottom: 0.3rem;
  }
  .feat-card p {
    font-size: 0.78rem;
    color: var(--muted);
    line-height: 1.55;
  }

  /* ── Pipeline ── */
  .pipe {
    padding: 4.5rem 0;
    border-top: 1px solid var(--border);
  }
  .pipe h2 {
    font-family: var(--fd);
    font-weight: 700;
    font-size: 1.4rem;
    color: var(--bright);
    margin-bottom: 2rem;
  }
  .pipe-row {
    display: flex;
    gap: 0;
  }
  .pipe-step {
    flex: 1;
    padding: 1.25rem 1rem;
    border-left: 2px solid var(--border);
    transition: border-color 0.3s;
  }
  .pipe-step:first-child { border-color: var(--gold); }
  .pipe-step:hover { border-color: var(--gold); }
  .pipe-step .n {
    font-size: 0.65rem;
    color: var(--dim);
    text-transform: uppercase;
    letter-spacing: 0.08em;
    margin-bottom: 0.15rem;
  }
  .pipe-step .t {
    font-weight: 600;
    font-size: 0.85rem;
    color: var(--bright);
    margin-bottom: 0.2rem;
  }
  .pipe-step .d {
    font-size: 0.75rem;
    color: var(--muted);
  }

  /* ── Footer ── */
  footer {
    padding: 3rem 0;
    border-top: 1px solid var(--border);
    text-align: center;
    font-size: 0.78rem;
    color: var(--dim);
  }
  .foot-links {
    display: flex;
    justify-content: center;
    gap: 2rem;
    margin-bottom: 1rem;
  }
  footer a { color: var(--muted); text-decoration: none; transition: color 0.2s; }
  footer a:hover { color: var(--text); }
  code { font-family: var(--fm); background: var(--surface-raised); padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.9em; }

  /* ── Animations ── */
  @keyframes fadeUp {
    from { opacity: 0; transform: translateY(20px); }
    to { opacity: 1; transform: translateY(0); }
  }
  @keyframes termLine {
    from { opacity: 0; transform: translateX(-6px); }
    to { opacity: 1; transform: translateX(0); }
  }

  /* ── Responsive ── */
  @media (max-width: 768px) {
    .wrap { padding: 0 1.25rem; }
    .hero { padding: 5rem 0 3.5rem; }
    .install {
      width: 100%;
      font-size: 0.78rem;
      gap: 0.6rem;
      overflow-x: auto;
    }
    .feat-grid { grid-template-columns: 1fr; }
    .pipe-row { flex-direction: column; }
    .pipe-step { border-left: 2px solid var(--border); padding: 1rem 1.25rem; }
    .pipe-step:first-child { border-color: var(--gold); }
    .stat-num { font-size: clamp(3rem, 14vw, 9rem); }
  }
  @media (max-width: 480px) {
    .feat-grid { grid-template-columns: 1fr; }
    .nav-links { gap: 1rem; font-size: 0.78rem; }
    .hero h1 { font-size: clamp(2.5rem, 12vw, 4rem); }
  }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <a href="/" class="nav-mark">nanobrew</a>
    <div class="nav-links">
      <a href="https://github.com/justrach/nanobrew">GitHub</a>
      <a href="https://github.com/justrach/nanobrew#how-it-works">Docs</a>
      <a href="https://github.com/justrach/nanobrew#performance-snapshot">Benchmarks</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew</h1>
    <p class="sub">The fastest macOS package manager. Written in <strong>Zig</strong>.</p>
    <div class="install" onclick="copyCmd()">
      <span><span class="p">$</span> <span class="c">curl -fsSL</span> <span class="u">https://nanobrew.trilok.ai/install</span> <span class="c">| bash</span></span>
      <button class="cp" id="cpBtn">copy</button>
    </div>
    <p class="install-note">Then restart your terminal or run the export command it prints.</p>
  </section>

  <section class="stat">
    <span class="stat-num">39ms</span>
    <span class="stat-label">warm install &middot; with full security checks</span>
    <p class="stat-ctx"><em>230x</em> faster than Homebrew &middot; 0.1ms for no-ops</p>
  </section>

  <section class="bench">
    <h2>Speed</h2>
    <p class="bench-sub">Apple Silicon, macOS 15, same network. Cold = fresh download. Warm = cached in store.</p>

    <div class="bg">
      <div class="bg-title">tree <span>/ 0 deps, cold</span></div>
      <div class="br">
        <span class="br-l">brew</span>
        <div class="br-t"><div class="br-b brew" data-w="100%">8.99s</div></div>
      </div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="13.2%">1.19s</div></div>
      </div>
      <div class="bg-note">7.6x faster</div>
    </div>

    <div class="bg">
      <div class="bg-title">wget <span>/ 6 deps, cold</span></div>
      <div class="br">
        <span class="br-l">brew</span>
        <div class="br-t"><div class="br-b brew" data-w="100%">16.84s</div></div>
      </div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="66.9%">11.26s</div></div>
      </div>
      <div class="bg-note">1.5x faster</div>
    </div>

    <div class="bg">
      <div class="bg-title">ffmpeg <span>/ 11 deps, warm</span></div>
      <div class="br">
        <span class="br-l">brew</span>
        <div class="br-t"><div class="br-b brew" data-w="100%">~24.5s</div></div>
      </div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="1.5%">3.5ms</div></div>
      </div>
      <div class="bg-note">7,000x faster</div>
    </div>
  </section>

  <section class="bench">
    <h2>What shipped in v0.1.082</h2>
    <p class="bench-sub">Recent fixes across install state, self-update, release automation, and the open-issue batch are now reflected in the current patch line.</p>

    <div class="bg">
      <div class="bg-title">🛡 security</div>
      <div class="br">
        <span class="br-l">patched</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">21 vulnerabilities — RCE, path traversal, injection, binary corruption</div></div>
      </div>
      <div class="bg-note">Shell injection in decompression &middot; JSON injection in DB &middot; self-update was curl|bash &middot; Mach-O binary guard</div>
    </div>

    <div class="bg">
      <div class="bg-title">🔧 broken packages</div>
      <div class="br">
        <span class="br-l">fixed</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">aws, pip3, c_rehash, wheel3 — all script packages work now</div></div>
      </div>
      <div class="bg-note">@@HOMEBREW_CELLAR@@ placeholders replaced in shebangs &middot; handles read-only files (0o555)</div>
    </div>

    <div class="bg">
      <div class="bg-title">✨ new commands</div>
      <div class="br">
        <span class="br-l">added</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">nb migrate &middot; nb info --cask &middot; nb bundle install</div></div>
      </div>
      <div class="bg-note">Import from Homebrew &middot; cask metadata &middot; Brewfile support with instant no-ops</div>
    </div>

    <div class="bg">
      <div class="bg-title">🚀 quality of life</div>
      <div class="br">
        <span class="br-l">added</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">no sudo after init &middot; clear errors &middot; no Gatekeeper quarantine on casks</div></div>
      </div>
      <div class="bg-note">sudo nb init chowns to your user &middot; failed packages listed with hint &middot; apps just open</div>
    </div>

    <div class="bg">
      <div class="bg-title">🧪 testing</div>
      <div class="br">
        <span class="br-l">before</span>
        <div class="br-t"><div class="br-b brew" data-w="68%">103 tests</div></div>
      </div>
      <div class="br">
        <span class="br-l">after</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">150 tests + adversarial security suite</div></div>
      </div>
      <div class="bg-note">+47 tests &middot; path traversal &middot; JSON injection &middot; null bytes &middot; version string attacks</div>
    </div>
  </section>
    <div class="term">
      <div class="term-bar">
        <span class="term-dot r"></span>
        <span class="term-dot y"></span>
        <span class="term-dot g"></span>
      </div>
      <div class="term-body">
        <div class="line prompt-line" style="animation-delay:0.2s">$ nb install jq</div>
        <div class="line dim" style="animation-delay:0.5s">==> Resolving dependencies...</div>
        <div class="line dim" style="animation-delay:0.7s">&nbsp;&nbsp;&nbsp;&nbsp;[38ms]</div>
        <div class="line dim" style="animation-delay:0.9s">==> Installing 1 package(s):</div>
        <div class="line dim" style="animation-delay:1.0s">&nbsp;&nbsp;&nbsp;&nbsp;jq 1.7.1</div>
        <div class="line dim" style="animation-delay:1.2s">==> Downloading + installing 1 packages...</div>
        <div class="line grn" style="animation-delay:1.6s">&nbsp;&nbsp;&nbsp;&nbsp;&#10003; jq</div>
        <div class="line gold" style="animation-delay:1.8s">==> Done in 1102.4ms</div>
        <div class="line" style="animation-delay:2.2s">&nbsp;</div>
        <div class="line prompt-line" style="animation-delay:2.4s">$ nb list</div>
        <div class="line" style="animation-delay:2.7s">jq 1.7.1</div>
        <div class="line" style="animation-delay:2.9s">&nbsp;</div>
        <div class="line prompt-line" style="animation-delay:3.2s">$ nb update <span class="cmt"># self-update nanobrew</span></div>
        <div class="line gold" style="animation-delay:3.5s">==> Updating nanobrew...</div>
        <div class="line grn" style="animation-delay:3.9s">==> nanobrew updated successfully</div>
      </div>
    </div>
  </section>

  <section class="pipe">
    <h2>How it works</h2>
    <div class="pipe-row">
      <div class="pipe-step">
        <div class="n">01</div>
        <div class="t">Resolve</div>
        <div class="d">BFS parallel dependency resolution across concurrent API calls</div>
      </div>
      <div class="pipe-step">
        <div class="n">02</div>
        <div class="t">Download</div>
        <div class="d">Native HTTP with streaming SHA256 verification in a single pass</div>
      </div>
      <div class="pipe-step">
        <div class="n">03</div>
        <div class="t">Extract</div>
        <div class="d">Unpack into content-addressable store keyed by SHA256</div>
      </div>
      <div class="pipe-step">
        <div class="n">04</div>
        <div class="t">Materialize</div>
        <div class="d">APFS clonefile into Cellar &mdash; copy-on-write, zero disk cost</div>
      </div>
      <div class="pipe-step">
        <div class="n">05</div>
        <div class="t">Link</div>
        <div class="d">Symlink binaries into PATH and record in local database</div>
      </div>
    </div>
  </section>

  <section class="feat">
    <h2>Why it's fast</h2>
    <div class="feat-grid">
      <div class="feat-card">
        <h3>APFS clonefile</h3>
        <p>Copy-on-write materialization via macOS syscall. Zero disk overhead per install.</p>
      </div>
      <div class="feat-card">
        <h3>Parallel everything</h3>
        <p>Downloads, extraction, relocation, and dependency resolution all run concurrently.</p>
      </div>
      <div class="feat-card">
        <h3>Native HTTP</h3>
        <p>Zig std.http.Client replaces curl subprocess spawns. One fewer process per bottle.</p>
      </div>
      <div class="feat-card">
        <h3>Native Mach-O</h3>
        <p>Reads load commands from binary headers directly. No otool. Batched codesign.</p>
      </div>
      <div class="feat-card">
        <h3>Content-addressed store</h3>
        <p>SHA256-keyed dedup means reinstalls skip download and extraction entirely.</p>
      </div>
      <div class="feat-card">
        <h3>Single static binary</h3>
        <p>No Ruby runtime. No interpreter startup. No config sprawl. Just one ~2MB binary.</p>
      </div>
    </div>
  </section>

  <footer>
    <div class="foot-links">
      <a href="https://github.com/justrach/nanobrew">GitHub</a>
      <a href="https://github.com/justrach/nanobrew#performance-snapshot">Benchmarks</a>
      <a href="https://github.com/justrach/nanobrew/blob/main/LICENSE">Apache 2.0</a>
    </div>
    <p>Built with care. Powered by Homebrew's bottle ecosystem.</p>
  </footer>
</div>

<script>
function copyCmd() {
  navigator.clipboard.writeText('curl -fsSL https://nanobrew.trilok.ai/install | bash');
  var box = document.querySelector('.install');
  var btn = document.getElementById('cpBtn');
  box.style.borderColor = '#FFB800';
  box.style.boxShadow = '0 0 40px rgba(255,184,0,0.15)';
  btn.textContent = 'copied!';
  btn.style.color = '#FFB800';
  setTimeout(function() {
    box.style.borderColor = '';
    box.style.boxShadow = '';
    btn.textContent = 'copy';
    btn.style.color = '';
  }, 1500);
}

// Animate benchmark bars on scroll
var obs = new IntersectionObserver(function(entries) {
  entries.forEach(function(e) {
    if (e.isIntersecting) {
      e.target.classList.add('visible');
      var bars = e.target.querySelectorAll('.br-b');
      bars.forEach(function(b) { b.style.width = b.getAttribute('data-w'); });
      obs.unobserve(e.target);
    }
  });
}, { threshold: 0.25 });
document.querySelectorAll('.bg').forEach(function(el) { obs.observe(el); });
</script>
</body>
</html>`;

const VERSION_CACHE_TTL = 300; // 5 minutes

const APT_GET_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nanobrew vs apt-get — up to 13x faster</title>
<meta name="description" content="nanobrew is a drop-in apt-get replacement for Linux. 7-13x faster warm installs. Native Zig tar, NBIX binary cache, 8-thread parallel extraction.">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>⚡</text></svg>">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root {
    --gold: #FFB800;
    --gold-soft: rgba(255, 184, 0, 0.12);
    --bg: #FFFFFF;
    --surface: #F7F7F7;
    --border: #E5E5E5;
    --text: #404040;
    --bright: #111111;
    --muted: #777;
    --dim: #AAAAAA;
    --apt-bar: #E8E8E8;
    --fd: 'Inter', system-ui, -apple-system, sans-serif;
    --fm: 'JetBrains Mono', 'SF Mono', 'Fira Code', monospace;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    background: var(--bg); color: var(--text);
    font-family: var(--fm); font-size: 15px; line-height: 1.65;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 820px; margin: 0 auto; padding: 0 2rem; }

  nav { padding: 1.5rem 0; display: flex; justify-content: space-between; align-items: center; }
  .nav-mark { font-family: var(--fd); font-weight: 700; font-size: 1rem; color: var(--bright); text-decoration: none; }
  .nav-links { display: flex; gap: 1.5rem; }
  .nav-links a { color: var(--muted); text-decoration: none; font-size: 0.82rem; font-weight: 500; }
  .nav-links a:hover { color: var(--bright); }

  @keyframes fadeUp { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }

  .hero { padding: 4rem 0 3rem; text-align: center; }
  .hero h1 {
    font-family: var(--fd); font-weight: 700;
    font-size: clamp(1.8rem, 4.5vw, 2.6rem);
    color: var(--bright); letter-spacing: -0.02em; line-height: 1.15;
    animation: fadeUp 0.7s ease-out both;
  }
  .hero h1 em { color: var(--gold); font-style: normal; }
  .hero p {
    font-size: 1rem; color: var(--muted); margin-top: 1rem; max-width: 560px; margin-inline: auto;
    animation: fadeUp 0.7s ease-out 0.12s both;
  }
  .hero code {
    display: inline-block; margin-top: 1.5rem; padding: 0.6rem 1.4rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
    font-size: 0.88rem; color: var(--bright); font-weight: 500;
    animation: fadeUp 0.7s ease-out 0.24s both;
  }

  .stat {
    padding: 4rem 0; text-align: center; border-top: 1px solid var(--border);
  }
  .stat-num {
    font-family: var(--fd); font-weight: 900;
    font-size: clamp(3.5rem, 10vw, 6rem);
    color: var(--gold); line-height: 1; letter-spacing: -0.03em;
    text-shadow: 0 0 80px var(--gold-soft);
    animation: fadeUp 0.8s ease-out 0.3s both;
  }
  .stat-label { font-size: 1rem; color: var(--muted); margin-top: 0.6rem; animation: fadeUp 0.8s ease-out 0.38s both; }
  .stat-ctx { font-size: 0.82rem; color: var(--dim); margin-top: 1.5rem; animation: fadeUp 0.8s ease-out 0.44s both; }
  .stat-ctx em { color: var(--muted); font-style: normal; font-weight: 500; }

  .bench { padding: 4rem 0; border-top: 1px solid var(--border); }
  .bench h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .bench-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 2.5rem; }

  .bg { margin-bottom: 2.5rem; }
  .bg-title { font-weight: 500; font-size: 0.88rem; color: var(--text); margin-bottom: 0.6rem; }
  .bg-title span { color: var(--dim); font-weight: 400; font-size: 0.82rem; }
  .br { display: flex; align-items: center; gap: 0.6rem; margin-bottom: 0.35rem; height: 30px; }
  .br-l { width: 4.5rem; text-align: right; font-size: 0.72rem; color: var(--muted); flex-shrink: 0; }
  .br-t { flex: 1; height: 100%; background: var(--surface); border-radius: 4px; overflow: hidden; }
  .br-b {
    height: 100%; border-radius: 4px; display: flex; align-items: center;
    padding: 0 0.7rem; font-size: 0.72rem; font-weight: 500; white-space: nowrap;
    width: 0; transition: width 1.2s cubic-bezier(0.22, 1, 0.36, 1);
  }
  .br-b.apt { background: var(--apt-bar); color: var(--muted); }
  .br-b.nb { background: var(--gold); color: var(--bg); }
  .bg.visible .br:nth-child(2) .br-b { transition-delay: 0s; }
  .bg.visible .br:nth-child(3) .br-b { transition-delay: 0.12s; }
  .bg-note {
    font-size: 0.72rem; color: var(--gold); margin-top: 0.35rem;
    padding-left: 5.1rem; font-weight: 500; opacity: 0; transition: opacity 0.5s 0.6s;
  }
  .bg.visible .bg-note { opacity: 1; }

  .how { padding: 4rem 0; border-top: 1px solid var(--border); }
  .how h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 1.5rem; }
  .how-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1.5rem; }
  .how-card {
    padding: 1.5rem; background: var(--surface); border-radius: 8px; border: 1px solid var(--border);
  }
  .how-card h3 { font-size: 0.9rem; color: var(--bright); margin-bottom: 0.4rem; }
  .how-card p { font-size: 0.78rem; color: var(--muted); line-height: 1.5; }
  .how-card .num { font-family: var(--fd); font-weight: 800; font-size: 1.4rem; color: var(--gold); margin-bottom: 0.3rem; }

  .method { padding: 4rem 0; border-top: 1px solid var(--border); }
  .method h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .method-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 1.5rem; }
  .method table { width: 100%; border-collapse: collapse; font-size: 0.82rem; }
  .method th { text-align: left; padding: 0.6rem 0.8rem; border-bottom: 2px solid var(--border); color: var(--muted); font-weight: 500; }
  .method td { padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--border); }
  .method td:last-child { font-weight: 600; color: var(--gold); }

  footer { padding: 3rem 0; border-top: 1px solid var(--border); text-align: center; font-size: 0.75rem; color: var(--dim); }
  footer a { color: var(--muted); }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <a class="nav-mark" href="/">nanobrew</a>
    <div class="nav-links">
      <a href="https://github.com/justrach/nanobrew">GitHub</a>
      <a href="https://github.com/justrach/nanobrew#install">Install</a>
      <a href="/">macOS benchmarks</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew vs apt-get<br><em>up to 13x faster</em></h1>
    <p>A drop-in apt-get replacement for Linux and Docker. Pure Zig. 8-thread parallel everything. Binary index cache.</p>
    <code>nb install --deb curl wget tree jq htop tmux</code>
  </section>

  <section class="stat">
    <span class="stat-num">13x</span>
    <span class="stat-label">faster than apt-get on warm installs</span>
    <p class="stat-ctx"><em>build-essential</em> (116 deps): apt-get 43.8s vs nanobrew 3.4s</p>
  </section>

  <section class="bench">
    <h2>Verified benchmarks</h2>
    <p class="bench-sub">Ubuntu 24.04.4 LTS, aarch64, Docker/Colima, median of 3 runs per test</p>

    <div class="bg" data-observe>
      <div class="bg-title">curl wget <span>35 dependencies</span></div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%">3,426ms</div></div></div>
      <div class="br"><div class="br-l">nanobrew</div><div class="br-t"><div class="br-b nb" style="width:13%">448ms</div></div></div>
      <div class="bg-note">7.6x faster</div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-title">curl wget tree jq htop tmux <span>53 dependencies</span></div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%">3,584ms</div></div></div>
      <div class="br"><div class="br-l">nanobrew</div><div class="br-t"><div class="br-b nb" style="width:14.5%">521ms</div></div></div>
      <div class="bg-note">6.9x faster</div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-title">git vim build-essential <span>116 dependencies</span></div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%">43,833ms</div></div></div>
      <div class="br"><div class="br-l">nanobrew</div><div class="br-t"><div class="br-b nb" style="width:7.8%">3,402ms</div></div></div>
      <div class="bg-note">12.9x faster</div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-title">nginx redis-server postgresql-client <span>78 dependencies</span></div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%">5,501ms</div></div></div>
      <div class="br"><div class="br-l">nanobrew</div><div class="br-t"><div class="br-b nb" style="width:25.5%">1,402ms</div></div></div>
      <div class="bg-note">3.9x faster</div>
    </div>
  </section>

  <section class="how">
    <h2>How it's fast</h2>
    <div class="how-grid">
      <div class="how-card">
        <div class="num">32ms</div>
        <h3>NBIX binary cache</h3>
        <p>70K packages deserialized from a compact binary format. Skips 20MB HTTP download + 72MB gzip decompress + text parsing entirely.</p>
      </div>
      <div class="how-card">
        <div class="num">8</div>
        <h3>Thread pool</h3>
        <p>Parallel .deb downloads with HTTP connection reuse, plus parallel ar/gzip/tar extraction. Work-stealing across 8 threads.</p>
      </div>
      <div class="how-card">
        <div class="num">0</div>
        <h3>Subprocess calls</h3>
        <p>Native Zig USTAR/GNU tar parser. No fork/exec for ar, tar, gzip, or dpkg. Single static binary, instant startup.</p>
      </div>
      <div class="how-card">
        <div class="num">1</div>
        <h3>deinit() to free all</h3>
        <p>Arena allocator wraps all 70K parsed packages. One call frees everything. No per-field deallocation overhead.</p>
      </div>
    </div>
  </section>

  <section class="method">
    <h2>Methodology</h2>
    <p class="method-sub">All benchmarks run in Docker (ubuntu:24.04) via Colima on Apple Silicon. Reproducible via <code>bench/</code> in the repo.</p>
    <table>
      <tr><th>Condition</th><th>Detail</th></tr>
      <tr><td>apt-get baseline</td><td>Index pre-cached via <code>apt-get update</code> in Dockerfile. Measures install only.</td></tr>
      <tr><td>nanobrew warm</td><td>NBIX index cache + .deb blob cache populated from prior cold run. <code>--skip-postinst</code>.</td></tr>
      <tr><td>Runs</td><td>3 per test, median reported</td></tr>
      <tr><td>Variance</td><td>&lt;4% across all warm runs (e.g. 519, 521, 523ms for medium suite)</td></tr>
      <tr><td>Reproduce</td><td><code>docker build -t nb-bench bench/ && docker run --rm nb-bench</code></td></tr>
    </table>
  </section>

  <footer>
    <p>nanobrew v0.1.082 &mdash; <a href="https://github.com/justrach/nanobrew">GitHub</a> &mdash; Apache-2.0</p>
  </footer>
</div>
<script>
const obs = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) e.target.classList.add('visible'); }), { threshold: 0.2 });
document.querySelectorAll('[data-observe]').forEach(el => obs.observe(el));
</script>
</body>
</html>`;

const RELEASE_190_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nanobrew v0.1.190 — Zig 0.16 + faster everything</title>
<meta name="description" content="nanobrew v0.1.190: Zig 0.16.0 compiler, native tar extraction, persistent HTTP, O(1) dep resolution, and 15+ correctness fixes. 11.8x faster than Homebrew on warm installs.">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>⚡</text></svg>">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root {
    --gold: #FFB800;
    --gold-soft: rgba(255, 184, 0, 0.12);
    --bg: #FFFFFF;
    --surface: #F7F7F7;
    --border: #E5E5E5;
    --text: #404040;
    --bright: #111111;
    --muted: #777;
    --dim: #AAAAAA;
    --apt-bar: #E8E8E8;
    --fd: 'Inter', system-ui, -apple-system, sans-serif;
    --fm: 'JetBrains Mono', 'SF Mono', 'Fira Code', monospace;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    background: var(--bg); color: var(--text);
    font-family: var(--fm); font-size: 15px; line-height: 1.65;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 820px; margin: 0 auto; padding: 0 2rem; }

  nav { padding: 1.5rem 0; display: flex; justify-content: space-between; align-items: center; }
  .nav-mark { font-family: var(--fd); font-weight: 700; font-size: 1rem; color: var(--bright); text-decoration: none; }
  .nav-links { display: flex; gap: 1.5rem; }
  .nav-links a { color: var(--muted); text-decoration: none; font-size: 0.82rem; font-weight: 500; }
  .nav-links a:hover { color: var(--bright); }

  @keyframes fadeUp { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }

  .hero { padding: 4rem 0 3rem; text-align: center; }
  .hero h1 {
    font-family: var(--fd); font-weight: 700;
    font-size: clamp(1.8rem, 4.5vw, 2.6rem);
    color: var(--bright); letter-spacing: -0.02em; line-height: 1.15;
    animation: fadeUp 0.7s ease-out both;
  }
  .hero h1 em { color: var(--gold); font-style: normal; }
  .hero p {
    font-size: 1rem; color: var(--muted); margin-top: 1rem; max-width: 560px; margin-inline: auto;
    animation: fadeUp 0.7s ease-out 0.12s both;
  }
  .hero code {
    display: inline-block; margin-top: 1.5rem; padding: 0.6rem 1.4rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
    font-size: 0.88rem; color: var(--bright); font-weight: 500;
    animation: fadeUp 0.7s ease-out 0.24s both;
  }

  .stat {
    padding: 4rem 0; text-align: center; border-top: 1px solid var(--border);
  }
  .stat-num {
    font-family: var(--fd); font-weight: 900;
    font-size: clamp(3.5rem, 10vw, 6rem);
    color: var(--gold); line-height: 1; letter-spacing: -0.03em;
    text-shadow: 0 0 80px var(--gold-soft);
    animation: fadeUp 0.8s ease-out 0.3s both;
  }
  .stat-label { font-size: 1rem; color: var(--muted); margin-top: 0.6rem; animation: fadeUp 0.8s ease-out 0.38s both; }
  .stat-ctx { font-size: 0.82rem; color: var(--dim); margin-top: 1.5rem; animation: fadeUp 0.8s ease-out 0.44s both; }
  .stat-ctx em { color: var(--muted); font-style: normal; font-weight: 500; }

  .bench { padding: 4rem 0; border-top: 1px solid var(--border); }
  .bench h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .bench-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 2.5rem; }

  .bg { margin-bottom: 2.8rem; }
  .bg-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.9rem; }
  .bg-title { font-family: var(--fd); font-weight: 700; font-size: 0.95rem; color: var(--bright); }
  .bg-title span { color: var(--muted); font-weight: 400; font-size: 0.82rem; margin-left: 0.4rem; }
  .bg-badge {
    font-family: var(--fd); font-weight: 800; font-size: 0.82rem; color: #92400e;
    background: rgba(251,191,36,0.15); border: 1px solid rgba(251,191,36,0.35);
    padding: 0.2rem 0.75rem; border-radius: 20px;
    opacity: 0; transform: translateY(4px); transition: opacity 0.4s 0.9s, transform 0.4s 0.9s;
  }
  .bg.visible .bg-badge { opacity: 1; transform: none; }
  .br { display: flex; align-items: center; gap: 0.7rem; margin-bottom: 0.45rem; }
  .br-l { width: 5rem; text-align: right; font-size: 0.72rem; color: var(--muted); flex-shrink: 0; font-weight: 500; }
  .br-t { flex: 1; height: 40px; background: var(--surface); border-radius: 6px; overflow: hidden; }
  .br-b {
    height: 100%; border-radius: 6px;
    width: 0; transition: width 1.3s cubic-bezier(0.16, 1, 0.3, 1);
  }
  .br-b.apt { background: #E4E4E4; }
  .br-b.old { background: linear-gradient(90deg, #FFC84A 0%, #FFB800 100%); opacity: 0.6; }
  .br-b.nb  { background: linear-gradient(90deg, #FFB800 0%, #FF8000 100%); box-shadow: 0 2px 16px rgba(255,140,0,0.22); }
  .bg.visible .br:nth-child(1) .br-b { transition-delay: 0s; }
  .bg.visible .br:nth-child(2) .br-b { transition-delay: 0.15s; }
  .bg.visible .br:nth-child(3) .br-b { transition-delay: 0.30s; }
  .br-time { font-size: 0.76rem; font-family: var(--fd); font-weight: 600; flex-shrink: 0; width: 3.8rem; }
  .br-time.brew-t { color: var(--dim); }
  .br-time.old-t  { color: #b45309; }
  .br-time.nb-t   { color: #c05621; }

  .how { padding: 4rem 0; border-top: 1px solid var(--border); }
  .how h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 1.5rem; }
  .how-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1.5rem; }
  .how-card {
    padding: 1.5rem; background: var(--surface); border-radius: 8px; border: 1px solid var(--border);
  }
  .how-card h3 { font-size: 0.9rem; color: var(--bright); margin-bottom: 0.4rem; }
  .how-card p { font-size: 0.78rem; color: var(--muted); line-height: 1.5; }
  .how-card .num { font-family: var(--fd); font-weight: 800; font-size: 1.4rem; color: var(--gold); margin-bottom: 0.3rem; }

  .method { padding: 4rem 0; border-top: 1px solid var(--border); }
  .method h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .method-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 1.5rem; }
  .method table { width: 100%; border-collapse: collapse; font-size: 0.82rem; }
  .method th { text-align: left; padding: 0.6rem 0.8rem; border-bottom: 2px solid var(--border); color: var(--muted); font-weight: 500; }
  .method td { padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--border); }
  .method td:last-child { font-weight: 600; color: var(--gold); }

  footer { padding: 3rem 0; border-top: 1px solid var(--border); text-align: center; font-size: 0.75rem; color: var(--dim); }
  footer a { color: var(--muted); }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <a class="nav-mark" href="/">nanobrew</a>
    <div class="nav-links">
      <a href="https://github.com/justrach/nanobrew">GitHub</a>
      <a href="https://github.com/justrach/nanobrew#install">Install</a>
      <a href="/">macOS benchmarks</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew v0.1.190<br><em>Zig 0.16 + faster everything</em></h1>
    <p>Zig 0.16.0 compiler, native tar extraction, persistent HTTP, O(1) dep resolution, and 15+ correctness fixes.</p>
    <code>nb update  # to v0.1.190</code>
  </section>

  <section class="stat">
    <span class="stat-num">140x</span>
    <span class="stat-label">faster than Homebrew on warm installs</span>
    <p class="stat-ctx"><em>tree</em> warm: Homebrew 2.38s &rarr; v0.1.083 23ms &rarr; <em>v0.1.190 17ms</em></p>
  </section>

  <section class="bench">
    <h2>Performance benchmarks</h2>
    <p class="bench-sub">Apple Silicon (M-series), macOS, median of 3 runs &mdash; v0.1.083 vs v0.1.190 vs Homebrew</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">tree <span>warm install</span></div>
        <div class="bg-badge">140x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time brew-t">2.38s</span></div>
      <div class="br"><div class="br-l">v0.1.083</div><div class="br-t"><div class="br-b old" style="width:0.97%"></div></div><span class="br-time old-t">23ms</span></div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b nb"  style="width:0.71%"></div></div><span class="br-time nb-t">17ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">tree <span>cold install</span></div>
        <div class="bg-badge">9x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time brew-t">3.13s</span></div>
      <div class="br"><div class="br-l">v0.1.083</div><div class="br-t"><div class="br-b old" style="width:12.6%"></div></div><span class="br-time old-t">394ms</span></div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b nb"  style="width:11.4%"></div></div><span class="br-time nb-t">356ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">v0.1.190 vs v0.1.083 <span>warm speedup</span></div>
        <div class="bg-badge">1.4x improvement</div>
      </div>
      <div class="br"><div class="br-l">v0.1.083</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">23ms</span></div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b nb"  style="width:73.9%"></div></div><span class="br-time nb-t">17ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">v0.1.190 vs v0.1.083 <span>cold speedup</span></div>
        <div class="bg-badge">1.1x improvement</div>
      </div>
      <div class="br"><div class="br-l">v0.1.083</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">394ms</span></div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b nb"  style="width:90.4%"></div></div><span class="br-time nb-t">356ms</span></div>
    </div>
  </section>
  </section>

  <section class="how">
    <h2>What changed in v0.1.190</h2>
    <div class="how-grid">
      <div class="how-card">
        <div class="num">0.16</div>
        <h3>Zig 0.16 compiler</h3>
        <p>New std.Io threading model. Mach-O relocation (install_name_tool, codesign) now runs via real I/O — was silently failing with a stub allocator that returned OOM on every alloc.</p>
      </div>
      <div class="how-card">
        <div class="num">0</div>
        <h3>Subprocess calls for tar</h3>
        <p>Native Zig USTAR/GNU tar parser replaces tar xzf subprocess. No fork/exec for extraction. File permissions preserved exactly from mode bits.</p>
      </div>
      <div class="how-card">
        <div class="num">O(1)</div>
        <h3>Dep resolution queue</h3>
        <p>Topological sort called orderedRemove(0) on every step — O(n²). Replaced with an index cursor: O(V+E) total. Noticeable on packages with 10+ transitive deps.</p>
      </div>
      <div class="how-card">
        <div class="num">1×</div>
        <h3>GHCR token per batch</h3>
        <p>Auth token prefetched once before parallel workers start. HTTP client reused across all downloads. Head buffer bumped to 32 KiB, fixing truncated redirects.</p>
      </div>
    </div>
  </section>

  <section class="method">
    <h2>What was fixed</h2>
    <p class="method-sub">15+ bugs addressed in this release</p>
    <table>
      <tr><th>Bug</th><th>Detail</th></tr>
      <tr><td>Mach-O relocation</td><td>install_name_tool/codesign never ran — stub allocator OOM on first alloc</td></tr>
      <tr><td>Non-atomic DB save</td><td>state.json written via temp + rename, safe against power-loss</td></tr>
      <tr><td>Release tarball</td><td>Binary inside tarball is now named nb (was nb-arch-os), fixing nb update</td></tr>
      <tr><td>UB in ReleaseFast</td><td>6 files used direct .Exited field access — converted to exhaustive switch</td></tr>
      <tr><td>ncurses man pages</td><td>walkAndReplaceText no longer skips man/ dir — placeholders now replaced</td></tr>
      <tr><td>Unbounded threads</td><td>Download worker count capped at 8</td></tr>
      <tr><td>nb cleanup size</td><td>Reported hardcoded 10 MB regardless of actual bytes freed — fixed</td></tr>
    </table>
  </section>

  <footer>
    <p>nanobrew v0.1.190 &mdash; <a href="https://github.com/justrach/nanobrew">GitHub</a> &mdash; Apache-2.0</p>
  </footer>
</div>
<script>
const obs = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) e.target.classList.add('visible'); }), { threshold: 0.2 });
document.querySelectorAll('[data-observe]').forEach(el => obs.observe(el));
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
          "cache-control": "public, max-age=86400",
        },
      });
    }

    if (url.pathname === "/version") {
      // Try CF Cache API first
      const cache = caches.default;
      const cacheKey = new Request("https://nanobrew.trilok.ai/_cached/version");
      const cached = await cache.match(cacheKey);
      if (cached) return cached;

      try {
        const gh = await fetch("https://api.github.com/repos/" + REPO + "/releases/latest", {
          headers: { "User-Agent": "nanobrew-worker" },
        });
        if (!gh.ok) {
          // Rate limited — return last known version
          return new Response("0.1.082", {
            headers: {
              "content-type": "text/plain; charset=utf-8",
              "cache-control": "public, max-age=60",
              "access-control-allow-origin": "*",
            },
          });
        }
        const data = await gh.json();
        const tag = data.tag_name || "";
        const ver = tag.startsWith("v") ? tag.slice(1) : tag;
        const resp = new Response(ver, {
          headers: {
            "content-type": "text/plain; charset=utf-8",
            "cache-control": "public, max-age=" + VERSION_CACHE_TTL,
            "access-control-allow-origin": "*",
          },
        });
        // Store in CF cache for 5 minutes
        await cache.put(cacheKey, resp.clone());
        return resp;
      } catch {
        return new Response("0.1.082", {
          headers: {
            "content-type": "text/plain; charset=utf-8",
            "cache-control": "public, max-age=60",
            "access-control-allow-origin": "*",
          },
        });
      }
    }

    if (url.pathname === "/") {
      return new Response(LANDING_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=3600",
        },
      });
    }

    if (url.pathname === "/apt-get" || url.pathname === "/apt") {
      return new Response(APT_GET_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=3600",
        },
      });
    }

    if (url.pathname === "/v0.1.190" || url.pathname === "/v-0.1.190") {
      return new Response(RELEASE_190_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=86400",
        },
      });
    }

    return Response.redirect("https://github.com/justrach/nanobrew", 302);
  },
};
