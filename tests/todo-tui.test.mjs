import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import * as core from '../todo/core.mjs';
import { render, reduce } from '../todo/tui.mjs';

const item = (id, changes = {}) => ({ id, title: `작업 ${id}`, project: '~/code/web',
  link: { label: 'WEB-123', url: 'https://example.atlassian.net/browse/WEB-123' },
  sdlc: null, waiting: '', events: [], notes: [], status: 'workable', done: false, ...changes });
const fixture = () => ({ file: '/tmp/할 일/todo.md', selected: 0, view: 'list', items: [
  item('open', { title: '한글 제목과 가족 👨‍👩‍👧‍👦 그리고 긴 제목 '.repeat(3) }),
  item('progress', { sdlc: { slug: '261026-work', phase: 'build', state: 'READY', action: '' } }),
  item('wait', { status: 'waiting', waiting: '기획서 검토 부탁드립니다' }),
  item('blocked', { status: 'blocked', sdlc: { slug: '261026-blocked', phase: 'plan', state: 'BLOCKED', action: 'project missing' } }),
  item('done', { title: '완료된 작업', done: true, status: 'done', events: [{ at: '2026-10-26 10:00', who: 'human', what: 'done' }] })
] });
const strip = line => line.replace(/\x1b\[[0-9;]*m/g, '');
// Independent width oracle for these Korean, emoji, combining, and ASCII fixtures.
function width(text) {
  let size = 0;
  for (const { segment } of new Intl.Segmenter('ko', { granularity: 'grapheme' }).segment(strip(text))) {
    if (/^[\p{Mark}\u200d\ufe0f]+$/u.test(segment)) continue;
    size += /[\u1100-\u115f\u2e80-\ua4cf\uac00-\ud7a3\uf900-\ufaff\uff01-\uff60]|\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(segment) ? 2 : 1;
  }
  return size;
}
function keys(state, ...values) {
  let result = { state, effects: [] };
  for (const key of values) result = reduce(result.state, key);
  return result;
}
function type(state, text) { return keys(state, ...text); }

for (const [columns, rows] of [[80, 24], [60, 12]]) {
  for (const color of [false, true]) test(`render ${columns}x${rows}, color=${color}: Korean/emoji fit`, () => {
    for (const extra of [{}, { showDone: true, selected: 4 }, { view: 'details' }, { view: 'help' },
      { input: { kind: 'add', text: '긴 입력 🧑‍💻 '.repeat(20), cursor: 80 } },
      { webUrl: `http://127.0.0.1:45678/?token=${'a'.repeat(32)}` }]) {
      const lines = render({ ...fixture(), ...extra }, { width: columns, height: rows, color });
      assert.equal(lines.length, rows);
      for (const line of lines) assert.ok(width(line) <= columns, `${width(line)} > ${columns}: ${line}`);
    }
  });
}

test('all five status glyphs, counts, wait text and metadata', () => {
  const text = render({ ...fixture(), showDone: true }, { width: 80, height: 24, color: true }).join('\n');
  for (const glyph of ['○', '◐', '●', '✕', '✓']) assert.ok(text.includes(glyph));
  assert.match(text, /4 open · 1 needs you · 1 done/);
  assert.match(text, /기획서 검토/);
  assert.match(text, /WEB-123/);
  assert.match(text, /web · WEB-123 · build/);
  assert.match(text, /2026-10-26 10:00/);
});
test('Done collapsed until Tab and expanded titles have dim strike styling', () => {
  const state = fixture();
  assert.match(render(state).join('\n'), /Done · 1/);
  assert.doesNotMatch(render(state).join('\n'), /완료된 작업/);
  const expanded = reduce(state, 'Tab').state;
  assert.match(render(expanded, { color: true }).join('\n'), /\x1b\[2;9m✓ 완료된 작업/);
  assert.equal(reduce(expanded, 'Tab').state.showDone, false);
});
test('color false has no ANSI, and file text cannot inject terminal sequences', () => {
  const state = fixture();
  state.items[0].title = 'injected\x1b[31m title\nnext\x07';
  const text = render(state, { color: false }).join('\n');
  assert.ok(!text.includes('\x1b'));
  assert.ok(!text.includes('\x07'));
  assert.equal(text.split('\n').length, 24);
});
test('tokenized URL and unavailable-web reason stay visible in header', () => {
  const url = `http://127.0.0.1:12345/?token=${'abcdef'.repeat(6)}`;
  const lines = render({ ...fixture(), webUrl: url }, { width: 60, height: 12 });
  assert.ok(lines.slice(2, 4).map(strip).join('').includes(url));
  assert.match(render({ ...fixture(), webError: 'port failed' }).join('\n'), /web: off \(port failed\)/);
});
test('details expose every field, author/time, notes and full long text via scrolling', () => {
  const state = fixture();
  state.items[0].notes = ['  - preserved note'];
  state.items[0].events = [{ at: '2026-10-26 11:00', who: 'jira', what: 'added' },
    { at: '2026-10-26 11:01', who: 'human', what: 'edited' }];
  const detail = keys(state, 'Enter').state;
  const text = [0, 6, 12, 18].flatMap(detailOffset => render({ ...detail, detailOffset }, { width: 60, height: 12 })).join('\n');
  for (const field of ['Project:', 'Link:', 'SDLC:', 'Phase:', 'Action:', 'Waiting:', 'History', 'Notes',
    '2026-10-26 11:00 jira: added', '2026-10-26 11:01 human: edited', 'preserved note']) assert.ok(text.includes(field), field);
  assert.equal(reduce(detail, 'Esc').state.view, 'list');
});
test('add flow uses parseText and human source', () => {
  const original = fixture();
  const state = type(keys(original, 'a').state, 'Buy milk ~/tmp https://example.atlassian.net/browse/AB-1').state;
  const result = reduce(state, 'Enter');
  assert.equal(result.state.input, null);
  assert.deepEqual(result.effects, [{ type: 'add', text: 'Buy milk ~/tmp https://example.atlassian.net/browse/AB-1',
    title: 'Buy milk', project: '~/tmp', link: { label: 'AB-1', url: 'https://example.atlassian.net/browse/AB-1' }, by: 'human' }]);
  assert.equal(original.input, undefined);
});
test('x and Space toggle Done and Tab makes completed items selectable', () => {
  assert.deepEqual(reduce(fixture(), 'x').effects, [{ type: 'done', id: 'open', item: fixture().items[0], done: true }]);
  assert.deepEqual(reduce(fixture(), ' ').effects, [{ type: 'done', id: 'open', item: fixture().items[0], done: true }]);
  assert.deepEqual(keys(fixture(), 'Tab', 'G', 'x').effects, [{ type: 'done', id: 'done', item: fixture().items[4], done: false }]);
});
test('delete requires y; n and Esc cancel; u describes one-level undo', () => {
  const deleting = reduce(fixture(), 'd');
  assert.deepEqual(deleting.effects, []);
  assert.match(render(deleting.state).join('\n'), /Delete “/);
  assert.deepEqual(reduce(deleting.state, 'y').effects, [{ type: 'remove', id: 'open', item: fixture().items[0] }]);
  for (const key of ['n', 'Esc']) {
    const cancelled = reduce(deleting.state, key);
    assert.equal(cancelled.state.confirm, null); assert.deepEqual(cancelled.effects, []);
  }
  const undo = keys(deleting.state, 'y', 'u');
  assert.equal(undo.effects[0].type, 'undo');
  assert.equal(undo.effects[0].undo.item.id, 'open');
  assert.equal(undo.state.undo, null);
  assert.deepEqual(reduce(undo.state, 'u').effects, []);
});
test('J/K move; j/k and g/G navigate and clamp at boundaries', () => {
  assert.deepEqual(reduce(fixture(), 'J').effects, [{ type: 'move', id: 'open', item: fixture().items[0], delta: 1 }]);
  assert.deepEqual(reduce(fixture(), 'K').effects, [{ type: 'move', id: 'open', item: fixture().items[0], delta: -1 }]);
  assert.equal(keys(fixture(), 'k').state.selected, 0);
  assert.equal(keys(fixture(), 'j', 'Down', 'Up').state.selected, 1);
  assert.equal(keys(fixture(), 'G').state.selected, 3);
  assert.equal(keys(fixture(), 'G', 'g').state.selected, 0);
});
test('r only replies to waiting items and cannot approve a gate', () => {
  assert.deepEqual(reduce(fixture(), 'r').effects, []);
  assert.equal(reduce(fixture(), 'r').state.input, undefined);
  const state = { ...fixture(), selected: 2 };
  const writing = type(reduce(state, 'r').state, 'Please revise').state;
  assert.deepEqual(reduce(writing, 'Enter').effects, [{ type: 'reply', id: 'wait', item: fixture().items[2], text: 'Please revise' }]);
  assert.match(render(state).join('\n'), /w: read and decide in the browser/);
});
test('input editing is grapheme-aware; empty submits cancel; normal shortcuts become text', () => {
  let state = type(keys(fixture(), 'a').state, '우유🥛').state;
  state = keys(state, 'Left', 'Backspace').state;
  assert.equal(state.input.text, '우🥛');
  state = keys(state, 'Home', 'Right', 'Delete', 'End').state;
  assert.equal(state.input.text, '우');
  state = keys(state, 'Ctrl+U').state;
  assert.equal(state.input.cursor, 0);
  assert.deepEqual(reduce(state, 'Enter').effects, []);
  assert.equal(reduce(state, 'Esc').state.input, null);
  assert.equal(type(keys(fixture(), 'a').state, 'qdx').state.input.text, 'qdx');
  assert.deepEqual(reduce(state, 'Ctrl+C').effects, [{ type: 'quit' }]);
});
test('edit, link/web, sync, help and quit effects preserve IO boundary', () => {
  const editing = keys(fixture(), 'e', 'Ctrl+U').state;
  assert.deepEqual(reduce(type(editing, 'New title').state, 'Enter').effects, [{ type: 'edit', id: 'open', item: fixture().items[0], text: 'New title' }]);
  assert.deepEqual(reduce(fixture(), 'o').effects, [{ type: 'open', url: 'https://example.atlassian.net/browse/WEB-123' }]);
  assert.deepEqual(reduce(fixture(), 'w').effects, [{ type: 'web', id: 'open' }]);
  assert.deepEqual(reduce(fixture(), 'R').effects, [{ type: 'sync' }]);
  assert.equal(reduce(fixture(), '?').state.view, 'help');
  assert.deepEqual(reduce(fixture(), 'q').effects, [{ type: 'quit' }]);
});
test('long lists keep selection and collapsed Done visible on a small screen', () => {
  const state = { ...fixture(), items: Array.from({ length: 50 }, (_, i) => item(String(i))), selected: 49 };
  const text = render(state, { width: 60, height: 12 }).join('\n');
  assert.match(text, /› ○ 작업 49/);
  assert.match(text, /Done · 0/);
});
test('G in details then k scrolls up immediately', () => {
  const state = fixture();
  state.items[0].events = Array.from({ length: 60 }, (_, i) => ({ at: '2026-10-26 11:00', who: 'human', what: `event ${i}` }));
  const bottom = keys(state, 'Enter', 'G').state;
  const up = reduce(bottom, 'k').state;
  assert.notDeepEqual(render(bottom), render(up));
});

test('typed combining marks and ZWJ emoji keep the cursor on grapheme boundaries', () => {
  for (const text of ['e\u0301', '👨‍👩‍👧‍👦', '🇰🇷']) {
    const state = type(keys(fixture(), 'a').state, text).state;
    assert.equal(state.input.cursor, 1);
    assert.equal(reduce(state, 'Backspace').state.input.text, '');
  }
});

async function until(predicate) {
  const deadline = Date.now() + 4000;
  while (!predicate()) {
    assert.ok(Date.now() < deadline, 'timed out waiting for TUI state');
    await delay(10);
  }
}
async function terminal(t, seed) {
  const root = mkdtempSync(join(tmpdir(), 'todo-tui-test-')), file = join(root, 'todo.md');
  await seed(file);
  const source = `import {runTui} from ${JSON.stringify(new URL('../todo/tui.mjs', import.meta.url).href)};
    process.stdin.isTTY = true; process.stdin.setRawMode = () => {};
    process.stdout.isTTY = true; process.stdout.columns = 60; process.stdout.rows = 12;
    await runTui({file: process.env.SDLC_TODO, kit: ${JSON.stringify(fileURLToPath(new URL('../', import.meta.url)))}, web:false});`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', source], {
    env: { ...process.env, SDLC_TODO: file, NO_COLOR: '' }, stdio: ['pipe', 'pipe', 'pipe']
  });
  let screen = '', error = '';
  child.stdout.on('data', data => { screen += data; });
  child.stderr.on('data', data => { error += data; });
  const exited = new Promise(resolve => child.once('exit', (code, signal) => resolve({ code, signal })));
  t.after(async () => { if (child.exitCode === null) child.kill('SIGKILL'); await exited; rmSync(root, { recursive: true, force: true }); });
  await until(() => screen.includes('To-do'));
  return { file, send: text => child.stdin.write(text), screen: () => screen,
    async close() { child.stdin.write('q'); const exit = await exited; assert.equal(exit.code, 0, error); } };
}
test('persisted undo delete restores the first of identical items after core renumbers IDs', async t => {
  const ui = await terminal(t, async file => { await core.add(file, 'duplicate', { by: 'human' }); await core.add(file, 'duplicate', { by: 'human' }); });
  ui.send('dy');
  await until(() => core.load(ui.file).items.length === 1);
  ui.send('u');
  await until(() => core.load(ui.file).items.length === 2);
  assert.ok(core.load(ui.file).items.some(i => i.events.some(e => e.who === 'human' && e.what === 'undo remove')));
  await ui.close();
});
test('persisted undo done refuses to overwrite a concurrent new waiting message', async t => {
  const ui = await terminal(t, async file => { const item = await core.add(file, 'wait', { by: 'human' }); await core.wait(file, item.id, 'old wait'); });
  ui.send('x');
  await until(() => core.load(ui.file).items[0].done);
  const item = core.load(ui.file).items[0];
  await core.wait(ui.file, item.id, 'new wait from agent');
  ui.send('u');
  await until(() => ui.screen().includes('Cannot undo: waiting changed elsewhere'));
  assert.equal(core.load(ui.file).items[0].waiting, 'new wait from agent');
  assert.equal(core.load(ui.file).items[0].done, true);
  await ui.close();
});
test('opening a focused web item preserves its session token', () => {
  const state = { ...fixture(), webUrl: 'http://127.0.0.1:12345/#t=secret-token' };
  assert.equal(reduce(state, 'w').effects[0].url, 'http://127.0.0.1:12345/#t=secret-token&id=open');
});
test('delete confirmation refuses a reused ID after another writer deletes its original duplicate', async t => {
  const ui = await terminal(t, async file => {
    const first = await core.add(file, 'duplicate', { by: 'human' }); await core.note(file, first.id, 'first record');
    const second = await core.add(file, 'duplicate', { by: 'human' }); await core.note(file, second.id, 'second record');
  });
  ui.send('d');
  await until(() => ui.screen().includes('Delete “duplicate”? y/n'));
  await core.remove(ui.file, core.load(ui.file).items[0].id);
  ui.send('y');
  await until(() => ui.screen().includes('Item changed'));
  const items = core.load(ui.file).items;
  assert.equal(items.length, 1);
  assert.ok(items[0].events.some(e => e.what === 'second record'));
  await ui.close();
});
test('undo refuses a different duplicate with matching minute-resolution history', async t => {
  const ui = await terminal(t, async file => {
    for (const note of ['record A', 'record B']) {
      const item = await core.add(file, 'duplicate', { by: 'human' });
      await core.done(file, item.id, '', 'human');
      await core.mutate(file, model => { model.items.find(i => i.id === item.id).notes = [`  - ${note}`]; });
    }
    await core.mutate(file, model => {
      // Same minute, same author and action; the free notes distinguish these records.
      model.items[1].events = structuredClone(model.items[0].events);
    });
  });
  ui.send('\tx');
  await until(() => core.load(ui.file).items.some(i => !i.done));
  await core.mutate(ui.file, model => {
    const opened = model.items.find(i => !i.done), other = model.items.find(i => i.done);
    other.done = false;
    other.events = structuredClone(opened.events);
    model.items.splice(model.items.indexOf(other), 1); model.items.unshift(other);
  });
  ui.send('u');
  await until(() => ui.screen().includes('Cannot undo: item changed elsewhere'));
  assert.equal(core.load(ui.file).items.filter(i => !i.done).length, 2);
  await ui.close();
});
