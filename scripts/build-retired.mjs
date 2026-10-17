import { existsSync, readFileSync, writeFileSync, readdirSync, rmSync, lstatSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ruleFiles = ['applications.txt', 'cncidr.txt', 'private.txt', 'lancidr.txt', 'apple.txt',
  'telegramcidr.txt', 'direct.txt', 'proxy.txt', 'icloud.txt', 'reject.txt', 'shadowrocket-telegram.list', 'metadata.json'];
const enabled = value => /^(true|1|yes|on)$/i.test(value || 'false');

export async function retiredFetch(request, env, target, files) {
  const url = new URL(request.url);
  const safe = request.method === 'GET' || request.method === 'HEAD';
  if (safe && (url.pathname === '/' || url.pathname === '/index.html')) {
    return new Response(null, { status: 302, headers: { Location: target, 'Cache-Control': 'no-store' } });
  }
  if (safe && files.some(file => url.pathname === '/rules/' + file)) return env.ASSETS.fetch(request);
  const body = '旧订阅链接已停用。请登录 ' + target + ' 获取新版专属订阅。\n';
  return new Response(request.method === 'HEAD' ? null : body, { status: 410, headers: {
    'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'X-Robots-Tag': 'noindex',
  } });
}

export function buildRetired(directory, env = process.env) {
  const marker = resolve(directory, '.subscriptions-retired');
  const previous = existsSync(marker) ? JSON.parse(readFileSync(marker, 'utf8')) : null;
  if (!enabled(env.SUB_LEGACY_RETIRED) && !previous) return false;
  if (enabled(env.SUB_AUTH_ENABLED) || existsSync(resolve(directory, '.auth-enabled'))) throw new Error('Refusing to retire an authenticated portal');
  if (!existsSync(resolve(directory, 'wrangler.toml'))) throw new Error('Expected an existing Pages output directory');
  const target = new URL(env.SUB_PORTAL_REDIRECT_URL || previous?.target || '');
  if (target.protocol !== 'https:' || target.username || target.password || target.search || target.hash || target.pathname !== '/' || target.hostname === env.SUB_DOMAIN) {
    throw new Error('Expected a separate HTTPS login portal origin');
  }
  const project = env.CF_PAGES_PROJECT || 'sub-converter';
  if (!/^[a-z0-9-]+$/.test(project)) throw new Error('Invalid Pages project');
  // Strip all generated credentials, hidden aliases and Functions. A static
  // fallback must be safe even if the Worker does not run. No wildcard pass-through.
  const origin = target.origin + '/';
  // Persist the guard before cleanup, and never delete it during a rebuild.
  writeFileSync(marker, JSON.stringify({ target: origin, retired: true }) + '\n', { mode: 0o600 });
  const keep = new Set(['rules', 'package.json', 'package-lock.json', 'README.md', '.subscriptions-retired']);
  for (const name of readdirSync(directory)) {
    const path = resolve(directory, name);
    if (!keep.has(name) || lstatSync(path).isSymbolicLink()) rmSync(path, { recursive: true, force: true });
  }
  const rules = resolve(directory, 'rules');
  if (existsSync(rules)) for (const name of readdirSync(rules)) {
    const path = resolve(rules, name);
    if (!ruleFiles.includes(name) || !lstatSync(path).isFile()) rmSync(path, { recursive: true, force: true });
  }
  writeFileSync(resolve(directory, '_worker.js'), `${retiredFetch.toString()}\nexport default { fetch(request, env) { return retiredFetch(request, env, ${JSON.stringify(origin)}, ${JSON.stringify(ruleFiles)}); } };\n`);
  writeFileSync(resolve(directory, '_routes.json'), JSON.stringify({ version: 1, include: ['/*'], exclude: [] }) + '\n');
  writeFileSync(resolve(directory, 'index.html'), `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="robots" content="noindex"><title>自由翱翔</title><p>旧订阅已停用，请前往 <a href="${origin}">新版登录入口</a>。</p></html>\n`);
  writeFileSync(resolve(directory, 'wrangler.toml'), `name = "${project}"\ncompatibility_date = "2025-01-01"\npages_build_output_dir = "."\n`);
  return true;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { buildRetired(resolve(process.argv[2])); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
