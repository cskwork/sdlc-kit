# The automation layer (v0.10.0)

The loop has always been drivable by hand. This layer makes it drivable by a
host — a scheduler, a ticket webhook, a multi-agent runtime such as Symphony —
without anyone parsing prose, and without loosening a single gate.

Four scripts, no daemon, no database. One optional dependency: **python3**, used
by `tools/verify.sh` (only) to bound a command by wall clock, give it its own
process group, and take that whole group down again — a POSIX shell cannot do
those three portably, and stock macOS ships no `timeout(1)`. The gates,
`tools/auto.sh` and `tools/handoff.sh` are shell + git only. Without python3,
`tools/verify.sh run` refuses with that reason and the loop keeps working: the
gates never required a receipt. CI runs all three suites on ubuntu/macos/windows
runners, which all ship python3.

| command | what it does |
|---|---|
| `tools/auto.sh status [--json] [slug]` | the machine view of every open feature: stage, status, next action, blockers, source identity |
| `tools/auto.sh next <slug>` | one line plus an exit code, for a driver |
| `tools/auto.sh intent-check <slug>` | the full-auto intent contract |
| `tools/auto.sh checkpoint <slug> …` | pending execution metadata: step, bounded attempts, completed external effects |
| `tools/verify.sh run\|check\|doctor\|show <slug>` | executes the project's verification recipe and records a receipt bound to the source |
| `tools/handoff.sh check\|push <slug>` | the review handoff: a feature branch a human can review, proven to be there |

`gates/status.sh --json` is the same output through the cockpit everyone
already knows; both go through `gates/_auto.sh`, which takes every gate verdict
from `gates/_common.sh` — the functions `check-gate.sh` and `close.sh` use. The
machine view can never be more permissive than the gates themselves.

**What these scripts are not.** None of them reasons, writes an artifact, or
performs a stage. `status: ready` means *the next action is one this project's
lazymode lets an agent take* — an LLM, under the stage skills, still takes it.
A shell script cannot review code, and this kit never claims one did.

## 1. The machine status contract

`tools/auto.sh status --json` prints `sdlc-kit/auto-status@1`:

```json
{
  "schema": "sdlc-kit/auto-status@1",
  "kit_version": "v0.10.0",
  "generated_at": "2026-09-17T09:12:44Z",
  "project_root": "/repo",
  "lazymode": 4,
  "source_digest": "c13948dd…",
  "git_head": "a9eb48da…",
  "features": [
    {
      "slug": "a20-1234-fix-login",
      "track": "compact",
      "stage": "build",
      "status": "ready",
      "exit_condition": "open",
      "next_action": { "kind": "verify", "command": "tools/verify.sh run a20-1234-fix-login", "text": "…" },
      "blockers": [ { "code": "verify.fail", "detail": "…" } ],
      "gaps":     [ { "code": "verify.unconfigured", "detail": "…" } ],
      "intent_contract": { "state": "ok", "detail": "…" },
      "fix_loop":        { "state": "none", "detail": "…" },
      "verification":    { "state": "ok", "profile": "strict", "detail": "…", "receipt": "…" },
      "source":   { "state": "ok", "reviewed_digest": "…", "current_digest": "…" },
      "delivery": { "state": "ok", "target": "pr", "detail": "…" },
      "handoff":  { "target": "review-ready", "remote": "origin", "branch": "…",
                    "remote_sha": "", "remote_verdict": "not-checked" },
      "checkpoint": { "state": "fresh", "step": "ship.push", "detail": "…" },
      "heartbeat":  { "line": "build 2/3 · …", "age_seconds": 41 }
    }
  ]
}
```

- `status` — `ready` · `needs-human` · `blocked` · `complete`.
- `stage` — `map` · `intent` · `spec` · `plan` · `build` · `ship` · `delivery` · `closed`.
- `exit_condition` — `open` · `review-ready` · `merged` · `deployed` · `local` · `closed`.
- `blockers` stop progress; `gaps` are honest holes that do not (a project with
  no verification recipe, for instance).
- `remote_verdict` — `match` · `mismatch` · `absent` · `not-checked`. A
  delivery that CLAIMS a remote branch (`Handoff: review-ready|merged|deployed`)
  is checked against the remote **by default**: a handoff nobody can see is not
  a handoff. `--no-remote-check` makes the run touch no network; it then reports
  `not-checked`, keeps `exit_condition: open`, and points at
  `tools/handoff.sh check` instead of ever calling the feature review-ready or
  suggesting `close.sh … shipped`. (`--remote-check` is still accepted, as a
  no-op, for drivers written against the first draft.)
- `unusable_feature_dirs` — directory names under `.sdlc/work/` that are not
  usable slugs (`[a-zA-Z0-9._-]+`). They are reported, never evaluated and never
  split into features that do not exist.
- `status` lists OPEN features only, exactly like `gates/status.sh`. A closed
  feature is answered by `tools/auto.sh next <slug>` (`complete`, exit 30).

`tools/auto.sh next <slug>` prints
`<status> <stage> <exit_condition> :: <command or text>` plus one `blocker:`
line each, and exits **0 ready · 10 needs-human · 20 blocked · 30 complete ·
1 usage/environment**. That exit code is the whole integration surface a host
needs.

## 2. The drive / resume procedure

This is a documented procedure for an agent, not a script that runs the loop:

1. The host wakes an agent for a ticket (Symphony dispatch, cron, webhook).
2. The agent runs `tools/auto.sh next <slug>` from the project root.
3. **ready** → it performs that one stage action under the stage skill
   (`skills/1-intent` … `skills/5-ship`), records the artifact or the approval,
   updates `progress.md`, and loops back to step 2.
4. **needs-human** → it posts the blocker and the decision that is owed, and
   stops. The host may sleep the ticket until a human answers.
5. **blocked** → it repairs what the blocker names (re-run the verification,
   re-approve a stale gate, fix a failing check) within the retry budget, or
   escalates. It never edits the gate machinery to get past a blocker.
6. **complete** → the feature is closed; the host may release the ticket.

Resuming after a crash, a context reset, or a new session is the same loop:
step 2 reads state from the artifacts on disk, which are the authority. The
checkpoint adds only what the artifacts cannot know — how many attempts a step
has had, and which external effects already happened.

## 3. The full-auto intent contract

An unattended run may act on an `intent.md` only when it carries:

- an actionable **Goal** (one plain sentence, what the caller can do afterwards),
- a **Scope authorization** line: the scope the human already authorized, in
  their words — this is *authority*, separate from any stage approval,
- at least one **Success criteria** checkbox (machine-checkable where possible),
- at least one **Out of scope / must not change** bullet (the non-goals),
- at least one labelled **Evidence** claim (`[verified: …]` / `[assumed: …]`),
- a **Material questions** section — present, and empty of unresolved lines.

`tools/auto.sh intent-check <slug>` reports `ok` (0), `material` (10), or
`incomplete` / `absent` (20).

**Material vs optional.** A question is MATERIAL when a wrong answer would
change what gets built, break something, or exceed the authorized scope. It
goes to the human: an unattended run never guesses one away to make progress.

Inside `## Material questions`, **content blocks — markers do not matter**. A
nested bullet, a `*` bullet, a numbered item and a bare sentence all count the
same. Two things, and only these two, stop a line from blocking:

- the **canonical resolution marker**, with the answer and its source, written in
  place so the trail survives:
  `- <question> — resolved: <the answer and where it came from>`
  (` - resolved:` and a leading `resolved:` / `[resolved …]` read the same once
  Markdown markers are peeled). The marker is **anchored**, not searched for: it
  must open the line or follow that separator, so a line that merely contains the
  word never clears a question — `unresolved:`, `not resolved: pending`,
  `non-resolved:` and `to be resolved with the PM` all keep blocking.
- a single `none` (or `n/a`) line declaring the section empty. An empty section
  does the same.

Lines still holding the template's `<placeholder>` read as `incomplete`, not as
"no questions". `gates/status.sh` prints the same verdict as
`tools/auto.sh`, and at lazymode 4 it overrides its own next action with it: the
prose cockpit is the screen an agent actually reads, and it may not offer the
lazy intent gate over a question a human owes an answer to.
Optional uncertainty is decided from evidence during the work, or carried as a
labelled `[assumed: why]` — it belongs under `## Open questions` and blocks
nothing. Known facts from the ticket, the code and DOMAIN.md come first;
questions are what remains after the evidence.

Lazymode is unchanged by all of this. Lazymode answers *who decides*;
authorization answers *may this be done at all*. A red flag outside the
authorized scope stops the loop at every level, including 4.

## 4. The verification contract

`.sdlc/verify.md` (seed from `templates/verify.md`) maps each requirement to the
project's own command and names the launch / doctor / cleanup commands around
them:

```
profile: strict
launch: npm run start:test
doctor: curl -fsS http://localhost:3000/health
doctor_timeout: 60
cleanup: docker compose -f compose.test.yml down -v
environment: local instance, seeded fixture data
check: build | build | npm run build
check: R1    | unit  | npm test -- login
check: R2    | e2e   | npx playwright test --grep @login
check: D1    | data  | psql -Atc "select count(*) from sessions where token_v2 is null" | grep -qx 0
```

`data` is a read-only consistency query (the Side effects lens of
`roles/verifier.md`): it is receipted like every other check and never counts
as runtime evidence.

`tools/verify.sh run <slug>` refuses an unfilled or malformed recipe outright,
deletes any previous receipt, launches the runtime in its own process group,
waits for the doctor, runs **every** configured check (stdin on `/dev/null`, one
own process group each, bounded by `check_timeout`), stops the whole launched
group, runs cleanup, re-hashes the source, and records
`.sdlc/work/<slug>/verify-receipt.md`:

```
receipt_schema: sdlc-kit/verify-receipt@1
source_digest_before: <the whole source snapshot before the checks>
source_digest_after:  <and after — they must be equal>
recipe_digest: <sha256 of .sdlc/verify.md>
launch: started (pgid 4711) | failed | skipped (--no-launch) | none
runtime_instance: owned | external | none
doctor: pass | fail (after 60s) | unowned-runtime | skip
cleanup: ok | failed | none
checks_configured: 5
checks_run: 5
runtime_evidence: yes | no
result: pass | fail | inconclusive
check: R2 | e2e | 0 | <command sha256> | <output sha256> | <log path>
```

Consequences, all of them deliberate:

- **Every configured check runs.** A check that reads stdin (`ssh host cmd`,
  `docker compose run` without `-T`, `mvn`, an interactive CLI) used to swallow
  the rest of the recipe; the receipt now states how many checks were configured
  and how many ran, and a mismatch reads `invalid`.
- **The run is bounded.** Each check, each doctor attempt and the cleanup have a
  wall-clock limit (`check_timeout`, `doctor_attempt_timeout`,
  `cleanup_timeout`). A hung project command is killed — process group included
  — instead of stopping an unattended driver for good.
- **The runtime is owned or it is not evidence.** `launch:` starts in its own
  process group and the whole group is stopped afterwards, children included. If
  the doctor answers while the launched process is already dead, something else
  is serving that endpoint: the receipt records `doctor: unowned-runtime` and
  the state is `blocked`. `--no-launch` labels the instance `external` and, under
  `profile: strict`, blocks — nothing proves an instance this run did not start
  is running this source. `strict` + `launch:` also requires a passing `doctor:`
  (make it assert the build or version, not just a listening port).
- **A cleanup that fails is loud.** `cleanup: failed` blocks instead of leaving a
  leftover runtime to make the next result meaningless.
- **An interruption stops the check that is running.** INT/TERM take down this
  run's current child and that child's process group, run the cleanup, and exit
  non-zero with no receipt; no further check starts. Nothing the run did not
  launch is signalled. (Windows/Git Bash: the same path, through
  `tools/_run.py` and `taskkill /T`, plus a job object that takes the running
  check down even when MSYS `kill` terminates the helper outright. If that job
  object cannot be created, `tools/_run.py` prints a `process tree NOT bound`
  line naming the Win32 call that refused — on stderr and in the check's log —
  instead of claiming a containment it does not have; the run still exits
  non-zero with no receipt, but the interrupted command may survive it.)
- **A source change during the run is `inconclusive`, not a pass.** A check that
  writes into the tree (coverage output, a generated fixture) makes the result
  belong to no single snapshot. Saying so beats returning 0 and then reporting
  `stale` forever, which livelocked the driver.
- Change the code, the commands, or the recipe and `tools/verify.sh check`
  answers `stale`. Old results never carry over to new code.
- `profile: strict` refuses review-ready without a passing `runtime` or `e2e`
  check: local unit and build results never stand in for the real run
  (AGENTS.md rule 6). A doctor that never succeeds is `blocked`, i.e. NOT
  VERIFIED — never a downgrade to "the unit suite is green".
- A project with no `.sdlc/verify.md` keeps working exactly as in v0.9.0; the
  machine view reports `verify.unconfigured` as a **gap**, so the hole is
  visible rather than silently filled.

**What a receipt is worth.** It is CHANGE DETECTION, and that is all. Each state
is re-derived on every read: the cited logs must exist and still hash to the
recorded digests, each command digest must match the recipe's command, every
configured check must be accounted for, and the source and recipe digests must
still match the working tree. That makes "these commands never ran", "this log
was edited afterwards" and "this receipt is for other code" **detectable**. It is
NOT authentication: nothing here says who produced the file, and anyone who can
write the receipt can also run the commands. It is not a review either — the
independent verifier (`roles/verifier.md`, fresh context) is still required and
is not replaced by any receipt.

`tools/verify.sh check <slug>` reports `ok` · `fail` · `stale` · `missing` ·
`invalid` · `inconclusive` · `blocked` · `recipe` · `unconfigured`.

## 5. The review handoff, and where the loop stops

```
tools/handoff.sh push  <slug> --authorized "<the human's words>" [--remote r] [--branch b]
tools/handoff.sh check <slug>
```

Every guard rail on `push` is re-checked **immediately before** the push, and
again before `check` confirms one:

- the **complete ship gate**, by running `gates/check-gate.sh ship` itself — the
  same program, the same words. An `evidence.md` edited after approval, a stale
  upstream, source drift: the push refuses and quotes the gate.
- the **verification**: a configured recipe must read `ok`.
- **authority**: `--authorized` is required, *and* `intent.md`'s
  `- Scope authorization:` must actually name publishing a branch (push, PR, MR,
  review branch). An agent typing a flag does not authorize an external effect
  for itself, and neither does a line an agent writes into `delivery.md`.
- a delivery target of `local` is **never** pushed.
- **remote drift**: a review branch that moved somewhere this history does not
  contain stops the push instead of racing it.

Beyond that, `push` refuses to run without `--authorized`; refuses protected or shared
branches (built-in list plus `protected_branches:` in `.sdlc/config.md`);
refuses `--force` / `--force-with-lease` outright; refuses a HEAD whose tree
does not CONTAIN the source the ship review saw (the same whole-source snapshot
the ship approval binds, never a patch-id shortcut); and, when the remote branch
is already at this commit, reports `already pushed` instead of repeating the
effect. The completed push is recorded in the checkpoint.

`check` verifies the remote branch's SHA with `git ls-remote` — the fact is
established with git, never asserted in prose — and prints the exit condition:

- **review-ready** — the branch is on the remote at the delivered commit, and
  that commit contains the reviewed source. A human review of that branch is
  the next step. **This is where an unattended loop stops.**
- **merged / deployed** — outside the loop's authority. `delivery.md` must carry
  `Authorized-by:` with the human's own words, at every lazymode; without it
  `check` refuses and `tools/auto.sh next` reports `needs-human`. With it,
  `check` prints `PENDING EXTERNAL PROOF` and says exactly what it did and did
  not establish: a feature ref on a remote is **not** a merge commit on the
  target branch and **not** a deployment. The machine view carries the same
  thing as the gap `handoff.external-proof`.

`close.sh <slug> shipped` enforces the same fact where it matters most: a
`delivery.md` that claims `Handoff: review-ready|merged|deployed` must name
Remote and Branch, and `close.sh` runs `git ls-remote` itself before accepting
the close. A pre-0.10 delivery record — no `Handoff:` line — closes exactly as
it did in v0.9.0: opting into the automation's exit condition is what opts into
the automation's check.

`delivery.md`'s new `Remote`, `Branch`, `Handoff` and `Authorized-by` lines are
optional: a v0.9.0 delivery record behaves exactly as before, and `close.sh`
does not require them.

## 6. Checkpoint, retries, pause and resume

```
tools/auto.sh checkpoint <slug> --set-step ship.push
tools/auto.sh checkpoint <slug> --attempt build.fix --class transient
tools/auto.sh checkpoint <slug> --effect "push|origin|a20-1234|<sha>"
tools/auto.sh checkpoint <slug> --show | --clear
```

- The artifacts remain the authority. `checkpoint.md` (gitignored) holds only
  pending execution metadata; deleting it changes no gate verdict.
- **Attempt classes.** `transient` (a flaky network, a port in use) gets three
  attempts; `deterministic` (a failing assertion, a missing binary) gets one —
  a deterministic failure repeats deterministically, so it escalates instead of
  burning the budget. Past the cap the command exits 20 and the loop escalates
  to the human. These sit beside the loop's existing caps (deviations 5,
  re-gates 2 per stage, fix-loop rounds 3, ship adversary rounds 2, map
  sessions 6) and replace none of them.
- **Step names and effect kinds are validated** (`[a-zA-Z0-9._-]+`, one line)
  and matched LITERALLY. `build.fi.` is a step of its own, not a pattern that
  wipes `build.fix`'s counter.
- **A source change resets the attempt counters** and invalidates receipts: the
  failures belonged to code that no longer exists. Completed external effects
  stay on record, so a resume never pushes twice.
- **Pause** is simply the absence of a next dispatch: every counter is on disk.
  **Resume** re-runs `tools/auto.sh next <slug>`.
- Nothing here auto-fixes anything unrelated. A blocker outside the feature's
  scope goes to the human.

## 7. Symphony integration example

Symphony (or any host) provides the wake and the dispatch; the kit provides the
state and the boundaries. A minimal ticket driver:

```bash
#!/usr/bin/env bash
# drive.sh <slug> — one wake-up of one ticket. The HOST loops this; the agent
# does the thinking. Run from the project root.
set -u
KIT=~/sdlc-kit
out=$("$KIT/tools/auto.sh" next "$1"); rc=$?
echo "$out"
case $rc in
  0)  # ready: dispatch the implementer agent with the kit contract and this line.
      # It performs exactly one stage action, then exits; the host wakes it again.
      symphony dispatch implementer \
        --prompt "Read $KIT/AGENTS.md, then the stage skill for: $out" \
        --cwd "$PWD" ;;
  10) symphony ask-human --subject "$1" --body "$out" ;;   # a decision is owed
  20) symphony ask-human --subject "$1 BLOCKED" --body "$out" ;;
  30) symphony close-ticket "$1" ;;                        # feature closed
  *)  echo "environment problem" >&2; exit 1 ;;
esac
```

The human boundary is explicit and is not the host's to move:

- the loop may write artifacts, record gates its lazymode waives, run the
  verification recipe, commit, and push a **feature branch** for review;
- **merging that branch, and deploying it, are separate human approvals**, bound
  in `delivery.md` (`Authorized-by:`) — at lazymode 4 as much as at 0;
- anything outside the authorized scope in `intent.md` stops the loop, whatever
  the host would like to happen next.

A deployment-environment adapter (which service, which environment, which QA
command) belongs in the project, not in this kit: `.sdlc/config.md` and
`.sdlc/verify.md` are where a project names its own commands. The kit stays
generic.

## 8. What this layer does not do

Read these as the boundary of the machine view, not as a to-do list.

- **L1 no authentication, anywhere.** Receipts, source snapshots, approval
  records and `Authorized-by:` lines are change detection and record-keeping.
  They make edits, stale results and missing runs *detectable*; none of them
  establishes who did anything. An independent fresh-context reviewer
  (`roles/verifier.md`) is still required and is replaced by nothing here.
- **L2 `ready` is not autonomy.** No script in this layer reasons or performs a
  stage. A host that treats `ready` as "it happened" gets nothing done.
- **L3 the authority chain ends at prose a human wrote.** `push` checks that
  `intent.md`'s Scope authorization names a publication, and that its artifact
  passed the intent gate. That binds the *text* to the gate; it does not prove
  a human typed it. A lazymode-4 project where an agent writes intent.md is
  trusting the agent, and the gate record says so.
- **L4 merge and deployment are unverifiable from here.** The kit can see a
  feature ref on a remote. It cannot see a merge commit on someone else's
  branch, a closed PR, or a running deployment. `merged`/`deployed` are
  therefore reported as pending external proof, always.
- **L5 the doctor is only as good as the recipe.** `tools/verify.sh` proves the
  process it launched is alive and that the doctor answered; it cannot tell
  whether the thing answering is the right *build* unless the project's own
  doctor command asserts that (see `templates/verify.md`).
- **L6 timeouts need python3.** Without it `tools/verify.sh run` refuses rather
  than running unbounded. Everything else in the kit is shell + git.
- **L7 strict is opt-in.** A project with no `.sdlc/verify.md` is reported as a
  gap, not blocked — backwards compatibility, and also a way to stay unproven.
- **L8 two fields are read from prose.** `## Material questions` and
  `Delivery target` are structured, documented Markdown lines, but a project
  that ignores the template reads as `incomplete`.
- **L9 no deployment adapter.** Which service, which environment, which QA
  command belongs in `.sdlc/config.md` and `.sdlc/verify.md`, not in the kit.
- **L10 `gates/status.sh --json --all` errors** (unknown option) instead of
  ignoring `--all`: the JSON view is open-features-only by design.
