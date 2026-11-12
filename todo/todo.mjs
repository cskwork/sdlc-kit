#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import * as core from './core.mjs';
import { defaultLanguage, languages, resolveLanguage } from './i18n.mjs';

const kit = fileURLToPath(new URL('../', import.meta.url));
const file = core.todoPath();
const usage = `Usage: node ${path.join(kit, 'todo', 'todo.mjs')} <command>
  add ["text"] [--project P] [--link URL] [--slug S] [--by NAME] [--brief PATH]
  next [--json] | take <id> [--json] | list [--json] | sync
  start <id> --slug S [--phase P] | phase <id> <phase>
  wait <id> "what" | resume <id> ["note"] | answer <id> "chat words" | note <id> "text"
  others <id> ["who answers"] (waiting on someone else, e.g. QA; leaves Needs you; empty clears)
  brief <id> <absolute .md path> (attach a markdown brief for the human; "" clears it)
  repos <id> [name,name] (repositories the work changes, shown on every view; empty clears)
  choices <id> ["label | label | ..."] [--pick N] (up to 6 one-click answers, N marks the recommended one; no labels clears)
  pin <id> [on|off] (keep at the top of every app tab, e.g. a setting switched with choices; not counted as needing you)
  run <id> ["command"] (a command the human runs; the app opens a terminal with it typed, not run; a reply or no text clears it)
  suggest <id> ["answer"] (the one-line reply you recommend, pre-filled in the human's reply field; a reply or no text clears it)
  working <id> ["what"] | working <id> --off (an agent works on it now: call on start, again at least every 60 s, --off when done; a mark not refreshed for 3 min expires)
  done <id> ["result"] | web [--port N] [--open] [--lang L] | serve [--lang L] | help
  No command: the app (--ui tui,web,app picks any of them; --no-web for the TUI alone, --lang L).
  Without a built app it opens the TUI with its web link; build it with: cargo build --release --manifest-path ${path.join(kit, 'todo', 'app', 'Cargo.toml')}
  serve keeps a web server for the app; launches share it through ${core.sessionPath()}.
  --lang ${languages.join('|')} sets the UI language; default SDLC_TODO_LANG, else ${defaultLanguage}.`;
const bad = message => { throw Object.assign(new Error(`${message}\n${usage}`), { code: 2 }); };
const schemas = {
  add: { project: true, link: true, slug: true, by: true, brief: true },
  next: { json: false }, take: { json: false }, list: { json: false }, sync: {},
  start: { slug: true, phase: true }, phase: {}, wait: {}, others: {}, resume: {}, answer: {}, note: {}, brief: {}, repos: {}, choices: { pick: true }, suggest: {}, run: {}, pin: {}, working: { off: false }, done: {},
  web: { port: true, open: false, lang: true }, serve: { lang: true }, help: {}, '': { 'no-web': false, lang: true, ui: true }
};
function argumentsFor(argv) {
  const command = argv[0] && !argv[0].startsWith('--') ? argv.shift() : '';
  if (!Object.hasOwn(schemas, command)) bad(`unknown command: ${command}`);
  const flags = {}, args = [];
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith('--')) { args.push(token); continue; }
    const key = token.slice(2);
    if (!Object.hasOwn(schemas[command], key) || Object.hasOwn(flags, key)) bad(`unexpected option: ${token}`);
    if (schemas[command][key]) {
      if (argv[i + 1] === undefined || argv[i + 1].startsWith('--')) bad(`missing value: ${token}`);
      flags[key] = argv[++i];
    } else flags[key] = true;
  }
  return { command, flags, args };
}
function summary(item, live = core.readWorking(file)) {
  return { id: item.id, title: item.title, project: item.project, link: item.link,
    slug: item.sdlc?.slug || null, phase: item.sdlc?.phase || null, state: item.sdlc?.state || null,
    action: item.sdlc?.action || '', waiting: item.waiting, asked: core.asked(item), others: item.others || '', brief: item.brief || '', repos: item.repos || [], choices: item.choices || [], pick: item.pick ?? null, suggest: item.suggest || '', run: item.run || '', pin: !!item.pin, replies: item.replies || core.replies(item), unread: item.unread || 0, fix: !!item.fixRequested, status: item.status, working: !item.done && live[item.id] || null };
}
const uiNames = ['tui', 'web', 'app'];
const appPath = () => process.env.SDLC_TODO_APP || path.join(kit, 'todo', 'app', 'target', 'release', process.platform === 'win32' ? 'sdlc-todo.exe' : 'sdlc-todo');
function surfaces(flags) {
  if (flags.ui !== undefined && flags['no-web']) bad('use --ui or --no-web, not both');
  if (flags['no-web']) return { uis: ['tui'], chosen: true, server: false };
  if (flags.ui === undefined) return { uis: ['app'], chosen: false, server: false };
  const uis = flags.ui.split(',').map(ui => ui.trim());
  if (uis.some(ui => !uiNames.includes(ui)) || new Set(uis).size !== uis.length) bad(`invalid --ui: ${flags.ui}`);
  return { uis, chosen: true, server: uis.includes('tui') || uis.includes('web') };
}
function startApp(app, lang) {
  return new Promise((resolve, reject) => {
    const child = spawn(app, ['--session', core.sessionPath(), '--kit', kit, '--node', process.execPath, '--lang', lang],
      { detached: true, stdio: 'ignore', shell: false });
    child.once('error', error => reject(new Error(`could not start the to-do app: ${error.code || error.message}`)));
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}
// Every surface talks to one server: reuse the running one, else start one that the TUI or this process owns.
async function launch(flags, lang) {
  let { uis, chosen, server: needServer } = surfaces(flags);
  const app = appPath();
  if (uis.includes('app') && !fs.existsSync(app)) {
    const build = `cargo build --release --manifest-path ${path.join(kit, 'todo', 'app', 'Cargo.toml')}`;
    if (chosen) bad(`the to-do app is not built: ${build}`);
    console.error(`The to-do app is not built; opening the TUI instead. Build it with: ${build}`);
    uis = ['tui']; needServer = true;
  }
  if (uis.includes('tui') && !process.stdout.isTTY) bad('a terminal is required for the TUI');
  const web = await import('./web.mjs');
  let server, url;
  if (needServer) {
    const live = await web.liveSession();
    if (live) url = live.url;
    else { server = await web.startWeb({ file, kit, port: 0, open: false, lang, session: core.sessionPath(), onUrl() {} }); url = server.url; }
  }
  try {
    if (uis.includes('app')) await startApp(app, lang);
    if (uis.includes('web')) await web.openBrowser(url);
  } catch (error) { await server?.close(); throw error; }
  if (uis.includes('tui')) {
    try { await import('./tui.mjs').then(m => m.runTui({ file, kit, web: url || false, lang })); }
    finally { await server?.close(); }
  } else if (server) {
    // The browser needs this server; keep it until interrupted, like the web command.
    process.stdout.write(`${url}\n`);
    const stop = () => server.close().finally(() => process.exit(0));
    process.once('SIGINT', stop); process.once('SIGTERM', stop);
  }
}
async function main() {
  const { command, flags, args } = argumentsFor(process.argv.slice(2));
  const arity = (min, max = min) => { if (args.length < min || args.length > max) bad(`invalid arguments for ${command || 'TUI'}`); };
  let lang;
  try { lang = resolveLanguage(flags.lang, process.env.SDLC_TODO_LANG); } catch (error) { bad(error.message); }
  if (!command) { arity(0); return launch(flags, lang); }
  switch (command) {
    case 'help': arity(0); console.log(usage); return;
    case 'web': {
      arity(0);
      if (!process.stdout.isTTY && !flags.open) bad('web requires a terminal or --open');
      let port;
      if (flags.port !== undefined) {
        if (!/^\d+$/.test(flags.port) || Number(flags.port) > 65535) bad('invalid port');
        port = Number(flags.port);
      }
      return import('./web.mjs').then(m => m.startWeb({ file, kit, port, open: !!flags.open, lang }));
    }
    case 'serve': {
      arity(0);
      const web = await import('./web.mjs');
      if (await web.liveSession()) { console.log('a to-do server is already running'); return; }
      const server = await web.startWeb({ file, kit, port: 0, open: false, lang, session: core.sessionPath(), onUrl() {} });
      const stop = () => server.close().finally(() => process.exit(0));
      process.once('SIGINT', stop); process.once('SIGTERM', stop);
      return;
    }
    case 'add': {
      arity(0, 1);
      if (flags.by?.trim() === 'human') bad('--by human is reserved for TUI/web');
      if ((!args[0] || !args[0].trim()) && !flags.slug) bad('title or --slug required');
      const item = await core.add(file, args[0] || '', flags);
      if (flags.slug) await core.sync(file, { kit });
      console.log(item.id);
      return;
    }
    case 'sync': arity(0); await core.sync(file, { kit }); return;
    case 'list': {
      arity(0);
      const model = await core.sync(file, { kit });
      const live = core.readWorking(file);
      if (flags.json) console.log(JSON.stringify(model.items.map(item => summary(item, live))));
      else for (const item of model.items) console.log(`${item.id} [${item.status}] ${item.title}`);
      return;
    }
    case 'next': case 'take': {
      arity(command === 'take' ? 1 : 0);
      const result = command === 'take' ? await core.take(file, args[0], { kit }) : await core.next(file, { kit });
      if (flags.json) console.log(JSON.stringify(result.item ? summary(result.item) : null));
      else if (result.item) console.log(`${result.item.id} [${result.item.status}] ${result.item.title}${result.item.sdlc?.action ? ` — ${result.item.sdlc.action}` : result.item.waiting ? ` — ${result.item.waiting}` : ''}`);
      process.exitCode = result.code;
      return;
    }
    case 'start':
      arity(1);
      if (!flags.slug) bad('start requires --slug');
      await core.start(file, args[0], flags.slug, flags.phase || 'intent'); return;
    case 'phase': case 'wait': case 'answer': case 'note':
      arity(2);
      if (!args[1].trim()) bad(`${command} requires text`);
      await core[command](file, ...args); return;
    case 'brief': arity(2); await core.brief(file, ...args); return;
    case 'repos': arity(1, 2); await core.repos(file, args[0], args[1] || ''); return;
    case 'choices': arity(1, 2); await core.choices(file, args[0], args[1] || '', flags.pick); return;
    case 'done': arity(1, 2); await core.done(file, ...args); return;
    case 'others': arity(1, 2); await core.others(file, args[0], args[1] || ''); return;
    case 'suggest': arity(1, 2); await core.suggest(file, args[0], args[1] || ''); return;
    case 'run': arity(1, 2); await core.run(file, args[0], args[1] || ''); return;
    case 'pin': arity(1, 2); await core.pin(file, args[0], args[1] || 'on'); return;
    case 'working':
      arity(1, flags.off ? 1 : 2);
      await core.working(file, args[0], args[1], { off: !!flags.off }); return;
    case 'resume': arity(1, 2); await core.resume(file, ...args); return;
  }
}
main().catch(error => {
  console.error(error.message);
  process.exitCode = typeof error.code === 'number' ? error.code : 1;
});
