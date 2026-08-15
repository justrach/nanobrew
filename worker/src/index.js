const REPO = "justrach/nanobrew";

const INSTALL_SCRIPT = `#!/bin/bash
set -euo pipefail

REPO="${REPO}"
INSTALL_DIR="\${NANOBREW_INSTALL_DIR:-/opt/nanobrew}"
BIN_DIR="$INSTALL_DIR/prefix/bin"
SITE_URL="https://nanobrew.trilok.ai"
# Last-resort release tag if the worker's /version endpoint AND GitHub's
# API are both unreachable. Bump on every release cut.
FALLBACK_RELEASE="v0.1.193"

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

# Get release tag
if [ -n "\${NANOBREW_INSTALL_VERSION:-}" ]; then
    LATEST="$NANOBREW_INSTALL_VERSION"
    case "$LATEST" in
        v*) ;;
        *) LATEST="v$LATEST" ;;
    esac
    echo "  Using $LATEST"
else
    echo "  Fetching latest release..."
    # Resolve the latest version via the worker (which caches GH for 5 min
    # and has its own fallback) BEFORE hitting GH directly. Avoids the
    # 60/hr unauthenticated rate limit on api.github.com that used to
    # break installs during traffic spikes.
    LATEST_VER=$(curl -fsSL "$SITE_URL/version" 2>/dev/null || true)
    if [ -n "$LATEST_VER" ]; then
        LATEST="v$LATEST_VER"
    else
        LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4)
    fi
    if [ -z "$LATEST" ]; then
        echo "  Could not resolve latest release; using $FALLBACK_RELEASE"
        LATEST="$FALLBACK_RELEASE"
    else
        echo "  Found $LATEST"
    fi
fi

# Download binary + SHA256 checksum
URL="https://github.com/$REPO/releases/download/$LATEST/$TARBALL"
SHA_URL="$URL.sha256"

if ! curl -fsI "$URL" >/dev/null 2>&1; then
    if [ "$LATEST" != "$FALLBACK_RELEASE" ]; then
        echo "  $LATEST not found; falling back to $FALLBACK_RELEASE"
        LATEST="$FALLBACK_RELEASE"
        URL="https://github.com/$REPO/releases/download/$LATEST/$TARBALL"
        SHA_URL="$URL.sha256"
    fi
fi

echo "  Release notes: $SITE_URL/$LATEST"

if [ "\${NANOBREW_INSTALL_DRY_RUN:-0}" = "1" ]; then
    echo "  Would download $URL"
    echo "  Would verify $SHA_URL"
    echo "  Would install nb to $BIN_DIR/nb"
    exit 0
fi

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

  <section class="bench">
    <h2>Version timeline</h2>
    <p class="bench-sub">What each nanobrew release actually shipped. Tree install numbers are warm, Apple Silicon, median of 3 runs.</p>

    <div class="bg">
      <div class="bg-title">v0.1.082 <span>/ jun 2025, first stable line</span></div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">39ms warm</div></div>
      </div>
      <div class="bg-note">21 CVEs fixed &middot; nb migrate &middot; nb info --cask &middot; nb bundle install &middot; no sudo after init</div>
    </div>

    <div class="bg">
      <div class="bg-title">v0.1.190 <span>/ apr 2026, Zig 0.16 + faster everything</span></div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="44%">17ms warm &middot; 2.3x faster than v0.1.082</div></div>
      </div>
      <div class="bg-note">Zig 0.16.0 compiler &middot; native tar extractor (no subprocess) &middot; persistent HTTP client &middot; O(1) resolver queue &middot; 15+ bugs fixed</div>
    </div>

    <div class="bg">
      <div class="bg-title">v0.1.191 <span>/ apr 2026, signed + command-speed wins</span></div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="44%">17ms warm &middot; install path unchanged</div></div>
      </div>
      <div class="bg-note">Apple-notarized &middot; 12x faster nb leaves &middot; 1.80x faster nb search (streaming JSON) &middot; 1.77x faster cold-install resolver &middot; Python dlopen codesign fix &middot; zero-leak nb outdated / nb info &middot; <a href="/v0.1.191">full notes</a></div>
    </div>

    <div class="bg">
      <div class="bg-title">v0.1.192 <span>/ apr 2026, native paths + manager-speed wins</span></div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">48.8ms yt-dlp reinstall &middot; 119.4x faster than Homebrew</div></div>
      </div>
      <div class="bg-note">359 verified native paths &middot; 100/100 top formulae + 100/100 top casks covered &middot; 37.5x faster than zerobrew on target reinstall &middot; no Homebrew required for covered paths &middot; <a href="/v0.1.192">full notes</a></div>
    </div>

    <div class="bg">
      <div class="bg-title">v0.1.193 <span>/ may 2026, audit-driven correctness sweep</span></div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">install path unchanged &middot; correctness over speed</div></div>
      </div>
      <div class="bg-note">38 commits, 20+ targeted bug fixes &middot; deb path correctness sweep (cwd-independent <code>nb remove --deb</code>, native xz, postinst io, patchelf race, locale relocation) &middot; process-wide threadsafe Io accessor &middot; <code>nb cleanup --prune-kegs</code> &middot; HTTP User-Agent override &middot; honest known-issue disclosure &middot; <a href="/v0.1.193">full notes</a></div>
    </div>

    <div class="bg">
      <div class="bg-title">v0.1.198 <span>/ jun 2026, our own bottle registry + CVE scanning</span></div>
      <div class="br">
        <span class="br-l">nb</span>
        <div class="br-t"><div class="br-b nb" data-w="100%">own GHCR registry &middot; ~800x faster ELF relocate &middot; still 100x+ vs Homebrew</div></div>
      </div>
      <div class="bg-note">nanobrew's own bottle registry (<code>ghcr.io/justrach/nb-bottles</code>): 231 Homebrew bottles mirrored byte-for-byte + repackaged upstream binaries &middot; every bottle SBOM'd + CVE-scanned with revoke-and-fallback &middot; native ELF relocation (4,777ms to 6ms) &middot; warm resolve 147ms to 1.8ms &middot; cached reinstall 534ms to 4ms &middot; 37 new packages &middot; <a href="/v0.1.198">full notes</a></div>
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
  .hero h1 .speed-line {
    display: block;
    color: var(--gold);
    font-size: clamp(1.75rem, 4.2vw, 3rem);
    margin-top: 0.45rem;
  }
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
      <a href="/v0.1.198">v0.1.198</a>
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
<meta name="description" content="nanobrew v0.1.190: Zig 0.16.0 compiler, native tar extraction, persistent HTTP, O(1) resolver queue, and 15+ correctness fixes. 11.8x faster than Homebrew on warm installs.">
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
      <a href="/v0.1.198">v0.1.198</a>
      <a href="/">macOS benchmarks</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew v0.1.190<br><em>Zig 0.16 + faster everything</em></h1>
    <p>Zig 0.16.0 compiler, native tar extraction, persistent HTTP, O(1) resolver queue, and 15+ correctness fixes.</p>
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
        <h3>Resolver queue pop</h3>
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

const RELEASE_191_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nanobrew v0.1.191 — signed, notarized, 12× faster nb leaves</title>
<meta name="description" content="nanobrew v0.1.191: macOS-signed and Apple-notarized binaries, 12× faster nb leaves, 1.8× faster nb search via streaming JSON, 43% faster cold-install resolver, Python dlopen codesign fix, zero-leak nb outdated / nb info, new nb where diagnostic subcommand.">
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
  .hero p code {
    background: var(--surface); border: 1px solid var(--border); border-radius: 3px;
    padding: 0.1rem 0.35rem; font-size: 0.85rem; color: var(--bright);
  }
  .hero > code {
    display: inline-block; margin-top: 1.5rem; padding: 0.6rem 1.4rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
    font-size: 0.88rem; color: var(--bright); font-weight: 500;
    animation: fadeUp 0.7s ease-out 0.24s both;
  }

  .stat { padding: 4rem 0; text-align: center; border-top: 1px solid var(--border); }
  .stat-num {
    font-family: var(--fd); font-weight: 900;
    font-size: clamp(2.2rem, 6vw, 3.4rem);
    color: var(--gold); line-height: 1.05; letter-spacing: -0.03em;
    text-shadow: 0 0 80px var(--gold-soft);
    animation: fadeUp 0.8s ease-out 0.3s both;
  }
  .stat-num.sig { font-size: clamp(1.2rem, 3vw, 1.55rem); font-family: var(--fm); letter-spacing: 0; }
  .stat-label { font-size: 1rem; color: var(--muted); margin-top: 0.7rem; animation: fadeUp 0.8s ease-out 0.38s both; }
  .stat-ctx { font-size: 0.82rem; color: var(--dim); margin-top: 1.3rem; animation: fadeUp 0.8s ease-out 0.44s both; }
  .stat-ctx em { color: var(--muted); font-style: normal; font-weight: 500; }

  .demo { padding: 4rem 0; border-top: 1px solid var(--border); }
  .demo h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .demo-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 1.5rem; }
  .demo-sub code { background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.75rem; }
  .demo pre {
    background: #0e0e0f; color: #e7e7ea; border-radius: 8px; padding: 1.1rem 1.2rem;
    font-family: var(--fm); font-size: 0.78rem; line-height: 1.55;
    overflow-x: auto; border: 1px solid #1c1c1f;
  }
  .demo pre .p { color: #ffb800; font-weight: 700; }
  .demo pre .k { color: #9ea0a4; }
  .demo pre .h { color: #fff; font-weight: 600; }

  .bench { padding: 4rem 0; border-top: 1px solid var(--border); }
  .bench h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .bench-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 2.5rem; }

  .bg { margin-bottom: 2.8rem; }
  .bg-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.9rem; flex-wrap: wrap; gap: 0.5rem; }
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
  .br-l { width: 5.5rem; text-align: right; font-size: 0.72rem; color: var(--muted); flex-shrink: 0; font-weight: 500; }
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
  .br-time { font-size: 0.76rem; font-family: var(--fd); font-weight: 600; flex-shrink: 0; width: 4.5rem; }
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
  .method td code { font-size: 0.75rem; background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; }

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
      <a href="/v0.1.198">v0.1.198</a>
      <a href="/v0.1.193">v0.1.193</a>
      <a href="/v0.1.192">v0.1.192</a>
      <a href="/v0.1.190">v0.1.190</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew v0.1.191<br><em>signed, searchable, leak-free</em></h1>
    <p>macOS binaries are now code-signed with a Developer ID, hardened, and Apple-notarized. Shell commands got a round of targeted speedups, a Python <code>dlopen</code> codesign regression is fixed, and two long-running DebugAllocator leaks are gone.</p>
    <code>nb update  # to v0.1.191</code>
  </section>

  <section class="stat">
    <span class="stat-num">140×</span>
    <span class="stat-label">faster than Homebrew on warm installs</span>
    <p class="stat-ctx"><em>tree</em> warm: Homebrew 2.38s &rarr; v0.1.083 23ms &rarr; v0.1.190 17ms &rarr; <em>v0.1.191 17ms</em></p>
  </section>

  <section class="bench">
    <h2>vs. Homebrew — install path unchanged, wins carry over</h2>
    <p class="bench-sub">Apple Silicon (M-series), macOS, median of 3 runs. v0.1.191 does not touch the install hot path; the Homebrew speedup the previous release earned is preserved.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">tree <span>warm install</span></div>
        <div class="bg-badge">140× faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time brew-t">2.38s</span></div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b old" style="width:0.71%"></div></div><span class="br-time old-t">17ms</span></div>
      <div class="br"><div class="br-l">v0.1.191</div><div class="br-t"><div class="br-b nb"  style="width:0.71%"></div></div><span class="br-time nb-t">17ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">tree <span>cold install</span></div>
        <div class="bg-badge">9× faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time brew-t">3.13s</span></div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b old" style="width:11.4%"></div></div><span class="br-time old-t">356ms</span></div>
      <div class="br"><div class="br-l">v0.1.191</div><div class="br-t"><div class="br-b nb"  style="width:11.4%"></div></div><span class="br-time nb-t">356ms</span></div>
    </div>
  </section>

  <section class="bench">
    <h2>Command-speed wins — v0.1.190 &rarr; v0.1.191</h2>
    <p class="bench-sub">Targeted work on the JSON parse, BFS resolver, and <code>nb leaves</code> hot paths. Apple Silicon, macOS, median of 3 runs.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">nb leaves <span>cold API cache, ~100 packages</span></div>
        <div class="bg-badge">12× faster</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:11.4%"></div></div><span class="br-time brew-t">1.14s</span></div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">10.0 s</span></div>
      <div class="br"><div class="br-l">v0.1.191</div><div class="br-t"><div class="br-b nb"  style="width:8.3%"></div></div><span class="br-time nb-t">0.83 s</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">nb search curl <span>streaming std.json.Scanner</span></div>
        <div class="bg-badge">1.80× faster</div>
      </div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">190 ms</span></div>
      <div class="br"><div class="br-l">v0.1.191</div><div class="br-t"><div class="br-b nb"  style="width:55.8%"></div></div><span class="br-time nb-t">106 ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">nb info python <span>alias-resolved formula fetch</span></div>
        <div class="bg-badge">1.68× faster</div>
      </div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">168 ms</span></div>
      <div class="br"><div class="br-l">v0.1.191</div><div class="br-t"><div class="br-b nb"  style="width:59.5%"></div></div><span class="br-time nb-t">100 ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">nb install graphviz <span>cold resolver phase, 15 deps</span></div>
        <div class="bg-badge">1.77× faster</div>
      </div>
      <div class="br"><div class="br-l">v0.1.190</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">3123 ms</span></div>
      <div class="br"><div class="br-l">v0.1.191</div><div class="br-t"><div class="br-b nb"  style="width:56.5%"></div></div><span class="br-time nb-t">1766 ms</span></div>
    </div>

    <p class="bench-sub" style="margin-top:1.5rem;"><code>brew leaves</code> reads a local prefix cache; nanobrew had been doing ~100 sequential API fetches with no shared HTTP client and O(n³) membership scans to reach the same answer. v0.1.191 parallelizes those fetches across a bounded worker pool with a per-thread persistent <code>std.http.Client</code> and replaces the scans with a <code>StringHashMap</code>. Net: nanobrew <code>nb leaves</code> is now 1.37× faster than <code>brew leaves</code> while still carrying fresh dep info.</p>
  </section>

  <section class="demo">
    <h2>nb where — one call, three views</h2>
    <p class="demo-sub">Replaces <code>nb list | grep X; ls $PREFIX/lib | grep X; nb search X</code> with a single aggregated subcommand.</p>
<pre>$ <span class="p">nb where</span> opus
<span class="h">==&gt; installed matching "opus":</span>
  opus 1.6.1
<span class="h">==&gt; /opt/nanobrew/prefix/bin/ matching "opus":</span>
  <span class="k">(none)</span>
<span class="h">==&gt; /opt/nanobrew/prefix/lib/ matching "opus":</span>
  <span class="k">(none)</span>
<span class="h">==&gt; /opt/nanobrew/prefix/opt/ matching "opus":</span>
  opus@
<span class="h">==&gt; formula index matches for "opus":</span>
  libopusenc 0.3 - Convenience library for creating .opus files
  opus 1.6.1 - Audio codec
  opus-tools 0.2 - Utilities to encode, inspect, and decode .opus files
  opusfile 0.12 - API for decoding and seeking in .opus files</pre>
  </section>

  <section class="how">
    <h2>What changed in v0.1.191</h2>
    <div class="how-grid">
      <div class="how-card">
        <div class="num">✓</div>
        <h3>Apple-notarized binaries</h3>
        <p>macOS tarballs for arm64 + x86_64 code-signed with a Developer ID, timestamped, hardened runtime, and submitted to Apple's notary service. Gatekeeper accepts on first run.</p>
      </div>
      <div class="how-card">
        <div class="num">🔒</div>
        <h3>Python dlopen codesign fix</h3>
        <p>install_name_tool strips signatures unconditionally, and the batch codesign pipe was too small on packages with many Mach-O files. python@3.14 went from 60/76 broken .so + SIGKILL to 0/76 + framework re-sealed.</p>
      </div>
      <div class="how-card">
        <div class="num">⚡</div>
        <h3>Streaming JSON parse</h3>
        <p>std.json.Scanner with skipValue() replaces full std.json.Value materialization on the 29.5 MB formula.json + 14.2 MB cask.json. 1.80× faster nb search, 1.68× faster nb info alias resolution.</p>
      </div>
      <div class="how-card">
        <div class="num">1×</div>
        <h3>nb where &lt;pattern&gt;</h3>
        <p>Aggregates installed kegs/casks/debs, files in $PREFIX/{bin,lib,opt}, and Homebrew formula index hits into one call. Case-insensitive substring match.</p>
      </div>
      <div class="how-card">
        <div class="num">📖</div>
        <h3>nb info — rich output</h3>
        <p>Formula info now prints desc, homepage, license, bottle/source URL + sha256, deps, build deps, and caveats — matching the cask info layout. Bottled formulae tag the version as (bottled); source-only tags the URL as (source).</p>
      </div>
      <div class="how-card">
        <div class="num">0</div>
        <h3>Zero allocator leaks</h3>
        <p>nb outdated was leaking three strings per outdated package on every run. nb info was leaking every formula on the alias path. Both now report zero DebugAllocator leaks.</p>
      </div>
    </div>
  </section>

  <section class="method">
    <h2>Verify a downloaded binary</h2>
    <p class="method-sub">Works offline after the notarization ticket is fetched once.</p>
    <table>
      <tr><th>Step</th><th>Command</th><th>Confirms</th></tr>
      <tr><td>Checksum</td><td><code>shasum -a 256 -c nb-arm64-apple-darwin.tar.gz.sha256</code></td><td>in-transit integrity</td></tr>
      <tr><td>Authority</td><td><code>codesign -dv --verbose=4 nb-arm64-apple-darwin</code></td><td>Developer ID + Apple Root CA</td></tr>
      <tr><td>Runtime</td><td>same output — <code>flags=0x10000(runtime)</code></td><td>hardened runtime enforced</td></tr>
      <tr><td>Structural</td><td><code>codesign --verify --deep --strict nb-arm64-apple-darwin</code></td><td>signature is internally consistent</td></tr>
    </table>
  </section>

  <footer>
    <p>nanobrew v0.1.191 &mdash; <a href="https://github.com/justrach/nanobrew">GitHub</a> &mdash; Apache-2.0</p>
  </footer>
</div>
<script>
const obs = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) e.target.classList.add('visible'); }), { threshold: 0.2 });
document.querySelectorAll('[data-observe]').forEach(el => obs.observe(el));
</script>
</body>
</html>`;

const RELEASE_192_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nanobrew v0.1.192 — native installs, no Homebrew runtime</title>
<meta name="description" content="nanobrew v0.1.192: native installs for the top 100 Homebrew formulae and top 100 casks, with no Homebrew runtime required for covered packages. 119.4x faster than Homebrew and 37.5x faster than zerobrew on yt-dlp target reinstalls.">
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
  .wrap { max-width: 880px; margin: 0 auto; padding: 0 2rem; }

  nav { padding: 1.5rem 0; display: flex; justify-content: space-between; align-items: center; }
  .nav-mark { font-family: var(--fd); font-weight: 700; font-size: 1rem; color: var(--bright); text-decoration: none; }
  .nav-links { display: flex; gap: 1.5rem; flex-wrap: wrap; justify-content: flex-end; }
  .nav-links a { color: var(--muted); text-decoration: none; font-size: 0.82rem; font-weight: 500; }
  .nav-links a:hover { color: var(--bright); }

  @keyframes fadeUp { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }

  .hero { padding: 4rem 0 3rem; text-align: center; }
  .hero h1 {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(2.1rem, 5vw, 3.4rem);
    color: var(--bright); line-height: 1.15;
    animation: fadeUp 0.7s ease-out both;
  }
  .hero-claim {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(1.85rem, 4.7vw, 3.25rem);
    line-height: 1.12; color: var(--bright);
    max-width: 820px; margin: 0.45rem auto 0;
    animation: fadeUp 0.7s ease-out 0.05s both;
  }
  .hero-speed {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(1.25rem, 2.8vw, 2rem);
    line-height: 1.18; color: var(--bright);
    max-width: 780px; margin: 0.65rem auto 0;
    animation: fadeUp 0.7s ease-out 0.1s both;
  }
  .hero-highlight {
    display: inline;
    padding: 0 0.06em;
    background: linear-gradient(180deg, transparent 55%, rgba(255,184,0,0.55) 55%);
    -webkit-box-decoration-break: clone;
    box-decoration-break: clone;
  }
  .hero p {
    font-size: 1rem; color: var(--muted); margin-top: 1rem; max-width: 700px; margin-inline: auto;
    animation: fadeUp 0.7s ease-out 0.12s both;
  }
  .hero .hero-lead {
    font-size: 1.05rem; color: var(--text);
  }
  .hero .hero-lead strong { color: var(--bright); font-weight: 800; }
  .hero p code {
    background: var(--surface); border: 1px solid var(--border); border-radius: 3px;
    padding: 0.1rem 0.35rem; font-size: 0.85rem; color: var(--bright);
  }
  .hero > code {
    display: inline-block; margin-top: 1.5rem; padding: 0.6rem 1.4rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
    font-size: 0.88rem; color: var(--bright); font-weight: 500;
    animation: fadeUp 0.7s ease-out 0.24s both;
  }

  .stat { padding: 4rem 0; border-top: 1px solid var(--border); }
  .stat-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1.2rem; }
  .stat-card {
    text-align: center; padding: 1.2rem 1rem; background: var(--surface);
    border: 1px solid var(--border); border-radius: 8px;
    animation: fadeUp 0.8s ease-out 0.28s both;
  }
  .stat-num {
    display: block; font-family: var(--fd); font-weight: 900;
    font-size: clamp(2rem, 5vw, 3.2rem);
    color: var(--gold); line-height: 1.05;
    text-shadow: 0 0 80px var(--gold-soft);
  }
  .stat-label { display: block; font-size: 0.82rem; color: var(--muted); margin-top: 0.45rem; }
  .stat-ctx { font-size: 0.82rem; color: var(--dim); margin-top: 1.4rem; text-align: center; }
  .stat-ctx em { color: var(--muted); font-style: normal; font-weight: 500; }

  .bench { padding: 4rem 0; border-top: 1px solid var(--border); }
  .bench h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .bench-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 2.3rem; }
  .bench-sub code { background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.75rem; color: var(--bright); }

  .bg { margin-bottom: 2.8rem; }
  .bg-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.9rem; flex-wrap: wrap; gap: 0.5rem; }
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
  .br-l { width: 8.5rem; text-align: right; font-size: 0.72rem; color: var(--muted); flex-shrink: 0; font-weight: 500; }
  .br-t { flex: 1; height: 40px; background: var(--surface); border-radius: 6px; overflow: hidden; }
  .br-b {
    height: 100%; border-radius: 6px;
    width: 0; transition: width 1.3s cubic-bezier(0.16, 1, 0.3, 1);
  }
  .br-b.apt { background: #E4E4E4; }
  .br-b.zb { background: #D8D8D8; }
  .br-b.old { background: linear-gradient(90deg, #FFC84A 0%, #FFB800 100%); opacity: 0.6; }
  .br-b.nb  { background: linear-gradient(90deg, #FFB800 0%, #FF8000 100%); box-shadow: 0 2px 16px rgba(255,140,0,0.22); }
  .bg.visible .br:nth-child(1) .br-b { transition-delay: 0s; }
  .bg.visible .br:nth-child(2) .br-b { transition-delay: 0.12s; }
  .bg.visible .br:nth-child(3) .br-b { transition-delay: 0.24s; }
  .bg.visible .br:nth-child(4) .br-b { transition-delay: 0.36s; }
  .br-time { font-size: 0.76rem; font-family: var(--fd); font-weight: 600; flex-shrink: 0; width: 5.8rem; color: var(--muted); }
  .br-time.old-t  { color: #b45309; }
  .br-time.nb-t   { color: #c05621; }

  .demo { padding: 4rem 0; border-top: 1px solid var(--border); }
  .demo h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .demo-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 1.5rem; }
  .demo-sub code { background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.75rem; }
  .demo pre {
    background: #0e0e0f; color: #e7e7ea; border-radius: 8px; padding: 1.1rem 1.2rem;
    font-family: var(--fm); font-size: 0.78rem; line-height: 1.55;
    overflow-x: auto; border: 1px solid #1c1c1f;
  }
  .demo pre .p { color: #ffb800; font-weight: 700; }
  .demo pre .k { color: #9ea0a4; }
  .demo pre .h { color: #fff; font-weight: 600; }

  .release-status { padding: 3rem 0; border-top: 1px solid var(--border); }
  .release-status h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.75rem; }
  .status-box {
    background: #fff7ed; border: 1px solid #fed7aa; border-radius: 8px;
    padding: 1.2rem 1.35rem; color: #7c2d12; font-size: 0.82rem;
  }
  .status-box strong { color: #9a3412; }
  .status-box code { background: rgba(154,52,18,0.08); padding: 0.08rem 0.3rem; border-radius: 3px; color: #9a3412; }

  .credits { padding: 3rem 0; border-top: 1px solid var(--border); }
  .credits h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.75rem; }
  .credits p { font-size: 0.82rem; color: var(--muted); margin-bottom: 0.8rem; }
  .credits a { color: var(--bright); text-decoration: none; font-weight: 700; border-bottom: 1px solid var(--border); }

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
  .method td { padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--border); vertical-align: top; }
  .method td code { font-size: 0.75rem; background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; }

  footer { padding: 3rem 0; border-top: 1px solid var(--border); text-align: center; font-size: 0.75rem; color: var(--dim); }
  footer a { color: var(--muted); }

  @media (max-width: 760px) {
    .wrap { padding: 0 1.1rem; }
    nav { align-items: flex-start; gap: 1rem; }
    .stat-grid { grid-template-columns: 1fr; }
    .br { display: block; }
    .br-l { display: block; width: auto; text-align: left; margin-bottom: 0.25rem; }
    .br-time { display: block; width: auto; margin-top: 0.25rem; }
    .method { overflow-x: auto; }
    .method table { min-width: 680px; }
  }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <a class="nav-mark" href="/">nanobrew</a>
    <div class="nav-links">
      <a href="https://github.com/justrach/nanobrew">GitHub</a>
      <a href="https://github.com/justrach/nanobrew#install">Install</a>
      <a href="/v0.1.198">v0.1.198</a>
      <a href="/v0.1.193">v0.1.193</a>
      <a href="/v0.1.191">v0.1.191</a>
      <a href="/v0.1.190">v0.1.190</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew v0.1.192</h1>
    <div class="hero-claim"><span class="hero-highlight">Native installs. No Homebrew runtime.</span></div>
    <div class="hero-speed"><span class="hero-highlight">119.4x faster than Homebrew.</span> <span class="hero-highlight">37.5x faster than zerobrew.</span></div>
    <p class="hero-lead"><strong>Top 100 Homebrew formulae and top 100 casks</strong> now run through nanobrew's own Zig install path. Covered packages do not need Homebrew installed, do not spawn <code>brew</code>, and do not touch the Ruby metadata path.</p>
    <p>359 verified native paths: 256 formula records plus 103 cask records. nanobrew resolves, downloads, verifies, extracts, caches, links, shims, and records install state itself.</p>
    <code>nb update  # to v0.1.192</code>
  </section>

  <section class="stat">
    <div class="stat-grid">
      <div class="stat-card">
        <span class="stat-num">119.4x</span>
        <span class="stat-label">faster than Homebrew on yt-dlp target reinstall</span>
      </div>
      <div class="stat-card">
        <span class="stat-num">37.5x</span>
        <span class="stat-label">faster than zerobrew on the same CI path</span>
      </div>
      <div class="stat-card">
        <span class="stat-num">359</span>
        <span class="stat-label">native paths covering top 100 formulae + top 100 casks</span>
      </div>
    </div>
    <p class="stat-ctx"><em>yt-dlp target reinstall:</em> nanobrew 48.8ms &rarr; zerobrew 1830.7ms &rarr; Homebrew 5827.7ms. Sandboxed macOS Actions runner, 5 iterations.</p>
  </section>

  <section class="bench">
    <h2>CI package-manager comparison — yt-dlp</h2>
    <p class="bench-sub">Target reinstall means dependencies and cache/store were primed, then only <code>yt-dlp</code> was removed and installed again. Current nanobrew runs as <code>nb install --shims yt-dlp</code> and smoke-tests that <code>yt-dlp --version</code> works while dependency tools stay private.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">target reinstall <span>lower is better</span></div>
        <div class="bg-badge">119.4x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew 5.1.7</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">5827.7ms</span></div>
      <div class="br"><div class="br-l">zerobrew 0.2.1</div><div class="br-t"><div class="br-b zb" style="width:31.4%"></div></div><span class="br-time">1830.7ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.191</div><div class="br-t"><div class="br-b old" style="width:58.1%"></div></div><span class="br-time old-t">3385.2ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.192</div><div class="br-t"><div class="br-b nb"  style="width:0.84%"></div></div><span class="br-time nb-t">48.8ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">already installed no-op <span>lower is better</span></div>
        <div class="bg-badge">186.8x faster than zerobrew</div>
      </div>
      <div class="br"><div class="br-l">nb v0.1.191</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">3183.7ms</span></div>
      <div class="br"><div class="br-l">zerobrew 0.2.1</div><div class="br-t"><div class="br-b zb" style="width:34.0%"></div></div><span class="br-time">1083.2ms</span></div>
      <div class="br"><div class="br-l">Homebrew 5.1.7</div><div class="br-t"><div class="br-b apt" style="width:28.8%"></div></div><span class="br-time">916.9ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.192</div><div class="br-t"><div class="br-b nb"  style="width:0.18%"></div></div><span class="br-time nb-t">5.8ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">native nanobrew vs non-native nanobrew <span>same CI path</span></div>
        <div class="bg-badge">69.4x reinstall / 548.9x no-op</div>
      </div>
      <div class="br"><div class="br-l">non-native target</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">3385.2ms</span></div>
      <div class="br"><div class="br-l">native target</div><div class="br-t"><div class="br-b nb"  style="width:1.44%"></div></div><span class="br-time nb-t">48.8ms</span></div>
      <div class="br"><div class="br-l">non-native no-op</div><div class="br-t"><div class="br-b old" style="width:94.0%"></div></div><span class="br-time old-t">3183.7ms</span></div>
      <div class="br"><div class="br-l">native no-op</div><div class="br-t"><div class="br-b nb"  style="width:0.18%"></div></div><span class="br-time nb-t">5.8ms</span></div>
    </div>
  </section>

  <section class="demo">
    <h2>Native install path</h2>
    <p class="demo-sub">The shimmed path exposes the requested tool while keeping dependency executables out of the global prefix.</p>
<pre>$ <span class="p">nb install --shims</span> yt-dlp
<span class="h">==&gt; Using verified upstream release metadata for yt-dlp</span>
<span class="k">==&gt; Installing dependencies privately for shim runtime</span>
<span class="k">==&gt; Linking requested command through prefix/bin/yt-dlp</span>
<span class="h">==&gt; Done in 48.8ms on the target reinstall benchmark</span>

$ <span class="p">yt-dlp</span> --version
<span class="h">2026.03.17</span>

$ <span class="p">ls</span> /opt/nanobrew/prefix/bin/deno /opt/nanobrew/prefix/bin/python3.14
<span class="k">not exposed globally; shim PATH is private</span></pre>
  </section>

  <section class="release-status">
    <h2>Release status</h2>
    <div class="status-box">
      <p><strong>x86 is not supported in v0.1.192 because of a Rosetta signed-binary bug.</strong> Fresh unsigned x86 builds run under Rosetta with status <code>0</code>, but signed/notarized x86 exits <code>139</code>. A universal signed binary also runs the arm64 slice fine while the x86 slice still exits <code>139</code>. Apple accepts notarization, but the actual Rosetta smoke test fails, so the x86 artifact is not safe to release as-is.</p>
    </div>
  </section>

  <section class="credits">
    <h2>Public issue credits</h2>
    <p>Thanks to <a href="https://github.com/SteveXFLiu">@SteveXFLiu</a> for the cask <code>MountFailed</code>/<code>ExtractFailed</code> report that drove the cask installer IO fix in this branch.</p>
    <p>Thanks to <a href="https://github.com/jet10000">@jet10000</a> and <a href="https://github.com/edvardm">@edvardm</a> for the x86 startup crash reports. Those reports are why this release now calls out the Rosetta signed-binary blocker instead of publishing a broken x86 artifact.</p>
  </section>

  <section class="how">
    <h2>What changed in v0.1.192</h2>
    <div class="how-grid">
      <div class="how-card">
        <div class="num">359</div>
        <h3>Verified native paths</h3>
        <p>The embedded registry now carries 256 formula records and 103 cask records, covering 100/100 top Homebrew formulae and 100/100 top casks from the April 25, 2026 snapshot.</p>
      </div>
      <div class="how-card">
        <div class="num">0</div>
        <h3>No Homebrew dependency</h3>
        <p>Covered packages do not shell out to brew, require a Homebrew prefix, or boot Ruby. Bottle-backed records still use verified artifact URLs and checksums; nanobrew owns the install work.</p>
      </div>
      <div class="how-card">
        <div class="num">5.8ms</div>
        <h3>Fast no-op installs</h3>
        <p>Already-installed shimmed packages now exit through the native state path in single-digit milliseconds on CI, 548.9x faster than v0.1.191 in the same workflow.</p>
      </div>
      <div class="how-card">
        <div class="num">--shims</div>
        <h3>Private runtime deps</h3>
        <p><code>nb install --shims yt-dlp</code> exposes yt-dlp but keeps helper binaries such as deno and python private, then injects them only into the wrapper's PATH.</p>
      </div>
      <div class="how-card">
        <div class="num">CI</div>
        <h3>Sandboxed comparisons</h3>
        <p>GitHub Actions now compares current nanobrew, previous nanobrew, Homebrew, and pinned zerobrew on disposable macOS runners without polluting a developer machine.</p>
      </div>
      <div class="how-card">
        <div class="num">off</div>
        <h3>Anonymous telemetry control</h3>
        <p><code>nb telemetry off</code> and <code>nanobrew telemetry off</code> make opt-out explicit. Events are anonymized and intended to prioritize which native paths to build next.</p>
      </div>
    </div>
  </section>

  <section class="method">
    <h2>What native means here</h2>
    <p class="method-sub">v0.1.192 moves the common path out of metadata lookup and into nanobrew's own install machinery.</p>
    <table>
      <tr><th>Phase</th><th>v0.1.192 behavior</th><th>Why it matters</th></tr>
      <tr><td>Resolve</td><td>Loads the verified upstream registry from local cache, hosted registry, or embedded fallback and parses the matching record.</td><td>No full formula-list parse on the hot path.</td></tr>
      <tr><td>Fetch</td><td>Uses Zig native HTTP with streaming SHA256 verification and content-addressed blob caching.</td><td>No curl process and no second hash pass.</td></tr>
      <tr><td>Extract</td><td>Uses native source-archive, bottle, and cask pipelines with cached relocated store entries.</td><td>Reinstalls skip repeated download/extraction/relocation work.</td></tr>
      <tr><td>Link</td><td>Repairs links only when needed and can create wrapper shims for private dependency runtimes.</td><td>Common already-installed and target-reinstall paths stay tiny.</td></tr>
    </table>
  </section>

  <footer>
    <p>nanobrew v0.1.192 &mdash; <a href="https://github.com/justrach/nanobrew">GitHub</a> &mdash; Apache-2.0</p>
  </footer>
</div>
<script>
const obs = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) e.target.classList.add('visible'); }), { threshold: 0.2 });
document.querySelectorAll('[data-observe]').forEach(el => obs.observe(el));
</script>
</body>
</html>`;

const RELEASE_193_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nanobrew v0.1.193 — audit-driven correctness sweep</title>
<meta name="description" content="nanobrew v0.1.193: 38 commits and 20+ targeted bug fixes from a multi-agent + manual audit. Deb path correctness sweep, process-wide threadsafe Io accessor, ELF/patchelf serialization, nb cleanup --prune-kegs, HTTP User-Agent override, and honest disclosure of the pre-existing apt-replacement exit-139 known issue.">
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
  .wrap { max-width: 880px; margin: 0 auto; padding: 0 2rem; }

  nav { padding: 1.5rem 0; display: flex; justify-content: space-between; align-items: center; }
  .nav-mark { font-family: var(--fd); font-weight: 700; font-size: 1rem; color: var(--bright); text-decoration: none; }
  .nav-links { display: flex; gap: 1.5rem; flex-wrap: wrap; justify-content: flex-end; }
  .nav-links a { color: var(--muted); text-decoration: none; font-size: 0.82rem; font-weight: 500; }
  .nav-links a:hover { color: var(--bright); }

  @keyframes fadeUp { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }

  .hero { padding: 4rem 0 3rem; text-align: center; }
  .hero h1 {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(2.1rem, 5vw, 3.4rem);
    color: var(--bright); line-height: 1.15;
    animation: fadeUp 0.7s ease-out both;
  }
  .hero-claim {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(1.85rem, 4.7vw, 3.25rem);
    line-height: 1.12; color: var(--bright);
    max-width: 820px; margin: 0.45rem auto 0;
    animation: fadeUp 0.7s ease-out 0.05s both;
  }
  .hero-speed {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(1.25rem, 2.8vw, 2rem);
    line-height: 1.18; color: var(--bright);
    max-width: 780px; margin: 0.65rem auto 0;
    animation: fadeUp 0.7s ease-out 0.1s both;
  }
  .hero-highlight {
    display: inline;
    padding: 0 0.06em;
    background: linear-gradient(180deg, transparent 55%, rgba(255,184,0,0.55) 55%);
    -webkit-box-decoration-break: clone;
    box-decoration-break: clone;
  }
  .hero p {
    font-size: 1rem; color: var(--muted); margin-top: 1rem; max-width: 700px; margin-inline: auto;
    animation: fadeUp 0.7s ease-out 0.12s both;
  }
  .hero .hero-lead {
    font-size: 1.05rem; color: var(--text);
  }
  .hero .hero-lead strong { color: var(--bright); font-weight: 800; }
  .hero p code {
    background: var(--surface); border: 1px solid var(--border); border-radius: 3px;
    padding: 0.1rem 0.35rem; font-size: 0.85rem; color: var(--bright);
  }
  .hero > code {
    display: inline-block; margin-top: 1.5rem; padding: 0.6rem 1.4rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
    font-size: 0.88rem; color: var(--bright); font-weight: 500;
    animation: fadeUp 0.7s ease-out 0.24s both;
  }

  .stat { padding: 4rem 0; border-top: 1px solid var(--border); }
  .stat-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1.2rem; }
  .stat-card {
    text-align: center; padding: 1.2rem 1rem; background: var(--surface);
    border: 1px solid var(--border); border-radius: 8px;
    animation: fadeUp 0.8s ease-out 0.28s both;
  }
  .stat-num {
    display: block; font-family: var(--fd); font-weight: 900;
    font-size: clamp(2rem, 5vw, 3.2rem);
    color: var(--gold); line-height: 1.05;
    text-shadow: 0 0 80px var(--gold-soft);
  }
  .stat-label { display: block; font-size: 0.82rem; color: var(--muted); margin-top: 0.45rem; }
  .stat-ctx { font-size: 0.82rem; color: var(--dim); margin-top: 1.4rem; text-align: center; }
  .stat-ctx em { color: var(--muted); font-style: normal; font-weight: 500; }

  .bench { padding: 4rem 0; border-top: 1px solid var(--border); }
  .bench h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .bench-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 2.3rem; }
  .bench-sub code { background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.75rem; color: var(--bright); }

  .bg { margin-bottom: 2.8rem; }
  .bg-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.9rem; flex-wrap: wrap; gap: 0.5rem; }
  .bg-title { font-family: var(--fd); font-weight: 700; font-size: 0.95rem; color: var(--bright); }
  .bg-title span { color: var(--muted); font-weight: 400; font-size: 0.82rem; margin-left: 0.4rem; }
  .bg-note { font-size: 0.8rem; color: var(--muted); line-height: 1.55; margin-top: 0.6rem; }
  .bg-note code { background: var(--surface); padding: 0.05rem 0.3rem; border-radius: 3px; font-size: 0.72rem; color: var(--bright); }
  .bg-badge {
    font-family: var(--fd); font-weight: 800; font-size: 0.82rem; color: #92400e;
    background: rgba(251,191,36,0.15); border: 1px solid rgba(251,191,36,0.35);
    padding: 0.2rem 0.75rem; border-radius: 20px;
    opacity: 0; transform: translateY(4px); transition: opacity 0.4s 0.9s, transform 0.4s 0.9s;
  }
  .bg.visible .bg-badge { opacity: 1; transform: none; }
  .br { display: flex; align-items: center; gap: 0.7rem; margin-bottom: 0.45rem; }
  .br-l { width: 8.5rem; text-align: right; font-size: 0.72rem; color: var(--muted); flex-shrink: 0; font-weight: 500; }
  .br-t { flex: 1; height: 40px; background: var(--surface); border-radius: 6px; overflow: hidden; }
  .br-b {
    height: 100%; border-radius: 6px;
    width: 0; transition: width 1.3s cubic-bezier(0.16, 1, 0.3, 1);
  }
  .br-b.apt { background: #E4E4E4; }
  .br-b.zb { background: #D8D8D8; }
  .br-b.old { background: linear-gradient(90deg, #FFC84A 0%, #FFB800 100%); opacity: 0.6; }
  .br-b.nb  { background: linear-gradient(90deg, #FFB800 0%, #FF8000 100%); box-shadow: 0 2px 16px rgba(255,140,0,0.22); }
  .bg.visible .br:nth-child(1) .br-b { transition-delay: 0s; }
  .bg.visible .br:nth-child(2) .br-b { transition-delay: 0.12s; }
  .bg.visible .br:nth-child(3) .br-b { transition-delay: 0.24s; }
  .bg.visible .br:nth-child(4) .br-b { transition-delay: 0.36s; }
  .br-time { font-size: 0.76rem; font-family: var(--fd); font-weight: 600; flex-shrink: 0; width: 5.8rem; color: var(--muted); }
  .br-time.old-t  { color: #b45309; }
  .br-time.nb-t   { color: #c05621; }

  .demo { padding: 4rem 0; border-top: 1px solid var(--border); }
  .demo h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .demo-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 1.5rem; }
  .demo-sub code { background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.75rem; }
  .demo pre {
    background: #0e0e0f; color: #e7e7ea; border-radius: 8px; padding: 1.1rem 1.2rem;
    font-family: var(--fm); font-size: 0.78rem; line-height: 1.55;
    overflow-x: auto; border: 1px solid #1c1c1f;
  }
  .demo pre .p { color: #ffb800; font-weight: 700; }
  .demo pre .k { color: #9ea0a4; }
  .demo pre .h { color: #fff; font-weight: 600; }

  .release-status { padding: 3rem 0; border-top: 1px solid var(--border); }
  .release-status h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.75rem; }
  .status-box {
    background: #fff7ed; border: 1px solid #fed7aa; border-radius: 8px;
    padding: 1.2rem 1.35rem; color: #7c2d12; font-size: 0.82rem;
  }
  .status-box strong { color: #9a3412; }
  .status-box code { background: rgba(154,52,18,0.08); padding: 0.08rem 0.3rem; border-radius: 3px; color: #9a3412; }

  .credits { padding: 3rem 0; border-top: 1px solid var(--border); }
  .credits h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.75rem; }
  .credits p { font-size: 0.82rem; color: var(--muted); margin-bottom: 0.8rem; }
  .credits a { color: var(--bright); text-decoration: none; font-weight: 700; border-bottom: 1px solid var(--border); }

  .how { padding: 4rem 0; border-top: 1px solid var(--border); }
  .how h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 1.5rem; }
  .how-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1.5rem; }
  .how-card {
    padding: 1.5rem; background: var(--surface); border-radius: 8px; border: 1px solid var(--border);
  }
  .how-card h3 { font-size: 0.9rem; color: var(--bright); margin-bottom: 0.4rem; }
  .how-card p { font-size: 0.78rem; color: var(--muted); line-height: 1.5; }
  .how-card code { background: rgba(255,184,0,0.1); padding: 0.05rem 0.3rem; border-radius: 3px; font-size: 0.72rem; color: var(--bright); }
  .how-card .num { font-family: var(--fd); font-weight: 800; font-size: 1.4rem; color: var(--gold); margin-bottom: 0.3rem; }

  .method { padding: 4rem 0; border-top: 1px solid var(--border); }
  .method h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .method-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 1.5rem; }
  .method table { width: 100%; border-collapse: collapse; font-size: 0.82rem; }
  .method th { text-align: left; padding: 0.6rem 0.8rem; border-bottom: 2px solid var(--border); color: var(--muted); font-weight: 500; }
  .method td { padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--border); vertical-align: top; }
  .method td code { font-size: 0.75rem; background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; }

  footer { padding: 3rem 0; border-top: 1px solid var(--border); text-align: center; font-size: 0.75rem; color: var(--dim); }
  footer a { color: var(--muted); }

  @media (max-width: 760px) {
    .wrap { padding: 0 1.1rem; }
    nav { align-items: flex-start; gap: 1rem; }
    .stat-grid { grid-template-columns: 1fr; }
    .br { display: block; }
    .br-l { display: block; width: auto; text-align: left; margin-bottom: 0.25rem; }
    .br-time { display: block; width: auto; margin-top: 0.25rem; }
    .method { overflow-x: auto; }
    .method table { min-width: 680px; }
  }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <a class="nav-mark" href="/">nanobrew</a>
    <div class="nav-links">
      <a href="https://github.com/justrach/nanobrew">GitHub</a>
      <a href="https://github.com/justrach/nanobrew#install">Install</a>
      <a href="/v0.1.198">v0.1.198</a>
      <a href="/v0.1.192">v0.1.192</a>
      <a href="/v0.1.191">v0.1.191</a>
      <a href="/v0.1.190">v0.1.190</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew v0.1.193</h1>
    <div class="hero-claim"><span class="hero-highlight">All the v0.1.192 speed.</span> <span class="hero-highlight">Audit-hardened.</span></div>
    <div class="hero-speed"><span class="hero-highlight">119.4x faster than Homebrew.</span> <span class="hero-highlight">12.9x faster than apt-get.</span></div>
    <p class="hero-lead"><strong>Install path is unchanged from v0.1.192</strong> — every speed number on this page still holds. What's new is 38 commits and 20+ targeted bug fixes from a multi-agent + manual audit, a new <code>nb cleanup --prune-kegs</code> flag, and honest disclosure of the pre-existing apt-replacement teardown bug.</p>
    <p>macOS arm64 and x86_64 tarballs are Developer-ID-signed, hardened-runtime, and notarized by Apple.</p>
    <code>nb update  # to v0.1.193</code>
  </section>

  <section class="stat">
    <div class="stat-grid">
      <div class="stat-card">
        <span class="stat-num">119.4x</span>
        <span class="stat-label">faster than Homebrew on yt-dlp target reinstall (inherited from v0.1.192)</span>
      </div>
      <div class="stat-card">
        <span class="stat-num">12.9x</span>
        <span class="stat-label">faster than apt-get on git + vim + build-essential (116 deps, Ubuntu 24.04)</span>
      </div>
      <div class="stat-card">
        <span class="stat-num">5.8ms</span>
        <span class="stat-label">already-installed no-op on the sandboxed CI yt-dlp benchmark</span>
      </div>
    </div>
    <p class="stat-ctx"><em>yt-dlp target reinstall:</em> nanobrew 48.8ms &rarr; zerobrew 1830.7ms &rarr; Homebrew 5827.7ms. <em>git+vim+build-essential:</em> nanobrew 3402ms &rarr; apt-get 43,833ms. Numbers are from the v0.1.192 baseline; v0.1.193 keeps the same install pipeline intact while fixing 20+ correctness bugs around it.</p>
  </section>

  <section class="bench">
    <h2>macOS — nanobrew vs Homebrew (warm)</h2>
    <p class="bench-sub">Already-installed reinstalls. Apple Silicon (GitHub Actions <code>macos-14</code>), median of 3 runs. Same install pipeline as v0.1.192; v0.1.193 doesn't move these.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">tree <span>0 deps</span></div>
        <div class="bg-badge">452x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">4070ms</span></div>
      <div class="br"><div class="br-l">zerobrew warm</div><div class="br-t"><div class="br-b zb" style="width:5.9%"></div></div><span class="br-time">242ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193</div><div class="br-t"><div class="br-b nb"  style="width:0.22%"></div></div><span class="br-time nb-t">9ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">ffmpeg <span>11 deps</span></div>
        <div class="bg-badge">49.7x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">14252ms</span></div>
      <div class="br"><div class="br-l">zerobrew warm</div><div class="br-t"><div class="br-b zb" style="width:15.1%"></div></div><span class="br-time">2147ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193</div><div class="br-t"><div class="br-b nb"  style="width:2.01%"></div></div><span class="br-time nb-t">287ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">wget <span>6 deps</span></div>
        <div class="bg-badge">146x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">3935ms</span></div>
      <div class="br"><div class="br-l">zerobrew warm</div><div class="br-t"><div class="br-b zb" style="width:14.9%"></div></div><span class="br-time">587ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193</div><div class="br-t"><div class="br-b nb"  style="width:0.69%"></div></div><span class="br-time nb-t">27ms</span></div>
    </div>
  </section>

  <section class="bench">
    <h2>Linux / Docker — nb install --deb vs apt-get</h2>
    <p class="bench-sub">Ubuntu 24.04 LTS (aarch64, Docker/Colima), median of 3 runs. Warm = NBIX binary index cache + cached .deb blobs, <code>--skip-postinst</code>. Audit-fixed in v0.1.193: cwd-independent <code>nb remove --deb</code>, native xz lifecycle, threadsafe postinst Io, serialized patchelf.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">curl + wget <span>35 packages</span></div>
        <div class="bg-badge">7.6x faster than apt-get</div>
      </div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">3426ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193 warm</div><div class="br-t"><div class="br-b nb"  style="width:13.1%"></div></div><span class="br-time nb-t">448ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">curl + wget + tree + jq + htop + tmux <span>53 packages</span></div>
        <div class="bg-badge">6.9x faster than apt-get</div>
      </div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">3584ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193 warm</div><div class="br-t"><div class="br-b nb"  style="width:14.5%"></div></div><span class="br-time nb-t">521ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">git + vim + build-essential <span>116 packages</span></div>
        <div class="bg-badge">12.9x faster than apt-get</div>
      </div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">43833ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193 warm</div><div class="br-t"><div class="br-b nb"  style="width:7.76%"></div></div><span class="br-time nb-t">3402ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">nginx + redis-server + postgresql-client <span>78 packages</span></div>
        <div class="bg-badge">3.9x faster than apt-get</div>
      </div>
      <div class="br"><div class="br-l">apt-get</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">5501ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193 warm</div><div class="br-t"><div class="br-b nb"  style="width:25.5%"></div></div><span class="br-time nb-t">1402ms</span></div>
    </div>
  </section>

  <section class="bench">
    <h2>CI package-manager comparison — yt-dlp</h2>
    <p class="bench-sub">Same sandboxed macOS Actions benchmark as v0.1.192. Target reinstall means dependencies and cache/store were primed, then only <code>yt-dlp</code> was removed and installed again as <code>nb install --shims yt-dlp</code>. v0.1.193 keeps the same install path, so the numbers carry over.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">target reinstall <span>lower is better</span></div>
        <div class="bg-badge">119.4x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew 5.1.7</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">5827.7ms</span></div>
      <div class="br"><div class="br-l">zerobrew 0.2.1</div><div class="br-t"><div class="br-b zb" style="width:31.4%"></div></div><span class="br-time">1830.7ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.191</div><div class="br-t"><div class="br-b old" style="width:58.1%"></div></div><span class="br-time old-t">3385.2ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193</div><div class="br-t"><div class="br-b nb"  style="width:0.84%"></div></div><span class="br-time nb-t">48.8ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">already installed no-op <span>lower is better</span></div>
        <div class="bg-badge">186.8x faster than zerobrew</div>
      </div>
      <div class="br"><div class="br-l">nb v0.1.191</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">3183.7ms</span></div>
      <div class="br"><div class="br-l">zerobrew 0.2.1</div><div class="br-t"><div class="br-b zb" style="width:34.0%"></div></div><span class="br-time">1083.2ms</span></div>
      <div class="br"><div class="br-l">Homebrew 5.1.7</div><div class="br-t"><div class="br-b apt" style="width:28.8%"></div></div><span class="br-time">916.9ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.193</div><div class="br-t"><div class="br-b nb"  style="width:0.18%"></div></div><span class="br-time nb-t">5.8ms</span></div>
    </div>
  </section>

  <section class="bench">
    <h2>What got fixed in this cycle</h2>
    <p class="bench-sub">38 commits since v0.1.192. Grouped by area. Every entry maps to a commit on <code>main</code> or a closed issue. Most were caught by an internal multi-agent audit pass; the rest came from real user reports (credited below).</p>

    <div class="bg">
      <div class="bg-title">apt-replacement (.deb install path)</div>
      <div class="bg-note"><code>nb remove --deb</code> is now cwd-independent &middot; absolute paths in <code>state.json</code> going forward, with back-compat for older relative-path DBs &middot; native xz decompress releases its <code>Decompress</code> buffer through <code>deinit</code> instead of the original pointer &middot; postinst execution receives the caller's Io so subprocess spawns don't hit the failing singleton allocator &middot; five other correctness fixes in the apt-replacement path bundled together.</div>
    </div>

    <div class="bg">
      <div class="bg-title">ELF / patchelf</div>
      <div class="bg-note"><code>patchelf</code> auto-install serialized across parallel workers &middot; <code>apt-get update</code> before patchelf auto-install &middot; literal <code>/home/linuxbrew/</code> paths repaired in ELF needed-paths and a symlinked <code>etc/</code> handled correctly (closes #269 — imagemagick + libheif).</div>
    </div>

    <div class="bg">
      <div class="bg-title">Process-wide threadsafe Io accessor</div>
      <div class="bg-note">Call sites that previously reached for <code>std.Io.Threaded.global_single_threaded.io()</code> now share an accessor seeded from <code>main</code>. The default initializer falls back to the singleton so tests and any pre-main use still see a valid Io. Fixes intermittent races during parallel extract/store and the singleton call-site sweep that surfaced under <code>nb install --deb</code> reinstalls.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Install pipeline</div>
      <div class="bg-note"><code>nb install</code> threads io through the install path to fix Linux <code>CopyFailed</code> from incompatible Io in <code>std.process.run</code> (closes #276) &middot; <code>@@HOMEBREW_*@@</code> relocation now correctly rewrites files &gt;1 MiB and locale subtrees that previously slipped through &middot; <code>nb upgrade</code> rejects unknown flags and uninstalled package names instead of silently no-op'ing.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Diagnostics + cleanup</div>
      <div class="bg-note">New: <code>nb cleanup --prune-kegs</code> drops phantom <code>state.json</code> entries pointing at kegs that no longer exist on disk (closes #279) &middot; <code>nb doctor</code> now points at this flag when it spots phantom entries &middot; hint when the 256-entry batch cap is hit so users know to re-run.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Memory + parser safety</div>
      <div class="bg-note">DB parser partial-allocation leaks in <code>pushHistory</code> and install paths now cascade-free already-successful dupes when a later step fails &middot; <code>nb services list</code> memory leaks plugged.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Networking polish</div>
      <div class="bg-note">HTTP <code>User-Agent</code> override (instead of append) so requests no longer leak <code>zig/0.16.0 (std.http)</code> to upstream endpoints that filter on UA (closes #258 — fixes the Warp vendor download).</div>
    </div>
  </section>

  <section class="demo">
    <h2>The new flag in action</h2>
    <p class="demo-sub">After upgrading from v0.1.191 with <code>nb update</code>, <code>nb doctor</code> proactively points at the new prune flag.</p>
<pre>$ <span class="p">nb update</span>
<span class="h">==&gt; Updating nanobrew...</span>
<span class="k">==&gt; Downloading v0.1.193 (arm64-darwin)...</span>
<span class="k">==&gt; Verifying checksum...</span>
<span class="k">==&gt; Checksum verified, extracting...</span>
<span class="h">==&gt; Updated nanobrew to v0.1.193 (was v0.1.191)</span>

$ <span class="p">nb doctor</span>
<span class="k">==&gt; Checking nanobrew installation...</span>
  <span class="h">✓</span> /opt/nanobrew is writable
  <span class="k">✗</span> DB entry 'alsa-lib' has no Cellar dir (run <span class="p">nb cleanup --prune-kegs</span> to remove)
  <span class="k">✗</span> DB entry 'sag' has no Cellar dir (run <span class="p">nb cleanup --prune-kegs</span> to remove)

$ <span class="p">nb cleanup --prune-kegs</span>
<span class="k">  Pruned phantom keg: alsa-lib 1.2.15.3</span>
<span class="k">  Pruned phantom keg: sag</span>
<span class="h">==&gt; Reclaimed 22.6 MB</span></pre>
  </section>

  <section class="release-status">
    <h2>Known issue: <code>nb install --deb</code> exits 139 on Linux</h2>
    <div class="status-box">
      <p><strong>Files install correctly, but the process exits with SIGSEGV at teardown.</strong> This is pre-existing since v0.1.190 and tracked under CI's <code>continue-on-error: true # Known Zig std.http.Client + musl TLS segfault</code>. The crash is in runtime/libc teardown after <code>main()</code> returns; install/extract/postinst all complete and the files are present on disk. Reproducible cleanly under Apple <code>container</code>; usually masked in <code>tests/deb-parity.sh</code> by piping <code>nb</code> output through <code>tail</code>, which absorbs the signal. v0.1.193 documents this honestly rather than silently shipping over it again. Workaround for Dockerfile users: pipe through <code>tail</code> or wrap in <code>( … ) || true</code> so a downstream <code>RUN</code> step doesn't fail. Tracked as a release-blocker for the next cycle.</p>
    </div>
  </section>

  <section class="credits">
    <h2>Public issue credits</h2>
    <p>Thanks to <a href="https://github.com/noripcord">@noripcord</a> for <a href="https://github.com/justrach/nanobrew/issues/269">#269</a> — imagemagick with libheif support being broken. That report drove the literal <code>/home/linuxbrew/</code> ELF path repair and the <code>etc/</code> symlink handling.</p>
    <p>Thanks to <a href="https://github.com/gavmor">@gavmor</a> for <a href="https://github.com/justrach/nanobrew/issues/276">#276</a> — <code>nb install</code> failing with <code>CopyFailed</code> on Linux due to incompatible Io in <code>std.process.run</code>. That report drove the install-path io threading fix.</p>
  </section>

  <section class="how">
    <h2>Release artifacts</h2>
    <div class="how-grid">
      <div class="how-card">
        <div class="num">arm64</div>
        <h3>macOS arm64</h3>
        <p><code>nb-arm64-apple-darwin.tar.gz</code><br>signed (Developer ID Application: Rachit Pradhan, WWP9DLJ27P), hardened-runtime, notarized by Apple.</p>
      </div>
      <div class="how-card">
        <div class="num">x86_64</div>
        <h3>macOS x86_64</h3>
        <p><code>nb-x86_64-apple-darwin.tar.gz</code><br>built against <code>minos 12.0</code>, signed, hardened-runtime, notarized. x86 smoke-tested under Rosetta before packaging.</p>
      </div>
      <div class="how-card">
        <div class="num">arm64</div>
        <h3>Linux aarch64-musl</h3>
        <p><code>nb-aarch64-linux.tar.gz</code><br>statically linked single binary, no runtime deps.</p>
      </div>
      <div class="how-card">
        <div class="num">x86_64</div>
        <h3>Linux x86_64-musl</h3>
        <p><code>nb-x86_64-linux.tar.gz</code><br>statically linked single binary, no runtime deps.</p>
      </div>
    </div>
  </section>

  <section class="method">
    <h2>How to read this release</h2>
    <p class="method-sub">v0.1.193 isn't a speed release. It's a confidence release.</p>
    <table>
      <tr><th>Question</th><th>Answer</th></tr>
      <tr><td>Should I upgrade from v0.1.192?</td><td>Yes. Strict improvement — same install-path performance, plus 20+ correctness fixes and the new prune flag.</td></tr>
      <tr><td>Will <code>nb install --deb</code> work in my Dockerfile?</td><td>The files will install correctly, but the <code>RUN</code> step will exit 139 unless you pipe through <code>tail</code> or wrap in <code>( … ) || true</code>. Tracked for the next release.</td></tr>
      <tr><td>Are macOS tarballs notarized?</td><td>Yes — both arm64 and x86_64. Gatekeeper fetches the ticket online on first run; browser downloads no longer prompt as "unidentified developer".</td></tr>
      <tr><td>Did anything get faster?</td><td>Not deliberately. The audit was about correctness. Existing perf claims from v0.1.192 still hold on the same hardware.</td></tr>
      <tr><td>What's the new feature?</td><td>One: <code>nb cleanup --prune-kegs</code> for cleaning phantom DB entries. <code>nb doctor</code> points at it when it spots them.</td></tr>
    </table>
  </section>

  <footer>
    <p>nanobrew v0.1.193 &mdash; <a href="https://github.com/justrach/nanobrew">GitHub</a> &mdash; <a href="https://github.com/justrach/nanobrew/releases/tag/v0.1.193">Release notes</a> &mdash; Apache-2.0</p>
  </footer>
</div>
<script>
const obs = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) e.target.classList.add('visible'); }), { threshold: 0.2 });
document.querySelectorAll('[data-observe]').forEach(el => obs.observe(el));
</script>
</body>
</html>`;

const RELEASE_198_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>nanobrew v0.1.198: our own bottle registry, scanned for CVEs</title>
<meta name="description" content="nanobrew v0.1.198 runs its own GHCR bottle registry: 231 Homebrew bottles mirrored byte-for-byte plus repackaged upstream binaries, every bottle SBOM'd and CVE-scanned with revoke-and-fallback. Native ELF relocation makes the Linux relocate phase about 800x faster, warm resolve drops 147ms to 1.8ms, and it stays 100x+ faster than Homebrew.">
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
  .wrap { max-width: 880px; margin: 0 auto; padding: 0 2rem; }

  nav { padding: 1.5rem 0; display: flex; justify-content: space-between; align-items: center; }
  .nav-mark { font-family: var(--fd); font-weight: 700; font-size: 1rem; color: var(--bright); text-decoration: none; }
  .nav-links { display: flex; gap: 1.5rem; flex-wrap: wrap; justify-content: flex-end; }
  .nav-links a { color: var(--muted); text-decoration: none; font-size: 0.82rem; font-weight: 500; }
  .nav-links a:hover { color: var(--bright); }

  @keyframes fadeUp { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }

  .hero { padding: 4rem 0 3rem; text-align: center; }
  .hero h1 {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(2.1rem, 5vw, 3.4rem);
    color: var(--bright); line-height: 1.15;
    animation: fadeUp 0.7s ease-out both;
  }
  .hero-claim {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(1.85rem, 4.7vw, 3.25rem);
    line-height: 1.12; color: var(--bright);
    max-width: 820px; margin: 0.45rem auto 0;
    animation: fadeUp 0.7s ease-out 0.05s both;
  }
  .hero-speed {
    font-family: var(--fd); font-weight: 800;
    font-size: clamp(1.25rem, 2.8vw, 2rem);
    line-height: 1.18; color: var(--bright);
    max-width: 780px; margin: 0.65rem auto 0;
    animation: fadeUp 0.7s ease-out 0.1s both;
  }
  .hero-highlight {
    display: inline;
    padding: 0 0.06em;
    background: linear-gradient(180deg, transparent 55%, rgba(255,184,0,0.55) 55%);
    -webkit-box-decoration-break: clone;
    box-decoration-break: clone;
  }
  .hero p {
    font-size: 1rem; color: var(--muted); margin-top: 1rem; max-width: 700px; margin-inline: auto;
    animation: fadeUp 0.7s ease-out 0.12s both;
  }
  .hero .hero-lead {
    font-size: 1.05rem; color: var(--text);
  }
  .hero .hero-lead strong { color: var(--bright); font-weight: 800; }
  .hero p code {
    background: var(--surface); border: 1px solid var(--border); border-radius: 3px;
    padding: 0.1rem 0.35rem; font-size: 0.85rem; color: var(--bright);
  }
  .hero > code {
    display: inline-block; margin-top: 1.5rem; padding: 0.6rem 1.4rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
    font-size: 0.88rem; color: var(--bright); font-weight: 500;
    animation: fadeUp 0.7s ease-out 0.24s both;
  }

  .stat { padding: 4rem 0; border-top: 1px solid var(--border); }
  .stat-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1.2rem; }
  .stat-card {
    text-align: center; padding: 1.2rem 1rem; background: var(--surface);
    border: 1px solid var(--border); border-radius: 8px;
    animation: fadeUp 0.8s ease-out 0.28s both;
  }
  .stat-num {
    display: block; font-family: var(--fd); font-weight: 900;
    font-size: clamp(2rem, 5vw, 3.2rem);
    color: var(--gold); line-height: 1.05;
    text-shadow: 0 0 80px var(--gold-soft);
  }
  .stat-label { display: block; font-size: 0.82rem; color: var(--muted); margin-top: 0.45rem; }
  .stat-ctx { font-size: 0.82rem; color: var(--dim); margin-top: 1.4rem; text-align: center; }
  .stat-ctx em { color: var(--muted); font-style: normal; font-weight: 500; }

  .bench { padding: 4rem 0; border-top: 1px solid var(--border); }
  .bench h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .bench-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 2.3rem; }
  .bench-sub code { background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; font-size: 0.75rem; color: var(--bright); }

  .bg { margin-bottom: 2.8rem; }
  .bg-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.9rem; flex-wrap: wrap; gap: 0.5rem; }
  .bg-title { font-family: var(--fd); font-weight: 700; font-size: 0.95rem; color: var(--bright); }
  .bg-title span { color: var(--muted); font-weight: 400; font-size: 0.82rem; margin-left: 0.4rem; }
  .bg-note { font-size: 0.8rem; color: var(--muted); line-height: 1.55; margin-top: 0.6rem; }
  .bg-note code { background: var(--surface); padding: 0.05rem 0.3rem; border-radius: 3px; font-size: 0.72rem; color: var(--bright); }
  .bg-badge {
    font-family: var(--fd); font-weight: 800; font-size: 0.82rem; color: #92400e;
    background: rgba(251,191,36,0.15); border: 1px solid rgba(251,191,36,0.35);
    padding: 0.2rem 0.75rem; border-radius: 20px;
    opacity: 0; transform: translateY(4px); transition: opacity 0.4s 0.9s, transform 0.4s 0.9s;
  }
  .bg.visible .bg-badge { opacity: 1; transform: none; }
  .br { display: flex; align-items: center; gap: 0.7rem; margin-bottom: 0.45rem; }
  .br-l { width: 8.5rem; text-align: right; font-size: 0.72rem; color: var(--muted); flex-shrink: 0; font-weight: 500; }
  .br-t { flex: 1; height: 40px; background: var(--surface); border-radius: 6px; overflow: hidden; }
  .br-b {
    height: 100%; border-radius: 6px;
    width: 0; transition: width 1.3s cubic-bezier(0.16, 1, 0.3, 1);
  }
  .br-b.apt { background: #E4E4E4; }
  .br-b.zb { background: #D8D8D8; }
  .br-b.old { background: linear-gradient(90deg, #FFC84A 0%, #FFB800 100%); opacity: 0.6; }
  .br-b.nb  { background: linear-gradient(90deg, #FFB800 0%, #FF8000 100%); box-shadow: 0 2px 16px rgba(255,140,0,0.22); }
  .bg.visible .br:nth-child(1) .br-b { transition-delay: 0s; }
  .bg.visible .br:nth-child(2) .br-b { transition-delay: 0.12s; }
  .bg.visible .br:nth-child(3) .br-b { transition-delay: 0.24s; }
  .bg.visible .br:nth-child(4) .br-b { transition-delay: 0.36s; }
  .br-time { font-size: 0.76rem; font-family: var(--fd); font-weight: 600; flex-shrink: 0; width: 5.8rem; color: var(--muted); }
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
  .how-card code { background: rgba(255,184,0,0.1); padding: 0.05rem 0.3rem; border-radius: 3px; font-size: 0.72rem; color: var(--bright); }
  .how-card .num { font-family: var(--fd); font-weight: 800; font-size: 1.4rem; color: var(--gold); margin-bottom: 0.3rem; }

  .method { padding: 4rem 0; border-top: 1px solid var(--border); }
  .method h2 { font-family: var(--fd); font-weight: 700; font-size: 1.4rem; color: var(--bright); margin-bottom: 0.5rem; }
  .method-sub { font-size: 0.8rem; color: var(--dim); margin-bottom: 1.5rem; }
  .method table { width: 100%; border-collapse: collapse; font-size: 0.82rem; }
  .method th { text-align: left; padding: 0.6rem 0.8rem; border-bottom: 2px solid var(--border); color: var(--muted); font-weight: 500; }
  .method td { padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--border); vertical-align: top; }
  .method td code { font-size: 0.75rem; background: var(--surface); padding: 0.1rem 0.35rem; border-radius: 3px; }

  footer { padding: 3rem 0; border-top: 1px solid var(--border); text-align: center; font-size: 0.75rem; color: var(--dim); }
  footer a { color: var(--muted); }

  @media (max-width: 760px) {
    .wrap { padding: 0 1.1rem; }
    nav { align-items: flex-start; gap: 1rem; }
    .stat-grid { grid-template-columns: 1fr; }
    .br { display: block; }
    .br-l { display: block; width: auto; text-align: left; margin-bottom: 0.25rem; }
    .br-time { display: block; width: auto; margin-top: 0.25rem; }
    .method { overflow-x: auto; }
    .method table { min-width: 680px; }
  }
</style>
</head>
<body>
<div class="wrap">
  <nav>
    <a class="nav-mark" href="/">nanobrew</a>
    <div class="nav-links">
      <a href="https://github.com/justrach/nanobrew">GitHub</a>
      <a href="https://github.com/justrach/nanobrew#install">Install</a>
      <a href="/v0.1.198">v0.1.198</a>
      <a href="/v0.1.193">v0.1.193</a>
      <a href="/v0.1.192">v0.1.192</a>
      <a href="/v0.1.191">v0.1.191</a>
    </div>
  </nav>

  <section class="hero">
    <h1>nanobrew v0.1.198</h1>
    <div class="hero-claim"><span class="hero-highlight">Our own bottle registry.</span> <span class="hero-highlight">Scanned for CVEs.</span></div>
    <div class="hero-speed"><span class="hero-highlight">Still 100x+ faster than Homebrew.</span></div>
    <p class="hero-lead"><strong>nanobrew now serves its own bottles.</strong> Covered packages download from <code>ghcr.io/justrach/nb-bottles</code>, our own registry, instead of leaning on Homebrew's servers. Every pinned bottle is SBOM'd and CVE-scanned, with automatic revoke-and-fallback when one goes bad.</p>
    <p>macOS arm64 and x86_64 tarballs are Developer-ID-signed, hardened-runtime, and notarized by Apple.</p>
    <code>nb update  # to v0.1.198</code>
  </section>

  <section class="stat">
    <div class="stat-grid">
      <div class="stat-card">
        <span class="stat-num">231</span>
        <span class="stat-label">Homebrew bottles mirrored byte-for-byte to our own GHCR registry, across all four platforms</span>
      </div>
      <div class="stat-card">
        <span class="stat-num">~800x</span>
        <span class="stat-label">faster ELF relocate phase on Linux (4,777ms to 6ms) with native in-place rewriting</span>
      </div>
      <div class="stat-card">
        <span class="stat-num">37</span>
        <span class="stat-label">new verified packages with pinned bottle digests for every platform</span>
      </div>
    </div>
    <p class="stat-ctx"><em>Warm install resolve</em> dropped 147ms to 1.8ms (~80x). <em>Cached-bottle reinstall</em> dropped 534ms to 4ms (~130x). The gap over Homebrew (119.4x on the yt-dlp target reinstall) carries over from the v0.1.192 install path and only widens with these warm-path wins.</p>
  </section>

  <section class="bench">
    <h2>This release vs recent nanobrew</h2>
    <p class="bench-sub">Before and after, measured within nanobrew. macOS Apple Silicon and Linux aarch64, representative runs. Lower is better; the gold bar is v0.1.198.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">ELF relocate phase <span>Linux, fresh machine</span></div>
        <div class="bg-badge">~800x faster</div>
      </div>
      <div class="br"><div class="br-l">before (patchelf)</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">4,777ms</span></div>
      <div class="br"><div class="br-l">v0.1.198 native</div><div class="br-t"><div class="br-b nb" style="width:0.4%"></div></div><span class="br-time nb-t">6ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">cached-bottle reinstall <span>macOS</span></div>
        <div class="bg-badge">~130x faster</div>
      </div>
      <div class="br"><div class="br-l">before</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">534ms</span></div>
      <div class="br"><div class="br-l">v0.1.198</div><div class="br-t"><div class="br-b nb" style="width:0.75%"></div></div><span class="br-time nb-t">4ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">warm install resolve <span>non-registry token</span></div>
        <div class="bg-badge">~80x faster</div>
      </div>
      <div class="br"><div class="br-l">before</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">147ms</span></div>
      <div class="br"><div class="br-l">v0.1.198</div><div class="br-t"><div class="br-b nb" style="width:1.2%"></div></div><span class="br-time nb-t">1.8ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">Linux cold install <span>hexyl, fresh machine</span></div>
        <div class="bg-badge">~5x faster</div>
      </div>
      <div class="br"><div class="br-l">before</div><div class="br-t"><div class="br-b old" style="width:100%"></div></div><span class="br-time old-t">5,876ms</span></div>
      <div class="br"><div class="br-l">v0.1.198</div><div class="br-t"><div class="br-b nb" style="width:18.9%"></div></div><span class="br-time nb-t">1,110ms</span></div>
    </div>
  </section>

  <section class="bench">
    <h2>vs Homebrew and zerobrew: yt-dlp on a clean macOS runner</h2>
    <p class="bench-sub">Sandboxed macOS Actions benchmark. Target reinstall means dependencies and the cache/store were primed, then only <code>yt-dlp</code> was removed and reinstalled as <code>nb install --shims yt-dlp</code>. The install path is unchanged since v0.1.192, so these carry forward, and v0.1.198's warm-path wins only widen the gap.</p>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">target reinstall <span>lower is better</span></div>
        <div class="bg-badge">119.4x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">Homebrew 5.1.7</div><div class="br-t"><div class="br-b apt" style="width:100%"></div></div><span class="br-time">5827.7ms</span></div>
      <div class="br"><div class="br-l">zerobrew 0.2.1</div><div class="br-t"><div class="br-b zb" style="width:31.4%"></div></div><span class="br-time">1830.7ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.198</div><div class="br-t"><div class="br-b nb" style="width:0.84%"></div></div><span class="br-time nb-t">48.8ms</span></div>
    </div>

    <div class="bg" data-observe>
      <div class="bg-header">
        <div class="bg-title">already installed no-op <span>lower is better</span></div>
        <div class="bg-badge">158x faster than Homebrew</div>
      </div>
      <div class="br"><div class="br-l">zerobrew 0.2.1</div><div class="br-t"><div class="br-b zb" style="width:100%"></div></div><span class="br-time">1083.2ms</span></div>
      <div class="br"><div class="br-l">Homebrew 5.1.7</div><div class="br-t"><div class="br-b apt" style="width:84.6%"></div></div><span class="br-time">916.9ms</span></div>
      <div class="br"><div class="br-l">nb v0.1.198</div><div class="br-t"><div class="br-b nb" style="width:0.54%"></div></div><span class="br-time nb-t">5.8ms</span></div>
    </div>
  </section>

  <section class="bench">
    <h2>New: our own bottle registry</h2>
    <p class="bench-sub">Everything lives under <code>ghcr.io/justrach/nb-bottles</code>. Public GHCR is free for storage and egress, so running it costs $0. Bottles are content-addressed, so a mirror that preserves digests is transparently trustworthy: nanobrew verifies the same sha256 either way.</p>

    <div class="bg">
      <div class="bg-title">Tier 1: mirror</div>
      <div class="bg-note">Byte-identical copies of all 231 Homebrew bottles we already pin, four platforms each. Digests are unchanged, so existing registry records work against the mirror with zero edits. This is insurance against upstream garbage-collection, renames, and outages. One env var, <code>NANOBREW_BOTTLE_DOMAIN=https://ghcr.io/v2/justrach/nb-bottles</code>, moves the whole fleet over.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Tier 2: repackage</div>
      <div class="bg-note">Upstream <code>github_release</code> binaries (ripgrep, fd, bat, jq, gh, and friends) re-laid into bottle form and published under our namespace. They carry no Homebrew placeholders, so the relocate phase does nothing and they get the fastest install path nanobrew has: blob cache, store, copy-on-write materialize, link. These pull from our registry by default.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Why it matters</div>
      <div class="bg-note">A metadata mirror is not independence. The bottle, the bytes you actually install and run, is the real dependency. For covered packages, those bytes now come from infrastructure we control, digest-verified identical to what Homebrew pins. Homebrew's bottle host can go down and your covered installs keep working.</div>
    </div>
  </section>

  <section class="bench">
    <h2>Supply-chain security</h2>
    <p class="bench-sub">The part Homebrew does not do. Every pinned bottle gets a real supply-chain pass, and a weekly CI cron rescans the whole fleet against fresh CVE data, opening a security issue on any hit.</p>

    <div class="bg">
      <div class="bg-title">CVE scanning</div>
      <div class="bg-note"><code>syft</code> builds an SBOM for each pinned bottle (all four platforms, Linux included), <code>grype</code> matches it against CVE data, and the job fails at or above the gate (default high). The first full run already caught a real one: <code>gh</code> 2.91.0 ships a Go 1.26.2 standard library with HIGH-severity CVEs.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Revoke and fallback</div>
      <div class="bg-note"><code>revoke</code> marks a bad pin and records the previous known-good version as a fallback. The resolver then installs that fallback and prints a warning naming the advisory; a revoked pin with no fallback fails closed. No binary release is needed, since revocations propagate through the registry in about six hours. <code>nb doctor</code> flags any machine that already installed a now-revoked version, with the exact fix.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Provenance and immutability</div>
      <div class="bg-note"><code>attest</code> ranks each upstream asset by the strongest vouching available (github-attestation, then checksum-file, then pin-only) and dies on any disagreement with upstream's published checksums. Version tags are immutable: a different blob can never be re-tagged under an existing version. SBOMs and scan reports ride along on each bottle's GHCR manifest as OCI referrer artifacts, so anyone can inspect a bottle's record without trusting our CI logs.</div>
    </div>
  </section>

  <section class="bench">
    <h2>What got faster</h2>
    <p class="bench-sub">The performance work behind the bars above.</p>

    <div class="bg">
      <div class="bg-title">Native ELF relocation</div>
      <div class="bg-note">Linux relocation is now native and in-place instead of shelling out to <code>patchelf</code>. A short <code>/opt/nb</code> symlink makes every <code>@@HOMEBREW_*@@</code> replacement shorter than its placeholder, so RPATH/RUNPATH, DT_NEEDED, PT_INTERP, and <code>.rodata</code> strings are all rewritten in one pass. No subprocesses, and no <code>apt-get install patchelf</code> bootstrap, which alone cost about 4.8s on every fresh machine and made installs fail where no package manager existed.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Warm resolve: 147ms to 1.8ms</div>
      <div class="bg-note">Resolving any package outside the verified-upstream registry used to re-download the roughly 650KB registry from GitHub on every resolve. A fresh registry cache is now authoritative for misses too, and a fetched registry is cached even when the requested token is not in it, so non-registry resolves stop re-paying the remote fetch on every call.</div>
    </div>

    <div class="bg">
      <div class="bg-title">Cached-bottle reinstall: 534ms to 4ms</div>
      <div class="bg-note">The batch-shared GHCR bearer token was being fetched whenever any package had a ghcr.io bottle URL, even when every blob was already in the local cache. It is now fetched only when at least one bottle actually needs downloading.</div>
    </div>

    <div class="bg">
      <div class="bg-title">TLS out of the box, and more</div>
      <div class="bg-note">A native post-install step wires <code>cert.pem</code> for brewed openssl/gnutls so TLS verification works on fresh Linux machines &middot; <code>@@HOMEBREW_PERL@@</code> shebangs are relocated so perl-backed tools run &middot; download retries are hardened with a transient-only whitelist and per-worker tmp paths &middot; <code>NB_BENCH=1</code> now reports per-phase timings (extract, materialize, relocate, link, postinstall) for each package.</div>
    </div>
  </section>

  <section class="how">
    <h2>Coverage this release</h2>
    <p class="bench-sub" style="margin-bottom:1.6rem">37 new verified-upstream packages with pinned bottle digests for all four platforms, on top of the 100/100 top formulae and 100/100 top casks already covered.</p>
    <div class="how-grid">
      <div class="how-card"><h3>Servers and infra</h3><p>nginx, qemu, colima, postgresql@14, postgresql@16, postgresql@18, mysql, tailscale</p></div>
      <div class="how-card"><h3>Languages and build</h3><p>node@24, rustup, gradle, poetry, composer, automake, expat, lcov</p></div>
      <div class="how-card"><h3>CLI and shells</h3><p>bash, zsh, eza, btop, hexyl, httpie, direnv, aria2, rsync, telnet, ghostscript</p></div>
      <div class="how-card"><h3>Security and devops</h3><p>sops, gitleaks, mkcert, kubeconform, flyctl, fastlane, xclogparser, xcresultparser, whisper-cpp, summarize</p></div>
    </div>
  </section>

  <section class="how">
    <h2>Release artifacts</h2>
    <div class="how-grid">
      <div class="how-card">
        <div class="num">arm64</div>
        <h3>macOS arm64</h3>
        <p><code>nb-arm64-apple-darwin.tar.gz</code><br>signed (Developer ID Application: Rachit Pradhan, WWP9DLJ27P), hardened-runtime, notarized by Apple.</p>
      </div>
      <div class="how-card">
        <div class="num">x86_64</div>
        <h3>macOS x86_64</h3>
        <p><code>nb-x86_64-apple-darwin.tar.gz</code><br>built against <code>minos 12.0</code>, signed, hardened-runtime, notarized.</p>
      </div>
      <div class="how-card">
        <div class="num">arm64</div>
        <h3>Linux aarch64-musl</h3>
        <p><code>nb-aarch64-linux.tar.gz</code><br>statically linked single binary, no runtime deps.</p>
      </div>
      <div class="how-card">
        <div class="num">x86_64</div>
        <h3>Linux x86_64-musl</h3>
        <p><code>nb-x86_64-linux.tar.gz</code><br>statically linked single binary, no runtime deps.</p>
      </div>
    </div>
  </section>

  <section class="method">
    <h2>How to read this release</h2>
    <p class="method-sub">v0.1.198 is an infrastructure and security release that also lands real speed wins.</p>
    <table>
      <tr><th>Question</th><th>Answer</th></tr>
      <tr><td>Should I upgrade from v0.1.193?</td><td>Yes. You get the own-registry mirror, CVE scanning with revoke-and-fallback, native ELF relocation, and faster warm installs.</td></tr>
      <tr><td>Do covered packages still depend on Homebrew's servers?</td><td>No. Their bottles are mirrored byte-for-byte to <code>ghcr.io/justrach/nb-bottles</code> (Tier 1) or repackaged under our namespace (Tier 2). The long-tail formula metadata still falls back to the Homebrew API.</td></tr>
      <tr><td>What happens if a pinned bottle gets a CVE?</td><td><code>revoke</code> records the last known-good version, the resolver installs that fallback with a warning, and it propagates through the registry without a binary release. <code>nb doctor</code> flags machines already on the bad version.</td></tr>
      <tr><td>Did anything get faster?</td><td>Yes. The Linux relocate phase is about 800x faster, warm resolve about 80x, and cached reinstalls about 130x. The lead over Homebrew (100x+) is unchanged or wider.</td></tr>
      <tr><td>Are macOS tarballs notarized?</td><td>Yes, both arm64 and x86_64: Developer-ID-signed, hardened-runtime, notarized by Apple.</td></tr>
    </table>
  </section>

  <footer>
    <p>nanobrew v0.1.198 &middot; <a href="https://github.com/justrach/nanobrew">GitHub</a> &middot; <a href="https://github.com/justrach/nanobrew/releases/tag/v0.1.198">Release notes</a> &middot; Apache-2.0</p>
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
          return new Response("0.1.198", {
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
        return new Response("0.1.198", {
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
          "cache-control": "public, max-age=300",
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

    if (url.pathname === "/v0.1.198" || url.pathname === "/v-0.1.198") {
      return new Response(RELEASE_198_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=86400",
        },
      });
    }

    if (url.pathname === "/v0.1.193" || url.pathname === "/v-0.1.193") {
      return new Response(RELEASE_193_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=86400",
        },
      });
    }

    if (url.pathname === "/v0.1.192" || url.pathname === "/v-0.1.192") {
      return new Response(RELEASE_192_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=86400",
        },
      });
    }

    if (url.pathname === "/v0.1.191" || url.pathname === "/v-0.1.191") {
      return new Response(RELEASE_191_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=86400",
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
