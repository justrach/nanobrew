# JSON output

`nb list --json` and `nb outdated --json` print a single JSON document on stdout, so scripts and GUIs do not have to parse the human-readable text. Errors still go to stderr, and the exit code does not change: a package that is not installed or an unknown flag exits 1.

```json
{"schema": 1, "packages": [ ... ]}
```

`schema` is the format version. Within schema 1, fields may only be added. A field that is removed or renamed, or whose meaning changes, gets a new `schema` number, so a tool can refuse a version it does not know. Tools should ignore fields they do not recognize.

## `nb list --json [--versions]`

```json
{"schema":1,"packages":[
  {"name":"jq","kind":"formula","version":"1.6","pinned":true,
   "versions":[{"version":"1.6","switchable":false},{"version":"1.5","switchable":false}]},
  {"name":"firefox","kind":"cask","version":"1.0","pinned":false},
  {"name":"curl","kind":"deb","version":"8.5.0-2","pinned":false}]}
```

| field | meaning |
|---|---|
| `name` | Formula name, cask token as recorded (tap casks keep `user/tap/token`), or deb package name |
| `kind` | `formula`, `cask` or `deb` |
| `version` | Installed version |
| `pinned` | `nb pin` is set (always `false` for casks and debs) |
| `versions` | Formulae only, and only with `--versions`: recorded history, newest first. `switchable` means `nb switch` can reactivate it without a download. |

`--json` cannot be combined with `--names`.

## `nb outdated --json [--cask|--deb] [pkg...]`

```json
{"schema":1,"packages":[
  {"name":"node","kind":"formula","installed":"26.13.0_2","latest":"26.14.0","pinned":false,
   "upgrade_supported":true,"unsupported_reason":null},
  {"name":"tool","kind":"cask","installed":"1.0","latest":"2.0","pinned":false,
   "upgrade_supported":false,"unsupported_reason":"external installers cannot be rolled back"}]}
```

| field | meaning |
|---|---|
| `installed`, `latest` | Installed version and the newer version available |
| `pinned` | `nb upgrade` skips this package until `nb unpin` |
| `upgrade_supported` | `nb upgrade` can replace this package. For casks this runs the same check `nb upgrade --cask` makes, including the trust policy. |
| `unsupported_reason` | When `upgrade_supported` is `false`: the reason that `nb upgrade` prints in `[unsupported, skipping: ...]`, or `cannot prepare cask upgrade (<error>)`. Otherwise `null`. |

An empty `packages` array means everything is up to date. The `==> Checking ...` progress lines are not printed in JSON mode.
