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

# Download binary
URL="https://github.com/$REPO/releases/download/$LATEST/$TARBALL"

echo "  Downloading $TARBALL..."
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
<meta name="theme-color" content="#050505">
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
    --bg: #050505;
    --surface: #0A0A0A;
    --surface-raised: #0F0F0F;
    --border: #1A1A1A;
    --border-bright: #282828;
    --text: #D4D4D4;
    --bright: #FAFAFA;
    --muted: #777;
    --dim: #444;
    --dim-2: #2A2A2A;
    --brew-bar: #181818;
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
    background: url("data:image/svg+xml,%3Csvg viewBox='0 0 512 512' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.75' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.05'/%3E%3C/svg%3E");
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
    <span class="stat-num">3.5ms</span>
    <span class="stat-label">warm install time</span>
    <p class="stat-ctx"><em>7,000x</em> faster than Homebrew &middot; faster than <code>echo</code></p>
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

  <section class="demo">
    <h2>Quick start</h2>
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
          return new Response("0.1.06", {
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
        return new Response("0.1.06", {
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

    return Response.redirect("https://github.com/justrach/nanobrew", 302);
  },
};
