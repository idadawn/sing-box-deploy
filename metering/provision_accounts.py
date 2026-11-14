"""Prepare account credentials/statistics without changing routes or shared obfs."""
import argparse
import copy
import json
import os
from pathlib import Path
import re


def prepare(runtime, meter, accounts):
    result, collector = copy.deepcopy(runtime), copy.deepcopy(meter)
    if not accounts or len(accounts) > 64 or not collector.get('kiwivm'):
        raise ValueError('Accounts and KiwiVM configuration required')
    existing = {u['name'].removeprefix('account-') for entry in runtime['inbounds'] for u in entry.get('users', []) if u.get('name', '').startswith('account-')}
    if not existing.issubset(accounts):
        raise ValueError('Existing accounts require a coordinated retirement')
    scopes = {'tx'} | {tag.removeprefix('isp-out-') for tag in [o['tag'] for o in runtime['outbounds']] if tag.startswith('isp-out-')}
    secrets = set()
    for name, value in accounts.items():
        if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,31}', name) or not value.get('scopes') or not set(value['scopes']).issubset(scopes):
            raise ValueError('Invalid account scopes')
        for kind in ['trojan', 'hysteria']:
            password = value.get(kind, '')
            if not re.fullmatch(r'[A-Za-z0-9_-]{32,128}', password) or password in secrets:
                raise ValueError('Account credentials must be strong and distinct')
            secrets.add(password)
    legacy_names = []
    reached = {name: set() for name in accounts}
    for inbound in result['inbounds']:
        tag, kind = inbound['tag'], inbound['type']
        if kind not in ['trojan', 'hysteria2']:
            raise ValueError('Unsupported account inbound')
        match = re.fullmatch(r'(?:trojan|hy2)-([a-z0-9_-]+)-in', tag)
        scope = 'tx' if tag in ['tx-trojan-in', 'tx-hy2-in'] else match.group(1) if match else None
        if scope not in scopes:
            raise ValueError('Unknown account inbound')
        users = []
        for index, user in enumerate(inbound['users']):
            if user.get('name', '').startswith('account-'):
                continue
            if user['password'] in secrets:
                raise ValueError('New credentials overlap legacy credentials')
            user['name'] = user['name'] if user.get('name', '').startswith('legacy-') else 'legacy-' + tag + '-' + str(index)
            legacy_names.append(user['name']); users.append(user)
        for name, account in accounts.items():
            if scope in account['scopes']:
                users.append({'name': 'account-' + name, 'password': account['trojan' if kind == 'trojan' else 'hysteria']})
                reached[name].add((scope, kind))
        inbound['users'] = users
    for name, value in accounts.items():
        if reached[name] != {(scope, kind) for scope in value['scopes'] for kind in ['trojan', 'hysteria2']}:
            raise ValueError('Account missing an authorized protocol/line')
    users = {name: ['account-' + name] for name in accounts}
    if legacy_names:
        users['__legacy__'] = sorted(set(legacy_names))
    stats = result['experimental']['v2ray_api']['stats']
    if not stats['enabled']:
        raise ValueError('Statistics must be enabled')
    stats['users'] = sorted({user for values in users.values() for user in values})
    collector['account_users'] = users
    return result, collector


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['runtime', 'meter', 'accounts', 'output_runtime', 'output_meter']:
        parser.add_argument(name)
    args = parser.parse_args()
    paths = [Path(getattr(args, name)) for name in ['runtime', 'meter', 'accounts']]
    if any(path.stat().st_mode & 0o077 for path in paths):
        raise ValueError('Private input files must be 0600')
    outputs = prepare(*(json.loads(path.read_text()) for path in paths))
    for path, value in zip([args.output_runtime, args.output_meter], outputs):
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
            json.dump(value, stream, indent=2)
    print('Prepared account-metered configuration; live services unchanged.')


if __name__ == '__main__':
    main()
