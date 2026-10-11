# Delivering software with sdlc-kit

The unit of work is a runnable, reviewable change that fulfills an approved
outcome. The stage artifacts carry that change from request to verified
delivery; completing the documents alone does not complete the work.

This guide explains how to use the existing loop efficiently. Gates,
authorization, review independence, and retry caps remain in [AGENTS.md](../AGENTS.md).
Host commands and receipt semantics remain in [automation.md](automation.md).

## Choose a slice that can finish

Use one delivery-sized vertical slice: one user or caller can achieve an
observable result through the real interface, with the necessary code, tests,
and data handling together. Keep its requirement IDs (`R1`, or compact `O1`)
through plan, checks, evidence, and QA steps. Define expected values and state
changes before implementation, including how a rejected operation behaves.

A slice is complete when its requirements and affected neighboring behavior
are proven on the final source and its agreed delivery target is confirmed.
Split an oversized request into independently useful outcomes in `map.md`;
record dependencies there instead of creating parallel unfinished layers.
Use the compact route when its existing criteria fit.
Before scope and Track are frozen, establish current caller and saved-record
compatibility evidence (stage 1). Judge boundedness by risk, affected surfaces
and reversibility. Exact known compact probes may be run by the author;
uncertain or broad behavior needs fresh research.

## Make the product runnable early

In plan.md's **Order of work**, put the shortest real path through the product
first. For greenfield work, the first build step establishes install/build,
launch, readiness, one meaningful action, and cleanup. Run it before expanding
the feature. For brownfield work, drive the existing path before editing and
retain the baseline and bug reproduction required by the contract.

Use the project's own scripts and fixtures. Put reusable commands in
`.sdlc/config.md`; when using receipts, fill the existing `.sdlc/verify.md`
recipe and feature requirement checks. A readiness check identifies the
instance under test, so a previous process cannot supply a false pass.
An unavailable runtime is an explicit blocker or verification gap, resolved
under the existing gate rules.

On resume, read `tools/auto.sh next <slug>` and the feature records, then inspect
the current branch, source changes, and runtime before acting. Re-run the
smallest affected smoke check if they differ from the last observation.
Check existing external effects before retrying them; the
[checkpoint procedure](automation.md#6-checkpoint-retries-pause-and-resume)
records bounded attempts and completed effects.

## Spend checks where failure matters

Put scoped quality checks in the plan's existing **Risks** and **Proof** and
execute them through the verifier lenses. Keep the contract's scenario floor;
choose additional checks from the touched behavior and its reach:

| Changed behavior | Evidence to include when applicable |
|---|---|
| UI or interaction | Actual rendered result, loading/empty/error recovery, keyboard and focus behavior, labels, and the layouts/platforms in scope |
| Data or state | Read back writes, older records, other producers/consumers, and failure or retry without partial or duplicate state |
| Authentication or permissions | Intended role succeeds; wrong role is refused; protected data and state stay protected |
| API, CLI, or job | Real invocation, exact values and exit/status behavior, invalid input, and affected callers |

The Side effects lens owns input-adversary checks: domain-applicable missing,
empty, null, wrong-type and unknown values, valid legacy shapes still accepted,
invalid inputs safely refused without crash or partial writes. Use observed
caller/record evidence and the domain contract to choose behavior, including
any default; a missing example does not authorize a new required field.

Choose the smallest existing solution that meets these expectations.
Additional architecture, redesign, performance work, or unrelated cleanup
needs a demonstrated requirement and authorization. Keep one author carrying
the loop; dispatch targeted read-only probes and the required independent
reviews with bounded inputs. Stage names are not separate implementation jobs.

## Finish on the source that will be delivered

Run narrow checks during each slice, then the configured full checks on the
final source. The independent verifier drives the real path and its failure
cases; the adversary reviews that final diff. A later source or recipe edit
or upstream review-input change requires fresh affected proof and final diff
review and, when configured, a new receipt before ship. Full uses three fresh
verifiers in parallel plus a separate adversary; approved compact uses one
fresh reviewer for all three complete lenses followed by the complete final
diff check on the same source. Keep three lens VERDICT lines and the adversary
verdict. Inspect and reuse current evidence rather than rerunning unchanged
commands or dispatching another compact diff review. Record actual reviewer
and tool IDs where available, otherwise explicit unknowns, exact input paths,
commands/exits/logs and deciding lines. Provenance is not authentication.
Record the source
identity beside the deciding outputs in evidence.md, and confirm the delivered
source in delivery.md. A successful command alone does not prove its expected
value or resulting state.

For bugs, preserve the same reproduction from failure through fix and adjacent
flows. For PR delivery, verify the remote branch and PR through the project's
tools, include the actual QA steps, and address CI or review findings through
the existing fix loop. Follow the existing authorization boundary for merge
and deploy.

## Check the kit separately from an agent's performance

Run from the kit root in Bash, with Python 3 available:

```bash
bash gates/selftest.sh
python tests/test_runner.py
bash tests/factory-e2e.sh
```

On Windows, first run the [actual-shell preflight](windows.md), then these
commands in that Git Bash context; `selftest.sh` also requires native symbolic-link creation permission and the Git/MSYS settings in [.github/workflows/selftest.yml](../.github/workflows/selftest.yml).

`selftest.sh` checks gate and artifact mechanics. `test_runner.py` checks
bounded command execution and cleanup. `factory-e2e.sh` exercises a deterministic
development lifecycle on a real stdlib task CLI: persisted state, a completion
feature, a sparse-legacy-ID collision fix, real CLI checks, base failure and
current success, stale-proof refusal, and review-branch delivery to a local
bare remote. It needs no model credentials or public publication.

These tests establish harness integration, not a statistical measurement of
agent quality or complete product correctness. To compare guidance, give clean
sessions the same held-out feature and bug tasks, fixture, tools, and budget.
Judge observable outcomes and final artifacts with an independent rubric;
repeat runs and report failures, runtime, and cost alongside success rates.
Keep deterministic kit checks separate from those agent evaluations.

## Rationale

This operating pattern draws on incremental feature work, restart artifacts,
and real E2E checks in Anthropic's
[long-running agent harness guidance](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents),
the distinction between outcomes and transcripts in its
[agent evaluation guidance](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents),
and small integrated changes with automated checks in Martin Fowler's
[Continuous Integration](https://martinfowler.com/articles/continuousIntegration.html).
The kit's tests measure the behavior they exercise; those sources do not
establish a measured quality improvement for this kit.
