---
name: sdlc-intent
description: "Explore-first grilling until intent is exact and evidenced. Triggers: new SDLC feature, fix, or change."
---

# Stage 1: Intent

Goal: create an `intent.md` precise enough to plan without guessing. Verify
the problem, cause, and requested outcome before moving on. Stage 1 is the
least costly place to correct a wrong assumption.

## Before you start

1. Read `.sdlc/memory/POLICY.md`, `.sdlc/memory/INDEX.md`, and
   `.sdlc/memory/DOMAIN.md`; open lessons whose tags match this request.
2. Pick a kebab-case feature slug; create `.sdlc/work/<slug>/`. Prefix with
   the tracker key when one exists (`a20-1234-fix-login`), else the date
   (`260830-fix-login`) — at thousands of tickets, bare names collide. Slugs
   are single-use: if `.sdlc/archive/<slug>/` already exists, pick another
   (`approve.sh` refuses reused slugs).

## Explore before asking questions

Do not ask questions until you have evidence. Without evidence, the user cannot
answer well and you cannot assess options. Once the request is clear, run
fresh-context researchers under `roles/researcher.md`. Run independent probes
in parallel, then start the interview:

- **History** for brownfield work. Check whether this was tried before. Read
  reverts, related tickets, prior fixes, and why they failed in git history
  and commit messages.
- **Affected area**: entry points, data shapes, callers, side effects of the
  code the request touches.
- **Feasibility**: can the behavior run or be reproduced locally? Verify the
  available test infrastructure, development environments, tools, and access.
- **Current browser behavior** for UI changes or hard bugs. When a browser
  tool and reachable environment exist, walk the real flow. Record behavior,
  API calls, and console errors. Use observations, not inferences from code.
  Screenshots follow the bulk rule. For a bug, this capture is reproduction
  evidence.

Skip a probe only when its subject does not exist (say so), or the change is
trivial and you already know the exact file and symbol. Keep raw exploration
out of the main context. Use reports.

**Feasibility rule:** Every option shown to the human must cite evidence that
it is possible. This may include working access, a reproduction, or available
infrastructure. If feasibility is unknown, dispatch research instead of
presenting the option. When dependency compatibility is material and
uncertain, test the exact resolved versions in an isolated disposable
environment with the smallest relevant resolve, compile, or test command.
Record the command, toolchain, and resolved versions. If execution is
unavailable, cite authoritative compatibility evidence and label the remaining
uncertainty.

## Grill protocol

Interview the user one question at a time. Each answer shapes the next
question. Use the agent tool's question feature when available. Continue
until you can restate the intent and the user confirms it — **eight
questions at most**. Not restatable after eight? The ticket is a map, not
an interview: chart the map below. Without a human (lazymode 4) there is
no interview: verify what the probes can, label the rest `[assumed]`, and
route to map when more than two open questions remain. Cover:

1. **Problem, not solution.** What breaks or hurts today? Who encounters it,
   and how often? If the user leads with a solution, ask what problem it solves.
2. **Demand proof. The user may be mistaken.** For every factual claim ("the
   API is slow", "users can't find X", "this bug is in module Y"):
   - Ask for evidence: logs, reproduction steps, a ticket, a metric, a file path.
   - Verify what you can yourself (read the code, run the repro, check the data).
   - Label every claim in intent.md: `[verified: how]` or `[assumed: why]`.
   - If your check contradicts the user, show the evidence and ask which is
     right. Do not defer or override the conflict silently.
3. **Success criteria.** What observable behavior means "done"? How would a
   machine check it?
4. **Scope edges.** What is explicitly NOT included? What must not change?
5. **Constraints.** Deadlines, compatibility, security/compliance, data
   migration concerns.

## Classify: greenfield or brownfield

- **Brownfield** (changes existing behavior): use the explorer reports to
  challenge the user's claims. This is where incorrect assumptions are most
  often caught. Contradiction between a report and a claim goes to the user
  with the evidence, before the intent is written.
- **Greenfield**: ask what existing systems it must integrate with; the
  feasibility explorer verifies those integration points exist as described.

## Too big for one pass? Chart a map first

When the interview cannot pin the intent down in one pass — several decisions
still open, the destination itself fuzzy — do not force a vague intent.md
through the gate. Fill `templates/map.md` → `.sdlc/work/<slug>/map.md` and
work the map instead:

- **Destination**: what "arrived" looks like, in one paragraph.
- **Decided**: decisions made so far, one line each, evidence-labeled.
- **Unknown**: open questions in order. Each session resolves the top one
  (a probe, research, or a question to the human) and moves it to Decided.
- **Out of scope**: what this ticket will not do.

The map lives beside the other artifacts and survives the session; the next
session reads it and takes the top Unknown. When Unknown is empty, write
intent.md as usual — the intent gate stays on intent.md, never on the map.

**Map cap: six sessions, or two consecutive sessions that end with more
Unknowns than they started with.** Increment `- Sessions: n` in map.md each
session. At the cap, STOP and show the human Decided vs Unknown; they
choose — narrow the Destination and restart, or `close.sh <slug> dead-end`
with a lesson naming which Unknown kept splitting. A growing map is a
finding about the Destination, never progress.
If an Unknown turns out to be an independent shippable change, open a new
feature slug for it and record the reference under Decided. When resolving
an Unknown surfaces a durable fact about the system, add it to the feature's
`.sdlc/work/<slug>/harvest.md` as a domain candidate (merged into DOMAIN.md
at close — AGENTS.md rule 4) — Decided records the decision, the harvest
carries the fact to every later feature.

## Write the artifact

Fill `templates/intent.md` → `.sdlc/work/<slug>/intent.md`. Every claim
labeled. Every open question is carried forward explicitly in its own section.
The `Goal:` line is the reporting sentence: one plain-language sentence — no
code identifiers, no jargon — that a non-technical reader understands and can
copy verbatim into a status report ("teachers can re-order quiz questions").

## Too small for the full loop? Micro track

**The full track is the default.** This skill is normally invoked for real
bug fixes and features — those run all six stages. Micro is the exception
for genuinely trivial changes (a typo, a copy change, a one-line guard);
a single "maybe" on any criterion below means full. After drafting
intent.md, it may skip spec and plan entirely (intent → build → ship) when
ALL of these hold:

- `tools/tripwire.sh` over intent.md is clean (necessary, not sufficient —
  it matches keywords), AND you can name the single revert that undoes the
  change;
- the probes named the exact files and symbols to change;
- success is checkable by an existing command from `.sdlc/config.md`;
- intent.md has no open questions.

Record the verdict in intent.md's `Track:` line with the reasons
(`- Track: micro — tripwire clean, single file, test exists`) BEFORE the
intent gate — the approval freezes the verdict. The intent
gate then authorizes build directly (`check-gate.sh intent …`); intent.md's
success criteria serve as the plan, and ship keeps its full adversary
review — the only review the diff gets. Any surprise during build (new
files, a trip-wire, growing scope) upgrades to the full track: STOP,
rewrite the Track line to `- Track: full — upgraded from micro (<reason>)`,
and write spec.md. Incidents have their own version of this — the
compressed loop in skills/6-maintain.

## Gate

At lazymode 4 (AGENTS.md rule 3): run `tools/tripwire.sh` over intent.md. On
a clean scan, approve directly; on any hit, dispatch a fresh-context
adversary (`roles/adversary.md`) over intent.md — this stage has no other
adversary pass. Max 2 adversary rounds: blockers surviving round 2 mean the
intent is unclearable — `close.sh <slug> dead-end "intent blockers: <list>"`
with a lesson, and report them. When the scan is clean or the adversary
raises no blocking objection, run
`<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md --lazy`, post the
intent summary and any objections to the human as FYI, and dispatch Stage 2
as a subagent task. Otherwise tell the user:

> Review `.sdlc/work/<slug>/intent.md`. If it says exactly what you want, run:
> `<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md`

STOP. After approval, dispatch Stage 2 as a subagent task (AGENTS.md rule 5):
give it `skills/2-spec/SKILL.md` and the approved intent.md path — the
artifact, not this conversation, is its input. The orchestrator stays for
routing and gates.
