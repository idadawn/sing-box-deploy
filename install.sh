#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# =========================================================
# sing-box 自动化部署脚本（Debian / Ubuntu）
# - Trojan + Hysteria2
# - 主出口：ISP SOCKS5（ISP-1 / 可选 ISP-2）
# - AI 强制走 ISP；可选让视频/CDN/软件包下载从当前服务器直出
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

FORCE_REINSTALL=0
SKIP_FIREWALL=0
NO_START=0

TMP_CONFIG=""
BACKUP_CONFIG=""

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

DEFAULT_CLASH_RULESET_BASE_URL="https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release"

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
  --no-start           仅部署配置，不启动/重启 sing-box
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
      --no-start)
        NO_START=1
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
  URLTEST_URL="${URLTEST_URL:-https://www.gstatic.com/generate_204}"
  URLTEST_INTERVAL="${URLTEST_INTERVAL:-3m}"
  URLTEST_TOLERANCE="${URLTEST_TOLERANCE:-50}"
  AI_ISP_DOMAINS="${AI_ISP_DOMAINS:-${DEFAULT_AI_ISP_DOMAINS}}"
  DIRECT_BULK_ENABLED="${DIRECT_BULK_ENABLED:-false}"
  DIRECT_BULK_DOMAINS="${DIRECT_BULK_DOMAINS:-${DEFAULT_DIRECT_BULK_DOMAINS}}"
  CLASH_RULESET_BASE_URL="${CLASH_RULESET_BASE_URL:-${DEFAULT_CLASH_RULESET_BASE_URL}}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
  SSH_PORT="${SSH_PORT:-22}"
  ENABLE_UFW="${ENABLE_UFW:-true}"

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

validate_config() {
  log_info "校验配置..."

  local required_vars=(
    TROJAN_DOMAIN
    HYSTERIA_DOMAIN
    CF_DNS_EDIT_TOKEN
    ACME_EMAIL
    PROXY_HOST
    PROXY_PORT
    PROXY_USER
    PROXY_PASS
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

  # 可选：备用 J 中继服务器域名验证
  HAS_VPS_J=0
  if [[ -n "${J_TROJAN_DOMAIN:-}" || -n "${J_HYSTERIA_DOMAIN:-}" ]]; then
    if [[ -z "${J_TROJAN_DOMAIN:-}" || -z "${J_HYSTERIA_DOMAIN:-}" ]]; then
      log_error "启用 J 中继服务器时，必须同时设置 J_TROJAN_DOMAIN 和 J_HYSTERIA_DOMAIN"
      exit 1
    fi
    validate_domain_like "J_TROJAN_DOMAIN" "${J_TROJAN_DOMAIN}"
    validate_domain_like "J_HYSTERIA_DOMAIN" "${J_HYSTERIA_DOMAIN}"
    if [[ "${J_TROJAN_DOMAIN}" == "${J_HYSTERIA_DOMAIN}" ]]; then
      log_error "J_TROJAN_DOMAIN 和 J_HYSTERIA_DOMAIN 不应相同"
      exit 1
    fi
    HAS_VPS_J=1
  fi

  validate_port "TROJAN_PORT" "${TROJAN_PORT}"
  validate_port "HYSTERIA_PORT" "${HYSTERIA_PORT}"
  validate_port "PROXY_PORT" "${PROXY_PORT}"
  validate_port "SSH_PORT" "${SSH_PORT}"

  local proxy2_fields=(
    PROXY2_HOST
    PROXY2_PORT
    PROXY2_USER
    PROXY2_PASS
  )
  local proxy2_set_count=0
  local proxy2_var
  for proxy2_var in "${proxy2_fields[@]}"; do
    [[ -n "${!proxy2_var:-}" ]] && proxy2_set_count=$((proxy2_set_count + 1))
  done

  HAS_PROXY2=0
  if (( proxy2_set_count > 0 )); then
    if (( proxy2_set_count != ${#proxy2_fields[@]} )); then
      log_error "启用 ISP-2 时，必须完整设置 PROXY2_HOST/PORT/USER/PASS"
      exit 1
    fi
    validate_port "PROXY2_PORT" "${PROXY2_PORT}"
    HAS_PROXY2=1
  fi

  ISP2_TROJAN_PORT="${ISP2_TROJAN_PORT:-$(derive_offset_port ISP2_TROJAN_PORT "${TROJAN_PORT}" 10000)}"
  ISP2_HYSTERIA_PORT="${ISP2_HYSTERIA_PORT:-$(derive_offset_port ISP2_HYSTERIA_PORT "${HYSTERIA_PORT}" 10000)}"
  if (( HAS_PROXY2 == 1 )); then
    validate_port "ISP2_TROJAN_PORT" "${ISP2_TROJAN_PORT}"
    validate_port "ISP2_HYSTERIA_PORT" "${ISP2_HYSTERIA_PORT}"
  fi

  validate_positive_int "HYSTERIA_UP_MBPS" "${HYSTERIA_UP_MBPS}"
  validate_positive_int "HYSTERIA_DOWN_MBPS" "${HYSTERIA_DOWN_MBPS}"
  validate_positive_int "URLTEST_TOLERANCE" "${URLTEST_TOLERANCE}"

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
  apt-get install -y curl jq ca-certificates gnupg ufw
  log_success "基础依赖安装完成"
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

  local direct_bulk_enabled_json=false
  if is_true "${DIRECT_BULK_ENABLED}"; then
    direct_bulk_enabled_json=true
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
    --arg proxy_host "${PROXY_HOST}" \
    --arg proxy2_host "${PROXY2_HOST:-}" \
    --arg proxy_user "${PROXY_USER}" \
    --arg proxy2_user "${PROXY2_USER:-}" \
    --arg proxy_pass "${PROXY_PASS}" \
    --arg proxy2_pass "${PROXY2_PASS:-}" \
    --arg urltest_url "${URLTEST_URL}" \
    --arg urltest_interval "${URLTEST_INTERVAL}" \
    --arg ai_isp_domains "${AI_ISP_DOMAINS}" \
    --arg direct_bulk_domains "${DIRECT_BULK_DOMAINS}" \
    --argjson direct_bulk_enabled "${direct_bulk_enabled_json}" \
    --argjson has_proxy2 "${HAS_PROXY2}" \
    --argjson trojan_port "${TROJAN_PORT}" \
    --argjson hysteria_port "${HYSTERIA_PORT}" \
    --argjson proxy_port "${PROXY_PORT}" \
    --argjson proxy2_port "${PROXY2_PORT:-0}" \
    --argjson isp2_trojan_port "${ISP2_TROJAN_PORT}" \
    --argjson isp2_hysteria_port "${ISP2_HYSTERIA_PORT}" \
    --argjson hy2_up_mbps "${HYSTERIA_UP_MBPS}" \
    --argjson hy2_down_mbps "${HYSTERIA_DOWN_MBPS}" \
    --argjson urltest_tolerance "${URLTEST_TOLERANCE}" \
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
      ["trojan-isp1-in", "hy2-isp1-in"] + (
        if $has_proxy2 == 1 then
          ["trojan-isp2-in", "hy2-isp2-in"]
        else
          []
        end
      );

    def ai_isp_rules:
      domain_list($ai_isp_domains) as $domains
      | if ($domains | length) > 0 then
          [
            {
              inbound: client_inbounds,
              domain_suffix: $domains,
              outbound: "ai-out"
            }
          ]
        else
          []
        end;

    def direct_bulk_rules:
      domain_list($direct_bulk_domains) as $domains
      | if $direct_bulk_enabled and (($domains | length) > 0) then
          [
            {
              inbound: client_inbounds,
              domain_suffix: $domains,
              outbound: "direct-out"
            }
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
      {
        type: "hysteria2",
        tag: $tag,
        listen: "::",
        listen_port: $port,
        up_mbps: $hy2_up_mbps,
        down_mbps: $hy2_down_mbps,
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
      };

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
        [
          trojan_inbound("trojan-isp1-in"; $trojan_port; "tj-isp1"),
          hy2_inbound("hy2-isp1-in"; $hysteria_port; "hy2-isp1")
        ] + (
          if $has_proxy2 == 1 then
            [
              trojan_inbound("trojan-isp2-in"; $isp2_trojan_port; "tj-isp2"),
              hy2_inbound("hy2-isp2-in"; $isp2_hysteria_port; "hy2-isp2")
            ]
          else
            []
          end
        )
      ),
      outbounds: [
        {
          type: "socks",
          tag: "isp-out-1",
          server: $proxy_host,
          server_port: $proxy_port,
          version: "5",
          username: $proxy_user,
          password: $proxy_pass
        },
        (
          if $has_proxy2 == 1 then
            {
              type: "socks",
              tag: "isp-out-2",
              server: $proxy2_host,
              server_port: $proxy2_port,
              version: "5",
              username: $proxy2_user,
              password: $proxy2_pass
            }
          else
            empty
          end
        ),
        {
          type: "urltest",
          tag: "ai-out",
          outbounds: (
            ["isp-out-1"] + (
              if $has_proxy2 == 1 then
                ["isp-out-2"]
              else
                []
              end
            )
          ),
          url: $urltest_url,
          interval: $urltest_interval,
          tolerance: $urltest_tolerance,
          interrupt_exist_connections: false
        },
        (
          if $direct_bulk_enabled and ((domain_list($direct_bulk_domains) | length) > 0) then
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
      ],
      route: {
        rules: (
          [
            {
              action: "sniff"
            }
          ] + ai_isp_rules + direct_bulk_rules + [
            {
              inbound: ["trojan-isp1-in", "hy2-isp1-in"],
              outbound: "isp-out-1"
            }
          ] + (
            if $has_proxy2 == 1 then
              [
                {
                  inbound: ["trojan-isp2-in", "hy2-isp2-in"],
                  outbound: "isp-out-2"
                }
              ]
            else
              []
            end
          )
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
  ufw allow "${TROJAN_PORT}/tcp" comment 'sing-box Trojan' >/dev/null || true
  ufw allow "${HYSTERIA_PORT}/udp" comment 'sing-box Hysteria2' >/dev/null || true
  if (( HAS_PROXY2 == 1 )); then
    ufw allow "${ISP2_TROJAN_PORT}/tcp" comment 'sing-box Trojan ISP-2' >/dev/null || true
    ufw allow "${ISP2_HYSTERIA_PORT}/udp" comment 'sing-box Hysteria2 ISP-2' >/dev/null || true
  fi

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
      "ISP-1 SOCKS5 出口访问异常") printf '%s' "中继异常-ISP-1出口" ;;
      "ISP-2 SOCKS5 出口访问异常") printf '%s' "中继异常-ISP-2出口" ;;
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

  if retry_command probe_socks5_once "${PROXY_HOST}" "${PROXY_PORT}" "${PROXY_USER}" "${PROXY_PASS}" "${check_url}"; then
    summary+=("ISP-1 SOCKS5 出口正常")
  else
    problems+=("ISP-1 SOCKS5 出口访问异常")
  fi

  if [[ -n "${PROXY2_HOST:-}" && -n "${PROXY2_PORT:-}" && -n "${PROXY2_USER:-}" && -n "${PROXY2_PASS:-}" ]]; then
    if retry_command probe_socks5_once "${PROXY2_HOST}" "${PROXY2_PORT}" "${PROXY2_USER}" "${PROXY2_PASS}" "${check_url}"; then
      summary+=("ISP-2 SOCKS5 出口正常")
    else
      problems+=("ISP-2 SOCKS5 出口访问异常")
    fi
  fi

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
  cat > "${summary_file}" <<EOF
部署时间: $(date '+%Y-%m-%d %H:%M:%S')

[服务端入口]
Trojan:
  域名: ${TROJAN_DOMAIN}
  端口: ${TROJAN_PORT}
  SNI : ${TROJAN_DOMAIN}

Hysteria2:
  域名: ${HYSTERIA_DOMAIN}
  端口: ${HYSTERIA_PORT}
  SNI : ${HYSTERIA_DOMAIN}
  OBFS: salamander

[服务端出口]
ISP-1: SOCKS5 (${PROXY_HOST}:${PROXY_PORT})
ISP-2: ${PROXY2_HOST:-未配置}
AI 域名: 强制使用 ISP 自动出口
视频/软件下载直出: ${DIRECT_BULK_ENABLED}
Clash 自动容灾: T-ISP1 -> T-ISP2 -> J-ISP1 -> J-ISP2
v2rayN/v2rayNG: 可手动选择 T-ISP1 / T-ISP2 / J-ISP1 / J-ISP2 节点

[接入端口]
ISP-1 Trojan: ${TROJAN_PORT}
ISP-1 Hysteria2: ${HYSTERIA_PORT}
ISP-2 Trojan: ${ISP2_TROJAN_PORT}
ISP-2 Hysteria2: ${ISP2_HYSTERIA_PORT}

[文件]
配置文件: ${CONFIG_PATH}
证书目录: ${CERT_DIR}
备份配置: ${BACKUP_CONFIG:-无}

[常用命令]
检查配置: sing-box check -c ${CONFIG_PATH}
查看状态: systemctl status sing-box
查看日志: journalctl -u sing-box -f
重启服务: systemctl restart sing-box
EOF
  chmod 600 "${summary_file}"
  log_success "部署摘要已写入: ${summary_file}"
}

show_final_info() {
  echo
  echo "=================================================="
  echo -e "${GREEN}部署完成${NC}"
  echo "=================================================="
  echo "Trojan    : ${TROJAN_DOMAIN}:${TROJAN_PORT}"
  echo "Hysteria2 : ${HYSTERIA_DOMAIN}:${HYSTERIA_PORT}"
  echo "ISP-1 出口 : ${PROXY_HOST}:${PROXY_PORT}"
  if (( HAS_PROXY2 == 1 )); then
    echo "ISP-2 出口 : ${PROXY2_HOST}:${PROXY2_PORT}"
  fi
  echo "AI 域名策略: ISP 自动出口"
  echo "视频/下载直出: ${DIRECT_BULK_ENABLED}"
  echo "Clash 容灾 : T-ISP1 -> T-ISP2 -> J-ISP1 -> J-ISP2"
  echo "v2 手选节点: T-ISP1 / T-ISP2 / J-ISP1 / J-ISP2"
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
  local max_retry=3
  local retry=0
  local v2_ok=0
  local c_ok=0
  
  # 等待几秒让部署生效
  sleep 2
  
  while [[ $retry -lt $max_retry ]]; do
    # 验证 v2rayN 订阅
    if [[ $v2_ok -eq 0 ]]; then
      local v2_content=$(curl -sL --max-time 10 "https://${domain}/v2" 2>/dev/null | base64 -d 2>/dev/null)
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
      local c_content=$(curl -sL --max-time 10 "https://${domain}/c" 2>/dev/null)
      if grep -q "proxies:" <<< "$c_content"; then
        local c_node_count=$(grep -c "name:" <<< "$c_content")
        log_success "Clash 订阅正常: 发现 ${c_node_count} 个节点"
        c_ok=1
      else
        log_warn "Clash 订阅验证失败，重试..."
      fi
    fi
    
    # 都成功则退出
    if [[ $v2_ok -eq 1 && $c_ok -eq 1 ]]; then
      log_success "订阅验证全部通过！"
      return 0
    fi
    
    retry=$((retry + 1))
    if [[ $retry -lt $max_retry ]]; then
      sleep 3
    fi
  done
  
  # 验证失败
  if [[ $v2_ok -eq 0 ]]; then
    log_error "v2rayN 订阅验证失败: https://${domain}/v2"
  fi
  if [[ $c_ok -eq 0 ]]; then
    log_error "Clash 订阅验证失败: https://${domain}/c"
  fi
  log_info "请检查: 1) DNS 解析 2) Cloudflare Pages 部署状态 3) 自定义域名绑定"
  return 1
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

  local pages_dir="${SCRIPT_DIR}/cloudflare-pages-sub"
  local functions_dir="${pages_dir}/functions"
  
  # 检查目录是否存在
  if [[ ! -d "$pages_dir" ]]; then
    log_warn "未找到 cloudflare-pages-sub 目录，跳过自动部署"
    return 0
  fi

  log_info "开始更新 Cloudflare Pages 订阅配置..."

  # 确保 functions 目录存在
  mkdir -p "$functions_dir"

  # 生成 v2.js (v2rayN 订阅) - URI 格式
  # v2rayN 需要 Base64 编码的 URI 列表，不是 JSON
  cat > "${functions_dir}/v2.js" <<'V2JS'
// v2rayN 订阅接口 - 返回 Base64 编码的 URI 列表
export async function onRequest(context) {
  const url = new URL(context.request.url);
  const isRaw = url.searchParams.get('raw') === '1';

  const nodes = [
    `trojan://TROJAN_PASSWORD_PLACEHOLDER@TROJAN_DOMAIN_PLACEHOLDER:TROJAN_PORT_PLACEHOLDER?security=tls&sni=TROJAN_DOMAIN_PLACEHOLDER&alpn=h2%2Chttp%2F1.1&fp=chrome#T-ISP1-TJ`,
    `hysteria2://HYSTERIA_PASSWORD_PLACEHOLDER@HYSTERIA_DOMAIN_PLACEHOLDER:HYSTERIA_PORT_PLACEHOLDER/?sni=HYSTERIA_DOMAIN_PLACEHOLDER&obfs=salamander&obfs-password=HYSTERIA_OBFS_PLACEHOLDER&insecure=0#T-ISP1-HY2`,
  ];

  if (HAS_PROXY2_PLACEHOLDER) {
    nodes.push(
      `trojan://TROJAN_PASSWORD_PLACEHOLDER@TROJAN_DOMAIN_PLACEHOLDER:ISP2_TROJAN_PORT_PLACEHOLDER?security=tls&sni=TROJAN_DOMAIN_PLACEHOLDER&alpn=h2%2Chttp%2F1.1&fp=chrome#T-ISP2-TJ`,
      `hysteria2://HYSTERIA_PASSWORD_PLACEHOLDER@HYSTERIA_DOMAIN_PLACEHOLDER:ISP2_HYSTERIA_PORT_PLACEHOLDER/?sni=HYSTERIA_DOMAIN_PLACEHOLDER&obfs=salamander&obfs-password=HYSTERIA_OBFS_PLACEHOLDER&insecure=0#T-ISP2-HY2`,
    );
  }

  if (J_ENABLED_PLACEHOLDER) {
    nodes.push(
      `trojan://TROJAN_PASSWORD_PLACEHOLDER@J_TROJAN_DOMAIN_PLACEHOLDER:TROJAN_PORT_PLACEHOLDER?security=tls&sni=J_TROJAN_DOMAIN_PLACEHOLDER&alpn=h2%2Chttp%2F1.1&fp=chrome#J-ISP1-TJ`,
      `hysteria2://HYSTERIA_PASSWORD_PLACEHOLDER@J_HYSTERIA_DOMAIN_PLACEHOLDER:HYSTERIA_PORT_PLACEHOLDER/?sni=J_HYSTERIA_DOMAIN_PLACEHOLDER&obfs=salamander&obfs-password=HYSTERIA_OBFS_PLACEHOLDER&insecure=0#J-ISP1-HY2`,
    );
    if (HAS_PROXY2_PLACEHOLDER) {
      nodes.push(
        `trojan://TROJAN_PASSWORD_PLACEHOLDER@J_TROJAN_DOMAIN_PLACEHOLDER:ISP2_TROJAN_PORT_PLACEHOLDER?security=tls&sni=J_TROJAN_DOMAIN_PLACEHOLDER&alpn=h2%2Chttp%2F1.1&fp=chrome#J-ISP2-TJ`,
        `hysteria2://HYSTERIA_PASSWORD_PLACEHOLDER@J_HYSTERIA_DOMAIN_PLACEHOLDER:ISP2_HYSTERIA_PORT_PLACEHOLDER/?sni=J_HYSTERIA_DOMAIN_PLACEHOLDER&obfs=salamander&obfs-password=HYSTERIA_OBFS_PLACEHOLDER&insecure=0#J-ISP2-HY2`,
      );
    }
  }

  const uriList = nodes.join('\n');

  if (isRaw) {
    return new Response(uriList, {
      status: 200,
      headers: { 
        'Content-Type': 'text/plain; charset=utf-8', 
        'Cache-Control': 'no-cache', 
        'Access-Control-Allow-Origin': '*'
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
      'Subscription-Userinfo': 'upload=0; download=0; total=0; expire=0'
    }
  });
}
V2JS

  # URL 编码密码 (处理 + = 等特殊字符)
  local trojan_password_encoded=$(echo -n "${TROJAN_PASSWORD}" | jq -sRr @uri)
  local hy2_password_encoded=$(echo -n "${HYSTERIA_PASSWORD}" | jq -sRr @uri)
  local obfs_password_encoded=$(echo -n "${HYSTERIA_OBFS_PASSWORD}" | jq -sRr @uri)
  
  # 替换 v2.js 中的占位符
  sed -i "s|J_TROJAN_DOMAIN_PLACEHOLDER|${J_TROJAN_DOMAIN:-}|g" "${functions_dir}/v2.js"
  sed -i "s|J_HYSTERIA_DOMAIN_PLACEHOLDER|${J_HYSTERIA_DOMAIN:-}|g" "${functions_dir}/v2.js"
  sed -i "s|TROJAN_DOMAIN_PLACEHOLDER|${TROJAN_DOMAIN}|g" "${functions_dir}/v2.js"
  sed -i "s|HYSTERIA_DOMAIN_PLACEHOLDER|${HYSTERIA_DOMAIN}|g" "${functions_dir}/v2.js"
  sed -i "s|ISP2_TROJAN_PORT_PLACEHOLDER|${ISP2_TROJAN_PORT}|g" "${functions_dir}/v2.js"
  sed -i "s|ISP2_HYSTERIA_PORT_PLACEHOLDER|${ISP2_HYSTERIA_PORT}|g" "${functions_dir}/v2.js"
  sed -i "s|TROJAN_PORT_PLACEHOLDER|${TROJAN_PORT}|g" "${functions_dir}/v2.js"
  sed -i "s|HYSTERIA_PORT_PLACEHOLDER|${HYSTERIA_PORT}|g" "${functions_dir}/v2.js"
  sed -i "s|TROJAN_PASSWORD_PLACEHOLDER|${trojan_password_encoded}|g" "${functions_dir}/v2.js"
  sed -i "s|HYSTERIA_PASSWORD_PLACEHOLDER|${hy2_password_encoded}|g" "${functions_dir}/v2.js"
  sed -i "s|HYSTERIA_OBFS_PLACEHOLDER|${obfs_password_encoded}|g" "${functions_dir}/v2.js"
  sed -i "s|HAS_PROXY2_PLACEHOLDER|$([[ ${HAS_PROXY2} -eq 1 ]] && echo true || echo false)|g" "${functions_dir}/v2.js"
  sed -i "s|J_ENABLED_PLACEHOLDER|$([[ ${HAS_VPS_J} -eq 1 ]] && echo true || echo false)|g" "${functions_dir}/v2.js"

  # 生成 c.js (Clash 订阅) - 完整双层结构配置
  cat > "${functions_dir}/c.js" <<'CJS'
// Clash 订阅接口 - 返回完整双层结构配置
export async function onRequest(context) {
  const proxyNames = [
    "T-ISP1-TJ",
    "T-ISP1-HY2",
    ...(HAS_PROXY2_PLACEHOLDER ? ["T-ISP2-TJ", "T-ISP2-HY2"] : []),
    ...(J_ENABLED_PLACEHOLDER ? ["J-ISP1-TJ", "J-ISP1-HY2"] : []),
    ...(J_ENABLED_PLACEHOLDER && HAS_PROXY2_PLACEHOLDER ? ["J-ISP2-TJ", "J-ISP2-HY2"] : []),
  ];
  const txProxyNames = [
    "T-ISP1-TJ",
    "T-ISP1-HY2",
    ...(HAS_PROXY2_PLACEHOLDER ? ["T-ISP2-TJ", "T-ISP2-HY2"] : []),
  ];
  const ispOnlyProxyNames = [
    "T-ISP1-TJ",
    "T-ISP1-HY2",
    ...(HAS_PROXY2_PLACEHOLDER ? ["T-ISP2-TJ", "T-ISP2-HY2"] : []),
    ...(J_ENABLED_PLACEHOLDER ? ["J-ISP1-TJ", "J-ISP1-HY2"] : []),
    ...(J_ENABLED_PLACEHOLDER && HAS_PROXY2_PLACEHOLDER ? ["J-ISP2-TJ", "J-ISP2-HY2"] : []),
  ];
  const decodeDomainList = (encoded) => atob(encoded)
    .split(/[\s,]+/)
    .map((domain) => domain.trim())
    .filter(Boolean);
  const aiIspDomains = decodeDomainList("AI_ISP_DOMAINS_BASE64_PLACEHOLDER");
  const txBulkDomains = DIRECT_BULK_ENABLED_PLACEHOLDER
    ? decodeDomainList("DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER")
    : [];

  const proxies = [
    `  - name: "T-ISP1-TJ"
    type: trojan
    server: TROJAN_DOMAIN_PLACEHOLDER
    port: TROJAN_PORT_PLACEHOLDER
    password: "TROJAN_PASSWORD_PLACEHOLDER"
    udp: true
    sni: TROJAN_DOMAIN_PLACEHOLDER
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
    client-fingerprint: chrome`,
    `  - name: "T-ISP1-HY2"
    type: hysteria2
    server: HYSTERIA_DOMAIN_PLACEHOLDER
    port: HYSTERIA_PORT_PLACEHOLDER
    password: "HYSTERIA_PASSWORD_PLACEHOLDER"
    obfs: salamander
    obfs-password: "HYSTERIA_OBFS_PLACEHOLDER"
    alpn:
      - h3
    sni: HYSTERIA_DOMAIN_PLACEHOLDER
    skip-cert-verify: false
    up: "HYSTERIA_UP_PLACEHOLDER Mbps"
    down: "HYSTERIA_DOWN_PLACEHOLDER Mbps"`,
    ...(HAS_PROXY2_PLACEHOLDER
      ? [
          `  - name: "T-ISP2-TJ"
    type: trojan
    server: TROJAN_DOMAIN_PLACEHOLDER
    port: ISP2_TROJAN_PORT_PLACEHOLDER
    password: "TROJAN_PASSWORD_PLACEHOLDER"
    udp: true
    sni: TROJAN_DOMAIN_PLACEHOLDER
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
    client-fingerprint: chrome`,
          `  - name: "T-ISP2-HY2"
    type: hysteria2
    server: HYSTERIA_DOMAIN_PLACEHOLDER
    port: ISP2_HYSTERIA_PORT_PLACEHOLDER
    password: "HYSTERIA_PASSWORD_PLACEHOLDER"
    obfs: salamander
    obfs-password: "HYSTERIA_OBFS_PLACEHOLDER"
    alpn:
      - h3
    sni: HYSTERIA_DOMAIN_PLACEHOLDER
    skip-cert-verify: false
    up: "HYSTERIA_UP_PLACEHOLDER Mbps"
    down: "HYSTERIA_DOWN_PLACEHOLDER Mbps"`,
        ]
      : []),
    ...(J_ENABLED_PLACEHOLDER
      ? [
          `  - name: "J-ISP1-TJ"
    type: trojan
    server: J_TROJAN_DOMAIN_PLACEHOLDER
    port: TROJAN_PORT_PLACEHOLDER
    password: "TROJAN_PASSWORD_PLACEHOLDER"
    udp: true
    sni: J_TROJAN_DOMAIN_PLACEHOLDER
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
    client-fingerprint: chrome`,
          `  - name: "J-ISP1-HY2"
    type: hysteria2
    server: J_HYSTERIA_DOMAIN_PLACEHOLDER
    port: HYSTERIA_PORT_PLACEHOLDER
    password: "HYSTERIA_PASSWORD_PLACEHOLDER"
    obfs: salamander
    obfs-password: "HYSTERIA_OBFS_PLACEHOLDER"
    alpn:
      - h3
    sni: J_HYSTERIA_DOMAIN_PLACEHOLDER
    skip-cert-verify: false
    up: "HYSTERIA_UP_PLACEHOLDER Mbps"
    down: "HYSTERIA_DOWN_PLACEHOLDER Mbps"`,
        ]
      : []),
    ...(J_ENABLED_PLACEHOLDER && HAS_PROXY2_PLACEHOLDER
      ? [
          `  - name: "J-ISP2-TJ"
    type: trojan
    server: J_TROJAN_DOMAIN_PLACEHOLDER
    port: ISP2_TROJAN_PORT_PLACEHOLDER
    password: "TROJAN_PASSWORD_PLACEHOLDER"
    udp: true
    sni: J_TROJAN_DOMAIN_PLACEHOLDER
    alpn:
      - h2
      - http/1.1
    skip-cert-verify: false
    client-fingerprint: chrome`,
          `  - name: "J-ISP2-HY2"
    type: hysteria2
    server: J_HYSTERIA_DOMAIN_PLACEHOLDER
    port: ISP2_HYSTERIA_PORT_PLACEHOLDER
    password: "HYSTERIA_PASSWORD_PLACEHOLDER"
    obfs: salamander
    obfs-password: "HYSTERIA_OBFS_PLACEHOLDER"
    alpn:
      - h3
    sni: J_HYSTERIA_DOMAIN_PLACEHOLDER
    skip-cert-verify: false
    up: "HYSTERIA_UP_PLACEHOLDER Mbps"
    down: "HYSTERIA_DOWN_PLACEHOLDER Mbps"`,
        ]
      : []),
  ];

  const proxyGroupLines = proxyNames.map((name) => `      - "${name}"`).join('\n');
  const txProxyGroupLines = txProxyNames.map((name) => `      - "${name}"`).join('\n');
  const ispOnlyProxyGroupLines = ispOnlyProxyNames.map((name) => `      - "${name}"`).join('\n');
  const selectProxyLines = [`      - "♻️ 自动选择"`, `      - "🛡️ 自动容灾"`, ...proxyNames.map((name) => `      - "${name}"`)].join('\n');
  const ispOnlySelectProxyLines = [`      - "🛡️ ISP 出口自动"`, ...ispOnlyProxyNames.map((name) => `      - "${name}"`)].join('\n');
  const fallbackProxyLines = ispOnlySelectProxyLines;
  const aiRuleLines = aiIspDomains
    .map((domain) => `    - 'DOMAIN-SUFFIX,${domain},🤖 AI 服务'`)
    .join('\n');
  const txBulkRuleLines = txBulkDomains
    .map((domain) => `    - 'DOMAIN-SUFFIX,${domain},📦 TX 大流量'`)
    .join('\n');

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
      - tls://1.1.1.1
      - tls://8.8.4.4
  fallback:
    - tls://1.1.1.1
    - tls://8.8.4.4
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
    url: "https://cp.cloudflare.com"
    interval: 300
    timeout: 3000

  - name: "♻️ 自动选择"
    type: url-test
    proxies:
${proxyGroupLines}
    url: "https://cp.cloudflare.com"
    interval: 300
    tolerance: 50
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
    url: "https://cp.cloudflare.com"
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
      - "🚀 节点选择"
      - "♻️ 自动选择"
      - "🛡️ 自动容灾"

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
${aiRuleLines}
${txBulkRuleLines}

    # Apple NTP 优先直连：避免 UDP/123 时间同步请求被代理策略截走导致解析或连接超时
    - 'DOMAIN,time.apple.com,DIRECT'

    # 本地/公司内网优先直连：避免浏览器系统代理把网关管理地址送入代理节点
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
    - 'RULE-SET,loyalsoldier-telegramcidr,📲 电报信息,no-resolve'
    - 'RULE-SET,loyalsoldier-proxy,🚀 节点选择'
    - 'RULE-SET,loyalsoldier-direct,🎯 全球直连'
    - 'RULE-SET,loyalsoldier-lancidr,DIRECT,no-resolve'
    - 'RULE-SET,loyalsoldier-cncidr,🎯 全球直连,no-resolve'
    - 'GEOIP,LAN,DIRECT'
    - 'GEOIP,CN,🎯 全球直连'
    - 'MATCH,🐟 漏网之鱼'

`;
  return new Response(config, {
    status: 200,
    headers: { 
      'Content-Type': 'text/yaml; charset=utf-8', 
      'Cache-Control': 'no-cache', 
      'Access-Control-Allow-Origin': '*' 
    }
  });
}
CJS

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
  local direct_bulk_enabled_js=false
  ai_isp_domains_base64=$(printf '%s' "${AI_ISP_DOMAINS}" | base64 | tr -d '\n')
  direct_bulk_domains_base64=$(printf '%s' "${DIRECT_BULK_DOMAINS}" | base64 | tr -d '\n')
  if is_true "${DIRECT_BULK_ENABLED}"; then
    direct_bulk_enabled_js=true
  fi
  
  sed -i "s|SECRET_PLACEHOLDER|${secret}|g" "${functions_dir}/c.js"
  sed -i "s|HIDDEN_SUB_URL_PLACEHOLDER|${hidden_sub_url}|g" "${functions_dir}/c.js"
  sed -i "s|SUB_REMARKS_LOWER_PLACEHOLDER|${sub_remarks_lower}|g" "${functions_dir}/c.js"
  sed -i "s|SUB_REMARKS_PLACEHOLDER|${SUB_REMARKS:-US-ISP}|g" "${functions_dir}/c.js"
  sed -i "s|J_TROJAN_DOMAIN_PLACEHOLDER|${J_TROJAN_DOMAIN:-}|g" "${functions_dir}/c.js"
  sed -i "s|J_HYSTERIA_DOMAIN_PLACEHOLDER|${J_HYSTERIA_DOMAIN:-}|g" "${functions_dir}/c.js"
  sed -i "s|TROJAN_DOMAIN_PLACEHOLDER|${TROJAN_DOMAIN}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_DOMAIN_PLACEHOLDER|${HYSTERIA_DOMAIN}|g" "${functions_dir}/c.js"
  sed -i "s|ISP2_TROJAN_PORT_PLACEHOLDER|${ISP2_TROJAN_PORT}|g" "${functions_dir}/c.js"
  sed -i "s|ISP2_HYSTERIA_PORT_PLACEHOLDER|${ISP2_HYSTERIA_PORT}|g" "${functions_dir}/c.js"
  sed -i "s|TROJAN_PORT_PLACEHOLDER|${TROJAN_PORT}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_PORT_PLACEHOLDER|${HYSTERIA_PORT}|g" "${functions_dir}/c.js"
  sed -i "s|TROJAN_PASSWORD_PLACEHOLDER|${TROJAN_PASSWORD}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_PASSWORD_PLACEHOLDER|${HYSTERIA_PASSWORD}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_OBFS_PLACEHOLDER|${HYSTERIA_OBFS_PASSWORD}|g" "${functions_dir}/c.js"
  sed -i "s|AI_ISP_DOMAINS_BASE64_PLACEHOLDER|${ai_isp_domains_base64}|g" "${functions_dir}/c.js"
  sed -i "s|DIRECT_BULK_DOMAINS_BASE64_PLACEHOLDER|${direct_bulk_domains_base64}|g" "${functions_dir}/c.js"
  sed -i "s|DIRECT_BULK_ENABLED_PLACEHOLDER|${direct_bulk_enabled_js}|g" "${functions_dir}/c.js"
  sed -i "s|CLASH_RULESET_BASE_URL_PLACEHOLDER|${CLASH_RULESET_BASE_URL%/}|g" "${functions_dir}/c.js"
  sed -i "s|HAS_PROXY2_PLACEHOLDER|$([[ ${HAS_PROXY2} -eq 1 ]] && echo true || echo false)|g" "${functions_dir}/c.js"
  sed -i "s|J_ENABLED_PLACEHOLDER|$([[ ${HAS_VPS_J} -eq 1 ]] && echo true || echo false)|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_UP_PLACEHOLDER|${HYSTERIA_UP_MBPS}|g" "${functions_dir}/c.js"
  sed -i "s|HYSTERIA_DOWN_PLACEHOLDER|${HYSTERIA_DOWN_MBPS}|g" "${functions_dir}/c.js"
  
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
REDIRECTS

  log_success "订阅配置文件已更新"

  # 检查 wrangler 是否安装
  if ! command -v wrangler &>/dev/null; then
    log_warn "wrangler CLI 未安装，跳过自动部署"
    log_info "手动部署命令: cd ${pages_dir} && wrangler pages deploy ."
    return 0
  fi

  log_info "开始部署到 Cloudflare Pages..."
  
  # 执行部署
  if (cd "$pages_dir" && GIT_OPTIONAL_LOCKS=0 CLOUDFLARE_API_TOKEN="${CF_API_TOKEN}" CLOUDFLARE_ACCOUNT_ID="${CF_ACCOUNT_ID}" wrangler pages deploy . --project-name="sub-converter" --branch=main 2>&1); then
    log_success "Cloudflare Pages 部署完成"
    log_info "订阅链接: https://${SUB_DOMAIN}/v2 (v2rayN)"
    log_info "订阅链接: https://${SUB_DOMAIN}/c (Clash)"
    
    # 验证订阅
    verify_subscription
  else
    log_error "Cloudflare Pages 部署失败"
    log_info "请手动执行: cd ${pages_dir} && wrangler pages deploy ."
  fi
}

main() {
  parse_args "$@"
  require_root
  require_supported_os
  load_env
  validate_config
  install_dependencies
  install_singbox
  prepare_dirs
  backup_existing_config
  generate_config
  validate_generated_config
  deploy_config
  setup_firewall
  restart_service
  setup_egress_monitor
  write_summary
  show_final_info
  
  # 自动更新并部署 Cloudflare Pages 订阅配置
  update_cloudflare_pages
}

main "$@"
