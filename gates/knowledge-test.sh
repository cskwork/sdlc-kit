#!/usr/bin/env bash
# knowledge-test.sh [kit-path] — the record STORE and its retrieval.
#
# Covers what gates/selftest.sh (gate mechanics) and gates/e2e.sh (the loop)
# do not: where records live, how a chosen area is bound to a checkout, every
# way that binding must refuse, and whether a closed feature can still be
# found afterwards (tools/kb.sh).
#
# Throwaway fixtures only, under its own mktemp dir. No network, no remote.
# Bash 3.2 compatible (no associative arrays, no mapfile, no [[ =~ ]]).
# Exit 0 = every assertion held. Exit 1 = at least one FAIL.
set -u

KIT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
KIT=$(cd "$KIT" 2>/dev/null && pwd) || { echo "no such kit path: ${1:-}" >&2; exit 2; }
[ -f "$KIT/init.sh" ] || { echo "not a kit: $KIT" >&2; exit 2; }

BASE="${KB_TEST_BASE:-${TMPDIR:-/tmp}}"
FIX=$(mktemp -d "${BASE%/}/sdlc-kb.XXXXXX") || exit 2
case "$FIX" in */sdlc-kb.*) ;; *) echo "refusing to use fixture $FIX" >&2; exit 2;; esac
cleanup() { case "$FIX" in */sdlc-kb.*)
    # a native deny ACE (C10, Windows) is removed before the fixture goes
    if [ -d "$FIX/ro-area" ] && command -v allow_write >/dev/null 2>&1; then allow_write "$FIX/ro-area"; fi
    cd / 2>/dev/null || true
    chmod -R u+w "$FIX" 2>/dev/null; rm -rf "$FIX";; esac; }
[ -n "${KB_TEST_KEEP:-}" ] || trap cleanup EXIT
echo "fixture: $FIX"
echo "kit:     $KIT"
echo

PASSED=0; FAILED=0; FAILLIST=""
pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); FAILLIST="$FAILLIST
  - $1"; printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '      output: %s\n' "$(printf '%s' "$2" | tr '\n' '|' | cut -c1-300)"; return 0; }
assert_ok() { local d="$1"; shift; local o rc; o=$("$@" 2>&1); rc=$?
  [ $rc -eq 0 ] && pass "$d" || fail "$d (exit $rc)" "$o"; }
assert_ok_msg() { local d="$1" n="$2"; shift 2; local o rc; o=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then fail "$d (exit $rc, expected 0)" "$o"
  else case "$o" in *"$n"*) pass "$d";; *) fail "$d (missing '$n')" "$o";; esac; fi; }
assert_fail_msg() { local d="$1" n="$2"; shift 2; local o rc; o=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then fail "$d (succeeded, expected refusal)" "$o"
  else case "$o" in *"$n"*) pass "$d";; *) fail "$d (refused, but message lacks '$n')" "$o";; esac; fi; }
assert_exit() { local d="$1" want="$2"; shift 2; local o rc; o=$("$@" 2>&1); rc=$?
  [ "$rc" = "$want" ] && pass "$d" || fail "$d (exit $rc, expected $want)" "$o"; }
assert_file() { [ -f "$1" ] && pass "$2" || fail "$2 (missing file $1)"; }
assert_nofile() { [ -e "$1" ] && fail "$2 (unexpected $1)" || pass "$2"; }

gitinit() { git init -q .; git config user.email kb@sdlc-kit.invalid; git config user.name "kb test"; }
newproj() { # <dir>
  mkdir -p "$1"; cd "$1" || exit 2; gitinit
  printf 'echo hi\n' > app.sh; git add app.sh; git commit -qm init >/dev/null
}
kb() { bash "$KIT/tools/kb.sh" "$@"; }

# --- an unwritable directory, on this platform -------------------------------
# `chmod 500` decides nothing on NTFS: Windows grants write access by ACL, and
# the POSIX bits Git Bash prints are a mapping, not the enforced right. So the
# deny is made natively there (icacls, on this run's fixture directory only),
# restored right afterwards, and no refusal is asserted until a real write
# probe has been denied. A fixture that cannot be made is reported as NOT
# VERIFIED — never quietly skipped.
IS_WINDOWS=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1;; esac
win_user() { printf '%s' "${USERNAME:-$(whoami)}"; }
# Why the ACL command never runs bare: Git Bash rewrites arguments that look
# like Unix paths into Windows paths before a NATIVE program sees them, so
# `/deny` and `/remove:d` reach icacls as `C:/Program Files/Git/deny` and the
# option is gone. MSYS2_ARG_CONV_EXCL='*' turns that conversion off for this
# one command; both directory arguments are already native (cygpath -w), so
# nothing is left for the conversion to do.
# https://www.msys2.org/docs/filesystem-paths/#automatic-unix-windows-path-conversion
ACL_DIAG=""
acl_diag() { ACL_DIAG="$1 (exit $2): $(printf '%s' "$3" | tr '\n' '|' | cut -c1-300)"; }
deny_write() { # <dir, inside this run's fixture>
  case "$1" in "$FIX"/*) ;; *) echo "refusing to change rights outside $FIX" >&2; return 1;; esac
  ACL_DIAG=""
  if [ "$IS_WINDOWS" = 1 ]; then
    local w o rc
    w=$(cygpath -w "$1" 2>&1); rc=$?
    [ $rc -eq 0 ] || { acl_diag "cygpath -w $1" "$rc" "$w"; return 1; }
    o=$(MSYS2_ARG_CONV_EXCL='*' icacls "$w" /deny "$(win_user):(W)" 2>&1); rc=$?
    [ $rc -eq 0 ] || { acl_diag "icacls '$w' /deny $(win_user):(W)" "$rc" "$o"; return 1; }
  else
    local o rc
    o=$(chmod 500 "$1" 2>&1); rc=$?
    [ $rc -eq 0 ] || { acl_diag "chmod 500 $1" "$rc" "$o"; return 1; }
  fi
}
allow_write() { # <dir, inside this run's fixture> — always tries both restores
  case "$1" in "$FIX"/*) ;; *) return 1;; esac
  if [ "$IS_WINDOWS" = 1 ]; then
    local w
    w=$(cygpath -w "$1" 2>/dev/null) && \
      MSYS2_ARG_CONV_EXCL='*' icacls "$w" /remove:d "$(win_user)" >/dev/null 2>&1
  fi
  chmod 700 "$1" 2>/dev/null
  return 0
}
# The deny ACE alone did not hold on the CI runner. Its account (runneradmin,
# RID 500) carries SeBackupPrivilege and SeRestorePrivilege ENABLED, and with
# them both a native CreateDirectory and an MSYS mkdir succeeded against a
# directory whose ACL icacls printed as `runneradmin:(DENY)(W)` — that is a
# privileged fixture, not the product skipping a Windows permission error
# (evidence: .sdlc/work/260920-external-knowledge-area/scratch/
# ci-windows-diagnostics.log, run 35517903326).
# So on Windows the write probe AND the real init.sh both run in a child whose
# token no longer has those two privileges (gates/win-restricted-run.py,
# SE_PRIVILEGE_REMOVED — irreversible, so the MSYS runtime cannot turn them
# back on). The shell running this test keeps its own privileges, which is what
# still lets cleanup restore the fixture ACL. Exit 90-93 from the helper means
# the reduced-privilege child could not be established: NOT VERIFIED, never a
# pass. Nothing outside this run's fixture, and no account or machine state,
# is changed.
RESTRICTED_PY=""; RESTRICTED_BASH=""; RESTRICTED_HELPER=""; RESTRICTED_DIAG=""
restricted_ready() { # 0 when a reduced-privilege child can be launched here
  [ "$IS_WINDOWS" = 1 ] || return 1
  [ -n "$RESTRICTED_PY" ] && return 0
  local c b
  for c in python3 python py; do command -v "$c" >/dev/null 2>&1 && { RESTRICTED_PY="$c"; break; }; done
  [ -n "$RESTRICTED_PY" ] || { RESTRICTED_DIAG="no python3/python/py on PATH"; return 1; }
  [ -f "$KIT/gates/win-restricted-run.py" ] || { RESTRICTED_DIAG="missing $KIT/gates/win-restricted-run.py"; return 1; }
  RESTRICTED_HELPER=$(cygpath -w "$KIT/gates/win-restricted-run.py" 2>&1) || {
    RESTRICTED_DIAG="cygpath -w on the helper failed: $RESTRICTED_HELPER"; RESTRICTED_PY=""; return 1; }
  # Git Bash is resolved through the MSYS PATH and then converted, so the name
  # can never fall through to C:\Windows\System32\bash.exe (WSL).
  b=$(command -v bash) || { RESTRICTED_DIAG="no bash on PATH"; RESTRICTED_PY=""; return 1; }
  [ -f "$b.exe" ] && b="$b.exe"
  RESTRICTED_BASH=$(cygpath -w "$b" 2>&1) || {
    RESTRICTED_DIAG="cygpath -w on bash failed: $RESTRICTED_BASH"; RESTRICTED_PY=""; return 1; }
  return 0
}
# Native Python would otherwise see `/tmp/...` rewritten, so the conversion is
# off for THIS call only and the two native paths are passed already converted.
# The helper drops the override again before it starts Git Bash.
restricted_run() { # <bash -c script> [args…] — under the reduced-privilege token
  local script="$1"; shift
  MSYS2_ARG_CONV_EXCL='*' "$RESTRICTED_PY" "$RESTRICTED_HELPER" -- \
    "$RESTRICTED_BASH" -c "$script" restricted "$@"
}
# Failure-only, Windows-only, concise: what the child token actually had, and
# the ACL as it actually stands. Asserts nothing and changes nothing.
win_restricted_diag() { # <dir, inside this run's fixture>
  case "$1" in "$FIX"/*) ;; *) return 0;; esac
  local w
  [ -n "$RESTRICTED_DIAG" ] && printf '      diag: %s\n' "$RESTRICTED_DIAG"
  if restricted_ready; then
    MSYS2_ARG_CONV_EXCL='*' "$RESTRICTED_PY" "$RESTRICTED_HELPER" --report 2>&1 \
      | sed 's/^/      diag: /'
  fi
  w=$(cygpath -w "$1" 2>/dev/null) && \
    MSYS2_ARG_CONV_EXCL='*' icacls "$w" 2>&1 | sed 's/^/      diag: /'
  return 0
}
write_denied() { # <dir> → 0 only when a real write into it actually fails
  local p="$1/.write-probe" o rc
  rm -rf "$p" 2>/dev/null
  if [ "$IS_WINDOWS" = 1 ]; then
    restricted_ready || return 1
    o=$(restricted_run 'mkdir "$1"' "$p" 2>&1); rc=$?
    if [ $rc -ge 90 ]; then
      RESTRICTED_DIAG="the reduced-privilege child could not be established (exit $rc): $(printf '%s' "$o" | tr '\n' '|' | cut -c1-300)"
      return 1
    fi
    if [ $rc -eq 0 ] || [ -e "$p" ]; then rm -rf "$p" 2>/dev/null; return 1; fi
    return 0
  fi
  if mkdir "$p" 2>/dev/null; then rmdir "$p" 2>/dev/null; return 1; fi
  [ -e "$p" ] && { rm -rf "$p" 2>/dev/null; return 1; }
  return 0
}
# C10 must meet the SAME conditions the write probe was proved under, or it
# would be testing a different access check than the one C10a established.
run_init_area() { # <project dir> <area>
  if [ "$IS_WINDOWS" = 1 ]; then
    restricted_run 'cd "$1" || exit 2; exec bash "$2" . --area "$3"' \
      "$1" "$KIT/init.sh" "$2"
  else
    ( cd "$1" && bash "$KIT/init.sh" . --area "$2" )
  fi
}
# Read a text file without any line-ending translation: CR is shown as `@`, so
# a byte that is there stays visible and a byte that is gone stays missing. The
# runtime's own reader is never reused here — a test that mirrors the code it
# checks cannot tell a real byte loss from a text-mode reader.
crlf_count() { # <file> <exact line, CR written as @> → how many lines match
  tr '\r' '@' < "$1" | grep -c -x -F -e "$2"
}
# the store name init.sh will compute for a checkout — the test must point at
# the same directory init.sh would, or a refusal case would never be reached
. "$KIT/gates/_common.sh"
store_name() { # <project dir> → <unit>-<checkout-id>
  local p; p=$(cd "$1" && pwd -P)
  printf '%s-%s\n' "$(basename "$p")" "$(printf '%s' "$p" | sdlc_sha256_stdin | cut -c1-8)"
}

# A symlink that is a COPY (Git Bash MSYS default) would make every assertion
# below pass for the wrong reason. Prove the filesystem links before trusting it.
mkdir -p "$FIX/linkprobe/t"; ln -s "$FIX/linkprobe/t" "$FIX/linkprobe/l" 2>/dev/null
if [ ! -L "$FIX/linkprobe/l" ]; then
  echo "SKIP: this filesystem/shell cannot create symlinks (Windows: MSYS=winsymlinks:nativestrict)."
  echo "      The external-area cases cannot be verified here. NOT VERIFIED."
  exit 2
fi

echo "=============== A. the default store: local, ignored, retrievable"
A="$FIX/proj-a"; newproj "$A"
assert_ok "A1 plain init still works" bash "$KIT/init.sh" .
assert_ok_msg "A2 git ignores the whole store" ".sdlc" git check-ignore -v .sdlc
assert_file "$A/.sdlc/README.md" "A3 init generated the contents page"
assert_ok_msg "A4 the page says it is generated" "generated by sdlc-kit" head -n 1 "$A/.sdlc/README.md"
mkdir -p .sdlc/work/feat-one
cat > .sdlc/work/feat-one/intent.md <<'EOF'
# Intent: feat-one
- Goal: make the greeting configurable
- Track: compact
EOF
assert_ok "A5 the intent gate works in a local store" \
  bash "$KIT/gates/approve.sh" intent .sdlc/work/feat-one/intent.md --delegated
assert_ok_msg "A6 the gate is open" "GATE OPEN" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/feat-one/intent.md
assert_ok_msg "A7 kb.sh show reads the goal back verbatim" "make the greeting configurable" \
  kb show feat-one
assert_ok_msg "A8 index lists the open feature and links its intent" "work/feat-one/intent.md" \
  sh -c "bash '$KIT/tools/kb.sh' index >/dev/null && cat '$A/.sdlc/README.md'"
# regenerating the page must not touch a single approval-bound byte
before=$(bash "$KIT/gates/check-gate.sh" intent .sdlc/work/feat-one/intent.md 2>&1)
kb index >/dev/null
assert_ok_msg "A9 index does not disturb an approved artifact" "GATE OPEN" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/feat-one/intent.md
assert_fail_msg "A10 a user-authored README.md is never clobbered" "refusing to overwrite" \
  sh -c "echo '# my own notes' > '$A/.sdlc/README.md'; bash '$KIT/tools/kb.sh' index --store '$A/.sdlc'"
assert_ok_msg "A11 the user's own page is still on disk" "my own notes" cat "$A/.sdlc/README.md"
rm -f "$A/.sdlc/README.md"
# a monorepo shipping unit owns its own store, ignored by its own rule
mkdir -p "$A/pkg/svc"
assert_ok "A12 a shipping unit inside the repo initializes" bash "$KIT/init.sh" pkg/svc
assert_file "$A/pkg/svc/.gitignore" "A13 the unit gets its own ignore rule"
# the matching rule is the UNIT's own, not the repo root's: /.sdlc is anchored
assert_ok_msg "A14 the unit's store is ignored by the unit's own rule" "pkg/svc/.gitignore" \
  git -C "$A" check-ignore -v pkg/svc/.sdlc/config.md
assert_exit "A15 a unit without its own rule is not caught by the root's" 1 \
  sh -c "mkdir -p '$A/pkg/bare/.sdlc' && touch '$A/pkg/bare/.sdlc/config.md' && git -C '$A' check-ignore -q pkg/bare/.sdlc/config.md"

echo
echo "=============== B. an external area, chosen by the user"
B="$FIX/proj-b"; newproj "$B"
AREA="$FIX/my knowledge área"        # spaces and non-ASCII on purpose
assert_ok_msg "B1 init --area binds a chosen folder" "Knowledge area:" \
  bash "$KIT/init.sh" . --area "$AREA"
STORE=$(cd "$B/.sdlc" && pwd -P)
case "$STORE" in "$(cd "$AREA" && pwd -P)"/proj-b-*) pass "B2 the store is <area>/<unit>-<checkout-id>";;
  *) fail "B2 unexpected store path" "$STORE";; esac
[ -L "$B/.sdlc" ] && pass "B3 .sdlc is a symlink, not a copy" || fail "B3 .sdlc is not a symlink"
assert_file "$STORE/PROJECT" "B4 the store records its owner"
assert_ok_msg "B5 the owner is this checkout" "$(cd "$B" && pwd -P)" cat "$STORE/PROJECT"
assert_ok_msg "B6 the area store is ignored by the project" ".sdlc" git check-ignore -v .sdlc
assert_ok_msg "B7 init reports where the records live" "back that up yourself" \
  bash "$KIT/init.sh" . --area "$AREA"
assert_ok "B8 re-running with the same area is idempotent" bash "$KIT/init.sh" . --area "$AREA"
assert_file "$STORE/config.md" "B9 records are physically in the area"
assert_nofile "$B/.sdlc/.git" "B10 the store is not a repository of its own"

# a second checkout of a same-named project gets its own store
B2D="$FIX/other/proj-b"; newproj "$B2D"
assert_ok "B11 a same-named second checkout initializes" bash "$KIT/init.sh" . --area "$AREA"
STORE2=$(cd "$B2D/.sdlc" && pwd -P)
[ "$STORE2" != "$STORE" ] && pass "B12 same-named checkouts do not share a store" \
  || fail "B12 two checkouts share $STORE"

echo
echo "=============== C. every way the binding must refuse"
C="$FIX/proj-c"; newproj "$C"
assert_fail_msg "C1 an area inside the project is refused" "inside the project" \
  bash "$KIT/init.sh" . --area "$C/records"
assert_nofile "$C/.sdlc" "C2 the refusal wrote nothing"
assert_nofile "$C/records" "C2b the refused area folder was never created inside the project"
bash "$KIT/init.sh" . --area "$C/deep/er/still-inside" >/dev/null 2>&1
assert_nofile "$C/deep" "C2c a refused area several levels deep creates no part of its path"
mkdir -p "$FIX/outer"; D="$FIX/outer/proj-d"; newproj "$D"
assert_fail_msg "C3 a project inside the area is refused" "inside the knowledge area" \
  bash "$KIT/init.sh" . --area "$FIX/outer"
# a store owned by another checkout is never adopted
cd "$C"
mkdir -p "$FIX/area-c/$(store_name "$C")"
printf 'project: /somewhere/else\n' > "$FIX/area-c/$(store_name "$C")/PROJECT"
assert_fail_msg "C4 another checkout's store is refused" "belongs to another checkout" \
  bash "$KIT/init.sh" . --area "$FIX/area-c"
assert_nofile "$C/.sdlc" "C4b nothing was linked into the refused store"
# … and a directory that is not a store at all is not adopted either
mkdir -p "$FIX/area-e/$(store_name "$C")"
echo x > "$FIX/area-e/$(store_name "$C")/notes.txt"
assert_fail_msg "C5 a non-store directory is refused" "not an sdlc-kit store" \
  bash "$KIT/init.sh" . --area "$FIX/area-e"
# an existing REAL .sdlc is never relocated
F="$FIX/proj-f"; newproj "$F"
bash "$KIT/init.sh" "$F" >/dev/null 2>&1
assert_fail_msg "C6 a real .sdlc directory is never moved automatically" "never relocates records" \
  bash "$KIT/init.sh" "$F" --area "$FIX/area-f"
assert_file "$F/.sdlc/config.md" "C7 the existing records are untouched"
# a link that points somewhere else is never redirected
assert_fail_msg "C8 a redirected .sdlc link is refused" "already points at" \
  bash "$KIT/init.sh" "$B" --area "$FIX/area-g"
assert_ok_msg "C9 the original binding survives the refusal" "$STORE" sh -c "cd '$B' && cd .sdlc && pwd -P"
# an unwritable area fails, it does not fall back anywhere
RO="$FIX/ro-area"; mkdir -p "$RO"
deny_write "$RO" || true
G="$FIX/proj-g"; newproj "$G"
if write_denied "$RO"; then
  pass "C10a the area really is unwritable here (a real write into it was denied)"
  # C10 requires a normal product refusal (non-zero, never a 90-93 helper code)
  # naming THIS area: the write check, or the traversal check Windows hits first.
  C10O=$(run_init_area "$G" "$RO" 2>&1); C10RC=$?
  if [ $C10RC -eq 0 ]; then
    fail "C10 an unwritable area fails explicitly (succeeded, expected refusal)" "$C10O"
  elif [ $C10RC -ge 90 ] && [ $C10RC -le 93 ]; then
    fail "C10 an unwritable area fails explicitly (exit $C10RC is a reserved helper failure, not a product refusal)" "$C10O"
  else
    case "$C10O" in
      *"not writable"*|*"FAIL: cannot resolve the knowledge area: $RO"*)
        pass "C10 an unwritable area fails explicitly";;
      *) fail "C10 an unwritable area fails explicitly (refused, but not with an explicit refusal naming $RO)" "$C10O";;
    esac
  fi
  assert_nofile "$G/.sdlc" "C11 no fallback store was created"
else
  # the command that was supposed to make the deny is named with its exit
  # status and its own words, so a fixture that cannot be built is debuggable
  fail "C10a NOT VERIFIED: no unwritable directory could be made on $(uname -s) — C10 and C11 are untested here, not passing" \
    "${ACL_DIAG:-${RESTRICTED_DIAG:-the deny command reported success, but a write into $RO still succeeded}}"
  # `fail` truncates its output to 300 characters, so the privilege state and
  # the ACL print themselves — only here, on Windows, after the fixture failed.
  if [ "$IS_WINDOWS" = 1 ]; then win_restricted_diag "$RO"; fi
fi
allow_write "$RO"
assert_fail_msg "C12 an unknown option is refused" "unknown option" bash "$KIT/init.sh" . --wiki
assert_fail_msg "C13 two target directories are refused" "more than one target" \
  bash "$KIT/init.sh" . "$G" --area "$FIX/area-h"

echo
echo "=============== D. the loop runs through the link, gates unchanged"
cd "$B"
mkdir -p .sdlc/work/ext-feat
cat > .sdlc/work/ext-feat/intent.md <<'EOF'
# Intent: ext-feat
- Goal: keep the records outside the application history
- Track: compact
EOF
assert_ok "D1 intent approved through the link" \
  bash "$KIT/gates/approve.sh" intent .sdlc/work/ext-feat/intent.md --delegated
assert_ok_msg "D2 gate open through the link" "GATE OPEN" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/ext-feat/intent.md
assert_file "$STORE/approvals/ext-feat.intent.approval" "D3 the approval record is in the area, not the project"
echo "tampered" >> .sdlc/work/ext-feat/intent.md
assert_fail_msg "D4 tampering still closes the gate" "changed after it was approved" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/ext-feat/intent.md
sed -i.bak '/tampered/d' .sdlc/work/ext-feat/intent.md && rm -f .sdlc/work/ext-feat/intent.md.bak
assert_ok_msg "D5 restoring the approved bytes reopens it" "GATE OPEN" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/ext-feat/intent.md
# a per-feature symlink is still forbidden, area or no area
mkdir -p "$FIX/elsewhere/sneak"; echo "- Goal: x" > "$FIX/elsewhere/sneak/intent.md"
ln -s "$FIX/elsewhere/sneak" .sdlc/work/sneak
assert_fail_msg "D6 a symlinked feature dir is still refused" "must live in" \
  bash "$KIT/gates/approve.sh" intent .sdlc/work/sneak/intent.md --delegated
assert_ok_msg "D7 kb.sh does not read through a feature symlink" "not read" \
  sh -c "bash '$KIT/tools/kb.sh' show sneak --store '$B/.sdlc' 2>&1; true"
rm -f .sdlc/work/sneak
# the ship snapshot must not bind the .sdlc link itself
printf 'echo hello\n' > app.sh
echo "- Command: sh app.sh -> hello" > .sdlc/work/ext-feat/evidence.md
assert_ok "D8 ship approval taken with the store linked" \
  bash "$KIT/gates/approve.sh" ship .sdlc/work/ext-feat/evidence.md --delegated
if grep -q ' \.sdlc$' "$STORE/approvals/ext-feat.ship.source"; then
  fail "D9 the source snapshot bound the .sdlc link"
else pass "D9 the source snapshot excludes the .sdlc link"; fi
git add -A; git commit -qm "feat: greet" >/dev/null
assert_ok_msg "D10 committing the reviewed source keeps the ship gate open" "GATE OPEN" \
  bash "$KIT/gates/check-gate.sh" ship .sdlc/work/ext-feat/evidence.md
SHA=$(git rev-parse HEAD)
cat > .sdlc/work/ext-feat/delivery.md <<EOF
# Delivery: ext-feat
- Target: local
- Source: $SHA
- Verified-by: sh app.sh
- Evidence: hello
- Confirmed: yes
EOF
assert_ok_msg "D11 the commit CONTAINS the reviewed source (the link is not drift)" "delivery: local" \
  bash "$KIT/gates/close.sh" ext-feat shipped "records kept in the chosen area"
assert_file "$STORE/archive/ext-feat/CLOSED" "D12 the feature archived inside the area"
assert_file "$STORE/archive/ext-feat/approvals/ext-feat.ship.approval" "D13 approvals archived with it"
assert_ok_msg "D14 close refreshed the contents page" "ext-feat" cat "$STORE/README.md"
assert_ok_msg "D15 the archived intent is linked from the page" "archive/ext-feat/intent.md" cat "$STORE/README.md"

echo
echo "=============== E. retrieval: find it again, later, from anywhere"
cd "$B"
assert_ok_msg "E1 show reports the closed state" "shipped" kb show ext-feat
assert_ok_msg "E2 show names the documents that exist" "archive/ext-feat/delivery.md" kb show ext-feat
assert_ok_msg "E3 search finds a line in an archived document" "evidence.md" kb search "sh app.sh"
assert_exit "E4 no match exits 1" 1 bash "$KIT/tools/kb.sh" search "nothing-like-this-exists"
assert_exit "E5 an unknown slug exits 1" 1 bash "$KIT/tools/kb.sh" show no-such-feature
assert_exit "E6 a bad store exits 2" 2 bash "$KIT/tools/kb.sh" search --store "$FIX/nope" x
assert_ok_msg "E7 a query starting with '-' is a query, not an option" "intent.md" \
  bash "$KIT/tools/kb.sh" search -- "- Goal: keep the records"
assert_fail_msg "E8 without -- a leading dash is a clear error, never silence" "goes after --" \
  bash "$KIT/tools/kb.sh" search "- Goal:"
assert_ok_msg "E9 output is bounded" "more match(es) not shown" \
  sh -c "bash '$KIT/tools/kb.sh' search --limit 1 -- '-' 2>&1; true"
# long lines are truncated, not dumped
mkdir -p .sdlc/work/longline
awk 'BEGIN { printf "- Goal: "; for (i = 0; i < 400; i++) printf "x"; print " needle-long" }' > .sdlc/work/longline/intent.md
LONG=$(kb search "needle-long" | awk '{ print length($0) }' | sort -rn | head -1)
[ "${LONG:-9999}" -le 260 ] && pass "E10 a very long matching line is truncated" \
  || fail "E10 an unbounded line was printed (${LONG} chars)"
# area-wide: every owned store, and nothing else
assert_ok_msg "E11 --area searches across stores" "ext-feat" \
  bash "$KIT/tools/kb.sh" search --area "$AREA" "keep the records"
mkdir -p "$AREA/not-a-store/work/x"
echo "- Goal: keep the records secret" > "$AREA/not-a-store/work/x/intent.md"
assert_exit "E12 --area never reads an unowned directory" 1 \
  sh -c "bash '$KIT/tools/kb.sh' search --area '$AREA' 'keep the records secret' 2>/dev/null"
ln -s "$FIX/elsewhere" "$AREA/linked-store"
assert_exit "E13 --area does not follow a symlink out of the area" 1 \
  sh -c "bash '$KIT/tools/kb.sh' list --area '$AREA' 2>/dev/null | grep -q linked-store"
assert_ok_msg "E14 list names the stores and their features" "ext-feat" \
  bash "$KIT/tools/kb.sh" list --area "$AREA"
# The point of the area: the checkout can be gone and the knowledge stays.
# Leave the checkout BEFORE deleting it. A process whose working directory has
# been removed cannot resolve its own cwd on Windows, and `find` then fails for
# the whole run — which would break retrieval here for a reason that has
# nothing to do with the records. The deletion itself is still asserted, and so
# are the retained bytes: the same query must come back with the same content.
EVID="$STORE/archive/ext-feat/evidence.md"
EV_BEFORE=$(sdlc_sha256_file "$EVID")
SEARCH_BEFORE=$(bash "$KIT/tools/kb.sh" search --area "$AREA" "sh app.sh" 2>&1)
cd "$FIX" || exit 2
rm -rf "$B"
assert_nofile "$B" "E15a the checkout the records came from is really gone"
assert_ok_msg "E15 knowledge outlives the checkout it came from" "ext-feat" \
  bash "$KIT/tools/kb.sh" show ext-feat --area "$AREA"
assert_ok_msg "E16 and stays searchable" "evidence.md" \
  bash "$KIT/tools/kb.sh" search --area "$AREA" "sh app.sh"
[ "$(sdlc_sha256_file "$EVID")" = "$EV_BEFORE" ] \
  && pass "E16a the retained evidence bytes are unchanged by the deletion" \
  || fail "E16a the evidence file changed when the checkout was deleted" "$EVID"
[ "$(bash "$KIT/tools/kb.sh" search --area "$AREA" "sh app.sh" 2>&1)" = "$SEARCH_BEFORE" ] \
  && pass "E16b the same query returns the same records as before the deletion" \
  || fail "E16b retrieval changed after the deletion" "$SEARCH_BEFORE"

echo
echo "=============== F. a COPY of a checkout never uses the original's store"
# cp -R, rsync, tar without --dereference and most backup restores preserve a
# symlink, so a copied project resolves .sdlc into the ORIGINAL's store. The
# copy owns nothing there: no gate verdict, no approval, no close — and the
# original must come out of the attempt byte-for-byte unchanged.
H="$FIX/proj-h"; newproj "$H"
AREA_H="$FIX/area-owner"
assert_ok "F0 the original checkout binds its own store" bash "$KIT/init.sh" . --area "$AREA_H"
HSTORE=$(cd "$H/.sdlc" && pwd -P)
mkdir -p .sdlc/work/owned
cat > .sdlc/work/owned/intent.md <<'EOF'
# Intent: owned
- Goal: work that belongs to the original checkout
- Track: compact
EOF
bash "$KIT/gates/approve.sh" intent .sdlc/work/owned/intent.md --delegated >/dev/null
REC="$HSTORE/approvals/owned.intent.approval"
REC_BEFORE=$(sdlc_sha256_file "$REC")
cd "$FIX" || exit 2
cp -R "$H" "$FIX/proj-h-copy"
COPY="$FIX/proj-h-copy"; cd "$COPY" || exit 2
if [ "$(cd .sdlc && pwd -P)" = "$HSTORE" ]; then
  pass "F1 the copy really does resolve into the original's store (the risk is real)"
else fail "F1 the copy does not reach the original store — the rest of F proves nothing"; fi
assert_fail_msg "F2 check-gate refuses from the copy" "belong to another checkout" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/owned/intent.md
assert_fail_msg "F3 approve refuses from the copy" "belong to another checkout" \
  bash "$KIT/gates/approve.sh" spec .sdlc/work/owned/intent.md --delegated
assert_fail_msg "F4 close refuses from the copy" "belong to another checkout" \
  bash "$KIT/gates/close.sh" owned abandoned "closed from a COPY of the checkout"
assert_fail_msg "F5 status refuses from the copy" "belong to another checkout" \
  bash "$KIT/gates/status.sh"
assert_fail_msg "F6 the machine view refuses too (--json goes through auto.sh)" "belong to another checkout" \
  bash "$KIT/tools/auto.sh" status --json
assert_fail_msg "F7 verify.sh refuses from the copy" "belong to another checkout" \
  bash "$KIT/tools/verify.sh" check owned
assert_fail_msg "F8 handoff.sh refuses from the copy" "belong to another checkout" \
  bash "$KIT/tools/handoff.sh" check owned
assert_fail_msg "F9 an ordinary init re-run does not bypass the owner check" "belong to another checkout" \
  bash "$KIT/init.sh" .
assert_fail_msg "F10 nor does re-running it with --area" "belong to another checkout" \
  bash "$KIT/init.sh" . --area "$AREA_H"
assert_fail_msg "F11 regenerating the contents page is a write, and is refused" "belong to another checkout" \
  bash "$KIT/tools/kb.sh" index
# reading is never bound to a checkout: that is how knowledge outlives one
assert_ok_msg "F12 read-only retrieval still works from anywhere" "work that belongs to the original" \
  bash "$KIT/tools/kb.sh" search --area "$AREA_H" "work that belongs to the original"
# … and the original is untouched by every refusal above
assert_file "$HSTORE/work/owned/intent.md" "F13 the original's feature is still open, not archived"
assert_nofile "$HSTORE/archive/owned" "F14 nothing of the original was archived"
if [ "$(sdlc_sha256_file "$REC")" = "$REC_BEFORE" ]; then
  pass "F15 the original's approval record is byte-identical"
else fail "F15 the original's approval record changed"; fi
cd "$H" || exit 2
assert_ok_msg "F16 the owning checkout still passes its own gate" "GATE OPEN" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/owned/intent.md
# an external store with no ownership record is not assumed to be anyone's
mv "$HSTORE/PROJECT" "$HSTORE/PROJECT.bak"
assert_fail_msg "F17 an external store with no PROJECT record fails explicitly" "no ownership record" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/owned/intent.md
printf 'unit: x\n' > "$HSTORE/PROJECT"
assert_fail_msg "F18 a PROJECT without a readable owner line fails explicitly" "owner of these records is unknown" \
  bash "$KIT/gates/status.sh"
mv "$HSTORE/PROJECT.bak" "$HSTORE/PROJECT"
assert_ok_msg "F19 restoring the record restores the gate" "GATE OPEN" \
  bash "$KIT/gates/check-gate.sh" intent .sdlc/work/owned/intent.md

echo
echo "=============== G. the ignore cleanup, and readable store names"
# A Windows-authored .gitignore stores every line with a trailing CR. The
# obsolete kit rules must still go, and every other byte — CR included — stays.
CR="$FIX/proj-crlf"; newproj "$CR"
printf 'keepme\r\n.sdlc/approvals/\r\nbuild/\r\n' > .gitignore
assert_ok_msg "G1 init reports the obsolete CRLF rule as removed" "removed obsolete kit ignore" \
  bash "$KIT/init.sh" .
# Counted byte by byte (crlf_count: CR is read as `@`), because the failure to
# catch here is a LOST CR, and a reader that drops CR itself would call the
# loss a pass — or an intact file a failure.
gi_state() { # → <keepme+CR><build/+CR><obsolete, either ending><'/.sdlc', LF only>
  printf '%d%d%d%d' \
    "$(crlf_count .gitignore 'keepme@')" \
    "$(crlf_count .gitignore 'build/@')" \
    "$(( $(crlf_count .gitignore '.sdlc/approvals/@') + $(crlf_count .gitignore '.sdlc/approvals/') ))" \
    "$(crlf_count .gitignore '/.sdlc')"
}
G=$(gi_state)
[ "$G" = "1101" ] && pass "G2 CRLF: obsolete rule gone, /.sdlc added once, user lines kept with their CR" \
  || { fail "G2 CRLF cleanup wrong (keepme/build/obsolete/count = $G)" "$(od -c .gitignore | tr '\n' ' ')"
       printf '      bytes on disk:\n'; od -c .gitignore | sed 's/^/        /'; }
# Diagnostic, never an assertion: awk's view of this file against its bytes.
# A disagreement means awk translates line endings on this platform (text
# mode), which is exactly what can make an intact file look byte-damaged — the
# reason nothing above reads .gitignore through awk.
AWK_CR=$(awk '/\r$/ { n += 1 } END { print n + 0 }' .gitignore 2>/dev/null)
BYTE_CR=$(tr '\r' '@' < .gitignore | grep -c '@$')
[ "${AWK_CR:-x}" = "$BYTE_CR" ] \
  || printf 'note: awk sees %s CR-terminated line(s), the bytes have %s — awk is in text mode here\n' \
       "${AWK_CR:-?}" "$BYTE_CR"
assert_ok "G3 a second run over the cleaned CRLF file changes nothing more" bash "$KIT/init.sh" .
G=$(gi_state)
[ "$G" = "1101" ] && pass "G4 still exactly one /.sdlc rule, and the CRs are still there" \
  || { fail "G4 the second run changed the file (keepme/build/obsolete/count = $G)"
       printf '      bytes on disk:\n'; od -c .gitignore | sed 's/^/        /'; }
assert_exit "G5 the git index was never touched" 1 \
  sh -c "git -C '$CR' diff --cached --quiet; test \$? -ne 0"
# a non-ASCII checkout keeps a readable store name (only path-hostile bytes go)
U="$FIX/지식 프로젝트"; newproj "$U"
assert_ok "G6 a Unicode-named checkout initializes" bash "$KIT/init.sh" . --area "$FIX/area-u"
USTORE=$(cd "$U/.sdlc" && pwd -P)
case "$(basename "$USTORE")" in
  (*지식-프로젝트-*) pass "G7 the store name stays readable: $(basename "$USTORE")";;
  (*) fail "G7 the Unicode name was collapsed" "$(basename "$USTORE")";;
esac
assert_ok_msg "G8 the store records the kit version that seeded it" "kit_version:" cat "$USTORE/PROJECT"
assert_ok_msg "G9 the readable name carries into retrieval output" "지식-프로젝트" \
  bash "$KIT/tools/kb.sh" list --area "$FIX/area-u"

echo
echo "================================================================"
printf 'PASSED: %s   FAILED: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then printf 'failures:%s\n' "$FAILLIST"; echo "KNOWLEDGE-TEST FAIL"; exit 1; fi
echo "KNOWLEDGE-TEST PASS"
