import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import * as core from './core.mjs';

const execute = promisify(execFile);
const defaultKit = fileURLToPath(new URL('../', import.meta.url));
const page = fileURLToPath(new URL('./page/', import.meta.url));
const bodyLimit = 64 * 1024;
const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['app.js', 'text/javascript; charset=utf-8']],
  ['/app.css', ['app.css', 'text/css; charset=utf-8']],
  ['/markdown.js', ['markdown.js', 'text/javascript; charset=utf-8']]
]);
const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
function text(value, name, max = Infinity) {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max || /[\r\n]/.test(value)) fail(400, `invalid ${name}`);
  return value.trim();
}
function itemFor(file, id) {
  if (typeof id !== 'string') fail(400, 'invalid id');
  const item = core.load(file).items.find(item => item.id === id);
  if (!item) fail(404, 'item not found');
  return item;
}
function approvalGate(item) {
  core.projectPath(item.project);
  const gate = item.sdlc?.action.match(/\bapprove\s+(intent|plan)\b/)?.[1];
  if (item.done || item.sdlc?.state !== 'NEEDS-HUMAN' || !gate || !item.project ||
      !/^[a-z0-9][a-z0-9._-]{0,79}$/.test(item.sdlc.slug)) fail(409, 'item has no approval gate');
  return gate;
}
// Bash can keep a junction cwd whose realpath would select a different store.
async function projectStore(item, kit, statusRunner) {
  const cwd = await core.nativePath(core.projectPath(item.project));
  const { stdout } = await statusRunner('bash', [path.join(kit, 'sdlc.sh'), 'status', item.sdlc.slug, '--json'], { cwd });
  const { store } = JSON.parse(stdout);
  if (typeof store !== 'string' || !store) fail(409, 'status did not report a store');
  return core.nativePath(store);
}
async function artifact(item, gate, kit, statusRunner) {
  const store = await projectStore(item, kit, statusRunner);
  let folder = path.join(store, 'work', item.sdlc.slug);
  if (!fs.existsSync(folder)) folder = path.join(store, 'archive', item.sdlc.slug);
  const file = path.join(folder, gate === 'intent' ? 'intent.md' : 'PLAN.md');
  const bytes = fs.readFileSync(file);
  return { gate, file, markdown: bytes.toString('utf8'), sha: createHash('sha256').update(bytes).digest('hex') };
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0, tooLarge = false;
    const chunks = [];
    req.on('data', chunk => {
      size += chunk.length;
      if (size > bodyLimit) {
        if (!tooLarge) reject(Object.assign(new Error('body too large'), { status: 413 }));
        tooLarge = true;
        chunks.length = 0;
      } else if (!tooLarge) chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooLarge) return;
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (!value || typeof value !== 'object' || Array.isArray(value)) fail(400, 'invalid JSON object');
        resolve(value);
      } catch { reject(Object.assign(new Error('invalid JSON object'), { status: 400 })); }
    });
    req.on('error', reject);
    req.on('aborted', () => reject(Object.assign(new Error('request aborted'), { status: 400 })));
  });
}
function openBrowser(url) {
  const [command, args] = process.platform === 'darwin' ? ['/usr/bin/open', [url]] :
    process.platform === 'win32' ? ['rundll32.exe', ['url.dll,FileProtocolHandler', url]] : ['xdg-open', [url]];
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: 'ignore', shell: false });
    child.once('error', error => reject(new Error(`could not open browser: ${error.code || 'spawn failed'}`)));
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}

export async function startWeb({ file = core.todoPath(), kit = defaultKit, port = 0, open = false, onUrl, statusRunner = execute } = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('invalid port');
  if (!onUrl && !open && !process.stdout.isTTY) throw new Error('web requires a terminal or --open');
  const token = randomBytes(16).toString('hex'), expected = Buffer.from(token);
  const authorized = value => typeof value === 'string' && Buffer.byteLength(value) === expected.length && timingSafeEqual(Buffer.from(value), expected);
  const clients = new Set();
  const payload = () => {
    const model = core.load(file);
    return { items: model.items.map(item => ({ ...item, version: core.itemVersion(item, model) })), file };
  };
  const sendEvent = (res, value, event = '') => res.write(`${event ? `event: ${event}\n` : ''}data: ${JSON.stringify(value)}\n\n`);
  const broadcast = () => {
    try { const value = payload(); for (const res of clients) sendEvent(res, value); }
    catch (error) { for (const res of clients) sendEvent(res, { error: error.message }, 'error'); }
  };
  await core.sync(file, { kit });
  let actualPort;
  const server = http.createServer(async (req, res) => {
    res.setHeader('Content-Security-Policy', "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Cache-Control', 'no-store');
    const json = (status, value) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(value));
    };
    try {
      const hosts = [`127.0.0.1:${actualPort}`, `localhost:${actualPort}`];
      const origins = hosts.map(host => `http://${host}`);
      if (!hosts.includes(req.headers.host) || req.rawHeaders.filter((value, index) => index % 2 === 0 && value.toLowerCase() === 'host').length !== 1) fail(403, 'Forbidden');
      const url = new URL(req.url, origins[0]);
      if ((url.pathname === '/api' || url.pathname.startsWith('/api/')) && !authorized(req.headers['x-todo-token'])) fail(403, 'Forbidden');
      if (url.pathname === '/events' && !authorized(url.searchParams.get('t'))) fail(403, 'Forbidden');
      if (req.method !== 'GET' && (!origins.includes(req.headers.origin) ||
          typeof req.headers['content-type'] !== 'string' || req.headers['content-type'].split(';')[0].trim().toLowerCase() !== 'application/json')) fail(403, 'Forbidden');
      if (req.method === 'GET') {
        if (assets.has(url.pathname)) {
          const [name, type] = assets.get(url.pathname);
          const content = fs.readFileSync(path.join(page, name));
          res.writeHead(200, { 'Content-Type': type });
          res.end(content);
        } else if (url.pathname === '/api/items') {
          await core.sync(file, { kit });
          json(200, payload());
        } else if (url.pathname === '/api/artifact') {
          await core.sync(file, { kit });
          const item = itemFor(file, url.searchParams.get('id'));
          json(200, await artifact(item, approvalGate(item), kit, statusRunner));
        } else if (url.pathname === '/events') {
          const initial = payload();
          res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', Connection: 'keep-alive' });
          res.flushHeaders();
          clients.add(res);
          res.on('close', () => clients.delete(res));
          sendEvent(res, initial);
        } else json(404, { error: 'not found' });
        return;
      }
      const body = await readBody(req);
      if (req.method !== 'POST') { json(405, { error: 'method not allowed' }); return; }
      if (url.pathname === '/api/items') {
        await core.add(file, text(body.text, 'text'), { by: 'human' });
      } else if (url.pathname === '/api/item') {
        const id = body.id, version = body.version ?? null;
        switch (body.op) {
          case 'edit': await core.edit(file, id, { title: text(body.title, 'title') }, version); break;
          case 'move':
            if (body.delta !== 1 && body.delta !== -1) fail(400, 'invalid delta');
            await core.move(file, id, body.delta, version); break;
          case 'done': await core.done(file, id, '', 'human', version); break;
          case 'undone':
            await core.update(file, id, (current, model) => {
              current.done = false;
              current.events.push({ at: core.stamp(), who: 'human', what: 'undone' });
              model.items.splice(model.items.indexOf(current), 1);
              const firstDone = model.items.findIndex(other => other.done);
              model.items.splice(firstDone < 0 ? model.items.length : firstDone, 0, current);
            }, version); break;
          case 'delete': await core.remove(file, id, version); break;
          case 'reply': await core.reply(file, id, text(body.text, 'reply'), version); break;
          default: fail(400, 'invalid operation');
        }
      } else if (url.pathname === '/api/approve') {
        const words = text(body.words, 'words', 500);
        if (!['intent', 'plan'].includes(body.gate) || typeof body.sha !== 'string' || !/^[a-f0-9]{64}$/i.test(body.sha)) fail(400, 'invalid approval');
        await core.update(file, body.id, async item => {
          if (approvalGate(item) !== body.gate) fail(409, 'approval gate changed');
          try {
            const store = await projectStore(item, kit, statusRunner);
            await execute('bash', [path.join(kit, 'sdlc.sh'), 'approve', body.gate, item.sdlc.slug, '--human', words, '--sha', body.sha], { cwd: path.dirname(store) });
          } catch (error) { fail(409, error.stderr || error.message); }
          item.events.push({ at: core.stamp(), who: 'human', what: `approved ${body.gate} — "${words}"` });
        }, body.version ?? null);
        await core.sync(file, { kit });
      } else { json(404, { error: 'not found' }); return; }
      json(200, payload());
    } catch (error) {
      if (res.headersSent) { res.end(); return; }
      if (error.status === 403) { res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end('Forbidden\n'); }
      else json(error.status || 400, { error: error.message });
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  actualPort = server.address().port;
  // Watching only loads the file: sync writes it, so syncing in the watcher would loop.
  const stopWatch = core.watch(file, broadcast);
  const keepalive = setInterval(() => { for (const res of clients) res.write(': keepalive\n\n'); }, 15000);
  keepalive.unref();
  let closing;
  const close = () => {
    if (!closing) {
      stopWatch();
      clearInterval(keepalive);
      for (const res of clients) res.end();
      clients.clear();
      closing = new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      server.closeIdleConnections?.();
    }
    return closing;
  };
  const url = `http://127.0.0.1:${actualPort}/#t=${token}`;
  try {
    if (onUrl) await onUrl(url);
    if (open) await openBrowser(url);
    else if (!onUrl) process.stdout.write(`${url}\n`);
  } catch (error) { await close(); throw error; }
  return { url, close };
}
