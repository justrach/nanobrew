# Twitter Thread — nanobrew v0.1.190: Zig 0.16 + faster everything

---

**1/**
nanobrew v0.1.190 is out.

Zig 0.16.0 compiler, native tar extraction, persistent HTTP, O(1) dep resolution, and 15+ bug fixes.

11.8x faster than Homebrew on warm installs.
Both macOS binaries signed and notarized by Apple.

nanobrew.trilok.ai/v0.1.190

---

**2/**
The numbers (Apple Silicon, macOS, median of 3 runs):

```
tree — warm:           Homebrew 2.25s  →  nanobrew 0.19s   (11.8x)
tree — cold:           Homebrew 8.99s  →  nanobrew 1.19s    (7.6x)
wget + 5 deps — warm:  Homebrew 2.43s  →  nanobrew  0.58s   (4.2x)
wget + 5 deps — cold:  Homebrew 16.84s →  nanobrew 11.26s   (1.5x)
```

Zerobrew fails on wget entirely — Mach-O prefix length bug. We don't.

---

**3/**
We migrated to Zig 0.16 and discovered install_name_tool was never running.

For months.

The new std.Io threading model initialises global_single_threaded with a `.failing` allocator. Every call to `process.run` returned OutOfMemory on the first alloc — silently swallowed by `catch {}`.

Mach-O relocation looked fine in tests. The binaries were broken at runtime.

---

**4/**
The fix: thread real `io: std.Io` (captured from main at startup) down through relocateKeg and every process-spawning helper.

Before: install_name_tool and codesign were called 0 times.
After: called correctly for every dylib path that needs patching.

jq, lua, ncurses — all now actually relocate on install.

---

**5/**
Also eliminated all subprocess calls for tar extraction.

Before: `tar xzf` — fork, exec, wait. For every package.
After: native Zig USTAR/GNU tar parser. Zero fork/exec.

Side effect: file permissions are now preserved exactly from the mode bits in the archive header. Previously we were guessing — executable bit set → 755, otherwise 644.

---

**6/**
Two other perf wins:

Dep resolution was O(n²). Topological sort called `orderedRemove(0)` to dequeue — shifts the entire array on every step. Replaced with an index cursor. O(V+E) total, same ordering.

HTTP client is now reused across all downloads in a batch. GHCR auth token prefetched once before workers start. Head buffer bumped from 8 KiB to 32 KiB — was silently truncating redirect responses on large packages.

---

**7/**
15+ bugs fixed. A few favourites:

- `state.json` was written non-atomically. SIGKILL during install = corrupted DB. Fixed with temp file + rename.
- `nb outdated` had a use-after-free. Worker threads read freed memory after main returned. Found in ReleaseFast only.
- `nb cleanup` reported "freed 10.0 MB" regardless of actual bytes freed. Always. Every time.
- `nb update` was broken for everyone — tarball contained binary as `nb-arm64-apple-darwin` instead of `nb`. Fixed.

---

**8/**
First release with notarized macOS binaries.

Both arm64 and x86_64 builds are signed with Developer ID Application and submitted to Apple's notary service. Gatekeeper won't block them.

Notarization IDs if you want to verify:
- arm64: 9f558eeb-6a26-4e66-870c-69ac3acec00d
- x86_64: 4a2e1e8f-8eeb-4fc4-8cd9-52df675a5a1a

---

**9/**
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
