#!/usr/bin/env bash
# selftest.sh — proves the gate mechanism works: approve→open, tamper→closed.
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

# 3. tamper → gate closed
echo "sneaky edit" >> "$a"
if "$kit/gates/check-gate.sh" intent "$a" >/dev/null 2>&1; then
  echo "FAIL: gate open after tamper"; exit 1; fi
echo "ok: tamper invalidates approval"

# 4. stage name injection rejected
if "$kit/gates/approve.sh" "../../etc/pwn" "$a" >/dev/null 2>&1; then
  echo "FAIL: path-traversal stage name accepted"; exit 1; fi
echo "ok: invalid stage name rejected"

# 5. artifact outside a feature dir rejected
echo x > bare.md
if "$kit/gates/approve.sh" intent bare.md >/dev/null 2>&1; then
  echo "FAIL: bare-path artifact accepted (slug '.')"; exit 1; fi
echo "ok: bare-path artifact rejected"

# 6. corrupt approval record → closed WITH a message (never silent)
"$kit/gates/approve.sh" intent "$a" >/dev/null   # re-approve tampered file
grep -v '^sha256: ' .sdlc/approvals/feat-a.intent.approval > t && mv t .sdlc/approvals/feat-a.intent.approval
out=$("$kit/gates/check-gate.sh" intent "$a" 2>&1) && { echo "FAIL: gate open on corrupt record"; exit 1; }
case "$out" in (*"GATE CLOSED"*) echo "ok: corrupt record closed with message";;
  (*) echo "FAIL: corrupt record closed SILENTLY"; exit 1;; esac

# 7. --delegated: works at any stage, always recorded
"$kit/gates/approve.sh" intent "$a" --delegated >/dev/null
grep -q '^mode: delegated-chat' .sdlc/approvals/feat-a.intent.approval || { echo "FAIL: delegated mode not recorded"; exit 1; }
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

echo "SELFTEST PASS"
