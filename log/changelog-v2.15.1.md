# v2.15.1: The to-do app installs into ~/Applications on macOS

Follow-up to v2.15.0. To-do app and docs only; the sdlc loop and the to-do file format are unchanged.

## Problem

On 2026-11-02 the v2.15.0 app could start only from `todo.mjs` or its build folder. Finder, Spotlight and Login Items start an app with no arguments and no shell `PATH`, so a copied binary could not find the kit or node.

## Changes

- **`todo/app/install-macos.sh [DIR]`** builds the app and writes `sdlc To-do.app` (default `~/Applications`, name via `SDLC_TODO_APP_NAME`). Its Info.plist `LSEnvironment` records `SDLC_TODO_KIT`, `SDLC_TODO_NODE`, `SDLC_TODO_LANG` and, when set, `SDLC_TODO`; the script re-registers the bundle so a changed environment takes effect.
- **The app reads `SDLC_TODO_KIT` and `SDLC_TODO_NODE`** when no `--kit`/`--node` is given, before falling back to its build folder and `node` on `PATH`.
- **Docs:** README and `docs/architecture.md` describe the app, the shared server file and the optional Rust build.

## Validation

- macOS local: `install-macos.sh /tmp/todo-apps` with `SDLC_TODO_LANG=ko`; `plutil -lint` OK; `open` on the bundle started the app, which reached the to-do server and showed Korean.
- `bash -n todo/app/install-macos.sh`; `node --test tests/todo*.test.mjs` unchanged.
