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

## Adversarial code review
- <finding> → <fixed | rejected because <reason>>

## Not verified
<honest gaps: environment limits, skipped checks, and why>

## Retro lessons
- <lesson one-liner> → .sdlc/memory/lessons/<file>  [promote: skills/<n> if applicable]
