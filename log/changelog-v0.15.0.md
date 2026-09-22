# v0.15.0 — knowledge filed by product area, with its business rules

Records were filed by feature and date. Nobody could ask "what are the rules
for the submit screen?" without knowing which slug changed it. In real stores
`DOMAIN.md` had turned into long evidence sentences with file paths and
hashes, not something a person reads. `summary.md` had five one-line fields
and no store had used it. This release files knowledge the way people
navigate a product, by area (for a web app, by menu), and gives business
rules (정책) one home. Gates, approvals, the `--json` schema, and lazymode are
unchanged.

## Changes

- **Product area pages** (`templates/area.md` → `memory/areas/<area>.md`).
  There is one page per area. For a web app an area is one menu, named by its
  menu path (`학습 > 평가 > 제출`); for other software it is a module, API,
  job, or CLI command. Each page has:
  - `Menu:`, `Where:`, and `Aliases:` lines;
  - **Business rules (정책)**, numbered P1… and written as testable sentences
    a non-developer can read, each with its source and the feature that set
    it (P-numbers are never reused, and a retired rule stays struck through);
  - a short How it works;
  - a History line per feature that changed the area.

  `init.sh` seeds `memory/areas/`. The page replaces DOMAIN.md's old
  "split into `memory/domain/<area>.md`" overflow rule, so there is one
  concept instead of two.
- **What goes where, in one table** (AGENTS.md rule 4). Business rules go to
  the area page, area history to the page's History, cross-area terms and
  facts to DOMAIN.md, traps to lessons, agent rules to POLICY.md (only on the
  human's word, and never a business rule), and one feature's story to
  summary.md. Every row except POLICY.md and summary.md is written only by
  the close merge, which creates a missing area page from the template.
- **The loop uses the pages**:
  - Intent names the area and cites the P-numbers the request touches.
  - The spec's AS-IS names each rule it keeps, changes, or retires.
  - The Side effects verifier re-checks the rules the change did not set out
    to change.
  - Ship writes every set, changed, or retired rule and a history line as area
    candidates (a new `Area candidates` section in `templates/harvest.md`).
- **summary.md reads like a note to a colleague**: a Goal sentence as its
  title, then `Area`, `Tags`, and `Status` (only what delivery.md confirms),
  followed by *What was wrong*, *Before → After*, *How to check*, and
  *Remember*.
- **`tools/kb.sh`**:
  - `index` opens with a **Product areas** table (live-rule count, last
    change, features, and areas a feature names that have no page yet).
  - The overview table gains an **Area** column.
  - `show <name>` falls back to a product area — the page's file name, its
    exact menu path, or an area features name with no page yet — and prints
    it with the features that name it. An `Area:` line may use the menu path
    or the file name.
  - `search` already covered `memory/`, so business rules are found by their
    words.
  - An area name containing `/` or starting with `.` never resolves to a file.
  - A record heading with nothing under it is no longer printed, so an
    unfinished summary shows only what is known. Summaries print up to 20
    lines (was 12).
  - Messages: a `show` miss reads "no feature or product area", `show` with
    no argument asks for "a feature slug or a product area", an `--area` miss
    reads "no such knowledge folder (--area)", the usage text lists
    `show <slug | product area>`, the contents page's Search line names
    `show <slug | area>`, and the harvest and close hints name the area
    pages.
- **`kb.sh` runs with byte semantics (`LC_ALL=C`).** Under a UTF-8 locale,
  macOS awk compares strings by collation, so different Hangul menu paths
  compared equal and every feature was filed under every area. Found by macOS
  CI (en_US.UTF-8).
- **Rules and history describe what shipped.** They merge only on a
  `shipped` close; any other close drops them, and a stale merge leaves
  them in harvest.md for that close. The merge
  gives a new rule the next number its page never used. A fact about one area
  goes to that page's How it works. The spec template gains a **Business
  rules touched** section, and the spec adversary and the verifier read the
  area pages.
- **E2E lens findings from v0.14.0, fixed**:
  - The compact route gains a `Baseline:` line (build reads it).
  - Probe 8 covers any outbound call, not only UI.
  - evidence.md and the ship authorization name the compact-route source.
  - The router states that a broken-and-undiagnosed report goes to stage 6
    ahead of the generic change row.
  - The compact criterion now explains why optional open questions still
    disqualify it: the compact route has no spec to answer them.

## Compatibility

Older summaries (Problem/Cause/… bullets) still print, now up to 20 lines. A store with
no `memory/areas/` and no `Area:` lines gets no Product areas section. The
overview table's header gains a column; `gates/knowledge-test.sh` H8 is
updated for that deliberate change.

## Validation

- `bash gates/knowledge-test.sh` → `KNOWLEDGE-TEST PASS`, 152, under the
  en_US.UTF-8, ko_KR.UTF-8 and C locales. H38–H45 are new and cover one
  contract each: area row, page-less area, `show` by menu path, `show` of a
  page-less area, path walk, unfilled summary, filled section, and Area by
  file name. H38, H39 and H45 fail on the pre-fix kb.sh under en_US.UTF-8.
- Three fresh-context verifier lenses (E2E, Side effects, Intent match).
  Round 1 found the unfilled-template leak (blocking) and ~20 minor gaps. A
  round-2 re-check found every one resolved (PASS), including against the old
  kb.sh on seven real stores (only named differences, byte-identical
  regeneration, unchanged exit codes). It also found four minor new gaps
  (usage line, changelog wording, stale-merge rule loss, researcher
  destination), and those were fixed.
- `bash gates/selftest.sh` → `SELFTEST PASS`
- `bash gates/e2e.sh` → `E2E PASS`, 152 · `bash gates/autotest.sh` → `AUTOTEST PASS`, 195

## Tests: one smoke test

The kit is mostly instructions, and four suites (about 3,800 lines, several
minutes per run) mostly re-checked wording. `gates/e2e.sh`,
`gates/autotest.sh`, `gates/knowledge-test.sh`, and
`gates/win-restricted-run.py` are removed. `gates/selftest.sh` is now one
smoke test (~75 lines, a few seconds) covering: scripts parse and are
LF-only, SKILL.md frontmatter, gates bind content and upstream, lazymode
limits, close proof (lesson, ship approval, confirmed delivery), and
product-area filing under a UTF-8 locale. CI runs only that: on pull
requests (branch protection requires its checks) and by hand, no longer on
every push to main or on tags.

