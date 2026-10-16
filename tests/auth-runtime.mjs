import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { buildFixture, demoPassword } from './auth-fixture.mjs';

const directory = mkdtempSync(resolve(tmpdir(), 'cody-auth-runtime-'));
const wrangler = process.env.WRANGLER_BIN || resolve('cloudflare-pages-sub/node_modules/.bin/wrangler');
let processHandle;
try {
  await buildFixture(directory);
  const migrated = spawnSync(wrangler, ['d1', 'execute', 'SUB_AUTH_DB', '--local', '--file=fixture.sql'], { cwd: directory, encoding: 'utf8', env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  assert.equal(migrated.status, 0, migrated.stderr);
  rmSync(resolve(directory, 'fixture.sql'));
  const socket = createServer(); await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port; await new Promise(resolve => socket.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  processHandle = spawn(wrangler, ['pages', 'dev', '.', '--ip=127.0.0.1', '--port=' + port, '--inspector-port=0', '--log-level=error'], { cwd: directory, stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  let errors = ''; processHandle.stderr.on('data', d => { errors += d.toString(); });
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { if ((await fetch(origin, { signal: AbortSignal.timeout(500) })).status === 200) { ready = true; break; } } catch {}
    if (processHandle.exitCode !== null) throw new Error('Runtime exited: ' + errors);
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  assert.ok(ready, 'Cloudflare runtime did not become ready: ' + errors);
  const request = (path, cookie, body) => fetch(origin + path, { headers: { ...(cookie ? { Cookie: cookie } : {}), ...(body ? { Origin: origin, 'Content-Type': 'application/json' } : {}) }, ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}) });
  for (const route of ['/c', '/v2', '/s', '/global-extension.js', '/subscriptions.json', '/tx', '/tx-v2']) assert.equal((await request(route)).status, 401, route);
  for (const route of ['/nodes.yaml', '/functions/v2.js', '/functions/_private/catalog.mjs', '/.dev.vars', '/fixture.sql', '/wrangler.toml']) assert.equal((await request(route)).status, 404, route);
  const tokens = {};
  for (const username of ['dawn', 'zw', 'gj', 'crj']) {
    const login = await request('/api/login', null, { username, password: demoPassword });
    assert.equal(login.status, 200, 'Login in actual Workers runtime');
    const cookie = login.headers.get('Set-Cookie').split(';')[0];
    const me = await (await request('/api/me', cookie)).json();
    assert.deepEqual(me.entries.map(e => e.id), [username, 'tx']);
    tokens[username] = new URL(me.entries[0].v2, origin).searchParams.get('token');
    for (const entry of me.entries) {
      for (const field of ['clash', 'v2', 'extension'].filter(field => entry[field])) {
        const response = await request(entry[field]);
        assert.equal(response.status, 200, `${username} ${field}`);
        assert.match(response.headers.get('Cache-Control'), /no-store/);
        const text = await response.text();
        const content = field === 'v2' ? Buffer.from(text, 'base64').toString() : text;
        for (const foreign of ['dawn', 'zw', 'gj', 'crj'].filter(x => x !== username)) assert.ok(!content.includes('T-' + foreign + '-'), 'Foreign node leaked');
      }
    }
  }
  for (const route of ['/c', '/v2', '/s', '/global-extension.js']) {
    assert.equal((await request(route + '?isp=zw&token=' + tokens.dawn)).status, 403, 'Cross-account request');
  }
  console.log('Actual Cloudflare Pages + D1 runtime: four accounts isolated; all personal/direct formats pass; private files blocked');
} finally {
  if (processHandle && processHandle.exitCode === null) {
    await new Promise(resolve => { processHandle.once('exit', resolve); processHandle.kill('SIGTERM'); });
  }
  rmSync(directory, { recursive: true, force: true });
}
