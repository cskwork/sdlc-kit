# Delivery: <feature slug>

<!-- The record of what was actually delivered, where, and how that was
     checked. "shipped" means this happened — a ship approval alone is a
     decision to deliver, not a delivery (AGENTS.md rule 6).
     close.sh <slug> shipped reads this file and refuses a delivery that is
     absent, unconfirmed, or built from source other than the reviewed one. -->

- Target: local | pr | deploy   <!-- what was agreed in spec.md's Release procedure -->
- Source: <the delivered commit sha, which must CONTAIN the reviewed source · `worktree:<source digest>` only for a local target>
<!-- close.sh compares that commit's tree against the reviewed snapshot: a commit
     that merely exists is refused. approve.sh prints the worktree digest. -->
- Verified-by: <the command or project tool actually run, e.g. `gh pr view 214 --json state,mergeStateStatus`>
- Evidence: <the deciding output line, verbatim — not a summary>
- Confirmed: yes | no          <!-- no ⇒ not shipped: close as handed-off or keep working -->
- Verified-at: YYYY-MM-DDTHH:MM:SSZ

<!-- OPTIONAL review-handoff fields (v0.10.0). Older delivery records without
     them behave exactly as before; close.sh does not require them. They are
     OPT-IN, and opting in means being checked: once `Handoff:` names a remote
     handoff, close.sh itself runs `git ls-remote` and REFUSES the shipped close
     unless Remote/Branch are named and really hold the delivered commit. Write
     them when it was really pushed; leave them out for an ordinary delivery. -->
- Remote: <the git remote the review branch was pushed to, e.g. origin>
- Branch: <the feature branch a human reviews, never a shared/protected branch>
- Handoff: review-ready | merged | deployed
  <!-- review-ready = pushed and PR-ready, human review pending. This is where
       an unattended loop STOPS.
       merged / deployed: the kit checks only that the branch is on the remote
       at the delivered commit. A feature ref is NOT a merge commit and NOT a
       deployment — that proof is external, and Verified-by/Evidence below are
       the human's (or the deployment system's) record of it, not a kit check. -->
- Authorized-by: <REQUIRED for merged/deployed: the human's own words authorizing
  the merge or deploy. The ship approval is not that authorization. This line is
  a RECORD of what a human said, not an authentication of it (docs/automation.md
  limitation L2): the authority it refers to lives in intent.md's Scope
  authorization, which is what tools/handoff.sh push checks before it pushes.>

## Notes
<!-- Anything the result does not show by itself: which environment, which
     reviewer, what is still pending (a merged PR that is not deployed yet is a
     pr delivery, not a deploy delivery — say so instead of upgrading it). -->
