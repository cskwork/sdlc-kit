# v2.14.0: intent.md in plain words, with why the request came up

Follow-up to v2.13.1. The intent and evidence templates, the prompts that name their labels, `sdlc.sh` messages and the to-do phase label; the approval rules, phase ids, `.state` keys and route values are unchanged.

## Changes

- **New "Why this came up" section.** `templates/intent.md` now has it right after What was asked. `phases/1-intent.md`: when the request, ticket or thread says why, quote or cite it; otherwise infer it from the whole context (ticket history, linked issues, commits, `memory`), start the line with `(inferred)` in the requester's language (Korean `(추정)`) and cite what it rests on; never state an inference as fact.
- **Plain-English labels.** Headings and field labels a first-time reader understands without the kit's jargon; the body stays in the requester's language.

  | Before | Now |
  |---|---|
  | `## Bottom line` — Changes · Left out · Needs you | `## At a glance` — What changes · Not included · Your call |
  | `## Request` | `## What was asked` |
  | — | `## Why this came up` |
  | `## Understood as` — In scope · Out of scope · `O1:` | `## What we will do` — Included · Not included · Done when `O1:` |
  | `## Risks in this intent` | `## Risks` |
  | `## Delivery` — Target · Authorized (intent and evidence), Delivered (evidence) | `## Shipping` — Ship to · Allowed, Shipped |
  | `## Blocking questions` | `## Questions for you` (still blocks approval; `— resolved:` and `— asked:` unchanged) |
  | `## Terms` | `## Key terms` |
  | `## Clarity` — Outcome · Scope · AS-IS · TO-BE · Success · Constraints, column How settled | `## How sure we are` — Goal · Boundaries · Today · After · Done when · Limits, column Based on |
  | Deliver (phase 4 section, `next` action "deliver, fill Delivery") | Ship ("ship, fill Shipping") |
  | to-do phase label Deliver / 전달 | Ship / 반영 |

  `O<n>` IDs, `Note`, `Checked with`, `Output`, `Policy`, `local | pr | deploy` and `clear | assumed | open` keep their names. PLAN.md's AS-IS → TO-BE is unchanged.
- **Messages name the new labels.** For example `What we will do needs a filled O1 line (done when)`, `Ship to (under Shipping) must be local, pr or deploy …`, `Goal (How sure we are): State must be clear, assumed or open`, `How sure we are needs a row for Done when (was Success)`, `Shipped missing for repo: …`. A weak or malformed area is named as written in the file.
- `README.ko.md` explains each intent.md label in Korean once; both READMEs describe the new sections.
- To stay within the 6000-word prompt budget, phase 4's Run paragraph no longer repeats what `roles/qa.md` already says (preflight, re-runs, cause definitions), and its return-cap sentence that repeated rule 6 is gone.

## Compatibility

- `sdlc.sh` reads both label sets, so features started before v2.14.0 keep working without edits, and their intent approvals (bound to the file's sha) stay valid: `## Understood as` or `## What we will do`; `## Clarity` or `## How sure we are`, with old and new area names mapped to one area each (Outcome = Goal, Scope = Boundaries, AS-IS = Today, TO-BE = After, Success = Done when, Constraints = Limits; an old and a new name for the same area count as a duplicate); `## Blocking questions` or `## Questions for you`; `## Delivery` or `## Shipping` with `Target:` or `Ship to:`, `Authorized:` or `Allowed:`, and in evidence `Delivered:` or `Shipped:`. `O` lines may be indented under `Done when:`.
- `sdlc.sh new` copies the new template. Edit an older intent.md in its own labels.
- Error message text changed (see above); a host matching the old strings must update.

## Validation

- macOS local (Node 22.19.0): to-do Node tests 180/180 passed.
- `tests/selftest.sh` was not run locally (a local hook blocks its `git reset --hard` fixtures); CI runs it. Its old-label assertions were updated, and a new `labels` group checks a filled new template, a new-format intent (What we will do, How sure we are with new area names, Questions for you, Shipping with Ship to and Allowed) and new-format evidence (Shipping, Shipped), and an old-format intent and evidence end to end.
- In a scratch copy under `/tmp` with every hard-reset line left out (the `uncommitted` group and the top-level checks after the first hard reset): 117 checks passed, including the `delivery`, `paths`, `target`, `clarity` and new `labels` groups, the prompt word limits (total 5995 of 6000; intent load 2325 of 2500) and `sdlc.sh` at 599 of 600 lines. A second scratch run mirrored the two skipped label assertions (fresh template `next`, raw evidence template Shipping `close`): both passed.
