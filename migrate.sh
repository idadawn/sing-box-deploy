#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERR]${NC} $*" >&2; }

WORK_DIR=""
cleanup() {
  [[ -z "${WORK_DIR}" || ! -d "${WORK_DIR}" ]] || rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
用法:
  ./migrate.sh export [迁移包路径]
  ./migrate.sh import <迁移包路径>

说明:
  export  把 .env 与 ISP 清单打包并使用 AES-256-CBC + PBKDF2 加密。
  import  校验并恢复 .env 与 isp-list.tsv；已有文件会先备份。

默认交互式输入迁移密码。自动化场景可设置：
  MIGRATION_PASSWORD_FILE=/仅当前用户可读的密码文件
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

read_env_value() {
  local expected_key="$1"
  local raw_line line key value
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="$(trim "${raw_line}")"
    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="$(trim "${line%%=*}")"
    [[ "${key}" == "${expected_key}" ]] || continue
    value="$(trim "${line#*=}")"
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:-1}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:-1}"
    fi
    printf '%s' "${value}"
    return 0
  done < "${ENV_FILE}"
  return 1
}

openssl_password_args() {
  if [[ -n "${MIGRATION_PASSWORD_FILE:-}" ]]; then
    [[ -r "${MIGRATION_PASSWORD_FILE}" ]] || {
      log_error "密码文件不可读: ${MIGRATION_PASSWORD_FILE}"
      exit 1
    }
    printf '%s\0%s\0' -pass "file:${MIGRATION_PASSWORD_FILE}"
  fi
}

encrypt_archive() {
  local source_tar="$1"
  local destination="$2"
  local password_args=()
  while IFS= read -r -d '' value; do
    password_args+=("${value}")
  done < <(openssl_password_args)

  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 -md sha256 \
    "${password_args[@]}" -in "${source_tar}" -out "${destination}"
}

decrypt_archive() {
  local source="$1"
  local destination_tar="$2"
  local password_args=()
  while IFS= read -r -d '' value; do
    password_args+=("${value}")
  done < <(openssl_password_args)

  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 \
    "${password_args[@]}" -in "${source}" -out "${destination_tar}"
}

export_bundle() {
  command -v openssl >/dev/null 2>&1 || {
    log_error "未安装 openssl"
    exit 1
  }
  command -v tar >/dev/null 2>&1 || {
    log_error "未安装 tar"
    exit 1
  }
  [[ -f "${ENV_FILE}" ]] || {
    log_error "未找到 ${ENV_FILE}"
    exit 1
  }

  local configured_list list_file output raw_tar
  configured_list="$(read_env_value ISP_LIST_FILE || true)"
  configured_list="${configured_list:-isp-list.tsv}"
  if [[ "${configured_list}" == /* ]]; then
    list_file="${configured_list}"
  else
    list_file="${SCRIPT_DIR}/${configured_list}"
  fi
  [[ -f "${list_file}" ]] || {
    log_error "未找到 ISP 清单: ${list_file}"
    exit 1
  }

  output="${1:-${SCRIPT_DIR}/migration-$(date +%Y%m%d-%H%M%S).tar.gz.enc}"
  [[ "${output}" == /* ]] || output="${PWD}/${output}"
  [[ ! -e "${output}" ]] || {
    log_error "目标文件已存在，拒绝覆盖: ${output}"
    exit 1
  }

  WORK_DIR="$(mktemp -d)"
  awk '
    BEGIN { replaced = 0 }
    /^[[:space:]]*ISP_LIST_FILE[[:space:]]*=/ {
      print "ISP_LIST_FILE=isp-list.tsv"
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) print "ISP_LIST_FILE=isp-list.tsv"
    }
  ' "${ENV_FILE}" > "${WORK_DIR}/.env"
  install -m 600 "${list_file}" "${WORK_DIR}/isp-list.tsv"
  {
    echo "format=sing-box-deploy-migration-v1"
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "source_host=$(hostname)"
    echo "env_sha256=$(openssl dgst -sha256 -r "${WORK_DIR}/.env" | awk '{print $1}')"
    echo "isp_list_sha256=$(openssl dgst -sha256 -r "${WORK_DIR}/isp-list.tsv" | awk '{print $1}')"
  } > "${WORK_DIR}/manifest.txt"

  raw_tar="${WORK_DIR}/payload.tar.gz"
  tar -C "${WORK_DIR}" -czf "${raw_tar}" .env isp-list.tsv manifest.txt
  encrypt_archive "${raw_tar}" "${output}"
  chmod 600 "${output}"

  log_success "加密迁移包已生成: ${output}"
  log_info "请把迁移包和密码分开保存；迁移包不包含证书缓存，证书会在新服务器重新签发。"
}

validate_tar_members() {
  local archive="$1"
  local members member expected count
  members="$(tar -tzf "${archive}")"
  while IFS= read -r member; do
    case "${member}" in
      .env|isp-list.tsv|manifest.txt) ;;
      *)
        log_error "迁移包包含非法路径: ${member}"
        exit 1
        ;;
    esac
  done <<< "${members}"

  for expected in .env isp-list.tsv manifest.txt; do
    count="$(grep -Fxc "${expected}" <<< "${members}" || true)"
    [[ "${count}" == "1" ]] || {
      log_error "迁移包缺少或重复文件: ${expected}"
      exit 1
    }
  done

  if tar -tvzf "${archive}" | awk '$1 !~ /^-/ { bad=1 } END { exit bad ? 0 : 1 }'; then
    log_error "迁移包包含非普通文件"
    exit 1
  fi
}

verify_manifest() {
  local extract_dir="$1"
  local format expected_env expected_list actual_env actual_list
  format="$(awk -F= '$1=="format" {print substr($0, index($0, "=") + 1)}' "${extract_dir}/manifest.txt")"
  [[ "${format}" == "sing-box-deploy-migration-v1" ]] || {
    log_error "不支持的迁移包格式"
    exit 1
  }
  expected_env="$(awk -F= '$1=="env_sha256" {print $2}' "${extract_dir}/manifest.txt")"
  expected_list="$(awk -F= '$1=="isp_list_sha256" {print $2}' "${extract_dir}/manifest.txt")"
  actual_env="$(openssl dgst -sha256 -r "${extract_dir}/.env" | awk '{print $1}')"
  actual_list="$(openssl dgst -sha256 -r "${extract_dir}/isp-list.tsv" | awk '{print $1}')"
  [[ -n "${expected_env}" && "${actual_env}" == "${expected_env}" ]] || {
    log_error ".env 完整性校验失败"
    exit 1
  }
  [[ -n "${expected_list}" && "${actual_list}" == "${expected_list}" ]] || {
    log_error "ISP 清单完整性校验失败"
    exit 1
  }
}

import_bundle() {
  local source="${1:-}"
  [[ -n "${source}" ]] || {
    log_error "import 需要迁移包路径"
    usage
    exit 1
  }
  [[ "${source}" == /* ]] || source="${PWD}/${source}"
  [[ -f "${source}" ]] || {
    log_error "迁移包不存在: ${source}"
    exit 1
  }

  WORK_DIR="$(mktemp -d)"
  local raw_tar="${WORK_DIR}/payload.tar.gz"
  local extract_dir="${WORK_DIR}/extract"
  mkdir -m 700 "${extract_dir}"

  log_info "解密并校验迁移包..."
  decrypt_archive "${source}" "${raw_tar}"
  validate_tar_members "${raw_tar}"
  tar --no-same-owner --no-same-permissions -C "${extract_dir}" -xzf "${raw_tar}"

  local file
  for file in .env isp-list.tsv manifest.txt; do
    [[ -f "${extract_dir}/${file}" && ! -L "${extract_dir}/${file}" ]] || {
      log_error "迁移包中的 ${file} 不是普通文件"
      exit 1
    }
  done
  verify_manifest "${extract_dir}"

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  [[ ! -f "${SCRIPT_DIR}/.env" ]] || cp -a "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/.env.bak.${timestamp}"
  [[ ! -f "${SCRIPT_DIR}/isp-list.tsv" ]] || cp -a "${SCRIPT_DIR}/isp-list.tsv" "${SCRIPT_DIR}/isp-list.tsv.bak.${timestamp}"
  install -m 600 "${extract_dir}/.env" "${SCRIPT_DIR}/.env"
  install -m 600 "${extract_dir}/isp-list.tsv" "${SCRIPT_DIR}/isp-list.tsv"

  log_success "配置已恢复到 ${SCRIPT_DIR}"
  log_info "确认新服务器 DNS 和安全组后，运行: sudo ./install.sh"
}

main() {
  case "${1:-}" in
    export)
      shift
      export_bundle "${1:-}"
      ;;
    import)
      shift
      import_bundle "${1:-}"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      log_error "未知操作: $1"
      usage
      exit 1
      ;;
  esac
}

main "$@"
