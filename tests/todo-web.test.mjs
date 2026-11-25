import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, renameSync, symlinkSync, realpathSync, statSync, existsSync, utimesSync } from 'node:fs';
import { tmpdir, networkInterfaces } from 'node:os';
import { dirname, join, resolve, relative as pathRelative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startWeb as startNodeWeb, liveSession, proofOf, runArgv, resolveCommand, commandSearchPath } from '../todo/web.mjs';
import * as core from '../todo/core.mjs';
import { rustServer, startRustWeb } from './rust-server.mjs';

const kit = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// SDLC_TODO_RUST_SERVE=<binary> runs these tests against the Rust server (todo/app/server).
const startWeb = rustServer ? startRustWeb : startNodeWeb;
const nodeOnly = { skip: rustServer && 'replaces the status runner inside the Node process' };
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
- Risk flags: migration no · data deletion no · public API no · security yes · infra no
- Undo: revert the change commit
## Scenarios
| ID | Persona | Steps | Expected | Must | Covers |
|---|---|---|---|---|---|
| S1 | operator | run real CLI | observable output | yes | O1 |
`;

async function web(t, options = {}) {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-web-'));
  const file = join(root, 'todo.md');
  let opened;
  // A temp feed: no test reads or watches ~/.sdlc/todo-feed.json.
  // A fixed command PATH: no test starts the login shell to read its PATH.
  const server = await startWeb({ file, kit, port: 0, open: false, onUrl(url) { opened = url; }, feed: join(root, 'feed.json'), searchPath: '/usr/bin:/bin', ...options });
  t.after(async () => { await server.close(); rmSync(root, { recursive: true, force: true }); });
  const url = new URL(opened || server.url);
  const token = new URLSearchParams(url.hash.slice(1)).get('t');
  assert.equal(url.hostname, '127.0.0.1');
  assert.notEqual(url.port, '0');
  assert.match(token || '', /^[a-f0-9]{32}$/);
  return { root, file, server, url, token };
}

function request(ctx, pathname, { method = 'GET', body, headers = {}, token = ctx.token, hostname = ctx.url.hostname, timeout = 2000 } = {}) {
  return new Promise((resolveResponse, reject) => {
    const data = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
    const requestHeaders = {
      Host: ctx.url.host,
      ...(token ? { 'X-Todo-Token': token } : {}),
      ...(method !== 'GET' ? { Origin: ctx.url.origin, 'Content-Type': 'application/json' } : {}),
      ...(data !== undefined ? { 'Content-Length': Buffer.byteLength(data) } : {}),
      ...headers,
    };
    for (const name of Object.keys(requestHeaders)) if (requestHeaders[name] === null) delete requestHeaders[name];
    const req = http.request({ hostname, port: ctx.url.port, path: pathname, method, headers: requestHeaders }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json;
        try { json = JSON.parse(text); } catch {}
        resolveResponse({ status: res.statusCode, headers: res.headers, text, json });
      });
      res.on('error', reject);
    });
    req.setTimeout(process.platform === 'win32' ? 60000 : timeout, () => req.destroy(new Error('HTTP request timed out')));
    req.on('error', reject);
    req.end(data);
  });
}

function items(response, file) {
  assert.equal(response.status, 200, response.text);
  assert.equal(response.json.file, file);
  assert.ok(Array.isArray(response.json.items), 'response contains the current items');
  return response.json.items;
}

// Ordinary actions read the snapshot they are about to change, as the page does.
async function post(ctx, pathname, body) {
  const snapshot = items(await request(ctx, '/api/items'), ctx.file).find(item => item.id === body.id);
  return request(ctx, pathname, { method: 'POST', body: { version: snapshot?.version, ...body } });
}

function command(program, args, cwd) {
  return execFileSync(program, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}
function sdlc(dir, ...args) { return command('bash', [join(kit, 'sdlc.sh'), ...args], dir); }
function project(root, name = 'project') {
  const dir = join(root, name);
  mkdirSync(dir, { recursive: true });
  command('git', ['-c', 'init.defaultBranch=main', 'init', '-q'], dir);
  command('git', ['config', 'user.name', 'sdlc web test'], dir);
  command('git', ['config', 'user.email', 'todo-web@sdlc.invalid'], dir);
  command('git', ['config', 'core.autocrlf', 'false'], dir);
  writeFileSync(join(dir, 'README'), 'baseline\n');
  command('git', ['add', 'README'], dir);
  command('git', ['commit', '-qm', 'baseline'], dir);
  sdlc(dir, 'init');
  return dir;
}
function feature(dir, slug) {
  sdlc(dir, 'new', slug);
  const folder = join(dir, '.sdlc', 'work', slug);
  writeFileSync(join(folder, 'intent.md'), intent);
  return folder;
}
function gateClosed(dir, gate, slug) {
  assert.throws(() => sdlc(dir, 'check', gate, slug), error => {
    assert.equal(error.status, 1);
    assert.match(error.stdout, /GATE CLOSED/);
    return true;
  });
}

// Real HTTP, including Host, avoids fetch/browser defaults hiding the trust boundary.
test('S9: web token, Host, Origin, JSON and body-size boundaries reject hostile requests', async t => {
  const ctx = await web(t);
  const before = items(await request(ctx, '/api/items'), ctx.file);
  assert.deepEqual(before, []);
  assert.deepEqual((await request(ctx, '/api/live')).json, { ok: true });
  for (const [label, pathname, options] of [
    ['missing token', '/api/items', { token: null }],
    ['live missing token', '/api/live', { token: null }],
    ['bad token', '/api/items', { token: '0'.repeat(32) }],
    ['evil Host', '/api/items', { headers: { Host: 'evil.test' } }],
    ['evil Origin', '/api/items', { method: 'POST', body: { text: 'forged' }, headers: { Origin: 'http://evil.test' } }],
    ['missing Origin', '/api/items', { method: 'POST', body: { text: 'forged' }, headers: { Origin: null } }],
    ['plain text', '/api/items', { method: 'POST', body: '{"text":"forged"}', headers: { 'Content-Type': 'text/plain' } }],
    ['events missing token', '/events', { token: null }],
    ['events bad token', '/events?t=bad', { token: null }],
  ]) {
    const response = await request(ctx, pathname, options);
    assert.equal(response.status, 403, `${label}: ${response.text}`);
  }
  const oversized = await request(ctx, '/api/items', { method: 'POST', body: { text: 'x'.repeat(64 * 1024 + 1) } });
  assert.equal(oversized.status, 413, oversized.text);
  assert.deepEqual(items(await request(ctx, '/api/items'), ctx.file), [], 'rejected requests have no write side effects');
});

test('S9: page has restrictive headers, no token in its bytes, and listens only on loopback', async t => {
  const ctx = await web(t);
  const page = await request(ctx, '/', { token: null });
  assert.equal(page.status, 200, page.text);
  assert.match(page.headers['content-security-policy'] || '', /default-src 'self'/);
  assert.match(page.headers['content-security-policy'] || '', /frame-ancestors 'none'/);
  assert.doesNotMatch(page.headers['content-security-policy'], /unsafe-inline|unsafe-eval/);
  assert.equal(page.headers['x-content-type-options'], 'nosniff');
  assert.equal(page.headers['referrer-policy'], 'no-referrer');
  assert.ok(!page.text.includes(ctx.token), 'token is supplied by the URL fragment, never embedded in HTML');
  const external = Object.values(networkInterfaces()).flat().find(entry => entry && !entry.internal && (entry.family === 'IPv4' || entry.family === 4));
  if (external) await assert.rejects(request(ctx, '/', { hostname: external.address, token: null }), /ECONNREFUSED|EHOSTUNREACH|ENETUNREACH|timed out/);
});

test('S3/S12: HTTP mutations add human history, edit, move, complete, undo, reply and delete', async t => {
  const ctx = await web(t);
  let list = items(await request(ctx, '/api/items', { method: 'POST', body: { text: 'First ~/code/web https://github.com/acme/widget/issues/42' } }), ctx.file);
  const first = list[0];
  assert.equal(first.title, 'First');
  assert.equal(first.project, '~/code/web');
  assert.match(readFileSync(ctx.file, 'utf8'), /human: added/);
  assert.match(readFileSync(ctx.file, 'utf8'), /widget#42/);
  list = items(await request(ctx, '/api/items', { method: 'POST', body: { text: 'Second' } }), ctx.file);
  const second = list.find(item => item.title === 'Second');
  list = items(await post(ctx, '/api/item', { op: 'edit', id: second.id, title: 'Revised second' }), ctx.file);
  const revised = list.find(item => item.title === 'Revised second');
  assert.ok(revised);
  list = items(await post(ctx, '/api/item', { op: 'move', id: revised.id, delta: -1 }), ctx.file);
  assert.equal(list[0].id, revised.id);
  list = items(await post(ctx, '/api/item', { op: 'done', id: revised.id }), ctx.file);
  assert.equal(list.find(item => item.title === 'Revised second').done, true);
  assert.match(readFileSync(ctx.file, 'utf8'), /human: done/);
  list = items(await post(ctx, '/api/item', { op: 'undone', id: revised.id }), ctx.file);
  assert.equal(list.find(item => item.title === 'Revised second').done, false);
  await core.wait(ctx.file, first.id, 'which environment?');
  items(await post(ctx, '/api/item', { op: 'reply', id: first.id, text: 'Use the local environment' }), ctx.file);
  assert.match(readFileSync(ctx.file, 'utf8'), /human: reply — Use the local environment/);
  assert.doesNotMatch(readFileSync(ctx.file, 'utf8'), /waiting: which environment/);
  list = items(await post(ctx, '/api/item', { op: 'delete', id: first.id }), ctx.file);
  assert.deepEqual(list.map(item => item.title), ['Revised second']);
  const unchanged = readFileSync(ctx.file, 'utf8');
  for (const body of [
    { op: 'unknown', id: revised.id }, { op: 'move', id: revised.id, delta: 'up' },
    { op: 'reply', id: revised.id, text: '' }, { op: 'edit', id: revised.id, title: '' },
    { op: 'delete' },
  ]) {
    const invalid = await request(ctx, '/api/item', { method: 'POST', body });
    assert.ok(invalid.status >= 400 && invalid.status < 500, invalid.text);
    assert.equal(readFileSync(ctx.file, 'utf8'), unchanged);
  }
  for (const options of [{ body: '{' }, { body: { text: '' } }]) {
    const invalid = await request(ctx, '/api/items', { method: 'POST', ...options });
    assert.ok(invalid.status >= 400 && invalid.status < 500, invalid.text);
    assert.equal(readFileSync(ctx.file, 'utf8'), unchanged);
  }
});

function eventStream(ctx, t) {
  const frames = [], waiters = [];
  let buffer = '';
  const req = http.get({ hostname: '127.0.0.1', port: ctx.url.port,
    path: `/events?t=${ctx.token}`, headers: { Host: ctx.url.host, Accept: 'text/event-stream' } }, res => {
    assert.equal(res.statusCode, 200);
    assert.match(res.headers['content-type'], /text\/event-stream/);
    res.on('data', chunk => {
      buffer += chunk.toString();
      for (let end; (end = buffer.indexOf('\n\n')) !== -1;) {
        const frame = buffer.slice(0, end); buffer = buffer.slice(end + 2);
        const data = frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trim()).join('\n');
        if (!data) continue;
        const value = JSON.parse(data);
        frames.push(value);
        for (const waiter of [...waiters]) if (waiter.matches(value)) { clearTimeout(waiter.timer); waiters.splice(waiters.indexOf(waiter), 1); waiter.resolve(value); }
      }
    });
  });
  req.on('error', error => { for (const waiter of waiters.splice(0)) { clearTimeout(waiter.timer); waiter.reject(error); } });
  t.after(() => req.destroy());
  return (matches, timeout = 1000) => {
    const previous = frames.find(matches);
    if (previous) return Promise.resolve(previous);
    return new Promise((resolveValue, reject) => {
      const waiter = { matches, resolve: resolveValue, reject };
      waiter.timer = setTimeout(() => { waiters.splice(waiters.indexOf(waiter), 1); reject(new assert.AssertionError({ message: 'SSE change did not arrive within one second', actual: frames, expected: 'matching SSE update' })); }, timeout);
      waiters.push(waiter);
    });
  };
}

test('working: SSE shows a marker at once and drops it when its heartbeat expires, with no further write', async t => {
  const ttl = process.env.SDLC_TODO_WORKING_TTL;
  process.env.SDLC_TODO_WORKING_TTL = '1';
  t.after(() => { if (ttl === undefined) delete process.env.SDLC_TODO_WORKING_TTL; else process.env.SDLC_TODO_WORKING_TTL = ttl; });
  const ctx = await web(t);
  const { id } = await core.add(ctx.file, 'Build it');
  const waitFor = eventStream(ctx, t);
  await waitFor(value => value.items?.some(item => item.id === id));
  const marked = waitFor(value => value.items?.some(item => item.id === id && item.working?.what === 'build'));
  await core.working(ctx.file, id, 'build');
  assert.deepEqual((await marked).items.find(item => item.id === id).turn, { actor: 'agent', kind: 'working' });
  const before = readFileSync(core.workingPath(ctx.file), 'utf8');
  // Frames are matched in order: the first one after the mark that no longer carries it.
  let seen = false;
  const expired = await waitFor(value => {
    const item = value.items?.find(other => other.id === id);
    if (item?.working) seen = true;
    return seen && item?.working === null;
  }, 3000);
  assert.deepEqual(expired.items.find(item => item.id === id).turn, { actor: 'agent', kind: 'new' });
  assert.equal(readFileSync(core.workingPath(ctx.file), 'utf8'), before, 'expiry needs no write');
});

test('S3: SSE observes an external core write within one second without reloading', async t => {
  const ctx = await web(t);
  await core.add(ctx.file, 'Initial');
  const waitFor = eventStream(ctx, t);
  await waitFor(value => value.items?.some(item => item.title === 'Initial'));
  const changed = waitFor(value => value.items?.some(item => item.title === 'External writer'));
  await core.add(ctx.file, 'External writer');
  const update = await changed;
  assert.equal(update.file, ctx.file);
  assert.equal(update.items.length, 2);
});

test('approval without a note opens the gate and records the shown version', async t => {
  const ctx = await web(t);
  const dir = project(ctx.root);
  const slug = 'web-blank-note';
  feature(dir, slug);
  const item = await core.add(ctx.file, 'Approve without a note', { project: dir, slug });
  const shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.json.gate, 'intent', shown.text);
  items(await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha: shown.json.sha, words: '  ' }), ctx.file);
  assert.match(sdlc(dir, 'check', 'intent', slug), /GATE OPEN/);
  assert.ok(readFileSync(ctx.file, 'utf8').includes(
    `human: approved intent — "approved as shown in the to-do web page (version ${shown.json.sha.slice(0, 12)})"`));
});

test('S6/S7/S8: intent artifact bytes bind approval; stale approval and replies keep the gate closed', async t => {
  const ctx = await web(t);
  const dir = project(ctx.root);
  const slug = 'web-intent';
  const folder = feature(dir, slug);
  const child = join(dir, 'src');
  mkdirSync(child);
  const item = await core.add(ctx.file, 'Approve intent', { project: child, slug });
  let shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  assert.equal(shown.json.gate, 'intent');
  assert.equal(realpathSync(shown.json.file), realpathSync(join(folder, 'intent.md')), 'artifact uses the ancestor SDLC store');
  assert.equal(shown.json.markdown, intent);
  assert.equal(shown.json.sha, createHash('sha256').update(intent).digest('hex'));
  writeFileSync(join(folder, 'intent.md'), intent + '\nEdited after the browser opened.\n');
  const stale = await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha: shown.json.sha, words: 'approved the displayed scope' });
  assert.equal(stale.status, 409, stale.text);
  assert.match(stale.text, /changed since/i);
  gateClosed(child, 'intent', slug);
  items(await post(ctx, '/api/item', { op: 'reply', id: item.id, text: 'Please keep the first outcome' }), ctx.file);
  assert.match(readFileSync(ctx.file, 'utf8'), /human: reply — Please keep the first outcome/);
  gateClosed(child, 'intent', slug);
  shown = await request(ctx, `/api/artifact?id=${item.id}`);
  const words = 'approved the revised intent scope';
  items(await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha: shown.json.sha, words }), ctx.file);
  assert.match(sdlc(child, 'check', 'intent', slug), /GATE OPEN/);
  assert.ok(readFileSync(ctx.file, 'utf8').includes(`human: approved intent — "${words}"`));
});

test('an open item without an approval gate shows its work document read-only', async t => {
  const ctx = await web(t);
  const dir = project(ctx.root);
  const slug = 'web-readonly';
  const folder = feature(dir, slug);
  sdlc(dir, 'approve', 'intent', slug, '--human', 'approved the planned outcomes');
  const item = await core.add(ctx.file, 'Planning work', { project: dir, slug });
  let shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  assert.equal(shown.json.gate, '', 'no gate: nothing to approve');
  assert.equal(realpathSync(shown.json.file), realpathSync(join(folder, 'intent.md')), 'before a plan exists, the intent is the work document');
  assert.equal(shown.json.markdown, readFileSync(join(folder, 'intent.md'), 'utf8'));
  const refused = await post(ctx, '/api/approve', { id: item.id, gate: 'plan', sha: shown.json.sha, words: 'approved what I read' });
  assert.equal(refused.status, 409, refused.text);
  gateClosed(dir, 'plan', slug);
  writeFileSync(join(folder, 'PLAN.md'), plan);
  shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(realpathSync(shown.json.file), realpathSync(join(folder, 'PLAN.md')), 'once a plan exists, it is the work document');
});

test('S6/S7: plan approval binds displayed bytes and targets the selected project', async t => {
  const ctx = await web(t);
  const one = project(ctx.root, 'one');
  const two = project(ctx.root, 'two');
  const slug = 'shared-slug';
  const folderOne = feature(one, slug);
  const folderTwo = feature(two, slug);
  for (const [dir, folder] of [[one, folderOne], [two, folderTwo]]) {
    sdlc(dir, 'approve', 'intent', slug, '--human', 'approved the planned outcomes');
    writeFileSync(join(folder, 'PLAN.md'), plan);
  }
  await core.add(ctx.file, 'First project plan', { project: one, slug });
  const item = await core.add(ctx.file, 'Second project plan', { project: two, slug });
  let shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  assert.equal(shown.json.gate, 'plan');
  assert.equal(realpathSync(shown.json.file), realpathSync(join(folderTwo, 'PLAN.md')));
  writeFileSync(join(folderTwo, 'PLAN.md'), plan + '\nA revised implementation detail.\n');
  const stale = await post(ctx, '/api/approve', { id: item.id, gate: 'plan', sha: shown.json.sha, words: 'approved the displayed plan' });
  assert.equal(stale.status, 409, stale.text);
  assert.match(stale.text, /changed since/i);
  gateClosed(two, 'plan', slug);
  shown = await request(ctx, `/api/artifact?id=${item.id}`);
  const words = 'approved the revised plan and security risk';
  items(await post(ctx, '/api/approve', { id: item.id, gate: 'plan', sha: shown.json.sha, words }), ctx.file);
  assert.match(sdlc(two, 'check', 'plan', slug), /GATE OPEN/);
  gateClosed(one, 'plan', slug);
  assert.ok(readFileSync(ctx.file, 'utf8').includes(`human: approved plan — "${words}"`));
});

test('artifact and approval validation reject unknown ids, gates and hashes', async t => {
  const ctx = await web(t);
  const item = await core.add(ctx.file, 'No SDLC feature');
  for (const pathname of ['/api/artifact', '/api/artifact?id=missing', `/api/artifact?id=${item.id}`]) {
    const response = await request(ctx, pathname);
    assert.ok(response.status >= 400 && response.status < 500, response.text);
  }
  const before = readFileSync(ctx.file, 'utf8');
  for (const body of [
    {}, { id: item.id, gate: 'build', sha: 'a'.repeat(64), words: 'approved scope' },
    { id: item.id, gate: 'intent', sha: 'bad', words: 'approved scope' },
    { id: 'missing', gate: 'intent', sha: 'a'.repeat(64), words: 'approved scope' },
  ]) {
    const response = await request(ctx, '/api/approve', { method: 'POST', body });
    assert.ok(response.status >= 400 && response.status < 500, response.text);
    assert.equal(readFileSync(ctx.file, 'utf8'), before);
  }
});

test('artifact Markdown renders requested syntax while escaping HTML and dropping unsafe links', async () => {
  // The page is a browser ES module; a data URL also runs it under Node 18 without changing package type.
  const source = readFileSync(join(kit, 'todo', 'page', 'markdown.js'), 'utf8');
  const { renderMarkdown } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  const rendered = renderMarkdown([
    '# Scope', '', '**Bold** and `inline <code>` with [safe](https://example.test/a).', '',
    '- Parent', '  - Child', '  1. Numbered child', '- Sibling', '',
    '| Name | Value |', '|---|---|', '| left \\| right | **cell** |', '',
    '```html', '<script>alert("fenced")</script>', '- literal list', '```', '',
    '<img src=x onerror=alert("raw")>', '<!-- hidden <script>comment</script> -->',
    '[unsafe](javascript:alert(1))', '[also unsafe](data:text/html,bad)',
  ].join('\n'));
  assert.match(rendered, /<h1[^>]*>Scope<\/h1>/);
  assert.match(rendered, /<strong>Bold<\/strong>/);
  assert.match(rendered, /<code>inline &lt;code&gt;<\/code>/);
  assert.match(rendered, /<ul[\s>]/);
  assert.match(rendered, /<ol[\s>]/);
  assert.match(rendered, /<li[^>]*>Parent[\s\S]*<ul[\s>]/, 'child list stays inside its parent item');
  assert.match(rendered, /<table[\s>]/);
  assert.match(rendered, /<t[dh][^>]*>left \| right<\/t[dh]>/);
  assert.match(rendered, /<pre[^>]*><code[^>]*>[\s\S]*&lt;script&gt;alert/);
  assert.match(rendered, /&lt;img src=x onerror=/);
  assert.doesNotMatch(rendered, /<(?:script|img)\b|<!--/i);
  assert.doesNotMatch(rendered, /href=["'](?:javascript|data):/i);
  assert.match(rendered, /href="https:\/\/example\.test\/a"/);
  assert.match(rendered, /rel="noopener noreferrer"/);
});

// Execute the agent document's gate-stop instruction, then use the real interfaces.
for (const channel of ['web', 'chat']) test(`B2: documented ${channel} approval resumes next without an explicit gate wait`, async t => {
  const ctx = await web(t), dir = project(ctx.root), slug = `documented-${channel}`;
  const folder = feature(dir, slug);
  const item = await core.add(ctx.file, 'Gate approval', { project: dir, slug });
  await core.add(ctx.file, 'Lower item');
  assert.equal((await core.next(ctx.file, { kit })).code, 10);
  const instructions = readFileSync(join(kit, 'todo', 'AGENT.md'), 'utf8');
  if (/When sdlc needs the human, run `wait/.test(instructions)) await core.wait(ctx.file, item.id, 'approve intent');
  if (channel === 'web') {
    const shown = await request(ctx, `/api/artifact?id=${item.id}`);
    items(await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha: shown.json.sha, words: 'approved scope' }), ctx.file);
  } else {
    sdlc(dir, 'approve', 'intent', slug, '--human', 'approved scope');
    execFileSync(process.execPath, [join(kit, 'todo', 'todo.mjs'), 'note', item.id, 'chat: approved intent — "approved scope"'], { cwd: dir, env: { ...process.env, SDLC_TODO: ctx.file } });
  }
  assert.match(sdlc(dir, 'check', 'intent', slug), /GATE OPEN/);
  const result = await core.next(ctx.file, { kit });
  assert.equal(result.code, 0, `approved gate still waits: ${result.item?.waiting}`);
  assert.equal(result.item.id, item.id);
  // A separate unanswered question survives an approval in either channel.
  writeFileSync(join(folder, 'PLAN.md'), plan);
  await core.wait(ctx.file, item.id, 'which environment?');
  if (channel === 'web') {
    const shown = await request(ctx, `/api/artifact?id=${item.id}`);
    items(await post(ctx, '/api/approve', { id: item.id, gate: 'plan', sha: shown.json.sha, words: 'approved plan' }), ctx.file);
  } else {
    sdlc(dir, 'approve', 'plan', slug, '--human', 'approved plan');
    execFileSync(process.execPath, [join(kit, 'todo', 'todo.mjs'), 'note', item.id, 'chat: approved plan — "approved plan"'], { cwd: dir, env: { ...process.env, SDLC_TODO: ctx.file } });
  }
  const waiting = await core.next(ctx.file, { kit });
  assert.equal(waiting.code, 10);
  assert.equal(waiting.item.waiting, 'which environment?');
});

test('B3: symlinked project reads and approves the reported status store with a duplicate slug', async t => {
  const ctx = await web(t);
  const logical = project(ctx.root, 'logical'), physical = project(ctx.root, 'physical');
  const slug = 'probe';
  const wrong = feature(logical, slug), right = feature(physical, slug);
  writeFileSync(join(wrong, 'intent.md'), intent + '\nWrong logical store.\n');
  writeFileSync(join(right, 'intent.md'), intent + '\nPhysical store.\n');
  mkdirSync(join(physical, 'src'));
  const alias = join(logical, 'alias'); symlinkSync(join(physical, 'src'), alias, process.platform === 'win32' ? 'junction' : 'dir');
  const item = await core.add(ctx.file, 'Symlink project', { project: alias, slug });
  const status = JSON.parse(sdlc(alias, 'status', slug, '--json'));
  const shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  const store = await core.nativePath(status.store);
  assert.equal(realpathSync(shown.json.file), realpathSync(join(store, 'work', slug, 'intent.md')));
  const selected = realpathSync(store) === realpathSync(join(logical, '.sdlc')) ? logical : physical;
  const other = selected === logical ? physical : logical;
  assert.equal(shown.json.markdown, readFileSync(join(selected, '.sdlc', 'work', slug, 'intent.md'), 'utf8'));
  items(await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha: shown.json.sha, words: 'approved physical scope' }), ctx.file);
  assert.match(sdlc(alias, 'check', 'intent', slug), /GATE OPEN/);
  gateClosed(other, 'intent', slug);
});

test('N: artifact and approval use the status runner store instead of the realpath ancestor', nodeOnly, async t => {
  let store;
  const calls = [];
  const ctx = await web(t, { statusRunner: async (...args) => {
    calls.push(args);
    return { stdout: JSON.stringify({ store }) };
  } });
  const physical = project(ctx.root, 'physical'), reported = project(ctx.root, 'reported'), slug = 'probe';
  const wrong = feature(physical, slug), right = feature(reported, slug);
  writeFileSync(join(wrong, 'intent.md'), intent + '\nWrong realpath store.\n');
  writeFileSync(join(right, 'intent.md'), intent + '\nReported store.\n');
  mkdirSync(join(physical, 'src'));
  const dir = join(physical, 'src');
  store = join(reported, '.sdlc');
  const item = await core.add(ctx.file, 'Reported store', { project: dir, slug });
  const shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  assert.equal(realpathSync(shown.json.file), realpathSync(join(right, 'intent.md')), 'artifact must use the reported store');
  assert.equal(shown.json.markdown, readFileSync(join(right, 'intent.md'), 'utf8'));
  items(await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha: shown.json.sha, words: 'approved reported scope' }), ctx.file);
  assert.match(sdlc(reported, 'check', 'intent', slug), /GATE OPEN/);
  gateClosed(physical, 'intent', slug);
  assert.deepEqual(calls, Array(2).fill(['bash', [join(kit, 'sdlc.sh'), 'status', slug, '--json'], { cwd: dir }]));
});

for (const missing of [true, false]) test(`N: store lookup ${missing ? 'without a reported store' : 'failure'} never falls back to a project ancestor`, nodeOnly, async t => {
  const ctx = await web(t, { statusRunner: async () => {
    if (missing) return { stdout: '{}' };
    throw new Error('status runner failed');
  } });
  const dir = project(ctx.root), slug = 'probe', folder = feature(dir, slug);
  const item = await core.add(ctx.file, 'No fallback', { project: dir, slug });
  const shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, missing ? 409 : 400, 'artifact must refuse a failed store lookup');
  assert.match(shown.json.error, missing ? /status did not report a store/ : /status runner failed/);
  const sha = createHash('sha256').update(readFileSync(join(folder, 'intent.md'))).digest('hex');
  const response = await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha, words: 'approved scope' });
  assert.equal(response.status, 409, response.text);
  gateClosed(dir, 'intent', slug);
  assert.doesNotMatch(readFileSync(ctx.file, 'utf8'), /human: approved/);
});

test('R5 B1: web add stores a relative project against the server cwd', async t => {
  const ctx = await web(t);
  const list = items(await request(ctx, '/api/items', { method: 'POST', body: { text: 'Web work ./project' } }), ctx.file);
  const expected = resolve('./project');
  assert.equal(list[0].project, expected);
  assert.equal(core.load(ctx.file).items[0].project, expected);
  assert.equal(list[0].id, core.itemId({ project: expected, title: 'Web work' }));
});

for (const operation of ['artifact', 'approve']) test(`R5 B1: web ${operation} refuses a hand-edited relative project`, async t => {
  const ctx = await web(t), dir = project(ctx.root), slug = 'relative-web';
  const folder = feature(dir, slug);
  // This path exists from the server cwd: refusing must precede any project lookup.
  const relative = './' + pathRelative(process.cwd(), dir);
  writeFileSync(ctx.file, `# To-do\n\n## Open\n\n- [ ] Hand edited\n  - project: ${relative}\n  - sdlc: ${slug} · intent · NEEDS-HUMAN — approve intent --human\n\n## Done\n`);
  const item = core.load(ctx.file).items[0];
  const response = operation === 'artifact' ? await request(ctx, `/api/artifact?id=${item.id}`) :
    await post(ctx, '/api/approve', { id: item.id, gate: 'intent',
      sha: createHash('sha256').update(readFileSync(join(folder, 'intent.md'))).digest('hex'), words: 'approved shown scope' });
  assert.equal(response.status, 409, response.text);
  assert.equal(response.json.error, 'relative project path: write an absolute or ~/ path');
  assert.equal(core.load(ctx.file).items[0].project, relative);
  gateClosed(dir, 'intent', slug);
  assert.doesNotMatch(readFileSync(ctx.file, 'utf8'), /human: approved/);
});


// Explicit stale snapshots bypass the fresh-snapshot helper used by ordinary actions.
const changedMessage = 'This item changed. Reload and try again.';
async function duplicateSnapshot(ctx) {
  for (const record of ['record A', 'record B']) {
    const item = await core.add(ctx.file, 'Duplicate', { by: 'human' });
    await core.note(ctx.file, item.id, record);
  }
  const list = items(await request(ctx, '/api/items'), ctx.file);
  const first = list[0];
  // The fallback lets the base server reach the behavioral assertion without a new export.
  return { ...first, version: first.version || 'a'.repeat(64) };
}
for (const op of ['delete', 'move', 'done', 'edit', 'undone', 'reply']) {
  test(`B1: stale ${op} refuses a duplicate that inherited the shown item's id`, async t => {
    const ctx = await web(t);
    const shown = await duplicateSnapshot(ctx);
    await core.remove(ctx.file, shown.id);
    await core.add(ctx.file, 'Tail');
    const before = readFileSync(ctx.file, 'utf8');
    const response = await request(ctx, '/api/item', { method: 'POST', body: {
      id: shown.id, version: shown.version, op, delta: 1, title: 'Wrong rename', text: 'Wrong reply'
    } });
    assert.equal(response.status, 409, `stale ${op} must not change record B: ${response.text}`);
    assert.equal(response.json.error, changedMessage);
    assert.equal(readFileSync(ctx.file, 'utf8'), before, 'record B and order survive unchanged');
    assert.ok(core.load(ctx.file).items[0].events.some(e => e.what === 'record B'));
  });
}
for (const op of ['delete', 'move', 'done']) {
  test(`B1: stale ${op} returns 409 when the shown id is gone`, async t => {
    const ctx = await web(t);
    const shown = await duplicateSnapshot(ctx);
    await core.remove(ctx.file, shown.id);
    await core.remove(ctx.file, shown.id);
    const response = await request(ctx, '/api/item', { method: 'POST', body: {
      id: shown.id, version: shown.version, op, delta: 1
    } });
    assert.equal(response.status, 409, response.text);
    assert.equal(response.json.error, changedMessage);
    assert.deepEqual(core.load(ctx.file).items, []);
  });
}
test('B1: same-id external edits and omitted versions cannot mutate an item', async t => {
  const ctx = await web(t);
  const shown = await duplicateSnapshot(ctx);
  await core.note(ctx.file, shown.id, 'external update');
  const before = readFileSync(ctx.file, 'utf8');
  for (const version of [shown.version, null, undefined]) {
    const response = await request(ctx, '/api/item', { method: 'POST', body: { id: shown.id, version, op: 'delete' } });
    assert.equal(response.status, 409, response.text);
    assert.equal(response.json.error, changedMessage);
    assert.equal(readFileSync(ctx.file, 'utf8'), before);
  }
});
test('B1: approval checks the shown item inside the mutation lock before opening its gate', async t => {
  const ctx = await web(t), dir = project(ctx.root), slug = 'stale-approval';
  feature(dir, slug);
  const item = await core.add(ctx.file, 'Approve shown item', { project: dir, slug });
  const artifact = await request(ctx, `/api/artifact?id=${item.id}`);
  const shown = items(await request(ctx, '/api/items'), ctx.file).find(i => i.id === item.id);
  const version = shown.version || 'a'.repeat(64);
  let entered;
  const locked = new Promise(resolve => { entered = resolve; });
  let release;
  const hold = new Promise(resolve => { release = resolve; });
  const writer = core.mutate(ctx.file, async model => {
    entered();
    await hold;
    core.findItem(model, item.id).notes.push('  external edit while approval queued');
  });
  await locked;
  const approval = request(ctx, '/api/approve', { method: 'POST', body: {
    id: item.id, version, gate: 'intent', sha: artifact.json.sha, words: 'approved shown scope'
  } });
  release();
  await writer;
  const response = await approval;
  assert.equal(response.status, 409, response.text);
  assert.equal(response.json.error, changedMessage);
  gateClosed(dir, 'intent', slug);
  assert.doesNotMatch(readFileSync(ctx.file, 'utf8'), /human: approved/);
});

test('R7 B1: snapshots expose sha256 of the block, identical-block position and count', async t => {
  const ctx = await web(t);
  await duplicateSnapshot(ctx);
  const shown = items(await request(ctx, '/api/items'), ctx.file)[0];
  const block = readFileSync(ctx.file, 'utf8').split('\n\n').find(block => block.startsWith('- [ ] Duplicate'));
  assert.equal(shown.version, createHash('sha256').update(JSON.stringify([block, 0, 1])).digest('hex'));
});
for (const scenario of ['missing target', 'missing version']) {
  test(`B1: approval rejects a ${scenario} with the changed-target message`, async t => {
    const ctx = await web(t), dir = project(ctx.root), slug = 'missing-approval';
    feature(dir, slug);
    const item = await core.add(ctx.file, 'Approve shown item', { project: dir, slug });
    const artifact = await request(ctx, `/api/artifact?id=${item.id}`);
    const shown = items(await request(ctx, '/api/items'), ctx.file)[0];
    if (scenario === 'missing target') await core.remove(ctx.file, item.id);
    const response = await request(ctx, '/api/approve', { method: 'POST', body: {
      id: item.id, version: scenario === 'missing version' ? undefined : shown.version || 'a'.repeat(64),
      gate: 'intent', sha: artifact.json.sha, words: 'approved shown scope'
    } });
    assert.equal(response.status, 409, response.text);
    assert.equal(response.json.error, changedMessage);
    gateClosed(dir, 'intent', slug);
  });
}

for (const op of ['delete', 'done', 'move']) {
  test(`R7 B1: stale ${op} refuses a surviving identical same-minute duplicate`, async t => {
    const ctx = await web(t);
    await core.add(ctx.file, 'Duplicate', { project: ctx.root, by: 'human' });
    await core.add(ctx.file, 'Duplicate', { project: ctx.root, by: 'human' });
    await core.mutate(ctx.file, model => {
      for (const item of model.items) item.events[0].at = '2026-10-26 09:41';
    });
    const model = core.load(ctx.file);
    assert.equal(core.serialize({ items: [model.items[0]] }), core.serialize({ items: [model.items[1]] }));
    const shown = items(await request(ctx, '/api/items'), ctx.file)[0];
    await core.remove(ctx.file, shown.id);
    const before = readFileSync(ctx.file, 'utf8');
    const response = await request(ctx, '/api/item', { method: 'POST', body: {
      op, id: shown.id, version: shown.version, delta: 1
    } });
    assert.equal(response.status, 409, `stale ${op} must refuse the surviving duplicate`);
    assert.equal(response.json.error, changedMessage);
    assert.equal(core.load(ctx.file).items.length, 1);
    assert.equal(readFileSync(ctx.file, 'utf8'), before);
  });
}

test('R7 B1: unrelated item edits keep the shown version usable', async t => {
  const ctx = await web(t);
  await core.add(ctx.file, 'Keep');
  const other = await core.add(ctx.file, 'Other');
  const shown = items(await request(ctx, '/api/items'), ctx.file)[0];
  await core.edit(ctx.file, other.id, { title: 'Other edited' });
  const current = items(await request(ctx, '/api/items'), ctx.file)[0];
  assert.equal(current.version, shown.version);
  const response = await request(ctx, '/api/item', { method: 'POST', body: {
    op: 'done', id: shown.id, version: shown.version
  } });
  assert.equal(response.status, 200, response.text);
  assert.ok(core.load(ctx.file).items.find(item => item.title === 'Keep').done);
});

test('M: approval resolves its store, runs one authoritative approve and refreshes status', async t => {
  const ctx = await web(t);
  const stub = join(ctx.root, 'kit'), calls = join(stub, 'calls');
  mkdirSync(stub);
  writeFileSync(join(stub, 'sdlc.sh'), `printf '%s\\n' "$1" >> "$(dirname "$0")/calls"
if [ "$1" = status ]; then
  printf '{"store":"%s/.sdlc","features":[{"slug":"probe","phase":"intent","state":"NEEDS-HUMAN","action":"approve intent --human"}]}\\n' "$PWD"
fi
`);
  const server = await startWeb({ file: ctx.file, kit: stub, onUrl() {}, feed: join(ctx.root, 'feed.json') });
  t.after(() => server.close());
  const url = new URL(server.url), token = new URLSearchParams(url.hash.slice(1)).get('t');
  const target = { ...ctx, url, token };
  const dir = project(ctx.root), folder = feature(dir, 'probe');
  const item = await core.add(ctx.file, 'Approve selected', { project: dir, slug: 'probe' });
  const shown = await request(target, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  assert.equal(shown.json.markdown, readFileSync(join(folder, 'intent.md'), 'utf8'));
  assert.deepEqual(readFileSync(calls, 'utf8').trim().split(/\r?\n/), ['status', 'status'], 'artifact refreshes its gate and resolves its store');
  const model = core.load(ctx.file), version = core.itemVersion(model.items[0], model);
  writeFileSync(calls, '');
  const response = await request(target, '/api/approve', { method: 'POST', body: {
    id: item.id, version, gate: 'intent', sha: shown.json.sha, words: 'approved shown scope'
  } });
  assert.equal(response.status, 200, response.text);
  assert.deepEqual(readFileSync(calls, 'utf8').trim().split(/\r?\n/), ['status', 'approve', 'status'], 'store lookup precedes approval; one inbox refresh follows');
  assert.ok(core.load(ctx.file).items[0].events.some(e => e.who === 'human' && e.what === 'approved intent — "approved shown scope"'));
});

test('language: payload and live snapshot carry the configured language; locale modules are served as JS', async t => {
  const { languages, defaultLanguage } = await import('../todo/i18n.mjs');
  const other = languages.find(l => l !== defaultLanguage);
  assert.equal((await request(await web(t), '/api/items')).json.lang, defaultLanguage);
  const ctx = await web(t, { lang: other });
  assert.equal((await request(ctx, '/api/items')).json.lang, other);
  const added = await request(ctx, '/api/items', { method: 'POST', body: { text: 'Translated page' } });
  assert.equal(added.json.lang, other, 'mutation responses keep the language');
  for (const pathname of ['/i18n.mjs', ...languages.map(l => `/locales/${l}.mjs`)]) {
    const asset = await request(ctx, pathname, { token: null });
    assert.equal(asset.status, 200, pathname);
    assert.match(asset.headers['content-type'], /^text\/javascript/);
  }
  assert.equal((await request(ctx, '/locales/../web.mjs', { token: null })).status, 404);
  assert.equal((await request(ctx, '/locales/xx.mjs', { token: null })).status, 404);
  await assert.rejects(startWeb({ file: ctx.file, kit, lang: 'xx', onUrl() {} }), /invalid language/);
});

test('session file shares the running server with the owner only and goes away on close', async t => {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-session-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const file = join(root, 'todo.md'), session = join(root, 'todo-web.json');
  await core.add(file, 'Needs nothing yet');
  const server = await startWeb({ file, kit, port: 0, open: false, onUrl() {}, session, feed: join(dirname(file), 'feed.json') });
  const stored = JSON.parse(readFileSync(session, 'utf8'));
  assert.match(stored.token, /^[a-f0-9]{32}$/);
  assert.equal(stored.pid, process.pid);
  if (process.platform !== 'win32') assert.equal(statSync(session).mode & 0o777, 0o600);
  const live = await liveSession(session);
  assert.equal(live.url, server.url);
  const url = new URL(server.url);
  const listed = items(await request({ url, token: stored.token }, '/api/items'), file);
  assert.deepEqual(listed[0].turn, { actor: 'agent', kind: 'new' });
  await server.close();
  assert.equal(existsSync(session), false);
  assert.equal(await liveSession(session), null);
  writeFileSync(session, JSON.stringify({ port: Number(url.port), token: stored.token, pid: 1 }));
  assert.equal(await liveSession(session), null, 'a stale file whose server is gone is not live');
});

test('a session is live only when its server proves it holds the token, which never travels', async t => {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-proof-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const file = join(root, 'todo.md'), session = join(root, 'todo-web.json');
  await core.add(file, 'One');
  const server = await startWeb({ file, kit, port: 0, open: false, onUrl() {}, session, feed: join(root, 'feed.json') });
  const { port, token } = JSON.parse(readFileSync(session, 'utf8'));
  const nonce = 'ab'.repeat(16);
  const ask = async path => { const response = await fetch(`http://127.0.0.1:${port}${path}`); return { status: response.status, body: await response.text() }; };
  assert.deepEqual(JSON.parse((await ask(`/proof?n=${nonce}`)).body), { proof: proofOf(token, nonce) });
  for (const path of ['/proof', '/proof?n=xyz', `/proof?n=${'AB'.repeat(16)}`]) assert.equal((await ask(path)).status, 400, path);
  assert.ok(await liveSession(session));
  await server.close();
  // Another program on the port answers 200 to anything, or a made-up proof.
  const http = await import('node:http');
  const seen = [];
  for (const answer of ['{"ok":true}', JSON.stringify({ proof: '0'.repeat(64) })]) {
    const stranger = http.createServer((req, res) => { seen.push([req.url, JSON.stringify(req.headers)]); res.end(answer); });
    await new Promise(resolve => stranger.listen(port, '127.0.0.1', resolve));
    writeFileSync(session, JSON.stringify({ port, token, pid: 1 }));
    assert.equal(await liveSession(session), null, answer);
    await new Promise(resolve => stranger.close(resolve));
  }
  assert.equal(seen.length, 2);
  // One that answers without end is cut off after 4 KiB, before anything is parsed, and is not live.
  // 64 MiB is far more than the loopback buffers of any OS take (Linux took the whole 1 MiB a reader never asked for).
  let sent = 0; const flood64 = 64 << 20;
  const flood = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    const more = () => { while (sent < flood64 && res.write('{"proof":"' + 'a'.repeat(4096))) sent += 4106; if (sent < flood64) res.once('drain', more); else res.end(); };
    more();
  });
  await new Promise(resolve => flood.listen(port, '127.0.0.1', resolve));
  writeFileSync(session, JSON.stringify({ port, token, pid: 1 }));
  // The size limit, not the 2 s timeout, is what stops it.
  const started = performance.now();
  assert.equal(await liveSession(session), null);
  assert.ok(performance.now() - started < 1800, 'the byte limit stopped the read before the timeout');
  flood.closeAllConnections?.();
  await new Promise(resolve => flood.close(resolve));
  assert.ok(sent < flood64, `stopped reading after ${sent} bytes were offered`);
  assert.ok(seen.every(([url, headers]) => url.startsWith('/proof?n=') && !url.includes(token) && !headers.includes(token)));
  assert.notEqual(seen[0][0], seen[1][0], 'a fresh nonce each time');
});

test('tray server streams the saved board before slow project status refresh', async t => {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-slow-sync-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const file = join(root, 'todo.md');
  const session = join(root, 'todo-web.json');
  const release = join(root, 'release');
  await core.add(file, 'Saved item', { project: root, slug: 'probe' });
  writeFileSync(join(root, 'sdlc.sh'), `
for attempt in 1 2 3 4 5; do
  [ ! -f "$PWD/release" ] || break
  sleep 1
done
printf '%s\\n' '{"features":[{"slug":"probe","phase":"plan","state":"READY"}]}'
`);
  const server = await startWeb({ file, kit: root, session, onUrl() {}, deferInitialSync: true });
  t.after(() => server.close());
  const url = new URL(server.url);
  const ctx = { url, token: new URLSearchParams(url.hash.slice(1)).get('t') };
  const frame = eventStream(ctx, t);
  try {
    const initial = await frame(value => value.items?.length === 1);
    assert.equal(initial.items[0].sdlc.state, '');
  } finally {
    writeFileSync(release, '');
  }
  const updated = await frame(value => value.items?.[0]?.sdlc?.state === 'READY', 7000);
  assert.equal(updated.items[0].title, 'Saved item');
});

test('web fix records the request on a block and reports whether an agent started', async t => {
  const ctx = await web(t), dir = project(ctx.root);
  mkdirSync(join(dir, '.sdlc', 'work', 'legacy'));
  const blocked = await core.add(ctx.file, 'Blocked legacy', { project: dir, slug: 'legacy' });
  const open = await core.add(ctx.file, 'Workable');
  const refused = await post(ctx, '/api/item', { id: open.id, op: 'fix' });
  assert.equal(refused.status, 409, refused.text);
  const response = await post(ctx, '/api/item', { id: blocked.id, op: 'fix' });
  assert.equal(response.json.launch, 'queued');
  const item = items(response, ctx.file).find(i => i.id === blocked.id);
  assert.deepEqual(item.turn, { actor: 'agent', kind: 'handoff' });
  assert.equal(item.events.at(-1).what, 'fix requested');
});

test('brief: a plain item serves its brief as an ungated document; a missing or relative brief fails; a gate keeps its artifact', async t => {
  const ctx = await web(t);
  const brief = join(ctx.root, 'brief.md');
  const markdown = '# Brief\n## At a glance\n- **Your call:** pick a vendor\n';
  writeFileSync(brief, markdown);
  const item = await core.add(ctx.file, 'Choose a vendor', { brief });
  const listed = items(await request(ctx, '/api/items'), ctx.file).find(i => i.id === item.id);
  assert.equal(listed.brief, brief);
  const shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  assert.deepEqual(shown.json, { gate: '', file: brief, markdown, sha: createHash('sha256').update(markdown).digest('hex') });
  const approve = await post(ctx, '/api/approve', { id: item.id, gate: 'intent', sha: shown.json.sha });
  assert.equal(approve.status, 409, 'a brief never opens a gate');
  rmSync(brief);
  assert.equal((await request(ctx, `/api/artifact?id=${item.id}`)).status, 404);
  writeFileSync(ctx.file, readFileSync(ctx.file, 'utf8').replace(`  - brief: ${brief}`, '  - brief: relative.md'));
  assert.equal((await request(ctx, `/api/artifact?id=${item.id}`)).status, 409);
  const dir = project(ctx.root);
  feature(dir, 'gated-brief');
  writeFileSync(brief, markdown);
  const gated = await core.add(ctx.file, 'Gated', { project: dir, slug: 'gated-brief', brief });
  const gate = await request(ctx, `/api/artifact?id=${gated.id}`);
  assert.equal(gate.json.gate, 'intent', gate.text);
  assert.equal(realpathSync(gate.json.file), realpathSync(join(dir, '.sdlc', 'work', 'gated-brief', 'intent.md')));
});

test('artifact syncs only the requested item, not every open sdlc item', async t => {
  // A full sync ran sdlc.sh status for each open item (~10 s for 35) and the app timed out reading the response.
  const ctx = await web(t);
  const dir = project(ctx.root);
  const slug = 'web-only-this';
  feature(dir, slug);
  const item = await core.add(ctx.file, 'Shown item', { project: dir, slug });
  const other = await core.add(ctx.file, 'Other item', { project: dir, slug: 'missing-feature' });
  const shown = await request(ctx, `/api/artifact?id=${item.id}`);
  assert.equal(shown.status, 200, shown.text);
  assert.equal(shown.json.gate, 'intent');
  const model = core.load(ctx.file);
  assert.equal(model.items.find(i => i.id === item.id).sdlc.state, 'NEEDS-HUMAN', 'the shown item is synced');
  assert.equal(model.items.find(i => i.id === other.id).sdlc.state, '', 'another item keeps its last state (no status call)');
});

test('feed: without SDLC_TODO_FEED the feed sits beside the list, never in ~/.sdlc for another list', async () => {
  const { feedPath } = await import('../todo/web.mjs');
  const saved = process.env.SDLC_TODO_FEED;
  delete process.env.SDLC_TODO_FEED;
  try { assert.equal(feedPath('/tmp/x/todo.md'), join('/tmp/x', 'todo-feed.json')); }
  finally { if (saved !== undefined) process.env.SDLC_TODO_FEED = saved; }
});

test('feed: /api/feed needs the token like every /api route; a missing feed is no feed', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'sdlc-todo-feed-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const ctx = await web(t, { feed: join(dir, 'missing', 'feed.json') });
  for (const token of [null, '0'.repeat(32)]) assert.equal((await request(ctx, '/api/feed', { token })).status, 403);
  const response = await request(ctx, '/api/feed');
  assert.equal(response.status, 200, response.text);
  assert.deepEqual(response.json, { feed: null, error: '' });
  const snapshot = await request(ctx, '/api/items');
  assert.equal(snapshot.json.feed, null);
  assert.equal(snapshot.json.feedError, undefined);
});

test('feed: an invalid feed says so, and an atomic replacement reaches the live stream', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'sdlc-todo-feed-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const feed = join(dir, 'feed.json');
  writeFileSync(feed, '{"version":1,"items":');
  const ctx = await web(t, { feed });
  assert.deepEqual((await request(ctx, '/api/feed')).json, { feed: null, error: 'feed is not valid JSON' });
  assert.equal((await request(ctx, '/api/items')).json.feedError, 'feed is not valid JSON');
  const waitFor = eventStream(ctx, t);
  await waitFor(value => Array.isArray(value.items));
  const replaced = waitFor(value => value.feed?.source === '<b>line</b>', 3000);
  writeFileSync(`${feed}.tmp`, JSON.stringify({ version: 1, source: '<b>line</b>', status: { state: 'running' } }));
  renameSync(`${feed}.tmp`, feed);
  const frame = await replaced;
  assert.equal(frame.feedError, undefined);
  assert.deepEqual((await request(ctx, '/api/feed')).json.feed.status, { state: 'running' }, 'text stays as written; the page shows it as text');
  const gone = waitFor(value => value.feed === null && value.feedError === undefined, 3000);
  rmSync(feed);
  await gone;
  writeFileSync(feed, '[1,2]');
  await waitFor(value => value.feedError === 'feed is not a JSON object', 3000);
});

// ---------- exec: a command the board runs for the human ----------
// The board runs commands on macOS and Linux; Windows has no POSIX shell or process groups (tested below as unsupported).
const posixOnly = { skip: process.platform === 'win32' && 'the board runs commands only on macOS and Linux for now' };
// Whichever sh comes first on the test PATH: /usr/bin/sh on Ubuntu, /bin/sh on macOS.
const testPath = '/usr/bin:/bin', sh = resolveCommand('sh', testPath);
// Spawning a process can take seconds on a loaded machine: these requests wait longer than the default 2 s, and
// each uses its own connection because a gap that long can outlive the server's keep-alive.
const slowRequest = { timeout: 30000, headers: { Connection: 'close' } };
async function execServer(t, options = {}) {
  const home = mkdtempSync(join(tmpdir(), 'sdlc-todo-home-')), oldHome = process.env.HOME;
  process.env.HOME = home;
  t.after(() => { process.env.HOME = oldHome; rmSync(home, { recursive: true, force: true }); });
  const ctx = await web(t, { lang: 'ko', ...options });
  const item = await core.add(ctx.file, 'clean the build folder');
  const shown = async () => items(await request(ctx, '/api/items', slowRequest), ctx.file).find(i => i.title === 'clean the build folder' || i.id === item.id);
  const run = body => request(ctx, '/api/exec', { method: 'POST', body, ...slowRequest });
  const runShown = async () => { const now = await shown(); return run({ id: now.id, version: now.version, path: now.execPath }); };
  const set = value => core.exec(ctx.file, item.id, JSON.stringify(value));
  const log = () => readFileSync(join(home, '.sdlc', 'todo-runs.log'), 'utf8').trim().split('\n').map(line => JSON.parse(line));
  return { ctx, home, item, shown, run, runShown, set, log };
}
const until = async (check, ms = 20000) => { const end = Date.now() + ms; while (!check()) { if (Date.now() > end) throw new Error('timed out'); await new Promise(r => setTimeout(r, 50)); } };

test('exec: runs the resolved program after the shown version and path are checked; exit 0 replies and clears, a failure keeps the wait', posixOnly, async t => {
  const { ctx, item, shown, run, runShown, set, log } = await execServer(t);
  await core.wait(ctx.file, item.id, '빌드 폴더를 지워 주세요');
  await core.run(ctx.file, item.id, 'open -a Terminal /x.command');
  await set({ argv: ['sh', '-c', 'echo first; echo hi'], cwd: ctx.root, why: 'test' });
  let now = await shown();
  assert.deepEqual(now.exec, { argv: ['sh', '-c', 'echo first; echo hi'], cwd: ctx.root, why: 'test' });
  assert.ok(sh && now.execPath === sh, 'argv[0] resolved on the command PATH');
  assert.equal((await run({ id: item.id, version: 'stale', path: now.execPath })).status, 409, 'a changed version runs nothing');
  assert.equal((await run({ id: 'nope00', version: now.version, path: now.execPath })).status, 404);
  assert.equal((await run({ id: item.id, version: now.version })).status, 400, 'the shown program is required');
  assert.equal((await run({ id: item.id, version: now.version, path: '/usr/bin/sh-other' })).status, 409, 'a different program than shown runs nothing');
  const ok = await run({ id: item.id, version: now.version, path: now.execPath });
  assert.equal(ok.status, 200, ok.text);
  assert.deepEqual(ok.json.exec, { exitCode: 0, stdout: 'first\nhi\n', stderr: '', timedOut: false, signal: null, error: '' });
  now = items(ok, ctx.file).find(i => i.id === item.id);
  assert.equal(now.exec, null, 'exit 0 clears it');
  assert.equal(now.run, '', 'and the terminal run, like any reply');
  assert.equal(now.waiting, '', 'and answers the wait');
  const [started, finished, reply] = now.events.slice(-3);
  assert.match(started.what, new RegExp(`^exec started run=[0-9a-f]{8} pid=${process.pid} server=[0-9a-f]{8} — sh -c 'echo first; echo hi' \\(cwd ${ctx.root}\\)$`));
  assert.equal(finished.what, `exec finished run=${started.what.match(/run=(\w+)/)[1]} — 실행함: sh -c 'echo first; echo hi' (cwd ${ctx.root}) → exit 0 · 출력: "hi"`);
  assert.deepEqual([reply.who, reply.what], ['human', `reply — 실행함: sh -c 'echo first; echo hi' (cwd ${ctx.root}) → exit 0 · 출력: "hi"`]);
  const firstRun = started.what.match(/run=(\w+)/)[1];
  assert.deepEqual({ ...now.execResult, at: 'x' }, { argv: ['sh', '-c', 'echo first; echo hi'], cwd: ctx.root, resolved: sh, exitCode: 0,
    timedOut: false, signal: null, at: 'x', run: firstRun }, 'the structured result machines read');
  assert.ok(Date.parse(now.execResult.at) > 0);
  assert.match(readFileSync(ctx.file, 'utf8'), /^  - execResult: \{"argv":\["sh","-c","echo first; echo hi"\].*"run":"\w+"\}$/m, 'one line of JSON');
  assert.equal((await run({ id: item.id, version: now.version, path: '/bin/sh' })).status, 409, 'no command left to run');

  await core.wait(ctx.file, item.id, '다시 지워 주세요');
  await core.run(ctx.file, item.id, 'open -a Terminal /x.command');
  await set({ argv: ['sh', '-c', 'echo nope >&2; exit 3'], cwd: ctx.root });
  const failed = await runShown();
  assert.equal(failed.json.exec.exitCode, 3);
  now = items(failed, ctx.file).find(i => i.id === item.id);
  assert.ok(now.exec, 'a failure keeps the command for a retry');
  assert.equal(now.run, 'open -a Terminal /x.command', 'and the terminal run');
  assert.equal(now.waiting, '다시 지워 주세요', 'and the wait: a failed run answers nothing');
  assert.equal(now.status, 'waiting');
  assert.match(now.events.at(-1).what, /^exec finished run=\w+ — 실행함: .* → exit 3 · 출력: "nope"$/);
  assert.ok(!now.events.at(-1).what.startsWith('reply'), 'no reply event');
  assert.equal(now.execResult.exitCode, 3, 'a newer run replaces the result');
  assert.notEqual(now.execResult.run, firstRun);

  await assert.rejects(async () => set({ argv: ['true'], cwd: join(ctx.root, 'gone') }), /not a directory/, 'the CLI refuses a missing folder');
  writeFileSync(ctx.file, readFileSync(ctx.file, 'utf8').replace(/^  - exec: .*$/m, `  - exec: ${JSON.stringify({ argv: ['true'], cwd: join(ctx.root, 'gone') })}`));
  const badCwd = await runShown();
  assert.equal(badCwd.status, 400, badCwd.text);
  assert.match(badCwd.json.error, /cwd is not a directory/);

  await set({ argv: ['no-such-command-xyz'], cwd: ctx.root });
  now = await shown();
  assert.equal(now.execPath, '', 'a command not on the PATH is not resolved');
  const missing = await run({ id: item.id, version: now.version, path: '' });
  assert.equal(missing.status, 409);
  assert.match(missing.json.error, /command not found: no-such-command-xyz/);

  const lines = log();
  assert.deepEqual(lines.map(line => line.event || line.exitCode), ['start', 0, 'start', 3], 'a start and an end line per run; refusals run nothing');
  assert.deepEqual(Object.keys(lines[1]), ['at', 'id', 'run', 'argv', 'cwd', 'exitCode', 'ms']);
  assert.equal(lines[0].path, sh);
});

test('exec: a timeout signals the whole process group, escalates to KILL and still records the result', posixOnly, async t => {
  const { ctx, item, set, runShown, log } = await execServer(t, { runTimeout: 1000, killAfter: 500 });
  await set({ argv: ['sh', '-c', 'trap "" TERM; sleep 30 & wait'], cwd: ctx.root });
  const started = Date.now();
  const late = await runShown();
  assert.equal(late.status, 200, late.text);
  assert.ok(Date.now() - started < 15000, 'a TERM-ignoring command does not hang the request');
  assert.equal(late.json.exec.timedOut, true);
  assert.equal(late.json.exec.exitCode, null);
  assert.equal(late.json.exec.signal, 'SIGKILL', 'TERM was ignored, KILL followed');
  assert.deepEqual([late.json.items.find(i => i.id === item.id).execResult.timedOut, late.json.items.find(i => i.id === item.id).execResult.signal, late.json.items.find(i => i.id === item.id).execResult.exitCode], [true, 'SIGKILL', null]);
  const now = items(late, ctx.file).find(i => i.id === item.id);
  assert.match(now.events.at(-1).what, /→ 시간 초과\(1초, SIGKILL\)$/);
  assert.ok(now.exec, 'a timeout keeps the command');
  assert.equal(log().at(-1).timedOut, true);
});

test('exec: runArgv kills grandchildren, settles soon after a backgrounded child, streams any output size and names start errors', posixOnly, async t => {
  const dir = mkdtempSync(join(tmpdir(), 'sdlc-todo-argv-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const go = (argv, extra = {}) => runArgv({ program: resolveCommand(argv[0], testPath) || argv[0], argv, cwd: dir, env: process.env, timeout: 800, killAfter: 500, grace: 300, ...extra });
  const pidFile = join(dir, 'grandchild.pid');
  const killed = await go(['sh', '-c', `sh -c 'trap "" TERM; echo $$ > ${pidFile}; while :; do sleep 0.2; done' & wait`]);
  assert.equal(killed.timedOut, true);
  const grandchild = Number(readFileSync(pidFile, 'utf8'));
  await until(() => { try { process.kill(grandchild, 0); return false; } catch { return true; } }, 5000);
  const started = Date.now();
  const quick = await go(['sh', '-c', '(sleep 20 &); echo quick'], { timeout: 30000 });
  assert.equal(quick.exitCode, 0);
  assert.equal(quick.stdout, 'quick\n');
  assert.ok(Date.now() - started < 10000, 'a background child holding stdout does not delay the result to the timeout');
  const big = await go(['sh', '-c', 'i=0; while [ $i -lt 400 ]; do printf "가나다라마바사아자차카타파하%.0s" $(seq 1 2000); i=$((i+1)); done; echo; echo end'], { timeout: 60000 });
  assert.equal(big.exitCode, 0, 'tens of megabytes of output never kill the command');
  assert.ok(Buffer.byteLength(big.stdout) <= 64 * 1024, 'only the last 64 KB is kept');
  assert.ok(!big.stdout.includes('�'), 'cut on a UTF-8 character boundary');
  assert.ok(big.stdout.endsWith('\nend\n'));
  assert.deepEqual(await go(['no-such-command-xyz'], { program: 'no-such-command-xyz' }).then(r => [r.exitCode, r.error]), [127, 'ENOENT']);
  writeFileSync(join(dir, 'plain'), 'not a program');
  assert.deepEqual(await go(['plain'], { program: join(dir, 'plain') }).then(r => [r.exitCode, r.error]), [126, 'EACCES']);
  assert.deepEqual(await go(['sh', '-c', 'true'], { cwd: join(dir, 'gone') }).then(r => [r.exitCode, r.error]), [126, 'ENOTDIR']);
});

test('exec: the command PATH drops relative and empty entries; resolution never uses the cwd', posixOnly, async () => {
  assert.equal(await commandSearchPath({ shell: '/nonexistent/shell', inherited: '.::relative/bin:/usr/bin:/bin:/usr/bin' }), '/usr/bin:/bin');
  assert.equal(resolveCommand('sh', '/usr/bin:/bin'), ['/usr/bin/sh', '/bin/sh'].find(existsSync), 'the first match on the PATH');
  assert.equal(resolveCommand('sh', '/bin:/usr/bin'), ['/bin/sh', '/usr/bin/sh'].find(existsSync));
  assert.equal(resolveCommand('sh', ''), '');
  assert.equal(resolveCommand(sh, ''), sh, 'an absolute program needs no PATH');
  assert.equal(resolveCommand('/etc/hosts', ''), '', 'not executable');
});

test('exec: the result goes to the item that started it and clears only what did not change meanwhile', posixOnly, async t => {
  const { ctx, item, shown, run, set } = await execServer(t);
  const startedRun = () => readFileSync(ctx.file, 'utf8').includes('exec started run=');
  const runningOne = async () => { const now = await shown(); return { now, pending: run({ id: now.id, version: now.version, path: now.execPath }) }; };

  // An agent asks a new question while it runs: the success leaves that question open and is not a reply to it.
  await core.wait(ctx.file, item.id, 'q1');
  await set({ argv: ['sh', '-c', 'sleep 4; echo done'], cwd: ctx.root });
  let { now, pending } = await runningOne();
  await until(startedRun);
  const again = await run({ id: now.id, version: now.version, path: now.execPath });
  assert.equal(again.status, 409, 'the start event changed the version: a second tab cannot run it again');
  const fresh = await shown();
  assert.equal((await run({ id: fresh.id, version: fresh.version, path: fresh.execPath })).status, 409, 'nor with the new version while it runs');
  await core.wait(ctx.file, item.id, 'q2');
  let result = await pending;
  assert.equal(result.status, 200, result.text);
  let after = items(result, ctx.file).find(i => i.id === item.id);
  assert.equal(after.waiting, 'q2', 'the new question stays');
  assert.equal(after.status, 'waiting');
  assert.match(after.events.at(-1).what, /^exec finished run=\w+ — 실행함: .* → exit 0 · 출력: "done"$/);
  assert.equal(after.events.filter(event => event.what.startsWith('reply — 실행함')).length, 0, 'not recorded as an answer to q2');

  // Renamed while running: the id follows the title, the result follows the start event.
  await set({ argv: ['sh', '-c', 'sleep 4; echo renamed'], cwd: ctx.root });
  ({ now, pending } = await runningOne());
  await until(() => (readFileSync(ctx.file, 'utf8').match(/exec started run=/g) || []).length === 2);
  await core.edit(ctx.file, item.id, { title: 'renamed while running' });
  result = await pending;
  after = items(result, ctx.file).find(i => i.title === 'renamed while running');
  assert.notEqual(after.id, item.id);
  assert.match(after.events.at(-1).what, /^reply — 실행함: .* → exit 0 · 출력: "renamed"$/, 'answered on the renamed item');

  // Done while running: the result is kept on it, never as a reply and never on another item.
  const other = await core.add(ctx.file, 'clean the build folder');
  await core.exec(ctx.file, after.id, JSON.stringify({ argv: ['sh', '-c', 'sleep 4; echo late'], cwd: ctx.root }));
  const current = items(await request(ctx, '/api/items', slowRequest), ctx.file).find(i => i.id === after.id);
  pending = run({ id: current.id, version: current.version, path: current.execPath });
  await until(() => (readFileSync(ctx.file, 'utf8').match(/exec started run=/g) || []).length === 3);
  await core.done(ctx.file, after.id, 'closed by agent');
  result = await pending;
  const closed = items(result, ctx.file).find(i => i.title === 'renamed while running');
  assert.equal(closed.done, true);
  assert.match(closed.events.at(-1).what, /^exec finished run=\w+ — .* → exit 0 · 출력: "late"$/);
  assert.equal(items(result, ctx.file).find(i => i.id === other.id).events.length, 1, 'nothing lands on another item');
});

test('exec: a run is live only while its own server runs it or, for another server, while its pid lives and it is young', posixOnly, async t => {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-web-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const file = join(root, 'todo.md');
  const exec = JSON.stringify({ argv: ['true'], cwd: root });
  const hourAgo = core.stamp(new Date(Date.now() - 3600000)), now = core.stamp(), otherPid = process.ppid;
  const item = (title, run, pid, server, at) => `- [ ] ${title}\n  - exec: ${exec}\n  - ${at} human: exec started run=${run} pid=${pid}${server ? ` server=${server}` : ''} — true (cwd ${root})\n`;
  writeFileSync(file, `## Open\n\n${item('dead pid', 'deadbeef', 99999999, 'aaaa0001', now)}\n${item('reused pid, too old', 'ba5eba11', otherPid, 'aaaa0002', hourAgo)}\n` +
    `${item('this pid, another server', 'feedf00d', process.pid, 'aaaa0003', now)}\n${item('old format, dead pid', 'c0ffee00', 99999999, '', now)}\n` +
    `${item('live other server', 'cafebabe', otherPid, 'aaaa0004', now)}\n## Done\n`);
  const server = await startWeb({ file, kit, port: 0, open: false, onUrl() {}, feed: join(root, 'feed.json'), searchPath: '/usr/bin:/bin', lang: 'ko' });
  t.after(() => server.close());
  const byTitle = title => core.load(file).items.find(i => i.title === title);
  for (const [title, run] of [['dead pid', 'deadbeef'], ['reused pid, too old', 'ba5eba11'], ['this pid, another server', 'feedf00d'], ['old format, dead pid', 'c0ffee00']]) {
    assert.match(byTitle(title).events.at(-1).what, new RegExp(`^exec finished run=${run} — 중단됨 \\(서버 재시작\\)`), title);
    assert.ok(byTitle(title).exec, `${title}: the human decides whether to run it again`);
  }
  assert.ok(byTitle('live other server').events.at(-1).what.startsWith('exec started run=cafebabe'), 'a young run of another live server is left alone');

  // On demand: a dead start that appears after this server started is closed when someone runs the command.
  const url = new URL(server.url), token = new URLSearchParams(url.hash.slice(1)).get('t');
  const ctx = { url, token, file };
  writeFileSync(file, readFileSync(file, 'utf8').replace('## Done', item('late dead start', 'abad1dea', 99999999, 'aaaa0005', now) + '\n## Done'));
  const shownLate = items(await request(ctx, '/api/items', slowRequest), file).find(i => i.title === 'late dead start');
  const ran = await request(ctx, '/api/exec', { method: 'POST', body: { id: shownLate.id, version: shownLate.version, path: shownLate.execPath }, ...slowRequest });
  assert.equal(ran.status, 200, ran.text);
  const events = byTitle('late dead start').events.map(event => event.what);
  assert.ok(events.some(what => what.startsWith('exec finished run=abad1dea — 중단됨')), 'the dead run is closed first');
  assert.match(events.at(-1), /^reply — 실행함: true .* → exit 0$/);
  assert.match(events.find(what => what.startsWith('exec started run=') && !what.includes('abad1dea')), / server=[0-9a-f]{8} — /, 'a new start names its server');
});

test('exec: a finish write that meets a busy lock is retried, then kept and written on the next request', posixOnly, async t => {
  const hold = (file, ms) => {
    const lock = `${file}.lock`;
    writeFileSync(lock, 'held by the test');
    const beat = setInterval(() => { const at = new Date(); try { utimesSync(lock, at, at); } catch { /* released */ } }, 500);
    const release = () => { clearInterval(beat); rmSync(lock, { force: true }); };
    if (ms) setTimeout(release, ms);
    return release;
  };
  const startedRuns = file => (readFileSync(file, 'utf8').match(/exec started run=/g) || []).length;
  const finishedRuns = file => (readFileSync(file, 'utf8').match(/exec finished run=/g) || []).length;

  // Busy for a few seconds: the retries outlast it and the result lands.
  let { ctx, item, set, shown, run } = await execServer(t);
  await set({ argv: ['sh', '-c', 'sleep 2; echo retried'], cwd: ctx.root });
  let now = await shown();
  let pending = run({ id: now.id, version: now.version, path: now.execPath });
  await until(() => startedRuns(ctx.file) === 1);
  hold(ctx.file, 6000);
  let result = await pending;
  assert.equal(result.status, 200, result.text);
  assert.equal(finishedRuns(ctx.file), 1, 'written after the lock came free');
  assert.equal(core.load(ctx.file).items.find(i => i.id === item.id).execResult.exitCode, 0);

  // Busy past the retry budget: kept in memory, still running (no second start), written by the next request.
  ({ ctx, item, set, shown, run } = await execServer(t, { finishRetryMs: 1500 }));
  await set({ argv: ['sh', '-c', 'sleep 1; echo kept'], cwd: ctx.root });
  now = await shown();
  pending = run({ id: now.id, version: now.version, path: now.execPath });
  await until(() => startedRuns(ctx.file) === 1);
  const release = hold(ctx.file);
  result = await pending;
  assert.equal(result.status, 200, result.text);
  assert.equal(result.json.exec.stdout, 'kept\n', 'the person still sees the result');
  assert.equal(finishedRuns(ctx.file), 0, 'not written while the lock is held');
  release();
  now = await shown(); // any request writes what was kept
  assert.equal(finishedRuns(ctx.file), 1);
  assert.equal(now.execResult.exitCode, 0);
  assert.match(now.events.at(-1).what, /^reply — 실행함: .* → exit 0 · 출력: "kept"$/);
  await set({ argv: ['sh', '-c', 'echo again'], cwd: ctx.root });
  now = await shown();
  const again = await run({ id: now.id, version: now.version, path: now.execPath });
  assert.equal(again.status, 200, 'once written, the run is over: the next one may start');
});

test('exec: on Windows the board does not run commands: no program is resolved and the request is refused', async t => {
  const ctx = await web(t, { platform: 'win32', searchPath: undefined });
  const item = await core.add(ctx.file, 'needs a command');
  await core.exec(ctx.file, item.id, JSON.stringify({ argv: ['sh', '-c', 'echo never'], cwd: ctx.root }));
  const now = items(await request(ctx, '/api/items', slowRequest), ctx.file).find(i => i.id === item.id);
  assert.equal(now.execPath, '');
  assert.equal(now.execUnsupported, true);
  const refused = await request(ctx, '/api/exec', { method: 'POST', body: { id: item.id, version: now.version, path: '' }, ...slowRequest });
  assert.equal(refused.status, 409);
  assert.match(refused.json.error, /not supported on Windows/);
  assert.ok(!readFileSync(ctx.file, 'utf8').includes('exec started'), 'nothing started');
});

test('exec: a log that cannot be written never skips the reply', posixOnly, async t => {
  const { ctx, home, item, set, runShown } = await execServer(t);
  writeFileSync(join(home, '.sdlc'), 'a file where the folder should be');
  await set({ argv: ['sh', '-c', 'echo still'], cwd: ctx.root });
  const result = await runShown();
  assert.equal(result.status, 200, result.text);
  assert.match(items(result, ctx.file).find(i => i.id === item.id).events.at(-1).what, /^reply — 실행함: .* → exit 0 · 출력: "still"$/);
});

test('an answered request leaves no idle connection to reuse; the event stream stays open', async t => {
  const ctx = await web(t);
  const ask = { 'Connection': 'keep-alive' };
  for (const [path, options] of [['/', {}], ['/api/live', {}], ['/api/nothing', {}], ['/api/live', { token: '' }],
    ['/api/items', { method: 'POST', body: { text: 'Added over a fresh connection' } }]]) {
    const response = await request(ctx, path, { ...options, timeout: 30000, headers: ask });
    assert.equal(response.headers.connection, 'close', `${options.method || 'GET'} ${path} answered ${response.status}`);
  }
  const stream = await new Promise((resolveStream, reject) => {
    const req = http.get({ hostname: ctx.url.hostname, port: ctx.url.port, path: `/events?t=${ctx.token}`, headers: { Host: ctx.url.host } }, resolveStream);
    req.on('error', reject);
    t.after(() => req.destroy());
  });
  assert.equal(stream.headers.connection, 'keep-alive');
});
