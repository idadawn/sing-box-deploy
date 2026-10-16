import { readFileSync, writeFileSync, copyFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export function buildAuth(directory, env = process.env) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const enabled = /^(true|1|yes|on)$/i.test(env.SUB_AUTH_ENABLED || 'false');
  // Once protected, never silently fall back to a public deployment after env loss.
  if (!enabled) {
    if (existsSync(resolve(directory, '.auth-enabled'))) throw new Error('Protected Pages cannot be rebuilt without SUB_AUTH_ENABLED=true');
    return false;
  }
  if (!/^[a-f0-9-]{36}$/.test(env.SUB_AUTH_D1_ID || '')) throw new Error('SUB_AUTH_D1_ID is required to enable login');
  const catalog = JSON.parse(readFileSync(resolve(directory, 'subscriptions.json'), 'utf8'));
  const globalSource = readFileSync(resolve(directory, 'global-extension.js'), 'utf8');
  if (!globalSource.match(/const ispEntries = JSON\.parse\(atob\("([A-Za-z0-9+/=]+)"\)\)/)) throw new Error('Global extension scope marker missing');
  mkdirSync(resolve(directory, 'functions/_private'), { recursive: true });
  mkdirSync(resolve(directory, 'functions'), { recursive: true });
  writeFileSync(resolve(directory, 'functions/_private/catalog.mjs'), `export const catalog = ${JSON.stringify(catalog)};\nexport const globalSource = ${JSON.stringify(globalSource)};\n`, { mode: 0o600 });
  copyFileSync(resolve(root, 'subscription-auth/auth.mjs'), resolve(directory, 'functions/_private/auth.mjs'));
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
  writeFileSync(resolve(directory, 'wrangler.toml'), `name = "${project}"\ncompatibility_date = "2025-01-01"\npages_build_output_dir = "."\n\n[[d1_databases]]\nbinding = "SUB_AUTH_DB"\ndatabase_name = "subscription-auth"\ndatabase_id = "${env.SUB_AUTH_D1_ID}"\n`);
  return true;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { buildAuth(resolve(process.argv[2])); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
