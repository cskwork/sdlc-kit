#!/usr/bin/env bash
# qa-mode.sh — which way the verifier drives a screen: `agent` (default: the
# `qa:` tool or any browser tool in the harness) or `jev` (Jego, scenarios in,
# one HTML report out; docs/jev-qa.md). Run from the project root.
#
#   tools/qa-mode.sh                          show the mode and where it comes from
#   tools/qa-mode.sh get                      print only the mode, for scripts
#   tools/qa-mode.sh set <agent|jev> [--project] [--jev-dir <path>]
#                                             remember the choice
#   tools/qa-mode.sh check                    can jev mode run here? (exit 0 = yes)
#
# Resolution, first non-empty wins: this project's `.sdlc/config.md`
# `qa_mode:` → the user default `qa_mode:` in
# ${XDG_CONFIG_HOME:-~/.config}/sdlc-kit/config → `agent`.
# `set` writes the user default, so a switch holds in every project until it
# is switched back; `--project` writes this project's config.md instead (an
# override that beats the user default). `jev_dir:` (the ego-jev-ultrafast
# checkout) resolves the same way.
set -euo pipefail

user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/sdlc-kit"
user_conf="$user_dir/config"
proj_conf=".sdlc/config.md"

# value of `key:` in a file, comments and surrounding space stripped; "" if absent
val() {
  [ -f "$2" ] || return 0
  sed -n "s/^$1:[[:space:]]*//p" "$2" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' | tail -1
}

# set `key: value` in a file, replacing an existing line or appending one
put() {
  local key="$1" value="$2" file="$3" tmp
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  if grep -q "^$key:" "$file"; then
    tmp="$file.tmp.$$"
    awk -v k="$key" -v v="$value" 'index($0, k ":") == 1 && !done { print k ": " v; done = 1; next } { print }' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then echo >> "$file"; fi
    printf '%s: %s\n' "$key" "$value" >> "$file"
  fi
}

resolve() {   # $1 = key; prints "value<TAB>source"
  local p u
  p=$(val "$1" "$proj_conf"); u=$(val "$1" "$user_conf")
  if [ -n "$p" ]; then printf '%s\t%s\n' "$p" "project ($proj_conf)"
  elif [ -n "$u" ]; then printf '%s\t%s\n' "$u" "user default ($user_conf)"
  else printf '\t%s\n' "unset"; fi
}

mode() {
  local m
  m=$(resolve qa_mode | cut -f1)
  case "$m" in
    ""|agent) echo agent ;;
    jev) echo jev ;;
    *) echo "qa-mode.sh: unknown qa_mode '$m' (agent|jev); using agent" >&2; echo agent ;;
  esac
}

check() {
  local dir problems=0
  dir=$(resolve jev_dir | cut -f1)
  dir="${dir/#\~/$HOME}"
  if [ -z "$dir" ]; then echo "jev_dir is not set (tools/qa-mode.sh set jev --jev-dir <ego-jev-ultrafast checkout>)"; problems=1
  elif [ ! -f "$dir/jego.js" ] || [ ! -f "$dir/qa/run.mjs" ]; then echo "jev_dir $dir has no jego.js and qa/run.mjs"; problems=1
  else echo "ok: jev_dir $dir"; fi
  if command -v ego-browser >/dev/null 2>&1; then echo "ok: ego-browser"; else echo "ego-browser is not on PATH (install Ego Lite)"; problems=1; fi
  if command -v node >/dev/null 2>&1; then echo "ok: node"; else echo "node is not on PATH"; problems=1; fi
  # The key is checked for presence only; it is never printed.
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then echo "ok: TypeSafe key (environment)"
  elif command -v security >/dev/null 2>&1 && security find-generic-password -a "$USER" -s jego-typesafe >/dev/null 2>&1; then echo "ok: TypeSafe key (Keychain jego-typesafe)"
  else echo "no TypeSafe key (TYPESAFE_API_KEY, or Keychain item jego-typesafe)"; problems=1; fi
  [ "$problems" = 0 ] && echo "jev mode: ready" || { echo "jev mode: NOT ready — the verifier falls back to agent QA and says why"; return 1; }
}

case "${1:-show}" in
  get) mode ;;
  show)
    src=$(resolve qa_mode | cut -f2)
    echo "qa_mode: $(mode)   # from: $( [ "$src" = unset ] && echo "default" || echo "$src")"
    d=$(resolve jev_dir)
    [ -z "$(printf '%s' "$d" | cut -f1)" ] || echo "jev_dir: $(printf '%s' "$d" | cut -f1)   # from: $(printf '%s' "$d" | cut -f2)"
    ;;
  set)
    shift
    new="${1:-}"; shift || true
    case "$new" in agent|jev) ;; *) echo "usage: tools/qa-mode.sh set <agent|jev> [--project] [--jev-dir <path>]" >&2; exit 2 ;; esac
    target="$user_conf"; jev_dir=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) [ -f "$proj_conf" ] || { echo "no $proj_conf here (run from the project root)" >&2; exit 2; }; target="$proj_conf" ;;
        --jev-dir) jev_dir="${2:?--jev-dir needs a path}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
      esac
      shift
    done
    put qa_mode "$new" "$target"
    [ -z "$jev_dir" ] || put jev_dir "$jev_dir" "$target"
    echo "qa_mode: $new   # saved in $target"
    if [ "$new" = jev ]; then check || true; fi
    ;;
  check) check ;;
  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
