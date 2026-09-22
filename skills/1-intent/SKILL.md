---
name: sdlc-intent
description: "Explore-first grilling until intent is exact and evidenced. Triggers: any feature, fix, or change request in a project with .sdlc/, however it is worded."
---

# Stage 1: Intent

Goal: create an `intent.md` precise enough to plan without guessing. Verify
the problem, cause, and requested outcome before moving on. Stage 1 is the
least costly place to correct a wrong assumption.

Heartbeat throughout: AGENTS.md rule 9.

## Before you start

1. Read memory (AGENTS.md rule 4), then **retrieve what past features
   already decided about this area**:
   `tools/kb.sh search "<the feature's own words>"` over the request's main
   nouns (the module, the endpoint, the error text), and
   `tools/kb.sh show <slug>` for any feature the hits name (closed ones
   included — AGENTS.md rule 7). Two or three targeted searches, not a scan
   of the archive: what you find goes into the Evidence section with its
   source path.
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
`.sdlc/work/<slug>/harvest.md` as a domain candidate (AGENTS.md rule 4) —
Decided records the decision, the harvest carries the fact to every later
feature.

## Write the artifact

Write `summary.md` beside it (templates/summary.md) — the page a human reads
instead of the stage files, printed first by `tools/kb.sh show` and the
contents page. Name the product area(s) on its `Area:` line — for a web app
the menu path a user clicks, in the exact words of the existing area page
(`tools/kb.sh index` lists them), or as the UI labels it when no page exists
yet. Open the page with `tools/kb.sh show <area>` and cite the business rules
(P-numbers) the request touches in intent.md's Evidence section. Fill What was wrong and Before → After as far as they are
known; `Status: not delivered`. No approval binds summary.md, so later
stages keep it true (skills/5-ship finishes it).

When the request has an origin — a ticket, a 기획서, an incident — snapshot
it FIRST as `.sdlc/work/<slug>/origin.md` (templates/origin.md): the intent
approval binds it, so it is written before the gate, and an edit afterwards
closes the gates by design (an edited ticket is a new decision). Number the
success criteria `O1..On` in the origin's words (else the human's): spec
R-items cite them and the verifier's Intent match lens counts Covered/Missing
over them.

Fill `templates/intent.md` → `.sdlc/work/<slug>/intent.md`. Every claim
labeled. Questions are carried forward in two sections, and the split matters:

- **`## Material questions`** — a wrong answer would change what gets built,
  break something, or exceed the authorized scope. These BLOCK: they go to the
  human and are never guessed away to make progress. Resolve a line in place
  (`— resolved: <answer, and where it came from>`) so the trail survives. The
  marker is anchored to that position: "not resolved: …" is not a resolution.
- **`## Open questions`** — optional uncertainty, decidable from evidence
  during the work or carried as `[assumed: why]`. These block nothing.

`- Scope authorization:` records the scope the human already authorized, in
their words. It is authority, not a gate approval (AGENTS.md rule 3): inside it
do not ask again; outside it the loop stops at every lazymode.
`tools/auto.sh intent-check <slug>` checks this contract — actionable Goal,
scope authorization, acceptance criteria, non-goals, labelled evidence, no
unresolved material question — and an unattended run may not act on an intent
that fails it.
The `Goal:` line is the reporting sentence: one plain-language sentence — no
code identifiers, no jargon — that a non-technical reader understands and can
copy verbatim into a status report ("teachers can re-order quiz questions").

## Which route: compact or full

Two routes, one contract (AGENTS.md "Two routes, one contract"). Features
and bug fixes both use them; incidents use the same compact route, not a
separate compressed loop.

**Compact** — for a small, well-understood, bounded change: intent (gate) →
build → ship → close, with intent.md as the single work artifact. No spec,
no plan, and nothing downstream may demand one. Take it only when ALL hold:

- the change is bounded and you can name the single revert that undoes it;
- the probes named the exact files and symbols to change;
- success is checkable by an existing command from `.sdlc/config.md`;
- intent.md has no open questions at all — optional ones included: on the
  full route the spec answers them, and the compact route has no spec;
- the work is inside what the human has already authorized — no data loss,
  public API change, security path, or migration outside that scope
  (AGENTS.md rule 3 "Autonomy is not authority"). A clean `tools/tripwire.sh`
  run does not establish this; reading the affected code does.

A single "maybe" means **full**. Ambiguity, breadth, and risk are exactly
what the spec and plan gates exist for.

A compact intent.md carries what spec and plan would have carried, in five
extra lines (templates/intent.md): **Files** to change, **Proof** command,
**Risk** and its blast radius, **Baseline** (brownfield), **Delivery
target** (local | pr | deploy). Without those five it is not compact-ready —
write them or go full.

Record the verdict in the `Track:` line with the reasons
(`- Track: compact — two known files, existing test covers it`) BEFORE the
intent gate; the approval freezes it (`micro` is the older spelling and
still parses). Ship keeps its full adversary review — the only review that
diff gets.

**Upgrade (any build surprise → full):** STOP, rewrite the Track line to
`- Track: full — upgraded from compact (<reason>)`, re-approve intent, then
write spec.md. The re-approval is not a formality: the human approved a
route with no spec or plan gate, and that verdict has changed. `approve.sh`
refuses a spec or plan approval until intent is re-approved as full.

## Gate

At lazymode 4 (AGENTS.md rule 3): review the change itself — the code the
intent points at and the behavior it would alter. A `tools/tripwire.sh` hit
over intent.md means a fresh-context adversary (`roles/adversary.md`)
reviews it — this stage has no other adversary pass. Max 2 adversary
rounds: blockers surviving round 2 mean
the intent is unclearable — `close.sh <slug> dead-end "intent blockers:
<list>"` with a lesson, and report them. When your review finds no blocking
objection, run:

```
<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md --lazy \
  --review "<what you actually reviewed>" [--risk-authorized "<the human's words>"]
```

Post the intent summary and any objections as FYI and continue (AGENTS.md
rule 3 "A waived gate is not a stop"); an unresolved MATERIAL question
stops the loop here, at every level.

Below lazymode 4 the intent gate is the human's. Tell the user:

> Review `.sdlc/work/<slug>/intent.md`. If it says exactly what you want, run:
> `<kit>/gates/approve.sh intent .sdlc/work/<slug>/intent.md`

and STOP there. After approval, continue to stage 2 (`skills/2-spec/SKILL.md`) — or, on
the compact route, straight to build (`skills/4-build/SKILL.md`) with the
intent gate as its gate. The approved artifact, not the conversation, is
the input.
