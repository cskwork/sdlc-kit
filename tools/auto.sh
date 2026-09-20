#!/usr/bin/env bash
# auto.sh — the machine entrypoint of sdlc-kit. Run from the project root.
#
#   tools/auto.sh status [--json] [slug]   machine state of the open features
#   tools/auto.sh next <slug>              one line + an exit code for a driver
#   tools/auto.sh intent-check <slug>      the full-auto intent contract
#   tools/auto.sh checkpoint <slug> …      pending execution metadata (resume)
#
# WHAT THIS IS: a reporter over the artifacts and approval records that already
# exist, plus a place to record attempts and completed external effects. Every
# gate verdict is taken from gates/_common.sh — the same functions check-gate.sh
# and close.sh use — so this view can never be more permissive than the gates.
#
# WHAT THIS IS NOT: an agent. It runs no model, writes no artifact, and performs
# no stage. `status: ready` means "the next action is one this project's
# lazymode lets an agent take" — an LLM under the stage skills still does it.
#
# Exit codes of `next` (for a host scheduler such as Symphony):
#   0 ready · 10 needs-human · 20 blocked · 30 complete · 1 usage/environment
set -euo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit/gates/_common.sh"
. "$kit/gates/_auto.sh"

usage() {
  cat >&2 <<'EOF'
usage (from the project root):
  tools/auto.sh status [--json] [--no-remote-check] [slug]
  tools/auto.sh next <slug> [--no-remote-check]
  tools/auto.sh intent-check <slug>
  tools/auto.sh checkpoint <slug> [--show | --set-step <step> | --attempt <step> --class <transient|deterministic>
                                   | --effect "<kind>|<detail>" | --clear]
EOF
  exit 1
}
[ $# -ge 1 ] || usage
cmd="$1"; shift
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here. Run init.sh first, from the project root." >&2; exit 1; }
# The machine view reports gate verdicts and records checkpoint state, so it is
# bound to the owning checkout exactly like the gates (_common.sh).
sdlc_store_owner_ok || exit 1

# Remote verification is ON by default for a delivery that claims a remote
# branch: a handoff the loop cannot see is not a handoff. `--no-remote-check`
# is for a poll that must touch no network — it then reports
# `remote_verdict: not-checked` and refuses to call anything review-ready.
# `--remote-check` is kept as an explicit no-op so existing drivers keep working.
REMOTE_CHECK=1
JSON=""
slug=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1;;
    --remote-check) REMOTE_CHECK=1;;
    --no-remote-check) REMOTE_CHECK="";;
    --*) break;;
    *) slug="$1";;
  esac
  shift
done

# An unknown flag must not be swallowed silently: a driver that asked for
# something this version does not implement has to hear about it.
case "$cmd" in
  status|next|intent-check) [ $# -eq 0 ] || { echo "FAIL: unknown option '$1'" >&2; usage; };;
esac

# ---------------------------------------------------------------- evaluation
# Every field of the machine view is set here, once, by one decision table.
EV_STAGE=""; EV_STATUS=""; EV_NEXT_KIND=""; EV_NEXT_CMD=""; EV_NEXT_TEXT=""
EV_BLOCKERS=""; EV_GAPS=""; EV_EXIT=""; EV_TRACK=""
EV_SRC_STATE=""; EV_SRC_WANT=""; EV_SRC_NOW=""
EV_VERIFY=""; EV_VERIFY_DETAIL=""; EV_INTENT=""; EV_INTENT_DETAIL=""
EV_DELIVERY=""; EV_DELIVERY_DETAIL=""; EV_DELIVERY_TARGET=""; EV_HANDOFF=""
EV_REMOTE=""; EV_BRANCH=""; EV_REMOTE_SHA=""; EV_REMOTE_VERDICT=""
EV_CHECKPOINT=""; EV_CHECKPOINT_DETAIL=""; EV_CHECKPOINT_STEP=""

add_blocker() { EV_BLOCKERS="$EV_BLOCKERS$1|$2
"; }
add_gap()     { EV_GAPS="$EV_GAPS$1|$2
"; }
set_next() { EV_NEXT_KIND="$1"; EV_NEXT_CMD="$2"; EV_NEXT_TEXT="$3"; }

skill_dir_for() { case "$1" in
  intent) echo skills/1-intent;; spec) echo skills/2-spec;; plan) echo skills/3-plan;;
  ship) echo skills/5-ship;; *) echo skills;; esac; }

planned_target() { # <slug> → local | pr | deploy | unknown  (what the loop agreed on)
  local dir=".sdlc/work/$1" v=""
  if [ -f "$dir/delivery.md" ]; then
    v=$(sdlc_delivery_field "$dir/delivery.md" Target | awk '{print tolower($1)}')
  fi
  if [ -z "$v" ] && [ -f "$dir/intent.md" ]; then
    v=$(awk '/^- *Delivery target:/{sub(/^[^:]*: */,""); print tolower($1); exit}' "$dir/intent.md")
  fi
  if [ -z "$v" ] && [ -f "$dir/spec.md" ]; then
    v=$(awk '/[Rr]elease procedure/{ if (match(tolower($0), /local|deploy|pr/)) { print substr(tolower($0), RSTART, RLENGTH); exit } }' "$dir/spec.md")
  fi
  case "$v" in local|pr|deploy) printf '%s\n' "$v";; *) echo unknown;; esac
}

evaluate() { # <slug>
  local s="$1" dir=".sdlc/work/$1" st detail stage rec loop art tier scope delivered_sha
  EV_STAGE=""; EV_STATUS=""; EV_BLOCKERS=""; EV_GAPS=""; EV_EXIT=open
  EV_NEXT_KIND=""; EV_NEXT_CMD=""; EV_NEXT_TEXT=""
  EV_SRC_STATE=""; EV_SRC_WANT=""; EV_SRC_NOW=""
  EV_VERIFY=""; EV_VERIFY_DETAIL=""; EV_INTENT=""; EV_INTENT_DETAIL=""
  EV_FIXLOOP=""; EV_FIXLOOP_DETAIL=""
  EV_DELIVERY=""; EV_DELIVERY_DETAIL=""; EV_DELIVERY_TARGET=""; EV_HANDOFF=""
  EV_REMOTE=""; EV_BRANCH=""; EV_REMOTE_SHA=""; EV_REMOTE_VERDICT="not-checked"
  EV_TRACK=$(sdlc_auto_track "$s")
  EV_DELIVERY_TARGET=$(planned_target "$s")

  st=$(sdlc_checkpoint_state "$s"); EV_CHECKPOINT="${st%%|*}"; EV_CHECKPOINT_DETAIL="${st#*|}"
  EV_CHECKPOINT_STEP=$(sdlc_field "$(sdlc_checkpoint_file "$s")" step 2>/dev/null || true)

  st=$(sdlc_auto_intent_contract "$s"); EV_INTENT="${st%%|*}"; EV_INTENT_DETAIL="${st#*|}"
  st=$(sdlc_verify_state "$s");        EV_VERIFY="${st%%|*}"; EV_VERIFY_DETAIL="${st#*|}"
  st=$(sdlc_auto_fixloop_state "$s");  EV_FIXLOOP="${st%%|*}"; EV_FIXLOOP_DETAIL="${st#*|}"

  if [ -f "$dir/CLOSED" ]; then
    EV_STAGE=closed; EV_STATUS=complete
    EV_EXIT=$(sdlc_auto_handoff_target "$dir/delivery.md")
    case "$EV_EXIT" in unknown) EV_EXIT=closed;; esac
    set_next none "" "closed: $(grep '^state: ' "$dir/CLOSED" | cut -d' ' -f2-)"
    return 0
  fi

  # map-first and legacy-compressed features: the next action is not an artifact
  if [ -f "$dir/map.md" ] && [ ! -f "$dir/intent.md" ]; then
    EV_STAGE=map; EV_STATUS=ready
    set_next write "" "resolve the top Unknown in $dir/map.md (skills/1-intent 'Chart a map first')"
    return 0
  fi
  if [ ! -f "$dir/intent.md" ] && [ -f "$dir/plan.md" ]; then
    EV_STAGE=intent; EV_STATUS=ready
    set_next write "" "legacy compressed feature: write $dir/intent.md (Track: compact), then pass the intent gate"
    return 0
  fi

  loop="intent spec plan ship"
  [ "$EV_TRACK" = compact ] && loop="intent ship"
  for stage in $loop; do
    art="$dir/$(sdlc_auto_artifact_for "$stage")"
    rec=".sdlc/approvals/${s}.${stage}.approval"
    st=$(sdlc_auto_stage_state "$s" "$stage"); detail="${st#*|}"; st="${st%%|*}"
    case "$st" in
      absent)
        if [ "$stage" = ship ]; then
          # evidence.md missing means the work itself is still open: build and
          # the independent verification come before the ship artifact
          EV_STAGE=build
          if [ "$EV_FIXLOOP" = exhausted ]; then
            # the fix loop hit its cap (skills/4-build): a human decides, at every
            # lazymode — no verification state makes this 'ready'
            EV_STATUS=needs-human; add_blocker fixloop.exhausted "$EV_FIXLOOP_DETAIL"
            set_next human "" "$EV_FIXLOOP_DETAIL"
          else case "$EV_VERIFY" in
            fail|invalid) EV_STATUS=blocked; add_blocker verify.fail "$EV_VERIFY_DETAIL"
                     set_next verify "tools/verify.sh run $s" "the verification is not satisfied over this source — fix it, then re-run";;
            blocked) EV_STATUS=blocked; add_blocker verify.environment "$EV_VERIFY_DETAIL"
                     set_next human "" "no runnable verification environment: $EV_VERIFY_DETAIL";;
            recipe)  EV_STATUS=blocked; add_blocker verify.recipe "$EV_VERIFY_DETAIL"
                     set_next write "" "$EV_VERIFY_DETAIL";;
            missing|stale|inconclusive)
                     EV_STATUS=ready
                     set_next verify "tools/verify.sh run $s" "build per skills/4-build, then record the verification receipt";;
            unconfigured)
                     EV_STATUS=ready; add_gap verify.unconfigured "$EV_VERIFY_DETAIL"
                     set_next build "" "build and verify per skills/4-build + roles/verifier.md, then write $art";;
            ok)      EV_STATUS=ready
                     set_next write "" "write $art (templates/evidence.md), quoting the receipt's deciding lines";;
          esac; fi
        else
          EV_STAGE="$stage"; EV_STATUS=ready
          set_next write "" "write $art (see $(skill_dir_for "$stage"))"
        fi
        return 0;;
      stale)
        EV_STAGE="$stage"; EV_STATUS=blocked
        add_blocker "gate.stale.$stage" "$detail"
        set_next approve "" "$detail"
        return 0;;
      pending)
        EV_STAGE="$stage"
        # the intent contract decides whether an unattended run may act at all
        if [ "$stage" = intent ]; then
          case "$EV_INTENT" in
            material)   EV_STATUS=needs-human; add_blocker intent.material "$EV_INTENT_DETAIL"
                        set_next human "" "answer the MATERIAL question(s) in $art, then the intent gate"
                        return 0;;
            incomplete) EV_STATUS=blocked; add_blocker intent.incomplete "$EV_INTENT_DETAIL"
                        set_next write "" "complete $art: $EV_INTENT_DETAIL"
                        return 0;;
          esac
        fi
        if [ "$stage" = ship ]; then
          case "$EV_VERIFY" in
            fail|invalid) EV_STATUS=blocked; add_blocker verify.fail "$EV_VERIFY_DETAIL"
                     set_next verify "tools/verify.sh run $s" "$EV_VERIFY_DETAIL"; return 0;;
            blocked) EV_STATUS=blocked; add_blocker verify.environment "$EV_VERIFY_DETAIL"
                     set_next human "" "$EV_VERIFY_DETAIL"; return 0;;
            recipe)  EV_STATUS=blocked; add_blocker verify.recipe "$EV_VERIFY_DETAIL"
                     set_next write "" "$EV_VERIFY_DETAIL"; return 0;;
            missing|stale|inconclusive)
                     EV_STATUS=blocked; add_blocker verify.stale "$EV_VERIFY_DETAIL"
                     set_next verify "tools/verify.sh run $s" "$EV_VERIFY_DETAIL"; return 0;;
            unconfigured) add_gap verify.unconfigured "$EV_VERIFY_DETAIL";;
          esac
        fi
        if [ "$stage" = ship ] && [ "$EV_FIXLOOP" = exhausted ]; then
          # evidence.md written over an exhausted fix loop: the ship gate is the
          # human's, whatever the lazymode (AGENTS.md rule 3, blocker past its cap)
          EV_STATUS=needs-human; add_blocker fixloop.exhausted "$EV_FIXLOOP_DETAIL"
          set_next human "gates/approve.sh ship $art" "$EV_FIXLOOP_DETAIL"; return 0
        fi
        if [ "$LAZY" -ge "$(sdlc_auto_lazy_min "$stage")" ]; then
          EV_STATUS=ready
          set_next approve "gates/approve.sh $stage $art --lazy --review \"<the review you ran over the affected code and behavior>\"" \
            "lazymode $LAZY waives the $stage human gate: review the affected code and behavior, then record the approval"
        elif [ "$stage" = plan ]; then
          tier=$(grep -qiE '^- *[Tt]ier: *human' "$art" && echo human || echo agent)
          if [ "$tier" = human ]; then
            EV_STATUS=needs-human; add_blocker gate.human.plan "plan.md declares Tier: human (a trip-wire) — the plan gate is a human decision"
            set_next human "gates/approve.sh plan $art" "show the human the plan's Human summary and trip-wires"
          else
            EV_STATUS=ready
            set_next approve "gates/approve.sh plan $art --agent-adversary" "tiered plan gate: after a clean adversary review"
          fi
        else
          EV_STATUS=needs-human; add_blocker "gate.human.$stage" "lazymode $LAZY keeps the $stage gate human"
          set_next human "gates/approve.sh $stage $art" "ask the human to approve $art"
        fi
        return 0;;
      approved) ;;
    esac
    if [ "$stage" = ship ]; then
      read -r EV_SRC_STATE EV_SRC_WANT EV_SRC_NOW <<EOF
$(sdlc_source_state "$rec")
EOF
      case "$EV_SRC_STATE" in
        ok|unbound) ;;
        *) EV_STAGE=ship; EV_STATUS=blocked
           add_blocker "source.$EV_SRC_STATE" "the ship source binding is '$EV_SRC_STATE' — re-run the ship review, then gates/approve.sh ship $art"
           set_next approve "gates/approve.sh ship $art" "the reviewed source no longer matches the working tree"
           return 0;;
      esac
    fi
  done

  # --- everything is approved: delivery and the review handoff ---------------
  EV_STAGE=delivery
  EV_DELIVERY_TARGET=$(planned_target "$s")
  if [ ! -f "$dir/delivery.md" ]; then
    EV_DELIVERY=absent; EV_DELIVERY_DETAIL="no delivery.md yet"
    # What the next action is depends on WHERE the loop agreed to deliver, and on
    # whether the human's recorded scope authorizes leaving the repository at
    # all. An agent filling "<the human's authorization>" into its own command
    # line is not authorization (AGENTS.md rule 3).
    case "$EV_DELIVERY_TARGET" in
      local)
        EV_STATUS=ready
        set_next deliver "" "local delivery: run the agreed proof here and record it in $dir/delivery.md (templates/delivery.md). Nothing is pushed — a local target has no remote review branch.";;
      pr)
        if sdlc_auto_scope_allows_publish "$s"; then
          scope=$(sdlc_auto_scope_authorization "$s")
          EV_STATUS=ready
          set_next deliver "tools/handoff.sh push $s --authorized \"$scope\"" \
            "publish the review branch within the scope intent.md records, then write $dir/delivery.md (Target, Source, Remote, Branch, Handoff: review-ready)"
        else
          EV_STATUS=needs-human
          add_blocker handoff.unauthorized-scope "the delivery target is 'pr' but intent.md's Scope authorization does not name publishing a branch (push / PR / review branch) — an agent may not authorize an external effect for itself"
          set_next human "" "ask the human whether this may be pushed for review; record their words in intent.md's '- Scope authorization:' line, re-run the intent gate, then deliver"
        fi;;
      deploy)
        EV_STATUS=needs-human
        add_blocker handoff.human "a deploy delivery leaves the review boundary: it needs its own human authorization, whatever the lazymode (AGENTS.md rule 3)"
        set_next human "" "ask the human to authorize the deploy; the loop may push the feature branch and stop there";;
      *)
        EV_STATUS=needs-human
        add_blocker delivery.target-unknown "no delivery target is recorded (intent.md '- Delivery target:' / delivery.md 'Target:'), so what 'shipped' has to prove is unknown — the loop does not pick one, and never pushes on a guess"
        set_next human "" "ask the human which delivery this is (local | pr | deploy), record it in intent.md, then deliver";;
    esac
    return 0
  fi
  st=$(sdlc_delivery_issue "$dir/delivery.md" "$EV_SRC_STATE" "$EV_SRC_WANT" "$EV_SRC_NOW")
  EV_DELIVERY="${st%% *}"; EV_DELIVERY_DETAIL="${st#* }"
  EV_HANDOFF=$(sdlc_auto_handoff_target "$dir/delivery.md")
  EV_BRANCH=$(sdlc_delivery_field "$dir/delivery.md" Branch)
  EV_REMOTE=$(sdlc_delivery_field "$dir/delivery.md" Remote)
  case "$EV_DELIVERY" in
    ok|unbound) ;;
    *) EV_STATUS=blocked; add_blocker "delivery.$EV_DELIVERY" "$EV_DELIVERY_DETAIL"
       set_next deliver "" "fix the delivery record ($dir/delivery.md): $EV_DELIVERY_DETAIL"
       return 0;;
  esac
  case "$EV_HANDOFF" in
    merged|deployed)
      if [ -z "$(sdlc_delivery_field "$dir/delivery.md" Authorized-by)" ]; then
        EV_STATUS=needs-human
        add_blocker handoff.unauthorized "Handoff: $EV_HANDOFF without an Authorized-by line — merge and deploy need a separately bound human approval"
        set_next human "" "record the human's authorization in $dir/delivery.md (Authorized-by:), or downgrade the handoff to review-ready"
        return 0
      fi
      # An Authorized-by line is a RECORD of the human's words, not proof that
      # the merge or the deployment happened: nothing in this repository can see
      # a merge commit on someone else's branch or a running deployment.
      add_gap handoff.external-proof "'$EV_HANDOFF' is not verified by this kit: a feature ref on a remote is not a merge commit and not a deployment. The proof of that step is external (the human's, or the deployment system's) and belongs in delivery.md's Verified-by/Evidence lines";;
  esac
  # A handoff that claims a remote branch must NAME one. Without Remote and
  # Branch there is nothing to check, and 'review-ready' would be prose.
  case "$EV_HANDOFF" in
    review-ready|merged|deployed)
      if [ -z "$EV_BRANCH" ] || [ -z "$EV_REMOTE" ]; then
        EV_STATUS=blocked
        add_blocker handoff.incomplete "Handoff: $EV_HANDOFF but $dir/delivery.md names no Remote/Branch — the reviewer's target cannot be verified, so it is not review-ready"
        set_next deliver "" "add '- Remote: <remote>' and '- Branch: <feature branch>' to $dir/delivery.md (templates/delivery.md), then re-check"
        return 0
      fi
      delivered_sha=$(git rev-parse "$(sdlc_delivery_field "$dir/delivery.md" Source)^{commit}" 2>/dev/null || echo none)
      if [ -z "$REMOTE_CHECK" ]; then
        # network-free poll: say exactly that, and claim nothing
        EV_REMOTE_VERDICT=not-checked
        EV_EXIT=open
        EV_STATUS=ready
        add_gap handoff.not-checked "--no-remote-check: $EV_REMOTE/$EV_BRANCH was not contacted, so this run knows nothing about the review branch and does not call it review-ready"
        set_next deliver "tools/handoff.sh check $s" \
          "verify the review branch against the remote before anything is closed as shipped"
        return 0
      fi
      EV_REMOTE_SHA=$(git ls-remote "$EV_REMOTE" "refs/heads/$EV_BRANCH" 2>/dev/null | awk 'NR==1{print $1}')
      if [ -z "$EV_REMOTE_SHA" ]; then
        EV_REMOTE_VERDICT=absent; EV_STATUS=blocked; EV_EXIT=open
        add_blocker handoff.remote-absent "$EV_REMOTE/$EV_BRANCH does not exist on the remote — the review target was never pushed, whatever delivery.md says"
        set_next deliver "" "push the feature branch (tools/handoff.sh push $s), then re-check"
        return 0
      elif [ "$EV_REMOTE_SHA" != "$delivered_sha" ]; then
        EV_REMOTE_VERDICT=mismatch; EV_STATUS=blocked; EV_EXIT=open
        add_blocker handoff.remote-mismatch "$EV_REMOTE/$EV_BRANCH is at $EV_REMOTE_SHA, not the delivered commit — the reviewer would read other code"
        set_next deliver "" "push the delivered commit to $EV_REMOTE/$EV_BRANCH, or correct delivery.md"
        return 0
      else
        EV_REMOTE_VERDICT=match
      fi;;
  esac
  EV_EXIT="$EV_HANDOFF"
  EV_STATUS=ready
  set_next close "gates/close.sh $s shipped \"<reason>\"" \
    "delivery confirmed (${EV_HANDOFF}) — close the feature; human review of the branch happens outside this loop"
}

# ---------------------------------------------------------------- rendering
LAZY=$(sdlc_auto_lazymode)

heartbeat_line() { [ -s ".sdlc/work/$1/progress.md" ] && head -n1 ".sdlc/work/$1/progress.md" | tr -d '\r' || true; }
heartbeat_age() { # <slug> → seconds or empty
  local f=".sdlc/work/$1/progress.md" mt
  [ -s "$f" ] || return 0
  mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true)
  case "$mt" in (''|*[!0-9]*) return 0;; esac
  echo $(( $(date +%s) - mt ))
}

emit_blockers_json() { # <list>
  local first=1 line code detail
  printf '['
  printf '%s' "$1" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    code="${line%%|*}"; detail="${line#*|}"
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"code":%s,"detail":%s}' "$(sdlc_json_str "$code")" "$(sdlc_json_str "$detail")"
  done
  printf ']'
}

feature_json() { # <slug>
  local s="$1" hb age
  hb=$(heartbeat_line "$s"); age=$(heartbeat_age "$s")
  printf '    {\n'
  printf '      "slug": %s,\n' "$(sdlc_json_str "$s")"
  printf '      "track": %s,\n' "$(sdlc_json_str "$EV_TRACK")"
  printf '      "stage": %s,\n' "$(sdlc_json_str "$EV_STAGE")"
  printf '      "status": %s,\n' "$(sdlc_json_str "$EV_STATUS")"
  printf '      "exit_condition": %s,\n' "$(sdlc_json_str "$EV_EXIT")"
  printf '      "next_action": {"kind": %s, "command": %s, "text": %s},\n' \
    "$(sdlc_json_str "$EV_NEXT_KIND")" "$(sdlc_json_str "$EV_NEXT_CMD")" "$(sdlc_json_str "$EV_NEXT_TEXT")"
  printf '      "blockers": '; emit_blockers_json "$EV_BLOCKERS"; printf ',\n'
  printf '      "gaps": '; emit_blockers_json "$EV_GAPS"; printf ',\n'
  printf '      "intent_contract": {"state": %s, "detail": %s},\n' \
    "$(sdlc_json_str "$EV_INTENT")" "$(sdlc_json_str "$EV_INTENT_DETAIL")"
  printf '      "fix_loop": {"state": %s, "detail": %s},\n' \
    "$(sdlc_json_str "$EV_FIXLOOP")" "$(sdlc_json_str "$EV_FIXLOOP_DETAIL")"
  printf '      "verification": {"state": %s, "profile": %s, "detail": %s, "receipt": %s},\n' \
    "$(sdlc_json_str "$EV_VERIFY")" "$(sdlc_json_str "$(sdlc_verify_profile)")" \
    "$(sdlc_json_str "$EV_VERIFY_DETAIL")" "$(sdlc_json_str "$(sdlc_verify_receipt "$s")")"
  printf '      "source": {"state": %s, "reviewed_digest": %s, "current_digest": %s},\n' \
    "$(sdlc_json_str "${EV_SRC_STATE:-unknown}")" "$(sdlc_json_str "${EV_SRC_WANT:-}")" "$(sdlc_json_str "${EV_SRC_NOW:-}")"
  printf '      "delivery": {"state": %s, "target": %s, "detail": %s},\n' \
    "$(sdlc_json_str "${EV_DELIVERY:-none}")" "$(sdlc_json_str "${EV_DELIVERY_TARGET:-unknown}")" "$(sdlc_json_str "${EV_DELIVERY_DETAIL:-}")"
  printf '      "handoff": {"target": %s, "remote": %s, "branch": %s, "remote_sha": %s, "remote_verdict": %s},\n' \
    "$(sdlc_json_str "${EV_HANDOFF:-unknown}")" "$(sdlc_json_str "${EV_REMOTE:-}")" "$(sdlc_json_str "${EV_BRANCH:-}")" \
    "$(sdlc_json_str "${EV_REMOTE_SHA:-}")" "$(sdlc_json_str "${EV_REMOTE_VERDICT:-not-checked}")"
  printf '      "checkpoint": {"state": %s, "step": %s, "detail": %s},\n' \
    "$(sdlc_json_str "$EV_CHECKPOINT")" "$(sdlc_json_str "${EV_CHECKPOINT_STEP:-}")" "$(sdlc_json_str "$EV_CHECKPOINT_DETAIL")"
  printf '      "heartbeat": {"line": %s, "age_seconds": %s}\n' \
    "$(sdlc_json_str "$hb")" "${age:-null}"
  printf '    }'
}

feature_text() { # <slug>
  local line
  printf '%s\t%s\t%s\t%s\n' "$1" "$EV_STAGE" "$EV_STATUS" "$EV_NEXT_TEXT"
  printf '%s' "$EV_BLOCKERS" | while IFS= read -r line; do
    [ -n "$line" ] && printf '  blocker: %s — %s\n' "${line%%|*}" "${line#*|}"
  done
  [ -n "$EV_NEXT_CMD" ] && printf '  command: %s\n' "$EV_NEXT_CMD" || true
}

# Feature directory names, one per line, VALIDATED. A name with a space used to
# be word-split by the caller into several features that do not exist, and the
# driver was told to write an intent.md for each of them. An unusable name is
# now reported as itself, once, and evaluated for nothing.
list_slugs() {
  local d n
  for d in .sdlc/work/*/; do
    [ -d "$d" ] || continue
    n=${d#.sdlc/work/}; n=${n%/}
    sdlc_auto_valid_slug "$n" || continue
    [ -n "$slug" ] && [ "$n" != "$slug" ] && continue
    printf '%s\n' "$n"
  done
}
list_invalid_slugs() {
  local d n
  for d in .sdlc/work/*/; do
    [ -d "$d" ] || continue
    n=${d#.sdlc/work/}; n=${n%/}
    sdlc_auto_valid_slug "$n" && continue
    printf '%s\n' "$n"
  done
}

status_code() { case "$1" in ready) echo 0;; needs-human) echo 10;; blocked) echo 20;; complete) echo 30;; *) echo 1;; esac; }

case "$cmd" in
  status)
    if [ -n "$JSON" ]; then
      printf '{\n'
      printf '  "schema": "sdlc-kit/auto-status@1",\n'
      printf '  "kit_version": %s,\n' "$(sdlc_json_str "$(sdlc_auto_kit_version "$kit")")"
      printf '  "generated_at": %s,\n' "$(sdlc_json_str "$(sdlc_auto_now)")"
      printf '  "project_root": %s,\n' "$(sdlc_json_str "$(pwd)")"
      printf '  "lazymode": %s,\n' "$LAZY"
      printf '  "source_digest": %s,\n' "$(sdlc_json_str "$(sdlc_source_digest 2>/dev/null || echo unbound)")"
      printf '  "git_head": %s,\n' "$(sdlc_json_str "$(git rev-parse --verify --quiet HEAD 2>/dev/null || echo none)")"
      printf '  "features": [\n'
      first=1
      while IFS= read -r s <&3; do
        [ -n "$s" ] || continue
        evaluate "$s"
        [ $first -eq 1 ] || printf ',\n'
        first=0
        feature_json "$s"
      done 3<<EOF
$(list_slugs)
EOF
      [ $first -eq 1 ] || printf '\n'
      printf '  ],\n'
      printf '  "unusable_feature_dirs": ['
      ifirst=1
      while IFS= read -r bad <&3; do
        [ -n "$bad" ] || continue
        [ $ifirst -eq 1 ] || printf ','
        ifirst=0
        printf '%s' "$(sdlc_json_str "$bad")"
      done 3<<EOF
$(list_invalid_slugs)
EOF
      printf ']\n}\n'
    else
      echo "lazymode: $LAZY"
      while IFS= read -r s <&3; do [ -n "$s" ] || continue; evaluate "$s"; feature_text "$s"; done 3<<EOF
$(list_slugs)
EOF
      while IFS= read -r bad <&3; do
        [ -n "$bad" ] || continue
        printf '%s\t-\tblocked\t%s\n' "$bad" "this directory name under .sdlc/work/ is not a usable slug ([a-zA-Z0-9._-]+) — rename it; no feature is evaluated for it"
      done 3<<EOF
$(list_invalid_slugs)
EOF
    fi
    ;;
  next)
    [ -n "$slug" ] || usage
    sdlc_auto_valid_slug "$slug" || { echo "FAIL: '$slug' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 1; }
    # a closed feature has been archived (close.sh): a driver polling one after
    # the close must read `complete`, not an error
    if [ ! -d ".sdlc/work/$slug" ] && [ -d ".sdlc/archive/$slug" ]; then
      exitc=$(sdlc_auto_handoff_target ".sdlc/archive/$slug/delivery.md")
      case "$exitc" in unknown) exitc=closed;; esac
      printf 'complete closed %s :: archived (%s)\n' "$exitc" \
        "$(grep '^state: ' ".sdlc/archive/$slug/CLOSED" 2>/dev/null | cut -d' ' -f2- || echo '?')"
      exit 30
    fi
    [ -d ".sdlc/work/$slug" ] || { echo "FAIL: no open feature '.sdlc/work/$slug'" >&2; exit 1; }
    evaluate "$slug"
    printf '%s %s %s :: %s\n' "$EV_STATUS" "$EV_STAGE" "${EV_EXIT}" "${EV_NEXT_CMD:-$EV_NEXT_TEXT}"
    printf '%s' "$EV_BLOCKERS" | while IFS= read -r l; do [ -n "$l" ] && printf 'blocker: %s — %s\n' "${l%%|*}" "${l#*|}"; done
    exit "$(status_code "$EV_STATUS")"
    ;;
  intent-check)
    [ -n "$slug" ] || usage
    sdlc_auto_valid_slug "$slug" || { echo "FAIL: '$slug' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 1; }
    st=$(sdlc_auto_intent_contract "$slug")
    printf 'INTENT %s: %s\n' "${st%%|*}" "${st#*|}"
    case "${st%%|*}" in ok) exit 0;; material) exit 10;; *) exit 20;; esac
    ;;
  checkpoint)
    [ -n "$slug" ] || usage
    sdlc_auto_valid_slug "$slug" || { echo "FAIL: '$slug' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 1; }
    [ -d ".sdlc/work/$slug" ] || { echo "FAIL: no open feature '.sdlc/work/$slug'" >&2; exit 1; }
    f=$(sdlc_checkpoint_file "$slug")
    action=show; step=""; class=""; effect=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --show) action=show;;
        --clear) action=clear;;
        --set-step) [ $# -ge 2 ] || usage; action=set; step="$2"; shift;;
        --attempt)  [ $# -ge 2 ] || usage; action=attempt; step="$2"; shift;;
        --class)    [ $# -ge 2 ] || usage; class="$2"; shift;;
        --effect)   [ $# -ge 2 ] || usage; action=effect; effect="$2"; shift;;
        *) usage;;
      esac
      shift
    done
    # checkpoint.md is a line-oriented record read back by this script. A value
    # carrying a newline (or a field separator) would inject arbitrary fields
    # into it, so the two fields an agent supplies are validated, not trusted.
    case "$action" in
      set|attempt)
        case "$step" in
          ''|*[!a-zA-Z0-9._-]*)
            echo "FAIL: step names must be [a-zA-Z0-9._-]+ (got: '$step')" >&2; exit 1;;
        esac;;
    esac
    if [ "$action" = effect ]; then
      case "$effect" in
        *'|'*) ;;
        *) echo "FAIL: --effect needs \"<kind>|<detail>\"" >&2; exit 1;;
      esac
      if [ "$(printf '%s' "$effect" | wc -l | tr -d ' ')" != 0 ]; then
        echo "FAIL: --effect must be a single line" >&2; exit 1
      fi
      case "$effect" in
        *"$(printf '\t')"*|*"$(printf '\r')"*)
          echo "FAIL: --effect must not contain tabs or carriage returns" >&2; exit 1;;
      esac
      case "${effect%%|*}" in
        ''|*[!a-zA-Z0-9._-]*)
          echo "FAIL: the effect kind must be [a-zA-Z0-9._-]+ (got: '${effect%%|*}')" >&2; exit 1;;
      esac
    fi
    cur_src=$(sdlc_source_digest 2>/dev/null || echo unbound)
    # a checkpoint written against other source is not evidence about this one:
    # the counters reset and the file is rewritten, so a resume never replays a
    # verdict that belonged to code nobody has any more
    if [ -f "$f" ] && [ "$(sdlc_field "$f" source_digest || true)" != "$cur_src" ]; then
      if [ "$action" != show ]; then
        grep -v '^attempt: ' "$f" > "$f.tmp" 2>/dev/null || true
        awk -v d="$cur_src" '/^source_digest: /{print "source_digest: " d; next} {print}' "$f.tmp" > "$f" && rm -f "$f.tmp"
      fi
    fi
    case "$action" in
      show)
        if [ -f "$f" ]; then cat "$f"; else echo "no checkpoint for $slug"; fi
        st=$(sdlc_checkpoint_state "$slug"); printf 'checkpoint %s: %s\n' "${st%%|*}" "${st#*|}";;
      clear) rm -f "$f"; echo "checkpoint cleared for $slug";;
      set)
        [ -f "$f" ] || printf 'checkpoint_schema: sdlc-kit/checkpoint@1\nsource_digest: %s\n' "$cur_src" > "$f"
        grep -v '^step: ' "$f" > "$f.tmp" || true; mv "$f.tmp" "$f"
        grep -v '^updated_at: ' "$f" > "$f.tmp" || true; mv "$f.tmp" "$f"
        printf 'step: %s\nupdated_at: %s\n' "$step" "$(sdlc_auto_now)" >> "$f"
        echo "checkpoint step: $step";;
      attempt)
        case "$class" in transient|deterministic) ;; *) echo "FAIL: --attempt needs --class transient|deterministic" >&2; exit 1;; esac
        [ -f "$f" ] || printf 'checkpoint_schema: sdlc-kit/checkpoint@1\nsource_digest: %s\n' "$cur_src" > "$f"
        n=$(sdlc_checkpoint_attempts "$slug" "$step")
        n=$((n + 1))
        # caps mirror the loop's existing ones: a deterministic failure repeats
        # deterministically, so it escalates at once; a transient one gets three
        cap=3; [ "$class" = deterministic ] && cap=1
        # LITERAL, never a regex: `build.fi.` used to match and delete the
        # counter of `build.fix`, which reset the retry cap of another step.
        # Same comparison sdlc_checkpoint_attempts reads them back with.
        awk -v s="$step" -F' *\\| *' '
          { line = $0
            if (index(line, "attempt: ") == 1) {
              body = substr(line, 10); n = split(body, parts, / *\| */)
              if (parts[1] == s) next
            }
            print line }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        printf 'attempt: %s | %s | %s\n' "$step" "$class" "$n" >> "$f"
        grep -v '^updated_at: ' "$f" > "$f.tmp" || true; mv "$f.tmp" "$f"
        printf 'updated_at: %s\n' "$(sdlc_auto_now)" >> "$f"
        if [ "$n" -gt "$cap" ]; then
          echo "RETRY CAP: '$step' has $n $class attempts (cap $cap) — stop retrying and escalate to the human"
          exit 20
        fi
        echo "attempt $n/$cap ($class) for $step";;
      effect)
        [ -f "$f" ] || printf 'checkpoint_schema: sdlc-kit/checkpoint@1\nsource_digest: %s\n' "$cur_src" > "$f"
        case "$effect" in
          *"|"*) ;;
          *) echo "FAIL: --effect needs \"<kind>|<detail>\"" >&2; exit 1;;
        esac
        if grep -qxF "effect: $effect" "$f"; then
          echo "effect already recorded (not repeated): $effect"
        else
          printf 'effect: %s\n' "$effect" >> "$f"
          echo "effect recorded: $effect"
        fi;;
    esac
    ;;
  *) usage;;
esac
