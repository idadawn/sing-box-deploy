"""Linux helper sent over SSH stdin/code; never restarts or edits the source."""
import io
import json
import re
import os
from pathlib import Path
import platform
import pwd
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from core import MigrationError, require, digest, inventory, source_id

CONFIG = Path('/etc/sing-box-gw/config.json')
METER = Path('/etc/subscription-meter-gw/config.json')
BINARY = Path('/opt/sing-box-gw/sing-box')
MARKER = Path('/etc/sing-box-gw/migration.json')


def run(args, input=None, timeout=60):
    result = subprocess.run(args, input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    require(result.returncode == 0, 'Remote command failed: ' + Path(args[0]).name)
    return result.stdout


def private_write(path, data, mode=0o600, gid=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.migration-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(name, mode)
        if gid is not None:
            os.chown(name, 0, gid)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def status():
    data = {'machine': Path('/etc/machine-id').read_text().strip(), 'arch': platform.machine()}
    data['occupied'] = any(Path(p).exists() for p in ('/etc/sing-box-gw', '/opt/sing-box-gw', '/var/lib/sing-box-gw', '/etc/subscription-meter-gw', '/opt/subscription-meter-gw', '/var/lib/subscription-meter-gw'))
    if CONFIG.exists():
        config = json.loads(CONFIG.read_text())
        data['config_sha256'] = digest(CONFIG.read_bytes())
        data['pid'] = run(['systemctl', 'show', 'sing-box-gw', '--property=MainPID', '--value']).decode().strip()
        data['active'] = subprocess.run(['systemctl', 'is-active', '--quiet', 'sing-box-gw']).returncode == 0
        ports = {x['listen_port'] for x in config['inbounds'] if x['type'] == 'trojan'}
        connections = run(['ss', '-Hnt', 'state', 'established']).decode().splitlines()
        data['established_tcp'] = sum(1 for line in connections if len(line.split()) >= 3 and line.split()[2].rsplit(':', 1)[-1].isdigit() and int(line.split()[2].rsplit(':', 1)[-1]) in ports)
        data['hysteria2_sessions'] = 'unknown: UDP sockets do not prove session drain'
    if MARKER.exists():
        data['migration'] = json.loads(MARKER.read_text())
    return data


def pack(files):
    memory = io.BytesIO()
    with tarfile.open(fileobj=memory, mode='w:gz') as archive:
        for name, data in files.items():
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o600
            archive.addfile(entry, io.BytesIO(data))
    return memory.getvalue()


def unpack(data):
    require(len(data) <= 128 * 1024 * 1024, 'Bundle too large')
    files, size = {}, 0
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for entry in archive:
            size += entry.size
            require(entry.isfile() and re.fullmatch(r'[a-zA-Z0-9_.-]+', entry.name) and entry.name not in ('.', '..') and
                    entry.name not in files and size <= 256 * 1024 * 1024 and len(files) < 100, 'Invalid bundle member')
            files[entry.name] = archive.extractfile(entry).read()
    manifest = json.loads(files['manifest.json'])
    require(manifest.get('version') == 1, 'Unsupported bundle version')
    require(set(files) == set(manifest['sha256']) | {'manifest.json'}, 'Bundle manifest mismatch')
    require(all(digest(files[name]) == checksum for name, checksum in manifest['sha256'].items()), 'Bundle integrity failure')
    return files, manifest


def snapshot():
    initial = status()
    config = json.loads(CONFIG.read_text())
    inventory(config)
    meter = json.loads(METER.read_text())
    require(meter['service'] == 'sing-box-gw.service' and meter['sing_box_config'] == str(CONFIG), 'Wrong meter runtime')
    files = {'server.json': CONFIG.read_bytes(), 'meter.json': METER.read_bytes(),
             'sing-box': BINARY.read_bytes(), 'grpcurl': Path(meter['grpcurl']).read_bytes(),
             'report.key': Path(meter['key_file']).read_bytes()}
    mapping = {}
    paths = []
    for entry in config['inbounds']:
        for key in ('certificate_path', 'key_path'):
            paths.append(entry['tls'][key])
    for entry in config.get('route', {}).get('rule_set', []):
        if entry.get('type') == 'local':
            paths.append(entry['path'])
    for index, path in enumerate(dict.fromkeys(paths)):
        require(Path(path).is_absolute() and Path(path).is_file(), 'Missing absolute runtime file')
        name = 'asset-' + str(index)
        mapping[path] = name
        files[name] = Path(path).read_bytes()
    final = status()
    require(initial['config_sha256'] == digest(files['server.json']) == final['config_sha256'] and initial['pid'] == final['pid'], 'Source changed during snapshot')
    manifest = {'version': 1, 'source': final, 'source_id': meter['source'], 'paths': mapping,
                'created_at': int(time.time()), 'sha256': {k: digest(v) for k, v in files.items()}}
    files['manifest.json'] = json.dumps(manifest).encode()
    return pack(files)


def target_config(files, manifest):
    config = json.loads(files['server.json'])
    inventory(config)
    def mapped(path):
        return '/etc/sing-box-gw/assets/' + manifest['paths'][path]
    for entry in config['inbounds']:
        for key in ('certificate_path', 'key_path'):
            entry['tls'][key] = mapped(entry['tls'][key])
    for entry in config.get('route', {}).get('rule_set', []):
        if entry.get('type') == 'local':
            entry['path'] = mapped(entry['path'])
    require(not config.get('log', {}).get('output') and not config.get('experimental', {}).get('cache_file', {}).get('enabled'), 'Unsupported external state path')
    return config


def check_certs(config, files, manifest):
    with tempfile.TemporaryDirectory(prefix='gw-cert-check-') as td:
        for entry in config['inbounds']:
            tls = entry['tls']
            cert, key = Path(td) / 'cert.pem', Path(td) / 'key.pem'
            private_write(cert, files[manifest['paths'][tls['certificate_path']]])
            private_write(key, files[manifest['paths'][tls['key_path']]])
            run(['openssl', 'x509', '-in', str(cert), '-checkend', '604800', '-noout'])
            host_check = run(['openssl', 'x509', '-in', str(cert), '-checkhost', tls['server_name'], '-noout'])
            require(b'does match certificate' in host_check, 'Certificate does not cover SNI')
            public_cert = run(['openssl', 'x509', '-in', str(cert), '-pubkey', '-noout'])
            public_key = run(['openssl', 'pkey', '-in', str(key), '-pubout'])
            require(public_cert == public_key, 'TLS certificate/key mismatch')


def install(files, manifest, options):
    require(os.geteuid() == 0 and platform.system() == 'Linux', 'Target needs Linux and passwordless sudo')
    current = status()
    require(current['machine'] != manifest['source']['machine'], 'Source and target are the same host')
    require(current['arch'] == manifest['source']['arch'], 'Target CPU architecture differs')
    source_id(options['meter_source'])
    require(options['meter_source'] != manifest['source_id'], 'Do not reuse the source ledger identity')
    config = target_config(files, manifest)
    check_certs(json.loads(files['server.json']), files, manifest)
    config_bytes = (json.dumps(config, indent=2) + '\n').encode()
    marker = {'id': options['id'], 'source_machine': manifest['source']['machine'], 'source_config': manifest['source']['config_sha256'],
              'target_config': digest(config_bytes), 'meter_source': options['meter_source']}
    if current['occupied']:
        require(current.get('migration') == marker and CONFIG.read_bytes() == config_bytes and current.get('active'), 'Target is occupied; refuse overwrite/restart')
        return {'already_prepared': True, **current}
    for unit in ('sing-box-gw.service', 'subscription-meter-gw.service', 'subscription-meter-gw.timer'):
        require(not Path('/etc/systemd/system', unit).exists() and run(['systemctl', 'show', unit, '--property=LoadState', '--value']).strip() == b'not-found', 'Existing target unit')
    for command in ('systemctl', 'openssl', 'ss', 'ip', 'useradd'):
        require(shutil.which(command), 'Missing target dependency: ' + command)
    listen = run(['ss', '-Hlnut']).decode()
    import socket
    sockets = []
    try:
        for inbound in config['inbounds'] + [{'type': 'trojan', 'listen_port': 10085}]:
            port = inbound['listen_port']
            require(not re.search(r':' + str(port) + r'\s', listen), 'Target port in use')
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM if inbound['type'] == 'trojan' else socket.SOCK_DGRAM)
            sock.bind(('0.0.0.0', port)); sockets.append(sock)
    finally:
        for sock in sockets:
            sock.close()
    interface = options['interface']
    require(re.fullmatch(r'[A-Za-z0-9_.-]+', interface) and interface != 'lo' and Path('/sys/class/net', interface).exists(), 'Target public interface does not exist')
    try:
        account = pwd.getpwnam('sing-box-gw')
    except KeyError:
        run(['useradd', '--system', '--user-group', '--no-create-home', '--shell', '/usr/sbin/nologin', 'sing-box-gw'])
        account = pwd.getpwnam('sing-box-gw')
    require(account.pw_uid != 0 and account.pw_shell in ('/sbin/nologin', '/usr/sbin/nologin', '/bin/false'), 'Unexpected target service account')
    for directory in ('/etc/sing-box-gw', '/etc/sing-box-gw/assets', '/var/lib/sing-box-gw'):
        Path(directory).mkdir(parents=True, exist_ok=True, mode=0o750)
        os.chown(directory, 0 if directory.startswith('/etc') else account.pw_uid, account.pw_gid)
    private_write(CONFIG, config_bytes, 0o640); os.chown(CONFIG, 0, account.pw_gid)
    private_write(MARKER, json.dumps(marker).encode())
    for name in manifest['paths'].values():
        path = Path('/etc/sing-box-gw/assets') / name
        private_write(path, files[name], 0o640); os.chown(path, 0, account.pw_gid)
    for path, name in ((BINARY, 'sing-box'), (Path('/opt/subscription-meter-gw/grpcurl'), 'grpcurl')):
        private_write(path, files[name], 0o755)
        os.chmod(path.parent, 0o755)
    for name in ('collector.py', 'stats.proto'):
        private_write('/opt/subscription-meter-gw/' + name, files[name])
    private_write('/etc/subscription-meter-gw/report.key', files['report.key'])
    meter = json.loads(files['meter.json'])
    meter.update(source=options['meter_source'], interface=interface, state_file='/var/lib/subscription-meter-gw/state.sqlite3',
                 grpcurl='/opt/subscription-meter-gw/grpcurl', key_file='/etc/subscription-meter-gw/report.key')
    private_write(METER, json.dumps(meter).encode())
    unit = '''[Unit]
Description=GW migration target
After=network-online.target
Wants=network-online.target
[Service]
User=sing-box-gw
Group=sing-box-gw
WorkingDirectory=/var/lib/sing-box-gw
StateDirectory=sing-box-gw
StateDirectoryMode=0700
ExecStartPre=/opt/sing-box-gw/sing-box check -c /etc/sing-box-gw/config.json
ExecStart=/opt/sing-box-gw/sing-box run -c /etc/sing-box-gw/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/sing-box-gw
[Install]
WantedBy=multi-user.target
'''
    private_write('/etc/systemd/system/sing-box-gw.service', unit.encode(), 0o644)
    private_write('/etc/systemd/system/subscription-meter-gw.service', b'''[Unit]
Description=GW independent migration ledger
After=network-online.target sing-box-gw.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/subscription-meter-gw/collector.py /etc/subscription-meter-gw/config.json
UMask=0077
StateDirectory=subscription-meter-gw
StateDirectoryMode=0700
''', 0o644)
    private_write('/etc/systemd/system/subscription-meter-gw.timer', b'''[Unit]
Description=GW migration accounting
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=1s
Persistent=true
[Install]
WantedBy=timers.target
''', 0o644)
    run([str(BINARY), 'check', '-c', str(CONFIG)])
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', '--now', 'sing-box-gw.service'])
    # The fresh ledger queues signed reports until the portal accepts its source.
    # Never copy the original SQLite ledger to a concurrently running collector.
    run(['systemctl', 'enable', '--now', 'subscription-meter-gw.timer'])
    time.sleep(1)
    require(status()['active'], 'Target proxy did not start')
    return status()


def host_main(action, options):
    if action == 'snapshot':
        sys.stdout.buffer.write(snapshot()); return
    if action == 'status':
        print(json.dumps(status())); return
    if action == 'install':
        files, manifest = unpack(sys.stdin.buffer.read())
        print(json.dumps(install(files, manifest, options))); return
    if action == 'sync-certs':
        files, manifest = unpack(sys.stdin.buffer.read())
        marker = json.loads(MARKER.read_text())
        require(marker['id'] == options['id'] and marker['source_config'] == manifest['source']['config_sha256'] and
                digest(CONFIG.read_bytes()) == marker['target_config'], 'Certificate sync target/config mismatch')
        config = json.loads(files['server.json'])
        check_certs(config, files, manifest)
        gid = pwd.getpwnam('sing-box-gw').pw_gid
        for entry in config['inbounds']:
            for field in ('key_path', 'certificate_path'):
                name = manifest['paths'][entry['tls'][field]]
                path = Path('/etc/sing-box-gw/assets') / name
                if path.read_bytes() != files[name]:
                    private_write(path, files[name], 0o640, gid=gid)
        print(json.dumps({'ok': True, 'restarted': False})); return
    if action == 'report':
        result = json.loads(run(['python3', '/opt/subscription-meter-gw/collector.py', str(METER)]))
        require(result.get('reports_sent', 0) > 0 and not result.get('unavailable'), 'Target metering is not complete/accepted')
        print(json.dumps(result)); return
    raise MigrationError('Unknown host action')
