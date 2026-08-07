#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

file_mode() {
  local path="$1"
  if stat -c '%a' "${path}" >/dev/null 2>&1; then
    stat -c '%a' "${path}"
  else
    stat -f '%Lp' "${path}"
  fi
}

for script in install.sh manage.sh migrate.sh setup-ssh.sh sync-clash-rules.sh; do
  bash -n "${ROOT_DIR}/${script}"
done

INSTALL_HELP="$("${ROOT_DIR}/install.sh" --help)"
grep -Fq -- '--skip-egress-preflight' <<< "${INSTALL_HELP}"
grep -Fq -- '--skip-pages' <<< "${INSTALL_HELP}"
grep -Fq -- '--pages-only' <<< "${INSTALL_HELP}"
grep -Fq 'preflight_isp_egress' "${ROOT_DIR}/install.sh"
grep -Fq 'LimitNOFILE=1048576' "${ROOT_DIR}/install.sh"

(
  source "${ROOT_DIR}/install.sh"
  call_trace=""
  require_supported_os() { :; }
  load_env() {
    CF_API_TOKEN="test-token"
    CF_ACCOUNT_ID="test-account"
    SUB_DOMAIN="sub.example.com"
  }
  validate_config() { :; }
  require_root() { :; }
  curl() { :; }
  flock() { :; }
  git() { :; }
  jq() { :; }
  wrangler() { :; }
  build_isp_json() { call_trace="${call_trace}build,"; }
  update_cloudflare_pages() { call_trace="${call_trace}pages,"; }
  install_dependencies() {
    echo "pages-only unexpectedly entered the data-plane install path" >&2
    return 99
  }
  setup_clash_rules_sync_timer() {
    echo "pages-only unexpectedly modified the systemd timer" >&2
    return 99
  }

  main --pages-only
  [[ "${call_trace}" == "build,pages," ]]

  PAGES_STAGE_ROOT="${TMP_DIR}/pages-activation"
  mkdir -p "${PAGES_STAGE_ROOT}/staged" "${PAGES_STAGE_ROOT}/live"
  printf '%s\n' staged > "${PAGES_STAGE_ROOT}/staged/version"
  printf '%s\n' live > "${PAGES_STAGE_ROOT}/live/version"
  activate_staged_pages "${PAGES_STAGE_ROOT}/staged" "${PAGES_STAGE_ROOT}/live"
  grep -Fxq staged "${PAGES_STAGE_ROOT}/live/version"
  grep -Fxq live "${PAGES_STAGE_ROOT}/previous-pages/version"
  discard_pages_stage
  [[ ! -e "${TMP_DIR}/pages-activation" ]]
)

if (
  source "${ROOT_DIR}/install.sh"
  parse_args --pages-only --validate-only
) >/dev/null 2>&1; then
  echo "Expected --pages-only and --validate-only to be mutually exclusive" >&2
  exit 1
fi

extract_heredoc() {
  local start="$1"
  local end="$2"
  local destination="$3"
  awk -v start="${start}" -v end="${end}" '
    $0 == start { copying = 1; next }
    $0 == end { copying = 0; exit }
    copying { print }
  ' "${ROOT_DIR}/install.sh" > "${destination}"
}

render_js_template() {
  local source="$1"
  local destination="$2"
  sed \
    -e 's|ISP_PUBLIC_LIST_BASE64_PLACEHOLDER|W3siaWQiOiJkZW1vIiwiZXhwaXJlcyI6IjIwOTktMTItMzEiLCJ0cm9qYW5fcG9ydCI6NDQzLCJoeXN0ZXJpYV9wb3J0Ijo4NDQzfSx7ImlkIjoiYmFja3VwIiwiZXhwaXJlcyI6IjIwOTktMTItMzEiLCJ0cm9qYW5fcG9ydCI6MTQ0MywiaHlzdGVyaWFfcG9ydCI6OTQ0M31d|g' \
    -e 's/AI_ISP_DOMAINS_BASE64_PLACEHOLDER/YWkuZXhhbXBsZQ==/g' \
    -e 's/DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER/YnVsay5leGFtcGxl/g' \
    -e 's/CLIENT_DIRECT_IP_CIDRS_BASE64_PLACEHOLDER/MjAzLjAuMTEzLjQyLzMy/g' \
    -e 's|AI_ISP_DOMAINS_JSON_PLACEHOLDER|["ai.example"]|g' \
    -e 's|DIRECT_BULK_DOMAINS_JSON_PLACEHOLDER|["bulk.example"]|g' \
    -e 's/DIRECT_BULK_APPS_JSON_PLACEHOLDER/[]/g' \
    -e 's|CLIENT_DIRECT_IP_CIDRS_JSON_PLACEHOLDER|["203.0.113.42/32"]|g' \
    -e 's|CLASH_FORCE_TCP_DOMAINS_BASE64_PLACEHOLDER|Z2l0aHViLmNvbSxnb29nbGUuY29tLHguY29t|g' \
    -e 's|CLASH_FORCE_TCP_DOMAINS_JSON_PLACEHOLDER|["github.com","google.com","x.com"]|g' \
    -e 's/CLASH_FORCE_TCP_ENABLED_PLACEHOLDER/true/g' \
    -e 's/DIRECT_BULK_ENABLED_PLACEHOLDER/true/g' \
    -e 's/HYSTERIA_USE_BBR_PLACEHOLDER/true/g' \
    -e 's/HYSTERIA_UP_PLACEHOLDER/100/g' \
    -e 's/HYSTERIA_DOWN_PLACEHOLDER/100/g' \
    -e 's/[A-Z][A-Z0-9_]*_PLACEHOLDER/test/g' \
    "${source}" > "${destination}"
}

if command -v node >/dev/null 2>&1; then
  extract_heredoc "  cat > \"\${functions_dir}/v2.js\" <<'V2JS'" "V2JS" "${TMP_DIR}/v2.template"
  extract_heredoc "  cat > \"\${functions_dir}/sr.js\" <<'SRJS'" "SRJS" "${TMP_DIR}/sr.template"
  extract_heredoc "  cat > \"\${functions_dir}/c.js\" <<'CJS'" "CJS" "${TMP_DIR}/c.template"
  extract_heredoc "  cat > \"\${pages_dir}/global-extension.js\" <<'GLOBALJS'" "GLOBALJS" "${TMP_DIR}/global.template"
  render_js_template "${TMP_DIR}/v2.template" "${TMP_DIR}/v2.mjs"
  render_js_template "${TMP_DIR}/sr.template" "${TMP_DIR}/sr.mjs"
  render_js_template "${TMP_DIR}/c.template" "${TMP_DIR}/c.mjs"
  render_js_template "${TMP_DIR}/global.template" "${TMP_DIR}/global.mjs"
  sed 's/const forceTcpEnabled = true;/const forceTcpEnabled = false;/' \
    "${TMP_DIR}/c.mjs" > "${TMP_DIR}/c-disabled.mjs"
  sed 's/const FORCE_TCP_ENABLED = true;/const FORCE_TCP_ENABLED = false;/' \
    "${TMP_DIR}/global.mjs" > "${TMP_DIR}/global-disabled.mjs"
  node --check "${TMP_DIR}/v2.mjs"
  node --check "${TMP_DIR}/sr.mjs"
  node --check "${TMP_DIR}/c.mjs"
  node --check "${TMP_DIR}/global.mjs"
  node --check "${TMP_DIR}/c-disabled.mjs"
  node --check "${TMP_DIR}/global-disabled.mjs"
  node --input-type=module - "${TMP_DIR}/v2.mjs" "${TMP_DIR}/c.mjs" "${TMP_DIR}/sr.mjs" "${TMP_DIR}/global.mjs" "${TMP_DIR}/c-disabled.mjs" "${TMP_DIR}/global-disabled.mjs" <<'NODE'
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { pathToFileURL } from "node:url";

const v2Module = await import(pathToFileURL(process.argv[2]));
const clashModule = await import(pathToFileURL(process.argv[3]));
const shadowrocketModule = await import(pathToFileURL(process.argv[4]));
const clashDisabledModule = await import(pathToFileURL(process.argv[6]));

const v2Response = await v2Module.onRequest({
  request: new Request("https://sub.example/v2?isp=demo&raw=1"),
});
const v2Body = await v2Response.text();
assert.equal(v2Response.status, 200);
assert.equal(v2Response.headers.get("profile-title"), "demo");
assert.equal(v2Response.headers.get("profile-update-interval"), "24");
assert.match(v2Response.headers.get("content-disposition"), /filename=demo/);
assert.match(v2Response.headers.get("content-disposition"), /filename\*=UTF-8''demo/);
assert.match(v2Body, /#T-demo-TJ/);
assert.match(v2Body, /#T-demo-HY2/);

const clashResponse = await clashModule.onRequest({
  request: new Request("https://sub.example/c?isp=demo"),
});
const clashBody = await clashResponse.text();
assert.equal(clashResponse.status, 200);
assert.equal(clashResponse.headers.get("profile-title"), "demo");
assert.equal(clashResponse.headers.get("profile-update-interval"), "24");
assert.match(clashBody, /name: "T-demo-TJ"/);
assert.match(clashBody, /name: "T-demo-HY2"/);
assert.match(clashBody, /name: "📦 TX 大流量"\n    type: fallback/);
assert.match(clashBody, /name: "♻️ 自动选择"\n    type: fallback/);
assert.match(clashBody, /name: "🛡️ ISP 出口自动"\n    type: fallback/);
assert.match(clashBody, /name: "🤖 AI 自动"\n    type: fallback/);
assert.match(
  clashBody,
  /name: "🚀 节点选择"\n    type: select\n    proxies:\n      - "🛡️ 自动容灾"\n      - "♻️ 自动选择"/,
);
assert.match(clashBody, /respect-rules: true/);
assert.match(clashBody, /https:\/\/1\.1\.1\.1\/dns-query#🛡️ 自动容灾/);
assert.match(clashBody, /tun:\n  mtu: 1400/);
assert.doesNotMatch(clashBody, /type: url-test/);
assert.doesNotMatch(clashBody, /tls:\/\/1\.1\.1\.1|tls:\/\/8\.8\.4\.4/);
assert.doesNotMatch(clashBody, /\n    up: "100 Mbps"/);
assert.doesNotMatch(clashBody, /\n    down: "100 Mbps"/);
const clientDirectRule = "IP-CIDR,203.0.113.42/32,DIRECT,no-resolve";
const clashClientDirectRuleIndex = clashBody.indexOf(`- '${clientDirectRule}'`);
assert.ok(clashClientDirectRuleIndex >= 0);
assert.ok(clashClientDirectRuleIndex < clashBody.indexOf("- 'RULE-SET,loyalsoldier-applications,DIRECT'"));
assert.ok(clashClientDirectRuleIndex < clashBody.indexOf("- 'MATCH,🐟 漏网之鱼'"));
const clashForceTcpRule = "AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,github.com)),REJECT";
const clashForceTcpRuleIndex = clashBody.indexOf(`- '${clashForceTcpRule}'`);
assert.ok(clashForceTcpRuleIndex > clashClientDirectRuleIndex);
assert.ok(clashForceTcpRuleIndex < clashBody.indexOf("- 'RULE-SET,loyalsoldier-applications,DIRECT'"));
assert.ok(clashForceTcpRuleIndex < clashBody.indexOf("DOMAIN-SUFFIX,ai.example,🤖 AI 服务"));
assert.ok(clashForceTcpRuleIndex < clashBody.indexOf("DOMAIN-SUFFIX,bulk.example,📦 TX 大流量"));

const allClashResponse = await clashModule.onRequest({
  request: new Request("https://sub.example/c"),
});
const allClashBody = await allClashResponse.text();
const expectedInteractiveNodes = ["T-demo-HY2", "T-demo-TJ", "T-backup-HY2", "T-backup-TJ"];
const expectedBulkNodes = ["T-demo-TJ", "T-demo-HY2", "T-backup-TJ", "T-backup-HY2"];
function groupBlock(body, name) {
  const start = body.indexOf(`  - name: "${name}"`);
  assert.ok(start >= 0, `missing group ${name}`);
  const next = body.indexOf("\n\n  - name:", start + 1);
  return body.slice(start, next >= 0 ? next : body.length);
}
for (const name of ["🛡️ 自动容灾", "♻️ 自动选择", "🛡️ ISP 出口自动", "🤖 AI 自动"]) {
  const block = groupBlock(allClashBody, name);
  assert.match(block, /type: fallback/);
  assert.doesNotMatch(block, /tolerance:/);
  let previous = -1;
  for (const node of expectedInteractiveNodes) {
    const current = block.indexOf(`- "${node}"`);
    assert.ok(current > previous, `${name} proxy order for ${node}`);
    previous = current;
  }
}
const bulkBlock = groupBlock(allClashBody, "📦 TX 大流量");
assert.match(bulkBlock, /type: fallback/);
assert.doesNotMatch(bulkBlock, /tolerance:/);
let previousBulkNode = -1;
for (const node of expectedBulkNodes) {
  const current = bulkBlock.indexOf(`- "${node}"`);
  assert.ok(current > previousBulkNode, `📦 TX 大流量 proxy order for ${node}`);
  previousBulkNode = current;
}
const appleBlock = groupBlock(allClashBody, "🍎 苹果服务");
const appleDirectIndex = appleBlock.indexOf("- DIRECT");
const appleProxyIndex = appleBlock.indexOf('- "🚀 节点选择"');
assert.ok(appleDirectIndex >= 0);
assert.ok(appleProxyIndex > appleDirectIndex);
for (const domain of ["github.com", "google.com", "x.com"]) {
  assert.ok(
    allClashBody.includes(
      `AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,${domain})),REJECT`,
    ),
    `missing force-TCP rule for ${domain}`,
  );
}
const disabledClashResponse = await clashDisabledModule.onRequest({
  request: new Request("https://sub.example/c"),
});
assert.doesNotMatch(await disabledClashResponse.text(), /AND,\(\(NETWORK,UDP\),\(DST-PORT,443\),\(DOMAIN-SUFFIX,/);

const globalScript = await readFile(process.argv[5], "utf8");
const globalMain = vm.runInNewContext(`${globalScript}\nmain`, { atob });
const globalConfig = globalMain({
  proxies: [],
  "proxy-groups": [],
  "proxy-providers": {},
  "rule-providers": {},
  dns: {
    enable: true,
    nameserver: ["https://resolver.example/dns-query"],
    "nameserver-policy": {"custom.example": "192.0.2.53"},
  },
  tun: {enable: true, stack: "system", mtu: 1500},
  rules: ["DOMAIN-SUFFIX,airport.example,DIRECT", "MATCH,DIRECT"],
});
const plain = (value) => JSON.parse(JSON.stringify(value));
const globalClientDirectRuleIndex = globalConfig.rules.indexOf(clientDirectRule);
assert.ok(globalClientDirectRuleIndex >= 0);
assert.ok(globalClientDirectRuleIndex < globalConfig.rules.indexOf("DOMAIN-SUFFIX,airport.example,DIRECT"));
assert.ok(globalClientDirectRuleIndex < globalConfig.rules.indexOf("RULE-SET,loyalsoldier-lancidr,DIRECT,no-resolve"));
assert.ok(globalClientDirectRuleIndex < globalConfig.rules.indexOf("MATCH,🛡️ ISP 最终出口"));
assert.equal(globalConfig["proxy-groups"][0].type, "fallback");
assert.equal(globalConfig["proxy-groups"][1].type, "fallback");
assert.deepEqual(plain(globalConfig["proxy-groups"][0].proxies), expectedBulkNodes);
assert.deepEqual(plain(globalConfig["proxy-groups"][1].proxies), expectedBulkNodes);
assert.equal(globalConfig.dns.enable, true);
assert.deepEqual(plain(globalConfig.dns.nameserver), ["https://resolver.example/dns-query"]);
assert.equal(globalConfig.dns["respect-rules"], true);
assert.equal(globalConfig.dns["nameserver-policy"]["custom.example"], "192.0.2.53");
assert.deepEqual(plain(globalConfig.dns["nameserver-policy"]["geosite:gfw"]), [
  "https://1.1.1.1/dns-query#🛡️ ISP 最终出口",
  "https://8.8.8.8/dns-query#🛡️ ISP 最终出口",
]);
assert.deepEqual(plain(globalConfig.dns["proxy-server-nameserver"]), [
  "https://doh.pub/dns-query",
  "https://dns.alidns.com/dns-query",
]);
assert.deepEqual(plain(globalConfig.dns.fallback), [
  "https://1.1.1.1/dns-query#🛡️ ISP 最终出口",
  "https://8.8.8.8/dns-query#🛡️ ISP 最终出口",
]);
assert.equal(globalConfig.tun.enable, true);
assert.equal(globalConfig.tun.stack, "system");
assert.equal(globalConfig.tun.mtu, 1400);
const globalForceTcpRuleIndex = globalConfig.rules.indexOf(clashForceTcpRule);
assert.ok(globalForceTcpRuleIndex > globalClientDirectRuleIndex);
assert.ok(globalForceTcpRuleIndex < globalConfig.rules.indexOf("RULE-SET,loyalsoldier-applications,DIRECT"));
assert.ok(globalForceTcpRuleIndex < globalConfig.rules.indexOf("DOMAIN-SUFFIX,ai.example,🛡️ ISP 最终出口"));
assert.ok(globalForceTcpRuleIndex < globalConfig.rules.indexOf("DOMAIN-SUFFIX,bulk.example,📦 TX 大流量"));

const preservedDnsConfig = globalMain({
  proxies: [],
  "proxy-groups": [],
  dns: {"proxy-server-nameserver": ["https://resolver.example/bootstrap"]},
  rules: [],
});
assert.deepEqual(plain(preservedDnsConfig.dns["proxy-server-nameserver"]), [
  "https://resolver.example/bootstrap",
]);

const globalDisabledScript = await readFile(process.argv[7], "utf8");
const globalDisabledMain = vm.runInNewContext(`${globalDisabledScript}\nmain`, { atob });
const disabledGlobalConfig = globalDisabledMain({
  proxies: [],
  "proxy-groups": [],
  rules: [],
});
assert.equal(
  disabledGlobalConfig.rules.some((rule) => rule.startsWith("AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,")),
  false,
);

const shadowrocketResponse = await shadowrocketModule.onRequest({
  request: new Request("https://sub.example/sr"),
});
const shadowrocketBody = await shadowrocketResponse.text();
assert.equal(shadowrocketResponse.status, 200);
assert.equal(shadowrocketResponse.headers.get("profile-title"), "Shadowrocket-Telegram");
assert.match(shadowrocketResponse.headers.get("content-disposition"), /shadowrocket-telegram\.module/);
assert.match(shadowrocketBody, /^#!name=Telegram via PROXY/m);
assert.match(shadowrocketBody, /^\[Rule\]$/m);
assert.match(shadowrocketBody, /^IP-CIDR,91\.108\.0\.0\/16,PROXY,no-resolve$/m);
assert.match(
  shadowrocketBody,
  /^RULE-SET,https:\/\/sub\.example\/rules\/shadowrocket-telegram\.list,PROXY$/m,
);
assert.doesNotMatch(shadowrocketBody, /^(DOMAIN|DOMAIN-SUFFIX|IP-CIDR).*,DIRECT$/m);
NODE
fi

grep -Fq 'shadowrocket_module: "/sr"' "${ROOT_DIR}/install.sh"
grep -Fq 'ISP_PUBLIC_LIST_JSON=$(jq -c '\''map({id, host, expires, trojan_port, hysteria_port})'\''' "${ROOT_DIR}/install.sh"
grep -Fq 'elements.host.textContent = entry.host' "${ROOT_DIR}/cloudflare-pages-sub/index.html"
grep -Fq 'DEFAULT_TELEGRAM_IP_CIDRS="5.28.192.0/18,91.105.192.0/23,91.108.0.0/16' "${ROOT_DIR}/install.sh"
grep -Fq 'shadowrocket-telegram.list' "${ROOT_DIR}/sync-clash-rules.sh"
grep -Fq "const homepageHiddenIds = new Set(['dawn']);" "${ROOT_DIR}/cloudflare-pages-sub/index.html"

(
  source "${ROOT_DIR}/install.sh"

  CLIENT_DIRECT_IP_CIDRS=""
  normalize_client_direct_ip_cidrs
  [[ -z "${CLIENT_DIRECT_IP_CIDRS}" ]]

  CLIENT_DIRECT_IP_CIDRS="203.0.113.42,10.0.0.0/8,2001:DB8::1,2001:db8::/48"
  normalize_client_direct_ip_cidrs
  [[ "${CLIENT_DIRECT_IP_CIDRS}" == "203.0.113.42/32,10.0.0.0/8,2001:db8::1/128,2001:db8::/48" ]]

  for invalid in \
    "999.0.0.1/32" \
    "203.0.113.42/33" \
    "203.0.113.42/" \
    "2001:db8::1/129" \
    "2001:db8::1::2/128" \
    "203.0.113.42/32,MATCH,DIRECT"; do
    if CLIENT_DIRECT_IP_CIDRS="${invalid}" normalize_client_direct_ip_cidrs 2>/dev/null; then
      echo "Expected CLIENT_DIRECT_IP_CIDRS validation failure: ${invalid}" >&2
      exit 1
    fi
  done

  CLASH_FORCE_TCP_DOMAINS="GitHub.com, google.com github.com,x.com"
  normalize_domain_suffix_csv "CLASH_FORCE_TCP_DOMAINS"
  [[ "${CLASH_FORCE_TCP_DOMAINS}" == "github.com,google.com,x.com" ]]

  for invalid_domain in \
    "github" \
    "-github.com" \
    "github-.com" \
    "github..com" \
    "github.com/path" \
    "github.com)),REJECT"; do
    if CLASH_FORCE_TCP_DOMAINS="${invalid_domain}" \
      normalize_domain_suffix_csv "CLASH_FORCE_TCP_DOMAINS" 2>/dev/null; then
      echo "Expected CLASH_FORCE_TCP_DOMAINS validation failure: ${invalid_domain}" >&2
      exit 1
    fi
  done
)

SHADOWROCKET_RULE_FIXTURE="${TMP_DIR}/shadowrocket-telegram.list"
printf '%s\n' \
  '# NAME: Telegram test fixture' \
  'DOMAIN-SUFFIX,telegram.org' \
  'IP-CIDR,5.28.192.0/18,no-resolve' \
  'IP-CIDR,91.108.0.0/16,no-resolve' \
  'IP-CIDR,149.154.160.0/20,no-resolve' > "${SHADOWROCKET_RULE_FIXTURE}"
for index in $(seq 1 26); do
  printf 'DOMAIN-SUFFIX,test%s.example\n' "${index}" >> "${SHADOWROCKET_RULE_FIXTURE}"
done
(
  source "${ROOT_DIR}/sync-clash-rules.sh"
  validate_shadowrocket_telegram_file "${SHADOWROCKET_RULE_FIXTURE}"
)

SOURCE_DIR="${TMP_DIR}/source"
TARGET_DIR="${TMP_DIR}/target"
mkdir -p "${SOURCE_DIR}" "${TARGET_DIR}"
install -m 700 "${ROOT_DIR}/migrate.sh" "${SOURCE_DIR}/migrate.sh"
install -m 700 "${ROOT_DIR}/migrate.sh" "${TARGET_DIR}/migrate.sh"

printf '%s\n' \
  'TROJAN_DOMAIN=tj.example.com' \
  'HYSTERIA_DOMAIN=hy2.example.com' \
  'ISP_LIST_FILE=private/custom.tsv' \
  'TROJAN_PASSWORD=test-secret' > "${SOURCE_DIR}/.env"
mkdir -p "${SOURCE_DIR}/private"
printf '编号\tIP\tHTTP端口\tSOCKS5端口\tuser\tpwd\t到期时间\n' > "${SOURCE_DIR}/private/custom.tsv"
printf 'demo\t203.0.113.10\t3128\t1080\ttest-user\ttest-password\t2099-12-31\n' >> "${SOURCE_DIR}/private/custom.tsv"
printf '%s\n' 'migration-test-password' > "${TMP_DIR}/password"
chmod 600 "${SOURCE_DIR}/.env" "${SOURCE_DIR}/private/custom.tsv" "${TMP_DIR}/password"

MIGRATION_PASSWORD_FILE="${TMP_DIR}/password" \
  "${SOURCE_DIR}/migrate.sh" export "${TMP_DIR}/bundle.tar.gz.enc"

printf '%s\n' 'OLD=true' > "${TARGET_DIR}/.env"
printf '%s\n' 'old-list' > "${TARGET_DIR}/isp-list.tsv"
chmod 600 "${TARGET_DIR}/.env" "${TARGET_DIR}/isp-list.tsv"
MIGRATION_PASSWORD_FILE="${TMP_DIR}/password" \
  "${TARGET_DIR}/migrate.sh" import "${TMP_DIR}/bundle.tar.gz.enc"

grep -Fxq 'ISP_LIST_FILE=isp-list.tsv' "${TARGET_DIR}/.env"
cmp "${SOURCE_DIR}/private/custom.tsv" "${TARGET_DIR}/isp-list.tsv"
[[ "$(find "${TARGET_DIR}" -maxdepth 1 -name '.env.bak.*' | wc -l | tr -d ' ')" == "1" ]]
[[ "$(find "${TARGET_DIR}" -maxdepth 1 -name 'isp-list.tsv.bak.*' | wc -l | tr -d ' ')" == "1" ]]
[[ "$(file_mode "${TARGET_DIR}/.env")" == "600" ]]
[[ "$(file_mode "${TARGET_DIR}/isp-list.tsv")" == "600" ]]

echo "All tests passed."
