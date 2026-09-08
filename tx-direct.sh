#!/usr/bin/env bash
# Deploy only the independent TX public-egress service, without touching sing-box.service.
set -Eeuo pipefail
umask 077
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"

main_tx_direct() {
  local mode="${1:---check}"
  [[ "${mode}" == --check || "${mode}" == --deploy ]] || {
    echo 'Usage: sudo bash tx-direct.sh [--check|--deploy]' >&2; return 2;
  }
  require_root
  load_env
  is_true "${TX_DIRECT_ENABLED:-false}" || { log_error 'TX_DIRECT_ENABLED is not true'; return 1; }
  normalize_client_direct_ip_cidrs
  export CLIENT_DIRECT_IP_CIDRS
  TMP_CONFIG="$(mktemp /run/tx-direct-config.XXXXXX.json)"
  node "${SCRIPT_DIR}/scripts/tx-direct.mjs" config "${TMP_CONFIG}"
  sing-box check -c "${TMP_CONFIG}"

  local primary=/etc/sing-box/config.json
  local own=/etc/sing-box-tx-direct/config.json
  local port protocol
  # Preserve active ISP slots. Retired slots may be reused by the independent service.
  local inventory="${ISP_LIST_FILE}"
  [[ "${inventory}" == /* ]] || inventory="${SCRIPT_DIR}/${inventory}"
  local today
  today=$(date -u +%F)
  local -a expiries=()
  mapfile -t expiries < <(awk -F '\t' 'NF && $1 !~ /^#/ && $1 != "编号" && tolower($1) != "id" {sub(/\r$/, "", $7); print $7}' "${inventory}")
  for port in "${TX_DIRECT_TROJAN_PORT:-443}" "${TX_DIRECT_HYSTERIA_PORT:-8443}"; do
    local slot
    for ((slot=0; slot<${#expiries[@]}; slot++)); do
      [[ "${expiries[slot]}" < "${today}" ]] && continue
      if (( port == TROJAN_PORT + slot * ISP_PORT_STEP || port == HYSTERIA_PORT + slot * ISP_PORT_STEP )); then
        log_error "TX port ${port} conflicts with an ISP slot"; return 1
      fi
    done
    if jq -e --argjson p "${port}" '.inbounds | any(.listen_port == $p)' "${primary}" >/dev/null; then
      log_error "TX port ${port} conflicts with the primary service"; return 1
    fi
  done
  while read -r protocol port; do
    if ss -H -ln"${protocol}" "sport = :${port}" | grep -q .; then
      if ! systemctl is-active --quiet sing-box-tx-direct || ! jq -e --argjson p "${port}" '.inbounds | any(.listen_port == $p)' "${own}" >/dev/null; then
        log_error "TX port ${port}/${protocol} is already occupied"; return 1
      fi
    fi
  done < <(printf 't %s\nu %s\n' "${TX_DIRECT_TROJAN_PORT:-443}" "${TX_DIRECT_HYSTERIA_PORT:-8443}")
  [[ "${mode}" == --deploy ]] || { log_success 'TX direct configuration and ports validated'; return 0; }

  local before_pid before_sha backup_dir
  before_pid=$(systemctl show sing-box -p MainPID --value)
  before_sha=$(sha256sum "${primary}" | cut -d ' ' -f1)
  backup_dir="$(mktemp -d /var/backups/sing-box-tx-direct.XXXXXX)"
  [[ ! -f "${own}" ]] || cp -p "${own}" "${backup_dir}/config.json"
  [[ ! -f /etc/systemd/system/sing-box-tx-direct.service ]] || cp -p /etc/systemd/system/sing-box-tx-direct.service "${backup_dir}/service"
  install -d -m 700 /etc/sing-box-tx-direct /var/lib/sing-box-tx-direct
  install -m 600 "${TMP_CONFIG}" "${own}"
  install -m 644 "${SCRIPT_DIR}/systemd/sing-box-tx-direct.service" /etc/systemd/system/sing-box-tx-direct.service
  systemctl daemon-reload
  if ! systemctl restart sing-box-tx-direct || ! systemctl is-active --quiet sing-box-tx-direct; then
    if [[ -f "${backup_dir}/config.json" ]]; then
      install -m 600 "${backup_dir}/config.json" "${own}"
      [[ ! -f "${backup_dir}/service" ]] || install -m 644 "${backup_dir}/service" /etc/systemd/system/sing-box-tx-direct.service
      systemctl daemon-reload
      systemctl restart sing-box-tx-direct || true
    else
      systemctl stop sing-box-tx-direct || true
    fi
    log_error "TX direct startup failed; backup: ${backup_dir}"; return 1
  fi
  systemctl enable sing-box-tx-direct
  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow "${TX_DIRECT_TROJAN_PORT:-443}/tcp" comment 'sing-box TX direct Trojan'
    ufw allow "${TX_DIRECT_HYSTERIA_PORT:-8443}/udp" comment 'sing-box TX direct Hysteria2'
  fi
  [[ "${before_pid}" == "$(systemctl show sing-box -p MainPID --value)" ]]
  [[ "${before_sha}" == "$(sha256sum "${primary}" | cut -d ' ' -f1)" ]]
  log_success 'Independent TX direct service started; primary sing-box unchanged'
}

main_tx_direct "$@"
