---
name: sdlc-ship
description: "Evidence assembly, adversarial review, ship gate, commit discipline. Triggers: build green and verified."
---

# Stage 5: Ship

Goal: create `evidence.md` so a human can decide whether to release, then
deliver and record what was delivered in `delivery.md`. Run agent reviews
first. The human reviews findings about intent and risk.

Heartbeat throughout: AGENTS.md rule 9.

## Before you start

The adversarial code review below must run in a fresh context (AGENTS.md
rule 5); assembling the evidence itself may stay with the implementer. Read plan.md, spec.md, deviations.md (if
present), and the diff (`git diff` against the base branch). Compact-route
features have no spec or plan: intent.md replaces both as the upstream
source, and its Compact route section and success criteria are the
requirements. Read memory (AGENTS.md rule 4).

## Adversarial code review (fresh context)

This review runs at every lazymode level — it is the last look at the diff
before the push, and the only security pass (AGENTS.md rule 3).

Dispatch an adversary (`roles/adversary.md`) with: spec.md, plan.md,
`.sdlc/memory/POLICY.md` if present, and the diff (compact route: intent.md
and the diff). It checks spec mismatch, missing untouched checks, security issues,
policy violations, tests that cannot fail, and complexity that hides bugs.
Fix findings or record justified rejections, then re-run the adversary over
the fixed diff — max 2 rounds, each logged in evidence.md's Adversary
section. Blockers surviving round 2 go into evidence.md's not-verified list
and block `--lazy`: ship is the irreversible edge, so an open blocker stops
the loop and goes to the human even at lazymode 4.

## Assemble evidence

Fill `templates/evidence.md` → `.sdlc/work/<slug>/evidence.md`:

- For each spec requirement, include the exact command and real output. Keep
  every numerical result. For long successful logs, include the verdict lines
  and numbers and cite the full scratch output. Include all failure output.
- **The three verifier reports** (roles/verifier.md — E2E, Side effects,
  Intent match) as reported, each check as command/tool · environment ·
  scenario · observed result, with the fix-loop rounds from deviations.md. A
  lens that reported NOT VERIFIED stays NOT VERIFIED here: name what is
  missing; unit tests never stand in, and delivering over the gap is the
  human's explicit call, recorded under Not verified.
- **Bug fixes: the proof chain** (AGENTS.md rule 6) in the Bug proof section.
  A chain with a missing link is a diagnosis, not a confirmed fix: label it
  that way here and in the report.
- Include full test, lint, and build results. Long successful logs may use the
  same verdict-lines-and-scratch-citation rule.
- Adversary findings + resolutions.
- State anything not verified, including environment limits and skipped checks.
  Record a gap instead of marking the check as passed.

## Retrospective

Review the feature history. Record what went wrong, what surprised you, and
what would help the next agent — but only what a future run could REUSE
(skills/6-maintain "Record the lesson"); a clean feature legitimately leaves
no lesson. Write what there is into the feature's
`.sdlc/work/<slug>/harvest.md` (lesson candidates in the skill 6 format;
durable terms, verified facts, and constraints as domain candidates;
AGENTS.md rule 4). **Every business rule this feature set, changed, or
retired is an area candidate** — the rule in one testable sentence, its
source (the origin, the spec R-item or compact intent O-item), the P-number
it changes or retires — plus one
history line per area it changed. Then finish the feature's `summary.md`:
`Status` says only what delivery.md confirms (a pushed review branch is not
a deployment), Before → After and How to check match what was actually
built and proven, Remember holds the one thing worth knowing next time.
`tools/kb.sh show` prints it first, so a stale one misleads every later
reader. Domain facts describe the system; lessons describe mistakes. If a
stage skill should have prevented a mistake, add `promote: skills/<n>` to
the lesson candidate. A tag that appears three or more times in INDEX.md
must be promoted: propose the stage-skill change to the human (`close.sh`
prints these).

## Gate

At lazymode ≥3 (AGENTS.md rule 3): after the adversary pass, run
`<kit>/gates/approve.sh ship .sdlc/work/<slug>/evidence.md --lazy --review
"<the diff review you ran>"` (add `--risk-authorized "<the human's words>"`
for risky work), post the evidence summary as FYI, and continue to commit
discipline in the same run: a waived gate is not a stop (AGENTS.md rule 3).
A blocker surviving round 2 of the adversary still stops the loop here.

Below lazymode 3 the ship gate is the human's:

> Review `.sdlc/work/<slug>/evidence.md`, then:
> `<kit>/gates/approve.sh ship .sdlc/work/<slug>/evidence.md`

STOP after requesting approval — and ask once, not once per artifact.

## After approval: one authorization, then deliver

The ship approval decides *that* this is released. What is still open is *what
exactly* goes out. Ask it ONCE, as a single concrete authorization — never as a
sequence of "may I ship?", "may I stage these?", "may I push?" for the same
work:

> Ready to deliver <slug>:
> - staged files: <list from `git status --short`>
> - final diff: <stat line + the deciding hunks, or the scratch file that holds it>
> - commit message: <subject line + body>
> - delivery target: <local | pr | deploy, from spec.md's Release procedure (compact route: intent.md's Delivery target)>
> Approve this delivery?

If the human already authorized this scope — "ship it when it's green", "push
to the PR", the `- Scope authorization:` line in intent.md — that IS the
authorization: proceed, post the same four items as FYI, and do not ask again.
At lazymode ≥3 the whole check is autonomous: verify the four items yourself
against the rules below and post them as FYI. A change outside the authorized
scope (a different branch, an extra file, a deploy where a PR was agreed) is a
new decision and goes back to the human.

**Where the unattended loop ends: a pushed feature branch.** Pushing the
reviewed commit to the ticket's own branch is the review handoff, and
`tools/handoff.sh push <slug> --authorized "<the human's words>"` is the safe
way to do it: it refuses protected or shared branches, never force-pushes,
refuses a commit whose tree does not CONTAIN the reviewed source, and repeats
no push that already happened. Merging that branch or deploying it is a
separate human approval, recorded as delivery.md's `Authorized-by:` — the ship
approval is not that authorization.

1. Stage named paths only: the changed source files. Do not use `git add -A`
   or `git add .` because they can include unrelated files. **The record
   store is not staged at all**: `/.sdlc` is gitignored in full (AGENTS.md
   rule 7), so the records stay in the store — the project's working copy,
   or the area the human chose — and the commit carries code. If any
   `.sdlc/` path appears in the staged list, the project tracks records
   from an older kit version: say so, and leave the decision to untrack
   them to the human (`init.sh` prints the command). Never untrack them
   mid-ship.
2. Commit and push following the **Release procedure** line in spec.md
   (compact route: intent.md's Delivery target). The ship approval binds the
   project's whole source snapshot as the review saw it (AGENTS.md rule 6):
   staging and committing those exact bytes change nothing, but any edit, new
   file, deletion, chmod, or symlink swap afterwards — including in a file the
   review did not name — closes the gate, and close.sh names the files.
   Re-run the review and re-approve rather than working around it.
3. **Record the delivery.** Fill `templates/delivery.md` →
   `.sdlc/work/<slug>/delivery.md`: the target, the delivered source (for a PR
   or deploy the commit sha, which must CONTAIN the reviewed source — close.sh
   compares that commit's tree against it), the command or project tool you actually ran to
   check the result, and its verbatim deciding output. Examples of a real
   check: `gh pr view <n> --json state,mergeStateStatus`, the deploy tool's
   status output, `git log origin/<branch> -1` after a push, or
   `tools/handoff.sh check <slug>`, which reads the remote branch's SHA with
   `git ls-remote` and prints the exit condition (review-ready vs merged or
   deployed). Record `Remote`, `Branch` and `Handoff` beside the usual fields
   when the target is a review branch. For a local
   target, the passing final suite over the delivered source is the result.
   Never write a result you did not observe — an unverified delivery is
   `Confirmed: no`, and the feature closes as handed-off, not shipped.
4. Hand it to close: `gates/close.sh <slug> shipped "<reason>"`. It re-checks
   the ship approval and the delivery record. `scratch/` stays until then —
   the pruning happens at close, and anything evidence.md, delivery.md, or a
   lesson cites is kept (AGENTS.md rule 5).
