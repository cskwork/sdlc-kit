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
- A different verifier checks the implementation against the approved artifacts.
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
| Keeps the plan inside one chat | Commits the durable record — `intent.md`, `spec.md`, `plan.md`, `evidence.md`, `delivery.md` — with the code; bulk logs stay in `scratch/` on disk |
| Author runs its own checks | A fresh-context verifier and adversary review the work without the author's context |
| Approval is a chat message that disappears | Approval records name the stage, artifact, time, and mode, and stay on disk in `.sdlc/approvals/` |
| Failed attempt becomes forgotten context | Lessons go to a bounded index; durable facts go to `DOMAIN.md` |
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
.sdlc/
├── config.md                         # real build/test/lint/run commands
├── approvals/                        # gitignored
│   └── <slug>.<stage>.approval       # stage · when · mode
├── memory/
│   ├── POLICY.md                     # human-declared hard rules; agents transcribe only
│   ├── INDEX.md                      # ≤50 lines of lesson pointers
│   ├── DOMAIN.md                     # terms · verified facts · constraints
│   └── lessons/<date>-<lesson>.md
├── work/<slug>/                      # OPEN features only
│   ├── intent.md                     # problem · proof · success · scope
│   ├── spec.md                       # Human summary · AS-IS → TO-BE · contract
│   ├── plan.md                       # files · order · risks · proof
│   ├── evidence.md                   # commands · outputs · observed behavior
│   ├── delivery.md                   # target · delivered source · how it was verified
│   ├── deviations.md                 # build-time differences — gitignored
│   ├── progress.md                   # heartbeat: ONE live line, gitignored (rule 9)
│   ├── baseline.txt                  # brownfield behavior before the change — gitignored
│   ├── harvest.md                    # mid-loop lesson/domain candidates; merged at close — gitignored
│   └── scratch/                      # bulk logs, captures, traces — gitignored
└── archive/<slug>/                   # closed features; close.sh moves them here
    ├── CLOSED                        # shipped · abandoned · dead-end · handed-off
    └── approvals/                    # moves with the feature, still gitignored
```

`init.sh` also adds twelve lines to the project's `.gitignore`, covering `work/` and `archive/` alike: `approvals/`, `baseline.txt`, `deviations.md`, `harvest.md`, `scratch/`, and `progress.md`. Git keeps the durable record — `config.md`, `memory/`, and per feature `intent.md`, `spec.md`, `plan.md`, `map.md`, `evidence.md`, `delivery.md`, and the archived `CLOSED` — so the decisions and the final proof survive without the working copy. Bulk output stays in `scratch/`, cited by the deciding lines quoted in evidence.md. Re-running `init.sh` on a project seeded by an older kit removes the ignore lines it once issued for `spec.md` and `evidence.md`; it never touches the git index. While a feature is open, `status.sh` shows the heartbeat as a `now →` line with its age — `watch -n5 cat .sdlc/work/<slug>/progress.md` follows it live.

The public sdlc-kit repository stays framework-only. The committed artifacts — intent, plan, map, memory — live and version with the project they describe. The ignored ones live only in the working copy that produced them.

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

Before any of that, verification runs the real thing: the changed behavior exercised end to end through the interface a user or caller actually meets, scoped to the change, with the project's own commands (`e2e:`, `qa:`, `run:` in `.sdlc/config.md`). No environment to run it in means NOT VERIFIED, stated as such in evidence.md — a green unit suite is never a silent substitute.

### Failed runs leave knowledge

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

An abandoned or dead-end run cannot close until a lesson exists (at lazymode ≥3, the mandatory close reason is the record instead). It records what was tried, why it failed, and what would unblock it. A handed-off close must name the external ticket or PR, so the audit trail continues outside the kit. Closing also archives: the feature dir and its approval records move to `.sdlc/archive/<slug>/`, keeping `status.sh` scoped to open work.

### Incident diagnosis starts with cheap probes

Stage 6 does not begin with a broad agent fan-out. It first checks the deployed source — `refcheck.sh` compares the working tree's content (staged, unstaged, and untracked alike) against the target revision, takes the real deployment SHA with `--deployed-sha` when the release system reports one, and reports UNKNOWN rather than guessing when a ref or fetch fails — asks which control failed, tracks requested reproduction evidence, and runs the short probes in `skills/6-maintain/probes.md`.

The probes catch four common diagnosis mistakes before they reach a fix plan:

- reading a stale checkout instead of the deployed branch;
- changing one shared query without auditing every caller;
- adding a `try/catch` where the lower layer already swallows the error;
- calling a change "zero risk" without checking normal missing-data states.

When the incident cannot be reproduced, fresh-context adversaries recount the scope, prove the claimed error propagation, attack every "never" claim, and propose a rival cause. Outstanding console, network, or screenshot evidence stays visible in `status.sh` until it is received or the human waives it.

## Cockpit

```bash
gates/status.sh [--all[=n]] [slug]  # open features + one next action; --all adds the newest 20 archived
gates/stats.sh [--all]              # time per stage + re-approval counts; default open + 20 recent closed
gates/selftest.sh        # gate, close, injection, lazymode, status render, YAML integrity
gates/e2e.sh [kit]       # the loop end to end in throwaway git fixtures (local only, no remotes)
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
gates/           approve · check · close · status · stats · selftest · e2e (+ _common.sh helpers)
templates/       intent · spec · plan · evidence · delivery · lesson
docs/index.html  bilingual EN/KO landing page
```

## Verify the kit

```bash
./gates/selftest.sh   # gate mechanics
./gates/e2e.sh        # the whole loop, in its own throwaway fixtures
```

The selftest covers gate state and its path/content binding (cross-path reuse, traversal, symlinks, and pre-binding records all fail closed), stage-name injection, bare-path rejection, delegated and lazy approvals with their recorded review and risk authorization, the compact route and its upgrade revalidation, delivery-backed `shipped` closes, `refcheck.sh` drift detection, lesson requirements for closing, double-close rejection, archive-on-close (with approval records and status scoping), YAML frontmatter parsing, and LF line endings in every script. It also runs two end-to-end workflow fixtures: a compact bug fix from intent to a delivered close, and the failure paths around it — plus the source binding over work that was committed BEFORE the review and the commit-containment check on a `pr` delivery.

`gates/e2e.sh` is the integration suite on top of that: it builds throwaway git projects in its own temp fixture and drives the real scripts through the compact route, the full route, and every negative case — including post-review edits, added files, chmod and symlink swaps, an old commit named as the delivered source, legacy ship bindings, a full-route spec or plan rewritten or deleted after the ship review, and the agreement between `status.sh`, `check-gate.sh`, and `close.sh`. It writes nothing outside its fixture and makes no network, remote, or `gh` call; `pr` and `deploy` deliveries are exercised locally, which is all `close.sh` inspects. It does not run the selftest inside itself — the two suites are independent. CI runs both on Ubuntu, macOS, and Windows (Git Bash).

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
