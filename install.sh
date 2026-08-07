#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# =========================================================
# sing-box 自动化部署脚本（Debian / Ubuntu）
# - Trojan + Hysteria2
# - 主出口：私有 ISP SOCKS5 清单（每行生成独立入口与订阅）
# - AI 强制走当前入口对应 ISP；可选让视频/CDN/软件包下载从当前服务器直出
# - 无通用 VPS 直出兜底，未匹配的 sing-box 入站默认 block
# - Cloudflare DNS-01 自动签发证书
# - 配置校验 / 失败回滚 / 增量 UFW
# =========================================================

# -----------------------------
# 基础变量
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONFIG_DIR="/etc/sing-box"
CONFIG_PATH="${CONFIG_DIR}/config.json"
CERT_DIR="/var/lib/sing-box/certmagic"
SOURCES_FILE="/etc/apt/sources.list.d/sagernet.sources"
KEYRING_FILE="/etc/apt/keyrings/sagernet.asc"
NETWORK_TUNING_FILE="/etc/sysctl.d/99-sing-box-performance.conf"

FORCE_REINSTALL=0
SKIP_FIREWALL=0
SKIP_NETWORK_TUNING=0
SKIP_EGRESS_PREFLIGHT=0
SKIP_PAGES=0
PAGES_ONLY=0
NO_START=0
VALIDATE_ONLY=0

TMP_CONFIG=""
BACKUP_CONFIG=""
PAGES_STAGE_ROOT=""

DEFAULT_AI_ISP_DOMAINS="openai.com,chatgpt.com,oaistatic.com,oaiusercontent.com,openai.azure.com,ai.com,openaiapi-site.azureedge.net"
DEFAULT_AI_ISP_DOMAINS+=",anthropic.com,claude.ai,servd-anthropic-website.b-cdn.net"
DEFAULT_AI_ISP_DOMAINS+=",gemini.google.com,aistudio.google.com,ai.google.dev,bard.google.com,generativelanguage.googleapis.com,aiplatform.googleapis.com"
DEFAULT_AI_ISP_DOMAINS+=",proactivebackend-pa.googleapis.com,alkalimakersuite-pa.clients6.google.com"
DEFAULT_AI_ISP_DOMAINS+=",deepseek.com,deepseek.ai,perplexity.ai,grok.com,x.ai"
DEFAULT_AI_ISP_DOMAINS+=",githubcopilot.com,copilot.microsoft.com,copilot-proxy.githubusercontent.com,openrouter.ai,poe.com"
DEFAULT_AI_ISP_DOMAINS+=",mistral.ai,cohere.com,cohere.ai,groq.com,groqcloud.com,together.ai,together.xyz,fireworks.ai"
DEFAULT_AI_ISP_DOMAINS+=",replicate.com,replicate.delivery,stability.ai,midjourney.com,cursor.com,cursor.sh,codeium.com,windsurf.com"
DEFAULT_AI_ISP_DOMAINS+=",qwen.ai,dashscope.aliyuncs.com,tavily.com,exa.ai"

DEFAULT_DIRECT_BULK_DOMAINS="youtube.com,youtu.be,youtube-nocookie.com,googlevideo.com,ytimg.com,youtubei.googleapis.com,ggpht.com"
DEFAULT_DIRECT_BULK_DOMAINS+=",twitch.tv,ttvnw.net,jtvnw.net,vimeo.com,vimeocdn.com,dailymotion.com,dmcdn.net"
DEFAULT_DIRECT_BULK_DOMAINS+=",python.org,pypi.org,pythonhosted.org,nodejs.org,npmjs.org,npmjs.com"
DEFAULT_DIRECT_BULK_DOMAINS+=",githubassets.com,githubusercontent.com,release-assets.githubusercontent.com,codeload.github.com,ghcr.io"
DEFAULT_DIRECT_BULK_DOMAINS+=",docker.io,docker.com,dockerusercontent.com,production.cloudflare.docker.com"
DEFAULT_DIRECT_BULK_DOMAINS+=",crates.io,rustup.rs,static.rust-lang.org,proxy.golang.org,sum.golang.org,go.dev"
DEFAULT_DIRECT_BULK_DOMAINS+=",repo.maven.apache.org,repo1.maven.org,gradle.org,debian.org,ubuntu.com,packages.microsoft.com"
DEFAULT_DIRECT_BULK_DOMAINS+=",download.jetbrains.com,cache-redirector.jetbrains.com,dl.google.com,dl.k8s.io,k8s.io"
DEFAULT_DIRECT_BULK_DOMAINS+=",swcdn.apple.com,updates.cdn-apple.com,mesu.apple.com,windowsupdate.com,download.microsoft.com"
DEFAULT_DIRECT_BULK_DOMAINS+=",steamcontent.com,steamstatic.com"
DEFAULT_DIRECT_BULK_DOMAINS+=",huggingface.co,hf.co,huggingfaceusercontent.com,hf.space"
DEFAULT_DIRECT_BULK_DOMAINS+=",1drv.com,1drv.ms,livefilestore.com,oneclient.sfx.ms,onedrive.com,onedrive.live.com,photos.live.com,skydrive.wns.windows.com"
DEFAULT_DIRECT_BULK_DOMAINS+=",sharepoint.com,sharepointonline.com,spoprod-a.akamaihd.net,storage.live.com,storage.msn.com"

DEFAULT_CLASH_FORCE_TCP_DOMAINS="github.com,githubassets.com,githubusercontent.com,release-assets.githubusercontent.com,codeload.github.com,ghcr.io"
DEFAULT_CLASH_FORCE_TCP_DOMAINS+=",google.com,gstatic.com,googleapis.com,googleusercontent.com"
DEFAULT_CLASH_FORCE_TCP_DOMAINS+=",x.com,twitter.com,twimg.com,t.co"

DEFAULT_TELEGRAM_DOMAINS="api.imem.app,api.swiftgram.app,cdn-telegram.org,comments.app,contest.com,graph.org,legra.ph"
DEFAULT_TELEGRAM_DOMAINS+=",mbrx.app,quiz.directory,stel.com,t.me,tdesktop.com,telega.one,telegra.ph"
DEFAULT_TELEGRAM_DOMAINS+=",telegram-cdn.org,telegram.dog,telegram.me,telegram.org,telegram.space,telegramdownload.com"
DEFAULT_TELEGRAM_DOMAINS+=",telesco.pe,tg.dev,tx.me,usercontent.dev"
DEFAULT_TELEGRAM_IP_CIDRS="5.28.192.0/18,91.105.192.0/23,91.108.0.0/16,95.161.64.0/20"
DEFAULT_TELEGRAM_IP_CIDRS+=",109.239.140.0/24,139.59.210.98/32,149.154.160.0/20,185.76.151.0/24,196.55.216.167/32"
DEFAULT_TELEGRAM_IP_CIDRS+=",2001:67c:4e8::/48,2001:b28:f23c::/47,2001:b28:f23f::/48,2a0a:f280::/29"

DEFAULT_CLASH_RULESET_UPSTREAM_REPO="https://github.com/Loyalsoldier/clash-rules.git"
DEFAULT_CLASH_RULESET_UPSTREAM_BRANCH="release"
DEFAULT_CLASH_RULESET_FALLBACK_URL="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release"

# -----------------------------
# 颜色
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------
# 日志
# -----------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERR]${NC} $*" >&2; }

# -----------------------------
# 清理
# -----------------------------
cleanup() {
  if [[ -n "${TMP_CONFIG}" && -f "${TMP_CONFIG}" ]]; then
    rm -f "${TMP_CONFIG}"
  fi
  if [[ -n "${PAGES_STAGE_ROOT}" && -d "${PAGES_STAGE_ROOT}" ]]; then
    rm -rf -- "${PAGES_STAGE_ROOT}"
  fi
}
trap cleanup EXIT

on_error() {
  local line="${1:-unknown}"
  log_error "脚本执行失败，出错行号: ${line}"
}
trap 'on_error $LINENO' ERR

# -----------------------------
# 帮助
# -----------------------------
usage() {
  cat <<'EOF'
用法:
  bash install-singbox.sh [选项]

选项:
  --env <path>         指定 .env 文件路径
  --force-reinstall    强制重装 sing-box
  --skip-firewall      跳过 UFW 配置
  --skip-network-tuning
                      跳过 Linux 网络参数优化
  --skip-egress-preflight
                      跳过 ISP SOCKS5 出口预检（仅限受控预发布）
  --skip-pages        跳过 Cloudflare Pages 发布与规则同步定时器
  --pages-only       只生成、发布并验证 Cloudflare Pages；不修改 sing-box、UFW 或系统网络
  --no-start           仅部署配置，不启动/重启 sing-box
  --validate-only      只生成并校验临时配置，不修改系统
  -h, --help           显示帮助

示例:
  bash install-singbox.sh
  bash install-singbox.sh --env /root/sb/.env
  bash install-singbox.sh --force-reinstall
EOF
}

# -----------------------------
# 参数解析
# -----------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        [[ $# -ge 2 ]] || { log_error "--env 需要一个路径参数"; exit 1; }
        ENV_FILE="$2"
        shift 2
        ;;
      --force-reinstall)
        FORCE_REINSTALL=1
        shift
        ;;
      --skip-firewall)
        SKIP_FIREWALL=1
        shift
        ;;
      --skip-network-tuning)
        SKIP_NETWORK_TUNING=1
        shift
        ;;
      --skip-egress-preflight)
        SKIP_EGRESS_PREFLIGHT=1
        shift
        ;;
      --skip-pages)
        SKIP_PAGES=1
        shift
        ;;
      --pages-only)
        PAGES_ONLY=1
        shift
        ;;
      --no-start)
        NO_START=1
        shift
        ;;
      --validate-only)
        VALIDATE_ONLY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done

  if (( PAGES_ONLY == 1 )); then
    if (( FORCE_REINSTALL == 1 || SKIP_FIREWALL == 1 || SKIP_NETWORK_TUNING == 1 \
      || SKIP_EGRESS_PREFLIGHT == 1 || SKIP_PAGES == 1 || NO_START == 1 || VALIDATE_ONLY == 1 )); then
      log_error "--pages-only 只能与 --env 一起使用，不能组合数据面或校验专用选项"
      exit 1
    fi
  fi
}

# -----------------------------
# 工具函数
# -----------------------------
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_true() {
  local v="${1:-}"
  case "${v,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

validate_bool() {
  local name="$1"
  local value="${2:-}"
  case "${value,,}" in
    1|0|true|false|yes|no|y|n|on|off) ;;
    *)
      log_error "${name} 必须是 true/false、yes/no、on/off 或 1/0"
      exit 1
      ;;
  esac
}

csv_list_contains() {
  local list="${1:-}"
  local expected
  expected="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  local item item_lower
  while IFS= read -r item; do
    item="$(trim "${item}")"
    [[ -z "${item}" ]] && continue
    item_lower="$(printf '%s' "${item}" | tr '[:upper:]' '[:lower:]')"
    [[ "${item_lower}" == "${expected}" ]] && return 0
  done < <(printf '%s\n' "${list}" | tr ',\t ' '\n')
  return 1
}

append_csv_list() {
  local current="${1:-}"
  local extra="${2:-}"
  if [[ -z "${current}" ]]; then
    printf '%s' "${extra}"
  elif [[ -z "${extra}" ]]; then
    printf '%s' "${current}"
  else
    printf '%s,%s' "${current}" "${extra}"
  fi
}

normalize_domain_suffix_csv() {
  local variable_name="$1"
  local raw_value="${!variable_name:-}"
  local normalized=""
  local domain label

  while IFS= read -r domain; do
    domain="$(trim "${domain}")"
    domain="$(printf '%s' "${domain}" | tr '[:upper:]' '[:lower:]')"
    [[ -z "${domain}" ]] && continue

    if (( ${#domain} > 253 )) || [[ "${domain}" != *.* || "${domain}" == *..* \
      || ! "${domain}" =~ ^[a-z0-9.-]+$ ]]; then
      log_error "${variable_name} 包含非法域名: ${domain}"
      return 1
    fi

    local labels=()
    IFS='.' read -r -a labels <<< "${domain}"
    for label in "${labels[@]}"; do
      if (( ${#label} < 1 || ${#label} > 63 )) \
        || [[ ! "${label}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        log_error "${variable_name} 包含非法域名: ${domain}"
        return 1
      fi
    done

    if ! csv_list_contains "${normalized}" "${domain}"; then
      normalized="$(append_csv_list "${normalized}" "${domain}")"
    fi
  done < <(printf '%s\n' "${raw_value}" | tr ',\t ' '\n')

  printf -v "${variable_name}" '%s' "${normalized}"
}

validate_direct_bulk_apps() {
  local app
  while IFS= read -r app; do
    app="$(trim "${app}")"
    [[ -z "${app}" ]] && continue
    case "${app,,}" in
      telegram) ;;
      *)
        log_error "DIRECT_BULK_APPS 包含不支持的应用: ${app}"
        log_error "当前支持: telegram"
        exit 1
        ;;
    esac
  done < <(printf '%s\n' "${DIRECT_BULK_APPS:-}" | tr ',\t ' '\n')
}

normalize_ip_or_cidr() {
  local value="$1"
  local address prefix

  if [[ "${value}" == */* ]]; then
    [[ "${value}" != */*/* ]] || return 1
    address="${value%/*}"
    prefix="${value##*/}"
    [[ -n "${prefix}" ]] || return 1
  else
    address="${value}"
    prefix=""
  fi

  if [[ "${address}" == *:* ]]; then
    [[ "${address}" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "${address}" != *:::* ]] || return 1
    prefix="${prefix:-128}"
    [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
    (( ${#prefix} <= 3 )) || return 1
    (( 10#${prefix} <= 128 )) || return 1

    local left right remainder group
    local left_count=0
    local right_count=0
    local -a left_groups right_groups all_groups
    if [[ "${address}" == *::* ]]; then
      remainder="${address#*::}"
      [[ "${remainder}" != *::* ]] || return 1
      left="${address%%::*}"
      right="${remainder}"
      if [[ -n "${left}" ]]; then
        IFS=':' read -r -a left_groups <<< "${left}"
        left_count=${#left_groups[@]}
        for group in "${left_groups[@]}"; do
          [[ "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        done
      fi
      if [[ -n "${right}" ]]; then
        IFS=':' read -r -a right_groups <<< "${right}"
        right_count=${#right_groups[@]}
        for group in "${right_groups[@]}"; do
          [[ "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        done
      fi
      (( left_count + right_count < 8 )) || return 1
    else
      [[ "${address}" != :* && "${address}" != *: ]] || return 1
      IFS=':' read -r -a all_groups <<< "${address}"
      (( ${#all_groups[@]} == 8 )) || return 1
      for group in "${all_groups[@]}"; do
        [[ "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      done
    fi
    address="$(printf '%s' "${address}" | tr '[:upper:]' '[:lower:]')"
    printf '%s/%s' "${address}" "$((10#${prefix}))"
    return 0
  fi

  [[ "${address}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  prefix="${prefix:-32}"
  [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
  (( ${#prefix} <= 3 )) || return 1
  (( 10#${prefix} <= 32 )) || return 1

  local octet1 octet2 octet3 octet4 octet
  IFS='.' read -r octet1 octet2 octet3 octet4 <<< "${address}"
  for octet in "${octet1}" "${octet2}" "${octet3}" "${octet4}"; do
    (( 10#${octet} <= 255 )) || return 1
  done
  printf '%d.%d.%d.%d/%d' \
    "$((10#${octet1}))" "$((10#${octet2}))" \
    "$((10#${octet3}))" "$((10#${octet4}))" "$((10#${prefix}))"
}

normalize_client_direct_ip_cidrs() {
  local item normalized_item
  local -a normalized=()
  while IFS= read -r item; do
    item="$(trim "${item}")"
    [[ -z "${item}" ]] && continue
    if ! normalized_item="$(normalize_ip_or_cidr "${item}")"; then
      log_error "CLIENT_DIRECT_IP_CIDRS 包含非法 IP/CIDR: ${item}"
      return 1
    fi
    normalized+=("${normalized_item}")
  done < <(printf '%s\n' "${CLIENT_DIRECT_IP_CIDRS:-}" | tr ',\t ' '\n')

  if (( ${#normalized[@]} > 0 )); then
    CLIENT_DIRECT_IP_CIDRS="$(IFS=,; printf '%s' "${normalized[*]}")"
  else
    CLIENT_DIRECT_IP_CIDRS=""
  fi
  export CLIENT_DIRECT_IP_CIDRS
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "请使用 root 运行此脚本"
    exit 1
  fi
}

require_supported_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_error "无法识别系统类型：缺少 /etc/os-release"
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID:-}" in
    debian|ubuntu)
      log_success "系统检查通过: ${PRETTY_NAME:-$ID}"
      ;;
    *)
      log_error "当前仅支持 Debian / Ubuntu，检测到: ${PRETTY_NAME:-$ID}"
      exit 1
      ;;
  esac
}

# -----------------------------
# 安全读取 .env
# - 不使用 source
# - 支持：
#   KEY=value
#   KEY="value"
#   KEY='value'
# - 不支持行尾内联注释
# -----------------------------
load_env() {
  [[ -f "${ENV_FILE}" ]] || {
    log_error "未找到 .env 文件: ${ENV_FILE}"
    exit 1
  }

  log_info "读取配置文件: ${ENV_FILE}"

  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    local line
    line="$(trim "${raw_line}")"

    [[ -z "${line}" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      log_error ".env 存在非法行：${raw_line}"
      log_error "请使用 KEY=value 格式，且不要写行尾注释"
      exit 1
    fi

    local key="${line%%=*}"
    local value="${line#*=}"

    key="$(trim "${key}")"
    value="$(trim "${value}")"

    # 去掉包裹引号
    # 去掉包裹引号（避免复杂转义导致语法错误）
	if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
	  value="${value:1:-1}"
	  value="${value//\\n/$'\n'}"
	  value="${value//\\\\/\\}"
	elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
	  value="${value:1:-1}"
	fi

    printf -v "${key}" '%s' "${value}"
    export "${key}"
  done < "${ENV_FILE}"

  # 默认值
  TROJAN_PORT="${TROJAN_PORT:-443}"
  HYSTERIA_PORT="${HYSTERIA_PORT:-8443}"
  HYSTERIA_UP_MBPS="${HYSTERIA_UP_MBPS:-50}"
  HYSTERIA_DOWN_MBPS="${HYSTERIA_DOWN_MBPS:-100}"
  HYSTERIA_CC_MODE="${HYSTERIA_CC_MODE:-bbr}"
  ISP_PORT_STEP="${ISP_PORT_STEP:-10000}"
  AI_ISP_DOMAINS="${AI_ISP_DOMAINS:-${DEFAULT_AI_ISP_DOMAINS}}"
  DIRECT_BULK_ENABLED="${DIRECT_BULK_ENABLED:-false}"
  DIRECT_BULK_DOMAINS="${DIRECT_BULK_DOMAINS:-${DEFAULT_DIRECT_BULK_DOMAINS}}"
  DIRECT_BULK_APPS="${DIRECT_BULK_APPS:-}"
  DIRECT_BULK_IP_CIDRS="${DIRECT_BULK_IP_CIDRS:-}"
  CLIENT_DIRECT_IP_CIDRS="${CLIENT_DIRECT_IP_CIDRS:-}"
  CLASH_FORCE_TCP_ENABLED="${CLASH_FORCE_TCP_ENABLED:-true}"
  CLASH_FORCE_TCP_DOMAINS="${CLASH_FORCE_TCP_DOMAINS:-${DEFAULT_CLASH_FORCE_TCP_DOMAINS}}"
  if csv_list_contains "${DIRECT_BULK_APPS}" "telegram"; then
    DIRECT_BULK_DOMAINS="$(append_csv_list "${DIRECT_BULK_DOMAINS}" "${DEFAULT_TELEGRAM_DOMAINS}")"
    DIRECT_BULK_IP_CIDRS="$(append_csv_list "${DIRECT_BULK_IP_CIDRS}" "${DEFAULT_TELEGRAM_IP_CIDRS}")"
  fi
  CLASH_RULESET_UPSTREAM_REPO="${CLASH_RULESET_UPSTREAM_REPO:-${DEFAULT_CLASH_RULESET_UPSTREAM_REPO}}"
  CLASH_RULESET_UPSTREAM_BRANCH="${CLASH_RULESET_UPSTREAM_BRANCH:-${DEFAULT_CLASH_RULESET_UPSTREAM_BRANCH}}"
  if [[ -z "${CLASH_RULESET_BASE_URL:-}" ]]; then
    if [[ -n "${SUB_DOMAIN:-}" ]]; then
      CLASH_RULESET_BASE_URL="https://${SUB_DOMAIN}/rules"
    else
      CLASH_RULESET_BASE_URL="${DEFAULT_CLASH_RULESET_FALLBACK_URL}"
    fi
  fi
  CF_PAGES_PROJECT="${CF_PAGES_PROJECT:-sub-converter}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
  SSH_PORT="${SSH_PORT:-22}"
  ENABLE_UFW="${ENABLE_UFW:-true}"
  ENABLE_NETWORK_TUNING="${ENABLE_NETWORK_TUNING:-true}"
  ENABLE_BBR="${ENABLE_BBR:-true}"
  ENABLE_TCP_FAST_OPEN="${ENABLE_TCP_FAST_OPEN:-true}"
  UDP_BUFFER_BYTES="${UDP_BUFFER_BYTES:-16777216}"
  ENABLE_EGRESS_PREFLIGHT="${ENABLE_EGRESS_PREFLIGHT:-true}"
  EGRESS_PREFLIGHT_URL="${EGRESS_PREFLIGHT_URL:-https://api.ipify.org}"
  EGRESS_PREFLIGHT_ATTEMPTS="${EGRESS_PREFLIGHT_ATTEMPTS:-2}"

  log_success ".env 已加载"
}

validate_port() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || { log_error "${name} 必须是数字"; exit 1; }
  (( value >= 1 && value <= 65535 )) || { log_error "${name} 必须在 1-65535 范围内"; exit 1; }
}

derive_offset_port() {
  local name="$1"
  local base="$2"
  local offset="$3"

  validate_port "${name}_BASE" "${base}"

  local derived=$((base + offset))
  (( derived >= 1 && derived <= 65535 )) || {
    log_error "${name} 默认端口越界，请手动在 .env 中设置 ${name}"
    exit 1
  }

  printf '%s' "${derived}"
}

validate_positive_int() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || { log_error "${name} 必须是非负整数"; exit 1; }
}

validate_domain_like() {
  local name="$1"
  local value="$2"
  [[ -n "${value}" ]] || { log_error "${name} 不能为空"; exit 1; }
  [[ "${value}" != *" "* ]] || { log_error "${name} 不能包含空格"; exit 1; }
  [[ "${value}" == *.* ]] || { log_error "${name} 格式看起来不像域名"; exit 1; }
}

load_isp_list() {
  [[ -n "${ISP_LIST_FILE:-}" ]] || {
    log_error "未配置 ISP_LIST_FILE"
    exit 1
  }

  if [[ "${ISP_LIST_FILE}" != /* ]]; then
    ISP_LIST_FILE="${SCRIPT_DIR}/${ISP_LIST_FILE}"
  fi
  [[ -f "${ISP_LIST_FILE}" ]] || {
    log_error "未找到 ISP 清单: ${ISP_LIST_FILE}"
    exit 1
  }

  local permissions
  permissions="$(stat -c '%a' "${ISP_LIST_FILE}")"
  if (( (8#${permissions} & 077) != 0 )); then
    log_error "ISP 清单包含凭据，权限必须为 600: ${ISP_LIST_FILE}（当前 ${permissions}）"
    exit 1
  fi

  validate_positive_int "ISP_PORT_STEP" "${ISP_PORT_STEP}"
  (( ISP_PORT_STEP > 0 )) || {
    log_error "ISP_PORT_STEP 必须大于 0"
    exit 1
  }

  ISP_IDS=()
  ISP_HOSTS=()
  ISP_HTTP_PORTS=()
  ISP_SOCKS_PORTS=()
  ISP_USERS=()
  ISP_PASSWORDS=()
  ISP_EXPIRES=()
  ISP_TROJAN_PORTS=()
  ISP_HYSTERIA_PORTS=()

  local today slot=0 line_number=0
  local id host http_port socks_port user password expires extra
  local trojan_port hysteria_port
  local -A seen_ids=()
  local -A seen_client_ports=()
  today="$(date -u +%F)"

  while IFS=$'\t' read -r id host http_port socks_port user password expires extra || [[ -n "${id}${host}${http_port}${socks_port}${user}${password}${expires}${extra}" ]]; do
    line_number=$((line_number + 1))
    id="${id%$'\r'}"
    expires="${expires%$'\r'}"

    [[ -z "${id}${host}${http_port}${socks_port}${user}${password}${expires}${extra}" ]] && continue
    [[ "${id:0:1}" == "#" ]] && continue
    if [[ "${id}" == "编号" || "${id,,}" == "id" ]]; then
      continue
    fi

    if [[ -n "${extra}" || -z "${id}" || -z "${host}" || -z "${http_port}" || -z "${socks_port}" || -z "${user}" || -z "${password}" || -z "${expires}" ]]; then
      log_error "ISP 清单第 ${line_number} 行必须恰好包含 7 个非空 TSV 字段"
      exit 1
    fi
    [[ "${id}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || {
      log_error "ISP 清单第 ${line_number} 行编号非法: ${id}"
      exit 1
    }
    [[ -z "${seen_ids[${id}]:-}" ]] || {
      log_error "ISP 清单编号重复: ${id}"
      exit 1
    }
    seen_ids["${id}"]=1

    validate_domain_like "ISP ${id} IP/域名" "${host}"
    validate_port "ISP ${id} HTTP_PORT" "${http_port}"
    validate_port "ISP ${id} SOCKS5_PORT" "${socks_port}"
    [[ "${expires}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -u -d "${expires}T00:00:00Z" >/dev/null 2>&1 || {
      log_error "ISP ${id} 到期时间必须是有效的 YYYY-MM-DD: ${expires}"
      exit 1
    }

    trojan_port=$((TROJAN_PORT + slot * ISP_PORT_STEP))
    hysteria_port=$((HYSTERIA_PORT + slot * ISP_PORT_STEP))
    validate_port "ISP ${id} TROJAN_PORT" "${trojan_port}"
    validate_port "ISP ${id} HYSTERIA_PORT" "${hysteria_port}"
    for client_port in "${trojan_port}" "${hysteria_port}"; do
      [[ -z "${seen_client_ports[${client_port}]:-}" ]] || {
        log_error "ISP 清单生成了重复的客户端端口: ${client_port}"
        exit 1
      }
      seen_client_ports["${client_port}"]=1
    done
    slot=$((slot + 1))

    if [[ "${expires}" < "${today}" ]]; then
      log_warn "ISP ${id} 已于 ${expires} 到期，本次部署跳过"
      continue
    fi

    ISP_IDS+=("${id}")
    ISP_HOSTS+=("${host}")
    ISP_HTTP_PORTS+=("${http_port}")
    ISP_SOCKS_PORTS+=("${socks_port}")
    ISP_USERS+=("${user}")
    ISP_PASSWORDS+=("${password}")
    ISP_EXPIRES+=("${expires}")
    ISP_TROJAN_PORTS+=("${trojan_port}")
    ISP_HYSTERIA_PORTS+=("${hysteria_port}")
  done < "${ISP_LIST_FILE}"

  ISP_COUNT="${#ISP_IDS[@]}"
  (( ISP_COUNT > 0 )) || {
    log_error "ISP 清单中没有未到期的可用条目"
    exit 1
  }
  log_success "ISP 清单已加载: ${ISP_COUNT} 个有效条目"
}

build_isp_json() {
  ISP_LIST_JSON='[]'
  local index
  for ((index = 0; index < ISP_COUNT; index++)); do
    ISP_LIST_JSON=$(jq -cn \
      --argjson current "${ISP_LIST_JSON}" \
      --arg id "${ISP_IDS[index]}" \
      --arg host "${ISP_HOSTS[index]}" \
      --arg username "${ISP_USERS[index]}" \
      --arg password "${ISP_PASSWORDS[index]}" \
      --arg expires "${ISP_EXPIRES[index]}" \
      --argjson http_port "${ISP_HTTP_PORTS[index]}" \
      --argjson socks_port "${ISP_SOCKS_PORTS[index]}" \
      --argjson trojan_port "${ISP_TROJAN_PORTS[index]}" \
      --argjson hysteria_port "${ISP_HYSTERIA_PORTS[index]}" \
      '$current + [{id: $id, host: $host, http_port: $http_port, socks_port: $socks_port, username: $username, password: $password, expires: $expires, trojan_port: $trojan_port, hysteria_port: $hysteria_port}]')
  done
  ISP_PUBLIC_LIST_JSON=$(jq -c 'map({id, host, expires, trojan_port, hysteria_port})' <<< "${ISP_LIST_JSON}")
}

validate_config() {
  log_info "校验配置..."

  local required_vars=(
    TROJAN_DOMAIN
    HYSTERIA_DOMAIN
    CF_DNS_EDIT_TOKEN
    ACME_EMAIL
    ISP_LIST_FILE
    TROJAN_PASSWORD
    HYSTERIA_PASSWORD
    HYSTERIA_OBFS_PASSWORD
  )

  local missing=()
  local var
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    log_error "以下配置项未设置："
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
  fi

  validate_domain_like "TROJAN_DOMAIN" "${TROJAN_DOMAIN}"
  validate_domain_like "HYSTERIA_DOMAIN" "${HYSTERIA_DOMAIN}"

  if [[ "${TROJAN_DOMAIN}" == "${HYSTERIA_DOMAIN}" ]]; then
    log_error "TROJAN_DOMAIN 和 HYSTERIA_DOMAIN 不应相同"
    exit 1
  fi

  # J 服务器已退役：禁止旧配置重新把不可用的 J 节点写回订阅。
  HAS_VPS_J=0
  if [[ -n "${J_TROJAN_DOMAIN:-}" || -n "${J_HYSTERIA_DOMAIN:-}" ]]; then
    log_error "J 服务器已退役；请从 .env 中删除 J_TROJAN_DOMAIN 和 J_HYSTERIA_DOMAIN 后重试"
    exit 1
  fi

  validate_port "TROJAN_PORT" "${TROJAN_PORT}"
  validate_port "HYSTERIA_PORT" "${HYSTERIA_PORT}"
  validate_port "SSH_PORT" "${SSH_PORT}"
  validate_direct_bulk_apps
  normalize_client_direct_ip_cidrs || exit 1
  load_isp_list

  validate_positive_int "HYSTERIA_UP_MBPS" "${HYSTERIA_UP_MBPS}"
  validate_positive_int "HYSTERIA_DOWN_MBPS" "${HYSTERIA_DOWN_MBPS}"
  case "${HYSTERIA_CC_MODE,,}" in
    bbr) ;;
    brutal)
      (( HYSTERIA_UP_MBPS > 0 && HYSTERIA_DOWN_MBPS > 0 )) || {
        log_error "HYSTERIA_CC_MODE=brutal 时 HYSTERIA_UP_MBPS 和 HYSTERIA_DOWN_MBPS 必须大于 0"
        exit 1
      }
      ;;
    *)
      log_error "HYSTERIA_CC_MODE 非法，允许值: bbr|brutal"
      exit 1
      ;;
  esac
  validate_positive_int "UDP_BUFFER_BYTES" "${UDP_BUFFER_BYTES}"
  (( UDP_BUFFER_BYTES >= 1048576 )) || {
    log_error "UDP_BUFFER_BYTES 不应低于 1048576"
    exit 1
  }
  validate_bool "ENABLE_NETWORK_TUNING" "${ENABLE_NETWORK_TUNING}"
  validate_bool "ENABLE_BBR" "${ENABLE_BBR}"
  validate_bool "ENABLE_TCP_FAST_OPEN" "${ENABLE_TCP_FAST_OPEN}"
  validate_bool "ENABLE_EGRESS_PREFLIGHT" "${ENABLE_EGRESS_PREFLIGHT}"
  validate_bool "CLASH_FORCE_TCP_ENABLED" "${CLASH_FORCE_TCP_ENABLED}"
  normalize_domain_suffix_csv "CLASH_FORCE_TCP_DOMAINS" || exit 1
  if is_true "${CLASH_FORCE_TCP_ENABLED}" && [[ -z "${CLASH_FORCE_TCP_DOMAINS}" ]]; then
    log_error "CLASH_FORCE_TCP_ENABLED=true 时 CLASH_FORCE_TCP_DOMAINS 不能为空"
    exit 1
  fi
  validate_positive_int "EGRESS_PREFLIGHT_ATTEMPTS" "${EGRESS_PREFLIGHT_ATTEMPTS}"
  [[ "${EGRESS_PREFLIGHT_URL}" =~ ^https:// ]] || {
    log_error "EGRESS_PREFLIGHT_URL 必须使用 https://"
    exit 1
  }
  [[ "${LOG_LEVEL}" =~ ^(trace|debug|info|warn|error|fatal|panic)$ ]] || {
    log_error "LOG_LEVEL 非法，允许值: trace|debug|info|warn|error|fatal|panic"
    exit 1
  }

  log_success "配置校验通过"
}

install_dependencies() {
  log_info "安装基础依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl git jq ca-certificates gnupg ufw util-linux
  log_success "基础依赖安装完成"
}

preflight_isp_egress() {
  if (( SKIP_EGRESS_PREFLIGHT == 1 )); then
    log_warn "按参数要求跳过 ISP 出口预检；不得据此执行 DNS 切换"
    return
  fi
  if ! is_true "${ENABLE_EGRESS_PREFLIGHT}"; then
    log_warn "ENABLE_EGRESS_PREFLIGHT=${ENABLE_EGRESS_PREFLIGHT}，跳过 ISP 出口预检"
    return
  fi

  log_info "预检 ${ISP_COUNT} 个 ISP SOCKS5 出口..."
  local index attempt ok
  local failed=()
  for ((index = 0; index < ISP_COUNT; index++)); do
    ok=0
    for ((attempt = 1; attempt <= EGRESS_PREFLIGHT_ATTEMPTS; attempt++)); do
      if curl -fsS --max-time 20 \
        --socks5-hostname "${ISP_HOSTS[index]}:${ISP_SOCKS_PORTS[index]}" \
        --proxy-user "${ISP_USERS[index]}:${ISP_PASSWORDS[index]}" \
        "${EGRESS_PREFLIGHT_URL}" >/dev/null 2>&1; then
        ok=1
        break
      fi
    done
    if (( ok == 1 )); then
      log_success "ISP ${ISP_IDS[index]} 出口预检通过"
    else
      failed+=("${ISP_IDS[index]}")
      log_error "ISP ${ISP_IDS[index]} 出口预检失败"
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    log_error "拒绝部署：以下 ISP 出口不可用: ${failed[*]}"
    log_info "迁移场景请先在上游放行新服务器公网 IP；仅受控预发布可使用 --skip-egress-preflight"
    exit 1
  fi
}

install_singbox() {
  log_info "配置 sing-box 官方 APT 源..."

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o "${KEYRING_FILE}"
  chmod a+r "${KEYRING_FILE}"

  cat > "${SOURCES_FILE}" <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: ${KEYRING_FILE}
EOF

  export DEBIAN_FRONTEND=noninteractive
  apt-get update

  if command -v sing-box >/dev/null 2>&1; then
    if (( FORCE_REINSTALL == 1 )); then
      log_info "强制重装 sing-box..."
      apt-get install --reinstall -y sing-box
    else
      log_info "升级/安装 sing-box..."
      apt-get install -y sing-box
    fi
  else
    log_info "安装 sing-box..."
    apt-get install -y sing-box
  fi

  log_success "sing-box 安装完成"
  sing-box version || true
}

prepare_dirs() {
  mkdir -p "${CONFIG_DIR}"
  mkdir -p "${CERT_DIR}"
  chmod 700 "${CONFIG_DIR}"
  chmod 700 "${CERT_DIR}"
}

backup_existing_config() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    BACKUP_CONFIG="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "${CONFIG_PATH}" "${BACKUP_CONFIG}"
    chmod 600 "${BACKUP_CONFIG}"
    log_success "已备份旧配置: ${BACKUP_CONFIG}"
  else
    log_info "未发现旧配置，跳过备份"
  fi
}

generate_config() {
  log_info "生成 sing-box 配置..."

  TMP_CONFIG="$(mktemp /tmp/sing-box-config.XXXXXX.json)"
  build_isp_json

  local direct_bulk_enabled_json=false
  local hy2_use_bbr_json=false
  local tcp_fast_open_json=false
  if is_true "${DIRECT_BULK_ENABLED}"; then
    direct_bulk_enabled_json=true
  fi
  if [[ "${HYSTERIA_CC_MODE,,}" == "bbr" ]]; then
    hy2_use_bbr_json=true
  fi
  if is_true "${ENABLE_TCP_FAST_OPEN}"; then
    tcp_fast_open_json=true
  fi

  jq -n \
    --arg log_level "${LOG_LEVEL}" \
    --arg trojan_domain "${TROJAN_DOMAIN}" \
    --arg hysteria_domain "${HYSTERIA_DOMAIN}" \
    --arg acme_email "${ACME_EMAIL}" \
    --arg cert_dir "${CERT_DIR}" \
    --arg cf_dns_edit_token "${CF_DNS_EDIT_TOKEN}" \
    --arg cf_zone_read_token "${CF_ZONE_READ_TOKEN:-}" \
    --arg tj_password "${TROJAN_PASSWORD}" \
    --arg hy2_password "${HYSTERIA_PASSWORD}" \
    --arg hy2_obfs_password "${HYSTERIA_OBFS_PASSWORD}" \
    --arg ai_isp_domains "${AI_ISP_DOMAINS}" \
    --arg direct_bulk_domains "${DIRECT_BULK_DOMAINS}" \
    --arg direct_bulk_ip_cidrs "${DIRECT_BULK_IP_CIDRS}" \
    --argjson isps "${ISP_LIST_JSON}" \
    --argjson direct_bulk_enabled "${direct_bulk_enabled_json}" \
    --argjson hy2_use_bbr "${hy2_use_bbr_json}" \
    --argjson tcp_fast_open "${tcp_fast_open_json}" \
    --argjson hy2_up_mbps "${HYSTERIA_UP_MBPS}" \
    --argjson hy2_down_mbps "${HYSTERIA_DOWN_MBPS}" \
    '
    def cf_dns01:
      ({
        provider: "cloudflare",
        api_token: $cf_dns_edit_token
      } + (if ($cf_zone_read_token | length) > 0
           then { zone_token: $cf_zone_read_token }
           else {}
           end));

    def trimstr:
      gsub("^\\s+|\\s+$"; "");

    def domain_list($domains):
      $domains
      | gsub("[\\n\\t ]+"; ",")
      | split(",")
      | map(trimstr)
      | map(select(length > 0))
      | unique;

    def client_inbounds:
      [$isps[] | "trojan-\(.id)-in", "hy2-\(.id)-in"];

    def ai_isp_rules:
      domain_list($ai_isp_domains) as $domains
      | if ($domains | length) > 0 then
          [$isps[] | {
            inbound: ["trojan-\(.id)-in", "hy2-\(.id)-in"],
            domain_suffix: $domains,
            outbound: "isp-out-\(.id)"
          }]
        else
          []
        end;

    def direct_bulk_rules:
      domain_list($direct_bulk_domains) as $domains
      | domain_list($direct_bulk_ip_cidrs) as $ip_cidrs
      | if $direct_bulk_enabled then
          [
            (if ($domains | length) > 0 then
              {
                inbound: client_inbounds,
                domain_suffix: $domains,
                outbound: "direct-out"
              }
            else empty end),
            (if ($ip_cidrs | length) > 0 then
              {
                inbound: client_inbounds,
                ip_cidr: $ip_cidrs,
                outbound: "direct-out"
              }
            else empty end)
          ]
        else
          []
        end;

    def trojan_inbound($tag; $port; $user_name):
      {
        type: "trojan",
        tag: $tag,
        listen: "::",
        listen_port: $port,
        tcp_fast_open: $tcp_fast_open,
        users: [
          {
            name: $user_name,
            password: $tj_password
          }
        ],
        tls: {
          enabled: true,
          server_name: $trojan_domain,
          alpn: ["h2", "http/1.1"],
          acme: {
            domain: [$trojan_domain],
            data_directory: $cert_dir,
            email: $acme_email,
            provider: "letsencrypt",
            disable_http_challenge: true,
            disable_tls_alpn_challenge: true,
            dns01_challenge: cf_dns01
          }
        }
      };

    def hy2_inbound($tag; $port; $user_name):
      ({
        type: "hysteria2",
        tag: $tag,
        listen: "::",
        listen_port: $port,
        ignore_client_bandwidth: $hy2_use_bbr,
        obfs: {
          type: "salamander",
          password: $hy2_obfs_password
        },
        users: [
          {
            name: $user_name,
            password: $hy2_password
          }
        ],
        tls: {
          enabled: true,
          server_name: $hysteria_domain,
          alpn: ["h3"],
          acme: {
            domain: [$hysteria_domain],
            data_directory: $cert_dir,
            email: $acme_email,
            provider: "letsencrypt",
            disable_http_challenge: true,
            disable_tls_alpn_challenge: true,
            dns01_challenge: cf_dns01
          }
        }
      } + if $hy2_use_bbr then
        {}
      else
        {
          up_mbps: $hy2_up_mbps,
          down_mbps: $hy2_down_mbps
        }
      end);

    {
      log: {
        level: $log_level,
        timestamp: true
      },
      dns: {
        servers: [
          {
            type: "local",
            tag: "dns-local"
          }
        ]
      },
      inbounds: (
        [$isps[] |
          trojan_inbound("trojan-\(.id)-in"; .trojan_port; "tj-\(.id)"),
          hy2_inbound("hy2-\(.id)-in"; .hysteria_port; "hy2-\(.id)")
        ]
      ),
      outbounds: (
        [$isps[] | {
          type: "socks",
          tag: "isp-out-\(.id)",
          server: .host,
          server_port: .socks_port,
          version: "5",
          tcp_fast_open: $tcp_fast_open,
          username: .username,
          password: .password
        }] + [
        (
          if $direct_bulk_enabled and (
            ((domain_list($direct_bulk_domains) | length) > 0) or
            ((domain_list($direct_bulk_ip_cidrs) | length) > 0)
          ) then
            {
              type: "direct",
              tag: "direct-out"
            }
          else
            empty
          end
        ),
        {
          type: "block",
          tag: "block"
        }
      ]),
      route: {
        rules: (
          [
            {
              action: "sniff"
            }
          ] + ai_isp_rules + direct_bulk_rules +
          [$isps[] | {
            inbound: ["trojan-\(.id)-in", "hy2-\(.id)-in"],
            outbound: "isp-out-\(.id)"
          }]
        ),
        final: "block",
        auto_detect_interface: true,
        default_domain_resolver: "dns-local"
      }
    }
    ' > "${TMP_CONFIG}"

  chmod 600 "${TMP_CONFIG}"
  log_success "临时配置已生成: ${TMP_CONFIG}"
}

validate_generated_config() {
  log_info "校验 sing-box 配置..."
  sing-box check -c "${TMP_CONFIG}"
  log_success "配置校验通过"
}

deploy_config() {
  log_info "写入正式配置..."
  install -m 600 "${TMP_CONFIG}" "${CONFIG_PATH}"
  log_success "配置已写入: ${CONFIG_PATH}"
}

setup_systemd_override() {
  local override_dir="/etc/systemd/system/sing-box.service.d"
  local override_path="${override_dir}/20-sing-box-deploy.conf"
  mkdir -p "${override_dir}"
  cat > "${override_path}" <<'EOF'
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
EOF
  chmod 644 "${override_path}"
  log_success "sing-box systemd 自动恢复与文件句柄限制已配置"
}

apply_network_tuning() {
  if (( SKIP_NETWORK_TUNING == 1 )); then
    log_warn "按参数要求跳过 Linux 网络参数优化"
    return
  fi
  if ! is_true "${ENABLE_NETWORK_TUNING}"; then
    log_warn "ENABLE_NETWORK_TUNING=${ENABLE_NETWORK_TUNING}，跳过 Linux 网络参数优化"
    return
  fi

  log_info "配置 Linux 网络参数（UDP 缓冲、TCP Fast Open、可用时启用 BBR/fq）..."

  local tuning_tmp
  local bbr_available=0
  tuning_tmp="$(mktemp /tmp/sing-box-sysctl.XXXXXX.conf)"

  if is_true "${ENABLE_BBR}"; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
      bbr_available=1
      modprobe sch_fq >/dev/null 2>&1 || true
    else
      log_warn "当前内核未提供 BBR，继续应用 UDP 缓冲和 TCP Fast Open 优化"
    fi
  fi

  {
    cat <<EOF
# Managed by sing-box-deploy. Re-run install.sh after changing .env.
net.core.rmem_max=${UDP_BUFFER_BYTES}
net.core.wmem_max=${UDP_BUFFER_BYTES}
EOF
    if is_true "${ENABLE_TCP_FAST_OPEN}"; then
      echo "net.ipv4.tcp_fastopen=3"
    fi
    if (( bbr_available == 1 )); then
      echo "net.core.default_qdisc=fq"
      echo "net.ipv4.tcp_congestion_control=bbr"
    fi
  } > "${tuning_tmp}"

  if [[ -f "${NETWORK_TUNING_FILE}" ]] && ! cmp -s "${tuning_tmp}" "${NETWORK_TUNING_FILE}"; then
    cp -a "${NETWORK_TUNING_FILE}" "${NETWORK_TUNING_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  install -m 644 "${tuning_tmp}" "${NETWORK_TUNING_FILE}"
  rm -f "${tuning_tmp}"

  if sysctl -p "${NETWORK_TUNING_FILE}" >/dev/null; then
    log_success "网络参数优化已生效: rmem/wmem=${UDP_BUFFER_BYTES}, TCP CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  else
    log_warn "网络参数文件已写入，但部分参数未能立即生效；重启后请复查 ${NETWORK_TUNING_FILE}"
  fi
}

setup_firewall() {
  if (( SKIP_FIREWALL == 1 )); then
    log_warn "按参数要求跳过防火墙配置"
    return
  fi

  if ! is_true "${ENABLE_UFW}"; then
    log_warn "ENABLE_UFW=${ENABLE_UFW}，跳过 UFW 配置"
    return
  fi

  log_info "增量配置 UFW（不会 reset 现有规则）..."

  command -v ufw >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ufw
  }

  ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null || true
  local index
  for ((index = 0; index < ISP_COUNT; index++)); do
    ufw allow "${ISP_TROJAN_PORTS[index]}/tcp" comment "sing-box Trojan ${ISP_IDS[index]}" >/dev/null || true
    ufw allow "${ISP_HYSTERIA_PORTS[index]}/udp" comment "sing-box Hysteria2 ${ISP_IDS[index]}" >/dev/null || true
  done

  if ufw status | grep -qi "Status: inactive"; then
    ufw --force enable >/dev/null
  else
    ufw reload >/dev/null || true
  fi

  log_success "UFW 已处理完成"
}

setup_egress_monitor() {
  local enabled="${SMTP_ALERT_ENABLED:-false}"
  if ! is_true "${enabled}"; then
    log_info "SMTP 告警未启用，跳过出口监控安装"
    return 0
  fi

  local required_vars=(
    SMTP_HOST
    SMTP_PORT
    SMTP_USER
    SMTP_PASS
    SMTP_FROM
    SMTP_TO
  )
  local missing=()
  local var
  for var in "${required_vars[@]}"; do
    [[ -n "${!var:-}" ]] || missing+=("${var}")
  done

  if (( ${#missing[@]} > 0 )); then
    log_warn "SMTP 告警未完整配置，跳过出口监控安装: ${missing[*]}"
    return 0
  fi

  local monitor_script="/usr/local/bin/sing-box-egress-monitor.sh"
  local monitor_state_dir="/var/lib/sing-box-egress-monitor"
  local service_path="/etc/systemd/system/sing-box-egress-monitor.service"
  local timer_path="/etc/systemd/system/sing-box-egress-monitor.timer"

  mkdir -p "${monitor_state_dir}"
  chmod 700 "${monitor_state_dir}"

  cat > "${monitor_script}" <<'MONITOR'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="__ENV_FILE__"
CONFIGURED_ISP_LIST_FILE="__ISP_LIST_FILE__"
STATE_DIR="/var/lib/sing-box-egress-monitor"
STATE_FILE="${STATE_DIR}/last-status"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

load_env_safe() {
  [[ -f "${ENV_FILE}" ]] || return 1
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    local line key value
    line="$(trim "${raw_line}")"
    [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(trim "${key}")"
    value="$(trim "${value}")"
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:-1}"
      value="${value//\\n/$'\n'}"
      value="${value//\\\\/\\}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:-1}"
    fi
    printf -v "${key}" '%s' "${value}"
    export "${key}"
  done < "${ENV_FILE}"
}

probe_http_once() {
  local url="$1"
  curl -fsS --max-time 12 "${url}" >/dev/null
}

probe_socks5_once() {
  local host="$1"
  local port="$2"
  local user="$3"
  local pass="$4"
  local url="$5"
  curl -fsS --max-time 15 --proxy "socks5://${user}:${pass}@${host}:${port}" "${url}" >/dev/null
}

retry_command() {
  local attempts="${EGRESS_RETRY_ATTEMPTS:-5}"
  local delay="${EGRESS_RETRY_DELAY:-15}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    "$@" && return 0
    (( i < attempts )) && sleep "${delay}"
  done
  return 1
}

build_subject() {
  if (( ${#problems[@]} == 1 )); then
    case "${problems[0]}" in
      "中继服务器公网出口访问异常") printf '%s' "中继异常-公网出口" ;;
      ISP-*) printf '%s' "中继异常-ISP出口" ;;
      "sing-box 服务未运行") printf '%s' "中继异常-服务状态" ;;
      *) printf '%s' "中继异常-出口状态" ;;
    esac
  else
    printf '%s' "中继异常-多项异常"
  fi
}

send_mail() {
  local subject="$1"
  local body="$2"
  local mail_file
  local subject_b64
  mail_file="$(mktemp)"
  subject_b64="$(printf '%s' "${subject}" | base64 -w 0)"
  cat > "${mail_file}" <<EOF
From: ${SMTP_FROM}
To: ${SMTP_TO}
Subject: =?UTF-8?B?${subject_b64}?=
Date: $(LC_ALL=C date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

${body}
EOF

  curl -fsS --url "smtps://${SMTP_HOST}:${SMTP_PORT}" \
    --ssl-reqd \
    --user "${SMTP_USER}:${SMTP_PASS}" \
    --mail-from "${SMTP_FROM}" \
    --mail-rcpt "${SMTP_TO}" \
    --upload-file "${mail_file}" >/dev/null

  rm -f "${mail_file}"
}

main() {
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  load_env_safe
  # .env 中允许使用相对路径；安装阶段已将其解析为绝对路径。
  ISP_LIST_FILE="${CONFIGURED_ISP_LIST_FILE}"

  local check_url="${EGRESS_CHECK_URL:-https://ipinfo.io/ip}"
  local problems=()
  local summary=()

  if ! systemctl is-active --quiet sing-box; then
    problems+=("sing-box 服务未运行")
  else
    summary+=("sing-box 服务运行正常")
  fi

  if retry_command probe_http_once "${check_url}"; then
    summary+=("中继服务器公网出口正常")
  else
    problems+=("中继服务器公网出口访问异常")
  fi

  local id host http_port socks_port user password expires extra
  local today
  today="$(date -u +%F)"
  while IFS=$'\t' read -r id host http_port socks_port user password expires extra || [[ -n "${id}${host}${http_port}${socks_port}${user}${password}${expires}${extra}" ]]; do
    expires="${expires%$'\r'}"
    [[ -z "${id}${host}${http_port}${socks_port}${user}${password}${expires}${extra}" ]] && continue
    [[ "${id:0:1}" == "#" || "${id}" == "编号" || "${id,,}" == "id" ]] && continue
    [[ "${expires}" < "${today}" ]] && continue
    if retry_command probe_socks5_once "${host}" "${socks_port}" "${user}" "${password}" "${check_url}"; then
      summary+=("ISP-${id} SOCKS5 出口正常")
    else
      problems+=("ISP-${id} SOCKS5 出口访问异常")
    fi
  done < "${ISP_LIST_FILE}"

  if (( ${#problems[@]} == 0 )); then
    rm -f "${STATE_FILE}"
    exit 0
  fi

  local status_body
  status_body="$(printf '%s\n' "${problems[@]}")"

  if [[ -f "${STATE_FILE}" ]] && [[ "$(cat "${STATE_FILE}")" == "${status_body}" ]]; then
    exit 0
  fi

  local body
  body=$(
    cat <<EOF
检测时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
主机: $(hostname)

异常项:
$(printf -- '- %s\n' "${problems[@]}")

当前正常项:
$(printf -- '- %s\n' "${summary[@]}")
EOF
  )

  send_mail "$(build_subject)" "${body}"
  printf '%s' "${status_body}" > "${STATE_FILE}"
}

main "$@"
MONITOR

  sed -i "s|__ENV_FILE__|${ENV_FILE}|g" "${monitor_script}"
  sed -i "s|__ISP_LIST_FILE__|${ISP_LIST_FILE}|g" "${monitor_script}"
  chmod 700 "${monitor_script}"

  cat > "${service_path}" <<EOF
[Unit]
Description=sing-box egress health monitor
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${monitor_script}
EOF

  cat > "${timer_path}" <<EOF
[Unit]
Description=Run sing-box egress health monitor every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=sing-box-egress-monitor.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now sing-box-egress-monitor.timer >/dev/null
  log_success "出口监控与 SMTP 邮件告警已启用"
}

restart_service() {
  if (( NO_START == 1 )); then
    log_warn "按参数要求跳过启动/重启服务"
    return
  fi

  log_info "启用并重启 sing-box..."
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null
  if systemctl restart sing-box; then
    log_success "sing-box 已成功启动/重启"
    return
  fi

  log_error "sing-box 启动失败，开始回滚"

  journalctl -u sing-box --no-pager -n 50 || true

  if [[ -n "${BACKUP_CONFIG}" && -f "${BACKUP_CONFIG}" ]]; then
    log_warn "回滚到旧配置: ${BACKUP_CONFIG}"
    install -m 600 "${BACKUP_CONFIG}" "${CONFIG_PATH}"

    if sing-box check -c "${CONFIG_PATH}" >/dev/null 2>&1; then
      systemctl restart sing-box || true
    fi
  fi

  log_error "部署失败，请检查日志：journalctl -u sing-box -f"
  exit 1
}

write_summary() {
  local summary_file="${SCRIPT_DIR}/deploy-summary.txt"
  {
    cat <<EOF
部署时间: $(date '+%Y-%m-%d %H:%M:%S')

[ISP 清单]
EOF
    local index
    for ((index = 0; index < ISP_COUNT; index++)); do
      printf '%s: SOCKS5 %s:%s, HTTP %s, 到期 %s\n' \
        "${ISP_IDS[index]}" "${ISP_HOSTS[index]}" "${ISP_SOCKS_PORTS[index]}" \
        "${ISP_HTTP_PORTS[index]}" "${ISP_EXPIRES[index]}"
      printf '  Trojan %s:%s / Hysteria2 %s:%s\n' \
        "${TROJAN_DOMAIN}" "${ISP_TROJAN_PORTS[index]}" \
        "${HYSTERIA_DOMAIN}" "${ISP_HYSTERIA_PORTS[index]}"
      printf '  v2ray: https://%s/v2?isp=%s\n' "${SUB_DOMAIN}" "${ISP_IDS[index]}"
      printf '  Clash: https://%s/c?isp=%s\n' "${SUB_DOMAIN}" "${ISP_IDS[index]}"
    done
    cat <<EOF

AI 域名: 强制使用当前订阅对应 ISP
视频/软件下载直出: ${DIRECT_BULK_ENABLED}
大流量应用: ${DIRECT_BULK_APPS:-无}
Hysteria2 拥塞控制: ${HYSTERIA_CC_MODE}
Linux 网络优化: ${ENABLE_NETWORK_TUNING}
UDP 收发缓冲上限: ${UDP_BUFFER_BYTES}
TCP Fast Open: ${ENABLE_TCP_FAST_OPEN}

[文件]
配置文件: ${CONFIG_PATH}
ISP 清单: ${ISP_LIST_FILE}
证书目录: ${CERT_DIR}
备份配置: ${BACKUP_CONFIG:-无}

[常用命令]
检查配置: sing-box check -c ${CONFIG_PATH}
查看状态: systemctl status sing-box
查看日志: journalctl -u sing-box -f
重启服务: systemctl restart sing-box
EOF
  } > "${summary_file}"
  chmod 600 "${summary_file}"
  log_success "部署摘要已写入: ${summary_file}"
}

show_final_info() {
  echo
  echo "=================================================="
  echo -e "${GREEN}部署完成${NC}"
  echo "=================================================="
  local index
  for ((index = 0; index < ISP_COUNT; index++)); do
    echo "${ISP_IDS[index]}: Trojan ${ISP_TROJAN_PORTS[index]}, Hysteria2 ${ISP_HYSTERIA_PORTS[index]}, 到期 ${ISP_EXPIRES[index]}"
  done
  echo "AI 域名策略: 当前订阅对应 ISP"
  echo "视频/下载直出: ${DIRECT_BULK_ENABLED}"
  echo "大流量应用: ${DIRECT_BULK_APPS:-无}"
  echo "Hysteria2 拥塞控制: ${HYSTERIA_CC_MODE}"
  echo "Linux 网络优化: ${ENABLE_NETWORK_TUNING}"
  echo "独立订阅数量: ${ISP_COUNT}"
  echo "配置文件   : ${CONFIG_PATH}"
  [[ -n "${BACKUP_CONFIG}" ]] && echo "配置备份   : ${BACKUP_CONFIG}"
  echo "日志命令   : journalctl -u sing-box -f"
  echo "=================================================="
  echo
  echo "提示：客户端密码以 .env 中填写的值为准，本脚本不会把密码明文写入摘要文件。"
}

# -----------------------------
# 验证订阅是否正常
# -----------------------------
verify_subscription() {
  log_info "验证订阅链接..."
  
  local domain="${SUB_DOMAIN}"
  local max_retry=6
  local retry=0
  local v2_ok=0
  local c_ok=0
  local script_ok=0
  local shadowrocket_ok=0
  local rules_ok=0
  local c_content=""
  local script_content=""
  local shadowrocket_content=""
  local verification_query="verify=$(date +%s)"
  
  # 等待几秒让部署生效
  sleep 3
  
  while [[ $retry -lt $max_retry ]]; do
    # 验证 v2rayN 订阅
    if [[ $v2_ok -eq 0 ]]; then
      local v2_content=$(curl -sL --max-time 10 "https://${domain}/v2?${verification_query}" 2>/dev/null | base64 -d 2>/dev/null)
      if grep -q "trojan://" <<< "$v2_content"; then
        local v2_node_count=$(grep -c "://" <<< "$v2_content")
        log_success "v2rayN 订阅正常: 发现 ${v2_node_count} 个节点"
        # 显示节点名称
        grep -oP '#\K[^ ]+' <<< "$v2_content" | while read name; do
          log_info "  └─ 节点: $name"
        done
        v2_ok=1
      else
        log_warn "v2rayN 订阅验证失败，重试..."
      fi
    fi
    
    # 验证 Clash 订阅
    if [[ $c_ok -eq 0 ]]; then
      c_content=$(curl -sL --max-time 10 "https://${domain}/c?${verification_query}" 2>/dev/null)
      local telegram_c_ok=1
      local client_direct_c_ok=1
      local tcp_stability_c_ok=1
      if is_true "${DIRECT_BULK_ENABLED}" && csv_list_contains "${DIRECT_BULK_APPS}" "telegram" \
        && ! grep -Fq 'RULE-SET,loyalsoldier-telegramcidr,📦 TX 大流量,no-resolve' <<< "$c_content"; then
        telegram_c_ok=0
      fi
      local client_direct_cidr
      while IFS= read -r client_direct_cidr; do
        client_direct_cidr="$(trim "${client_direct_cidr}")"
        [[ -z "${client_direct_cidr}" ]] && continue
        if ! grep -Fq "IP-CIDR,${client_direct_cidr},DIRECT,no-resolve" <<< "$c_content"; then
          client_direct_c_ok=0
          break
        fi
      done < <(printf '%s\n' "${CLIENT_DIRECT_IP_CIDRS}" | tr ',\t ' '\n')
      if [[ "$(grep -c '    type: fallback' <<< "${c_content}" || true)" -lt 5 ]] \
        || grep -Fq '    type: url-test' <<< "${c_content}" \
        || ! grep -Fq '  respect-rules: true' <<< "${c_content}" \
        || ! grep -Fq '  mtu: 1400' <<< "${c_content}" \
        || ! grep -Fq 'https://1.1.1.1/dns-query#🛡️ 自动容灾' <<< "${c_content}"; then
        tcp_stability_c_ok=0
      fi
      if is_true "${CLASH_FORCE_TCP_ENABLED}"; then
        local force_tcp_domain
        while IFS= read -r force_tcp_domain; do
          force_tcp_domain="$(trim "${force_tcp_domain}")"
          [[ -z "${force_tcp_domain}" ]] && continue
          if ! grep -Fq "AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,${force_tcp_domain})),REJECT" <<< "${c_content}"; then
            tcp_stability_c_ok=0
            break
          fi
        done < <(printf '%s\n' "${CLASH_FORCE_TCP_DOMAINS}" | tr ',\t ' '\n')
      elif grep -Fq 'AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,' <<< "${c_content}"; then
        tcp_stability_c_ok=0
      fi
      if grep -q "proxies:" <<< "$c_content" \
        && grep -Fq "${CLASH_RULESET_BASE_URL%/}/proxy.txt" <<< "$c_content" \
        && (( telegram_c_ok == 1 )) \
        && (( client_direct_c_ok == 1 )) \
        && (( tcp_stability_c_ok == 1 )); then
        local c_node_count=$(grep -c "name:" <<< "$c_content")
        log_success "Clash 订阅正常: 发现 ${c_node_count} 个节点"
        c_ok=1
      else
        log_warn "Clash 订阅验证失败，重试..."
      fi
    fi

    # 验证 Clash Verge 全局扩展脚本
    if [[ $script_ok -eq 0 ]]; then
      script_content=$(curl -sL --max-time 10 "https://${domain}/s?${verification_query}" 2>/dev/null)
      local telegram_script_ok=1
      local client_direct_script_ok=1
      local tcp_stability_script_ok=1
      local expected_client_direct_json
      local expected_force_tcp_json
      local expected_force_tcp_enabled=false
      expected_client_direct_json=$(jq -cn --arg cidrs "${CLIENT_DIRECT_IP_CIDRS}" '$cidrs | gsub("[\\n\\t ]+"; ",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique')
      expected_force_tcp_json=$(jq -cn --arg domains "${CLASH_FORCE_TCP_DOMAINS}" '$domains | gsub("[\\n\\t ]+"; ",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique')
      if is_true "${CLASH_FORCE_TCP_ENABLED}"; then
        expected_force_tcp_enabled=true
      fi
      if is_true "${DIRECT_BULK_ENABLED}" && csv_list_contains "${DIRECT_BULK_APPS}" "telegram" \
        && ! grep -Fq 'const DIRECT_BULK_APPS = ["telegram"]' <<< "$script_content"; then
        telegram_script_ok=0
      fi
      if ! grep -Fq "const CLIENT_DIRECT_IP_CIDRS = ${expected_client_direct_json};" <<< "$script_content"; then
        client_direct_script_ok=0
      fi
      if ! grep -Fq 'type: "fallback"' <<< "${script_content}" \
        || ! grep -Fq "const FORCE_TCP_DOMAINS = ${expected_force_tcp_json};" <<< "${script_content}" \
        || ! grep -Fq "const FORCE_TCP_ENABLED = ${expected_force_tcp_enabled};" <<< "${script_content}" \
        || ! grep -Fq '"respect-rules": true' <<< "${script_content}" \
        || ! grep -Fq 'mtu: 1400' <<< "${script_content}" \
        || ! grep -Fq 'FORCE_TCP_DOMAINS.map' <<< "${script_content}"; then
        tcp_stability_script_ok=0
      fi
      if grep -q "function main(config)" <<< "$script_content" \
        && grep -q '"dialer-proxy"' <<< "$script_content" \
        && grep -Fq "${CLASH_RULESET_BASE_URL%/}" <<< "$script_content" \
        && grep -Fq 'CLIENT_DIRECT_IP_CIDRS.map' <<< "$script_content" \
        && (( telegram_script_ok == 1 )) \
        && (( client_direct_script_ok == 1 )) \
        && (( tcp_stability_script_ok == 1 )); then
        log_success "Clash Verge 全局扩展脚本正常"
        script_ok=1
      else
        log_warn "Clash Verge 全局扩展脚本验证失败，重试..."
      fi
    fi

    # Shadowrocket 模块必须强制 Telegram 走 PROXY，并引用本站每日同步的专用规则。
    if [[ $shadowrocket_ok -eq 0 ]]; then
      shadowrocket_content=$(curl -sL --max-time 10 "https://${domain}/sr?${verification_query}" 2>/dev/null)
      if grep -Fq '#!name=Telegram via PROXY' <<< "${shadowrocket_content}" \
        && grep -Fq "RULE-SET,https://${domain}/rules/shadowrocket-telegram.list,PROXY" <<< "${shadowrocket_content}" \
        && grep -Fq 'IP-CIDR,91.108.0.0/16,PROXY,no-resolve' <<< "${shadowrocket_content}" \
        && ! grep -Eq '^(DOMAIN|DOMAIN-SUFFIX|IP-CIDR).*,DIRECT' <<< "${shadowrocket_content}"; then
        log_success "Shadowrocket Telegram 模块正常"
        shadowrocket_ok=1
      else
        log_warn "Shadowrocket Telegram 模块验证失败，重试..."
      fi
    fi

    # 元数据仅在全部规则文件校验成功后生成，可作为线上快照完整性标记。
    if [[ $rules_ok -eq 0 ]]; then
      local rules_metadata
      rules_metadata=$(curl -sL --max-time 10 "https://${domain}/rules/metadata.json?${verification_query}" 2>/dev/null)
      if jq -e '
        (.upstream_sha | strings | test("^[0-9a-f]{40}$")) and
        (.shadowrocket_telegram_sha | strings | test("^[0-9a-f]{40}$")) and
        (.files | length == 11) and
        (.files | index("shadowrocket-telegram.list") != null)
      ' <<< "$rules_metadata" >/dev/null 2>&1; then
        log_success "Clash / Shadowrocket 规则镜像正常"
        rules_ok=1
      else
        log_warn "Clash / Shadowrocket 规则镜像验证失败，重试..."
      fi
    fi
    
    # 基础入口通过后，逐个验证私有 ISP 订阅只包含对应节点。
    if [[ $v2_ok -eq 1 && $c_ok -eq 1 && $script_ok -eq 1 && $shadowrocket_ok -eq 1 && $rules_ok -eq 1 ]]; then
      local personal_ok=1
      local index id personal_v2 personal_c personal_c_headers
      local personal_c_profile personal_c_update_interval personal_c_filename personal_c_filename_expected
      for ((index = 0; index < ISP_COUNT; index++)); do
        id="${ISP_IDS[index]}"
        personal_v2=$(curl -sL --max-time 10 "https://${domain}/v2?isp=${id}&${verification_query}" 2>/dev/null | base64 -d 2>/dev/null || true)
        personal_c=$(curl -sL --max-time 10 "https://${domain}/c?isp=${id}&${verification_query}" 2>/dev/null || true)
        personal_c_headers=$(curl -sL -D - -o /dev/null --max-time 10 "https://${domain}/c?isp=${id}&${verification_query}" 2>/dev/null | tr -d '\r' || true)
        personal_c_profile=$(awk -F': *' 'tolower($1) == "profile-title" {print $2; exit}' <<< "${personal_c_headers}")
        personal_c_update_interval=$(awk -F': *' 'tolower($1) == "profile-update-interval" {print $2; exit}' <<< "${personal_c_headers}")
        personal_c_filename=$(awk -F': *' 'tolower($1) == "content-disposition" {print $2; exit}' <<< "${personal_c_headers}")
        personal_c_filename_expected="attachment; filename=${id}; filename*=UTF-8''${id}"
        if [[ "$(grep -c "#T-${id}-" <<< "${personal_v2}" || true)" -ne 2 ]] \
          || ! grep -Fq "name: \"T-${id}-TJ\"" <<< "${personal_c}" \
          || ! grep -Fq "name: \"T-${id}-HY2\"" <<< "${personal_c}" \
          || [[ "${personal_c_profile}" != "${id}" ]] \
          || [[ "${personal_c_update_interval}" != "24" ]] \
          || [[ "${personal_c_filename}" != "${personal_c_filename_expected}" ]]; then
          log_warn "ISP ${id} 独立订阅验证失败，重试..."
          personal_ok=0
          break
        fi
      done
      if (( personal_ok == 1 )); then
        log_success "${ISP_COUNT} 组独立 ISP 订阅验证全部通过！"
        return 0
      fi
    fi
    
    retry=$((retry + 1))
    if [[ $retry -lt $max_retry ]]; then
      sleep 4
    fi
  done
  
  # 验证失败
  if [[ $v2_ok -eq 0 ]]; then
    log_error "v2rayN 订阅验证失败: https://${domain}/v2"
  fi
  if [[ $c_ok -eq 0 ]]; then
    log_error "Clash 订阅验证失败: https://${domain}/c"
  fi
  if [[ $script_ok -eq 0 ]]; then
    log_error "Clash Verge 全局扩展脚本验证失败: https://${domain}/s"
  fi
  if [[ $shadowrocket_ok -eq 0 ]]; then
    log_error "Shadowrocket Telegram 模块验证失败: https://${domain}/sr"
  fi
  if [[ $rules_ok -eq 0 ]]; then
    log_error "Clash / Shadowrocket 规则镜像验证失败: https://${domain}/rules/metadata.json"
  fi
  log_info "请检查: 1) DNS 解析 2) Cloudflare Pages 部署状态 3) 自定义域名绑定"
  return 1
}

sync_clash_rules_snapshot() {
  local output_dir="${1:-${SCRIPT_DIR}/cloudflare-pages-sub/rules}"
  local sync_script="${SCRIPT_DIR}/sync-clash-rules.sh"
  [[ -x "${sync_script}" ]] || {
    log_error "规则同步脚本不存在或不可执行: ${sync_script}"
    return 1
  }

  log_info "同步 Loyalsoldier ${CLASH_RULESET_UPSTREAM_BRANCH} 规则快照..."
  CLASH_RULESET_LOCK_HELD_FD=8 \
    CLASH_RULESET_OUTPUT_DIR="${output_dir}" \
    "${sync_script}" --env "${ENV_FILE}"
}

acquire_pages_deploy_lock() {
  command -v flock >/dev/null 2>&1 || {
    log_error "Pages 发布需要 flock 以避免与定时任务并发"
    return 1
  }

  local default_lock_file="${TMPDIR:-/tmp}/sing-box-deploy-clash-rules.lock"
  (( EUID == 0 )) && default_lock_file="/run/lock/sing-box-deploy-clash-rules.lock"
  local lock_file="${CLASH_RULESET_LOCK_FILE:-${default_lock_file}}"
  exec 8>"${lock_file}"
  if ! flock -n 8; then
    exec 8>&-
    log_error "已有规则同步或 Pages 发布任务正在运行，请稍后重试"
    return 1
  fi
}

release_pages_deploy_lock() {
  if [[ -e /proc/self/fd/8 ]]; then
    flock -u 8 || true
    exec 8>&-
  fi
}

discard_pages_stage() {
  if [[ -n "${PAGES_STAGE_ROOT}" && -d "${PAGES_STAGE_ROOT}" ]]; then
    rm -rf -- "${PAGES_STAGE_ROOT}"
  fi
  PAGES_STAGE_ROOT=""
}

activate_staged_pages() {
  local staged_pages_dir="$1"
  local live_pages_dir="$2"
  local previous_pages_dir="${PAGES_STAGE_ROOT}/previous-pages"

  if ! mv "${live_pages_dir}" "${previous_pages_dir}"; then
    log_error "无法备份当前 Pages 本地资产"
    return 1
  fi
  if mv "${staged_pages_dir}" "${live_pages_dir}"; then
    return 0
  fi

  log_error "无法激活已验证的 Pages 本地资产，开始恢复原目录"
  if ! mv "${previous_pages_dir}" "${live_pages_dir}"; then
    log_error "原 Pages 目录恢复失败，已保留恢复材料: ${PAGES_STAGE_ROOT}"
    PAGES_STAGE_ROOT=""
  fi
  return 1
}

validate_generated_pages_assets() {
  local pages_dir="$1"
  local generated_js=(
    "${pages_dir}/functions/v2.js"
    "${pages_dir}/functions/sr.js"
    "${pages_dir}/functions/c.js"
    "${pages_dir}/global-extension.js"
  )
  local generated_file

  command -v node >/dev/null 2>&1 || {
    log_error "Pages 生成资产校验需要 node"
    return 1
  }
  for generated_file in "${generated_js[@]}"; do
    [[ -s "${generated_file}" ]] || {
      log_error "Pages 生成资产缺失: ${generated_file}"
      return 1
    }
    node --input-type=module --check < "${generated_file}" >/dev/null
  done
  if grep -ERq '[A-Z][A-Z0-9_]*_PLACEHOLDER' \
    "${pages_dir}/functions" "${pages_dir}/global-extension.js"; then
    log_error "Pages 生成资产仍包含未替换占位符"
    return 1
  fi
  log_success "Pages 生成资产语法与占位符校验通过"
}

setup_clash_rules_sync_timer() {
  if [[ -z "${CF_API_TOKEN:-}" || -z "${CF_ACCOUNT_ID:-}" ]]; then
    log_warn "Cloudflare Pages 凭据不完整，跳过规则同步定时器"
    return 0
  fi
  if ! command -v wrangler >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    log_warn "缺少 wrangler 或 systemctl，跳过规则同步定时器"
    return 0
  fi

  local service_template="${SCRIPT_DIR}/systemd/clash-rules-sync.service.in"
  local timer_template="${SCRIPT_DIR}/systemd/clash-rules-sync.timer"
  local service_path="/etc/systemd/system/clash-rules-sync.service"
  local timer_path="/etc/systemd/system/clash-rules-sync.timer"

  [[ -f "${service_template}" && -f "${timer_template}" ]] || {
    log_error "缺少 Clash 规则同步 systemd 模板"
    return 1
  }

  sed \
    -e "s|@SCRIPT_DIR@|${SCRIPT_DIR}|g" \
    -e "s|@ENV_FILE@|${ENV_FILE}|g" \
    "${service_template}" > "${service_path}"
  install -m 0644 "${timer_template}" "${timer_path}"
  systemctl daemon-reload
  systemctl enable --now clash-rules-sync.timer
  log_success "已启用每日 Clash 规则同步定时器（北京时间 07:15，随机延迟不超过 10 分钟）"
}

# -----------------------------
# 自动更新 Cloudflare Pages 订阅配置
# -----------------------------
update_cloudflare_pages() {
  # 检查是否配置了 CF_API_TOKEN
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    log_warn "未配置 CF_API_TOKEN，跳过 Cloudflare Pages 自动部署"
    log_info "如需自动部署，请在 .env 中添加: CF_API_TOKEN=你的Token"
    return 0
  fi

  # 检查 CF_ACCOUNT_ID
  if [[ -z "${CF_ACCOUNT_ID:-}" ]]; then
    log_warn "未配置 CF_ACCOUNT_ID，跳过 Cloudflare Pages 自动部署"
    return 0
  fi

  local live_pages_dir="${SCRIPT_DIR}/cloudflare-pages-sub"
  
  # 检查目录是否存在
  if [[ ! -d "$live_pages_dir" ]]; then
    if (( PAGES_ONLY == 1 )); then
      log_error "未找到 cloudflare-pages-sub 目录，无法执行 Pages-only 发布"
      return 1
    fi
    log_warn "未找到 cloudflare-pages-sub 目录，跳过自动部署"
    return 0
  fi

  acquire_pages_deploy_lock
  PAGES_STAGE_ROOT="$(mktemp -d "${SCRIPT_DIR}/.pages-stage.XXXXXX")"
  chmod 0700 "${PAGES_STAGE_ROOT}"
  local pages_dir="${PAGES_STAGE_ROOT}/cloudflare-pages-sub"
  cp -a "${live_pages_dir}" "${pages_dir}"
  local functions_dir="${pages_dir}/functions"
  log_info "开始更新 Cloudflare Pages 订阅配置..."

  # 客户端只读取完整镜像；同步失败时保留旧快照并停止本次 Pages 部署。
  sync_clash_rules_snapshot "${pages_dir}/rules"

  # 确保 functions 目录存在
  mkdir -p "$functions_dir"

  # 生成 v2.js (v2rayN 订阅) - URI 格式
  # v2rayN 需要 Base64 编码的 URI 列表，不是 JSON
  cat > "${functions_dir}/v2.js" <<'V2JS'
// v2rayN 订阅接口 - 返回 Base64 编码的 URI 列表
export async function onRequest(context) {
  const url = new URL(context.request.url);
  const isRaw = url.searchParams.get('raw') === '1';
  const requestedIsp = url.searchParams.get('isp');
  const today = new Date().toISOString().slice(0, 10);
  const allEntries = JSON.parse(atob('ISP_PUBLIC_LIST_BASE64_PLACEHOLDER'));
  const activeEntries = allEntries.filter((entry) => entry.expires >= today);
  const entries = requestedIsp
    ? activeEntries.filter((entry) => entry.id === requestedIsp)
    : activeEntries;

  if (entries.length === 0) {
    return new Response('ISP subscription not found or expired', { status: 410 });
  }

  const nodes = entries.flatMap((entry) => [
    `trojan://TROJAN_PASSWORD_PLACEHOLDER@TROJAN_DOMAIN_PLACEHOLDER:${entry.trojan_port}?security=tls&sni=TROJAN_DOMAIN_PLACEHOLDER&alpn=h2%2Chttp%2F1.1&fp=chrome#T-${entry.id}-TJ`,
    `hysteria2://HYSTERIA_PASSWORD_PLACEHOLDER@HYSTERIA_DOMAIN_PLACEHOLDER:${entry.hysteria_port}/?sni=HYSTERIA_DOMAIN_PLACEHOLDER&obfs=salamander&obfs-password=HYSTERIA_OBFS_PLACEHOLDER&insecure=0#T-${entry.id}-HY2`,
  ]);

  const uriList = nodes.join('\n');
  const expire = entries.length > 0
    ? Math.floor(new Date(`${entries.map((entry) => entry.expires).sort()[0]}T23:59:59Z`).getTime() / 1000)
    : 0;
  const profileName = requestedIsp || 'all-isps';
  const profileHeaders = {
    'Profile-Title': profileName,
    'Profile-Update-Interval': '24',
    'Content-Disposition': `attachment; filename=${profileName}; filename*=UTF-8''${encodeURIComponent(profileName)}`,
    'Subscription-Userinfo': `upload=0; download=0; total=0; expire=${expire}`
  };

  if (isRaw) {
    return new Response(uriList, {
      status: 200,
      headers: { 
        'Content-Type': 'text/plain; charset=utf-8', 
        'Cache-Control': 'no-cache', 
        'Access-Control-Allow-Origin': '*',
        ...profileHeaders
      }
    });
  }

  const encoder = new TextEncoder();
  const data = encoder.encode(uriList);
  const base64Config = btoa(String.fromCharCode(...data));
  
  return new Response(base64Config, {
    status: 200,
    headers: { 
      'Content-Type': 'text/plain; charset=utf-8', 
      'Cache-Control': 'no-cache', 
      'Access-Control-Allow-Origin': '*',
      ...profileHeaders
    }
  });
}
V2JS

  # URL 编码密码 (处理 + = 等特殊字符)
  local trojan_password_encoded=$(echo -n "${TROJAN_PASSWORD}" | jq -sRr @uri)
  local hy2_password_encoded=$(echo -n "${HYSTERIA_PASSWORD}" | jq -sRr @uri)
  local obfs_password_encoded=$(echo -n "${HYSTERIA_OBFS_PASSWORD}" | jq -sRr @uri)
  
  # 替换 v2.js 中的占位符
  sed -i "s|TROJAN_DOMAIN_PLACEHOLDER|${TROJAN_DOMAIN}|g" "${functions_dir}/v2.js"
  sed -i "s|HYSTERIA_DOMAIN_PLACEHOLDER|${HYSTERIA_DOMAIN}|g" "${functions_dir}/v2.js"
  sed -i "s|TROJAN_PASSWORD_PLACEHOLDER|${trojan_password_encoded}|g" "${functions_dir}/v2.js"
  sed -i "s|HYSTERIA_PASSWORD_PLACEHOLDER|${hy2_password_encoded}|g" "${functions_dir}/v2.js"
  sed -i "s|HYSTERIA_OBFS_PLACEHOLDER|${obfs_password_encoded}|g" "${functions_dir}/v2.js"
  local isp_public_list_base64
  isp_public_list_base64=$(printf '%s' "${ISP_PUBLIC_LIST_JSON}" | base64 | tr -d '\n')
  sed -i "s|ISP_PUBLIC_LIST_BASE64_PLACEHOLDER|${isp_public_list_base64}|g" "${functions_dir}/v2.js"

  # 生成 Shadowrocket Telegram 高优先级规则模块。
  # 节点仍从 /v2 导入；模块只负责避免 Telegram 被客户端原配置误判为 DIRECT。
  cat > "${functions_dir}/sr.js" <<'SRJS'
export async function onRequest(context) {
  const url = new URL(context.request.url);
  const ruleSetUrl = `${url.origin}/rules/shadowrocket-telegram.list`;
  const moduleContent = `#!name=Telegram via PROXY
#!homepage=https://github.com/blackmatrix7/ios_rule_script
#!desc=Force Telegram traffic through the currently selected Shadowrocket proxy.
[Rule]
DOMAIN-SUFFIX,t.me,PROXY
DOMAIN-SUFFIX,telegram.me,PROXY
DOMAIN-SUFFIX,telegram.org,PROXY
DOMAIN-SUFFIX,telegram.dog,PROXY
DOMAIN-SUFFIX,telegram-cdn.org,PROXY
DOMAIN-SUFFIX,cdn-telegram.org,PROXY
IP-CIDR,5.28.192.0/18,PROXY,no-resolve
IP-CIDR,91.108.0.0/16,PROXY,no-resolve
IP-CIDR,149.154.160.0/20,PROXY,no-resolve
RULE-SET,${ruleSetUrl},PROXY
`;

  return new Response(moduleContent, {
    status: 200,
    headers: {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-cache',
      'Access-Control-Allow-Origin': '*',
      'Profile-Title': 'Shadowrocket-Telegram',
      'Profile-Update-Interval': '24',
      'Content-Disposition': "attachment; filename=shadowrocket-telegram.module"
    }
  });
}
SRJS

  # 生成 c.js (Clash 订阅) - 完整双层结构配置
  cat > "${functions_dir}/c.js" <<'CJS'
// Clash 订阅接口 - 返回完整双层结构配置
export async function onRequest(context) {
  const url = new URL(context.request.url);
  const requestedIsp = url.searchParams.get('isp');
  const today = new Date().toISOString().slice(0, 10);
  const allEntries = JSON.parse(atob('ISP_PUBLIC_LIST_BASE64_PLACEHOLDER'));
  const activeEntries = allEntries.filter((entry) => entry.expires >= today);
  const entries = requestedIsp
    ? activeEntries.filter((entry) => entry.id === requestedIsp)
    : activeEntries;
  if (entries.length === 0) {
    return new Response('ISP subscription not found or expired', { status: 410 });
  }

  // Prefer HY2 for interactive traffic on lossy/high-RTT access links, while
  // keeping Trojan first for sustained downloads where TCP delivers more throughput.
  const proxyNames = entries.flatMap((entry) => [`T-${entry.id}-HY2`, `T-${entry.id}-TJ`]);
  const txProxyNames = entries.flatMap((entry) => [`T-${entry.id}-TJ`, `T-${entry.id}-HY2`]);
  const ispOnlyProxyNames = proxyNames;
  const decodeDomainList = (encoded) => atob(encoded)
    .split(/[\s,]+/)
    .map((domain) => domain.trim())
    .filter(Boolean);
  const aiIspDomains = decodeDomainList("AI_ISP_DOMAINS_BASE64_PLACEHOLDER");
  const txBulkDomains = DIRECT_BULK_ENABLED_PLACEHOLDER
    ? decodeDomainList("DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER")
    : [];
  const clientDirectIpCidrs = decodeDomainList("CLIENT_DIRECT_IP_CIDRS_BASE64_PLACEHOLDER");
  const forceTcpDomains = decodeDomainList("CLASH_FORCE_TCP_DOMAINS_BASE64_PLACEHOLDER");
  const forceTcpEnabled = CLASH_FORCE_TCP_ENABLED_PLACEHOLDER;
  const directBulkApps = DIRECT_BULK_APPS_JSON_PLACEHOLDER;
  const hysteriaUseBbr = HYSTERIA_USE_BBR_PLACEHOLDER;
  const telegramDirectEnabled = DIRECT_BULK_ENABLED_PLACEHOLDER
    && directBulkApps.includes("telegram");
  const hy2BandwidthLines = hysteriaUseBbr
    ? ''
    : `
    up: "HYSTERIA_UP_PLACEHOLDER Mbps"
    down: "HYSTERIA_DOWN_PLACEHOLDER Mbps"`;

  const proxies = entries.flatMap((entry) => [
    `  - name: "T-${entry.id}-TJ"
    type: trojan
    server: TROJAN_DOMAIN_PLACEHOLDER
    port: ${entry.trojan_port}
    password: "TROJAN_PASSWORD_PLACEHOLDER"
    udp: true
    sni: TROJAN_DOMAIN_PLACEHOLDER
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
    client-fingerprint: chrome`,
    `  - name: "T-${entry.id}-HY2"
    type: hysteria2
    server: HYSTERIA_DOMAIN_PLACEHOLDER
    port: ${entry.hysteria_port}
    password: "HYSTERIA_PASSWORD_PLACEHOLDER"
    obfs: salamander
    obfs-password: "HYSTERIA_OBFS_PLACEHOLDER"
    alpn:
      - h3
    sni: HYSTERIA_DOMAIN_PLACEHOLDER
    skip-cert-verify: false${hy2BandwidthLines}`,
  ]);

  const proxyGroupLines = proxyNames.map((name) => `      - "${name}"`).join('\n');
  const txProxyGroupLines = txProxyNames.map((name) => `      - "${name}"`).join('\n');
  const ispOnlyProxyGroupLines = ispOnlyProxyNames.map((name) => `      - "${name}"`).join('\n');
  const selectProxyLines = [`      - "🛡️ 自动容灾"`, `      - "♻️ 自动选择"`, ...proxyNames.map((name) => `      - "${name}"`)].join('\n');
  const ispOnlySelectProxyLines = [`      - "🛡️ ISP 出口自动"`, ...ispOnlyProxyNames.map((name) => `      - "${name}"`)].join('\n');
  const fallbackProxyLines = ispOnlySelectProxyLines;
  const telegramProxyLines = [
    ...(telegramDirectEnabled ? [`      - "📦 TX 大流量"`] : []),
    `      - "🚀 节点选择"`,
    `      - "♻️ 自动选择"`,
    `      - "🛡️ 自动容灾"`,
  ].join('\n');
  const telegramRuleTarget = telegramDirectEnabled ? "📦 TX 大流量" : "📲 电报信息";
  const aiRuleLines = aiIspDomains
    .map((domain) => `    - 'DOMAIN-SUFFIX,${domain},🤖 AI 服务'`)
    .join('\n');
  const txBulkRuleLines = txBulkDomains
    .map((domain) => `    - 'DOMAIN-SUFFIX,${domain},📦 TX 大流量'`)
    .join('\n');
  const clientDirectIpRuleLines = clientDirectIpCidrs
    .map((cidr) => `    - 'IP-CIDR,${cidr},DIRECT,no-resolve'`)
    .join('\n');
  const forceTcpRuleLines = forceTcpEnabled
    ? forceTcpDomains
      .map((domain) => `    - 'AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,${domain})),REJECT'`)
      .join('\n')
    : '';

  const config = `mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
external-controller: 127.0.0.1:9090
secret: "SECRET_PLACEHOLDER"
profile:
  store-selected: true
  store-fake-ip: true

tun:
  mtu: 1400

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  skip-domain:
    - "Mijia Cloud"
    - "+.push.apple.com"
    - "+.icloud.com"

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  cache-algorithm: arc
  use-hosts: true
  use-system-hosts: true
  respect-rules: true
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "+.lan"
    - "+.local"
    - "+.market.xiaomi.com"
    - "+.icloud.com"
    - "+.icloud-content.com"
    - "+.push.apple.com"
    - "api.push.apple.com"
    - "courier.push.apple.com"
    - "TROJAN_DOMAIN_PLACEHOLDER"
    - "HYSTERIA_DOMAIN_PLACEHOLDER"
  default-nameserver:
    - 223.5.5.5
    - 223.6.6.6
  proxy-server-nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  nameserver-policy:
    "geosite:gfw":
      - "https://1.1.1.1/dns-query#🛡️ 自动容灾"
      - "https://8.8.8.8/dns-query#🛡️ 自动容灾"
  fallback:
    - "https://1.1.1.1/dns-query#🛡️ 自动容灾"
    - "https://8.8.8.8/dns-query#🛡️ 自动容灾"
  fallback-filter:
    geoip: true
    geoip-code: CN

rule-providers:
  loyalsoldier-applications:
    type: http
    behavior: classical
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/applications.txt"
    path: ./ruleset/loyalsoldier/applications.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-private:
    type: http
    behavior: domain
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/private.txt"
    path: ./ruleset/loyalsoldier/private.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-reject:
    type: http
    behavior: domain
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/reject.txt"
    path: ./ruleset/loyalsoldier/reject.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-icloud:
    type: http
    behavior: domain
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/icloud.txt"
    path: ./ruleset/loyalsoldier/icloud.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-apple:
    type: http
    behavior: domain
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/apple.txt"
    path: ./ruleset/loyalsoldier/apple.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-proxy:
    type: http
    behavior: domain
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/proxy.txt"
    path: ./ruleset/loyalsoldier/proxy.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-direct:
    type: http
    behavior: domain
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/direct.txt"
    path: ./ruleset/loyalsoldier/direct.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-lancidr:
    type: http
    behavior: ipcidr
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/lancidr.txt"
    path: ./ruleset/loyalsoldier/lancidr.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-cncidr:
    type: http
    behavior: ipcidr
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/cncidr.txt"
    path: ./ruleset/loyalsoldier/cncidr.yaml
    interval: 86400
    proxy: "🚀 节点选择"
  loyalsoldier-telegramcidr:
    type: http
    behavior: ipcidr
    format: yaml
    url: "CLASH_RULESET_BASE_URL_PLACEHOLDER/telegramcidr.txt"
    path: ./ruleset/loyalsoldier/telegramcidr.yaml
    interval: 86400
    proxy: "🚀 节点选择"

proxies:
${proxies.join('\n\n')}

proxy-groups:
  - name: "🛡️ 自动容灾"
    type: fallback
    proxies:
${proxyGroupLines}
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    timeout: 3000

  - name: "♻️ 自动选择"
    type: fallback
    proxies:
${proxyGroupLines}
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    timeout: 3000

  - name: "📦 TX 大流量"
    type: fallback
    proxies:
${txProxyGroupLines}
    url: "https://www.youtube.com/generate_204"
    interval: 300
    timeout: 3000

  - name: "🚀 节点选择"
    type: select
    proxies:
${selectProxyLines}

  - name: "🛡️ ISP 出口自动"
    type: fallback
    proxies:
${ispOnlyProxyGroupLines}
    url: "https://cp.cloudflare.com/generate_204"
    interval: 300
    timeout: 3000

  - name: "🤖 AI 服务"
    type: select
    proxies:
      - "🤖 AI 自动"
      - "🛡️ ISP 出口自动"
${ispOnlyProxyGroupLines}

  - name: "🤖 AI 自动"
    type: fallback
    proxies:
${ispOnlyProxyGroupLines}
    url: "https://chat.openai.com/cdn-cgi/trace"
    interval: 300
    timeout: 5000

  - name: "📲 电报信息"
    type: select
    proxies:
${telegramProxyLines}

  - name: "🔎 IP 信息"
    type: select
    proxies:
${ispOnlySelectProxyLines}

  - name: "🧬 AdsPower"
    type: select
    proxies:
      - DIRECT
      - "🚀 节点选择"
      - "♻️ 自动选择"
      - "🛡️ 自动容灾"

  - name: "🍎 苹果服务"
    type: select
    proxies:
      - DIRECT
      - "🚀 节点选择"
      - "♻️ 自动选择"
      - "🛡️ 自动容灾"

  - name: "🎯 全球直连"
    type: select
    proxies:
      - DIRECT

  - name: "🐟 漏网之鱼"
    type: select
    proxies:
${fallbackProxyLines}

rules:
${clientDirectIpRuleLines}
${forceTcpRuleLines}
${aiRuleLines}
${txBulkRuleLines}

    # Apple NTP 优先直连：避免 UDP/123 时间同步请求被代理策略截走导致解析或连接超时
    - 'DOMAIN,time.apple.com,DIRECT'

    # 本地/公司网络优先直连：避免浏览器系统代理把管理地址送入代理节点
    - 'IP-CIDR,192.168.1.0/24,DIRECT,no-resolve'
    - 'IP-CIDR,10.78.1.0/24,DIRECT,no-resolve'

    # AdsPower 客户端服务优先走独立策略组：避免登录、同步、日志接口落入漏网之鱼导致指纹浏览器不可用
    - 'DOMAIN-SUFFIX,adspower.net,🧬 AdsPower'
    - 'DOMAIN-SUFFIX,adspower.com,🧬 AdsPower'

    # Clash Verge Rev IP 信息查询优先走独立策略组：避免检测服务落入不稳定节点导致首页一直显示骨架屏
    - 'DOMAIN,api.ip.sb,🔎 IP 信息'
    - 'DOMAIN,api.ipapi.is,🔎 IP 信息'
    - 'DOMAIN,ip.api.skk.moe,🔎 IP 信息'
    - 'DOMAIN,get.geojs.io,🔎 IP 信息'
    - 'DOMAIN-SUFFIX,ip.sb,🔎 IP 信息'
    - 'DOMAIN-SUFFIX,ipapi.co,🔎 IP 信息'
    - 'DOMAIN-SUFFIX,ipapi.is,🔎 IP 信息'
    - 'DOMAIN-SUFFIX,ipwho.is,🔎 IP 信息'
    - 'DOMAIN-SUFFIX,geojs.io,🔎 IP 信息'

    # Loyalsoldier 规则每天更新；自定义 AI / TX 规则始终位于这些通用规则之前
    - 'RULE-SET,loyalsoldier-applications,DIRECT'
    - 'RULE-SET,loyalsoldier-private,DIRECT'
    - 'RULE-SET,loyalsoldier-reject,REJECT'
    - 'RULE-SET,loyalsoldier-icloud,🍎 苹果服务'
    - 'RULE-SET,loyalsoldier-apple,🍎 苹果服务'
    - 'RULE-SET,loyalsoldier-telegramcidr,${telegramRuleTarget},no-resolve'
    - 'RULE-SET,loyalsoldier-proxy,🚀 节点选择'
    - 'RULE-SET,loyalsoldier-direct,🎯 全球直连'
    - 'RULE-SET,loyalsoldier-lancidr,DIRECT,no-resolve'
    - 'RULE-SET,loyalsoldier-cncidr,🎯 全球直连,no-resolve'
    - 'GEOIP,LAN,DIRECT'
    - 'GEOIP,CN,🎯 全球直连'
    - 'MATCH,🐟 漏网之鱼'

`;
  const expire = entries.length > 0
    ? Math.floor(new Date(`${entries.map((entry) => entry.expires).sort()[0]}T23:59:59Z`).getTime() / 1000)
    : 0;
  const profileName = requestedIsp || 'all-isps';
  return new Response(config, {
    status: 200,
    headers: { 
      'Content-Type': 'text/yaml; charset=utf-8', 
      'Cache-Control': 'no-cache', 
      'Access-Control-Allow-Origin': '*',
      'Profile-Title': profileName,
      'Profile-Update-Interval': '24',
      'Content-Disposition': `attachment; filename=${profileName}; filename*=UTF-8''${encodeURIComponent(profileName)}`,
      'Subscription-Userinfo': `upload=0; download=0; total=0; expire=${expire}`
    }
  });
}
CJS

  # 生成 Clash Verge 全局扩展脚本：任意机场仅作为 T 节点的前置中转。
  cat > "${pages_dir}/global-extension.js" <<'GLOBALJS'
const FINAL_GROUP_NAME = "🛡️ ISP 最终出口";
const TX_GROUP_NAME = "📦 TX 大流量";
const TRANSIT_GROUP_NAME = "🛫 机场中转";
const CUSTOM_GROUP_NAMES = new Set([
  FINAL_GROUP_NAME,
  TX_GROUP_NAME,
  TRANSIT_GROUP_NAME,
]);

const AI_ISP_DOMAINS = AI_ISP_DOMAINS_JSON_PLACEHOLDER;
const TX_BULK_DOMAINS = DIRECT_BULK_DOMAINS_JSON_PLACEHOLDER;
const DIRECT_BULK_APPS = DIRECT_BULK_APPS_JSON_PLACEHOLDER;
const CLIENT_DIRECT_IP_CIDRS = CLIENT_DIRECT_IP_CIDRS_JSON_PLACEHOLDER;
const FORCE_TCP_DOMAINS = CLASH_FORCE_TCP_DOMAINS_JSON_PLACEHOLDER;
const FORCE_TCP_ENABLED = CLASH_FORCE_TCP_ENABLED_PLACEHOLDER;
const HYSTERIA_USE_BBR = HYSTERIA_USE_BBR_PLACEHOLDER;
const TELEGRAM_DIRECT_ENABLED = DIRECT_BULK_APPS.includes("telegram");
const IP_CHECK_DOMAINS = [
  "ip.sb",
  "ipapi.co",
  "ipapi.is",
  "ipwho.is",
  "geojs.io",
  "ipify.org",
  "ipinfo.io",
  "ifconfig.me",
  "icanhazip.com",
];
const RULESET_BASE_URL = "CLASH_RULESET_BASE_URL_PLACEHOLDER";
const finalOverlayDomains = new Set([...AI_ISP_DOMAINS, ...IP_CHECK_DOMAINS]);
const txOverlayDomains = new Set(TX_BULK_DOMAINS);

const today = new Date().toISOString().slice(0, 10);
const ispEntries = JSON.parse(atob("ISP_PUBLIC_LIST_BASE64_PLACEHOLDER"))
  .filter((entry) => entry.expires >= today);
const injectedProxies = ispEntries.flatMap((entry) => [
  {
    name: `T-${entry.id}-TJ`,
    type: "trojan",
    server: "TROJAN_DOMAIN_PLACEHOLDER",
    port: entry.trojan_port,
    password: "TROJAN_PASSWORD_PLACEHOLDER",
    udp: true,
    sni: "TROJAN_DOMAIN_PLACEHOLDER",
    alpn: ["h2", "http/1.1"],
    "skip-cert-verify": false,
    "client-fingerprint": "chrome",
  },
  {
    name: `T-${entry.id}-HY2`,
    type: "hysteria2",
    server: "HYSTERIA_DOMAIN_PLACEHOLDER",
    port: entry.hysteria_port,
    password: "HYSTERIA_PASSWORD_PLACEHOLDER",
    obfs: "salamander",
    "obfs-password": "HYSTERIA_OBFS_PLACEHOLDER",
    alpn: ["h3"],
    sni: "HYSTERIA_DOMAIN_PLACEHOLDER",
    "skip-cert-verify": false,
    ...(HYSTERIA_USE_BBR
      ? {}
      : {
          up: "HYSTERIA_UP_PLACEHOLDER Mbps",
          down: "HYSTERIA_DOWN_PLACEHOLDER Mbps",
        }),
  },
]);

const txNodeNames = injectedProxies
  .map((proxy) => proxy.name)
  .filter((name) => name.startsWith("T-"));
const finalNodeNames = injectedProxies.map((proxy) => proxy.name);
const injectedNodeNames = new Set(finalNodeNames);

function ruleProvider(name, behavior) {
  return {
    type: "http",
    behavior,
    format: "yaml",
    url: `${RULESET_BASE_URL}/${name}.txt`,
    path: `./ruleset/loyalsoldier/${name}.yaml`,
    interval: 86400,
    proxy: FINAL_GROUP_NAME,
  };
}

const loyalsoldierProviders = {
  "loyalsoldier-applications": ruleProvider("applications", "classical"),
  "loyalsoldier-private": ruleProvider("private", "domain"),
  "loyalsoldier-reject": ruleProvider("reject", "domain"),
  "loyalsoldier-icloud": ruleProvider("icloud", "domain"),
  "loyalsoldier-apple": ruleProvider("apple", "domain"),
  "loyalsoldier-proxy": ruleProvider("proxy", "domain"),
  "loyalsoldier-direct": ruleProvider("direct", "domain"),
  "loyalsoldier-lancidr": ruleProvider("lancidr", "ipcidr"),
  "loyalsoldier-cncidr": ruleProvider("cncidr", "ipcidr"),
  "loyalsoldier-telegramcidr": ruleProvider("telegramcidr", "ipcidr"),
};

function rewriteAirportRules(rules, replaceableTargets) {
  if (!Array.isArray(rules)) return [];

  return rules.flatMap((rule) => {
    if (typeof rule !== "string") return [rule];
    if (rule.startsWith("RULE-SET,loyalsoldier-")) return [];
    if (rule === "GEOIP,LAN,DIRECT" || rule === "GEOIP,CN,DIRECT") return [];

    const parts = rule.split(",");
    const type = parts[0].trim().toUpperCase();
    if (type === "MATCH" || type === "FINAL") return [];
    if (parts.length < 2) return [rule];

    if (type === "DOMAIN-SUFFIX" && parts.length >= 3) {
      const domain = parts[1].trim();
      const target = parts[parts.length - 1].trim();
      if (target === FINAL_GROUP_NAME && finalOverlayDomains.has(domain)) return [];
      if (target === TX_GROUP_NAME && txOverlayDomains.has(domain)) return [];
    }

    const lastPart = parts[parts.length - 1].trim();
    const hasNoResolve = lastPart === "no-resolve";
    const targetIndex = hasNoResolve ? parts.length - 2 : parts.length - 1;
    const target = parts[targetIndex].trim();
    if (replaceableTargets.has(target)) {
      parts[targetIndex] = FINAL_GROUP_NAME;
    }
    return [parts.join(",")];
  });
}

function main(config) {
  config = config || {};
  const sourceProxies = Array.isArray(config.proxies) ? config.proxies : [];
  const sourceGroups = Array.isArray(config["proxy-groups"]) ? config["proxy-groups"] : [];
  const sourceRuleProviders = config["rule-providers"] || {};
  const sourceProxyProviders = config["proxy-providers"] || {};
  const sourceDns = config.dns && typeof config.dns === "object" ? config.dns : {};
  const sourceDnsPolicy = sourceDns["nameserver-policy"]
    && typeof sourceDns["nameserver-policy"] === "object"
    ? sourceDns["nameserver-policy"]
    : {};
  const sourceTun = config.tun && typeof config.tun === "object" ? config.tun : {};

  const airportProxies = sourceProxies.filter(
    (proxy) => proxy && proxy.name && !injectedNodeNames.has(proxy.name),
  );
  const airportProxyNames = [...new Set(airportProxies.map((proxy) => proxy.name))];
  const originalGroups = sourceGroups.filter(
    (group) => group && group.name && !CUSTOM_GROUP_NAMES.has(group.name),
  );
  const originalGroupNames = originalGroups.map((group) => group.name);
  const replaceableTargets = new Set([...airportProxyNames, ...originalGroupNames]);
  const upstreamProviderNames = new Set(Object.keys(loyalsoldierProviders));
  const airportProviderNames = Object.keys(sourceProxyProviders).filter(
    (name) => !upstreamProviderNames.has(name),
  );

  const transitGroup = {
    name: TRANSIT_GROUP_NAME,
    type: "select",
  };
  if (airportProxyNames.length > 0) transitGroup.proxies = airportProxyNames;
  if (airportProviderNames.length > 0) transitGroup.use = airportProviderNames;
  if (airportProxyNames.length === 0 && airportProviderNames.length === 0) {
    transitGroup.proxies = ["DIRECT"];
  }

  config.proxies = [
    ...airportProxies,
    ...injectedProxies.map((proxy) => ({
      ...proxy,
      "dialer-proxy": TRANSIT_GROUP_NAME,
    })),
  ];
  config["proxy-groups"] = [
    {
      name: FINAL_GROUP_NAME,
      type: "fallback",
      proxies: finalNodeNames,
      url: "https://cp.cloudflare.com/generate_204",
      interval: 300,
      timeout: 5000,
    },
    {
      name: TX_GROUP_NAME,
      type: "fallback",
      proxies: txNodeNames,
      url: "https://www.youtube.com/generate_204",
      interval: 300,
      timeout: 5000,
    },
    transitGroup,
    ...originalGroups,
  ];
  config["rule-providers"] = {
    ...sourceRuleProviders,
    ...loyalsoldierProviders,
  };
  config.dns = {
    ...sourceDns,
    "respect-rules": true,
    "proxy-server-nameserver": Array.isArray(sourceDns["proxy-server-nameserver"])
      && sourceDns["proxy-server-nameserver"].length > 0
      ? sourceDns["proxy-server-nameserver"]
      : ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"],
    "nameserver-policy": {
      ...sourceDnsPolicy,
      "geosite:gfw": [
        `https://1.1.1.1/dns-query#${FINAL_GROUP_NAME}`,
        `https://8.8.8.8/dns-query#${FINAL_GROUP_NAME}`,
      ],
    },
    fallback: [
      `https://1.1.1.1/dns-query#${FINAL_GROUP_NAME}`,
      `https://8.8.8.8/dns-query#${FINAL_GROUP_NAME}`,
    ],
  };
  config.tun = {
    ...sourceTun,
    mtu: 1400,
  };

  const airportRules = rewriteAirportRules(config.rules, replaceableTargets);
  config.rules = [
    ...CLIENT_DIRECT_IP_CIDRS.map((cidr) => `IP-CIDR,${cidr},DIRECT,no-resolve`),
    ...(FORCE_TCP_ENABLED
      ? FORCE_TCP_DOMAINS.map(
        (domain) => `AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,${domain})),REJECT`,
      )
      : []),
    ...AI_ISP_DOMAINS.map((domain) => `DOMAIN-SUFFIX,${domain},${FINAL_GROUP_NAME}`),
    ...IP_CHECK_DOMAINS.map((domain) => `DOMAIN-SUFFIX,${domain},${FINAL_GROUP_NAME}`),
    ...TX_BULK_DOMAINS.map((domain) => `DOMAIN-SUFFIX,${domain},${TX_GROUP_NAME}`),
    "RULE-SET,loyalsoldier-applications,DIRECT",
    "RULE-SET,loyalsoldier-private,DIRECT",
    "RULE-SET,loyalsoldier-reject,REJECT",
    "RULE-SET,loyalsoldier-icloud,DIRECT",
    "RULE-SET,loyalsoldier-apple,DIRECT",
    `RULE-SET,loyalsoldier-telegramcidr,${TELEGRAM_DIRECT_ENABLED ? TX_GROUP_NAME : FINAL_GROUP_NAME},no-resolve`,
    `RULE-SET,loyalsoldier-proxy,${FINAL_GROUP_NAME}`,
    "RULE-SET,loyalsoldier-direct,DIRECT",
    ...airportRules,
    "RULE-SET,loyalsoldier-lancidr,DIRECT,no-resolve",
    "RULE-SET,loyalsoldier-cncidr,DIRECT,no-resolve",
    "GEOIP,LAN,DIRECT",
    "GEOIP,CN,DIRECT",
    `MATCH,${FINAL_GROUP_NAME}`,
  ];

  return config;
}
GLOBALJS

  # 替换 c.js 中的占位符
  # 生成或获取 secret
  local secret="${SECRET:-}"
  if [[ -z "$secret" ]]; then
    secret=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
  fi
  # 生成或获取隐藏订阅路径
  local hidden_path="${HIDDEN_SUB_PATH:-}"
  if [[ -z "$hidden_path" ]]; then
    hidden_path=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
  fi
  # 构建隐藏订阅 URL
  local hidden_sub_url="https://${SUB_DOMAIN}/${hidden_path}/nodes"
  # 小写的订阅别名（用于文件名）
  local sub_remarks_lower=$(echo "${SUB_REMARKS:-US-ISP}" | tr '[:upper:]' '[:lower:]')
  local ai_isp_domains_base64
  local direct_bulk_domains_base64
  local client_direct_ip_cidrs_base64
  local force_tcp_domains_base64
  local ai_isp_domains_json
  local direct_bulk_domains_json='[]'
  local direct_bulk_apps_json='[]'
  local client_direct_ip_cidrs_json
  local force_tcp_domains_json
  local direct_bulk_enabled_js=false
  local force_tcp_enabled_js=false
  local hy2_use_bbr_js=false
  ai_isp_domains_base64=$(printf '%s' "${AI_ISP_DOMAINS}" | base64 | tr -d '\n')
  direct_bulk_domains_base64=$(printf '%s' "${DIRECT_BULK_DOMAINS}" | base64 | tr -d '\n')
  client_direct_ip_cidrs_base64=$(printf '%s' "${CLIENT_DIRECT_IP_CIDRS}" | base64 | tr -d '\n')
  force_tcp_domains_base64=$(printf '%s' "${CLASH_FORCE_TCP_DOMAINS}" | base64 | tr -d '\n')
  ai_isp_domains_json=$(jq -cn --arg domains "${AI_ISP_DOMAINS}" '$domains | gsub("[\\n\\t ]+"; ",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique')
  client_direct_ip_cidrs_json=$(jq -cn --arg cidrs "${CLIENT_DIRECT_IP_CIDRS}" '$cidrs | gsub("[\\n\\t ]+"; ",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique')
  force_tcp_domains_json=$(jq -cn --arg domains "${CLASH_FORCE_TCP_DOMAINS}" '$domains | gsub("[\\n\\t ]+"; ",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique')
  if is_true "${DIRECT_BULK_ENABLED}"; then
    direct_bulk_enabled_js=true
    direct_bulk_domains_json=$(jq -cn --arg domains "${DIRECT_BULK_DOMAINS}" '$domains | gsub("[\\n\\t ]+"; ",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique')
    direct_bulk_apps_json=$(jq -cn --arg apps "${DIRECT_BULK_APPS}" '$apps | ascii_downcase | gsub("[\\n\\t ]+"; ",") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique')
  fi
  if [[ "${HYSTERIA_CC_MODE,,}" == "bbr" ]]; then
    hy2_use_bbr_js=true
  fi
  if is_true "${CLASH_FORCE_TCP_ENABLED}"; then
    force_tcp_enabled_js=true
  fi
  
  sed -i "s|SECRET_PLACEHOLDER|${secret}|g" "${functions_dir}/c.js"
  sed -i "s|HIDDEN_SUB_URL_PLACEHOLDER|${hidden_sub_url}|g" "${functions_dir}/c.js"
  sed -i "s|SUB_REMARKS_LOWER_PLACEHOLDER|${sub_remarks_lower}|g" "${functions_dir}/c.js"
  sed -i "s|SUB_REMARKS_PLACEHOLDER|${SUB_REMARKS:-US-ISP}|g" "${functions_dir}/c.js"
  sed -i "s|TROJAN_DOMAIN_PLACEHOLDER|${TROJAN_DOMAIN}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_DOMAIN_PLACEHOLDER|${HYSTERIA_DOMAIN}|g" "${functions_dir}/c.js"
  sed -i "s|TROJAN_PASSWORD_PLACEHOLDER|${TROJAN_PASSWORD}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_PASSWORD_PLACEHOLDER|${HYSTERIA_PASSWORD}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_OBFS_PLACEHOLDER|${HYSTERIA_OBFS_PASSWORD}|g" "${functions_dir}/c.js"
  sed -i "s|AI_ISP_DOMAINS_BASE64_PLACEHOLDER|${ai_isp_domains_base64}|g" "${functions_dir}/c.js"
  sed -i "s|DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER|${direct_bulk_domains_base64}|g" "${functions_dir}/c.js"
  sed -i "s|CLIENT_DIRECT_IP_CIDRS_BASE64_PLACEHOLDER|${client_direct_ip_cidrs_base64}|g" "${functions_dir}/c.js"
  sed -i "s|CLASH_FORCE_TCP_DOMAINS_BASE64_PLACEHOLDER|${force_tcp_domains_base64}|g" "${functions_dir}/c.js"
  sed -i "s|CLASH_FORCE_TCP_ENABLED_PLACEHOLDER|${force_tcp_enabled_js}|g" "${functions_dir}/c.js"
  sed -i "s|DIRECT_BULK_ENABLED_PLACEHOLDER|${direct_bulk_enabled_js}|g" "${functions_dir}/c.js"
  sed -i "s|DIRECT_BULK_APPS_JSON_PLACEHOLDER|${direct_bulk_apps_json}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_USE_BBR_PLACEHOLDER|${hy2_use_bbr_js}|g" "${functions_dir}/c.js"
  sed -i "s|CLASH_RULESET_BASE_URL_PLACEHOLDER|${CLASH_RULESET_BASE_URL%/}|g" "${functions_dir}/c.js"
  sed -i "s|ISP_PUBLIC_LIST_BASE64_PLACEHOLDER|${isp_public_list_base64}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_UP_PLACEHOLDER|${HYSTERIA_UP_MBPS}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_DOWN_PLACEHOLDER|${HYSTERIA_DOWN_MBPS}|g" "${functions_dir}/c.js"

  sed -i "s|AI_ISP_DOMAINS_JSON_PLACEHOLDER|${ai_isp_domains_json}|g" "${pages_dir}/global-extension.js"
  sed -i "s|DIRECT_BULK_DOMAINS_JSON_PLACEHOLDER|${direct_bulk_domains_json}|g" "${pages_dir}/global-extension.js"
  sed -i "s|DIRECT_BULK_APPS_JSON_PLACEHOLDER|${direct_bulk_apps_json}|g" "${pages_dir}/global-extension.js"
  sed -i "s|CLIENT_DIRECT_IP_CIDRS_JSON_PLACEHOLDER|${client_direct_ip_cidrs_json}|g" "${pages_dir}/global-extension.js"
  sed -i "s|CLASH_FORCE_TCP_DOMAINS_JSON_PLACEHOLDER|${force_tcp_domains_json}|g" "${pages_dir}/global-extension.js"
  sed -i "s|CLASH_FORCE_TCP_ENABLED_PLACEHOLDER|${force_tcp_enabled_js}|g" "${pages_dir}/global-extension.js"
  sed -i "s|HYSTERIA_USE_BBR_PLACEHOLDER|${hy2_use_bbr_js}|g" "${pages_dir}/global-extension.js"
  sed -i "s|CLASH_RULESET_BASE_URL_PLACEHOLDER|${CLASH_RULESET_BASE_URL%/}|g" "${pages_dir}/global-extension.js"
  sed -i "s|TROJAN_DOMAIN_PLACEHOLDER|${TROJAN_DOMAIN}|g" "${pages_dir}/global-extension.js"
  sed -i "s|HYSTERIA_DOMAIN_PLACEHOLDER|${HYSTERIA_DOMAIN}|g" "${pages_dir}/global-extension.js"
  sed -i "s|TROJAN_PASSWORD_PLACEHOLDER|${TROJAN_PASSWORD}|g" "${pages_dir}/global-extension.js"
  sed -i "s|HYSTERIA_PASSWORD_PLACEHOLDER|${HYSTERIA_PASSWORD}|g" "${pages_dir}/global-extension.js"
  sed -i "s|HYSTERIA_OBFS_PLACEHOLDER|${HYSTERIA_OBFS_PASSWORD}|g" "${pages_dir}/global-extension.js"
  sed -i "s|ISP_PUBLIC_LIST_BASE64_PLACEHOLDER|${isp_public_list_base64}|g" "${pages_dir}/global-extension.js"
  sed -i "s|HYSTERIA_UP_PLACEHOLDER|${HYSTERIA_UP_MBPS}|g" "${pages_dir}/global-extension.js"
  sed -i "s|HYSTERIA_DOWN_PLACEHOLDER|${HYSTERIA_DOWN_MBPS}|g" "${pages_dir}/global-extension.js"

  # 主页公开订阅编号、ISP 地址、到期日和独立链接，不包含 ISP 账号或密码。
  jq -cn \
    --argjson entries "${ISP_PUBLIC_LIST_JSON}" \
    '$entries | map({
      id,
      host,
      expires,
      v2: ("/v2?isp=" + .id),
      clash: ("/c?isp=" + .id),
      shadowrocket: ("/v2?isp=" + .id),
      shadowrocket_module: "/sr"
    })' \
    > "${pages_dir}/subscriptions.json"
  
  # 生成 _redirects（每次重建，确保隐藏路径始终最新）
  cat > "${pages_dir}/_redirects" <<REDIRECTS
# Cloudflare Pages 重定向规则
# 格式: <source> <destination> [status]

# 隐藏订阅路径 - 外部 providers 使用
/${hidden_path}/nodes /nodes.yaml 200

# v2rayN 订阅接口
/v2 /v2 200

# Clash 订阅接口
/c /c 200

# Clash Verge 全局扩展脚本
/s /global-extension.js 200

# Shadowrocket Telegram 高优先级模块
/sr /sr 200
REDIRECTS

  chmod 0755 "${functions_dir}"
  chmod 0600 \
    "${functions_dir}/v2.js" \
    "${functions_dir}/sr.js" \
    "${functions_dir}/c.js" \
    "${pages_dir}/global-extension.js" \
    "${pages_dir}/subscriptions.json" \
    "${pages_dir}/_redirects"

  log_success "订阅配置文件已更新"

  # 检查 wrangler 是否安装
  if ! command -v wrangler &>/dev/null; then
    log_warn "wrangler CLI 未安装，跳过自动部署"
    if ! activate_staged_pages "${pages_dir}" "${live_pages_dir}"; then
      discard_pages_stage
      release_pages_deploy_lock
      return 1
    fi
    log_info "手动部署命令: cd ${live_pages_dir} && wrangler pages deploy ."
    discard_pages_stage
    release_pages_deploy_lock
    return 0
  fi

  validate_generated_pages_assets "${pages_dir}"

  log_info "开始部署到 Cloudflare Pages..."
  
  # 执行部署
  if (cd "$pages_dir" && GIT_OPTIONAL_LOCKS=0 CLOUDFLARE_API_TOKEN="${CF_API_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" wrangler pages deploy . --project-name="${CF_PAGES_PROJECT}" --branch=main 2>&1); then
    log_success "Cloudflare Pages 部署完成"
    log_info "订阅链接: https://${SUB_DOMAIN}/v2 (v2rayN)"
    log_info "订阅链接: https://${SUB_DOMAIN}/c (Clash)"
    log_info "全局扩展脚本: https://${SUB_DOMAIN}/s (Clash Verge)"
    log_info "Telegram 模块: https://${SUB_DOMAIN}/sr (Shadowrocket)"
    
    # 验证订阅
    if verify_subscription; then
      if ! activate_staged_pages "${pages_dir}" "${live_pages_dir}"; then
        log_error "本地资产切换失败，重新部署原版本以保持线上与本地一致"
        (cd "${live_pages_dir}" && GIT_OPTIONAL_LOCKS=0 CLOUDFLARE_API_TOKEN="${CF_API_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" wrangler pages deploy . --project-name="${CF_PAGES_PROJECT}" --branch=main 2>&1) || true
        discard_pages_stage
        release_pages_deploy_lock
        return 1
      fi
      discard_pages_stage
      release_pages_deploy_lock
      return 0
    fi
    log_error "新 Pages 部署线上验证失败，开始重新部署原版本"
    if (cd "${live_pages_dir}" && GIT_OPTIONAL_LOCKS=0 CLOUDFLARE_API_TOKEN="${CF_API_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" wrangler pages deploy . --project-name="${CF_PAGES_PROJECT}" --branch=main 2>&1); then
      log_success "Cloudflare Pages 已恢复到部署前资产"
    else
      log_error "Cloudflare Pages 自动恢复失败，请立即执行控制台回滚"
    fi
    discard_pages_stage
    release_pages_deploy_lock
    return 1
  else
    log_error "Cloudflare Pages 部署失败"
    log_info "原 Pages 本地资产保持不变"
    discard_pages_stage
    release_pages_deploy_lock
    return 1
  fi
}

main() {
  parse_args "$@"
  require_supported_os
  load_env
  validate_config
  if (( PAGES_ONLY == 1 )); then
    require_root
    local pages_required_var
    for pages_required_var in CF_API_TOKEN CF_ACCOUNT_ID SUB_DOMAIN; do
      if [[ -z "${!pages_required_var:-}" ]]; then
        log_error "Pages-only 发布需要 ${pages_required_var}"
        exit 1
      fi
    done
    validate_domain_like "SUB_DOMAIN" "${SUB_DOMAIN}"
    for command_name in curl flock git jq node wrangler; do
      command -v "${command_name}" >/dev/null 2>&1 || {
        log_error "Pages-only 发布需要 ${command_name}"
        exit 1
      }
    done
    build_isp_json
    update_cloudflare_pages
    log_success "Pages-only 发布完成；未修改 sing-box、UFW 或系统网络"
    return
  fi
  if (( VALIDATE_ONLY == 1 )); then
    command -v jq >/dev/null 2>&1 || {
      log_error "校验需要 jq"
      exit 1
    }
    command -v sing-box >/dev/null 2>&1 || {
      log_error "校验需要 sing-box"
      exit 1
    }
    generate_config
    validate_generated_config
    log_success "只读校验完成，未修改系统配置"
    return
  fi
  require_root
  install_dependencies
  install_singbox
  preflight_isp_egress
  prepare_dirs
  backup_existing_config
  generate_config
  validate_generated_config
  deploy_config
  apply_network_tuning
  setup_firewall
  setup_systemd_override
  restart_service
  setup_egress_monitor
  write_summary
  show_final_info
  
  if (( SKIP_PAGES == 1 )); then
    log_warn "按参数要求跳过 Cloudflare Pages 发布与规则同步定时器"
  else
    # 自动更新并部署 Cloudflare Pages 订阅配置
    update_cloudflare_pages
    setup_clash_rules_sync_timer
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
