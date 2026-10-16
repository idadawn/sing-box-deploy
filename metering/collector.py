#!/usr/bin/env python3
"""Read-only counters -> durable monthly ledger -> signed portal report.

Never edits active sing-box/firewall configuration, resets counters, or blocks users.
"""
import argparse
import datetime
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
import urllib.request
import urllib.parse
import uuid


def period_at(at):
    date = datetime.datetime.fromtimestamp(at, datetime.timezone.utc)
    return date.strftime('%Y-%m'), int(date.replace(day=1, hour=0, minute=0, second=0, microsecond=0).timestamp())


def open_state(path):
    db = sqlite3.connect(str(path))
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA synchronous=FULL')
    db.executescript('''
      CREATE TABLE IF NOT EXISTS raw(meter TEXT PRIMARY KEY, epoch TEXT, up INTEGER, down INTEGER, at INTEGER);
      CREATE TABLE IF NOT EXISTS totals(period TEXT, meter TEXT, up INTEGER, down INTEGER, started INTEGER,
        observed INTEGER, gap INTEGER, PRIMARY KEY(period,meter));
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS outbox(period TEXT PRIMARY KEY, sequence INTEGER, body TEXT);
    ''')
    with db:
        db.execute("INSERT OR IGNORE INTO meta VALUES('generation',?)", (uuid.uuid4().hex,))
    return db


def record_sample(db, source, at, counters):
    """Cumulative raw values; first sample establishes a baseline, not past usage."""
    period, start = period_at(at)
    with db:
        latest = db.execute('SELECT MAX(at) FROM raw').fetchone()[0]
        if latest is not None and at < latest:
            raise ValueError('Clock moved backwards')
        for meter, value in counters.items():
            up, down, epoch = value
            if min(up, down) < 0:
                raise ValueError('Negative raw counter')
            old = db.execute('SELECT * FROM raw WHERE meter=?', (meter,)).fetchone()
            if old and at <= old['at']:
                continue
            delta_up = delta_down = 0
            began = at
            gap = False
            if old:
                same_epoch = old['epoch'] == epoch and up >= old['up'] and down >= old['down']
                crossed_month = period_at(old['at'])[0] != period
                if crossed_month and at - old['at'] > 300:
                    # A long interval across a month boundary cannot be assigned
                    # honestly. Establish a new partial baseline instead.
                    gap = True
                else:
                    began = max(start, old['at'])
                    if same_epoch:
                        delta_up, delta_down = up - old['up'], down - old['down']
                    else:
                        # Include measured post-reset bytes; the old process tail
                        # is unknowable, so flag this period as incomplete.
                        delta_up, delta_down, gap = up, down, True
            db.execute('''INSERT INTO totals VALUES(?,?,?,?,?,?,?) ON CONFLICT(period,meter) DO UPDATE SET
                up=up+excluded.up, down=down+excluded.down, started=MIN(started,excluded.started),
                observed=excluded.observed, gap=MAX(gap,excluded.gap)''',
                (period, meter, delta_up, delta_down, began, at, int(gap)))
            db.execute('INSERT OR REPLACE INTO raw VALUES(?,?,?,?,?)', (meter, epoch, up, down, at))
        db.execute("INSERT INTO meta VALUES('sequence',1) ON CONFLICT(key) DO UPDATE SET value=value+1")
        sequence = int(db.execute("SELECT value FROM meta WHERE key='sequence'").fetchone()[0])
        rows = db.execute('SELECT * FROM totals WHERE period=? ORDER BY meter', (period,)).fetchall()
        if not rows:
            return
        generation = db.execute("SELECT value FROM meta WHERE key='generation'").fetchone()[0]
        report = {'source': source, 'generation': generation, 'period': period, 'sequence': sequence, 'observed_at': at, 'counters': [
            {'meter': r['meter'], 'upload_bytes': r['up'], 'download_bytes': r['down'],
             'started_at': r['started'], 'observed_at': r['observed'], 'has_gap': bool(r['gap'])} for r in rows]}
        # Coalesce unsent snapshots per month. Cumulative values preserve all bytes.
        db.execute('INSERT OR REPLACE INTO outbox VALUES(?,?,?)',
                   (period, sequence, json.dumps(report, separators=(',', ':'))))


def network_sample(interface):
    if not re.fullmatch(r'[a-zA-Z0-9_.-]+', interface) or interface == 'lo':
        raise ValueError('Expected physical public interface')
    directory = Path('/sys/class/net') / interface / 'statistics'
    epoch = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    return (int((directory / 'tx_bytes').read_text()), int((directory / 'rx_bytes').read_text()), epoch)


def loopback_address(address):
    match = re.fullmatch(r'127\.0\.0\.1:([0-9]{1,5})', address)
    return bool(match and 1 <= int(match[1]) <= 65535)


def stats_sample(config):
    path = Path(config['sing_box_config'])
    runtime = json.loads(path.read_text())
    stats = runtime.get('experimental', {}).get('v2ray_api', {})
    address = stats.get('listen', '')
    wanted = config['isp_outbounds']
    if not loopback_address(address) or not stats.get('stats', {}).get('enabled'):
        raise ValueError('Loopback sing-box statistics are not enabled')
    if not set(wanted.values()).issubset(stats.get('stats', {}).get('outbounds', [])):
        raise ValueError('ISP outbound counters are not configured')
    actual = {o['tag']: o['type'] for o in runtime.get('outbounds', [])}
    if any(actual.get(tag) != 'socks' for tag in wanted.values()):
        raise ValueError('Only dedicated ISP SOCKS outbounds can consume personal quota')
    unit = config.get('service', 'sing-box.service')
    if not re.fullmatch(r'[a-zA-Z0-9@_.-]+', unit):
        raise ValueError('Invalid service name')
    def epoch():
        return subprocess.check_output(['systemctl', 'show', unit, '-p', 'InvocationID', '--value'], text=True, timeout=5).strip()
    before = epoch()
    if not before:
        raise ValueError('Service is not active')
    raw = subprocess.check_output([
        config.get('grpcurl', '/usr/local/bin/grpcurl'), '-plaintext', '-max-time', '10',
        '-import-path', str(Path(__file__).resolve().parent), '-proto', 'stats.proto',
        '-d', '{"patterns":["outbound>>>"],"reset":false}', address,
        'experimental.v2rayapi.StatsService/QueryStats'], stderr=subprocess.DEVNULL, timeout=15)
    if before != epoch():
        raise ValueError('Service restarted while sampling')
    values = {item['name']: int(item.get('value', 0)) for item in json.loads(raw).get('stat', [])}
    return {'isp:' + ident: (values['outbound>>>' + tag + '>>>traffic>>>uplink'],
                             values['outbound>>>' + tag + '>>>traffic>>>downlink'], before)
            for ident, tag in wanted.items()
            if 'outbound>>>' + tag + '>>>traffic>>>uplink' in values and 'outbound>>>' + tag + '>>>traffic>>>downlink' in values}


def signed_headers(key, raw, at):
    signature = hmac.new(key.encode(), (str(at) + '.' + raw).encode(), hashlib.sha256).hexdigest()
    return {'Content-Type': 'application/json', 'User-Agent': 'SubscriptionMeter/1.0', 'X-Meter-Timestamp': str(at), 'X-Meter-Signature': signature}


def send_pending(db, config):
    origin = urllib.parse.urlsplit(config['portal'])
    if origin.scheme != 'https' or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment or origin.path not in ['', '/']:
        raise ValueError('Expected HTTPS portal origin')
    key_file = Path(config['key_file'])
    if key_file.stat().st_mode & 0o077:
        raise ValueError('Meter key file must be private (0600)')
    key = key_file.read_text().strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]{43,128}', key):
        raise ValueError('Invalid meter key')
    count = 0
    for row in db.execute('SELECT * FROM outbox ORDER BY period').fetchall():
        request = urllib.request.Request(config['portal'].rstrip('/') + '/api/usage/report',
            data=row['body'].encode(), headers=signed_headers(key, row['body'], int(time.time())), method='POST')
        # Refuse redirects so signed private reports cannot move to another host.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                return None
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            result = json.load(response)
            if response.status != 200 or result.get('ok') is not True:
                raise ValueError('Meter report rejected')
        with db:
            db.execute('DELETE FROM outbox WHERE period=? AND sequence=?', (row['period'], row['sequence']))
        count += 1
    return count


def prepare_config(config, output):
    target = Path(output)
    if target.exists():
        raise ValueError('Output exists; refusing to overwrite')
    runtime = json.loads(Path(config['sing_box_config']).read_text())
    address = config.get('stats_listen', '127.0.0.1:10085')
    if not loopback_address(address):
        raise ValueError('Statistics must listen on loopback')
    actual = {o['tag']: o['type'] for o in runtime.get('outbounds', [])}
    tags = list(config['isp_outbounds'].values())
    if not tags or any(actual.get(tag) != 'socks' for tag in tags):
        raise ValueError('Missing dedicated ISP SOCKS outbound')
    experimental = runtime.setdefault('experimental', {})
    if 'v2ray_api' in experimental:
        raise ValueError('Existing stats configuration requires review')
    experimental['v2ray_api'] = {'listen': address, 'stats': {'enabled': True, 'outbounds': tags}}
    with os.fdopen(os.open(str(target), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'w') as stream:
        json.dump(runtime, stream, indent=2)
    print('Prepared a private candidate config. Active services were not modified.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config')
    parser.add_argument('--prepare-config', metavar='NEW_FILE')
    parser.add_argument('--sample-only', action='store_true', help='Read counter availability only; no ledger or HTTP writes')
    args = parser.parse_args()
    os.umask(0o077)
    config = json.loads(Path(args.config).read_text())
    if args.prepare_config:
        prepare_config(config, args.prepare_config)
        return
    def sample():
        counters = {'machine': network_sample(config.get('interface', 'eth0'))}
        unavailable = []
        try:
            personal = stats_sample(config)
            counters.update(personal)
            if len(personal) < len(config['isp_outbounds']):
                unavailable.append('personal_isp_statistics_incomplete')
        except (ValueError, KeyError, OSError, subprocess.SubprocessError):
            unavailable.append('personal_isp_statistics')
        return counters, unavailable
    if args.sample_only:
        counters, unavailable = sample()
        print(json.dumps({'available_meters': list(counters), 'unavailable': unavailable, 'mutations': False}))
        return
    state = Path(config['state_file'])
    state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state.parent / (state.name + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        db = open_state(state)
        try:
            counters, unavailable = sample()
            record_sample(db, config.get('source', 'la'), int(time.time()), counters)
            sent = send_pending(db, config)
            print(json.dumps({'reports_sent': sent, 'unavailable': unavailable}))
        finally:
            db.close()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never echo URLs, credentials, config contents or subprocess output.
        print('Collector failed (' + type(error).__name__ + '); durable pending reports retained.', file=__import__('sys').stderr)
        raise SystemExit(1)
