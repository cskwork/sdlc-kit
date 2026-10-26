import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execute = promisify(execFile);
const defaultKit = fileURLToPath(new URL('../', import.meta.url));
const header = '# To-do\n\n<!-- sdlc-kit to-do. Agents work Open items top-down and stop at one waiting for you. One item per "- [ ]" line; its indented lines are fields and history. -->\n\n';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const fail = (message, code = 2) => { throw Object.assign(new Error(message), { code }); };
const line = value => {
  const text = String(value ?? '').trim();
  if (/[\r\n]/.test(text)) fail('fields must fit on one line');
  return text;
};
const relativeProjectError = 'relative project path: write an absolute or ~/ path';
const isRelativeProject = project => !!project && project !== '~' && !/^(?:~\/|\/|[A-Za-z]:[\\/]|\\\\)/.test(project);
function normalizeProject(value) {
  const project = line(value);
  return isRelativeProject(project) ? path.resolve(project) : project;
}
export function projectPath(project) {
  if (isRelativeProject(project)) throw Object.assign(new Error(relativeProjectError), { status: 409 });
  return project === '~' ? os.homedir() : project.startsWith('~/') ? path.join(os.homedir(), project.slice(2)) : project;
}
// Bash stdout is not covered by MSYS's native-process argument conversion.
export async function nativePath(value, { platform = process.platform, runner = execute } = {}) {
  if (platform !== 'win32' || !value.startsWith('/') || value.startsWith('//')) return value;
  const { stdout } = await runner('bash', ['-c', 'cygpath -w -- "$1"', 'sdlc-path', value]);
  return stdout.replace(/\r?\n$/, '');
}
export const todoPath = () => process.env.SDLC_TODO || path.join(os.homedir(), '.sdlc', 'todo.md');
export function stamp(date = new Date()) {
  const pad = n => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
export function itemId(item) {
  return createHash('sha1').update(`${item.project || ''}\0${item.sdlc?.slug || item.title}`).digest('hex').slice(0, 6);
}
const isAnswer = event => (event.who === 'human' && event.what.startsWith('reply — ')) ||
  (event.who === 'agent' && event.what.startsWith('chat answer — '));
const isWait = event => (event.who === 'agent' && event.what.startsWith('waiting — ')) ||
  (event.who === 'sdlc' && event.what.startsWith('NEEDS-HUMAN — '));
const isRead = event => event.who === 'agent' && event.what === 'read replies';
const lastIndex = (item, match) => item.events.reduce((last, event, i) => match(event) ? i : last, -1);
export function replies(item) {
  const lastWait = lastIndex(item, isWait);
  return item.events.filter((event, i) => i > lastWait && isAnswer(event));
}
// Human replies no agent has been handed yet; next and take mark them read.
export function unread(item) {
  const from = Math.max(lastIndex(item, isWait), lastIndex(item, isRead));
  return item.events.filter((event, i) => i > from && event.who === 'human' && isAnswer(event));
}
function derive(item) {
  // A file edit has no trustworthy cwd, even before a slug is attached.
  if (isRelativeProject(item.project)) item.error = relativeProjectError;
  else delete item.error;
  item.status = item.done ? 'done' : item.error || item.sdlc?.state === 'BLOCKED' ? 'blocked' :
    ((item.waiting || item.sdlc?.state === 'NEEDS-HUMAN') && !replies(item).length) ? 'waiting' : 'workable';
  item.unread = unread(item).length;
  return item;
}
function identify(model) {
  const used = new Set();
  for (const item of model.items) {
    const base = itemId(item);
    let id = base, n = 2;
    while (used.has(id)) id = `${base}-${n++}`;
    used.add(id);
    item.id = id;
    derive(item);
  }
  return model;
}
export function linkLabel(url) {
  const parsed = new URL(url);
  const jira = parsed.pathname.match(/\/browse\/([^/]+)\/?$/);
  const github = parsed.hostname === 'github.com' && parsed.pathname.match(/^\/[^/]+\/([^/]+)\/(?:issues|pull)\/(\d+)\/?$/);
  return jira ? jira[1] : github ? `${github[1]}#${github[2]}` : parsed.host;
}
function linkValue(value) {
  if (!value) return null;
  const url = line(typeof value === 'string' ? value : value.url);
  try {
    if (!/^https?:$/.test(new URL(url).protocol)) return null;
    return { label: line(value.label || linkLabel(url)), url };
  } catch { return null; }
}
export function parseText(text) {
  const words = line(text).split(/\s+/).filter(Boolean);
  let project = '', link = null;
  const title = [];
  for (const word of words) {
    if (!link && /^https?:\/\//i.test(word)) link = linkValue(word);
    else if (!project && /^(?:~\/|\/|\.\/|[A-Za-z]:\\)/.test(word)) project = word;
    else title.push(word);
  }
  return { title: title.join(' '), project, link };
}
function parse(source) {
  const rawLines = source.split('\n');
  const lines = rawLines.map(text => text.replace(/\r$/, ''));
  const open = lines.indexOf('## Open');
  const first = lines.findIndex(s => /^- \[[ xX]\] |^## Done$/.test(s));
  const boundary = open >= 0 ? open : first >= 0 ? first : lines.length;
  const preamble = rawLines.slice(0, boundary).join('\n') + (boundary < lines.length ? '\n' : '');
  const model = { preamble, items: [] };
  let section = 'open', item;
  for (const text of lines.slice(boundary)) {
    if (text === '## Open' || text === '## Done') { section = text === '## Done' ? 'done' : 'open'; item = null; continue; }
    const match = text.match(/^- \[([ xX])\] (.*)$/);
    if (match) {
      const checked = match[1].toLowerCase() === 'x';
      item = { id: '', title: match[2].replace(/^~~(.*)~~$/, '$1'), done: section === 'done' || checked,
        project: '', link: null, sdlc: null, waiting: '', events: [], notes: [] };
      if (checked && section === 'open') item.checkedOpen = true;
      model.items.push(item);
      continue;
    }
    if (!item || !/^\s+/.test(text)) continue;
    let field;
    if ((field = text.match(/^  - project: (.*)$/))) item.project = field[1];
    else if ((field = text.match(/^  - link: \[(.*)\]\((.*)\)$/))) item.link = linkValue({ label: field[1], url: field[2] });
    else if ((field = text.match(/^  - sdlc: (.*)$/))) {
      const [slug, phase = '', ...rest] = field[1].split(' · ');
      const stateAction = rest.join(' · ');
      const sep = stateAction.indexOf(' — ');
      item.sdlc = { slug, phase, state: sep < 0 ? stateAction : stateAction.slice(0, sep), action: sep < 0 ? '' : stateAction.slice(sep + 3) };
    } else if ((field = text.match(/^  - waiting: (.*)$/))) item.waiting = field[1];
    else if ((field = text.match(/^  - (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) ([^:]+): (.*)$/))) item.events.push({ at: field[1], who: field[2], what: field[3] });
    else item.notes.push(text);
  }
  return identify(model);
}
export function load(file = todoPath()) {
  try { return parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; return { preamble: header, items: [] }; }
}
function renderItem(item) {
  const lines = [`- [${item.done ? 'x' : ' '}] ${item.done ? `~~${item.title}~~` : item.title}`];
  if (item.project) lines.push(`  - project: ${item.project}`);
  const link = linkValue(item.link);
  if (link) lines.push(`  - link: [${link.label}](${link.url})`);
  if (item.sdlc) {
    const s = item.sdlc;
    lines.push(`  - sdlc: ${s.slug}${s.phase ? ` · ${s.phase}` : ''}${s.state ? ` · ${s.state}${s.action ? ` — ${s.action}` : ''}` : ''}`);
  }
  if (item.waiting) lines.push(`  - waiting: ${item.waiting}`);
  for (const e of item.events) lines.push(`  - ${e.at} ${e.who}: ${e.what}`);
  lines.push(...item.notes);
  return lines.join('\n');
}
export function itemVersion(item, model) {
  const block = renderItem(item);
  const identical = model.items.filter(candidate => renderItem(candidate) === block);
  return createHash('sha256').update(JSON.stringify([block, identical.indexOf(item), identical.length])).digest('hex');
}
export function serialize(model) {
  const group = done => model.items.filter(item => item.done === done).map(renderItem).join('\n\n');
  return `${model.preamble ?? header}## Open\n\n${group(false)}${group(false) ? '\n\n' : ''}## Done\n\n${group(true)}${group(true) ? '\n' : ''}`;
}
function event(item, who, what) { item.events.push({ at: stamp(), who, what }); derive(item); }
function finish(model, item, who, what) {
  item.done = true;
  item.waiting = '';
  event(item, who, what);
  model.items.splice(model.items.indexOf(item), 1);
  const firstDone = model.items.findIndex(i => i.done);
  model.items.splice(firstDone < 0 ? model.items.length : firstDone, 0, item);
}
function normalize(model) {
  for (const item of [...model.items]) {
    if (item.checkedOpen) { delete item.checkedOpen; finish(model, item, 'human', 'done'); }
    if (replies(item).length) item.waiting = '';
  }
  identify(model);
}
const lockLost = Symbol('lock ownership lost');
async function atomicWrite(file, text, owns = () => true) {
  const temp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${randomUUID()}.tmp`);
  try {
    fs.writeFileSync(temp, text, 'utf8');
    for (let attempt = 0; ; attempt++) {
      try { if (!owns()) throw lockLost; fs.renameSync(temp, file); break; }
      catch (error) { if (!['EPERM', 'EBUSY'].includes(error.code) || attempt >= 5) throw error; await pause(20 * (attempt + 1)); }
    }
  } finally { try { fs.unlinkSync(temp); } catch (e) { if (e.code !== 'ENOENT') throw e; } }
}
// Move the observed lock aside atomically; a delayed reclaimer may find a
// successor there. Restore that successor without clobbering a newer owner.
function removeLock(lock, observed, staleOnly, moved) {
  try { fs.renameSync(lock, moved); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  try {
    if (fs.readFileSync(moved, 'utf8') !== observed ||
        (staleOnly && Date.now() - fs.statSync(moved).mtimeMs <= 10000)) {
      try { fs.linkSync(moved, lock); }
      catch (error) { if (error.code !== 'EEXIST') throw error; }
    }
  } finally { fs.unlinkSync(moved); }
}
// Unique per-process markers coordinate the short reclaim/commit sections.
// They are never reused: dead-process cleanup cannot remove a successor's marker.
const unlink = file => { try { fs.unlinkSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; } };
function markers(lock, kind) {
  const prefix = `${path.basename(lock)}.${kind}-`, active = [];
  for (const name of fs.readdirSync(path.dirname(lock))) {
    if (!name.startsWith(prefix) || !/^\d+-[a-f0-9-]+$/.test(name.slice(prefix.length))) continue;
    const marker = path.join(path.dirname(lock), name), pid = Number(name.slice(prefix.length).split('-')[0]);
    try { process.kill(pid, 0); active.push(marker); }
    catch (error) {
      if (error.code !== 'ESRCH') { if (error.code === 'EPERM') { active.push(marker); continue; } throw error; }
      const moved = `${marker}.moved`;
      try { fs.linkSync(moved, lock); } catch (e) { if (!['ENOENT', 'EEXIST'].includes(e.code)) throw e; }
      unlink(moved); unlink(marker);
    }
  }
  return active;
}
function mark(lock, kind) {
  const marker = `${lock}.${kind}-${process.pid}-${randomUUID()}`;
  fs.writeFileSync(marker, '', { flag: 'wx' });
  return marker;
}
async function waitMarkers(lock, kind) {
  const deadline = Date.now() + 2000;
  while (markers(lock, kind).length) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for lock: ${lock}`);
    await pause(5);
  }
}
function ownsLock(lock, owner) {
  try { return fs.readFileSync(lock, 'utf8') === owner; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
async function committing(lock, owner, fn, required = true) {
  for (;;) {
    await waitMarkers(lock, 'reclaim');
    const marker = mark(lock, 'commit');
    try {
      // A reclaimer that arrived first wins; withdraw before waiting for it.
      if (markers(lock, 'reclaim').length) continue;
      if (!ownsLock(lock, owner)) { if (required) throw lockLost; return; }
      return await fn();
    } finally { unlink(marker); }
  }
}
async function reclaim(lock, observed) {
  const marker = mark(lock, 'reclaim');
  try {
    await waitMarkers(lock, 'commit');
    removeLock(lock, observed, true, `${marker}.moved`);
  } finally { unlink(marker); }
}
export async function mutate(file, fn, onSaved) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const lock = `${file}.lock`, deadline = Date.now() + 2000;
  for (;;) {
    let fd;
    while (fd === undefined) {
      await waitMarkers(lock, 'reclaim');
      try { fd = fs.openSync(lock, 'wx'); }
      catch (error) {
        if (error.code !== 'EEXIST') throw error;
        try {
          const observed = fs.readFileSync(lock, 'utf8');
          if (Date.now() - fs.statSync(lock).mtimeMs > 10000) {
            await reclaim(lock, observed); continue;
          }
        } catch (e) { if (e.code === 'ENOENT') continue; throw e; }
        if (Date.now() >= deadline) throw new Error(`timed out waiting for lock: ${lock}`);
        await pause(20);
      }
    }
    const owner = randomUUID();
    const owns = () => ownsLock(lock, owner);
    let heartbeatError;
    const heartbeat = setInterval(() => {
      try { const now = new Date(); fs.futimesSync(fd, now, now); }
      catch (error) { heartbeatError = error; }
    }, 1000);
    heartbeat.unref();
    try {
      fs.writeFileSync(fd, owner);
      await waitMarkers(lock, 'reclaim');
      if (!owns()) throw lockLost;
      const model = load(file);
      normalize(model);
      const result = await fn(model);
      if (heartbeatError) throw heartbeatError;
      return await committing(lock, owner, async () => {
        normalize(model);
        const completed = model.items.filter(item => item.done);
        if (completed.length > 30) {
          const overflow = completed.slice(30);
          const archive = path.join(path.dirname(file), 'todo-archive.md');
          let previous;
          try { previous = fs.readFileSync(archive, 'utf8'); } catch (e) { if (e.code !== 'ENOENT') throw e; previous = '# To-do archive\n\n'; }
          await atomicWrite(archive, previous + overflow.map(renderItem).join('\n\n') + '\n\n', owns);
          model.items = model.items.filter(item => !overflow.includes(item));
        }
        await atomicWrite(file, serialize(model), owns);
        // Observe the persisted postimage before releasing the original mutation lock.
        onSaved?.(model, result);
        return result;
      });
    } catch (error) { if (error !== lockLost) throw error; }
    finally {
      try { await committing(lock, owner, () => fs.unlinkSync(lock), false); }
      finally { clearInterval(heartbeat); fs.closeSync(fd); }
    }
    // A reclaimer displaced this owner: re-read and apply the operation again.
  }
}
export function findItem(model, idOrSlug) {
  const id = model.items.find(item => item.id === idOrSlug);
  if (id) return id;
  const matches = model.items.filter(item => item.sdlc?.slug === idOrSlug);
  if (matches.length > 1) fail(`ambiguous slug: ${idOrSlug}`, 1);
  if (!matches.length) fail(`item not found: ${idOrSlug}`, 1);
  return matches[0];
}
export async function add(file, text, options = {}) {
  const parsed = parseText(text);
  const project = normalizeProject(options.project ?? parsed.project), slug = line(options.slug || '');
  return mutate(file, model => {
    if (slug) {
      const existing = model.items.find(i => i.project === project && i.sdlc?.slug === slug);
      if (existing) return existing;
    }
    const title = line(parsed.title || slug);
    if (!title) fail('title or --slug required');
    const by = line(options.by || 'agent');
    if (!/^[^:\r\n]+$/.test(by)) fail('invalid event author');
    const item = { id: '', title, done: false, project, link: linkValue(options.link ?? parsed.link),
      sdlc: slug ? { slug, phase: 'intent', state: '', action: '' } : null, waiting: '', events: [], notes: [] };
    model.items.splice(model.items.findIndex(i => i.done) < 0 ? model.items.length : model.items.findIndex(i => i.done), 0, item);
    event(item, by, 'added');
    identify(model);
    return item;
  });
}
export const update = (file, id, fn, version) => mutate(file, async model => {
  const item = version === undefined ? findItem(model, id) : model.items.find(item => item.id === id);
  if (version !== undefined && (!item || itemVersion(item, model) !== version)) {
    throw Object.assign(new Error('This item changed. Reload and try again.'), { status: 409 });
  }
  await fn(item, model);
  identify(model);
  return item;
});
export const edit = (file, id, changes, version) => update(file, id, item => {
  for (const key of ['title', 'project']) if (key in changes) item[key] = line(changes[key]);
  if (!item.title) fail('title required');
  if ('link' in changes) item.link = linkValue(changes.link);
  event(item, 'human', 'edited');
}, version);
export const move = (file, id, delta, version) => update(file, id, (item, model) => {
  const group = model.items.filter(i => i.done === item.done), from = group.indexOf(item);
  const to = Math.max(0, Math.min(group.length - 1, from + delta));
  const target = model.items.indexOf(group[to]);
  model.items.splice(model.items.indexOf(item), 1);
  model.items.splice(target, 0, item);
}, version);
export const remove = (file, id, version) => update(file, id, (item, model) => { model.items.splice(model.items.indexOf(item), 1); }, version);
export const done = (file, id, words = '', by = 'agent', version) => update(file, id, (item, model) => finish(model, item, by, `done${words ? ` — ${line(words)}` : ''}`), version);
export const reply = (file, id, words, version) => update(file, id, item => { item.waiting = ''; event(item, 'human', `reply — ${line(words)}`); }, version);
export const wait = (file, id, words) => update(file, id, item => { item.waiting = line(words); if (!item.waiting) fail('wait text required'); event(item, 'agent', `waiting — ${item.waiting}`); });
// An agent drops its own wait once it no longer waits; a missing wait is a no-op.
export const resume = (file, id, words = '') => update(file, id, item => {
  if (!item.waiting) return;
  item.waiting = '';
  event(item, 'agent', `resumed${line(words) ? ` — ${line(words)}` : ''}`);
});
export const answer = (file, id, words) => update(file, id, item => { item.waiting = ''; event(item, 'agent', `chat answer — ${line(words)}`); });
export const note = (file, id, words) => update(file, id, item => event(item, 'agent', line(words)));
export const start = (file, id, slug, phase = 'intent') => update(file, id, item => { item.sdlc = { slug: line(slug), phase: line(phase), state: '', action: '' }; event(item, 'agent', `started ${item.sdlc.slug}`); });
export const phase = (file, id, value) => update(file, id, item => { if (!item.sdlc) fail('item has no slug'); item.sdlc.phase = line(value); event(item, 'agent', `phase ${item.sdlc.phase}`); });
export const approved = (file, id, gate, words) => update(file, id, item => event(item, 'human', `approved ${line(gate)} — "${line(words)}"`));
async function readStatuses(file, kit) {
  const statuses = [];
  for (const item of load(file).items) {
    if (item.done || !item.project || !item.sdlc) continue;
    const previous = item.sdlc;
    let current;
    try {
      const { stdout } = await execute('bash', [path.join(kit, 'sdlc.sh'), 'status', previous.slug, '--json'], { cwd: await nativePath(projectPath(item.project)) });
      current = JSON.parse(stdout).features.find(f => f.slug === previous.slug);
      if (!current || !current.state) throw new Error(`feature not found: ${previous.slug}`);
    } catch (error) {
      current = { ...previous, state: 'BLOCKED', action: line((error.stderr || error.message).replace(/[\r\n]+/g, ' ')) };
    }
    statuses.push({ id: item.id, project: item.project, previous, current });
  }
  return statuses;
}
const syncChanged = Symbol('inbox changed during status');
function syncModel(model, statuses) {
  // Status calls run unlocked; retry if any current slug lacks the same preimage.
  if (model.items.some(item => !item.done && item.project && item.sdlc &&
      !statuses.some(status => status.id === item.id && status.project === item.project &&
        JSON.stringify(status.previous) === JSON.stringify(item.sdlc)))) throw syncChanged;
  for (const { id, project, previous, current } of statuses) {
    const item = model.items.find(item => item.id === id && item.project === project && !item.done);
    // A concurrent edit/start/sync wins over a status read of an older item.
    if (!item || JSON.stringify(item.sdlc) !== JSON.stringify(previous)) continue;
    item.sdlc = { slug: previous.slug, phase: current.phase, state: current.state, action: current.action || '' };
    if (current.state === 'DONE') { finish(model, item, 'sdlc', `DONE — ${item.sdlc.action}`); continue; }
    if ((['NEEDS-HUMAN', 'BLOCKED'].includes(current.state) && previous.state !== current.state) || previous.action !== item.sdlc.action) {
      event(item, 'sdlc', `${current.state} — ${item.sdlc.action}`);
    }
    if (replies(item).length) item.waiting = '';
    derive(item);
  }
  return identify(model);
}
async function synced(file, kit, fn) {
  for (;;) {
    const statuses = await readStatuses(file, kit);
    try { return await mutate(file, model => { syncModel(model, statuses); return fn(model); }); }
    catch (error) { if (error !== syncChanged) throw error; }
  }
}
export const sync = (file, { kit = defaultKit } = {}) => synced(file, kit, model => model);
function handOut(item) {
  const result = { code: { workable: 0, waiting: 10, blocked: 20 }[item.status], item: { ...item, events: [...item.events], replies: replies(item) } };
  if (item.error) result.item.sdlc = { ...item.sdlc, state: 'BLOCKED', action: item.error };
  // A reply lets the agent read a gate answer once; only sdlc.sh can open the gate.
  if (result.code === 0 && item.sdlc?.state === 'NEEDS-HUMAN' && result.item.replies.length) event(item, 'sdlc', `NEEDS-HUMAN — ${item.sdlc.action}`);
  else if (result.code === 0 && item.unread) event(item, 'agent', 'read replies');
  return result;
}
export const next = (file, { kit = defaultKit } = {}) => synced(file, kit, model => {
  const item = model.items.find(i => !i.done);
  return item ? handOut(item) : { code: 30, item: null };
});
// A worker that owns one item (not the top-down queue) reads its replies the same way.
export const take = (file, id, { kit = defaultKit } = {}) => synced(file, kit, model => {
  const item = findItem(model, id);
  if (item.done) fail(`item is done: ${id}`, 1);
  return handOut(item);
});
export function watch(file, onChange) {
  const listener = (current, previous) => { if (current.mtimeMs !== previous.mtimeMs || current.ctimeMs !== previous.ctimeMs || current.ino !== previous.ino || current.size !== previous.size) onChange(); };
  fs.watchFile(file, { interval: 250 }, listener);
  return () => fs.unwatchFile(file, listener);
}
