# v0.11.0 — three-lens verification, bound origin, machine-readable fix loop

The build stage's verification grows from one E2E pass into three lenses that
run in parallel, each in a fresh context, under the one existing role
contract; the request's origin becomes a bound artifact; the fix-loop cap and
data-consistency checks become machine-readable. The gates and the source
binding are unchanged in kind.

## Changes

- **Three verification lenses.** `roles/verifier.md` is now the single definition of what verification checks, dispatched one lens each: **E2E** (the change through the real interface; the bug-fix proof chain; the `verify.sh` receipt), **Side effects** (baseline and untouched items, neighbouring flows, and data consistency — every shape the diff writes or reads followed to its other producers and consumers), and **Intent match** (the build read back, per intent.md O-item, against the origin of the request, listing what is covered, missing, and beyond; a detail dropped between the origin and an approved spec.md is a finding). The verifier now receives intent.md and its origin on the full route too — before, it saw only plan.md and spec.md, so the human's actual ask was never read back.
- **`origin.md` — the ticket / 기획서 as requested, bound by the gates** (templates/origin.md). Stage 1 snapshots the origin BEFORE the intent gate; `approve.sh intent` binds its digest exactly like a spec or plan upstream (`upstream_origin:`), and every downstream gate, `status.sh`, `check-gate.sh`, `tools/auto.sh` and `close.sh` report a rewrite in the same words (`origin.md changed after … — re-approve intent, then <stage>`). An origin written after the approval reads as unbound and closes the gate, exactly like a late spec.md. `origin` is never a gate of its own: `approve.sh origin` is refused. Absent when the request had no origin beyond the chat — nothing is demanded then. It is part of the durable record (AGENTS.md rule 7, init.sh, README trees). One artifact map now serves every script (`_common.sh` `sdlc_artifact_of`); `status.sh` and `_auto.sh` dropped their private copies.
- **O-numbered success criteria.** intent.md's Success criteria are `O1..On` in the origin's words (else the human's); spec R-items cite them (`R1: … (O1)`); an O-item with no R is a flagged concern, never a silent drop. The adversary's traceability check and the verifier's Intent match lens count coverage over them instead of rediscovering it.
- **Data touched in plan.md.** The plan names every shape the changed files write or read, with its other producers and consumers and what happens to pre-existing records. The plan adversary checks the list is complete; the Side effects lens executes it and treats a missed shape as a finding.
- **Fix loop, any lens, machine-readable cap.** `skills/4-build` routes a finding from ANY lens into the fix loop. A round is one deviations.md line — lens, accepted, declined, `re-check: pending | resolved | open: <what>` updated in place. The cap stays at three rounds. `gates/_auto.sh` `sdlc_auto_fixloop_state` reads those lines: round 3 still `open`, or any round past 3, is `fixloop.exhausted` — `tools/auto.sh next` exits 10 (needs-human) at every lazymode, both while build is open and once evidence.md exists over it (the lazy ship gate is refused), `status --json` carries `"fix_loop"`, and `status.sh` prints `FIX LOOP EXHAUSTED` and overrides its next action, exactly like an open material question. A finding that implies new scope is a human decision, not a fix.
- **`data` check kind** in `.sdlc/verify.md` (templates/verify.md, docs/automation.md): a read-only consistency query for the Side effects lens, receipted like every other check and never counted as runtime evidence.
- `templates/evidence.md` carries the three reports under one **Verification** section (E2E · Side effects · Intent match · Fix loop) and names the origin and its live re-read; the old End-to-end and Regression sections fold into it.
- DRY: the real-E2E prose that was repeated in AGENTS.md rule 6, `skills/4-build`, `skills/5-ship` and `roles/verifier.md` now lives in the role file; rule 6 states the contract in one paragraph and the stage skills reference it.

## Upgrade notes

- Nothing is required. Existing approvals keep working: a feature without origin.md binds nothing new, and existing evidence.md files stay valid — no script parses their section names.
- Existing `deviations.md` round lines without a `re-check:` field read as `open` (in progress) and never as exhausted; only a round past 3, or a round 3 marked `open`, blocks.
- Snapshot the ticket or 기획서 as `origin.md` BEFORE `approve.sh intent`; written afterwards it closes the gate as unbound until intent is re-approved — that is the binding working.
- `status --json` gained `fix_loop`; drivers that ignore unknown fields are unaffected.

## Validation

Local, on macOS (Bash 3.2) — darwin 25.6.0, arm64:

- `bash gates/selftest.sh` → `SELFTEST PASS` (new: origin.md bound by intent and downstream gates, refused as a gate, unbound when written late).
- `bash gates/e2e.sh` → `E2E PASS`, 146 assertions, 0 failures (new: B2b, B10i–B10k, B12b — the full route snapshots, binds, refuses a post-review origin edit, archives origin.md).
- `bash gates/autotest.sh` → `AUTOTEST PASS`, 195 assertions, 0 failures (new: A24a–h fix-loop states through `next`, `status.sh`, `status --json` and the lazy ship gate; A25a–d the `data` kind runs, is receipted, is not runtime evidence, and fails the run when it fails).
- `bash -n` over every changed shell script: clean.
