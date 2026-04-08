# Extended Keg Linking — Design Spec

## Goal

Fix #164 (libraries not symlinked) and #102 (packages not accessible) by extending `linkKeg` to symlink `lib/`, `include/`, `share/` into the prefix, and upgrading all conflict handling from silent skip to skip-with-warning.

## Current State

`linkKeg` in `src/linker/linker.zig` only symlinks `bin/` and `sbin/` entries into `prefix/bin/`, plus a single `opt/<name>` directory symlink. `lib/`, `include/`, `share/` are never symlinked. The Mach-O relocator rewrites dylib paths to `/opt/nanobrew/prefix/lib/...` but no symlinks exist there. `prefix/lib/`, `prefix/include/`, `prefix/share/` directories aren't even created by `nb init`.

Existing conflict handling: if `symLinkAbsolute` fails (e.g., file exists), it prints a warning via `deprecatedWriter` but the `openDirAbsolute` on `bin/` itself is `catch {}` — completely silent if the directory doesn't exist.

## Design

### New helper: `linkSubdir`

```
fn linkSubdir(alloc, keg_dir, subdir_name, prefix_target_dir, keg_name) !void
```

Recursively walks `keg_dir/<subdir_name>/` and creates mirror symlinks in `prefix_target_dir/<subdir_name>/`. For nested paths like `share/man/man1/tree.1`, creates intermediate directories under prefix as needed.

**Conflict handling:** Before creating each symlink, check if the target path already exists. If it's a symlink, `readLink` to see where it points. If it points into the same keg (reinstall/upgrade), overwrite. If it points into a different keg, print `nb: warning: <path> already linked by <other_package>, skipping` and continue.

### Directories to link

| Keg subdir | Prefix target | Why |
|------------|--------------|-----|
| `bin/` | `prefix/bin/` | Executables (already done, upgrade conflict handling) |
| `sbin/` | `prefix/bin/` | System executables (already done, upgrade conflict handling) |
| `lib/` | `prefix/lib/` | Shared libraries, `.a` archives, pkgconfig |
| `include/` | `prefix/include/` | C/C++ headers for dependent builds |
| `share/` | `prefix/share/` | Man pages, completions, locale data |

### `unlinkKeg` changes

Mirror the link logic: walk the same 5 subdirectories in the prefix, remove any symlink whose readLink target starts with the keg path being unlinked. After removing symlinks, clean up empty parent directories.

### Path constants and init

Add to `paths.zig`:
- `LIB_DIR = PREFIX ++ "/lib"`
- `INCLUDE_DIR = PREFIX ++ "/include"`
- `SHARE_DIR = PREFIX ++ "/share"`

Add those to `runInit` in `main.zig`.

### Files touched

- `src/linker/linker.zig` — refactor existing `bin/sbin` linking to use `linkSubdir`, add `lib/include/share`
- `src/platform/paths.zig` — 3 new constants
- `src/main.zig` — 3 dirs in `runInit`
- `src/security_test.zig` — conflict detection and recursive walk tests
