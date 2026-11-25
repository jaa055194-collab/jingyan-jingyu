// Headless smoke test: serve this package on 127.0.0.1 and screenshot web/index.html?demo=1
// with Microsoft Edge (or any Chromium) in headless mode.
//   node scripts/smoke.mjs <out.png> [width=1080] [height=2400]
// Env: EDGE=<browser exe>, BUDGET_MS=<virtual time budget, default 6000>, TIMEOUT_MS=<kill after, default 90000>.
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { startServer } from './serve.mjs';

const out = resolve(process.argv[2] ?? 'smoke.png');
const width = Number(process.argv[3] ?? 1080);
const height = Number(process.argv[4] ?? 2400);
const browser = process.env.EDGE ?? 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const profile = join(dirname(out), 'edge-profile');
mkdirSync(profile, { recursive: true });

const { server, url } = await startServer({ port: 0 });
const page = `${url}web/index.html?demo=1`;
const args = [
  '--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
  '--hide-scrollbars', '--mute-audio', '--force-device-scale-factor=1',
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
  `--user-data-dir=${profile}`, `--window-size=${width},${height}`,
  `--virtual-time-budget=${Number(process.env.BUDGET_MS ?? 6000)}`, `--screenshot=${out}`, page,
];

let finished = false;
const child = spawn(browser, args, { stdio: 'ignore', windowsHide: true });
const timer = setTimeout(() => child.kill(), Number(process.env.TIMEOUT_MS ?? 90000));
const done = (code, why = '') => {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  server.closeAllConnections?.();
  server.close();
  console.log(`smoke: browser exit=${code}${why} page=${page} out=${out}`);
  process.exitCode = code === 0 ? 0 : 1;
};
child.once('error', (e) => done(-1, ` (${e.message})`));
child.once('exit', (code) => done(code));
