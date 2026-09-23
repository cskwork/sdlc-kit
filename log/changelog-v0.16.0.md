# v0.16.0 — area pages: figures, menu-path file names, reader-first layout

v0.15.0 gave a product area one home for its business rules (P-numbers). A
menu that shows counts, rates, scores or charts had nowhere to say what a
number on screen actually means — "what is counted, out of what, real-time
or batch" lived in someone's head or nowhere. This release adds an optional
Numbers section to the area page, numbered N1… with the same permanence and
filing rules as a business rule. It also names each area page by its menu
path, so the file list reads like the product's menus, and lays the page out
reader first: plain language on top for a non-developer, every source,
verification, and code location folded into an evidence block at the
bottom, with rules, figures, history and evidence as markdown tables. Gates,
approvals, and the `--json` schema are unchanged; `kb.sh`'s rule count still
counts only live rules (a `| P<n> |` row, or an older `- P<n>:` line).

## Changes

- **`templates/area.md`** gains an optional **Numbers (통계 산정)** section
  between Business rules and How it works: one row per on-screen figure,
  named as the screen labels it, recording what it counts, out of what,
  whether it is real-time or batch (job, refresh, data-as-of), its source,
  and who set it. Delete the section for an area with no figures. N-numbers
  follow the P-number rules: permanent, a changed figure is edited in place,
  a retired one stays struck through.
- **The loop treats a figure like a business rule** wherever omitting it
  would leave it unprotected:
  - `templates/spec.md`'s "Business rules touched" section gains a sibling
    line for numbers touched (kept/changed/new), so the Side effects
    verifier re-checks a figure it did not set out to change, the same way
    it already re-checks a P-number.
  - Ship's retrospective (`skills/5-ship/SKILL.md`) writes a figure a
    feature sets, changes, or retires as an area candidate, same as a
    business rule.
  - `templates/harvest.md`'s Area candidates format gains the `N<n>`
    line shape the close merge numbers, next to the existing `P<n>` one.
  - AGENTS.md rule 4's "what goes where" table gains a row: a figure's
    calculation method files to the area page's Numbers, written by the
    close merge on a shipped close only — same as a business rule.
- **An area page is named by its menu path.** The file name is the Menu
  line with each ` > ` written ` - `, and any character a Windows or macOS
  file name may not hold (`/ \ : * ? " < > |`) replaced with `-`: Menu
  `교사 > 학생 > 학급 분석` → `memory/areas/교사 - 학생 - 학급 분석.md`. The
  "ASCII kebab-case file name" instruction is gone from `templates/area.md`,
  AGENTS.md rule 4, the READMEs, and `init.sh`'s DOMAIN.md header; the
  close merge (AGENTS.md rule 4, `skills/5-ship`) is told the rule when it
  creates a page.
- **`tools/kb.sh`** finds an area page by its file name, by its Menu line,
  or by the file name a Menu gives (`kb_area_file`); a name holding `/` or
  `\`, or starting with `.`, is still never looked up as a file. The
  contents page's Product areas links percent-encode space `%` `(` `)` `[`
  `]` `#` `<` `>` (`kb_area_href`) so a link to `교사 - 학생 - 학급 분석.md`
  opens in GitHub and Obsidian; Hangul bytes stay as written. `kb_body`
  prints a `<summary>…</summary>` line as a section label, so `show` prints
  the page top first and the evidence block last, under
  `근거 · 코드 위치 (개발자용):` — the part the line bound cuts first. The
  Rules column no longer counts an unfilled template row `| P1 | <…> |`
  (or line `- P1: <…>`), and `show` drops such a line the way it already
  dropped `- Where: <…>`.
- **Reader-first `templates/area.md`.** Menu and Aliases on top; Business
  rules, Numbers, How it works, and History in plain sentences with no
  source and no code; then a `<details>` block — "근거 · 코드 위치
  (개발자용)" — holding the Where line and one evidence row per rule or
  figure: `| P1 | source | set by | verified |`. Evidence rows sit below
  the block's opening line, where the rule count stops, so they are never
  counted as rules. A retired rule stays struck through on top
  (`| ~~P3~~ | ~~rule~~ |`) and its evidence row's Source cell carries
  `retired YYYY-MM-DD by <slug>: <why>`. The section
  headings are unchanged. `templates/harvest.md`'s area candidates split
  the plain sentence from its evidence the same way, and ship's
  retrospective says which part goes where.
- **Obsidian form of the evidence block.** Obsidian does not render markdown
  inside `<details>`, so a store with `index_style: obsidian` writes it as
  a folded callout (`> [!info]- 근거 · 코드 위치 (개발자용)`, every line
  prefixed `> `); `kb.sh` reads both forms (Where found, callout lines
  printed last without `> `, never counted as rules).
- **Tables for rules, figures, history and evidence.** Each is one
  markdown table row (`| P1 | <rule> |`, `| N1 | label | counted | out of
  | timing |`, `| YYYY-MM-DD | slug | what changed |`, and in the evidence
  block `| P1 | source | set by | verified |` under the `- Where:` line);
  Menu, Aliases and How it works stay list lines. A retired rule is
  `| ~~P3~~ | ~~rule~~ |`, its reason in its evidence row's Source cell.
  Header words are free (`| # | 정책 |` works); a literal `|` in a cell is
  `\|`. `kb.sh` keys on row shapes only: the Rules count reads `| P<n> |`
  rows above the evidence block (the `<details>` or `> [!…]` line), the
  last change reads History's first `| YYYY-MM-DD |` row, and `show`
  prints tables as written — callout rows without `> ` — dropping only a
  template placeholder row (every cell after the first `<…>`) and the
  header of a table left with no rows. The close merge (AGENTS.md rule 4,
  ship, harvest.md) writes rows; harvest candidates stay line-shaped.
- **README.md / README.ko.md**: the "Knowledge is filed by product area"
  paragraph and the memory-tree comment now mention the optional Numbers
  section, the menu-path file name, and the folded evidence block.

## Compatibility

**Existing ASCII-named area pages keep working.** `kb.sh show "<menu
path>"` still finds a page by its Menu line whatever the file is called,
the contents page still lists and links it, and features still file under
it by their `Area:` line. Only a newly created page takes the menu-path
name. To rename an old page, move it to the name its Menu line gives (a
plain `mv` when the store is not in git), then regenerate the contents page:

```bash
git mv ".sdlc/memory/areas/class-analysis.md" ".sdlc/memory/areas/교사 - 학생 - 학급 분석.md"
tools/kb.sh index
```
 A feature whose `Area:` line names the old file name
instead of the Menu should be changed to the Menu words. Nothing is renamed
for you.

**List-form pages keep working.** A page written with `- P<n>: rule`
lines and `- YYYY-MM-DD <slug> — …` History lines (v0.15.0 and the first
v0.16.0 commits) is still counted and dated, and a page may mix both forms;
convert it to rows whenever the close merge next edits it.

**Existing pages with inline sources keep working.** A rule written the old
way — `- P1: <rule> — source: … · set by …` — still counts and still
prints; the close merge moves its source to the evidence block the next
time it edits that rule, or you can move it by hand.

An area page with no Numbers section is unaffected: the section is
optional and `kb.sh`'s Rules column stays a P-number count only (a store
with only P-numbers renders identically to before). No script parses the
`N<n>:` line; filing it is an instruction to the agent, exactly like a
`P<n>:` line.

## Validation

- `bash gates/selftest.sh` → `SELFTEST PASS`. Its "knowledge by product
  area" test now also files a feature under a Hangul menu page named
  `교사 - 학생 - 학급 분석.md`, laid out reader first with evidence rows and
  a retired rule: the contents-page row links the percent-encoded path with
  a Rules count of 2 (evidence and retired rows not counted); `show` by
  Menu and by file name prints the rules before the evidence block; a
  lookup holding `/` is refused; a second page in the Obsidian callout form
  is read the same way. Both pages are in table form with Korean header
  words: evidence rows, a retired row and a placeholder row are not
  counted, the last change comes from the History table, and `show`
  prints the tables with the evidence last. The list-form `roster` page
  still counts. With the old `kb.sh`, the test fails.
