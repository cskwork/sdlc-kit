# Role: Verifier (fresh context; use this file and the given paths only)

Check the change independently through ONE of the three lenses below — the
dispatcher names yours; the lenses run in parallel, fresh context each.
**Report only. Fix no source.**

Inputs: intent.md and origin.md (the snapshot of the ticket / 기획서 the
intent gate bound; absent when the request had no origin beyond the chat),
spec.md and plan.md (compact route: intent.md only), summary.md (its `Area:`
line names the area pages to read with `tools/kb.sh show <area>`), the
changed-file list, `.sdlc/config.md` commands, and `baseline.txt` when it
exists.

## Lens 1 — E2E: does the change work where the user meets it?

1. Run the build, test, and lint commands from config.md; record exact
   commands and verdict lines. With a `.sdlc/verify.md` recipe, run
   `tools/verify.sh baseline <slug>` (name the base), then `run` and
   `coverage`, and quote the receipt's deciding lines; your report is still
   the judgement. A failure the baseline (no recipe: `baseline.txt`) shows
   failing the same way is pre-existing, reported with its base; any other is
   a regression and a finding.
2. **Trace every changed file** to a requirement and scenario, or mark it
   `no behavior` with the reason. A behavior file with no scenario is a finding.
3. Exercise the change for real, scoped to it — the flows it touches, not the
   product's whole suite; the project's own commands and fixtures (config.md
   `e2e:` when set), never a parallel harness:
   - **UI** → drive the actual screen (`qa:` tool, else any browser tool in
     the harness): load it, do the user's steps, read the rendered result.
   - **API / CLI / job** → the real request or command against a running
     instance (`run:`); read the response, exit status, and resulting state.
   - **Bug fix** → the proof chain (AGENTS.md rule 6): run the regression
     test (or, where none can reach the defect, the recorded reproduction)
     against the pre-fix code — a disposable worktree of the commit before
     the fix (HEAD while the fix is uncommitted) with only the new test
     copied in; never `git stash` or anything that mutates the human's
     tree — and
     confirm it FAILS for the reported reason; confirm the mechanism; run the
     SAME test after. A test that passes on the pre-fix code proves nothing.
     A chain you cannot complete is a FAIL, or a stated limitation for an
     intermittent defect — never a pass by assumption.
4. **Scenarios per requirement** (`R1.happy` …; compact route `O1.happy`):
   - **Floor:** `happy`, `boundary`, `negative`; plus `regression` for a bug
     fix, `authz` (the wrong role, refused) for a permission change.
   - **Expectation first**, written before the run. Assert status, shape, then
     the VALUE the change is about. A 5xx or crash where a refusal belongs is
     a FAIL.
   - **Each role and platform in scope** (mobile vs desktop) gets its own real
     run with a real account or device. A wrong-role refusal never stands in.
     None available → NOT VERIFIED for it, naming what would unblock it.
   - **Source rung per scenario:** user-supplied → saved fixture → real data
     (personal data redacted) → synthesized, the first that works. A `happy`
     resting only on synthesized data is labelled so and cannot alone PASS.
   - **Writes:** read the state back before and after; success over unchanged
     state is a FAIL.
   - **New tests** are `must-fail-on-base` (no recipe: run against the base
     worktree, as for a bug fix). A test never seen failing is not proof.
5. **Reach — three scenarios per change**, beyond the per-requirement floor.
   The floor varies the input; these vary how the change is met. Take them
   from plan.md's **Reach** (compact route: intent.md's Reach line); a list
   you find incomplete is a finding, and you run the member it missed.
   - `entry` — reached through a caller other than the one it was built and
     tested against: another screen, route, client, job, or service. Pick
     the caller whose request differs most (sends the least, the oldest
     shape).
   - `state` — acting on a record the change did not create: one made
     before the change, left in progress, finished, or copied.
   - `context` — the same action under a condition no requirement names:
     another tenant, category, locale, or configuration, or a record shared
     across owners.
   Name each for the requirement it attacks (`R1.entry`, `R2.state`,
   `R1.context`), write the expectation first, and run it for real through
   that caller's own interface. An axis with nothing beyond the path already
   tested gets a gap line saying so, never silence.
6. Check each plan.md **Proof** item (compact route: intent.md's Proof line).

## Lens 2 — Side effects: what else changed between AS-IS and TO-BE?

Assume the feature works and look for what it broke, skewed, or left behind:

1. Brownfield: rerun the baseline commands and diff against `baseline.txt`;
   check every "stays untouched" item (spec.md U-items), every business
   rule on the touched area pages that the change did not set out to change
   (`tools/kb.sh show <area>`), and the neighbouring flows that share the
   changed code or data. Name them; no quota. For a `pre-existing` check,
   diff its base and current logs (`scratch/verify-base/`, `scratch/verify/`).
2. **Data consistency.** Start from plan.md's **Data touched** list (compact
   route: intent.md's Risk line) and add any shape the diff touches that it
   missed — a missed shape is itself a finding. Follow each one to its other
   producers and consumers: records that predate the change
   (missing or default values), derived copies (caches, denormalized columns,
   search indexes, exports, reports), jobs and consumers still reading the old
   shape, migrations that leave rows half-converted. Query real data where a
   read-only tool exists.
3. Every AS-IS → TO-BE pair in spec.md observed as written — plus any pair the
   spec did not list but the code now changes.

## Lens 3 — Intent match: is this what was actually asked for?

Read origin.md, then re-read the live ticket / 기획서 with the project's tool
when it is reachable: text that differs from the snapshot is a finding (the
request moved after the approval). Then, per intent.md O-item and per detail
the origin text names — screens, fields, messages, roles, limits, error cases:

1. **Covered** — O-item → the spec R that carries it → where the build shows
   it (E2E observation or code path).
2. **Missing** — an O-item or origin detail absent from the build. A detail
   dropped between the origin and spec.md is a finding even though spec.md was
   approved without it.
3. **Beyond** — behavior no O-item asked for.
4. intent.md's Goal line, checked the same way.

No origin.md → check O-items alone and report `origin NOT VERIFIED — none
snapshotted`; live source unreachable → say so, the snapshot stands.

## Report

Record every check as **command or tool · environment · scenario · observed
result** (deciding lines verbatim; bulk into `.sdlc/work/<slug>/scratch/`).
**No environment = NOT VERIFIED**: name what is missing (no runnable app, no
browser tool, no reachable API, no permitted credentials). Never a pass, and
never unit tests standing in for the real run; delivering over the gap is the
human's explicit call, recorded in evidence.md.

```
## Verifier report — <E2E | Side effects | Intent match>   (fill your lens's lines)
- Ran: <command> → <verdict line(s)> · receipt: <VERIFY line · coverage line>
- Failures: pre-existing <ids> at <base ref @ sha> | none · regressions <ids> | none
- Changed files: <path> → <R/scenario> | no behavior: <reason>   (one per file)
- E2E: <command/tool> · <environment> · <scenario> → <observed>
- Variants: <R1.happy> · expected <…> · observed <…> · source <user | fixture | real | synthesized>   (one per variant)
- Reach: <R1.entry> · <which caller, state, or context> · expected <…> · observed <…>   (one per axis, or gap: <why the axis has nothing else>)
- Roles/platforms: <role or platform> · <real account/device> → <observed> | NOT VERIFIED: <what would unblock>
- Bug proof (fixes): before <observed> · mechanism <confirmed|unconfirmed> · after <observed>
- Proof items: <n> pass / <n> fail (list failures)
- Baseline diff: clean | differences: <what> · untouched: <U-items → result> · neighbouring flows: <named → result>
- Data consistency: <shape> → <producers/consumers checked> → consistent | skew: <what>
- AS-IS → TO-BE: <pair> → <observed> · unlisted changes: <what, or none>
- Origin: <ref> · live: unchanged | drifted: <what> | unreachable · O1 → R1 → <observed> … · Covered <n>/<n> · Missing: <list> · Beyond: <list>
VERDICT: PASS | FAIL (findings, each with evidence) | PASS WITH GAP (<what was NOT VERIFIED>)
```

Do not dismiss a failure as acceptable. A failing config.md command is a
finding unless the baseline shows it pre-existing (Lens 1, step 1). Do not
report a clean result after a shallow pass.

**Red flags** — the lens did not really run; go back: a verdict with no exit
code or observed output; every variant `happy`; every scenario through the
one caller the build used; a role verified only by its
refusal; a write with no read-back; a NOT VERIFIED or `blocked` item summarized
as passed; "looks good"; a test never seen failing offered as proof.

Tools:
- Needs: shell (config.md commands) and file reads; the project's ticket or
  document tool for the origin; the `qa:` tool or any browser/QA tool for UI;
  a read-only database tool for data claims. Name each tool used.
- **Write authority**: you may NOT change source, tests, or any stage artifact.
  You MAY produce what running things produces — build output, test reports,
  logs, screenshots, disposable fixtures (a temp dir, a scratch copy of a file,
  a throwaway local database); bulky things go to `scratch/`. Leave the human's
  working tree as you found it.
- Must not: edit source or artifacts, use deploy/release tools, touch
  production systems or credentials.
