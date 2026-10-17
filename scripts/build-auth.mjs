import { readFileSync, writeFileSync, copyFileSync, mkdirSync, rmSync, existsSync, statSync } from 'node:fs';
import { usageSources } from '../subscription-auth/usage.mjs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export function buildAuth(directory, env = process.env) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const enabled = /^(true|1|yes|on)$/i.test(env.SUB_AUTH_ENABLED || 'false');
  // Once protected, never silently fall back to a public deployment after env loss.
  if (!enabled) {
    if (env.SUB_AUTH_ISP_CREDENTIALS_FILE) throw new Error('Private ISP credentials require SUB_AUTH_ENABLED=true');
    if (existsSync(resolve(directory, '.auth-enabled'))) throw new Error('Protected Pages cannot be rebuilt without SUB_AUTH_ENABLED=true');
    return false;
  }
  if (!/^[a-f0-9-]{36}$/.test(env.SUB_AUTH_D1_ID || '')) throw new Error('SUB_AUTH_D1_ID is required to enable login');
  const admins = [...new Set((env.SUB_ADMIN_USERS || '').split(',').map(name => name.trim().toLowerCase()).filter(Boolean))];
  if (!admins.every(name => /^[a-z0-9][a-z0-9_-]{0,31}$/.test(name))) throw new Error('Invalid subscription administrator');
  const catalog = JSON.parse(readFileSync(resolve(directory, 'subscriptions.json'), 'utf8'));
  let globalSource = readFileSync(resolve(directory, 'global-extension.js'), 'utf8');
  if (!globalSource.match(/const ispEntries = JSON\.parse\(atob\("([A-Za-z0-9+/=]+)"\)\)/)) throw new Error('Global extension scope marker missing');
  if (env.SUB_AUTH_ISP_CREDENTIALS_FILE) {
    const file = resolve(env.SUB_AUTH_ISP_CREDENTIALS_FILE);
    if (statSync(file).mode & 0o077) throw new Error('ISP credentials file must be private (0600)');
    const credentials = JSON.parse(readFileSync(file, 'utf8'));
    const ids = catalog.filter(e => e.kind !== 'tx-direct').map(e => e.id).sort();
    if (!credentials || Array.isArray(credentials) || JSON.stringify(Object.keys(credentials).sort()) !== JSON.stringify(ids)) {
      throw new Error('ISP credentials must cover exactly the active ISP IDs');
    }
    const seen = new Set();
    for (const id of ids) {
      const value = credentials[id];
      if (!value || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(['hysteria', 'obfs', 'trojan'])) throw new Error('Invalid ISP credential fields');
      for (const password of Object.values(value)) {
        if (typeof password !== 'string' || !/^[A-Za-z0-9_-]{24,128}$/.test(password) || seen.has(password)) throw new Error('ISP credentials must be strong and distinct');
        seen.add(password);
      }
    }
    const inject = source => {
      const marker = /const (allEntries|ispEntries) = JSON\.parse\(atob\((['"])([A-Za-z0-9+/=]+)\2\)\)/g;
      const matches = [...source.matchAll(marker)];
      if (matches.length !== 1) throw new Error('ISP credentials template marker missing');
      const entries = JSON.parse(Buffer.from(matches[0][3], 'base64').toString('utf8'));
      if (JSON.stringify(entries.map(e => e.id).sort()) !== JSON.stringify(ids)) throw new Error('ISP credentials template IDs differ');
      for (const entry of entries) entry.credentials = credentials[entry.id];
      const encoded = Buffer.from(JSON.stringify(entries)).toString('base64');
      return source.replace(marker, `const $1 = JSON.parse(atob($2${encoded}$2))`);
    };
    // Only Functions and the scoped extension carry credentials. The public
    // catalog remains credential-free, and auth filters the extension per user.
    globalSource = inject(globalSource);
    for (const name of ['v2.js', 'c.js']) {
      const path = resolve(directory, 'functions', name);
      writeFileSync(path, inject(readFileSync(path, 'utf8')), { mode: 0o600 });
    }
  }
  mkdirSync(resolve(directory, 'functions/_private'), { recursive: true });
  mkdirSync(resolve(directory, 'functions'), { recursive: true });
  writeFileSync(resolve(directory, 'functions/_private/catalog.mjs'), `export const catalog = ${JSON.stringify(catalog)};\nexport const globalSource = ${JSON.stringify(globalSource)};\n`, { mode: 0o600 });
  copyFileSync(resolve(root, 'subscription-auth/auth.mjs'), resolve(directory, 'functions/_private/auth.mjs'));
  copyFileSync(resolve(root, 'subscription-auth/usage.mjs'), resolve(directory, 'functions/_private/usage.mjs'));
  copyFileSync(resolve(root, 'subscription-auth/middleware.js'), resolve(directory, 'functions/_middleware.js'));
  for (const [from, to] of [['portal.html', 'index.html'], ['portal.css', 'portal.css'], ['portal.js', 'portal.js']]) {
    copyFileSync(resolve(root, 'subscription-auth', from), resolve(directory, to));
  }
  for (const name of ['subscriptions.json', 'global-extension.js', 'nodes.yaml', '_redirects']) rmSync(resolve(directory, name), { force: true });
  writeFileSync(resolve(directory, '_routes.json'), JSON.stringify({ version: 1, include: ['/*'], exclude: [] }) + '\n');
  // Pages excludes functions/ from static uploads; private modules live there too.
  // Do not rely on Workers-only .assetsignore support to protect credentials.
  writeFileSync(resolve(directory, '.auth-enabled'), '1\n');
  const project = env.CF_PAGES_PROJECT || 'sub-converter';
  if (!/^[a-z0-9-]+$/.test(project)) throw new Error('Invalid Pages project');
  const { sources, active } = usageSources(env);
  const source = sources[0];
  if (!/^[a-z0-9-]{1,40}$/.test(source)) throw new Error('Invalid usage source');
  writeFileSync(resolve(directory, 'wrangler.toml'), `name = "${project}"\ncompatibility_date = "2025-01-01"\npages_build_output_dir = "."\n\n[vars]\nSUB_USAGE_SOURCE = "${source}"\nSUB_USAGE_EXTRA_SOURCES = "${sources.slice(1).join(',')}"\nSUB_USAGE_INACTIVE_SOURCES = "${sources.filter(s => !active.includes(s)).join(',')}"\nSUB_ADMIN_USERS = "${admins.join(',')}"\n\n[[d1_databases]]\nbinding = "SUB_AUTH_DB"\ndatabase_name = "subscription-auth"\ndatabase_id = "${env.SUB_AUTH_D1_ID}"\n`);
  return true;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { buildAuth(resolve(process.argv[2])); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
