#!/usr/bin/env bash
# init.sh [target-dir] [--area <folder>] — seed .sdlc/ into a project
# (greenfield or brownfield).
#
# Records are the project's knowledge, not its source: the whole of .sdlc/ is
# gitignored (one anchored `/.sdlc` rule), so an application clone no longer
# carries them. They stay readable where they are written — in the project's
# working copy by default, or, with --area, in a folder the user chooses, one
# store per checkout, navigable through tools/kb.sh.
#
# Re-running is safe: it adds the missing ignore rule, removes the exact ignore
# lines older kit versions issued, re-checks the area binding, and refreshes the
# contents page. It never touches the git index and never moves user records.
set -euo pipefail
kit="$(cd "$(dirname "$0")" && pwd)"
. "$kit/gates/_common.sh"
orig_pwd=$(pwd)

usage() {
  cat >&2 <<'EOF'
usage: init.sh [target-dir] [--area <folder>]
  target-dir   the project (or monorepo shipping unit) that owns .sdlc  [default: .]
  --area       keep this checkout's records in <folder>/<unit>-<checkout-id>
               and link .sdlc to it. The folder is yours: back it up yourself.
EOF
  exit 2
}
target=""; area=""
while [ $# -gt 0 ]; do
  case "$1" in
    --area) [ $# -ge 2 ] || usage; area="$2"; shift;;
    --area=*) area="${1#--area=}";;
    -h|--help) usage;;
    -*) echo "FAIL: unknown option: $1" >&2; usage;;
    *) [ -z "$target" ] || { echo "FAIL: more than one target directory given" >&2; usage; }
       target="$1";;
  esac
  shift
done
[ -n "$target" ] || target="."
cd "$target" || { echo "FAIL: no such directory: $target" >&2; exit 2; }
project_phys=$(pwd -P)

# Records already here must belong to THIS checkout before anything is written —
# an ordinary re-run included, with or without --area. A copied checkout keeps
# the `.sdlc` link of the original, so without this check `init.sh` would seed
# directories into, and refresh the contents page of, someone else's store
# (gates/_common.sh sdlc_store_owner_ok; it refuses, moves nothing, adopts nothing).
sdlc_store_owner_ok || exit 1

# Which kit version is seeding this project: recorded in .sdlc/config.md below,
# and in an external store's PROJECT record. A vendored copy sits inside another
# repo, where git describe would report the HOST repo's tags — only trust git
# when the kit dir is its own toplevel.
kit_ver=""
if [ "$(git -C "$kit" rev-parse --show-toplevel 2>/dev/null)" = "$kit" ]; then
  kit_ver=$(git -C "$kit" describe --tags --always 2>/dev/null || true)
fi
[ -n "$kit_ver" ] || kit_ver=$(cat "$kit/VERSION" 2>/dev/null || echo unknown)

# --- external knowledge area (optional) --------------------------------------
# Binding rules, all failing loudly and writing nothing on refusal:
#   - the area may not contain, or live inside, the project: a source snapshot
#     must never be able to see raw records;
#   - the store is <area>/<unit>-<checkout-id>, so two checkouts or worktrees of
#     a same-named project never share approvals or verification state;
#   - <store>/PROJECT records the owner; a store owned by another checkout is
#     refused, never adopted;
#   - a real .sdlc directory is NEVER relocated automatically, and a link that
#     points somewhere else is never redirected;
#   - if the link cannot be created as a link (Git Bash MSYS copy mode), init
#     fails — a copy pretending to be a store would fork the records.
if [ -n "$area" ]; then
  case "$area" in (/*) area_abs="$area";; (*) area_abs="$orig_pwd/$area";; esac
  # Containment is checked BEFORE anything is created: a refused area must not
  # leave a folder inside the reviewed source. A path that does not exist yet is
  # resolved through its deepest existing ancestor (physically, pwd -P), and the
  # non-existent tail is appended — the same comparison, one step earlier.
  area_head="$area_abs"; area_tail=""
  while [ ! -d "$area_head" ]; do
    area_up=$(dirname "$area_head")
    area_tail="$(basename "$area_head")${area_tail:+/$area_tail}"
    [ "$area_up" = "$area_head" ] && break
    area_head="$area_up"
  done
  [ -d "$area_head" ] || { echo "FAIL: cannot resolve the knowledge area: $area_abs" >&2; exit 1; }
  area_pre=$(cd "$area_head" 2>/dev/null && pwd -P) || { echo "FAIL: cannot resolve the knowledge area: $area_abs" >&2; exit 1; }
  area_pre="$area_pre${area_tail:+/$area_tail}"
  area_refuse() { # <resolved area path> — the two containment refusals, one text
    case "$1" in
      ("$project_phys"|"$project_phys"/*)
        echo "FAIL: the knowledge area is inside the project ($1)." >&2
        echo "  Records kept there would end up inside the reviewed source. Choose a folder outside $project_phys." >&2
        return 1;;
    esac
    case "$project_phys" in
      ("$1"/*)
        echo "FAIL: the project is inside the knowledge area ($1)." >&2
        echo "  That nests the store in the tree it describes. Choose a separate folder." >&2
        return 1;;
    esac
    return 0
  }
  area_refuse "$area_pre" || exit 1
  mkdir -p "$area_abs" 2>/dev/null || { echo "FAIL: cannot create the knowledge area: $area_abs" >&2; exit 1; }
  area_phys=$(cd "$area_abs" 2>/dev/null && pwd -P) || { echo "FAIL: cannot resolve the knowledge area: $area_abs" >&2; exit 1; }
  # Re-checked on the real physical path: a symlinked ancestor can land the area
  # somewhere the lexical pre-check could not see. Directories this run created
  # are then removed again with rmdir, which refuses a non-empty one — nothing a
  # user put there is ever deleted.
  if ! area_refuse "$area_phys"; then
    area_undo="$area_abs"
    while [ "$area_undo" != "$area_head" ] && [ "$area_undo" != "/" ]; do
      rmdir "$area_undo" 2>/dev/null || break
      area_undo=$(dirname "$area_undo")
    done
    exit 1
  fi
  [ -w "$area_phys" ] || { echo "FAIL: the knowledge area is not writable: $area_phys" >&2; exit 1; }
  # A readable store name: only the characters that break a path or a shell are
  # replaced, so a Korean, Japanese or accented checkout name stays legible in
  # the area listing and in tools/kb.sh output. Byte-wise on purpose — every
  # byte of a UTF-8 name is >= 0x80 and can never collide with the ASCII set below.
  unit=$(basename "$project_phys")
  unit=$(printf '%s' "$unit" | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C tr '\\/:*?"<>|	 ' '-')
  case "$unit" in (''|-*|.|..) unit="project";; esac
  checkout_id=$(printf '%s' "$project_phys" | sdlc_sha256_stdin | cut -c1-8)
  store="$area_phys/$unit-$checkout_id"
  owner="$store/PROJECT"
  if [ -e "$store" ]; then
    [ -d "$store" ] || { echo "FAIL: $store exists and is not a directory." >&2; exit 1; }
    if [ -f "$owner" ]; then
      recorded=$(awk '/^project: /{sub(/^project: /,""); sub(/[ \t\r]*$/,""); print; exit}' "$owner")
      if [ "$recorded" != "$project_phys" ]; then
        echo "FAIL: $store belongs to another checkout." >&2
        echo "  recorded owner: ${recorded:-<none>}" >&2
        echo "  this checkout:  $project_phys" >&2
        echo "  Approvals and verification state are per checkout and are never shared." >&2
        exit 1
      fi
    elif [ -n "$(ls -A "$store" 2>/dev/null)" ]; then
      echo "FAIL: $store already has content but no PROJECT record — it is not an sdlc-kit store." >&2
      echo "  Move it aside, or pick another area." >&2
      exit 1
    fi
  fi
  # The state of .sdlc decides everything below, so it is read BEFORE the store
  # directory is created: a refusal must not leave an empty store behind, and the
  # advice it prints must stay true for the directory the user then looks at.
  link_needed=""
  if [ -L .sdlc ]; then
    linked=$(cd .sdlc 2>/dev/null && pwd -P) || {
      echo "FAIL: .sdlc is a broken symlink in $project_phys — fix or remove it, then re-run." >&2; exit 1; }
    if [ "$linked" != "$store" ]; then
      echo "FAIL: .sdlc already points at $linked, not at $store." >&2
      echo "  Nothing was changed. Remove the link yourself if you mean to re-point it." >&2
      echo "  Renamed or moved this checkout? The old store is still readable, and is never" >&2
      echo "  re-bound automatically: tools/kb.sh list --store \"$linked\"" >&2
      exit 1
    fi
  elif [ -e .sdlc ]; then
    # No migration: this kit never moves records, and it does not print a command
    # that would move them into a store it has just created (that store would then
    # hold a nested .sdlc and be refused as unowned on the next run).
    echo "FAIL: $project_phys/.sdlc is a real directory; --area never relocates records." >&2
    echo "  Nothing was changed, and nothing here needs to move: those records keep working" >&2
    echo "  exactly as they are, and are read with" >&2
    echo "    \"$kit/tools/kb.sh\" list --store \"$project_phys/.sdlc\"" >&2
    echo "  If you want this checkout to use the area instead, move the existing records aside" >&2
    echo "  yourself first (they are yours — nothing is deleted or copied for you):" >&2
    echo "    mv \"$project_phys/.sdlc\" \"$project_phys/.sdlc-old\"" >&2
    echo "    \"$kit/init.sh\" \"$project_phys\" --area \"$area_phys\"   # creates an EMPTY store" >&2
    echo "  The old records stay readable where you put them: tools/kb.sh --store \"<that path>\"." >&2
    exit 1
  else
    link_needed=1
  fi
  # The `-w` test above cannot see a Windows deny ACL (MSYS maps NTFS rights
  # onto POSIX bits and can report a denied directory as writable), so the
  # first real write is also a refusal, before .sdlc is linked: a store that
  # cannot be created never becomes a fallback store inside the project.
  mkdir -p "$store" || {
    echo "FAIL: cannot create the store: $store" >&2
    echo "  This usually means the knowledge area is not writable by this account: $area_phys" >&2
    echo "  Nothing was changed, and no records directory was created in $project_phys." >&2
    exit 1; }
  if [ -n "$link_needed" ]; then
    ln -s "$store" .sdlc 2>/dev/null || { echo "FAIL: cannot link .sdlc -> $store" >&2; exit 1; }
    if [ ! -L .sdlc ]; then
      # MSYS copy mode: what was just created is a copy of an empty store this run
      # made. Remove that copy if it is a plain file; a directory is left for the
      # human to remove, because this script deletes nothing it did not create alone.
      rm -f .sdlc 2>/dev/null || true
      echo "FAIL: .sdlc was created as a copy, not a symlink (Git Bash needs MSYS=winsymlinks:nativestrict)." >&2
      if [ -e .sdlc ]; then
        echo "  Remove $project_phys/.sdlc yourself, then re-run with symlink support enabled." >&2
      else
        echo "  The partial copy was removed. Re-run with symlink support enabled." >&2
      fi
      exit 1
    fi
  fi
  if [ ! -f "$owner" ]; then
    {
      echo "project: $project_phys"
      echo "unit: $unit"
      echo "checkout_id: $checkout_id"
      echo "created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "kit_version: $kit_ver"
    } > "$owner"
  fi
  echo "Knowledge area: $store (linked as $project_phys/.sdlc)"
fi

mkdir -p .sdlc/work .sdlc/approvals .sdlc/memory/lessons

# Append a line to a project file unless it is already there, verbatim.
# tr -d '\r': a CRLF file would never match, re-appending the line each run.
# The match is a quoted case pattern, not a grep pipeline: under pipefail a
# `grep -q` that exits early SIGPIPEs its producer and fakes a miss.
ensure_line() { # <file> <line>
  local f="$1" line="$2" have=""
  if [ -f "$f" ]; then have=$(tr -d '\r' < "$f"); fi
  case "
$have
" in
    *"
$line
"*) return 0 ;;
  esac
  # a file with no trailing newline would swallow the entry into its last line
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then echo >> "$f"; fi
  echo "$line" >> "$f"
}

# ONE anchored rule covers the lot (AGENTS.md rule 7). `/.sdlc` is anchored to
# the project root, so it matches this project's records — a real directory or
# the symlink an external area installs — and never a `.sdlc` deeper in the
# tree (another shipping unit keeps its own rule, written by its own init run).
# Records are knowledge, not source: they stay where they are written and are
# read through tools/kb.sh, not through the application's git history.
ensure_line .gitignore '/.sdlc'

# Kit-owned ignores this kit no longer issues — the twenty narrower patterns
# earlier versions wrote are subsumed by `/.sdlc`. Removing the exact line is safe and
# reversible; the file stays on disk and the git index is NOT touched —
# untracking or adding is the human's call, as below.
# tr -d '\r' on the comparison only, exactly as ensure_line does it: a
# Windows-authored .gitignore stores every line with a trailing CR, so a
# byte-exact match would never fire and the obsolete rules would live forever.
# Only the matching lines go; every other line is written back as it was read,
# CR and all, so unrelated bytes and line endings are preserved. The file is
# rewritten only when something actually matched.
# Read and written with the shell itself, not awk: an awk built for Windows
# text mode translates CRLF on read and on write, so a user's line endings
# would depend on which awk is installed. `IFS= read -r` and `printf` move the
# bytes as they are on every platform this kit supports.
drop_line() { # <file> <exact-line>
  local f="$1" line="$2" tmpf l s n=0
  [ -f "$f" ] || return 0
  tmpf="$f.sdlc-tmp.$$"
  { while IFS= read -r l || [ -n "$l" ]; do
      s=${l%$'\r'}
      if [ "$s" = "$line" ]; then n=$((n + 1)); continue; fi
      printf '%s\n' "$l"
    done } < "$f" > "$tmpf" 2>/dev/null
  if [ "$n" -gt 0 ]; then
    mv "$tmpf" "$f" || { rm -f "$tmpf"; return 0; }
    echo "note: removed obsolete kit ignore '$line' from $f (subsumed by /.sdlc — AGENTS.md rule 7)"
  else
    rm -f "$tmpf"
  fi
}
for obsolete in '.sdlc/work/*/spec.md' '.sdlc/archive/*/spec.md' \
                '.sdlc/work/*/evidence.md' '.sdlc/archive/*/evidence.md' \
                '.sdlc/work/*/scratch/' '.sdlc/archive/*/scratch/' \
                '.sdlc/work/*/progress.md' '.sdlc/archive/*/progress.md' \
                '.sdlc/approvals/' '.sdlc/archive/*/approvals/' \
                '.sdlc/work/*/baseline.txt' '.sdlc/archive/*/baseline.txt' \
                '.sdlc/work/*/deviations.md' '.sdlc/archive/*/deviations.md' \
                '.sdlc/work/*/harvest.md' '.sdlc/archive/*/harvest.md' \
                '.sdlc/work/*/checkpoint.md' '.sdlc/archive/*/checkpoint.md' \
                '.sdlc/work/*/verify-receipt.md' '.sdlc/archive/*/verify-receipt.md'; do
  drop_line .gitignore "$obsolete"
done

[ -f .sdlc/memory/INDEX.md ] || cat > .sdlc/memory/INDEX.md <<'EOF'
# Lessons index — one line per lesson: [tags] summary → lessons/<file>
# Agents: read THIS file only (≤50 lines); open a lesson file only when its tags match your task.
# When full, merge/prune oldest entries; promote repeat offenders into the stage skill itself.
EOF

[ -f .sdlc/memory/POLICY.md ] || cat > .sdlc/memory/POLICY.md <<'EOF'
# Policy — human-declared hard rules for this repository (≤50 lines)
# WRITE PATH: only when the human states a rule in chat does the agent
# transcribe it here, with the date and the human's words. Agents never add,
# soften, or remove a rule on their own judgment.
# READ PATH: every stage start (AGENTS.md rule 4); the adversary treats a
# violation as a blocking finding.
#
# - <rule> — [human: YYYY-MM-DD "quoted words"]
EOF

[ -f .sdlc/memory/DOMAIN.md ] || cat > .sdlc/memory/DOMAIN.md <<'EOF'
# Domain knowledge — how THIS system works (≤100 lines; over → split by
# subdomain into memory/domain/<area>.md and keep one pointer line here)
# ONE writer: the close step. Mid-loop candidates stage in the feature's
# work/<slug>/harvest.md and merge here at close (AGENTS.md rule 4).
# Facts carry [verified: how — YYYY-MM-DD]. Recency wins: a merge candidate
# that contradicts an entry REPLACES it — the source changed; never keep both.

## Terms (ubiquitous language)
<!-- - term — meaning in this project -->

## Facts
<!-- - fact — [verified: file:line / command / capture] -->

## Constraints (load-bearing)
<!-- - constraint the code depends on — [verified: how] -->
EOF

# kit_ver was resolved at the top of this script (status.sh warns when the kit
# has since moved on, so a mid-feature rule change is visible, not silent).
# Under Git Bash the kit path is a POSIX one (/c/Users/…). An agent that shells
# out to PowerShell or cmd cannot use it, so record the native path too.
kit_lines="kit: $kit   # re-point this if the kit is moved or cloned elsewhere
kit_version: $kit_ver   # kit version this project was seeded with"
if command -v cygpath >/dev/null 2>&1 && kit_win=$(cygpath -w "$kit" 2>/dev/null) && [ -n "$kit_win" ]; then
  kit_lines="$kit_lines
kit_windows: $kit_win   # same kit, native path for PowerShell/cmd"
fi

lazy_block="# lazymode 0-4 — which gates stay HUMAN (policy: AGENTS.md rule 3).
# AGENTS: ask the human which level they want at init; 1 is the default.
#   0: intent, spec, plan trip-wires, ship (everything as designed)
#   1: intent, spec, ship    2: intent, ship    3: intent    4: none
lazymode: 1"

[ -f .sdlc/config.md ] || cat > .sdlc/config.md <<EOF
# SDLC config
$kit_lines
$lazy_block
# Real commands agents must use for proof (fill these in — brownfield: copy from CI/Makefile).
# AGENTS: if a command below is empty when you need it, STOP and ask the human to fill it in.
build:
test:
lint:
run:
# Optional preferred browser/QA tool for UI verification (CLI, MCP, or agent name).
# Empty is fine: the verifier falls back to any browser/QA tool its harness has.
qa:
# Optional: the project's own end-to-end command, scoped per run where possible
# (e.g. npx playwright test --grep <tag>). Empty or absent is fine — the verifier
# then finds the project's own e2e entry point, and records NOT VERIFIED when
# there is no runnable environment (roles/verifier.md). Never a new dependency.
e2e:
# Optional: the project's own agent or skill to dispatch for each kit role
# (AGENTS.md "Running beside…" rule 3) — e.g. a debugging skill as researcher,
# a QA agent as verifier. Empty = the best local fit, else a generic worker.
researcher:
verifier:
adversary:
EOF

# projects seeded before lazymode existed keep their config; append the block
# so the "default 1 is already set" claim below is true on re-runs too
if ! grep -q '^lazymode:' .sdlc/config.md; then
  if [ -s .sdlc/config.md ] && [ -n "$(tail -c 1 .sdlc/config.md)" ]; then echo >> .sdlc/config.md; fi
  printf '%s\n' "$lazy_block" >> .sdlc/config.md
fi

if [ -n "$area" ]; then
  ensure_line .sdlc/config.md "area_store: $store   # external knowledge area (init.sh --area)"
fi

echo "Seeded .sdlc/ in $(pwd)"

# The contents page is generated from what is on disk; it never writes inside
# work/ or archive/, so no approved artifact can change (tools/kb.sh).
bash "$kit/tools/kb.sh" index || echo "note: contents page not refreshed (see the reason above)"

# .gitignore never untracks: a project seeded by an older kit keeps committing
# the paths above. Report them and let the human run the removal — rewriting
# someone else's index is not this script's call.
# awk, not head: head exits early, and under pipefail that SIGPIPEs the
# producer and aborts the script (same trap ensure_line documents).
if git rev-parse --git-dir >/dev/null 2>&1; then
  tracked=$(git ls-files -c -i --exclude-standard -- .sdlc 2>/dev/null || true)
  if [ -n "$tracked" ]; then
    n=$(printf '%s\n' "$tracked" | wc -l | tr -d ' ')
    echo
    echo "note: $n tracked file(s) now match .gitignore:"
    printf '%s\n' "$tracked" | awk 'NR<=10 { print "        " $0 }'
    if [ "$n" -gt 10 ]; then echo "        … and $((n - 10)) more"; fi
    echo "      Untrack them (files stay on disk), then commit the removal:"
    echo "        git ls-files -ci --exclude-standard -- .sdlc | tr '\\n' '\\0' | xargs -0 git rm --cached --"
  fi
fi

echo "Next: 0) OPTIONAL (required for unattended runs): copy $kit/templates/verify.md to"
echo "         .sdlc/verify.md and map each requirement to the real command that proves it;"
echo "         tools/verify.sh then records a receipt bound to the source it ran against"
echo "      1) fill .sdlc/config.md verification commands"
echo "      2) AGENT: ask the human which lazymode level to use (0-4; default 1 is already set in .sdlc/config.md)"
echo "      3) point your harness at $kit/AGENTS.md (see README)"
echo "      4) start a feature: agent reads $kit/skills/1-intent/SKILL.md"
echo "         (search past features first: $kit/tools/kb.sh search \"<term>\")"
echo
echo "Records are gitignored: a clone of this project does NOT carry them."
echo "They live in $(cd .sdlc && pwd -P) — back that up yourself."
