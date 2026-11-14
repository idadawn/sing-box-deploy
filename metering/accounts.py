"""Durable per-account payload counters, grouped by provider-confirmed cycles."""
def prepare(db):
    db.executescript('''
      CREATE TABLE IF NOT EXISTS account_raw(meter TEXT PRIMARY KEY, epoch TEXT, up INTEGER, down INTEGER, at INTEGER, first_at INTEGER);
      CREATE TABLE IF NOT EXISTS account_intervals(meter TEXT, began INTEGER, ended INTEGER, up INTEGER, down INTEGER, gap INTEGER, PRIMARY KEY(meter,ended));
      CREATE TABLE IF NOT EXISTS account_cycles(service_id TEXT, reset_at INTEGER, start_at INTEGER, observed INTEGER, PRIMARY KEY(service_id,reset_at));
    ''')


def record(db, service_id, at, counters, provider):
    # Keep interval evidence even while the provider is unreachable across reset.
    for meter, (up, down, epoch) in counters.items():
        old = db.execute('SELECT * FROM account_raw WHERE meter=?', (meter,)).fetchone()
        if old and at <= old['at']:
            continue
        if min(up, down) < 0:
            raise ValueError('Negative account counter')
        first = old['first_at'] if old else at
        if old:
            stable = epoch == old['epoch'] and up >= old['up'] and down >= old['down']
            du, dd = (up - old['up'], down - old['down']) if stable else (up, down)
            db.execute('INSERT INTO account_intervals VALUES(?,?,?,?,?,?)', (meter, old['at'], at, du, dd, int(not stable)))
        db.execute('INSERT OR REPLACE INTO account_raw VALUES(?,?,?,?,?,?)', (meter, epoch, up, down, at, first))
    if provider is not None:
        old = db.execute('SELECT * FROM account_cycles WHERE service_id=? ORDER BY observed DESC LIMIT 1', (service_id,)).fetchone()
        end = provider['reset_at']
        # An end-date correction before reset keeps the same accounting window.
        start = old['reset_at'] if old and old['reset_at'] <= provider['observed_at'] else old['start_at'] if old else None
        existing = db.execute('SELECT start_at FROM account_cycles WHERE service_id=? AND reset_at=?', (service_id, end)).fetchone()
        if existing:
            start = existing['start_at']
        db.execute('INSERT OR REPLACE INTO account_cycles VALUES(?,?,?,?)', (service_id, end, start, provider['observed_at']))
    cycle = db.execute('SELECT * FROM account_cycles WHERE service_id=? ORDER BY observed DESC LIMIT 1', (service_id,)).fetchone()
    if not cycle or cycle['reset_at'] <= at:
        return None  # Do not invent a new billing cycle or erase buffered traffic.
    rows = []
    for raw in db.execute('SELECT * FROM account_raw ORDER BY meter'):
        start = cycle['start_at'] if cycle['start_at'] is not None else raw['first_at']
        if raw['at'] < start:
            continue  # Missing new-cycle telemetry is not a fresh zero.
        total = db.execute('''SELECT COALESCE(SUM(up),0) AS up, COALESCE(SUM(down),0) AS down,
          COALESCE(MAX(gap),0) AS gap,
          COALESCE(MAX(CASE WHEN began < ? AND ended-began > 300 THEN 1 ELSE 0 END),0) AS boundary_gap
          FROM account_intervals WHERE meter=? AND ended>? AND ended<=?''', (start, raw['meter'], start, at)).fetchone()
        rows.append({'account': raw['meter'], 'upload_bytes': total['up'], 'download_bytes': total['down'],
                     'started_at': max(start, raw['first_at']), 'observed_at': raw['at'],
                     'has_gap': cycle['start_at'] is None or raw['first_at'] > start or bool(total['gap'] or total['boundary_gap'])})
    return {'service_id': service_id, 'reset_at': cycle['reset_at'], 'start_at': cycle['start_at'], 'counters': rows} if rows else None
