import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, symlinkSync, realpathSync } from 'node:fs';
import { tmpdir, networkInterfaces } from 'node:os';
import { dirname, join, resolve, relative as pathRelative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startWeb } from '../todo/web.mjs';
import * as core from '../todo/core.mjs';

const kit = resolve(dirname(fileURLToPath(import.meta.url)), '..');
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
## Scenarios
| ID | Persona | Steps | Expected | Must | Covers |
|---|---|---|---|---|---|
| S1 | operator | run real CLI | observable output | yes | O1 |
`;

async function web(t, options = {}) {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-web-'));
  const file = join(root, 'todo.md');
  let opened;
  const server = await startWeb({ file, kit, port: 0, open: false, onUrl(url) { opened = url; }, ...options });
  t.after(async () => { await server.close(); rmSync(root, { recursive: true, force: true }); });
  const url = new URL(opened || server.url);
  const token = new URLSearchParams(url.hash.slice(1)).get('t');
  assert.equal(url.hostname, '127.0.0.1');
  assert.notEqual(url.port, '0');
  assert.match(token || '', /^[a-f0-9]{32}$/);
  return { root, file, server, url, token };
}

function request(ctx, pathname, { method = 'GET', body, headers = {}, token = ctx.token, hostname = ctx.url.hostname } = {}) {
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
    req.setTimeout(process.platform === 'win32' ? 60000 : 2000, () => req.destroy(new Error('HTTP request timed out')));
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
  for (const [label, pathname, options] of [
    ['missing token', '/api/items', { token: null }],
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

test('N: artifact and approval use the status runner store instead of the realpath ancestor', async t => {
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

for (const missing of [true, false]) test(`N: store lookup ${missing ? 'without a reported store' : 'failure'} never falls back to a project ancestor`, async t => {
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
  const server = await startWeb({ file: ctx.file, kit: stub, onUrl() {} });
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
