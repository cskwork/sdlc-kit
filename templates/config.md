# sdlc config — the project values the kit reads, one `key: value` per line.
# Fill the commands from the repository (package scripts, Makefile, CI) and run
# each once. Leave a value empty when the project has none.
kit: <path to the kit>
build:
test:
lint:
# start the app for end-to-end scenarios, and the project's own e2e command
run:
e2e:
# how QA drives the interface: a browser driver, an HTTP client, the shell; empty = whatever the agent has
qa:
# gates a human approves: intent, plan. Plan also needs the human when PLAN.md raises a risk flag.
human_gates: intent
# durable knowledge: scouts read it first, Evidence adds verified facts to it
knowledge: .sdlc/knowledge
