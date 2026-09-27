#!/usr/bin/env bash
# verify.sh — run this project's verification recipe and record a receipt that is
# bound to the source it was produced from. Run from the project root.
#
#   tools/verify.sh run <slug> [--no-launch]   execute the recipe, write the receipt
#   tools/verify.sh check <slug>               is the receipt still worth anything?
#   tools/verify.sh doctor                     is the runtime environment ready?
#   tools/verify.sh show <slug>                print the receipt
#   tools/verify.sh coverage <slug>            which check (or gap) covers each requirement
#   tools/verify.sh baseline <slug> [--base <ref>]
#                                              the same checks at the BASE commit:
#                                              pre-existing failures, vacuous tests
#
# The recipe is `.sdlc/verify.md` (seed it from templates/verify.md) plus an
# optional `.sdlc/work/<slug>/verify.md` (templates/verify-feature.md). Together
# they map each requirement to the REAL project command that proves it, and name
# the optional launch / doctor / cleanup commands around them. What the states
# mean, coverage, and the baseline rules: docs/automation.md §4.
#
# What a receipt is, and is not. It records, for each configured check, the
# command's digest, its exit status, the digest of its output log, and the
# digest of the project's whole source snapshot before AND after the run. Change
# the code, the commands, or the recipe and the receipt reads `stale`; rewrite a
# log it cites and it reads `invalid`. That is CHANGE DETECTION: it makes "these
# commands never ran" and "this was edited afterwards" visible. It is NOT
# authentication — it says nothing about who produced it — and it is not an
# independent review. roles/verifier.md still runs in a fresh context.
#
# Bounded execution. Every check, every doctor attempt and the cleanup run under
# a wall-clock bound, in their own process group, with stdin on /dev/null, via
# tools/_run.py (python3). A hung project command can no longer hang an
# unattended driver, a check can no longer eat the recipe off stdin, and a
# launched runtime is stopped as a GROUP — its children do not survive the run.
#
# Interruption. INT/TERM stop the check that is RUNNING — this run's own child
# and that child's group — then run the cleanup, then exit non-zero with no
# receipt. No further check runs. Nothing outside this run is signalled: an
# external runtime the recipe did not launch is left exactly as it was.
#
# Exit: 0 pass · 1 fail/flaky/stale/blocked/inconclusive · 2 no recipe, unusable
# recipe, missing python3, or usage error.
set -uo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit/gates/_common.sh"
. "$kit/gates/_auto.sh"

usage() {
  echo "usage: verify.sh run <slug> [--no-launch] | verify.sh <check|show|coverage> <slug>" >&2
  echo "       verify.sh baseline <slug> [--base <ref>] | verify.sh doctor" >&2
  exit 2
}
[ $# -ge 1 ] || usage
cmd="$1"; shift
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root." >&2; exit 2; }
# A receipt is written into the store and is read as proof of this checkout's
# source: never another checkout's store (_common.sh sdlc_store_owner_ok).
sdlc_store_owner_ok || exit 2
recipe=$(sdlc_verify_recipe)
# the real checkout, for baseline_setup: to READ from; never link into it
SDLC_PROJECT_ROOT="$(pwd -P)"; export SDLC_PROJECT_ROOT

rfield() { sdlc_verify_field "$recipe" "$1"; }
hide_note() {
  echo "  A suite that already failed can hide a new failure inside it — compare the base and"
  echo "  current logs (Side-effects lens, roles/verifier.md) before calling it unrelated."
}
rnum() { # <key> <default>
  local v; v=$(rfield "$1")
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$2";; 0) printf '%s\n' "$2";; *) printf '%s\n' "$v";; esac
}

PY=""
need_python() {
  [ -n "$PY" ] && return 0
  local c real
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 || continue
    # one probe: Python 3, and the real interpreter behind a pyenv/asdf shim
    # (a shim costs a fraction of a second per bounded command); Windows paths
    # stay as found
    if real=$("$c" -c 'import os, sys; assert sys.version_info[0] == 3; print("" if os.name == "nt" else sys.executable)' 2>/dev/null); then
      PY="$c"
      if [ -n "$real" ] && [ -x "$real" ]; then PY="$real"; fi
      return 0
    fi
  done
  echo "FAIL: tools/verify.sh needs python3 for bounded execution and process groups." >&2
  echo "  A shell cannot portably time-bound a command or kill a whole process group" >&2
  echo "  (stock macOS has no timeout(1)). Install python3, or verify by hand and keep" >&2
  echo "  the evidence in evidence.md — the gates do not require a receipt." >&2
  return 1
}
# Every bounded child is started in the BACKGROUND and waited for, never run in
# the foreground: a shell does not run a trap while a foreground command is
# still running, so INT/TERM used to be deferred until the current check had
# finished on its own — up to check_timeout later. `wait` on a job IS
# interruptible, so the trap fires at once and stop_runner() then stops the
# helper, which takes the check's own process group down with it.
runner_pid=""
runner() {
  local rc=0
  "$PY" "$kit/tools/_run.py" "$@" &
  runner_pid=$!
  wait "$runner_pid" || rc=$?
  runner_pid=""
  return "$rc"
}
stop_runner() { # bounded: TERM the helper we own, wait for it, then KILL
  local pid="$runner_pid" i=0
  [ -n "$pid" ] || return 0
  runner_pid=""
  kill -TERM "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

pidfile=""
launch_state=none
cleanup_state=none
cleanup_ran=""
run_cleanup() {
  [ -n "$cleanup_ran" ] && return 0
  cleanup_ran=1
  local c rc=0
  if [ -n "$pidfile" ] && [ -f "$pidfile" ]; then
    # the whole process group, not just the shell we forked: a server that
    # exec'd a child would otherwise keep the port and "pass" the next run
    if runner stop --pidfile "$pidfile" --timeout "$(rnum cleanup_timeout 30)"; then :; else
      rc=1
      echo "CLEANUP FAILED: the runtime this run launched could not be stopped (see above)." >&2
      echo "  It is still holding whatever it holds; the next run's result would be about IT," >&2
      echo "  not about the code. Stop it before re-running." >&2
    fi
    rm -f "$pidfile"
    # the runtime wrote its own log: redact it once stopped (tools/_run.py)
    runner redact --log "${logdir:-.}/launch.log" >/dev/null 2>&1 || true
  fi
  c=$(rfield cleanup)
  if [ -n "$c" ]; then
    if runner exec --cmd "$c" --log "${logdir:-.}/cleanup.log" --timeout "$(rnum cleanup_timeout 30)"; then :; else
      rc=1
      echo "CLEANUP FAILED: 'cleanup: $c' exited non-zero or timed out — see ${logdir:-.}/cleanup.log" >&2
    fi
  fi
  [ "$rc" = 0 ] && cleanup_state=ok || cleanup_state=failed
  return 0
}
on_signal() {
  # Ignore further INT/TERM while stopping: every step below is already bounded,
  # and a second signal must not leave the launched runtime behind.
  trap '' INT TERM
  echo "" >&2
  echo "INTERRUPTED: stopping the check that is running, then what this run launched." >&2
  stop_runner
  run_cleanup
  # No receipt is written on this path: the one from an earlier run was removed
  # when this run started, so the next reader sees "no receipt", never a pass.
  echo "VERIFY interrupted: no verdict is claimed for this source." >&2
  exit 1
}

# An unfilled, malformed, or forbidden recipe is refused HERE, before a
# placeholder is handed to sh -c, a 60s doctor wait makes it look like work
# happened, or a command reaches a host the recipe forbids.
recipe_or_exit() { # <slug>
  local issue
  sdlc_auto_valid_slug "$1" || { echo "FAIL: '$1' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 2; }
  [ -d ".sdlc/work/$1" ] || { echo "FAIL: no open feature '.sdlc/work/$1'" >&2; exit 2; }
  [ -f "$recipe" ] || {
    echo "FAIL: no $recipe in this project."
    echo "  Copy $kit/templates/verify.md to $recipe and map each requirement to the"
    echo "  real command that proves it. Without it, runtime proof is not machine-checked."
    exit 2; }
  issue=$(sdlc_verify_recipe_issue "$1")
  [ -z "$issue" ] || {
    echo "FAIL: the verification recipe is not usable — ${issue#* }" >&2
    echo "  Fix $recipe (templates/verify.md) or $(sdlc_verify_feature_recipe "$1") (templates/verify-feature.md)," >&2
    echo "  then run tools/verify.sh $cmd $1 again." >&2
    exit 2; }
}

case "$cmd" in
  doctor)
    d=$(rfield doctor)
    [ -n "$d" ] || { echo "DOCTOR unconfigured: no 'doctor:' line in $recipe"; exit 2; }
    hit=$(sdlc_verify_forbidden_hit "")
    [ -z "$hit" ] || { echo "FAIL: $hit (forbidden_hosts: in $recipe) — nothing was run." >&2; exit 2; }
    need_python || exit 2
    logdir=".sdlc/scratch"; mkdir -p "$logdir"
    if runner exec --cmd "$d" --log "$logdir/doctor.log" --timeout "$(rnum doctor_attempt_timeout 30)"; then
      echo "DOCTOR ok: $d"; exit 0
    else
      rc=$?
      [ "$rc" = 124 ] && echo "DOCTOR timeout: $d did not answer within $(rnum doctor_attempt_timeout 30)s" \
                      || echo "DOCTOR fail: $d — the environment is not ready, so nothing can be verified for real"
      exit 1
    fi;;
  check)
    slug="${1:-}"; [ -n "$slug" ] || usage
    sdlc_auto_valid_slug "$slug" || { echo "FAIL: '$slug' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 2; }
    st=$(sdlc_verify_state "$slug")
    printf 'VERIFY %s: %s\n' "${st%%|*}" "${st#*|}"
    case "${st%%|*}" in ok) exit 0;; unconfigured) exit 2;; recipe) exit 2;; *) exit 1;; esac;;
  show)
    slug="${1:-}"; [ -n "$slug" ] || usage
    sdlc_auto_valid_slug "$slug" || { echo "FAIL: '$slug' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 2; }
    r=$(sdlc_verify_receipt "$slug")
    [ -f "$r" ] || { echo "no receipt: $r" >&2; exit 1; }
    cat "$r"
    b=$(sdlc_verify_baseline "$slug")
    pre=$(sdlc_field "$r" pre_existing || true)
    case "$pre" in ''|none) ;; *)
      echo ""
      echo "pre-existing: $pre — failed with the same exit status at base"
      echo "  $(sdlc_verify_baseline_label "$slug") too ($b), so not counted against this change."
      hide_note;;
    esac
    if [ -f "$b" ]; then
      echo ""
      echo "baseline: $(sdlc_verify_baseline_label "$slug") — $(sdlc_field "$b" base_sha || true)"
      sdlc_verify_baseline_usable "$slug" || echo "  (not usable: recorded for another recipe, or its base is no longer in HEAD's history)"
    fi
    exit 0;;
  coverage)
    slug="${1:-}"; [ -n "$slug" ] || usage
    recipe_or_exit "$slug"
    cov=$(sdlc_verify_coverage "$slug")
    if [ "$(sdlc_auto_track "$slug")" = compact ]; then src="intent.md O-items (compact route)"; else src="spec.md R-items (full route)"; fi
    if [ -z "$cov" ]; then
      rf=$(sdlc_verify_requirement_file "$slug")
      if [ -f "$rf" ]; then
        echo "COVERAGE uncovered: no requirement ids found in $rf ($src) — write each as"
        echo "  '- R<n>: <text>' (spec.md) or '- [ ] O<n>: <text>' (compact intent.md)"
        exit 1
      fi
      echo "COVERAGE: no $rf yet ($src) — nothing to cover yet"; exit 0
    fi
    echo "requirements: $src · profile: $(sdlc_verify_profile)"
    printf '%-12s %-11s %s\n' requirement status "checks / gap reason"
    # awk, not `read`: a tab is IFS whitespace, so an empty checks column would
    # collapse and shift the gap reason into it
    printf '%s\n' "$cov" | awk -F'\t' 'NF {
      if ($2 == "gap") printf "%-12s %-11s gap: %s%s\n", $1, $2, $4, ($3 == "" ? "" : "  (checks: " $3 ")")
      else printf "%-12s %-11s %s\n", $1, $2, ($3 == "" ? "—" : $3) }'
    bad=$(printf '%s\n' "$cov" | sdlc_verify_join '^(uncovered|no-runtime)$')
    if [ -n "$bad" ]; then
      echo "COVERAGE uncovered: $bad — add 'check: <id>[.<variant>] | <kind> | <command>' or 'gap: <id> | <reason>'"
      exit 1
    fi
    echo "COVERAGE ok"; exit 0;;
  baseline) ;;
  run) ;;
  *) usage;;
esac

# ------------------------------------------------------------------ run
slug="${1:-}"; [ -n "$slug" ] || usage
shift || true

# ------------------------------------------------------------------ baseline
if [ "$cmd" = baseline ]; then
  base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || usage; base="$2"; shift;;
      --base=*) base="${1#--base=}";;
      *) usage;;
    esac
    shift
  done
  recipe_or_exit "$slug"
  need_python || exit 2
  git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "FAIL: not a git repository — a baseline needs a base commit to check out." >&2; exit 2; }
  if [ -z "$base" ]; then
    # With uncommitted changes, HEAD is the code before them. With a clean tree
    # HEAD already CONTAINS the change, so only the human can say what "before"
    # is — the kit never guesses a branch point.
    dirty=$(git -c core.quotepath=off status --porcelain --untracked-files=all 2>/dev/null \
      | awk '{ p = substr($0, 4) } p !~ /(^|\/)\.sdlc(\/|$)/ { c++ } END { print c + 0 }')
    if [ "$dirty" -gt 0 ]; then
      base=HEAD
    else
      echo "FAIL: the working tree is clean, so HEAD already contains the change." >&2
      echo "  Name the commit before it: tools/verify.sh baseline $slug --base <ref>" >&2
      echo "  (e.g. --base main, or --base HEAD~1 for a one-commit change)." >&2
      exit 2
    fi
  fi
  base_sha=$(git rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null) || {
    echo "FAIL: '$base' names no commit here — tools/verify.sh baseline $slug --base <ref>" >&2; exit 2; }
  # "before this change" means an ancestor of what is checked now: a sibling
  # branch or an unrelated commit would compare two different histories
  git merge-base --is-ancestor "$base_sha" HEAD 2>/dev/null || {
    echo "FAIL: '$base' (${base_sha%"${base_sha#????????}"}) is not an ancestor of HEAD, so it is not the code before this change." >&2
    echo "  Name the commit this work started from: tools/verify.sh baseline $slug --base <ref>" >&2
    echo "  (git merge-base HEAD main prints it for a branch cut from main)." >&2
    exit 2; }
  prefix=$(git rev-parse --show-prefix 2>/dev/null || true)
  check_timeout=$(rnum check_timeout 900)
  bfile=$(sdlc_verify_baseline "$slug")
  blogdir=".sdlc/work/$slug/scratch/verify-base"
  # an interrupted or failed baseline leaves NO baseline, never the last one
  rm -f "$bfile" "$bfile.tmp"
  mfc=$(sdlc_verify_checks "$slug" | awk -F'\t' '$4 == "must-fail-on-base"' || true)
  # Before anything runs: the new test must reach the base, or the base runs the
  # old test (or none) and its "failure" proves nothing about this one.
  tfiles=""; ntf=0
  if [ -n "$mfc" ]; then
    tfiles=$(sdlc_verify_test_files "$base_sha")
    ntf=$(printf '%s\n' "$tfiles" | awk 'NF' | wc -l | tr -d ' ')
    if [ "$ntf" = 0 ]; then
      echo "FAIL: $(printf '%s\n' "$mfc" | sdlc_verify_join) must fail on the base WITH the new test, but no changed or added file" >&2
      echo "  matches test_paths: ($(rfield test_paths)), so there is no new test to copy into the base." >&2
      echo "  Point test_paths: in $recipe at where this feature's test lives, then re-run" >&2
      echo "  tools/verify.sh baseline $slug. No baseline is recorded." >&2
      exit 1
    fi
    # a must-fail command that runs a changed file test_paths: does not match
    # would run the OLD (or a missing) version of it at base
    chg=$(sdlc_verify_changed_files "$base_sha")
    while IFS='	' read -r id kind ccmd flag <&3; do
      [ -n "$id" ] || continue
      # ENVIRON, not -v: BSD awk refuses a newline in a -v value and -v would
      # also rewrite a backslash in the command
      miss=$(printf '%s\n' "$chg" | SDLC_C="$ccmd" SDLC_T="
$tfiles
" awk 'NF && index(ENVIRON["SDLC_C"], $0) > 0 && index(ENVIRON["SDLC_T"], "\n" $0 "\n") == 0 { print; exit }')
      if [ -n "$miss" ]; then
        echo "FAIL: must-fail-on-base check '$id' runs $miss, which changed since the base but is not" >&2
        echo "  matched by test_paths: ($(rfield test_paths)) — the base would run its old or missing version." >&2
        echo "  Add it to test_paths: in $recipe, then re-run tools/verify.sh baseline $slug." >&2
        echo "  No baseline is recorded." >&2
        exit 1
      fi
    done 3<<EOF
$mfc
EOF
  fi
  mkdir -p "$blogdir"
  # A DISPOSABLE worktree outside the project, removed on every path out: the
  # kit never stashes, resets or writes the human's tree.
  wtroot=$(mktemp -d "${TMPDIR:-/tmp}/sdlc-base.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
  wt="$wtroot/sdlc-base"; wt_admin=""
  remove_worktree() {
    [ -n "$wtroot" ] || return 0
    # the running check first: it holds files in the worktree
    stop_runner
    if [ -n "$wt_admin" ] && ! git worktree remove --force "$wt" >/dev/null 2>&1; then
      # only THIS worktree's entry: a global prune would drop the human's others
      rm -rf "$wt"
      case "$wt_admin" in */worktrees/sdlc-base*) rm -rf "$wt_admin";; esac
    fi
    rm -rf "$wtroot"
    if [ -e "$wtroot" ] || { [ -n "$wt_admin" ] && [ -e "$wt_admin" ]; }; then
      echo "WARNING: the base worktree could not be fully removed: $wtroot${wt_admin:+ (git entry $wt_admin)}" >&2
      echo "  Remove it by hand: git worktree remove --force \"$wt\"; rm -rf \"$wtroot\"" >&2
    fi
    wtroot=""
  }
  on_signal_base() {
    trap '' INT TERM HUP
    echo "" >&2
    echo "INTERRUPTED: stopping the base check that is running, removing the base worktree." >&2
    remove_worktree
    rm -f "$bfile.tmp"
    echo "BASELINE interrupted: no baseline is recorded." >&2
    exit 1
  }
  trap on_signal_base INT TERM HUP
  trap remove_worktree EXIT
  # hooks off: the human's post-checkout hook could write outside the worktree
  if ! git -c core.hooksPath=/dev/null worktree add --detach "$wt" "$base_sha" >"$blogdir/worktree.log" 2>&1; then
    echo "FAIL: could not check out $base in a temporary worktree — see $blogdir/worktree.log" >&2; exit 1; fi
  wt_admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null || true)
  here="$wt/${prefix%/}"; here="${here%/}"
  echo "baseline: $base (${base_sha%"${base_sha#????????}"}) in a disposable worktree"
  bsetup=$(rfield baseline_setup)
  if [ -n "$bsetup" ]; then
    printf '$ %s\n' "$bsetup" > "$blogdir/setup.log"
    if ! runner exec --cwd "$here" --cmd "$bsetup" --log "$blogdir/setup.log" --timeout "$check_timeout"; then
      echo "BASELINE fail: baseline_setup exited non-zero — see $blogdir/setup.log. No baseline is recorded." >&2
      exit 1
    fi
  fi
  blines=""; nbase=0; vac=""; norun=""; basefail=""
  run_base() { # <id> <kind> <command> <role>
    local log="$blogdir/$1.log" rc csha osha
    printf '$ %s\n' "$3" > "$log"
    runner exec --cwd "$here" --cmd "$3" --log "$log" --timeout "$check_timeout"
    rc=$?
    csha=$(printf '%s' "$3" | sdlc_sha256_stdin)
    osha=$(sdlc_sha256_file "$log")
    nbase=$((nbase + 1))
    blines="${blines}check: $1 | $2 | $csha | $rc | $4 | $osha | $log
"
    if [ "$4" = must-fail ]; then
      case "$rc" in
        0)  vac="$vac${vac:+, }$1"
            echo "base $1 ($2, must-fail-on-base): exit 0 — PASSES WITHOUT THE CHANGE, so it proves nothing  → $log";;
        124|126|127)
            norun="$norun${norun:+, }$1"
            echo "base $1 ($2, must-fail-on-base): exit $rc — COULD NOT RUN at base (timed out / not executable / not found), so it proves nothing  → $log";;
        *)  echo "base $1 ($2, must-fail-on-base): exit $rc — fails without the change, as it must  → $log";;
      esac
    else
      [ "$rc" = 0 ] || basefail="$basefail${basefail:+, }$1"
      echo "base $1 ($2): exit $rc  → $log"
    fi
  }
  # 1) the PROJECT recipe's build/unit/lint checks on the untouched base; 2) the
  #    must-fail-on-base checks with the changed test files (test_paths:) copied in
  while IFS='	' read -r id kind ccmd flag <&3; do
    [ -n "$id" ] && [ -z "$flag" ] || continue
    # a check named for a requirement is its proof, never pre-existing: no base run
    if sdlc_verify_covers_requirement "$slug" "$id"; then continue; fi
    case "$kind" in build|unit|lint) ;; *) continue;; esac
    nf=$(sdlc_verify_cmd_new_file "$base_sha" "$ccmd")
    if [ -n "$nf" ]; then
      echo "base $id ($kind): not run — it names $nf, which is new since the base, so it can never be pre-existing"
      continue
    fi
    run_base "$id" "$kind" "$ccmd" base
  done 3<<EOF
$(sdlc_verify_recipe_checks "$recipe")
EOF
  if [ -n "$mfc" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! { mkdir -p "$(dirname "$here/$f")" && cp -p "./$f" "$here/$f"; }; then
        echo "FAIL: could not copy $f into the base worktree. No baseline is recorded." >&2; exit 1; fi
    done <<EOF
$tfiles
EOF
    echo "copied $ntf changed/added test file(s) (test_paths: $(rfield test_paths)) into the base"
    while IFS='	' read -r id kind ccmd flag <&3; do
      [ -n "$id" ] || continue
      run_base "$id" "$kind" "$ccmd" must-fail
    done 3<<EOF
$mfc
EOF
  fi
  {
    echo "baseline_schema: sdlc-kit/verify-baseline@1"
    echo "slug: $slug"
    echo "recorded_at: $(sdlc_auto_now)"
    echo "base_ref: $base"
    echo "base_sha: $base_sha"
    echo "recipe_digest: $(sdlc_verify_recipe_digest)"
    echo "feature_recipe_digest: $(sdlc_verify_feature_recipe_digest "$slug")"
    echo "test_files: $ntf"
    echo "test_files_digest: $(sdlc_verify_test_files_digest "$base_sha")"
    echo "checks_run: $nbase"
    printf '%s' "$blines"
  } > "$bfile.tmp" && mv "$bfile.tmp" "$bfile"
  remove_worktree
  trap - EXIT INT TERM HUP
  echo "baseline: $bfile ($nbase check(s) at ${base_sha%"${base_sha#????????}"})"
  if [ -n "$basefail" ]; then
    echo "  failing at base: $basefail — the same failure (same exit status) in tools/verify.sh run"
    echo "  is labelled pre-existing. If one failed only because the fresh worktree lacks what"
    echo "  the real checkout has (installed dependencies, generated files), set 'baseline_setup:'"
    echo "  in $recipe and re-run: otherwise a real regression would read as pre-existing."
  fi
  if [ -n "$vac$norun" ]; then
    [ -z "$vac" ] || echo "VERIFY vacuous: check $vac passes without the change, so it proves nothing."
    [ -z "$norun" ] || echo "VERIFY vacuous: check $norun could not run at base, so its failure there proves nothing."
    echo "  Make the test exercise the change and run against the base (it must FAIL there,"
    echo "  not be missing), then re-run tools/verify.sh baseline $slug."
    exit 1
  fi
  exit 0
fi

# ------------------------------------------------------------------ run (cont.)
no_launch=""
while [ $# -gt 0 ]; do
  case "$1" in --no-launch) no_launch=1;; *) usage;; esac
  shift
done
recipe_or_exit "$slug"
need_python || exit 2

profile=$(sdlc_verify_profile)
logdir=".sdlc/work/$slug/scratch/verify"
mkdir -p "$logdir"
receipt=$(sdlc_verify_receipt "$slug")
# A stale receipt must not survive the start of a new run: if this run dies
# half-way, the next reader has to see "no receipt", never the last pass.
rm -f "$receipt"
src_before=$(sdlc_source_digest 2>/dev/null || echo unbound)
trap on_signal INT TERM
trap run_cleanup EXIT

# launch: start the runtime the checks need, in its own process group, and
# prove it is actually up before anything is called verified
runtime_instance=none
doctor_state=skip
launch=$(rfield launch)
if [ -n "$launch" ]; then
  if [ -n "$no_launch" ]; then
    launch_state="skipped (--no-launch)"
    runtime_instance=external
    echo "launch: SKIPPED (--no-launch) — the checks below run against an instance this"
    echo "  run did not start. Nothing here proves that instance runs the current source."
  else
    echo "launch: $launch"
    pidfile="$logdir/launch.pid"
    if runner launch --cmd "$launch" --log "$logdir/launch.log" --pidfile "$pidfile"; then
      launch_state="started (pgid $(cat "$pidfile" 2>/dev/null || echo ?))"
      runtime_instance=owned
    else
      launch_state=failed
      runtime_instance=none
      echo "launch: FAILED — it exited immediately; see $logdir/launch.log"
    fi
  fi
fi

if [ -n "$(rfield doctor)" ]; then
  wait_s=$(rnum doctor_timeout 60)
  att_s=$(rnum doctor_attempt_timeout 30)
  waited=0
  while :; do
    if runner exec --cmd "$(rfield doctor)" --log "$logdir/doctor.log" --timeout "$att_s" >/dev/null 2>&1; then
      # It answered. But if THIS run launched a runtime and that runtime is
      # already dead, the thing that answered is somebody else's process — an
      # old build still holding the port. That is not evidence about this source.
      if [ "$runtime_instance" = owned ] && ! runner alive --pidfile "$pidfile" >/dev/null 2>&1; then
        doctor_state="unowned-runtime"
        echo "doctor: ANSWERED, but the runtime this run launched is already dead."
        echo "  Something else is serving that endpoint (an older instance still holding the"
        echo "  port, most likely). Nothing below would be evidence about this source."
      else
        doctor_state=pass
      fi
      break
    fi
    if [ "$runtime_instance" = owned ] && ! runner alive --pidfile "$pidfile" >/dev/null 2>&1; then
      doctor_state="fail (the launched runtime exited; see $logdir/launch.log)"
      break
    fi
    [ "$waited" -ge "$wait_s" ] && { doctor_state="fail (after ${wait_s}s)"; break; }
    sleep 2; waited=$((waited + 2))
  done
  echo "doctor: $doctor_state"
elif [ "$runtime_instance" = owned ]; then
  # no doctor configured: the only thing that can be asserted is that the
  # process this run started is still alive
  if runner alive --pidfile "$pidfile" >/dev/null 2>&1; then
    echo "launch: alive (no doctor: line — readiness is not proven, only the process is)"
  else
    launch_state=failed
    echo "launch: the launched runtime exited before any check ran; see $logdir/launch.log"
  fi
fi

result=pass
runtime_evidence=no
checks=""
checks_configured=$(sdlc_verify_checks "$slug" | grep -c . || true)
pre_existing=""
if [ -f "$(sdlc_verify_baseline "$slug")" ] && ! sdlc_verify_baseline_usable "$slug"; then
  echo "note: $(sdlc_verify_baseline "$slug") was recorded for a different recipe, or at a base no longer in HEAD's history — ignored;"
  echo "  no failure below can be called pre-existing until tools/verify.sh baseline $slug is re-run."
fi
checks_run=0
check_timeout=$(rnum check_timeout 900)
case "$doctor_state" in
  fail*|unowned-runtime*) result=fail;;
  *)
    if [ "$launch_state" = failed ]; then
      result=fail
    else
      # fd 3, never stdin: a check that reads stdin (ssh, docker compose run
      # without -T, mvn) used to swallow the rest of the recipe and the run
      # still said "ok". Each check also gets its own /dev/null stdin, inside
      # tools/_run.py.
      while IFS='	' read -r id kind ccmd flag <&3; do
        [ -n "$id" ] || continue
        log="$logdir/$id.log"
        printf '$ %s\n' "$ccmd" > "$log"
        runner exec --cmd "$ccmd" --log "$log" --timeout "$check_timeout"
        rc=$?
        checks_run=$((checks_run + 1))
        csha=$(printf '%s' "$ccmd" | sdlc_sha256_stdin)
        osha=$(sdlc_sha256_file "$log")
        if [ "$rc" = 124 ]; then
          echo "check $id ($kind): TIMED OUT after ${check_timeout}s  → $log"
        else
          echo "check $id ($kind): exit $rc  → $log"
        fi
        # a failing runtime/e2e check runs once more (passing then = flaky); any
        # other failure may be pre-existing (sdlc_verify_preexisting_ok)
        label=""
        if [ "$rc" != 0 ] && { [ "$kind" = runtime ] || [ "$kind" = e2e ]; }; then
          rlog="$logdir/$id.rerun.log"
          printf '$ %s\n' "$ccmd" > "$rlog"
          if runner exec --cmd "$ccmd" --log "$rlog" --timeout "$check_timeout"; then
            label="flaky (re-run exit 0: $rlog)"
            [ "$result" = pass ] && result=flaky
            echo "  ↳ flaky: it failed (exit $rc), then passed on one re-run  → $rlog"
          else
            echo "  ↳ re-run: failed again (exit $?)  → $rlog"
            result=fail
          fi
        elif [ "$rc" != 0 ]; then
          if sdlc_verify_preexisting_ok "$slug" "$id" "$kind" "$csha" "$flag" "$rc"; then
            label=pre-existing; pre_existing="$pre_existing${pre_existing:+ }$id"
            echo "  ↳ pre-existing: it failed with exit $rc at base $(sdlc_verify_baseline_label "$slug") too — not counted against this change"
          else
            result=fail
          fi
        fi
        case "$kind" in runtime|e2e) [ "$rc" = 0 ] && runtime_evidence=yes;; esac
        checks="${checks}check: $id | $kind | $rc | $csha | $osha | $log${label:+ | $label}
"
      done 3<<EOF
$(sdlc_verify_checks "$slug")
EOF
    fi;;
esac

if [ "$checks_run" != "$checks_configured" ] && [ "$result" = pass ]; then
  echo "VERIFY inconclusive: $checks_run of $checks_configured configured checks ran." >&2
  result=inconclusive
fi

run_cleanup
trap - EXIT INT TERM

# The source is re-hashed AFTER the run: a check that writes into the tree
# (coverage output, a generated fixture) makes the receipt describe a snapshot
# that no longer exists. Saying so is the only honest answer — the old code
# returned 0 and then reported `stale` forever, which livelocked the driver.
src_after=$(sdlc_source_digest 2>/dev/null || echo unbound)
[ "$src_before" = "$src_after" ] || result=inconclusive

{
  echo "receipt_schema: sdlc-kit/verify-receipt@1"
  echo "slug: $slug"
  echo "recorded_at: $(sdlc_auto_now)"
  echo "source_digest_before: $src_before"
  echo "source_digest_after: $src_after"
  echo "source_digest: $src_after"
  echo "git_head: $(git rev-parse --verify --quiet HEAD 2>/dev/null || echo none)"
  echo "recipe_digest: $(sdlc_verify_recipe_digest)"
  echo "feature_recipe_digest: $(sdlc_verify_feature_recipe_digest "$slug")"
  if sdlc_verify_baseline_usable "$slug"; then
    echo "baseline: $(sdlc_field "$(sdlc_verify_baseline "$slug")" base_sha || true)"
  else echo "baseline: none"; fi
  echo "pre_existing: ${pre_existing:-none}"
  echo "profile: $profile"
  echo "launch: $launch_state"
  echo "runtime_instance: $runtime_instance"
  echo "doctor: $doctor_state"
  echo "cleanup: $cleanup_state"
  echo "environment: $(rfield environment)"
  echo "checks_configured: $checks_configured"
  echo "checks_run: $checks_run"
  echo "runtime_evidence: $runtime_evidence"
  echo "result: $result"
  printf '%s' "$checks"
  # requirements the recipe deliberately leaves unchecked, in its own words
  sdlc_verify_gaps "$slug" | awk -F'\t' 'NF { print "gap: " $1 " | " $2 }'
} > "$receipt"

echo "receipt: $receipt (source $(printf '%s' "$src_after" | cut -c1-8)…, result $result)"
if [ "$cleanup_state" = failed ]; then
  echo "VERIFY blocked: the run could not stop what it started. Nothing is claimed about this"
  echo "  source until the leftover runtime is gone."
  exit 1
fi
if [ "$src_before" != "$src_after" ]; then
  echo "VERIFY inconclusive: the source changed WHILE the checks ran"
  echo "  (before ${src_before%"${src_before#????????}"}…, after ${src_after%"${src_after#????????}"}…),"
  echo "  so these results describe no single snapshot. A check is writing into the tree:"
  echo "  send its output to .sdlc/work/$slug/scratch/ or .gitignore it, then re-run."
  exit 1
fi
if [ "$result" = inconclusive ]; then
  echo "VERIFY inconclusive: the run did not reach a verdict over every configured check."
  exit 1
fi
if [ "$result" = fail ]; then
  echo "VERIFY fail: a configured check failed — the logs above are the evidence."
  exit 1
fi
# pass or flaky: the state below says which, in the words every gate reads
st=$(sdlc_verify_state "$slug")
case "${st%%|*}" in
  ok) ;;
  *) printf 'VERIFY %s: %s\n' "${st%%|*}" "${st#*|}"; exit 1;;
esac
if [ -n "$pre_existing" ]; then
  echo "VERIFY ok: $checks_run/$checks_configured configured checks ran over this source; every failure is"
  echo "  pre-existing (it failed with the same exit status at base $(sdlc_verify_baseline_label "$slug") too): $pre_existing"
  hide_note
else
  echo "VERIFY ok: every configured check ($checks_run/$checks_configured) passed over this source."
fi
gaps=$(sdlc_verify_gaps "$slug" | sdlc_verify_join)
[ -z "$gaps" ] || echo "  gap (recipe gap: line, not checked): $gaps"
