import { readFileSync, statSync } from 'node:fs';

export function readAccountCredentials(path, catalog) {
  if (!path) return {};
  if (statSync(path).mode & 0o077) throw Error('Account credentials file must be private (0600)');
  const accounts = JSON.parse(readFileSync(path, 'utf8'));
  const known = new Set(catalog.map(entry => entry.id)), secrets = new Set();
  if (!accounts || Array.isArray(accounts) || !Object.keys(accounts).length || Object.keys(accounts).length > 64) throw Error('Invalid account credentials');
  for (const [name, value] of Object.entries(accounts)) {
    if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(name) || !value || !Array.isArray(value.scopes) ||
        !value.scopes.length || !value.scopes.every(id => known.has(id))) throw Error('Invalid account scope');
    for (const type of ['trojan', 'hysteria']) {
      const secret = value[type];
      if (!/^[A-Za-z0-9_-]{32,128}$/.test(secret || '') || secrets.has(secret)) throw Error('Account credentials must be strong and distinct');
      secrets.add(secret);
    }
  }
  return accounts;
}

export function installAccountTemplates(code) {
  if (code.includes('context.data?.accountCredentials')) return code;
  const marker = /(const allEntries = JSON\.parse\(atob\((['"])[A-Za-z0-9+/=]+\2\)\));/;
  if (!marker.test(code)) throw Error('Account subscription template marker missing');
  return code.replace(marker, '$1.map(entry => context.data?.accountCredentials ? { ...entry, credentials: { ...entry.credentials, ...context.data.accountCredentials } } : entry);')
    .replaceAll('entry.credentials ? encodeURIComponent(entry.credentials.obfs)', 'entry.credentials?.obfs ? encodeURIComponent(entry.credentials.obfs)');
}
