<div align="center">

# sdlc-kit

### Stop letting coding agents mark their own homework.

**A portable SDLC for AI coding agents.**

Intent → spec → plan → build → evidence → maintain, with human approval gates, fresh-context review, and lessons for the next run.

[![Release](https://img.shields.io/github/v/release/cskwork/sdlc-kit?style=flat-square&color=C79A55)](https://github.com/cskwork/sdlc-kit/releases/latest)
[![GitHub Pages](https://img.shields.io/badge/live_site-open-C79A55?style=flat-square)](https://cskwork.github.io/sdlc-kit/)
[![Harness neutral](https://img.shields.io/badge/harness-pi_%C2%B7_Claude_Code_%C2%B7_Codex_%C2%B7_Gemini-24211E?style=flat-square)](#works-with-your-agent)

[**See the live site**](https://cskwork.github.io/sdlc-kit/) · [**Install in 60 seconds**](#quick-start) · [**Read the contract**](AGENTS.md)

</div>

---

Coding is fast now. **Being wrong is still expensive.**

A common agent workflow starts with implementation. The agent receives a prompt, writes code, runs tests, and assumes the request was clear. sdlc-kit moves clarification and evidence earlier and keeps independent checks through the loop:

- The agent investigates before it asks you questions.
- Claims in `intent.md` are labeled `[verified]` or `[assumed]`.
- A fresh-context adversary reviews the spec before you approve it.
- A routine plan auto-approves after a clean adversary review; migrations, deletions, API, security, and infra changes escalate to you.
- A different verifier checks the implementation against the approved artifacts.
- Editing an approved artifact closes its gate automatically.
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

`lazymode` slides that human/auto line. `init.sh` seeds `lazymode: 1` in `.sdlc/config.md` and the agent asks you which level you want. Each level names the gates that stay human: **0** intent, spec, plan trip-wires, ship (everything as designed) · **1** (default) intent, spec, ship · **2** intent, ship · **3** intent · **4** none — the loop runs autonomously. A waived gate is auto-approved with `gates/approve.sh <stage> <artifact> --lazy` (recorded as `mode: lazy`), only after the stage's adversary review passes; approvals still record and chain hashes, and `approve.sh --lazy` refuses any gate the configured level keeps human.

When a shipped change fails, Maintain diagnoses it and writes the next `intent.md`.

## Why it is different

| Typical agent workflow | sdlc-kit |
|---|---|
| Starts coding from the first request | Explores history, code, feasibility, browser, API, or DB before grilling the user |
| Treats the user's diagnosis as truth | Marks claims `[verified: evidence]` or `[assumed: reason]` |
| Keeps the plan inside one chat | Commits `intent.md`, `spec.md`, `plan.md`, and `evidence.md` with the code |
| Author runs its own checks | A fresh-context verifier and adversary review the work without the author's context |
| Approval is a chat message that disappears | sha256 approval records bind the decision to the exact artifact bytes |
| Failed attempt becomes forgotten context | Lessons go to a bounded index; durable facts go to `DOMAIN.md` |
| One generic worker does everything | Roles map onto local QA, reviewer, browser, API, or DB specialists when available |
| "Done" is ambiguous | Every run closes as `shipped`, `abandoned`, `dead-end`, or `handed-off` |

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
agent  APPROVED: intent of claims-status (... @ a21d9c8f4b10…)
       mode: delegated-chat

       Stage 2 starts in fresh context.
```

If the approved file changes later:

```text
GATE CLOSED: intent.md was EDITED AFTER approval.
A human must re-review and re-approve it.
```

No hidden state. No vendor-specific hook required. The files are the protocol.

## What it produces

Per feature, inside the **target project**:

```text
.sdlc/
├── config.md                         # real build/test/lint/run commands
├── approvals/
│   └── <slug>.<stage>.approval       # hash · who · when · delegated mode
├── memory/
│   ├── INDEX.md                      # ≤50 lines of lesson pointers
│   ├── DOMAIN.md                     # terms · verified facts · constraints
│   └── lessons/<date>-<lesson>.md
└── work/<slug>/
    ├── intent.md                     # problem · proof · success · scope
    ├── spec.md                       # Human summary · AS-IS → TO-BE · contract
    ├── plan.md                       # files · order · risks · proof
    ├── deviations.md                 # build-time differences; plan stays locked
    ├── baseline.txt                  # brownfield behavior before the change
    ├── evidence.md                   # commands · outputs · observed behavior
    └── CLOSED                        # shipped · abandoned · dead-end · handed-off
```

`init.sh` also adds one line to the project's `.gitignore` (scratch evidence stays uncommitted) and one to its `.gitattributes` (`.sdlc/** text eol=lf`), so approval hashes agree across macOS, Linux, and Windows checkouts of the same commit.

The public sdlc-kit repository stays framework-only. Domain artifacts live and version with the project they describe.

## The safety model

### Human decisions, agent keystrokes

The human owns every gate decision. After explicit approval in chat, the agent may run:

```bash
gates/approve.sh <stage> .sdlc/work/<slug>/<artifact> --delegated
```

The approval record stays explicit. Silence and generic "continue" are not approval.

### Tamper-evident, not tamper-proof

`approve.sh` stores the artifact's sha256. `check-gate.sh` recomputes it before the next stage. A changed artifact closes the gate.

Approvals also chain: spec binds the intent bytes it was derived from, plan binds spec, ship binds plan. Editing an approved upstream file closes every downstream gate until a human re-reviews.

This detects accidental or unauthorized post-approval edits. It does not stop a malicious process from forging a file. Agent rules plus the git history of `.sdlc/approvals/` form the audit trail.

### Fresh-context review

The artifact author does not verify the work in the same context. Independent workers may run in parallel. Use one writer per checkout.

### Failed runs leave knowledge

```bash
gates/close.sh <slug> <shipped|abandoned|dead-end|handed-off> "reason"
```

An abandoned or dead-end run cannot close until a lesson exists. It records what was tried, why it failed, and what would unblock it. A handed-off close must name the external ticket or PR, so the audit trail continues outside the kit.

### Incident diagnosis starts with cheap probes

Stage 6 does not begin with a broad agent fan-out. It first checks the deployed ref, asks which control failed, tracks requested reproduction evidence, and runs the short probes in `skills/6-maintain/probes.md`.

The probes catch four common diagnosis mistakes before they reach a fix plan:

- reading a stale checkout instead of the deployed branch;
- changing one shared query without auditing every caller;
- adding a `try/catch` where the lower layer already swallows the error;
- calling a change "zero risk" without checking normal missing-data states.

When the incident cannot be reproduced, fresh-context adversaries recount the scope, prove the claimed error propagation, attack every "never" claim, and propose a rival cause. Outstanding console, network, or screenshot evidence stays visible in `status.sh` until it is received or the human waives it.

## Cockpit

```bash
gates/status.sh [slug]   # gate state + one next action
gates/stats.sh           # time per stage + re-approval counts
gates/selftest.sh        # gate, close, injection, corruption, chaining, status render, YAML integrity
```

Example:

```text
== claims-status
  intent   APPROVED (danny @ 2026-08-28T10:18:53Z · delegated)
  spec     APPROVED (danny @ 2026-08-28T10:43:30Z · delegated)
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
gates/           approve · check · close · status · stats · selftest
templates/       intent · spec · plan · evidence · lesson
docs/index.html  bilingual EN/KO landing page
```

## Verify the kit

```bash
./gates/selftest.sh
```

The selftest covers gate state, artifact edits after approval, stage-name injection, bare-path rejection, corrupt approval records, delegated approvals, lesson requirements for closing, double-close rejection, YAML frontmatter parsing, and LF line endings in every script.

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
