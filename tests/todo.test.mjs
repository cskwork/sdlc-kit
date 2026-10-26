import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync, rmSync, utimesSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as core from '../todo/core.mjs';
import { statusOf } from '../todo/status.mjs';

const kit = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const entry = join(kit, 'todo', 'todo.mjs');
const runFile = promisify(execFile);
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
const plan = `# Plan
- Risk flags: migration no · data deletion no · public API no · security no · infra no
## Scenarios
| ID | Persona | Steps | Expected | Must | Covers |
|---|---|---|---|---|---|
| S1 | operator | run real CLI | observable output | yes | O1 |
`;

function scratch(t) {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return { root, file: join(root, 'todo.md') };
}

function command(program, args, cwd) {
  return execFileSync(program, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function sdlc(project, ...args) {
  return command('bash', [join(kit, 'sdlc.sh'), ...args], project);
}

function project(root, name = 'project') {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  command('git', ['-c', 'init.defaultBranch=main', 'init', '-q'], dir);
  command('git', ['config', 'user.name', 'sdlc todo test'], dir);
  command('git', ['config', 'user.email', 'todo@sdlc.invalid'], dir);
  command('git', ['config', 'core.autocrlf', 'false'], dir);
  writeFileSync(join(dir, 'README'), 'baseline\n');
  command('git', ['add', 'README'], dir);
  command('git', ['commit', '-qm', 'baseline'], dir);
  sdlc(dir, 'init');
  return dir;
}

function feature(dir, slug = 'feature', ready = false) {
  sdlc(dir, 'new', slug);
  const folder = join(dir, '.sdlc', 'work', slug);
  writeFileSync(join(folder, 'intent.md'), intent);
  if (ready) {
    sdlc(dir, 'approve', 'intent', slug, '--human', 'approved scope');
    writeFileSync(join(folder, 'PLAN.md'), plan);
    sdlc(dir, 'approve', 'plan', slug, '--agent', 'scenarios and risks reviewed');
  }
  return folder;
}

async function cli(file, args, options = {}) {
  const env = { ...process.env, SDLC_TODO: file, ...options.env };
  try {
    const result = await runFile(process.execPath, [entry, ...args], {
      cwd: options.cwd || kit, env, encoding: 'utf8', timeout: 20000,
      maxBuffer: 2 * 1024 * 1024,
    });
    return { code: 0, ...result };
  } catch (error) {
    if (typeof error.code !== 'number') throw error;
    return { code: error.code, stdout: error.stdout, stderr: error.stderr };
  }
}

function checkCode(result, expected) {
  assert.equal(result.code, expected, `${result.stdout}\n${result.stderr}`);
  return result;
}

async function next(file, code) {
  const result = checkCode(await cli(file, ['next', '--json']), code);
  return code === 30 ? null : JSON.parse(result.stdout);
}

function sameMinute(file) {
  writeFileSync(file, readFileSync(file, 'utf8').replace(/\d{4}-\d\d-\d\d \d\d:\d\d/g, '2026-10-26 09:00'));
}

function hasReply(item, words) {
  assert.ok(Array.isArray(item.replies), 'next exposes replies as an array');
  assert.ok(JSON.stringify(item.replies).includes(words), `reply missing: ${words}`);
}

test('S1/S4/S12: CLI writes readable fields, Jira labels, and ordered agent history', async t => {
  const { file } = scratch(t);
  const result = checkCode(await cli(file, ['add', 'Fix login', '--project', '~/p', '--link',
    'https://x.atlassian.net/browse/WEB-123', '--by', 'jira']), 0);
  let id = result.stdout.trim();
  assert.match(id, /^[a-f0-9]{6}$/);
  checkCode(await cli(file, ['start', id, '--slug', 'fix-login', '--phase', 'intent']), 0);
  id = core.load(file).items[0].id;
  checkCode(await cli(file, ['phase', id, 'plan']), 0);
  checkCode(await cli(file, ['wait', id, 'confirm the redirect']), 0);
  checkCode(await cli(file, ['note', id, 'checked the current behavior']), 0);
  let text = readFileSync(file, 'utf8');
  assert.match(text, /^# To-do/m);
  assert.match(text, /^## Open$/m);
  assert.match(text, /^- \[ \] Fix login$/m);
  assert.match(text, /^  - project: ~\/p$/m);
  assert.match(text, /^  - link: \[WEB-123\]\(https:\/\/x\.atlassian\.net\/browse\/WEB-123\)$/m);
  assert.match(text, /^  - sdlc: fix-login · plan/m);
  assert.match(text, /^  - waiting: confirm the redirect$/m);
  for (const event of ['jira: added', 'agent: started fix-login', 'agent: waiting — confirm the redirect',
    'agent: checked the current behavior']) {
    assert.ok(text.includes(event), event);
  }
  const events = text.split('\n').filter(line => /^  - \d{4}-\d\d-\d\d /.test(line));
  assert.ok(events.length >= 5);
  for (const event of events) assert.match(event, /^  - \d{4}-\d\d-\d\d \d\d:\d\d (jira|agent): .+$/);
  checkCode(await cli(file, ['done', id, 'PR #12']), 0);
  text = readFileSync(file, 'utf8');
  assert.match(text, /## Done\s+- \[x\] ~~Fix login~~/);
  assert.match(text, /agent: done — PR #12/);
});

test('S5: next stops at the first wait, exposes a human reply, and returns 30 when empty', async t => {
  const { file } = scratch(t);
  const a = await core.add(file, 'A');
  const b = await core.add(file, 'B');
  await core.wait(file, a.id, 'which endpoint?');
  assert.equal((await next(file, 10)).id, a.id);
  await core.reply(file, a.id, 'use the existing endpoint');
  const answered = await next(file, 0);
  assert.equal(answered.id, a.id);
  hasReply(answered, 'use the existing endpoint');
  assert.doesNotMatch(readFileSync(file, 'utf8'), /^  - waiting:/m);
  await core.done(file, a.id);
  assert.equal((await next(file, 0)).id, b.id);
  await core.done(file, b.id);
  await next(file, 30);
});

test('S10: new and resumed slugs register once and sync intent approval into plan', async t => {
  const { root, file } = scratch(t);
  const dir = project(root);
  feature(dir, 'new-work');
  feature(dir, 'resumed-work');
  const added = checkCode(await cli(file, ['add', '--project', dir, '--slug', 'new-work']), 0);
  const a = core.load(file).items[0];
  assert.equal(added.stdout.trim(), a.id);
  assert.equal(a.title, 'new-work');
  assert.match(readFileSync(file, 'utf8'), /sdlc: new-work · intent · NEEDS-HUMAN/);
  const b = await core.add(file, '', { project: dir, slug: 'resumed-work' });
  const again = await core.add(file, 'ignored duplicate title', { project: dir, slug: 'resumed-work' });
  assert.equal(again.id, b.id);
  assert.equal(core.load(file).items.length, 2);
  assert.equal((await next(file, 10)).slug, 'new-work');
  sdlc(dir, 'approve', 'intent', 'new-work', '--human', 'approved new work scope');
  const advanced = await next(file, 0);
  assert.equal(advanced.id, a.id);
  assert.equal(advanced.phase, 'plan');
  assert.equal(advanced.state, 'READY');
  assert.match(readFileSync(file, 'utf8'), /sdlc: new-work · plan · READY/);
});

test('S11: thirty Done items stay newest-first and item 31 archives the oldest', async t => {
  const { root, file } = scratch(t);
  for (let n = 0; n < 31; n++) {
    const item = await core.add(file, `Finished ${n}`);
    await core.done(file, item.id, `result ${n}`);
  }
  const text = readFileSync(file, 'utf8');
  assert.equal((text.match(/^- \[x\]/gm) || []).length, 30);
  assert.ok(text.indexOf('~~Finished 30~~') < text.indexOf('~~Finished 29~~'));
  assert.ok(text.includes('~~Finished 1~~'));
  assert.ok(!text.includes('~~Finished 0~~'));
  const archive = readFileSync(join(root, 'todo-archive.md'), 'utf8');
  assert.match(archive, /^# To-do archive$/m);
  assert.match(archive, /- \[x\] ~~Finished 0~~/);
  assert.match(archive, /agent: done — result 0/);
});

test('S14: twenty parallel CLI writers preserve every unique item and release the lock', async t => {
  const { file } = scratch(t);
  const results = await Promise.all(Array.from({ length: 20 }, (_, n) => cli(file, ['add', `Concurrent ${n}`])));
  for (const result of results) checkCode(result, 0);
  const model = core.load(file);
  assert.equal(model.items.length, 20);
  assert.equal(new Set(model.items.map(item => item.id)).size, 20);
  assert.deepEqual(new Set(model.items.map(item => item.title)), new Set(Array.from({ length: 20 }, (_, n) => `Concurrent ${n}`)));
  assert.equal(existsSync(`${file}.lock`), false);
});

test('S15: first use writes only the child HOME inbox and SDLC_TODO selects a separate file', async t => {
  const { root } = scratch(t);
  const home = join(root, 'home');
  mkdirSync(home);
  const env = { ...process.env, HOME: home, USERPROFILE: home };
  delete env.SDLC_TODO;
  const first = await runFile(process.execPath, [entry, 'add', 'Default inbox'], { env, encoding: 'utf8', timeout: 20000 });
  assert.match(first.stdout.trim(), /^[a-f0-9]{6}$/);
  const defaultFile = join(home, '.sdlc', 'todo.md');
  assert.match(readFileSync(defaultFile, 'utf8'), /^# To-do/m);
  assert.deepEqual(readdirSync(join(home, '.sdlc')), ['todo.md']);
  const alternate = join(root, 'other.md');
  checkCode(await cli(alternate, ['add', 'Alternate inbox'], { env: { HOME: home, USERPROFILE: home } }), 0);
  assert.equal(core.load(alternate).items[0].title, 'Alternate inbox');
  assert.equal(core.load(defaultFile).items.length, 1);
  assert.equal(existsSync(join(home, '.sdlc', 'config.md')), false);
});

test('S16: hand edits preserve the preamble and notes and checked Open items become human Done', async t => {
  const { file } = scratch(t);
  const preamble = '# My inbox\n\nOwner text kept exactly.\n<!-- personal note -->\n\n';
  writeFileSync(file, `${preamble}## Open\n\n- [ ] Hand added\n  an unknown indented note\n  - custom: keep this\n\n- [x] ~~Checked in editor~~\n  - project: ~/p\n\n## Done\n`);
  const before = core.load(file);
  assert.equal(before.preamble, preamble);
  assert.ok(core.serialize(before).startsWith(preamble));
  await core.add(file, 'Tool added');
  const text = readFileSync(file, 'utf8');
  assert.ok(text.startsWith(preamble));
  assert.ok(text.includes('  an unknown indented note\n  - custom: keep this'));
  assert.match(text, /^- \[ \] Hand added$/m);
  assert.match(text, /## Done\s+- \[x\] ~~Checked in editor~~/);
  assert.match(text, /\d{4}-\d\d-\d\d \d\d:\d\d human: done/);
  assert.doesNotMatch(text.split('## Done')[0], /Checked in editor/);
});

test('parser and serializer preserve canonical bytes and recover hand edits without section headings', async t => {
  const { file } = scratch(t);
  const canonical = '# Personal to-do\n\n## Open\n\n- [ ] First\n  - project: ~/code\n  - link: [WEB-123](https://x.atlassian.net/browse/WEB-123)\n  - sdlc: first · build · READY — implement\n  - waiting: choose environment\n  - 2026-10-26 09:00 agent: added\n  - custom: exact text\n\n## Done\n\n- [x] ~~Earlier~~\n  - 2026-10-25 08:00 human: done\n';
  writeFileSync(file, canonical);
  assert.equal(core.serialize(core.load(file)), canonical);
  for (const source of [
    '# Personal to-do\n\n- [ ] Missing both headings\n  an exact note\n',
    '# Personal to-do\n\n## Open\n\n- [ ] Missing Done heading\n  an exact note\n',
    '# Personal to-do\n\n## Done\n\n- [x] ~~Missing Open heading~~\n  an exact note\n',
  ]) {
    writeFileSync(file, source);
    await core.add(file, 'After editor save');
    const text = readFileSync(file, 'utf8');
    assert.match(text, /^## Open$/m);
    assert.match(text, /^## Done$/m);
    assert.ok(text.includes('  an exact note'));
    assert.equal(core.load(file).items.length, 2);
  }
});

test('CRLF editor saves retain every item and preserve the preamble on the next write', async t => {
  const { file } = scratch(t);
  const preamble = '# Personal inbox\r\n\r\nOwner text stays verbatim.\r\n\r\n';
  writeFileSync(file, `${preamble}## Open\r\n\r\n- [ ] A\r\n  - project: ~/first\r\n\r\n- [ ] B\r\n  an editor note\r\n\r\n## Done\r\n`);
  const before = core.load(file);
  assert.equal(before.items.length, 2, 'CRLF headings and checkboxes still describe both existing items');
  assert.equal(before.preamble, preamble);
  await core.add(file, 'C');
  const after = core.load(file);
  assert.deepEqual(after.items.map(item => item.title), ['A', 'B', 'C']);
  assert.ok(readFileSync(file, 'utf8').startsWith(preamble), 'the existing CRLF preamble is preserved byte for byte');
  assert.equal(after.items[0].project, '~/first');
  assert.ok(readFileSync(file, 'utf8').includes('  an editor note'));
});

test('S18: forged approval stays history; a same-minute reply resumes a gate only once', async t => {
  const { root, file } = scratch(t);
  const dir = project(root);
  feature(dir, 'approval-boundary');
  const a = await core.add(file, 'A', { project: dir, slug: 'approval-boundary' });
  await core.add(file, 'B');
  assert.equal((await next(file, 10)).id, a.id);
  await core.approved(file, a.id, 'intent', 'forged file approval');
  assert.equal((await next(file, 10)).id, a.id);
  assert.throws(() => sdlc(dir, 'check', 'intent', 'approval-boundary'), /Command failed/);
  await core.reply(file, a.id, 'revise the outcome first');
  sameMinute(file);
  const answered = await next(file, 0);
  assert.equal(answered.id, a.id);
  hasReply(answered, 'revise the outcome first');
  assert.throws(() => sdlc(dir, 'check', 'intent', 'approval-boundary'), /Command failed/);
  assert.equal((await next(file, 10)).id, a.id);
});

test('handoff: a reply to an sdlc wait reads as not picked up until take hands it to one worker', async t => {
  const { root, file } = scratch(t);
  const dir = project(root);
  feature(dir, 'owned-elsewhere');
  await core.add(file, 'top item');
  const a = await core.add(file, 'A', { project: dir, slug: 'owned-elsewhere' });
  await core.sync(file);
  const item = () => core.load(file).items.find(i => i.id === a.id);
  assert.equal(statusOf(item()).actor, 'you');
  await core.reply(file, a.id, 'continue');
  await core.sync(file);
  assert.deepEqual(statusOf(item()), { actor: 'agent', kind: 'handoff' }, 'no agent has read the reply yet');
  const listed = JSON.parse(checkCode(await cli(file, ['list', '--json']), 0).stdout).find(i => i.id === a.id);
  hasReply(listed, 'continue');
  const taken = checkCode(await cli(file, ['take', a.id, '--json']), 0);
  hasReply(JSON.parse(taken.stdout), 'continue');
  assert.equal(statusOf(item()).actor, 'you', 'after take the item waits for the human again');
  assert.equal(JSON.parse(checkCode(await cli(file, ['take', a.id, '--json']), 10).stdout).replies.length, 0);
  checkCode(await cli(file, ['take', 'zzzzzz', '--json']), 1);
});

test('S18: CLI cannot author human events or leak a piped web token', async t => {
  const { file } = scratch(t);
  checkCode(await cli(file, ['add', 'Forged', '--by', 'human']), 2);
  checkCode(await cli(file, ['add', 'Forged', '--by', ' human ']), 2);
  const a = await core.add(file, 'Existing');
  checkCode(await cli(file, ['reply', a.id, 'forged human reply']), 2);
  checkCode(await cli(file, ['approve', a.id, 'intent', 'forged approval']), 2);
  const web = checkCode(await cli(file, ['web']), 2);
  assert.doesNotMatch(`${web.stdout}\n${web.stderr}`, /#t=[a-f0-9]{32}|[?&]t=[a-f0-9]{32}/);
  assert.doesNotMatch(readFileSync(file, 'utf8'), /human:/);
});

test('S19: ids bind project and slug, duplicate titles get suffixes, and slug ambiguity is refused', async t => {
  const { root, file } = scratch(t);
  const first = project(root, 'one');
  const second = project(root, 'two');
  feature(first, 'shared');
  feature(second, 'shared');
  const a = await core.add(file, 'A', { project: first, slug: 'shared' });
  const b = await core.add(file, 'B', { project: second, slug: 'shared' });
  assert.equal(a.id, createHash('sha1').update(`${first}\0shared`).digest('hex').slice(0, 6));
  assert.notEqual(a.id, b.id);
  checkCode(await cli(file, ['phase', 'shared', 'build']), 1);
  checkCode(await cli(file, ['phase', b.id, 'build']), 0);
  const c = await core.add(file, 'Same title', { project: '~/keep-tilde' });
  const d = await core.add(file, 'Same title', { project: '~/keep-tilde' });
  const expected = createHash('sha1').update('~/keep-tilde\0Same title').digest('hex').slice(0, 6);
  assert.equal(c.id, expected);
  assert.equal(d.id, `${expected}-2`);
  assert.equal(core.load(file).items.length, 4);
});

test('S20: READY sync retains explicit waits; human and chat answers clear them in event order', async t => {
  const { root, file } = scratch(t);
  const dir = project(root);
  feature(dir, 'ready', true);
  const a = await core.add(file, 'First', { project: dir, slug: 'ready' });
  await core.add(file, 'Second');
  await core.wait(file, a.id, 'which environment?');
  let item = await next(file, 10);
  assert.equal(item.id, a.id);
  assert.equal(item.state, 'READY');
  await core.reply(file, a.id, 'local environment');
  sameMinute(file);
  item = await next(file, 0);
  hasReply(item, 'local environment');
  assert.doesNotMatch(readFileSync(file, 'utf8'), /^  - waiting:/m);
  await core.wait(file, a.id, 'which branch?');
  sameMinute(file);
  assert.equal((await next(file, 10)).id, a.id, 'old reply cannot answer the newer wait');
  checkCode(await cli(file, ['answer', a.id, 'the current branch']), 0);
  sameMinute(file);
  item = await next(file, 0);
  assert.equal(item.id, a.id);
  hasReply(item, 'the current branch');
  assert.ok(!JSON.stringify(item.replies).includes('local environment'), 'only replies after the newest wait are actionable');
  assert.match(readFileSync(file, 'utf8'), /agent: chat answer — the current branch/);
});

test('S21: blocked legacy or unavailable projects stop before item two despite replies, then recover', async t => {
  const { root, file } = scratch(t);
  const dir = project(root);
  const absent = join(root, 'absent');
  const plain = join(root, 'plain');
  mkdirSync(plain);
  const legacy = join(dir, '.sdlc', 'work', 'legacy');
  mkdirSync(legacy);
  const cases = [
    { project: dir, slug: 'legacy', error: /legacy/i },
    { project: absent, slug: 'missing', error: /ENOENT|no such|not found|does not exist|missing|directory/i },
    { project: plain, slug: 'missing', error: /no \.sdlc\/config\.md found/i },
    { project: dir, slug: 'unknown', error: /feature not found/i },
  ];
  for (const example of cases) {
    writeFileSync(file, '# To-do\n\n## Open\n\n## Done\n');
    const a = await core.add(file, 'Blocked first', example);
    await core.add(file, 'Open second');
    await core.reply(file, a.id, 'please proceed');
    const item = await next(file, 20);
    assert.equal(item.id, a.id);
    assert.equal(item.state, 'BLOCKED');
    assert.match(item.action, example.error);
  }
  feature(dir, 'unknown');
  const recovered = await next(file, 10);
  assert.equal(recovered.state, 'NEEDS-HUMAN');
  assert.equal(recovered.slug, 'unknown');
});

test('S21: missing bash is BLOCKED and a later successful sync clears the call error', async t => {
  const { root, file } = scratch(t);
  const dir = project(root);
  feature(dir, 'bash-path');
  const a = await core.add(file, 'First', { project: dir, slug: 'bash-path' });
  await core.add(file, 'Second');
  const missing = checkCode(await cli(file, ['next', '--json'], { env: { PATH: join(root, 'empty-path') } }), 20);
  const item = JSON.parse(missing.stdout);
  assert.equal(item.id, a.id);
  assert.equal(item.state, 'BLOCKED');
  assert.match(item.action, /bash|ENOENT|not found/i);
  assert.equal((await next(file, 10)).state, 'NEEDS-HUMAN');
});

test('S21: sync finds an archived shipped slug and retains its close note in Done', async t => {
  const { root, file } = scratch(t);
  const dir = project(root);
  const folder = feature(dir, 'shipped', true);
  const a = await core.add(file, 'Ship this', { project: dir, slug: 'shipped' });
  writeFileSync(join(folder, 'review.md'), 'VERDICT: PASS\n');
  sdlc(dir, 'review', 'shipped', 'pass', 'independent review passed');
  const sha = command('git', ['rev-parse', 'HEAD'], dir).trim();
  writeFileSync(join(folder, 'logs', 'S1.txt'), 'observable output\n');
  writeFileSync(join(folder, 'evidence.md'), `# Evidence\n- Commit: ${sha}\n## Results\n| ID | Result | Cause | Observed | Log |\n|---|---|---|---|---|\n| S1 | PASS | | observable output | logs/S1.txt |\n## Delivery\n- Target: local\n- Delivered: ${sha}\n- Checked with: git rev-parse HEAD\n- Output: ${sha}\n- Authorized: no\n`);
  sdlc(dir, 'score', 'shipped');
  sdlc(dir, 'close', 'shipped', 'shipped', 'delivered locally');
  await core.sync(file, { kit });
  await next(file, 30);
  const text = readFileSync(file, 'utf8');
  assert.match(text, /## Done\s+- \[x\] ~~Ship this~~/);
  assert.match(text, /sdlc: DONE — .*delivered locally/);
  assert.ok(core.load(file).items.some(item => item.id === a.id));
});

test('core mutations reread editor changes, preserve notes, reorder, edit, and delete one item', async t => {
  const { file } = scratch(t);
  const a = await core.add(file, 'First');
  const b = await core.add(file, 'Second');
  writeFileSync(file, readFileSync(file, 'utf8').replace('- [ ] First', '- [ ] First\n  editor note kept'));
  await core.edit(file, b.id, { title: 'Changed second' });
  const changed = core.load(file).items.find(item => item.title === 'Changed second');
  assert.ok(changed);
  await core.move(file, changed.id, -1);
  assert.equal(core.load(file).items[0].title, 'Changed second');
  assert.ok(readFileSync(file, 'utf8').includes('  editor note kept'));
  await core.remove(file, a.id);
  assert.deepEqual(core.load(file).items.map(item => item.title), ['Changed second']);
});

test('mutation locks expire only when stale and rejected operations preserve the file', async t => {
  const { file } = scratch(t);
  await core.add(file, 'Keep me');
  const before = readFileSync(file, 'utf8');
  writeFileSync(`${file}.lock`, 'another writer');
  await assert.rejects(core.add(file, 'Cannot steal a fresh lock'), /lock/i);
  assert.equal(readFileSync(file, 'utf8'), before);
  const stale = new Date(Date.now() - 11000);
  utimesSync(`${file}.lock`, stale, stale);
  await core.add(file, 'Recovered stale lock');
  assert.equal(existsSync(`${file}.lock`), false);
  assert.equal(core.load(file).items.length, 2);
  const unchanged = readFileSync(file, 'utf8');
  await assert.rejects(core.mutate(file, model => {
    model.items.length = 0;
    throw new Error('operation failed');
  }), /operation failed/);
  assert.equal(readFileSync(file, 'utf8'), unchanged);
  assert.equal(existsSync(`${file}.lock`), false);
});

test('an asynchronous mutation keeps its live lock beyond ten seconds without losing concurrent writes', async t => {
  const { file } = scratch(t);
  await core.add(file, 'Original');
  const held = core.mutate(file, async model => {
    await new Promise(resolve => setTimeout(resolve, 11300));
    model.items[0].title = 'Changed by held mutation';
  });
  const concurrent = new Promise(resolve => setTimeout(resolve, 10200))
    .then(() => cli(file, ['add', 'Concurrent child']));
  await assert.doesNotReject(Promise.all([held, concurrent]), 'a live writer retains ownership until its asynchronous operation completes');
  checkCode(await concurrent, 0);
  assert.deepEqual(core.load(file).items.map(item => item.title), ['Changed by held mutation', 'Concurrent child']);
  assert.equal(existsSync(`${file}.lock`), false);
});

test('CLI text parsing accepts project/link tokens and stores only HTTP links', async t => {
  const { file } = scratch(t);
  checkCode(await cli(file, ['add', 'Fix ~/code/web https://github.com/acme/widget/issues/42 redirect']), 0);
  const text = readFileSync(file, 'utf8');
  assert.match(text, /^- \[ \] Fix redirect$/m);
  assert.match(text, /^  - project: ~\/code\/web$/m);
  assert.match(text, /link: \[widget#42\]\(https:\/\/github\.com\/acme\/widget\/issues\/42\)/);
  const unsafe = await cli(file, ['add', 'Unsafe link', '--link', 'javascript:alert(1)']);
  assert.ok(unsafe.code === 0 || unsafe.code === 2, 'unsafe link is rejected or omitted');
  assert.doesNotMatch(readFileSync(file, 'utf8'), /^  - link: .*javascript:/m);
  const listed = checkCode(await cli(file, ['list', '--json']), 0);
  const json = JSON.parse(listed.stdout);
  assert.ok(JSON.stringify(json).includes('Fix redirect'));
});

test('text and link helpers recognize portable project tokens and Jira, issue, pull, and host labels', () => {
  for (const project of ['~/code/web', './local', '/absolute/project', 'C:\\code\\web']) {
    const parsed = core.parseText(`Fix ${project} https://example.test/path redirect`);
    assert.equal(parsed?.project, project);
    assert.equal(parsed.title, 'Fix redirect');
    assert.equal(parsed.link.url, 'https://example.test/path');
  }
  for (const [url, label] of [
    ['https://x.atlassian.net/browse/WEB-123', 'WEB-123'],
    ['https://github.com/acme/widget/issues/42', 'widget#42'],
    ['https://github.com/acme/widget/pull/7', 'widget#7'],
    ['http://example.test/docs', 'example.test'],
  ]) assert.equal(core.linkLabel(url), label);
});

test('R5 B1: CLI binds a relative project to the adding cwd before selecting from another folder', async t => {
  const { root: temporaryRoot, file } = scratch(t), root = realpathSync(temporaryRoot);
  const a = join(root, 'A'), b = join(root, 'B');
  const target = project(a), other = project(b);
  feature(target, 'probe');
  feature(other, 'probe');
  sdlc(other, 'approve', 'intent', 'probe', '--human', 'approved B only');
  const added = checkCode(await cli(file, ['add', 'A work', '--project', './project', '--slug', 'probe'], { cwd: a }), 0);
  await t.test('stored path and id bind A', () => {
    assert.equal(core.load(file).items[0].project, target, 'store the absolute path from the adding process');
    assert.equal(added.stdout.trim(), createHash('sha1').update(`${target}\0probe`).digest('hex').slice(0, 6));
  });
  for (const cwd of [a, b]) await t.test(`next from ${cwd === a ? 'A' : 'B'} waits for A`, async () => {
    const selected = JSON.parse(checkCode(await cli(file, ['next', '--json'], { cwd }), 10).stdout);
    assert.equal(selected.id, added.stdout.trim());
    assert.equal(selected.project, target);
    assert.equal(selected.state, 'NEEDS-HUMAN');
    assert.match(selected.action, /intent not approved/);
  });
  const again = checkCode(await cli(file, ['add', '--project', target, '--slug', 'probe'], { cwd: b }), 0);
  assert.equal(again.stdout.trim(), added.stdout.trim(), 'absolute and relative intake share one identity');
  assert.equal(core.load(file).items.length, 1);
  assert.throws(() => sdlc(target, 'check', 'intent', 'probe'), /Command failed/);
});

test('R5 B1: intake resolves every relative spelling and preserves tilde and portable absolute paths', async t => {
  const { root: temporaryRoot, file } = scratch(t), root = realpathSync(temporaryRoot);
  for (const [index, input] of ['./project', '../project', 'x/y', '.\\project'].entries()) {
    await t.test(input, async () => {
      const title = `Relative-${index}`;
      checkCode(await cli(file, ['add', title, '--project', input], { cwd: root }), 0);
      const item = core.load(file).items.at(-1);
      assert.equal(item.project, resolve(root, input));
      assert.equal(item.id, core.itemId({ project: resolve(root, input), title }));
    });
  }
  for (const input of ['~', '~/project', '/absolute/project', 'C:\\project', 'C:/project', '\\\\server\\share\\project', '//server/share/project']) {
    const item = await core.add(file, 'Keep spelling', { project: input });
    assert.equal(item.project, input);
    assert.equal(core.load(file).items.at(-1).project, input);
  }
  const item = await core.add(file, 'Inline ./project');
  assert.equal(item.project, resolve('./project'), 'the shared add path also handles TUI/web text');
});

for (const slug of ['probe', '']) test(`R5 B1: hand-edited relative project ${slug ? 'with' : 'without'} a slug blocks next`, async t => {
  const { root, file } = scratch(t), dir = project(root);
  feature(dir, 'probe', true);
  writeFileSync(file, `# To-do\n\n## Open\n\n- [ ] Hand edited\n  - project: ./project\n${slug ? '  - sdlc: probe · plan · READY\n' : ''}  - 2026-10-26 09:00 human: reply — please proceed\n\n- [ ] Lower item\n\n## Done\n`);
  const selected = JSON.parse(checkCode(await cli(file, ['next', '--json'], { cwd: root }), 20).stdout);
  assert.equal(selected.title, 'Hand edited');
  assert.equal(selected.project, './project', 'never repair a file path using the consuming cwd');
  assert.equal(selected.action, 'relative project path: write an absolute or ~/ path');
  assert.equal(core.load(file).items[0].status, 'blocked');
  writeFileSync(file, readFileSync(file, 'utf8').replace('project: ./project', `project: ${dir}`));
  checkCode(await cli(file, ['next', '--json'], { cwd: root }), 0);
});

test('watch observes an external file edit within one second and can be stopped', async t => {
  const { file } = scratch(t);
  await core.add(file, 'Original');
  let stop, timer;
  t.after(() => { clearTimeout(timer); stop?.(); });
  const observed = new Promise(resolve => {
    timer = setTimeout(() => resolve(null), 1000);
    stop = core.watch(file, () => resolve(core.load(file)));
  });
  writeFileSync(file, readFileSync(file, 'utf8').replace('## Open\n', '## Open\n\n- [ ] Added in editor\n'));
  const model = await observed;
  assert.ok(model, 'watch observes the editor change within one second');
  assert.ok(model.items.some(item => item.title === 'Added in editor'));
  assert.equal(typeof stop, 'function');
  stop();
});

test('CLI malformed commands exit 2 and missing ids exit 1 without altering the file', async t => {
  const { file } = scratch(t);
  await core.add(file, 'Keep me');
  const before = readFileSync(file, 'utf8');
  for (const args of [['not-a-command'], ['add'], ['start'], ['start', 'abc123', '--slug'],
    ['phase', 'abc123'], ['wait', 'abc123'], ['answer', 'abc123'], ['list', '--unknown']]) {
    checkCode(await cli(file, args), 2);
  }
  for (const args of [['done', 'missing-id'], ['note', 'missing-id', 'note'], ['phase', 'missing-id', 'plan']]) {
    checkCode(await cli(file, args), 1);
  }
  assert.equal(readFileSync(file, 'utf8'), before);
});

// Pause only the stale stat, preserving the review's two-reclaimer interleaving.
test('B1: two stale reclaimers preserve both successful writes', async t => {
  const { root, file } = scratch(t);
  await core.add(file, 'Original');
  writeFileSync(`${file}.lock`, 'crashed owner');
  const stale = new Date(Date.now() - 11000);
  utimesSync(`${file}.lock`, stale, stale);
  const observed = join(root, 'observed'), resume = join(root, 'resume'), restored = join(root, 'restored');
  const source = `import fs from 'node:fs';
    import * as core from ${JSON.stringify(new URL('../todo/core.mjs', import.meta.url).href)};
    const file = ${JSON.stringify(file)}, observed = ${JSON.stringify(observed)}, resume = ${JSON.stringify(resume)}, restored = ${JSON.stringify(restored)};
    const stat = fs.statSync, link = fs.linkSync;
    let paused = false;
    fs.statSync = function(name, ...args) {
      const value = stat.call(this, name, ...args);
      if (name === file + '.lock' && !paused) {
        paused = true; fs.writeFileSync(observed, 'stale stat read');
        const deadline = Date.now() + 5000;
        while (!fs.existsSync(resume)) {
          if (Date.now() > deadline) throw new Error('parent did not resume stale reclaimer');
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
        }
      }
      return value;
    };
    fs.linkSync = function(from, to) {
      const value = link.call(this, from, to);
      if (to === file + '.lock') fs.writeFileSync(restored, 'successor restored');
      return value;
    };
    await core.add(file, 'Concurrent A');`;
  const a = spawn(process.execPath, ['--input-type=module', '-e', source]);
  let error = '', exited = false;
  a.stderr.on('data', data => { error += data; });
  const finished = new Promise(resolve => a.once('exit', code => { exited = true; resolve(code); }));
  t.after(() => { if (!exited) a.kill('SIGKILL'); });
  const until = async predicate => {
    const deadline = Date.now() + 5000;
    while (!predicate()) {
      assert.ok(Date.now() < deadline, 'interleaving reached its scheduled step');
      await new Promise(resolve => setTimeout(resolve, 5));
    }
  };
  await until(() => existsSync(observed));
  let release, held;
  const loaded = new Promise(resolve => { held = resolve; });
  const b = core.mutate(file, async model => {
    model.items[0].title = 'Held B';
    held();
    await new Promise(resolve => { release = resolve; });
  });
  await loaded;
  try {
    writeFileSync(resume, 'resume A with its stale observation');
    await until(() => exited || existsSync(restored));
  } finally { release(); }
  await b;
  assert.equal(await finished, 0, error);
  assert.deepEqual(core.load(file).items.map(item => item.title), ['Held B', 'Concurrent A'],
    'successful A must survive B committing its older model');
});

test('B1: sync releases the inbox lock while sdlc status runs', async t => {
  const { root, file } = scratch(t);
  const kitStub = join(root, 'kit'); mkdirSync(kitStub);
  writeFileSync(join(kitStub, 'sdlc.sh'), `if [ -e "$SDLC_TODO.lock" ]; then echo 'inbox lock held during status' >&2; exit 1; fi\nprintf '%s\\n' '{"features":[{"slug":"probe","phase":"build","state":"READY"}]}'\n`);
  const item = await core.add(file, 'Status', { project: root, slug: 'probe' });
  const old = process.env.SDLC_TODO; process.env.SDLC_TODO = file;
  try {
    const result = await core.next(file, { kit: kitStub });
    assert.equal(result.code, 0, result.item?.sdlc?.action);
    assert.equal(result.item.id, item.id);
  } finally { if (old === undefined) delete process.env.SDLC_TODO; else process.env.SDLC_TODO = old; }
});

test('B1: displaced owner retries before committing an older snapshot', async t => {
  const { file } = scratch(t);
  await core.add(file, 'Original');
  let calls = 0;
  await core.mutate(file, async model => {
    if (calls++ === 0) {
      const displaced = `${file}.displaced`;
      // Simulate ownership lost during an asynchronous operation.
      const { renameSync, unlinkSync } = await import('node:fs');
      renameSync(`${file}.lock`, displaced);
      await core.add(file, 'Successor write');
      unlinkSync(displaced);
    }
    model.items[0].title = 'Updated original';
  });
  assert.deepEqual(core.load(file).items.map(item => item.title), ['Updated original', 'Successor write']);
  assert.equal(calls, 2, 'the stale model must be discarded and the mutation reapplied');
});

test('B1: a delayed reclaimer cannot open a commit window or duplicate archive entries', async t => {
  const { root, file } = scratch(t);
  await core.add(file, 'Original');
  const model = core.load(file);
  for (let i = 0; i < 32; i++) model.items.push({ ...structuredClone(model.items[0]), title: `Done ${i}`, done: true });
  writeFileSync(file, core.serialize(model));
  writeFileSync(file + '.lock', 'crashed owner');
  const stale = new Date(Date.now() - 11000); utimesSync(file + '.lock', stale, stale);
  const observed = join(root, 'observed'), resume = join(root, 'resume');
  const committing = join(root, 'committing'), commit = join(root, 'commit');
  const moved = join(root, 'moved'), restore = join(root, 'restore'), reclaiming = join(root, 'reclaiming');
  const prelude = `import fs from 'node:fs'; import * as core from ${JSON.stringify(new URL('../todo/core.mjs', import.meta.url).href)};
    const file=${JSON.stringify(file)};
    function wait(name) { const end=Date.now()+5000; while(!fs.existsSync(name)) { if(Date.now()>end) throw Error('schedule timed out: '+name); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,5); } }`;
  const child = source => {
    const proc = spawn(process.execPath, ['--input-type=module', '-e', prelude + source]);
    let error = '', exited = false; proc.stdout.resume(); proc.stderr.on('data', d => { error += d; });
    const done = new Promise(resolve => proc.once('exit', code => { exited = true; resolve({ code, error }); }));
    t.after(() => { if (!exited) proc.kill('SIGKILL'); });
    return done;
  };
  const until = async predicate => {
    const deadline = Date.now() + 5000;
    while (!predicate()) { assert.ok(Date.now() < deadline, 'scheduled writer reached its pause'); await new Promise(r => setTimeout(r, 5)); }
  };
  const c = child(`const stat=fs.statSync, rename=fs.renameSync; let paused=false;
    fs.statSync=function(name,...args) { const value=stat.call(this,name,...args); if(name===file+'.lock'&&!paused) { paused=true; fs.writeFileSync(${JSON.stringify(observed)},'observed'); wait(${JSON.stringify(resume)}); fs.writeFileSync(${JSON.stringify(reclaiming)},'resumed'); } return value; };
    fs.renameSync=function(from,to) { const value=rename.call(this,from,to); if(from===file+'.lock') { fs.writeFileSync(${JSON.stringify(moved)},'moved'); wait(${JSON.stringify(restore)}); } return value; };
    await core.add(file,'Concurrent C');`);
  await until(() => existsSync(observed));
  const b = child(`const rename=fs.renameSync; let paused=false;
    fs.renameSync=function(from,to) { if(to===file&&!paused) { paused=true; fs.writeFileSync(${JSON.stringify(committing)},'owner checked, before rename'); wait(${JSON.stringify(commit)}); } return rename.call(this,from,to); };
    await core.mutate(file, model => { model.items[0].title='Held B'; });`);
  await until(() => existsSync(committing));
  let d;
  try {
    writeFileSync(resume, 'resume stale reclaimer');
    await until(() => existsSync(reclaiming));
    await new Promise(r => setTimeout(r, 100));
    d = core.add(file, 'Concurrent D');
    // Before the fix, C opens a pathname gap, so D commits an older model.
    if (existsSync(moved)) await d;
  } finally { writeFileSync(restore, 'restore'); writeFileSync(commit, 'commit'); }
  const [resultB, resultC] = await Promise.all([b, c]);
  await d;
  assert.equal(resultB.code, 0, resultB.error); assert.equal(resultC.code, 0, resultC.error);
  assert.deepEqual(core.load(file).items.filter(i => !i.done).map(i => i.title).sort(), ['Concurrent C', 'Concurrent D', 'Held B'],
    'each successful writer survives the delayed reclamation and final rename');
  const archived = core.load(join(root, 'todo-archive.md')).items.map(i => i.title);
  assert.equal(archived.length, 2, 'one archive rotation, even when reclamation overlaps commit');
  assert.equal(new Set(archived).size, 2, 'overflow records must not be appended twice');
});

test('B1: dead-process markers restore moved locks and are removed without stranding writers', async t => {
  const { root, file } = scratch(t);
  await core.add(file, 'Original');
  const child = spawn(process.execPath, ['-e', '']);
  const pid = child.pid; await new Promise(resolve => child.once('exit', resolve));
  const reclaim = `${file}.lock.reclaim-${pid}-00000000-0000-0000-0000-000000000000`;
  const commit = `${file}.lock.commit-${pid}-00000000-0000-0000-0000-000000000000`;
  writeFileSync(reclaim, ''); writeFileSync(commit, ''); writeFileSync(reclaim + '.moved', 'crashed owner');
  const stale = new Date(Date.now() - 11000); utimesSync(reclaim + '.moved', stale, stale);
  await core.add(file, 'Recovered');
  assert.deepEqual(core.load(file).items.map(i => i.title), ['Original', 'Recovered']);
  assert.deepEqual(readdirSync(root).filter(name => name.startsWith('todo.md.lock')), [], 'dead markers and moved locks are cleaned up');
});

test('B1: even an old commit marker belonging to a live process prevents reclamation', async t => {
  const { file } = scratch(t);
  await core.add(file, 'Original'); const before = readFileSync(file, 'utf8');
  const marker = `${file}.lock.commit-${process.pid}-00000000-0000-0000-0000-000000000000`;
  writeFileSync(marker, ''); writeFileSync(file + '.lock', 'stale observed owner');
  const stale = new Date(Date.now() - 11000); utimesSync(marker, stale, stale); utimesSync(file + '.lock', stale, stale);
  await assert.rejects(core.add(file, 'Cannot enter a live commit'), /timed out waiting for lock/);
  assert.equal(readFileSync(file, 'utf8'), before);
  assert.ok(existsSync(marker), 'age cannot retire a live process marker');
});

test('B1: sync retries when a new slug is inserted while status runs outside the lock', async t => {
  const { root, file } = scratch(t), kitStub = join(root, 'kit'); mkdirSync(kitStub);
  const entered = join(root, 'entered'), release = join(root, 'release'), calls = join(root, 'calls');
  writeFileSync(join(kitStub, 'sdlc.sh'), `echo "$2" >> "${calls}"\nif [ ! -f "${entered}" ]; then touch "${entered}"; while [ ! -f "${release}" ]; do sleep 0.01; done; fi\nif [ "$2" = new ]; then state=NEEDS-HUMAN; else state=READY; fi\nprintf '{"features":[{"slug":"%s","phase":"intent","state":"%s","action":"approve intent --human"}]}\\n' "$2" "$state"\n`);
  await core.add(file, 'Old item', { project: root, slug: 'old' });
  const reading = core.next(file, { kit: kitStub });
  const deadline = Date.now() + 4000;
  while (!existsSync(entered)) { assert.ok(Date.now() < deadline, 'status entered'); await new Promise(r => setTimeout(r, 5)); }
  let added;
  try {
    added = await core.add(file, 'New first item', { project: root, slug: 'new' });
    await core.move(file, added.id, -1);
  } finally { writeFileSync(release, 'resume status'); }
  const result = await reading;
  assert.equal(result.code, 10, 'a concurrently inserted slug must be synced before it can be selected');
  assert.equal(result.item.id, added.id);
  assert.equal(result.item.sdlc.state, 'NEEDS-HUMAN');
  assert.ok(readFileSync(calls, 'utf8').includes('new'), 'the new head was queried after the snapshot changed');
});

test('R7 B1: version hashes the block, identical-block position and count', async t => {
  const { file } = scratch(t);
  await core.add(file, 'Duplicate', { by: 'human' });
  await core.add(file, 'Other');
  await core.add(file, 'Duplicate', { by: 'human' });
  await core.mutate(file, model => {
    for (const item of model.items) item.events[0].at = '2026-10-26 09:41';
  });
  const model = core.load(file), [first, other, second] = model.items;
  const block = item => core.serialize({ items: [item] }).split('\n\n').find(block => block.startsWith('- [ ]'));
  assert.equal(block(first), block(second));
  const firstVersion = core.itemVersion(first, model), secondVersion = core.itemVersion(second, model);
  assert.notEqual(firstVersion, secondVersion, 'identical duplicates have distinct versions');
  for (const [position, item] of [first, second].entries()) {
    const expected = createHash('sha256').update(JSON.stringify([block(item), position, 2])).digest('hex');
    assert.equal(core.itemVersion(item, model), expected);
  }
  await core.edit(file, other.id, { title: 'Other edited' });
  await core.move(file, core.load(file).items[1].id, -1);
  const edited = core.load(file);
  assert.equal(core.itemVersion(edited.items[1], edited), firstVersion, 'unrelated edits and moves preserve the version');
  assert.equal(core.itemVersion(edited.items[2], edited), secondVersion);
  await core.remove(file, first.id);
  const remaining = core.load(file), survivor = remaining.items.find(item => item.title === 'Duplicate');
  assert.notEqual(core.itemVersion(survivor, remaining), firstVersion, 'survivor cannot inherit the deleted version');
  assert.notEqual(core.itemVersion(survivor, remaining), secondVersion, 'membership changes invalidate even the surviving position');
  assert.equal(core.itemVersion(survivor, remaining), createHash('sha256').update(JSON.stringify([block(survivor), 0, 1])).digest('hex'));
});

test('M: nativePath converts MSYS paths only on Windows and propagates conversion errors', async () => {
  // The fallback represents the pre-fix path passthrough for assertion-red proof.
  const nativePath = core.nativePath || (async value => value);
  const paths = [
    ['/tmp/inbox', 'C:\\Program Files\\Git\\tmp\\inbox'],
    ['/c/Users/Name/project', 'C:\\Users\\Name\\project'],
    ['/d/a/repo/repo', 'D:\\a\\repo\\repo'],
    ["/d/a/space 'quote' $(literal)/project", "D:\\a\\space 'quote' $(literal)\\project"],
  ];
  for (const [input, expected] of paths) {
    const calls = [];
    const runner = async (...args) => { calls.push(args); return { stdout: `${expected}\r\n` }; };
    assert.equal(await nativePath(input, { platform: 'win32', runner }), expected);
    assert.deepEqual(calls, [['bash', ['-c', 'cygpath -w -- "$1"', 'sdlc-path', input]]], 'path is a positional argument, never shell source');
  }
  const unused = async () => assert.fail('identity paths must not start bash');
  for (const platform of ['darwin', 'linux']) {
    for (const [input] of paths) assert.equal(await nativePath(input, { platform, runner: unused }), input);
  }
  for (const input of ['C:\\Users\\Name', 'D:/a/repo', '\\\\server\\share\\project', '//server/share/project']) {
    assert.equal(await nativePath(input, { platform: 'win32', runner: unused }), input);
  }
  const failure = new Error('cygpath unavailable');
  await assert.rejects(nativePath('/tmp/inbox', { platform: 'win32', runner: async () => { throw failure; } }), error => error === failure);
});
