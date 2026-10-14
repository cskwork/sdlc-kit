# sdlc config — the project values the kit reads, one `key: value` per line.
# Fill the commands from the repository (package scripts, Makefile, CI) and run
# each once. Leave a value empty when the project has none.
kit: <path to the kit>
build:
test:
lint:
# start the app for end-to-end scenarios (QA runs it detached, outliving the run), and the project's own e2e command
run:
e2e:
# how QA drives the interface: a browser driver, an HTTP client, the shell; empty = whatever the agent has
qa:
# optional scenario runner adapter in the kit's adapters/ folder (e2e); empty = scripts in logs/scripts/
qa_runner:
# command that signs in for QA where the runner cannot (popup, SSO) and writes the session file it injects; empty = none
qa_session:
# gates a human approves: intent, plan. Plan also needs the human when PLAN.md raises a risk flag.
human_gates: intent
# durable knowledge: scouts read it first, Evidence adds verified facts to it
knowledge: .sdlc/knowledge
# repositories a review PASS binds: top folders, separated by spaces or commas, of repositories under the project root (relative, no spaces in a path), "." for the repository holding the root; empty = every repository under the root; review --repos replaces it for one review
repos:
