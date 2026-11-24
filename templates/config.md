# sdlc config — the project values the kit reads, one `key: value` per line.
# Fill the commands from the repository (package scripts, Makefile, CI) and run
# each once. Leave a value empty when the project has none.
kit: <path to the kit>
build:
test:
lint:
# start the app for end-to-end scenarios (QA runs it detached), and the project's e2e command
run:
e2e:
# how QA drives the interface (browser driver, HTTP client, shell); empty = whatever the agent has
qa:
# optional scenario runner in the kit's adapters/ (e2e); empty = scripts in logs/scripts/
qa_runner:
# command that signs in for QA where the runner cannot (popup, SSO), writing the session file it injects
qa_session:
# gates a human approves: intent, plan (a plan raising a risk flag always needs the human)
human_gates: intent
# durable memory: scouts read it first, Evidence adds verified facts to it
memory: .sdlc/memory
# repositories a review PASS binds: top folders relative to the project root, no spaces, space- or comma-separated ("." = the root's); empty = all; review --repos replaces it once
repos:
