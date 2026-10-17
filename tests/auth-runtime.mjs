import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { createHmac } from 'node:crypto';
import { buildFixture, demoPassword } from './auth-fixture.mjs';

const directory = mkdtempSync(resolve(tmpdir(), 'cody-auth-runtime-'));
const wrangler = process.env.WRANGLER_BIN || resolve('cloudflare-pages-sub/node_modules/.bin/wrangler');
let processHandle;
try {
  const credentials = Object.fromEntries(['dawn', 'zw', 'gj', 'crj'].map(id => [id,
    Object.fromEntries(['trojan', 'hysteria', 'obfs'].map(type => [type, `runtime-${id}-${type}-`.padEnd(40, 'x')]))]));
  const credentialsFile = resolve(directory, 'private-credentials.json');
  writeFileSync(credentialsFile, JSON.stringify(credentials), { mode: 0o600 });
  await buildFixture(directory, { SUB_AUTH_ISP_CREDENTIALS_FILE: credentialsFile, SUB_ADMIN_USERS: 'dawn' });
  rmSync(credentialsFile);
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
  const firstLogin = await request('/api/login', null, { username: 'dawn', password: demoPassword });
  assert.equal(firstLogin.status, 200);
  const firstCookie = firstLogin.headers.get('Set-Cookie').split(';')[0];
  const firstMonth = await (await request('/api/me', firstCookie)).json();
  assert.equal(firstMonth.usage.personal.used_bytes, 0);
  assert.equal(firstMonth.usage.shared.used_bytes, 0);
  assert.equal(firstMonth.usage.personal.status, 'initialized');
  assert.equal(firstMonth.usage.personal.quota_bytes / 1024 ** 3, 100, 'Client card denominator must render as 100 GB');
  assert.equal(firstMonth.usage.shared.quota_bytes / 1024 ** 3, 1000, 'Shared denominator must render as 1000 GB');
  const firstSubscription = await request(firstMonth.entries[0].clash);
  assert.equal(firstSubscription.headers.get('Subscription-Userinfo'), 'upload=0; download=0; total=107374182400; expire=0');
  assert.equal(firstSubscription.headers.get('X-Subscription-Usage-Status'), 'initialized');
  await request('/api/logout', firstCookie, {});
  const observed = Math.floor(Date.now() / 1000), period = new Date(observed * 1000).toISOString().slice(0, 7);
  const started = Date.parse(period + '-01T00:00:00Z') / 1000;
  const meterKey = readFileSync(resolve(directory, '.dev.vars'), 'utf8').match(/^SUB_METER_KEY=(.+)$/m)[1];
  const report = JSON.stringify({ source: 'la', generation: '0123456789abcdef0123456789abcdef', period, sequence: 1, observed_at: observed,
    counters: ['machine', 'isp:dawn', 'isp:zw', 'isp:gj', 'isp:crj'].map(meter => ({ meter,
      upload_bytes: meter === 'machine' ? 500e9 : 60e9, download_bytes: meter === 'machine' ? 600e9 : 50e9,
      started_at: observed, observed_at: observed, has_gap: true })) });
  const signature = createHmac('sha256', meterKey).update(observed + '.' + report).digest('hex');
  const meterResponse = await fetch(origin + '/api/usage/report', { method: 'POST', body: report,
    headers: { 'Content-Type': 'application/json', 'X-Meter-Timestamp': String(observed), 'X-Meter-Signature': signature } });
  assert.equal(meterResponse.status, 200);
  const tokens = {}, savedLinks = [];
  for (const username of ['dawn', 'zw', 'gj', 'crj']) {
    const login = await request('/api/login', null, { username, password: demoPassword });
    assert.equal(login.status, 200, 'Login in actual Workers runtime');
    const cookie = login.headers.get('Set-Cookie').split(';')[0];
    const me = await (await request('/api/me', cookie)).json();
    assert.deepEqual(me.entries.map(e => e.id), username === 'dawn' ? ['dawn', 'zw', 'gj', 'crj', 'tx'] : [username, 'tx']);
    assert.equal(me.is_admin, username === 'dawn');
    for (const entry of me.entries) assert.equal(entry.usage.used_bytes, entry.id === 'tx' ? 1100e9 : 110e9);
    assert.equal(me.usage.personal.used_bytes, 110e9);
    assert.equal(me.usage.shared.used_bytes, 1100e9);
    assert.equal(me.usage.personal.over_quota, true);
    assert.equal(me.usage.mode, 'notify_only');
    assert.equal(me.usage.personal.status, 'partial');
    assert.equal(me.usage.personal.remaining_bytes, 0);
    tokens[username] = new URL(me.entries[0].v2, origin).searchParams.get('token');
    const repeated = await (await request('/api/me', cookie)).json();
    assert.deepEqual(repeated.entries, me.entries, 'Refreshing the portal must not rotate subscription URLs');
    for (const entry of me.entries) {
      assert.equal(entry.shadowrocket, entry.v2, 'Shadowrocket uses the same authorized remote subscription');
      assert.equal(entry.shadowrocket_module, '/sr', 'Keep the optional Telegram module visible');
      for (const field of ['clash', 'v2', 'shadowrocket', 'extension'].filter(field => entry[field])) {
        const response = await request(entry[field]);
        assert.equal(response.status, 200, `${username} ${field}`);
        assert.match(response.headers.get('Cache-Control'), /no-store/);
        if (field !== 'extension') {
          assert.equal(response.headers.get('Profile-Update-Interval'), '24');
          assert.equal(response.headers.get('X-Subscription-Usage-Status'), 'partial');
          assert.equal(response.headers.get('Profile-Web-Page-URL'), origin + '/');
          assert.match(response.headers.get('Subscription-Userinfo'), /total=(107374182400|1073741824000);/);
          if (username === 'dawn') savedLinks.push({ url: entry[field], field, direct: entry.id === 'tx' });
        }
        const text = await response.text();
        const content = ['v2', 'shadowrocket'].includes(field) ? Buffer.from(text, 'base64').toString() : text;
        for (const foreign of ['dawn', 'zw', 'gj', 'crj'].filter(x => x !== entry.id)) assert.ok(!content.includes(foreign.toUpperCase() + '-'), 'Foreign node leaked');
        for (const [id, values] of Object.entries(credentials)) {
          for (const password of Object.values(values)) assert.equal(content.includes(password), entry.id !== 'tx' && id === entry.id, 'Credential scope mismatch');
        }
      }
    }
    assert.equal((await request('/api/logout', cookie, {})).status, 200);
    assert.equal((await request(me.entries[0].clash)).status, 200, 'Client updates do not depend on the browser session');
    const relogin = await request('/api/login', null, { username, password: demoPassword });
    const newCookie = relogin.headers.get('Set-Cookie').split(';')[0];
    const afterLogin = await (await request('/api/me', newCookie)).json();
    assert.deepEqual(afterLogin.entries, me.entries, 'Re-login must preserve existing client subscription URLs');
  }
  // Simulate a new generated configuration while preserving D1 and signing key.
  // The exact URL saved during initial import must now return the updated values.
  for (const file of ['c.js', 'v2.js']) {
    const path = resolve(directory, 'functions', file);
    writeFileSync(path, readFileSync(path, 'utf8').replaceAll('relay.example', 'updated-relay.example'));
  }
  for (const file of ['tx.js', 'tx-v2.js']) {
    const path = resolve(directory, 'functions', file);
    writeFileSync(path, readFileSync(path, 'utf8').replaceAll('relay.example', 'updated-relay.example'));
  }
  for (const link of savedLinks) {
    let updated = false;
    for (let attempt = 0; attempt < 80; attempt++) {
      const response = await request(link.url);
      const text = await response.text();
      const body = ['v2', 'shadowrocket'].includes(link.field) ? Buffer.from(text, 'base64').toString() : text;
      if (response.status === 200 && body.includes('updated-relay.example')) { updated = true; break; }
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    assert.ok(updated, 'An existing subscription URL must retrieve the newly published configuration');
  }
  for (const route of ['/c', '/v2', '/s', '/global-extension.js']) {
    assert.equal((await request(route + '?isp=gj&token=' + tokens.zw)).status, 403, 'Cross-account request');
  }
  for (const route of ['/c', '/v2', '/s']) {
    const response = await request(route + '?token=' + tokens.dawn);
    assert.equal(response.status, 200, 'Administrator can fetch all lines');
    if (route === '/s') assert.equal(response.headers.get('Subscription-Userinfo'), null);
    else assert.match(response.headers.get('Subscription-Userinfo'), /total=1073741824000;/, 'Combined admin subscription uses the shared machine pool');
    let text = await response.text(); if (route === '/v2') text = Buffer.from(text, 'base64').toString();
    for (const id of ['dawn', 'zw', 'gj', 'crj']) assert.ok(text.includes(route === '/s' ? '"id":"' + id + '"' : id.toUpperCase() + '-'));
  }
  const moduleResponse = await request('/sr');
  assert.equal(moduleResponse.status, 200);
  const module = await moduleResponse.text();
  assert.ok(module.includes('DOMAIN-SUFFIX,telegram.org,PROXY'));
  assert.ok(module.includes('RULE-SET,' + origin + '/rules/shadowrocket-telegram.list,PROXY'));
  assert.ok(!module.includes('trojan://') && !module.includes('hysteria2://'));
  console.log('Actual Cloudflare Pages + D1 runtime: DAWN sees all lines; ordinary accounts stay isolated; per-line usage and all formats pass; private files blocked; existing client URLs refresh after configuration changes');
} finally {
  if (processHandle && processHandle.exitCode === null) {
    await new Promise(resolve => { processHandle.once('exit', resolve); processHandle.kill('SIGTERM'); });
  }
  rmSync(directory, { recursive: true, force: true });
}
