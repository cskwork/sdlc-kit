#!/usr/bin/env bash
# selftest.sh — proves the gate mechanism works: approve→open, unapproved→closed.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; mkdir -p .sdlc/work/feat-a
git init -q .   # close.sh's .gitignore handling is git-repo-only

# mklink <target> <link> — a fixture that claims to be a symlink must BE one.
# Git Bash's default MSYS mode makes `ln -s` COPY instead of link, which would
# turn a security assertion into a false PASS; CI sets
# MSYS=winsymlinks:nativestrict. A link we cannot create is a setup failure.
mklink() {
  ln -s "$1" "$2" || {
    echo "FAIL: setup — cannot create symlink $2 -> $1 (Windows: MSYS=winsymlinks:nativestrict)"; exit 1; }
  [ -L "$2" ] || {
    echo "FAIL: setup — $2 is a copy, not a symlink (Windows: MSYS=winsymlinks:nativestrict)"; exit 1; }
}

a=.sdlc/work/feat-a/intent.md
echo "goal: test" > "$a"

# 1. gate closed before approval
if "$kit/gates/check-gate.sh" intent "$a" >/dev/null 2>&1; then
  echo "FAIL: gate open without approval"; exit 1; fi
echo "ok: gate closed before approval"

# 2. approve → gate open
"$kit/gates/approve.sh" intent "$a" >/dev/null
"$kit/gates/check-gate.sh" intent "$a" >/dev/null
echo "ok: gate open after approval"

# 3. edit after approval → gate CLOSES (the approval binds the artifact's content)
cp "$a" "$a.orig"
echo "later edit" >> "$a"
out=$("$kit/gates/check-gate.sh" intent "$a" 2>&1) && { echo "FAIL: gate stayed open after the approved artifact changed"; exit 1; }
case "$out" in (*"changed after it was approved"*) ;; (*) echo "FAIL: content-drift message missing: $out"; exit 1;; esac
cp "$a.orig" "$a"; rm -f "$a.orig"
"$kit/gates/check-gate.sh" intent "$a" >/dev/null || { echo "FAIL: gate not open again for the approved content"; exit 1; }
echo "ok: post-approval edit closes the gate; approved content reopens it"

# 4. stage name injection rejected
if "$kit/gates/approve.sh" "../../etc/pwn" "$a" >/dev/null 2>&1; then
  echo "FAIL: path-traversal stage name accepted"; exit 1; fi
echo "ok: invalid stage name rejected"

# 5. artifact outside a feature dir rejected
echo x > bare.md
if "$kit/gates/approve.sh" intent bare.md >/dev/null 2>&1; then
  echo "FAIL: bare-path artifact accepted (slug '.')"; exit 1; fi
echo "ok: bare-path artifact rejected"

# 6. approved artifact missing → closed WITH a message (never silent)
mv "$a" "$a.bak"
out=$("$kit/gates/check-gate.sh" intent "$a" 2>&1) && { echo "FAIL: gate open on missing artifact"; exit 1; }
case "$out" in (*"GATE CLOSED"*) echo "ok: missing artifact closed with message";;
  (*) echo "FAIL: missing artifact closed SILENTLY"; exit 1;; esac
mv "$a.bak" "$a"

# 7. --delegated: works at every gated stage, always recorded (with the agent runner)
"$kit/gates/approve.sh" intent "$a" --delegated >/dev/null
grep -q '^mode: delegated-chat' .sdlc/approvals/feat-a.intent.approval || { echo "FAIL: delegated mode not recorded"; exit 1; }
grep -q '^runner: agent' .sdlc/approvals/feat-a.intent.approval || { echo "FAIL: agent runner not recorded for delegated"; exit 1; }
grep -q '^artifact_sha256: [0-9a-f]\{64\}$' .sdlc/approvals/feat-a.intent.approval || { echo "FAIL: approval does not bind the artifact digest"; exit 1; }
grep -qx 'artifact: .sdlc/work/feat-a/intent.md' .sdlc/approvals/feat-a.intent.approval || { echo "FAIL: approval does not bind the canonical path"; exit 1; }
echo "spec body" > .sdlc/work/feat-a/spec.md
"$kit/gates/approve.sh" spec .sdlc/work/feat-a/spec.md --delegated >/dev/null
grep -q '^mode: delegated-chat' .sdlc/approvals/feat-a.spec.approval || { echo "FAIL: delegated mode not recorded for spec"; exit 1; }
grep -q '^upstream_intent: [0-9a-f]\{64\}$' .sdlc/approvals/feat-a.spec.approval || { echo "FAIL: spec approval does not bind the upstream intent"; exit 1; }
# the gate binds ONE artifact per stage: a spec approval over intent.md is refused
if "$kit/gates/approve.sh" spec "$a" --delegated >/dev/null 2>&1; then
  echo "FAIL: spec gate accepted intent.md as its artifact"; exit 1; fi
echo "ok: delegated approval recorded, path/digest/upstream bound, artifact allowlisted"

# 8. close mechanism: dead-end blocked without lesson, allowed with, idempotent-refused,
#    and the feature + its approvals archive out of work/
mkdir -p .sdlc/memory/lessons
if "$kit/gates/close.sh" feat-a dead-end "test reason" >/dev/null 2>&1; then
  echo "FAIL: dead-end close allowed without a lesson"; exit 1; fi
echo "lesson" > .sdlc/memory/lessons/2020-01-01-feat-a.md
mkdir -p .sdlc/work/feat-a/scratch && echo bulk > .sdlc/work/feat-a/scratch/dump.log
out=$("$kit/gates/close.sh" feat-a dead-end "test reason")
grep -q '^state: dead-end' .sdlc/archive/feat-a/CLOSED || { echo "FAIL: CLOSED record wrong or not archived"; exit 1; }
[ -d .sdlc/work/feat-a ] && { echo "FAIL: closed feature still under work/"; exit 1; }
[ -f .sdlc/archive/feat-a/approvals/feat-a.intent.approval ] || { echo "FAIL: approvals not archived with the feature"; exit 1; }
ls .sdlc/approvals/feat-a.*.approval >/dev/null 2>&1 && { echo "FAIL: approvals left behind in .sdlc/approvals/"; exit 1; }
grep -q '^\.sdlc/archive/\*/scratch/$' .gitignore || { echo "FAIL: archive scratch not gitignored on close"; exit 1; }
case "$out" in (*"scratch/ still has files"*) ;; (*) echo "FAIL: leftover scratch not flagged at close"; exit 1;; esac
if "$kit/gates/close.sh" feat-a abandoned "again" >/dev/null 2>&1; then
  echo "FAIL: double close allowed"; exit 1; fi
echo "ok: close requires lesson, archives feature+approvals, refuses double close"

# 9. handed-off: blocked without external reference, allowed with key/URL, no lesson required
mkdir -p .sdlc/work/feat-b
if "$kit/gates/close.sh" feat-b handed-off "sent to another team" >/dev/null 2>&1; then
  echo "FAIL: handed-off close allowed without an external reference"; exit 1; fi
"$kit/gates/close.sh" feat-b handed-off "tracking continues in A20-1240" >/dev/null
grep -q '^state: handed-off' .sdlc/archive/feat-b/CLOSED || { echo "FAIL: handed-off state not recorded"; exit 1; }
grep -q '^reason: tracking continues in A20-1240' .sdlc/archive/feat-b/CLOSED || { echo "FAIL: handed-off reference not recorded"; exit 1; }
echo "ok: handed-off requires and records external reference"

# 10. shell scripts are LF-only — a CRLF checkout (Git for Windows default
#     core.autocrlf=true, without .gitattributes) makes bash reject every script
crlf=$(find "$kit" \( -name '*.sh' -o -name '*.py' \) -not -path '*/.git/*' -exec awk '/\r/{print FILENAME}' {} + | sort -u)
[ -z "$crlf" ] || { echo "FAIL: CRLF line endings — bash on Windows cannot run these:"; echo "$crlf"; exit 1; }
echo "ok: shell scripts are LF-only"

# 11. every SKILL.md frontmatter parses as YAML (guards the 'Triggers:' colon trap)
py=""
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 || continue
  # -c '' rejects the Windows Store alias stub, which resolves but never runs
  "$c" -c '' >/dev/null 2>&1 && { py="$c"; break; }
done
if [ -n "$py" ]; then
  if ! "$py" - "$kit" <<'PYEOF'
import sys, glob, os
failed = []
for p in glob.glob(os.path.join(sys.argv[1], '**/SKILL.md'), recursive=True):
    text = open(p).read()
    if not text.startswith('---'):
        failed.append(f'{p}: no frontmatter'); continue
    fm = text.split('---')[1]
    try:
        import yaml
        d = yaml.safe_load(fm)
        assert isinstance(d, dict) and 'name' in d and 'description' in d
    except ImportError:
        for line in fm.strip().split('\n'):
            if line and not line.startswith((' ', '#')) and ': ' in line:
                v = line.split(': ', 1)[1]
                if ': ' in v and not v.startswith(('"', "'", '|', '>')):
                    failed.append(f'{p}: unquoted colon in value: {line[:60]}')
    except Exception as e:
        failed.append(f'{p}: {e}')
if failed:
    print('\n'.join(failed)); sys.exit(1)
PYEOF
  then
    echo "FAIL: SKILL.md frontmatter invalid (see above)"; exit 1
  fi
  echo "ok: all SKILL.md frontmatter valid"
else
  echo "skip: no working python found, frontmatter check skipped"
fi

# 12. --agent-adversary: recorded for plan, rejected for every other stage
mkdir -p .sdlc/work/feat-c
p=.sdlc/work/feat-c/plan.md
echo "plan: test" > "$p"
"$kit/gates/approve.sh" plan "$p" --agent-adversary >/dev/null
grep -q '^mode: agent-adversary' .sdlc/approvals/feat-c.plan.approval || { echo "FAIL: agent-adversary mode not recorded"; exit 1; }
grep -q '^runner: agent' .sdlc/approvals/feat-c.plan.approval || { echo "FAIL: agent runner not recorded for agent-adversary"; exit 1; }
"$kit/gates/check-gate.sh" plan "$p" >/dev/null
if "$kit/gates/approve.sh" spec "$p" --agent-adversary >/dev/null 2>&1; then
  echo "FAIL: agent-adversary accepted for a non-plan stage"; exit 1; fi
echo "ok: agent-adversary approval is plan-only and recorded"

# 13. status.sh renders every state without crashing
mkdir -p .sdlc/work/feat-d
out=$("$kit/gates/status.sh" feat-d) || { echo "FAIL: status.sh crashed on artifact-less feature"; exit 1; }
case "$out" in (*"write intent.md"*) ;; (*) echo "FAIL: wrong next action for empty feature"; exit 1;; esac
echo i > .sdlc/work/feat-d/intent.md; echo s > .sdlc/work/feat-d/spec.md; echo p > .sdlc/work/feat-d/plan.md
"$kit/gates/approve.sh" intent .sdlc/work/feat-d/intent.md --delegated >/dev/null
"$kit/gates/approve.sh" spec .sdlc/work/feat-d/spec.md --delegated >/dev/null
out=$("$kit/gates/status.sh" feat-d) || { echo "FAIL: status.sh crashed mid-run"; exit 1; }
case "$out" in (*"plan gate (tiered)"*) ;; (*) echo "FAIL: tiered plan hint missing"; exit 1;; esac
"$kit/gates/approve.sh" plan .sdlc/work/feat-d/plan.md --agent-adversary >/dev/null
out=$("$kit/gates/status.sh" feat-d) || { echo "FAIL: status.sh crashed after tier approval"; exit 1; }
case "$out" in (*"agent-adversary"*) ;; (*) echo "FAIL: agent-adversary mode not shown"; exit 1;; esac
out=$("$kit/gates/status.sh") || { echo "FAIL: status.sh crashed on full run"; exit 1; }
case "$out" in (*"[CLOSED:"*) echo "FAIL: archived feature leaked into the default run"; exit 1;; (*) ;; esac
out=$("$kit/gates/status.sh" --all) || { echo "FAIL: status.sh crashed with --all"; exit 1; }
case "$out" in (*"[CLOSED: dead-end]"*"(archived)"*) ;; (*) echo "FAIL: --all does not render archived features"; exit 1;; esac
out=$("$kit/gates/status.sh" feat-a) || { echo "FAIL: status.sh crashed on an archived slug"; exit 1; }
case "$out" in (*"[CLOSED: dead-end]"*) ;; (*) echo "FAIL: archived slug not found by name"; exit 1;; esac
echo "ok: status.sh renders empty, tiered, approved, and archived states"

# 14. upstream chaining: editing intent after spec approval CLOSES the spec gate
"$kit/gates/check-gate.sh" spec .sdlc/work/feat-d/spec.md >/dev/null
cp .sdlc/work/feat-d/intent.md .sdlc/work/feat-d/intent.md.orig
echo "tweak" >> .sdlc/work/feat-d/intent.md
out=$("$kit/gates/check-gate.sh" spec .sdlc/work/feat-d/spec.md 2>&1) && { echo "FAIL: spec gate survived an upstream intent rewrite"; exit 1; }
case "$out" in (*"intent.md changed after"*) ;; (*) echo "FAIL: upstream-drift message missing: $out"; exit 1;; esac
mv .sdlc/work/feat-d/intent.md.orig .sdlc/work/feat-d/intent.md
"$kit/gates/check-gate.sh" spec .sdlc/work/feat-d/spec.md >/dev/null || { echo "FAIL: spec gate not open after the upstream was restored"; exit 1; }
echo "ok: upstream edit closes the downstream gate"

# 14b. origin.md (the ticket / 기획서 snapshot) is bound by the intent gate and
#      every gate downstream of it, and is never a gate of its own
mkdir -p .sdlc/work/feat-o
echo "ticket A20-1: users can export" > .sdlc/work/feat-o/origin.md
echo i > .sdlc/work/feat-o/intent.md; echo s > .sdlc/work/feat-o/spec.md
"$kit/gates/approve.sh" intent .sdlc/work/feat-o/intent.md --delegated >/dev/null
grep -q '^upstream_origin: [0-9a-f]' .sdlc/approvals/feat-o.intent.approval || { echo "FAIL: intent approval does not bind origin.md"; exit 1; }
"$kit/gates/approve.sh" spec .sdlc/work/feat-o/spec.md --delegated >/dev/null
echo "edited after approval" >> .sdlc/work/feat-o/origin.md
out=$("$kit/gates/check-gate.sh" spec .sdlc/work/feat-o/spec.md 2>&1) && { echo "FAIL: spec gate survived an origin.md rewrite"; exit 1; }
case "$out" in (*"origin.md changed after"*"re-approve intent, then spec"*) ;; (*) echo "FAIL: origin-drift message wrong: $out"; exit 1;; esac
if "$kit/gates/approve.sh" origin .sdlc/work/feat-o/origin.md --delegated >/dev/null 2>&1; then
  echo "FAIL: 'origin' accepted as a gate"; exit 1; fi
mkdir -p .sdlc/work/feat-o2; echo i > .sdlc/work/feat-o2/intent.md
"$kit/gates/approve.sh" intent .sdlc/work/feat-o2/intent.md --delegated >/dev/null
echo "late snapshot" > .sdlc/work/feat-o2/origin.md
out=$("$kit/gates/check-gate.sh" intent .sdlc/work/feat-o2/intent.md 2>&1) && { echo "FAIL: intent gate survived an origin.md written after the approval"; exit 1; }
case "$out" in (*"binds no digest for origin.md"*) ;; (*) echo "FAIL: unbound-origin message wrong: $out"; exit 1;; esac
echo "ok: origin.md is bound by intent and every downstream gate, never a gate itself"

# 15. tripwire.sh: flags risky plans, stays quiet on clean ones
tw=.sdlc/work/feat-d/tw.md
printf 'step 1: run ALTER TABLE users\nstep 2: edit Dockerfile\n' > "$tw"
out=$("$kit/tools/tripwire.sh" "$tw")
case "$out" in (*"TRIP-WIRE?"*) ;; (*) echo "FAIL: tripwire missed a migration"; exit 1;; esac
printf 'step 1: rename a local variable\n' > "$tw"
out=$("$kit/tools/tripwire.sh" "$tw")
case "$out" in (*"no trip-wire candidates"*) ;; (*) echo "FAIL: tripwire false positive on a clean plan"; exit 1;; esac
echo "ok: tripwire flags risk and stays quiet on clean plans"

# 16. close.sh prints a promotion reminder for lesson tags repeating 3+ times
mkdir -p .sdlc/work/feat-e
echo "goal" > .sdlc/work/feat-e/intent.md
echo "lesson" > .sdlc/memory/lessons/2020-01-02-feat-e.md
cat >> .sdlc/memory/INDEX.md <<'EOF'
- [async, gate] one → lessons/a.md
- [async] two → lessons/b.md
- [async, test] three → lessons/c.md
EOF
out=$("$kit/gates/close.sh" feat-e dead-end "test promote" 2>&1)
case "$out" in (*"PROMOTE:"*async*) echo "ok: repeated lesson tag triggers promotion reminder";;
  (*) echo "FAIL: no promotion reminder for repeated tag"; exit 1;; esac

# 17. --lazy: refused with no lazymode / below the level, accepted at the level, recorded, shown
mkdir -p .sdlc/work/feat-f
fi2=.sdlc/work/feat-f/intent.md; fs=.sdlc/work/feat-f/spec.md; fp=.sdlc/work/feat-f/plan.md
echo "goal" > "$fi2"; echo "spec" > "$fs"; echo "plan" > "$fp"
rm -f .sdlc/config.md
if "$kit/gates/approve.sh" plan "$fp" --lazy --review "read the diff" >/dev/null 2>&1; then
  echo "FAIL: lazy approval accepted without lazymode in config"; exit 1; fi
printf 'lazymode: 1\n' > .sdlc/config.md
if "$kit/gates/approve.sh" spec "$fs" --lazy --review "read the spec" >/dev/null 2>&1; then
  echo "FAIL: lazy spec approval accepted at lazymode 1"; exit 1; fi
if "$kit/gates/approve.sh" plan "$fp" --lazy >/dev/null 2>&1; then
  echo "FAIL: lazy approval accepted without --review"; exit 1; fi
"$kit/gates/approve.sh" plan "$fp" --lazy --review "read plan and the code it touches" >/dev/null
grep -q '^review: read plan and the code it touches$' .sdlc/approvals/feat-f.plan.approval || { echo "FAIL: review note not recorded"; exit 1; }
grep -q '^mode: lazy' .sdlc/approvals/feat-f.plan.approval || { echo "FAIL: lazy mode not recorded"; exit 1; }
grep -q '^runner: agent' .sdlc/approvals/feat-f.plan.approval || { echo "FAIL: agent runner not recorded for lazy"; exit 1; }
printf 'lazymode: 4\n' > .sdlc/config.md
"$kit/gates/approve.sh" intent "$fi2" --lazy --review "read the handler and its callers" >/dev/null
"$kit/gates/approve.sh" spec "$fs" --lazy --review "read the spec against the code" >/dev/null
echo "evidence" > .sdlc/work/feat-f/evidence.md   # ship PENDING so status must hint --lazy
out=$("$kit/gates/status.sh" feat-f) || { echo "FAIL: status.sh crashed with lazymode set"; exit 1; }
case "$out" in (*"lazymode: 4"*) ;; (*) echo "FAIL: lazymode not shown in status"; exit 1;; esac
case "$out" in (*"· lazy"*) ;; (*) echo "FAIL: lazy approval mode not shown in status"; exit 1;; esac
case "$out" in (*"--lazy"*) ;; (*) echo "FAIL: pending ship gate should hint --lazy at lazymode 4"; exit 1;; esac
if "$kit/gates/approve.sh" build "$fp" --lazy --review r >/dev/null 2>&1; then
  echo "FAIL: --lazy accepted for an unknown stage"; exit 1; fi
printf 'lazymode: 10\n' > .sdlc/config.md   # out of range must fail CLOSED
if "$kit/gates/approve.sh" ship .sdlc/work/feat-f/evidence.md --lazy --review r >/dev/null 2>&1; then
  echo "FAIL: out-of-range lazymode failed OPEN"; exit 1; fi
printf 'lazymode: 4\r\n' > .sdlc/config.md  # CRLF-saved config must still parse
"$kit/gates/approve.sh" ship .sdlc/work/feat-f/evidence.md --lazy --review "diff reviewed" >/dev/null || { echo "FAIL: CRLF lazymode config not parsed"; exit 1; }
echo "ok: lazy approval enforces the lazymode level, range, and CRLF, is recorded, and shows in status"

# 18. lazymode >=3 waives the lesson requirement on non-shipped closes; below 3 keeps it
mkdir -p .sdlc/work/feat-g .sdlc/work/feat-h
echo "goal" > .sdlc/work/feat-g/intent.md; echo "goal" > .sdlc/work/feat-h/intent.md
printf 'lazymode: 3\n' > .sdlc/config.md
"$kit/gates/close.sh" feat-g dead-end "spike did not pan out" >/dev/null || { echo "FAIL: lazymode 3 close still demands a lesson"; exit 1; }
printf 'lazymode: 2\n' > .sdlc/config.md
if "$kit/gates/close.sh" feat-h dead-end "no lesson here" >/dev/null 2>&1; then
  echo "FAIL: lazymode 2 close allowed without a lesson"; exit 1; fi
echo "ok: lazymode >=3 waives the lesson, below 3 still requires it"

# 19. archived slugs are single-use: approve.sh refuses them
mkdir -p .sdlc/work/feat-a && echo again > .sdlc/work/feat-a/intent.md   # feat-a archived in test 8
if "$kit/gates/approve.sh" intent .sdlc/work/feat-a/intent.md >/dev/null 2>&1; then
  echo "FAIL: approve accepted a slug that is already archived"; exit 1; fi
rm -rf .sdlc/work/feat-a
echo "ok: approve refuses an archived slug"

# 20. interrupted close resumes without rewriting CLOSED, but re-runs the
#     checks (CLOSED is agent-writable) and refuses a state mismatch
printf 'lazymode: 0\n' > .sdlc/config.md
mkdir -p .sdlc/work/feat-j
printf 'state: abandoned\nreason: r\n' > .sdlc/work/feat-j/CLOSED
if "$kit/gates/close.sh" feat-j dead-end "r" >/dev/null 2>&1; then
  echo "FAIL: resume accepted a state that contradicts CLOSED"; exit 1; fi
if "$kit/gates/close.sh" feat-j abandoned "r" >/dev/null 2>&1; then
  echo "FAIL: resume skipped the lesson check"; exit 1; fi
echo "lesson" > .sdlc/memory/lessons/2020-01-03-feat-j.md
out=$("$kit/gates/close.sh" feat-j abandoned "r") || { echo "FAIL: legit resume failed"; exit 1; }
case "$out" in (*"resuming"*) ;; (*) echo "FAIL: resume not announced"; exit 1;; esac
grep -q '^reason: r$' .sdlc/archive/feat-j/CLOSED || { echo "FAIL: resume rewrote CLOSED"; exit 1; }
echo "ok: resume archives, re-runs checks, refuses state mismatch"

# 21. map-first feature: next action points at map.md, not intent.md
mkdir -p .sdlc/work/feat-k
echo m > .sdlc/work/feat-k/map.md
out=$("$kit/gates/status.sh" feat-k) || { echo "FAIL: status.sh crashed on a map-only feature"; exit 1; }
case "$out" in (*"map.md"*) ;; (*) echo "FAIL: map-first next action missing"; exit 1;; esac
echo "ok: map-first feature routes to the map, not intent.md"

# 22. archive listings are bounded: --all caps at 20 with a pointer line,
#     --all=<n> widens/narrows, stats.sh default notes the truncation
for i in $(seq 1 20); do
  d=".sdlc/archive/bulk-$i"; mkdir -p "$d"
  printf 'state: shipped\nreason: r\n' > "$d/CLOSED"
done   # + features archived by earlier tests → well over the cap
out=$("$kit/gates/status.sh" --all)
n=$(printf '%s\n' "$out" | grep -c '(archived)') || true
[ "$n" -eq 20 ] || { echo "FAIL: --all showed $n archived, expected cap 20"; exit 1; }
case "$out" in (*"more archived"*) ;; (*) echo "FAIL: --all missing the truncation pointer"; exit 1;; esac
out=$("$kit/gates/status.sh" --all=3)
n=$(printf '%s\n' "$out" | grep -c '(archived)') || true
[ "$n" -eq 3 ] || { echo "FAIL: --all=3 showed $n archived"; exit 1; }
out=$("$kit/gates/stats.sh")
case "$out" in (*"most recently closed"*) ;; (*) echo "FAIL: stats.sh default not bounded/noted"; exit 1;; esac
case "$out" in (*"included only with --all"*) ;; (*) echo "FAIL: stats.sh re-approval scope note missing"; exit 1;; esac
echo "ok: archive listings bounded by default, widened only explicitly"

# 23. compact route: status skips spec/plan, marks the feature, routes to build;
#     'micro' still parses as the older spelling of the same verdict
mkdir -p .sdlc/work/feat-m
printf -- '- Track: compact — two known files, existing test\ngoal\n' > .sdlc/work/feat-m/intent.md
"$kit/gates/approve.sh" intent .sdlc/work/feat-m/intent.md --delegated >/dev/null
grep -q '^track: compact' .sdlc/approvals/feat-m.intent.approval || { echo "FAIL: compact track not recorded"; exit 1; }
out=$("$kit/gates/status.sh" feat-m) || { echo "FAIL: status.sh crashed on a compact feature"; exit 1; }
case "$out" in (*"(compact)"*) ;; (*) echo "FAIL: compact marker missing"; exit 1;; esac
case "$out" in (*"  spec "*) echo "FAIL: compact feature still shows a spec stage"; exit 1;; (*) ;; esac
case "$out" in (*"write evidence.md"*) ;; (*) echo "FAIL: compact next action should be build/ship"; exit 1;; esac
# a compact slug has no spec or plan gate: approving one demands the upgrade first
echo s > .sdlc/work/feat-m/spec.md
out=$("$kit/gates/approve.sh" spec .sdlc/work/feat-m/spec.md --delegated 2>&1) && { echo "FAIL: spec approved on a compact-track slug"; exit 1; }
case "$out" in (*"upgraded from compact"*) ;; (*) echo "FAIL: no upgrade instruction on the refused spec approval"; exit 1;; esac
# upgrade: re-approve intent as full, then the spec gate is available again
printf -- '- Track: full — upgraded from compact (scope grew)\ngoal\n' > .sdlc/work/feat-m/intent.md
"$kit/gates/approve.sh" intent .sdlc/work/feat-m/intent.md --delegated >/dev/null
"$kit/gates/approve.sh" spec .sdlc/work/feat-m/spec.md --delegated >/dev/null || { echo "FAIL: spec approval still refused after the track upgrade"; exit 1; }
out=$("$kit/gates/status.sh" feat-m) || { echo "FAIL: status.sh crashed on healed compact"; exit 1; }
case "$out" in (*"(compact)"*) echo "FAIL: spec.md present but still rendered compact"; exit 1;; (*) ;; esac
rm .sdlc/work/feat-m/spec.md
mkdir -p .sdlc/work/feat-p   # 'microservice-…' must NOT read as the compact track
printf -- '- Track: microservice-split\ngoal\n' > .sdlc/work/feat-p/intent.md
out=$("$kit/gates/status.sh" feat-p) || { echo "FAIL: status.sh crashed on feat-p"; exit 1; }
case "$out" in (*"(compact)"*) echo "FAIL: 'microservice…' misread as the compact track"; exit 1;; (*) ;; esac
mkdir -p .sdlc/work/feat-mi   # older spelling still parses
printf -- '- Track: micro — legacy spelling\ngoal\n' > .sdlc/work/feat-mi/intent.md
"$kit/gates/approve.sh" intent .sdlc/work/feat-mi/intent.md --delegated >/dev/null
grep -q '^track_spelling: micro' .sdlc/approvals/feat-mi.intent.approval || { echo "FAIL: legacy micro spelling not recorded"; exit 1; }
out=$("$kit/gates/status.sh" feat-mi) || { echo "FAIL: status.sh crashed on a legacy micro feature"; exit 1; }
case "$out" in (*"(compact)"*) ;; (*) echo "FAIL: legacy micro spelling not treated as compact"; exit 1;; esac
echo "ok: compact route skips spec/plan, upgrade revalidates intent, 'micro' still parses"

# 24. shipped requires the ship approval AND a confirmed delivery record;
#     unmerged harvest blocks close
mkdir -p .sdlc/work/feat-o
echo goal > .sdlc/work/feat-o/intent.md
echo evidence > .sdlc/work/feat-o/evidence.md
echo "- [tag] candidate" > .sdlc/work/feat-o/harvest.md
if "$kit/gates/close.sh" feat-o shipped "done" >/dev/null 2>&1; then
  echo "FAIL: shipped close allowed without a ship approval"; exit 1; fi
"$kit/gates/approve.sh" ship .sdlc/work/feat-o/evidence.md >/dev/null
if "$kit/gates/close.sh" feat-o shipped "done" >/dev/null 2>&1; then
  echo "FAIL: close allowed with an unmerged harvest.md"; exit 1; fi
rm .sdlc/work/feat-o/harvest.md
out=$("$kit/gates/close.sh" feat-o shipped "done" 2>&1) && { echo "FAIL: shipped close allowed with no delivery record"; exit 1; }
case "$out" in (*"requires a delivery record"*) ;; (*) echo "FAIL: missing-delivery message wrong: $out"; exit 1;; esac
codeid=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/feat-o.ship.approval)
cat > .sdlc/work/feat-o/delivery.md <<EOF
# Delivery: feat-o
- Target: local
- Source: worktree:$codeid
- Verified-by: bash gates/selftest.sh
- Evidence: SELFTEST PASS
- Confirmed: no
EOF
out=$("$kit/gates/close.sh" feat-o shipped "done" 2>&1) && { echo "FAIL: unconfirmed delivery accepted as shipped"; exit 1; }
case "$out" in (*"Confirmed"*) ;; (*) echo "FAIL: unconfirmed-delivery message wrong: $out"; exit 1;; esac
sed 's/^- Confirmed: no/- Confirmed: yes/; s|^- Source: .*|- Source: worktree:deadbeef|' .sdlc/work/feat-o/delivery.md > .sdlc/work/feat-o/delivery.tmp
mv .sdlc/work/feat-o/delivery.tmp .sdlc/work/feat-o/delivery.md
out=$("$kit/gates/close.sh" feat-o shipped "done" 2>&1) && { echo "FAIL: delivery with a mismatched source accepted"; exit 1; }
case "$out" in (*"Source does not match the current source identity"*) ;; (*) echo "FAIL: source-mismatch message wrong: $out"; exit 1;; esac
sed "s|^- Source: .*|- Source: worktree:$codeid|" .sdlc/work/feat-o/delivery.md > .sdlc/work/feat-o/delivery.tmp
mv .sdlc/work/feat-o/delivery.tmp .sdlc/work/feat-o/delivery.md
out=$("$kit/gates/close.sh" feat-o shipped "done") || { echo "FAIL: valid delivery still rejected"; exit 1; }
case "$out" in (*"delivery: local"*) ;; (*) echo "FAIL: delivery not reported at close"; exit 1;; esac
echo "ok: shipped needs approval + confirmed, source-matching delivery; harvest blocks until merged"

# 25. approvals stranded between the two archive mvs are swept on the next close attempt
echo "stage: intent" > .sdlc/approvals/feat-o.intent.approval   # feat-o already archived in test 24
out=$("$kit/gates/close.sh" feat-o shipped "again" 2>&1) && { echo "FAIL: double close of archived slug allowed"; exit 1; }
case "$out" in (*"swept stranded approval"*) ;; (*) echo "FAIL: stranded approval not swept"; exit 1;; esac
[ -f .sdlc/archive/feat-o/approvals/feat-o.intent.approval ] || { echo "FAIL: swept approval not in archive"; exit 1; }
echo "ok: stranded approvals are swept into the archive"

# 26. re-approval leaves a .history trail and stats counts it
mkdir -p .sdlc/work/feat-q
echo plan > .sdlc/work/feat-q/plan.md
"$kit/gates/approve.sh" plan .sdlc/work/feat-q/plan.md --agent-adversary >/dev/null
"$kit/gates/approve.sh" plan .sdlc/work/feat-q/plan.md --agent-adversary >/dev/null
[ -f .sdlc/approvals/feat-q.plan.approval.history ] || { echo "FAIL: no .history on re-approval"; exit 1; }
out=$("$kit/gates/stats.sh") || { echo "FAIL: stats.sh crashed"; exit 1; }
case "$out" in (*"feat-q.plan: 2 approvals"*) ;; (*) echo "FAIL: stats missed the re-approval"; exit 1;; esac
case "$out" in (*"agent-adversary"*) ;; (*) echo "FAIL: stats hides agent-run approval modes"; exit 1;; esac
echo "ok: re-approvals leave a history trail; stats reports modes honestly"

# 27. Track verdict frozen at approval: post-approval micro flip is flagged, not honored
mkdir -p .sdlc/work/feat-r
printf -- '- Track: full\ngoal\n' > .sdlc/work/feat-r/intent.md
"$kit/gates/approve.sh" intent .sdlc/work/feat-r/intent.md --delegated >/dev/null
grep -q '^track: full' .sdlc/approvals/feat-r.intent.approval || { echo "FAIL: track not recorded in approval"; exit 1; }
printf -- '- Track: compact — flipped after approval\ngoal\n' > .sdlc/work/feat-r/intent.md
out=$("$kit/gates/status.sh" feat-r) || { echo "FAIL: status crashed on track mismatch"; exit 1; }
case "$out" in (*"(compact)"*) echo "FAIL: post-approval compact flip honored"; exit 1;; (*) ;; esac
case "$out" in (*"re-approve intent"*) ;; (*) echo "FAIL: track mismatch not flagged"; exit 1;; esac
echo "ok: intent approval freezes the Track verdict"

# 28. init.sh seeds the full ignore set, keeps the decision record committable,
#     is idempotent, and flags paths a previous kit version already tracked
(
  mkdir -p "$tmp/init-probe"; cd "$tmp/init-probe"; git init -q .
  mkdir -p .sdlc/work/feat-x
  echo e > .sdlc/work/feat-x/evidence.md
  git add -A
  printf '%s\n' '.sdlc/work/*/spec.md' '.sdlc/archive/*/evidence.md' > .gitignore  # seeded by an older kit
  out=$("$kit/init.sh" .)
  for line in '.sdlc/approvals/' '.sdlc/archive/*/approvals/' \
              '.sdlc/work/*/harvest.md' '.sdlc/work/*/deviations.md' \
              '.sdlc/work/*/baseline.txt' '.sdlc/work/*/scratch/'; do
    grep -qxF "$line" .gitignore || { echo "FAIL: init.sh does not ignore $line"; exit 1; }
  done
  # the durable record is committable: obsolete kit-owned ignores are removed,
  # and never re-added
  for line in '.sdlc/work/*/spec.md' '.sdlc/archive/*/spec.md' \
              '.sdlc/work/*/evidence.md' '.sdlc/archive/*/evidence.md'; do
    grep -qxF "$line" .gitignore && { echo "FAIL: init.sh still ignores the durable $line"; exit 1; }
  done
  case "$out" in (*"removed obsolete kit ignore"*) ;;
    (*) echo "FAIL: init.sh did not report removing the obsolete ignores"; exit 1;; esac
  before=$(wc -l < .gitignore)
  "$kit/init.sh" . >/dev/null
  [ "$(wc -l < .gitignore)" = "$before" ] || { echo "FAIL: init.sh .gitignore is not idempotent"; exit 1; }
  # --no-index: check-ignore skips paths already in the index, and evidence.md
  # was staged above on purpose — we are testing the rules, not the index
  # the durable record must survive: ignoring it would erase the audit trail
  for keep in intent.md spec.md plan.md map.md evidence.md delivery.md; do
    if git check-ignore --no-index -q ".sdlc/work/feat-x/$keep"; then
      echo "FAIL: $keep is gitignored — the durable record must stay committable"; exit 1; fi
  done
  for drop in harvest.md deviations.md baseline.txt progress.md; do
    if ! git check-ignore --no-index -q ".sdlc/work/feat-x/$drop"; then
      echo "FAIL: $drop is not gitignored"; exit 1; fi
  done
  if ! git check-ignore --no-index -q .sdlc/work/feat-x/scratch/dump.log; then
    echo "FAIL: scratch/ is not gitignored"; exit 1; fi
  if ! git check-ignore --no-index -q .sdlc/approvals/feat-x.intent.approval; then
    echo "FAIL: approval records are not gitignored"; exit 1; fi
  # init.sh must never touch the git index: evidence.md was staged before the
  # run and must still be staged after it (untracking is the human's call)
  git ls-files | grep -q '^\.sdlc/work/feat-x/evidence\.md$' || {
    echo "FAIL: init.sh mutated the git index"; exit 1; }
) || exit 1
echo "ok: init.sh keeps the durable record committable, ignores residue, is idempotent"

# 29. approvals are bound to a PATH, not a bare slug: a same-slug feature dir
#     somewhere else cannot reuse the approval, and a symlinked dir is refused
mkdir -p .sdlc/work/marker
echo "goal" > .sdlc/work/marker/intent.md
"$kit/gates/approve.sh" intent .sdlc/work/marker/intent.md >/dev/null
"$kit/gates/check-gate.sh" intent .sdlc/work/marker/intent.md >/dev/null
mkdir -p elsewhere/marker
cp .sdlc/work/marker/intent.md elsewhere/marker/intent.md
if "$kit/gates/check-gate.sh" intent elsewhere/marker/intent.md >/dev/null 2>&1; then
  echo "FAIL: an approval opened the gate for a same-slug dir outside .sdlc/work/"; exit 1; fi
if "$kit/gates/approve.sh" intent elsewhere/marker/intent.md >/dev/null 2>&1; then
  echo "FAIL: approve accepted an artifact outside .sdlc/work/"; exit 1; fi
# a traversal that resolves to the SAME canonical file is fine, not a hole
"$kit/gates/check-gate.sh" intent .sdlc/work/../work/marker/intent.md >/dev/null \
  || { echo "FAIL: canonical path rejected when reached via .."; exit 1; }
# a traversal that escapes is not
if "$kit/gates/check-gate.sh" intent .sdlc/work/../../elsewhere/marker/intent.md >/dev/null 2>&1; then
  echo "FAIL: traversal out of the project accepted"; exit 1; fi
mklink "$tmp/elsewhere/marker" .sdlc/work/linked
if "$kit/gates/approve.sh" intent .sdlc/work/linked/intent.md >/dev/null 2>&1; then
  echo "FAIL: symlinked feature dir accepted"; exit 1; fi
rm -f .sdlc/work/linked
mklink ../marker/intent.md .sdlc/work/marker/link.md
if "$kit/gates/approve.sh" intent .sdlc/work/marker/link.md >/dev/null 2>&1; then
  echo "FAIL: symlinked artifact accepted"; exit 1; fi
rm -f .sdlc/work/marker/link.md
echo "ok: approvals bind a canonical path; cross-path, traversal, and symlinks refused"

# 30. an approval record written by an older kit (no content binding) fails CLOSED
printf 'stage: intent\nartifact: .sdlc/work/marker/intent.md\napproved_at: 2020-01-01T00:00:00Z\n' \
  > .sdlc/approvals/marker.intent.approval
out=$("$kit/gates/check-gate.sh" intent .sdlc/work/marker/intent.md 2>&1) && {
  echo "FAIL: legacy approval marker still opens the gate"; exit 1; }
case "$out" in (*"predates content binding"*"approve.sh intent"*) ;;
  (*) echo "FAIL: legacy marker message is not actionable: $out"; exit 1;; esac
out=$("$kit/gates/status.sh" marker) || { echo "FAIL: status crashed on a legacy marker"; exit 1; }
case "$out" in (*"STALE"*) ;; (*) echo "FAIL: status does not flag the stale approval"; exit 1;; esac
"$kit/gates/approve.sh" intent .sdlc/work/marker/intent.md >/dev/null
"$kit/gates/check-gate.sh" intent .sdlc/work/marker/intent.md >/dev/null
echo "ok: pre-binding approval records fail closed with the re-approval command"

# 31. lazymode moves the checkpoint, not the review: --review is mandatory, and
#     risky work needs recorded authorization. A clean keyword scan clears nothing.
mkdir -p .sdlc/work/feat-risk
ri=.sdlc/work/feat-risk/intent.md
printf 'goal: drop the password check for admin sessions\n' > "$ri"
printf 'lazymode: 4\n' > .sdlc/config.md
if "$kit/gates/approve.sh" intent "$ri" --lazy --review "read the session code" >/dev/null 2>&1; then
  echo "FAIL: risky intent lazily approved without recorded authorization"; exit 1; fi
"$kit/gates/approve.sh" intent "$ri" --lazy --review "read auth/session.js and its callers" \
  --risk-authorized "human 2026-09-15: yes, remove that check" >/dev/null
grep -q '^risk_authority: human 2026-09-15' .sdlc/approvals/feat-risk.intent.approval || {
  echo "FAIL: risk authorization not recorded"; exit 1; }
# non-English risky text: the scan finds nothing, and that clears NOTHING —
# the review requirement is unchanged, which is what the record must show
mkdir -p .sdlc/work/feat-ko
ki=.sdlc/work/feat-ko/intent.md
printf '목표: 로그인 검증을 제거하고 모든 사용자에게 관리자 권한을 부여한다\n' > "$ki"
out=$("$kit/tools/tripwire.sh" "$ki")
case "$out" in (*"no trip-wire candidates"*) ;; (*) echo "FAIL: tripwire fixture changed"; exit 1;; esac
case "$out" in (*"not a risk verdict"*) ;; (*) echo "FAIL: tripwire clean output does not disclaim authority"; exit 1;; esac
if "$kit/gates/approve.sh" intent "$ki" --lazy >/dev/null 2>&1; then
  echo "FAIL: clean keyword scan let a lazy approval skip the review"; exit 1; fi
"$kit/gates/approve.sh" intent "$ki" --lazy --review "read the auth middleware; change is scoped to the test fixture" >/dev/null
grep -q '^review: ' .sdlc/approvals/feat-ko.intent.approval || { echo "FAIL: review note not recorded"; exit 1; }
echo "ok: --lazy records a real review; risky work needs authorization; a clean scan authorizes nothing"

# 32. a feature from the OLD compressed loop (plan.md, no intent.md) gets a
#     documented continuation path instead of a silently lost gate
mkdir -p .sdlc/work/feat-legacy
echo "mini plan" > .sdlc/work/feat-legacy/plan.md
"$kit/gates/approve.sh" plan .sdlc/work/feat-legacy/plan.md --agent-adversary >/dev/null
out=$("$kit/gates/status.sh" feat-legacy) || { echo "FAIL: status crashed on a legacy compressed feature"; exit 1; }
case "$out" in (*"LEGACY COMPRESSED"*) ;; (*) echo "FAIL: legacy compressed feature not detected"; exit 1;; esac
case "$out" in (*"write intent.md"*) ;; (*) echo "FAIL: no continuation path for legacy compressed work"; exit 1;; esac
echo "ok: pre-compact compressed work keeps an explicit continuation path"

# 33. refcheck.sh: a matching HEAD proves nothing about the files on disk
(
  mkdir -p "$tmp/refprobe"; cd "$tmp/refprobe"; git init -q .
  git config user.email t@example.com; git config user.name t
  echo "v1" > app.txt; echo "cfg" > cfg.txt
  git add app.txt cfg.txt; git commit -qm init
  git branch deploy-ref
  # clean tree, HEAD == ref → OK
  out=$("$kit/tools/refcheck.sh" deploy-ref --no-fetch) || { echo "FAIL: clean tree reported as drift"; exit 1; }
  case "$out" in (*"OK:"*) ;; (*) echo "FAIL: clean tree not OK: $out"; exit 1;; esac
  case "$out" in (*"deployed revision: UNKNOWN"*) ;;
    (*) echo "FAIL: refcheck claims to know the deployed revision without evidence"; exit 1;; esac
  # unstaged edit, HEAD still == ref → DRIFT (this is the bug that shipped in 0.8.0)
  echo "hotfix" >> app.txt
  out=$("$kit/tools/refcheck.sh" deploy-ref --no-fetch 2>&1) && {
    echo "FAIL: dirty working tree reported as matching the deploy ref"; exit 1; }
  case "$out" in (*"DRIFT"*app.txt*) ;; (*) echo "FAIL: drifted file not named: $out"; exit 1;; esac
  # staged, not committed → still drift
  git add app.txt
  "$kit/tools/refcheck.sh" deploy-ref --no-fetch >/dev/null 2>&1 && {
    echo "FAIL: staged-only change reported as matching"; exit 1; }
  git commit -qm hotfix
  # committed → HEAD moved; the named path really differs from the ref
  out=$("$kit/tools/refcheck.sh" deploy-ref --no-fetch app.txt 2>&1) && {
    echo "FAIL: committed divergence reported as matching"; exit 1; }
  case "$out" in (*"~ app.txt"*) ;; (*) echo "FAIL: content comparison missing for app.txt: $out"; exit 1;; esac
  # a path that did NOT change is reported clean by CONTENT, not by commit count
  out=$("$kit/tools/refcheck.sh" deploy-ref --no-fetch cfg.txt) || {
    echo "FAIL: unchanged path reported as drift"; exit 1; }
  case "$out" in (*"OK:"*cfg.txt*) ;; (*) echo "FAIL: unchanged path not confirmed by content: $out"; exit 1;; esac
  # untracked new file counts as drift for the paths it covers
  echo new > extra.txt
  "$kit/tools/refcheck.sh" deploy-ref --no-fetch >/dev/null 2>&1 && {
    echo "FAIL: untracked file ignored"; exit 1; }
  rm extra.txt
  # unknown ref and an unknown deployed sha are UNKNOWN (exit 2), never a claim
  out=$("$kit/tools/refcheck.sh" no-such-ref --no-fetch 2>&1); rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: unknown ref exit $rc, expected 2"; exit 1; }
  case "$out" in (*"UNKNOWN"*) ;; (*) echo "FAIL: unknown ref not reported as unknown"; exit 1;; esac
  out=$("$kit/tools/refcheck.sh" deploy-ref --no-fetch --deployed-sha 0123456789012345678901234567890123456789 2>&1); rc=$?
  [ "$rc" = 2 ] || { echo "FAIL: unknown deployed sha exit $rc, expected 2"; exit 1; }
  # a supplied deployed sha is what gets compared, and it is labelled as such
  sha=$(git rev-parse HEAD)
  out=$("$kit/tools/refcheck.sh" deploy-ref --no-fetch --deployed-sha "$sha" cfg.txt) || {
    echo "FAIL: comparison against the supplied deployed sha failed"; exit 1; }
  case "$out" in (*"deployed revision: $sha"*) ;; (*) echo "FAIL: deployed sha not reported: $out"; exit 1;; esac
) || exit 1
echo "ok: refcheck compares worktree content, separates ref from deployment, fails to UNKNOWN"

# 34. workflow scenario: a compact bug fix from intent to a delivered close,
#     in a repo with real commits — staging and committing must NOT invalidate
#     the ship approval, but an edit after the review must.
(
  mkdir -p "$tmp/flow"; cd "$tmp/flow"; git init -q .
  git config user.email t@example.com; git config user.name t
  printf 'def login(user):\n    return user.valid\n' > app.py
  git add app.py; git commit -qm init
  "$kit/init.sh" . >/dev/null
  mkdir -p .sdlc/work/fix-login .sdlc/memory/lessons
  cat > .sdlc/work/fix-login/intent.md <<'EOF'
# Intent: fix-login
- Goal: users with a trailing space in their name can log in again.
- Track: compact — one file, existing test covers it
## Compact route
- Files: app.py (login)
- Proof: python3 -c "import app"
- Risk: login path only; single revert
- Delivery target: local
EOF
  # gate first: build is not authorized before the intent gate
  "$kit/gates/check-gate.sh" intent .sdlc/work/fix-login/intent.md >/dev/null 2>&1 && {
    echo "FAIL: compact build gate open before approval"; exit 1; }
  "$kit/gates/approve.sh" intent .sdlc/work/fix-login/intent.md --delegated >/dev/null
  "$kit/gates/check-gate.sh" intent .sdlc/work/fix-login/intent.md >/dev/null || {
    echo "FAIL: intent gate closed after approval"; exit 1; }
  out=$("$kit/gates/status.sh" fix-login)
  case "$out" in (*"(compact)"*) ;; (*) echo "FAIL: scenario feature not on the compact route"; exit 1;; esac
  case "$out" in (*"  spec "*) echo "FAIL: compact scenario still lists a spec stage"; exit 1;; (*) ;; esac
  # build
  printf 'def login(user):\n    return user.valid and user.name.strip() != ""\n' > app.py
  cat > .sdlc/work/fix-login/evidence.md <<'EOF'
# Evidence: fix-login
## Bug proof
- Before: repro → AttributeError
- Mechanism: name was compared unstripped
- After: same repro → pass
- Adjacent flows: signup → pass
EOF
  "$kit/gates/approve.sh" ship .sdlc/work/fix-login/evidence.md --delegated >/dev/null
  codeid=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/fix-login.ship.approval)
  grep -q '^code_scope: project' .sdlc/approvals/fix-login.ship.approval || {
    echo "FAIL: ship approval did not record the source scope"; exit 1; }
  grep -q ' app.py$' .sdlc/approvals/fix-login.ship.source || {
    echo "FAIL: ship source snapshot does not contain the reviewed file"; exit 1; }
  out=$("$kit/gates/status.sh" fix-login)
  case "$out" in (*"no delivery.md"*) ;; (*) echo "FAIL: status does not ask for the delivery record"; exit 1;; esac
  # staging + committing the REVIEWED content keeps the approval valid
  git add app.py .sdlc/work/fix-login .gitignore
  git commit -qm "fix(login): strip the name before validating"
  sha=$(git rev-parse HEAD)
  cat > .sdlc/work/fix-login/delivery.md <<EOF
# Delivery: fix-login
- Target: local
- Source: $sha
- Verified-by: python3 -c "import app"
- Evidence: exit 0
- Confirmed: yes
EOF
  "$kit/gates/close.sh" fix-login shipped "login fix delivered locally" >/dev/null || {
    echo "FAIL: committing the reviewed content invalidated the delivery"; exit 1; }
  [ -f .sdlc/archive/fix-login/CLOSED ] || { echo "FAIL: scenario feature not archived"; exit 1; }
  # second feature: an edit AFTER the ship review must block the close
  mkdir -p .sdlc/work/fix-two
  echo "goal" > .sdlc/work/fix-two/intent.md
  echo "evidence" > .sdlc/work/fix-two/evidence.md
  printf 'def helper():\n    return 1\n' > helper.py
  "$kit/gates/approve.sh" ship .sdlc/work/fix-two/evidence.md --delegated >/dev/null
  printf 'def helper():\n    return 2   # sneaked in after the review\n' > helper.py
  cat > .sdlc/work/fix-two/delivery.md <<EOF
# Delivery: fix-two
- Target: local
- Source: worktree:$(awk '/^code_digest: /{print $2}' .sdlc/approvals/fix-two.ship.approval)
- Verified-by: python3 -c "import helper"
- Evidence: exit 0
- Confirmed: yes
EOF
  out=$("$kit/gates/close.sh" fix-two shipped "done" 2>&1) && {
    echo "FAIL: close accepted code edited after the ship review"; exit 1; }
  case "$out" in (*"the source changed after the ship review"*) ;; (*) echo "FAIL: post-review edit message wrong: $out"; exit 1;; esac
  case "$out" in (*"~ helper.py"*) ;; (*) echo "FAIL: drift report does not name the changed file: $out"; exit 1;; esac
  # rewriting evidence.md after its approval is caught too
  mkdir -p .sdlc/work/fix-three
  echo "goal" > .sdlc/work/fix-three/intent.md
  echo "evidence" > .sdlc/work/fix-three/evidence.md
  "$kit/gates/approve.sh" ship .sdlc/work/fix-three/evidence.md --delegated >/dev/null
  echo "rewritten after approval" >> .sdlc/work/fix-three/evidence.md
  cat > .sdlc/work/fix-three/delivery.md <<EOF
# Delivery: fix-three
- Target: local
- Source: worktree:$(awk '/^code_digest: /{print $2}' .sdlc/approvals/fix-three.ship.approval)
- Verified-by: true
- Evidence: ok
- Confirmed: yes
EOF
  out=$("$kit/gates/close.sh" fix-three shipped "done" 2>&1) && {
    echo "FAIL: close accepted evidence rewritten after its approval"; exit 1; }
  case "$out" in (*"changed after the ship approval"*) ;; (*) echo "FAIL: evidence-drift message wrong: $out"; exit 1;; esac
  # a remote target may not be delivered from an uncommitted worktree
  sed 's/^- Target: local/- Target: pr/' .sdlc/work/fix-three/delivery.md > .sdlc/work/fix-three/d.tmp
  mv .sdlc/work/fix-three/d.tmp .sdlc/work/fix-three/delivery.md
  out=$("$kit/gates/close.sh" fix-three shipped "done" 2>&1) && {
    echo "FAIL: a pr delivery from an uncommitted worktree was accepted"; exit 1; }
  case "$out" in (*"changed after the ship approval"*|*"cannot come from an uncommitted worktree"*) ;;
    (*) echo "FAIL: pr-from-worktree message wrong: $out"; exit 1;; esac
) || exit 1
echo "ok: compact scenario ships through delivery; commits keep, edits break, the ship binding"

# 35. the ship binding covers work that was COMMITTED BEFORE the review, and a
#     pr/deploy Source commit must CONTAIN the reviewed source, not merely exist.
(
  mkdir -p "$tmp/committed"; cd "$tmp/committed"; git init -q .
  git config user.email t@example.com; git config user.name t
  printf 'echo v1\n' > late.sh
  git add late.sh; git commit -qm base
  old=$(git rev-parse HEAD)
  "$kit/init.sh" . >/dev/null
  mkdir -p .sdlc/work/committed-first
  echo goal > .sdlc/work/committed-first/intent.md
  printf 'echo v2\n' > late.sh
  echo "- Command: sh late.sh -> v2" > .sdlc/work/committed-first/evidence.md
  git add -A .; git commit -qm "feat: v2 (committed BEFORE the ship review)"
  head=$(git rev-parse HEAD)
  "$kit/gates/approve.sh" ship .sdlc/work/committed-first/evidence.md --delegated >/dev/null
  n=$(awk '/^code_files: /{print $2}' .sdlc/approvals/committed-first.ship.approval)
  [ "${n:-0}" -ge 1 ] || { echo "FAIL: ship approval bound an empty source set after a commit"; exit 1; }
  # a Source commit that predates the reviewed source is refused
  cat > .sdlc/work/committed-first/delivery.md <<EOF
# Delivery: committed-first
- Target: pr
- Source: $old
- Verified-by: sh late.sh
- Evidence: v2
- Confirmed: yes
EOF
  out=$("$kit/gates/close.sh" committed-first shipped "done" 2>&1) && {
    echo "FAIL: close accepted a Source commit that does not contain the reviewed source"; exit 1; }
  case "$out" in (*"does not CONTAIN the reviewed source"*) ;;
    (*) echo "FAIL: stale-source-commit message wrong: $out"; exit 1;; esac
  # the commit that does contain it closes
  sed "s|^- Source: .*|- Source: $head|" .sdlc/work/committed-first/delivery.md > d.tmp
  mv d.tmp .sdlc/work/committed-first/delivery.md
  "$kit/gates/close.sh" committed-first shipped "delivered" >/dev/null || {
    echo "FAIL: the commit that contains the reviewed source was refused"; exit 1; }
  # second feature: an edit after the review of ALREADY COMMITTED work is drift
  mkdir -p .sdlc/work/committed-two
  echo goal > .sdlc/work/committed-two/intent.md
  echo ev > .sdlc/work/committed-two/evidence.md
  git add -A .; git commit -qm "chore: archive + next feature"
  "$kit/gates/approve.sh" ship .sdlc/work/committed-two/evidence.md --delegated >/dev/null
  printf 'echo HACKED\n' > late.sh          # never reviewed by anyone
  sha=$(git rev-parse HEAD)
  cat > .sdlc/work/committed-two/delivery.md <<EOF
# Delivery: committed-two
- Target: local
- Source: $sha
- Verified-by: sh late.sh
- Evidence: v2
- Confirmed: yes
EOF
  out=$("$kit/gates/close.sh" committed-two shipped "done" 2>&1) && {
    echo "FAIL: post-review edit of committed work closed as shipped (B1)"; exit 1; }
  case "$out" in (*"the source changed after the ship review"*) ;;
    (*) echo "FAIL: committed-work drift message wrong: $out"; exit 1;; esac
  out=$("$kit/gates/status.sh" committed-two 2>&1)
  case "$out" in (*"SOURCE DRIFT"*) ;; (*) echo "FAIL: status hides the source drift: $out"; exit 1;; esac
  case "$out" in (*"NOT CLOSEABLE"*) ;; (*) echo "FAIL: status calls an uncloseable delivery closeable: $out"; exit 1;; esac
  out=$("$kit/gates/check-gate.sh" ship .sdlc/work/committed-two/evidence.md 2>&1) && {
    echo "FAIL: ship gate stayed open over drifted source"; exit 1; }
  case "$out" in (*"GATE CLOSED"*) ;; (*) echo "FAIL: ship gate drift message wrong: $out"; exit 1;; esac
) || exit 1
echo "ok: work committed before the review is bound; a Source commit must contain it; status agrees"

echo "SELFTEST PASS"
