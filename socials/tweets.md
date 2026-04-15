# Twitter Thread -- nanobrew v0.1.190: Zig 0.16 + faster everything

---

**1/**
nanobrew v0.1.190 is out.

Zig 0.16.0 compiler, native tar extraction, persistent HTTP, O(1) dep resolution, and 15+ bug fixes.

140x faster than Homebrew on warm installs. 1.4x faster than v0.1.083.
Both macOS binaries signed and notarized by Apple.

nanobrew.trilok.ai/v0.1.190

---

**2/**
The numbers (Apple Silicon, macOS, median of 3 runs):

```
tree (warm):   Homebrew 2.38s  ->  nb v0.1.083  23ms  ->  nb v0.1.190  17ms
tree (cold):   Homebrew 3.13s  ->  nb v0.1.083 394ms  ->  nb v0.1.190 356ms
```

v0.1.190 vs Homebrew: 140x warm, 9x cold
v0.1.190 vs v0.1.083: 1.4x warm, 1.1x cold

---

**3/**
Eliminated all subprocess calls for tar extraction.

Before: `tar xzf` -- fork, exec, wait. For every package.
After: native Zig USTAR/GNU tar parser. Zero fork/exec.

File permissions now preserved exactly from the mode bits in the archive header. Before we were guessing: executable bit set = 755, otherwise 644.

---

**4/**
Two algorithmic wins:

Dep resolution was O(n2). Topological sort called `orderedRemove(0)` on every dequeue, shifting the whole array. Replaced with an index cursor. O(V+E) total, same ordering.

HTTP client now reused across all downloads in a batch. GHCR auth token prefetched once before workers start. Head buffer bumped from 8 KiB to 32 KiB.

---

**5/**
15+ bugs fixed. A few favourites:

- `state.json` was written non-atomically. SIGKILL during install = corrupted DB. Fixed with temp file + rename.
- `nb outdated` had a use-after-free. Worker threads read freed memory after main returned. Found in ReleaseFast only.
- `nb cleanup` reported "freed 10.0 MB" regardless of actual bytes freed. Always. Every time.
- `nb update` was broken for everyone. Tarball contained binary as `nb-arm64-apple-darwin` instead of `nb`. Fixed.

---

**6/**
First release with notarized macOS binaries.

Both arm64 and x86_64 builds are signed with Developer ID Application and submitted to Apple's notary service. Gatekeeper won't block them.

Notarization IDs if you want to verify:
- arm64: 9f558eeb-6a26-4e66-870c-69ac3acec00d
- x86_64: 4a2e1e8f-8eeb-4fc4-8cd9-52df675a5a1a

---

**7/**
Try it:

```bash
# Fresh install
curl -fsSL https://nanobrew.trilok.ai | bash

# Upgrade
nb update
```

Full release notes with benchmark breakdowns:
nanobrew.trilok.ai/v0.1.190

github.com/justrach/nanobrew

---

*thread end*
