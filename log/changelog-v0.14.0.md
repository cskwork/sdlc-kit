# v0.14.0 — a leaner contract, test-first bug fixes, generic intake

Real stores showed where the kit's words went. The agent-facing prose had
grown to about 128 KB. `AGENTS.md` restated what the scripts already enforce,
each stage skill repeated the heartbeat and memory paragraphs, and bug fixes
could "prove" themselves with reproduction steps that nothing re-runs. The
kit is used for any software (web, API, batch, CLI), but stage 6 intake still
asked only UI questions. This release cuts the duplication and makes the bug
proof durable. Gates, scripts, the `--json` schema, and lazymode are
unchanged; `init.sh` gains three optional config lines.

## Changes

- **`AGENTS.md` keeps what an agent must decide** (453 → 324 lines, −31%).
  Mechanics a script enforces and prints a reason for (digest binding,
  ship-snapshot rules, C-quoted paths, handoff refusals, store ownership) are
  now one line each. Text that `docs/automation.md` already holds (full-auto
  intent contract §3, verify receipt §4) is now a pointer. Rule numbers and
  section names are unchanged. The stale "rule 3a" citations in
  `gates/_auto.sh` and `gates/status.sh` now resolve: 3a labels the full-auto
  intent contract.
- **Defined once.** Heartbeat (rule 9, now listing the stage names and
  build's n/m) and memory reading (rule 4) are no longer repeated in six stage
  skills; each skill carries a one-line pointer. The harvest/close-writer
  rule, the `kb.sh` digest description, and tripwire caveats are referenced,
  not restated. `SKILL.md` drops its Coexistence and Invariants summaries,
  which repeated `AGENTS.md`. `roles/researcher.md` points at `probes.md`
  instead of copying three probes.
- **Bug fixes start with a failing test** (AGENTS.md rule 6). By default the
  reproduction is an automated test at the lowest level that reaches the
  defect. It fails on the pre-fix code for the reported reason, passes after,
  and stays in the suite. Manual steps or logs stand in only when no test can
  reach the defect, and the evidence says why. Stage 6 drafts the test outside
  the source tree, build adds it before the fix, and the verifier runs it
  against the pre-fix commit and must see it fail. `templates/evidence.md`
  gains a `Regression test:` line, and the plan's Proof and the compact
  route's Proof line name it.
- **Generic stage 6 intake.** The five questions now fit a UI, an API, a job,
  or a CLI: what was done with what input, what happened versus what was
  expected, where and when, as whom, and what trace exists (request or trace
  id, log line, affected record keys). A symptom class (nothing happened /
  wrong result / looks wrong / intermittent) replaces the UI-only
  "does not react vs looks disabled" split. Probe 2 is no longer a MyBatis
  `awk` over `mapper.xml`: it diffs the filters of every query on one entity
  (SQL, ORM, API params, cache keys).
- **Projects name their own helpers.** New optional `researcher:`,
  `verifier:`, `adversary:` keys in `.sdlc/config.md`: the named agent or
  skill is dispatched with the kit's role file as its contract ("Running
  beside…" rule 3). Empty or absent means the old behavior. Existing configs
  are not rewritten.

Agent-facing prose (SKILL.md, AGENTS.md, stage skills, roles): 104,136 →
~89,700 bytes.

## Validation

- `bash gates/knowledge-test.sh` → `KNOWLEDGE-TEST PASS`, 144
- `bash gates/selftest.sh` → `SELFTEST PASS`
- `bash gates/e2e.sh` → `E2E PASS`, 152 · `bash gates/autotest.sh` → `AUTOTEST PASS`, 195
- Three fresh-context verifier lenses over the diff: E2E (init.sh in a
  disposable repo, plus a backend-bug compact walk and a UI full-route walk),
  Side effects (removed instructions and cross-references), and Intent match
  (against the approved recommendation). Their minor findings in the changed
  text were fixed before release.
