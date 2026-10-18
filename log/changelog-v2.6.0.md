# v2.6.0 — intent at least 90% clear before planning

Phase 1 used to restate the request and leave the rest to phase 2:
exploration stopped at "enough to restate it", and reproducing a bug was
phase 2's job. A plan could then rest on a request nobody had pinned down.
Intent now carries a scored Clarity table, and `sdlc.sh` refuses the intent
gate below 90%.

## Changes

- **Clarity table.** `templates/intent.md` gains `## Clarity`, one row per
  area: Outcome, Scope, AS-IS, TO-BE, Success, Constraints. Each row is
  `clear`, `assumed` or `open`, with How settled: the evidence that leaves
  one reading, why it is assumed, or what is missing.
- **Scored by the script.** clear counts 1, assumed 1/2, open 0. One assumed
  area is 91% and passes; two assumed, or one open, is 83% and does not.
  `sdlc.sh next` prints the score and the weak areas (`clarity 83% < 90%:
  settle TO-BE assumed, Constraints assumed by …`), and `approve intent`
  refuses below the bar or when an area is missing, duplicated, unknown, or
  has no How settled (empty, a template placeholder, or only `-`, `?`,
  `n/a`, `tbd`). The human's answer settles an area like any other
  evidence: cite it.
- **Four ways to raise it**, cheapest first (`phases/1-intent.md`): explore
  the code and earlier tickets; reproduce a reported bug where that is safe
  (local or test, never writing shared or production data), with the log in
  `logs/`; research the primary source when TO-BE depends on something
  outside the repository; ask the requester where the request came from.
  Root cause and the failing test stay in phase 2's `refs/repro.md`, which
  now starts from phase 1's reproduction, and phase 2 scouts reuse phase 1's
  `refs/` and `logs/`.
- **Asking on the ticket, any tracker.** Questions go to the request's own
  channel — a comment on its Jira, GitHub, GitLab or Linear ticket, issue or
  pull request, else the chat. One comment carries every open question, each
  with its options and the answer the agent will assume; each is marked
  `— asked: <where, when>` and keeps the feature at NEEDS-HUMAN (exit 10)
  until answered; a question that blocks nothing rides in the same comment
  and is noted in its area's How settled. Only the requester or the policy
  owner resolves one, and an answer settles what to build without granting
  authority.
- **Posting needs the human's words.** Rule 3 adds posting beyond this
  machine (a ticket or issue comment, a message). Without that authority the
  agent shows the human the draft.
- **Intent check.** The reviewer gains an intent mode: a fresh context looks
  for a second reading of the request that intent.md does not rule out, and
  for an area marked clear on evidence that does not say so. It writes
  `refs/intent-check.md`, never `review.md`, which keeps only the plan and
  diff rounds that `sdlc.sh review` reads. Skipped only when every area
  cites the requester's own words.

## Compatibility

An intent approved by an earlier kit has no Clarity table and stays
approved: the bar is checked only when the intent gate is closed. Editing
such an intent closes its gate, and re-approval then needs the table.
