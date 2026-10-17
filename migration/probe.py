"""Independent loopback-only client probes; never touches the user's client."""
import base64
import json
import ipaddress
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from core import require, client_node

IP_TARGETS = ('https://api.ipify.org', 'https://api.ip.sb/ip')


def probe_node(binary, node, expected):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix='gw-migration-probe-') as td:
        config = {'mixed-port': port, 'bind-address': '127.0.0.1', 'allow-lan': False,
                  'log-level': 'silent', 'mode': 'rule', 'ipv6': False,
                  'tun': {'enable': False}, 'proxies': [node], 'rules': ['MATCH,' + node['name']]}
        path = Path(td) / 'config.json'
        path.write_text(json.dumps(config)); path.chmod(0o600)
        with (Path(td) / 'client.log').open('wb') as log:
            process = subprocess.Popen([str(binary), '-d', td, '-f', str(path)], stdout=log, stderr=subprocess.STDOUT)
            try:
                ready = False
                for _ in range(80):
                    require(process.poll() is None, 'Isolated client exited')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.2):
                            ready = True; break
                    except OSError:
                        time.sleep(.1)
                require(ready, 'Isolated client did not start')
                for target in IP_TARGETS:
                    success = False
                    for attempt in range(3):
                        result = subprocess.run(['curl', '-q', '--silent', '--show-error', '--fail', '--proxy', 'http://127.0.0.1:' + str(port),
                                                 '--noproxy', '', '--connect-timeout', '8', '--max-time', '20', target],
                                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
                        observed = result.stdout.decode().strip()
                        try:
                            is_ip = bool(ipaddress.ip_address(observed))
                        except ValueError:
                            is_ip = False
                        if result.returncode == 0 and is_ip:
                            require(observed == expected, 'Wrong fixed egress for ' + node['name'])
                            success = True; break
                        if attempt < 2:
                            time.sleep(attempt + 1)
                    require(success, 'Egress probe failed for ' + node['name'] + ' via ' + urllib.parse.urlparse(target).hostname + ' (curl ' + str(result.returncode) + ')')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()


def verify_nodes(binary, lines, server, direct_exit, selected=None):
    results = []
    for ident, line in lines.items():
        if selected is not None and ident not in selected:
            continue
        expected = direct_exit if ident == 'tx' else line['expected_exit']
        for kind in ('trojan', 'hysteria2'):
            node = client_node(ident, line, kind, server)
            probe_node(binary, node, expected)
            results.append({'line': ident, 'protocol': kind, 'exit': expected, 'ok': True})
            print(json.dumps(results[-1]), flush=True)
    return results


def verify_publication(origin, accounts, lines, endpoints):
    require(origin.startswith('https://') and urllib.parse.urlparse(origin).path in ('', '/'), 'Expected HTTPS portal origin')
    require(len(accounts) >= 2 and any(not a.get('can_view_all') for a in accounts), 'Need admin and ordinary account verification')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def fetch(path, token=None):
        request = urllib.request.Request(origin + path, headers={'User-Agent': 'Clash.Meta', **({'Authorization': 'Bearer ' + token} if token else {})})
        try:
            with opener.open(request, timeout=20) as response:
                require(response.url == origin + path, 'Unexpected portal redirect')
                return response.status, response.headers, response.read(2 * 1024 * 1024)
        except urllib.error.HTTPError as error:
            return error.code, error.headers, b''
    for path in ('/v2', '/tx-v2', '/c', '/s'):
        require(fetch(path)[0] == 401, 'Anonymous subscription unexpectedly accessible')
    checked = set()
    for account in accounts:
        for ident in account['scopes']:
            require(ident in lines, 'Unexpected verification scope')
            path = '/tx-v2' if ident == 'tx' else '/v2?isp=' + ident
            code, headers, body = fetch(path, account['token'])
            require(code == 200 and headers.get('Subscription-Userinfo'), 'Existing subscription or traffic metadata unavailable')
            uris = base64.b64decode(body).decode().splitlines()
            require(len(uris) == 2, 'Unexpected node count')
            found = set()
            for raw in uris:
                uri = urllib.parse.urlparse(raw)
                kind = {'trojan': 'trojan', 'hysteria2': 'hysteria2'}.get(uri.scheme)
                require(kind in lines[ident] and kind not in found, 'Unexpected subscription protocol')
                found.add(kind)
                node, params = lines[ident][kind], urllib.parse.parse_qs(uri.query)
                require(uri.hostname == endpoints[ident] and uri.port == node['port'] and
                        urllib.parse.unquote(uri.username or '') == node['password'], 'Published endpoint or credentials mismatch')
                require(params.get('sni') == [node['sni']], 'Published SNI mismatch')
                if kind == 'hysteria2':
                    require(params.get('obfs-password') == [node['obfs']], 'Published obfuscation mismatch')
            checked.add(ident)
        foreign = next((i for i in lines if i != 'tx' and i not in account['scopes']), None)
        if foreign:
            require(fetch('/v2?isp=' + foreign, account['token'])[0] == 403, 'Cross-account scope leak')
    require(checked == set(lines), 'Verification accounts do not cover every line')
    return True
