#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
CONFIG_PATH="/etc/sing-box/config.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERR]${NC} $*"; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

load_env_safe() {
    [[ -f "$ENV_FILE" ]] || return 0

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line key value
        line="$(trim "$raw_line")"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            continue
        fi

        key="${line%%=*}"
        value="${line#*=}"

        key="$(trim "$key")"
        value="$(trim "$value")"

        if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:-1}"
            value="${value//\\n/$'\n'}"
            value="${value//\\\\/\\}"
        elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:-1}"
        fi

        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$ENV_FILE"
}

show_menu() {
    echo
    echo "========================================"
    echo "sing-box 管理菜单"
    echo "========================================"
    echo "1. 查看服务状态"
    echo "2. 查看实时日志"
    echo "3. 重启服务"
    echo "4. 查看本机直连出口 IP"
    echo "5. 测试 1024proxy SOCKS5 出口"
    echo "6. 检查配置文件语法"
    echo "7. 备份配置"
    echo "8. 卸载 sing-box"
    echo "0. 退出"
    echo "========================================"
}

view_status() {
    load_env_safe
    echo -e "${BLUE}服务状态:${NC}"
    systemctl status sing-box --no-pager || true
    echo
    echo -e "${BLUE}监听端口:${NC}"
    local trojan_port="${TROJAN_PORT:-443}"
    local hysteria_port="${HYSTERIA_PORT:-8443}"
    ss -tulnp | grep -E ":${trojan_port}|:${hysteria_port}" || echo "未找到 ${trojan_port}/${hysteria_port} 监听"
}

view_logs() {
    echo -e "${BLUE}按 Ctrl+C 退出日志查看${NC}"
    journalctl -u sing-box -f
}

restart_service() {
    echo -e "${YELLOW}重启 sing-box...${NC}"
    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}重启成功${NC}"
    else
        echo -e "${RED}重启失败${NC}"
        journalctl -u sing-box --no-pager -n 30 || true
    fi
}

check_direct_ip() {
    echo -e "${BLUE}检查本机直连出口...${NC}"
    local ip
    ip="$(curl -s --max-time 8 https://ipinfo.io/ip 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
        echo -e "${GREEN}本机直连正常${NC} - IP: $ip"
    else
        echo -e "${RED}本机直连失败${NC}"
    fi
}

check_proxy_ip() {
    load_env_safe

    if [[ -z "${PROXY_HOST:-}" || -z "${PROXY_PORT:-}" || -z "${PROXY_USER:-}" || -z "${PROXY_PASS:-}" ]]; then
        echo -e "${RED}.env 中缺少 PROXY_HOST/PROXY_PORT/PROXY_USER/PROXY_PASS${NC}"
        return 1
    fi

    echo -e "${BLUE}测试 1024proxy SOCKS5 出口...${NC}"
    local ip
    ip="$(curl -s --max-time 10 --proxy "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}" https://ipinfo.io/ip 2>/dev/null || true)"
    if [[ -n "$ip" ]]; then
        echo -e "${GREEN}ISP 代理正常${NC} - IP: $ip"
    else
        echo -e "${RED}ISP 代理连接失败${NC}"
    fi
}

check_config() {
    echo -e "${BLUE}检查 sing-box 配置语法...${NC}"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -e "${RED}未找到配置文件: ${CONFIG_PATH}${NC}"
        return 1
    fi

    if sing-box check -c "$CONFIG_PATH"; then
        echo -e "${GREEN}配置语法正常${NC}"
    else
        echo -e "${RED}配置语法异常${NC}"
    fi
}

backup_config() {
    local backup_dir="${SCRIPT_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    cp "$CONFIG_PATH" "$backup_dir/" 2>/dev/null || true
    cp "${SCRIPT_DIR}/.env" "$backup_dir/" 2>/dev/null || true
    cp "${SCRIPT_DIR}/deploy-summary.txt" "$backup_dir/" 2>/dev/null || true

    tar czf "${backup_dir}.tar.gz" -C "$backup_dir" .
    rm -rf "$backup_dir"

    echo -e "${GREEN}备份已保存: ${backup_dir}.tar.gz${NC}"
}

uninstall_singbox() {
    echo -e "${RED}警告：这将卸载 sing-box，并删除 /etc/sing-box 与 /var/lib/sing-box${NC}"
    read -rp "确认卸载? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        backup_config
        systemctl stop sing-box || true
        systemctl disable sing-box || true
        apt-get remove -y sing-box || true
        rm -rf /etc/sing-box /var/lib/sing-box
        echo -e "${GREEN}卸载完成${NC}"
    fi
}

while true; do
    show_menu
    read -rp "请选择 [0-8]: " choice

    case "$choice" in
        1) view_status ;;
        2) view_logs ;;
        3) restart_service ;;
        4) check_direct_ip ;;
        5) check_proxy_ip ;;
        6) check_config ;;
        7) backup_config ;;
        8) uninstall_singbox ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
done