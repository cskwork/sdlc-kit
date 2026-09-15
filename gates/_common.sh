#!/usr/bin/env bash
# _common.sh — shared helpers for gates/*.sh. Sourced, never run directly.
# Keep it dependency-free: POSIX tools plus git, no python, no jq.

# --- hashing -----------------------------------------------------------------
# sha256 is used for CHANGE DETECTION only: it proves an artifact is byte-identical
# to the one that was approved. It authenticates nobody — anyone who can write the
# artifact can write the approval record next to it (both live in the working copy).
sdlc_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 | awk '{print $NF}'
  else echo "FAIL: no sha256 tool found (need shasum, sha256sum, or openssl)" >&2; return 1; fi
}
sdlc_sha256_file() { # <path>
  [ -f "$1" ] || return 1
  sdlc_sha256_stdin < "$1"
}

# --- stage ↔ artifact allowlist ---------------------------------------------
# Gated stages and the ONE artifact each gate may bind. An approval for any other
# name is refused: a gate that can bind an arbitrary file binds nothing.
sdlc_stage_artifact() { # <stage> → expected basename, or empty for an unknown stage
  case "$1" in
    intent) echo intent.md;; spec) echo spec.md;; plan) echo plan.md;; ship) echo evidence.md;;
    *) return 1;;
  esac
}
# Upstream artifacts whose content the gate also binds (AGENTS.md rule 3): a
# material edit upstream must not leave a downstream gate reusable. These are
# CANDIDATES: approve.sh binds the ones that exist at approval time, so the
# compact route (intent.md only, no spec.md, no plan.md) binds just the intent
# and is never asked for an artifact it does not have.
sdlc_upstream_stages() { # <stage> → stages listed oldest-first
  case "$1" in
    intent) echo "";; spec) echo "intent";; plan) echo "intent spec";; ship) echo "intent spec plan";;
    *) echo "";;
  esac
}
# Upstream artifacts that exist on disk and are NOT bound by this record. A
# record written by an older kit binds no digest for them, so a downstream gate
# would silently outlive a rewrite of a spec or plan it was granted on top of.
# An ABSENT upstream artifact is never reported — that is the compact route.
sdlc_upstream_unbound() { # <record> <slug> → stage names, space-separated (may be empty)
  local rec="$1" slug="$2" stage up upart out=""
  stage=$(sdlc_field "$rec" stage || true)
  [ -n "$stage" ] || return 0
  for up in $(sdlc_upstream_stages "$stage"); do
    upart=".sdlc/work/$slug/$(sdlc_stage_artifact "$up")"
    [ -f "$upart" ] || continue
    [ -n "$(sdlc_field "$rec" "upstream_$up" || true)" ] && continue
    out="$out $up"
  done
  printf '%s\n' "${out# }"
}

# --- path canonicalization ---------------------------------------------------
# Every gated artifact must resolve to <project-root>/.sdlc/work/<slug>/<file>.
# Checked physically (pwd -P), so `..`, a symlinked feature dir, or a same-slug
# tree somewhere else cannot reuse another feature's approval.
# Prints the canonical project-relative path on success; a reason on stderr and
# a non-zero exit otherwise.
sdlc_canon_artifact() { # <path>
  local art="$1" dir base dir_phys work_phys slug
  case "$art" in ("") echo "empty artifact path" >&2; return 1;; esac
  base=$(basename "$art"); dir=$(dirname "$art")
  case "$base" in
    (.|..|*/*) echo "artifact must be a plain file name: $art" >&2; return 1;;
    (*[!a-zA-Z0-9._-]*) echo "artifact name must be [a-zA-Z0-9._-]+: $base" >&2; return 1;;
  esac
  [ -e "$art" ] || { echo "artifact not found: $art" >&2; return 1; }
  [ -L "$art" ] && { echo "artifact is a symlink (not allowed): $art" >&2; return 1; }
  [ -f "$art" ] || { echo "artifact is not a regular file: $art" >&2; return 1; }
  [ -d .sdlc/work ] || { echo "no .sdlc/work/ here — run this from the project root" >&2; return 1; }
  work_phys=$(cd .sdlc/work 2>/dev/null && pwd -P) || { echo "cannot resolve .sdlc/work" >&2; return 1; }
  dir_phys=$(cd "$dir" 2>/dev/null && pwd -P) || { echo "cannot resolve directory of $art" >&2; return 1; }
  slug=$(basename "$dir_phys")
  if [ "$dir_phys" != "$work_phys/$slug" ]; then
    echo "artifact must live in <project-root>/.sdlc/work/<slug>/ (resolved: $dir_phys)" >&2; return 1
  fi
  case "$slug" in
    (.|..|"") echo "invalid feature slug" >&2; return 1;;
    (*[!a-zA-Z0-9._-]*) echo "feature slug must be [a-zA-Z0-9._-]+: $slug" >&2; return 1;;
  esac
  printf '.sdlc/work/%s/%s\n' "$slug" "$base"
}
sdlc_slug_of() { # <canonical path> → slug
  printf '%s\n' "$1" | awk -F/ '{print $3}'
}

# --- reviewed source identity ------------------------------------------------
# The ship review is a review of the project's SOURCE, so the ship approval binds
# the whole source snapshot — not only the part that happened to be uncommitted:
#   every tracked file + every untracked file git does not ignore, minus .sdlc/.
# Everything about that is deliberate:
#   - work COMMITTED BEFORE the review is bound too (a diff-vs-HEAD set is empty
#     in that case and would bind nothing at all),
#   - staging or committing the same bytes changes nothing — the snapshot is
#     content, never index or commit identity,
#   - a file added, removed, chmod'ed, or turned into a symlink after the review
#     is drift, and so is an edit to a file the review did not name. A source
#     change nobody reviewed must not close silently.
# .sdlc/ is excluded: evidence.md, delivery.md, and the approval record live
# there and are written after the review — a binding covering them could never
# match itself. Submodule contents are NOT bound (the gitlink is, by path only).
#
# Path names are line-based. `core.quotepath=off` prints Unicode and spaces
# verbatim, but git still C-quotes a name that contains a tab, a newline, a
# double quote, or a backslash (`"we\"ird.txt"`). Such a line is not a path on
# disk, so it can be neither hashed nor watched — and a stable placeholder for it
# would bind nothing while looking bound. Those names are UNSUPPORTED: they are
# reported as `unsupported` entries, approve.sh refuses to bind a snapshot that
# has one, and sdlc_source_state answers `invalid` for as long as one exists.
# A name that is missing on disk is different and stays `missing`: a tracked
# file deleted in the worktree is an ordinary state the review can look at.
sdlc_source_paths() { # → project-relative source paths, one per line; non-zero when git cannot list them
  local raw
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  raw=$(git -c core.quotepath=off ls-files -c -o --exclude-standard 2>/dev/null) || {
    echo "FAIL: git ls-files could not enumerate the source" >&2; return 1; }
  printf '%s\n' "$raw" | awk 'NF && $0 !~ /^\.sdlc\//' | LC_ALL=C sort -u
}
# One entry line per path: "<kind> <mode> <content-sha256> <path>". The mode
# column is `x` for an executable file, `-` otherwise, so a chmod is drift; a
# symlink hashes its TARGET STRING, exactly like git stores it, so a file
# replaced by a symlink is drift too. Paths are addressed as ./<path> so a name
# that starts with `-` is never read as an option by readlink or test.
# Exit status is non-zero when ANY entry could not be hashed (a FAIL: line names
# it on stderr); the caller must treat that as no snapshot at all.
sdlc_source_entries() { # paths on stdin → entry lines (sorted); non-zero on a hashing failure
  local out rc=0
  out=$(sdlc__entries_unsorted) || rc=$?      # captured: the loop's status survives without pipefail
  [ -z "$out" ] || printf '%s\n' "$out" | LC_ALL=C sort
  return $rc
}
sdlc__entries_unsorted() { # helper of sdlc_source_entries
  local f h t rc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in (\"*) printf 'unsupported - - %s\n' "$f"; continue;; esac   # git C-quoted it
    if [ -L "./$f" ]; then
      if t=$(readlink "./$f") && h=$(printf '%s' "$t" | sdlc_sha256_stdin) && [ -n "$h" ]; then
        printf 'l - %s %s\n' "$h" "$f"
      else echo "FAIL: cannot hash symlink target: $f" >&2; rc=1; fi
    elif [ -d "./$f" ]; then
      printf 'submodule - - %s\n' "$f"
    elif [ -f "./$f" ]; then
      if h=$(sdlc_sha256_file "./$f") && [ -n "$h" ]; then
        if [ -x "./$f" ]; then printf 'f x %s %s\n' "$h" "$f"
        else printf 'f - %s %s\n' "$h" "$f"; fi
      else echo "FAIL: cannot hash file: $f" >&2; rc=1; fi
    else
      printf 'missing - - %s\n' "$f"
    fi
  done
  return $rc
}
# The whole snapshot in one call: paths + entries, with either failure made
# visible as a non-zero status instead of a shorter list that hashes fine.
sdlc_source_snapshot() { # → entry lines (sorted); non-zero when enumeration or hashing failed
  local paths
  paths=$(sdlc_source_paths) || return 1
  printf '%s\n' "$paths" | sdlc_source_entries
}
# How many entries of a snapshot name a path this kit cannot bind.
sdlc_entries_unsupported() { # entry lines on stdin → count (awk reads to EOF: no SIGPIPE under pipefail)
  awk '$1 == "unsupported" { c++ } END { print c + 0 }'
}
# The same entry lines for a COMMIT's tree, so a delivered commit can be checked
# to CONTAIN the reviewed source instead of merely existing. Blob content is read
# through the repo's filters (--filters), so a checkout of that commit would put
# these bytes on disk. A C-quoted tree path is reported as `unsupported` like a
# worktree one; a blob that cannot be read or hashed is a non-zero exit, never a
# skipped line.
sdlc_tree_entries() { # <commit> → entry lines (sorted); non-zero on a read/hash failure
  local rev="$1" raw out rc=0
  raw=$(git -c core.quotepath=off ls-tree -r --full-tree "$rev" 2>/dev/null) || {
    echo "FAIL: git ls-tree could not read the tree of $rev" >&2; return 1; }
  out=$(printf '%s\n' "$raw" | sdlc__tree_entries_unsorted "$rev") || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | LC_ALL=C sort
  return $rc
}
sdlc__tree_entries_unsorted() { # <commit>; ls-tree lines on stdin — helper of sdlc_tree_entries
  local rev="$1" meta path mode sha h rc=0
  while IFS='	' read -r meta path; do
    [ -n "$path" ] || continue
    case "$path" in
      (.sdlc/*) continue;;
      (\"*) printf 'unsupported - - %s\n' "$path"; continue;;
    esac
    mode=${meta%% *}; sha=${meta##* }
    case "$mode" in
      (160000) printf 'submodule - - %s\n' "$path"; continue;;
    esac
    # pipefail inside: a blob that cannot be read must not hash as empty content
    if h=$( set -o pipefail; { git cat-file --filters "$rev:$path" 2>/dev/null || git cat-file blob "$sha" 2>/dev/null; } | sdlc_sha256_stdin ) && [ -n "$h" ]; then
      case "$mode" in
        (100755) printf 'f x %s %s\n' "$h" "$path";;
        (120000) printf 'l - %s %s\n' "$h" "$path";;
        (*)      printf 'f - %s %s\n' "$h" "$path";;
      esac
    else echo "FAIL: cannot hash $rev:$path" >&2; rc=1; fi
  done
  return $rc
}
sdlc_entries_digest() { sdlc_sha256_stdin; }           # entry lines on stdin
sdlc_source_digest() { # → digest of the current snapshot; non-zero when it could not be taken
  local s
  s=$(sdlc_source_snapshot) || return 1
  printf '%s\n' "$s" | sdlc_sha256_stdin
}

# What the ship approval's source binding is worth RIGHT NOW. One answer, shared
# by approve.sh, check-gate.sh, status.sh, and close.sh so they never disagree.
# Prints "<state> <recorded-digest> <current-digest>":
#   ok        — the source on disk is the source the review saw
#   drift     — it is not (added, removed, edited, chmod'ed, retyped)
#   legacy    — record written by an older kit: it bound the uncommitted diff
#               only (and nothing at all when the work was already committed)
#   nosnapshot— the entry list this record was written with is gone
#   invalid   — the source (now, or in the recorded snapshot) has a path name
#               this kit cannot bind (git C-quotes it); nothing can be proven
#   error     — the current snapshot could not be taken (enumeration or hashing
#               failed), so there is no current identity to compare
#   unbound   — no git repository, so no source identity exists to bind
#   norecord  — there is no ship approval
# Every caller must treat any state but `ok` (and `unbound`) as closed, and an
# EMPTY or unknown state as closed too: this function never fails open by
# printing less than three words.
sdlc_source_state() { # <ship approval record>
  local rec="$1" scope want now snap cur
  [ -f "$rec" ] || { echo "norecord - -"; return 0; }
  scope=$(sdlc_field "$rec" code_scope || true)
  want=$(sdlc_field "$rec" code_digest || true)
  if [ -z "$scope" ] || [ -z "$want" ]; then echo "legacy ${want:--} -"; return 0; fi
  if [ "$scope" = none ]; then echo "unbound none none"; return 0; fi
  snap="${rec%.approval}.source"
  [ -f "$snap" ] || { echo "nosnapshot $want -"; return 0; }
  if [ "$(sdlc_entries_unsupported < "$snap")" != 0 ]; then echo "invalid $want -"; return 0; fi
  cur=$(sdlc_source_snapshot 2>/dev/null) || { echo "error $want -"; return 0; }
  if [ "$(printf '%s\n' "$cur" | sdlc_entries_unsupported)" != 0 ]; then echo "invalid $want -"; return 0; fi
  now=$(printf '%s\n' "$cur" | sdlc_entries_digest) || { echo "error $want -"; return 0; }
  [ -n "$now" ] || { echo "error $want -"; return 0; }
  if [ "$want" = "$now" ]; then echo "ok $want $now"; else echo "drift $want $now"; fi
}
# The unsupported names themselves, for the message that refuses them.
sdlc_source_unsupported_list() { # entry lines on stdin → "    <quoted name>" lines
  awk '$1 == "unsupported" { sub(/^[^ ]* [^ ]* [^ ]* /, ""); print "    " $0 }'
}
# Human-readable drift: what changed between two entry files.
sdlc_source_drift_list() { # <recorded entries> <current entries>
  awk '
    function k(s) { sub(/^[^ ]* [^ ]* [^ ]* /, "", s); return s }
    function v(s) { split(s, a, " "); return a[1] " " a[2] " " a[3] }
    NR == FNR { o[k($0)] = v($0); next }
    { key = k($0); seen[key] = 1
      if (!(key in o)) print "    + " key "   (added since the review)"
      else if (o[key] != v($0)) print "    ~ " key "   (changed since the review)" }
    END { for (key in o) if (!(key in seen)) print "    - " key "   (removed since the review)" }
  ' "$1" "$2" | LC_ALL=C sort
}

# --- delivery record ---------------------------------------------------------
sdlc_delivery_field() { # <delivery.md> <field>
  awk -v k="- $2:" 'index($0, k) == 1 { sub(/^[^:]*: */, ""); sub(/[ \t\r]*$/, ""); print; exit }' "$1"
}
# The ONE verdict on a delivery record, used by close.sh (which blocks on it) and
# status.sh (which reports it), so a feature can never look deliverable in status
# and be refused at close for a reason status did not show.
# Prints "<token> <short message>"; token `ok` (and `unbound`) mean deliverable.
sdlc_delivery_issue() { # <delivery.md> <source-state> <recorded-digest> <current-digest>
  local del="$1" st="$2" want="$3" now="$4" t s by ev conf pair name val tree
  [ -f "$del" ] || { echo "missing no delivery.md — 'shipped' needs a delivery record"; return 0; }
  t=$(sdlc_delivery_field "$del" Target | awk '{print tolower($1)}')
  s=$(sdlc_delivery_field "$del" Source)
  by=$(sdlc_delivery_field "$del" Verified-by)
  ev=$(sdlc_delivery_field "$del" Evidence)
  conf=$(sdlc_delivery_field "$del" Confirmed | awk '{print tolower($1)}')
  case "$t" in (local|pr|deploy) ;; (*)
    echo "target Target must be local, pr, or deploy (found: '${t:-empty}')"; return 0;; esac
  for pair in "Verified-by:$by" "Evidence:$ev" "Source:$s"; do
    name=${pair%%:*}; val=${pair#*:}
    case "$val" in (""|"<"*)
      echo "placeholder $name is empty or still the template placeholder"; return 0;; esac
  done
  if [ "$conf" != yes ]; then
    echo "unconfirmed Confirmed: '${conf:-empty}' — an unconfirmed delivery is not 'shipped'"; return 0
  fi
  case "$st" in
    (ok) ;;
    (unbound)
      case "$s" in (worktree:*)
        if [ "$t" = local ]; then
          echo "unbound no git repository here, so the delivered source is unbound"; return 0
        fi;;
      esac;;
    (*) echo "source the ship source binding is '$st' — the delivered source cannot be confirmed"; return 0;;
  esac
  case "$s" in
    (worktree:*)
      if [ "$t" != local ]; then
        echo "worktree-remote a '$t' delivery cannot come from an uncommitted worktree"; return 0
      fi
      if [ "${s#worktree:}" != "$now" ]; then
        echo "source-mismatch Source does not match the current source identity"; return 0
      fi;;
    (*)
      if ! git rev-parse --git-dir >/dev/null 2>&1 || ! git cat-file -e "${s}^{commit}" 2>/dev/null; then
        echo "source-not-commit Source '$s' is not a commit in this repository"; return 0
      fi
      # the tree is read explicitly: a blob that cannot be hashed or a path git
      # quotes is a refusal with its own reason, never a shorter list to compare
      tree=$(sdlc_tree_entries "$s" 2>/dev/null) || {
        echo "source-error the tree of Source commit '$s' could not be read or hashed"; return 0; }
      if [ "$(printf '%s\n' "$tree" | sdlc_entries_unsupported)" != 0 ]; then
        echo "source-unsupported Source commit '$s' contains a path name this kit cannot bind (git quotes it)"; return 0
      fi
      if [ "$(printf '%s\n' "$tree" | sdlc_entries_digest)" != "$want" ]; then
        echo "source-content Source commit '$s' does not CONTAIN the reviewed source"; return 0
      fi;;
  esac
  echo "ok delivery confirmed ($t)"
}

# --- record reading ----------------------------------------------------------
sdlc_field() { # <record> <field>
  [ -f "$1" ] || return 1
  awk -v k="$2: " 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1"
}
