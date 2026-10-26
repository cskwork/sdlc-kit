#!/usr/bin/env node
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as core from './core.mjs';
import { defaultLanguage, languages, resolveLanguage } from './i18n.mjs';

const kit = fileURLToPath(new URL('../', import.meta.url));
const file = core.todoPath();
const usage = `Usage: node ${path.join(kit, 'todo', 'todo.mjs')} <command>
  add ["text"] [--project P] [--link URL] [--slug S] [--by NAME]
  next [--json] | list [--json] | sync
  start <id> --slug S [--phase P] | phase <id> <phase>
  wait <id> "what" | answer <id> "chat words" | note <id> "text"
  done <id> ["result"] | web [--port N] [--open] [--lang L] | help
  No command: TUI and web (--no-web for TUI only, --lang L).
  --lang ${languages.join('|')} sets the UI language; default SDLC_TODO_LANG, else ${defaultLanguage}.`;
const bad = message => { throw Object.assign(new Error(`${message}\n${usage}`), { code: 2 }); };
const schemas = {
  add: { project: true, link: true, slug: true, by: true },
  next: { json: false }, list: { json: false }, sync: {},
  start: { slug: true, phase: true }, phase: {}, wait: {}, answer: {}, note: {}, done: {},
  web: { port: true, open: false, lang: true }, help: {}, '': { 'no-web': false, lang: true }
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
function summary(item) {
  return { id: item.id, title: item.title, project: item.project, link: item.link,
    slug: item.sdlc?.slug || null, phase: item.sdlc?.phase || null, state: item.sdlc?.state || null,
    action: item.sdlc?.action || '', waiting: item.waiting, replies: item.replies || [], status: item.status };
}
async function main() {
  const { command, flags, args } = argumentsFor(process.argv.slice(2));
  const arity = (min, max = min) => { if (args.length < min || args.length > max) bad(`invalid arguments for ${command || 'TUI'}`); };
  let lang;
  try { lang = resolveLanguage(flags.lang, process.env.SDLC_TODO_LANG); } catch (error) { bad(error.message); }
  if (!command) {
    arity(0);
    if (!process.stdout.isTTY) bad('a terminal is required for the TUI');
    return import('./tui.mjs').then(m => m.runTui({ file, kit, web: !flags['no-web'], lang }));
  }
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
      if (flags.json) console.log(JSON.stringify(model.items.map(summary)));
      else for (const item of model.items) console.log(`${item.id} [${item.status}] ${item.title}`);
      return;
    }
    case 'next': {
      arity(0);
      const result = await core.next(file, { kit });
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
    case 'done': arity(1, 2); await core.done(file, ...args); return;
  }
}
main().catch(error => {
  console.error(error.message);
  process.exitCode = typeof error.code === 'number' ? error.code : 1;
});
