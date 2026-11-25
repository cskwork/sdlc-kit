// To-do page. Rows are patched by id so drafts, focus and scroll survive live updates.
import { defaultLanguage, isLanguage, languages, locales, phaseLabel, translator } from './i18n.mjs';
import { countsOf, displayCommand, queueOf, shellWord, statusLabel, statusOf, ticketGroups, visibleText } from './status.mjs';
const $ = id => document.getElementById(id);
const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// ---------- language ----------
// The server's language applies until the person picks one; the choice lasts until reload.
let lang = defaultLanguage, t = translator(lang), langChosen = false;
// A message is raw text (server or file) or { key, vars } translated whenever it is shown.
const say = message => typeof message === 'string' ? message : t(message.key,
  Object.fromEntries(Object.entries(message.vars || {}).map(([name, value]) => [name, value && typeof value === 'object' ? say(value) : value])));
const sourceOf = error => error.source ?? error.message;
function show(node, message) { node._message = message; node.textContent = say(message); }
function setLanguage(next) {
  lang = next;
  t = translator(lang);
  document.documentElement.lang = lang;
  $('lang').value = lang;
  for (const node of document.querySelectorAll('[data-i18n]')) node.textContent = t(node.dataset.i18n);
  for (const node of document.querySelectorAll('[data-i18n-label]')) node.setAttribute('aria-label', t(node.dataset.i18nLabel));
  for (const node of document.querySelectorAll('[data-i18n-placeholder]')) node.placeholder = t(node.dataset.i18nPlaceholder);
  for (const node of document.querySelectorAll('[data-i18n-title]')) node.title = t(node.dataset.i18nTitle);
  const shown = ['error-text', 'approve-error', 'reply-error', 'live-text', 'artifact-title', 'approve-submit', 'approve-help'].map($);
  for (const node of [...shown, ...$('artifact').children]) if (node._message) node.textContent = say(node._message);
  detailVersion = '';
}

// Token stays in page memory. Keep the terminal's fragment so a reload can read it again.
let openOnLoad = '';
let token = '', appWindow = false;
{
  const hash = location.hash.slice(1);
  const params = new URLSearchParams(hash.includes('=') ? hash : '');
  token = params.get('t') || '';
  // The tray marks its app windows with app=1; only those take part in single-window (see singleWindow).
  appWindow = params.get('app') === '1';
  if (!hash.includes('=') && /^[0-9a-f]{6}(?:-\d+)?$/.test(hash)) openOnLoad = hash;
  if (params.get('id')) openOnLoad = params.get('id');
}

let items = [], file = '';
// The board's optional feed (see web.mjs readFeed); untrusted text, shown with textContent only.
let feed = null, feedError = '';
const listeners = []; // views that redraw after every snapshot (board.js)
let seenSnapshot = false, changedAt = null;
const drafts = new Map(); // item id -> {reply, words}
// The inbox keeps one event per line, so the server rejects line breaks; join the lines the textarea allows.
const oneLine = value => value.trim().replace(/\s*[\r\n]+\s*/g, ' / ');

// ---------- server ----------
class RequestError extends Error {
  constructor(source, status) { super(say(source)); this.source = source; this.status = status; }
}
let inFlight = 0;
async function api(path, body) {
  inFlight++;
  try { return await request(path, body); } finally { inFlight--; }
}
async function request(path, body) {
  let response;
  try {
    response = await fetch(path, {
      method: body ? 'POST' : 'GET',
      headers: body ? { 'X-Todo-Token': token, 'Content-Type': 'application/json' } : { 'X-Todo-Token': token },
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store'
    });
  } catch {
    throw new RequestError({ key: 'error.unreachable' }, 0);
  }
  const text = await response.text();
  if (!response.ok) {
    let message = text.trim();
    try { const data = JSON.parse(text); message = data.error || data.message || message; } catch { /* plain text */ }
    if (response.status === 403) message = { key: 'error.forbidden' };
    if (response.status === 409 && body) {
      try { received(await api('/api/items')); } catch { /* keep the mutation's error */ }
    }
    throw new RequestError(message || { key: 'error.failed', vars: { status: response.status } }, response.status);
  }
  return text ? JSON.parse(text) : {};
}
async function mutate(path, body, done) {
  try {
    const data = await api(path, body);
    if (data.items) apply(data);
    if (done) announce(done);
    return data;
  } catch (error) {
    showError(sourceOf(error));
    throw error;
  }
}

// ---------- messages ----------
let announceTimer;
function announce(text) {
  const box = $('announce');
  box.textContent = '';
  clearTimeout(announceTimer);
  announceTimer = setTimeout(() => { box.textContent = text; }, 50);
}
function showError(message) {
  show($('error-text'), message);
  $('error').hidden = false;
}
$('error-dismiss').addEventListener('click', () => { $('error').hidden = true; $('add-text').focus(); });

// ---------- words shown to people ----------
const basename = project => project.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || project;
// What the person is asked to do: the explicit wait, the gate, else the sdlc question.
function whatWaits(item) {
  const status = statusOf(item);
  return item.waiting || (status.gate ? t(`next.${status.kind}`) : item.exec ? t('run.ask') : item.sdlc?.action || t(`next.${status.kind}`));
}
// Colour tone of a status pill, row bar and check ring: amber you, blue agent's turn, green with a pulsing dot
// while an agent works on it now, grey not started or not picked up.
const tones = { you: 'wait', agent: 'busy', others: 'open', blocked: 'blocked', done: 'ok' };
const toneOf = status => status.kind === 'working' ? 'working' : ['new', 'handoff'].includes(status.kind) ? 'open' : tones[status.actor];
const pill = item => { const status = statusOf(item); return chip(statusLabel(t, item), `badge ${toneOf(status)}`); };
function doneAt(item) {
  const last = [...item.events].reverse().find(e => /^(done|DONE)\b/.test(e.what));
  return last ? last.at : '';
}

// ---------- rows ----------
const rows = new Map(); // id -> li
let queue = queueOf([]);

function button(label, role, text) {
  const b = el('button', 'icon', text);
  b.type = 'button';
  b.dataset.role = role;
  b.setAttribute('aria-label', label);
  return b;
}
function buildRow(item) {
  const li = el('li', 'row');
  li.dataset.id = item.id;
  li.tabIndex = 0;
  const check = el('input', 'check');
  check.type = 'checkbox';
  check.dataset.role = 'check';
  const main = el('div', 'main');
  const title = el('span', 'title');
  if (!item.done) {
    title.tabIndex = 0;
    title.dataset.role = 'title';
    title.setAttribute('role', 'button');
  }
  const info = el('div', 'info');
  main.append(title, info);
  li.append(check, main);
  const refs = { check, title, info, sig: '' };
  if (!item.done) {
    refs.waitLine = el('div', 'wait-line');
    refs.waitLabel = el('span', 'wait-label');
    refs.waitWhat = el('span');
    refs.review = button('', 'review');
    refs.review.className = 'text-button';
    refs.waitLine.append(refs.waitLabel, refs.waitWhat, refs.review);
    main.append(refs.waitLine);
  }
  const tools = el('div', 'tools');
  tools.id = `tools-${item.id}`;
  refs.more = button('', 'more', '⋯');
  refs.more.className = 'more icon';
  const dots = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  dots.setAttribute('viewBox', '0 0 20 20');
  dots.setAttribute('aria-hidden', 'true');
  for (const x of [4, 10, 16]) {
    const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', x); dot.setAttribute('cy', '10'); dot.setAttribute('r', '1.5');
    dots.append(dot);
  }
  refs.more.replaceChildren(dots);
  refs.more.setAttribute('aria-expanded', 'false');
  refs.more.setAttribute('aria-controls', tools.id);
  refs.open = button('', 'open', t('row.details'));
  refs.open.className = 'quiet';
  tools.append(refs.open);
  if (!item.done) {
    refs.up = button('', 'up', '↑');
    refs.down = button('', 'down', '↓');
    refs.del = button('', 'delete', '✕');
    tools.append(refs.up, refs.down, refs.del);
  } else {
    refs.when = el('span', 'when');
    main.append(refs.when);
  }
  li.append(refs.more, tools);
  li._refs = refs;
  return li;
}
function chip(text, className = 'chip') { return el('span', className, text); }
function updateRow(li, item) {
  const r = li._refs;
  li._item = item;
  if (!li.classList.contains('editing') && r.title.textContent !== item.title) r.title.textContent = item.title;
  r.check.checked = item.done;
  const title = item.title, status = statusOf(item);
  r.check.setAttribute('aria-label', t(item.done ? 'row.markOpen' : 'row.markDone', { title }));
  if (!item.done) r.title.setAttribute('aria-label', t('row.rename', { title }));
  if (r.when) r.when.textContent = doneAt(item) ? t('row.doneAt', { at: doneAt(item) }) : '';
  r.open.textContent = t('row.details');
  r.open.setAttribute('aria-label', t('row.detailsFor', { title }));
  r.more.setAttribute('aria-label', t('row.actionsFor', { title }));
  const stop = item.id === queue.stop?.id;
  if (r.waitLine) {
    li.classList.toggle('needs-you', stop && status.actor === 'you');
    // Your-turn rows name their action; the row where agents stop says so.
    const yours = status.actor === 'you';
    r.waitLine.hidden = !yours && !stop;
    r.waitLabel.hidden = !stop;
    r.waitLabel.dataset.actor = status.actor;
    r.waitLabel.textContent = stop ? t(`stop.${status.actor}`) : '';
    r.waitWhat.textContent = yours ? item.waiting || (status.gate ? '' : item.sdlc?.action || '') : '';
    r.waitWhat.hidden = !r.waitWhat.textContent;
    r.review.hidden = !yours;
    r.review.textContent = yours ? t(`action.${status.kind}`) : '';
    r.review.setAttribute('aria-label', yours ? t('row.actionFor', { action: t(`action.${status.kind}`), title }) : '');
    r.up.setAttribute('aria-label', t('row.up', { title }));
    r.down.setAttribute('aria-label', t('row.down', { title }));
    r.del.setAttribute('aria-label', t('row.delete', { title }));
  }
  li.dataset.status = item.status;
  li.dataset.tone = toneOf(status);
  const queued = queue.queued.has(item.id) ? queue.stop.status === 'blocked' ? 'row.queuedFix' : 'row.queued' : '';
  // Rebuild the small info line only when it changed, so a focused link keeps focus.
  const sig = JSON.stringify([lang, statusLabel(t, item), queued, item.project, item.repos, item.link, item.sdlc?.phase, item.error, item.sdlc?.action, item.others, item.done]);
  if (sig === r.sig) return;
  r.sig = sig;
  const parts = [];
  if (!item.done) {
    parts.push(pill(item));
    if (status.actor === 'blocked') parts.push(chip(item.error || item.sdlc?.action || t('row.unknownError'), 'row-error'));
    if (status.actor === 'others') parts.push(chip(item.others, 'chip others'));
    if (queued) parts.push(chip(t(queued), 'chip queued'));
  }
  if (item.project) { const c = chip(basename(item.project)); c.title = item.project; parts.push(c); }
  if (item.repos?.length) { const c = chip(item.repos.join(', '), 'chip repos'); c.title = t('field.repos'); parts.push(c); }
  if (item.link && /^https?:\/\//i.test(item.link.url)) {
    const a = el('a', 'chip link', item.link.label);
    a.href = item.link.url;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.setAttribute('aria-label', t('row.newTab', { label: item.link.label }));
    parts.push(a);
  }
  if (item.sdlc?.phase && !item.done) parts.push(chip(phaseLabel(t, item.sdlc.phase)));
  r.info.replaceChildren(...parts);
  r.info.hidden = !parts.length;
}

// Where focus was, so it can land somewhere sensible if its row goes away.
function focusInfo() {
  const active = document.activeElement;
  const li = active?.closest?.('li.row');
  if (!li) return null;
  const list = li.parentElement;
  return { list, id: li.dataset.id, index: [...list.children].indexOf(li), role: active.dataset.role || '' };
}
function restoreFocus(info) {
  if (!info) return;
  const active = document.activeElement;
  if (active && active !== document.body && active.isConnected) return;
  const same = rows.get(info.id);
  const target = same && same.parentElement === info.list ? same : info.list.children[Math.min(info.index, info.list.children.length - 1)];
  const node = target && (target.querySelector(`[data-role="${info.role}"]`) || target.querySelector('[data-role="check"]'));
  (node || $('add-text')).focus({ preventScroll: true });
}
// A ticket heading over the items that need you and share its link (see ticketGroups).
const heads = new Map(); // link url -> li
function headRow(ticket) {
  let li = heads.get(ticket.url);
  if (!li) {
    // The heading sits inside the item: a list may only hold list items.
    li = el('li', 'ticket-head');
    const heading = el('span');
    heading.setAttribute('role', 'heading');
    heading.setAttribute('aria-level', '3');
    li.append(heading);
    li._heading = heading;
    li._head = ticket.url;
    heads.set(ticket.url, li);
  }
  if (li._heading.textContent !== ticket.label) li._heading.textContent = ticket.label;
  return li;
}
function patchList(list, wanted, groups = false) {
  const entries = groups ? ticketGroups(wanted) : wanted.map(item => ({ item }));
  const want = entries.flatMap(entry => entry.ticket ? [headRow(entry.ticket), ...entry.items.map(item => rowFor(list, item, true))] : [rowFor(list, entry.item, false)]);
  const keep = new Set(want);
  for (const li of [...list.children]) if (!keep.has(li)) { if (li._head) heads.delete(li._head); else rows.delete(li.dataset.id); li.remove(); }
  want.forEach((li, i) => { if (list.children[i] !== li) list.insertBefore(li, list.children[i] || null); });
}

function rowFor(list, item, grouped) {
  let li = rows.get(item.id);
  if (li && li.parentElement !== list) { li.remove(); rows.delete(item.id); li = null; }
  if (!li) { li = buildRow(item); rows.set(item.id, li); }
  updateRow(li, item);
  li.classList.toggle('in-ticket', grouped);
  return li;
}

function apply(data) {
  if (!langChosen && isLanguage(data.lang) && data.lang !== lang) setLanguage(data.lang);
  const before = new Map(items.map(i => [i.id, i]));
  items = Array.isArray(data.items) ? data.items : [];
  file = data.file || file;
  if ('feed' in data) { feed = data.feed && typeof data.feed === 'object' ? data.feed : null; feedError = data.feedError || ''; }
  // Pinned items (settings) stay on top, as in the app.
  const open = items.filter(i => !i.done).sort((a, b) => Number(!!b.pin) - Number(!!a.pin)), done = items.filter(i => i.done);
  queue = queueOf(items);

  const focus = focusInfo(), active = document.activeElement, x = scrollX, y = scrollY;
  const selection = active?.matches('input.edit') ? [active.selectionStart, active.selectionEnd] : null;
  patchList($('open'), open, true);
  patchList($('done'), done);
  if (active && active !== document.body && active.isConnected && active.getClientRects().length) {
    active.focus({ preventScroll: true });
    if (selection) active.setSelectionRange(...selection);
  } else restoreFocus(focus);
  if (scrollX !== x || scrollY !== y) scrollTo(x, y);

  $('counts').textContent = t('page.counts', countsOf(items));
  $('empty').hidden = open.length > 0;
  $('done-box').hidden = done.length === 0;
  $('done-count').textContent = String(done.length);
  $('file').textContent = file ? t('page.saved', { file }) : '';
  const lastChange = items.flatMap(item => item.events).map(event => event.at).sort().at(-1);
  // The API has event times but no file mtime; observe subsequent edits, moves and deletions here.
  if (!seenSnapshot) changedAt = lastChange ? new Date(lastChange.replace(' ', 'T')) : null;
  else if (JSON.stringify([...before.values()]) !== JSON.stringify(items)) changedAt = new Date();
  seenSnapshot = true;
  const changed = $('changed');
  changed.hidden = !changedAt;
  if (changedAt) {
    if (!Number.isNaN(changedAt.getTime())) {
      changed.dateTime = changedAt.toISOString();
      changed.textContent = new Intl.DateTimeFormat(lang, { dateStyle: 'long', timeStyle: 'short' }).format(changedAt);
    } else changed.hidden = true;
  }
  syncPane();
  if (detailId) renderDetail();
  for (const listener of listeners) listener();
  return before;
}

// Brief, polite summary of changes made elsewhere (terminal, editor, agent).
function describeChange(before) {
  const now = new Map(items.map(i => [i.id, i]));
  const added = items.filter(i => !before.has(i.id)).length;
  const removed = [...before.keys()].filter(id => !now.has(id)).length;
  const newlyWaiting = items.filter(i => i.status === 'waiting' && before.get(i.id)?.status !== 'waiting' && before.has(i.id));
  if (newlyWaiting.length) return t('announce.needsYou', { title: newlyWaiting[0].title });
  if (added && !removed) return t('announce.addedCount', { count: added });
  if (removed && !added) return t('announce.removedCount', { count: removed });
  return JSON.stringify([...before.values()]) === JSON.stringify(items) ? '' : t('announce.updated');
}

// ---------- row actions ----------
const op = (item, name, extra, done) => mutate('/api/item', { id: item.id, version: item.version, op: name, ...extra }, done);

function rowOf(node) { return node.closest('li.row'); }
async function move(li, delta) {
  try { await op(li._item, 'move', { delta }, t(delta < 0 ? 'announce.movedUp' : 'announce.movedDown')); } catch { /* shown */ }
}
async function remove(li) {
  const item = li._item;
  if (!confirm(t('row.confirmDelete', { title: item.title }))) return;
  try { await op(item, 'delete', {}, t('announce.deleted', { title: item.title })); } catch { /* shown */ }
}

function startEdit(li) {
  if (li.classList.contains('editing') || li._item.done) return;
  const r = li._refs, item = li._item;
  const input = el('input', 'edit');
  input.type = 'text';
  input.value = li._item.title;
  input.dataset.role = 'title';
  input.setAttribute('aria-label', t('row.renameInput', { title: li._item.title }));
  li.classList.add('editing');
  r.title.hidden = true;
  r.title.after(input);
  input.focus();
  input.select();
  let finished = false;
  const finish = async save => {
    if (finished) return;
    finished = true;
    const value = input.value.trim(), oldTitle = item.title;
    const restore = () => { li.classList.remove('editing'); r.title.hidden = false; input.remove(); };
    if (!save || !value || value === oldTitle) {
      restore();
      if (li.isConnected) r.title.focus();
      return;
    }
    // Ids follow the title for items without a slug, so the row may come back under a new id.
    const index = [...li.parentElement.children].indexOf(li);
    try {
      await op(item, 'edit', { title: value }, t('announce.renamed'));
    } catch {
      finished = false;
      input.focus();
      return;
    }
    if (li.isConnected) { restore(); r.title.textContent = value; r.title.focus(); return; }
    const next = $('open').children[index];
    (next?.querySelector('[data-role="title"]') || $('add-text')).focus();
  };
  input.addEventListener('keydown', event => {
    if (event.key === 'Enter') {
      event.preventDefault();
      // Enter also confirms a Hangul (IME) syllable; committing then would cut the title short. Safari reports it as 229.
      if (event.isComposing || event.keyCode === 229) return;
      finish(true);
    }
    else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); finish(false); }
  });
  // Only Enter commits: moving a live row can blur its editor without a human decision.
}

function wireList(list) {
  list.addEventListener('change', event => {
    if (event.target.dataset.role !== 'check') return;
    const li = rowOf(event.target), item = li._item;
    const wantDone = event.target.checked;
    event.target.checked = item.done; // the server decides; the next list sets it
    op(item, wantDone ? 'done' : 'undone', {}, t(wantDone ? 'announce.done' : 'announce.reopened', { title: item.title })).catch(() => {});
  });
  list.addEventListener('click', event => {
    const target = event.target.closest('[data-role]');
    // Anywhere else on a row, including its title, shows it in the side pane; links and the rename box keep their own job.
    if (!target || target.dataset.role === 'title') {
      const li = event.target.closest('li.row');
      if (li && isWide && !event.target.closest('a, input')) openDetail(li.dataset.id, li, event.detail === 0);
      return;
    }
    const li = rowOf(target);
    const role = target.dataset.role;
    if (role === 'open' || role === 'review') openDetail(li.dataset.id, target);
    else if (role === 'more') {
      const expanded = li.classList.toggle('actions-open');
      target.setAttribute('aria-expanded', String(expanded));
    }
    else if (role === 'up') move(li, -1);
    else if (role === 'down') move(li, 1);
    else if (role === 'delete') remove(li);
  });
  list.addEventListener('dblclick', event => {
    if (event.target.dataset.role === 'title' && event.target.tagName === 'SPAN') startEdit(rowOf(event.target));
  });
  list.addEventListener('keydown', event => {
    const li = rowOf(event.target);
    if (!li) return;
    if (event.target === li && (event.key === 'Enter' || event.key === ' ')) {
      event.preventDefault();
      openDetail(li.dataset.id, li);
      return;
    }
    if (li._item.done) return;
    if (event.key === 'Escape' && li.classList.contains('actions-open') && !li.classList.contains('editing')) {
      li.classList.remove('actions-open');
      li._refs.more.setAttribute('aria-expanded', 'false');
      li._refs.more.focus();
    } else if (event.altKey && (event.key === 'ArrowUp' || event.key === 'ArrowDown') && !li.classList.contains('editing')) {
      event.preventDefault();
      move(li, event.key === 'ArrowUp' ? -1 : 1);
    } else if ((event.key === 'Enter' || event.key === ' ') && event.target.tagName === 'SPAN' && event.target.dataset.role === 'title') {
      event.preventDefault();
      startEdit(li);
    }
  });
}
wireList($('open'));
wireList($('done'));

// ---------- add ----------
const addText = $('add-text');
let adding = false;
$('add').addEventListener('submit', async event => {
  event.preventDefault();
  const text = addText.value.trim();
  if (!text || adding) return;
  adding = true;
  try {
    await mutate('/api/items', { text }, t('announce.added'));
    if (addText.value.trim() === text) addText.value = '';
  } catch { /* draft stays */ }
  finally { adding = false; }
  addText.focus();
});
document.addEventListener('keydown', event => {
  if ((event.key !== '/' && event.key !== 'n') || event.altKey || event.ctrlKey || event.metaKey) return;
  const t = event.target;
  // The list's add shortcut; the board has its own keys.
  if (document.body?.dataset?.view && document.body.dataset.view !== 'list') return;
  if (($('detail').open && !isWide) || $('run-confirm').open || t.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) return;
  event.preventDefault();
  addText.focus();
});

// ---------- detail ----------
// One <dialog>: a modal on narrow screens, a persistent side pane beside the list on wide ones.
const dialog = $('detail');
const wideQuery = matchMedia('(min-width: 1100px)');
let isWide = wideQuery.matches, quietClose = false;
// detailId is what the dialog shows ('' when closed); selectedId is the row chosen for the pane.
let detailId = '', selectedId = '', opener = null, artifact = null, artifactRequest = 0, detailVersion = '', detailPill = null;

function draftFor(id) { if (!drafts.has(id)) drafts.set(id, { reply: '', words: '', seed: '' }); return drafts.get(id); }
// The agent's suggested answer fills the reply field until the person edits it; a new suggestion replaces an unedited one.
// Shared with the board (todoPage.seedDraft): returns the text the field now shows, or null to leave the field alone.
function seedDraft(draft, item) {
  const suggest = item.done ? '' : item.suggest || '';
  if (draft.reply !== draft.seed || draft.seed === suggest) return null;
  draft.reply = draft.seed = suggest;
  return suggest;
}
function seedReply(item) {
  const d = draftFor(item.id), seeded = seedDraft(d, item);
  if (seeded === null) return;
  d.replyVersion = item.version;
  if (detailId === item.id) $('reply-text').value = seeded;
}
function openDetail(id, from, focus = true) {
  const item = items.find(i => i.id === id);
  if (!item) return;
  selectedId = id;
  delete dialog.dataset.empty;
  if (id !== detailId || !dialog.open) {
    detailId = id;
    detailVersion = '';
    artifact = null;
    const d = draftFor(id);
    $('reply-text').value = d.reply;
    $('approve-words').value = d.words;
    $('reply-error').hidden = $('approve-error').hidden = true;
    $('artifact-box').hidden = $('decide').hidden = true;
    updateCount();
    renderDetail();
    // Every open sdlc item or item with a brief shows its document; only an approval gate adds the decision form.
    if (!item.done && (item.sdlc || item.brief)) loadArtifact();
  }
  opener = from || document.activeElement;
  if (!dialog.open) { if (isWide) showPane(); else dialog.showModal(); }
  markSelected();
  if (focus) $('detail-title').focus();
}
// show() runs the dialog focusing steps; a pane opened by a live update must not take focus.
function showPane() {
  const keep = document.activeElement;
  dialog.show();
  if (keep && keep !== document.body && keep.isConnected) keep.focus({ preventScroll: true });
  else document.activeElement?.blur?.();
}
function markSelected() {
  for (const [id, li] of rows) li.setAttribute('aria-current', String(isWide && id === selectedId));
}
// Wide screens always show an item: the chosen one, else where agents stop, else the first open one.
function paneTarget() {
  if (items.some(i => i.id === selectedId)) return selectedId;
  return queue.stop?.id || items.find(i => !i.done)?.id || '';
}
function syncPane() {
  if (!isWide) return markSelected();
  const id = paneTarget();
  if (id) { if (id !== detailId || !dialog.open) openDetail(id, null, false); return; }
  selectedId = detailId = '';
  dialog.dataset.empty = 'true';
  if (!dialog.open) showPane();
  markSelected();
}
function closeQuietly() {
  if (!dialog.open) return;
  const inside = dialog.contains?.(document.activeElement);
  quietClose = true;
  dialog.close();
  quietClose = false;
  if (inside) (rows.get(selectedId) || addText).focus({ preventScroll: true });
}
// Crossing the breakpoint never leaves a modal over the panes; the selection is kept.
wideQuery.addEventListener('change', () => {
  isWide = wideQuery.matches;
  closeQuietly();
  syncPane();
});
// Fix asks an agent to clear the block; the server records the request and starts the human's configured agent, if any.
function fixButton(item) {
  const button = el('button', 'quiet', t('fix.button'));
  button.type = 'button';
  button.title = t('fix.help');
  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const data = await api('/api/item', { id: item.id, version: item.version, op: 'fix' });
      if (data.items) apply(data);
      const launch = data.launch || 'queued';
      if (launch.startsWith('failed: ')) showError(t('fix.failed', { reason: launch.slice(8) }));
      else announce(t(launch === 'started' ? 'fix.started' : 'fix.queued'));
    } catch (failure) {
      showError(sourceOf(failure));
      button.disabled = false;
    }
  });
  return button;
}
function field(dl, name, value) {
  if (!value) return;
  const dt = el('dt', '', name), dd = el('dd');
  if (value instanceof Node) dd.append(value); else dd.textContent = value;
  dl.append(dt, dd);
}
function renderDetail() {
  const item = items.find(i => i.id === detailId);
  renderRun($('detail-run'), item);
  // A heartbeat only moves working.beat: refresh the status words in place, so Details keeps focus.
  const version = item ? JSON.stringify({ ...item, working: item.working && { what: item.working.what, since: item.working.since } }) : '';
  if (version === detailVersion) { if (item && detailPill) detailPill.textContent = statusLabel(t, item); return; }
  detailVersion = version;
  $('detail-gone').hidden = !!item;
  for (const form of [$('approve-form'), $('reply-form')]) for (const c of form.elements) c.disabled = !item;
  if (!item) {
    artifact = null;
    $('artifact-box').hidden = $('decide').hidden = true;
    return;
  }
  $('approve-submit').disabled = !artifact;
  $('detail-title').textContent = item.title;
  const dl = $('detail-fields');
  dl.replaceChildren();
  const actor = statusOf(item).actor;
  detailPill = pill(item);
  field(dl, t('field.status'), detailPill);
  if (actor === 'you') field(dl, t('field.next'), whatWaits(item));
  if (actor === 'others') field(dl, t('field.others'), item.others);
  if (!item.done && item.run) field(dl, t('field.run'), el('code', '', item.run));
  if (actor === 'blocked') field(dl, t('field.problem'), item.error || item.sdlc?.action || t('field.unknown'));
  if (actor === 'blocked' && !item.error) field(dl, t('field.next'), fixButton(item));
  field(dl, t('field.project'), item.project);
  if (item.repos?.length) field(dl, t('field.repos'), item.repos.join(', '));
  if (item.link && /^https?:\/\//i.test(item.link.url)) {
    const a = el('a', '', item.link.label);
    a.href = item.link.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
    field(dl, t('field.link'), a);
  }
  if (item.sdlc) field(dl, t('field.work'), `${item.sdlc.slug}${item.sdlc.phase ? ` · ${phaseLabel(t, item.sdlc.phase)}` : ''}`);
  $('reply-box').hidden = item.done;
  seedReply(item);
  renderChoices(item);
  const history = $('history');
  history.replaceChildren(...item.events.map(e => {
    const li = el('li');
    li.append(el('time', '', e.at), document.createTextNode(` · ${e.who} · ${e.what}`));
    return li;
  }));
  if (!item.events.length) history.append(el('li', 'hint', t('history.empty')));
  $('notes-box').hidden = !item.notes.length;
  $('notes').textContent = item.notes.map(n => n.trim()).join('\n');
}
// One button per offered answer; a click sends the label as an ordinary reply. The recommended one comes first.
function renderChoices(item) {
  const box = $('reply-choices'), labels = item.done ? [] : item.choices || [];
  const order = labels.map((label, i) => ({ label, recommended: item.pick === i + 1 }))
    .sort((a, b) => b.recommended - a.recommended);
  box.replaceChildren(...order.map(({ label, recommended }) => {
    const b = el('button', recommended ? 'primary choice' : 'secondary choice', label);
    b.type = 'button';
    if (recommended) b.append(el('span', 'choice-tag', t('choices.recommended')));
    b.addEventListener('click', async () => {
      for (const other of box.children) other.disabled = true;
      try { await sendReply(item.id, item.version, label); } catch { /* shown in the reply box */ }
      for (const other of box.children) other.disabled = false;
    });
    return b;
  }));
  box.hidden = !order.length;
}
async function sendReply(id, version, text, sent) {
  const error = $('reply-error');
  error.hidden = true;
  try {
    const data = await api('/api/item', { id, version, op: 'reply', text });
    sent?.();
    if (data.items) apply(data);
    announce(t('announce.replied'));
    return data;
  } catch (failure) {
    if (detailId === id) { show(error, sourceOf(failure)); error.hidden = false; }
    throw failure;
  }
}
async function loadArtifact() {
  const id = detailId, version = items.find(item => item.id === id)?.version, request = ++artifactRequest;
  artifact = null;
  $('decide').hidden = true;
  $('approve-submit').disabled = true;
  $('approve-error').hidden = true;
  $('artifact-reload').hidden = true;
  // The document can take seconds (the server syncs with sdlc first); say so instead of showing nothing.
  $('artifact-box').hidden = false;
  show($('artifact-title'), { key: 'artifact.document' });
  $('artifact-file').textContent = '';
  const loading = el('p', 'hint');
  show(loading, { key: 'artifact.loading' });
  $('artifact').replaceChildren(loading);
  try {
    const data = await api(`/api/artifact?id=${encodeURIComponent(id)}`);
    if (id !== detailId || request !== artifactRequest) return;
    $('artifact-box').hidden = false;
    show($('artifact-title'), { key: data.gate ? 'artifact.approve' : 'artifact.document' });
    const { renderMarkdown, addCopyButtons } = await import('./markdown.js');
    const rendered = renderMarkdown(data.markdown || '');
    if (id !== detailId || request !== artifactRequest) return;
    // The renderer escapes all HTML first; this is the page's only innerHTML.
    $('artifact').innerHTML = rendered;
    addCopyButtons($('artifact'), { t: (key, vars) => t(key, vars), announce });
    $('artifact-file').textContent = data.file || '';
    if (!data.gate) return;
    artifact = { ...data, version };
    $('decide').hidden = false;
    $('approve-submit').disabled = false;
    show($('approve-submit'), { key: `decide.approve-${artifact.gate}` });
    show($('approve-help'), { key: `decide.help-${artifact.gate}`, vars: { version: artifact.sha.slice(0, 12) } });
  } catch (error) {
    if (id !== detailId || request !== artifactRequest) return;
    artifact = null;
    $('decide').hidden = true;
    $('approve-submit').disabled = true;
    $('artifact-box').hidden = false;
    $('artifact-reload').hidden = false;
    show($('artifact-title'), { key: 'artifact.document' });
    $('artifact-file').textContent = '';
    const failed = el('p', 'field-error');
    show(failed, { key: 'artifact.failed', vars: { message: sourceOf(error) } });
    $('artifact').replaceChildren(failed);
  }
}
// Text size of Details only; kept in memory because the page never uses Web Storage.
let textScale = 1;
function scaleText(step) {
  textScale = Math.min(1.6, Math.max(0.8, Math.round((textScale + step) * 10) / 10));
  dialog.style.setProperty('--detail-scale', textScale);
  $('text-smaller').disabled = textScale <= 0.8;
  $('text-larger').disabled = textScale >= 1.6;
  announce(t('announce.textSize', { percent: Math.round(textScale * 100) }));
}
$('text-smaller').addEventListener('click', () => scaleText(-0.1));
$('text-larger').addEventListener('click', () => scaleText(0.1));
function updateCount() { $('approve-count').textContent = `${oneLine($('approve-words').value).length} / 500`; }
$('approve-words').addEventListener('input', () => { draftFor(detailId).words = $('approve-words').value; updateCount(); });
$('reply-text').addEventListener('input', () => {
  const draft = draftFor(detailId);
  if (!draft.reply) draft.replyVersion = items.find(item => item.id === detailId)?.version;
  draft.reply = $('reply-text').value;
});
// Enter sends, as on the board's panel; Shift+Enter is a new line, and an Enter that confirms a Hangul (IME)
// syllable never sends (Safari reports it as keyCode 229 with isComposing already false).
$('reply-text').addEventListener('keydown', event => {
  if (event.key !== 'Enter' || event.shiftKey) return;
  event.preventDefault();
  if (event.isComposing || event.keyCode === 229) return;
  $('reply-form').requestSubmit();
});
$('artifact-reload').addEventListener('click', () => loadArtifact().then(() => $('artifact-title').focus()));
$('artifact-title').tabIndex = -1;

$('approve-form').addEventListener('submit', async event => {
  event.preventDefault();
  const words = oneLine($('approve-words').value);
  const error = $('approve-error');
  error.hidden = true;
  if (!artifact) return;
  if (words.length > 500) {
    show(error, { key: 'decide.length' });
    error.hidden = false;
    $('approve-words').focus();
    return;
  }
  const id = detailId, draft = draftFor(id);
  try {
    const data = await api('/api/approve', { id, version: artifact.version, gate: artifact.gate, sha: artifact.sha, words });
    draft.words = '';
    if (detailId === id) {
      $('approve-words').value = '';
      updateCount();
    }
    if (data.items) apply(data);
    announce(t('announce.approved'));
    if (detailId === id) {
      $('decide').hidden = $('artifact-box').hidden = true;
      $('detail-title').focus();
    }
  } catch (failure) {
    if (detailId !== id) return;
    show(error, failure.status === 409 ? { key: 'decide.conflict', vars: { message: sourceOf(failure) } } : sourceOf(failure));
    error.hidden = false;
    $('artifact-reload').hidden = failure.status !== 409;
    if (failure.status === 409) $('approve-submit').disabled = true;
    (failure.status === 409 ? $('artifact-reload') : $('approve-words')).focus();
  }
});
$('reply-form').addEventListener('submit', async event => {
  event.preventDefault();
  const text = oneLine($('reply-text').value);
  const error = $('reply-error');
  error.hidden = true;
  if (!text) { show(error, { key: 'reply.empty' }); error.hidden = false; $('reply-text').focus(); return; }
  const id = detailId, draft = draftFor(id);
  try {
    await sendReply(id, draft.replyVersion, text, () => {
      draft.reply = draft.seed = '';
      if (detailId === id) $('reply-text').value = '';
    });
  } catch {
    if (detailId === id) $('reply-text').focus();
  }
});
$('detail-close').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => {
  const id = detailId;
  detailId = '';
  if (quietClose) return;
  const row = rows.get(id);
  // Mobile row tools hide while the dialog has focus; reveal them before restoring the opener.
  if (opener?.isConnected && !opener.getClientRects().length) row?.focus({ preventScroll: true });
  const target = opener?.isConnected && opener.getClientRects().length ? opener
    : row?.isConnected && row.getClientRects().length ? row : addText;
  target.focus({ preventScroll: true });
});

// ---------- live updates ----------
function setLive(state, key) {
  $('live').dataset.state = state;
  show($('live-text'), { key });
}
let source = null, retry = 0, retryTimer, firstLoad = true;
function received(data) {
  const before = apply(data);
  if (firstLoad) {
    firstLoad = false;
    if (openOnLoad && items.some(i => i.id === openOnLoad)) openDetail(openOnLoad, addText);
    return;
  }
  const text = describeChange(before);
  if (text) announce(text);
}
function connect() {
  clearTimeout(retryTimer);
  source?.close();
  source = new EventSource(`/events?t=${encodeURIComponent(token)}`);
  source.addEventListener('open', () => { retry = 0; setLive('live', 'live.live'); $('error').hidden = true; });
  source.addEventListener('message', event => {
    try { received(JSON.parse(event.data)); } catch { /* ignore a malformed message */ }
  });
  source.addEventListener('error', () => {
    setLive('retry', 'live.retry');
    source.close();
    // Reconnect with capped backoff while the server or network is unavailable.
    const wait = Math.min(30000, 1000 * 2 ** retry++);
    retryTimer = setTimeout(async () => {
      try { received(await api('/api/items')); }
      catch (error) { if (error.status === 403) { setLive('off', 'live.denied'); showError(sourceOf(error)); return; } }
      connect();
    }, wait);
  });
}

// ---------- language switcher ----------
$('lang').append(...languages.map(code => {
  const option = el('option', '', locales[code].name);
  option.value = code;
  option.lang = code;
  return option;
}));
$('lang').value = lang;
$('lang').addEventListener('change', () => {
  if (!isLanguage($('lang').value)) return;
  langChosen = true;
  setLanguage($('lang').value);
  apply({ items, file });
  announce(t('announce.language', { name: locales[lang].name }));
});

// ---------- a command the page runs for the person ----------
// An agent can leave one command (exec: {argv, cwd, why}) the person may run from here. Nothing runs without the
// confirmation dialog; the server runs argv without a shell. Every place shows the command through status.mjs's
// displayCommand, the same escape the server writes to todo.md and the reply, so hidden characters show as escapes.
const runs = new Map(); // item id -> { command, running, result }
const runViews = new Map(); // a shown run box -> { id, keys }
const longCommand = 400; // characters shown before "Show all" must be opened
// The last 20 output lines, each with hidden characters made visible.
const outputTail = result => [result.stdout, result.stderr].map(text => (text || '').trimEnd()).filter(Boolean)
  .join('\n').split(/\r?\n/).slice(-20).map(part => visibleText(part, { blanks: false }).text).join('\n');
function commandView(command) {
  const shown = displayCommand(command.argv), where = shellWord(command.cwd), why = visibleText(command.why || '');
  return { ...shown, cwd: where.text, why: why.text, escaped: shown.escaped || where.escaped || why.escaped };
}
// Draws the box for an item into a container (the list's details or the board's panel); `keys` names its shortcut.
function renderRun(box, item, keys = '') {
  runViews.set(box, { id: item?.id || '', keys });
  const command = item && !item.done ? item.exec : null;
  // A result belongs to the command that ran; a newer command shows without it.
  if (item && command && runs.get(item.id) && !runs.get(item.id).running &&
      JSON.stringify(runs.get(item.id).command) !== JSON.stringify(command)) runs.delete(item.id);
  const state = item ? runs.get(item.id) : null;
  const shown = command || state?.command;
  const sig = JSON.stringify([lang, item?.id, command, item?.execPath, state]);
  if (box._sig === sig) return;
  box._sig = sig;
  box.hidden = !shown;
  box.setAttribute('aria-busy', String(!!state?.running));
  if (!shown) { box.replaceChildren(); return; }
  const view = commandView(shown);
  const title = el('h3', '', t('run.title'));
  title.id = `${box.id}-title`;
  const parts = [title];
  if (view.escaped) parts.push(el('p', 'run-warn', t('run.escaped')));
  const code = el('pre', 'run-command');
  code.append(el('code', '', view.text));
  const where = el('p', 'run-where');
  where.append(el('span', 'muted-label', t('run.cwd')), el('code', '', view.cwd), document.createTextNode(` · ${t('run.args', { count: view.count })}`));
  parts.push(code, where);
  if (view.why) { const why = el('p', 'run-why'); why.append(el('span', 'muted-label', t('run.why')), document.createTextNode(view.why)); parts.push(why); }
  if (command && !item.execPath) parts.push(el('p', 'field-error', item.execUnsupported ? t('run.unsupported') : t('run.notFound', { name: shellWord(command.argv[0]).text })));
  if (command) {
    const button = el('button', 'secondary', t('run.button'));
    button.type = 'button';
    button.id = `${box.id}-button`;
    button.disabled = !!state?.running;
    if (keys) { button.dataset.keys = keys; button.setAttribute('aria-keyshortcuts', keys); }
    button.addEventListener('click', () => confirmRun(item.id));
    const actions = el('div', 'actions');
    actions.append(button);
    parts.push(actions);
  }
  const status = el('div', '');
  status.setAttribute('role', 'status');
  if (state?.running) {
    const line = el('p', 'run-state');
    line.append(el('span', 'run-spinner'), el('span', '', t('run.running')));
    status.append(line);
  } else if (state?.result) {
    const r = state.result;
    const text = r.error ? t('run.startFailed', { error: r.error, code: r.exitCode }) : r.timedOut ? t('run.timeout') :
      r.exitCode === null ? t('run.signal') : t('run.exit', { code: r.exitCode });
    const tail = outputTail(r);
    status.append(el('p', `run-state ${r.exitCode === 0 ? 'ok' : 'fail'}`, text), tail ? el('pre', 'run-output', tail) : el('p', 'hint', t('run.noOutput')));
  }
  parts.push(status);
  // Redrawing removes the focused button without a focusout, which would strand its tooltip: blur first, then
  // give focus back to the new button, or to the heading once the command is gone.
  const focused = box.contains?.(document.activeElement) ? document.activeElement : null;
  focused?.blur?.();
  box.replaceChildren(...parts);
  if (focused) {
    const button = parts.find(part => part.className === 'actions')?.firstChild;
    const next = button && !button.disabled ? button : title;
    if (next === title) title.tabIndex = -1;
    next.focus?.({ preventScroll: true });
  }
}
function refreshRuns() {
  for (const [box, { id, keys }] of runViews) if (box.isConnected !== false) { box._sig = ''; renderRun(box, items.find(item => item.id === id), keys); }
}
const runDialog = $('run-confirm');
let confirming = null, openedAt = 0;
const clip = text => text.length > longCommand ? `${text.slice(0, longCommand)}…` : text;
// Run is possible only when the program was found and the whole command has been on screen.
function syncRunButton() {
  $('run-confirm-run').disabled = !confirming?.path || !$('run-confirm-long').hidden;
}
function confirmRun(id) {
  const item = items.find(i => i.id === id);
  if (!item?.exec || item.done || runs.get(id)?.running || runDialog.open) return;
  const view = commandView(item.exec), long = view.text.length > longCommand || view.cwd.length > longCommand;
  confirming = { id, version: item.version, command: item.exec, path: item.execPath || '', view };
  $('run-confirm-escaped').hidden = !view.escaped;
  $('run-confirm-escaped').textContent = t('run.escaped');
  $('run-confirm-command').textContent = long ? clip(view.text) : view.text;
  $('run-confirm-cwd').textContent = long ? clip(view.cwd) : view.cwd;
  $('run-confirm-args').textContent = t('run.args', { count: view.count });
  $('run-confirm-program').textContent = item.execPath ? shellWord(item.execPath).text : '—';
  $('run-confirm-missing').hidden = !!item.execPath;
  $('run-confirm-missing').textContent = item.execPath ? '' : item.execUnsupported ? t('run.unsupported') : t('run.notFound', { name: shellWord(item.exec.argv[0]).text });
  $('run-confirm-long').hidden = !long;
  syncRunButton();
  runDialog.returnValue = '';
  openedAt = Date.now();
  runDialog.showModal();
}
$('run-confirm-full').addEventListener('click', () => {
  if (!confirming) return;
  $('run-confirm-command').textContent = confirming.view.text;
  $('run-confirm-cwd').textContent = confirming.view.cwd;
  $('run-confirm-long').hidden = true;
  syncRunButton();
  $('run-confirm-title').focus();
});
// Enter confirms from the title or text, after a reading pause: a held key's repeats and an Enter within 400 ms of
// opening do nothing, so the Enter (or X) that opened the dialog cannot also run it. A focused button keeps its own Enter.
runDialog.addEventListener('keydown', event => {
  if (event.key !== 'Enter') return;
  if (event.repeat || event.isComposing || Date.now() - openedAt < 400) { event.preventDefault(); return; }
  if (event.target?.closest?.('button')) return;
  event.preventDefault();
  if (!$('run-confirm-run').disabled) runDialog.close('run');
});
runDialog.addEventListener('close', () => {
  const chosen = runDialog.returnValue, request = confirming;
  runDialog.returnValue = '';
  confirming = null;
  // After the browser has given focus back to the button that opened it, so the redraw can carry that focus on.
  if (chosen === 'run' && request?.path) setTimeout(() => executeRun(request), 0);
});
async function executeRun({ id, version, command, path }) {
  const before = runs.get(id);
  runs.set(id, { command, running: true, result: null });
  refreshRuns();
  try {
    const data = await api('/api/exec', { id, version, path });
    runs.set(id, { command, running: false, result: data.exec });
    if (data.items) apply(data);
    announce(t('run.done', { code: data.exec.timedOut ? '-' : data.exec.exitCode ?? '-' }));
  } catch (error) {
    runs.set(id, { ...before, command, running: false });
    if (!before) runs.delete(id);
    showError(sourceOf(error));
  }
  refreshRuns();
}

// The board (board.js, a separate module) reads state and acts through this; the list keeps its own code paths.
const busyChecks = [() => inFlight > 0 || adding || !!$('add-text').value.trim() ||
  [...drafts.values()].some(draft => (draft.reply.trim() && draft.reply !== draft.seed) || draft.words.trim())];
const busy = () => busyChecks.some(check => check());
globalThis.todoPage = {
  get items() { return items; }, get feed() { return feed; }, get feedError() { return feedError; },
  get lang() { return lang; }, get t() { return t; }, get token() { return token; },
  api, apply, announce, showError, sourceOf, oneLine, say, seedDraft, renderRun, confirmRun,
  subscribe(listener) { listeners.push(listener); if (seenSnapshot) listener(); },
  addBusyCheck(check) { busyChecks.push(check); }
};

// One board window: the tray opens a new app window (#…&app=1) on every click, so a newer one asks older ones to
// close. Only app windows talk; a tab opened with `todo web --open` never closes. A window with an unsent draft or
// a request in flight stays. A browser closes only script-opened or single-entry windows; otherwise nothing happens.
function singleWindow(Channel = globalThis.BroadcastChannel, app = appWindow) {
  if (!app || typeof Channel !== 'function') return null;
  const channel = new Channel('sdlc-todo-board'), born = Date.now();
  channel.addEventListener('message', event => {
    if (event.data?.type === 'board-open' && event.data.at >= born && !busy()) globalThis.close?.();
  });
  channel.postMessage({ type: 'board-open', at: born });
  return channel;
}
singleWindow();

if (!token) {
  setLive('off', 'live.off');
  showError({ key: 'error.noToken' });
} else {
  setLive('connecting', 'live.connecting');
  api('/api/items').then(received).catch(error => showError(sourceOf(error)));
  connect();
}
