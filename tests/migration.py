#!/usr/bin/env python3
"""Migration safety contracts; fake credentials, no real SSH or publication."""
import contextlib
import copy
import importlib.util
import io
import json
import os
import types
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'migration'))
from core import MigrationError, digest, inventory, parse_env, patch_env, publisher_guard, endpoint_patch, add_source
import host
import publisher
spec = importlib.util.spec_from_file_location('migrate_gw', ROOT / 'migrate-gw.py')
cli = importlib.util.module_from_spec(spec); spec.loader.exec_module(cli)


def fixture():
    config = {'inbounds': [], 'outbounds': [], 'route': {'final': 'block', 'rules': []},
              'experimental': {'v2ray_api': {'listen': '127.0.0.1:10085', 'stats': {'enabled': True}}}}
    for index, ident in enumerate(('dawn', 'crj', 'tx')):
        outbound = 'tx-direct-out' if ident == 'tx' else 'isp-out-' + ident
        config['outbounds'].append({'tag': outbound, 'type': 'direct' if ident == 'tx' else 'socks', 'server': '192.0.2.' + str(index + 1)})
        for kind, prefix, base in [('trojan', 'trojan', 23000), ('hysteria2', 'hy2', 24000)]:
            tag = 'tx-' + prefix + '-in' if ident == 'tx' else prefix + '-' + ident + '-in'
            config['inbounds'].append({'type': kind, 'tag': tag, 'listen_port': base + index,
                'users': [{'password': 'fixture-' + ident + '-' + kind}],
                'tls': {'enabled': True, 'server_name': 'old.example', 'certificate_path': '/old/cert', 'key_path': '/old/key'},
                'obfs': {'type': 'salamander', 'password': 'fixture-obfs-' + ident}})
            config['route']['rules'].append({'inbound': [tag], 'outbound': outbound})
    return config


def bundle():
    config = json.dumps(fixture()).encode()
    files = {'server.json': config, 'meter.json': b'{"source":"old"}', 'sing-box': b'fake-binary',
             'grpcurl': b'fake-grpcurl', 'report.key': b'fake-key', 'asset-0': b'fake-cert', 'asset-1': b'fake-private-key'}
    manifest = {'version': 1, 'source': {'machine': 'old-machine', 'arch': 'x86_64', 'active': True, 'pid': '123', 'config_sha256': digest(config)},
                'source_id': 'old', 'paths': {'/old/cert': 'asset-0', '/old/key': 'asset-1'}, 'sha256': {k: digest(v) for k, v in files.items()}}
    files['manifest.json'] = json.dumps(manifest).encode()
    return files, manifest


class MigrationTests(unittest.TestCase):
    def test_partial_cutover_and_rollback_keep_other_lines_and_credentials(self):
        config = fixture(); before = copy.deepcopy(config); lines = inventory(config)
        original = {'ISP_INGRESS_OVERRIDES': json.dumps({'dawn': {'server': 'old.example', 'sni': 'old.example'}}), 'TX_DIRECT_IP': '192.0.2.8'}
        env = dict(original)
        moved = endpoint_patch(env, original, lines, ['crj'], '198.51.100.20')
        entries = json.loads(moved['ISP_INGRESS_OVERRIDES'])
        self.assertEqual(entries['dawn']['server'], 'old.example')
        self.assertEqual(entries['crj']['server'], '198.51.100.20')
        self.assertNotIn('TX_DIRECT_IP', moved)
        env.update(moved)
        restored = endpoint_patch(env, original, lines, ['crj'], '198.51.100.20', True)
        self.assertEqual(json.loads(restored['ISP_INGRESS_OVERRIDES']), json.loads(original['ISP_INGRESS_OVERRIDES']))
        self.assertEqual(endpoint_patch(env, original, lines, ['tx'], '198.51.100.20')['TX_DIRECT_IP'], '198.51.100.20')
        self.assertEqual(config, before)
        with self.assertRaises(MigrationError):
            endpoint_patch(env, original, lines, ['unknown'], '198.51.100.20')

    def test_env_is_data_and_preserves_unrelated_values(self):
        text = "# keep\nSECRET='$(touch /tmp/do-not-run)'\nISP_INGRESS_OVERRIDES='{}'\nNAME=hello\n"
        new = patch_env(text, {'ISP_INGRESS_OVERRIDES': '{"dawn":{"server":"new.example","sni":"old.example"}}'})
        self.assertEqual(parse_env(new)['SECRET'], '$(touch /tmp/do-not-run)')
        self.assertEqual(parse_env(new)['NAME'], 'hello')
        self.assertIn('# keep', new)
        with self.assertRaises(MigrationError):
            parse_env('X=1\nX=2\n')
        with self.assertRaises(MigrationError):
            patch_env(text, {'NAME': "bad\nVALUE=yes"})

    def test_source_identity_and_private_site_guards(self):
        env = {'SUB_AUTH_ENABLED': 'true', 'CF_PAGES_PROJECT': 'gw', 'SUB_AUTH_D1_ID': 'fixture', 'SUB_AUTH_ISP_CREDENTIALS_FILE': 'private.json'}
        publisher_guard(env)
        for extra in ({'SUB_AUTH_ENABLED': 'false'}, {'SUB_LEGACY_RETIRED': 'true'}):
            with self.assertRaises(MigrationError):
                publisher_guard({**env, **extra})
        with self.assertRaises(MigrationError):
            publisher_guard(env, True)
        self.assertEqual(add_source({'SUB_USAGE_SOURCE': 'old', 'SUB_USAGE_EXTRA_SOURCES': 'older'}, 'new')['SUB_USAGE_EXTRA_SOURCES'], 'older,new')
        with self.assertRaises(MigrationError):
            add_source({'SUB_USAGE_SOURCE': 'old'}, 'old')

    def test_bundle_integrity_paths_and_runtime_invariants(self):
        files, manifest = bundle()
        self.assertEqual(host.unpack(host.pack(files))[0], files)
        target = host.target_config(files, manifest)
        old = json.loads(files['server.json'])
        self.assertEqual(target['route'], old['route'])
        self.assertEqual(target['outbounds'], old['outbounds'])
        self.assertEqual(inventory(target), inventory(old))
        self.assertTrue(target['inbounds'][0]['tls']['key_path'].startswith('/etc/sing-box-gw/assets/'))
        bad = dict(files); bad['asset-0'] = b'modified'
        with self.assertRaises(MigrationError):
            host.unpack(host.pack(bad))
        for name in ('../escape', '/absolute', '..'):
            with self.assertRaises(MigrationError):
                host.unpack(host.pack({name: b'x'}))
        malformed = fixture(); malformed['route']['final'] = 'direct-out'
        with self.assertRaises(MigrationError):
            inventory(malformed)
        malformed = fixture(); malformed['inbounds'][1]['listen_port'] = malformed['inbounds'][0]['listen_port']
        with self.assertRaises(MigrationError):
            inventory(malformed)
        malformed = fixture(); malformed['route']['rules'] = []
        with self.assertRaises(MigrationError):
            inventory(malformed)

    def test_target_rejects_same_host_and_architecture_without_writes(self):
        files, manifest = bundle()
        with patch.object(host.os, 'geteuid', return_value=0), patch.object(host.platform, 'system', return_value='Linux'), patch.object(host, 'private_write') as write:
            for current in ({'machine': 'old-machine', 'arch': 'x86_64'}, {'machine': 'new-machine', 'arch': 'aarch64'}):
                with patch.object(host, 'status', return_value=current), self.assertRaises(MigrationError):
                    host.install(files, manifest, {'meter_source': 'new'})
            write.assert_not_called()

    def test_prepared_target_files_units_and_independent_ledger(self):
        files, manifest = bundle()
        files['collector.py'] = (ROOT / 'metering/collector.py').read_bytes()
        files['stats.proto'] = (ROOT / 'metering/stats.proto').read_bytes()
        before = copy.deepcopy(files)
        with tempfile.TemporaryDirectory() as td:
            sandbox = Path(td)
            def mapped(value, *parts):
                path = Path(value, *parts)
                if str(path).startswith(('/etc/', '/opt/', '/var/lib/', '/sys/')):
                    return sandbox / str(path).lstrip('/')
                return path
            mapped('/sys/class/net/eth0').mkdir(parents=True)
            calls, checks = [], []
            def status():
                if checks:
                    return {'active': True, 'machine': 'new-machine', 'config_sha256': digest(mapped('/etc/sing-box-gw/config.json').read_bytes())}
                checks.append(True)
                return {'occupied': False, 'machine': 'new-machine', 'arch': 'x86_64'}
            def run(command, **kwargs):
                calls.append(command)
                return b'not-found' if '--property=LoadState' in command else b''
            with patch.object(host, 'Path', side_effect=mapped), patch.object(host, 'CONFIG', mapped('/etc/sing-box-gw/config.json')), \
                 patch.object(host, 'METER', mapped('/etc/subscription-meter-gw/config.json')), patch.object(host, 'BINARY', mapped('/opt/sing-box-gw/sing-box')), \
                 patch.object(host, 'MARKER', mapped('/etc/sing-box-gw/migration.json')), patch.object(host.os, 'geteuid', return_value=0), \
                 patch.object(host.os, 'chown'), patch.object(host.platform, 'system', return_value='Linux'), patch.object(host, 'status', side_effect=status), \
                 patch.object(host, 'check_certs'), patch.object(host.shutil, 'which', return_value='/fake/bin'), patch.object(host, 'run', side_effect=run), \
                 patch.object(host.pwd, 'getpwnam', return_value=types.SimpleNamespace(pw_uid=max(1, os.getuid()), pw_gid=os.getgid(), pw_shell='/usr/sbin/nologin')), \
                 patch.object(host.time, 'sleep'), patch('socket.socket'):
                result = host.install(files, manifest, {'meter_source': 'new-source', 'id': 'fixture', 'interface': 'eth0'})
            self.assertTrue(result['active'])
            self.assertEqual(files, before, 'Source snapshot remains intact')
            meter = json.loads(mapped('/etc/subscription-meter-gw/config.json').read_text())
            self.assertEqual(meter['source'], 'new-source')
            self.assertEqual(meter['state_file'], '/var/lib/subscription-meter-gw/state.sqlite3')
            self.assertFalse(mapped(meter['state_file']).exists(), 'No original ledger is cloned')
            self.assertEqual(mapped('/etc/subscription-meter-gw/report.key').stat().st_mode & 0o777, 0o600)
            self.assertEqual(mapped('/etc/sing-box-gw/config.json').stat().st_mode & 0o777, 0o640)
            self.assertIn(['systemctl', 'enable', '--now', 'sing-box-gw.service'], calls)
            self.assertIn(['systemctl', 'enable', '--now', 'subscription-meter-gw.timer'], calls)
            self.assertFalse(any('restart' in command or 'stop' in command for command in calls))
            unit = mapped('/etc/systemd/system/sing-box-gw.service').read_text()
            self.assertIn('User=sing-box-gw', unit)
            self.assertIn('ExecStartPre=/opt/sing-box-gw/sing-box check', unit)

    def test_publisher_compare_and_swap_and_failed_publish_journal(self):
        with tempfile.TemporaryDirectory() as td:
            directory = Path(td)
            (directory / 'scripts').mkdir(); (directory / 'scripts/build-auth.mjs').write_text('SUB_USAGE_EXTRA_SOURCES')
            (directory / 'creds.json').write_text('{}'); (directory / 'creds.json').chmod(0o600)
            text = 'SUB_AUTH_ENABLED=true\nCF_PAGES_PROJECT=gw\nSUB_AUTH_D1_ID=fixture\nSUB_AUTH_ISP_CREDENTIALS_FILE=creds.json\nSUB_USAGE_EXTRA_SOURCES=older\n'
            (directory / '.env').write_text(text); (directory / '.env').chmod(0o600)
            request = {'expected': 'wrong', 'patch': {'TX_DIRECT_IP': '198.51.100.20'}}
            with patch.object(publisher.subprocess, 'run') as run, self.assertRaises(MigrationError):
                publisher.publisher_main('apply', {'directory': td}, request)
            run.assert_not_called(); self.assertEqual((directory / '.env').read_text(), text)
            request.update(expected=digest(text.encode()), patch={'SUB_USAGE_EXTRA_SOURCES': 'new'})
            with self.assertRaises(MigrationError):
                publisher.publisher_main('apply', {'directory': td}, request)
            request['patch'] = {'SUB_USAGE_EXTRA_SOURCES': 'older,new', 'TX_DIRECT_IP': '198.51.100.20'}
            with patch.object(publisher.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), contextlib.redirect_stdout(io.StringIO()) as out:
                publisher.publisher_main('apply', {'directory': td}, request)
            self.assertFalse(json.loads(out.getvalue())['ok'])
            self.assertTrue((directory / '.migration-private/pending.json').exists())
            self.assertEqual((directory / '.env').stat().st_mode & 0o777, 0o600)
            self.assertEqual(parse_env((directory / '.env').read_text())['SUB_USAGE_EXTRA_SOURCES'], 'older,new')

    def test_switch_failure_rolls_back_without_source_mutations_or_usage_loss(self):
        files, manifest = bundle(); raw = host.pack(files)
        original = {'ISP_INGRESS_OVERRIDES': '{}', 'TX_DIRECT_IP': '192.0.2.8', 'TROJAN_DOMAIN': 'old.example'}
        initial_text = 'SUB_USAGE_SOURCE=old\nISP_INGRESS_OVERRIDES={}\nTX_DIRECT_IP=192.0.2.8\n'
        for mode in ('failed_verification', 'target_down_rollback', 'stale_verification', 'interrupted_rollback'):
            with tempfile.TemporaryDirectory() as td:
                directory = Path(td); directory.chmod(0o700)
                host.private_write(directory / 'snapshot.tar.gz', raw)
                state = {'id': 'id', 'source': 'old', 'source_address': '192.0.2.8', 'target': 'new', 'target_address': '198.51.100.20',
                         'target_machine': 'new-machine', 'snapshot_sha256': digest(raw), 'phase': 'prepared', 'target_config': 'target-hash',
                         'publisher': 'pub', 'publisher_dir': '/pub', 'publisher_sha256': digest(initial_text.encode()), 'portal': 'https://gw.example',
                         'original': original, 'switched': [], 'verified_at': int(time.time()) - (1000 if mode == 'stale_verification' else 10),
                         'meter_source': 'new', 'accounts_file': str(directory / 'accounts.json')}
                host.private_write(directory / 'accounts.json', b'[]')
                if mode == 'interrupted_rollback':
                    forward = {'ISP_INGRESS_OVERRIDES': '{"crj":{"server":"198.51.100.20","sni":"old.example"}}', 'SUB_USAGE_EXTRA_SOURCES': 'new'}
                    after = patch_env(initial_text, forward)
                    recovery = patch_env(after, {'ISP_INGRESS_OVERRIDES': '{}'})
                    state['pending'] = {'before': {'ISP_INGRESS_OVERRIDES': '{}'}, 'before_sha256': digest(initial_text.encode()),
                        'after_sha256': digest(after.encode()), 'rollback_sha256': digest(recovery.encode()), 'previous_switched': []}
                cli.save(directory, state)
                calls, current = [], {'text': recovery if mode == 'interrupted_rollback' else initial_text}
                def remote(server, module, action, options=None, data=b'', ssh_address=None):
                    calls.append((server, action))
                    if server == 'old':
                        self.assertEqual(action, 'status', 'Source must only be read')
                        return manifest['source']
                    if server == 'new':
                        self.assertNotEqual(mode, 'target_down_rollback', 'Rollback must work with target offline')
                        return {'machine': 'new-machine', 'active': True, 'config_sha256': 'target-hash', 'migration': {'id': 'id'}}
                    if action == 'read':
                        return {'text': current['text'], 'sha256': digest(current['text'].encode())}
                    request = json.loads(data)
                    self.assertEqual(request['expected'], digest(current['text'].encode()))
                    current['text'] = patch_env(current['text'], request['patch'])
                    return {'ok': True, 'sha256': digest(current['text'].encode())}
                action = 'recover' if mode == 'interrupted_rollback' else 'rollback' if mode == 'target_down_rollback' else 'switch'
                args = ['migrate-gw.py', action, '--state', td, '--lines', 'crj']
                verification = [MigrationError('simulated public endpoint mismatch'), True] if mode == 'failed_verification' else [True]
                with patch.object(sys, 'argv', args), patch.object(cli, 'remote', side_effect=remote), patch.object(cli, 'verify_publication', side_effect=verification), contextlib.redirect_stdout(io.StringIO()):
                    if mode in ('target_down_rollback', 'interrupted_rollback'):
                        cli.main()
                    else:
                        with self.assertRaises(MigrationError):
                            cli.main()
                if mode == 'stale_verification':
                    self.assertNotIn(('pub', 'apply'), calls)
                else:
                    self.assertEqual(json.loads(parse_env(current['text'])['ISP_INGRESS_OVERRIDES']), {})
                    self.assertEqual(parse_env(current['text'])['SUB_USAGE_EXTRA_SOURCES'], 'new', 'Rollback keeps target usage registered')


if __name__ == '__main__':
    unittest.main()
