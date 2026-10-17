#!/usr/bin/env python3
"""Parallel GW migration. Run --help; state contains secrets and stays off Git."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'migration'))
from core import MigrationError, require, digest, inventory, parse_env, endpoint_patch, add_source, address, source_id, patch_env
from host import pack, unpack, private_write
from probe import verify_nodes, verify_publication


def remote(host, module, action, options=None, data=b'', ssh_address=None):
    require(host.lower().split('@')[-1] != 'j', 'Retired J host is out of scope')
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@:-]*', host), 'Invalid SSH alias')
    code = (ROOT / 'migration/core.py').read_text() + '\n'
    helper = (ROOT / 'migration' / (module + '.py')).read_text()
    helper = re.sub(r'^from core import .+\n', '', helper, flags=re.M)
    code += helper
    if module == 'host':
        call = 'host_main(' + repr(action) + ',' + repr(options or {}) + ')'
    else:
        call = 'publisher_main(' + repr(action) + ',' + repr(options or {}) + ',json.loads(sys.stdin.buffer.read() or b"{}"))'
    code += '\nimport sys\ntry:\n    ' + call + '\nexcept Exception as e:\n    print("Migration helper failed: " + (str(e) if isinstance(e, MigrationError) else type(e).__name__),file=sys.stderr)\n    sys.exit(1)\n'
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=yes']
    if ssh_address:
        settings = subprocess.run(['ssh', '-G', host], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.decode()
        hostname = re.search(r'^hostname (.+)$', settings, re.M)[1]
        alias = re.search(r'^hostkeyalias (.+)$', settings, re.M)
        known_host = alias[1] if alias and alias[1] != 'none' else hostname
        command += ['-o', 'HostName=' + address(ssh_address), '-o', 'HostKeyAlias=' + known_host]
    command += [host, 'sudo -n python3 -c ' + shlex.quote(code)]
    result = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=720)
    # Do not echo remote stdout/stderr: a failing publisher may contain credentials.
    require(result.returncode == 0, 'SSH helper failed on ' + host + ' (' + action + '); no secret output shown')
    return result.stdout if action == 'snapshot' else json.loads(result.stdout)


def save(directory, state):
    private_write(directory / 'state.json', (json.dumps(state, indent=2) + '\n').encode())


def read_private(path):
    path = Path(path).expanduser().resolve()
    require(path.is_file() and path.stat().st_mode & 0o077 == 0, 'Private file must have mode 0600')
    return json.loads(path.read_text())


def publisher(state, action='read', data=None):
    return remote(state['publisher'], 'publisher', action, {'directory': state['publisher_dir']}, json.dumps(data or {}).encode())


def source_status(state):
    return remote(state['source'], 'host', 'status', ssh_address=state['source_address'])


def source_unchanged(state, manifest):
    current = source_status(state)
    require(current.get('active') and current.get('config_sha256') == manifest['source']['config_sha256'], 'Source configuration changed; make a new plan')
    require(current['machine'] == manifest['source']['machine'], 'Source host identity changed')
    return current


def target_status(state):
    return remote(state['target'], 'host', 'status')


def current_endpoints(state, lines):
    original = state['original']
    ingress = json.loads(original.get('ISP_INGRESS_OVERRIDES') or '{}')
    return {i: state['target_address'] if i in state['switched'] else original['TX_DIRECT_IP'] if i == 'tx' else
            ingress.get(i, {}).get('server', original['TROJAN_DOMAIN']) for i in lines}


def validate_publisher(info, lines, meter_source):
    env = parse_env(info['text'])
    require(meter_source in [env.get('SUB_USAGE_SOURCE', 'la')] + env.get('SUB_USAGE_EXTRA_SOURCES', '').split(','), 'Publisher/source ledger mismatch')
    require(set(info['credentials']) == set(lines) - {'tx'}, 'Publisher line inventory differs')
    ports = json.loads(env.get('ISP_PORT_OVERRIDES') or '{}')
    overrides = json.loads(env.get('ISP_INGRESS_OVERRIDES') or '{}')
    for ident, line in lines.items():
        if ident == 'tx':
            credentials = {'trojan': env.get('TX_DIRECT_TROJAN_PASSWORD'), 'hysteria': env.get('TX_DIRECT_HYSTERIA_PASSWORD'), 'obfs': env.get('TX_DIRECT_OBFS_PASSWORD')}
            pair = {'trojan': int(env.get('TX_DIRECT_TROJAN_PORT', 443)), 'hysteria': int(env.get('TX_DIRECT_HYSTERIA_PORT', 8443))}
        else:
            credentials, pair = info['credentials'][ident], ports.get(ident, {})
        require(credentials['trojan'] == line['trojan']['password'] and credentials['hysteria'] == line['hysteria2']['password'] and
                credentials['obfs'] == line['hysteria2']['obfs'], 'Publisher credentials do not match runtime')
        require(pair.get('trojan') == line['trojan']['port'] and pair.get('hysteria') == line['hysteria2']['port'], 'Publisher ports do not match runtime')
        require(overrides.get(ident, {}).get('sni', env['TROJAN_DOMAIN']) == line['trojan']['sni'] and
                overrides.get(ident, {}).get('sni', env['HYSTERIA_DOMAIN']) == line['hysteria2']['sni'], 'Publisher SNI differs')
    return env


def main():
    parser = argparse.ArgumentParser(description='GW 并行迁移：预部署、双协议验证、分批切换、回退；不会停止旧机或修改 DNS。')
    parser.add_argument('action', choices=['plan', 'prepare', 'verify', 'switch', 'rollback', 'status', 'audit-source', 'sync-certs', 'recover'])
    parser.add_argument('--state', required=True, help='Git 之外的私有迁移目录')
    parser.add_argument('--source', help='旧机 SSH 别名')
    parser.add_argument('--source-address', help='旧机 IPv4；同时用于严格主机密钥校验的 SSH HostName 覆盖')
    parser.add_argument('--target', help='已信任主机密钥的第二台 SSH 别名')
    parser.add_argument('--target-address', help='第二台公网 IPv4')
    parser.add_argument('--interface', default='eth0', help='第二台公网网卡')
    parser.add_argument('--meter-source', help='全新且永不复用的计量 source，例如 dmit-gw-202611')
    parser.add_argument('--publisher', help='受保护 GW 发布机 SSH 别名')
    parser.add_argument('--publisher-dir', help='发布机上 GW 仓库绝对路径，不能用旧 dl 目录')
    parser.add_argument('--accounts-file', help='已有专属订阅验证账号 JSON 文件，0600，含 username/scopes/token')
    parser.add_argument('--mihomo', help='本机 Mihomo 可执行文件，用于隔离验证')
    parser.add_argument('--lines', default='all', help='all 或逗号分隔线路，例如 crj,zw；直出为 tx')
    args = parser.parse_args()
    directory = Path(args.state).expanduser().resolve()
    require(ROOT not in directory.parents and directory != ROOT, 'Migration state must be outside Git')
    os.umask(0o077)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(directory.stat().st_mode & 0o077 == 0, 'Migration directory must be mode 0700')
    with (directory / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action in ('plan', 'audit-source'):
            require(not (directory / 'state.json').exists(), 'State exists; use a new directory for a new plan')
            require(args.source and args.source_address, 'Specify --source and --source-address')
            address(args.source_address)
            raw = remote(args.source, 'host', 'snapshot', ssh_address=args.source_address)
            files, manifest = unpack(raw)
            lines = inventory(json.loads(files['server.json']))
            require(manifest['source'].get('active'), 'Source GW is inactive')
            private_write(directory / 'snapshot.tar.gz', raw)
            state = {'id': uuid.uuid4().hex, 'source': args.source, 'source_address': args.source_address,
                     'snapshot_sha256': digest(raw), 'created_at': int(time.time()), 'phase': args.action,
                     'switched': [], 'verified_at': 0}
            if args.action == 'audit-source':
                require(args.mihomo, 'audit-source requires --mihomo')
                result = verify_nodes(args.mihomo, lines, args.source_address, args.source_address)
                private_write(directory / 'source-verification.json', json.dumps(result).encode())
                save(directory, state)
                print('旧机只读快照与全部协议出口验证通过；未修改服务器或客户端配置。'); return
            require(all((args.target, args.target_address, args.meter_source, args.publisher, args.publisher_dir, args.accounts_file)), 'Missing plan parameters; see --help')
            address(args.target_address); source_id(args.meter_source)
            require(args.target_address != args.source_address, 'Target address equals source')
            state.update(target=args.target, target_address=args.target_address, interface=args.interface, meter_source=args.meter_source,
                         publisher=args.publisher, publisher_dir=args.publisher_dir, accounts_file=str(Path(args.accounts_file).expanduser().resolve()))
            target = target_status(state)
            require(not target['occupied'] and target['machine'] != manifest['source']['machine'] and target['arch'] == manifest['source']['arch'], 'Target must be empty, distinct and same CPU architecture')
            info = publisher(state)
            env = validate_publisher(info, lines, manifest['source_id'])
            all_sources = [env.get('SUB_USAGE_SOURCE', 'la')] + env.get('SUB_USAGE_EXTRA_SOURCES', '').split(',')
            require(args.meter_source not in all_sources, 'Target source is already registered; use a fresh identity')
            state.update(publisher_sha256=info['sha256'], portal='https://' + env['SUB_DOMAIN'],
                         target_machine=target['machine'], original={k: env.get(k) for k in ('ISP_INGRESS_OVERRIDES', 'TX_DIRECT_IP', 'TROJAN_DOMAIN', 'HYSTERIA_DOMAIN')})
            verify_publication(state['portal'], read_private(state['accounts_file']), lines, current_endpoints(state, lines))
            save(directory, state)
            print(json.dumps({'phase': 'planned', 'lines': list(lines), 'ports': [line[k]['port'] for line in lines.values() for k in ('trojan', 'hysteria2')], 'target': args.target, 'mutations': False})); return

        state = read_private(directory / 'state.json')
        raw = (directory / 'snapshot.tar.gz').read_bytes()
        require(digest(raw) == state['snapshot_sha256'], 'Private snapshot changed')
        files, manifest = unpack(raw)
        lines = inventory(json.loads(files['server.json']))
        selected = list(lines) if args.lines == 'all' else list(dict.fromkeys(args.lines.split(',')))
        require(selected and set(selected) <= set(lines), 'Unknown line selection')
        if args.action == 'status':
            print(json.dumps({'phase': state['phase'], 'switched': state['switched'], 'source': source_status(state),
                              'target': target_status(state), 'note': 'TCP 数为参考，HY2 活跃会话未知；不会自动下线任何服务器。'}, indent=2)); return
        source_unchanged(state, manifest)
        if args.action == 'recover':
            pending = state.get('pending')
            require(pending, 'No interrupted publication to recover')
            info = publisher(state)
            require(info['sha256'] in (pending['after_sha256'], pending['before_sha256'], pending['rollback_sha256']), 'Publisher changed independently; refuse recovery overwrite')
            recovery_patch = {**pending['before'], **add_source(parse_env(info['text']), state['meter_source'])}
            result = publisher(state, 'apply', {'expected': info['sha256'], 'patch': recovery_patch})
            require(result['ok'], 'Recovery publication failed; journal retained')
            state['publisher_sha256'] = result['sha256']
            state['switched'] = pending['previous_switched']
            verify_publication(state['portal'], read_private(state['accounts_file']), lines, current_endpoints(state, lines))
            state.update(pending=None, phase='parallel' if state['switched'] else 'rolled_back')
            save(directory, state)
            print('已恢复中断发布前的入口；保留两台服务器和累计流量。'); return
        require(not state.get('pending'), 'Publication journal is pending; run recover first')
        if args.action == 'prepare':
            require(state['phase'] in ('plan', 'prepared'), 'Unexpected migration phase')
            target = target_status(state)
            require(target['machine'] == state['target_machine'], 'Target host changed')
            # Append current collector source/proto to the sealed runtime snapshot.
            for name in ('collector.py', 'stats.proto'):
                files[name] = (ROOT / 'metering' / name).read_bytes()
                manifest['sha256'][name] = digest(files[name])
            files['manifest.json'] = json.dumps(manifest).encode()
            result = remote(state['target'], 'host', 'install', {'id': state['id'], 'meter_source': state['meter_source'], 'interface': state['interface']}, pack(files))
            state.update(phase='prepared', target_config=result['config_sha256'])
            save(directory, state)
            print('第二台已预部署；尚未改订阅。请放行列出的 TCP/UDP 端口后执行 verify。'); return
        target = target_status(state) if args.action != 'rollback' else {}
        if args.action != 'rollback':
            require(target.get('active') and target.get('config_sha256') == state.get('target_config') and
                target['machine'] == state['target_machine'] and target.get('migration', {}).get('id') == state['id'], 'Target is not the prepared runtime')
        if args.action == 'sync-certs':
            fresh = remote(state['source'], 'host', 'snapshot', ssh_address=state['source_address'])
            fresh_files, fresh_manifest = unpack(fresh)
            require(fresh_manifest['source']['config_sha256'] == manifest['source']['config_sha256'] and fresh_manifest['paths'] == manifest['paths'], 'Source changed during certificate refresh')
            remote(state['target'], 'host', 'sync-certs', {'id': state['id']}, fresh)
            print('证书已同步；未重启代理。旧机下线前仍需安排新机独立续期。'); return
        if args.action == 'verify':
            require(args.mihomo, 'verify requires --mihomo')
            results = verify_nodes(args.mihomo, lines, state['target_address'], state['target_address'])
            private_write(directory / 'target-verification.json', json.dumps(results).encode())
            state['verified_at'] = int(time.time()); save(directory, state)
            print('全部线路双协议、双测速目标的真实出口验证通过。'); return

        require(args.action in ('switch', 'rollback'), 'Invalid action')
        rollback = args.action == 'rollback'
        if not rollback:
            require(0 < time.time() - state['verified_at'] < 900, 'Run verify successfully within 15 minutes before switch')
        info = publisher(state)
        require(info['sha256'] == state['publisher_sha256'], 'Publisher changed; inspect journal before overwriting')
        env = parse_env(info['text'])
        patch = endpoint_patch(env, state['original'], lines, selected, state['target_address'], rollback)
        patch.update(add_source(env, state['meter_source']))
        before = {k: env.get(k) for k in patch if k != 'SUB_USAGE_EXTRA_SOURCES'}
        previous_switched = state['switched'][:]
        state['pending'] = {'before': before, 'patch': patch, 'at': int(time.time()), 'before_sha256': info['sha256'],
                            'after_sha256': digest(patch_env(info['text'], patch).encode()),
                            'rollback_sha256': digest(patch_env(patch_env(info['text'], patch), before).encode()), 'previous_switched': previous_switched}
        save(directory, state)
        try:
            result = publisher(state, 'apply', {'expected': info['sha256'], 'patch': patch})
            state['publisher_sha256'] = result['sha256']; save(directory, state)
            require(result['ok'], 'Pages publication failed')
            state['switched'] = sorted(set(previous_switched) - set(selected) if rollback else set(previous_switched) | set(selected))
            verify_publication(state['portal'], read_private(state['accounts_file']), lines, current_endpoints(state, lines))
            if not rollback:
                remote(state['target'], 'host', 'report')
            source_unchanged(state, manifest)
            state.update(phase='parallel' if state['switched'] else 'rolled_back', pending=None)
            save(directory, state)
            print(json.dumps({'ok': True, 'action': args.action, 'switched': state['switched'], 'old_server_still_running': True, 'subscription_links_unchanged': True})); return
        except Exception:
            # CAS rollback: never clobber concurrent human changes. New source is
            # deliberately retained so target usage cannot disappear on rollback.
            now = publisher(state)
            expected_after = digest(patch_env(info['text'], patch).encode())
            if now['sha256'] == info['sha256']:
                state['switched'] = previous_switched
                state.update(pending=None, phase='parallel' if previous_switched else 'rolled_back')
                save(directory, state)
                raise MigrationError('Publication did not change the publisher; existing endpoints retained')
            require(now['sha256'] == expected_after, 'Publication outcome changed concurrently; pending journal retained for manual reconciliation')
            restored = publisher(state, 'apply', {'expected': now['sha256'], 'patch': before})
            state['publisher_sha256'] = restored['sha256']; state['switched'] = previous_switched
            state['phase'] = 'rollback_needs_verification'; save(directory, state)
            require(restored['ok'], 'Rollback publication failed; both proxies kept running and journal retained')
            verify_publication(state['portal'], read_private(state['accounts_file']), lines, current_endpoints(state, lines))
            state.update(pending=None, phase='parallel' if previous_switched else 'rolled_back'); save(directory, state)
            raise MigrationError('Switch failed; previous endpoints restored and verified. Both hosts and all recorded usage retained.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # No traceback or subprocess contents: they can contain private material.
        print('迁移未完成：' + (str(error) if isinstance(error, MigrationError) else type(error).__name__) + '。现有服务不会被自动停止。', file=sys.stderr)
        sys.exit(1)
