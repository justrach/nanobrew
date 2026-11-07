# JSON output

`--json` makes these commands print a single JSON document on stdout, so scripts and GUIs do not have to parse the human-readable text:

`nb list`, `nb outdated`, `nb info` (formula and `--cask`), `nb search`, `nb leaves`, `nb deps`, `nb services list` and `nb where`.

Errors and warnings still go to stderr, with the same exit code as the text command: a package that is not installed, a formula or cask that is not found, or an unknown flag exits 1. Progress lines such as `==> Searching ...` are not printed in JSON mode. In JSON mode `nb leaves` and `nb services list` also exit 1 when the database or service discovery fails (the text commands only warn).

Every document is one object with `schema` and command-specific fields:

```json
{"schema": 1, "packages": [ ... ]}
```

`schema` is the format version. Within schema 1, fields may only be added. A field that is removed or renamed, or whose meaning changes, gets a new `schema` number, so a tool can refuse a version it does not know. Tools should ignore fields they do not recognize. Fields marked *optional* are left out when they do not apply.

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

## `nb info --json [--cask] <name>...`

`packages` has one entry per name that was found; a name that is not found is reported on stderr and makes the command exit 1 after the document is printed.

```json
{"schema":1,"packages":[
  {"name":"jq","kind":"formula","version":"1.8.1","desc":"Lightweight and flexible command-line JSON processor",
   "homepage":"https://jqlang.org/","url":"https://ghcr.io/...","sha256":"...",
   "trust":{"tier":"checksum-verified","local_probe":"not recorded"},
   "installed":{"version":"1.8.1","pinned":false},
   "license":"MIT","bottled":true,"url_kind":"bottle","dependencies":["oniguruma"],"build_dependencies":[]}]}
```

| field | meaning |
|---|---|
| `name` | Formula name or cask token |
| `kind` | `formula` or `cask` |
| `version`, `desc`, `homepage` | As in the text output (`desc`/`homepage` may be `""`) |
| `url`, `sha256` | *optional* for formulae: the bottle, or the source when there is no bottle |
| `trust.tier` | `unverified`, `checksum-verified`, `source-verified` or `install-verified`, the same tier the text prints |
| `trust.local_probe` | `not recorded`, `passed`, `failed`, `stale` or `invalidated` |
| `trust.probed_at` | *optional* Unix time of the local probe |
| `trust.published` | *optional* `{source, result, observed_at, platform}` from the signed published evidence |
| `installed` | *optional* `{version, pinned}` when this package is installed |
| formula only | `license` (*optional*), `bottled`, `url_kind` (`bottle` or `source`, *optional*), `dependencies`, `build_dependencies`, `caveats` (*optional*) |
| cask only | `display_name`, `source` (`verified_upstream` or `homebrew`), `auto_updates`, `security_warnings` (`ghsa_id`, `cve_id`, `severity`, `summary`, `url`, `affected_versions`, `patched_versions`), `artifacts` |

Each `artifacts` entry has a `type` (`app`, `binary`, `pkg`, `font`, `artifact`, `suite`, `installer` or `uninstall`) and, depending on the type, `path`, `source` and `target`, `executable` and `args`, or `quit` and `pkgutil`.

## `nb search --json <query>`

```json
{"schema":1,"query":"ripgrep","packages":[
  {"name":"ripgrep","kind":"formula","version":"15.1.0","desc":"Search tool like grep and The Silver Searcher","installed":false}]}
```

An empty `packages` array means no results. A failed search exits 1.

## `nb leaves --json [--tree]`

```json
{"schema":1,"packages":[
  {"name":"wget","kind":"formula","version":"1.25.0","pinned":false,
   "dependencies":[{"name":"openssl@3","version":"3.6.0"}]}],
 "unresolved":[]}
```

`dependencies` (installed dependencies only) is present only with `--tree`. `unresolved` lists installed formulae whose metadata could not be fetched, so the result may be incomplete; they are also warned about on stderr.

## `nb deps --json [--tree] <formula>`

Without `--tree`, `dependencies` is the full install order (dependencies first), without the formula itself:

```json
{"schema":1,"name":"wget","dependencies":["ca-certificates","openssl@3","libunistring","gettext","libidn2"]}
```

With `--tree`, `tree` is nested like the text tree; a shared dependency appears under every parent:

```json
{"schema":1,"tree":{"name":"wget","dependencies":[{"name":"libidn2","dependencies":[{"name":"gettext","dependencies":[]}]}]}}
```

## `nb services list --json`

`nb services --json` is the same. `--json` with `start`, `stop` or `restart` exits 1.

```json
{"schema":1,"services":[{"name":"postgresql@17","formula":"postgresql@17","version":"17.6","status":"running"}]}
```

`status` is `running` or `stopped`.

## `nb where --json <pattern>`

```json
{"schema":1,"pattern":"rip",
 "installed":[{"name":"ripgrep","kind":"formula","version":"15.1.0","pinned":false}],
 "installed_error":null,
 "files":[{"dir":"/opt/nanobrew/prefix/bin","name":"rg","type":"symlink"}],
 "index":[{"name":"ripgrep","kind":"formula","version":"15.1.0","desc":"..."}],
 "index_error":null}
```

The three sections match the text output: installed packages, entries in `prefix/{bin,lib,opt}` (`type` is `file`, `directory` or `symlink`), and search-index hits. The text output caps prefix entries at 50 and index hits at 20; JSON lists all of them. `installed_error` and `index_error` are `null`, or say why that section could not be read; the command still exits 0, as the text command does.

## Tap cask short names

`nb upgrade --cask` and `nb outdated` accept an installed tap cask by its short name, so `nb upgrade --cask nanobrew-ui` finds `Rex57/tap/nanobrew-ui`. This works only when exactly one installed tap cask has that short name; otherwise the command exits 1 and asks for the full token. JSON output always reports the full recorded token.
