#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# SSH 免密登录配置脚本
# 用法: bash setup-ssh.sh [别名] [IP/域名] [用户名] [端口]
# 默认: bash setup-ssh.sh j 66.6.58.72 root 22
# =========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERR]${NC} $*" >&2; }

# 参数解析（带默认值）
HOST_ALIAS="${1:-j}"
HOST_IP="${2:-66.6.58.72}"
HOST_USER="${3:-root}"
HOST_PORT="${4:-22}"

SSH_DIR="${HOME}/.ssh"
KEY_FILE="${SSH_DIR}/id_ed25519"
CONFIG_FILE="${SSH_DIR}/config"

# 检查依赖
if ! command -v ssh-keygen &>/dev/null; then
  log_err "未找到 ssh-keygen，请先安装 openssh-client"
  exit 1
fi

# 创建 ~/.ssh 目录
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

# 生成密钥对（如果不存在）
if [[ -f "${KEY_FILE}" ]]; then
  log_warn "SSH 密钥已存在: ${KEY_FILE}"
else
  log_info "生成 SSH ed25519 密钥对..."
  ssh-keygen -t ed25519 -C "${HOST_ALIAS}-${HOST_IP}" -f "${KEY_FILE}" -N ""
  log_ok "密钥已生成"
fi

# 配置 ~/.ssh/config
if [[ -f "${CONFIG_FILE}" ]] && grep -qE "^Host\s+${HOST_ALIAS}\b" "${CONFIG_FILE}"; then
  log_warn "SSH config 中已存在 Host ${HOST_ALIAS}"
  read -rp "是否覆盖? [y/N]: " confirm
  if [[ "${confirm}" =~ ^[Yy]$ ]]; then
    # 删除旧配置块
    awk -v alias="${HOST_ALIAS}" '
      /^Host\s+/ { in_block = ($2 == alias) }
      !in_block { print }
    ' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
  else
    log_info "跳过 config 配置"
    exit 0
  fi
fi

log_info "写入 SSH config..."
cat >> "${CONFIG_FILE}" <<EOF

Host ${HOST_ALIAS}
    HostName ${HOST_IP}
    User ${HOST_USER}
    Port ${HOST_PORT}
    IdentityFile ${KEY_FILE}
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
chmod 600 "${CONFIG_FILE}"
log_ok "SSH config 已更新"

# 复制公钥到目标机器
echo
log_info "正在复制公钥到 ${HOST_USER}@${HOST_IP}:${HOST_PORT} ..."
log_info "请输入目标机器的密码:"
if ssh-copy-id -i "${KEY_FILE}.pub" -p "${HOST_PORT}" "${HOST_USER}@${HOST_IP}"; then
  log_ok "公钥复制成功！"
else
  log_err "公钥复制失败，请手动执行:"
  echo "  ssh-copy-id -i ${KEY_FILE}.pub -p ${HOST_PORT} ${HOST_USER}@${HOST_IP}"
  exit 1
fi

# 测试连接
echo
log_info "测试连接: ssh ${HOST_ALIAS} ..."
if ssh -o BatchMode=yes "${HOST_ALIAS}" "echo 'SSH OK from \$(hostname)'"; then
  log_ok "配置完成！以后可直接使用: ssh ${HOST_ALIAS}"
else
  log_warn "连接测试失败，请检查目标机器配置"
fi
