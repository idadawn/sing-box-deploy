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

    def test_provider_counter_multiplier_and_cycle(self):
        data = {'error': 0, 'plan_monthly_data': '1000', 'data_counter': '969',
                'monthly_data_multiplier': '0.5', 'data_next_reset': self.at + 17 * 86400}
        # Byte counts must remain exact after applying the provider's multiplier.
        with self.assertRaises(ValueError):
            collector.normalize_kiwivm(data, '123', self.at)
        data['data_counter'] = '968'
        sample = collector.normalize_kiwivm(data, '123', self.at)
        self.assertEqual((sample['used_bytes'], sample['quota_bytes']), (484, 500))
        self.assertEqual(sample['reset_at'], data['data_next_reset'])
        for field, bad in [('error', 1), ('monthly_data_multiplier', 0), ('monthly_data_multiplier', 'NaN'),
                           ('data_counter', -1), ('data_counter', True), ('plan_monthly_data', 0),
                           ('data_next_reset', self.at), ('data_counter', 2**54)]:
            with self.subTest(field=field, bad=bad), self.assertRaises(ValueError):
                collector.normalize_kiwivm({**data, field: bad}, '123', self.at)

    def test_provider_failure_keeps_pending_snapshot_without_refreshing_it(self):
        provider = {'name': 'kiwivm', 'service_id': '123', 'used_bytes': 969,
                    'quota_bytes': 1000, 'reset_at': self.at + 17 * 86400, 'observed_at': self.at}
        collector.record_sample(self.db, 'la', self.at, {'machine': (1, 2, 'boot')}, provider)
        self.sample(self.at + 60, 101, 202, 'boot')
        self.assertEqual(self.report()['provider'], provider)
        self.assertEqual(self.report()['counters'][0]['upload_bytes'], 100)

    def test_provider_request_uses_private_key_and_fixed_read_only_endpoint(self):
        key = Path(self.temp.name) / 'api.key'; key.write_text('fixture-api-key'); key.chmod(0o600)
        data = {'error': 0, 'plan_monthly_data': 1000, 'data_counter': 969,
                'monthly_data_multiplier': 1, 'data_next_reset': self.at + 17 * 86400}
        config = {'kiwivm': {'veid': '123', 'key_file': str(key)}}
        with mock.patch.object(collector.urllib.request, 'build_opener') as opener, mock.patch.object(collector.time, 'time', return_value=self.at):
            opener.return_value.open.return_value = io.BytesIO(json.dumps(data).encode())
            self.assertEqual(collector.kiwivm_sample(config)['used_bytes'], 969)
            request = opener.return_value.open.call_args[0][0]
            self.assertEqual(request.full_url, 'https://api.64clouds.com/v1/getServiceInfo')
            self.assertEqual(request.method, 'POST')
            self.assertNotIn('fixture-api-key', request.full_url)
            self.assertIn(b'api_key=fixture-api-key', request.data)
        key.chmod(0o644)
        with self.assertRaises(ValueError):
            collector.kiwivm_sample(config)

    def test_account_billing_reset_and_provider_outage(self):
        end = self.at + 16 * 86400
        def sample(at, up, down, reset=None, epoch='process'):
            p = {'name': 'kiwivm', 'service_id': '123', 'reset_at': reset, 'observed_at': at,
                 'used_bytes': 900, 'quota_bytes': 1000} if reset else None
            collector.record_sample(self.db, 'la', at, {'machine': (1, 2, 'boot')}, p,
                                    {'alice': (up, down, epoch), '__legacy__': (0, 0, epoch)}, '123')
        sample(self.at, 100, 100, end)
        self.assertTrue(self.report()['account_usage']['counters'][1]['has_gap'])
        sample(end - 30, 250, 300, end)
        old = self.report()['account_usage']
        self.assertEqual(old['reset_at'], end)
        sample(end + 30, 400, 500)  # Keep evidence while the next reset is unknown.
        self.assertNotIn('account_usage', self.report())
        pending = json.loads(self.db.execute('SELECT body FROM account_outbox').fetchone()[0])
        self.assertEqual(pending['account_usage'], old, 'Do not lose an undelivered previous-cycle snapshot')
        sample(end + 90, 500, 700, end + 31 * 86400)
        cycle = self.report()['account_usage']; row = next(c for c in cycle['counters'] if c['account'] == 'alice')
        self.assertEqual(cycle['start_at'], end)
        self.assertEqual((row['upload_bytes'], row['download_bytes']), (250, 400))
        self.assertFalse(row['has_gap'])
        # Natural-month boundaries never reset the provider's account window.
        sample(self.at + 32 * 86400, 700, 900, end + 31 * 86400)
        row = next(c for c in self.report()['account_usage']['counters'] if c['account'] == 'alice')
        self.assertEqual((row['upload_bytes'], row['download_bytes']), (450, 600))

    def test_account_restart_preserves_known_usage_and_marks_gap(self):
        end = self.at + 16 * 86400
        p = {'name': 'kiwivm', 'service_id': '123', 'reset_at': end, 'observed_at': self.at, 'used_bytes': 900, 'quota_bytes': 1000}
        for at, up, down, epoch in [(self.at, 0, 0, 'a'), (self.at + 60, 100, 200, 'a'), (self.at + 120, 30, 40, 'b')]:
            collector.record_sample(self.db, 'la', at, {'machine': (1, 2, 'boot')}, {**p, 'observed_at': at},
                                    {'alice': (up, down, epoch)}, '123')
        row = self.report()['account_usage']['counters'][0]
        self.assertEqual((row['upload_bytes'], row['download_bytes']), (130, 240))
        self.assertTrue(row['has_gap'])
        self.db.close(); self.db = collector.open_state(self.path)
        collector.record_sample(self.db, 'la', self.at + 180, {'machine': (1, 2, 'boot')}, {**p, 'observed_at': self.at + 180}, {'alice': (40, 50, 'b')}, '123')
        self.assertEqual(self.report()['account_usage']['counters'][0]['upload_bytes'], 140)

    def test_account_provisioning_keeps_routes_and_attributes_admin_to_admin(self):
        spec = importlib.util.spec_from_file_location('provision', Path(__file__).resolve().parents[1] / 'metering/provision_accounts.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        runtime = {'inbounds': [], 'outbounds': [{'tag': 'isp-out-dawn'}, {'tag': 'isp-out-zw'}],
                   'route': {'final': 'block', 'rules': [{'inbound': ['trojan-zw-in'], 'outbound': 'isp-out-zw'}]},
                   'experimental': {'v2ray_api': {'stats': {'enabled': True, 'outbounds': ['isp-out-dawn', 'isp-out-zw']}}}}
        for scope in ['dawn', 'zw', 'tx']:
            for kind, prefix in [('trojan', 'trojan'), ('hysteria2', 'hy2')]:
                tag = ('tx-' + prefix + '-in') if scope == 'tx' else prefix + '-' + scope + '-in'
                runtime['inbounds'].append({'tag': tag, 'type': kind, 'listen_port': len(runtime['inbounds']) + 23000,
                                            'users': [{'name': 'old', 'password': 'old-' + tag}], 'obfs': {'password': 'old-obfs'}})
        manifest = {'dawn': {'scopes': ['dawn', 'zw', 'tx'], 'trojan': 'a'*40, 'hysteria': 'b'*40},
                    'zw': {'scopes': ['zw', 'tx'], 'trojan': 'c'*40, 'hysteria': 'd'*40}}
        result, meter = module.prepare(runtime, {'kiwivm': {'veid': '123'}}, manifest)
        self.assertEqual(result['route'], runtime['route'])
        for before, after in zip(runtime['inbounds'], result['inbounds']):
            self.assertEqual(after['listen_port'], before['listen_port']); self.assertEqual(after['obfs'], before['obfs'])
            self.assertEqual(after['users'][0]['password'], before['users'][0]['password'])
            self.assertIn('account-dawn', [u['name'] for u in after['users']])
            self.assertEqual('account-zw' in [u['name'] for u in after['users']], 'dawn' not in after['tag'])
        self.assertEqual(meter['account_users']['dawn'], ['account-dawn'])
        self.assertEqual(len(meter['account_users']['__legacy__']), 6)
        repeated, _ = module.prepare(result, meter, manifest)
        self.assertEqual(repeated, result, 'Provisioning is idempotent')


if __name__ == '__main__':
    unittest.main()
