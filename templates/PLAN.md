# Plan: <slug>

## Summary
<three lines for the human: what changes, the main risk, how it is proven>

## Understanding
- Data: <…> (refs/data.md)
- Logic: <…> (refs/logic.md)
- Source of truth: <…> (refs/source.md)
- User flow: <…> (refs/flow.md)

## AS-IS → TO-BE
| Behavior | Policy | AS-IS (observed) | TO-BE |
|---|---|---|---|
| <…> | <where it is written, with version | code | unknown> | <…> | <… | unchanged> |

## Side effects
- <another reader or writer, caller, existing record state or shared path> → <how it stays correct> (<scenario ID>)
- Risk flags: migration no · data deletion no · public API no · security no · infra no

## Changes
1. <file or symbol> — <what and why>

## Scenarios
| ID | Persona | Steps | Expected | Must | Covers |
|---|---|---|---|---|---|
| S1 | <who> | <steps through the real interface> | <observable result> | yes | O1 |
<!-- write \| for a literal pipe inside a cell -->

## Out of scope and open questions
- <…>
