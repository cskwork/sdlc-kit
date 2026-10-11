#!/usr/bin/env bash
# Real product lifecycle integration: stdlib CLI, disposable git repo and local remote.
# Approvals below simulate explicit human decisions ONLY inside this test fixture.
# No GitHub credentials, real remote, background service or third-party package is used.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$kit/tests/fixtures/factory"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-factory.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1
if python3 -c 'import sys; assert sys.version_info >= (3, 9)' >/dev/null 2>&1; then py=python3
elif python -c 'import sys; assert sys.version_info >= (3, 9)' >/dev/null 2>&1; then py=python
else echo 'FAIL: factory E2E requires Python 3.9+' >&2; exit 2; fi
V="$kit/tools/verify.sh"; A="$kit/gates/approve.sh"; C="$kit/gates/close.sh"
H="$kit/tools/handoff.sh"; G="$kit/gates/check-gate.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@"; }
refuse() {
  local expected="$1" out rc=0; shift
  out=$("$@" 2>&1) || rc=$?
  printf '%s\n' "$out"
  [ "$rc" != 0 ] || fail "accepted a deliberately invalid state: $*"
  case "$out" in *"$expected"*) ;; *) fail "refusal did not name '$expected': $out";; esac
}
commit() { git add -A; git commit -qm "$1"; }
write_intent() {
  mkdir -p ".sdlc/work/$slug"
  cat > ".sdlc/work/$slug/intent.md" <<EOF
# Intent: $slug
- Goal: $goal
- Type: brownfield
- Track: compact
- Requested by: simulated factory test human
- Scope authorization: Implement this fixture change and push a review branch to the disposable local bare remote; no merge or deploy.
## Problem
$problem
## Evidence
- $observed [verified: executable reproduction in this lifecycle]
## Success criteria
- [ ] O1: $criterion
## Compact route
- Files: taskdesk.py, tests/$testfile
- Proof: $py tests/$testfile; CLI happy, boundary, negative and regression assertions.
- Reach: alternate module entry, persisted legacy state, surrounding input context.
- Risk: confined to the disposable taskdesk product; preserve add/list/completion compatibility.
- Baseline: $py tests/test_existing.py
- Delivery target: pr
## Out of scope / must not change
- No shared branch, real GitHub publication, merge, deployment, or dependencies.
## Material questions
none
EOF
  echo "SIMULATED HUMAN: approve the compact intent for $slug."
  run "$A" intent ".sdlc/work/$slug/intent.md" --delegated
  run "$G" intent ".sdlc/work/$slug/intent.md"
}
write_feature_recipe() {
  local mode flag
  : > ".sdlc/work/$slug/verify.md"
  for mode in happy boundary negative entry state context; do
    flag=""; [ "$mode" != happy ] || flag=' | must-fail-on-base'
    printf 'check: O1.%s | e2e | %s tests/%s %s%s\n' "$mode" "$py" "$testfile" "$mode" "$flag" >> ".sdlc/work/$slug/verify.md"
  done
}
prove() {
  run "$V" coverage "$slug"
  run "$V" baseline "$slug"
  base_log=".sdlc/work/$slug/scratch/verify-base/O1.happy.log"
  cat "$base_log"
  grep -q "$base_reason" "$base_log" || fail "base failed for the wrong reason"
  grep -q ' | must-fail | ' ".sdlc/work/$slug/verify-baseline.md" || fail 'baseline did not record must-fail'
  run "$V" run "$slug"
  run "$V" check "$slug"
  receipt=".sdlc/work/$slug/verify-receipt.md"
  grep -q '^profile: strict$' "$receipt" || fail 'receipt is not strict'
  grep -q '^runtime_evidence: yes$' "$receipt" || fail 'real CLI behavior did not run'
  grep -q '^result: pass$' "$receipt" || fail 'receipt did not pass'
  # Evidence quotes actual deciding output and declares the scripted review limit.
  {
    printf '# Evidence: %s\n\n' "$slug"
    echo 'no independent verification available: deterministic lifecycle fixture; no fresh-context reviewer is simulated.'
    echo 'The test human explicitly accepts this fixture-only review limitation.'
    printf '\n## Before-fail proof\n```text\n'; cat "$base_log"; printf '```\n'
    printf '\n## After-pass proof\n```text\n'; cat "$receipt"; printf '```\n'
    printf '\n## Causal mechanism\n%s\n' "$cause"
  } > ".sdlc/work/$slug/evidence.md"
  echo "SIMULATED HUMAN: approve ship for $slug after inspecting actual baseline and CLI results."
  run "$A" ship ".sdlc/work/$slug/evidence.md" --delegated
  run "$G" ship ".sdlc/work/$slug/evidence.md"
}
stale_guards() {
  cp taskdesk.py "$tmp/reviewed.py"
  printf '\n# post-verification drift\n' >> taskdesk.py
  refuse 'source changed' "$V" check "$slug"
  refuse 'GATE CLOSED' "$G" ship ".sdlc/work/$slug/evidence.md"
  refuse 'ship gate is not open' "$H" push "$slug" --authorized 'simulated human: push this disposable local review branch' --branch "$branch"
  [ -z "$(git ls-remote origin "refs/heads/$branch")" ] || fail 'stale source reached the remote'
  cp "$tmp/reviewed.py" taskdesk.py
  local log=".sdlc/work/$slug/scratch/verify/O1.happy.log"
  cp "$log" "$tmp/reviewed.log"
  printf 'edited after verification\n' >> "$log"
  refuse 'changed after it was recorded' "$V" check "$slug"
  refuse 'verification invalid' "$A" ship ".sdlc/work/$slug/evidence.md" --delegated
  cp "$tmp/reviewed.log" "$log"
  run "$V" check "$slug"
  run "$G" ship ".sdlc/work/$slug/evidence.md"
}
deliver() {
  commit "$slug"
  local sha tree remote_sha remote_tree handoff
  sha=$(git rev-parse HEAD); tree=$(git rev-parse 'HEAD^{tree}')
  # A recorded scope never substitutes for the explicit push authorization flag.
  refuse 'pushing leaves this repository' "$H" push "$slug" --branch "$branch"
  handoff=$("$H" push "$slug" --authorized 'simulated human: push this disposable local review branch' --branch "$branch")
  printf '%s\n' "$handoff"
  remote_sha=$(git ls-remote origin "refs/heads/$branch" | awk 'NR == 1 {print $1}')
  remote_tree=$(git --git-dir="$tmp/remote.git" rev-parse "refs/heads/$branch^{tree}")
  [ "$sha" = "$remote_sha" ] || fail 'remote commit differs from delivered HEAD'
  [ "$tree" = "$remote_tree" ] || fail 'remote tree differs from reviewed source commit'
  cat > ".sdlc/work/$slug/delivery.md" <<EOF
# Delivery: $slug
- Target: pr
- Source: $sha
- Remote: origin
- Branch: $branch
- Handoff: review-ready
- Verified-by: git ls-remote origin refs/heads/$branch; local bare remote commit/tree comparison; tools/handoff.sh check $slug
- Evidence: HANDOFF review-ready: origin/$branch @ $sha contains the reviewed source.
- Confirmed: yes
- Verified-at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
## Notes
This is a local review-branch simulation; no GitHub PR, merge or deployment occurred.
Remote commit $remote_sha; remote tree $remote_tree matches local tree $tree.
EOF
  run "$H" check "$slug"
  run "$C" "$slug" shipped 'Simulated human: local review branch delivered and commit/tree verified' --delegated
  grep -q '^verify_state: ok$' ".sdlc/archive/$slug/CLOSED" || fail 'close did not retain verified state'
  [ ! -d ".sdlc/work/$slug" ] || fail 'closed feature was not archived'
  echo "PASS lifecycle $slug: before-fail, after-pass, stale refusals, authorized local remote $sha tree $tree, shipped archive"
}
mkdir "$tmp/project"
git init -q --bare "$tmp/remote.git"
cd "$tmp/project"
git init -q .
git config user.email factory@sdlc-kit.invalid
git config user.name 'sdlc-kit factory fixture'
git config core.autocrlf false
git remote add origin "$tmp/remote.git"
run "$kit/init.sh" .
printf '__pycache__/\n' >> .gitignore
mkdir tests
cp "$fixture/taskdesk.py" taskdesk.py
cp "$fixture/test_existing.py" tests/test_existing.py
run "$py" tests/test_existing.py
commit 'baseline persisted taskdesk CLI'
cat > .sdlc/verify.md <<EOF
profile: strict
environment: disposable local stdlib CLI with isolated JSON data per scenario
check_timeout: 30
test_paths: tests/*
check: existing | unit | $py tests/test_existing.py
EOF

slug=complete-task; branch=factory/complete-task; testfile=test_feature.py
goal='Users can complete a persisted task by its ID.'
problem='The add/list CLI cannot complete a task.'
observed='The baseline CLI only has add and list commands.'
criterion='complete persists only the selected task; invalid IDs preserve data; repeated completion is safe.'
cause='Before: argparse has no complete command. After: complete validates an integer ID, selects that record, persists done=true, and rejects missing IDs without writes.'
base_reason='invalid choice'
write_intent
cp "$fixture/test_feature.py" tests/test_feature.py
write_feature_recipe
"$py" - <<'PY'
from pathlib import Path
p = Path('taskdesk.py')
s = p.read_text().replace('    # COMPLETE_PARSER', '    complete = commands.add_parser("complete")\n    complete.add_argument("id", type=int)')
s = s.replace('    # COMPLETE_HANDLER', '''    elif args.command == "complete":
        task = next((task for task in tasks if task["id"] == args.id), None)
        if task is None:
            parser.error("unknown task ID")
        task["done"] = True
        args.db.write_text(json.dumps(tasks))
        print(json.dumps(task))''')
p.write_text(s)
PY
prove
stale_guards
deliver

slug=sparse-task-id; branch=factory/sparse-task-id; testfile=test_regression.py
goal='New tasks keep unique IDs after an older task was removed.'
problem='A persisted legacy file with IDs 1 and 3 makes add allocate ID 3 again.'
observed='The reproduction expects ID 4 but the baseline allocates 3.'
criterion='add allocates above the maximum persisted ID and preserves legacy rows; add/list/complete still work.'
cause='Before: next_id = len(tasks) + 1; for real fixture rows [1,3], 2+1=3 collides. After: max(existing IDs, default=0)+1; max(1,3)+1=4. Counterexample: empty state still produces 1, and rejected blank titles never allocate or write.'
base_reason='expected next ID 4, got 3'
write_intent
cp "$fixture/test_regression.py" tests/test_regression.py
write_feature_recipe
# Retain the preceding feature in the ongoing suite as an adjacent-flow guard.
printf 'check: completion | e2e | %s tests/test_feature.py happy\n' "$py" >> .sdlc/verify.md
"$py" - <<'PY'
from pathlib import Path
p = Path('taskdesk.py')
s = p.read_text().replace('len(tasks) + 1  # FIX_ID_ALLOCATION', 'max((task["id"] for task in tasks), default=0) + 1')
p.write_text(s)
PY
prove
stale_guards
deliver
echo 'PASS factory E2E: actual feature and regression fix both delivered to isolated local review branches; no external publication'
