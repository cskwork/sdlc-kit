# v3.5.0: The board opens in the app's own window, without Chrome; tickets open in your logged-in Chrome

## Problem

The tray app showed the board in a Google Chrome `--app` window. That tied a light Rust tray to a full Chrome instance: about 330–450 MB in the user's main Chrome profile, depending on extensions. It also mixed the board into the user's own browsing windows.

## Changes

- **`todo/app/src/board.rs` (new):** the board opens in a native AppKit window with the system webview (wry 0.55, WKWebView). winit/eframe keep the run loop; the window is created on the main thread through `dispatch`.
  - Closing it hides it.
  - Its frame is saved to `todo-app-window.json` next to `todo-app.json`.
  - An Edit menu provides copy, paste, undo, select all and ⌘W.
  - When the server is replaced, the board loads the new URL in place.
  - If the webview cannot start, the app falls back to the Chrome `--app` window or the default browser and logs why.
- **`todo/app/src/ticket.rs` (new):** tickets open in the user's own Google Chrome, so the logged-in Jira session is used.
  - The window is docked at the screen's left edge at 45% width and full height. One window is reused while the selection changes.
  - It is driven through JXA (`osascript -l JavaScript`), addressed by the main Chrome process id so that automation copies of Chrome are never touched.
  - The board window never moves.
  - If Chrome is missing or the script fails, the default browser opens the ticket.
  - `install-macos.sh` adds `NSAppleEventsUsageDescription` for the one-time permission prompt.
- **README.md:** describes the app's board window and the ticket window.
- **Hardening (two reviews):**
  - **Tickets through the webview's public IPC.** In the app's window the board sends the ticket as `{open}` or `{follow}` through the webview's IPC channel, no longer as a `window.open` popup. The app accepts a message only from the board's own loopback origin, up to 8 KiB, with an http(s) ticket address.
    - `open` shows and brings forward the Chrome ticket window, recreating it if it was closed.
    - `follow` moves an open ticket window when the selection changes, without taking focus.
  - **Other links.** Every other link leaving the board is handed off once: http(s) to Chrome, `mailto:` to the system; anything else is refused. No hidden relay windows remain.
  - **Automation permission.** The app asks once for permission to control Chrome at launch. A denied permission is logged and falls back to the default browser.
  - **osascript.** Each script is limited to 8 s; a timeout opens nothing else. Queued clicks merge to the newest ticket. The script reuses the remembered window, then a window already showing the ticket, before it makes one.
  - **Processes.** `ps` lists only this user's processes, and child processes are reaped.
  - **Window frame.** The saved frame is clamped into its screen. Moving the window saves it after 0.5 s. Quit and ⌘Q save at once.

## Verification

- `cargo test --release` in `todo/app`: 24 of 24 pass, 16 of them new. `node --test tests/todo-page.test.mjs tests/todo-board.test.mjs`: 68 of 68. They cover:
  - the left-dock geometry;
  - restoring the saved frame only on a visible screen;
  - board versus ticket URL classification, including `127.0.0.1@evil`, `127.0.0.1.evil.example` and `[::1]`;
  - URL quoting in the script;
  - window reuse;
  - picking the main Chrome process.
- `cargo check --target x86_64-pc-windows-msvc` is clean. Windows keeps the browser board.
- Live run on a copy of a real list:
  - the board rendered in WKWebView with live updates;
  - the server was replaced and the board followed the new port;
  - the frame was saved on quit;
  - the ticket script reused one Chrome window at x 0 for two tickets.
- Memory (footprint): the app plus its WebKit processes came to about 226 MB, against about 330–450 MB for the Chrome `--app` path. The Node server was about 21 MB in both.
- Not verified before release: Korean typing with Enter-to-send, `<dialog>`/`popover`, and a ticket click from the board in the installed app (the IPC round trip), and the launch permission prompt. The machine locked during the GUI check, so these are checked by the user after install.
