# Area: <menu path>

<!-- One page per product area, at .sdlc/memory/areas/<file name>.md. The file
     name is the Menu line with each " > " written as " - ", and any of
     / \ : * ? " < > | replaced with "-":
       Menu 교사 > 학생 > 학급 분석 → memory/areas/교사 - 학생 - 학급 분석.md
     For a web app an area is one menu — split a page when its sub-screens
     carry different rules or it passes ~60 lines. Other software: a module,
     API, job, or CLI command. ONE writer: the close merge (AGENTS.md rule 4).
     READER FIRST: everything above the evidence block is for a non-developer
     — plain sentences, no source, no code. Every source, date, verification,
     and code identifier goes in the evidence block at the bottom, one row per
     rule or figure.
     TABLES: rules, figures, history and evidence are one table row each. The
     header words are free (a store may write | # | 정책 |); kb.sh reads only
     the row shapes. Write a literal "|" inside a cell as "\|". -->

- Menu: <menu path as users see it; no commas>
- Aliases: <other words people search with>

<!-- Menu is unique across pages and reads exactly as summary.md's Area line.
     Aliases: screen title, ticket wording, other language. -->

## Business rules (정책)
<!-- One row per rule, one plain testable sentence, nothing else in the row.
     Its source goes in its evidence row below. P-numbers are permanent: the
     close merge gives a new rule the next number this page has never used
     (retired ones count), edits a changed rule in place (and its evidence
     row), and keeps a retired one struck through:
       | ~~P3~~ | ~~<rule>~~ |
     with the reason in its evidence row's Source cell:
       | P3 | retired YYYY-MM-DD by <slug>: <why> | … | … |
     Not POLICY.md — that file holds the human's rules for agents. -->
| # | Rule |
|---|---|
| P1 | <rule in one plain sentence — no source, no code> |

## Numbers (통계 산정)
<!-- Only for an area that shows counts, rates, scores or charts; delete the
     section otherwise. One row per figure, named as the screen labels it.
     N-numbers follow the P-number rules above: permanent, a changed figure is
     edited in place, a retired one is kept struck through with the reason in
     its evidence row. The batch job's name goes in the evidence row. -->
| # | Label on screen | What is counted | Out of | Timing |
|---|---|---|---|---|
| N1 | <label> | <what is counted> | <out of what, or —> | <real-time \| batch: refreshed <when>, data up to <when>> |

## How it works
<!-- ≤10 plain bullets: what the user does, step by step, what the system does
     in response, and facts that hold for this area only. Use DOMAIN.md terms;
     do not redefine them here. -->
- <step or fact, in plain words>

## History
<!-- Newest first; one row per shipped feature that changed this area, from
     its summary.md. -->
| Date | Feature | What changed for the user |
|---|---|---|
| YYYY-MM-DD | <slug> | <…> |

<!-- In a store with `index_style: obsidian` write this block as a folded
     callout instead, every line prefixed "> ":
       > [!info]- 근거 · 코드 위치 (개발자용)
       > - Where: <…>
       >
       > | # | Source | Set by | Verified |
       > |---|---|---|---|
       > | P1 | … | … | … | -->
<details>
<summary>근거 · 코드 위치 (개발자용)</summary>

- Where: <route · file:symbol · endpoint · job>

| # | Source | Set by | Verified |
|---|---|---|---|
| P1 | <기획서 / ticket / human / code, date> | <slug> | <how — YYYY-MM-DD> |
| N1 | <…> | <slug> | <how — YYYY-MM-DD> |

</details>
