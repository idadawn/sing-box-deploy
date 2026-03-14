# sing-box 自动化部署方案

Debian / Ubuntu 一键部署 **Trojan + Hysteria2** 双入站代理服务器，主出口走 ISP SOCKS5，备出口走 VPS 直连，URLTest 自动故障切换。订阅配置托管在 Cloudflare Pages。

## 架构概览

```
客户端 (v2rayN / Clash)
    │
    ├── Trojan  TCP:443   (tj.yourdomain.com)
    └── Hysteria2 UDP:8443 (hy2.yourdomain.com)
              │
         sing-box 服务端
              │
         URLTest 自动切换（每 3 分钟探测）
              │
    ┌─────────┴─────────┐
    │                   │
 ISP SOCKS5 出口      VPS 直连出口
  (isp-out)           (direct-out)
```

## 前置要求

- Debian 10+ 或 Ubuntu 20.04+，root 权限
- 已购买 ISP SOCKS5 代理（如 1024proxy）
- Cloudflare 托管的域名，两条 A 记录（DNS Only 灰云）
- Cloudflare API Token（Zone:DNS:Edit 权限）

## 快速开始

### 1. 克隆并配置

```bash
git clone https://github.com/yourname/sing-box-deploy.git
cd sing-box-deploy
cp .env.example .env
nano .env   # 填写所有必填项
```

`.env` 中的关键变量：

| 变量 | 说明 |
|------|------|
| `TROJAN_DOMAIN` | Trojan 入口域名（灰云 A 记录） |
| `HYSTERIA_DOMAIN` | Hysteria2 入口域名（灰云 A 记录） |
| `CF_DNS_EDIT_TOKEN` | Cloudflare DNS:Edit Token（申请证书用） |
| `ACME_EMAIL` | Let's Encrypt 注册邮箱 |
| `PROXY_HOST/PORT/USER/PASS` | ISP SOCKS5 代理凭据 |
| `TROJAN_PASSWORD` | Trojan 入站密码 |
| `HYSTERIA_PASSWORD` | Hysteria2 入站密码 |
| `CF_API_TOKEN` + `CF_ACCOUNT_ID` | Cloudflare Pages 部署凭据 |
| `SUB_DOMAIN` | 订阅托管域名 |

### 2. 部署

```bash
chmod +x install.sh
sudo ./install.sh
```

脚本将自动完成：

1. 安装 sing-box（官方 APT 仓库）
2. 申请 TLS 证书（Let's Encrypt DNS-01）
3. 生成并部署 `/etc/sing-box/config.json`
4. 配置 UFW 防火墙
5. 生成订阅文件并部署到 Cloudflare Pages

### 3. 客户端订阅

| 客户端 | 订阅链接 |
|--------|----------|
| v2rayN | `https://<SUB_DOMAIN>/v2` |
| Clash  | `https://<SUB_DOMAIN>/c`  |

### 4. 管理

```bash
./manage.sh   # 交互式管理菜单
```

菜单选项：状态查看、日志追踪、服务重启、出口 IP 测试、配置检查、备份、卸载。

## 常用命令

```bash
# 检查服务状态
systemctl status sing-box

# 实时日志
journalctl -u sing-box -f

# 验证配置语法
sing-box check -c /etc/sing-box/config.json

# 测试 ISP SOCKS5 出口 IP
curl --socks5 USER:PASS@HOST:PORT https://ipinfo.io/ip

# 手动部署 Cloudflare Pages 订阅
cd cloudflare-pages-sub && wrangler pages deploy .
```

## 安装选项

```bash
sudo ./install.sh                    # 完整部署
sudo ./install.sh --force-reinstall  # 强制重装 sing-box 包
sudo ./install.sh --skip-firewall    # 跳过 UFW 配置
sudo ./install.sh --no-start         # 仅部署配置，不启动服务
```

## 目录结构

```
sing-box-deploy/
├── install.sh                        # 主部署脚本
├── manage.sh                         # 管理菜单
├── .env.example                      # 配置模板（复制为 .env 使用）
├── .env                              # 实际配置（已加入 .gitignore）
└── cloudflare-pages-sub/
    ├── functions/
    │   ├── v2.js                     # v2rayN 订阅（由 install.sh 生成）
    │   └── c.js                      # Clash 订阅（由 install.sh 生成）
    ├── _redirects                    # 重定向规则（由 install.sh 生成）
    ├── index.html                    # Pages 占位页
    ├── wrangler.toml                 # Wrangler 配置
    └── package.json
```

## Cloudflare 配置要求

- `TROJAN_DOMAIN` 和 `HYSTERIA_DOMAIN` 必须是 **DNS Only（灰云）**
- 不能开启 Cloudflare 代理（橙云），否则 TLS 握手会失败
- A 记录指向 VPS 的公网 IP

## 证书说明

- 使用 Let's Encrypt + Cloudflare DNS-01 挑战自动申请
- 证书保存在 `/var/lib/sing-box/certmagic/`，自动续期

## 故障排查

```bash
# 查看日志
journalctl -u sing-box -f

# 检查配置语法
sing-box check -c /etc/sing-box/config.json

# 检查端口监听
ss -tulnp | grep -E ':443|:8443'
```

## 卸载

```bash
./manage.sh   # 选择选项 8
```

## License

MIT
