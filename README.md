<div align="center">

# sdlc-kit

### Stop letting coding agents mark their own homework.

**A portable four-phase SDLC for AI coding agents, in any codebase and any domain.**

Intent → Plan → Build → Evidence. Parallel scouts before code, an adversarial reviewer after it, and a scored, routed proof at the end.

[![Release](https://img.shields.io/github/v/release/cskwork/sdlc-kit?style=flat-square&color=C79A55)](https://github.com/cskwork/sdlc-kit/releases/latest)
[![GitHub Pages](https://img.shields.io/badge/live_site-open-C79A55?style=flat-square)](https://cskwork.github.io/sdlc-kit/)
[![Harness neutral](https://img.shields.io/badge/harness-pi_%C2%B7_Claude_Code_%C2%B7_Codex_%C2%B7_Gemini-24211E?style=flat-square)](#quick-start)

[**See the live site**](https://cskwork.github.io/sdlc-kit/) · [**Quick start**](#quick-start) · [**Read the contract**](SKILL.md) · [**한국어**](README.ko.md)

</div>

---

Coding is fast now. **Being wrong is still expensive.** An agent that starts by
writing code finds the side effects last, and an agent that checks its own work
finds few. sdlc-kit puts understanding first and independent proof last, and
keeps everything in between small.

It is adapted from [Anthropic's AI-Native SDLC playbook](https://claude.com/blog/the-ai-native-sdlc-playbook)
and needs no particular harness: it is Markdown plus one shell script.

> sdlc-kit is an independent project and is not affiliated with Anthropic.

## The loop

```mermaid
flowchart LR
  I["1 Intent"] -->|you approve| P["2 Plan"]
  P -. gap found .-> P
  P -->|plan approved| B["3 Build"]
  B -. FAIL: fix, re-review .-> B
  B -->|review PASS| E["4 Evidence"]
  E -. plan was wrong, or same failure twice .-> P
  E -. code failed .-> B
  E -->|every must passes, 95%+ overall| D(["deliver"])
  E -->|no environment to run it| H(["you decide"])
```

| Phase | What happens | Goes back when |
|---|---|---|
| **1 Intent** | What you asked, what the agent understood, and the risks in it, scored for clarity across six areas. Below 90% the agent explores, reproduces the bug, researches the spec or asks the requester on the ticket, issue or pull request. You confirm it. | — |
| **2 Plan** | Parallel scouts map source of truth, data, logic and user flow into `refs/`; one `PLAN.md` holds AS-IS → TO-BE, side effects and the scenarios QA will run. | the gap check finds holes |
| **3 Build** | The smallest complete change, committed, then a separate adversarial reviewer. | the review FAILs: fix it, review again |
| **4 Evidence** | Real checks, then every scenario as its persona through the real interface. `sdlc.sh score` scores and routes it; the agent does not judge. | the plan was wrong or the same failure came twice → Plan; code failed → Build |

Every way back is capped at three — three review FAILs, three returns to Plan,
three to Build — then the loop stops for you, and only
`sdlc.sh approve plan --human` resumes it. A scenario that could not run counts
as failed, only you can remove a scenario, and every PASS needs its log.

## Quick start

```bash
# 1. Install once, and link it where your agent finds skills
git clone https://github.com/cskwork/sdlc-kit ~/sdlc-kit
ln -s ~/sdlc-kit ~/.claude/skills/sdlc-kit      # Claude Code; use your harness's skills folder

# 2. Seed a project (or one shipping unit of a monorepo)
cd /path/to/your-project
~/sdlc-kit/sdlc.sh init
$EDITOR .sdlc/config.md                          # build, test, lint, run, e2e, qa
```

Without a skills folder, add `For SDLC work, read ~/sdlc-kit/SKILL.md and
follow it.` to the harness's instruction file (`AGENTS.md`, `CLAUDE.md`,
`GEMINI.md`). Then ask for a change in plain words — "add CSV export",
"fix the login redirect" — and the agent runs the loop. `sdlc.sh next <slug>`
always says what comes next.

## What one feature leaves behind

```
.sdlc/work/<slug>/
  intent.md     what was asked, understood, risked, and how clear it is
  refs/         scout findings and the intent check: source.md data.md logic.md flow.md learnings.md intent-check.md
  PLAN.md       one page: understanding, AS-IS → TO-BE, side effects, changes, scenarios
  review.md     reviewer rounds, each ending in VERDICT
  evidence.md   checks, one result row per scenario, delivery
  logs/         raw output behind every PASS and FAIL; scripts/ re-runs each scenario
```

Closed features move to `.sdlc/archive/`. Verified facts move to the
`knowledge` folder, which the next feature's scouts read first.

## Config

`.sdlc/config.md` is the only project-specific file: the `build`, `test`,
`lint`, `run` and `e2e` commands, the `qa` tool that drives screens or APIs,
an optional `qa_runner` adapter with its `qa_session` sign-in command,
`human_gates` (default `intent`; add `plan` to approve every plan yourself — a
plan with a risk flag always asks), the `knowledge` folder, and `repos` (the
repositories a review binds — list them when the project root holds many,
or name them per review with `sdlc.sh review <slug> pass --repos "<path> ..." "<note>"`;
empty means every one under it). `.sdlc/` stays
out of git through `.git/info/exclude`; point `knowledge:` at a tracked folder
to share what the team learns.

`adapters/e2e/` is one such runner: with `qa_runner: e2e`, QA writes each
browser or mobile scenario as an [e2e](https://www.npmjs.com/package/e2e)
test with a deterministic layer (the evidence, no model) and an optional
agent layer that replays without model calls on later rounds. The kit
vendors e2e's agent guide (Apache-2.0, pinned) so it works offline;
`adapters/e2e/update.sh [version]` refreshes it.

## Rules that never relax

- **Authority is not a gate.** Data loss, migrations, public API changes,
  security-sensitive code, infra changes, push, merge or deploy, and a
  comment posted on a ticket need your prior words at every setting.
- **Independent eyes.** Scouts, reviewer and QA run in fresh contexts, never
  in the one that wrote the work.
- **Proof, not claims.** No environment means BLOCKED, never PASS. A bug fix
  needs a test that failed before the fix.
- **Delivered means what was verified.** `close` refuses a delivered tree that
  differs from the verified commit.

Build follows the [ponytail](https://github.com/DietrichGebert/ponytail) approach — the
smallest complete change — with the rules written into the phase file, so no
other skill is needed.

## Drive it from a host

`sdlc.sh status --json` lists every feature with its phase, state, score and
route. `sdlc.sh next <slug>` exits `0` ready, `10` needs a human, `20`
blocked, `30` done. The scripts record and report; they never run a model. An
unattended run delivers no further than your recorded words allow — a local
commit unless you said more. Windows: run `sdlc.sh` in Git Bash or WSL.

## Upgrading from v0.x

v2 is a new contract. Your records stay where they are.

- Features started under v0 show as `legacy` in `sdlc.sh status`. Finish them
  with the old kit (`git -C ~/sdlc-kit checkout v0.27.0`) or close them:
  `sdlc.sh close <slug> dropped "<reason>"`.
- `lazymode` keeps working: 0–1 → `human_gates: intent plan`, 2–3 → `intent`,
  4 → none. Write `human_gates:` to choose explicitly; a word other than
  `intent` or `plan` means both.
- `.sdlc/memory/` is read as the knowledge folder until you set `knowledge:`.
- `init.sh` → `sdlc.sh init`; `gates/status.sh --json` and `tools/auto.sh
  next` → `sdlc.sh status --json` and `sdlc.sh next` (same exit codes).
  spec.md, summary.md, delivery.md, qa-guide.md, map.md, harvest, verification
  receipts, handoff, tripwire, refcheck and the QA-mode switch are gone: their
  jobs live in PLAN.md, evidence.md, `sdlc.sh close` and config `qa:`.

Why: [v2.0.0 changelog](log/changelog-v2.0.0.md).

## Verify the kit

```bash
bash tests/selftest.sh
```

Word budgets for every prompt, the gate and routing rules, and one real
feature driven through all four phases on a small CLI fixture. CI runs it on
Linux, macOS and Windows.

## License

MIT
