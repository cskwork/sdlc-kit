# v3.8.0: One to-do app for macOS and Windows, on Tauri 2, with the server inside it

## Problem

- **Two screens, one of them macOS only.** The tray app carried its own renderer (egui) for a list window, and the web board in a second window that existed only on macOS. Windows opened the board in a browser. The two screens showed different things: memos and text size only in one, the board only in the other.
- **Memory.** The app held a renderer, fonts and a `node` server: 77 MB with no board open. Closing the board kept its webview.
- **Server.** The app started `node todo.mjs serve` as a child and killed it on Quit, so the session file stayed behind.
- **Delete did nothing in the app.** A macOS webview shows no `confirm()` and answers it with no, so the list's delete button had no effect.
- **Fix by agent hid its failure.** When the agent did not start, the success toast covered the notice for 4 seconds.

## Changes

- **App (`todo/app`).** Tauri 2.11 (Rust 1.88) instead of eframe and wry.
  - One window shows the web page in the system webview (WKWebView, WebView2) on macOS and Windows.
  - Open list is the same window on the List view.
  - Closing the window frees its webview unless something is unsent; then it only hides.
  - A second launch for the same list brings the running app forward.
  - While no server answers, a small page says why and opens the board as soon as one does.
  - The window's place and the files `todo-app.json` and `todo-app-window.json` carry over.
- **Server (`todo/app/server`, new).** The list and its web API in Rust, run inside the app when no server answers.
  - **It ends with the app:** a browser tab on it goes offline on Quit.
  - **Node 18+ is still needed** for the CLI, the TUI, `web` and `serve`, and by the app for the few inputs JavaScript alone answers exactly (unusual links or dates, broken status output).
  - Both servers use the same file, lock and version hashes. `sdlc-todo-serve` runs the Rust one without a window, for tests.
- **Security.** The page may call five commands of the app, from its own server's origin only. The window never leaves that origin; only http(s) and `mailto:` links go out. The session token is cut from errors and logs.
- **Moved from the old list window to the page:**
  - your memo, text size and font (in the app only; nothing reaches the list or an agent);
  - Open in Terminal (macOS; elsewhere Copy command);
  - what each choice does, "Once you answer", the brief's phase, "Yours to decide" and "AI suggestion ready";
  - other tickets named in a question, and how many agents work now.
- **Dropped with it:**
  - the queue order with decisions lacking a recommendation first and blocks among them (the board pages your turn column by column);
  - the separate list window;
  - the "No agent is working right now" line;
  - the six-step phase stepper (the column and a tag show the phase);
  - one-click pinned settings (a pinned card is opened first).
- **Pretendard is no longer bundled.** The page uses it when it is installed, else the system's Hangul font.
- **Delete** asks in the page's own dialog: focus starts on Cancel, Esc cancels, and a key held or pressed as it opens answers nothing.
- **Fix by agent** shows one notice, and no success toast, when the request was recorded but the agent did not start.
- **Tickets on Windows** open in the default browser and do not follow the selection.
- **CI.** The app is tested and built on macOS and Windows; the server crate on all three systems.
- **Phones.** The code has Tauri's mobile layout, but no mobile target is built and nothing listens beyond `127.0.0.1`. The README lists what must be decided first.

## Verification

- `cargo test --release`: app 34 of 34, server 20 of 20. The to-do node tests pass against the Node server; against the Rust server two tests failed once on a loaded machine (load 12–15) and passed on two re-runs.
- An independent review of the app found eight faults (memo keystrokes lost on close, an unsent rename lost, a crash when no page had come up, and others); all are fixed.
- Real runs on macOS with a fixture list of 68 items: tray open and quit, reopening, a server replaced under the running app, the offline page and recovery, a memo, text size, a reply, a draft kept on close, the typed Terminal command, a ticket opened and followed in Chrome, dark (theme forced) and narrow windows, and a delete confirmed, cancelled with Esc and cancelled with Enter on Cancel.
- Footprint with every WebKit process and the server, 20 s after start:

| | v3.7.3 | v3.8.0 |
|---|---|---|
| Board open | 144 MB | 91 MB |
| Board closed for 20 s | 136 MB | 50 MB |
| Started in the tray, board never opened | 77 MB | 14 MB |

- Binary: 6.0 MB before, 6.5 MB after, with the server inside.
- **Windows: built and tested in CI only; not used on a real PC by us.** Also not checked by hand: Korean typing through a real input method in the new window, how a notification looks, a physical click on the tray icon (its menu was used), Linux.
