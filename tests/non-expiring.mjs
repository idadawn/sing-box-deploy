import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const entry = (id, expires) => ({ id, expires, trojan_port: 443, hysteria_port: 8443 });
const permanent = entry('permanent', 'never');
const dated = entry('dated', '2099-12-31');
const earlier = entry('earlier', '2098-06-01');
const expired = entry('expired', '2000-01-01');
const inventory = [permanent, dated, earlier, expired];
const withEntries = (source, entries) => {
  const encoded = Buffer.from(JSON.stringify(entries)).toString('base64');
  const replaced = source.replace(/JSON\.parse\(atob\((["'])[^"']+\1\)\)/,
    `JSON.parse(atob('${encoded}'))`);
  assert.notEqual(replaced, source, 'fixture must replace the public inventory');
  return replaced;
};

for (const path of process.argv.slice(2, 4)) {
  const source = await readFile(path, 'utf8');
  const load = entries => import(`data:text/javascript;base64,${Buffer.from(withEntries(source, entries)).toString('base64')}`);
  const module = await load(inventory);
  const request = query => module.onRequest({ request: new Request(`https://sub.example/test?raw=1&${query}`) });
  const permanentResponse = await request('isp=permanent');
  assert.equal(permanentResponse.status, 200);
  assert.match(permanentResponse.headers.get('Subscription-Userinfo'), /; expire=0$/);
  assert.match(await permanentResponse.text(), /T-permanent-(TJ|HY2)/);
  const finiteResponse = await request('isp=dated');
  const finiteExpiry = Date.parse('2099-12-31T23:59:59Z') / 1000;
  assert.ok(finiteResponse.headers.get('Subscription-Userinfo').endsWith(`expire=${finiteExpiry}`));
  const mixedResponse = await request('');
  const mixedExpiry = Date.parse('2098-06-01T23:59:59Z') / 1000;
  assert.ok(mixedResponse.headers.get('Subscription-Userinfo').endsWith(`expire=${mixedExpiry}`));
  const body = await mixedResponse.text();
  assert.match(body, /T-permanent-/);
  assert.match(body, /T-dated-/);
  assert.doesNotMatch(body, /T-expired-/);
  assert.equal((await request('isp=expired')).status, 410);
  assert.equal((await request('isp=missing')).status, 410);
  const onlyPermanent = await load([permanent]);
  const response = await onlyPermanent.onRequest({ request: new Request('https://sub.example/test') });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Subscription-Userinfo'), /; expire=0$/);
}

const globalSource = withEntries(await readFile(process.argv[4], 'utf8'), inventory);
const main = vm.runInNewContext(`${globalSource}\nmain`, { atob });
const config = main({ proxies: [], 'proxy-groups': [], rules: [] });
assert.ok(config.proxies.some(proxy => proxy.name === 'T-permanent-TJ'));
assert.ok(config.proxies.some(proxy => proxy.name === 'T-permanent-HY2'));
assert.ok(!config.proxies.some(proxy => proxy.name.startsWith('T-expired-')));

const html = await readFile(new URL('../cloudflare-pages-sub/index.html', import.meta.url), 'utf8');
const helper = html.match(/function expiryText\(entry\) \{[\s\S]*?\n    \}/)[0];
const expiryText = vm.runInNewContext(`${helper}\nexpiryText`);
assert.equal(expiryText(permanent), '有效期不限');
assert.equal(expiryText(dated), '到期 2099-12-31');
assert.equal(expiryText({ kind: 'tx-direct' }), '不受 ISP 到期影响');
console.log('Non-expiring ISP tests passed: headers, mixed expiry, filtering, overlay and display.');
