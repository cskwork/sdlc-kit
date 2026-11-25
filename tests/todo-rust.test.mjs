// The app's Rust server against core.mjs: the same bytes, the same hashes, and safe writes beside the Node CLI.
// Runs with SDLC_TODO_RUST_SERVE=<binary> (see rust-server.mjs). SDLC_TODO_RUST_CORPUS=<folder> adds list files.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as core from '../todo/core.mjs';
import { startWeb } from '../todo/web.mjs';
import { rustServer, startRustWeb } from './rust-server.mjs';

const kit = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const needsRust = { skip: !rustServer && 'set SDLC_TODO_RUST_SERVE to the built sdlc-todo-serve' };
const scratch = t => { const dir = mkdtempSync(join(tmpdir(), 'sdlc-todo-rust-')); t.after(() => rmSync(dir, { recursive: true, force: true })); return dir; };

function random(seed) {
  let a = seed >>> 0;
  const next = () => { a = a + 0x6d2b79f5 >>> 0; let t = Math.imul(a ^ a >>> 15, a | 1); t = t + Math.imul(t ^ t >>> 7, t | 61) ^ t; return (t ^ t >>> 14) >>> 0; };
  return { int: n => next() % n, pick: list => list[next() % list.length], chance: p => next() % 100 < p };
}
const words = ['plain', '한글 할 일', '이모지 😀 끝', 'a\tb', 'x\u2028y', 'n\u0085l', '\ufeffbom', '~~struck~~', '~~~', '~~~~', '', ' ', '  two', 'a\rb', 'c\u00a0', '$1 $& {id}', '- [ ] nested', '## Done',
  ' · ', ' — ', 'a · b — c · d — e', 'approve intent --human', 'approve  plan', 'say: "x" \\ y', '\u0001', '\u2029', 'café', '각'];
const urls = ['https://acme.example/browse/WEB-1', 'http://x.example:80/', 'https://github.com/a/b/pull/12', 'https://github.com/a/b/issues/7/', 'HTTPS://UP.example/A', 'ftp://no', 'not a url', 'https://',
  'http://1.2.3', 'https://x.example/한글/browse/K-1', 'https://한글.example/', 'http://u:p@h.example:81/q', 'https://x.example/a/../browse/Z-9/', 'http:y.example', '  https://pad.example  ', 'https://p.example:99999/', 'javascript:alert(1)'];
const execs = [{ argv: ['sh', '-c', 'echo hi'], cwd: '/tmp', why: ' because ' }, { argv: ['a\nb', '한\u2028'], cwd: '/tmp\u0085' }, { argv: [], cwd: '/' }, { argv: ['./x'], cwd: '/' }, { argv: ['x'], cwd: 'rel' }, { argv: ['x'], cwd: '/', more: 1 }, { argv: ['x'], cwd: '/', why: 'y'.repeat(201) },
  { argv: ['/abs', ''], cwd: '/', why: '😀'.repeat(100) }].map(value => JSON.stringify(value)).concat(['{"argv":["\\ud800x","\\ud83d\\ude00"],"cwd":"/","why":"\\u000b w \\u001f"}', '{"cwd":"/","argv":["b"],"argv":["c"]}', '{"argv":["x"],"cwd":"/","why":null}', '{ "argv" : [ "x" ] , "cwd" : "/" }', '[1]', 'nope', '{"argv":["x\\u0000"],"cwd":"/"}']);
const result = { argv: ['x'], cwd: '/', resolved: '/bin/x', exitCode: 0, timedOut: false, signal: null, at: '2026-01-01T00:00:00.000Z', run: 'ab' };
const results = [result, { ...result, exitCode: null, signal: 'SIGKILL' }, { ...result, exitCode: 1.5 }, { ...result, argv: [] }, { ...result, extra: 1 }, { ...result, cwd: '\u2028' }].map(value => JSON.stringify(value))
  .concat(['{"run":"z","at":"","signal":null,"timedOut":true,"exitCode":1e21,"resolved":"","cwd":"","argv":["\\udfff"]}', JSON.stringify(result).replace('"exitCode":0', '"exitCode":-0'), JSON.stringify(result).replace('"exitCode":0', '"exitCode":1e400')]);
function list(r) {
  const eol = r.pick(['\n', '\n', '\n', '\r\n']), out = [];
  if (r.chance(70)) out.push('# To-do', '', r.pick(words), '');
  if (r.chance(75)) out.push('## Open', '');
  let previous;
  for (let i = r.int(9); i >= 0; i--) {
    if (r.chance(15)) out.push(r.pick(['## Done', '## Open', '## Other', 'stray line', '\t']));
    if (previous && r.chance(20)) { out.push(...previous, ''); continue; }
    const item = [`- [${r.pick([' ', ' ', 'x', 'X', '?'])}] ${r.pick(words)}${r.chance(30) ? r.pick(words) : ''}`];
    for (let n = r.int(12); n > 0; n--) item.push(r.pick([
      () => `  - project: ${r.pick(['~', '~/code', '/abs/한글', './rel', 'C:\\x', 'C:', '\\\\srv', 'rel/x', ''])}`,
      () => `  - link: [${r.pick(['', ' ', 'label', 'a](b', '한글'])}](${r.pick(urls)})${r.pick(['', '', 'x'])}`,
      () => `  - sdlc: ${r.pick(['', 'slug', 'other-slug'])}${r.pick(['', ' · intent', ' · build · READY', ' · plan · NEEDS-HUMAN — approve plan --human', ' · build · BLOCKED — why — more · x', ' · '])}`,
      () => `  - waiting: ${r.pick(words)}`, () => `  - others: ${r.pick(words)}`, () => `  - brief: ${r.pick(['/a.md', 'rel.md', ''])}`,
      () => `  - repos: ${r.pick(['web-api, admin', 'a a,b', '-bad ok', '', 'x'.repeat(101)])}`, () => `  - choices: ${r.pick(['a | b', '|', 'a||b', '1|2|3|4|5|6|7', ' 한 | 글 '])}`,
      () => `  - pick: ${r.pick(['1', '02', '9', '0', 'x', '', ' 1 ', '99999999999999999999'])}`, () => `  - suggest: ${r.pick(words)}`, () => `  - run: ${r.pick(words)}`,
      () => `  - exec: ${r.pick(execs)}`, () => `  - execResult: ${r.pick(results)}`, () => r.pick(['  - pin: yes', '  - pin: no', '  - pin: yes ']),
      () => `  - 2026-11-0${1 + r.int(9)} 09:4${r.int(10)} ${r.pick(['human', 'agent', 'sdlc', 'two words', '한글', 'a\rb', ''])}: ${r.pick(['added', 'done', 'reply — ok', 'chat answer — x', 'waiting — q', 'read replies', 'fix requested', 'NEEDS-HUMAN — approve plan', 'BLOCKED — b', 'READY — r', 'brief /a', 'suggest — s', 'working — w', 'exec started run=ab pid=1 — x', r.pick(words)])}`,
      () => `  - 2026-1-01 09:40 human: short`, () => `${r.pick(['  ', '\t', '\u00a0', '\ufeff', '   ', ''])}${r.pick(words)}`
    ])());
    previous = item;
    out.push(...item, ...(r.chance(70) ? [''] : []));
  }
  return out.join(eol) + r.pick(['', eol]);
}
const cases = () => {
  const out = ['', '\n', '## Open', '## Done\n', 'no heading at all', '\ufeff# To-do\n\n## Open\n\n- [ ] a\n', '- [x] done\n- [ ] open\n  note\n', '## Open\r\n\r\n- [ ] crlf\r\n  - waiting: q\r\n\r\n## Done\r\n',
    '## Open\n\n- [ ] \n  - sdlc: \n\n- [ ] same\n\n- [ ] same\n\n## Done\n\n- [x] ~~same~~\n'];
  for (let seed = 1; seed <= 4000; seed++) out.push(list(random(seed)));
  const corpus = process.env.SDLC_TODO_RUST_CORPUS;
  if (corpus) for (const name of readdirSync(corpus)) out.push(readFileSync(join(corpus, name), 'utf8'));
  return out;
};

test('rust: parsing and rendering any list gives core.mjs bytes, version hashes, ids and status', needsRust, async t => {
  const dir = scratch(t), file = join(dir, 'todo.md'), sources = cases();
  const child = spawn(rustServer, ['--render', '--kit', kit, '--node', process.execPath], { stdio: ['pipe', 'pipe', 'inherit'] });
  let text = '';
  child.stdout.setEncoding('utf8').on('data', chunk => { text += chunk; });
  child.stdin.end(sources.map(source => JSON.stringify(source)).join('\n') + '\n');
  assert.equal(await new Promise(done => child.once('close', done)), 0);
  const answers = text.trimEnd().split('\n').map(line => JSON.parse(line));
  assert.equal(answers.length, sources.length);
  for (const [i, source] of sources.entries()) {
    writeFileSync(file, source);
    const model = core.load(file);
    assert.deepEqual(answers[i], { text: core.serialize(model), versions: model.items.map(item => core.itemVersion(item, model)),
      ids: model.items.map(item => item.id), status: model.items.map(item => item.status), unread: model.items.map(item => item.unread) }, JSON.stringify(source));
  }
  t.diagnostic(`${sources.length} lists compared`);
});

async function call(url, pathname, body) {
  const at = new URL(url), token = new URLSearchParams(at.hash.slice(1)).get('t');
  const response = await fetch(at.origin + pathname, { method: body ? 'POST' : 'GET', ...(body ? { body: JSON.stringify(body) } : {}),
    headers: { 'X-Todo-Token': token, ...(body ? { Origin: at.origin, 'Content-Type': 'application/json' } : {}) } });
  return { status: response.status, text: await response.text() };
}

test('rust: the same requests give the same answers and leave the same files as the Node server', { skip: needsRust.skip || process.platform === 'win32' && 'the stub project paths are POSIX' }, async t => {
  const dir = scratch(t);
  const start = { node: options => startWeb(options), rust: options => startRustWeb(options) }, sides = {};
  // One stub kit for both: no real project, no git; its path is part of error words and so of versions.
  writeFileSync(join(dir, 'sdlc.sh'), `case "$2" in gone) printf '{"features":[]}\\n';; bad) echo nope;; fail) printf 'one\\ntwo\\n' >&2; exit 3;; quiet) exit 4;; empty) echo '{}';; *) printf '{"store":"/none","features":[{"slug":"%s","phase":"plan","state":"NEEDS-HUMAN","action":"approve plan --human"}]}\\n' "$2";; esac\n`);
  writeFileSync(join(dir, 'plain'), 'echo no interpreter line', { mode: 0o755 });
  for (const name of ['node', 'rust']) {
    const root = join(dir, name);
    mkdirSync(root);
    writeFileSync(join(root, 'feed.json'), '{"items":{"B":1,"10":{"a":"\\ud800"},"2":1e21}}');
    sides[name] = { root, file: join(root, 'todo.md'), server: null };
  }
  const same = text => text.replaceAll('/node/', '/side/').replaceAll('/rust/', '/side/');
  const compare = label => {
    const files = side => Object.fromEntries(['todo.md', 'todo-archive.md', 'todo-working.json', ...(existsSync(join(side.root, 'todo-history')) ? readdirSync(join(side.root, 'todo-history')).map(name => `todo-history/${name}`) : [])]
      .filter(name => existsSync(join(side.root, name))).map(name => [name, same(readFileSync(join(side.root, name), 'utf8'))]));
    assert.deepEqual(files(sides.rust), files(sides.node), label);
    for (const side of Object.values(sides)) assert.deepEqual(readdirSync(side.root).filter(name => /\.lock|\.tmp$/.test(name)), [], `${label}: nothing left behind`);
  };
  const seed = list(random(77));
  const source = `# To-do\n\n## Open\n\n${['gone', 'bad', 'fail', 'quiet', 'empty', 'ok'].map(slug => `- [ ] Item ${slug}\n  - project: /tmp\n  - sdlc: ${slug} · build\n`).join('\n')}\n` +
    `- [ ] No folder\n  - project: /no/such/folder\n  - sdlc: nofolder · build\n\n- [ ] A file\n  - project: ${join(dir, 'sdlc.sh')}\n  - sdlc: afile · build\n\n- [ ] Relative\n  - project: ./x\n  - sdlc: rel · build\n\n` +
    Array.from({ length: 33 }, (_, i) => `- [x] ~~Old ${i}~~\n  - 2026-01-01 00:00 agent: suggest — a\n  - 2026-01-01 00:01 agent: suggest — b\n`).join('\n') + seed.replace(/## (Open|Done)/g, '');
  const now = new Date().toISOString();
  for (const name of Object.keys(sides)) {
    const side = sides[name];
    writeFileSync(side.file, source);
    const id = core.load(side.file).items[0].id;
    writeFileSync(join(side.root, 'todo-working.json'), JSON.stringify({ [id]: { what: 'x', since: now, beat: now }, dead: { what: 'x', since: now, beat: '2020-01-01T00:00:00.000Z' } }));
  }
  // Event times are minutes: stay inside one while both sides write.
  const left = 60 - new Date().getSeconds();
  if (left < 45) await new Promise(done => setTimeout(done, left * 1000 + 200));
  for (const name of Object.keys(sides)) {
    const side = sides[name];
    side.server = await start[name]({ file: side.file, kit: dir, feed: join(side.root, 'feed.json'), searchPath: '/usr/bin:/bin', onUrl() {} });
    t.after(() => side.server.close());
  }
  compare('first sync');
  const both = async (pathname, make) => {
    const out = {};
    for (const name of Object.keys(sides)) {
      const side = sides[name], model = core.load(side.file);
      const body = make?.(model.items, item => core.itemVersion(item, model));
      const answer = await call(side.server.url, pathname, body);
      out[name] = { status: answer.status, text: same(answer.text).replace(/"(since|beat)":"[^"]*"/g, '"$1":""') };
    }
    // A recorded fix whose program cannot start: Node throws for some codes after the write; here it is the launch's result.
    const thrown = make && out.node.status === 400 && JSON.parse(out.node.text).error.match(/^spawn (ENOEXEC|ENOTDIR)$/);
    if (thrown) { assert.deepEqual([out.rust.status, JSON.parse(out.rust.text).launch], [200, `failed: ${thrown[1]}`]); return out.rust; }
    assert.deepEqual(out.rust, out.node, `${pathname} ${JSON.stringify(make?.([{ id: 'x' }], () => 'v') ?? null)}`.slice(0, 200));
    return out.node;
  };
  const op = (name, extra = {}, at = 0) => both('/api/item', (items, version) => ({ op: name, id: items[at]?.id, version: items[at] && items[at].title !== undefined ? version(items[at]) : 'v', ...extra }));
  assert.equal((await both('/api/items')).status, 200);
  await both('/api/feed');
  for (const id of ['', 'x', ...core.load(sides.node.file).items.slice(0, 10).map(item => item.id)]) await both(`/api/artifact?id=${id}`);
  for (const text of ['New 한글 😀 ~/code https://acme.example/browse/WEB-1', 'Two ./rel https://x.example:8080/a b', 'https://only.example/', '', ' \u00a0 ', 'a\nb', 'x\u2028y', 'odd https://한글.example/ http:z', 'lone \ud800', 5, null]) { await both('/api/items', () => ({ text })); compare(`add ${text}`); }
  for (const [name, extra, at] of [['edit', { title: ' 새 제목 ' }, 0], ['edit', { title: '' }, 0], ['edit', { title: 'Item fail' }, 1], ['move', { delta: 1 }, 0], ['move', { delta: -1 }, 0], ['move', { delta: 2 }, 0], ['move', { delta: -1 }, 2], ['done', {}, 1],
    ['undone', {}, 9], ['reply', { text: 'x\u0085y "q"' }, 2], ['reply', { text: 'a\rb' }, 2], ['fix', {}, 0], ['fix', {}, 2], ['fix', {}, 3], ['fix', {}, 5], ['delete', {}, 4], ['delete', { version: null }, 4], ['delete', { id: 7 }, 4], ['nope', {}, 0]]) { await op(name, extra, at); compare(`${name} ${at}`); }
  for (const body of [{}, { gate: 'plan', sha: 'a'.repeat(64) }, { gate: 'plan', sha: 'a'.repeat(64), words: null }, { gate: 'plan', sha: 'a'.repeat(64), words: 'x'.repeat(501) }, { gate: 'intent', sha: 'A'.repeat(64), words: 'ok' }]) {
    for (let at = 0; at < 8; at++) { await both('/api/approve', (items, version) => ({ id: items[at]?.id, version: items[at]?.title !== undefined ? version(items[at]) : 'v', ...body })); compare(`approve ${at}`); }
  }
  for (const pathname of ['/api/exec', '/api/nothing', '/api']) await both(pathname, items => ({ id: items[0].id, version: 'x', path: '/bin/sh' }));
  // todo-agent.json: missing, broken, wrong, and a real program.
  for (const config of ['{', '[]', '{}', '{"fix":[]}', '{"fix":["",1]}', '{"fix":["/no/such/program","{id}","{kit}","{project}{x}"]}', '{"fix":["true"]}', '{"fix":["/bin"]}', `{"fix":["${dir}/plain"]}`]) {
    for (const side of Object.values(sides)) writeFileSync(join(side.root, 'todo-agent.json'), config);
    for (let at = 0; at < 8; at++) await op('fix', {}, at);
    compare(`fix with ${config}`);
  }
  // Bytes that are not UTF-8 read as Node reads them.
  for (const side of Object.values(sides)) writeFileSync(side.file, Buffer.concat([Buffer.from('## Open\n\n- [ ] bad '), Buffer.from([0xff, 0xe2, 0x82, 0x41, 0xf0, 0x9f, 0x98]), Buffer.from(' end\n')]));
  assert.equal((await both('/api/items')).status, 200);
  await op('reply', { text: 'kept' }, 0);
  compare('invalid bytes');
});

test('rust: Node CLI processes and the Rust server write one list at once without losing, doubling or tearing anything', { ...needsRust, timeout: 600000 }, async t => {
  const dir = scratch(t), file = join(dir, 'todo.md');
  const rounds = Number(process.env.SDLC_TODO_RUST_ROUNDS || 60), cli = 4, web = 4;
  const server = await startRustWeb({ file, kit, feed: join(dir, 'feed.json'), onUrl() {} });
  t.after(() => server.close());
  const node = args => new Promise(done => {
    const child = spawn(process.execPath, [join(kit, 'todo', 'todo.mjs'), ...args], { env: { ...process.env, SDLC_TODO: file, SDLC_TODO_SESSION: join(dir, 's.json'), SDLC_TODO_FEED: join(dir, 'feed.json'), HOME: dir }, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = '';
    child.stdout.on('data', chunk => { out += chunk; }); child.stderr.on('data', chunk => { err += chunk; });
    child.once('close', code => done({ code, out: out.trim(), err }));
  });
  const acked = new Set(), notes = [], retries = { cli: 0, web: 0 };
  // A busy lock is refused, never half done: only that refusal may be retried.
  const unsure = (text, saved) => {
    if (/timed out waiting for lock/.test(text)) return true;
    assert.equal(process.platform, 'win32', text);
    for (;;) { try { return !saved(core.load(file).items); } catch (error) { assert.match(String(error.code), /EPERM|EBUSY|EACCES/); } }
  };
  const retry = async (kind, attempt) => { for (let n = 0; n < 200; n++) { const busy = await attempt(); if (!busy) return; retries[kind]++; } assert.fail('the lock never came free'); };
  let reading = true, reads = 0;
  const torn = (async () => {
    while (reading) {
      let text = '';
      // Windows refuses a read for a moment while the file is being replaced.
      try { text = readFileSync(file, 'utf8'); } catch (error) { if (error.code !== 'ENOENT' && process.platform !== 'win32') throw error; }
      if (text) { assert.match(text, /^# To-do\n/); assert.match(text, /\n## Open\n\n[^]*## Done\n\n/); assert.ok(text.endsWith('\n'), 'whole'); reads++; }
      await new Promise(next => setTimeout(next, 2));
    }
  })();
  const workers = [];
  for (let w = 0; w < cli; w++) workers.push((async () => {
    for (let i = 0; i < rounds; i++) {
      const title = `cli-${w}-${i} 한글`;
      let id;
      await retry('cli', async () => { const r = await node(['add', title]); if (r.code) { if (unsure(r.err, items => items.some(i => i.title === title))) return true; id = core.load(file).items.find(i => i.title === title).id; return false; } id = r.out; return false; });
      acked.add(title);
      await retry('cli', async () => { const r = await node(['note', id, `note ${title}`]); return !!r.code && unsure(r.err, items => items.some(i => i.events.some(e => e.what === `note ${title}`))); });
      notes.push(title);
    }
  })());
  for (let w = 0; w < web; w++) workers.push((async () => {
    for (let i = 0; i < rounds; i++) {
      const title = `web-${w}-${i}`;
      await retry('web', async () => { const r = await call(server.url, '/api/items', { text: title }); return r.status !== 200 && unsure(r.text, items => items.some(i => i.title === title)); });
      acked.add(title);
      await retry('web', async () => {
        const model = core.load(file), item = model.items.find(other => other.title === title);
        const r = await call(server.url, '/api/item', { op: 'reply', id: item.id, version: core.itemVersion(item, model), text: `reply ${title}` });
        return r.status !== 200 && (/This item changed/.test(r.text) || unsure(r.text, items => items.some(i => i.events.some(e => e.what === `reply — reply ${title}`))));
      });
      notes.push(title);
    }
  })());
  await Promise.all(workers);
  reading = false;
  await torn;
  const items = core.load(file).items, count = title => items.filter(item => item.title === title).length;
  for (const title of acked) assert.equal(count(title), 1, `${title} once`);
  assert.equal(items.length, acked.size);
  for (const title of notes) {
    const said = items.find(item => item.title === title).events.filter(event => event.what === `note ${title}` || event.what === `reply — reply ${title}`);
    assert.equal(said.length, 1, `${title} answered once`);
  }
  assert.deepEqual(readdirSync(dir).filter(name => /\.lock|\.tmp$/.test(name)), [], 'no lock, marker or temporary file stays');
  t.diagnostic(`${acked.size * 2} writes, ${reads} whole reads, retries after a busy lock: cli ${retries.cli}, web ${retries.web}`);
});

test('rust: a stale lock and the markers of dead processes are taken over', needsRust, async t => {
  const dir = scratch(t), file = join(dir, 'todo.md');
  const server = await startRustWeb({ file, kit, feed: join(dir, 'feed.json'), onUrl() {} });
  t.after(() => server.close());
  const { utimesSync } = await import('node:fs');
  for (const kind of ['reclaim', 'commit']) mkdirSync(`${file}.lock.${kind}-99999999-0aa0aa00-0000-4000-8000-000000000000`);
  writeFileSync(`${file}.lock`, 'dead owner');
  const old = new Date(Date.now() - 20000);
  utimesSync(`${file}.lock`, old, old);
  assert.equal((await call(server.url, '/api/items', { text: 'after a dead owner' })).status, 200);
  // A fresh lock of a live owner is respected.
  writeFileSync(`${file}.lock`, 'live owner');
  const busy = await call(server.url, '/api/items', { text: 'refused' });
  assert.equal(busy.status, 400);
  assert.equal(JSON.parse(busy.text).error, `timed out waiting for lock: ${file}.lock`);
  assert.equal(readFileSync(`${file}.lock`, 'utf8'), 'live owner');
  rmSync(`${file}.lock`);
  assert.deepEqual(core.load(file).items.map(item => item.title), ['after a dead owner']);
  assert.deepEqual(readdirSync(dir).filter(name => /\.lock|\.tmp$/.test(name)), []);
});

const posix = { skip: needsRust.skip || process.platform === 'win32' && 'POSIX stub scripts' };
for (const stream of ['stderr', 'stdout']) test(`rust: an approve child that floods ${stream} and never exits frees the list, as with the Node server`, posix, async t => {
  for (const [name, start] of [['node', startWeb], ['rust', startRustWeb]]) {
    const root = join(scratch(t), name), file = join(root, 'todo.md');
    mkdirSync(join(root, '.sdlc'), { recursive: true });
    writeFileSync(join(root, 'sdlc.sh'), `if [ "$1" = approve ]; then exec yes ${stream === 'stderr' ? '>&2' : ''}; fi\nprintf '{"store":"${root}/.sdlc","features":[{"slug":"s","phase":"plan","state":"NEEDS-HUMAN","action":"approve plan"}]}\\n'\n`);
    writeFileSync(file, `## Open\n\n- [ ] a\n  - project: ${root}\n  - sdlc: s · plan · NEEDS-HUMAN — approve plan\n`);
    const server = await start({ file, kit: root, feed: join(root, 'feed.json'), onUrl() {} });
    t.after(() => server.close());
    const model = core.load(file), began = Date.now();
    const response = await call(server.url, '/api/approve', { id: model.items[0].id, version: core.itemVersion(model.items[0], model), gate: 'plan', sha: 'a'.repeat(64), words: 'ok' });
    assert.equal(response.status, 409, name);
    assert.ok(Date.now() - began < 15000, `${name} stopped the child`);
    if (stream === 'stdout') assert.equal(JSON.parse(response.text).error, 'stdout maxBuffer length exceeded', name);
    else assert.ok(JSON.parse(response.text).error.startsWith('y\ny\n'), name);
    await core.add(file, `${name} can write again`);
    assert.doesNotMatch(readFileSync(file, 'utf8'), /human: approved/);
  }
});

test('rust: the default list and session are the ones Node names, with HOME set, empty and unset', needsRust, async () => {
  const { execFileSync } = await import('node:child_process');
  const name = process.platform === 'win32' ? 'USERPROFILE' : 'HOME';
  for (const home of ['/tmp/some home', '', undefined]) for (const todo of [undefined, '', '/tmp/x/list.md']) {
    if (home === '' && process.platform === 'win32') continue; // os.homedir() throws there
    const env = { ...process.env, SDLC_TODO: todo };
    delete env.SDLC_TODO_SESSION;
    delete env[name];
    if (todo === undefined) delete env.SDLC_TODO;
    if (home !== undefined) env[name] = home;
    const script = `import(${JSON.stringify(new URL('../todo/core.mjs', import.meta.url).href)}).then(c => console.log(c.todoPath() + '\\n' + c.sessionPath()))`;
    const expected = execFileSync(process.execPath, ['-e', script], { env, encoding: 'utf8' }).trim();
    assert.equal(execFileSync(rustServer, ['--where'], { env, encoding: 'utf8' }).trim().replaceAll('\r', ''), expected, `home ${home} todo ${todo}`);
  }
});

test('rust: silent connections neither hide the server nor stay', needsRust, async t => {
  const net = await import('node:net');
  const dir = scratch(t);
  const server = await startRustWeb({ file: join(dir, 'todo.md'), kit, feed: join(dir, 'feed.json'), onUrl() {} });
  t.after(() => server.close());
  const at = new URL(server.url), sockets = [];
  t.after(() => { for (const socket of sockets) socket.destroy(); });
  let closed = 0;
  for (let i = 0; i < 300; i++) {
    const socket = net.connect(Number(at.port), '127.0.0.1');
    socket.on('error', () => {});
    socket.on('close', () => { closed++; });
    sockets.push(socket);
    if (i % 2) socket.write('GET / HTT');
  }
  await new Promise(done => setTimeout(done, 1000));
  for (let i = 0; i < 5; i++) {
    const began = Date.now();
    assert.equal((await call(server.url, '/api/live')).status, 200);
    assert.ok(Date.now() - began < 1500, 'answered inside the app\'s 2 s check');
  }
  for (const socket of sockets) socket.resume();
  const end = Date.now() + 15000;
  while (closed < 300 && Date.now() < end) await new Promise(done => setTimeout(done, 100));
  assert.equal(closed, 300, 'silent connections are closed');
});

test('rust: close returns while a Node helper hangs', posix, async t => {
  const dir = scratch(t), file = join(dir, 'todo.md'), hang = join(dir, 'node'), started = join(dir, 'started');
  writeFileSync(hang, `#!/bin/sh\ntouch '${started}'\nexec sleep 60\n`, { mode: 0o755 });
  const server = await startRustWeb({ file, kit, node: hang, feed: join(dir, 'feed.json'), onUrl() {} });
  const at = new URL(server.url), token = new URLSearchParams(at.hash.slice(1)).get('t');
  const stream = fetch(`${at.origin}/events?t=${token}`).catch(() => null);
  await stream;
  writeFileSync(file, '## Open\n\n- [ ] odd\n  - link: [a](https://한글.example/)\n');
  for (let i = 0; i < 100 && !existsSync(started); i++) await new Promise(done => setTimeout(done, 50));
  assert.ok(existsSync(started), 'a frame waits on the helper');
  assert.equal((await call(server.url, '/api/live')).status, 200, 'still live');
  const began = Date.now();
  await server.close();
  assert.ok(Date.now() - began < 4000, `closed in ${Date.now() - began} ms`);
});

test('rust: a change that could not be shown while the Node helper failed is shown once it works, without another write', posix, async t => {
  const dir = scratch(t), file = join(dir, 'todo.md'), node = join(dir, 'node'), works = join(dir, 'works'), asked = join(dir, 'asked');
  writeFileSync(node, `#!/bin/sh\necho x >> '${asked}'\n[ -f '${works}' ] || exit 1\nexec '${process.execPath}' "$@"\n`, { mode: 0o755 });
  const server = await startRustWeb({ file, kit, node, feed: join(dir, 'feed.json'), onUrl() {} });
  t.after(() => server.close());
  const at = new URL(server.url), token = new URLSearchParams(at.hash.slice(1)).get('t'), stop = new AbortController();
  t.after(() => stop.abort());
  const response = await fetch(`${at.origin}/events?t=${token}`, { signal: stop.signal });
  let text = '';
  (async () => { for await (const chunk of response.body) text += Buffer.from(chunk).toString(); })().catch(() => {});
  const until = async (check, what) => { for (let i = 0; i < 300 && !check(); i++) await new Promise(done => setTimeout(done, 50)); assert.ok(check(), what); };
  await until(() => text.includes('"items":[]'), 'the first frame');
  writeFileSync(file, '## Open\n\n- [ ] odd link\n  - link: [a](https://한글.example/)\n');
  await until(() => text.includes('event: error'), 'the failure is reported');
  assert.ok(!text.includes('odd link'));
  await new Promise(done => setTimeout(done, 2500));
  assert.equal(text.split('event: error').length, 2, 'reported once');
  assert.ok(readFileSync(asked, 'utf8').split('\n').length < 8, 'retries back off');
  writeFileSync(works, '');
  await until(() => text.includes('odd link'), 'shown after the helper works');
});

test('rust: a marker whose time cannot be read is left out of the list alone, fails no stored change, and shows later', posix, async t => {
  const dir = scratch(t), file = join(dir, 'todo.md'), node = join(dir, 'node'), works = join(dir, 'works');
  writeFileSync(node, `#!/bin/sh\n[ -f '${works}' ] || exit 1\nexec '${process.execPath}' "$@"\n`, { mode: 0o755 });
  writeFileSync(file, '## Open\n\n- [ ] fine\n\n- [ ] odd\n');
  const id = title => core.load(file).items.find(item => item.title === title).id, now = new Date().toISOString();
  writeFileSync(join(dir, 'todo-working.json'), JSON.stringify({ [id('fine')]: { what: 'ok', since: now, beat: now }, [id('odd')]: { what: 'odd', since: now, beat: new Date().toString() } }));
  const server = await startRustWeb({ file, kit, node, feed: join(dir, 'feed.json'), onUrl() {} });
  t.after(() => server.close());
  const what = (items, title) => items.find(item => item.title === title)?.working?.what;
  const listed = JSON.parse((await call(server.url, '/api/items')).text).items;
  assert.deepEqual([what(listed, 'fine'), what(listed, 'odd')], ['ok', undefined]);
  const at = new URL(server.url), token = new URLSearchParams(at.hash.slice(1)).get('t'), stop = new AbortController();
  t.after(() => stop.abort());
  const response = await fetch(`${at.origin}/events?t=${token}`, { signal: stop.signal });
  assert.equal(response.status, 200);
  let text = '';
  (async () => { for await (const chunk of response.body) text += Buffer.from(chunk).toString(); })().catch(() => {});
  const added = await call(server.url, '/api/items', { text: 'stored once' });
  assert.equal(added.status, 200, added.text);
  assert.equal(JSON.parse(added.text).items.filter(item => item.title === 'stored once').length, 1);
  const model = core.load(file), item = model.items.find(other => other.title === 'fine');
  const edited = await call(server.url, '/api/item', { op: 'edit', id: item.id, version: core.itemVersion(item, model), title: 'renamed' });
  assert.equal(what(JSON.parse(edited.text).items, 'renamed'), 'ok', 'the readable marker followed its item');
  assert.ok(!text.includes('event: error'));
  writeFileSync(works, '');
  for (let i = 0; i < 300 && !text.includes('"what":"odd"'); i++) await new Promise(done => setTimeout(done, 50));
  assert.ok(text.includes('"what":"odd"'), 'sent without another write once the time can be read');
  assert.equal(core.load(file).items.filter(other => other.title === 'stored once').length, 1);
});

test('rust: a status refresh that fails after a recorded approval is retried until the card is right, with no further request', posix, async t => {
  const dir = scratch(t), file = join(dir, 'todo.md'), lock = `${file}.lock`, approved = join(dir, 'approved'), failed = join(dir, 'failed');
  // After the approval, the first status call leaves the list locked by someone else, so that refresh cannot be written.
  writeFileSync(join(dir, 'sdlc.sh'), `if [ "$1" = approve ]; then touch '${approved}'; exit; fi
state=NEEDS-HUMAN; action='approve plan'
if [ -f '${approved}' ]; then state=READY; action='build it'; [ -f '${failed}' ] || { touch '${failed}'; echo other > '${lock}'; }; fi
printf '{"store":"${dir}/.sdlc","features":[{"slug":"s","phase":"plan","state":"%s","action":"%s"}]}\\n' "$state" "$action"
`);
  writeFileSync(file, `## Open\n\n- [ ] a\n  - project: ${dir}\n  - sdlc: s · plan · NEEDS-HUMAN — approve plan\n`);
  const server = await startRustWeb({ file, kit: dir, feed: join(dir, 'feed.json'), onUrl() {} });
  t.after(() => server.close());
  const at = new URL(server.url), token = new URLSearchParams(at.hash.slice(1)).get('t'), stop = new AbortController();
  t.after(() => stop.abort());
  let text = '';
  const response = await fetch(`${at.origin}/events?t=${token}`, { signal: stop.signal });
  (async () => { for await (const chunk of response.body) text += Buffer.from(chunk).toString(); })().catch(() => {});
  const model = core.load(file);
  const answer = await call(server.url, '/api/approve', { id: model.items[0].id, version: core.itemVersion(model.items[0], model), gate: 'plan', sha: 'a'.repeat(64), words: 'ok' });
  assert.equal(answer.status, 200, answer.text);
  assert.equal(core.load(file).items[0].sdlc.state, 'NEEDS-HUMAN', 'the refresh failed');
  assert.equal(readFileSync(lock, 'utf8'), 'other\n');
  rmSync(lock);
  for (let i = 0; i < 300 && !text.includes('"state":"READY"'); i++) await new Promise(done => setTimeout(done, 50));
  assert.ok(text.includes('"state":"READY"'), 'the stream shows it');
  assert.equal(core.load(file).items[0].events.filter(event => event.what.startsWith('approved plan')).length, 1);
});
