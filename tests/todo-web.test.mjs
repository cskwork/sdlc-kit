import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir, networkInterfaces } from 'node:os';
import { dirname, join, resolve } from 'node:path';
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

async function web(t) {
  const root = mkdtempSync(join(tmpdir(), 'sdlc-todo-web-'));
  const file = join(root, 'todo.md');
  let opened;
  const server = await startWeb({ file, kit, port: 0, open: false, onUrl(url) { opened = url; } });
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
    req.setTimeout(2000, () => req.destroy(new Error('HTTP request timed out')));
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
  list = items(await request(ctx, '/api/item', { method: 'POST', body: { op: 'edit', id: second.id, title: 'Revised second' } }), ctx.file);
  const revised = list.find(item => item.title === 'Revised second');
  assert.ok(revised);
  list = items(await request(ctx, '/api/item', { method: 'POST', body: { op: 'move', id: revised.id, delta: -1 } }), ctx.file);
  assert.equal(list[0].id, revised.id);
  list = items(await request(ctx, '/api/item', { method: 'POST', body: { op: 'done', id: revised.id } }), ctx.file);
  assert.equal(list.find(item => item.title === 'Revised second').done, true);
  assert.match(readFileSync(ctx.file, 'utf8'), /human: done/);
  list = items(await request(ctx, '/api/item', { method: 'POST', body: { op: 'undone', id: revised.id } }), ctx.file);
  assert.equal(list.find(item => item.title === 'Revised second').done, false);
  await core.wait(ctx.file, first.id, 'which environment?');
  items(await request(ctx, '/api/item', { method: 'POST', body: { op: 'reply', id: first.id, text: 'Use the local environment' } }), ctx.file);
  assert.match(readFileSync(ctx.file, 'utf8'), /human: reply — Use the local environment/);
  assert.doesNotMatch(readFileSync(ctx.file, 'utf8'), /waiting: which environment/);
  list = items(await request(ctx, '/api/item', { method: 'POST', body: { op: 'delete', id: first.id } }), ctx.file);
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
      waiter.timer = setTimeout(() => { waiters.splice(waiters.indexOf(waiter), 1); reject(new Error('SSE change did not arrive within one second')); }, timeout);
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
  assert.equal(shown.json.file, join(folder, 'intent.md'), 'artifact uses the ancestor SDLC store');
  assert.equal(shown.json.markdown, intent);
  assert.equal(shown.json.sha, createHash('sha256').update(intent).digest('hex'));
  writeFileSync(join(folder, 'intent.md'), intent + '\nEdited after the browser opened.\n');
  const stale = await request(ctx, '/api/approve', { method: 'POST', body: { id: item.id, gate: 'intent', sha: shown.json.sha, words: 'approved the displayed scope' } });
  assert.equal(stale.status, 409, stale.text);
  assert.match(stale.text, /changed since/i);
  gateClosed(child, 'intent', slug);
  items(await request(ctx, '/api/item', { method: 'POST', body: { op: 'reply', id: item.id, text: 'Please keep the first outcome' } }), ctx.file);
  assert.match(readFileSync(ctx.file, 'utf8'), /human: reply — Please keep the first outcome/);
  gateClosed(child, 'intent', slug);
  shown = await request(ctx, `/api/artifact?id=${item.id}`);
  const words = 'approved the revised intent scope';
  items(await request(ctx, '/api/approve', { method: 'POST', body: { id: item.id, gate: 'intent', sha: shown.json.sha, words } }), ctx.file);
  assert.match(sdlc(child, 'check', 'intent', slug), /GATE OPEN/);
  assert.ok(readFileSync(ctx.file, 'utf8').includes(`human: approved intent — "${words}"`));
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
  assert.equal(shown.json.file, join(folderTwo, 'PLAN.md'));
  writeFileSync(join(folderTwo, 'PLAN.md'), plan + '\nA revised implementation detail.\n');
  const stale = await request(ctx, '/api/approve', { method: 'POST', body: { id: item.id, gate: 'plan', sha: shown.json.sha, words: 'approved the displayed plan' } });
  assert.equal(stale.status, 409, stale.text);
  assert.match(stale.text, /changed since/i);
  gateClosed(two, 'plan', slug);
  shown = await request(ctx, `/api/artifact?id=${item.id}`);
  const words = 'approved the revised plan and security risk';
  items(await request(ctx, '/api/approve', { method: 'POST', body: { id: item.id, gate: 'plan', sha: shown.json.sha, words } }), ctx.file);
  assert.match(sdlc(two, 'check', 'plan', slug), /GATE OPEN/);
  gateClosed(one, 'plan', slug);
  assert.ok(readFileSync(ctx.file, 'utf8').includes(`human: approved plan — "${words}"`));
});

test('artifact and approval validation reject unknown ids, gates, hashes and empty words', async t => {
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
    { id: item.id, gate: 'intent', sha: 'a'.repeat(64), words: '' },
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
