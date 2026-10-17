import assert from 'node:assert/strict';
const origin = process.argv[2];
const target = process.env.SUB_PORTAL_REDIRECT_URL;
if (!/^https:\/\/[a-z0-9.-]+$/.test(origin || '') || !target) throw new Error('Expected legacy and portal HTTPS origins');
const headers = { 'User-Agent': 'Clash.Meta' };
for (const path of ['/', '/index.html']) {
  const r = await fetch(origin + path, { redirect: 'manual', headers, signal: AbortSignal.timeout(15000) });
  assert.equal(r.status, 302, 'Homepage redirect'); assert.equal(r.headers.get('Location'), new URL(target).origin + '/');
}
for (const path of ['/c', '/c?isp=dawn', '/c?isp=zw', '/c?isp=gj', '/c?isp=crj', '/v2', '/v2?raw=1', '/s', '/tx', '/tx-v2', '/sr', '/subscriptions.json', '/global-extension.js', '/nodes.yaml', '/functions/c.js', '/functions/v2.js', '/unknown/nodes']) {
  const r = await fetch(origin + path, { redirect: 'manual', headers, signal: AbortSignal.timeout(15000) });
  assert.equal(r.status, 410, 'Retired endpoint');
  const text = await r.text(); assert.ok(text.includes('新版专属订阅') && !text.includes('trojan://') && !text.includes('hysteria2://'));
}
const rule = await fetch(origin + '/rules/apple.txt', { headers, signal: AbortSignal.timeout(15000) });
assert.equal(rule.status, 200, 'Credential-free rules remain available');
console.log('Legacy subscriptions return 410; homepage redirect and safe rules verified: ' + origin);
