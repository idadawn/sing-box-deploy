import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const entries = [
  { id: 'pilot', expires: 'never', trojan_port: 64689, hysteria_port: 64690,
    ingress: { server: 'new.example.com', sni: 'cert.example.com' } },
  { id: 'unchanged', expires: 'never', trojan_port: 443, hysteria_port: 8443 },
];
const inject = source => source.replace(/JSON\.parse\(atob\((["'])[^"']+\1\)\)/,
  `JSON.parse(atob('${Buffer.from(JSON.stringify(entries)).toString('base64')}'))`);
const sources = await Promise.all(process.argv.slice(2, 5).map(path => readFile(path, 'utf8')));
const load = source => import(`data:text/javascript;base64,${Buffer.from(inject(source)).toString('base64')}`);
const v2 = await load(sources[0]);
const response = await v2.onRequest({ request: new Request('https://sub.example/v2?raw=1') });
const uris = (await response.text()).trim().split('\n').map(line => new URL(line));
for (const uri of uris) {
  const pilot = uri.hash.includes('PILOT');
  assert.equal(uri.hostname, pilot ? 'new.example.com' : 'test');
  assert.equal(uri.searchParams.get('sni'), pilot ? 'cert.example.com' : uri.hostname);
  if (pilot) assert.equal(uri.port, uri.protocol === 'trojan:' ? '64689' : '64690');
  assert.ok(uri.username, 'migration must preserve authentication');
}
const clash = await load(sources[1]);
const yaml = await (await clash.onRequest({ request: new Request('https://sub.example/c?isp=pilot') })).text();
assert.equal((yaml.match(/server: new\.example\.com/g) || []).length, 2);
assert.equal((yaml.match(/sni: cert\.example\.com/g) || []).length, 2);
assert.equal((yaml.match(/skip-cert-verify: false/g) || []).length, 2);
assert.doesNotMatch(yaml, /name: "UNCHANGED-/);
const main = vm.runInNewContext(`${inject(sources[2])}\nmain`, { atob });
const overlay = main({ proxies: [], 'proxy-groups': [], rules: [] });
assert.equal(overlay.proxies.length, 4);
for (const p of overlay.proxies) {
  const pilot = p.name.startsWith('PILOT-');
  assert.equal(p.server, pilot ? 'new.example.com' : 'test');
  assert.equal(p.sni, pilot ? 'cert.example.com' : p.server);
  assert.equal(p['skip-cert-verify'], false);
}
console.log('Ingress overrides: pilot changes only its server/SNI across all subscription formats.');
