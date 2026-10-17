import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { buildRetired, retiredFetch, ruleFiles } from '../scripts/build-retired.mjs';

const directory = mkdtempSync(resolve(tmpdir(), 'retired-pages-'));
try {
  mkdirSync(resolve(directory, 'functions'));
  mkdirSync(resolve(directory, 'rules'));
  for (const name of ['functions/c.js', 'subscriptions.json', 'nodes.yaml', 'global-extension.js', 'old-backup/secret.json']) {
    mkdirSync(resolve(directory, name, '..'), { recursive: true });
    writeFileSync(resolve(directory, name), 'fixture-private-credential');
  }
  writeFileSync(resolve(directory, 'wrangler.toml'), 'name="old-sub"\npages_build_output_dir="."\n');
  writeFileSync(resolve(directory, '_redirects'), '/private-alias/nodes /nodes.yaml 200\n');
  writeFileSync(resolve(directory, 'rules/apple.txt'), 'DOMAIN,apple.example\n');
  writeFileSync(resolve(directory, 'rules/secret.json'), 'fixture-private-credential');
  const env = { SUB_LEGACY_RETIRED: 'true', SUB_DOMAIN: 'old.example', SUB_PORTAL_REDIRECT_URL: 'https://new.example', CF_PAGES_PROJECT: 'old-sub' };
  assert.equal(buildRetired(directory, {}), false);
  assert.throws(() => buildRetired(directory, { ...env, SUB_AUTH_ENABLED: 'true' }), /authenticated/);
  assert.throws(() => buildRetired(directory, { ...env, SUB_PORTAL_REDIRECT_URL: 'https://old.example' }), /separate/);
  assert.ok(existsSync(resolve(directory, 'functions/c.js')), 'Safety refusal must not mutate assets');
  assert.equal(buildRetired(directory, env), true);
  for (const name of ['functions', 'subscriptions.json', 'nodes.yaml', 'global-extension.js', '_redirects', 'old-backup', 'rules/secret.json']) assert.equal(existsSync(resolve(directory, name)), false);
  assert.equal(readFileSync(resolve(directory, 'rules/apple.txt'), 'utf8'), 'DOMAIN,apple.example\n');
  assert.equal(buildRetired(directory, { SUB_DOMAIN: 'old.example', CF_PAGES_PROJECT: 'old-sub' }), true, 'Persistent marker keeps retirement even after env loss');
  const worker = readFileSync(resolve(directory, '_worker.js'), 'utf8');
  assert.ok(!worker.includes('fixture-private-credential'));
  let assetReads = 0;
  const bindings = { ASSETS: { fetch: () => { assetReads++; return new Response('safe-rule'); } } };
  for (const path of ['/c', '/v2?raw=1', '/s?isp=dawn', '/tx', '/tx-v2', '/sr', '/subscriptions.json', '/global-extension.js', '/nodes.yaml', '/private-alias/nodes', '/functions/c.js', '/rules/secret.json', '/rules/apple.txt/']) {
    const response = await retiredFetch(new Request('https://old.example' + path), bindings, 'https://new.example/', ruleFiles);
    assert.equal(response.status, 410, path); assert.ok((await response.text()).includes('新版专属订阅'));
  }
  assert.equal(assetReads, 0, 'No sensitive path reaches static assets');
  assert.equal((await retiredFetch(new Request('https://old.example/rules/apple.txt'), bindings, 'https://new.example/', ruleFiles)).status, 200);
  assert.equal(assetReads, 1);
  const redirect = await retiredFetch(new Request('https://old.example/?token=private'), bindings, 'https://new.example/', ruleFiles);
  assert.equal(redirect.status, 302); assert.equal(redirect.headers.get('Location'), 'https://new.example/');
  const head = await retiredFetch(new Request('https://old.example/c', { method: 'HEAD' }), bindings, 'https://new.example/', ruleFiles);
  assert.equal(head.status, 410); assert.equal(await head.text(), '');
  console.log('Retired site: credential removal, sticky closure, private-path denial and rule continuity passed.');
} finally { rmSync(directory, { recursive: true, force: true }); }
