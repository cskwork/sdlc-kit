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

## Notes
<!-- Anything the result does not show by itself: which environment, which
     reviewer, what is still pending (a merged PR that is not deployed yet is a
     pr delivery, not a deploy delivery — say so instead of upgrading it). -->
