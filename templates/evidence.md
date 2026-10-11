# Evidence: <feature slug>

- From: plan.md (approved YYYY-MM-DD) | intent.md (compact route, approved YYYY-MM-DD)
- Diff: <branch/commit range>
- Origin: <origin.md Ref · live source re-read with <tool>: unchanged | drifted: <what> | unreachable>
- Reviewed source/inputs: <revision + working-tree identity, recipe identity,
  upstream input identities and exact paths; later changes need affected proof
  and final diff review again>
- Review provenance: <full: three fresh verifier contexts + separate adversary;
  approved compact: one fresh reviewer, three lenses then final diff check;
  actual reviewer/context/tool IDs when exposed, otherwise unknown — why>

<!-- The record store is local to this checkout or to the area it is linked to
     (AGENTS.md rule 7); a clone of the application carries neither this file nor
     the scratch/ logs it cites. Cite scratch/ only NEXT TO the deciding lines
     quoted here, or point at a durable home instead (the PR body, an artifact
     URL). -->


## Proof per requirement   <!-- variants and source rung: roles/verifier.md -->
- R1: `<command>` →
  ```
  <real output, verdict lines>
  ```
  - R1.happy · source <user | fixture | real | synthesized> → <observed> · R1.boundary … · R1.negative … · <R1.regression · R1.authz where they apply>
  - roles/platforms: <role or platform> → <observed> | NOT VERIFIED: <what would unblock>
- Reach: R1.entry · <caller> → <observed> · R2.state · <record> → <observed> · R1.context · <condition> → <observed> | gap: <axis — why nothing else exists>
- Receipt: `tools/verify.sh check <slug>` → <VERIFY line, verbatim> · coverage: <gap: lines, or none>   <!-- recipe only -->

## Bug proof   <!-- bug fixes only; AGENTS.md rule 6. A missing link = diagnosis, not a fix -->
- Regression test: <path::name, kept in the suite | none — why no test can reach this defect>
- Before: `<that test, or the reproduction steps>` on the pre-fix code → <the observed failure, verbatim>
- Mechanism: <why that code produced that failure — the causal chain, not a guess>
- After: `<the SAME reproduction>` → <passing output>
- Reported surface: <the screen, request or job the failure was reported on> → <observed there after the fix | NOT VERIFIED: what would unblock | n/a — the test is where it was reported>
- Adjacent flows: <other paths through the changed code> → <checked; result>
- Intermittent? <the logs/traces or isolated deterministic repro used instead, and what it does NOT prove>

## Verification   <!-- preserve the three lens reports and provenance as reported (roles/verifier.md); compact may share provenance once, never omit a lens. Each check: command/tool · exit · environment · scenario · observed + log and deciding lines. Ship needs each lens's VERDICT line, or AGENTS.md rule 5's explicit independence gap. -->
### E2E
- <command/tool> · <environment> · <scenario> → <observed, verbatim; bulk → scratch/>
VERDICT: <the E2E report's VERDICT line, verbatim>
### Side effects   <!-- AS-IS → TO-BE beyond the requirement -->
- Baseline vs after: <clean | diffs explained> · U1: <checked; result> · neighbouring flows: <named → result>
- Data consistency: <shape → producers/consumers checked → consistent | skew: what>
- Input adversary: <missing | empty | null | wrong-type | unknown> · <domain-valid legacy | invalid | inapplicable — reason> · <caller/record source> · expected <value/refusal/state> → observed <value/status/state>
- Unlisted changes: <behavior spec.md did not name but the code now changes, or none>
VERDICT: <the Side effects report's VERDICT line, verbatim>
### Intent match   <!-- per O-item, against origin.md — not only spec.md -->
- O1 → R1 → <observed> · O2 → <none> → MISSING: <what>
- Covered: <n>/<n> · Missing: <list or none> · Contradicts: <list or none> · Beyond: <list or none>
VERDICT: <the Intent match report's VERDICT line, verbatim>
### Fix loop   <!-- copied from deviations.md; cap 3 rounds -->
- round 1/3: <lens> · accepted <findings> · declined <findings — reason each> · re-check: resolved | open: <what>

## Full checks
- Build: `<command>` → <verdict>
- Test:  `<command>` → <verdict>
- Lint:  `<command>` → <verdict>
- Failures: pre-existing <checks, failing the same way at base <ref @ sha>> | none · regressions <checks> | none

## Adversarial code review   <!-- max 2 rounds; the round lines ARE the counter (AGENTS.md rule 5) -->
- Reviewed: <same final source/inputs as above; compact combined review retained
  | full separate reviewer>; provenance <actual IDs | unknown — why>;
  <preserve report and per-file rows; commands/exits/logs/deciding lines>
- round 1/2: <finding> → <fixed | rejected because <reason>>
- round 2/2: <re-review verdict; blockers surviving here go to Not verified and block --lazy>

## Not verified
<honest gaps: a lens with no environment (what is missing), skipped checks, an unreachable origin — never "covered by unit tests">
- Verification gap: <the `VERIFY blocked` detail, verbatim> — ships only with the human's `--accept-gap` words | none

## Retro lessons   <!-- draft in harvest.md; the close merge writes memory/ -->
- <lesson one-liner> → harvest.md  [promote: skills/<n> if applicable]
