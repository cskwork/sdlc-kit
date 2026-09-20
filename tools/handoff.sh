#!/usr/bin/env bash
# handoff.sh — the review handoff: get the reviewed source onto a feature branch
# a human can review, and prove it is there. Run from the project root.
#
#   tools/handoff.sh check <slug> [--remote <r>] [--branch <b>]
#   tools/handoff.sh push  <slug> --authorized "<the human's words>" [--remote <r>] [--branch <b>]
#
# The boundary this script draws is the point of the whole automation layer:
#
#   review-ready  — the feature branch exists on the remote at the delivered
#                   commit, and that commit CONTAINS the source the ship review
#                   saw. A human review of that branch is the next step.
#   merged/deployed — NOT this script's business. Merging a feature branch or
#                   deploying it leaves the review boundary, so delivery.md must
#                   carry `Authorized-by:` with the human's own words for it, at
#                   every lazymode level (AGENTS.md rule 3 "Autonomy is not
#                   authority"). `check` refuses to call it done without one.
#
# Guard rails on `push`, all of them checked IMMEDIATELY BEFORE the side effect:
#
#   * the complete ship gate — gates/check-gate.sh ship, the same program the
#     agent runs by hand: the approval must bind this artifact, its upstreams
#     and the reviewed source. A ship gate that is CLOSED for any reason
#     (an evidence.md edited after approval, source drift, an unbound record)
#     refuses the push, in check-gate.sh's own words;
#   * the verification receipt — a configured recipe must read `ok`;
#   * AUTHORITY — `--authorized` is required, AND the scope the human recorded
#     in intent.md (`- Scope authorization:`) must actually name publishing a
#     branch. A flag an agent types is not permission; neither is a line an
#     agent wrote into delivery.md. Both are records, not authentication (L2).
#   * a `local` delivery target is never pushed;
#   * protected/shared branches are refused (`protected_branches:` in
#     .sdlc/config.md plus a built-in list), --force/--force-with-lease are
#     refused outright, and a remote branch that has drifted away from this
#     history (not an ancestor of HEAD) stops the push instead of racing it.
#
# A push whose remote branch is already at this commit is reported and NOT
# repeated, so a resume cannot double-fire an external effect.
#
# Exit: 0 ok · 1 refusal, mismatch, or failed push · 2 usage/environment.
set -uo pipefail
kit="$(cd "$(dirname "$0")/.." && pwd)"
. "$kit/gates/_common.sh"
. "$kit/gates/_auto.sh"

usage() {
  cat >&2 <<'EOF'
usage (from the project root):
  tools/handoff.sh check <slug> [--remote <r>] [--branch <b>]
  tools/handoff.sh push  <slug> --authorized "<the human's words>" [--remote <r>] [--branch <b>]
EOF
  exit 2
}
[ $# -ge 2 ] || usage
cmd="$1"; slug="$2"; shift 2
remote=""; branch=""; authorized=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) [ $# -ge 2 ] || usage; remote="$2"; shift;;
    --branch) [ $# -ge 2 ] || usage; branch="$2"; shift;;
    --authorized) [ $# -ge 2 ] || usage; authorized="$2"; shift;;
    --force|--force-with-lease|-f)
      echo "FAIL: this script never force-pushes. A rejected push means the remote branch moved —" >&2
      echo "  look at what is there and take it to the human." >&2; exit 2;;
    *) usage;;
  esac
  shift
done
[ -d .sdlc ] || { echo "FAIL: no .sdlc/ here." >&2; exit 2; }
# A handoff re-checks the ship gate and records an external effect, both of
# them store state of the owning checkout (_common.sh sdlc_store_owner_ok).
sdlc_store_owner_ok || exit 2
sdlc_auto_valid_slug "$slug" || { echo "FAIL: '$slug' is not a usable feature slug ([a-zA-Z0-9._-]+)" >&2; exit 2; }
[ -d ".sdlc/work/$slug" ] || { echo "FAIL: no open feature '.sdlc/work/$slug'" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "FAIL: not a git repository — no branch handoff is possible here." >&2; exit 2; }

del=".sdlc/work/$slug/delivery.md"
evidence=".sdlc/work/$slug/evidence.md"
shiprec=".sdlc/approvals/${slug}.ship.approval"

# The COMPLETE ship gate, not a subset of it: the same script, the same output.
# Run immediately before the external effect and immediately before confirming
# one, so nothing can change between the verdict and the act.
ship_gate() { # → 0 open; prints check-gate.sh's own refusal otherwise
  local out rc
  [ -f "$evidence" ] || { echo "the ship gate is CLOSED: $evidence does not exist."; return 1; }
  out=$("$kit/gates/check-gate.sh" ship "$evidence" 2>&1); rc=$?
  [ "$rc" = 0 ] && return 0
  printf '%s\n' "$out"
  return 1
}
# The verification receipt, by the same rule the loop and the cockpit use.
verify_gate() { # → 0 when nothing is owed
  local st; st=$(sdlc_verify_state "$slug")
  case "${st%%|*}" in
    ok|unconfigured) return 0;;
    *) printf 'verification %s: %s\n' "${st%%|*}" "${st#*|}"; return 1;;
  esac
}
[ -n "$remote" ] || { [ -f "$del" ] && remote=$(sdlc_delivery_field "$del" Remote) || true; }
[ -n "$branch" ] || { [ -f "$del" ] && branch=$(sdlc_delivery_field "$del" Branch) || true; }

# Shared branches are never a handoff target: a feature branch is.
protected_default="main master develop development trunk release production prod staging"
protected_extra=$(awk '/^protected_branches: /{sub(/^[^:]*: */,""); gsub(/,/," "); print; exit}' .sdlc/config.md 2>/dev/null | tr -d '\r')
is_protected() { # <branch>
  local b="$1" p
  for p in $protected_default $protected_extra; do [ "$b" = "$p" ] && return 0; done
  case "$b" in release/*|releases/*|prod/*|production/*|hotfix/main*) return 0;; esac
  return 1
}

reviewed_digest() { sdlc_field "$shiprec" code_digest 2>/dev/null || true; }
contains_reviewed() { # <commit> → 0 when its tree IS the reviewed source
  local rev="$1" want tree
  want=$(reviewed_digest)
  [ -n "$want" ] && [ "$want" != none ] || return 2
  tree=$(sdlc_tree_entries "$rev" 2>/dev/null) || return 3
  [ "$(printf '%s\n' "$tree" | sdlc_entries_unsupported)" = 0 ] || return 3
  [ "$(printf '%s\n' "$tree" | sdlc_entries_digest)" = "$want" ]
}

case "$cmd" in
  check)
    [ -f "$del" ] || { echo "HANDOFF none: no $del yet — nothing has been delivered."; exit 1; }
    target=$(sdlc_delivery_field "$del" Target | awk '{print tolower($1)}')
    handoff=$(sdlc_auto_handoff_target "$del")
    src=$(sdlc_delivery_field "$del" Source)
    external_claim=""
    case "$handoff" in
      merged|deployed)
        if [ -z "$(sdlc_delivery_field "$del" Authorized-by)" ]; then
          echo "HANDOFF unauthorized: '$handoff' needs the human's own authorization in $del (Authorized-by:)."
          echo "  Merging or deploying is a separate decision from the ship approval, at every lazymode."
          exit 1
        fi
        # Being on the remote feature ref proves the branch is there. It proves
        # NOTHING about a merge or a deployment: those happen outside this
        # repository, and this script cannot see them.
        external_claim="$handoff";;
    esac
    if [ "$target" = local ]; then
      echo "HANDOFF local: a local delivery has no remote review branch (exit condition: local)."
      exit 0
    fi
    [ -n "$remote" ] && [ -n "$branch" ] || {
      echo "HANDOFF incomplete: $del names no Branch/Remote, so the reviewer's target cannot be verified."
      echo "  Add '- Remote: <remote>' and '- Branch: <feature branch>' (templates/delivery.md)."
      exit 1; }
    git cat-file -e "${src}^{commit}" 2>/dev/null || {
      echo "HANDOFF unknown-source: delivery Source '$src' is not a commit in this repository."; exit 1; }
    local_sha=$(git rev-parse "${src}^{commit}")
    remote_sha=$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')
    [ -n "$remote_sha" ] || { echo "HANDOFF absent: $remote/$branch does not exist — the reviewer has nothing to read."; exit 1; }
    if [ "$remote_sha" != "$local_sha" ]; then
      echo "HANDOFF mismatch: $remote/$branch is at $remote_sha, the delivered commit is $local_sha."
      echo "  The reviewer would read other code than the one this feature delivered."
      exit 1
    fi
    contains_reviewed "$local_sha"; rc=$?
    case $rc in
      0) ;;
      2) echo "HANDOFF unbound: no ship approval with a source binding — re-run the ship review."; exit 1;;
      3) echo "HANDOFF unreadable: the tree of $local_sha could not be read or hashed."; exit 1;;
      *) echo "HANDOFF source-content: $local_sha does not CONTAIN the source the ship review saw."; exit 1;;
    esac
    # confirming is a claim too: the whole ship gate and the verification are
    # re-checked here, so `review-ready` can never be printed over a gate that
    # check-gate.sh calls CLOSED
    if ! out=$(ship_gate); then
      echo "HANDOFF blocked: the ship gate is not open, so nothing here is review-ready."
      printf '%s\n' "$out"
      exit 1
    fi
    if ! out=$(verify_gate); then
      echo "HANDOFF blocked: the verification this project configured is not satisfied."
      printf '%s\n' "$out"
      exit 1
    fi
    if [ -n "$external_claim" ]; then
      echo "HANDOFF $external_claim: PENDING EXTERNAL PROOF."
      echo "  Verified here: $remote/$branch @ $local_sha contains the reviewed source, and"
      echo "  $del records a human authorization for '$external_claim'."
      echo "  NOT verified here: that the branch was actually $external_claim. A feature ref on a"
      echo "  remote is not a merge commit on the target branch and is not a deployment."
      echo "  That proof is the human's (or the deployment system's) to provide, in $del."
      exit 0
    fi
    echo "HANDOFF review-ready: $remote/$branch @ $local_sha contains the reviewed source."
    echo "  exit condition: review-ready (human review pending; NOT merged, NOT deployed)."
    exit 0;;

  push)
    [ -n "$authorized" ] || {
      echo "FAIL: pushing leaves this repository. Re-run with --authorized \"<the human's words>\"" >&2
      echo "  naming the scope they authorized (AGENTS.md rule 3)." >&2; exit 1; }
    [ -f "$shiprec" ] || { echo "FAIL: no ship approval for '$slug' — nothing has been reviewed to hand off." >&2; exit 1; }
    # AUTHORITY: the human's recorded scope, not the flag. --authorized carries
    # the words; intent.md is where they were recorded before the work started.
    if ! sdlc_auto_scope_allows_publish "$slug"; then
      scope=$(sdlc_auto_scope_authorization "$slug")
      echo "FAIL: nothing on record authorizes publishing a branch for '$slug'." >&2
      echo "  intent.md's '- Scope authorization:' reads: ${scope:-(absent)}" >&2
      echo "  A --authorized flag an agent types is not permission, and neither is a line an" >&2
      echo "  agent writes into delivery.md. Take it to the human, record their words in" >&2
      echo "  intent.md's Scope authorization (naming the push / PR / review branch), re-run" >&2
      echo "  the intent gate, then push (AGENTS.md rule 3)." >&2
      exit 1
    fi
    # a delivery the loop agreed to keep local never leaves the repository
    dtarget=""
    if [ -f "$del" ]; then dtarget=$(sdlc_delivery_field "$del" Target | awk '{print tolower($1)}'); fi
    if [ -z "$dtarget" ] && [ -f ".sdlc/work/$slug/intent.md" ]; then
      dtarget=$(awk '/^[ \t]*- *Delivery target:/{sub(/^[^:]*: */,""); print tolower($1); exit}' ".sdlc/work/$slug/intent.md")
    fi
    if [ "$dtarget" = local ]; then
      echo "FAIL: the agreed delivery target for '$slug' is 'local' — a local delivery has no" >&2
      echo "  remote review branch. Record it in $del instead of pushing, or take a change of" >&2
      echo "  target to the human first." >&2
      exit 1
    fi
    # the whole ship gate, in check-gate.sh's own words, immediately before the effect
    if ! out=$(ship_gate); then
      echo "FAIL: the ship gate is not open, so there is nothing reviewed to publish." >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
    if ! out=$(verify_gate); then
      echo "FAIL: the verification this project configured is not satisfied — do not publish it yet." >&2
      printf '%s\n' "$out" >&2
      exit 1
    fi
    read -r st want now <<EOF
$(sdlc_source_state "$shiprec")
EOF
    [ "$st" = ok ] || { echo "FAIL: the ship source binding is '$st' — re-run the ship review before pushing." >&2; exit 1; }
    [ -n "$remote" ] || remote=origin
    git remote get-url "$remote" >/dev/null 2>&1 || { echo "FAIL: no such remote: $remote" >&2; exit 2; }
    [ -n "$branch" ] || branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -n "$branch" ] || { echo "FAIL: detached HEAD and no --branch: name the feature branch explicitly." >&2; exit 2; }
    if is_protected "$branch"; then
      echo "FAIL: '$branch' is a protected/shared branch. This loop pushes a FEATURE branch for review;" >&2
      echo "  merging into a shared branch is the human's decision (AGENTS.md rule 3)." >&2
      exit 1
    fi
    head_sha=$(git rev-parse --verify --quiet HEAD) || {
      echo "FAIL: this repository has no commit yet — commit the reviewed source before the handoff." >&2; exit 1; }
    contains_reviewed "$head_sha"; rc=$?
    case $rc in
      0) ;;
      2) echo "FAIL: the ship approval binds no source identity — nothing can be proven about this commit." >&2; exit 1;;
      3) echo "FAIL: the tree of HEAD could not be read or hashed." >&2; exit 1;;
      *) echo "FAIL: HEAD ($head_sha) does not CONTAIN the source the ship review saw. Commit the reviewed" >&2
         echo "  bytes, or re-run the ship review over what is really there." >&2; exit 1;;
    esac
    remote_sha=$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')
    if [ "$remote_sha" = "$head_sha" ]; then
      echo "already pushed: $remote/$branch is at $head_sha — no external effect repeated."
      echo "HANDOFF review-ready: $remote/$branch @ $head_sha"
      exit 0
    fi
    # Remote drift: the feature branch moved somewhere this history does not
    # contain (a rebase, a colleague, another agent). git would reject it, but
    # a rejection read as "retry" is how force-pushes happen. Stop first, and say
    # what is there.
    if [ -n "$remote_sha" ]; then
      if ! git cat-file -e "${remote_sha}^{commit}" 2>/dev/null; then
        echo "FAIL: $remote/$branch is at $remote_sha, a commit this repository does not have." >&2
        echo "  Fetch it and look at what is there before anything is pushed over it." >&2
        exit 1
      fi
      if ! git merge-base --is-ancestor "$remote_sha" "$head_sha" 2>/dev/null; then
        echo "FAIL: $remote/$branch is at $remote_sha, which is NOT an ancestor of HEAD ($head_sha)." >&2
        echo "  The review branch drifted: pushing would either be rejected or lose what is there." >&2
        echo "  This script never force-pushes — take the divergence to the human." >&2
        exit 1
      fi
    fi
    echo "pushing $head_sha to $remote/$branch (authorized: $authorized)"
    if ! git push "$remote" "HEAD:refs/heads/$branch"; then
      echo "FAIL: the push was rejected. It is NOT retried with --force: look at what is on the remote." >&2
      exit 1
    fi
    remote_sha=$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')
    [ "$remote_sha" = "$head_sha" ] || {
      echo "FAIL: after the push $remote/$branch is at '${remote_sha:-nothing}', not $head_sha." >&2; exit 1; }
    ck=$(sdlc_checkpoint_file "$slug")
    [ -f "$ck" ] || printf 'checkpoint_schema: sdlc-kit/checkpoint@1\nsource_digest: %s\n' "$(sdlc_source_digest 2>/dev/null || echo unbound)" > "$ck"
    grep -qxF "effect: push|$remote|$branch|$head_sha" "$ck" || printf 'effect: push|%s|%s|%s\n' "$remote" "$branch" "$head_sha" >> "$ck"
    if ! out=$(ship_gate); then
      echo "PUSHED, BUT NOT REVIEW-READY: the ship gate closed between the push and this line." >&2
      printf '%s\n' "$out" >&2
      echo "  $remote/$branch is at $head_sha. Repair the gate before anyone reviews it." >&2
      exit 1
    fi
    echo "HANDOFF review-ready: $remote/$branch @ $head_sha contains the reviewed source."
    echo "  Record it in $del: Target, Source: $head_sha, Remote: $remote, Branch: $branch, Handoff: review-ready."
    exit 0;;

  *) usage;;
esac
