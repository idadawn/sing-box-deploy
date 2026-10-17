import assert from 'node:assert/strict';
import { readFileSync, statSync } from 'node:fs';

const origin = process.argv[2];
if (!/^https:\/\/[a-z0-9.-]+$/.test(origin || '')) throw new Error('Expected HTTPS origin');
const file = process.env.SUB_AUTH_VERIFY_FILE;
if (!file || (statSync(file).mode & 0o077)) throw new Error('SUB_AUTH_VERIFY_FILE must be a private 0600 file');
const accounts = JSON.parse(readFileSync(file, 'utf8'));
assert.ok(Array.isArray(accounts) && accounts.length >= 2, 'Need at least two accounts to check cross-account isolation');
assert.ok(accounts.some(account => !account.can_view_all), 'Need an ordinary account to verify isolation');
const fetchPath = (path, token) => fetch(origin + path, {
  redirect: 'manual', signal: AbortSignal.timeout(15000),
  headers: { 'User-Agent': 'Clash.Meta', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
});
for (const path of ['/v2', '/c', '/s', '/global-extension.js', '/tx', '/tx-v2', '/subscriptions.json']) {
  assert.equal((await fetchPath(path)).status, 401, `Anonymous access: ${path}`);
}
for (const path of ['/nodes.yaml', '/server/catalog.mjs', '/functions/v2.js', '/unknown/nodes']) {
  assert.equal((await fetchPath(path)).status, 404, `Unexpected asset: ${path}`);
}
for (const account of accounts) {
  for (const id of account.scopes.filter(id => id !== 'tx')) {
    for (const format of ['v2', 'c', 's']) {
      const response = await fetchPath('/' + format + '?isp=' + encodeURIComponent(id), account.token);
      assert.equal(response.status, 200, `Authorized ${format} failed for ${account.username}`);
      assert.match(response.headers.get('Cache-Control'), /no-store/);
      const text = await response.text();
      const body = format === 'v2' ? Buffer.from(text, 'base64').toString() : text;
      assert.ok(format === 's' ? body.includes('"id":"' + id + '"') : body.includes(id.toUpperCase()), `Missing own scope for ${account.username}`);
      for (const other of accounts.flatMap(a => a.scopes).filter(other => other !== 'tx' && !account.scopes.includes(other))) {
        assert.ok(!body.includes(`${other.toUpperCase()}-`), 'Cross-account node disclosure');
      }
    }
  }
  const foreign = accounts.flatMap(a => a.scopes).find(id => !account.scopes.includes(id));
  if (foreign) assert.equal((await fetchPath('/c?isp=' + encodeURIComponent(foreign), account.token)).status, 403);
  else assert.equal(account.can_view_all, true, 'All-line access must be explicitly expected for this verification account');
  assert.equal((await fetchPath('/tx', account.token)).status, account.scopes.includes('tx') ? 200 : 403);
  console.log(`Verified private subscription scope: ${account.username}`);
}
console.log('Protected endpoints and cross-account isolation verified; credentials omitted.');
