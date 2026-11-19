import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as core from '../todo/core.mjs';
import { boardCards, feedEntryOf, targetOf } from '../todo/status.mjs';

const now = Date.parse('2026-11-19T12:00');
// Items as the board receives them: parsed by core from a to-do file.
function itemsOf(t, body) {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-board-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const file = join(root, 'todo.md');
  writeFileSync(file, `# To-do\n\n## Open\n\n${body}\n`);
  return core.load(file).items;
}
const ticket = `- [ ] [Decision D99] T-1 · which textbook
  - link: [T-1](https://tracker.invalid/browse/T-1)
  - waiting: 1) grade 9 · 2) class
  - choices: grade 9 | class
  - pick: 1
  - 2026-11-18 12:36 factory: added

- [ ] T-1 which textbook
  - project: /tmp/project
  - link: [T-1](https://tracker.invalid/browse/T-1)
  - sdlc: t-1-textbook · plan · READY — plan not approved
  - waiting: answer in D99
  - repos: api
  - 2026-11-18 12:38 agent: started t-1-textbook

- [ ] T-2 agent work
  - link: [T-2](https://tracker.invalid/browse/T-2)
  - sdlc: t-2-work · build · READY — build next
  - 2026-11-18 09:00 agent: started t-2-work

- [ ] T-3 blocked work
  - link: [T-3](https://tracker.invalid/browse/T-3)
  - sdlc: t-3-work · evidence · BLOCKED — dev database unreachable
  - 2026-11-18 09:00 agent: started t-3-work

- [ ] [Notice] factory line
  - waiting: read the morning report
  - 2026-11-19 08:31 agent: waiting — read the morning report

- [ ] Old idea
  - 2026-10-01 10:00 human: added

- [ ] Pinned setting
  - others: setting · judge on
  - pin: yes
  - 2026-10-01 10:00 agent: pinned`;

test('board: items sharing a ticket link are one card in the work item\'s column, answered on the item with choices', t => {
  const cards = boardCards(itemsOf(t, ticket), null, now);
  const t1 = cards.filter(card => card.link?.label === 'T-1');
  assert.equal(t1.length, 1, 'one card for the ticket');
  assert.equal(t1[0].members.length, 2);
  assert.equal(t1[0].column, 'plan', 'the column comes from the member with an sdlc phase');
  assert.equal(t1[0].lane, 'you');
  assert.match(t1[0].target.title, /Decision D99/, 'answers go to the decision, not the work item');
  assert.equal(targetOf(t1[0].members).id, t1[0].target.id);
  const notice = cards.find(card => card.target.title.startsWith('[Notice]'));
  assert.equal(notice.column, 'general', 'an item without an sdlc phase sits in the general column');
  assert.equal(notice.lane, 'you');
  assert.equal(cards.find(card => card.link?.label === 'T-3').lane, 'blocked');
  assert.equal(cards.find(card => card.link?.label === 'T-2').lane, 'agent');
});

test('board: the most urgent member decides the lane: you, then blocked, then others, then agent', t => {
  const items = itemsOf(t, `- [ ] T-9 work
  - link: [T-9](https://tracker.invalid/browse/T-9)
  - sdlc: t-9 · deliver · BLOCKED — stg down
  - 2026-11-18 09:00 agent: started t-9

- [ ] T-9 waiting on QA
  - link: [T-9](https://tracker.invalid/browse/T-9)
  - others: QA
  - 2026-11-18 09:00 agent: waiting on others — QA`);
  const [card] = boardCards(items, null, now);
  assert.equal(card.lane, 'blocked');
  assert.equal(card.column, 'deliver');
  assert.equal(card.target.sdlc?.slug, 't-9', 'a blocked member is the target when nobody waits on you');
});

test('board: a feed moves agent and others cards but never hides your turn or a block', t => {
  const items = itemsOf(t, ticket);
  const feed = { version: 1, items: {
    'T-1': { column: 'deliver', turn: 'agent', chip: 'dev' },
    'T-2': { column: 'evidence', turn: 'others', chip: 'stg' },
    't-3-work': { turn: 'agent', column: 'deliver' },
    'Pinned setting': { turn: 'nobody' }
  } };
  const cards = boardCards(items, feed, now), by = label => cards.find(card => card.link?.label === label);
  assert.equal(by('T-1').lane, 'you', 'your turn from the to-do file stays');
  assert.equal(by('T-1').column, 'plan', 'the feed column does not move your turn');
  assert.equal(by('T-1').chip, 'dev');
  assert.equal(by('T-2').lane, 'others', 'an agent card follows the feed turn');
  assert.equal(by('T-2').column, 'evidence');
  assert.equal(by('T-3').lane, 'blocked', 'a block from the to-do file stays, matched by slug');
  assert.equal(by('T-3').column, 'evidence', 'nor a block');
  const pinned = cards.find(card => card.pinned);
  assert.equal(pinned.lane, 'others', 'an unknown feed turn is ignored');
  const without = boardCards(items, null, now);
  assert.equal(without.find(card => card.link?.label === 'T-2').column, 'build');
  assert.equal(without.find(card => card.link?.label === 'T-2').chip, '');
});

test('board: a feed never moves a card that needs you or is blocked, and never moves an open card to Done', t => {
  const items = itemsOf(t, `${ticket}

- [ ] T-9 pick one
  - link: [T-9](https://tracker.invalid/browse/T-9)
  - waiting: which?
  - choices: a | b
  - 2026-11-18 09:00 agent: waiting — which?`);
  const feed = { items: { 'T-9': { column: 'done' }, 'T-1': { column: 'build' }, 'T-3': { column: 'intent' }, 'T-2': { column: 'done' } } };
  const by = label => boardCards(items, feed, now).find(card => card.link?.label === label);
  assert.deepEqual([by('T-9').lane, by('T-9').column, by('T-9').needsHuman], ['you', 'general', true]);
  assert.equal(by('T-1').column, 'plan', 'your turn keeps its sdlc column');
  assert.equal(by('T-3').column, 'evidence', 'a block keeps its sdlc column');
  assert.equal(by('T-2').column, 'build', 'an open agent card never moves to Done');
  assert.ok(boardCards(items, feed, now).filter(card => card.column === 'done').every(card => card.target.done));
});

test('board: feed entries match by ticket label, then slug key, then slug field; junk is ignored', t => {
  const items = itemsOf(t, ticket), members = items.filter(item => item.link?.label === 'T-2');
  assert.equal(feedEntryOf({ items: { 'T-2': { chip: 'a' } } }, members).chip, 'a');
  assert.equal(feedEntryOf({ items: { 't-2-work': { chip: 'b' } } }, members).chip, 'b');
  assert.equal(feedEntryOf({ items: { other: { slug: 't-2-work', chip: 'c' } } }, members).chip, 'c');
  for (const feed of [null, 'text', [], { items: [] }, { items: { 'T-2': 'x' } }, { items: { 'T-2': ['x'] } }]) {
    assert.equal(feedEntryOf(feed, members), null, JSON.stringify(feed));
  }
  assert.doesNotThrow(() => boardCards(items, { items: { 'T-1': { column: 42, turn: {}, chip: ['x'], updatedAt: 'soon' } } }, now));
  const card = boardCards(items, { items: { 'T-1': { column: 42, chip: ['x'] } } }, now).find(c => c.link?.label === 'T-1');
  assert.equal(card.column, 'plan');
  assert.equal(card.chip, '');
});

test('board: cards quiet for over 14 days are stale unless pinned or needing you; done shows for 7 days', t => {
  const items = itemsOf(t, `${ticket}

## Done

- [x] ~~Shipped yesterday~~
  - 2026-11-18 10:00 agent: done — shipped

- [x] ~~Shipped last month~~
  - 2026-10-10 10:00 agent: done — shipped`);
  const cards = boardCards(items, null, now);
  assert.equal(cards.find(card => card.target.title === 'Old idea').stale, true);
  assert.equal(cards.find(card => card.pinned).stale, false, 'pinned stays visible');
  assert.ok(cards.filter(card => card.lane === 'you').every(card => !card.stale));
  const done = cards.filter(card => card.column === 'done');
  assert.deepEqual(done.map(card => card.target.title), ['Shipped yesterday']);
  const fresh = boardCards(items, { items: { 'Old idea': {} } }, now).find(card => card.target.title === 'Old idea');
  assert.equal(fresh.stale, true, 'a feed entry that does not match keeps the card stale');
});
