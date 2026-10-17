import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { buildFixture, demoPassword } from './auth-fixture.mjs';
import { createHandler } from '../subscription-auth/auth.mjs';
import { buildAuth } from '../scripts/build-auth.mjs';

const dir = mkdtempSync(resolve(tmpdir(), 'isp-credentials-'));
try {
  const credentials = Object.fromEntries(['dawn', 'zw', 'gj', 'crj'].map(id => [id,
    Object.fromEntries(['trojan', 'hysteria', 'obfs'].map(type => [type, `fixture-${id}-${type}-`.padEnd(40, 'x')]))]));
  const file = resolve(dir, 'credentials.json');
  const env = { SUB_AUTH_ISP_CREDENTIALS_FILE: file };
  writeFileSync(file, JSON.stringify(credentials), { mode: 0o600 });
  const site = resolve(dir, 'site');
  await buildFixture(site, env);
  const { catalog, globalSource } = await import(pathToFileURL(resolve(site, 'functions/_private/catalog.mjs')));
  assert.ok(!JSON.stringify(catalog).includes('credentials'));
  const { onRequest: v2 } = await import(pathToFileURL(resolve(site, 'functions/v2.js')));
  const { onRequest: clash } = await import(pathToFileURL(resolve(site, 'functions/c.js')));
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec(readFileSync(resolve(site, 'fixture.sql'), 'utf8'));
  const db = { prepare(sql) { const stmt = sqlite.prepare(sql); let args = []; const q = {
    bind(...v) { args = v; return q; }, async first() { return stmt.get(...args) || null; },
    async run() { return { meta: { changes: Number(stmt.run(...args).changes) } }; },
  }; return q; }, async batch(statements) { sqlite.exec('BEGIN'); try { const result = []; for (const s of statements) result.push(await s.run()); sqlite.exec('COMMIT'); return result; } catch (e) { sqlite.exec('ROLLBACK'); throw e; } } };
  const key = readFileSync(resolve(site, '.dev.vars'), 'utf8').match(/^SUB_AUTH_KEY=(.+)$/m)[1];
  const handler = createHandler({ catalog, globalSource, handlers: { '/v2': v2, '/c': clash } });
  let ip = 1, adminUsers = '';
  const cookies = {};
  const request = (path, cookie, body) => handler({ request: new Request('https://fixture.example' + path, {
    method: body ? 'POST' : 'GET', headers: { Cookie: cookie || '', Origin: 'https://fixture.example',
      'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.' + ip++ },
    ...(body ? { body: JSON.stringify(body) } : {}),
  }), env: { SUB_AUTH_DB: db, SUB_AUTH_KEY: key, SUB_ADMIN_USERS: adminUsers }, next: () => new Response('public') });
  for (const id of Object.keys(credentials)) {
    const login = await request('/api/login', '', { username: id, password: demoPassword });
    assert.equal(login.status, 200);
    const cookie = login.headers.get('Set-Cookie').split(';')[0];
    cookies[id] = cookie;
    for (const path of ['/v2?raw=1', '/v2', '/c', '/s']) {
      const result = await request(path, cookie);
      assert.equal(result.status, 200, id + path);
      let body = await result.text();
      if (path === '/v2') body = Buffer.from(body, 'base64').toString();
      for (const [other, value] of Object.entries(credentials)) {
        for (const password of Object.values(value)) assert.equal(body.includes(password), other === id, id + path + other);
      }
    }
    assert.equal((await request('/c?isp=' + (id === 'dawn' ? 'zw' : 'dawn'), cookie)).status, 403);
  }
  const now = Math.floor(Date.now() / 1000), period = new Date().toISOString().slice(0, 7);
  const start = Date.parse(period + '-01T00:00:00Z') / 1000;
  for (const [i, id] of Object.keys(credentials).entries()) {
    sqlite.prepare('INSERT INTO monthly_usage VALUES(?,?,?,?,?,?,?,?,?)')
      .run('la', period, 'isp:' + id, (i + 1) * 1e9, (i + 1) * 2e9, start, now, 0, 1);
  }
  sqlite.prepare('INSERT INTO monthly_usage VALUES(?,?,?,?,?,?,?,?,?)').run('la', period, 'machine', 10e9, 20e9, start, now, 0, 1);
  adminUsers = 'dawn';
  const me = await (await request('/api/me', cookies.dawn)).json();
  assert.equal(me.is_admin, true);
  assert.deepEqual(me.entries.map(e => e.id), ['dawn', 'zw', 'gj', 'crj', 'tx']);
  assert.equal(me.usage.personal.used_bytes, 3e9, 'All-line visibility must not combine other users into DAWN quota');
  assert.equal(me.usage.shared.used_bytes, 30e9);
  for (const [i, entry] of me.entries.filter(e => e.id !== 'tx').entries()) {
    assert.equal(entry.usage.used_bytes, (i + 1) * 3e9, 'Every card has its own ISP measurement');
    assert.equal(entry.usage.quota_bytes, 100e9);
  }
  const token = new URL(me.entries[0].clash, 'https://fixture.example').searchParams.get('token');
  for (const path of ['/v2?raw=1', '/c', '/s']) {
    const result = await request(path, cookies.dawn); assert.equal(result.status, 200);
    const body = await result.text();
    for (const value of Object.values(credentials)) for (const password of Object.values(value)) assert.ok(body.includes(password));
    if (path === '/s') assert.equal(result.headers.get('Subscription-Userinfo'), null);
    else assert.match(result.headers.get('Subscription-Userinfo'), /upload=10000000000; download=20000000000; total=1000000000000;/, 'Combined admin subscription uses the shared quota');
  }
  const scoped = await request('/c?isp=zw&token=' + token);
  assert.equal(scoped.status, 200);
  assert.match(scoped.headers.get('Subscription-Userinfo'), /upload=2000000000; download=4000000000; total=100000000000;/);
  const scopedBody = await scoped.text();
  assert.ok(scopedBody.includes(credentials.zw.trojan) && !scopedBody.includes(credentials.dawn.trojan));
  const ordinary = await (await request('/api/me?admin=true&username=dawn', cookies.zw)).json();
  assert.equal(ordinary.is_admin, false);
  assert.deepEqual(ordinary.entries.map(e => e.id), ['zw', 'tx']);
  assert.equal((await request('/c?isp=crj&admin=true', cookies.zw)).status, 403);
  adminUsers = '';
  assert.equal((await request('/c?isp=zw', cookies.dawn)).status, 403, 'Role revocation applies to existing sessions');
  assert.equal((await request('/c?isp=zw&token=' + token)).status, 403, 'Role revocation applies to existing subscription tokens');
  adminUsers = 'dawn'; sqlite.prepare('UPDATE users SET enabled=0 WHERE username=?').run('dawn');
  assert.equal((await request('/c?token=' + token)).status, 401, 'Disabled administrators cannot download');
  assert.equal((await request('/api/me', cookies.dawn)).status, 401);
  sqlite.close();
  assert.throws(() => buildAuth(site, env), /require SUB_AUTH_ENABLED/);
  for (const [name, value, mode, pattern] of [
    ['missing', { dawn: credentials.dawn }, 0o600, /exactly/],
    ['duplicate', { ...credentials, zw: credentials.dawn }, 0o600, /distinct/],
    ['unknown', { ...credentials, extra: credentials.dawn }, 0o600, /exactly/],
    ['permissions', credentials, 0o644, /private/],
  ]) {
    writeFileSync(file, JSON.stringify(value)); chmodSync(file, mode);
    await assert.rejects(buildFixture(resolve(dir, name), env), pattern);
  }
  console.log('Per-ISP credentials: all formats, cross-account isolation and validation passed.');
} finally { rmSync(dir, { recursive: true, force: true }); }
