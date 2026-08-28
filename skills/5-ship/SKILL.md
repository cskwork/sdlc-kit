---
name: sdlc-ship
description: "Evidence assembly, adversarial review, ship gate, commit discipline. Triggers: build green and verified."
---

# Stage 5: Ship

Goal: an `evidence.md` that lets the human approve the release by reviewing
what the agents flagged — layered agentic review first, human attention
reserved for intent and risk.

## Before you start

Fresh session. Read plan.md, spec.md, deviations.md (if present), and the
diff (`git diff` against the base branch). Read `.sdlc/memory/INDEX.md` and
`.sdlc/memory/DOMAIN.md`.

## Adversarial code review (fresh context)

Dispatch an adversary (`roles/adversary.md`) with: spec.md, plan.md, the diff.
It attacks: spec mismatch, missing untouched-checks, security issues, test
theater (tests that can't fail), complexity that hides bugs. Fix findings or
record justified rejections.

## Assemble evidence

Fill `templates/evidence.md` → `.sdlc/work/<slug>/evidence.md`:

- Per spec requirement: the command run + REAL output (paste, don't summarize
  away the numbers). Evidence comes from the toolchain, not from your claims.
- Brownfield: baseline vs after — same commands, diffed; each "stays
  untouched" item explicitly checked.
- Full test/lint/build output (trimmed to verdict lines + failures, if any).
- Adversary findings + resolutions.
- Anything NOT verified, stated plainly (environment limits, skipped checks).
  An honest gap beats a false green.
- UI-facing change? The verifier should have exercised the running app through
  a browser/QA tool if one is available — and evidence.md must say whether
  that happened or state plainly that no eyes were on pixels.
- Where the spec has AS-IS → TO-BE pairs, evidence proves each TO-BE
  observed (browser capture or command output) — the same pairs, third
  column filled: OBSERVED.

## Retro (mandatory, 2 minutes)

Scan the feature's history: what went wrong, what surprised, what would you
tell the next agent? Record lessons per skill 6 format. Separately, harvest
domain knowledge: durable terms, verified facts, and constraints this feature
uncovered go into `.sdlc/memory/DOMAIN.md` (dedup, keep the cap) — they are
facts about the system, not mistakes, so they are not lessons. If a lesson
fires on
something a stage skill should have prevented, note in the lesson:
`promote: skills/<n>` — the human can then patch the skill; that is the
continual-improvement loop closing.

## Gate

> Review `.sdlc/work/<slug>/evidence.md`, then:
> `<kit>/gates/approve.sh ship .sdlc/work/<slug>/evidence.md`

STOP after requesting approval.

## After approval: commit discipline

The ship approval and the commit check are two different human checks.

1. Delete `.sdlc/work/<slug>/scratch/` if present — only artifacts ship.
2. Stage NAMED paths only — the changed source files, `.sdlc/work/<slug>/`,
   and `.sdlc/approvals/` (guardrail: `git add -A` / `git add .` sweep in
   strays and are how scratch leaks into history).
3. Show the human the staged file list (`git status`) and the proposed commit
   message — subject describes the behavior change in plain words, not file
   names. Wait for their word; approval of evidence was not approval of the
   staged set.
4. Commit and push. Pushing a protected/shared branch needs its own approval.
