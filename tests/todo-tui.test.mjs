import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import * as core from '../todo/core.mjs';
import { render, reduce } from '../todo/tui.mjs';
import { defaultLanguage, languages, translator } from '../todo/i18n.mjs';

const item = (id, changes = {}) => ({ id, title: `작업 ${id}`, project: '~/code/web',
  link: { label: 'WEB-123', url: 'https://example.atlassian.net/browse/WEB-123' },
  sdlc: null, waiting: '', events: [], notes: [], status: 'workable', done: false, ...changes });

for (const view of ['list', 'details']) {
  for (const reason of ['error', 'action', 'both']) {
    test(`S23: blocked ${view} shows the repair instruction from ${reason}`, () => {
      const repair = 'relative project path: write an absolute or ~/ path';
      const blocked = item('blocked', { status: 'blocked', project: './project',
        error: reason !== 'action' ? repair : undefined,
        sdlc: reason === 'error' ? null : { state: 'BLOCKED', action: reason === 'both' ? 'stale action' : repair } });
      const text = render({ file: '/tmp/todo.md', items: [blocked], selected: 0, view },
        { width: 100, height: 28 }).join('\n');
      assert.ok(text.includes(`${view === 'list' ? 'blocked' : 'Action'}: ${repair}`), text);
      assert.doesNotMatch(text, /blocked: blocked|Action: —|stale action/);
    });
  }
}
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
  // Was "4 open · 1 needs you · 1 done": counts now say who acts next.
  assert.match(text, /1 your turn · 2 agent · 1 blocked · 1 done/);
  assert.match(text, /Agents stop here until you decide/);
  assert.match(text, /기획서 검토/);
  assert.match(text, /WEB-123/);
  assert.match(text, /web · WEB-123 · Build/);
  assert.match(text, /2026-10-26 10:00/);
});
test('Done collapsed until Tab and expanded titles have dim strike styling', () => {
  const state = fixture();
  assert.match(render(state).join('\n'), /Done · 1/);
  assert.doesNotMatch(render(state).join('\n'), /완료된 작업/);
  const expanded = reduce(state, 'Tab').state;
  assert.match(render(expanded, { color: true }).join('\n'), /\x1b\[2;33;9m✓ 완료된 작업/);
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
  for (const field of ['Project:', 'Link:', 'SDLC:', 'Phase:', 'Action:', 'Your next step:' /* was 'Waiting:' */, 'History', 'Notes',
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
async function terminal(t, seed, web = false) {
  const root = mkdtempSync(join(tmpdir(), 'todo-tui-test-')), file = join(root, 'todo.md');
  await seed(file);
  const source = `import {runTui} from ${JSON.stringify(new URL('../todo/tui.mjs', import.meta.url).href)};
    process.stdin.isTTY = true; process.stdin.setRawMode = () => {};
    process.stdout.isTTY = true; process.stdout.columns = 60; process.stdout.rows = 12;
    await runTui({file: process.env.SDLC_TODO, kit: ${JSON.stringify(fileURLToPath(new URL('../', import.meta.url)))}, web:${web}});`;
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
await until(() => ui.screen().includes('Cannot undo:'));
assert.match(ui.screen(), /Cannot undo: item changed elsewhere/);
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

const kit = fileURLToPath(new URL('../', import.meta.url));
const intent = `# Intent
## Understood as
- O1: operator observes requested behavior.
## Blocking questions
- none
## Delivery
- Target: local
- Authorized: no
## Clarity
| Area | State | How settled |
|---|---|---|
| Outcome | clear | operator's request |
| Scope | clear | operator's request |
| AS-IS | clear | observed with real CLI |
| TO-BE | clear | operator's request |
| Success | clear | O1 is CLI output |
| Constraints | clear | none found in config.md |
`;

function setupProject(root) {
  const dir = join(root, 'project'); mkdirSync(dir);
  const run = (...args) => execFileSync('bash', [join(kit, 'sdlc.sh'), ...args], { cwd: dir, encoding: 'utf8' });
  run('init'); run('new', 'startup');
  writeFileSync(join(dir, '.sdlc', 'work', 'startup', 'intent.md'), intent);
  return { dir, run };
}
for (const [state, web] of [['approved', false], ['approved', true], ['archived', false], ['missing', false]]) test(`B5: ${web ? 'web' : 'no-web'} startup syncs ${state} before the first usable frame`, async t => {
  const ui = await terminal(t, async file => {
    const { dir, run } = setupProject(dirname(file));
    await core.add(file, 'Startup item', { project: dir, slug: 'startup' });
    await core.sync(file, { kit });
    if (state === 'approved') run('approve', 'intent', 'startup', '--human', 'approved scope');
    if (state === 'archived') run('close', 'startup', 'dropped', 'no longer needed');
    if (state === 'missing') rmSync(dir, { recursive: true, force: true });
  }, web);
  const current = core.load(ui.file).items[0];
  assert.equal(current.sdlc.state, { approved: 'READY', archived: 'DONE', missing: 'BLOCKED' }[state],
    'startup must reconcile cached NEEDS-HUMAN without R or a web server');
  if (state === 'approved') assert.ok(!ui.screen().includes('approve intent --human'), 'no usable frame shows the stale approval wait');
  if (state === 'archived') assert.match(ui.screen(), /0 your turn · 0 agent · 0 blocked/); // was /0 open/
  if (state === 'missing') assert.match(ui.screen(), /blocked/);
  await ui.close();
});

test('B5: startup sync failure restores raw mode, cursor and alternate screen', async t => {
  const root = mkdtempSync(join(tmpdir(), 'todo-tui-failure-')), file = join(root, 'todo.md');
  writeFileSync(file, '## Open\n\n## Done\n');
  writeFileSync(`${file}.lock`, 'live owner');
  const source = `import {runTui} from ${JSON.stringify(new URL('../todo/tui.mjs', import.meta.url).href)};
    process.stdin.isTTY = true; process.stdin.setRawMode = raw => process.stdout.write('RAW=' + raw + '\\n');
    process.stdout.isTTY = true; process.stdout.columns = 60; process.stdout.rows = 12;
    try { await runTui({file:process.env.SDLC_TODO, web:false}); }
    catch (error) { process.stderr.write(error.message); process.exitCode = 1; }`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', source], {
    env: { ...process.env, SDLC_TODO: file }, stdio: ['pipe', 'pipe', 'pipe']
  });
  let output = '', error = '';
  child.stdout.on('data', data => { output += data; }); child.stderr.on('data', data => { error += data; });
  // The old implementation never syncs: quit it, then assert the missing failure.
  const timer = setTimeout(() => child.stdin.write('q'), 2800);
  t.after(() => { clearTimeout(timer); if (child.exitCode === null) child.kill('SIGKILL'); rmSync(root, { recursive: true, force: true }); });
  const code = await new Promise(resolve => child.once('exit', resolve));
  assert.equal(code, 1, 'startup must fail when sync cannot acquire the inbox lock');
  assert.match(error, /timed out waiting for lock/);
  assert.match(output, /RAW=false/);
  assert.ok(output.includes('\x1b[?25h') && output.includes('\x1b[?1049l'), 'cursor and alternate screen restored');
});

test('Apple Notes palette uses yellow title, selection, waiting and dim done with readable plain glyphs', () => {
  const state = { ...fixture(), showDone: true };
  const colored = render(state, { color: true }).join('\n');
  assert.match(colored, /\x1b\[1;33mTo-do/);
  assert.match(colored, /\x1b\[33m› /);
  assert.match(colored, /\x1b\[33m● /);
  assert.match(colored, /\x1b\[2;33;9m✓ /);
  assert.match(colored, /\x1b\[31m✕ /);
  const plain = render(state, { color: false }).join('\n');
  assert.doesNotMatch(plain, /\x1b/);
  for (const glyph of ['○', '●', '✓', '✕', '◐']) assert.ok(plain.includes(glyph));
});

test('B5: resize during startup cannot draw cached state before sync completes', async t => {
  const root = mkdtempSync(join(tmpdir(), 'todo-tui-resize-')), file = join(root, 'todo.md');
  const kitStub = join(root, 'kit'), entered = join(root, 'entered'), release = join(root, 'release'); mkdirSync(kitStub);
  await core.add(file, 'Cached item', { project: root, slug: 'probe' });
  writeFileSync(join(kitStub, 'sdlc.sh'), `touch "${entered}"\nwhile [ ! -f "${release}" ]; do sleep 0.01; done\nprintf '%s\\n' '{"features":[{"slug":"probe","phase":"build","state":"READY"}]}'\n`);
  const source = `import {runTui} from ${JSON.stringify(new URL('../todo/tui.mjs', import.meta.url).href)};
    import fs from 'node:fs';
    process.stdin.isTTY=true;process.stdin.setRawMode=()=>{};process.stdout.isTTY=true;
    process.stdout.columns=60;process.stdout.rows=12;
    const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(entered)})){clearInterval(timer);process.stdout.emit('resize');process.stdout.write('RESIZED');}},5);
    await runTui({file:process.env.SDLC_TODO,kit:${JSON.stringify(kitStub)},web:false});`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', source], { env: { ...process.env, SDLC_TODO: file } });
  let screen = '', error = ''; child.stdout.on('data', d => { screen += d; }); child.stderr.on('data', d => { error += d; });
  const exited = new Promise(resolve => child.once('exit', resolve));
  t.after(async () => { if (child.exitCode === null) child.kill('SIGKILL'); await exited; rmSync(root, { recursive: true, force: true }); });
  try { await until(() => screen.includes('RESIZED')); assert.ok(!screen.includes('To-do'), 'resize cannot display an unsynced inbox'); }
  finally { writeFileSync(release, 'sync may finish'); }
  await until(() => screen.includes('To-do')); child.stdin.write('q'); assert.equal(await exited, 0, error);
});

test('R7 B1: pending delete refuses a surviving identical same-minute duplicate', async t => {
  const ui = await terminal(t, async file => {
    await core.add(file, 'Duplicate', { project: dirname(file), by: 'human' });
    await core.add(file, 'Duplicate', { project: dirname(file), by: 'human' });
    await core.mutate(file, model => {
      for (const item of model.items) item.events[0].at = '2026-10-26 09:41';
    });
  });
  const model = core.load(ui.file);
  assert.equal(core.serialize({ items: [model.items[0]] }), core.serialize({ items: [model.items[1]] }));
  ui.send('d');
  await until(() => ui.screen().includes('Delete “Duplicate”? y/n'));
  await core.remove(ui.file, model.items[0].id);
  const before = readFileSync(ui.file, 'utf8');
  // Let the file watcher reload while the original confirmation stays pending.
  await delay(350);
  ui.send('y');
  await until(() => /Deleted|Item changed/.test(ui.screen()));
  assert.equal(core.load(ui.file).items.length, 1, 'stale confirmation must preserve the surviving duplicate');
  assert.match(ui.screen(), /Item changed; review it and try again/);
  assert.equal(readFileSync(ui.file, 'utf8'), before);
  await ui.close();
});

test('R8 B1: undo refuses a surviving identical completed duplicate', async t => {
  const ui = await terminal(t, async file => {
    const first = await core.add(file, 'Duplicate', { by: 'human' });
    await core.done(file, first.id, '', 'human');
    await core.add(file, 'Duplicate', { by: 'human' });
    // Align the seeded histories with the TUI completion's current local minute.
    await core.mutate(file, model => {
      for (const item of model.items) for (const event of item.events) event.at = core.stamp();
    });
  });
  ui.send('x');
  await until(() => core.load(ui.file).items.every(item => item.done));
  const model = core.load(ui.file);
  // The histories must actually be identical for this to exercise duplicate membership.
  assert.equal(core.serialize({ items: [model.items[0]] }), core.serialize({ items: [model.items[1]] }));
  await core.remove(ui.file, model.items[0].id);
  const before = readFileSync(ui.file, 'utf8');
  await delay(350);
  ui.send('u');
  await until(() => /Undone|Cannot undo/.test(ui.screen()));
  assert.equal(readFileSync(ui.file, 'utf8'), before, 'undo must preserve the surviving completed duplicate');
  assert.match(ui.screen(), /Cannot undo: item changed elsewhere/);
  await ui.close();
});

for (const action of ['done', 'undone', 'edit']) {
  for (const change of ['event', 'note']) {
    test(`R8 B1: undo ${action} refuses an appended ${change}`, async t => {
      const ui = await terminal(t, async file => {
        const item = await core.add(file, 'Original', { by: 'human' });
        if (action === 'undone') await core.done(file, item.id, '', 'human');
      });
      ui.send(action === 'edit' ? 'e\x15Renamed\r' : action === 'undone' ? '\tx' : 'x');
      await until(() => {
        const item = core.load(ui.file).items[0];
        return action === 'edit' ? item.title === 'Renamed' : item.done === (action === 'done');
      });
      await core.mutate(ui.file, model => {
        const item = model.items[0];
        if (change === 'event') item.events.push({ at: core.stamp(), who: 'agent', what: 'new information' });
        else item.notes.push('  - new information');
      });
      const before = readFileSync(ui.file, 'utf8');
      ui.send('u');
      await until(() => /Undone|Cannot undo/.test(ui.screen()));
      assert.equal(readFileSync(ui.file, 'utf8'), before, 'undo must preserve intervening information');
      assert.match(ui.screen(), /Cannot undo: item changed elsewhere/);
      await ui.close();
    });
  }
  test(`R8 B1: ordinary undo ${action} succeeds without an intervening change`, async t => {
    const ui = await terminal(t, async file => {
      const item = await core.add(file, 'Original', { by: 'human' });
      if (action === 'undone') await core.done(file, item.id, '', 'human');
    });
    ui.send(action === 'edit' ? 'e\x15Renamed\r' : action === 'undone' ? '\tx' : 'x');
    await until(() => {
      const item = core.load(ui.file).items[0];
      return action === 'edit' ? item.title === 'Renamed' : item.done === (action === 'done');
    });
    ui.send('u');
    await until(() => /Undone|Cannot undo/.test(ui.screen()));
    const item = core.load(ui.file).items[0];
    assert.equal(item.title, 'Original');
    assert.equal(item.done, action === 'undone');
    assert.ok(item.events.some(event => event.what === `undo ${action === 'edit' ? 'edit' : 'done'}`));
    await ui.close();
  });
}

test('R8 B1: undo refuses a removed target with the changed-item message', async t => {
  const ui = await terminal(t, file => core.add(file, 'Original', { by: 'human' }));
  ui.send('x');
  await until(() => core.load(ui.file).items[0].done);
  await core.remove(ui.file, core.load(ui.file).items[0].id);
  const before = readFileSync(ui.file, 'utf8');
  ui.send('u');
  await until(() => /Cannot undo|Item changed or was removed/.test(ui.screen()));
  assert.match(ui.screen(), /Cannot undo: item changed elsewhere/);
  assert.equal(readFileSync(ui.file, 'utf8'), before);
  await ui.close();
});

test('R8 B1: ordinary undo uses the saved version after Done overflow archives a duplicate', async t => {
  const ui = await terminal(t, async file => {
    await core.add(file, 'Duplicate', { by: 'human' });
    await core.mutate(file, model => {
      const open = structuredClone(model.items[0]);
      model.items = [open, ...Array.from({ length: 30 }, () => ({
        ...structuredClone(open), done: true,
        events: [...structuredClone(open.events), { at: core.stamp(), who: 'human', what: 'done' }]
      }))];
    });
  });
  ui.send('x');
  await until(() => core.load(ui.file).items.every(item => item.done));
  const model = core.load(ui.file);
  assert.equal(model.items.length, 30);
  assert.equal(new Set(model.items.map(item => core.serialize({ items: [item] }))).size, 1);
  assert.equal((readFileSync(join(dirname(ui.file), 'todo-archive.md'), 'utf8').match(/^- \[x\]/gm) || []).length, 1);
  ui.send('u');
  await until(() => /Undone|Cannot undo/.test(ui.screen()));
  assert.equal(core.load(ui.file).items.filter(item => !item.done).length, 1, 'ordinary undo must use the post-archive version');
  assert.match(ui.screen(), /Undone/);
  await ui.close();
});

test('language: TUI renders the configured language, fits Korean and L cycles every registered language', () => {
  const other = languages.find(l => l !== defaultLanguage), t = translator(other);
  for (const extra of [{}, { showDone: true, selected: 4 }, { view: 'details', selected: 2 }, { view: 'help' }, { input: { kind: 'add', text: '', cursor: 0 } }]) {
    for (const [columns, rows] of [[80, 24], [60, 12]]) {
      const lines = render({ ...fixture(), lang: other, ...extra }, { width: columns, height: rows });
      for (const line of lines) assert.ok(width(line) <= columns, `${width(line)} > ${columns}: ${line}`);
    }
  }
  const list = render({ ...fixture(), lang: other }, { width: 100, height: 24 }).join('\n');
  assert.ok(list.includes(t('tui.counts', { you: 1, agent: 2, blocked: 1, done: 1 })), list);
  assert.ok(list.includes(t('stop.you')), list);
  assert.doesNotMatch(list, /your turn|needs you/);
  const details = render({ ...fixture(), lang: other, view: 'details', selected: 2 }, { width: 100, height: 24 }).join('\n');
  assert.ok(details.includes(t('status.answer')), details);
  const help = render({ ...fixture(), lang: other, view: 'help' }, { width: 100, height: 40 }).join('\n');
  assert.ok(help.includes(t('tui.help.language')) && /\bL\b/.test(help), help);
  let state = { ...fixture(), lang: defaultLanguage };
  const seen = [];
  for (const _ of languages) { state = reduce(state, 'L').state; seen.push(state.lang); }
  assert.deepEqual(seen, [...languages.slice(1), languages[0]]);
  assert.equal(reduce({ ...fixture() }, 'L').state.lang, languages[1], 'an unset language starts from the default');
  assert.match(render({ ...fixture(), view: 'help' }, { width: 100, height: 40 }).join('\n'), /L +Next language/);
});
