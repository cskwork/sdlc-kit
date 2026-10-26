import { emitKeypressEvents } from 'node:readline';
import { spawn } from 'node:child_process';
import * as core from './core.mjs';
import { defaultLanguage, locales, nextLanguage, phaseLabel, translator } from './i18n.mjs';
import { countsOf, queueOf, statusOf } from './status.mjs';

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const chars = text => [...segmenter.segment(String(text))].map(part => part.segment);
// File content, including notes and authors, must never become terminal controls.
const clean = text => String(text ?? '').replace(/[\x00-\x1f\x7f-\x9f]/g, ' ');
function columns(char) {
  const n = char.codePointAt(0);
  if (/^[\p{Mark}\u200d\ufe0f]+$/u.test(char)) return 0;
  return /\p{Extended_Pictographic}|\p{Regional_Indicator}|\u20e3/u.test(char) ||
    n >= 0x1100 && (n <= 0x115f || n >= 0x2329 && n <= 0x232a ||
    n >= 0x2e80 && n <= 0xa4cf || n >= 0xac00 && n <= 0xd7a3 ||
    n >= 0xf900 && n <= 0xfaff || n >= 0xfe10 && n <= 0xfe6f ||
    n >= 0xff01 && n <= 0xff60 || n >= 0xffe0 && n <= 0xffe6 ||
    n >= 0x20000 && n <= 0x3fffd) ? 2 : 1;
}
const widthOf = text => chars(text).reduce((sum, char) => sum + columns(char), 0);
function clip(text, width) {
  text = clean(text);
  if (width <= 0) return '';
  if (widthOf(text) <= width) return text;
  let result = '', used = 0;
  for (const char of chars(text)) {
    if (used + columns(char) > width - 1) break;
    result += char; used += columns(char);
  }
  return result + '…';
}
function wrap(text, width) {
  const lines = [];
  let line = '', used = 0;
  for (const char of chars(clean(text))) {
    if (used + columns(char) > width && line) { lines.push(line); line = ''; used = 0; }
    line += char; used += columns(char);
  }
  lines.push(clip(line, width));
  return lines;
}
const visible = state => (state.items || []).filter(item => !item.done || state.showDone);
const selected = state => visible(state)[state.selected || 0];
const waiting = item => item?.status === 'waiting';
const textOf = state => translator(state.lang || defaultLanguage);
// What the human is asked to do: the explicit wait, else the sdlc action, else the generic step.
const waitText = (item, t) => item.waiting || item.sdlc?.action || t(`next.${statusOf(item).kind}`);
const doneTime = item => [...(item.events || [])].reverse().find(e => /^(done|DONE)(?:$| —)/.test(e.what))?.at || '';
const looks = { done: ['✓', '2;33'], blocked: ['✕', '31'], you: ['●', '33'], agent: ['◐', '36'], new: ['○', ''] };
function status(item, t) {
  const { actor, kind } = statusOf(item);
  return [...looks[kind === 'new' ? kind : actor], t(`status.${kind}`)];
}
const webText = (state, t) => state.webUrl || (state.webError ? t('tui.webOffBecause', { reason: state.webError }) : t('tui.webOff'));
function detailLines(item, t) {
  const [glyph, , label] = status(item, t);
  return [item.title, `${glyph} ${label} · ${item.id}`, t('tui.field.project', { value: item.project || '—' }),
    t('tui.field.link', { value: item.link?.url || '—' }), t('tui.field.sdlc', { value: item.sdlc?.slug || '—' }),
    t('tui.field.phase', { phase: item.sdlc?.phase ? phaseLabel(t, item.sdlc.phase) : '—', state: item.sdlc?.state || '—' }),
    t('tui.field.action', { value: item.error || item.sdlc?.action || '—' }),
    t('tui.field.next', { value: waiting(item) ? waitText(item, t) : '—' }),
    ...(waiting(item) ? [t('tui.decideInBrowser')] : []),
    ...(item.done ? [t('tui.field.done', { value: doneTime(item) || '—' })] : []), '', t('tui.history'),
    ...(item.events || []).map(e => `${e.at} ${e.who}: ${e.what}`), '', t('tui.notes'), ...(item.notes || [])];
}
const helpKeys = [['↑ ↓ / j k', 'select', 'g G', 'ends'], ['a', 'add', 'Enter', 'details'], ['e', 'edit', 'x / Space', 'done'],
  ['d', 'delete', 'u', 'undo'], ['J K', 'move', 'Tab', 'showDone'], ['r', 'reply', 'o', 'link'], ['w', 'web', 'R', 'sync'],
  ['L', 'language', 'q / Ctrl+C', 'quit'], ['Esc', 'back']];
function help(t) {
  const pad = (text, size) => text + ' '.repeat(Math.max(0, size - widthOf(text)));
  const cells = helpKeys.map(([key, label, ...rest]) => [`${key}  ${t(`tui.help.${label}`)}`, rest.length ? `${rest[0]}  ${t(`tui.help.${rest[1]}`)}` : '']);
  const left = Math.max(...cells.map(([cell]) => widthOf(cell))) + 2;
  return [t('tui.help.title'), '', ...cells.map(([a, b]) => b ? pad(a, left) + b : a), '',
    t('tui.help.input'), t('tui.help.submit'), '', t('tui.help.legend'), t('tui.help.stop'), t('tui.help.decide'), t('tui.help.scroll')];
}

function headerLines(state, width) {
  const t = textOf(state), items = state.items || [];
  const web = webText(state, t);
  const counts = t('tui.counts', countsOf(items));
  const combined = widthOf(counts + ' · ' + clean(web)) <= width;
  return [clip(combined ? `${counts} · ${web}` : counts, width), clip(state.file || '', width),
    ...(!combined ? wrap(web, width) : [])];
}
function detailContent(state, width) {
  const item = selected(state);
  const t = textOf(state);
  return (state.view === 'help' ? help(t) : item ? detailLines(item, t) : []).flatMap(line => wrap(line, width));
}

export function render(state, { width = 80, height = 24, color = false } = {}) {
  width = Math.max(1, Math.floor(width)); height = Math.max(1, Math.floor(height));
  const paint = (text, code) => color && code ? `\x1b[${code}m${text}\x1b[0m` : text;
  const t = textOf(state), items = state.items || [], open = items.filter(i => !i.done), { stop } = queueOf(items);
  // Only header URLs and detail text wrap; inbox rows never wrap.
  const lines = headerLines(state, width).map((line, i) => i ? paint(line, '2') : paint(line, '1;33'));
  const capacity = Math.max(0, height - lines.length - 2), item = selected(state);
  let body;
  if (state.view === 'help' || state.view === 'details' && item) {
    const all = detailContent(state, width);
    const offset = Math.max(0, Math.min(state.detailOffset || 0, Math.max(0, all.length - capacity)));
    body = all.slice(offset, offset + capacity);
  } else {
    const rows = [];
    let selectionRow = 0, doneHeading = false;
    for (const current of visible(state)) {
      if (current.done && !doneHeading) { rows.push(t('tui.doneHide', { count: items.length - open.length })); doneHeading = true; }
      const active = current === item;
      if (active) selectionRow = rows.length;
      const [glyph, code, label] = status(current, t), prefix = `${active ? '›' : ' '} ${glyph} `;
      const project = clean(current.project || '').replace(/[\\/]+$/, '').split(/[\\/]/).pop();
      const meta = clean(current.done ? doneTime(current) : [project, current.link?.label ||
        (current.link?.url ? core.linkLabel(current.link.url) : ''), current.sdlc?.phase && phaseLabel(t, current.sdlc.phase)].filter(Boolean).join(' · '));
      const showMeta = meta && width >= 72 && widthOf(meta) <= Math.floor(width / 3);
      const title = clip(current.title, width - widthOf(prefix) - (showMeta ? widthOf(meta) + 2 : 0));
      let row = paint(`${active ? '›' : ' '} `, active ? '33' : '') + paint(`${glyph} ${title}`, current.done ? '2;33;9' : code);
      if (showMeta) row += ' '.repeat(Math.max(2, width - widthOf(prefix + title) - widthOf(meta))) + paint(meta, '2');
      rows.push(row);
      if (current === stop) rows.push(paint(clip(`    ${t(`stop.${statusOf(current).actor}`)}`, width), code));
      if (waiting(current)) rows.push(paint(clip(`    ${waitText(current, t)} · ${t('tui.decideInBrowser')}`, width), '2'));
      if (current.status === 'blocked') rows.push(paint(clip(`    ${t('tui.blockedRow', { reason: current.error || current.sdlc?.action || t('row.unknownError') })}`, width), code));
      if (current.done && !showMeta) rows.push(paint(clip(`    ${t('tui.doneRow', { at: doneTime(current) })}`, width), '2'));
    }
    if (!open.length && !visible(state).length) rows.push(t('tui.empty'));
    const rowCapacity = Math.max(0, capacity - (!state.showDone ? 1 : 0));
    let offset = Math.max(0, state.scroll || 0);
    if (selectionRow < offset) offset = selectionRow;
    if (selectionRow >= offset + rowCapacity) offset = Math.max(0, selectionRow - rowCapacity + 1);
    body = rows.slice(offset, offset + rowCapacity);
    if (!state.showDone && capacity) body.push(t('tui.doneShow', { count: items.length - open.length }));
  }
  lines.push(...body);
  while (lines.length < height - 2) lines.push('');
  let prompt = state.message || '';
  if (state.confirm) prompt = t('tui.confirmDelete', { title: state.confirm.title });
  if (state.input) {
    const input = state.input, units = chars(input.text), kind = `${t(`tui.input.${input.kind}`)}> `, budget = Math.max(1, width - widthOf(kind) - 1);
    let start = 0;
    while (widthOf(units.slice(start, input.cursor).join('')) >= budget && start < input.cursor) start++;
    prompt = !input.text && input.kind === 'add' ? kind + t('tui.addHint') :
      `${kind}${units.slice(start, input.cursor).join('')}│${units.slice(input.cursor).join('')}`;
  }
  lines.push(clip(prompt, width));
  lines.push(clip(t(state.input ? 'tui.keys.input' : ['details', 'help'].includes(state.view) ? 'tui.keys.details' :
    waiting(item) ? 'tui.keys.waiting' : 'tui.keys.list'), width));
  return lines.slice(0, height);
}

export function reduce(state, key) {
  const next = { ...state, message: '' }, effects = [];
  const effect = (type, extra = {}) => effects.push({ type, ...extra });
  const item = selected(state);
  if (key === 'Ctrl+C') { effect('quit'); return { state: next, effects }; }
  if (state.input) {
    const input = { ...state.input }, units = chars(input.text); next.input = input;
    if (key === 'Esc') next.input = null;
    else if (key === 'Left') input.cursor = Math.max(0, input.cursor - 1);
    else if (key === 'Right') input.cursor = Math.min(units.length, input.cursor + 1);
    else if (key === 'Home') input.cursor = 0;
    else if (key === 'End') input.cursor = units.length;
    else if (key === 'Ctrl+U') { input.text = ''; input.cursor = 0; }
    else if (key === 'Backspace' && input.cursor) { units.splice(--input.cursor, 1); input.text = units.join(''); }
    else if (key === 'Delete') { units.splice(input.cursor, 1); input.text = units.join(''); }
    else if (key === 'Enter') {
      next.input = null;
      if (input.text.trim()) {
        if (input.kind === 'add') {
          const parsed = core.parseText(input.text);
          if (parsed.title) effect('add', { text: input.text, ...parsed, by: 'human' });
          else next.message = textOf(state)('tui.titleRequired');
        } else effect(input.kind, { id: input.id, item: input.item, text: input.text.trim() });
      }
    } else if (chars(key).length === 1 && !/[\x00-\x1f\x7f-\x9f]/.test(key)) {
      const prefix = units.slice(0, input.cursor).join('') + key;
      input.text = prefix + units.slice(input.cursor).join('');
      input.cursor = chars(prefix).length;
    }
    return { state: next, effects };
  }
  if (state.confirm) {
    if (key === 'y') {
      next.undo = { kind: 'remove', item: state.confirm, index: (state.items || []).findIndex(i => i.id === state.confirm.id) };
      effect('remove', { id: state.confirm.id, item: state.confirm }); next.confirm = null;
    } else if (['n', 'Esc'].includes(key)) next.confirm = null;
    return { state: next, effects };
  }
  if (key === 'q') effect('quit');
  else if (key === '?') { next.view = state.view === 'help' ? 'list' : 'help'; next.detailOffset = 0; }
  else if (key === 'Esc') { next.view = 'list'; next.detailOffset = 0; }
  else if (['details', 'help'].includes(state.view) && ['j', 'k', 'Down', 'Up', 'PageDown', 'PageUp', 'g', 'G'].includes(key)) {
    const width = state.width || 80, height = state.height || 24;
    const capacity = Math.max(0, height - headerLines(state, width).length - 2);
    const limit = Math.max(0, detailContent(state, width).length - capacity);
    const offset = Math.min(state.detailOffset || 0, limit);
    next.detailOffset = key === 'g' ? 0 : key === 'G' ? limit : Math.max(0, Math.min(limit,
      offset + (['j', 'Down'].includes(key) ? 1 : ['k', 'Up'].includes(key) ? -1 : key === 'PageDown' ? 8 : -8)));
  } else if (['j', 'k', 'Down', 'Up', 'g', 'G'].includes(key)) {
    next.selected = key === 'g' ? 0 : key === 'G' ? visible(state).length - 1 :
      (state.selected || 0) + (['j', 'Down'].includes(key) ? 1 : -1);
  } else if (key === 'Tab') { next.showDone = !state.showDone; next.view = 'list'; }
  else if (key === 'a') next.input = { kind: 'add', text: '', cursor: 0 };
  else if (key === 'R') effect('sync');
  else if (key === 'L') {
    next.lang = nextLanguage(state.lang || defaultLanguage);
    next.message = translator(next.lang)('tui.language', { name: locales[next.lang].name });
  }
  else if (key === 'u' && state.undo) { effect('undo', { undo: state.undo }); next.undo = null; }
  else if (item) {
    if (key === 'Enter') { next.view = 'details'; next.detailOffset = 0; }
    else if (key === 'e') next.input = { kind: 'edit', id: item.id, item, text: item.title, cursor: chars(item.title).length };
    else if (key === 'r' && waiting(item)) next.input = { kind: 'reply', id: item.id, item, text: '', cursor: 0 };
    else if (key === 'x' || key === ' ') effect('done', { id: item.id, item, done: !item.done });
    else if (key === 'd') next.confirm = item;
    else if (key === 'J' || key === 'K') effect('move', { id: item.id, item, delta: key === 'J' ? 1 : -1 });
    else if (key === 'o' && item.link?.url) effect('open', { url: item.link.url });
    else if (key === 'w') {
      let url;
      if (state.webUrl) {
        url = new URL(state.webUrl);
        const fragment = new URLSearchParams(url.hash.slice(1));
        fragment.set('id', item.id); url.hash = fragment.toString();
      }
      effect('web', { id: item.id, ...(url ? { url: url.href } : {}) });
    }
  }
  next.selected = Math.max(0, Math.min(next.selected || 0, visible(next).length - 1));
  return { state: next, effects };
}

function openUrl(url, t) {
  if (!['http:', 'https:'].includes(new URL(url).protocol)) throw new Error(t('tui.error.url'));
  const [command, args] = process.platform === 'darwin' ? ['open', [url]] :
    process.platform === 'win32' ? ['rundll32', ['url.dll,FileProtocolHandler', url]] : ['xdg-open', [url]];
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: 'ignore', shell: false });
    child.once('error', reject); child.once('spawn', () => { child.unref(); resolve(); });
  });
}
const humanEvent = (item, what) => item.events.push({ at: core.stamp(), who: 'human', what });
function requireItem(model, id, t) {
  const item = model.items.find(i => i.id === id);
  if (!item) throw new Error(t('tui.error.gone'));
  return item;
}

export async function runTui({ file, kit, web, lang = defaultLanguage }) {
  const input = process.stdin, output = process.stdout;
  if (!input.isTTY || !output.isTTY || !input.setRawMode) throw new Error('A terminal is required for the TUI');
  const readItems = () => {
    const model = core.load(file);
    return model.items.map(item => ({ ...item, version: core.itemVersion(item, model) }));
  };
  let state = { items: readItems(), file, selected: 0, view: 'list', lang };
  const t = (key, vars) => textOf(state)(key, vars);
  let server, webStart, stopWatch, messageTimer, stopped = false, failure, queue = Promise.resolve(), finish;
  const finished = new Promise(resolve => { finish = resolve; });
  const wasRaw = input.isRaw, wasFlowing = input.readableFlowing;
  let ready = false;
  const draw = () => {
    if (stopped || !ready) return;
    state.width = output.columns || 80; state.height = output.rows || 24;
    const color = !Object.hasOwn(process.env, 'NO_COLOR') && process.env.TERM !== 'dumb' && (output.getColorDepth?.() || 1) > 1;
    output.write('\x1b[H' + render(state, { width: output.columns || 80, height: output.rows || 24, color })
      .map(line => line + '\x1b[K').join('\r\n') + '\x1b[J');
  };
  const reload = () => {
    const id = selected(state)?.id;
    state = { ...state, items: readItems() };
    const index = visible(state).findIndex(i => i.id === id);
    state.selected = index >= 0 ? index : Math.max(0, Math.min(state.selected, visible(state).length - 1));
    draw();
  };
  const message = text => {
    if (stopped) return;
    state.message = text; clearTimeout(messageTimer);
    messageTimer = setTimeout(() => { state.message = ''; draw(); }, 4000); draw();
  };
  const stop = error => {
    if (stopped) return;
    failure = error; stopped = true;
    // Restore synchronously, before awaiting outstanding writes or server shutdown.
    try { input.setRawMode(!!wasRaw); }
    finally { output.write('\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l'); }
    finish();
  };
  const sigint = () => stop(), sigterm = () => stop();
  const fatal = error => stop(error instanceof Error ? error : new Error(String(error)));
  const refresh = () => { try { reload(); } catch (error) { message(error.message); } };
  const perform = async effect => {
    let result, snapshot;
    // Core's helpers lack compare-before-write and an undo preimage. Capture both
    // under its lock, so derived IDs cannot silently target a different duplicate.
    const change = fn => core.mutate(file, model => {
      const item = requireItem(model, effect.id, t);
      if (core.itemVersion(item, model) !== effect.item.version) throw new Error(t('tui.error.changed'));
      snapshot = { item: structuredClone(item), index: model.items.indexOf(item), version: core.itemVersion(item, model) };
      fn(item, model);
      return item;
    }, (model, item) => {
      snapshot.afterVersion = model.items.includes(item) ? core.itemVersion(item, model) : snapshot.version;
    });
    const remember = kind => {
      state.undo = { ...snapshot, kind, id: result.id };
    };
    switch (effect.type) {
      case 'add': result = await core.add(file, effect.text, { by: 'human' }); message(t('tui.added')); break;
      case 'edit':
        result = await change(item => { item.title = effect.text; humanEvent(item, 'edited'); });
        remember('edit'); message(t('tui.edited')); break;
      case 'reply':
        await change(item => { item.waiting = ''; humanEvent(item, `reply — ${effect.text}`); });
        message(t('tui.replied')); break;
      case 'done':
        result = await change((item, model) => {
          item.done = effect.done; item.waiting = ''; humanEvent(item, effect.done ? 'done' : 'reopened');
          model.items.splice(model.items.indexOf(item), 1);
          const firstDone = model.items.findIndex(i => i.done);
          model.items.splice(effect.done ? firstDone < 0 ? model.items.length : firstDone : 0, 0, item);
        });
        remember('done');
        message(t(effect.done ? 'tui.movedDone' : 'tui.reopened')); break;
      case 'remove':
        await change((item, model) => { model.items.splice(model.items.indexOf(item), 1); });
        state.undo = { ...snapshot, kind: 'remove' };
        state.view = 'list'; message(t('tui.deleted')); break;
      case 'move':
        await change((item, model) => {
          const group = model.items.filter(i => i.done === item.done);
          const from = group.indexOf(item), to = Math.max(0, Math.min(group.length - 1, from + effect.delta));
          if (from === to) return;
          const target = model.items.indexOf(group[to]);
          model.items.splice(model.items.indexOf(item), 1); model.items.splice(target, 0, item);
          humanEvent(item, effect.delta > 0 ? 'moved down' : 'moved up');
        }); message(t('tui.moved')); break;
      case 'undo': {
        const undo = effect.undo;
        await core.mutate(file, model => {
          let item;
          if (undo.kind === 'remove') {
            // IDs are derived and duplicates renumber after deletion. Restoring inserts,
            // never replaces another item, even if its ID now equals the deleted ID.
            item = structuredClone(undo.item); model.items.splice(Math.min(undo.index, model.items.length), 0, item);
          } else {
            item = model.items.find(item => item.id === undo.id);
            if (!item || core.itemVersion(item, model) !== undo.afterVersion) {
              throw new Error(t('tui.error.undo'));
            }
            if (undo.kind === 'edit') {
              item.title = undo.item.title;
            } else {
              item.done = undo.item.done; item.waiting = undo.item.waiting;
              model.items.splice(model.items.indexOf(item), 1); model.items.splice(Math.min(undo.index, model.items.length), 0, item);
            }
          }
          humanEvent(item, `undo ${undo.kind}`); result = item;
        });
        state.undo = null; if (result.done) state.showDone = true; message(t('tui.undone')); break;
      }
      case 'sync': await core.sync(file, { kit }); message(t('tui.synced')); break;
      case 'open': await openUrl(effect.url, t); message(t('tui.openedLink')); return;
      case 'web': {
        if (!state.webUrl) { message(webText(state, t)); return; }
        await openUrl(effect.url, t); message(t('tui.openedWeb')); return;
      }
    }
    reload();
    if (result) { const index = visible(state).findIndex(i => i.id === result.id); if (index >= 0) state.selected = index; draw(); }
  };
  const keypress = (text, key = {}) => {
    const names = { up: 'Up', down: 'Down', left: 'Left', right: 'Right', home: 'Home', end: 'End',
      backspace: 'Backspace', delete: 'Delete', return: 'Enter', enter: 'Enter', escape: 'Esc', tab: 'Tab',
      pageup: 'PageUp', pagedown: 'PageDown', space: ' ' };
    const value = key.ctrl ? `Ctrl+${(key.name || '').toUpperCase()}` : names[key.name] || text;
    if (value === 'Ctrl+C') { stop(); return; }
    queue = queue.then(async () => {
      if (stopped || !value) return;
      const previousUndo = state.undo;
      try {
        const reduced = reduce(state, value); state = reduced.state; draw();
        for (const effect of reduced.effects) { if (effect.type === 'quit') stop(); else await perform(effect); }
      } catch (error) { state.undo = previousUndo; message(error.message); }
    });
  };
  try {
    process.on('SIGINT', sigint); process.on('SIGTERM', sigterm);
    process.on('uncaughtException', fatal); process.on('unhandledRejection', fatal); output.on('resize', refresh);
    input.setRawMode(true); output.write('\x1b[?1049h\x1b[?25l\x1b[?7l');
    await core.sync(file, { kit });
    if (stopped) { if (failure) throw failure; return; }
    state.items = readItems(); ready = true;
    emitKeypressEvents(input); input.on('keypress', keypress); input.resume();
    stopWatch = core.watch(file, refresh); draw();
    if (web) webStart = import('./web.mjs').then(({ startWeb }) => startWeb({ file, kit, port: 0, open: false, lang,
      onUrl: url => { state.webUrl = url; draw(); } }))
      .then(value => { server = value; state.webUrl = value.url; draw(); })
      .catch(error => { state.webUrl = ''; state.webError = error.message; draw(); });
    await finished;
  } finally {
    stop(); stopWatch?.(); clearTimeout(messageTimer);
    input.off('keypress', keypress); output.off('resize', refresh);
    process.off('SIGINT', sigint); process.off('SIGTERM', sigterm);
    process.off('uncaughtException', fatal); process.off('unhandledRejection', fatal);
    if (wasFlowing !== true) input.pause();
    await queue; await webStart; await server?.close();
  }
  if (failure) throw failure;
}
