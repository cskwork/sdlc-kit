#!/usr/bin/env bash
# init.sh [target-dir] — seed .sdlc/ into a project (greenfield or brownfield).
# Artifacts live in the TARGET repo so they version with the code.
set -euo pipefail
kit="$(cd "$(dirname "$0")" && pwd)"
target="${1:-.}"
cd "$target"

mkdir -p .sdlc/{work,approvals,memory/lessons}

[ -f .sdlc/memory/INDEX.md ] || cat > .sdlc/memory/INDEX.md <<'EOF'
# Lessons index — one line per lesson: [tags] summary → lessons/<file>
# Agents: read THIS file only (≤50 lines); open a lesson file only when its tags match your task.
# When full, merge/prune oldest entries; promote repeat offenders into the stage skill itself.
EOF

[ -f .sdlc/config.md ] || cat > .sdlc/config.md <<EOF
# SDLC config
kit: $kit
# Real commands agents must use for proof (fill these in — brownfield: copy from CI/Makefile):
build:
test:
lint:
run:
EOF

echo "Seeded .sdlc/ in $(pwd)"
echo "Next: 1) fill .sdlc/config.md verification commands"
echo "      2) point your harness at $kit/AGENTS.md (see README)"
echo "      3) start a feature: agent reads $kit/skills/1-intent/SKILL.md"
