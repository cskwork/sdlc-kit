# Evidence: <feature slug>

- From: plan.md (approved YYYY-MM-DD)
- Diff: <branch/commit range>
- Origin: <origin.md Ref · live source re-read with <tool>: unchanged | drifted: <what> | unreachable>

<!-- The record store is local to this checkout or to the area it is linked to
     (AGENTS.md rule 7); a clone of the application carries neither this file nor
     the scratch/ logs it cites. Cite scratch/ only NEXT TO the deciding lines
     quoted here, or point at a durable home instead (the PR body, an artifact
     URL). -->


## Proof per requirement
- R1: `<command>` →
  ```
  <real output, verdict lines>
  ```

## Bug proof   <!-- bug fixes only; AGENTS.md rule 6. A missing link = diagnosis, not a fix -->
- Regression test: <path::name, kept in the suite | none — why no test can reach this defect>
- Before: `<that test, or the reproduction steps>` on the pre-fix code → <the observed failure, verbatim>
- Mechanism: <why that code produced that failure — the causal chain, not a guess>
- After: `<the SAME reproduction>` → <passing output>
- Adjacent flows: <other paths through the changed code> → <checked; result>
- Intermittent? <the logs/traces or isolated deterministic repro used instead, and what it does NOT prove>

## Verification   <!-- the three verifier reports (roles/verifier.md), as reported; each check: command/tool · environment · scenario · observed -->
### E2E
- <command/tool> · <environment> · <scenario> → <observed, verbatim; bulk → scratch/>
### Side effects   <!-- AS-IS → TO-BE beyond the requirement -->
- Baseline vs after: <clean | diffs explained> · U1: <checked; result> · neighbouring flows: <named → result>
- Data consistency: <shape → producers/consumers checked → consistent | skew: what>
- Unlisted changes: <behavior spec.md did not name but the code now changes, or none>
### Intent match   <!-- per O-item, against origin.md — not only spec.md -->
- O1 → R1 → <observed> · O2 → <none> → MISSING: <what>
- Covered: <n>/<n> · Missing: <list or none> · Beyond: <list or none>
### Fix loop   <!-- copied from deviations.md; cap 3 rounds -->
- round 1/3: <lens> · accepted <findings> · declined <findings — reason each> · re-check: resolved | open: <what>

## Full checks
- Build: `<command>` → <verdict>
- Test:  `<command>` → <verdict>
- Lint:  `<command>` → <verdict>

## Adversarial code review   <!-- max 2 rounds; the round lines ARE the counter (AGENTS.md rule 5) -->
- round 1/2: <finding> → <fixed | rejected because <reason>>
- round 2/2: <re-review verdict; blockers surviving here go to Not verified and block --lazy>

## Not verified
<honest gaps: a lens with no environment (what is missing), skipped checks, an unreachable origin — never "covered by unit tests">

## Retro lessons   <!-- draft in harvest.md; the close merge writes memory/ -->
- <lesson one-liner> → harvest.md  [promote: skills/<n> if applicable]
