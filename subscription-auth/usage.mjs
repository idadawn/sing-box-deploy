const GB = 1000 ** 3;
const encoder = new TextEncoder();
const reply = (error, status) => Response.json({ error }, { status });
export function usagePeriod(seconds = Date.now() / 1000) {
  const date = new Date(seconds * 1000);
  return { id: date.toISOString().slice(0, 7), start: Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1) / 1000,
    end: Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1) / 1000, timezone: 'UTC' };
}

async function aggregate(db, source, period, meters, quota) {
  const empty = { quota_bytes: quota, upload_bytes: null, download_bytes: null, used_bytes: null, remaining_bytes: null,
    status: 'not_connected', over_quota: false, observed_at: null, started_at: null };
  if (!meters.length) return empty;
  try {
    const placeholders = meters.map(() => '?').join(',');
    const row = await db.prepare(`SELECT COUNT(*) AS n, SUM(upload_bytes) AS up, SUM(download_bytes) AS down,
      MIN(observed_at) AS observed, MAX(started_at) AS started, MAX(has_gap) AS gap
      FROM monthly_usage WHERE source = ? AND period = ? AND meter IN (${placeholders})`)
      .bind(source, period.id, ...meters).first();
    if (!row.n) return empty;
    const used = row.up + row.down;
    const partial = row.n !== meters.length || row.started > period.start || row.gap > 0;
    const stale = row.observed < Math.floor(Date.now() / 1000) - 300;
    const status = stale ? 'stale' : partial ? 'partial' : 'current';
    return { quota_bytes: quota, upload_bytes: row.up, download_bytes: row.down, used_bytes: used,
      remaining_bytes: status === 'current' ? Math.max(0, quota - used) : null, status,
      over_quota: used >= quota, observed_at: row.observed, started_at: row.started };
  } catch { return { ...empty, status: 'unavailable' }; }
}

export async function accountUsage(db, env, allowed) {
  const period = usagePeriod();
  const source = env.SUB_USAGE_SOURCE || 'la';
  const personal = await aggregate(db, source, period, allowed.filter(id => id !== 'tx').map(id => 'isp:' + id), 100 * GB);
  // This is the public NIC total, not personal + direct counters. No double counting.
  const shared = await aggregate(db, source, period, ['machine'], 1000 * GB);
  return { period, mode: 'notify_only', personal, shared };
}

async function bodyText(request) {
  if (!request.headers.get('Content-Type')?.startsWith('application/json') || Number(request.headers.get('Content-Length')) > 16384) return null;
  const reader = request.body?.getReader(); if (!reader) return null;
  const chunks = []; let length = 0;
  while (true) {
    const { value, done } = await reader.read(); if (done) break;
    length += value.length;
    if (length > 16384) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  const joined = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder().decode(joined);
}

export async function ingestUsage(context, catalog) {
  const { env, request } = context;
  if (request.method !== 'POST') return reply('Method not allowed', 405);
  if (!env.SUB_AUTH_DB || !/^[A-Za-z0-9_-]{43,128}$/.test(env.SUB_METER_KEY || '')) return reply('Metering unavailable', 503);
  const timestamp = request.headers.get('X-Meter-Timestamp') || '';
  const signature = request.headers.get('X-Meter-Signature') || '';
  const now = Math.floor(Date.now() / 1000);
  if (!/^\d{10}$/.test(timestamp) || Math.abs(Number(timestamp) - now) > 300 || !/^[a-f0-9]{64}$/.test(signature)) return reply('Unauthorized', 401);
  const raw = await bodyText(request); if (raw === null) return reply('Invalid report', 400);
  const key = await crypto.subtle.importKey('raw', encoder.encode(env.SUB_METER_KEY), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  const signatureBytes = Uint8Array.from(signature.match(/../g), byte => parseInt(byte, 16));
  if (!await crypto.subtle.verify('HMAC', key, signatureBytes, encoder.encode(timestamp + '.' + raw))) return reply('Unauthorized', 401);
  let data; try { data = JSON.parse(raw); } catch { return reply('Invalid report', 400); }
  const integer = n => Number.isSafeInteger(n) && n >= 0;
  if (!data || data.source !== (env.SUB_USAGE_SOURCE || 'la') || !/^[a-f0-9]{32}$/.test(data.generation || '') || !integer(data.sequence) || !integer(data.observed_at) || data.observed_at > now + 60 ||
      !Array.isArray(data.counters) || !data.counters.length || data.counters.length > catalog.length + 1) return reply('Invalid report', 400);
  const period = usagePeriod(data.observed_at);
  if (data.period !== period.id) return reply('Invalid period', 400);
  const allowed = new Set(['machine', ...catalog.filter(e => e.kind !== 'tx-direct').map(e => 'isp:' + e.id)]);
  const seen = new Set();
  const generation = await env.SUB_AUTH_DB.prepare('SELECT generation FROM usage_generations WHERE source=? AND period=?').bind(data.source, period.id).first();
  if (generation && generation.generation !== data.generation) return reply('Collector state changed; restore the original ledger', 409);
  const queries = [env.SUB_AUTH_DB.prepare('INSERT OR IGNORE INTO usage_generations VALUES(?,?,?)').bind(data.source, period.id, data.generation)];
  for (const c of data.counters) {
    if (!c || !allowed.has(c.meter) || seen.has(c.meter) || !integer(c.upload_bytes) || !integer(c.download_bytes) ||
      !integer(c.upload_bytes + c.download_bytes) || !integer(c.observed_at) || c.observed_at > data.observed_at || c.observed_at < period.start ||
      !integer(c.started_at) || c.started_at < period.start || c.started_at > c.observed_at || typeof c.has_gap !== 'boolean') return reply('Invalid counters', 400);
    seen.add(c.meter);
    // Cumulative monthly values: retries and out-of-order delivery cannot add twice
    // or roll totals backwards. Each month has its own independent ledger row.
    queries.push(env.SUB_AUTH_DB.prepare(`INSERT INTO monthly_usage(source, period, meter, upload_bytes, download_bytes, started_at, observed_at, has_gap, sequence)
      SELECT ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS(SELECT 1 FROM usage_generations WHERE source=? AND period=? AND generation=?)
      ON CONFLICT(source, period, meter) DO UPDATE SET
        upload_bytes = MAX(upload_bytes, excluded.upload_bytes), download_bytes = MAX(download_bytes, excluded.download_bytes),
        started_at = MIN(started_at, excluded.started_at), observed_at = MAX(observed_at, excluded.observed_at),
        has_gap = MAX(has_gap, excluded.has_gap), sequence = MAX(sequence, excluded.sequence)`)
      .bind(data.source, period.id, c.meter, c.upload_bytes, c.download_bytes, c.started_at, c.observed_at, Number(c.has_gap), data.sequence, data.source, period.id, data.generation));
  }
  await env.SUB_AUTH_DB.batch(queries);
  const active = await env.SUB_AUTH_DB.prepare('SELECT generation FROM usage_generations WHERE source=? AND period=?').bind(data.source, period.id).first();
  if (active.generation !== data.generation) return reply('Collector state changed; restore the original ledger', 409);
  return Response.json({ ok: true, period: period.id });
}

export function withUsageHeaders(response, usage) {
  const headers = new Headers(response.headers);
  const expiry = /(?:^|;\s*)expire=(\d+)/.exec(headers.get('Subscription-Userinfo') || '')?.[1] || '0';
  if (usage.status === 'current') {
    headers.set('Subscription-Userinfo', `upload=${usage.upload_bytes}; download=${usage.download_bytes}; total=${usage.quota_bytes}; expire=${expiry}`);
  } else {
    // Do not advertise unknown/incomplete measurements as 0 GB used to clients.
    headers.delete('Subscription-Userinfo');
  }
  return new Response(response.body, { status: response.status, headers });
}
