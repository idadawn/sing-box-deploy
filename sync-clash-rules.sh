#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ENV_FILE="${SCRIPT_DIR}/.env"
ENV_FILE="${DEFAULT_ENV_FILE}"
PAGES_DIR="${SCRIPT_DIR}/cloudflare-pages-sub"

RULE_FILES=(
  applications.txt
  private.txt
  reject.txt
  icloud.txt
  apple.txt
  proxy.txt
  direct.txt
  lancidr.txt
  cncidr.txt
  telegramcidr.txt
)
SHADOWROCKET_RULE_FILE="shadowrocket-telegram.list"

DEPLOY=0
FORCE=0
STAGE_ROOT=""

log_info() { printf '[INFO] %s\n' "$*"; }
log_ok() { printf '[OK] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERR] %s\n' "$*" >&2; }

cleanup() {
  if [[ -n "${STAGE_ROOT}" && -d "${STAGE_ROOT}" ]]; then
    rm -rf "${STAGE_ROOT}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
用法:
  ./sync-clash-rules.sh [--deploy] [--force] [--env <path>]

选项:
  --deploy       同步完成后部署 Cloudflare Pages
  --force        即使上游提交未变化也重新下载
  --env <path>   指定部署配置文件，默认读取仓库根目录 .env
  -h, --help     显示帮助
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deploy)
        DEPLOY=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --env)
        [[ $# -ge 2 ]] || { log_error "--env 需要路径参数"; exit 2; }
        ENV_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "未知参数: $1"
        usage
        exit 2
        ;;
    esac
  done
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

load_env_file() {
  [[ -f "${ENV_FILE}" ]] || return 0

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    local line key value
    line="$(trim "${raw_line}")"
    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

    key="$(trim "${line%%=*}")"
    case "${key}" in
      CLASH_RULESET_UPSTREAM_REPO|CLASH_RULESET_UPSTREAM_BRANCH|CLASH_RULESET_RAW_BASE_URL|SHADOWROCKET_TELEGRAM_REPO|SHADOWROCKET_TELEGRAM_BRANCH|SHADOWROCKET_TELEGRAM_RAW_BASE_URL|CF_API_TOKEN|CF_ACCOUNT_ID|CF_PAGES_PROJECT)
        ;;
      *)
        continue
        ;;
    esac

    # 显式传入的环境变量优先于 .env。
    [[ -n "${!key+x}" ]] && continue
    value="$(trim "${line#*=}")"
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:-1}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:-1}"
    fi
    printf -v "${key}" '%s' "${value}"
    export "${key}"
  done < "${ENV_FILE}"
}

require_commands() {
  local command_name
  for command_name in curl flock git jq readlink; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      log_error "缺少命令: ${command_name}"
      exit 1
    }
  done
}

validate_rule_file() {
  local path="$1"
  [[ -s "${path}" ]] || return 1

  local first_content_line
  first_content_line="$(awk 'NF && $1 !~ /^#/ { print; exit }' "${path}")"
  [[ "${first_content_line}" == "payload:" ]] || return 1
  grep -Eq '^[[:space:]]*-[[:space:]]+[^[:space:]]' "${path}"
}

validate_shadowrocket_telegram_file() {
  local path="$1"
  [[ -s "${path}" ]] || return 1

  local rule_count
  rule_count="$(grep -Ec '^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|IP-ASN),' "${path}" || true)"
  (( rule_count >= 30 )) || return 1
  awk '
    NF && $1 !~ /^#/ &&
    $0 !~ /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|IP-ASN),/ {
      exit 1
    }
  ' "${path}" || return 1
  grep -Fxq 'DOMAIN-SUFFIX,telegram.org' "${path}" || return 1
  grep -Fxq 'IP-CIDR,5.28.192.0/18,no-resolve' "${path}" || return 1
  grep -Fxq 'IP-CIDR,91.108.0.0/16,no-resolve' "${path}" || return 1
  grep -Fxq 'IP-CIDR,149.154.160.0/20,no-resolve' "${path}"
}

validate_snapshot() {
  local directory="$1"
  local require_metadata="${2:-true}"
  local file

  [[ -d "${directory}" ]] || return 1
  for file in "${RULE_FILES[@]}"; do
    validate_rule_file "${directory}/${file}" || return 1
  done
  validate_shadowrocket_telegram_file "${directory}/${SHADOWROCKET_RULE_FILE}" || return 1

  if [[ "${require_metadata}" == "true" ]]; then
    jq -e '
      (.upstream_sha | strings | test("^[0-9a-f]{40}$")) and
      (.shadowrocket_telegram_sha | strings | test("^[0-9a-f]{40}$")) and
      (.files | arrays | length == 11) and
      (.files | index("shadowrocket-telegram.list") != null)
    ' "${directory}/metadata.json" >/dev/null 2>&1 || return 1
  fi
}

normalize_snapshot_permissions() {
  local directory="$1"
  chmod 0755 "${directory}"
  chmod 0644 "${directory}"/*.txt "${directory}"/*.list "${directory}/metadata.json"
}

resolve_raw_base_url() {
  local repository="$1"
  local configured_base_url="${2:-}"
  if [[ -n "${configured_base_url}" ]]; then
    printf '%s' "${configured_base_url%/}"
    return 0
  fi

  local repository_path="${repository#https://github.com/}"
  repository_path="${repository_path%.git}"
  if [[ "${repository_path}" == "${repository}" || "${repository_path}" != */* ]]; then
    log_error "非 GitHub 仓库必须同时设置对应的 RAW_BASE_URL"
    return 1
  fi
  printf 'https://raw.githubusercontent.com/%s' "${repository_path}"
}

resolve_upstream_sha() {
  local repository="$1"
  local branch="$2"
  local ref="refs/heads/${branch}"
  local result
  result="$(git ls-remote "${repository}" "${ref}")"
  awk 'NR == 1 { print $1 }' <<< "${result}"
}

write_metadata() {
  local directory="$1"
  local upstream_sha="$2"
  local shadowrocket_telegram_sha="$3"
  local files_json
  files_json="$(
    {
      printf '%s\n' "${RULE_FILES[@]}"
      printf '%s\n' "${SHADOWROCKET_RULE_FILE}"
    } | jq -R . | jq -s .
  )"

  jq -n \
    --arg repository "${CLASH_RULESET_UPSTREAM_REPO}" \
    --arg branch "${CLASH_RULESET_UPSTREAM_BRANCH}" \
    --arg upstream_sha "${upstream_sha}" \
    --arg shadowrocket_telegram_repository "${SHADOWROCKET_TELEGRAM_REPO}" \
    --arg shadowrocket_telegram_branch "${SHADOWROCKET_TELEGRAM_BRANCH}" \
    --arg shadowrocket_telegram_sha "${shadowrocket_telegram_sha}" \
    --arg synced_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson files "${files_json}" \
    '{
      repository: $repository,
      branch: $branch,
      upstream_sha: $upstream_sha,
      shadowrocket_telegram_repository: $shadowrocket_telegram_repository,
      shadowrocket_telegram_branch: $shadowrocket_telegram_branch,
      shadowrocket_telegram_sha: $shadowrocket_telegram_sha,
      synced_at: $synced_at,
      files: $files
    }' \
    > "${directory}/metadata.json"
}

download_snapshot() {
  local upstream_sha="$1"
  local raw_base_url="$2"
  local shadowrocket_telegram_sha="$3"
  local shadowrocket_raw_base_url="$4"
  local output_parent
  output_parent="$(dirname "${CLASH_RULESET_OUTPUT_DIR}")"
  mkdir -p "${output_parent}"

  STAGE_ROOT="$(mktemp -d "${output_parent}/.clash-rules-sync.XXXXXX")"
  local stage_dir="${STAGE_ROOT}/rules"
  mkdir -p "${stage_dir}"

  local file url
  for file in "${RULE_FILES[@]}"; do
    url="${raw_base_url}/${upstream_sha}/${file}"
    log_info "下载 ${file}"
    if ! curl --fail --silent --show-error --location \
      --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
      "${url}" -o "${stage_dir}/${file}"; then
      log_error "${file} 下载失败，保留当前规则快照"
      return 1
    fi
  done

  local shadowrocket_url="${shadowrocket_raw_base_url}/${shadowrocket_telegram_sha}/rule/Shadowrocket/Telegram/Telegram.list"
  log_info "下载 ${SHADOWROCKET_RULE_FILE}"
  if ! curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 \
    "${shadowrocket_url}" -o "${stage_dir}/${SHADOWROCKET_RULE_FILE}"; then
    log_error "${SHADOWROCKET_RULE_FILE} 下载失败，保留当前规则快照"
    return 1
  fi

  validate_snapshot "${stage_dir}" false || {
    log_error "上游规则文件校验失败，保留当前快照"
    return 1
  }
  write_metadata "${stage_dir}" "${upstream_sha}" "${shadowrocket_telegram_sha}"
  validate_snapshot "${stage_dir}" true || {
    log_error "规则快照元数据校验失败，保留当前快照"
    return 1
  }
  normalize_snapshot_permissions "${stage_dir}"

  local previous_dir="${CLASH_RULESET_OUTPUT_DIR}.previous"
  rm -rf "${previous_dir}"
  if [[ -d "${CLASH_RULESET_OUTPUT_DIR}" ]]; then
    mv "${CLASH_RULESET_OUTPUT_DIR}" "${previous_dir}"
  fi
  if ! mv "${stage_dir}" "${CLASH_RULESET_OUTPUT_DIR}"; then
    [[ -d "${previous_dir}" ]] && mv "${previous_dir}" "${CLASH_RULESET_OUTPUT_DIR}"
    log_error "无法替换规则快照，已恢复旧版本"
    return 1
  fi
  rm -rf "${previous_dir}"
  log_ok "规则快照已更新到 ${upstream_sha}"
}

deploy_pages() {
  validate_snapshot "${CLASH_RULESET_OUTPUT_DIR}" true || {
    log_error "本地规则快照无效，拒绝部署"
    return 1
  }
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ACCOUNT_ID:-}" ]] || {
    log_error "部署需要 CF_API_TOKEN 和 CF_ACCOUNT_ID"
    return 1
  }
  command -v wrangler >/dev/null 2>&1 || {
    log_error "未安装 wrangler，无法部署 Cloudflare Pages"
    return 1
  }

  log_info "部署 Cloudflare Pages 项目 ${CF_PAGES_PROJECT}"
  (
    cd "${PAGES_DIR}"
    GIT_OPTIONAL_LOCKS=0 \
      CLOUDFLARE_API_TOKEN="${CF_API_TOKEN}" \
      CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" \
      wrangler pages deploy . --project-name="${CF_PAGES_PROJECT}" --branch=main
  )
  log_ok "Cloudflare Pages 部署完成"
}

main() {
  parse_args "$@"
  load_env_file

  CLASH_RULESET_UPSTREAM_REPO="${CLASH_RULESET_UPSTREAM_REPO:-https://github.com/Loyalsoldier/clash-rules.git}"
  CLASH_RULESET_UPSTREAM_BRANCH="${CLASH_RULESET_UPSTREAM_BRANCH:-release}"
  CLASH_RULESET_OUTPUT_DIR="${CLASH_RULESET_OUTPUT_DIR:-${PAGES_DIR}/rules}"
  SHADOWROCKET_TELEGRAM_REPO="${SHADOWROCKET_TELEGRAM_REPO:-https://github.com/blackmatrix7/ios_rule_script.git}"
  SHADOWROCKET_TELEGRAM_BRANCH="${SHADOWROCKET_TELEGRAM_BRANCH:-master}"
  CF_PAGES_PROJECT="${CF_PAGES_PROJECT:-sub-converter}"

  require_commands
  mkdir -p "$(dirname "${CLASH_RULESET_OUTPUT_DIR}")"

  local default_lock_file="${TMPDIR:-/tmp}/sing-box-deploy-clash-rules.lock"
  (( EUID == 0 )) && default_lock_file="/run/lock/sing-box-deploy-clash-rules.lock"
  local lock_file="${CLASH_RULESET_LOCK_FILE:-${default_lock_file}}"
  if [[ -n "${CLASH_RULESET_LOCK_HELD_FD:-}" ]]; then
    [[ "${CLASH_RULESET_LOCK_HELD_FD}" =~ ^[0-9]+$ \
      && -e "/proc/self/fd/${CLASH_RULESET_LOCK_HELD_FD}" ]] || {
      log_error "继承的 Pages 发布锁无效"
      exit 1
    }
    [[ "$(readlink -f "/proc/self/fd/${CLASH_RULESET_LOCK_HELD_FD}")" == "$(readlink -f "${lock_file}")" ]] || {
      log_error "继承的 Pages 发布锁与规则锁不一致"
      exit 1
    }
  else
    exec 9>"${lock_file}"
    flock -n 9 || { log_warn "已有规则同步或 Pages 发布任务正在运行，本次跳过"; exit 0; }
  fi

  local upstream_sha raw_base_url current_sha=""
  local shadowrocket_telegram_sha shadowrocket_raw_base_url current_shadowrocket_sha=""
  upstream_sha="$(resolve_upstream_sha "${CLASH_RULESET_UPSTREAM_REPO}" "${CLASH_RULESET_UPSTREAM_BRANCH}")"
  [[ "${upstream_sha}" =~ ^[0-9a-f]{40}$ ]] || {
    log_error "无法解析 ${CLASH_RULESET_UPSTREAM_BRANCH} 分支提交"
    exit 1
  }
  shadowrocket_telegram_sha="$(resolve_upstream_sha "${SHADOWROCKET_TELEGRAM_REPO}" "${SHADOWROCKET_TELEGRAM_BRANCH}")"
  [[ "${shadowrocket_telegram_sha}" =~ ^[0-9a-f]{40}$ ]] || {
    log_error "无法解析 Shadowrocket Telegram ${SHADOWROCKET_TELEGRAM_BRANCH} 分支提交"
    exit 1
  }
  raw_base_url="$(resolve_raw_base_url "${CLASH_RULESET_UPSTREAM_REPO}" "${CLASH_RULESET_RAW_BASE_URL:-}")"
  shadowrocket_raw_base_url="$(resolve_raw_base_url "${SHADOWROCKET_TELEGRAM_REPO}" "${SHADOWROCKET_TELEGRAM_RAW_BASE_URL:-}")"

  if validate_snapshot "${CLASH_RULESET_OUTPUT_DIR}" true; then
    current_sha="$(jq -r '.upstream_sha' "${CLASH_RULESET_OUTPUT_DIR}/metadata.json")"
    current_shadowrocket_sha="$(jq -r '.shadowrocket_telegram_sha' "${CLASH_RULESET_OUTPUT_DIR}/metadata.json")"
  fi

  if (( FORCE == 1 )) \
    || [[ "${current_sha}" != "${upstream_sha}" ]] \
    || [[ "${current_shadowrocket_sha}" != "${shadowrocket_telegram_sha}" ]]; then
    download_snapshot \
      "${upstream_sha}" \
      "${raw_base_url}" \
      "${shadowrocket_telegram_sha}" \
      "${shadowrocket_raw_base_url}"
  else
    log_ok "规则已是最新提交 ${upstream_sha} / ${shadowrocket_telegram_sha}"
  fi
  normalize_snapshot_permissions "${CLASH_RULESET_OUTPUT_DIR}"

  if (( DEPLOY == 1 )); then
    deploy_pages
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
