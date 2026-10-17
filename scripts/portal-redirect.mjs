import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Only replace the web entrance. Legacy subscription routes remain byte-for-byte.
export function applyPortalRedirect(directory, env = process.env) {
  const path = resolve(directory, '_redirects');
  const previous = readFileSync(path, 'utf8');
  const existing = previous.replace(/^# Portal entrance begin\n[\s\S]*?^# Portal entrance end\n/m, '');
  let managed = '';
  if (env.SUB_PORTAL_REDIRECT_URL) {
    const target = new URL(env.SUB_PORTAL_REDIRECT_URL);
    if (target.protocol !== 'https:' || target.username || target.password || target.search || target.hash || target.pathname !== '/') {
      throw new Error('Portal target must be an HTTPS origin without credentials, query or path');
    }
    if (target.origin === `https://${env.SUB_DOMAIN}` || /^(true|1|yes|on)$/i.test(env.SUB_AUTH_ENABLED || 'false')) {
      throw new Error('Cannot redirect an authenticated portal or redirect back to the same site');
    }
    managed = `# Portal entrance begin\n/ ${target.origin}/ 302\n/index.html ${target.origin}/ 302\n# Portal entrance end\n`;
  }
  const next = managed + existing;
  if (next !== previous) writeFileSync(path, next, { mode: 0o600 });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { applyPortalRedirect(resolve(process.argv[2])); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
