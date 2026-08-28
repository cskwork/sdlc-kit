# sdlc-kit

Portable, harness-neutral AI-native SDLC, adapted from [Anthropic's AI-Native
SDLC playbook](https://claude.com/blog/the-ai-native-sdlc-playbook). Works with
pi, Claude Code, Codex CLI, Gemini CLI, Cursor — anything that can read files
and run shell commands.

**Core ideas** (all from the playbook, made harness-neutral):

- Artifact loop: `intent.md → spec.md → plan.md → code → evidence.md → new intent.md`
- Human approval gates between stages, tamper-evident (sha256 catches post-approval
  edits; forgery is held off by agent rules + git history of `.sdlc/approvals/`)
- Intent stage *grills* the user and demands proof — users can be mistaken
- Fresh-context adversarial reviewer + verifier at every stage boundary
- Mistakes recorded once in bounded memory, never repeated, promoted into skills
- Hooks/CLAUDE.md replaced by shell gates + a routing AGENTS.md any harness reads

## Install

```bash
git clone <this-repo> ~/sdlc-kit
```

Per project (greenfield or brownfield):

```bash
cd /path/to/project
~/sdlc-kit/init.sh          # seeds .sdlc/ (work, approvals, memory, config)
$EDITOR .sdlc/config.md     # fill in real build/test/lint commands
```

Point your harness at the routing contract (pick one):

| Harness     | How |
|-------------|-----|
| pi          | `ln -s ~/sdlc-kit/AGENTS.md .sdlc/SDLC.md` and tell pi "run the SDLC in .sdlc/SDLC.md", or add a pointer line to your project AGENTS.md |
| Claude Code | Add to project `CLAUDE.md`: `For SDLC work, read ~/sdlc-kit/AGENTS.md and follow it.` |
| Codex CLI   | Same one-liner in project `AGENTS.md` |
| Gemini CLI  | Same one-liner in `GEMINI.md` |
| Anything    | Paste `AGENTS.md` into the session; the contract is files + scripts, not harness features |

## Use

```
you:   "Start SDLC for <feature idea>"
agent: reads skills/1-intent/SKILL.md, grills you, writes .sdlc/work/<feature>/intent.md
you:   review, then:  ~/sdlc-kit/gates/approve.sh intent .sdlc/work/<feature>/intent.md
agent: spec → you approve → plan → you approve → build → evidence → ship gate → done
```

The agent checks gates itself and stops when one is closed. You approve; it moves.

## Layout

```
AGENTS.md        routing contract (the file every harness reads)
init.sh          seed .sdlc/ into a target project
skills/1-6       one skill per stage
roles/           verifier, adversary, researcher — fresh-context briefs
gates/           approve.sh (human), check-gate.sh (agent), selftest.sh
templates/       intent / spec / plan / evidence / lesson
```

## Verify the kit itself

```bash
gates/selftest.sh   # approve→open, tamper→closed
```
