#!/usr/bin/env bash
# selftest.sh — the kit's one smoke test: scripts parse, skill metadata is valid,
# and the gate mechanics that make the loop trustworthy still hold. Runs in
# seconds in a throwaway git repo; touches nothing outside it.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cd "$tmp"; git init -q .
fail() { echo "FAIL: $*"; exit 1; }
closed() { "$kit/gates/check-gate.sh" "$1" "$2" >/dev/null 2>&1 && fail "$3" || true; }

# 1. every script parses; scripts are LF-only (a CRLF checkout breaks bash on Windows)
for f in "$kit"/init.sh "$kit"/gates/*.sh "$kit"/tools/*.sh; do bash -n "$f" || fail "syntax: $f"; done
crlf=$(find "$kit" \( -name '*.sh' -o -name '*.py' \) -not -path '*/.git/*' -exec awk '/\r/{print FILENAME}' {} + | sort -u)
[ -z "$crlf" ] || fail "CRLF line endings: $crlf"
echo "ok: scripts parse and are LF-only"

# 2. every SKILL.md frontmatter has name and description (guards the 'Triggers:' colon trap)
for p in "$kit"/SKILL.md "$kit"/skills/*/SKILL.md; do
  head -1 "$p" | grep -qx -- '---' || fail "no frontmatter: $p"
  awk '/^---$/{n++; next} n==1' "$p" | grep -q '^name: ' || fail "no name: $p"
  awk '/^---$/{n++; next} n==1' "$p" | grep -q '^description: "' || fail "description must be a quoted string: $p"
done
echo "ok: SKILL.md frontmatter"

# 3. a gate opens only for the approved bytes, and an upstream edit closes the gate below it
"$kit/init.sh" . >/dev/null
d=.sdlc/work/feat-a; mkdir -p "$d"; a=$d/intent.md; s=$d/spec.md
echo "goal" > "$a"
closed intent "$a" "gate open without approval"
"$kit/gates/approve.sh" intent "$a" --delegated >/dev/null
"$kit/gates/check-gate.sh" intent "$a" >/dev/null || fail "gate closed after approval"
echo "spec" > "$s"; "$kit/gates/approve.sh" spec "$s" --delegated >/dev/null
echo "edit" >> "$a"
closed intent "$a" "gate stayed open after the approved artifact changed"
closed spec "$s" "spec gate survived an upstream intent edit"
"$kit/gates/approve.sh" "../../etc/pwn" "$a" >/dev/null 2>&1 && fail "path-traversal stage name accepted"
echo "ok: gates bind content and upstream; bad stage names refused"

# 4. lazymode moves who decides, never beyond the configured level
d=.sdlc/work/feat-b; mkdir -p "$d"; echo spec > "$d/spec.md"; echo plan > "$d/plan.md"
sed -i.bak 's/^lazymode: .*/lazymode: 1/' .sdlc/config.md && rm -f .sdlc/config.md.bak
"$kit/gates/approve.sh" spec "$d/spec.md" --lazy --review r >/dev/null 2>&1 && fail "lazy spec approval accepted at lazymode 1"
"$kit/gates/approve.sh" plan "$d/plan.md" --lazy >/dev/null 2>&1 && fail "lazy approval accepted without --review"
"$kit/gates/approve.sh" plan "$d/plan.md" --lazy --review "read the plan" >/dev/null || fail "lazy plan approval refused at lazymode 1"
echo "ok: lazymode enforced"

# 5. close: dead-end needs a lesson; shipped needs a ship approval and a confirmed delivery
"$kit/gates/close.sh" feat-b dead-end "tried" >/dev/null 2>&1 && fail "dead-end closed without a lesson"
d=.sdlc/work/feat-c; mkdir -p "$d"; echo goal > "$d/intent.md"; echo evidence > "$d/evidence.md"
"$kit/gates/close.sh" feat-c shipped "done" >/dev/null 2>&1 && fail "shipped without a ship approval"
"$kit/gates/approve.sh" ship "$d/evidence.md" >/dev/null
"$kit/gates/close.sh" feat-c shipped "done" >/dev/null 2>&1 && fail "shipped without a delivery record"
src=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/feat-c.ship.approval)
printf -- '- Target: local\n- Source: worktree:%s\n- Verified-by: selftest\n- Evidence: ok\n- Confirmed: yes\n' "$src" > "$d/delivery.md"
"$kit/gates/close.sh" feat-c shipped "done" >/dev/null || fail "valid delivery refused"
[ -f .sdlc/archive/feat-c/CLOSED ] || fail "shipped feature not archived"
echo "ok: close requires its proof"

# 6. knowledge retrieval files features under their own product area — under a
#    UTF-8 locale too (macOS awk once collated Hangul menu paths as equal)
mkdir -p .sdlc/work/f1 .sdlc/work/f2 .sdlc/memory/areas
printf -- '- Area: 명단 > 내보내기\n' > .sdlc/work/f1/summary.md
printf -- '- Area: 결제 > 환불\n' > .sdlc/work/f2/summary.md
printf -- '# Area: 명단 > 내보내기\n- Menu: 명단 > 내보내기\n## Business rules (정책)\n- P1: 현재 학기만\n' > .sdlc/memory/areas/roster.md
LC_ALL=en_US.UTF-8 bash "$kit/tools/kb.sh" index >/dev/null
grep -qF '| [명단 > 내보내기](memory/areas/roster.md) | 1 | — | f1 |' .sdlc/README.md || fail "area table wrong: $(grep '명단' .sdlc/README.md)"
out=$(bash "$kit/tools/kb.sh" show "명단 > 내보내기")
case "$out" in (*"P1: 현재 학기만"*) ;; (*) fail "show <menu path> did not print the rule: $out";; esac
#    a page named by its menu path (" > " → " - "), reader first: plain rules on
#    top, evidence in <details> at the bottom — evidence lines do not count as rules
mkdir -p .sdlc/work/f3; printf -- '- Area: 교사 > 학생 > 학급 분석\n' > .sdlc/work/f3/summary.md
printf -- '%s\n' '# Area: 교사 > 학생 > 학급 분석' '- Menu: 교사 > 학생 > 학급 분석' '## Business rules (정책)' \
  '- P1: 자기 학급만 본다' '- P2: 전학생은 빠진다' '- ~~P3: 지난 학기도 보인다~~' '## History' '- 2026-09-01 f3 — 참여율 추가' \
  '<details>' '<summary>근거 · 코드 위치 (개발자용)</summary>' '' '- Where: ClassAnalysis#get' \
  '- P1 — source: 기획서 · set by f3' '- P3 — retired 2026-09-01 by f3: 정책 변경' '' '</details>' > ".sdlc/memory/areas/교사 - 학생 - 학급 분석.md"
LC_ALL=en_US.UTF-8 bash "$kit/tools/kb.sh" index >/dev/null
grep -qF '| [교사 > 학생 > 학급 분석](memory/areas/교사%20-%20학생%20-%20학급%20분석.md) | 2 | 2026-09-01 | f3 |' .sdlc/README.md \
  || fail "menu-named page row wrong: $(grep '교사' .sdlc/README.md)"
for q in "교사 > 학생 > 학급 분석" "교사 - 학생 - 학급 분석"; do
  out=$(bash "$kit/tools/kb.sh" show "$q") || fail "show '$q' found no page"
  case "$out" in (*"P1: 자기 학급만"*"근거 · 코드 위치 (개발자용):"*"Where: ClassAnalysis#get"*) ;; (*) fail "show '$q' not reader first: $out";; esac
done
bash "$kit/tools/kb.sh" show "../areas/roster" >/dev/null 2>&1 && fail "area lookup followed a path"
#    the Obsidian form of the evidence block: a folded callout, lines prefixed "> "
printf -- '%s\n' '- Menu: 학생 > 과제' '## Business rules (정책)' '- P1: 마감 후 제출 불가' '## History' '- 2026-09-02 f4 — 마감 표시' \
  '> [!info]- 근거 · 코드 위치 (개발자용)' '> - Where: HomeworkApi#submit' '> - P1 — source: 기획서 · set by f4' '> - P2: 콜론 줄도 규칙이 아니다' \
  > ".sdlc/memory/areas/학생 - 과제.md"
LC_ALL=en_US.UTF-8 bash "$kit/tools/kb.sh" index >/dev/null
grep -qF '| [학생 > 과제](memory/areas/학생%20-%20과제.md) | 1 | 2026-09-02 | — |' .sdlc/README.md || fail "callout page row wrong: $(grep '과제' .sdlc/README.md)"
out=$(bash "$kit/tools/kb.sh" show "학생 > 과제") || fail "show found no callout page"
case "$out" in (*"P1: 마감 후"*"History:"*"근거 · 코드 위치 (개발자용):"*"  - Where: HomeworkApi#submit"*) ;; (*) fail "callout evidence not read last: $out";; esac
case "$out" in (*"> -"*) fail "callout prefix printed: $out";; esac
fns=$(sed -n -e '/^kb_field() {/,/^}/p' -e '/^kb_get() {/,/^}/p' "$kit/tools/kb.sh")
where=$(eval "$fns"; kb_get ".sdlc/memory/areas/학생 - 과제.md" Where)
[ "$where" = "HomeworkApi#submit" ] || fail "kb_get did not read Where inside the callout: '$where'"
echo "ok: knowledge by product area"

echo "SELFTEST PASS"
