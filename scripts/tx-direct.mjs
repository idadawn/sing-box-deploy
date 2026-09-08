import { readFileSync, writeFileSync } from 'node:fs';
import { isIP } from 'node:net';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const LOCAL_CIDRS = [
  '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
  '172.16.0.0/12', '192.168.0.0/16', '::1/128', 'fc00::/7', 'fe80::/10',
];
const csv = value => (value || '').split(/[\s,]+/).filter(Boolean);
const b64 = value => Buffer.from(value).toString('base64');

export function settings(env) {
  for (const key of ['TX_DIRECT_IP', 'TX_DIRECT_TROJAN_PASSWORD',
    'TX_DIRECT_HYSTERIA_PASSWORD', 'TX_DIRECT_OBFS_PASSWORD',
    'TROJAN_DOMAIN', 'HYSTERIA_DOMAIN']) {
    if (!env[key]) throw new Error(`Missing ${key}`);
  }
  if (isIP(env.TX_DIRECT_IP) !== 4) throw new Error('TX_DIRECT_IP must be an IPv4 address');
  for (const key of ['TX_DIRECT_TROJAN_PASSWORD', 'TX_DIRECT_HYSTERIA_PASSWORD', 'TX_DIRECT_OBFS_PASSWORD']) {
    if (!/^[A-Za-z0-9_-]{24,128}$/.test(env[key])) throw new Error(`${key} must be 24-128 URL-safe characters`);
  }
  for (const key of ['TROJAN_DOMAIN', 'HYSTERIA_DOMAIN']) {
    if (!/^[a-zA-Z0-9.-]+$/.test(env[key])) throw new Error(`Invalid ${key}`);
  }
  const port = (key, fallback) => {
    const value = Number(env[key] || fallback);
    if (!Number.isInteger(value) || value < 1 || value > 65535) throw new Error(`Invalid ${key}`);
    return value;
  };
  const trojan = port('TX_DIRECT_TROJAN_PORT', 443);
  const hysteria = port('TX_DIRECT_HYSTERIA_PORT', 8443);
  if (trojan === hysteria) throw new Error('TX direct ports must be distinct');
  const cidrs = [...new Set([...LOCAL_CIDRS, ...csv(env.CLIENT_DIRECT_IP_CIDRS)])];
  return { trojan, hysteria, cidrs };
}

export function buildConfig(env) {
  const { trojan, hysteria, cidrs } = settings(env);
  if (!env.CF_DNS_EDIT_TOKEN || !env.ACME_EMAIL) throw new Error('Missing DNS-01 credentials');
  const tls = (domain, alpn) => ({
    enabled: true, server_name: domain, alpn,
    acme: {
      domain: [domain], data_directory: '/var/lib/sing-box-tx-direct/certmagic',
      email: env.ACME_EMAIL, provider: 'letsencrypt',
      disable_http_challenge: true, disable_tls_alpn_challenge: true,
      dns01_challenge: {
        provider: 'cloudflare', api_token: env.CF_DNS_EDIT_TOKEN,
        ...(env.CF_ZONE_READ_TOKEN ? { zone_token: env.CF_ZONE_READ_TOKEN } : {}),
      },
    },
  });
  return {
    log: { level: 'info', timestamp: true },
    dns: { servers: [{ type: 'local', tag: 'dns-local' }] },
    inbounds: [
      { type: 'trojan', tag: 'tx-trojan-in', listen: '::', listen_port: trojan,
        tcp_fast_open: true, users: [{ name: 'tx', password: env.TX_DIRECT_TROJAN_PASSWORD }],
        tls: tls(env.TROJAN_DOMAIN, ['h2', 'http/1.1']) },
      { type: 'hysteria2', tag: 'tx-hy2-in', listen: '::', listen_port: hysteria,
        ignore_client_bandwidth: true,
        users: [{ name: 'tx', password: env.TX_DIRECT_HYSTERIA_PASSWORD }],
        obfs: { type: 'salamander', password: env.TX_DIRECT_OBFS_PASSWORD },
        tls: tls(env.HYSTERIA_DOMAIN, ['h3']) },
    ],
    outbounds: [{ type: 'direct', tag: 'tx-direct-out' }, { type: 'block', tag: 'block' }],
    route: {
      rules: [
        { action: 'resolve', strategy: 'ipv4_only' },
        // Never turn the new public proxy into a gateway to TX's LAN/metadata.
        { ip_cidr: [...new Set([...cidrs, '0.0.0.0/8', '224.0.0.0/4', '240.0.0.0/4', '::/128', 'ff00::/8'])], action: 'reject' },
        { inbound: ['tx-trojan-in', 'tx-hy2-in'], outbound: 'tx-direct-out' },
      ],
      final: 'block', auto_detect_interface: true, default_domain_resolver: 'dns-local',
    },
  };
}

export function renderPages(source, env) {
  if (!/^(true|1|yes|on)$/i.test(env.TX_DIRECT_ENABLED || 'false')) {
    const disabled = 'export function onRequest() { return new Response("TX direct is disabled", { status: 410 }); }\n';
    return { 'tx.js': disabled, 'tx-v2.js': disabled };
  }
  const { trojan, hysteria, cidrs } = settings(env);
  const extract = marker => {
    const start = source.indexOf(`<<'${marker}'\n`);
    if (start < 0) throw new Error(`Missing template ${marker}`);
    const offset = start + `<<'${marker}'\n`.length;
    const end = source.indexOf(`\n${marker}\n`, offset);
    if (end < 0) throw new Error(`Unterminated template ${marker}`);
    return source.slice(offset, end);
  };
  const entries = [{ id: 'tx', host: env.TX_DIRECT_IP, expires: '9999-12-31',
    trojan_port: trojan, hysteria_port: hysteria }];
  const replacements = {
    ISP_PUBLIC_LIST_BASE64_PLACEHOLDER: b64(JSON.stringify(entries)),
    TROJAN_DOMAIN_PLACEHOLDER: env.TROJAN_DOMAIN,
    HYSTERIA_DOMAIN_PLACEHOLDER: env.HYSTERIA_DOMAIN,
    TROJAN_PASSWORD_PLACEHOLDER: env.TX_DIRECT_TROJAN_PASSWORD,
    HYSTERIA_PASSWORD_PLACEHOLDER: env.TX_DIRECT_HYSTERIA_PASSWORD,
    HYSTERIA_OBFS_PLACEHOLDER: env.TX_DIRECT_OBFS_PASSWORD,
    CLIENT_DIRECT_IP_CIDRS_BASE64_PLACEHOLDER: b64(cidrs.join(',')),
    AI_ISP_DOMAINS_BASE64_PLACEHOLDER: b64(env.AI_ISP_DOMAINS || ''),
    DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER: b64(env.DIRECT_BULK_DOMAINS || ''),
    DIRECT_BULK_ENABLED_PLACEHOLDER: 'true',
    DIRECT_BULK_APPS_JSON_PLACEHOLDER: '["telegram"]',
    CLASH_FORCE_TCP_DOMAINS_BASE64_PLACEHOLDER: b64(env.CLASH_FORCE_TCP_DOMAINS || ''),
    CLASH_FORCE_TCP_ENABLED_PLACEHOLDER: /^(true|1|yes|on)$/i.test(env.CLASH_FORCE_TCP_ENABLED || 'true') ? 'true' : 'false',
    HYSTERIA_USE_BBR_PLACEHOLDER: 'true',
    HYSTERIA_UP_PLACEHOLDER: '100', HYSTERIA_DOWN_PLACEHOLDER: '100',
    CLASH_RULESET_BASE_URL_PLACEHOLDER: env.CLASH_RULESET_BASE_URL,
    SECRET_PLACEHOLDER: env.TX_DIRECT_TROJAN_PASSWORD,
  };
  const render = marker => {
    let code = extract(marker);
    for (const [key, value] of Object.entries(replacements)) code = code.replaceAll(key, value || '');
    if (/[A-Z][A-Z0-9_]*_PLACEHOLDER/.test(code)) throw new Error('Unresolved TX template placeholder');
    // IP is the entry address; domain SNI still provides normal TLS validation.
    code = code.replaceAll(`@${env.TROJAN_DOMAIN}:`, `@${env.TX_DIRECT_IP}:`)
      .replaceAll(`@${env.HYSTERIA_DOMAIN}:`, `@${env.TX_DIRECT_IP}:`)
      .replaceAll(`server: ${env.TROJAN_DOMAIN}\n`, `server: ${env.TX_DIRECT_IP}\n`)
      .replaceAll(`server: ${env.HYSTERIA_DOMAIN}\n`, `server: ${env.TX_DIRECT_IP}\n`)
      .replaceAll("requestedIsp || 'all-isps'", "'tx-direct'")
      .replaceAll('expire=${expire}', 'expire=0')
      .replaceAll('🛡️ ISP 出口自动', '🛡️ TX 出口');
    return code + '\n';
  };
  return { 'tx.js': render('CJS'), 'tx-v2.js': render('V2JS') };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [mode, target] = process.argv.slice(2);
    if (mode === 'config') {
      writeFileSync(target, JSON.stringify(buildConfig(process.env), null, 2) + '\n', { mode: 0o600 });
    } else if (mode === 'pages') {
      const source = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
      for (const [name, code] of Object.entries(renderPages(source, process.env))) {
        writeFileSync(resolve(target, 'functions', name), code, { mode: 0o600 });
      }
    } else {
      throw new Error('Usage: tx-direct.mjs config <file> | pages <directory>');
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
