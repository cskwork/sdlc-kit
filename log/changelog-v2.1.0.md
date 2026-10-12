# v2.1.0 — policies through the loop, every way back on the page

Policies now travel with the work from Intent to delivery, and readers can
see where work goes back.

## Changes

- **Policy column.** PLAN.md's AS-IS → TO-BE table names the policy behind
  each behavior: where it is written, with its version, or `code` or
  `unknown`. Behavior that must not change is a row whose TO-BE is
  `unchanged`, with a scenario.
- **Policy owner in Intent.** Risks name a policy the request would change
  and who owns it.
- **Policy at delivery.** A changed policy is updated where it is written in
  the same delivery, or evidence.md's Delivery records the follow-up and its
  owner on a `Policy:` line. The reviewer blocks a policy change that has
  neither.
- **Loops shown.** The README (English and Korean) has a diagram of every way
  back: the plan gap check, a build review FAIL, and Evidence returning to
  Plan or Build. The site's loop section draws the same loop in place of the
  routing table.

No script change; existing records stay valid.
