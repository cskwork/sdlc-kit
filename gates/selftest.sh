#!/usr/bin/env bash
# selftest.sh — the kit's one smoke test: scripts parse, skill metadata is valid,
# and the gate mechanics that make the loop trustworthy still hold. Runs in
# throwaway temp dirs and touches nothing outside them. Its sections are
# independent, each in its own dir, so they run side by side (see the end);
# their output is printed in order.
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'wait; rm -rf "$tmp"' EXIT   # wait: sections still running
# verify.sh probes python3 on every call, and a pyenv/asdf shim costs a quarter
# second each time: link the real interpreter first (Windows paths stay as found)
py=$(python3 -c 'import os, sys; print("" if os.name == "nt" else sys.executable)' 2>/dev/null) || py=""
[ -z "$py" ] || { mkdir "$tmp/bin"; ln -s "$py" "$tmp/bin/python3"; PATH="$tmp/bin:$PATH"; }
fail() { echo "FAIL: $*"; exit 1; }
has() { case "$1" in (*"$2"*) ;; (*) fail "$3: $1";; esac; }
# evidence.md carrying the three verifier lens verdicts (templates/evidence.md)
lens() { printf '%s\n' '### E2E' 'VERDICT: PASS' '### Side effects   <!-- c -->' '- VERDICT: PASS' '### Intent match' 'VERDICT: PASS' > "$1"; }
closed() { "$kit/gates/check-gate.sh" "$1" "$2" >/dev/null 2>&1 && fail "$3" || true; }
V="$kit/tools/verify.sh"; A="$kit/gates/approve.sh"; C="$kit/gates/close.sh"
intent() { mkdir -p ".sdlc/work/$1"; printf -- '- Track: compact\n## Success criteria\n- [ ] O1: app says new\n' > ".sdlc/work/$1/intent.md"; }
commit() { git add -A; git -c user.email=t@t.invalid -c user.name=t commit -qm base; }
# Each section runs in its own dir $t (its cwd at the start).

basics() {
git init -q .
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
d=.sdlc/work/feat-c; mkdir -p "$d"; echo goal > "$d/intent.md"; lens "$d/evidence.md"
"$kit/gates/close.sh" feat-c shipped "done" >/dev/null 2>&1 && fail "shipped without a ship approval"
#    ship needs every lens VERDICT in evidence.md, or the rule-5 gap line
sed '$d' "$d/evidence.md" > "$t/ev"; printf 'VERDICT: <PASS>\n' >> "$t/ev"; cp "$t/ev" "$d/evidence.md"
out=$("$kit/gates/approve.sh" ship "$d/evidence.md" 2>&1) && fail "ship approved with the Intent match VERDICT missing"
has "$out" "no VERDICT: line under ### Intent match." "the missing lens not named alone"
printf 'no independent verification available: no subagent in this harness\n' > "$d/evidence.md"
"$kit/gates/approve.sh" ship "$d/evidence.md" >/dev/null || fail "ship refused over the rule-5 gap line"
lens "$d/evidence.md"
out=$("$kit/gates/approve.sh" ship "$d/evidence.md")
case "$out" in (*"not machine-checked"*) ;; (*) fail "ship without a verification recipe gave no note: $out";; esac
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
#    a page named by its menu path (" > " → " - "), reader first, in tables:
#    rules counted from rows above the evidence block (evidence and retired rows
#    are not), last change from the History table, header words free
mkdir -p .sdlc/work/f3; printf -- '- Area: 교사 > 학생 > 학급 분석\n' > .sdlc/work/f3/summary.md
printf -- '%s\n' '# Area: 교사 > 학생 > 학급 분석' '- Menu: 교사 > 학생 > 학급 분석' '## Business rules (정책)' '| # | 정책 |' '|---|---|' \
  '| P1 | 자기 학급만 본다 |' '| P2 | 전학생은 빠진다 |' '| ~~P3~~ | ~~지난 학기도 보인다~~ |' '| P4 | <rule> |' \
  '## History' '| 날짜 | 작업 | 바뀐 점 |' '|---|---|---|' '| 2026-09-01 | f3 | 참여율 추가 |' '| 2026-08-01 | f1 | 처음 |' \
  '<details>' '<summary>근거 · 코드 위치 (개발자용)</summary>' '' '- Where: ClassAnalysis#get' '' '| # | 출처 | 작업 | 검증 |' '|---|---|---|---|' \
  '| P1 | 기획서 | f3 | code — 2026-09-01 |' '| P3 | retired 2026-09-01 by f3: 정책 변경 | f3 | human |' '' '</details>' > ".sdlc/memory/areas/교사 - 학생 - 학급 분석.md"
#    the Obsidian form of the evidence block: a folded callout, lines prefixed "> "
printf -- '%s\n' '- Menu: 학생 > 과제' '## Business rules (정책)' '| # | Rule |' '|---|---|' '| P1 | 마감 후 제출 불가 |' \
  '## History' '| Date | Feature | What changed |' '|---|---|---|' '| 2026-09-02 | f4 | 마감 표시 |' \
  '> [!info]- 근거 · 코드 위치 (개발자용)' '> - Where: HomeworkApi#submit' '>' '> | # | Source | Set by | Verified |' '> |---|---|---|---|' \
  '> | P1 | 기획서 | f4 | test — 2026-09-02 |' '> | P2 | 증거 행은 규칙이 아니다 | f4 | — |' > ".sdlc/memory/areas/학생 - 과제.md"
LC_ALL=en_US.UTF-8 bash "$kit/tools/kb.sh" index >/dev/null
grep -qF '| [교사 > 학생 > 학급 분석](memory/areas/교사%20-%20학생%20-%20학급%20분석.md) | 2 | 2026-09-01 | f3 |' .sdlc/README.md \
  || fail "menu-named table page row wrong: $(grep '교사' .sdlc/README.md)"
grep -qF '| [학생 > 과제](memory/areas/학생%20-%20과제.md) | 1 | 2026-09-02 | — |' .sdlc/README.md || fail "callout page row wrong: $(grep '과제' .sdlc/README.md)"
for q in "교사 > 학생 > 학급 분석" "교사 - 학생 - 학급 분석"; do
  out=$(bash "$kit/tools/kb.sh" show "$q") || fail "show '$q' found no page"
  case "$out" in (*"| P1 | 자기 학급만"*"| 2026-09-01 | f3 |"*"근거 · 코드 위치 (개발자용):"*"Where: ClassAnalysis#get"*"| P3 | retired"*) ;; (*) fail "show '$q' not reader first: $out";; esac
  case "$out" in (*"<rule>"*) fail "show printed a placeholder row: $out";; esac
done
out=$(bash "$kit/tools/kb.sh" show "학생 > 과제") || fail "show found no callout page"
case "$out" in (*"| P1 | 마감 후"*"History:"*"근거 · 코드 위치 (개발자용):"*"  - Where: HomeworkApi#submit"*"  | P1 | 기획서 | f4 |"*) ;; (*) fail "callout evidence not read last: $out";; esac
printf '%s\n' "$out" | grep -q '^ *>' && fail "callout prefix printed: $out"
fns=$(sed -n -e '/^kb_field() {/,/^}/p' -e '/^kb_get() {/,/^}/p' "$kit/tools/kb.sh")
where=$(eval "$fns"; kb_get ".sdlc/memory/areas/학생 - 과제.md" Where)
[ "$where" = "HomeworkApi#submit" ] || fail "kb_get did not read Where inside the callout: '$where'"
bash "$kit/tools/kb.sh" show "../areas/roster" >/dev/null 2>&1 && fail "area lookup followed a path"
echo "ok: knowledge by product area"
}

# 7. verification: the receipt gates ship; a baseline separates pre-existing
#    failures from regressions and vacuous tests; every requirement is covered;
#    per-feature recipes merge; forbidden hosts and credentials never get through.
#    Three sections, each on its own copy of this fixture (repo $t/v):
vrepo() {
  mkdir v; cd v; git init -q .
  "$kit/init.sh" . >/dev/null
  printf 'old\n' > app.txt; printf 'exit 1\n' > lint.sh; printf '! grep -q TODO app.txt\n' > style.sh
  commit
  printf 'new\n' > app.txt   # the change: uncommitted, so the default base is HEAD
  printf '%s\n' 'echo "Authorization: Bearer abc123 password=hunter2 eyJhbGciOiJ.eyJzdWIiOiIx.c2ln"' 'grep -q new app.txt' > test.sh
  printf '%s\n' 'profile: advisory' 'test_paths: tests/*' 'forbidden_hosts: prod.example.com' \
    'check: lint | lint | sh lint.sh' 'check: style | lint | sh style.sh' > .sdlc/verify.md
}
verify_ship() {
vrepo
intent vf; fr=.sdlc/work/vf/verify.md
out=$("$V" check vf) && fail "a requirement with no check verified"
has "$out" "VERIFY uncovered" "O1 with no check not uncovered"; has "$out" "O1" "uncovered did not name O1"
printf 'gap: O1 | proven by hand\n' > "$fr"
out=$("$V" coverage vf) || fail "a gap line in the feature recipe did not clear coverage: $out"
has "$out" "gap: proven by hand" "coverage did not list the gap"
printf 'check: lint | unit | sh test.sh\n' > "$fr"
out=$("$V" run vf 2>&1) && fail "duplicate id across project and feature recipes accepted"
has "$out" "share the id 'lint'" "duplicate id not named"
printf 'check: O1 | unit | touch ran; echo https://Prod.Example.com/x\n' > "$fr"
rc=0; out=$("$V" run vf 2>&1) || rc=$?; [ "$rc" = 2 ] || fail "forbidden host not refused with exit 2 (got $rc)"
has "$out" "forbidden host" "forbidden host not named"; [ ! -e ran ] || fail "a forbidden command ran"
printf 'check: O1 | unit | sh test.sh\n' > "$fr"
"$V" baseline vf >/dev/null || fail "baseline failed"
out=$("$V" run vf) || fail "a pre-existing lint failure (or the feature recipe's O1) failed the run: $out"
has "$out" "pre-existing" "VERIFY ok did not list the pre-existing failure"
has "$out" "at base HEAD @" "VERIFY ok did not name the base the pre-existing failure was seen at"
out=$("$V" check vf) || fail "check after an ok run: $out"
has "$out" "at base HEAD @" "the ok state did not name the base the pre-existing failure was seen at"
grep -q '^check: lint | lint | 1 | .* | pre-existing$' .sdlc/work/vf/verify-receipt.md || fail "lint not labelled pre-existing in the receipt"
log=.sdlc/work/vf/scratch/verify/O1.log
grep -q '\[REDACTED\]' "$log" || fail "no redaction in the check log"
grep -qE 'hunter2|abc123|eyJhbGci' "$log" && fail "a credential survived in the check log: $(cat "$log")"
lens .sdlc/work/vf/evidence.md
"$A" ship .sdlc/work/vf/evidence.md >/dev/null || fail "ship refused over an ok receipt"
src=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/vf.ship.approval)
printf -- '- Target: local\n- Source: worktree:%s\n- Verified-by: selftest\n- Evidence: ok\n- Confirmed: yes\n' "$src" > .sdlc/work/vf/delivery.md
cp .sdlc/verify.md "$t/recipe.bak"; echo '# edited after ship' >> .sdlc/verify.md
out=$("$C" vf shipped "done" 2>&1) && fail "closed shipped over a stale receipt"
has "$out" "stale" "close did not say the receipt is stale"
out=$("$kit/gates/check-gate.sh" ship .sdlc/work/vf/evidence.md 2>&1) && fail "check-gate ship OPEN over a stale receipt: $out"
has "$out" "GATE CLOSED: verification stale" "check-gate ship did not name the stale receipt"
cp "$t/recipe.bak" .sdlc/verify.md
echo TODO >> app.txt
out=$("$V" check vf) && fail "a receipt stayed ok after the source changed"
has "$out" "VERIFY stale: the source changed" "a source edit did not make the receipt stale"
out=$("$V" run vf) && fail "a new lint failure passed"
has "$out" "VERIFY fail" "a new failure next to a pre-existing one was not a fail"
grep -q '^check: style | lint | 1 | .* | pre-existing$' .sdlc/work/vf/verify-receipt.md && fail "a new failure labelled pre-existing"
out=$("$A" ship .sdlc/work/vf/evidence.md 2>&1) && fail "ship approved over a failed receipt"
has "$out" "verification fail" "ship refusal did not say why"
[ ! -f .sdlc/approvals/vf.ship.approval.history ] || fail "a refused ship approval superseded the record"
printf 'new\n' > app.txt   # back to the reviewed source
"$V" run vf >/dev/null || fail "the reviewed source no longer verifies"
out=$("$C" vf shipped "done") || fail "close shipped refused over an ok receipt: $out"
grep -q '^verify_state: ok$' .sdlc/archive/vf/CLOSED || fail "CLOSED does not record the verification state"
echo "ok: verification gates ship; baseline, pre-existing, stale, redaction, coverage, feature recipes, forbidden hosts"
}
#    must-fail-on-base without a baseline, vacuous; flaky
verify_vacuous() {
vrepo
intent vm; mkdir -p tests; printf 'exit 0\n' > tests/o1.sh
printf 'check: O1 | unit | sh tests/o1.sh | must-fail-on-base\n' > .sdlc/work/vm/verify.md
out=$("$V" check vm) || true; has "$out" "tools/verify.sh baseline vm" "must-fail-on-base without a baseline did not ask for one"
"$V" baseline vm >/dev/null && fail "a check that passes at base was not vacuous"
out=$("$V" check vm) || true; has "$out" "VERIFY vacuous" "vacuous state not reported"
printf 'exit 0\n' > lint.sh
#    a runtime check that fails, then passes on its one re-run, is flaky and refuses ship
intent vk; printf 'check: O1 | runtime | [ -e .sdlc/work/vk/ran ] || { touch .sdlc/work/vk/ran; exit 3; }\n' > .sdlc/work/vk/verify.md
out=$("$V" run vk) && fail "a check that failed, then passed on a re-run, verified"
has "$out" "VERIFY flaky" "a fail-then-pass check not flaky"; has "$out" "O1" "flaky did not name the check"
grep -q '^check: O1 | runtime | 3 | .* | flaky' .sdlc/work/vk/verify-receipt.md || fail "the receipt did not keep the first exit and the flaky label"
lens .sdlc/work/vk/evidence.md
out=$("$A" ship .sdlc/work/vk/evidence.md 2>&1) && fail "ship approved over a flaky check"
has "$out" "verification flaky" "the flaky refusal did not say why"
echo "ok: must-fail-on-base needs a baseline and a failing base; flaky refuses ship"
}
#    strict: runtime proof, --accept-gap, variants; close honours only the accepted gap
verify_strict() {
vrepo
printf 'exit 0\n' > lint.sh
sed 's/^profile: advisory/profile: strict/' .sdlc/verify.md > "$t/r.tmp"; cat "$t/r.tmp" > .sdlc/verify.md
intent vg; "$A" intent .sdlc/work/vg/intent.md --delegated >/dev/null   # so the driver reaches delivery below
printf 'gap: O1 | no runtime environment in this fixture\n' > .sdlc/work/vg/verify.md; lens .sdlc/work/vg/evidence.md
out=$("$V" run vg) && fail "strict without runtime evidence passed"
has "$out" "VERIFY blocked" "strict without runtime evidence not blocked"
sed 's/^lazymode: .*/lazymode: 3/' .sdlc/config.md > "$t/c.tmp"; cat "$t/c.tmp" > .sdlc/config.md
out=$("$A" ship .sdlc/work/vg/evidence.md --lazy --review r 2>&1) && fail "--lazy ship approved over a blocked verification without --accept-gap"
has "$out" "verification blocked" "the blocked refusal did not say why"
has "$out" "re-run with --accept-gap" "the blocked refusal did not name --accept-gap"
for bad in "$(printf 'yes\nverify_state: ok')" "$(printf 'yes\rno')" "   "; do
  "$A" ship .sdlc/work/vg/evidence.md --accept-gap "$bad" >/dev/null 2>&1 && fail "--accept-gap took a multi-line or blank value"
done
"$A" ship .sdlc/work/vg/evidence.md --accept-gap "human: ship without runtime proof" >/dev/null || fail "--accept-gap refused"
grep -q '^verify_gap_accepted: human: ship without runtime proof$' .sdlc/approvals/vg.ship.approval || fail "accepted gap not recorded"
#    strict: a unit check does not cover a requirement, and no --accept-gap clears that;
#    each requirement needs happy/boundary/negative variants, or a gap line per variant
intent vn; printf 'check: O1.boundary | unit | true\n' > .sdlc/work/vn/verify.md; echo evidence > .sdlc/work/vn/evidence.md
out=$("$A" ship .sdlc/work/vn/evidence.md --accept-gap "human: fine" 2>&1) && fail "--accept-gap cleared a strict no-runtime requirement"
has "$out" "verification uncovered" "strict no-runtime not uncovered"
printf 'check: O1.happy | runtime | true\n' >> .sdlc/work/vn/verify.md
out=$("$V" check vn) && fail "strict verified with O1.negative missing"
has "$out" "VERIFY uncovered" "strict missing variant not uncovered"; has "$out" "O1.negative" "uncovered did not name O1.negative"
printf 'gap: O1.negative | no invalid input exists for this fixture\n' >> .sdlc/work/vn/verify.md
out=$("$V" coverage vn) || fail "a variant gap line did not clear strict coverage: $out"
#    close honours the gap accepted at ship, and only that one: a different
#    blocked gap is refused by close and the gate, and the driver sends it to the human
src=$(awk '/^code_digest: /{print $2}' .sdlc/approvals/vg.ship.approval)
printf -- '- Target: local\n- Source: worktree:%s\n- Verified-by: selftest\n- Evidence: ok\n- Confirmed: yes\n' "$src" > .sdlc/work/vg/delivery.md
cp .sdlc/verify.md "$t/strict.bak"; cp .sdlc/work/vg/verify-receipt.md "$t/receipt.bak"
printf 'cleanup: false\n' >> .sdlc/verify.md
"$V" run vg >/dev/null 2>&1 && fail "a failed cleanup verified"
out=$("$C" vg shipped "done" 2>&1) && fail "closed shipped over a different gap than the one accepted at ship"
has "$out" "it is blocked" "close did not say the verification is blocked"; has "$out" "a different one" "close did not name the gap accepted at ship"
out=$("$kit/gates/check-gate.sh" ship .sdlc/work/vg/evidence.md 2>&1) && fail "check-gate ship OPEN over an unaccepted gap"
has "$out" "GATE CLOSED: verification blocked" "check-gate did not name the unaccepted gap"
out=$(bash "$kit/tools/auto.sh" status --json vg)
has "$out" '"stage": "delivery"' "auto.sh did not reach delivery"; has "$out" '"status": "blocked"' "auto.sh did not block on the unaccepted gap"
has "$out" 'approve.sh ship .sdlc/work/vg/evidence.md --accept-gap' "auto.sh did not route the unaccepted gap to the human's --accept-gap"
cp "$t/strict.bak" .sdlc/verify.md; cp "$t/receipt.bak" .sdlc/work/vg/verify-receipt.md   # the ship-time gap again
out=$("$C" vg shipped "done") || fail "close did not honour the gap accepted at ship: $out"
grep -q '^verify_state: blocked$' .sdlc/archive/vg/CLOSED || fail "CLOSED does not record the blocked state"
grep -q '^verify_gap_accepted: human: ship without runtime proof$' .sdlc/archive/vg/CLOSED || fail "CLOSED does not record the gap accepted at ship"
grep -q '^verify_gap_accepted_at: ship$' .sdlc/archive/vg/CLOSED || fail "CLOSED does not say where the gap was accepted"
echo "ok: strict needs runtime proof; --accept-gap binds one gap, honoured by close"
}

# 8. what verification reads: the template as shipped, requirement ids as people
#    write them, and nothing it cannot read; a baseline that cannot be gamed and
#    that cleans up after itself; no source identity without git
verify_reads() {
mkdir w; cd w; git init -q .
"$kit/init.sh" . >/dev/null
intent t1; fr=.sdlc/work/t1/verify.md
#    the template copied verbatim with its placeholders filled is usable, trailing
#    comments included; a BOM does not hide profile: strict
{ printf '\357\273\277'; sed -e 's/^profile: advisory/profile: strict  # the real run is required/' \
    -e '/^forbidden_hosts:/s/<[^>]*>/prod.invalid/' -e '/^#/!s/<[^>]*>/true/' "$kit/templates/verify.md"; } > .sdlc/verify.md
out=$("$V" coverage t1 2>&1) || true
case "$out" in (*"not usable"*) fail "the filled-in template was refused: $out";; esac
has "$out" "profile: strict" "a BOM or a trailing comment hid profile: strict"
cp .sdlc/verify.md "$t/tpl.md"
refused() { # <what> <expected text>
  rc=0; out=$("$V" check t1 2>&1) || rc=$?; [ "$rc" = 2 ] || fail "$1 not refused (exit $rc): $out"; has "$out" "$2" "$1 refused for the wrong reason"; }
sed 's/^doctor_attempt_timeout: 30/doctor_attempt_timeout: soon/' "$t/tpl.md" > .sdlc/verify.md; refused "a word as doctor_attempt_timeout" "doctor_attempt_timeout"
{ cat "$t/tpl.md"; printf '  check: O1 | unit | true\n'; } > .sdlc/verify.md; refused "an indented check line" "indented directive"
cp "$t/tpl.md" .sdlc/verify.md
printf 'check: O1\t| unit | true\n' > "$fr"; refused "a tab in a check line" "holds a tab"
printf 'check: O1 | unit | sh tests/o1.sh | must-fail-on-base  # the new test\ngap: O1 | runtime proven by hand\n' > "$fr"
out=$("$V" check t1 2>&1) || true; has "$out" "must fail without the change" "must-fail-on-base with a trailing comment not recognised"
#    no git: the receipt binds no source, so it is blocked (never ok forever)
ng="$t/ng"; mkdir "$ng"
if git -C "$ng" rev-parse --git-dir >/dev/null 2>&1; then echo "note: $ng is inside a git repository — no-git case skipped"
else
  cd "$ng"; "$kit/init.sh" . >/dev/null; intent n1; printf 'check: O1 | unit | true\n' > .sdlc/verify.md
  out=$("$V" run n1) && fail "a receipt with no git repository verified"
  has "$out" "VERIFY blocked: not a git repository" "no-git receipt not blocked"
fi
echo "ok: verification reads the template and its lines strictly; no git is a gap"
}
verify_baseline() {
mkdir w; cd w; git init -q .
"$kit/init.sh" . >/dev/null
#    the baseline: same failure = pre-existing; anything else is not
printf 'old\n' > app.txt; printf 'exit 1\n' > lint.sh; printf 'exit 1\n' > lint2.sh
commit
printf 'new\n' > app.txt; printf 'exit 2\n' > lint2.sh   # lint2 now fails differently
mkdir -p tests; printf 'exit 1\n' > tests/new.sh           # a new, failing test: missing at base
printf '%s\n' 'test_paths: tests/*' 'check: lint | lint | sh lint.sh' 'check: lint2 | lint | sh lint2.sh' 'check: unit | unit | sh tests/new.sh' > .sdlc/verify.md
intent w1; printf '%s\n' 'check: O1 | unit | grep -q new app.txt' 'check: flint | lint | sh lint.sh' > .sdlc/work/w1/verify.md
#    requirement ids as people write them; only the template placeholder is skipped
mkdir -p .sdlc/work/s1 .sdlc/work/s2; echo goal > .sdlc/work/s1/intent.md
printf '%s\n' '- R1: plain' '* **R2**: bold' '  - R3 : indented' '- R4: <b>starts with a tag</b>' '- R5: <requirement> (O1)' > .sdlc/work/s1/spec.md
printf '%s\n' 'check: R1.happy | e2e | true' 'check: R2 | e2e | true' 'gap: R3 | checked by hand' > .sdlc/work/s1/verify.md
out=$("$V" coverage s1) && fail "coverage passed with R4 uncovered: $out"
has "$out" "R1.happy(e2e)" "a variant check did not cover R1"; has "$out" "COVERAGE uncovered: R4" "R4 not reported uncovered"
case "$out" in (*R5*) fail "the template placeholder was read as a requirement: $out";; esac
printf -- '- R1: <requirement> (O1)\n' > .sdlc/work/s2/spec.md
out=$("$V" check s2) && fail "a spec.md with no requirement id verified"
has "$out" "no requirement ids found" "an empty requirement list was not uncovered"
git worktree add -q --detach "$t/keep-wt" HEAD; mv "$t/keep-wt" "$t/keep-wt.moved"   # the human's, now missing
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$t" > .git/hooks/post-checkout; chmod +x .git/hooks/post-checkout
tt="$t/tt"; mkdir "$tt"
wtclean() {
  [ -z "$(ls -A "$tt")" ] || fail "$1: the baseline left its temp dir behind: $(ls -A "$tt")"
  [ "$(git worktree list | grep -c .)" = 2 ] || fail "$1: the baseline changed the worktree list: $(git worktree list)"; }
side=$(echo side | git -c user.email=t@t.invalid -c user.name=t commit-tree "HEAD^{tree}")
out=$(TMPDIR="$tt" "$V" baseline w1 --base "$side" 2>&1) && fail "a base outside HEAD's history was accepted"
has "$out" "not an ancestor of HEAD" "a sibling base not refused by name"
out=$(TMPDIR="$tt" "$V" baseline w1 2>&1) || fail "baseline failed: $out"
has "$out" "names tests/new.sh, which is new since the base" "a check running a new file was run at base"
wtclean "after a baseline"; [ ! -e "$t/hook-ran" ] || fail "the repository's post-checkout hook ran for the base worktree"
grep -q '^check: flint ' .sdlc/work/w1/verify-baseline.md && fail "a feature recipe check was run at base"
out=$("$V" run w1) && fail "a regression passed as pre-existing: $out"
grep -q '^check: lint | lint | 1 | .* | pre-existing$' .sdlc/work/w1/verify-receipt.md || fail "the same failure at base was not pre-existing"
for c in lint2 flint unit; do
  grep -q "^check: $c | .* | pre-existing$" .sdlc/work/w1/verify-receipt.md && fail "check $c labelled pre-existing"
done
out=$("$V" show w1); has "$out" "baseline: HEAD @" "show did not name the base"
echo evidence > .sdlc/work/w1/evidence.md
out=$("$A" ship .sdlc/work/w1/evidence.md 2>&1) && fail "ship approved over a new failing test"
has "$out" "verification fail" "ship refusal did not say why"
#    must-fail-on-base: the new test must reach the base, and must run there
intent w2; printf 'exit 0\n' > tests/o2.sh
printf 'check: O1 | unit | sh tests/o2.sh | must-fail-on-base\n' > .sdlc/work/w2/verify.md
sed 's#^test_paths: .*#test_paths: spec/*#' .sdlc/verify.md > "$t/r.tmp"; cat "$t/r.tmp" > .sdlc/verify.md
out=$(TMPDIR="$tt" "$V" baseline w2 2>&1) && fail "a must-fail baseline with no test copied was recorded"
has "$out" "no changed or added file" "zero copied tests not named"; [ ! -f .sdlc/work/w2/verify-baseline.md ] || fail "a refused baseline was recorded"
mkdir spec; printf 'x\n' > spec/x.txt
out=$(TMPDIR="$tt" "$V" baseline w2 2>&1) && fail "a must-fail command running an uncopied changed file was baselined"
has "$out" "runs tests/o2.sh, which changed since the base" "the uncopied test not named"
sed 's#^test_paths: .*#test_paths: tests/*#' .sdlc/verify.md > "$t/r.tmp"; cat "$t/r.tmp" > .sdlc/verify.md
printf 'sh helper.sh\n' > tests/o2.sh; printf 'exit 1\n' > helper.sh   # the helper does not exist at base
out=$(TMPDIR="$tt" "$V" baseline w2 2>&1) && fail "a must-fail check that could not run at base passed"
has "$out" "COULD NOT RUN" "a 127 at base was counted as the test failing"; wtclean "after a vacuous baseline"
out=$("$V" check w2) || true; has "$out" "could not run at base" "the state did not name the check that could not run"
printf 'baseline_setup: false\n' >> .sdlc/verify.md
TMPDIR="$tt" "$V" baseline w1 >/dev/null 2>&1 && fail "a failing baseline_setup recorded a baseline"
wtclean "after a failed baseline"
echo "ok: verification reads ids and baselines strictly; cleans up"
}

# Every section at once, each in its own dir and output file; the output is
# printed in this order, and any failed section fails the run.
sections="basics verify_ship verify_vacuous verify_strict verify_reads verify_baseline"
set --
for s in $sections; do
  t="$tmp/$s"; mkdir "$t"
  ( cd "$t"; "$s" ) > "$t.out" 2>&1 &
  set -- "$@" $!
done
rc=0
for s in $sections; do
  wait "$1" || rc=1; shift
  cat "$tmp/$s.out"
done
[ "$rc" = 0 ] || exit 1
echo "SELFTEST PASS"
