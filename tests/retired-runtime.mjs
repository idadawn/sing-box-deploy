import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { buildRetired } from '../scripts/build-retired.mjs';
const directory = mkdtempSync(resolve(tmpdir(), 'retired-runtime-'));
const wrangler = process.env.WRANGLER_BIN || resolve('cloudflare-pages-sub/node_modules/.bin/wrangler');
let processHandle;
try {
  mkdirSync(resolve(directory, 'functions')); mkdirSync(resolve(directory, 'rules'));
  writeFileSync(resolve(directory, 'functions/c.js'), 'export function onRequest(){ return new Response("fixture-secret"); }');
  writeFileSync(resolve(directory, 'nodes.yaml'), 'fixture-secret');
  writeFileSync(resolve(directory, 'wrangler.toml'), 'name="old-sub"\npages_build_output_dir="."\n');
  writeFileSync(resolve(directory, 'rules/apple.txt'), 'DOMAIN,apple.example\n');
  buildRetired(directory, { SUB_LEGACY_RETIRED: 'true', SUB_DOMAIN: 'old.example', SUB_PORTAL_REDIRECT_URL: 'https://new.example', CF_PAGES_PROJECT: 'old-sub' });
  const socket = createServer(); await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port; await new Promise(resolve => socket.close(resolve));
  const origin = 'http://127.0.0.1:' + port;
  processHandle = spawn(wrangler, ['pages', 'dev', '.', '--ip=127.0.0.1', '--port=' + port, '--inspector-port=0', '--log-level=error'], { cwd: directory, stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  let errors = ''; processHandle.stderr.on('data', d => { errors += d.toString(); });
  let ready = false;
  for (let i = 0; i < 100; i++) {
    try { if ((await fetch(origin, { redirect: 'manual', signal: AbortSignal.timeout(500) })).status === 302) { ready = true; break; } } catch {}
    if (processHandle.exitCode !== null) throw new Error(errors);
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  assert.ok(ready, errors);
  for (const path of ['/c', '/c?isp=dawn', '/v2', '/v2?raw=1', '/s', '/tx', '/tx-v2', '/sr', '/global-extension.js', '/subscriptions.json', '/nodes.yaml', '/old-hidden/nodes', '/functions/c.js', '/index.js', '/rules/apple.txt/', '/%63']) {
    const r = await fetch(origin + path, { redirect: 'manual' });
    assert.equal(r.status, 410, path); const body = await r.text(); assert.ok(body.includes('新版专属订阅') && !body.includes('fixture-secret'));
  }
  for (const path of ['/', '/index.html']) {
    const r = await fetch(origin + path, { redirect: 'manual' }); assert.equal(r.status, 302); assert.equal(r.headers.get('Location'), 'https://new.example/');
  }
  assert.equal(await (await fetch(origin + '/rules/apple.txt')).text(), 'DOMAIN,apple.example\n');
  const head = await fetch(origin + '/c', { method: 'HEAD' }); assert.equal(head.status, 410); assert.equal(await head.text(), '');
  console.log('Actual Pages runtime: retired subscriptions and hidden paths return 410; login redirect and safe rules remain available.');
} finally {
  if (processHandle && processHandle.exitCode === null) await new Promise(resolve => { processHandle.once('exit', resolve); processHandle.kill('SIGTERM'); });
  rmSync(directory, { recursive: true, force: true });
}
