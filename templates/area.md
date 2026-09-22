# Area: <the area as users name it — for a web app the menu path, e.g. 학습 > 평가 > 제출>

<!-- One page per product area, at .sdlc/memory/areas/<area-slug>.md (ASCII
     kebab-case file name; the human name lives on the Menu line). For a web
     app an area is one menu — split a page when its sub-screens carry
     different rules or it passes ~60 lines. Other software: a module, API,
     job, or CLI command. This is the page a person or an agent opens to learn
     what the area does and which business rules hold.
     ONE writer: the close merge (AGENTS.md rule 4). Plain language a
     non-developer can read; code identifiers only on the Where line. -->

- Menu: <the path as users see it; unique across pages, no commas — summary.md's Area line must read the same>
- Where: <URL / route · entry point file:symbol · API endpoint · job name>
- Aliases: <other words people search with — screen title, ticket wording, other language>

## Business rules (정책)
<!-- The product's rules for this area, one testable sentence each:
       - P1: <rule> — source: <기획서 / ticket / human, date> · set by <slug> · [verified: how — YYYY-MM-DD]
     P-numbers are permanent. The close merge gives a new rule the next number
     this page has never used (retired ones count), edits a changed rule in
     place with its new source, and keeps a retired one struck through:
       - ~~P3: <rule>~~ — retired YYYY-MM-DD by <slug>: <why>
     Not POLICY.md — that file holds the human's rules for agents. -->

## How it works
<!-- ≤10 lines: what the user does, step by step, what the system does in
     response, and facts that hold for this area only. Use DOMAIN.md terms;
     do not redefine them here. -->

## History
<!-- Newest first; one line per shipped feature that changed this area:
       - YYYY-MM-DD <slug> — <what changed for the user, from its summary.md> -->
