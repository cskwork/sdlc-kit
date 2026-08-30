# Evidence: <feature slug>

- From: plan.md (approved YYYY-MM-DD)
- Diff: <branch/commit range>

## Proof per requirement
- R1: `<command>` →
  ```
  <real output, verdict lines>
  ```

## Regression   <!-- brownfield -->
- Baseline vs after: <clean | diffs explained>
- U1: <checked; result>

## Full checks
- Build: `<command>` → <verdict>
- Test:  `<command>` → <verdict>
- Lint:  `<command>` → <verdict>

## Adversarial code review   <!-- max 2 rounds; the round lines ARE the counter (AGENTS.md rule 5) -->
- round 1/2: <finding> → <fixed | rejected because <reason>>
- round 2/2: <re-review verdict; blockers surviving here go to Not verified and block --lazy>

## Not verified
<honest gaps: environment limits, skipped checks, and why>

## Retro lessons   <!-- draft in harvest.md; the close merge writes memory/ -->
- <lesson one-liner> → harvest.md  [promote: skills/<n> if applicable]
