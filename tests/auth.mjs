import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHandler, passwordHash, randomToken, digest, subscriptionToken } from '../subscription-auth/auth.mjs';
import { buildAuth } from '../scripts/build-auth.mjs';

// Execute the real SQL against SQLite, including atomic updates and uniqueness.
const sqlite = new DatabaseSync(':memory:');
sqlite.exec(readFileSync(new URL('../subscription-auth/schema.sql', import.meta.url), 'utf8'));
const db = {
  prepare(sql) {
    const stmt = sqlite.prepare(sql); let args = [];
    const query = {
      bind(...values) { args = values; return query; },
      async first() { return stmt.get(...args) || null; },
      async run() { return { meta: { changes: Number(stmt.run(...args).changes) } }; },
    }; return query;
  },
  async batch(statements) {
    sqlite.exec('BEGIN');
    try { const result = []; for (const stmt of statements) result.push(await stmt.run()); sqlite.exec('COMMIT'); return result; }
    catch (error) { sqlite.exec('ROLLBACK'); throw error; }
  },
};
const secret = randomToken(), password = 'fixture-only-passphrase-2026';
const catalog = [
  { id: 'demo', v2: '/v2?isp=demo', clash: '/c?isp=demo', host: '192.0.2.1', expires: 'never' },
  { id: 'backup', v2: '/v2?isp=backup', clash: '/c?isp=backup', host: '192.0.2.2', expires: 'never' },
  { id: 'tx', kind: 'tx-direct', v2: '/tx-v2', clash: '/tx', host: '192.0.2.3' },
];
const v2 = await import(pathToFileURL(process.argv[2]));
const clash = await import(pathToFileURL(process.argv[3]));
const globalSource = readFileSync(process.argv[4], 'utf8');
const handler = createHandler({ catalog, globalSource, handlers: {
  '/v2': v2.onRequest, '/c': clash.onRequest,
  '/tx': context => { assert.deepEqual(context.data.allowedIsps, ['tx']); return new Response('direct-only'); },
  '/tx-v2': () => new Response('direct-only'),
} });
let ip = 1;
async function request(path, options = {}) {
  const headers = new Headers(options.headers);
  headers.set('CF-Connecting-IP', options.ip || '192.0.2.' + ip++);
  if (options.cookie) headers.set('Cookie', options.cookie);
  if (options.body !== undefined) { headers.set('Content-Type', 'application/json'); if (!options.crossOrigin) headers.set('Origin', 'https://sub.example'); }
  const req = new Request('https://sub.example' + path, {
    method: options.method || (options.body !== undefined ? 'POST' : 'GET'), headers,
    ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}),
  });
  return handler({ request: req, env: options.env || { SUB_AUTH_DB: db, SUB_AUTH_KEY: secret }, next: () => new Response('public-asset') });
}
async function addUser(username, ids) {
  const salt = randomToken(), invite = randomToken();
  await db.prepare('INSERT INTO users(username, scopes, password_hash, password_salt, invite_hash, invite_expires, token_version, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
    .bind(username, JSON.stringify(ids), await passwordHash(password, salt, secret), salt, await digest(invite), Math.floor(Date.now() / 1000) + 3600, randomToken(), 1).run();
  return invite;
}
await addUser('alice', ['demo', 'tx']); await addUser('bob', ['backup', 'tx']); await addUser('limited', ['demo']);
async function login(username, value = password) {
  const response = await request('/api/login', { body: { username, password: value } });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Set-Cookie'), /__Host-sub-session=.*; Path=\/; HttpOnly; Secure; SameSite=Strict/);
  return response.headers.get('Set-Cookie').split(';')[0];
}
for (const path of ['/v2', '/c', '/s', '/global-extension.js', '/tx', '/tx-v2', '/subscriptions.json', '/api/me']) {
  const response = await request(path);
  assert.equal(response.status, 401, path); assert.match(response.headers.get('Cache-Control'), /no-store/);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), null);
}
for (const path of ['/nodes.yaml', '/anything/nodes', '/server/catalog.mjs', '/functions/_private/catalog.mjs', '/functions/v2.js', '/wrangler.toml', '/README.md', '/manifest.json', '/c/']) {
  assert.equal((await request(path)).status, 404, path);
}
assert.equal((await request('/c', { env: {} })).status, 503);
assert.equal((await request('/c', { headers: { 'X-User': 'alice', Authorization: 'Basic abc' } })).status, 401);
assert.equal((await request('/api/login', { body: { username: 'alice', password }, crossOrigin: true })).status, 403);
assert.equal((await request('/api/login', { body: { username: 'alice', password: 'wrong-password-long' } })).status, 401);
assert.equal((await request('/api/login', { body: { username: 'unknown', password } })).status, 401);
assert.equal((await request('/api/login', { body: { username: 'alice', password: 'x'.repeat(5000) } })).status, 400);
let aliceCookie = await login('alice'), bobCookie = await login('bob');
let alice = await (await request('/api/me', { cookie: aliceCookie })).json();
const bob = await (await request('/api/me', { cookie: bobCookie })).json();
assert.deepEqual(alice.entries.map(e => e.id), ['demo', 'tx']);
assert.deepEqual(bob.entries.map(e => e.id), ['backup', 'tx']);
assert.ok(!JSON.stringify(alice).includes('192.0.2.2'));
let aliceToken = new URL(alice.entries[0].v2, 'https://sub.example').searchParams.get('token');
const bobToken = new URL(bob.entries[0].v2, 'https://sub.example').searchParams.get('token');
for (const [token, id, foreign] of [[aliceToken, 'demo', 'backup'], [bobToken, 'backup', 'demo']]) {
  for (const path of ['/v2', '/v2?raw=1', '/c', '/s', '/global-extension.js']) {
    const response = await request(path, { headers: { Authorization: 'Bearer ' + token } });
    assert.equal(response.status, 200, path);
    let body = await response.text(); if (path === '/v2') body = Buffer.from(body, 'base64').toString();
    if (path === '/s' || path === '/global-extension.js') {
      const entries = JSON.parse(body.match(/const ispEntries = (\[[^\n]+\])/)[1]);
      assert.deepEqual(entries.map(e => e.id), [id]); assert.ok(!body.includes('JSON.parse(atob('));
    } else { assert.ok(body.includes(`T-${id}-`)); assert.ok(!body.includes(`T-${foreign}-`)); }
  }
  assert.equal((await request('/c?isp=' + foreign + '&token=' + token)).status, 403);
  assert.equal((await request('/v2?isp=' + foreign + '&token=' + token)).status, 403);
  assert.equal((await request('/s?isp=' + foreign + '&token=' + token)).status, 403);
  assert.equal((await request('/c?isp=' + id + '&isp=' + foreign + '&token=' + token)).status, 403);
  assert.equal((await request('/tx?token=' + token)).status, 200);
  assert.equal((await request('/tx-v2?token=' + token)).status, 200);
  assert.equal((await request('/api/me?token=' + token)).status, 401, 'Subscription token cannot become a browser session');
}
assert.equal((await request('/c?token=' + aliceToken + '&token=' + bobToken)).status, 401);
assert.equal((await request('/c?token=' + aliceToken.slice(0, -2) + 'xx')).status, 401);
assert.equal((await request('/c', { cookie: aliceCookie, headers: { Authorization: 'Bearer invalid' } })).status, 401);
const limitedCookie = await login('limited');
assert.equal((await request('/tx', { cookie: limitedCookie })).status, 403);
const before = aliceToken;
assert.equal((await request('/api/rotate-token', { cookie: aliceCookie, body: {} })).status, 200);
assert.equal((await request('/c?token=' + before)).status, 401);
alice = await (await request('/api/me', { cookie: aliceCookie })).json();
aliceToken = new URL(alice.entries[0].v2, 'https://sub.example').searchParams.get('token');
assert.equal((await request('/c?token=' + aliceToken)).status, 200);
const secondSession = await login('alice');
assert.equal((await request('/api/password', { cookie: aliceCookie, body: { currentPassword: password, password: 'new-fixture-passphrase' } })).status, 200);
assert.equal((await request('/api/me', { cookie: secondSession })).status, 401);
assert.equal((await request('/api/me', { cookie: aliceCookie })).status, 401);
assert.equal((await request('/c?token=' + aliceToken)).status, 200, 'Password reset does not silently break client links');
aliceCookie = await login('alice', 'new-fixture-passphrase');
assert.equal((await request('/api/logout', { cookie: aliceCookie, body: {} })).status, 200);
assert.equal((await request('/api/me', { cookie: aliceCookie })).status, 401);
await db.prepare('UPDATE users SET enabled = 0 WHERE username = ?').bind('bob').run();
assert.equal((await request('/c?token=' + bobToken)).status, 401);
assert.equal((await request('/api/me', { cookie: bobCookie })).status, 401);
const invitation = await addUser('newuser', ['demo', 'tx']);
await db.prepare('UPDATE users SET password_hash = NULL, password_salt = NULL WHERE username = ?').bind('newuser').run();
const activated = await request('/api/activate', { body: { invite: invitation, password } });
assert.equal(activated.status, 200);
assert.equal((await request('/api/activate', { body: { invite: invitation, password } })).status, 401);
const raced = await addUser('raced', ['demo']);
const race = await Promise.all([request('/api/activate', { body: { invite: raced, password } }), request('/api/activate', { body: { invite: raced, password } })]);
assert.deepEqual(race.map(r => r.status).sort(), [200, 401], 'An invitation can only be consumed once under concurrency');
const expired = await addUser('expired', ['demo']);
await db.prepare('UPDATE users SET invite_expires = 1 WHERE username = ?').bind('expired').run();
assert.equal((await request('/api/activate', { body: { invite: expired, password } })).status, 401);
for (let i = 0; i < 30; i++) await request('/api/login', { ip: '198.51.100.1', body: {} });
assert.equal((await request('/api/login', { ip: '198.51.100.1', body: { username: 'alice', password } })).status, 429);
// Session expiry must be checked by the server, not trusted from the cookie.
const expiredCookie = await login('limited');
await db.prepare('UPDATE sessions SET expires = 1 WHERE username = ?').bind('limited').run();
assert.equal((await request('/api/me', { cookie: expiredCookie })).status, 401);

const dir = mkdtempSync(resolve(tmpdir(), 'cody-auth-build-'));
try {
  mkdirSync(resolve(dir, 'functions'));
  writeFileSync(resolve(dir, 'subscriptions.json'), JSON.stringify(catalog));
  writeFileSync(resolve(dir, 'global-extension.js'), globalSource);
  writeFileSync(resolve(dir, 'nodes.yaml'), 'sensitive-old-static');
  writeFileSync(resolve(dir, '_redirects'), '/hidden/nodes /nodes.yaml 200');
  assert.equal(buildAuth(dir, {}), false, 'Default leaves existing public deployment unchanged');
  assert.throws(() => buildAuth(dir, { SUB_AUTH_ENABLED: 'true' }), /D1/);
  assert.equal(buildAuth(dir, { SUB_AUTH_ENABLED: 'true', SUB_AUTH_D1_ID: '00000000-0000-0000-0000-000000000000' }), true);
  for (const file of ['subscriptions.json', 'global-extension.js', 'nodes.yaml', '_redirects']) assert.equal(existsSync(resolve(dir, file)), false, file);
  assert.ok(existsSync(resolve(dir, 'functions/_private/catalog.mjs')));
  assert.deepEqual(JSON.parse(readFileSync(resolve(dir, '_routes.json'), 'utf8')), { version: 1, include: ['/*'], exclude: [] });
  assert.throws(() => buildAuth(dir, {}), /cannot be rebuilt/);
} finally { rmSync(dir, { recursive: true, force: true }); sqlite.close(); }
console.log('Account isolation, authentication, token revocation, expiry, CSRF, rate limits and private asset packaging passed');
