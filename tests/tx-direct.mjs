import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { buildConfig, renderPages } from '../scripts/tx-direct.mjs';

const source = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
const cidrs = readFileSync(new URL('../config/tx-client-direct-cidrs.txt', import.meta.url), 'utf8')
  .split('\n').map(line => line.replace(/#.*/, '').trim()).filter(Boolean);
const env = {
  TX_DIRECT_ENABLED: 'true', TX_DIRECT_IP: '203.0.113.50',
  TX_DIRECT_TROJAN_PORT: '443', TX_DIRECT_HYSTERIA_PORT: '8443',
  TX_DIRECT_TROJAN_PASSWORD: 'test-trojan-'.repeat(3),
  TX_DIRECT_HYSTERIA_PASSWORD: 'test-hysteria-'.repeat(3),
  TX_DIRECT_OBFS_PASSWORD: 'test-obfs-'.repeat(3),
  TROJAN_DOMAIN: 'tj.example.com', HYSTERIA_DOMAIN: 'hy.example.com',
  CF_DNS_EDIT_TOKEN: 'test-dns-token', ACME_EMAIL: 'test@example.com',
  CLIENT_DIRECT_IP_CIDRS: cidrs.join(','), AI_ISP_DOMAINS: 'ai.example',
  DIRECT_BULK_DOMAINS: 'youtube.com,rou.video',
  CLASH_RULESET_BASE_URL: 'https://sub.example/rules',
  CLASH_FORCE_TCP_DOMAINS: 'github.com', CLASH_FORCE_TCP_ENABLED: 'true',
};
const cfg = buildConfig(env);
assert.deepEqual(cfg.inbounds.map(i => i.listen_port), [443, 8443]);
assert.equal(cfg.route.final, 'block');
assert.deepEqual(cfg.outbounds.map(o => o.type), ['direct', 'block']);
assert.equal(cfg.route.rules[0].action, 'resolve');
const reject = cfg.route.rules.find(r => r.action === 'reject');
for (const cidr of cidrs) assert.ok(reject.ip_cidr.includes(cidr), `server must reject ${cidr}`);
assert.equal(cfg.route.rules.at(-1).outbound, 'tx-direct-out');
assert.deepEqual(cfg.route.rules.at(-1).inbound, cfg.inbounds.map(i => i.tag));
assert.ok(cfg.inbounds.every(i => i.tls.acme.data_directory === '/var/lib/sing-box-tx-direct/certmagic'));
assert.throws(() => buildConfig({ ...env, TX_DIRECT_IP: 'bad-host' }), /IPv4/);
assert.throws(() => buildConfig({ ...env, TX_DIRECT_TROJAN_PORT: '8443' }), /distinct/);
assert.throws(() => buildConfig({ ...env, TX_DIRECT_TROJAN_PASSWORD: 'short' }), /24-128/);

const modules = renderPages(source, env);
const importCode = code => import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);
const clash = await importCode(modules['tx.js']);
const uri = await importCode(modules['tx-v2.js']);
const response = await clash.onRequest({ request: new Request('https://sub.example/tx') });
const yaml = await response.text();
assert.equal(response.status, 200);
assert.equal(response.headers.get('Profile-Title'), 'tx-direct');
assert.match(response.headers.get('Subscription-Userinfo'), /expire=0$/);
assert.equal((yaml.match(/type: (trojan|hysteria2)\n/g) || []).length, 2);
assert.equal((yaml.match(/server: 203\.0\.113\.50\n/g) || []).length, 2);
assert.match(yaml, /sni: tj\.example\.com/);
assert.match(yaml, /sni: hy\.example\.com/);
assert.doesNotMatch(yaml, /skip-cert-verify: true|ISP 出口|T-ds-|T-dawn/);
for (const cidr of cidrs) {
  const rule = `IP-CIDR,${cidr},DIRECT,no-resolve`;
  assert.ok(yaml.indexOf(rule) > 0, `missing ${rule}`);
  assert.ok(yaml.indexOf(rule) < yaml.indexOf('DOMAIN-SUFFIX,ai.example'), `LAN priority ${cidr}`);
  assert.ok(yaml.indexOf(rule) < yaml.indexOf("- 'MATCH,"));
}
const rawResponse = await uri.onRequest({ request: new Request('https://sub.example/tx-v2?raw=1') });
const raw = await rawResponse.text();
assert.equal(raw.trim().split('\n').length, 2);
assert.match(raw, /@203\.0\.113\.50:443\?/);
assert.match(raw, /@203\.0\.113\.50:8443\//);
assert.match(raw, /sni=tj\.example\.com/);
assert.match(raw, /sni=hy\.example\.com/);
assert.doesNotMatch(raw, /test-dns-token/);
const encoded = await uri.onRequest({ request: new Request('https://sub.example/tx-v2') });
assert.equal(Buffer.from(await encoded.text(), 'base64').toString(), raw);
assert.equal((await clash.onRequest({request:new Request('https://sub.example/tx?isp=ds-1')})).status, 410);

// Disabling must replace copied old generated files with 410 handlers, not leave active credentials.
const disabled = renderPages(source, { TX_DIRECT_ENABLED: 'false' });
for (const code of Object.values(disabled)) {
  const handler = await importCode(code);
  assert.equal(handler.onRequest().status, 410);
  assert.doesNotMatch(code, /password|203\.0\.113/);
}
// Generation is side-effect-free with respect to the original ISP template.
assert.equal(source, readFileSync(new URL('../install.sh', import.meta.url), 'utf8'));
console.log('TX direct tests passed: isolated nodes, valid credentials, LAN precedence, disabled cleanup.');
