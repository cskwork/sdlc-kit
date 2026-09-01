---
name: sdlc-ship
description: "Evidence assembly, adversarial review, ship gate, commit discipline. Triggers: build green and verified."
---

# Stage 5: Ship

Goal: create `evidence.md` so a human can decide whether to release. Run agent
reviews first. The human reviews findings about intent and risk.

Heartbeat: on entry and at every sub-task change, overwrite
`.sdlc/work/<slug>/progress.md` with one line —
`ship · <doing what> · <ISO timestamp>` (AGENTS.md rule 9).

## Before you start

Run as a dispatched subagent (AGENTS.md rule 5) — do not assemble evidence in
the context that built the code. Read plan.md, spec.md, deviations.md (if
present), and the diff (`git diff` against the base branch). Micro-track
features have no spec or plan: intent.md replaces both as the upstream
source, and its success criteria are the requirements. Read
`.sdlc/memory/POLICY.md`, `.sdlc/memory/INDEX.md`, `.sdlc/memory/DOMAIN.md`,
and the feature's `harvest.md`; open lesson files whose tags match the
current task.

## Adversarial code review (fresh context)

This review runs at every lazymode level — it is the last look at the diff
before the push, and the only security pass (AGENTS.md rule 3).

Dispatch an adversary (`roles/adversary.md`) with: spec.md, plan.md,
`.sdlc/memory/POLICY.md` if present, and the diff (micro: intent.md and the
diff). It checks spec mismatch, missing untouched checks, security issues,
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
- For brownfield work, compare baseline and after using the same commands.
  Check each "stays untouched" item.
- Include full test, lint, and build results. Long successful logs may use the
  same verdict-lines-and-scratch-citation rule.
- Adversary findings + resolutions.
- State anything not verified, including environment limits and skipped checks.
  Record a gap instead of marking the check as passed.
- For UI changes, the verifier must use the `qa:` tool from config.md — or,
  when that line is empty or absent, any browser or QA tool available in the
  harness — when the app is reachable. Otherwise record why the UI was not
  checked.
- For every AS-IS to TO-BE pair, record the observed result and its command or
  browser evidence.

## Retrospective (mandatory)

Review the feature history. Record what went wrong, what surprised you, and
what would help the next agent — all into the feature's
`.sdlc/work/<slug>/harvest.md` (lesson candidates in the skill 6 format;
durable terms, verified facts, and constraints as domain candidates).
INDEX.md, DOMAIN.md, and lessons/ are written only at close, by the closer
(AGENTS.md rule 4). Domain facts describe the system; lessons describe mistakes. If a
stage skill should have prevented a mistake, add `promote: skills/<n>` to
the lesson candidate. A tag that appears three or more times in INDEX.md
must be promoted: propose the stage-skill change to the human (`close.sh`
prints these).

## Gate

At lazymode ≥3 (AGENTS.md rule 3): after the adversary pass, run
`<kit>/gates/approve.sh ship .sdlc/work/<slug>/evidence.md --lazy`, post the
evidence summary as FYI, and continue to commit discipline. Otherwise:

> Review `.sdlc/work/<slug>/evidence.md`, then:
> `<kit>/gates/approve.sh ship .sdlc/work/<slug>/evidence.md`

STOP after requesting approval.

## After approval: commit discipline

The ship approval and the commit check are two different human checks. At
lazymode ≥3 the staged-set check is also autonomous: verify the staged list
yourself against the rules below, post it as FYI, and commit.

1. Stage named paths only: changed source files, `.sdlc/work/<slug>/`, and
   — when changed — `.sdlc/memory/POLICY.md` and `.sdlc/config.md`
   (lazymode, command, and `qa:` edits must reach the audit trail). Do not
   use `git add -A` or `git add .` because they can include unrelated files.
   Staging `.sdlc/work/<slug>/` yields only `intent.md`, `plan.md`, and
   `map.md`; approvals, spec.md, evidence.md, harvest.md, deviations.md,
   baseline.txt, progress.md, and scratch/ are gitignored (init.sh) and stay
   on disk. If any of them appears in the staged list, the project's
   `.gitignore` predates the kit version in `.sdlc/config.md` — re-run
   `init.sh` and follow its untrack note before committing.
2. Show the human the staged file list with `git status` and the proposed
   commit message. Describe the behavior change, not file names. Wait for the
   human to approve the staged set (lazymode ≥3: verify it yourself against
   step 1 and post as FYI, per the intro above). Evidence approval does not
   approve the staged files.
3. Commit and push following the **Release procedure** line in spec.md. Ask
   separately before pushing a protected or shared branch. After the push,
   delete `.sdlc/work/<slug>/scratch/` — the one cleanup of the loop. Nothing
   is deleted before this point.
