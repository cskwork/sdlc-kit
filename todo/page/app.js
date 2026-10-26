// To-do page. Rows are patched by id so drafts, focus and scroll survive live updates.
const $ = id => document.getElementById(id);
const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};

// Token stays in page memory. Keep the terminal's fragment so a reload can read it again.
let openOnLoad = '';
let token = '';
{
  const hash = location.hash.slice(1);
  const params = new URLSearchParams(hash.includes('=') ? hash : '');
  token = params.get('t') || '';
  if (!hash.includes('=') && /^[0-9a-f]{6}(?:-\d+)?$/.test(hash)) openOnLoad = hash;
  if (params.get('id')) openOnLoad = params.get('id');
}

let items = [], file = '';
let seenSnapshot = false, changedAt = null;
const drafts = new Map(); // item id -> {reply, words}

// ---------- server ----------
class RequestError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}
async function api(path, body) {
  let response;
  try {
    response = await fetch(path, {
      method: body ? 'POST' : 'GET',
      headers: body ? { 'X-Todo-Token': token, 'Content-Type': 'application/json' } : { 'X-Todo-Token': token },
      body: body ? JSON.stringify(body) : undefined,
      cache: 'no-store'
    });
  } catch {
    throw new RequestError('Could not reach the to-do. Is it still running in the terminal?', 0);
  }
  const text = await response.text();
  if (!response.ok) {
    let message = text.trim();
    try { const data = JSON.parse(text); message = data.error || data.message || message; } catch { /* plain text */ }
    if (response.status === 403) message = 'This page is not allowed. Open the link printed in the terminal again.';
    if (response.status === 409 && body) {
      try { received(await api('/api/items')); } catch { /* keep the mutation's error */ }
    }
    throw new RequestError(message || `Request failed (${response.status})`, response.status);
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
    showError(error.message);
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
function showError(text) {
  $('error-text').textContent = text;
  $('error').hidden = false;
}
$('error-dismiss').addEventListener('click', () => { $('error').hidden = true; $('add-text').focus(); });

// ---------- words shown to people ----------
const basename = project => project.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || project;
const capital = text => text ? text[0].toUpperCase() + text.slice(1) : text;
function gateOf(item) {
  const action = item.sdlc?.action || '';
  return item.sdlc?.state === 'NEEDS-HUMAN' ? (action.match(/approve (intent|plan)\b/) || [])[1] || '' : '';
}
function whatWaits(item) {
  if (item.waiting) return item.waiting;
  const gate = gateOf(item);
  if (gate) return gate === 'intent' ? 'Approve what will be done' : 'Approve the plan';
  return item.sdlc?.action || 'Your answer';
}
function doneAt(item) {
  const last = [...item.events].reverse().find(e => /^(done|DONE)\b/.test(e.what));
  return last ? last.at : '';
}

// ---------- rows ----------
const rows = new Map(); // id -> li

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
  li.tabIndex = -1;
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
    refs.waitLabel = el('span', 'wait-label', 'Needs you');
    refs.waitWhat = el('span');
    refs.review = button('', 'review', 'Review');
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
  refs.open = button('', 'open', 'Details');
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
  r.check.setAttribute('aria-label', item.done ? `Mark "${item.title}" not done` : `Mark "${item.title}" done`);
  if (!item.done) r.title.setAttribute('aria-label', `${item.title}. Press Enter to rename.`);
  if (r.when) r.when.textContent = doneAt(item) ? `Done ${doneAt(item)}` : '';
  r.open.setAttribute('aria-label', `Details for "${item.title}"`);
  r.more.setAttribute('aria-label', `Actions for "${item.title}"`);
  if (r.waitLine) {
    const needsYou = item.id === items.find(i => !i.done && i.status === 'waiting')?.id;
    li.classList.toggle('needs-you', needsYou);
    r.waitLine.hidden = !needsYou;
    r.waitWhat.textContent = whatWaits(item);
    r.review.setAttribute('aria-label', `Review "${item.title}"`);
    r.up.setAttribute('aria-label', `Move "${item.title}" up`);
    r.down.setAttribute('aria-label', `Move "${item.title}" down`);
    r.del.setAttribute('aria-label', `Delete "${item.title}"`);
  }
  li.dataset.status = item.status;
  // Rebuild the small info line only when it changed, so a focused link keeps focus.
  const sig = JSON.stringify([item.status, item.project, item.link, item.sdlc?.phase, item.error, item.sdlc?.action, item.done]);
  if (sig === r.sig) return;
  r.sig = sig;
  const parts = [];
  if (!item.done) {
    if (item.status === 'waiting') parts.push(chip('Waiting', 'badge wait'));
    else if (item.status === 'blocked') {
      parts.push(chip('Blocked', 'badge blocked'));
      parts.push(chip(item.error || item.sdlc?.action || 'Unknown error', 'row-error'));
    }
    else if (item.sdlc) parts.push(chip('In progress', 'badge busy'));
  }
  if (item.project) { const c = chip(basename(item.project)); c.title = item.project; parts.push(c); }
  if (item.link && /^https?:\/\//i.test(item.link.url)) {
    const a = el('a', 'chip link', item.link.label);
    a.href = item.link.url;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    a.setAttribute('aria-label', `${item.link.label} (opens in a new tab)`);
    parts.push(a);
  }
  if (item.sdlc?.phase && !item.done) parts.push(chip(capital(item.sdlc.phase)));
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
function patchList(list, wanted) {
  const want = wanted.map(item => {
    let li = rows.get(item.id);
    if (li && li.parentElement !== list) { li.remove(); rows.delete(item.id); li = null; }
    if (!li) { li = buildRow(item); rows.set(item.id, li); }
    updateRow(li, item);
    return li;
  });
  const keep = new Set(want);
  for (const li of [...list.children]) if (!keep.has(li)) { rows.delete(li.dataset.id); li.remove(); }
  want.forEach((li, i) => { if (list.children[i] !== li) list.insertBefore(li, list.children[i] || null); });
}

function apply(data) {
  const before = new Map(items.map(i => [i.id, i]));
  items = Array.isArray(data.items) ? data.items : [];
  file = data.file || file;
  const open = items.filter(i => !i.done), done = items.filter(i => i.done);
  const waiting = open.filter(i => i.status === 'waiting');

  const focus = focusInfo(), active = document.activeElement, x = scrollX, y = scrollY;
  const selection = active?.matches('input.edit') ? [active.selectionStart, active.selectionEnd] : null;
  patchList($('open'), open);
  patchList($('done'), done);
  if (active && active !== document.body && active.isConnected && active.getClientRects().length) {
    active.focus({ preventScroll: true });
    if (selection) active.setSelectionRange(...selection);
  } else restoreFocus(focus);
  if (scrollX !== x || scrollY !== y) scrollTo(x, y);

  $('counts').textContent = `${open.length} open · ${waiting.length} ${waiting.length === 1 ? 'needs' : 'need'} you · ${done.length} done`;
  $('empty').hidden = open.length > 0;
  $('done-box').hidden = done.length === 0;
  $('done-count').textContent = String(done.length);
  $('file').textContent = file ? `Saved in ${file}` : '';
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
      changed.textContent = new Intl.DateTimeFormat(undefined, { dateStyle: 'long', timeStyle: 'short' }).format(changedAt);
    } else changed.hidden = true;
  }
  if (detailId) renderDetail();
  return before;
}

// Brief, polite summary of changes made elsewhere (terminal, editor, agent).
function describeChange(before) {
  const now = new Map(items.map(i => [i.id, i]));
  const added = items.filter(i => !before.has(i.id)).length;
  const removed = [...before.keys()].filter(id => !now.has(id)).length;
  const newlyWaiting = items.filter(i => i.status === 'waiting' && before.get(i.id)?.status !== 'waiting' && before.has(i.id));
  if (newlyWaiting.length) return `${newlyWaiting[0].title} needs you`;
  if (added && !removed) return added === 1 ? 'One item added' : `${added} items added`;
  if (removed && !added) return removed === 1 ? 'One item removed' : `${removed} items removed`;
  return JSON.stringify([...before.values()]) === JSON.stringify(items) ? '' : 'Inbox updated';
}

// ---------- row actions ----------
const op = (item, name, extra, done) => mutate('/api/item', { id: item.id, version: item.version, op: name, ...extra }, done);

function rowOf(node) { return node.closest('li.row'); }
async function move(li, delta) {
  try { await op(li._item, 'move', { delta }, delta < 0 ? 'Moved up' : 'Moved down'); } catch { /* shown */ }
}
async function remove(li) {
  const item = li._item;
  if (!confirm(`Delete "${item.title}"? This cannot be undone.`)) return;
  try { await op(item, 'delete', {}, `Deleted ${item.title}`); } catch { /* shown */ }
}

function startEdit(li) {
  if (li.classList.contains('editing') || li._item.done) return;
  const r = li._refs, item = li._item;
  const input = el('input', 'edit');
  input.type = 'text';
  input.value = li._item.title;
  input.dataset.role = 'title';
  input.setAttribute('aria-label', `Rename "${li._item.title}". Enter saves, Escape cancels.`);
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
      await op(item, 'edit', { title: value }, 'Renamed');
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
    if (event.key === 'Enter') { event.preventDefault(); finish(true); }
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
    op(item, wantDone ? 'done' : 'undone', {}, wantDone ? `Done: ${item.title}` : `Back to open: ${item.title}`).catch(() => {});
  });
  list.addEventListener('click', event => {
    const target = event.target.closest('[data-role]');
    if (!target) return;
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
    if (!li || li._item.done) return;
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
    await mutate('/api/items', { text }, 'Added');
    if (addText.value.trim() === text) addText.value = '';
  } catch { /* draft stays */ }
  finally { adding = false; }
  addText.focus();
});
document.addEventListener('keydown', event => {
  if ((event.key !== '/' && event.key !== 'n') || event.altKey || event.ctrlKey || event.metaKey) return;
  const t = event.target;
  if ($('detail').open || t.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) return;
  event.preventDefault();
  addText.focus();
});

// ---------- detail ----------
const dialog = $('detail');
let detailId = '', opener = null, artifact = null, artifactRequest = 0, detailVersion = '';

function draftFor(id) { if (!drafts.has(id)) drafts.set(id, { reply: '', words: '' }); return drafts.get(id); }
function openDetail(id, from) {
  const item = items.find(i => i.id === id);
  if (!item) return;
  detailId = id;
  detailVersion = '';
  opener = from || document.activeElement;
  artifact = null;
  const d = draftFor(id);
  $('reply-text').value = d.reply;
  $('approve-words').value = d.words;
  $('reply-error').hidden = $('approve-error').hidden = true;
  $('artifact-box').hidden = $('decide').hidden = true;
  updateCount();
  renderDetail();
  dialog.showModal();
  $('detail-title').focus();
  if (item.status === 'waiting') loadArtifact();
}
function field(dl, name, value) {
  if (!value) return;
  const dt = el('dt', '', name), dd = el('dd');
  if (value instanceof Node) dd.append(value); else dd.textContent = value;
  dl.append(dt, dd);
}
function renderDetail() {
  const item = items.find(i => i.id === detailId);
  const version = JSON.stringify(item);
  if (version === detailVersion) return;
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
  const status = { waiting: 'Needs you', blocked: 'Blocked', workable: item.sdlc ? 'In progress' : 'Open', done: 'Done' }[item.status];
  field(dl, 'Status', status);
  if (item.status === 'waiting') field(dl, 'Waiting for', whatWaits(item));
  if (item.status === 'blocked') field(dl, 'Problem', item.error || item.sdlc?.action || 'Unknown');
  field(dl, 'Project', item.project);
  if (item.link && /^https?:\/\//i.test(item.link.url)) {
    const a = el('a', '', item.link.label);
    a.href = item.link.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
    field(dl, 'Link', a);
  }
  if (item.sdlc) field(dl, 'Work', `${item.sdlc.slug}${item.sdlc.phase ? ` · ${capital(item.sdlc.phase)}` : ''}`);
  $('reply-box').hidden = item.done;
  const history = $('history');
  history.replaceChildren(...item.events.map(e => {
    const li = el('li');
    li.append(el('time', '', e.at), document.createTextNode(` · ${e.who} · ${e.what}`));
    return li;
  }));
  if (!item.events.length) history.append(el('li', 'hint', 'No history yet.'));
  $('notes-box').hidden = !item.notes.length;
  $('notes').textContent = item.notes.map(n => n.trim()).join('\n');
}
async function loadArtifact() {
  const id = detailId, version = items.find(item => item.id === id)?.version, request = ++artifactRequest;
  artifact = null;
  $('decide').hidden = true;
  $('approve-submit').disabled = true;
  $('approve-error').hidden = true;
  $('artifact-reload').hidden = true;
  try {
    const data = await api(`/api/artifact?id=${encodeURIComponent(id)}`);
    if (id !== detailId || request !== artifactRequest) return;
    $('artifact-box').hidden = !data.gate;
    if (!data.gate) return;
    const { renderMarkdown } = await import('./markdown.js');
    const rendered = renderMarkdown(data.markdown || '');
    if (id !== detailId || request !== artifactRequest) return;
    // The renderer escapes all HTML first; this is the page's only innerHTML.
    $('artifact').innerHTML = rendered;
    artifact = { ...data, version };
    $('decide').hidden = false;
    $('approve-submit').disabled = false;
    const what = artifact.gate === 'intent' ? 'what will be done' : 'the plan';
    $('artifact-file').textContent = artifact.file || '';
    $('approve-submit').textContent = artifact.gate === 'intent' ? 'Approve intent' : 'Approve plan';
    $('approve-help').textContent = `Approving records your words and lets the agent go ahead with ${what}, exactly as shown above (version ${artifact.sha.slice(0, 12)}). If the file changed since it was shown, the approval is refused.`;
  } catch (error) {
    if (id !== detailId || request !== artifactRequest) return;
    artifact = null;
    $('decide').hidden = true;
    $('approve-submit').disabled = true;
    $('artifact-box').hidden = false;
    $('artifact-reload').hidden = false;
    $('artifact').replaceChildren(el('p', 'field-error', `Could not load what needs approval: ${error.message}`));
  }
}
function updateCount() { $('approve-count').textContent = `${$('approve-words').value.trim().length} / 500`; }
$('approve-words').addEventListener('input', () => { draftFor(detailId).words = $('approve-words').value; updateCount(); });
$('reply-text').addEventListener('input', () => {
  const draft = draftFor(detailId);
  if (!draft.reply) draft.replyVersion = items.find(item => item.id === detailId)?.version;
  draft.reply = $('reply-text').value;
});
$('artifact-reload').addEventListener('click', () => loadArtifact().then(() => $('artifact-title').focus()));
$('artifact-title').tabIndex = -1;

$('approve-form').addEventListener('submit', async event => {
  event.preventDefault();
  const words = $('approve-words').value.trim();
  const error = $('approve-error');
  error.hidden = true;
  if (!artifact) return;
  if (words.length < 1 || words.length > 500) {
    error.textContent = 'Write between 1 and 500 characters in your own words.';
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
    announce('Approved');
    if (detailId === id) {
      $('decide').hidden = $('artifact-box').hidden = true;
      $('detail-title').focus();
    }
  } catch (failure) {
    if (detailId !== id) return;
    error.textContent = failure.status === 409 ? `${failure.message} Reload to see the current version.` : failure.message;
    error.hidden = false;
    $('artifact-reload').hidden = failure.status !== 409;
    if (failure.status === 409) $('approve-submit').disabled = true;
    (failure.status === 409 ? $('artifact-reload') : $('approve-words')).focus();
  }
});
$('reply-form').addEventListener('submit', async event => {
  event.preventDefault();
  const text = $('reply-text').value.trim();
  const error = $('reply-error');
  error.hidden = true;
  if (!text) { error.textContent = 'Write a reply first.'; error.hidden = false; $('reply-text').focus(); return; }
  const id = detailId, draft = draftFor(id);
  try {
    const data = await api('/api/item', { id, version: draft.replyVersion, op: 'reply', text });
    draft.reply = '';
    if (detailId === id) $('reply-text').value = '';
    if (data.items) apply(data);
    announce('Reply sent');
  } catch (failure) {
    if (detailId !== id) return;
    error.textContent = failure.message;
    error.hidden = false;
    $('reply-text').focus();
  }
});
$('detail-close').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => {
  const id = detailId;
  detailId = '';
  const row = rows.get(id);
  // Mobile row tools hide while the dialog has focus; reveal them before restoring the opener.
  if (opener?.isConnected && !opener.getClientRects().length) row?.focus({ preventScroll: true });
  const target = opener?.isConnected && opener.getClientRects().length ? opener
    : row?.isConnected && row.getClientRects().length ? row : addText;
  target.focus({ preventScroll: true });
});

// ---------- live updates ----------
function setLive(state, text) {
  $('live').dataset.state = state;
  $('live-text').textContent = text;
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
  source.addEventListener('open', () => { retry = 0; setLive('live', 'Live'); $('error').hidden = true; });
  source.addEventListener('message', event => {
    try { received(JSON.parse(event.data)); } catch { /* ignore a malformed message */ }
  });
  source.addEventListener('error', () => {
    setLive('retry', 'Reconnecting…');
    source.close();
    // Reconnect with capped backoff while the server or network is unavailable.
    const wait = Math.min(30000, 1000 * 2 ** retry++);
    retryTimer = setTimeout(async () => {
      try { received(await api('/api/items')); }
      catch (error) { if (error.status === 403) { setLive('off', 'Not allowed'); showError(error.message); return; } }
      connect();
    }, wait);
  });
}

if (!token) {
  setLive('off', 'Not connected');
  showError('Open the link printed in your terminal (or press w in the TUI)');
} else {
  api('/api/items').then(received).catch(error => showError(error.message));
  connect();
}
