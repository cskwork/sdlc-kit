// Starts the app's server (todo/app/server) in place of startWeb. SDLC_TODO_RUST_SERVE names the binary:
//   cargo build --release -p sdlc-todo-server --manifest-path todo/app/Cargo.toml   (target/release/sdlc-todo-serve)
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { feedPath } from '../todo/web.mjs';

export const rustServer = process.env.SDLC_TODO_RUST_SERVE || '';
const kitHere = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export async function startRustWeb({ file, kit, node = process.execPath, onUrl, lang, session = '', feed = feedPath(file), statusRunner,
  deferInitialSync = false, runTimeout, killAfter, searchPath, finishRetryMs, platform } = {}) {
  if (statusRunner) throw new Error('a status runner function cannot reach another process');
  // Without a session of the test's own, one in a temp folder carries the address back.
  const temp = session ? '' : mkdtempSync(join(tmpdir(), 'sdlc-todo-rust-'));
  const where = session || join(temp, 'todo-web.json');
  const flags = { '--kit': kitHere, '--file': file, '--feed': feed, '--session': where, '--node': node, '--pid': process.pid,
    '--lang': lang, '--status-kit': kit, '--defer': deferInitialSync || undefined, '--run-timeout': runTimeout, '--kill-after': killAfter,
    '--finish-retry': finishRetryMs, '--search-path': searchPath, '--platform': platform };
  const args = Object.entries(flags).filter(([, value]) => value !== undefined).flatMap(([name, value]) => [name, String(value)]);
  const child = spawn(rustServer, args, { stdio: ['pipe', 'inherit', 'pipe'] });
  let errors = '', exited = false;
  child.stderr.on('data', chunk => { errors += chunk; });
  const gone = new Promise(done => child.once('exit', () => { exited = true; done(); }));
  const close = async () => {
    child.stdin.end();
    await gone;
    if (temp) rmSync(temp, { recursive: true, force: true });
  };
  for (let waited = 0; ; waited += 20) {
    if (existsSync(where)) break;
    if (exited || waited > 60000) { await close(); throw new Error(errors || 'the Rust server did not start'); }
    await new Promise(next => setTimeout(next, 20));
  }
  const { port: bound, token } = JSON.parse(readFileSync(where, 'utf8'));
  const url = `http://127.0.0.1:${bound}/#t=${token}`;
  if (onUrl) await onUrl(url);
  return { url, close };
}
