# v2.22.0: Open a command in Terminal, typed but not run

To-do only.

## Problem

Factory alerts such as "Switch VPN to audit; type OTP in Terminal: open -a Terminal …/audit.command" asked the human to copy a command out of the card and paste it into a terminal by hand.

## Changes

- **`run <id> ["command"]`** stores a command the human runs (`  - run:` field). A human reply, `resume`, `done` or no text clears it; `list --json` and `take --json` carry `run`.
- **App:** a card with a command shows it and an **Open in Terminal** button. On macOS with zsh the button opens Terminal with the command already typed at the prompt; the human reads it and presses Enter. Nothing is typed into the terminal: a throwaway `ZDOTDIR` loads `~/.zshrc`, then `print -rz` puts the command in the line editor and the directory removes itself. (Typing it with AppleScript `do script` ran the pushed line when the shell was not ready yet.) Elsewhere the button copies the command.
- **Web, TUI:** the detail view shows the command.
- **Tests:** a core test covers the field, its events and every way it clears.
