<div align="center">

# sdlc-kit

### Stop letting coding agents mark their own homework.

**A portable SDLC for AI coding agents.**

Intent → spec → plan → build → evidence → maintain, with human approval gates, fresh-context review, and lessons for the next run.

[![Release](https://img.shields.io/github/v/release/cskwork/sdlc-kit?style=flat-square&color=C79A55)](https://github.com/cskwork/sdlc-kit/releases/latest)
[![GitHub Pages](https://img.shields.io/badge/live_site-open-C79A55?style=flat-square)](https://cskwork.github.io/sdlc-kit/)
[![Harness neutral](https://img.shields.io/badge/harness-pi_%C2%B7_Claude_Code_%C2%B7_Codex_%C2%B7_Gemini-24211E?style=flat-square)](#works-with-your-agent)

[**See the live site**](https://cskwork.github.io/sdlc-kit/) · [**Install in 60 seconds**](#quick-start) · [**Read the contract**](AGENTS.md) · [**한국어**](README.ko.md)

</div>

---

Coding is fast now. **Being wrong is still expensive.**

A common agent workflow starts with implementation. The agent receives a prompt, writes code, runs tests, and assumes the request was clear. sdlc-kit moves clarification and evidence earlier and keeps independent checks through the loop:

- The agent investigates before it asks you questions.
- Claims in `intent.md` are labeled `[verified]` or `[assumed]`.
- A fresh-context adversary reviews the spec before you approve it.
- A routine plan auto-approves after a clean adversary review; migrations, deletions, API, security, and infra changes escalate to you.
- A different verifier checks the implementation three ways in parallel: end to end, for side effects and data consistency, and against the ticket or spec document the request came from.
- Failed attempts leave lessons and domain knowledge for the next run.

It is adapted from [Anthropic's AI-Native SDLC playbook](https://claude.com/blog/the-ai-native-sdlc-playbook), but it does not depend on Claude Code. The implementation is plain Markdown plus shell scripts. Any harness that can read files and run commands can use it.

> sdlc-kit is an independent project and is not affiliated with Anthropic.

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

Each stage produces one reviewable artifact. Intent, spec, and ship gates are human decisions; after you approve in chat, the agent may run the approval command, and the record marks that delegation with `mode: delegated-chat`. The plan gate is tiered: a fresh-context adversary reviews every plan, a routine plan auto-approves (`mode: agent-adversary`), and any trip-wire — migration, data deletion, public API, security paths, infra/config, beyond-spec scope — makes it a human gate.

`lazymode` slides that human/auto line. `init.sh` seeds `lazymode: 1` in `.sdlc/config.md` and the agent asks you which level you want. Each level names the gates that stay human: **0** intent, spec, plan trip-wires, ship (everything as designed) · **1** (default) intent, spec, ship · **2** intent, ship · **3** intent · **4** none — the loop runs autonomously. A waived gate is auto-approved with `gates/approve.sh <stage> <artifact> --lazy --review "<what the review covered>"` (recorded as `mode: lazy` plus the review note). **lazymode moves who decides, never whether the work is reviewed or allowed**: every waived gate still carries a review of the affected code and behavior, and risky work — data loss, public API, security paths, migrations, external delivery — needs the human's prior authorization recorded with `--risk-authorized`, at every level. `tripwire.sh` is a supplemental English keyword scan: a hit adds requirements, a clean scan clears nothing. Approvals are still recorded, and `approve.sh --lazy` refuses any gate the configured level keeps human.

When a shipped change fails, Maintain diagnoses it and writes the next `intent.md`.

Not every ticket needs all six stages. A small, well-understood change — exact files known, success checkable by an existing command, no open questions, inside what you already authorized — takes the **compact route**: one work artifact (`intent.md`, carrying files · proof · risk · delivery target), intent (gate) → build → ship, with ship's adversary review as the diff's only review (`Track: compact` in intent.md; `micro` is the older spelling; criteria in `skills/1-intent`). Incidents use the same compact route — there is no separate compressed loop. Anything ambiguous, broad, or risky takes the full route, and an upgrade mid-flight re-approves the intent that authorized the shortcut. A ticket too foggy to pin down starts with a **map** (`map.md`: destination · decided · unknown · out of scope) and resolves one unknown per session before intent.md is written.

Mid-loop, lesson and domain candidates stage in the feature's own `harvest.md`; the close step is the only writer of shared memory (`INDEX.md`, `DOMAIN.md`, `lessons/`), so parallel loops never collide on those files. Hard rules you state in chat are transcribed — on your word only, with the date — into `.sdlc/memory/POLICY.md`, and the adversary treats any violation as a blocking finding.

## Why it is different

| Typical agent workflow | sdlc-kit |
|---|---|
| Starts coding from the first request | Explores history, code, feasibility, browser, API, or DB before grilling the user |
| Treats the user's diagnosis as truth | Marks claims `[verified: evidence]` or `[assumed: reason]` |
| Keeps the plan inside one chat | Writes the record — `intent.md`, `spec.md`, `plan.md`, `evidence.md`, `delivery.md` — to a store you can search later (`tools/kb.sh`), out of the application's git history |
| Author runs its own checks | A fresh-context verifier and adversary review the work without the author's context |
| Approval is a chat message that disappears | Approval records name the stage, artifact, time, and mode, and stay on disk in `.sdlc/approvals/` |
| Failed attempt becomes forgotten context | Lessons go to a bounded index; business rules go to their product area's page; durable facts go to `DOMAIN.md` |
| One generic worker does everything | Roles map onto local QA, reviewer, browser, API, or DB specialists when available |
| "Done" is ambiguous | Every run closes as `shipped`, `abandoned`, `dead-end`, or `handed-off` — and `shipped` requires a verified delivery record, not just an approval |

## Quick start

Requires `bash`, `git`, and coreutils. macOS and Linux already have them. On Windows, use **Git Bash** (bundled with [Git for Windows](https://gitforwindows.org/)) or WSL, and run every kit command there, including the ones your agent runs. PowerShell and cmd cannot execute the scripts.

```bash
# 1. Install once
git clone https://github.com/cskwork/sdlc-kit ~/sdlc-kit

# 2. Seed one project or monorepo shipping unit
cd /path/to/your-project
~/sdlc-kit/init.sh

# 3. Add the project's real proof commands
$EDITOR .sdlc/config.md
```

Then point your harness at the routing contract:

| Harness | Project instruction |
|---|---|
| **pi** | Add: `For SDLC work, read ~/sdlc-kit/AGENTS.md and follow it.` to the project `AGENTS.md` |
| **Claude Code** | Add the same pointer to `CLAUDE.md` |
| **Codex CLI** | Add the same pointer to `AGENTS.md` |
| **Gemini CLI** | Add the same pointer to `GEMINI.md` |
| **Cursor / other agents** | Put the pointer in the instruction file the harness loads, or paste `AGENTS.md` into the session |

Now say:

```text
Start SDLC for <your feature, bug, or change>
```

The agent routes to Stage 1, explores the project, and asks one evidence-backed question at a time.

## A 60-second example

```text
you    Start SDLC for claims status self-service
agent  I checked the current API, UI flow, git history, and test harness.
       One claim in the request is wrong. Here is the evidence...

       [grill continues one question at a time]

agent  intent.md is ready. Review the Human summary.
you    approve
agent  APPROVED: intent of claims-status (.sdlc/work/claims-status/intent.md)
       mode: delegated-chat

       Stage 2 starts from the approved artifact.
```

No hidden state. No vendor-specific hook required. The files are the protocol.

## What it produces

Per feature, inside the **target project**:

```text
.sdlc/                                # gitignored in full — records are knowledge, not source
├── README.md                         # generated contents page (tools/kb.sh index)
├── config.md                         # real build/test/lint/run commands
├── approvals/                        # local gate records
│   └── <slug>.<stage>.approval       # stage · when · mode
├── memory/
│   ├── POLICY.md                     # human-declared hard rules; agents transcribe only
│   ├── INDEX.md                      # ≤50 lines of lesson pointers
│   ├── DOMAIN.md                     # terms · facts and constraints that span areas
│   ├── areas/<area-slug>.md               # one per product area (web app: one menu): business rules P1… · how it works · history
│   └── lessons/<date>-<lesson>.md
├── work/<slug>/                      # OPEN features only
│   ├── origin.md                     # the ticket / 기획서 as requested — bound by the intent gate
│   ├── intent.md                     # problem · proof · success · scope
│   ├── spec.md                       # Human summary · AS-IS → TO-BE · contract
│   ├── plan.md                       # files · order · risks · proof
│   ├── evidence.md                   # commands · outputs · observed behavior
│   ├── delivery.md                   # target · delivered source · how it was verified
│   ├── deviations.md                 # build-time differences
│   ├── progress.md                   # heartbeat: ONE live line (rule 9)
│   ├── baseline.txt                  # brownfield behavior before the change
│   ├── summary.md                    # the reader's page: Area · What was wrong · Before → After · How to check · Remember; kept current, bound by no approval
│   ├── harvest.md                    # mid-loop lesson/domain candidates; merged at close (readable before: kb.sh show / harvest)
│   └── scratch/                      # bulk logs, captures, traces
└── archive/<slug>/                   # closed features; close.sh moves them here
    ├── CLOSED                        # shipped · abandoned · dead-end · handed-off
    └── approvals/                    # moves with the feature
```

`init.sh` adds ONE line to the project's `.gitignore`: `/.sdlc`. Records are the project's knowledge, not its source — they stay out of the application's history, and a clone of the application does not carry them. The rule is anchored, so a nested shipping unit's own `.sdlc` is unaffected; it matches a real directory and the symlink an external area installs alike. Re-running `init.sh` on a project seeded by an older kit removes the narrower ignore lines that rule now subsumes, and it never touches the git index: files already committed stay committed until you untrack them yourself (`init.sh` prints the command). Bulk output stays in `scratch/`, cited by the deciding lines quoted in evidence.md. While a feature is open, `status.sh` shows the heartbeat as a `now →` line with its age — `watch -n5 cat .sdlc/work/<slug>/progress.md` follows it live.

**Where the records live is your choice.** By default they sit in the project's working copy. `init.sh . --area ~/knowledge` puts them in a folder you choose instead — `<area>/<unit>-<checkout-id>/`, with `.sdlc` linked to it, one store per checkout so two worktrees never share approvals. The area is refused if it sits inside the project (or the project inside it), if another checkout already owns that store, if a real `.sdlc` directory is already there (nothing is ever relocated for you), or if the link cannot be made. That ownership is re-checked at RUNTIME, not only at init: `check-gate.sh`, `approve.sh`, `close.sh`, `status.sh`, `tools/auto.sh`, `tools/verify.sh` and `tools/handoff.sh` refuse before any verdict or write when `<store>/PROJECT` names a different checkout, so a copied working copy (`cp -R`, rsync and most restores keep the symlink) can neither open another checkout's gate nor close its features. Reading is never bound that way: `tools/kb.sh show|search|list` still works, and nothing is ever re-bound or moved for you. Whichever you choose, **the store is yours to back up** — git no longer does it for you.

**Knowledge is filed by product area.** For a web app an area is one menu, named by its menu path (`학습 > 평가 > 제출`); for other software a module, API, job, or CLI command. Each area has one page, `memory/areas/<area-slug>.md`: its business rules numbered P1, P2… in sentences a non-developer can read, how it works, and a history line per feature that changed it. A feature's `summary.md` names its area on an `Area:` line, the spec states which rules it keeps or changes, the Side effects verifier re-checks the rules it should not have touched, and the close merge files new or changed rules on the page. `tools/kb.sh show "학습 > 평가 > 제출"` (or the page's file name) prints the page with the features that changed it.

**Reading the records back** is `tools/kb.sh`: `index` regenerates the contents page (`init.sh` and `close.sh` do it for you) — the product areas with their rule count, last change and features, an overview table by state, date, area and tags, newest first, the harvests no close has merged yet, then one section per feature; `show <slug>` prints one feature as a digest — goal, its `summary.md` (area, what was wrong, before → after, how to check, the one record meant to be kept current), delivery, unmerged harvest candidates, lesson titles, then the paths; `search "<text>"` does a bounded literal search over open and closed features plus durable memory; `harvest [--stale <days>]` lists open features whose harvest.md is not in memory yet, with idle time (a stale one may be merged without closing — AGENTS.md rule 4); and `--area <folder>` does any of these across every store in that folder — including features whose checkout no longer exists. `index_style: obsidian` in the store's config.md adds frontmatter and inline `#tags` for a vault; no timestamp is ever written, so an unchanged page produces no diff. Exit codes: `0` found, `1` nothing found, `2` usage error or refusal.

The public sdlc-kit repository stays framework-only. The records live and stay readable where they were written — in the project's working copy, or in the area you chose.

## The safety model

### Human decisions, agent keystrokes

The human owns every gate decision — directly at the gate, or up front by setting `lazymode` in `.sdlc/config.md`. After explicit approval in chat, the agent may run:

```bash
gates/approve.sh <stage> .sdlc/work/<slug>/<artifact> --delegated
```

The approval record stays explicit. Silence and generic "continue" are not approval; a lazymode waiver is approval the human configured in advance, and the record names it.

### Bound to what was approved

`approve.sh` records the stage, the canonical `.sdlc/work/<slug>/<artifact>` path, that artifact's sha256, the digests of the upstream artifacts it was granted on top of, the time, the mode, and — at ship — the reviewed source snapshot (kept beside the record as `<slug>.ship.source`). `check-gate.sh` opens the gate only when all of that still matches, so editing an approved artifact, or materially rewriting an upstream one, closes the gate and prints the exact re-approval command. The hash is change detection, not authentication: it proves the bytes are the ones approved, never who approved them. A record from an older kit carries no digest and fails closed with the same instruction. The records are gitignored, so the trail is the `.sdlc/approvals/` directory on disk (for closed features, `.sdlc/archive/<slug>/approvals/`), not git history. `status.sh` and `stats.sh` read those files, so gate state and re-approval counts are unaffected. What changes is durability: a fresh clone carries no approvals, so re-cloning mid-feature means approving again. The honesty of the trail comes from agent rules plus those on-disk records.

### Fresh-context review

One delegate carries the loop — stage-by-stage subagent dispatch is not required, and is used only where it buys something. What is never optional: verification and adversarial review run in a fresh context, because the author cannot review their own work. A harness that cannot provide one records that as an explicit gap in the evidence instead of self-reviewing quietly. Independent workers may run in parallel; one writer per checkout.

### "Shipped" means delivered

The ship approval decides to release; it is not a release. Closing as `shipped` requires `delivery.md`: the agreed target (`local`, `pr`, or `deploy`), the delivered source, the command or project tool actually run to check the result, and its verbatim output. `close.sh` re-checks the ship approval — the approved evidence unchanged, the reviewed source unchanged — and refuses an absent, mismatching, or unconfirmed delivery. A `pr` or `deploy` `Source` must be a commit that CONTAINS the reviewed source: close compares that commit's tree against the reviewed snapshot, so naming a commit that merely exists is refused. Local work needs no production step.

The ship approval binds the project's whole source snapshot as the review saw it — every tracked file plus every untracked file git does not ignore, minus `.sdlc/`, by path, content, and executable bit. Staging or committing those exact bytes keeps the binding valid, and work that was already committed when the review ran is bound too. An edit, a new file, a deletion, a chmod, or a symlink swap afterwards breaks it, including in a file the review did not name — `check-gate.sh`, `status.sh`, and `close.sh` report it in the same words and name the files that changed. Ship approvals written by an older kit bound only the uncommitted diff and fail closed, saying so. Submodule contents are not bound. A path name git C-quotes — one containing a tab, a newline, a double quote, or a backslash — cannot be bound: `approve.sh ship` refuses it by name, and one that appears after the review closes the gate as an invalid source until it is renamed or ignored. Unicode and spaces in names are fine.

Executable bits follow Git's `core.filemode` setting. When it is `false`, as on Git Bash for Windows, the snapshot uses the index mode for tracked files and treats new files as non-executable. Use `git add --chmod=+x` or `git update-index --chmod=+x` before review to mark an executable; changing that index mode after review invalidates approval. With `core.filemode=true`, filesystem chmod changes are checked directly.

Before any of that, verification runs the real thing: the changed behavior exercised end to end through the interface a user or caller actually meets, scoped to the change, with the project's own commands (`e2e:`, `qa:`, `run:` in `.sdlc/config.md`). No environment to run it in means NOT VERIFIED, stated as such in evidence.md — a green unit suite is never a silent substitute. Two more lenses run beside it in parallel: **side effects** — the baseline, the untouched items, and the consistency of every data shape the change touches across its other producers and consumers — and **intent match** — the build read back, per numbered success criterion, against `origin.md`, the snapshot of the ticket or 기획서 the intent gate bound, listing what is covered, missing, and beyond. A finding from any lens enters the build fix loop: three rounds, then the human, and `tools/auto.sh` reports an exhausted loop as `fixloop.exhausted`.

### Failed runs leave knowledge

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

An abandoned or dead-end run cannot close until a lesson exists (at lazymode ≥3, the mandatory close reason is the record instead). It records what was tried, why it failed, and what would unblock it. A handed-off close must name the external ticket or PR, so the audit trail continues outside the kit. Closing also archives: the feature dir and its approval records move to `.sdlc/archive/<slug>/`, keeping `status.sh` scoped to open work.

### Incident diagnosis starts with cheap probes

Stage 6 does not begin with a broad agent fan-out. It first checks the deployed source — `refcheck.sh` compares the working tree's content (staged, unstaged, and untracked alike) against the target revision, takes the real deployment SHA with `--deployed-sha` when the release system reports one, and reports UNKNOWN rather than guessing when a ref or fetch fails — asks what was done with what input, what happened instead, where, as whom, and what trace exists (the same five questions for a UI, an API, a job, or a CLI), tracks requested reproduction evidence, and runs the short probes in `skills/6-maintain/probes.md`.

The probes catch four common diagnosis mistakes before they reach a fix plan:

- reading a stale checkout instead of the deployed branch;
- changing one shared query without auditing every caller;
- adding a `try/catch` where the lower layer already swallows the error;
- calling a change "zero risk" without checking normal missing-data states.

A bug fix starts with a regression test that fails on the pre-fix code for the reported reason; the same test passes after and stays in the suite. Manual steps or logs stand in only when no test can reach the defect, and the evidence says why.

When the incident cannot be reproduced, fresh-context adversaries recount the scope, prove the claimed error propagation, attack every "never" claim, and propose a rival cause. Outstanding console, network, or screenshot evidence stays visible in `status.sh` until it is received or the human waives it.

## Cockpit

```bash
gates/status.sh [--all[=n]] [slug]  # open features + one next action; --all adds the newest 20 archived
gates/status.sh --json [slug]       # the same state, machine-readable (tools/auto.sh)
gates/stats.sh [--all]              # time per stage + re-approval counts; default open + 20 recent closed
gates/selftest.sh        # gate, close, injection, lazymode, status render, YAML integrity
gates/e2e.sh [kit]       # the loop end to end in throwaway git fixtures (local only, no remotes)
gates/autotest.sh [kit]  # the automation layer in its own fixtures (local bare remotes, no network)
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

## Drive it from a host (v0.10.0)

A scheduler, a webhook, or a multi-agent runtime can drive the loop without
reading prose. Four small scripts, no daemon, no database, no new dependency:

```bash
tools/auto.sh next <slug>              # one line; exit 0 ready · 10 needs-human · 20 blocked · 30 complete
tools/auto.sh status --json [slug]     # schema sdlc-kit/auto-status@1
tools/auto.sh intent-check <slug>      # is this intent.md safe to run unattended?
tools/auto.sh checkpoint <slug> …      # pending step, bounded attempts, completed effects
tools/verify.sh run|check <slug>       # run the project's verification recipe (needs python3); receipt bound to the source
tools/handoff.sh push|check <slug>     # the review branch, proven to be on the remote
tools/kb.sh index|show|search|list|harvest   # find past features and lessons (--area for every store; harvest = knowledge not merged yet)
```

The host wakes an agent; the agent reads `next`, performs that ONE stage action
under the stage skill, and loops. These scripts report and record — they run no
model and perform no stage. `ready` means the next action is one this project's
lazymode lets an agent take, not that a shell script reviewed anything.

Three boundaries are explicit and do not move:

- **A material question stops the loop.** An unattended run never guesses away a
  question whose wrong answer would change what gets built or exceed the scope
  the human authorized.
- **Runtime proof is executed, not asserted.** `.sdlc/verify.md` maps each
  requirement to the project's own command; `tools/verify.sh` runs every one of
  them — bounded, stdin closed, each in its own process group — and binds the
  result to the source before and after the run, the recipe, and each command's
  output. Change the code and it goes `stale`; edit a log it cites and it goes
  `invalid`. Under `profile: strict`, no passing runtime/e2e check against a
  runtime that run launched means not review-ready — a green unit suite is never
  a stand-in. The receipt is change detection, not authentication: it makes a
  missing or edited proof visible, and never says who produced it.
- **The loop ends at a pushed feature branch.** `tools/handoff.sh push` re-runs
  the complete ship gate and the verification immediately before it pushes, and
  requires that the scope `intent.md` records actually names a publication — an
  agent cannot authorize an external effect for itself. Merging that branch or
  deploying it is a separate human approval, recorded in `delivery.md`, at every
  lazymode level; neither is something this kit can verify from here.

Full contract, drive/resume procedure, and a Symphony example:
[`docs/automation.md`](docs/automation.md).

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

**Brownfield:** history, code graph, feasibility, and optional browser/API/DB probes establish AS-IS first. The plan captures a baseline before editing. Evidence proves the TO-BE and the unchanged neighboring behavior.

## Upgrade

```bash
cd ~/sdlc-kit && git pull
cd /path/to/project && ~/sdlc-kit/init.sh
```

`init.sh` is idempotent. Existing files stay intact; new seed files from later kit versions are added.

A Windows clone made before the kit pinned its line endings still holds CRLF scripts, which bash refuses to run. Re-normalize that clone once:

```bash
cd ~/sdlc-kit && git rm --cached -r -q . && git reset --hard
```

That discards any local edits inside the kit clone.

## Repository map

```text
SKILL.md         discovery router: start · continue · status · close
AGENTS.md        full portable process contract
init.sh          idempotent project seed
.gitattributes   pins LF endings so scripts survive a Windows clone
skills/1-6/      stage instructions
roles/           verifier · adversary · researcher contracts
gates/           approve · check · close · status · stats · selftest · e2e · autotest (+ _common.sh, _auto.sh)
tools/           auto (machine status) · verify (receipts, needs python3) · handoff (review branch) · _run.py (bounded execution) · tripwire · refcheck
templates/       intent · spec · plan · evidence · delivery · verify · lesson
docs/index.html  bilingual EN/KO landing page
docs/automation.md  the machine contract: status JSON, receipts, handoff, checkpoint
```

## Verify the kit

```bash
./gates/selftest.sh   # gate mechanics
./gates/e2e.sh        # the whole loop, in its own throwaway fixtures
./gates/autotest.sh   # the automation layer, in its own throwaway fixtures
./gates/knowledge-test.sh  # where records live and how they are found again
```

The selftest covers gate state and its path/content binding (cross-path reuse, traversal, symlinks, and pre-binding records all fail closed), stage-name injection, bare-path rejection, delegated and lazy approvals with their recorded review and risk authorization, the compact route and its upgrade revalidation, delivery-backed `shipped` closes, `refcheck.sh` drift detection, lesson requirements for closing, double-close rejection, archive-on-close (with approval records and status scoping), YAML frontmatter parsing, and LF line endings in every script. It also runs two end-to-end workflow fixtures: a compact bug fix from intent to a delivered close, and the failure paths around it — plus the source binding over work that was committed BEFORE the review and the commit-containment check on a `pr` delivery.

`gates/autotest.sh` covers the automation layer on the same principle: the
full-auto intent contract (a material question blocks, a resolved one releases),
verification receipts (a failing check, a missing receipt, a strict profile with
no runtime evidence, and stale code, commands, or recipe all block), the review
handoff against a local bare remote (unauthorized, protected-branch, force, and
non-containing pushes refused; a second push repeats nothing; a remote SHA that
differs blocks review-ready; merge and deploy need `Authorized-by:`), bounded
retries and resume, and the lazymode-0 and source-binding behavior unchanged.
It also carries a regression case for every finding of the first independent
review: material questions written without bullets, a check that reads stdin, a
launched runtime that must not leak its children, an unowned runtime answering
the doctor, a hung check, a push over a closed ship gate, a `pr` feature that
was never pushed, and a local target that must never be pushed at all.

`gates/e2e.sh` is the integration suite on top of that: it builds throwaway git projects in its own temp fixture and drives the real scripts through the compact route, the full route, and every negative case — including post-review edits, added files, chmod and symlink swaps, an old commit named as the delivered source, legacy ship bindings, a full-route spec or plan rewritten or deleted after the ship review, and the agreement between `status.sh`, `check-gate.sh`, and `close.sh`. It writes nothing outside its fixture and makes no network, remote, or `gh` call; `pr` and `deploy` deliveries are exercised locally, which is all `close.sh` inspects. It does not run the selftest inside itself — the two suites are independent. CI runs both on Ubuntu, macOS, and Windows (Git Bash).

`gates/knowledge-test.sh` covers the store itself: the anchored ignore rule, an external area bound to a chosen folder (spaces and non-ASCII included), one store per checkout, and every refusal — an area inside the project, a project inside the area, a store another checkout owns, a directory that is not a store, a real `.sdlc` that is never relocated, a link pointing somewhere else, an unwritable area. It then runs a feature through the link (approve, tamper, ship, deliver, close) to prove the gates are unchanged, and checks retrieval: the contents page refreshed at close, `show`, bounded literal `search`, a query starting with `-`, a user-authored page that is never clobbered, a feature symlink that is never followed, and records still readable through `--area` after the checkout they came from is deleted. Where the filesystem cannot create a symlink the external-area cases are reported as NOT VERIFIED rather than skipped silently.

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
