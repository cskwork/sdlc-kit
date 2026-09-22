# Intent: <feature slug>

- Goal: <ONE plain-language sentence anyone can understand — who can do what
  once this ships. Written to be copy-pasted into a status report verbatim.>
  <!-- The reader's digest (Problem/Cause/Change/Result/Lesson, Tags) lives in
       summary.md (templates/summary.md), NOT here: this file is frozen by its
       approval, summary.md is meant to be kept current. -->
- Date: YYYY-MM-DD
- Type: greenfield | brownfield
- Track: full (default) | compact — <compact only when ALL criteria in skills/1-intent hold; `micro` is the older spelling of compact>
- Requested by: <who>
- Refs: <ticket/PR/incident key or URL, 기획서 path — snapshotted in origin.md
  (templates/origin.md) BEFORE this gate, which binds it. Omit if none>
- Scope authorization: <the scope the human already authorized, in their words —
  e.g. "fix the A20-1234 login redirect and open a PR". This is NOT the stage
  approval: it answers "may this be done at all?" (AGENTS.md rule 3). Anything
  outside it stops the loop at every lazymode.>

## Problem
<What breaks or hurts today. Who encounters it, and how often. Do not describe the solution here.>

## Evidence
<Every factual claim, labeled:>
- <claim> [verified: <command output, file:line, reproduction steps, or metric>]
- <claim> [assumed: <why it could not be verified>]

<For incidents — track requested evidence explicitly; do not let it evaporate.
One line per request, updated in place; max 2 requests, then waived-by-agent
(skills/6-maintain):>
- reproduction evidence: requested <date> (<what was asked for>)
  <!-- update the line to: received <date> | waived-by-human <date, why> | waived-by-agent <date> — unreproduced, diagnosis stays [assumed] -->
- verification debt: <what could not be run because config.md test/lint is empty, and what replaced it>

## Success criteria   <!-- O-numbered: spec R-items cite them; the Intent match lens counts Covered/Missing over them -->
<Observable behavior that means done, in the origin's words (origin.md) or
else the human's. Name a command or test where possible.>
- [ ] O1: <criterion>

## Compact route   <!-- REQUIRED when Track is compact; delete the section on the full track -->
<!-- This is the whole work contract: no spec.md, no plan.md, and nothing
     downstream may ask for one (AGENTS.md "Two routes, one contract"). -->
- Files: <exact paths and symbols that change>
- Proof: <the existing command from .sdlc/config.md that proves it (bug fix: the regression test it runs — AGENTS.md rule 6), and what its passing output means>
- Risk: <blast radius, what else touches this code, the single revert that undoes it>
- Delivery target: local | pr | deploy   <!-- what "shipped" will have to prove; becomes delivery.md's Target -->

## Out of scope / must not change
- <explicitly excluded>
- <behavior that must survive unchanged>   <!-- brownfield: feeds spec's "stays untouched" -->

## Constraints
<deadlines, compatibility, security/compliance, data migration>

## Material questions   <!-- the ones that BLOCK; tools/auto.sh reads this section -->
<!-- A question is MATERIAL when a wrong answer would change what gets built,
     break something, or exceed the authorized scope: which behavior is correct,
     which data is authoritative, whether a risky operation is allowed. It goes
     to the human — an unattended run never guesses one away to make progress.

     ANY content in this section blocks, with or without a bullet: a nested
     list item, a `*` item, a numbered item and a bare sentence all count.
     Exactly two things stop a line from blocking:
       * the canonical marker `— resolved: <answer and where it came from>`,
         written in place so the trail survives (a leading `resolved:` or
         `[resolved …]` reads the same). The marker must OPEN the line or
         follow that dash separator: "unresolved:", "not resolved: pending"
         and "to be resolved with the PM" are not resolutions and still block.
       * a single `none` (or `n/a`) line declaring the section empty.
     An empty section, or one holding only this comment, is the normal state of
     a full-auto-ready intent. Leaving the placeholders below unfilled reads as
     `incomplete`, never as "no questions". -->
- <material question>
- <material question> — resolved: <the answer and where it came from>

## Open questions   <!-- OPTIONAL uncertainty: carried, not blocking -->
<Detail that can be decided from evidence during the work, or labelled
[assumed: why] and carried forward. The spec must answer it or flag it again.>
- <question>

## Researcher findings   <!-- brownfield: summary + pointer to full report -->
<key facts; contradictions with user claims and how they were resolved>
