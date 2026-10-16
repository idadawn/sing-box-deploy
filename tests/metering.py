import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import io
import urllib.error

spec = importlib.util.spec_from_file_location('collector', Path(__file__).resolve().parents[1] / 'metering/collector.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class MeteringTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'state.sqlite3'
        self.db = collector.open_state(self.path)
        self.at = 1790812800  # 2026-10-01 00:00:00 UTC

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def sample(self, at, up, down, epoch='boot-1'):
        collector.record_sample(self.db, 'la', at, {'machine': (up, down, epoch)})

    def report(self):
        return json.loads(self.db.execute('SELECT body FROM outbox ORDER BY period DESC').fetchone()[0])

    def test_baseline_delta_and_restart(self):
        self.sample(self.at, 1000000, 2000000)
        self.assertEqual(self.report()['counters'][0]['upload_bytes'], 0)
        self.sample(self.at + 60, 1000123, 2000456)
        self.db.close(); self.db = collector.open_state(self.path)
        self.sample(self.at + 120, 1000223, 2000556)
        row = self.report()['counters'][0]
        self.assertEqual((row['upload_bytes'], row['download_bytes']), (223, 556))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 1)
        self.sample(self.at + 180, 10, 20, 'boot-2')
        row = self.report()['counters'][0]
        self.assertEqual((row['upload_bytes'], row['download_bytes']), (233, 576))
        self.assertTrue(row['has_gap'])

    def test_month_rollover_and_pending_old_month(self):
        boundary = 1793491200  # 2026-11-01 UTC
        self.sample(boundary - 60, 100, 200)
        self.sample(boundary, 110, 220)
        row = self.report()['counters'][0]
        self.assertEqual(self.report()['period'], '2026-11')
        self.assertEqual((row['upload_bytes'], row['download_bytes']), (10, 20))
        self.assertEqual(row['started_at'], boundary)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 2)

    def test_long_cross_month_gap_is_not_fabricated_usage(self):
        self.sample(self.at, 100, 200)
        self.sample(self.at + 32 * 86400, 9000000, 8000000)
        row = self.report()['counters'][0]
        self.assertEqual(row['upload_bytes'], 0)
        self.assertTrue(row['has_gap'])
        self.assertEqual(row['started_at'], self.at + 32 * 86400)

    def test_missing_personal_stats_do_not_become_fresh_zeroes(self):
        collector.record_sample(self.db, 'la', self.at, {'machine': (100, 200, 'boot'), 'isp:dawn': (1, 2, 'process')})
        self.sample(self.at + 60, 300, 400, 'boot')
        rows = {c['meter']: c for c in self.report()['counters']}
        self.assertEqual(rows['isp:dawn']['observed_at'], self.at)
        self.assertEqual(rows['machine']['observed_at'], self.at + 60)

    def test_clock_rollback_does_not_overwrite_pending_state(self):
        self.sample(self.at, 100, 200)
        original = self.report()
        with self.assertRaises(ValueError):
            self.sample(self.at - 1, 80, 90)
        self.assertEqual(self.report(), original)

    def test_numeric_generation_is_not_coerced_to_float(self):
        value = '12345678901234567890123456789012'
        self.db.execute("UPDATE meta SET value=? WHERE key='generation'", (value,))
        self.db.commit()
        self.sample(self.at, 1, 2)
        self.assertEqual(self.report()['generation'], value)

    def test_candidate_only_enables_private_statistics(self):
        src = Path(self.temp.name) / 'input.json'
        dest = Path(self.temp.name) / 'candidate.json'
        original = {'inbounds': [{'tag': 'test', 'password': 'fixture-only'}],
                    'outbounds': [{'tag': 'isp-out-dawn', 'type': 'socks'}, {'tag': 'direct-out', 'type': 'direct'}],
                    'route': {'final': 'block'}}
        src.write_text(json.dumps(original))
        config = {'sing_box_config': str(src), 'isp_outbounds': {'dawn': 'isp-out-dawn'}}
        collector.prepare_config(config, dest)
        generated = json.loads(dest.read_text())
        self.assertEqual(generated.pop('experimental')['v2ray_api']['stats']['outbounds'], ['isp-out-dawn'])
        self.assertEqual(generated, original)
        self.assertEqual(json.loads(src.read_text()), original)
        self.assertEqual(dest.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            collector.prepare_config(config, dest)
        for address in ['0.0.0.0:10085', '127.0.0.1:0', '127.0.0.1:99999']:
            with self.assertRaises(ValueError):
                collector.prepare_config({**config, 'stats_listen': address}, Path(self.temp.name) / 'bad.json')

    def test_failed_delivery_retains_cumulative_report(self):
        key = Path(self.temp.name) / 'report.key'
        key.write_text('fixture-meter-key-that-is-long-enough-123456789')
        key.chmod(0o600)
        self.sample(self.at, 100, 200)
        config = {'portal': 'https://sub.example', 'key_file': str(key)}
        with mock.patch.object(collector.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = urllib.error.HTTPError('https://sub.example', 503, 'unavailable', {}, None)
            with self.assertRaises(urllib.error.HTTPError):
                collector.send_pending(self.db, config)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 1)
        response = io.BytesIO(b'{"ok":true}')
        response.status = 200
        with mock.patch.object(collector.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = response
            self.assertEqual(collector.send_pending(self.db, config), 1)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
