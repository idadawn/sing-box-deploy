# ========== 域名与证书 ==========
TROJAN_DOMAIN=trojan-j.yourdomain.com
HYSTERIA_DOMAIN=hy2-j.yourdomain.com
ACME_EMAIL=your_email@example.com

# Cloudflare DNS-01
CF_DNS_EDIT_TOKEN=your_cloudflare_dns_token
CF_ZONE_READ_TOKEN=your_cloudflare_zone_token

# ========== ISP SOCKS5 出口配置 ==========
PROXY_HOST=your_isp1_host
PROXY_PORT=443
PROXY_USER=your_isp1_user
PROXY_PASS=your_isp1_pass
PROXY2_HOST=your_isp2_host
PROXY2_PORT=443
PROXY2_USER=your_isp2_user
PROXY2_PASS=your_isp2_pass

# ========== 客户端认证 ==========
TROJAN_PASSWORD=your_trojan_password
HYSTERIA_PASSWORD=your_hy2_password
HYSTERIA_OBFS_PASSWORD=your_obfs_password

# ========== 端口 ==========
TROJAN_PORT=14687
HYSTERIA_PORT=19623

# ========== Hysteria2 带宽 ==========
HYSTERIA_UP_MBPS=100
HYSTERIA_DOWN_MBPS=100

# ========== URLTest ==========
URLTEST_URL=https://www.gstatic.com/generate_204
URLTEST_INTERVAL=3m
URLTEST_TOLERANCE=100

# ========== 出口模式 ==========
OUTBOUND_MODE=isp

# ========== 日志 ==========
LOG_LEVEL=info

# ========== 防火墙 ==========
ENABLE_UFW=true
SSH_PORT=22

# ========== Cloudflare Pages 订阅部署（J机建议留空）==========
CF_API_TOKEN=
CF_ACCOUNT_ID=
SUB_DOMAIN=dl.yourdomain.com
SUB_REMARKS=US-ISP

# ========== Clash 配置 ==========
SECRET=
HIDDEN_SUB_PATH=

# ========== 告警配置 ==========
SMTP_ALERT_ENABLED=false
SMTP_HOST=smtp.example.com
SMTP_PORT=465
SMTP_USER=
SMTP_PASS=
SMTP_FROM=
SMTP_TO=
PUSHPLUS_TOKEN=

# ----------------------------------------------------------
# 备用 VPS-J 配置（J机填T机的域名，实现双向备份）
# ----------------------------------------------------------
J_TROJAN_DOMAIN=trojan.yourdomain.com
J_HYSTERIA_DOMAIN=hy2.yourdomain.com
