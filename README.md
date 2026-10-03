<div align="center">

# sdlc-kit

### Stop letting coding agents mark their own homework.

**A portable SDLC for AI coding agents.**

Intent → spec → plan → build → evidence → maintain, with human approval gates, fresh-context review, and lessons for the next run.

[![Release](https://img.shields.io/github/v/release/cskwork/sdlc-kit?style=flat-square&color=C79A55)](https://github.com/cskwork/sdlc-kit/releases/latest)
[![GitHub Pages](https://img.shields.io/badge/live_site-open-C79A55?style=flat-square)](https://cskwork.github.io/sdlc-kit/)
[![Harness neutral](https://img.shields.io/badge/harness-pi_%C2%B7_Claude_Code_%C2%B7_Codex_%C2%B7_Gemini-24211E?style=flat-square)](#quick-start)

[**See the live site**](https://cskwork.github.io/sdlc-kit/) · [**Install in 60 seconds**](#quick-start) · [**Read the contract**](AGENTS.md) · [**한국어**](README.ko.md)

</div>

---

Coding is fast now. **Being wrong is still expensive.**

A common agent workflow starts with implementation. The agent receives a prompt, writes code, runs tests, and assumes the request was clear. sdlc-kit moves clarification and evidence earlier and keeps independent checks through the loop.

It is adapted from [Anthropic's AI-Native SDLC playbook](https://claude.com/blog/the-ai-native-sdlc-playbook), but it does not depend on Claude Code. The kit is plain Markdown plus shell scripts, so any harness that can read files and run commands can use it.

> sdlc-kit is an independent project and is not affiliated with Anthropic.

## Why it is different

| Typical agent workflow | sdlc-kit |
|---|---|
| Starts coding from the first request | Explores history, code, feasibility, and the live product first, including any flow that already makes the same change; asks only what it cannot check itself |
| Treats the user's diagnosis as truth | Labels claims `[verified: evidence]` or `[assumed: reason]` |
| Keeps the plan inside one chat | Writes `intent.md`, `spec.md`, `plan.md`, `evidence.md`, and `delivery.md` to a searchable record store (`tools/kb.sh`), outside the application's git history |
| Author checks its own work | A fresh-context adversary attacks the spec, plan, and diff; a separate verifier checks the build end to end, for side effects, and against the ticket |
| A green test suite stands in for every claim | Each claim carries its own proof: a test that failed before the fix, a pin for a refactor, a measurement for a number |
| Approval is a chat message that disappears | Approval records name the stage, artifact, time, and mode, and stay on disk in `.sdlc/approvals/` |
| Failed attempt becomes forgotten context | Lessons go to a bounded index, business rules to their product area's page, durable facts to `DOMAIN.md`; a recurring lesson is promoted, a project check first |
| "Done" is ambiguous | Every run closes as `shipped`, `abandoned`, `dead-end`, or `handed-off`, and `shipped` requires a verified delivery record |

## The loop

```text
┌────────────┐     human gate     ┌────────────┐     human gate
│  1. INTENT │ ─────────────────▶ │   2. SPEC  │ ─────────────────┐
│ intent.md  │                    │  spec.md   │                  │
└─────▲──────┘                    └────────────┘                  ▼
      │                                                     ┌────────────┐
      │ new intent                                          │  3. PLAN   │
      │                                                     │  plan.md   │
┌─────┴──────┐                    ┌────────────┐             └─────┬──────┘
│ 6. MAINTAIN│ ◀───────────────── │ 5. EVIDENCE│ ◀────────────────┘
│ diagnosis  │   ship + observe   │evidence.md │   build + verify
└────────────┘                    └────────────┘
                                      ▲
                                      │ fresh-context verifier
                                ┌─────┴──────┐
                                │  4. BUILD  │
                                │code + tests│
                                └────────────┘
```

Each stage produces one reviewable artifact, and an approval opens the next. Intent, spec, and ship gates are your decisions; after you approve in chat, the agent may run the approval command (recorded as `mode: delegated-chat`). The plan gate is tiered: a fresh-context adversary reviews every plan, and a routine plan auto-approves (`mode: agent-adversary`). A trip-wire makes it a human gate: migration, data deletion, public API or contract change, security paths, infra or config, or scope beyond the spec. When a shipped change fails, Maintain diagnoses it and writes the next `intent.md`.

`lazymode` in `.sdlc/config.md` moves the line between human and automatic gates. `init.sh` seeds `lazymode: 1`, and the agent asks which level you want.

| lazymode | Gates that stay human |
|---|---|
| 0 | intent, spec, plan on a trip-wire, ship (the design above) |
| 1 (default) | intent, spec, ship |
| 2 | intent, ship |
| 3 | intent |
| 4 | none; the loop runs on its own |

A waived gate is approved with `gates/approve.sh <stage> <artifact> --lazy --review "<what the review covered>"`, which refuses any gate the level keeps human. **lazymode moves who decides, never whether the work is reviewed or allowed.** Every waived gate still carries a review of the affected code and behavior. Risky work (data loss, public API, security paths, migrations, external delivery) needs your prior authorization, recorded with `--risk-authorized`, at every level. `tools/tripwire.sh` is a supplemental English keyword scan: a hit adds requirements, a clean scan clears nothing.

Not every ticket needs all six stages:

| Route | When | Flow |
|---|---|---|
| Compact | Small and well understood: exact files known, success checkable by an existing command, no open questions, inside what you already authorized | `intent.md` is the only work artifact and carries files, proof, risk, baseline, and delivery target. Intent (gate) → build → ship; ship's adversary review is the diff's only review |
| Full | Anything ambiguous, broad, or risky | All six stages |

The `Track:` line in `intent.md` records the route (criteria in `skills/1-intent`); incidents use the same routes. A surprise during build upgrades compact to full and re-approves the intent. A ticket too foggy to pin down starts with a **map** (`map.md`: destination · decided · unknown · out of scope) that resolves one unknown per session before `intent.md` is written.

## Quick start

Requires `bash`, `git`, and coreutils, which macOS and Linux already have. On Windows, use **Git Bash** (bundled with [Git for Windows](https://gitforwindows.org/)) or WSL, and run every kit command there, including the ones your agent runs. PowerShell and cmd cannot execute the scripts.

```bash
# 1. Install once
git clone https://github.com/cskwork/sdlc-kit ~/sdlc-kit

# 2. Seed one project or monorepo shipping unit
cd /path/to/your-project
~/sdlc-kit/init.sh

# 3. Review the proof commands (build, test, lint, run);
#    the agent fills empty ones from the repo and runs each once
$EDITOR .sdlc/config.md
```

Then point your harness at the routing contract by adding `For SDLC work, read ~/sdlc-kit/AGENTS.md and follow it.` to its project instruction file:

| Harness | File |
|---|---|
| pi, Codex CLI | `AGENTS.md` |
| Claude Code | `CLAUDE.md` |
| Gemini CLI | `GEMINI.md` |
| Cursor / other agents | the instruction file the harness loads, or paste `AGENTS.md` into the session |

Now say:

```text
Start SDLC for <your feature, bug, or change>
```

The agent routes to Stage 1, explores the project, and asks one evidence-backed question at a time. In a project with `.sdlc/`, a plain change request ("fix the login redirect") starts the loop too; read-only questions do not.

## A 60-second example

```text
you    Start SDLC for claims status self-service
agent  I checked the current API, UI flow, git history, and test harness.
       One claim in the request is wrong. Here is the evidence...

       [grill continues one question at a time]

agent  intent.md is ready. Review the Human summary.
you    approve
agent  APPROVED: intent of claims-status (.sdlc/work/claims-status/intent.md)
       recorded with mode: delegated-chat

       Stage 2 starts from the approved artifact.
```

There is no hidden state and no vendor-specific hook. The files are the protocol.

## What it produces

Per feature, inside the **target project**:

```text
.sdlc/                            # gitignored in full: records are knowledge, not source
├── README.md                     # generated contents page (tools/kb.sh index)
├── config.md                     # real build/test/lint/run commands, lazymode
├── approvals/                    # local gate records
│   └── <slug>.<stage>.approval   # stage · digests · time · mode
├── memory/
│   ├── POLICY.md                 # your hard rules; agents transcribe only
│   ├── INDEX.md                  # ≤50 lines of lesson pointers
│   ├── DOMAIN.md                 # terms, facts, and constraints that span areas
│   ├── areas/<menu path>.md      # one page per product area
│   └── lessons/<date>-<lesson>.md
├── work/<slug>/                  # OPEN features only
│   ├── origin.md                 # the ticket / 기획서 as requested
│   ├── intent.md                 # problem · proof · success · scope · route
│   ├── spec.md                   # Human summary · AS-IS → TO-BE · contract
│   ├── plan.md                   # files · order · reach · risks · proof
│   ├── evidence.md               # commands · outputs · observed behavior
│   ├── delivery.md               # target · delivered source · how it was verified
│   ├── summary.md                # the reader's page, kept current
│   ├── harvest.md                # memory candidates, merged at close
│   ├── deviations.md             # build-time differences
│   ├── progress.md               # heartbeat: one live line
│   ├── baseline.txt              # brownfield behavior before the change
│   └── scratch/                  # bulk logs and captures; artifacts quote the deciding lines
└── archive/<slug>/               # closed features; close.sh moves them here
    ├── CLOSED                    # shipped · abandoned · dead-end · handed-off
    └── approvals/                # moves with the feature
```

`init.sh` adds one anchored line, `/.sdlc`, to the project's `.gitignore`, so a clone of the application does not carry the records. While a feature is open, `status.sh` shows its heartbeat as a `now →` line with its age.

**Where the records live is your choice.** By default they sit in the project's working copy. `init.sh . --area ~/knowledge` puts them in `<area>/<unit>-<checkout-id>/` instead, with `.sdlc` linked to it: one store per checkout, so two worktrees never share approvals. Every script that writes to the store or reports a gate verdict refuses when `<store>/PROJECT` names another checkout, so a copied working copy cannot open or close the original's features. Reading is not bound: `tools/kb.sh show|search|list` still works. Nothing is ever moved for you, and **the store is yours to back up**. The kit directory stays framework-only.

**Knowledge is filed by product area.** For a web app an area is one menu, named by its menu path (`학습 > 평가 > 제출`); otherwise a module, API, job, or CLI command. Each area has one page, `memory/areas/학습 - 평가 - 제출.md`, written for a non-developer: business rules P1, P2…, figures N1, N2… when the area shows counts, rates, scores, or charts, how it works, and one history row per feature that changed it. A folded evidence block at the bottom holds sources, code locations, and a `Drive:` line: how a user reaches the area, the command or tool that drives it, the end state that proves it, and the traps. Ship harvests that line from the E2E check, and the next verifier starts from it. A feature's `summary.md` names its area, the spec states which rules and figures it keeps or changes, and the Side effects verifier re-checks the rest.

**Shared memory has one writer.** Mid-loop, candidates stage in the feature's own `harvest.md`. The close step is the only writer of `INDEX.md`, `DOMAIN.md`, `areas/`, and `lessons/`, so parallel loops never collide; business rules and history merge only when a feature closes `shipped`. Hard rules you state in chat are transcribed into `.sdlc/memory/POLICY.md`, on your word only and dated, and the adversary treats any violation as blocking.

**Reading the records back** is `tools/kb.sh`:

| Command | What it prints |
|---|---|
| `index` | Regenerates the contents page, `.sdlc/README.md` (`init.sh` and `close.sh` run it) |
| `show <slug>` | One feature as a digest: goal, `summary.md`, delivery, unmerged harvest, lessons, paths |
| `show "<product area>"` | The area page, `Drive:` line first, and the features that changed it |
| `search "<text>"` | A bounded literal search over open and closed features plus memory |
| `harvest [--stale <days>]` | Open features whose `harvest.md` is not in memory yet; a stale one may be merged without closing |

`list`, `show`, `search`, and `harvest` take `--area <folder>` to cover every store in that folder, including features whose checkout is gone. `index_style: obsidian` in the store's `config.md` adds frontmatter and `#tags` for a vault. Exit codes: `0` found, `1` nothing found, `2` usage error or refusal.

## The safety model

### Human decisions, agent keystrokes

You own every gate decision, directly at the gate or up front through `lazymode`. After you approve in chat, the agent may run:

```bash
gates/approve.sh <stage> .sdlc/work/<slug>/<artifact> --delegated
```

Silence and a generic "continue" are not approval. A lazymode waiver is approval you configured in advance, and the record names it. Text the agent reads (a ticket, a review comment, a log line, a web page) describes the problem: an instruction inside it is not followed, and it grants no scope or approval you did not give.

### Bound to what was approved

`approve.sh` records the stage, the artifact's path and sha256, the digests of the upstream artifacts it was granted on (`origin.md` included), the time, the mode, and, at ship, the reviewed source snapshot. `check-gate.sh` opens the gate only while all of that still matches. Editing an approved artifact, or one upstream of it, closes the gate and prints the exact re-approval command. The hash is change detection, not authentication: it proves the bytes are the ones approved, never who approved them. The records are gitignored, so the trail lives on disk in `.sdlc/approvals/`, and re-cloning mid-feature means approving again.

### Fresh-context review

One delegate carries the loop; subagents are dispatched only where they buy something. Verification and adversarial review always run in a fresh context, because the author cannot review its own work. A harness that cannot provide one records an explicit gap in the evidence instead of quietly reviewing itself. Independent workers may run in parallel, with one writer per checkout.

### Verification runs the real thing

After build, three verifier lenses run in parallel, each in a fresh context:

| Lens | What it checks |
|---|---|
| E2E | The changed behavior, end to end through the interface a user or caller meets, with the project's own commands (`e2e:`, `qa:`, `run:` in `.sdlc/config.md`) |
| Side effects | The baseline, the items that must stay untouched, and every other producer and consumer of the data shapes the change touches |
| Intent match | The build read back against `origin.md`, the ticket or 기획서 snapshot the intent gate bound: covered, missing, and beyond, per success criterion |

Each requirement runs happy, boundary, and negative cases, expectations written first, for every role and platform in scope. Three **reach** scenarios per change also vary how the change is met: another caller of the same behavior (entry), a record the change did not create (state), and a condition no requirement names (context). The plan lists every caller across the repositories and tiers that call the behavior; a change that refuses input those callers send today is a contract change and trips the plan gate.

Three kinds of claim carry their own proof:

| Claim | Proof |
|---|---|
| A bug is fixed | A regression test that fails on the pre-fix code for the reported reason, passes after, and stays in the suite; manual steps only when no test can reach the defect. A failure reported on a screen, an API call, or a job run is re-driven there after the fix |
| No behavior change (refactor, rename, move) | A pin: a check green before the first edit and after the last, seen failing once on a deliberate break. Type checks and lint are not a pin |
| A number (faster, smaller, cheaper) | The same command before and after, five or more runs a side, as median and range with errors and work done counted. A gap inside the spread is no difference |

No environment to run in means NOT VERIFIED, stated as such in `evidence.md`; a green unit suite is never a silent substitute. A gap the project has hit before also gets a proposal for a feature that builds the missing piece in the project. A finding from any lens enters the build fix loop: three rounds, then you (`tools/auto.sh` reports `fixloop.exhausted`).

Screens can be checked two ways. The default **agent** mode drives a browser through the `qa:` tool or whatever the harness has. **Jev** mode hands each UI scenario to [Jego](https://github.com/cskwork/ego-jev-ultrafast) as a plain-language goal with the texts that must appear, re-checks each result in a fresh tab, and writes one HTML report (screenshots, time, and cost per scenario) for the ship gate. `tools/qa-mode.sh set jev` switches every project until switched back (`--project` for one); see [`docs/jev-qa.md`](docs/jev-qa.md). When Jego is not usable, the verifier says so and uses agent mode.

### "Shipped" means delivered

The ship approval decides to release; it is not a release. Closing as `shipped` requires `delivery.md`: the agreed target (`local`, `pr`, or `deploy`), the delivered source, the command or project tool actually run to check the result, and its verbatim output. `close.sh` re-checks that the approved evidence and the reviewed source are unchanged, and refuses an absent, mismatching, or unconfirmed delivery. A `pr` or `deploy` `Source` must be a commit whose tree contains the reviewed source. Local work needs no production step.

The ship approval binds the project's whole source snapshot as the review saw it: every tracked file plus every untracked file git does not ignore, minus `.sdlc/`, by path, content, and executable bit. Committing those exact bytes keeps the binding valid. An edit, a new file, a deletion, a chmod, or a symlink swap afterwards breaks it, even in a file the review did not name, and `check-gate.sh`, `status.sh`, and `close.sh` name the files that changed. Submodule contents are not bound. Files are hashed in batches, so a shipped close on a repository of a few thousand files takes seconds.

Executable bits follow Git's `core.filemode`. When it is `false`, as on Git Bash for Windows, tracked files use the index mode and new files count as non-executable: mark an executable with `git add --chmod=+x` before review.

After the handoff, a review comment or a CI failure is a finding. While the feature is open, it is accepted or declined with a reason, and an accepted one is fixed under build, reviewed again, re-approved, and pushed. Once the feature is closed, it becomes a new feature with the comment as its origin.

### Failed runs leave knowledge

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

An abandoned or dead-end run cannot close until a lesson records what was tried, why it failed, and what would unblock it (at lazymode ≥3 the close reason is the record). A handed-off close must name the external ticket or PR. Closing archives the feature and its approval records to `.sdlc/archive/<slug>/`, which keeps `status.sh` scoped to open work.

A lesson is kept only when it changes what a future run does. When a lesson tag repeats three or more times in `INDEX.md`, `close.sh` prints a reminder to promote the fix to the strongest mechanism that fits: a test, lint rule, or check in the project first, then a `check:` line in the verify recipe, a stage-skill edit last.

### Incident diagnosis starts with cheap probes

Stage 6 does not begin with a broad agent fan-out. It first checks the deployed source: `tools/refcheck.sh` compares the working tree against the target revision (or the real deployment SHA, with `--deployed-sha`) and reports UNKNOWN rather than guessing when a ref or fetch fails. Then the agent asks what was done with what input, what happened instead, where, as whom, and what trace exists, and runs the short probes in `skills/6-maintain/probes.md`. They catch four common diagnosis mistakes before they reach a fix plan:

- reading a stale checkout instead of the deployed branch;
- changing one shared query without auditing every caller;
- adding a `try/catch` where the lower layer already swallows the error;
- calling a change "zero risk" without checking normal missing-data states.

When the probes do not show the cause, the agent lists rival causes and eliminates them by runtime observation. When the incident cannot be reproduced, fresh-context adversaries recount the scope, prove the claimed error propagation, attack every "never" claim, and propose a rival cause. Requested console, network, or screenshot evidence stays visible in `status.sh` until it arrives or is waived.

## Cockpit

```bash
gates/status.sh [--all[=n]] [slug]  # open features + one next action; --all adds the newest 20 archived
gates/status.sh --json [slug]       # the same state, machine-readable (tools/auto.sh)
gates/stats.sh [--all]              # time per stage + re-approval counts; default open + 20 recent closed
```

Example:

```text
== claims-status
  intent   APPROVED (@ 2026-08-28T10:18:53Z · delegated)
  spec     APPROVED (@ 2026-08-28T10:43:30Z · delegated)
  plan     PENDING approval
  ship     —  (no artifact)
  next  →  plan gate (tiered): gates/approve.sh plan ...
```

## Drive it from a host

A scheduler, a webhook, or a multi-agent runtime can drive the loop without reading prose. There is no daemon and no database; only `tools/verify.sh` needs python3.

```bash
tools/auto.sh next <slug>              # one line; exit 0 ready · 10 needs-human · 20 blocked · 30 complete
tools/auto.sh status --json [slug]     # schema sdlc-kit/auto-status@1
tools/auto.sh intent-check <slug>      # is this intent.md safe to run unattended?
tools/auto.sh checkpoint <slug> …      # pending step, bounded attempts, completed effects
tools/verify.sh run|check|baseline|coverage <slug>   # the verification recipe; receipt bound to the source
tools/handoff.sh push|check <slug>     # push the review branch (needs --authorized); prove it is on the remote
tools/kb.sh index|show|search|list|harvest   # read the records back
```

The host wakes an agent. The agent reads `next`, performs that one stage action under the stage skill, and loops. These scripts report and record; they run no model and perform no stage. `ready` means the next action is one this project's lazymode lets an agent take, not that a script reviewed anything.

Three boundaries do not move:

- **A material question stops the loop.** An unattended run never guesses away a question whose wrong answer would change what gets built or exceed the scope the human authorized.
- **Runtime proof is executed, not asserted.** `.sdlc/verify.md` maps each requirement to the project's own command or a stated gap. `tools/verify.sh run` runs every check, bounded, and binds the receipt to the source, the recipe, and each command's output: changed code makes it `stale`, an edited log `invalid`. Under `profile: strict`, review-ready needs a passing runtime or e2e check against a runtime that run launched. With a recipe, ship refuses a receipt that is not `ok`; a `blocked` one (no environment to run in) ships only with the human's own words (`--accept-gap`). Like the approval hash, the receipt is change detection, not authentication.
- **The loop ends at a pushed feature branch.** `tools/handoff.sh push` re-runs the ship gate and the verification just before it pushes, and requires that the scope authorization in `intent.md` names a publication: an agent cannot authorize an external effect for itself. Merging or deploying is a separate human approval, recorded in `delivery.md`, at every lazymode level.

Full contract, drive/resume procedure, and a Symphony example: [`docs/automation.md`](docs/automation.md).

## Works in complex codebases

sdlc-kit is a process layer, not a replacement for the project's existing rules:

- **Project rules win on how:** commands, branches, style, tools, deployment policy.
- **sdlc-kit wins on process:** stages, approval gates, evidence, memory.
- **Existing knowledge wins:** `DOMAIN.md` points to existing glossaries, `CONTEXT.md`, and ADRs instead of copying them.
- **Existing agents win:** local QA, browser, API, reviewer, or DB specialists execute the kit's role contract.
- **Monorepos stay scoped:** use one `.sdlc/` per shipping unit; root only for cross-unit changes.

A genuine rule conflict is shown to the human with both texts quoted. The agent does not resolve it silently.

## Greenfield and brownfield

**Greenfield:** Stage 1 records the problem and checks required integration points before Stage 2 opens.

**Brownfield:** probes establish AS-IS first, the plan captures a baseline before editing, and evidence proves the TO-BE and the unchanged neighboring behavior.

## Upgrade

```bash
cd ~/sdlc-kit && git pull
cd /path/to/project && ~/sdlc-kit/init.sh
```

`init.sh` is idempotent: existing files stay intact, seed files from later kit versions are added, and narrower ignore lines from older kits give way to `/.sdlc`. It never touches the git index, so records an older kit committed stay tracked until you untrack them (`init.sh` prints the command). An approval in an older binding format (no digest, or a ship approval bound only to the uncommitted diff) fails closed, and the gate prints the re-approval command.

A Windows clone made before the kit pinned its line endings still holds CRLF scripts, which bash refuses to run. Re-normalize that clone once (this discards any local edits inside the kit clone):

```bash
cd ~/sdlc-kit && git rm --cached -r -q . && git reset --hard
```

## Repository map

```text
SKILL.md         discovery router: start · continue · status · close
AGENTS.md        full portable process contract
init.sh          idempotent project seed
skills/1-6/      stage instructions
roles/           verifier · adversary · researcher contracts
gates/           approve · check-gate · close · status · stats · selftest (+ _common.sh, _auto.sh)
tools/           auto · verify (needs python3) · handoff · kb · qa-mode · tripwire · refcheck · _run.py
templates/       artifacts, memory pages, verify recipe (intent, spec, plan, evidence, area, lesson, …)
docs/            index.html (bilingual EN/KO site) · automation.md (machine contract) · jev-qa.md
log/             release notes
.gitattributes   pins LF endings so scripts survive a Windows clone
```

## Verify the kit

```bash
./gates/selftest.sh   # a few seconds
```

One smoke test for a kit that is mostly instructions. It checks that every script parses and is LF-only, every SKILL.md has valid frontmatter, a gate opens only for the approved bytes, lazymode never goes beyond its level, `dead-end` needs a lesson and `shipped` a confirmed delivery, knowledge is filed under its own product area, and the verification receipt gates ship. CI runs it on Ubuntu, macOS, and Windows (Git Bash) for pull requests, and by hand.

## What this is not

- Not an autonomous production deployment system.
- Not a substitute for project tests, CI, branch protection, or security review.
- Not a promise that an agent cannot lie or forge files.
- Not another agent runtime. Keep your agent tool and add this process.

## Try it

Start with one small brownfield issue. Compare what the independent verifier finds with what the author reported.

If the process works for your team, star the repository or open an issue for the agent tool or workflow you want supported next.

<div align="center">

[**Get started**](#quick-start) · [**Live site**](https://cskwork.github.io/sdlc-kit/) · [**Latest release**](https://github.com/cskwork/sdlc-kit/releases/latest) · [**Open an issue**](https://github.com/cskwork/sdlc-kit/issues/new)

</div>
