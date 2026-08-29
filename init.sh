#!/usr/bin/env bash
# init.sh [target-dir] — seed .sdlc/ into a project (greenfield or brownfield).
# Artifacts live in the TARGET repo so they version with the code.
set -euo pipefail
kit="$(cd "$(dirname "$0")" && pwd)"
target="${1:-.}"
cd "$target"

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

# bulk evidence (screenshots, probe logs) is read+quoted, kept until ship
# cleanup, never committed
ensure_line .gitignore '.sdlc/work/*/scratch/'

[ -f .sdlc/memory/INDEX.md ] || cat > .sdlc/memory/INDEX.md <<'EOF'
# Lessons index — one line per lesson: [tags] summary → lessons/<file>
# Agents: read THIS file only (≤50 lines); open a lesson file only when its tags match your task.
# When full, merge/prune oldest entries; promote repeat offenders into the stage skill itself.
EOF

[ -f .sdlc/memory/DOMAIN.md ] || cat > .sdlc/memory/DOMAIN.md <<'EOF'
# Domain knowledge — how THIS system works (≤100 lines; over → split by
# subdomain into memory/domain/<area>.md and keep one pointer line here)
# Continuously updated: researchers write back verified facts; ship retro
# harvests new entries. Facts carry [verified: how] like intent claims.

## Terms (ubiquitous language)
<!-- - term — meaning in this project -->

## Facts
<!-- - fact — [verified: file:line / command / capture] -->

## Constraints (load-bearing)
<!-- - constraint the code depends on — [verified: how] -->
EOF

# Record which kit version seeded this project; status.sh warns when the kit
# has since moved on, so a mid-feature rule change is visible, not silent.
# A vendored copy sits inside another repo, where git describe would report the
# host repo's tags — only trust git when the kit dir is its own toplevel.
kit_ver=""
if [ "$(git -C "$kit" rev-parse --show-toplevel 2>/dev/null)" = "$kit" ]; then
  kit_ver=$(git -C "$kit" describe --tags --always 2>/dev/null || true)
fi
[ -n "$kit_ver" ] || kit_ver=$(cat "$kit/VERSION" 2>/dev/null || echo unknown)

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
EOF

# projects seeded before lazymode existed keep their config; append the block
# so the "default 1 is already set" claim below is true on re-runs too
if ! grep -q '^lazymode:' .sdlc/config.md; then
  if [ -s .sdlc/config.md ] && [ -n "$(tail -c 1 .sdlc/config.md)" ]; then echo >> .sdlc/config.md; fi
  printf '%s\n' "$lazy_block" >> .sdlc/config.md
fi

echo "Seeded .sdlc/ in $(pwd)"
echo "Next: 1) fill .sdlc/config.md verification commands"
echo "      2) AGENT: ask the human which lazymode level to use (0-4; default 1 is already set in .sdlc/config.md)"
echo "      3) point your harness at $kit/AGENTS.md (see README)"
echo "      4) start a feature: agent reads $kit/skills/1-intent/SKILL.md"
