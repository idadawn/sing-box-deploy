import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, copyFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';
import { renderPages } from '../scripts/tx-direct.mjs';

const probes = [
  'captive.apple.com', 'connectivitycheck.gstatic.com', 'connectivitycheck.android.com',
  'www.msftconnecttest.com', 'ipv6.msftconnecttest.com', 'www.msftncsi.com', 'dns.msftncsi.com',
];
const localDomains = [...probes, '+.lan', '+.local'];
const rules = [...probes.map(domain => `DOMAIN,${domain},DIRECT`),
  'DOMAIN-SUFFIX,lan,DIRECT', 'DOMAIN-SUFFIX,local,DIRECT'];
const plain = value => JSON.parse(JSON.stringify(value));
const fixtures = new Map();
const clash = await import(pathToFileURL(process.argv[2]));
const globalMain = vm.runInNewContext(`${readFileSync(process.argv[3], 'utf8')}\nmain`, { atob });

async function checkSubscription(handler, path, name) {
  const request = () => handler.onRequest({ request: new Request(`https://sub.example${path}`) });
  const response = await request();
  assert.equal(response.status, 200);
  const yaml = await response.text();
  // A fresh subscription fetch must reproduce the policy without client edits.
  assert.equal(await (await request()).text(), yaml);
  const dns = yaml.split('\ndns:\n')[1].split('\nrule-providers:')[0];
  const filter = dns.split('\n  fake-ip-filter:\n')[1].split('\n  default-nameserver:')[0];
  for (const domain of localDomains) {
    assert.ok(filter.includes(`- "${domain}"`), `missing real-IP exception for ${domain}`);
    assert.ok(dns.includes(`"${domain}": [system]`), `missing local DNS for ${domain}`);
  }
  assert.ok(dns.indexOf('"captive.apple.com":') < dns.indexOf('"geosite:cn,private":'));
  assert.match(dns, /fake-ip-filter-mode: blacklist/);
  assert.match(dns, /direct-nameserver-follow-policy: true/);
  // Ordinary foreign DNS must still use the proxy; never replace it with system DNS.
  const resolvers = dns.split('\n  nameserver:\n')[1].split('\n  nameserver-policy:')[0];
  assert.match(resolvers, /dns-query#🛡️ 自动容灾/);
  assert.doesNotMatch(resolvers, /system|dhcp|DIRECT/);
  for (const rule of rules) {
    const index = yaml.indexOf(`- '${rule}'`);
    assert.ok(index > 0, `missing ${rule}`);
    assert.ok(index < yaml.indexOf("- 'RULE-SET,loyalsoldier-applications,"));
    const forceTcp = yaml.indexOf("- 'AND,((NETWORK,UDP)");
    if (forceTcp >= 0) assert.ok(index < forceTcp);
  }
  assert.doesNotMatch(yaml, /DOMAIN-SUFFIX,(apple\.com|google\.com|microsoft\.com),DIRECT/);
  fixtures.set(name, yaml);
}

await checkSubscription(clash, '/c', 'all-isps.yaml');
await checkSubscription(clash, '/c?isp=demo', 'single-isp.yaml');
const source = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
const txModules = renderPages(source, {
  TX_DIRECT_ENABLED: 'true', TX_DIRECT_IP: '192.0.2.1',
  TX_DIRECT_TROJAN_PASSWORD: 'fixture-trojan-password-only',
  TX_DIRECT_HYSTERIA_PASSWORD: 'fixture-hysteria-password-only',
  TX_DIRECT_OBFS_PASSWORD: 'fixture-obfs-password-only',
  TROJAN_DOMAIN: 'relay.example', HYSTERIA_DOMAIN: 'relay.example',
  CLASH_RULESET_BASE_URL: 'https://rules.example.test',
});
const tx = await import(`data:text/javascript;base64,${Buffer.from(txModules['tx.js']).toString('base64')}`);
await checkSubscription(tx, '/tx', 'tx.yaml');

const inputs = [
  { label: 'default', filter: {} },
  { label: 'blacklist', filter: { 'fake-ip-filter-mode': 'blacklist', 'fake-ip-filter': ['+.custom.example'] } },
  { label: 'rule', filter: { 'fake-ip-filter-mode': 'rule', 'fake-ip-filter': ['DOMAIN-SUFFIX,apple.com,fake-ip', 'MATCH,fake-ip'] } },
  { label: 'whitelist', filter: { 'fake-ip-filter-mode': 'whitelist', 'fake-ip-filter': ['+.apple.com', '*.example', 'rule-set:original-domains'] } },
];
for (const { label, filter } of inputs) {
  const config = globalMain({
    proxies: [], 'proxy-groups': [],
    'rule-providers': {
      'original-domains': { type: 'inline', behavior: 'domain', payload: ['+.original.example'] },
    },
    dns: {
      enable: true, 'enhanced-mode': 'fake-ip', ...filter,
      nameserver: ['https://1.1.1.1/dns-query'],
      'direct-nameserver': ['https://8.8.8.8/dns-query'],
      'direct-nameserver-follow-policy': false,
      'nameserver-policy': {
        'rule-set:original-domains': ['https://8.8.8.8/dns-query'],
        'captive.apple.com': ['https://8.8.4.4/dns-query'],
        'custom.example': ['192.0.2.53'],
      },
    },
    rules: ['DOMAIN,captive.apple.com,REJECT', 'MATCH,DIRECT'],
  });
  assert.deepEqual(plain(config.rules.slice(0, rules.length)), rules);
  assert.equal(config.dns['direct-nameserver-follow-policy'], true);
  assert.deepEqual(plain(config.dns['direct-nameserver']), ['https://8.8.8.8/dns-query']);
  assert.deepEqual(Object.keys(config.dns['nameserver-policy']).slice(0, localDomains.length), localDomains);
  for (const domain of localDomains) assert.deepEqual(plain(config.dns['nameserver-policy'][domain]), ['system']);
  assert.deepEqual(plain(config.dns['nameserver-policy']['custom.example']), ['192.0.2.53']);
  assert.deepEqual(plain(config.dns.nameserver), ['https://1.1.1.1/dns-query']);
  if (label === 'default' || label === 'blacklist') {
    assert.equal(config.dns['fake-ip-filter-mode'], 'blacklist');
    for (const domain of localDomains) assert.ok(config.dns['fake-ip-filter'].includes(domain));
    if (label === 'blacklist') assert.ok(config.dns['fake-ip-filter'].includes('+.custom.example'));
  } else {
    assert.equal(config.dns['fake-ip-filter-mode'], 'rule');
    assert.equal(config.dns['fake-ip-filter'][0], 'DOMAIN,captive.apple.com,real-ip');
    if (label === 'rule') assert.equal(config.dns['fake-ip-filter'].at(-1), 'MATCH,fake-ip');
    if (label === 'whitelist') {
      assert.equal(config.dns['fake-ip-filter'].at(-1), 'MATCH,real-ip');
      assert.ok(config.dns['fake-ip-filter'].includes('RULE-SET,original-domains,fake-ip'));
      assert.deepEqual(plain(config['rule-providers']['captive-portal-original-fakeip-whitelist'].payload), ['+.apple.com', '*.example']);
    }
  }
  fixtures.set(`extension-${label}.json`, JSON.stringify(config, null, 2));
  const second = globalMain(plain(config));
  assert.deepEqual(plain(second.dns), plain(config.dns), 'reapplying the extension must preserve DNS exceptions');
  for (const rule of rules) assert.equal(second.rules.filter(r => r === rule).length, 1);
}

// Optional real-core check, isolated from the running client and its credentials.
// MIHOMO_DATA_DIR may supply public GeoSite.dat / GeoIP.dat / Country.mmdb caches.
if (process.env.MIHOMO_BIN) {
  const directory = mkdtempSync(join(tmpdir(), 'captive-portal-mihomo-'));
  try {
    for (const name of ['GeoSite.dat', 'GeoIP.dat', 'Country.mmdb']) {
      const cached = process.env.MIHOMO_DATA_DIR && join(process.env.MIHOMO_DATA_DIR, name);
      if (cached && existsSync(cached)) copyFileSync(cached, join(directory, name));
    }
    for (const [name, content] of fixtures) {
      const path = join(directory, name);
      writeFileSync(path, content, { mode: 0o600 });
      const result = spawnSync(process.env.MIHOMO_BIN, ['-t', '-d', directory, '-f', path], {
        encoding: 'utf8', timeout: 45000,
      });
      assert.equal(result.status, 0, `${name}: ${result.error || ''}\n${result.stdout}\n${result.stderr}`);
      console.log(`Mihomo config check passed: ${name}`);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
console.log('Captive portal tests passed: subscription refresh, DNS precedence, Fake-IP modes, extension reapply.');
