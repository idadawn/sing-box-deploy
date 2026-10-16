const encoder = new TextEncoder();
const COOKIE = '__Host-sub-session';
const SESSION_AGE = 7 * 86400;
const ITERATIONS = 100000; // Workers WebCrypto's supported per-call PBKDF2 limit.
const USERNAME = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const TOKEN_PART = /^[A-Za-z0-9_-]{43}$/;
const bytes = text => encoder.encode(text);
const b64 = data => btoa(String.fromCharCode(...new Uint8Array(data))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
const unb64 = text => Uint8Array.from(atob(text.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - text.length % 4) % 4)), c => c.charCodeAt(0));
export const randomToken = () => b64(crypto.getRandomValues(new Uint8Array(32)));
export const digest = async text => b64(await crypto.subtle.digest('SHA-256', bytes(text)));
const now = () => Math.floor(Date.now() / 1000);
const json = (data, status = 200, headers = {}) => Response.json(data, { status, headers });
const error = (message, status) => json({ error: message }, status);

async function hmacKey(secret) {
  return crypto.subtle.importKey('raw', bytes(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
async function sign(secret, value) {
  return b64(await crypto.subtle.sign('HMAC', await hmacKey(secret), bytes(value)));
}
export async function passwordHash(password, salt, secret) {
  // A separate server-side pepper protects a database-only disclosure.
  const peppered = await sign(secret, 'password:' + password);
  const key = await crypto.subtle.importKey('raw', bytes(peppered), 'PBKDF2', false, ['deriveBits']);
  return b64(await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: unb64(salt), iterations: ITERATIONS, hash: 'SHA-256' }, key, 256));
}
function equal(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
export async function subscriptionToken(user, secret) {
  const payload = `${user.username}.${user.token_version}`;
  return `${payload}.${await sign(secret, 'subscription:' + payload)}`;
}
function scopes(user) {
  const ids = JSON.parse(user.scopes);
  if (!Array.isArray(ids) || !ids.every(id => typeof id === 'string' && USERNAME.test(id))) throw new Error('Invalid account scope');
  return ids;
}
async function getUser(db, username) {
  return db.prepare('SELECT * FROM users WHERE username = ? AND enabled = 1').bind(username).first();
}
async function sessionUser(request, db) {
  const values = (request.headers.get('Cookie') || '').split(';').map(v => v.trim()).filter(v => v.startsWith(COOKIE + '='));
  if (values.length !== 1) return null;
  const token = values[0].slice(COOKIE.length + 1);
  if (!TOKEN_PART.test(token)) return null;
  return db.prepare('SELECT users.* FROM sessions JOIN users USING(username) WHERE sessions.hash = ? AND sessions.expires > ? AND users.enabled = 1')
    .bind(await digest(token), now()).first();
}
async function tokenUser(token, db, secret) {
  const parts = token.split('.');
  if (parts.length !== 3 || !USERNAME.test(parts[0]) || !TOKEN_PART.test(parts[1]) || !TOKEN_PART.test(parts[2])) return null;
  const valid = await crypto.subtle.verify('HMAC', await hmacKey(secret), unb64(parts[2]), bytes('subscription:' + parts.slice(0, 2).join('.')));
  if (!valid) return null;
  const user = await getUser(db, parts[0]);
  return user?.password_hash && equal(user.token_version, parts[1]) ? user : null;
}
async function limited(db, key, maximum) {
  const bucket = Math.floor(now() / 900);
  const row = await db.prepare('INSERT INTO throttles(key, bucket, count) VALUES (?, ?, 1) ON CONFLICT(key) DO UPDATE SET count = CASE WHEN bucket = excluded.bucket THEN count + 1 ELSE 1 END, bucket = excluded.bucket RETURNING count')
    .bind(await digest(key), bucket).first();
  return row.count > maximum;
}
async function readBody(request) {
  if (!request.headers.get('Content-Type')?.startsWith('application/json')) return null;
  if (Number(request.headers.get('Content-Length')) > 4096) return null;
  const reader = request.body?.getReader();
  if (!reader) return null;
  const chunks = []; let length = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    length += value.length;
    if (length > 4096) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  try {
    const joined = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.length; }
    const value = JSON.parse(new TextDecoder().decode(joined));
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch { return null; }
}
function cookie(token, age = SESSION_AGE) {
  return `${COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${age}`;
}
async function newSession(db, username) {
  const token = randomToken();
  await db.batch([
    db.prepare('DELETE FROM sessions WHERE expires <= ?').bind(now()),
    db.prepare('DELETE FROM throttles WHERE bucket < ?').bind(Math.floor(now() / 900) - 1),
    db.prepare('INSERT INTO sessions(hash, username, expires) VALUES (?, ?, ?)').bind(await digest(token), username, now() + SESSION_AGE),
  ]);
  return json({ ok: true }, 200, { 'Set-Cookie': cookie(token) });
}
function validPassword(password) { return typeof password === 'string' && password.length >= 12 && password.length <= 128; }

async function api(context, path, secret) {
  const { request, env } = context, db = env.SUB_AUTH_DB;
  if (request.method !== 'POST') return error('Method not allowed', 405);
  if (request.headers.get('Origin') !== new URL(request.url).origin) return error('请求来源不正确', 403);
  if (await limited(db, 'ip:' + (request.headers.get('CF-Connecting-IP') || 'local'), 30)) return error('尝试过于频繁，请 15 分钟后重试', 429);
  const body = await readBody(request);
  if (!body) return error('请求格式不正确', 400);

  if (path === '/api/login') {
    const username = typeof body.username === 'string' ? body.username.trim().toLowerCase() : '';
    if (!USERNAME.test(username) || !validPassword(body.password)) return error('账号或密码不正确', 401);
    if (await limited(db, 'user:' + username, 50)) return error('尝试过于频繁，请 15 分钟后重试', 429);
    const user = await getUser(db, username);
    const hash = await passwordHash(body.password, user?.password_salt || b64(new Uint8Array(32)), secret);
    if (!user?.password_hash || !equal(hash, user.password_hash)) return error('账号或密码不正确', 401);
    return newSession(db, username);
  }
  if (path === '/api/activate') {
    if (!TOKEN_PART.test(body.invite || '') || !validPassword(body.password)) return error('请使用有效邀请，并设置 12–128 位密码', 400);
    const inviteHash = await digest(body.invite);
    const user = await db.prepare('SELECT username FROM users WHERE invite_hash = ? AND invite_expires > ? AND enabled = 1').bind(inviteHash, now()).first();
    if (!user) return error('邀请无效或已过期', 401);
    const salt = randomToken(), hash = await passwordHash(body.password, salt, secret);
    const result = await db.prepare('UPDATE users SET password_hash = ?, password_salt = ?, invite_hash = NULL, invite_expires = NULL WHERE username = ? AND invite_hash = ? AND invite_expires > ?')
      .bind(hash, salt, user.username, inviteHash, now()).run();
    if (result.meta.changes !== 1) return error('邀请无效或已过期', 401);
    return newSession(db, user.username);
  }
  const user = await sessionUser(request, db);
  if (!user) return error('请先登录', 401);
  if (path === '/api/logout') {
    const token = (request.headers.get('Cookie') || '').split(';').map(v => v.trim()).find(v => v.startsWith(COOKIE + '='))?.slice(COOKIE.length + 1);
    await db.prepare('DELETE FROM sessions WHERE hash = ?').bind(await digest(token)).run();
    return json({ ok: true }, 200, { 'Set-Cookie': cookie('', 0) });
  }
  if (path === '/api/rotate-token') {
    await db.prepare('UPDATE users SET token_version = ? WHERE username = ?').bind(randomToken(), user.username).run();
    return json({ ok: true });
  }
  if (path === '/api/password') {
    if (!validPassword(body.password) || typeof body.currentPassword !== 'string' || body.currentPassword.length > 128) return error('请输入原密码及 12–128 位新密码', 400);
    if (!equal(await passwordHash(body.currentPassword, user.password_salt, secret), user.password_hash)) return error('原密码不正确', 401);
    const salt = randomToken(), hash = await passwordHash(body.password, salt, secret);
    // Invalidate all browser sessions. Subscription links have a separate explicit reset.
    await db.batch([
      db.prepare('UPDATE users SET password_hash = ?, password_salt = ? WHERE username = ?').bind(hash, salt, user.username),
      db.prepare('DELETE FROM sessions WHERE username = ?').bind(user.username),
    ]);
    return json({ ok: true }, 200, { 'Set-Cookie': cookie('', 0) });
  }
  return error('Not found', 404);
}

function secure(response) {
  const headers = new Headers(response.headers);
  for (const name of ['Access-Control-Allow-Origin', 'Access-Control-Allow-Credentials', 'ETag', 'Last-Modified']) headers.delete(name);
  headers.set('Cache-Control', 'private, no-store, max-age=0');
  headers.set('Vary', 'Cookie, Authorization');
  headers.set('Referrer-Policy', 'no-referrer');
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('X-Frame-Options', 'DENY');
  headers.set('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'");
  return new Response(response.body, { status: response.status, headers });
}

export function createHandler({ catalog, globalSource, handlers }) {
  const routes = new Set(['/v2', '/c', '/s', '/global-extension.js', '/tx', '/tx-v2']);
  async function handle(context) {
    const { request, env } = context;
    const url = new URL(request.url), path = url.pathname;
    // Explicit public allowlist; never pass arbitrary generated files to ASSETS.
    if (request.method === 'GET' || request.method === 'HEAD') {
      if (['/', '/index.html', '/portal.js', '/portal.css'].includes(path)) return context.next();
      if (/^\/rules\/[a-z0-9-]+\.(txt|list|json)$/.test(path) || path === '/sr') return context.next();
    }
    if (!routes.has(path) && !['/api/me', '/subscriptions.json', '/api/login', '/api/activate', '/api/logout', '/api/password', '/api/rotate-token'].includes(path)) return error('Not found', 404);
    if (!env.SUB_AUTH_DB || typeof env.SUB_AUTH_KEY !== 'string' || env.SUB_AUTH_KEY.length < 43) return error('登录服务暂不可用', 503);
    if (path.startsWith('/api/') && path !== '/api/me') return api(context, path, env.SUB_AUTH_KEY);
    if (!['GET', 'HEAD'].includes(request.method)) return error('Method not allowed', 405);
    const tokens = url.searchParams.getAll('token');
    const bearer = request.headers.get('Authorization');
    if (tokens.length > 1 || (tokens.length && bearer) || (bearer && !bearer.startsWith('Bearer '))) return error('无效的订阅令牌', 401);
    const token = tokens[0] || (bearer ? bearer.slice(7) : null);
    const user = token
      ? (routes.has(path) ? await tokenUser(token, env.SUB_AUTH_DB, env.SUB_AUTH_KEY) : null)
      : await sessionUser(request, env.SUB_AUTH_DB);
    if (!user) return error('请先登录或使用专属订阅链接', 401);
    const allowed = scopes(user);
    if (path === '/api/me' || path === '/subscriptions.json') {
      const personalToken = await subscriptionToken(user, env.SUB_AUTH_KEY);
      const entries = catalog.filter(entry => allowed.includes(entry.id)).map(entry => {
        const result = { ...entry };
        for (const key of ['v2', 'clash', 'shadowrocket']) {
          if (result[key]) { const link = new URL(result[key], url.origin); link.searchParams.set('token', personalToken); result[key] = link.pathname + link.search; }
        }
        if (entry.kind !== 'tx-direct') result.extension = '/s?isp=' + encodeURIComponent(entry.id) + '&token=' + encodeURIComponent(personalToken);
        return result;
      });
      return json(path === '/api/me' ? { username: user.username, entries } : entries);
    }
    const requested = url.searchParams.getAll('isp');
    if (requested.length > 1 || requested.some(id => !allowed.includes(id))) return error('没有这条线路的访问权限', 403);
    const direct = path === '/tx' || path === '/tx-v2';
    if (direct && !allowed.includes('tx')) return error('没有这条线路的访问权限', 403);
    const permitted = allowed.filter(id => direct ? id === 'tx' : id !== 'tx');
    if (!permitted.length) return error('没有这条线路的访问权限', 403);
    if (path === '/s' || path === '/global-extension.js') {
      const match = globalSource.match(/const ispEntries = JSON\.parse\(atob\("([A-Za-z0-9+/=]+)"\)\)/);
      if (!match) throw new Error('Invalid global extension template');
      const entries = JSON.parse(atob(match[1])).filter(entry => permitted.includes(entry.id) && (!requested[0] || entry.id === requested[0]));
      if (!entries.length) return error('线路不可用', 410);
      const source = globalSource.replace(match[0], 'const ispEntries = ' + JSON.stringify(entries));
      return new Response(source, { headers: { 'Content-Type': 'application/javascript; charset=utf-8' } });
    }
    return handlers[path]({ ...context, data: { ...context.data, allowedIsps: permitted } });
  }
  return async context => {
    try {
      const response = await handle(context);
      const safe = secure(response);
      return context.request.method === 'HEAD' ? new Response(null, { status: safe.status, headers: safe.headers }) : safe;
    } catch {
      // No exception, database contents, request URL or credentials in public responses/logs.
      return secure(error('服务暂不可用，请稍后重试', 503));
    }
  };
}
