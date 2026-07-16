# sing-box 多 ISP 固定出口部署

在 Debian / Ubuntu 上部署一台 sing-box 接入服务器，并把不同入口固定映射到私有 ISP SOCKS5 出口。每个未到期的 ISP 条目会生成一组 Trojan、Hysteria2 节点和独立订阅，适合需要稳定、可识别出口且不允许静默跨 ISP 回落的个人环境。

本仓库是纯技术实现，不绑定、推荐或推广任何服务器、代理或网络服务提供商。

> 当前只维护 `T` 接入服务器。旧 `J` 服务器已经退役，安装脚本会拒绝残留的 `J_*` 配置。

## 设计目标

- 一个 ISP 编号对应一个固定出口，不在不同 ISP 之间自动切换。
- 同时提供 Trojan/TCP 与 Hysteria2/UDP，覆盖不同网络条件。
- 默认失败关闭：未命中明确规则的服务端流量由 `route.final=block` 拒绝。
- ISP 地址、账号和密码只保存在服务器本地私有 TSV 文件中。
- 自动生成 v2rayN/v2rayNG 与 Clash/Mihomo 订阅，并发布到 Cloudflare Pages。
- 自动同步并校验 Clash 规则快照，失败时继续使用上一版。
- 支持出口健康检查、systemd 定时任务和可选 SMTP 告警。

## 架构

```text
v2rayN / v2rayNG / Clash / Mihomo
                │
      ┌─────────┴─────────┐
      │                   │
Trojan/TCP           Hysteria2/UDP
      │                   │
      └─────────┬─────────┘
                │
         T sing-box 接入服务器
                │
      ┌─────────┴────────────┐
      │                      │
AI 与普通流量          指定的大流量域名
      │                      │
当前订阅对应 ISP        T 公网直出（可选）
   SOCKS5
```

每个 ISP 条目生成两个客户端节点：

- `T-<编号>-TJ`
- `T-<编号>-HY2`

两个节点只代表不同的接入协议，服务端最终出口相同。

## 能力边界

本方案提供固定出口、订阅生成和基础自动运维，但不等同于完整的高可用平台：

- T 是唯一接入服务器，服务器、机房或上游网络故障会影响全部节点。
- ISP 故障时默认不会切换到另一个 ISP，也不会回落到 T 公网出口。
- Cloudflare Pages 只负责订阅和规则文件分发，不承载 Trojan/Hysteria2 流量。
- 当前 Trojan、Hysteria2 和混淆密码分别按协议全局共享；任一同协议订阅泄漏后需要轮换该协议的全部节点。
- 首页隐藏某个编号只影响页面展示，不是访问控制；知道订阅 URL 的人仍可请求该订阅。
- `/v2`、`/c` 与 `/s` 的响应包含客户端节点凭据，必须按敏感信息管理。

## 前置条件

- Debian 10+ 或 Ubuntu 20.04+。
- root 或 sudo 权限。
- 一台具有公网 IPv4 的接入服务器。
- 至少一个可用的 ISP SOCKS5 出口。
- 由 Cloudflare 托管的域名。
- 两个指向接入服务器的 DNS Only A 记录，分别用于 Trojan 和 Hysteria2。
- 用于 DNS-01 证书签发的 Cloudflare DNS API Token。
- 如需自动发布订阅，还需 Cloudflare Pages 项目、Account ID 与 Pages API Token。

云平台安全组和服务器防火墙必须同时放行实际使用的 TCP、UDP 入站端口。

## 快速部署

```bash
git clone https://github.com/idadawn/sing-box-deploy.git
cd sing-box-deploy

cp .env.example .env
cp isp-list.example.tsv isp-list.tsv

chmod 600 .env isp-list.tsv
nano .env
nano isp-list.tsv

chmod +x install.sh manage.sh sync-clash-rules.sh
sudo ./install.sh
```

安装脚本会完成：

1. 安装或更新 sing-box 及基础依赖。
2. 通过 Cloudflare DNS-01 申请 TLS 证书。
3. 根据 ISP 清单生成 `/etc/sing-box/config.json`。
4. 校验配置并部署 systemd 服务。
5. 按配置更新 UFW。
6. 生成订阅、首页、Clash 扩展脚本和规则镜像。
7. 发布 Cloudflare Pages。
8. 安装规则同步与可选出口监控定时器。

## ISP 清单

`ISP_LIST_FILE` 指向一个 7 列 TSV 文件：

```text
编号	IP	HTTP端口	SOCKS5端口	user	pwd	到期时间
demo	203.0.113.10	3128	1080	example-user	example-password	2026-12-31
```

约束：

- 列顺序固定，字段之间使用 Tab。
- 文件权限必须是 `600`。
- 文件已加入 `.gitignore`，不得提交到 Git。
- 编号只能使用脚本允许的安全字符，并且必须唯一。
- 行顺序决定入站端口槽位；不要随意重排或删除旧行。
- 已到期条目不会进入运行配置，订阅接口会对未知或过期编号返回 HTTP 410。

后续条目的端口计算方式：

```text
Trojan 端口    = TROJAN_PORT + 行槽位 × ISP_PORT_STEP
Hysteria2 端口 = HYSTERIA_PORT + 行槽位 × ISP_PORT_STEP
```

## 核心配置

### 接入与证书

| 变量 | 用途 |
| --- | --- |
| `TROJAN_DOMAIN` | Trojan 入口域名，必须使用 DNS Only |
| `HYSTERIA_DOMAIN` | Hysteria2 入口域名，必须使用 DNS Only |
| `TROJAN_PORT` | 第一条 ISP 的 Trojan 端口 |
| `HYSTERIA_PORT` | 第一条 ISP 的 Hysteria2 端口 |
| `ISP_PORT_STEP` | 后续 ISP 的端口偏移 |
| `CF_DNS_EDIT_TOKEN` | DNS-01 证书签发所需 Token |
| `ACME_EMAIL` | ACME 注册邮箱 |

### 认证与出口

| 变量 | 用途 |
| --- | --- |
| `ISP_LIST_FILE` | 私有 ISP TSV 清单路径 |
| `TROJAN_PASSWORD` | Trojan 入站密码 |
| `HYSTERIA_PASSWORD` | Hysteria2 入站密码 |
| `HYSTERIA_OBFS_PASSWORD` | Hysteria2 Salamander 混淆密码 |
| `AI_ISP_DOMAINS` | 必须走当前 ISP 的 AI 域名，留空使用内置清单 |
| `DIRECT_BULK_ENABLED` | 是否允许指定大流量域名从 T 公网直出 |
| `DIRECT_BULK_DOMAINS` | 自定义大流量直出域名 |

### 订阅与规则

| 变量 | 用途 |
| --- | --- |
| `SUB_DOMAIN` | Pages 订阅域名 |
| `CF_ACCOUNT_ID` | Cloudflare Account ID |
| `CF_API_TOKEN` | Pages 部署 Token |
| `CF_PAGES_PROJECT` | Pages 项目名 |
| `CLASH_RULESET_BASE_URL` | Clash 规则地址，留空使用当前 Pages 镜像 |
| `CLASH_RULESET_UPSTREAM_REPO` | 规则上游仓库 |
| `CLASH_RULESET_UPSTREAM_BRANCH` | 规则上游分支 |

### 运维

| 变量 | 用途 |
| --- | --- |
| `ENABLE_UFW` | 是否由脚本维护 UFW |
| `SSH_PORT` | 需要保留的 SSH 端口 |
| `LOG_LEVEL` | sing-box 日志级别 |
| `SMTP_ALERT_ENABLED` | 是否启用出口异常邮件告警 |
| `SMTP_*` | SMTP 连接与收件配置 |

完整字段和默认值见 [`.env.example`](.env.example)。

## 路由语义

| 流量 | 服务端出口 |
| --- | --- |
| AI 域名 | 当前入口绑定的 ISP SOCKS5 |
| 普通互联网流量 | 当前入口绑定的 ISP SOCKS5 |
| 指定大流量域名 | `DIRECT_BULK_ENABLED=true` 时使用 T 公网直出 |
| 未匹配或异常流量 | `block` |

关键原则：

- AI 规则优先于大流量直出规则。
- 不会从当前 ISP 静默切换到其他 ISP。
- 不会把 T 公网 IP 当作通用兜底出口。
- 只有显式列入大流量规则的域名可以使用 `direct-out`。
- 对出口一致性要求最高时，应保持 `DIRECT_BULK_ENABLED=false`。

## 订阅

| 类型 | URL |
| --- | --- |
| v2rayN/v2rayNG 全量订阅 | `https://<SUB_DOMAIN>/v2` |
| Clash/Mihomo 全量订阅 | `https://<SUB_DOMAIN>/c` |
| 单 ISP v2rayN/v2rayNG | `https://<SUB_DOMAIN>/v2?isp=<编号>` |
| 单 ISP Clash/Mihomo | `https://<SUB_DOMAIN>/c?isp=<编号>` |
| Clash Verge 全局扩展脚本 | `https://<SUB_DOMAIN>/s` |

单 ISP 订阅只返回该编号的 Trojan 与 Hysteria2 节点。Clash 响应使用以下响应头保持客户端显示名稳定：

```text
Profile-Title: <编号>
Content-Disposition: attachment; filename=<编号>
```

`filename` 不添加引号和 `.yaml` 后缀，以兼容采用不同响应头解析方式的客户端。

### 首页可见性

首页读取部署时生成的 `subscriptions.json`。该文件只包含编号、到期时间和订阅路径，不包含 ISP 地址、账号或密码。

`cloudflare-pages-sub/index.html` 中的 `homepageHiddenIds` 可以隐藏私用编号。此设置只隐藏首页列表和详情，不会阻止 `/v2?isp=<编号>` 或 `/c?isp=<编号>` 访问。需要真正限制访问时，应在 Pages Functions 中增加令牌校验。

### Clash Verge 全局扩展脚本

`/s` 用于把本项目节点和规则接入已有 Clash 配置。扩展脚本会保留原配置节点，并增加固定 ISP 出口、大流量直出和中转策略组。

`/s` 同样含有节点凭据，不应公开转发。

## 规则同步

`clash-rules-sync.timer` 每天触发一次同步：

1. 拉取指定上游分支。
2. 校验所需规则文件完整性。
3. 只有全部检查成功才原子替换当前快照。
4. 重新发布 Cloudflare Pages。
5. 同步失败时保留上一版可用规则。

手动执行：

```bash
sudo ./sync-clash-rules.sh --deploy
systemctl list-timers clash-rules-sync.timer
journalctl -u clash-rules-sync.service -n 100 --no-pager
```

## 运维

### 管理菜单

```bash
sudo ./manage.sh
```

支持查看状态、追踪日志、重启服务、检查配置、测试 ISP 出口、管理备份和卸载。

### 常用命令

```bash
# 服务状态
systemctl status sing-box

# 实时日志
journalctl -u sing-box -f

# 配置校验
sing-box check -c /etc/sing-box/config.json

# 当前监听端口
ss -tulnp | grep sing-box

# 出口监控
systemctl status sing-box-egress-monitor.timer
journalctl -u sing-box-egress-monitor.service -n 100 --no-pager

# 规则同步
systemctl status clash-rules-sync.timer
journalctl -u clash-rules-sync.service -n 100 --no-pager
```

### 安装选项

```bash
sudo ./install.sh
sudo ./install.sh --force-reinstall
sudo ./install.sh --skip-firewall
sudo ./install.sh --no-start
```

## 安全清单

- `.env` 与 `isp-list.tsv` 使用 `600` 权限。
- 不在 Git、Issue、日志或聊天中粘贴真实 ISP 凭据。
- 为 Trojan、Hysteria2、混淆、Clash Controller 和订阅访问使用不同密钥。
- Cloudflare Token 只授予所需账户、Zone 和最小权限。
- 定期轮换入口密码与 Pages 部署 Token。
- 不把首页隐藏、随机路径或难猜 URL 当作身份认证。
- 订阅泄漏后应轮换入口凭据，而不是只更换订阅 URL。
- 保留 `route.final=block`，除非明确接受未知流量的出口变化。
- 在云安全组和 UFW 中只开放当前配置使用的端口。

## 故障排查

### 客户端无法连接

```bash
systemctl is-active sing-box
sing-box check -c /etc/sing-box/config.json
ss -tulnp | grep sing-box
ufw status numbered
```

同时检查云平台安全组、DNS 解析、TLS 域名和客户端系统时间。Trojan 使用 TCP，Hysteria2 使用 UDP，两类规则需要分别放行。

### 节点可连接但出口错误

```bash
sudo ./manage.sh
journalctl -u sing-box-egress-monitor.service -n 100 --no-pager
```

确认 ISP 清单行顺序未改变，SOCKS5 账号仍有效，并检查 `/etc/sing-box/config.json` 中入口到 `isp-out-<编号>` 的映射。

### 订阅更新失败

```bash
curl -I 'https://<SUB_DOMAIN>/c?isp=<编号>'
curl -I 'https://<SUB_DOMAIN>/v2?isp=<编号>'
journalctl -u clash-rules-sync.service -n 100 --no-pager
```

未知或过期编号返回 HTTP 410。Pages 发布成功但自定义域名仍是旧页面时，需要等待边缘缓存刷新。

## 目录结构

```text
sing-box-deploy/
├── install.sh
├── manage.sh
├── sync-clash-rules.sh
├── setup-ssh.sh
├── .env.example
├── isp-list.example.tsv
├── systemd/
│   ├── clash-rules-sync.service.in
│   └── clash-rules-sync.timer
└── cloudflare-pages-sub/
    ├── functions/             # 部署时生成，不进入 Git
    ├── rules/                 # 同步生成的规则快照
    ├── index.html
    ├── global-extension.js    # 部署时生成
    ├── subscriptions.json     # 部署时生成
    ├── wrangler.toml
    └── README.md
```

## License

MIT
