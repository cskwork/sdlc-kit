# Intent: <feature slug>

- Goal: <ONE plain-language sentence anyone can understand — who can do what
  once this ships. Written to be copy-pasted into a status report verbatim.>
- Date: YYYY-MM-DD
- Type: greenfield | brownfield
- Track: full (default) | micro — <only when ALL criteria hold; evidence per skills/1-intent>
- Requested by: <who>

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

## Success criteria
<Observable behavior that means done. Name a command or test where possible.>
- [ ] <criterion>

## Out of scope / must not change
- <explicitly excluded>
- <behavior that must survive unchanged>   <!-- brownfield: feeds spec's "stays untouched" -->

## Constraints
<deadlines, compatibility, security/compliance, data migration>

## Open questions
<Carry each question forward. The spec must answer it or flag it again.>
- <question>

## Researcher findings   <!-- brownfield: summary + pointer to full report -->
<key facts; contradictions with user claims and how they were resolved>
