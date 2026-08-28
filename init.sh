#!/usr/bin/env bash
# init.sh [target-dir] — seed .sdlc/ into a project (greenfield or brownfield).
# Artifacts live in the TARGET repo so they version with the code.
set -euo pipefail
kit="$(cd "$(dirname "$0")" && pwd)"
target="${1:-.}"
cd "$target"

mkdir -p .sdlc/{work,approvals,memory/lessons}

# bulk evidence (screenshots, probe logs) is read+quoted+deleted, never committed
grep -qxF '.sdlc/work/*/scratch/' .gitignore 2>/dev/null || \
  echo '.sdlc/work/*/scratch/' >> .gitignore

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

[ -f .sdlc/config.md ] || cat > .sdlc/config.md <<EOF
# SDLC config
kit: $kit   # re-point this if the kit is moved or cloned elsewhere
# Real commands agents must use for proof (fill these in — brownfield: copy from CI/Makefile).
# AGENTS: if a command below is empty when you need it, STOP and ask the human to fill it in.
build:
test:
lint:
run:
EOF

echo "Seeded .sdlc/ in $(pwd)"
echo "Next: 1) fill .sdlc/config.md verification commands"
echo "      2) point your harness at $kit/AGENTS.md (see README)"
echo "      3) start a feature: agent reads $kit/skills/1-intent/SKILL.md"
