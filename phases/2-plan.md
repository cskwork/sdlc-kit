# Phase 2: Plan — explore, then document

Goal: understand the domain, data, logic, source of truth and user flow well
enough that side effects are found here, before any code. Scouts write
`refs/`; you compact them into one `PLAN.md`.

## 1. Scout

`sdlc.sh check intent <slug>` must print GATE OPEN. Read the `memory`
folder and phase 1's `refs/` and `logs/` first: a fact they already give
with a source is not scouted again.
Dispatch one scout (`roles/scout.md`) per open question, in parallel, each
writing one file in `refs/`:

| Scout | File | Answers |
|---|---|---|
| source | `refs/source.md` | the request's text, the policies and canonical docs it touches, earlier attempts and reverts and why |
| data | `refs/data.md` | data models and fields, who writes and reads each, the states existing records are in |
| logic | `refs/logic.md` | entry points, call chains, every caller in every tier and repository the change crosses, shared code, every consumer of an identifier the change renames, retires or redirects |
| flow | `refs/flow.md` | how each persona reaches the behavior today, observed by running it, with the result |

A bug adds `refs/repro.md`: starting from phase 1's reproduction, the
failure as a failing test where one can reach it, and its cause, with rival
causes ruled out.
Scale to the unknowns: skip a scout whose answer you can already cite with
file:line; a small change in known files may need none. Facts worth keeping
beyond this feature go to `refs/learnings.md`, one line each with a source.

## 2. Write PLAN.md

Fill `templates/PLAN.md`, 150 lines at most. It summarizes; refs hold the
evidence. Link, do not copy.
- **Understanding** — a few lines each on data, logic, source of truth and
  user flow, each with its ref.
- **AS-IS → TO-BE** — every behavior before and after, with the policy that
  sets it; AS-IS as observed. Behavior that must not change is a row whose
  TO-BE is `unchanged`, with a scenario.
- **Side effects** — every other reader or writer of the touched data, every
  caller that sends today's shapes (missing, empty, null, old values),
  records made before the change, shared code, every consumer of a changed
  identifier (even one that only compares it) — each with how it stays
  correct and the scenario that checks it. Then the risk flags line.
- **Changes** — files and symbols, in an order that keeps checks passing;
  the smallest runnable path first.
- **Scenarios** — the QA contract, written before the code. A persona is
  whoever uses the change: a user role, an API client, an operator, a job, a
  library caller. Steps go through the real interface. Every `O` has at
  least one `must` scenario; side effects get scenarios; a bug's reported
  failure is a `must` scenario.

## 3. Gap check

Dispatch the reviewer (`roles/reviewer.md`, plan mode) with intent.md,
PLAN.md and `refs/`. Fix what it finds; one round, two at most. A finding
that changes the intent goes to the human.

## Gate

When `plan` is in `human_gates` or a risk flag says yes: show the human the
Summary, AS-IS → TO-BE and the flags, then `sdlc.sh approve plan <slug>
--human "<their words>"`. Otherwise `sdlc.sh approve plan <slug> --agent
"<what the gap check covered>"` and post the Summary as FYI. Then phase 3.

## Back from Evidence

`sdlc.sh next` names the failing scenarios the plan got wrong. Re-scout only
that gap, update `refs/` and PLAN.md (add a missed scenario under the ID QA
gave it), and approve again. An unchanged PLAN.md is refused unless the
human approves it. Only the human can remove a scenario or drop its must; a
scenario only QA added goes by deleting its `evidence.md` row before the
human approves.
