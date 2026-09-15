# Evidence: <feature slug>

- From: plan.md (approved YYYY-MM-DD)
- Diff: <branch/commit range>

<!-- scratch/ is gitignored and local-only: a fresh clone has the citation but not
     the file. Cite it only NEXT TO the deciding lines quoted here, or point at a
     durable home instead (the PR body, an artifact URL). -->


## Proof per requirement
- R1: `<command>` →
  ```
  <real output, verdict lines>
  ```

## Bug proof   <!-- bug fixes only; AGENTS.md rule 6. A missing link = diagnosis, not a fix -->
- Before: `<the reproduction command / steps>` → <the observed failure, verbatim>
- Mechanism: <why that code produced that failure — the causal chain, not a guess>
- After: `<the SAME reproduction>` → <passing output>
- Adjacent flows: <other paths through the changed code> → <checked; result>
- Intermittent? <the logs/traces or isolated deterministic repro used instead, and what it does NOT prove>

## End-to-end check   <!-- the change exercised for real, scoped to it (roles/verifier.md) -->
- Command/tool: <the real UI tool, request, or CLI invocation — config.md `e2e:`/`qa:`/`run:` where set>
- Environment: <where it ran: local instance, staging URL, seeded fixture data>
- Scenario: <the user's or caller's steps>
- Observed: <the final result as the user/caller sees it, verbatim; bulk → scratch/>
- Neighbouring flows: <the ones sharing the changed code> → <result>
- NOT VERIFIED: <what could not be run for real, and what is missing — never "covered by unit tests">

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
