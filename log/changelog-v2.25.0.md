# v2.25.0: The app reads like a book, one decision at a time

To-do app (`todo/app`) only. The web page, the TUI, the server and `todo.md` are unchanged.

## Problem

The **Needs you** tab opened every waiting item at once. With 16 items waiting, 16 full cards shared one scroll, each with a status pill, the six-phase stepper, a "now · next" line and the repos. Five count pills sat over four tabs that said the same thing. The one thing each card exists for, what the human has to decide, did not stand out from the rest, and a choice was a bare label: what each option does was only in the folded document.

## Changes

- **One decision at a time.** The Needs-you tab shows a single decision. Its page number (`3 / 16`) with previous/next arrows sits at the foot of the window, outside the scrolling area, like a book's page number; the left/right arrow keys turn the page unless a field is being typed in. Answering brings up the decision now at that place; a newly arrived decision does not move the one on screen. The others fold under **Other decisions**, one line each.
- **What only you can decide comes first.** Gate approvals, blocks and questions with no agent-recommended answer lead the queue and are marked **Yours to decide**; a question with a recommended answer is marked **AI suggestion ready**. Decisions for one ticket stay together, the one offering choices first.
- **A book-like page.** Paper tones in light and dark, a page with wide margins, roomier line spacing and no bullet dots. On a wide window (960 points or more) a decision opens as a two-page spread: the left page is what to read (the question, the situation, what happens once you answer, why, the agent's pick), the right page, **Your answer**, is how to answer (the choices with what each does, the answer field, approve, fix, tickets, memo, **More**). A narrower window shows both on one page in a centred column of at most 760 points; the spread is at most 1240 points wide. List tabs run in two columns on a wide window. The window opens at 600×820.
- **A fuller brief.** A leading `(AS-IS):` or `(TO-BE):` tag is dropped, repeated lines show once, brief lines are cut at 320 characters instead of 160, and the agent's pick has its own box.
- **Choices say what they do.** When the document has an `## Options` (or `## 선택지`) section with one numbered line per choice (`1. **label** — what it does`), each choice button is stacked over the line whose label matches it; a list that does not match the choices one to one shows nothing rather than mislabel them.
- **Less on screen.** Tabs carry the counts and the five count pills are gone; the connection is a dot, with words only when it is not live; the phase stepper, the repos and the whole document are under **More**; help lines became hover text. The other tabs list one line per item and open on a click; a decision's line leads to the Needs-you tab.
- **Memo.** Each open item has a memo of your own. Memos are never sent to agents or written to `todo.md`. The approval note field is now labelled **Words for the approval (optional)** so it is not confused with the memo.
- **Text size and font.** The header's **Aa** button opens the size (5% steps, 80–200%, default 115%; Cmd/Ctrl with `+`/`-` is kept as well) and the font. Pretendard Regular (SIL OFL 1.1, licence in `todo/app/fonts/Pretendard-LICENSE.txt`) is built into the binary as the default. Other readable Hangul fonts found on the machine can be picked: Apple SD Gothic Neo, Malgun Gothic, Noto Sans CJK/KR, NanumGothic, NanumSquare, Spoqa Han Sans Neo, SUIT, AppleGothic, AppleMyungjo and NanumMyeongjo. Malgun Gothic is not bundled: it is Microsoft's and can be picked only where it is installed.
- **`todo-app.json`**, beside the session file (mode 0600), keeps the size, the font and the memos. It is saved through a temporary file, and a file that cannot be read or does not parse is set aside as `todo-app.json.bad` and reported rather than overwritten. Memos of done items are dropped.
- **Tests.** `cargo test` in `todo/app` covers the queue order, where the focus lands after an answer, the option lines (matched to choices by label, not position), the tag removal and the settings file. The Rust app is not built in CI.

## After updating

Rebuild the app: run `todo/app/install-macos.sh` again (macOS), or `cargo build --release` in `todo/app`.
