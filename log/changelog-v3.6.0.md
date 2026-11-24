# v3.6.0: Run a command an agent left for you, from the board, after you confirm it

## Problem

Some waits need an action that agents are not allowed to take, such as deleting a build folder outside temp space or stopping a server. Until now the board only showed the instruction as text, so the person had to leave the board, type the command in a terminal, then come back and answer.

## Changes

- **`exec` field (`todo/core.mjs`, `todo/todo.mjs`).** An item can carry `  - exec: {"argv":[…],"cwd":"/abs","why":"…"}`, set with `todo.mjs exec <id> --json '…'` and cleared with `--clear`. It sits beside the terminal `run` field (VPN OTP), which is unchanged.
  - An item with `exec` is the person's turn.
- **Confirm dialog (`todo/page/*`).** The board panel and the list page show the exact command, its working folder and the program it resolves to. Pressing "명령 실행" (X) opens a dialog.
  - Control, bidi and zero-width characters are shown escaped (`$'…'`) with a warning.
  - The dialog shows the argument count.
  - Long commands need "전체 보기" before they can run.
  - Focus starts on the title; a held or early Enter never confirms.
- **`POST /api/exec` (`todo/web.mjs`).**
  - It runs the program with `spawn` in its own process group, with no shell.
  - Limits: a 300 s timeout (TERM, then KILL to the group) and 64 KB output tails.
  - The program is resolved with the login shell's PATH and must match the one shown.
  - It is bound to the item version through a start event written under the lock, so a second tab or server gets 409, and a run cut off by a server stop is marked interrupted.
  - The result goes to the item that started it: fields changed during the run are kept.
  - It records `execResult` (a structured outcome for machines) and logs to `~/.sdlc/todo-runs.log` (0600).
  - On exit 0 it adds a reply `실행함: … → exit 0 · 출력: "…"` and clears the wait. A failure keeps the wait.
- **Event lines** escape CR, LF, U+0085, U+2028 and U+2029, so no command text can forge a todo.md line.
- **Result write under load.** If the lock is busy when a run finishes, the server retries for up to 30 s, then keeps the result in memory and writes it on the next request or keepalive. A run counts as live only in this server's running set, or by the server nonce in its start event plus an age bound, so a reused pid never revives it.
- **`execPath` in JSON.** `list`, `next`, `take --json` and `/api/items` expose the resolved program path; `''` means not runnable.
- **Windows.** Board runs are not supported yet: the Run button is off, the reason is shown, `execPath` is `''` and `/api/exec` answers 409.

## Verification

- New tests:
  - core/CLI: 6;
  - API: 7, covering timeout and group kill, output caps, start errors, concurrency and interruption, and PATH;
  - page: the dialog, escapes, Enter and the missing program.
- All page, board and i18n tests pass: 84 of 84.
- Full node suites: the remaining failures are the same load-related HTTP and lock timeouts that also fail on v3.5.0.
- A headless browser check on a copy of a real list covered:
  - a newline command and a bidi command, both shown escaped with a warning;
  - a confirmed run that created its folder and wrote `execResult` and the reply.
- Two independent security reviews ran; all findings are fixed.
- CI on 7e82ff5: macOS and Ubuntu passed. The release did not wait for the Windows job.
