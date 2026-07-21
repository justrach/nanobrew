#!/usr/bin/env bash
set -euo pipefail

nb=${1:-./zig-out/bin/nb}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$nb" completions zsh >"$tmp/nb.zsh"
"$nb" completions bash >"$tmp/nb.bash"
"$nb" completions fish >"$tmp/nb.fish"

zsh -n "$tmp/nb.zsh"
bash -n "$tmp/nb.bash"
if command -v fish >/dev/null 2>&1; then
    fish -n "$tmp/nb.fish"
fi

# Empty installed-package output must produce no candidates and, in particular,
# no ZSH `bad substitution` diagnostic. A no-match helper returns status 1.
set +e
zsh -f -c '
  compdef() { :; }
  _describe() { print -r -- unexpected; }
  nb() { [[ "$1 $2" == "list --names" ]] || return 99; }
  source "$1"
  _nb_installed
' _ "$tmp/nb.zsh" >"$tmp/empty.out" 2>"$tmp/empty.err"
empty_status=$?
set -e
[[ $empty_status -eq 1 ]]
[[ ! -s "$tmp/empty.out" ]]
[[ ! -s "$tmp/empty.err" ]]

# Populated output must preserve complete package names, one candidate per line.
populated=$(zsh -f -c '
  compdef() { :; }
  _describe() { eval "print -l -- \${$2[@]}"; }
  nb() { [[ "$1 $2" == "list --names" ]] || return 99; print -l -- jq ripgrep; }
  source "$1"
  _nb_installed
' _ "$tmp/nb.zsh")
[[ $populated == $'jq\nripgrep' ]]

# Bash must use the same names-only contract for empty and populated databases.
bash_empty=$(bash --noprofile --norc -c '
  nb() { [[ "$1 $2" == "list --names" ]] || return 99; }
  source "$1"
  COMP_WORDS=(nb upgrade "")
  COMP_CWORD=2
  _nb_completions
  printf "%s" "${COMPREPLY[*]}"
' _ "$tmp/nb.bash")
[[ -z $bash_empty ]]

bash_populated=$(bash --noprofile --norc -c '
  nb() { [[ "$1 $2" == "list --names" ]] || return 99; printf "%s\n" jq ripgrep; }
  source "$1"
  COMP_WORDS=(nb upgrade "")
  COMP_CWORD=2
  _nb_completions
  printf "%s\n" "${COMPREPLY[@]}"
' _ "$tmp/nb.bash")
[[ $bash_populated == $'jq\nripgrep' ]]

# Fish is syntax-checked when available; always protect its data-source contract.
grep -Fq -- "(nb list --names 2>/dev/null)" "$tmp/nb.fish"

# The real machine-readable mode emits either nothing or one token per line.
"$nb" list --names | awk 'NF != 1 { exit 1 }'

# Output modes are intentionally mutually exclusive.
if "$nb" list --names --versions >"$tmp/conflict.out" 2>"$tmp/conflict.err"; then
    echo "expected conflicting list modes to fail" >&2
    exit 1
fi
grep -q -- '--versions and --names cannot be combined' "$tmp/conflict.err"

if "$nb" list --not-a-list-option >"$tmp/unknown.out" 2>"$tmp/unknown.err"; then
    echo "expected an unknown list option to fail" >&2
    exit 1
fi
grep -q -- "unknown list option '--not-a-list-option'" "$tmp/unknown.err"

echo "completion tests passed"
