import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import { accountUsage, ingestUsage, usagePeriod, withUsageHeaders, billingOverview } from '../subscription-auth/usage.mjs';

const sql = new DatabaseSync(':memory:');
sql.exec(readFileSync(new URL('../subscription-auth/schema.sql', import.meta.url), 'utf8'));
const db = {
  prepare(text) {
    const statement = sql.prepare(text); let values = [];
    const query = { bind(...args) { values = args; return query; }, async first() { return statement.get(...values); },
      async run() { return { meta: { changes: Number(statement.run(...values).changes) } }; } };
    return query;
  },
  async batch(queries) {
    sql.exec('BEGIN');
    try { for (const query of queries) await query.run(); sql.exec('COMMIT'); }
    catch (error) { sql.exec('ROLLBACK'); throw error; }
  },
};
const key = 'fixture-meter-key-not-a-production-secret-123456789';
const env = { SUB_AUTH_DB: db, SUB_METER_KEY: key };
const catalog = [{ id: 'dawn' }, { id: 'zw' }, { id: 'tx', kind: 'tx-direct' }];
const now = Math.floor(Date.now() / 1000), period = usagePeriod(now);
const GB = 1024 ** 3;
function payload(sequence, counters) { return { source: 'la', generation: '0123456789abcdef0123456789abcdef', sequence, observed_at: now, period: period.id, counters }; }
function counter(meter, up, down, extra = {}) { return { meter, upload_bytes: up, download_bytes: down, started_at: period.start, observed_at: now, has_gap: false, ...extra }; }
async function send(data, { secret = key, timestamp = now } = {}) {
  const body = JSON.stringify(data), signature = createHmac('sha256', secret).update(timestamp + '.' + body).digest('hex');
  return ingestUsage({ env, request: new Request('https://sub.example/api/usage/report', { method: 'POST', body,
    headers: { 'Content-Type': 'application/json', 'X-Meter-Timestamp': String(timestamp), 'X-Meter-Signature': signature } }) }, catalog);
}
assert.equal(usagePeriod(Date.parse('2026-10-31T23:59:59Z') / 1000).id, '2026-10');
assert.equal(usagePeriod(Date.parse('2026-11-01T00:00:00Z') / 1000).id, '2026-11');
let usage = await accountUsage(db, env, ['dawn', 'tx']);
assert.equal(usage.personal.used_bytes, 0); assert.equal(usage.shared.used_bytes, 0);
assert.equal(usage.personal.status, 'initialized'); assert.equal(usage.personal.remaining_bytes, 100 * GB);
assert.equal(usage.personal.quota_bytes, 100 * GB); assert.equal(usage.shared.quota_bytes, 1000 * GB);
assert.equal(withUsageHeaders(new Response('', { headers: { 'Subscription-Userinfo': 'upload=0; download=0; total=0; expire=0' } }), usage.personal).headers.get('Subscription-Userinfo'), 'upload=0; download=0; total=107374182400; expire=0');
const initial = payload(1, [counter('machine', 10 * GB, 20 * GB), counter('isp:dawn', GB, 2 * GB), counter('isp:zw', 4 * GB, 5 * GB)]);
assert.equal((await send(initial)).status, 200);
assert.equal((await send(initial)).status, 200, 'Retry is idempotent');
assert.equal((await send({ ...initial, generation: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' })).status, 409, 'Lost local state must not silently restart accounting');
usage = await accountUsage(db, env, ['dawn', 'tx']);
assert.equal(usage.personal.used_bytes, 3 * GB);
assert.equal(usage.shared.used_bytes, 30 * GB, 'Machine pool must not add personal bytes a second time');
assert.equal(usage.shared.remaining_bytes, 970 * GB);
assert.equal(usage.mode, 'notify_only');
assert.ok(!JSON.stringify(usage).includes('zw'));
assert.equal((await accountUsage(db, env, ['zw'])).personal.used_bytes, 9 * GB);
const header = withUsageHeaders(new Response('', { headers: { 'Subscription-Userinfo': 'expire=0' } }), usage.personal).headers.get('Subscription-Userinfo');
assert.equal(header, 'upload=1073741824; download=2147483648; total=107374182400; expire=0');
assert.equal((await send(payload(0, [counter('machine', 1, 1)]))).status, 200);
assert.equal((await accountUsage(db, env, ['dawn'])).shared.used_bytes, 30 * GB, 'Out-of-order reports cannot roll back totals');
assert.equal((await send(payload(2, [counter('machine', 99 * GB, 99 * GB)]), { secret: 'wrong' })).status, 401);
assert.equal((await send(initial, { timestamp: now - 301 })).status, 401);
assert.equal((await send(payload(2, [counter('machine', 99 * GB, 99 * GB), counter('isp:unknown', 1, 1)]))).status, 400);
assert.equal((await accountUsage(db, env, ['dawn'])).shared.used_bytes, 30 * GB, 'Invalid batch is atomic');
assert.equal((await send(payload(3, [counter('isp:dawn', 1, -1)]))).status, 400);
assert.equal((await send(payload(3, [counter('isp:dawn', 1, 1), counter('isp:dawn', 1, 1)]))).status, 400);
assert.equal((await send({ ...initial, source: 'another-server' })).status, 400);
assert.equal((await send({ ...initial, period: '1999-01' })).status, 400);
assert.equal((await send(payload(4, [counter('isp:dawn', 80 * GB, 30 * GB), counter('machine', 500 * GB, 600 * GB)]))).status, 200);
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.personal.over_quota, true); assert.equal(usage.shared.over_quota, true);
assert.equal(usage.personal.remaining_bytes, 0);
await send(payload(5, [counter('isp:dawn', 80 * GB, 30 * GB, { has_gap: true })]));
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.personal.status, 'partial'); assert.equal(usage.personal.remaining_bytes, 0);
assert.match(withUsageHeaders(new Response(''), usage.personal).headers.get('Subscription-Userinfo'), /upload=85899345920; download=32212254720; total=107374182400;/);
const partialResponse = withUsageHeaders(new Response('', { headers: { 'Subscription-Userinfo': 'expire=0' } }), usage.personal,
  { homepage: 'https://sub.example/' });
assert.equal(partialResponse.headers.get('Subscription-Userinfo'), 'upload=85899345920; download=32212254720; total=107374182400; expire=0');
assert.equal(partialResponse.headers.get('X-Subscription-Usage-Status'), 'partial');
assert.equal(partialResponse.headers.get('X-Subscription-Usage-Started-At'), String(period.start));
assert.equal(partialResponse.headers.get('Profile-Web-Page-URL'), 'https://sub.example/');
assert.equal(usage.personal.remaining_bytes, 0, 'Remaining quota follows recorded monthly usage');
assert.ok(withUsageHeaders(new Response(''), { ...usage.personal, status: 'stale' }).headers.get('Subscription-Userinfo'), 'Stale values remain visible with their original update timestamp');
for (const bad of [
  { ...usage.personal, status: 'unavailable', upload_bytes: null },
  { ...usage.personal, download_bytes: null }, { ...usage.personal, upload_bytes: -1 },
]) {
  const response = withUsageHeaders(new Response('', { headers: { 'Subscription-Userinfo': 'upload=0; total=1' } }), bad);
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('Subscription-Userinfo'), null);
}
assert.equal(withUsageHeaders(new Response('', { status: 410 }), usage.personal).headers.get('Subscription-Userinfo'), null);

sql.prepare('UPDATE monthly_usage SET observed_at=? WHERE meter=?').run(now - 600, 'isp:dawn');
assert.equal((await accountUsage(db, env, ['dawn'])).personal.status, 'stale');
sql.prepare('UPDATE monthly_usage SET period=?').run('1999-01');
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.personal.used_bytes, 0); assert.equal(usage.shared.used_bytes, 0, 'Previous UTC months do not consume this month');
assert.equal(usage.personal.remaining_bytes, 100 * GB);
assert.equal(usage.personal.status, 'initialized');
assert.equal((await accountUsage({ prepare() { throw new Error('Database unavailable'); } }, env, ['dawn'])).personal.used_bytes, null, 'Database faults must not masquerade as a fresh zero');
// New and draining hosts have independent cumulative ledgers. Sum them once.
env.SUB_USAGE_EXTRA_SOURCES = 'dmit,la,dmit';
assert.equal((await send({ ...initial, source: 'dmit', generation: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' })).status, 200);
assert.equal((await send({ ...initial, source: 'dmit', generation: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' })).status, 200);
assert.equal((await send(initial)).status, 200);
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.personal.used_bytes, 6 * GB);
assert.equal(usage.shared.used_bytes, 60 * GB);
assert.equal(usage.personal.quota_bytes, 100 * GB, 'Parallel hosts do not multiply quota');
assert.equal((await send({ ...initial, source: 'dmit' })).status, 409, 'Each source independently guards generation');
sql.prepare('UPDATE monthly_usage SET observed_at=? WHERE source=? AND period=?').run(now - 600, 'la', period.id);
assert.equal((await accountUsage(db, env, ['dawn'])).personal.status, 'stale');
env.SUB_USAGE_INACTIVE_SOURCES = 'la';
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.personal.used_bytes, 6 * GB, 'Drained source remains in historical totals');
assert.equal(usage.personal.status, 'current');
env.SUB_USAGE_EXTRA_SOURCES += ',next';
assert.equal((await accountUsage(db, env, ['dawn'])).personal.status, 'partial', 'Missing active host must not look complete');
env.SUB_USAGE_INACTIVE_SOURCES = 'unknown';
assert.equal((await send(initial)).status, 503);
assert.equal((await accountUsage(db, env, ['dawn'])).personal.status, 'unavailable');

// The provider bill must never reset with the personal calendar month.
env.SUB_USAGE_EXTRA_SOURCES = 'dmit'; env.SUB_USAGE_INACTIVE_SOURCES = '';
env.SUB_KIWIVM_VEID = '123';
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.shared.used_bytes, null);
assert.equal(usage.shared.remaining_bytes, null);
assert.equal(withUsageHeaders(new Response(''), usage.shared).status, 503);
const provider = { name: 'kiwivm', service_id: '123', used_bytes: 969 * GB,
  quota_bytes: 1000 * GB, reset_at: now + 3 * 86400, observed_at: now };
const providerReport = { ...initial, provider };
assert.equal((await send(providerReport)).status, 200);
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.shared.used_bytes, 969 * GB);
assert.equal(usage.shared.remaining_bytes, 31 * GB);
assert.equal(usage.shared.reset_at, provider.reset_at);
assert.equal(usage.shared.source, 'kiwivm');
const providerHeader = withUsageHeaders(new Response('', { headers: { 'Subscription-Userinfo': 'expire=0' } }), usage.shared);
assert.equal(providerHeader.headers.get('Subscription-Userinfo'), `upload=0; download=${969 * GB}; total=${1000 * GB}; expire=0`);
assert.equal(providerHeader.headers.get('X-Subscription-Usage-Reset-At'), String(provider.reset_at));
assert.equal(providerHeader.headers.get('X-Subscription-Usage-Source'), 'kiwivm');
for (const change of [ { service_id: '456' }, { used_bytes: -1 }, { quota_bytes: 0 },
  { reset_at: now - 1 }, { reset_at: now + 41 * 86400 }, { observed_at: now + 1 } ]) {
  assert.equal((await send({ ...providerReport, provider: { ...provider, ...change } })).status, 400);
}
assert.equal((await send({ ...providerReport, source: 'dmit', generation: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' })).status, 400, 'Another collector cannot overwrite the provider bill');
assert.equal((await send({ ...providerReport, provider: { ...provider, used_bytes: 1, observed_at: now - 1 } })).status, 200);
assert.equal((await accountUsage(db, env, ['dawn'])).shared.used_bytes, 969 * GB, 'Old snapshots cannot roll back provider use');
sql.prepare('UPDATE monthly_usage SET period=? WHERE period=?').run('1998-01', period.id);
assert.equal((await accountUsage(db, env, ['dawn'])).shared.used_bytes, 969 * GB, 'No personal-month records must not reset the provider bill');
sql.prepare('UPDATE provider_usage SET observed_at=?').run(now - 601);
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.shared.status, 'stale'); assert.equal(usage.shared.used_bytes, 969 * GB);
assert.equal(usage.shared.remaining_bytes, null, 'Stale remaining allowance must not look current');
sql.prepare('UPDATE provider_usage SET reset_at=?').run(now - 1);
assert.equal(withUsageHeaders(new Response(''), (await accountUsage(db, env, ['dawn'])).shared).status, 503, 'An expired cycle must not be advertised as current');
assert.equal((await send({ ...providerReport, observed_at: now + 1, provider: { ...provider,
  used_bytes: 2 * GB, quota_bytes: 2000 * GB, reset_at: now + 31 * 86400, observed_at: now + 1 } })).status, 200);
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.shared.used_bytes, 2 * GB); assert.equal(usage.shared.remaining_bytes, 1998 * GB, 'Provider reset and plan upgrades replace the old snapshot');
assert.equal((await send(providerReport)).status, 200);
assert.equal((await accountUsage(db, env, ['dawn'])).shared.used_bytes, 2 * GB, 'Replayed prior-cycle reports cannot undo a reset');
assert.equal((await accountUsage({ prepare() { throw Error('offline'); } }, env, ['dawn'])).shared.used_bytes, null);
// Per-account payloads share the supplier cycle, independently of UTC months.
env.SUB_ACCOUNT_USAGE_ENABLED = 'true'; env.SUB_USAGE_EXTRA_SOURCES = '';
for (const name of ['dawn', 'zw']) sql.prepare('INSERT INTO users(username,scopes,token_version,created_at) VALUES(?,?,?,?)').run(name, JSON.stringify([name, 'tx']), 'fixture', now);
const accountEnd = now + 31 * 86400;
const accountReport = { ...initial, account_usage: { service_id: '123', reset_at: accountEnd, start_at: null,
  counters: [{ account: 'dawn', upload_bytes: 10 * GB, download_bytes: 20 * GB, started_at: now - 60, observed_at: now, has_gap: true },
    { account: 'zw', upload_bytes: GB, download_bytes: 2 * GB, started_at: now - 60, observed_at: now, has_gap: true },
    { account: '__legacy__', upload_bytes: 3 * GB, download_bytes: 4 * GB, started_at: now - 60, observed_at: now, has_gap: true }] } };
assert.equal((await send(accountReport)).status, 200);
assert.equal((await send(accountReport)).status, 200);
usage = await accountUsage(db, env, ['dawn', 'tx'], 'dawn');
assert.equal(usage.personal.used_bytes, 30 * GB); assert.equal(usage.personal.reset_at, accountEnd);
assert.equal(usage.personal.remaining_bytes, null, 'Incomplete history must not advertise full remaining quota');
assert.equal(usage.personal.status, 'partial'); assert.equal(usage.account_mode, true);
assert.equal(usage.period.end, accountEnd); assert.equal(usage.period.start, null);
assert.equal((await accountUsage(db, env, ['dawn', 'zw', 'tx'], 'dawn')).personal.used_bytes, 30 * GB, 'Admin access never merges another account into personal use');
assert.equal((await accountUsage(db, env, ['zw', 'tx'], 'zw')).personal.used_bytes, 3 * GB);
const overview = await billingOverview(db, env, usage.shared);
assert.equal(overview.accounts.length, 2); assert.equal(overview.legacy.used_bytes, 7 * GB);
const invalidAccount = { ...accountReport, account_usage: { ...accountReport.account_usage, counters: [{ ...accountReport.account_usage.counters[0], account: 'outsider' }] } };
assert.equal((await send(invalidAccount)).status, 400);
assert.equal((await send({ ...accountReport, generation: 'cccccccccccccccccccccccccccccccc' })).status, 409);
assert.equal((await send({ ...accountReport, account_usage: { ...accountReport.account_usage,
  counters: [{ ...accountReport.account_usage.counters[0], upload_bytes: 1, download_bytes: 1, observed_at: now - 1 }] } })).status, 200);
assert.equal((await accountUsage(db, env, ['dawn'], 'dawn')).personal.used_bytes, 30 * GB, 'Replays cannot reduce a known account total');
sql.prepare('UPDATE account_usage SET observed_at=? WHERE account=?').run(now - 601, 'dawn');
assert.equal((await accountUsage(db, env, ['dawn'], 'dawn')).personal.status, 'stale');
sql.prepare('UPDATE provider_usage SET reset_at=?').run(now - 1);
assert.equal((await accountUsage(db, env, ['dawn'], 'dawn')).personal.used_bytes, null, 'No fabricated zero when supplier and account snapshots have not aligned');
sql.close();
console.log('Monthly usage: UTC periods, private scope, shared NIC pool, signed/idempotent reports and honest unknown states passed');
