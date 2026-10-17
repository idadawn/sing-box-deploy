"""Guarded changes to the authenticated Pages publisher, never the proxy units."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
from core import require, parse_env, patch_env, publisher_guard, digest

MANAGED = {'ISP_INGRESS_OVERRIDES', 'TX_DIRECT_IP', 'SUB_USAGE_EXTRA_SOURCES'}


def atomic(path, data):
    fd, temp = tempfile.mkstemp(prefix='.migration-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def inspect(directory):
    env_file = directory / '.env'
    require(env_file.is_file() and not env_file.is_symlink() and env_file.stat().st_mode & 0o077 == 0, 'Publisher env must be private')
    text = env_file.read_text()
    env = parse_env(text)
    publisher_guard(env, (directory / 'cloudflare-pages-sub/.subscriptions-retired').exists())
    require('SUB_USAGE_EXTRA_SOURCES' in (directory / 'scripts/build-auth.mjs').read_text(), 'Update the publisher repository to the migration-capable release first')
    path = Path(env['SUB_AUTH_ISP_CREDENTIALS_FILE'])
    if not path.is_absolute():
        path = directory / path
    require(path.stat().st_mode & 0o077 == 0, 'Private credentials have unsafe permissions')
    return {'text': text, 'sha256': digest(text.encode()), 'credentials': json.loads(path.read_text())}


def publisher_main(action, options, request):
    directory = Path(options['directory'])
    require(directory.is_absolute() and directory.is_dir(), 'Expected absolute publisher directory')
    if action == 'read':
        print(json.dumps(inspect(directory))); return
    require(action == 'apply' and set(request['patch']) <= MANAGED, 'Invalid publisher operation')
    private = directory / '.migration-private'
    private.mkdir(mode=0o700, exist_ok=True)
    require(not private.is_symlink() and private.stat().st_mode & 0o077 == 0, 'Unsafe migration state directory')
    with (private / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = inspect(directory)
        require(current['sha256'] == request['expected'], 'Publisher changed since plan; refusing stale overwrite')
        before, patch = current['text'], request['patch']
        old_env = parse_env(before)
        # Meter sources can only be added by migration, including during rollback.
        if 'SUB_USAGE_EXTRA_SOURCES' in patch:
            old_sources = set(filter(None, old_env.get('SUB_USAGE_EXTRA_SOURCES', '').split(',')))
            new_sources = set(filter(None, patch['SUB_USAGE_EXTRA_SOURCES'].split(',')))
            require(old_sources <= new_sources, 'Cannot remove historical meter sources')
        after = patch_env(before, patch)
        name = digest(before.encode())[:16]
        atomic(private / (name + '.env'), before.encode())
        atomic(private / 'pending.json', json.dumps({'before': name, 'after': digest(after.encode()), 'patch': patch}).encode())
        atomic(directory / '.env', after.encode())
        log_path = private / 'publish.log'
        with log_path.open('wb') as log:
            result = subprocess.run(['bash', 'install.sh', '--pages-only'], cwd=str(directory), stdout=log, stderr=subprocess.STDOUT, timeout=600)
        # On errors retain the journal and exact state for recovery. The caller
        # restores endpoint fields, preserving any newly accepted metering data.
        print(json.dumps({'ok': result.returncode == 0, 'sha256': digest(after.encode()), 'log': str(log_path)}))
        if result.returncode == 0:
            (private / 'pending.json').unlink()
