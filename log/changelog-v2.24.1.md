# v2.24.1: No temp-file deletions on the hot paths

## Problem

On a machine where every file deletion took 5.4 s, `sdlc.sh status` took 18 to 48 s while using 0.18 s of CPU, and one to-do write took 14 to 22 s. The to-do CLI runs `status` for every open item, so with 41 open items each call ran for minutes and callers with a 20 s limit failed. Creating a file, renaming to a new name, `mkdir` and `rmdir` were not delayed; deleting a regular file always was.

Two things in the kit deleted files on every call:

- `sdlc.sh` read its state with here-strings (`read ... <<< "$x"`). bash 3.2, the macOS `/bin/bash`, writes each here-string to a temp file and deletes it. `status` ran eight.
- Every to-do write made and deleted two marker files, then deleted the lock file.

## Changes

- **`sdlc.sh`:** the nine here-strings read from `< <(printf '%s\n' ...)`, which sends the same bytes through a pipe. Output is unchanged. On that machine `status` went from 18–48 s to about 1.7 s.
- **To-do lock markers:** a marker is now an empty directory (`mkdir`/`rmdir`) instead of an empty file. A marker left by an older kit is a file and is still removed. A write went from about 22 s to about 11 s there; the two deletions left are the lock file and the atomic replace of `todo.md`.
- **Selftest:** fails if `sdlc.sh` contains a here-string. A to-do test checks that the commit marker held during a save is a directory.

## Upgrade

Restart a running to-do app (`todo.mjs serve`) after upgrading. An older process that finds a directory marker left by a newer process that died cannot remove it.
