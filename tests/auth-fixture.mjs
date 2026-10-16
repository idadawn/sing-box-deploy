import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildAuth } from '../scripts/build-auth.mjs';
import { renderPages } from '../scripts/tx-direct.mjs';
import { randomToken, passwordHash } from '../subscription-auth/auth.mjs';

// Deliberately fake addresses/passwords. Never reads .env, ISP TSV or live servers.
export const demoPassword = 'preview-only-passphrase';
export async function buildFixture(directory) {
  mkdirSync(resolve(directory, 'functions'), { recursive: true });
  const source = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
  const entries = ['dawn', 'zw', 'gj', 'crj'].map((id, i) => ({ id, host: '192.0.2.' + (i + 1), expires: 'never', trojan_port: 4400 + i, hysteria_port: 5400 + i }));
  const replacements = {
    ISP_PUBLIC_LIST_BASE64_PLACEHOLDER: Buffer.from(JSON.stringify(entries)).toString('base64'),
    AI_ISP_DOMAINS_BASE64_PLACEHOLDER: 'ZXhhbXBsZS5jb20=', DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER: '',
    CLIENT_DIRECT_IP_CIDRS_BASE64_PLACEHOLDER: '', CLASH_FORCE_TCP_DOMAINS_BASE64_PLACEHOLDER: '',
    AI_ISP_DOMAINS_JSON_PLACEHOLDER: '[]', PAYPAL_ISP_DOMAINS_JSON_PLACEHOLDER: '[]',
    DIRECT_BULK_DOMAINS_JSON_PLACEHOLDER: '[]', DIRECT_BULK_APPS_JSON_PLACEHOLDER: '[]',
    CLIENT_DIRECT_IP_CIDRS_JSON_PLACEHOLDER: '[]', CLASH_FORCE_TCP_DOMAINS_JSON_PLACEHOLDER: '[]',
    CLASH_FORCE_TCP_ENABLED_PLACEHOLDER: 'true', DIRECT_BULK_ENABLED_PLACEHOLDER: 'true', HYSTERIA_USE_BBR_PLACEHOLDER: 'true',
    HYSTERIA_UP_PLACEHOLDER: '100', HYSTERIA_DOWN_PLACEHOLDER: '100', CLASH_RULESET_BASE_URL_PLACEHOLDER: 'https://sub.example/rules',
    SECRET_PLACEHOLDER: 'fixture-controller-secret', TROJAN_DOMAIN_PLACEHOLDER: 'relay.example', HYSTERIA_DOMAIN_PLACEHOLDER: 'relay.example',
    TROJAN_PASSWORD_PLACEHOLDER: 'fixture-proxy-password-only', HYSTERIA_PASSWORD_PLACEHOLDER: 'fixture-hy-password-only', HYSTERIA_OBFS_PLACEHOLDER: 'fixture-obfs-only',
  };
  for (const [marker, file] of [['V2JS', 'functions/v2.js'], ['CJS', 'functions/c.js'], ['SRJS', 'functions/sr.js'], ['GLOBALJS', 'global-extension.js']]) {
    let code = source.split(`<<'${marker}'\n`)[1].split(`\n${marker}\n`)[0];
    for (const [key, value] of Object.entries(replacements)) code = code.replaceAll(key, value);
    if (/[A-Z][A-Z0-9_]*_PLACEHOLDER/.test(code)) throw new Error('Unrendered fixture');
    writeFileSync(resolve(directory, file), code);
  }
  for (const [file, code] of Object.entries(renderPages(source, {
    TX_DIRECT_ENABLED: 'true', TX_DIRECT_IP: '198.51.100.10',
    TX_DIRECT_TROJAN_PASSWORD: 'fixture-direct-trojan-password', TX_DIRECT_HYSTERIA_PASSWORD: 'fixture-direct-hy-password', TX_DIRECT_OBFS_PASSWORD: 'fixture-direct-obfs-password',
    TROJAN_DOMAIN: 'relay.example', HYSTERIA_DOMAIN: 'relay.example', CLASH_RULESET_BASE_URL: 'https://sub.example/rules',
  }))) writeFileSync(resolve(directory, 'functions', file), code);
  writeFileSync(resolve(directory, 'subscriptions.json'), JSON.stringify(entries.map(e => ({ ...e, v2: '/v2?isp=' + e.id, clash: '/c?isp=' + e.id })).concat({ id: 'tx', kind: 'tx-direct', host: '198.51.100.10', v2: '/tx-v2', clash: '/tx' })));
  buildAuth(directory, { SUB_AUTH_ENABLED: 'true', SUB_AUTH_D1_ID: '00000000-0000-0000-0000-000000000000' });
  const index = resolve(directory, 'index.html');
  writeFileSync(index, readFileSync(index, 'utf8').replace('个人空间', '测试预览 · 虚构数据'));
  const secret = randomToken();
  writeFileSync(resolve(directory, '.dev.vars'), 'SUB_AUTH_KEY=' + secret + '\n', { mode: 0o600 });
  let sql = readFileSync(new URL('../subscription-auth/schema.sql', import.meta.url), 'utf8');
  for (const entry of entries) {
    const salt = randomToken();
    sql += `\nINSERT INTO users(username, scopes, password_hash, password_salt, token_version, created_at) VALUES ('${entry.id}', '${JSON.stringify([entry.id, 'tx'])}', '${await passwordHash(demoPassword, salt, secret)}', '${salt}', '${randomToken()}', 1);\n`;
  }
  writeFileSync(resolve(directory, 'fixture.sql'), sql, { mode: 0o600 });
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await buildFixture(resolve(process.argv[2]));
