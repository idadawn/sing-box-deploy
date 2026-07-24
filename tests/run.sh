#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

for script in install.sh manage.sh migrate.sh setup-ssh.sh sync-clash-rules.sh; do
  bash -n "${ROOT_DIR}/${script}"
done

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
    -e 's|ISP_PUBLIC_LIST_BASE64_PLACEHOLDER|W3siaWQiOiJkZW1vIiwiZXhwaXJlcyI6IjIwOTktMTItMzEiLCJ0cm9qYW5fcG9ydCI6NDQzLCJoeXN0ZXJpYV9wb3J0Ijo4NDQzfV0=|g' \
    -e 's/AI_ISP_DOMAINS_BASE64_PLACEHOLDER//g' \
    -e 's/DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER//g' \
    -e 's/AI_ISP_DOMAINS_JSON_PLACEHOLDER/[]/g' \
    -e 's/DIRECT_BULK_DOMAINS_JSON_PLACEHOLDER/[]/g' \
    -e 's/DIRECT_BULK_APPS_JSON_PLACEHOLDER/[]/g' \
    -e 's/DIRECT_BULK_ENABLED_PLACEHOLDER/false/g' \
    -e 's/HYSTERIA_USE_BBR_PLACEHOLDER/true/g' \
    -e 's/HYSTERIA_UP_PLACEHOLDER/100/g' \
    -e 's/HYSTERIA_DOWN_PLACEHOLDER/100/g' \
    -e 's/[A-Z][A-Z0-9_]*_PLACEHOLDER/test/g' \
    "${source}" > "${destination}"
}

if command -v node >/dev/null 2>&1; then
  extract_heredoc "  cat > \"\${functions_dir}/v2.js\" <<'V2JS'" "V2JS" "${TMP_DIR}/v2.template"
  extract_heredoc "  cat > \"\${functions_dir}/c.js\" <<'CJS'" "CJS" "${TMP_DIR}/c.template"
  extract_heredoc "  cat > \"\${pages_dir}/global-extension.js\" <<'GLOBALJS'" "GLOBALJS" "${TMP_DIR}/global.template"
  render_js_template "${TMP_DIR}/v2.template" "${TMP_DIR}/v2.mjs"
  render_js_template "${TMP_DIR}/c.template" "${TMP_DIR}/c.mjs"
  render_js_template "${TMP_DIR}/global.template" "${TMP_DIR}/global.mjs"
  node --check "${TMP_DIR}/v2.mjs"
  node --check "${TMP_DIR}/c.mjs"
  node --check "${TMP_DIR}/global.mjs"
  node --input-type=module - "${TMP_DIR}/v2.mjs" "${TMP_DIR}/c.mjs" <<'NODE'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const v2Module = await import(pathToFileURL(process.argv[2]));
const clashModule = await import(pathToFileURL(process.argv[3]));

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
assert.match(clashBody, /name: "📦 TX 大流量"\n    type: url-test/);
assert.match(clashBody, /name: "🛡️ ISP 出口自动"\n    type: url-test/);
assert.doesNotMatch(clashBody, /\n    up: "100 Mbps"/);
assert.doesNotMatch(clashBody, /\n    down: "100 Mbps"/);
NODE
fi

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
[[ "$(stat -f '%Lp' "${TARGET_DIR}/.env" 2>/dev/null || stat -c '%a' "${TARGET_DIR}/.env")" == "600" ]]
[[ "$(stat -f '%Lp' "${TARGET_DIR}/isp-list.tsv" 2>/dev/null || stat -c '%a' "${TARGET_DIR}/isp-list.tsv")" == "600" ]]

echo "All tests passed."
