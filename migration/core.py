"""Pure validation and endpoint patching for the isolated GW deployment."""
import copy
import hashlib
import ipaddress
import json
import re


class MigrationError(Exception):
    pass


def require(value, message):
    if not value:
        raise MigrationError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_id(value):
    require(isinstance(value, str) and re.fullmatch(r'[a-z0-9-]{1,40}', value), 'Invalid meter source')
    return value


def address(value):
    require(ipaddress.ip_address(value).version == 4, 'Target address must be IPv4')
    return value


def inventory(config):
    require(config.get('route', {}).get('final') == 'block', 'Expected fail-closed GW routing')
    require(not config.get('endpoints') and not config.get('services'), 'Unsupported extra runtime components')
    stats = config.get('experimental', {}).get('v2ray_api', {})
    require(stats.get('listen') == '127.0.0.1:10085' and stats.get('stats', {}).get('enabled'), 'Expected isolated loopback statistics')
    outbounds = {o['tag']: o for o in config['outbounds']}
    result, ports = {}, set()
    for inbound in config['inbounds']:
        tag, kind = inbound['tag'], inbound['type']
        match = re.fullmatch(r'(trojan|hy2)-([a-z0-9_-]+)-in', tag)
        ident = 'tx' if tag in ('tx-trojan-in', 'tx-hy2-in') else match.group(2) if match else None
        require(ident and kind in ('trojan', 'hysteria2'), 'Unsupported GW inbound')
        require((kind == 'trojan') == (tag.startswith('trojan-') or tag == 'tx-trojan-in'), 'Protocol/tag mismatch')
        port = inbound['listen_port']
        require(type(port) is int and 1 <= port <= 65535 and port not in ports, 'Duplicate or invalid port')
        ports.add(port)
        tls = inbound.get('tls', {})
        require(tls.get('enabled') and tls.get('certificate_path') and tls.get('key_path') and
                not tls.get('acme') and not tls.get('certificate_provider'), 'Only file-based GW TLS is supported')
        require(re.fullmatch(r'[A-Za-z0-9.-]+', tls.get('server_name', '')), 'Invalid SNI')
        users = inbound.get('users', [])
        require(len(users) == 1 and users[0].get('password'), 'Expected one private credential per inbound')
        outbound = 'tx-direct-out' if ident == 'tx' else 'isp-out-' + ident
        require(outbound in outbounds and outbounds[outbound]['type'] == ('direct' if ident == 'tx' else 'socks'), 'Unexpected egress mapping')
        routes = [r for r in config['route'].get('rules', []) if r.get('outbound') == outbound and tag in r.get('inbound', [])]
        require(routes, 'Missing fixed inbound-to-egress rule')
        line = result.setdefault(ident, {'expected_exit': None if ident == 'tx' else outbounds[outbound]['server']})
        require(kind not in line, 'Duplicate protocol for line')
        line[kind] = {'port': port, 'sni': tls['server_name'], 'password': users[0]['password']}
        if kind == 'hysteria2':
            require(inbound.get('obfs', {}).get('type') == 'salamander', 'Expected salamander obfuscation')
            line[kind]['obfs'] = inbound['obfs']['password']
    require(result and all('trojan' in v and 'hysteria2' in v for v in result.values()), 'Incomplete protocol pairs')
    return result


def parse_env(text):
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        require(re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', line), 'Invalid publisher env syntax')
        key, value = line.split('=', 1)
        require(key not in values, 'Duplicate publisher env key')
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            quote, value = value[0], value[1:-1]
            if quote == '"':
                value = value.replace('\\n', '\n').replace('\\\\', '\\')
        values[key] = value
    return values


def patch_env(text, patch):
    parse_env(text)
    remaining, lines = dict(patch), []
    for line in text.splitlines():
        key = line.strip().split('=', 1)[0]
        if key in remaining:
            value = remaining.pop(key)
            if value is not None:
                require('\n' not in value and "'" not in value, 'Unsafe env patch')
                lines.append(key + "='" + value + "'")
        else:
            lines.append(line)
    for key, value in remaining.items():
        if value is not None:
            require('\n' not in value and "'" not in value, 'Unsafe env patch')
            lines.append(key + "='" + value + "'")
    return '\n'.join(lines) + '\n'


def publisher_guard(env, directory_retired=False):
    require(env.get('SUB_AUTH_ENABLED', '').lower() in ('true', '1', 'yes', 'on'), 'Publisher must be authenticated')
    require(not directory_retired and env.get('SUB_LEGACY_RETIRED', '').lower() not in ('true', '1', 'yes', 'on'), 'Refusing retired publisher')
    require(env.get('CF_PAGES_PROJECT') and env.get('SUB_AUTH_D1_ID') and env.get('SUB_AUTH_ISP_CREDENTIALS_FILE'), 'Expected private GW publisher')


def endpoint_patch(env, original, lines, selected, target_ip, rollback=False):
    require(selected and set(selected) <= set(lines), 'Unknown or empty line selection')
    current = json.loads(env.get('ISP_INGRESS_OVERRIDES') or '{}')
    old = json.loads(original.get('ISP_INGRESS_OVERRIDES') or '{}')
    for ident in selected:
        if ident == 'tx':
            continue
        if rollback:
            if ident in old:
                current[ident] = old[ident]
            else:
                current.pop(ident, None)
        else:
            require(lines[ident]['trojan']['sni'] == lines[ident]['hysteria2']['sni'], 'Per-line SNI differs')
            current[ident] = {'server': target_ip, 'sni': lines[ident]['trojan']['sni']}
    patch = {'ISP_INGRESS_OVERRIDES': json.dumps(current, separators=(',', ':'))}
    if 'tx' in selected:
        patch['TX_DIRECT_IP'] = original['TX_DIRECT_IP'] if rollback else target_ip
    return patch


def add_source(env, new_source):
    source_id(new_source)
    existing = [x.strip() for x in env.get('SUB_USAGE_EXTRA_SOURCES', '').split(',') if x.strip()]
    require(new_source != env.get('SUB_USAGE_SOURCE', 'la'), 'Target must use a distinct meter source')
    sources = list(dict.fromkeys(existing + [new_source]))
    require(len(sources) < 16 and all(source_id(x) for x in sources), 'Too many meter sources')
    return {'SUB_USAGE_EXTRA_SOURCES': ','.join(sources)}


def client_node(ident, line, kind, server):
    p = line[kind]
    node = {'name': ident.upper() + ('-TJ' if kind == 'trojan' else '-HY2'), 'type': kind,
            'server': server, 'port': p['port'], 'password': p['password'], 'sni': p['sni'],
            'skip-cert-verify': False, 'udp': True}
    if kind == 'hysteria2':
        node.update({'obfs': 'salamander', 'obfs-password': p['obfs']})
    return node
