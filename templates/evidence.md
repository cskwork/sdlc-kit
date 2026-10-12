# Evidence: <slug>

- Commit: <sha> <repo path, omit for the project root>
- QA: <agent or session id | unknown>

## Checks
- build: `<command>` → <verdict line>
- test: `<command>` → <verdict line>
- lint: `<command>` → <verdict line>
- e2e: `<command>` → <verdict line>

## Results
| ID | Result | Cause | Observed | Log |
|---|---|---|---|---|
| S1 | <PASS, FAIL or BLOCKED> | <code or plan, for a FAIL> | <what was seen, or what is missing> | logs/S1.txt |

## Bug proof
<bug fixes only: before the fix at <base sha> → <failing line>; after → <passing line>; reported surface re-driven → <result>>

## Delivery
- Target: <local | pr | deploy>
- Delivered: <sha> <repo path, omit for the project root>
- Checked with: <command>
- Output: <the deciding output line, verbatim>
- Authorized: <yes — "the human's words", when intent.md has none for this target>
- Policy: <updated <where> | follow-up <what, owner> | unchanged>
