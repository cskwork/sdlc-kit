import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import * as core from './core.mjs';
import { defaultLanguage, isLanguage, languages, translator } from './i18n.mjs';
import { shellWord, statusOf, visibleText } from './status.mjs';

const execute = promisify(execFile);
const defaultKit = fileURLToPath(new URL('../', import.meta.url));
const here = fileURLToPath(new URL('./', import.meta.url));
const bodyLimit = 64 * 1024;
const js = 'text/javascript; charset=utf-8';
// Allow-list of served files; the page shares the language and status modules with the TUI.
const assets = new Map([
  ['/', ['page/index.html', 'text/html; charset=utf-8']],
  ['/app.js', ['page/app.js', js]],
  ['/app.css', ['page/app.css', 'text/css; charset=utf-8']],
  ['/markdown.js', ['page/markdown.js', js]],
  ['/board.js', ['page/board.js', js]],
  ['/favicon.png', ['app/AppIcon.png', 'image/png']],
  ['/i18n.mjs', ['i18n.mjs', js]],
  ['/status.mjs', ['status.mjs', js]],
  ...languages.map(language => [`/locales/${language}.mjs`, [`locales/${language}.mjs`, js]])
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
const slugPattern = /^[a-z0-9][a-z0-9._-]{0,79}$/;
const gateIn = item => item.sdlc?.state === 'NEEDS-HUMAN' && item.sdlc.action.match(/\bapprove\s+(intent|plan)\b/)?.[1] || '';
function approvalGate(item) {
  core.projectPath(item.project);
  const gate = gateIn(item);
  if (item.done || !gate || !item.project ||
      !slugPattern.test(item.sdlc.slug)) fail(409, 'item has no approval gate');
  return gate;
}
// Any open sdlc item can show its work document; only an approval gate makes it approvable.
function documentGate(item) {
  core.projectPath(item.project);
  if (item.done || !item.sdlc || !item.project ||
      !slugPattern.test(item.sdlc.slug)) fail(409, 'item has no work document');
  return gateIn(item);
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
  // Without a gate, show the plan once one exists, otherwise the intent.
  const plan = gate ? gate === 'plan' : item.sdlc.phase !== 'intent' && fs.existsSync(path.join(folder, 'PLAN.md'));
  const file = path.join(folder, plan ? 'PLAN.md' : 'intent.md');
  const bytes = fs.readFileSync(file);
  return { gate, file, markdown: bytes.toString('utf8'), sha: createHash('sha256').update(bytes).digest('hex') };
}
// A brief is any open item's own document; an sdlc approval gate keeps its approvable artifact.
function briefDocument(item) {
  if (item.done) fail(409, 'item has no work document');
  if (!path.isAbsolute(item.brief)) fail(409, 'brief must be an absolute path');
  let bytes;
  try { bytes = fs.readFileSync(item.brief); }
  catch (error) { fail(error.code === 'ENOENT' ? 404 : 409, `brief not readable: ${item.brief}`); }
  return { gate: '', file: item.brief, markdown: bytes.toString('utf8'), sha: createHash('sha256').update(bytes).digest('hex') };
}
// The board's optional feed: JSON another tool writes. It is untrusted text; a missing file is no feed, and an
// unreadable or invalid one says so instead of keeping stale data.
const feedLimit = 1024 * 1024;
// Beside the list, like todo-working.json: ~/.sdlc/todo-feed.json for the default list.
export const feedPath = (file = core.todoPath()) => process.env.SDLC_TODO_FEED || path.join(path.dirname(file), 'todo-feed.json');
export function readFeed(file) {
  let bytes;
  try { bytes = fs.readFileSync(file); }
  catch (error) { return error.code === 'ENOENT' || error.code === 'ENOTDIR' ? { feed: null, error: '' } : { feed: null, error: 'feed not readable' }; }
  if (bytes.length > feedLimit) return { feed: null, error: 'feed too large' };
  try {
    const feed = JSON.parse(bytes.toString('utf8'));
    return feed && typeof feed === 'object' && !Array.isArray(feed) ? { feed, error: '' } : { feed: null, error: 'feed is not a JSON object' };
  } catch { return { feed: null, error: 'feed is not valid JSON' }; }
}
// An exec request runs the item's command as given: no shell, argv[0] resolved to an absolute path first, its own
// process group so a timeout reaches every process it started.
const runLimit = 64 * 1024;
// The last `limit` bytes of a stream, cut on a UTF-8 character boundary; no size kills the command.
function tailBuffer(limit = runLimit) {
  let chunks = [], size = 0, cut = false;
  return {
    push(chunk) {
      chunks.push(chunk); size += chunk.length;
      if (size > 2 * limit) { const kept = Buffer.concat(chunks).subarray(-limit); chunks = [kept]; size = kept.length; cut = true; }
    },
    text() {
      let bytes = Buffer.concat(chunks);
      if (bytes.length > limit) { bytes = bytes.subarray(-limit); cut = true; }
      let from = 0;
      while (cut && from < bytes.length && (bytes[from] & 0xc0) === 0x80) from++;
      return bytes.subarray(from).toString('utf8');
    }
  };
}
let defaultSearchPath;
const runsLogPath = () => path.join(os.homedir(), '.sdlc', 'todo-runs.log');
// The log is a record, never a gate: a log that cannot be written must not skip the reply.
function logRun(entry) {
  try {
    const file = runsLogPath();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const fd = fs.openSync(file, 'a', 0o600);
    try { fs.fchmodSync(fd, 0o600); fs.writeSync(fd, `${JSON.stringify(entry)}\n`); }
    finally { fs.closeSync(fd); }
  } catch (error) { console.error(`to-do exec log not written: ${error.message}`); }
}
// The PATH a command is found on. A tray app started by Finder or at login gets launchd's short PATH, so the login
// shell's PATH comes first, then this process's. Relative and empty entries (".", "") are dropped: they would
// resolve against the agent-chosen cwd.
export async function commandSearchPath({ shell = process.env.SHELL, inherited = process.env.PATH || '' } = {}) {
  let login = '';
  if (process.platform !== 'win32' && shell && path.isAbsolute(shell)) {
    try { login = (await execute(shell, ['-lc', 'printf %s "$PATH"'], { timeout: 5000, encoding: 'utf8' })).stdout; } catch { login = ''; }
  }
  return [...new Set([...login.split(path.delimiter), ...inherited.split(path.delimiter)].filter(entry => entry && path.isAbsolute(entry)))].join(path.delimiter);
}
const executable = file => { try { return fs.statSync(file).isFile() && (fs.accessSync(file, fs.constants.X_OK), true); } catch { return false; } };
export const execSupported = (platform = process.platform) => platform !== 'win32';
export function resolveCommand(name, searchPath) {
  if (path.isAbsolute(name)) return executable(name) ? name : '';
  for (const dir of searchPath.split(path.delimiter)) {
    const candidate = path.join(dir, name);
    if (executable(candidate)) return candidate;
  }
  return '';
}
// exitCode 127 = not found and 126 = could not start, as a shell reports them; error names the system code.
function startFailure(error) {
  const code = error.code || 'ERROR';
  return { exitCode: code === 'ENOENT' ? 127 : 126, signal: null, error: code, message: error.message };
}
export function runArgv({ program, argv, cwd, env, timeout, killAfter = 5000, grace = 2000 }) {
  return new Promise(resolve => {
    const out = tailBuffer(), err = tailBuffer();
    let child, timedOut = false, settled = false, exited = null, closed = false;
    const timers = [];
    const finish = result => {
      if (settled) return;
      settled = true;
      for (const timer of timers) clearTimeout(timer);
      resolve({ exitCode: result.exitCode, signal: result.signal || null, error: result.error || '', timedOut,
        stdout: out.text(), stderr: err.text() || result.message || '' });
    };
    if (!fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) return finish({ exitCode: 126, error: 'ENOTDIR', message: `cwd is not a directory: ${cwd}` });
    try {
      child = spawn(program, argv.slice(1), { cwd, env, argv0: argv[0], detached: process.platform !== 'win32', stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true, shell: false });
    } catch (error) { return finish(startFailure(error)); }
    child.stdout.on('data', chunk => out.push(chunk));
    child.stderr.on('data', chunk => err.push(chunk));
    // Only a command that never started reports here; a failed kill of a running one changes nothing.
    child.once('error', error => { if (child.pid === undefined) finish(startFailure(error)); });
    const group = signal => {
      try { if (process.platform === 'win32') child.kill(signal); else process.kill(-child.pid, signal); } catch { /* already gone */ }
    };
    // TERM to the whole group, then KILL to whatever ignored it; the KILL also reaches grandchildren after the leader exits.
    timers.push(setTimeout(() => {
      timedOut = true;
      group('SIGTERM');
      const kill = setTimeout(() => group('SIGKILL'), killAfter);
      kill.unref?.();
    }, timeout));
    child.once('exit', (code, signal) => {
      exited = { exitCode: code, signal };
      if (closed) return finish(exited);
      // A background process that inherited stdout keeps the pipes open: wait briefly for them, then stop reading.
      timers.push(setTimeout(() => { child.stdout.destroy(); child.stderr.destroy(); finish(exited); }, grace));
    });
    child.once('close', () => { closed = true; if (exited) finish(exited); });
  });
}
const lastLine = text => text.split(/\r?\n/).map(part => part.trim()).filter(Boolean).pop() || '';
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
export function openBrowser(url) {
  const [command, args] = process.platform === 'darwin' ? ['/usr/bin/open', [url]] :
    process.platform === 'win32' ? ['rundll32.exe', ['url.dll,FileProtocolHandler', url]] : ['xdg-open', [url]];
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: 'ignore', shell: false });
    child.once('error', error => reject(new Error(`could not open browser: ${error.code || 'spawn failed'}`)));
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}

// The session file lets the app and later launches reach a running server; it holds the token, so only the owner may read it.
const urlOf = session => `http://127.0.0.1:${session.port}/#t=${session.token}`;
function writeSession(file, session) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(session)}\n`, { mode: 0o600 });
  fs.chmodSync(temp, 0o600);
  fs.renameSync(temp, file);
}
function readSession(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    return Number.isInteger(value?.port) && /^[a-f0-9]{32}$/.test(value.token) ? value : null;
  } catch { return null; }
}
// What a server proves it holds the token with, for a fresh nonce (GET /proof?n=…): only the server that wrote the
// session file can answer it, and the token never travels to a program that took the port of one that is gone.
export const proofOf = (token, nonce) => createHmac('sha256', token).update(`sdlc-todo-proof:${nonce}`).digest('hex');
export async function liveSession(file = core.sessionPath()) {
  const session = readSession(file);
  if (!session) return null;
  try {
    const nonce = randomBytes(16).toString('hex');
    const response = await fetch(`http://127.0.0.1:${session.port}/proof?n=${nonce}`, { signal: AbortSignal.timeout(2000) });
    const shown = response.ok ? String((await response.json())?.proof || '') : (await response.body?.cancel(), '');
    const expected = Buffer.from(proofOf(session.token, nonce));
    return shown.length === expected.length && timingSafeEqual(Buffer.from(shown), expected) ? { ...session, url: urlOf(session) } : null;
  } catch { return null; }
}

export async function startWeb({ file = core.todoPath(), kit = defaultKit, port = 0, open = false, onUrl, statusRunner = execute, lang = defaultLanguage, session = '', feed = feedPath(file), deferInitialSync = false, runTimeout = 300000, killAfter = 5000, searchPath, finishRetryMs = 30000, platform = process.platform } = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('invalid port');
  if (!isLanguage(lang)) throw new Error(`invalid language: ${lang}`);
  if (!onUrl && !open && !process.stdout.isTTY) throw new Error('web requires a terminal or --open');
  const token = randomBytes(16).toString('hex'), expected = Buffer.from(token);
  const authorized = value => typeof value === 'string' && Buffer.byteLength(value) === expected.length && timingSafeEqual(Buffer.from(value), expected);
  const clients = new Set();
  let feedState = readFeed(feed);
  const payload = () => {
    const model = core.load(file);
    // The version hashes the item as loaded; the working marker is not part of it.
    return { items: core.withWorking(model.items, file).map((item, i) => ({ ...item, ...(item.exec ? { execPath: canExec ? resolveCommand(item.exec.argv[0], commandPath) : '', ...(canExec ? {} : { execUnsupported: true }) } : {}), version: core.itemVersion(model.items[i], model), turn: statusOf(item) })), file, lang,
      feed: feedState.feed, ...(feedState.error ? { feedError: feedState.error } : {}) };
  };
  const sendEvent = (res, value, event = '') => res.write(`${event ? `event: ${event}\n` : ''}data: ${JSON.stringify(value)}\n\n`);
  const broadcast = () => {
    try { const value = payload(); for (const res of clients) sendEvent(res, value); }
    catch (error) { for (const res of clients) sendEvent(res, { error: error.message }, 'error'); }
  };
  if (!deferInitialSync) await core.sync(file, { kit });
  // Reads share one sync: each runs sdlc.sh status per item, so a burst of artifact requests
  // (one per open card) would otherwise queue many multi-second syncs and time the app out.
  let syncing = null;
  const synced = () => (syncing ??= core.sync(file, { kit }).finally(() => { syncing = null; }));
  const t = translator(lang);
  // argv[0] is resolved once per request against a sane PATH; the dialog shows that program and the run spawns it.
  // Windows has no POSIX shell, process groups or login-shell PATH: the board does not run commands there yet.
  const canExec = execSupported(platform);
  const commandPath = !canExec ? '' : searchPath ?? await (defaultSearchPath ??= commandSearchPath());
  const childEnv = { ...process.env, PATH: commandPath };
  // A run is recorded in todo.md before it starts and when it ends, so every server and tab sees it:
  // "exec started run=<id> pid=<server pid> server=<server nonce> — <command>" and "exec finished run=<id> — <result>".
  const serverId = randomBytes(4).toString('hex'), running = new Set();
  const startOf = runId => event => event.who === 'human' && event.what.startsWith(`exec started run=${runId} `);
  const unfinished = item => item.events.flatMap(event => {
    const started = event.who === 'human' && event.what.match(/^exec started run=([0-9a-f]+) pid=(\d+)(?: server=([0-9a-f]+))? /);
    if (!started || item.events.some(other => other.who === 'human' && other.what.startsWith(`exec finished run=${started[1]} `))) return [];
    return [{ runId: started[1], pid: Number(started[2]), server: started[3] || '', at: Date.parse(event.at.replace(' ', 'T')) }];
  });
  const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; } };
  // No run outlives its timeout, the KILL that follows, the pipe grace and a minute of slack: a start older than that
  // is dead even if its pid now belongs to another process (a reboot can hand it to a root daemon, which answers EPERM).
  const longestRun = runTimeout + killAfter + 2000 + 60000;
  // This server knows its own runs; another server's run counts while its pid lives and it is not too old.
  const live = run => run.server === serverId ? running.has(run.runId) :
    run.pid !== process.pid && alive(run.pid) && !(Date.now() - run.at > longestRun);
  // A run whose server stopped (or whose result could never be written) keeps its command for the human.
  const markInterrupted = item => {
    for (const run of unfinished(item)) {
      if (live(run)) continue;
      item.events.push({ at: core.stamp(), who: 'human', what: `exec finished run=${run.runId} — ${t('run.interrupted')}` });
      logRun({ at: new Date().toISOString(), id: item.id, run: run.runId, event: 'interrupted' });
    }
  };
  if (core.load(file).items.some(item => unfinished(item).some(run => !live(run)))) {
    await core.mutate(file, model => { for (const item of model.items) markInterrupted(item); });
  }
  // A finish write that keeps failing (the lock stays busy under load) waits here and is written on the next request
  // or keepalive tick; until then its run still counts as running, so nobody starts it twice.
  const pendingFinish = new Map();
  async function flushFinishes() {
    for (const [runId, write] of pendingFinish) {
      try { await core.mutate(file, write); pendingFinish.delete(runId); running.delete(runId); }
      catch (error) { console.error(`to-do exec result still not written (run ${runId}): ${error.message}`); return; }
    }
  }
  async function writeFinish(runId, write) {
    const deadline = Date.now() + finishRetryMs;
    for (let wait = 250; ; wait = Math.min(wait * 2, 8000)) {
      try { await core.mutate(file, write); running.delete(runId); return; }
      catch (error) {
        if (Date.now() + wait > deadline) {
          console.error(`to-do exec result not written yet (run ${runId}): ${error.message}`);
          pendingFinish.set(runId, write);
          return;
        }
        await new Promise(resolve => setTimeout(resolve, wait));
      }
    }
  }
  async function runItem(id, version, shownPath) {
    if (typeof id !== 'string' || !core.load(file).items.some(item => item.id === id)) fail(404, 'item not found');
    if (!canExec) fail(409, 'Running a command from the board is not supported on Windows yet; run it yourself and reply.');
    if (typeof shownPath !== 'string') fail(400, 'invalid path');
    const runId = randomBytes(4).toString('hex');
    let command, program, snapshot;
    // Under the lock and bound to the shown version: the start event changes the version, so another tab or
    // server holding the old one gets 409 instead of running the command a second time.
    await core.update(file, id, item => {
      if (item.done || !item.exec) fail(409, 'item has no command to run');
      try { command = core.execValue(item.exec); } catch (error) { fail(400, error.message); }
      if (unfinished(item).some(live)) fail(409, 'this command is already running');
      markInterrupted(item);
      program = resolveCommand(command.argv[0], commandPath);
      if (!program) fail(409, `command not found: ${command.argv[0]}`);
      if (program !== shownPath) fail(409, 'The command now resolves to a different program. Reload and try again.');
      snapshot = { exec: JSON.stringify(item.exec), run: item.run, waiting: item.waiting, others: item.others, suggest: item.suggest };
      item.events.push({ at: core.stamp(), who: 'human', what: `exec started run=${runId} pid=${process.pid} server=${serverId} — ${core.showExec(command)}` });
      running.add(runId);
    }, version);
    const at = new Date();
    logRun({ at: at.toISOString(), id, run: runId, event: 'start', argv: command.argv, cwd: command.cwd, path: program });
    const result = await runArgv({ program, argv: command.argv, cwd: command.cwd, env: childEnv, timeout: runTimeout, killAfter });
    const ms = Date.now() - at.getTime();
    logRun({ at: at.toISOString(), id, run: runId, argv: command.argv, cwd: command.cwd, exitCode: result.exitCode, ms,
      ...(result.signal ? { signal: result.signal } : {}), ...(result.error ? { error: result.error } : {}), ...(result.timedOut ? { timedOut: true } : {}) });
    const vars = { command: core.shellQuote(command.argv), cwd: shellWord(command.cwd).text,
      code: result.exitCode ?? '-', seconds: Math.round(runTimeout / 1000), signal: result.signal || '', error: result.error };
    const head = t(result.error ? 'run.reply.spawn' : result.timedOut ? 'run.reply.timeout' : result.exitCode === null ? 'run.reply.signal' : 'run.reply', vars);
    const last = visibleText(lastLine(result.stdout) || lastLine(result.stderr), { blanks: false }).text;
    const words = head + (last ? t('run.reply.output', { text: last.length > 200 ? `${last.slice(0, 199)}…` : last }) : '');
    // The result goes to the item that started it (found by its start event, not its id, which follows the title).
    // Only fields still as they were at the start are cleared: an agent may have asked something new meanwhile.
    await writeFinish(runId, model => {
      const item = model.items.find(candidate => candidate.events.some(startOf(runId)));
      if (!item) return;
      const stamp = core.stamp();
      item.events.push({ at: stamp, who: 'human', what: `exec finished run=${runId} — ${words}` });
      // The structured outcome machines read; the reply text is for people and varies with locale and output.
      item.execResult = { argv: command.argv, cwd: command.cwd, resolved: program, exitCode: result.exitCode, timedOut: result.timedOut,
        signal: result.signal || null, at: new Date().toISOString(), run: runId };
      // A failure keeps the wait and the command, so the human can retry or answer by hand; only exit 0 resolves it.
      if (item.done || result.exitCode !== 0) return;
      if (JSON.stringify(item.exec) === snapshot.exec) item.exec = null;
      if (item.run === snapshot.run) item.run = '';
      const from = item.events.findIndex(startOf(runId));
      const askedSince = item.events.slice(from + 1).some(event => (event.who === 'agent' && /^waiting(?: on others)? — /.test(event.what)) ||
        (event.who === 'sdlc' && event.what.startsWith('NEEDS-HUMAN — ')));
      if (askedSince || item.waiting !== snapshot.waiting || item.others !== snapshot.others) return;
      if (item.suggest === snapshot.suggest) item.suggest = '';
      item.waiting = ''; item.others = '';
      item.events.push({ at: stamp, who: 'human', what: `reply — ${words}` });
    });
    return { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut, signal: result.signal, error: result.error };
  }
  let actualPort;
  const server = http.createServer(async (req, res) => {
    // Node closes an idle connection after 6 s; a page reusing it at that moment loses its request
    // ("cannot reach the to-do list"). Answer each request on its own connection; /events stays open.
    res.shouldKeepAlive = false;
    if (pendingFinish.size) await flushFinishes();
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
          const content = fs.readFileSync(path.join(here, name));
          res.writeHead(200, { 'Content-Type': type });
          res.end(content);
        } else if (url.pathname === '/proof') {
          const nonce = url.searchParams.get('n');
          if (!/^[a-f0-9]{32}$/.test(nonce || '')) fail(400, 'invalid nonce');
          json(200, { proof: proofOf(token, nonce) });
        } else if (url.pathname === '/api/live') {
          // Liveness only: /api/items syncs every sdlc item and can take seconds on a long list.
          json(200, { ok: true });
        } else if (url.pathname === '/api/feed') {
          json(200, feedState);
        } else if (url.pathname === '/api/items') {
          await synced();
          json(200, payload());
        } else if (url.pathname === '/api/artifact') {
          // A plain item's brief is only a file read. An sdlc document needs only this item's status:
          // a full sync runs sdlc.sh status per open item (~10 s for 35) and the app timed out.
          let item = itemFor(file, url.searchParams.get('id'));
          if (!item.brief || item.sdlc) { await core.sync(file, { kit, only: item.id }); item = itemFor(file, url.searchParams.get('id')); }
          json(200, item.brief && !gateIn(item) ? briefDocument(item) : await artifact(item, documentGate(item), kit, statusRunner));
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
      let launch;
      if (url.pathname === '/api/exec') {
        const result = await runItem(body.id, body.version ?? null, body.path);
        json(200, { ...payload(), exec: result });
        return;
      }
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
          case 'fix': ({ launch } = await core.requestFix(file, id, version, { kit })); break;
          default: fail(400, 'invalid operation');
        }
      } else if (url.pathname === '/api/approve') {
        // The note is optional: pressing Approve is the human's act; sdlc.sh still needs a note, so a blank one names the shown version.
        const blank = body.words === undefined || (typeof body.words === 'string' && !body.words.trim());
        const typed = blank ? '' : text(body.words, 'words', 500);
        if (!['intent', 'plan'].includes(body.gate) || typeof body.sha !== 'string' || !/^[a-f0-9]{64}$/i.test(body.sha)) fail(400, 'invalid approval');
        const words = typed || `approved as shown in the to-do web page (version ${body.sha.slice(0, 12).toLowerCase()})`;
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
      json(200, launch ? { ...payload(), launch } : payload());
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
  const stopWatch = core.watch(file, broadcast), stopWorking = core.watchWorking(file, broadcast);
  // Polling stat survives a feed that does not exist yet and one replaced by rename.
  const stopFeed = core.watch(feed, () => { feedState = readFeed(feed); broadcast(); });
  const keepalive = setInterval(() => {
    for (const res of clients) res.write(': keepalive\n\n');
    if (pendingFinish.size) void flushFinishes();
  }, 15000);
  keepalive.unref();
  let closing;
  const close = () => {
    if (!closing) {
      stopWatch(); stopWorking(); stopFeed();
      clearInterval(keepalive);
      if (session && readSession(session)?.token === token) fs.rmSync(session, { force: true });
      for (const res of clients) res.end();
      clients.clear();
      closing = new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      server.closeIdleConnections?.();
    }
    return closing;
  };
  const url = urlOf({ port: actualPort, token });
  try {
    if (session) writeSession(session, { port: actualPort, token, pid: process.pid });
    // The tray app can follow the saved list immediately while project status commands
    // run. The watcher sends the updated list once sync persists it.
    if (deferInitialSync) void synced().catch(error => console.error(`to-do sync: ${error.message}`));
    if (onUrl) await onUrl(url);
    if (open) await openBrowser(url);
    else if (!onUrl) process.stdout.write(`${url}\n`);
  } catch (error) { await close(); throw error; }
  return { url, close };
}
