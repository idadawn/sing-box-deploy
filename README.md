# sing-box 自动化部署方案

Debian / Ubuntu 一键部署 **Trojan + Hysteria2** 代理服务器，支持 `ISP-1`、可选 `ISP-2` 和 `VPS` 三类出口节点。Clash 订阅内置 `ISP-1 -> ISP-2 -> VPS` 自动容灾，v2rayN / v2rayNG 订阅同时提供 `ISP-1 / ISP-2 / VPS` 手动节点。订阅配置托管在 Cloudflare Pages。

## 架构概览

```
客户端 (v2rayN / Clash)
    │
    ├── ISP-1 / ISP-2 / VPS 手动节点
    └── Clash 自动容灾组：ISP-1 -> ISP-2 -> VPS
              │
         sing-box 服务端
              │
    ┌─────────┬─────────┬─────────┐
    │         │         │
 ISP-1     ISP-2      VPS
 SOCKS5    SOCKS5     直连
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
| `PROXY_HOST/PORT/USER/PASS` | ISP-1 SOCKS5 代理凭据 |
| `PROXY2_HOST/PORT/USER/PASS` | ISP-2 SOCKS5 代理凭据，可选，4 项需同时填写 |
| `TROJAN_PASSWORD` | Trojan 入站密码 |
| `HYSTERIA_PASSWORD` | Hysteria2 入站密码 |
| `CF_API_TOKEN` + `CF_ACCOUNT_ID` | Cloudflare Pages 部署凭据 |
| `SUB_DOMAIN` | 订阅托管域名 |
| `SMTP_ALERT_ENABLED` + `SMTP_*` | 可选，开启 ISP/VPS 出口异常邮件告警 |

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
6. 可选启用 systemd 定时出口监控与 SMTP 邮件告警

### 3. 客户端订阅

| 客户端 | 订阅链接 |
|--------|----------|
| v2rayN | `https://<SUB_DOMAIN>/v2` |
| Clash  | `https://<SUB_DOMAIN>/c`  |

- `Clash` 订阅内置自动容灾组，顺序为 `ISP-1 -> ISP-2 -> VPS`
- `v2rayN / v2rayNG` 订阅直接下发 `ISP-1-TJ`、`ISP-1-HY2`、`ISP-2-*`、`VPS-*` 节点，按需手动选择
- 服务端额外处理 `VPS` 节点访问 `Gemini / Google AI` 的流量：命中相关规则集后自动改走 ISP 出口

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

## 服务提供商参考

本方案在实际使用中采用了以下服务商（供参考，非强制要求）：

### VPS 提供商：极络云

本项目实际部署使用的 VPS 服务商。极络云提供性价比高的 CN2 GIA 线路，适合搭建代理服务器。

- 官网: https://www.jiluoyun.com/whmcs
- 推广链接: https://www.jiluoyun.com/whmcs/aff.php?aff=24 （支持本项目可使用此链接注册）

### ISP 代理：1024proxy

本项目实际使用的 ISP SOCKS5 代理服务商，提供稳定的住宅 IP 出口。

- 官网: https://1024proxy.com/
- 推广链接: https://api.1024proxy.com/share/7wstuqogm （支持本项目可使用此链接注册）

> 说明：以上链接为作者实际使用的服务商，推广链接仅供参考。您可以根据自己的需求选择其他服务商，本项目不依赖特定提供商。

## License

MIT
