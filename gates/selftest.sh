#!/usr/bin/env bash
# selftest.sh — proves the gate mechanism works: approve→open, unapproved→closed.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; mkdir -p .sdlc/work/feat-a

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

# 3. edit after approval → gate STAYS open (approvals are markers, not hashes)
echo "later edit" >> "$a"
"$kit/gates/check-gate.sh" intent "$a" >/dev/null || { echo "FAIL: gate closed by a post-approval edit"; exit 1; }
echo "ok: post-approval edit does not close the gate"

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

# 7. --delegated: works at any stage, always recorded (with the agent runner)
"$kit/gates/approve.sh" intent "$a" --delegated >/dev/null
grep -q '^mode: delegated-chat' .sdlc/approvals/feat-a.intent.approval || { echo "FAIL: delegated mode not recorded"; exit 1; }
grep -q '^runner: agent' .sdlc/approvals/feat-a.intent.approval || { echo "FAIL: agent runner not recorded for delegated"; exit 1; }
"$kit/gates/approve.sh" spec "$a" --delegated >/dev/null
grep -q '^mode: delegated-chat' .sdlc/approvals/feat-a.spec.approval || { echo "FAIL: delegated mode not recorded for spec"; exit 1; }
echo "ok: delegated approval recorded at any stage"

# 8. close mechanism: dead-end blocked without lesson, allowed with, idempotent-refused
mkdir -p .sdlc/memory/lessons
if "$kit/gates/close.sh" feat-a dead-end "test reason" >/dev/null 2>&1; then
  echo "FAIL: dead-end close allowed without a lesson"; exit 1; fi
echo "lesson" > .sdlc/memory/lessons/2020-01-01-feat-a.md
"$kit/gates/close.sh" feat-a dead-end "test reason" >/dev/null
grep -q '^state: dead-end' .sdlc/work/feat-a/CLOSED || { echo "FAIL: CLOSED record wrong"; exit 1; }
if "$kit/gates/close.sh" feat-a abandoned "again" >/dev/null 2>&1; then
  echo "FAIL: double close allowed"; exit 1; fi
echo "ok: close requires lesson, records state, refuses double close"

# 9. handed-off: blocked without external reference, allowed with key/URL, no lesson required
mkdir -p .sdlc/work/feat-b
if "$kit/gates/close.sh" feat-b handed-off "sent to another team" >/dev/null 2>&1; then
  echo "FAIL: handed-off close allowed without an external reference"; exit 1; fi
"$kit/gates/close.sh" feat-b handed-off "tracking continues in A20-1240" >/dev/null
grep -q '^state: handed-off' .sdlc/work/feat-b/CLOSED || { echo "FAIL: handed-off state not recorded"; exit 1; }
grep -q '^reason: tracking continues in A20-1240' .sdlc/work/feat-b/CLOSED || { echo "FAIL: handed-off reference not recorded"; exit 1; }
echo "ok: handed-off requires and records external reference"

# 10. shell scripts are LF-only — a CRLF checkout (Git for Windows default
#     core.autocrlf=true, without .gitattributes) makes bash reject every script
crlf=$(find "$kit" -name '*.sh' -not -path '*/.git/*' -exec awk '/\r/{print FILENAME}' {} + | sort -u)
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
case "$out" in (*"[CLOSED: dead-end]"*) ;; (*) echo "FAIL: closed feature not rendered"; exit 1;; esac
echo "ok: status.sh renders empty, tiered, approved, and closed states"

# 14. no upstream chaining: editing intent after spec approval keeps the spec gate open
"$kit/gates/check-gate.sh" spec .sdlc/work/feat-d/spec.md >/dev/null
echo "tweak" >> .sdlc/work/feat-d/intent.md
"$kit/gates/check-gate.sh" spec .sdlc/work/feat-d/spec.md >/dev/null || { echo "FAIL: spec gate closed by an upstream edit"; exit 1; }
echo "ok: upstream edit does not close the downstream gate"

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
if "$kit/gates/approve.sh" plan "$fp" --lazy >/dev/null 2>&1; then
  echo "FAIL: lazy approval accepted without lazymode in config"; exit 1; fi
printf 'lazymode: 1\n' > .sdlc/config.md
if "$kit/gates/approve.sh" spec "$fs" --lazy >/dev/null 2>&1; then
  echo "FAIL: lazy spec approval accepted at lazymode 1"; exit 1; fi
"$kit/gates/approve.sh" plan "$fp" --lazy >/dev/null
grep -q '^mode: lazy' .sdlc/approvals/feat-f.plan.approval || { echo "FAIL: lazy mode not recorded"; exit 1; }
grep -q '^runner: agent' .sdlc/approvals/feat-f.plan.approval || { echo "FAIL: agent runner not recorded for lazy"; exit 1; }
printf 'lazymode: 4\n' > .sdlc/config.md
"$kit/gates/approve.sh" intent "$fi2" --lazy >/dev/null
"$kit/gates/approve.sh" spec "$fs" --lazy >/dev/null
echo "evidence" > .sdlc/work/feat-f/evidence.md   # ship PENDING so status must hint --lazy
out=$("$kit/gates/status.sh" feat-f) || { echo "FAIL: status.sh crashed with lazymode set"; exit 1; }
case "$out" in (*"lazymode: 4"*) ;; (*) echo "FAIL: lazymode not shown in status"; exit 1;; esac
case "$out" in (*"· lazy"*) ;; (*) echo "FAIL: lazy approval mode not shown in status"; exit 1;; esac
case "$out" in (*"--lazy"*) ;; (*) echo "FAIL: pending ship gate should hint --lazy at lazymode 4"; exit 1;; esac
if "$kit/gates/approve.sh" build "$fp" --lazy >/dev/null 2>&1; then
  echo "FAIL: --lazy accepted for an unknown stage"; exit 1; fi
printf 'lazymode: 10\n' > .sdlc/config.md   # out of range must fail CLOSED
if "$kit/gates/approve.sh" ship .sdlc/work/feat-f/evidence.md --lazy >/dev/null 2>&1; then
  echo "FAIL: out-of-range lazymode failed OPEN"; exit 1; fi
printf 'lazymode: 4\r\n' > .sdlc/config.md  # CRLF-saved config must still parse
"$kit/gates/approve.sh" ship .sdlc/work/feat-f/evidence.md --lazy >/dev/null || { echo "FAIL: CRLF lazymode config not parsed"; exit 1; }
echo "ok: lazy approval enforces the lazymode level, range, and CRLF, is recorded, and shows in status"

echo "SELFTEST PASS"
