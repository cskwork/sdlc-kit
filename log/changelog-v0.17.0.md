# v0.17.0 — verification that gates ship: baseline, coverage, per-feature recipes

Until now only the host driver enforced the verification receipt. A human
could approve ship and close `shipped` over a failed, stale or missing
receipt, even under `profile: strict`; a failure the base already had read
like a regression; nothing proved a new test could fail; a recipe that skipped
a requirement still said `VERIFY ok`; and two open features collided in the
one project recipe. This release closes those holes. A project without
`.sdlc/verify.md` behaves as before. The reference is docs/automation.md §4;
the recipe syntax is templates/verify.md.

## Changes

- **The receipt gates ship.** `approve.sh ship` (every mode), `close.sh
  shipped` and `check-gate.sh ship` read one verdict table
  (`gates/_auto.sh sdlc_verify_gate`), shared with `auto.sh`, `handoff.sh` and
  `status.sh`. `ok` passes; `unconfigured` passes with a note; `blocked` needs
  `--accept-gap "<the human's words>"` (never `--lazy`); every other state is
  refused with its fix. Accepted words are recorded in the ship approval and,
  on a `shipped` close, in `CLOSED`.
- **No git repository** is now `blocked`: the receipt binds no source.
- **Baseline.** New `tools/verify.sh baseline <slug> [--base <ref>]` runs the
  project recipe's build/unit/lint checks at the base commit in a disposable
  worktree and writes `verify-baseline.md`. `run` labels a failure the base
  shared, with the same exit status, `pre-existing`. New `baseline_setup:`.
- **Must fail on base.** A check may end in `| must-fail-on-base`; with the
  new `test_paths:`, the baseline runs the new test against the old code.
  Passing there, or not running (124/126/127), is the new state `vacuous`.
- **Coverage.** Every requirement id (spec.md R, compact intent.md O) needs a
  check named for it or a `gap: <id> | <reason>` line, else the new state
  `uncovered`. Strict needs a runtime/e2e check and the `happy`, `boundary`
  and `negative` variants. New `tools/verify.sh coverage <slug>`.
- **Per-feature recipe.** Optional `.sdlc/work/<slug>/verify.md`
  (templates/verify-feature.md), `check:`/`gap:` lines only; the receipt binds
  its digest.
- **Flaky.** A failing runtime/e2e check runs once more; passing then is the
  new state `flaky`, refused like `fail`.
- **Lens verdicts.** Ship needs a `VERDICT:` line under each verifier lens in
  evidence.md, or AGENTS.md rule 5's gap line.
- **Safety.** `forbidden_hosts:` refuses a recipe that names a listed host.
  `tools/_run.py` redacts credentials in every log before it is hashed
  (best-effort).
- **Parsing.** A UTF-8 BOM no longer hides `profile: strict`; value lines take
  a trailing ` # comment`; an indented or tabbed directive is refused, not
  skipped; `doctor_attempt_timeout` is validated.
- `auto.sh --json`: new blockers `verify.uncovered` / `verify.vacuous`;
  `flaky` is `verify.fail`; a verification that fails after the ship approval
  blocks the delivery stage.
- `verify.sh` resolves a pyenv/asdf python shim once per run.
- `approve.sh ship` writes the source snapshot before the record.
- `kb.sh` never reads `verify-baseline.md`.

## Agent guidance

- **roles/verifier.md:** baseline, run and coverage with a recipe;
  pre-existing vs regression; every changed file traced; the scenario floor
  (happy, boundary, negative, + regression, + authz) with expectations first,
  per role and platform, source rung stated; writes read back; new tests
  must fail on base; red flags.
- **roles/adversary.md:** seven blocking clean-code findings and a per-file
  table.
- **skills/4-build, 5-ship, AGENTS.md rule 6, templates:** the checks are
  written with the code; ship needs `ok` or the human's `--accept-gap`;
  evidence.md carries variants, the receipt line and each lens `VERDICT:`.

## Compatibility

- No recipe: no change beyond one note line.
- With a recipe: a ship approval or `shipped` close over a non-`ok` receipt
  is now refused. A recipe with no git repository needs `--accept-gap`.
- Old recipes may read `uncovered` until checks are named for requirements
  (`R1`, `R1.happy`) or gap lines are added; strict recipes also need the
  variants.
- evidence.md needs the lens `VERDICT:` lines, recipe or not.
- Old receipts stay valid; the schema stays `sdlc-kit/verify-receipt@1`.

## Validation

- `bash gates/selftest.sh` → `SELFTEST PASS`. New sections cover the
  ship gate, `--accept-gap`, baseline and pre-existing, must-fail and
  vacuous, coverage and the strict variants, per-feature recipes, flaky,
  forbidden hosts, redaction, the parser rules, worktree cleanup, no-git,
  and a receipt going stale when the source changes (a gap before v0.17.0).
- Faster: the selftest runs its independent sections in parallel (~31 s →
  ~9 s), and `sdlc_sha256_stdin` (prefers `sha256sum`) and `sdlc_field`
  (no awk per field) roughly halve the processes `verify.sh run`/`check`
  start.
- `bash -n` on every changed script; no CRLF.
- By hand: `auto.sh --json` blockers, `--base` handling, TERM/HUP during a
  baseline, and the worktree-removal fallback.
