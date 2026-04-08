# Extended Keg Linking — Design Spec

## Goal

Fix #164 (libraries not symlinked) and #102 (silent symlink failures) by extending `linkKeg` to symlink `lib/`, `include/`, `share/` into the prefix, upgrading conflict handling to skip-with-warning across all directories, and adding matching `unlinkKeg` logic.

## Current State

`linkKeg` in `src/linker/linker.zig` only symlinks `bin/` and `sbin/` entries into `prefix/bin/`. It creates `prefix/opt/<name>` as a keg alias. `lib/`, `include/`, `share/` are never symlinked. Conflicts on `bin/` entries are silently swallowed via `catch {}`.

## Design

### `linkSubdir` helper

New function: `linkSubdir(alloc, keg_dir, subdir_name, prefix_target_dir)` — recursively walks a keg subdirectory and creates mirror symlinks in the prefix. Handles:

- **Flat entries** (files, symlinks): symlink `prefix/<subdir>/<name>` -> `keg/<subdir>/<name>`
- **Nested directories**: create intermediate directories under prefix, recurse
- **Conflicts**: if symlink already exists, readLink to check target. Same keg = overwrite (reinstall). Different keg = print `nb: warning: <path> already linked by <other>, skipping` and continue.

### Directories to link

| Keg subdir | Prefix target | Walk mode |
|------------|---------------|-----------|
| `bin/` | `prefix/bin/` | Flat (existing, upgraded to use helper) |
| `sbin/` | `prefix/bin/` | Flat (existing, upgraded) |
| `lib/` | `prefix/lib/` | Recursive |
| `include/` | `prefix/include/` | Recursive |
| `share/` | `prefix/share/` | Recursive |

### `unlinkKeg` changes

Walk the same 5 prefix directories. For each symlink, readLink and check if it points into the keg being unlinked. If so, remove it. After removing symlinks, clean up empty parent directories.

### Path constants and init

Add to `paths.zig`: `LIB_DIR`, `INCLUDE_DIR`, `SHARE_DIR`. Add to `runInit` directory list in `main.zig`.

### Files touched

- `src/linker/linker.zig` — refactor `linkKeg`/`unlinkKeg`, add `linkSubdir`
- `src/platform/paths.zig` — 3 new constants
- `src/main.zig` — 3 dirs in `runInit`
- `src/security_test.zig` — conflict detection and path validation tests
