import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import { accountUsage, ingestUsage, usagePeriod, withUsageHeaders } from '../subscription-auth/usage.mjs';

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
const GB = 1e9;
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
assert.equal(usage.personal.used_bytes, null); assert.equal(usage.shared.used_bytes, null);
assert.equal(usage.personal.quota_bytes, 100 * GB); assert.equal(usage.shared.quota_bytes, 1000 * GB);
assert.equal(withUsageHeaders(new Response('', { headers: { 'Subscription-Userinfo': 'upload=0; download=0; total=0; expire=0' } }), usage.personal).headers.get('Subscription-Userinfo'), null);
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
assert.equal(header, 'upload=1000000000; download=2000000000; total=100000000000; expire=0');
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
assert.equal(usage.personal.status, 'partial'); assert.equal(usage.personal.remaining_bytes, null);
assert.equal(withUsageHeaders(new Response(''), usage.personal).headers.get('Subscription-Userinfo'), null);
sql.prepare('UPDATE monthly_usage SET observed_at=? WHERE meter=?').run(now - 600, 'isp:dawn');
assert.equal((await accountUsage(db, env, ['dawn'])).personal.status, 'stale');
sql.prepare('UPDATE monthly_usage SET period=?').run('1999-01');
usage = await accountUsage(db, env, ['dawn']);
assert.equal(usage.personal.used_bytes, null); assert.equal(usage.shared.used_bytes, null, 'Previous UTC months do not consume this month');
sql.close();
console.log('Monthly usage: UTC periods, private scope, shared NIC pool, signed/idempotent reports and honest unknown states passed');
