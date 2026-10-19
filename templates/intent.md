# Intent: <slug>

- Date: <YYYY-MM-DD>
- Requested by: <who>
- Source: <ticket, issue or document link | chat>

## Request
<the human's words, verbatim or a faithful excerpt>

## Understood as
- Outcome: <one plain sentence: who can do what once this is done>
- In scope: <…>
- Out of scope: <…>
- O1: <observable success criterion>

## Terms
<!-- Each term the request turns on, or none: ✅ one meaning, ⚠️ assumed, ❓ two readings (each with a real value; its Clarity area stays open). -->
- ✅ <term> = <plain meaning>, e.g. <real value>
  - Source: <glossary line | requester's words | file:line> · Code: <identifier>

## Clarity
<!-- State: clear, assumed or open. sdlc.sh scores clear 1, assumed 1/2, open 0 and refuses approval below 90%: one assumed area passes; two, or one open, do not. How settled: the evidence that leaves one reading, why it is assumed, or what is missing. -->
| Area | State | How settled |
|---|---|---|
| Outcome | <state> | <who gets what, and why> |
| Scope | <state> | <what is in and out, and who drew the line> |
| AS-IS | <state> | <today's behavior as observed; a bug as reproduced> |
| TO-BE | <state> | <the exact behavior: rules, values, messages, edge cases> |
| Success | <state> | <how each O is observed> |
| Constraints | <state> | <policies, compatibility, data, owners — or none found, where you looked> |

## Risks in this intent
- <an ambiguity, a claim the code or data contradicts (with evidence), a policy the request would change and its owner, work that needs the human's authority — or none>

## Blocking questions
- none
<!-- a question here blocks approval until its line ends with "— resolved: <answer, source>"; while the requester has it, add "— asked: <where, when>" -->

## Delivery
- Target: <local | pr | deploy>
- Note: <optional: branch, environment or anything else about the delivery>
- Authorized: <yes — "the human's words authorizing push, merge or deploy" | no>
