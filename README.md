# sing-box 自动化部署方案

Debian / Ubuntu 一键部署 **Trojan + Hysteria2** 中继服务器。项目支持 `T` 与可选 `J` 两台海外服务器作为接入层，AI 与普通流量由 `ISP-1` 和可选 `ISP-2` SOCKS5 出口承担；也可只在 T 服务器启用视频/CDN/软件包下载直出。Clash 订阅内置 T/J 接入容灾、ISP 出口容灾，以及每日更新的 [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) 规则集。

## 架构概览

```
客户端 (v2rayN / Clash)
    │
    ├── T-ISP1 / T-ISP2 节点
    ├── J-ISP1 / J-ISP2 节点（可选，接入容灾）
    └── Clash 自动容灾组：T/J 中继 -> ISP-1/ISP-2 出口
              │
       T / J sing-box 接入服务器
              │
       ┌──────┴──────────┐
       │                 │
  AI / 普通流量      视频 / 大文件（可选）
       │                 │
  ISP-1 / ISP-2       当前服务器直出
     SOCKS5
```

## 前置要求

- Debian 10+ 或 Ubuntu 20.04+，root 权限
- 已购买 ISP SOCKS5 代理（如 1024proxy）
- Cloudflare 托管的域名，T 机至少两条 A 记录；如启用 J 机，再额外准备两条 J 机 A 记录（均为 DNS Only 灰云）
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
| `AI_ISP_DOMAINS` | 可选，始终走 ISP 自动出口的 AI 域名清单；留空使用内置清单 |
| `DIRECT_BULK_ENABLED` | 是否让视频/CDN/软件下载从当前服务器直出；建议仅 T 设置为 `true` |
| `DIRECT_BULK_DOMAINS` | 可选，直出域名清单；留空使用内置清单 |
| `CLASH_RULESET_BASE_URL` | 可选，客户端规则地址；留空使用 `https://<SUB_DOMAIN>/rules` 自托管镜像 |
| `CLASH_RULESET_UPSTREAM_REPO/BRANCH` | 可选，每日同步的上游仓库与分支，默认 Loyalsoldier `release` |
| `TROJAN_PASSWORD` | Trojan 入站密码 |
| `HYSTERIA_PASSWORD` | Hysteria2 入站密码 |
| `CF_API_TOKEN` + `CF_ACCOUNT_ID` | Cloudflare Pages 部署凭据 |
| `SUB_DOMAIN` | 订阅托管域名 |
| `SMTP_ALERT_ENABLED` + `SMTP_*` | 可选，开启中继服务与 ISP 出口异常邮件告警 |
| `J_TROJAN_DOMAIN/J_HYSTERIA_DOMAIN` | 可选，J 中继服务器入口域名；用于客户端接入容灾，不代表额外上网出口 |

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
6. 启用每日 Loyalsoldier 规则同步定时器
7. 可选启用 systemd 定时出口监控与 SMTP 邮件告警

### 3. 客户端订阅

| 客户端 | 订阅链接 |
|--------|----------|
| v2rayN | `https://<SUB_DOMAIN>/v2` |
| Clash  | `https://<SUB_DOMAIN>/c`  |
| Clash Verge 全局扩展脚本 | `https://<SUB_DOMAIN>/s` |

- `Clash` 订阅内置自动容灾组，默认在 `T-ISP1/T-ISP2` 与可选 `J-ISP1/J-ISP2` 中继节点之间自动切换
- `v2rayN / v2rayNG` 订阅直接下发 `T-ISP1-*`、`T-ISP2-*`、可选 `J-ISP1-*`、`J-ISP2-*` 节点，按需手动选择
- AI 域名在服务端优先匹配 `ai-out`，只会在 ISP-1/ISP-2 之间选择，不会落到服务器直出
- 如需同时使用任意第三方机场，将 `/s` 的内容粘贴到 Clash Verge 的全局扩展脚本。脚本会把原机场节点放入 `🛫 机场中转`，并让注入的 T/J 节点通过该组建立连接；机场不会成为网站最终出口
- `DIRECT_BULK_ENABLED=true` 时，仅内置或自定义的视频/CDN/软件下载域名使用当前服务器公网 IP；J 默认关闭该能力
- 服务端每天在北京时间 07:15 后同步 Loyalsoldier `release`，全部文件校验通过后才替换并发布；客户端通过 `rule-providers` 每天读取自托管镜像
- 自定义 AI 与 TX 大流量规则始终优先于上游通用规则
- Clash 订阅默认关闭 IPv6，并保留 Apple / iCloud 分流规则，以降低 iOS 推送异常和 IPv6 泄漏风险

### 服务端分流优先级

1. AI 域名优先匹配并发送到 `ai-out`，覆盖 OpenAI、Claude、Gemini、Copilot、DeepSeek、Perplexity、OpenRouter、Mistral、Groq、Cursor 等常用服务。
2. 启用高带宽直出后，YouTube、Twitch、Vimeo、Hugging Face、OneDrive/SharePoint，以及 Python、Node/npm、GitHub Releases、Docker、Rust、Go、Maven、Linux/Windows/macOS 更新等域名发送到 `direct-out`。
3. Netflix、Disney、Hulu 等依赖地区解锁的流媒体不在直出清单中，仍使用 ISP。
4. 其余客户端流量按入口发送到对应 ISP；`route.final` 保持 `block`，不存在通用 VPS 兜底。

AI 规则排在直出规则之前。例如 `copilot-proxy.githubusercontent.com` 即使同时命中 GitHub 下载域名，也仍会使用 ISP。两份域名清单都可通过 `.env` 覆盖。

Clash 客户端中的 `📦 TX 大流量` 组只包含 T 节点，确保上述下载流量先进入 T，再由服务端 `direct-out` 直出。Loyalsoldier 的 `proxy.txt` 本身包含 Hugging Face 和 OneDrive 域名，但本项目的自定义规则位于 `RULE-SET` 之前，因此不会被上游策略覆盖。

### Clash Verge 全局扩展脚本

1. 保留并启用任意机场订阅。
2. 打开 `https://<SUB_DOMAIN>/s`，将完整内容粘贴到 Clash Verge 的“全局扩展脚本”。
3. 保存并更新机场配置。页面会出现 `🛡️ ISP 最终出口`、`📦 TX 大流量` 和 `🛫 机场中转` 三个组。

脚本会自动接入同一套 Loyalsoldier 规则，并重写机场原有代理策略：AI、IP 检测和最终兜底使用 T/J -> ISP，视频和下载使用 T -> `direct-out`，局域网、中国大陆和上游 `direct` 规则仍在本机直连。`/s` 与 `/c` 一样包含节点凭据，请勿公开转发。

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

# 立即同步规则并发布（定时服务也执行这条命令）
sudo ./sync-clash-rules.sh --deploy

# 查看每日同步计划与日志
systemctl list-timers clash-rules-sync.timer
journalctl -u clash-rules-sync.service -n 100 --no-pager
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
├── sync-clash-rules.sh               # 上游规则原子同步与 Pages 发布
├── systemd/                           # 每日规则同步 service/timer 模板
├── manage.sh                         # 管理菜单
├── .env.example                      # 配置模板（复制为 .env 使用）
├── .env                              # 实际配置（已加入 .gitignore）
└── cloudflare-pages-sub/
    ├── functions/
    │   ├── v2.js                     # v2rayN 订阅（由 install.sh 生成）
    │   └── c.js                      # Clash 订阅（由 install.sh 生成）
    ├── global-extension.js           # Clash Verge 全局扩展脚本（由 install.sh 生成）
    ├── rules/                         # 已校验的 Loyalsoldier 快照（定时生成）
    ├── _redirects                    # 重定向规则（由 install.sh 生成）
    ├── index.html                    # Pages 占位页
    ├── wrangler.toml                 # Wrangler 配置
    └── package.json
```

## Cloudflare 配置要求

- `TROJAN_DOMAIN` 和 `HYSTERIA_DOMAIN` 必须是 **DNS Only（灰云）**
- 不能开启 Cloudflare 代理（橙云），否则 TLS 握手会失败
- A 记录分别指向 T/J 接入服务器的公网 IP；默认出口由 ISP SOCKS5 决定，只有显式启用的高带宽域名使用当前服务器直出

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

### 中继服务器提供商：极络云

本项目实际部署使用的海外中继服务器服务商。中继服务器主要用于承载 Trojan / Hysteria2 入站与转发流量，不建议作为 OpenAI / Claude 等高风控服务的最终出口。

- 官网: https://www.jiluoyun.com/whmcs
- 推广链接: https://www.jiluoyun.com/whmcs/aff.php?aff=24 （支持本项目可使用此链接注册）

### ISP 代理：1024proxy

本项目实际使用的 ISP SOCKS5 代理服务商，提供稳定的住宅 IP 出口。

- 官网: https://1024proxy.com/
- 推广链接: https://api.1024proxy.com/share/7wstuqogm （支持本项目可使用此链接注册）

> 说明：以上链接为作者实际使用的服务商，推广链接仅供参考。您可以根据自己的需求选择其他服务商，本项目不依赖特定提供商。

## License

MIT
