---
name: sdlc-ship
description: "Evidence assembly, adversarial review, ship gate, commit discipline. Triggers: build green and verified."
---

# Stage 5: Ship

Goal: create `evidence.md` so a human can decide whether to release. Run agent
reviews first. The human reviews findings about intent and risk.

## Before you start

Fresh session. Read plan.md, spec.md, deviations.md (if present), and the
diff (`git diff` against the base branch). Read `.sdlc/memory/INDEX.md` and
`.sdlc/memory/DOMAIN.md`; open lesson files whose tags match the current task.

## Adversarial code review (fresh context)

Dispatch an adversary (`roles/adversary.md`) with: spec.md, plan.md, the diff.
It checks spec mismatch, missing untouched checks, security issues, tests that
cannot fail, and complexity that hides bugs. Fix findings or
record justified rejections.

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
- For UI changes, the verifier must use a browser or QA tool when one is
  available and the app is reachable. Otherwise record why the UI was not
  checked.
- For every AS-IS to TO-BE pair, record the observed result and its command or
  browser evidence.

## Retrospective (mandatory)

Review the feature history. Record what went wrong, what surprised you, and
what would help the next agent. Add lessons using the skill 6 format. Add
durable terms, verified facts, and constraints to `.sdlc/memory/DOMAIN.md`.
Deduplicate entries and keep the file within its limit. Domain facts describe
the system; lessons describe mistakes. If a stage skill should have prevented
a mistake, add `promote: skills/<n>` to the lesson. A tag that appears three
or more times in INDEX.md must be promoted: propose the stage-skill change to
the human (`close.sh` prints these).

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

1. Stage named paths only: changed source files, `.sdlc/work/<slug>/`, changed
   `.sdlc/memory/` paths, and `.sdlc/approvals/`. Do not use `git add -A` or
   `git add .` because they can include unrelated files and scratch output
   (scratch/ is gitignored and stays on disk until step 3).
2. Show the human the staged file list with `git status` and the proposed
   commit message. Describe the behavior change, not file names. Wait for the
   human to approve the staged set. Evidence approval does not approve the
   staged files.
3. Commit and push following the **Release procedure** line in spec.md. Ask
   separately before pushing a protected or shared branch. After the push,
   delete `.sdlc/work/<slug>/scratch/` — the one cleanup of the loop. Nothing
   is deleted before this point.
