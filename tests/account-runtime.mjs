import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { createHmac } from 'node:crypto';
import { buildFixture, demoPassword } from './auth-fixture.mjs';

const directory = mkdtempSync(resolve(tmpdir(), 'cody-account-runtime-'));
const wrangler = process.env.WRANGLER_BIN || resolve('cloudflare-pages-sub/node_modules/.bin/wrangler');
const names = ['dawn', 'zw', 'gj', 'crj'], GB = 1024 ** 3;
let runtime;
try {
  const credentials = Object.fromEntries(names.map(username => [username, {
    scopes: username === 'dawn' ? [...names, 'tx'] : [username, 'tx'],
    trojan: ('fixture-' + username + '-trojan-').padEnd(40, 'x'), hysteria: ('fixture-' + username + '-hy2-').padEnd(40, 'y'),
  }]));
  const file = resolve(directory, 'private-account-credentials.json');
  writeFileSync(file, JSON.stringify(credentials), { mode: 0o600 });
  await buildFixture(directory, { SUB_ADMIN_USERS: 'dawn', SUB_KIWIVM_VEID: '123', SUB_ACCOUNT_CREDENTIALS_FILE: file });
  rmSync(file);
  const migrated = spawnSync(wrangler, ['d1', 'execute', 'SUB_AUTH_DB', '--local', '--file=fixture.sql'], { cwd: directory, encoding: 'utf8', env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  assert.equal(migrated.status, 0, migrated.stderr); rmSync(resolve(directory, 'fixture.sql'));
  const socket = createServer(); await new Promise(r => socket.listen(0, '127.0.0.1', r));
  const port = socket.address().port; await new Promise(r => socket.close(r));
  const origin = `http://127.0.0.1:${port}`;
  runtime = spawn(wrangler, ['pages', 'dev', '.', '--ip=127.0.0.1', '--port=' + port, '--inspector-port=0', '--log-level=error'], { cwd: directory, stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, WRANGLER_SEND_METRICS: 'false' } });
  let errors = ''; runtime.stderr.on('data', d => { errors += d; });
  let ready = false;
  for (let n = 0; n < 100; n++) {
    try { if ((await fetch(origin, { signal: AbortSignal.timeout(500) })).status === 200) { ready = true; break; } } catch {}
    if (runtime.exitCode !== null) throw Error(errors);
    await new Promise(r => setTimeout(r, 250));
  }
  assert.ok(ready, errors);
  const req = (path, cookie, body) => fetch(origin + path, { headers: { ...(cookie ? { Cookie: cookie } : {}), ...(body ? { Origin: origin, 'Content-Type': 'application/json' } : {}) }, ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}) });
  const now = Math.floor(Date.now() / 1000), reset = now + 3 * 86400, start = now - 27 * 86400;
  const key = readFileSync(resolve(directory, '.dev.vars'), 'utf8').match(/^SUB_METER_KEY=(.+)$/m)[1];
  const report = JSON.stringify({ source: 'la', generation: '0123456789abcdef0123456789abcdef', period: new Date(now * 1000).toISOString().slice(0, 7), sequence: 1, observed_at: now,
    provider: { name: 'kiwivm', service_id: '123', used_bytes: 991 * GB, quota_bytes: 1000 * GB, reset_at: reset, observed_at: now },
    counters: [{ meter: 'machine', upload_bytes: 123, download_bytes: 456, started_at: now, observed_at: now, has_gap: true }],
    account_usage: { service_id: '123', reset_at: reset, start_at: start,
      counters: [...names, '__legacy__'].map((account, i) => ({ account, upload_bytes: (i+1)*GB, download_bytes: (i+2)*GB, started_at: start, observed_at: now, has_gap: false })) } });
  const signed = await fetch(origin + '/api/usage/report', { method: 'POST', body: report, headers: {
    'Content-Type': 'application/json', 'X-Meter-Timestamp': String(now), 'X-Meter-Signature': createHmac('sha256', key).update(now + '.' + report).digest('hex') } });
  assert.equal(signed.status, 200, await signed.text());
  for (const [i, name] of names.entries()) {
    const login = await req('/api/login', null, { username: name, password: demoPassword });
    assert.equal(login.status, 200); const cookie = login.headers.get('Set-Cookie').split(';')[0];
    const me = await (await req('/api/me', cookie)).json();
    assert.equal(me.usage.account_mode, true); assert.equal(me.usage.personal.used_bytes, (2*i+3)*GB);
    assert.equal(me.usage.personal.reset_at, reset); assert.equal(me.usage.period.start, start);
    assert.equal(me.usage.shared.used_bytes, 991*GB);
    assert.equal(me.overview?.accounts.length, name === 'dawn' ? 4 : undefined, 'Only admins may see other account totals');
    if (me.overview) assert.equal(me.overview.legacy.used_bytes, 11*GB);
    for (const entry of me.entries) {
      for (const field of ['clash', 'v2', 'extension'].filter(f => entry[f])) {
        const response = await req(entry[field]); assert.equal(response.status, 200, name + ':' + entry.id + ':' + field);
        const raw = await response.text(), body = field === 'v2' ? Buffer.from(raw, 'base64').toString() : raw;
        assert.ok(body.includes(credentials[name].trojan)); assert.ok(body.includes(credentials[name].hysteria));
        assert.ok(!body.includes('undefined'), 'Shared obfs fallback remains intact');
        for (const foreign of names.filter(n => n !== name)) {
          assert.ok(!body.includes(credentials[foreign].trojan)); assert.ok(!body.includes(credentials[foreign].hysteria));
        }
        if (field !== 'extension') {
          assert.equal(response.headers.get('Subscription-Userinfo'), `upload=${(i+1)*GB}; download=${(i+2)*GB}; total=${100*GB}; expire=0`);
          assert.equal(response.headers.get('X-Subscription-Usage-Reset-At'), String(reset));
        }
      }
    }
    if (name === 'zw') assert.equal((await req('/c?isp=gj', cookie)).status, 403);
    assert.deepEqual((await (await req('/api/me', cookie)).json()).entries, me.entries, 'Refreshing must preserve subscription URLs');
  }
  for (const path of ['/functions/_private/accounts.mjs', '/private-account-credentials.json', '/wrangler.toml']) assert.equal((await req(path)).status, 404);
  console.log('Account runtime passed: ISP/direct credentials isolated per account, admin uses own identity, common billing cycle, private overview, and all client formats');
} finally {
  if (runtime && runtime.exitCode === null) await new Promise(r => { runtime.once('exit', r); runtime.kill('SIGTERM'); });
  rmSync(directory, { recursive: true, force: true });
}
