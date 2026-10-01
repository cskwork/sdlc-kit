# Jev QA mode

The verifier's UI checks can run through
[Jego](https://github.com/cskwork/ego-jev-ultrafast) (Jev on Ego Lite)
instead of the agent driving a browser itself. Each UI scenario becomes a
plain-language goal; Jego does it in the user's real browser; a runner checks
the result independently and writes one HTML report with screenshots, time,
and cost. The report is what a human reads at the ship gate.

The default stays `agent`. Nothing changes until someone switches.

## Switching

```bash
tools/qa-mode.sh                      # which mode, and where it comes from
tools/qa-mode.sh set jev --jev-dir ~/code/ego-jev-ultrafast   # every project, remembered
tools/qa-mode.sh set agent            # back to the default, every project
tools/qa-mode.sh set jev --project    # only this project (beats the user default)
tools/qa-mode.sh check                # can jev mode run here?
```

`set` saves to `${XDG_CONFIG_HOME:-~/.config}/sdlc-kit/config`, so the choice
holds across projects and sessions until it is switched back. A project's own
`qa_mode:` in `.sdlc/config.md` wins over it. When the human says "use jev for
QA" / "jev로 QA" / "switch QA back to agent", run the matching `set` and say
where it was saved.

## What the verifier does in jev mode (E2E lens, UI scenarios)

1. `tools/qa-mode.sh check`. Not ready → agent mode for this run, and the
   report says which check failed. Never a silent switch.
2. Write `.sdlc/work/<slug>/scratch/jev-qa/scenarios.mjs` (working residue,
   never a stage artifact) from the plan's scenarios (`R1.happy` …, reach
   scenarios included). One entry per scenario:
   - `id` = the scenario name, `title` = what the user does, `role` when roles
     are in scope;
   - `goal`: the user's steps in plain words, naming the exact buttons and what
     NOT to press (delete, deploy, other accounts). Vague goals are the main
     cause of wrong clicks;
   - `expect`: the texts that prove the expectation you wrote first — the value
     the change is about, not just the page title;
   - `accept: ["done", "blocked"]` and `expectUrl` only for a step that hands
     off to another domain on purpose (SSO entry); `verifyUrl` for the page to
     re-open; `mutation: true` for scenarios that write data.
3. Run from the project root:
   `node <jev_dir>/qa/run.mjs .sdlc/work/<slug>/scratch/jev-qa/scenarios.mjs --out .sdlc/work/<slug>/scratch/jev-qa`
4. Read every failing scenario's steps and final screenshot before judging. A
   failure caused by the goal wording is fixed in the wording and rerun
   (`--only <id>`); a failure the product causes is a finding. For a write,
   read the state back as the floor requires (re-open the record, or a second
   scenario as the other role).
5. Add your judgement in `.sdlc/work/<slug>/scratch/jev-qa/notes.json` (per-scenario
   `verdict`/`summary`, `_findings`, `_env` with accounts used and data
   changed), then build the report:
   `node <jev_dir>/qa/report.mjs .sdlc/work/<slug>/scratch/jev-qa --open`
6. In the verifier report, the E2E line names the tool and the report:
   `E2E: jev qa/run.mjs · <environment> · <n> scenarios → <passed>/<n>; report: .sdlc/work/<slug>/scratch/jev-qa/report.html`.
   Quote the deciding lines (the `verify:` line of each failing or written
   scenario) beside it; a bare scratch path is not evidence (AGENTS.md).

## Rules that do not change

- The agent's DONE is never a pass. A scenario passes on `expect` texts, the
  final URL, and the independent re-open; a popup or viewer that cannot be
  re-opened passes only on its final screenshot, reviewed and noted.
- Jego cannot drive file uploads, canvas, iframes, or shadow DOM. Those
  scenarios run the agent way and are labelled so in the report.
- Jego sends page text to its decision API (TypeSafe) and, for text fields, to
  the configured text helper. Pages with personal data need the human's say-so
  first (AGENTS.md authority rules apply unchanged).
- Writes happen on test accounts only, and `_env` lists what to clean up.
