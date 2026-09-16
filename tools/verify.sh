#!/usr/bin/env bash
# verify.sh — run this project's verification recipe and record a receipt that is
# bound to the source it was produced from. Run from the project root.
#
#   tools/verify.sh run <slug> [--no-launch]   execute the recipe, write the receipt
#   tools/verify.sh check <slug>               is the receipt still worth anything?
#   tools/verify.sh doctor                     is the runtime environment ready?
#   tools/verify.sh show <slug>                print the receipt
#
# The recipe is `.sdlc/verify.md` (seed it from templates/verify.md). It maps each
# requirement to the REAL project command that proves it, and names the optional
# launch / doctor / cleanup commands around them.
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
# Exit: 0 pass · 1 fail/stale/blocked/inconclusive · 2 no recipe, unusable
# recipe, missing python3, or usage error.
set -uo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit/gates/_common.sh"
. "$kit/gates/_auto.sh"

usage() { echo "usage: verify.sh <run|check|show> <slug> [--no-launch] | verify.sh doctor" >&2; exit 2; }
[ $# -ge 1 ] || usage
cmd="$1"; shift
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root." >&2; exit 2; }
recipe=$(sdlc_verify_recipe)

rfield() { sdlc_verify_field "$recipe" "$1"; }
rnum() { # <key> <default>
  local v; v=$(rfield "$1")
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$2";; 0) printf '%s\n' "$2";; *) printf '%s\n' "$v";; esac
}

PY=""
need_python() {
  [ -n "$PY" ] && return 0
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' 2>/dev/null; then
      PY="$c"; return 0
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

case "$cmd" in
  doctor)
    d=$(rfield doctor)
    [ -n "$d" ] || { echo "DOCTOR unconfigured: no 'doctor:' line in $recipe"; exit 2; }
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
    cat "$r"; exit 0;;
  run) ;;
  *) usage;;
esac

# ------------------------------------------------------------------ run
slug="${1:-}"; [ -n "$slug" ] || usage
shift || true
no_launch=""
while [ $# -gt 0 ]; do
  case "$1" in --no-launch) no_launch=1;; *) usage;; esac
  shift
done
sdlc_auto_valid_slug "$slug" || { echo "FAIL: '$slug' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 2; }
[ -d ".sdlc/work/$slug" ] || { echo "FAIL: no open feature '.sdlc/work/$slug'" >&2; exit 2; }
[ -f "$recipe" ] || {
  echo "FAIL: no $recipe in this project."
  echo "  Copy $kit/templates/verify.md to $recipe and map each requirement to the"
  echo "  real command that proves it. Without it, runtime proof is not machine-checked."
  exit 2; }

# An unfilled or malformed recipe is refused HERE, before a placeholder is
# handed to sh -c and a 60s doctor wait makes it look like work happened.
issue=$(sdlc_verify_recipe_issue)
[ -z "$issue" ] || {
  echo "FAIL: $recipe is not usable — ${issue#* }" >&2
  echo "  Fix the recipe (templates/verify.md), then run tools/verify.sh run $slug again." >&2
  exit 2; }
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
checks_configured=$(sdlc_verify_recipe_checks | grep -c . || true)
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
      while IFS='	' read -r id kind ccmd <&3; do
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
        [ "$rc" = 0 ] || result=fail
        case "$kind" in runtime|e2e) [ "$rc" = 0 ] && runtime_evidence=yes;; esac
        checks="${checks}check: $id | $kind | $rc | $csha | $osha | $log
"
      done 3<<EOF
$(sdlc_verify_recipe_checks)
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
if [ "$result" != pass ]; then
  echo "VERIFY fail: a configured check failed — the logs above are the evidence."
  exit 1
fi
st=$(sdlc_verify_state "$slug")
case "${st%%|*}" in
  ok) ;;
  *) printf 'VERIFY %s: %s\n' "${st%%|*}" "${st#*|}"; exit 1;;
esac
echo "VERIFY ok: every configured check ($checks_run/$checks_configured) passed over this source."
