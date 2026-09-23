# Area: <menu path>

<!-- One page per product area, at .sdlc/memory/areas/<file name>.md. The file
     name is the Menu line with each " > " written as " - ", and any of
     / \ : * ? " < > | replaced with "-":
       Menu 교사 > 학생 > 학급 분석 → memory/areas/교사 - 학생 - 학급 분석.md
     For a web app an area is one menu — split a page when its sub-screens
     carry different rules or it passes ~60 lines. Other software: a module,
     API, job, or CLI command. ONE writer: the close merge (AGENTS.md rule 4).
     READER FIRST: everything above <details> is for a non-developer — plain
     sentences, no source, no code. Every source, date, verification, and code
     identifier goes in the <details> block at the bottom, one evidence line
     per rule or figure. -->

- Menu: <menu path as users see it; no commas>
- Aliases: <other words people search with>

<!-- Menu is unique across pages and reads exactly as summary.md's Area line.
     Aliases: screen title, ticket wording, other language. -->

## Business rules (정책)
<!-- The product's rules for this area, one plain sentence each, testable,
     nothing else on the line. Its source goes on its evidence line below.
     P-numbers are permanent. The close merge gives a new rule the next number
     this page has never used (retired ones count), edits a changed rule in
     place (and its evidence line), and keeps a retired one struck through:
       - ~~P3: <rule>~~
     with the reason on its evidence line:
       - P3 — retired YYYY-MM-DD by <slug>: <why> · source: <…>
     Not POLICY.md — that file holds the human's rules for agents. -->
- P1: <rule in one plain sentence — no source, no code>

## Numbers (통계 산정)
<!-- Only for an area that shows counts, rates, scores or charts; delete the
     section otherwise. One line per figure, named as the screen labels it.
     N-numbers follow the P-number rules above: permanent, a changed figure is
     edited in place, a retired one is kept struck through with the reason on
     its evidence line. The batch job's name goes on the evidence line. -->
- N1: <label on screen> — <what is counted> / <out of what> · <real-time | batch: refreshed <when>, data up to <when>>

## How it works
<!-- What the user does, step by step, what the system does in response, and
     facts that hold for this area only. Use DOMAIN.md terms; do not redefine
     them here. -->
<≤10 plain lines>

## History
<!-- Newest first; one line per shipped feature that changed this area, from
     its summary.md. -->
- YYYY-MM-DD <slug> — <what changed for the user>

<!-- In a store with `index_style: obsidian` write this block as a folded
     callout instead, every line prefixed "> ":
       > [!info]- 근거 · 코드 위치 (개발자용)
       > - Where: <…>
       > - P1 — source: … · set by … · [verified: …] -->
<details>
<summary>근거 · 코드 위치 (개발자용)</summary>

- Where: <route · file:symbol · endpoint · job>
- P1 — source: <기획서 / ticket / human / code, date> · set by <slug> · [verified: how — YYYY-MM-DD]
- N1 — source: … · set by … · [verified: …]

</details>
