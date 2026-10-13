# v2.3.0 — fewer repeated reviews, faster review on large roots

Four fixes from two days of use on a project root holding about 350 git
repositories and worktrees, where 8 features ran through the loop.

## Changes

- **Review carries over when nothing it judged moved.** `approve plan` used
  to clear the review PASS every time, so a human resuming a BLOCKED route to
  retry one scenario had to run a new diff review on unchanged code. One
  feature did this 12 times: rounds 5 to 15 reviewed the same two commits and
  found nothing. Now the PASS carries to the new build entry when the
  build's review was a PASS, every HEAD it bound is unchanged, intent.md is
  unchanged, and PLAN.md is unchanged outside its Scenarios section.
  `approve plan` then prints `review PASS carried` and the next step is QA.
  A new commit in a bound repository, a change to intent.md or to any other
  PLAN.md section (HTML comments aside), a round in review.md after the
  recorded review that is not PASS (a passing plan gap check is fine), a review bound to a working tree (`--uncommitted`) or a `.state`
  written by an older kit still needs a new round. The PLAN.md hash outside Scenarios is stored as
  `planbody:` in `.state`.
- **`review --repos "<path> ..."`.** Binding every repository under the root
  took a median of 109 s per `review` (31 recordings, 201 s at worst);
  run alone, the repository scan took 125 s, and 0.14 s with three listed
  repositories. A global `repos:` does not fit a root where each feature
  commits in a different worktree, so `--repos`, given before the note,
  replaces `repos:` for one review, with the same checks and commas between
  entries. It goes with `--uncommitted` in either order. An empty list is
  refused, as are a repeated flag and `--repos` on a FAIL. A Commit outside
  the bound repositories now names both `config repos:` (with its current
  list) and `review --repos` in its error.
- **BLOCKED choices.** On a human route for a BLOCKED row, Evidence now
  offers all three choices: remove the scenario (the approval records it),
  retry with what is missing and a limit on attempts, or drop. Before, only
  retry was described, and one feature asked the human to approve a new
  retry 9 times.
- **Delivery Target errors quote the value.** Three intents in those days first
  failed with `Delivery Target must be local, pr or deploy` because detail
  followed the value (`deploy (dev → stg)`, `local commit → push`). The
  error now quotes what it found, or says `missing`, and points detail to a
  `- Note:` line, which the intent template now has. Phase 1 says `pr` also
  covers pushing a branch for review with no pull request.

Selftest adds `reposflag`, `carry` and `target` (119 checks); each fails on
v2.2.1 for the reported reason.

## Compatibility

Existing records stay valid. A feature whose `.state` has no `planbody:`
keeps the v2.2.1 behavior until its next plan approval, which records it.
Messages for `repos:` errors now start with `config repos:` or
`review --repos`, naming where the list came from.
