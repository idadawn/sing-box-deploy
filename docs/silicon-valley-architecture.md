# 硅谷 TX 服务器架构

## 目标

硅谷服务器 `43.162.81.53` 是唯一接入数据面。东京服务器已完成迁移并正式
下线。客户端继续使用原有订阅 URL，刷新订阅后获取硅谷专用入口域名，避免
逐台手工修改节点。

- Trojan：`tj.1761.org`
- Hysteria2：`hy.1761.org`

东京原入口域名 `trojan.1761.org`、`hy2.1761.org` 已删除，不再提供旧入口。

核心约束：

- 一个入站编号只映射一个 ISP SOCKS5 出口。
- ISP 不可用时失败关闭，不跨 ISP，也不回落到服务器公网。
- 只有明确列入大流量直出规则的目标可以使用服务器公网。
- 所有 ISP 预检、配置校验、端口验证通过后才能切 DNS。
- Cloudflare Pages 是订阅控制面，不承载代理流量。

## 分层

```text
客户端
  │
  ├─ HTTPS ──> Cloudflare Pages：订阅、规则、首页
  │
  ├─ Trojan/TCP ─────┐
  └─ Hysteria2/UDP ──┴─> 硅谷 sing-box 数据面
                            │
                            ├─ ds-1 ─> 固定 ISP SOCKS5
                            ├─ ds-2 ─> 固定 ISP SOCKS5
                            ├─ ds-3 ─> 固定 ISP SOCKS5
                            └─ dawn ─> 固定 ISP SOCKS5
```

数据面使用 Ubuntu 原生 sing-box 与 systemd，不增加 Docker、反向代理或集群层。
在当前单机、4GB 内存规模下，这能减少 UDP 转发层数、故障面和证书管理复杂度。

## 端口与路由

| 编号 | Trojan/TCP | Hysteria2/UDP |
| --- | ---: | ---: |
| ds-2 | 14687 | 19623 |
| ds-1 | 24687 | 29623 |
| ds-3 | 34687 | 39623 |
| dawn | 44687 | 49623 |

行槽位与端口保持不变，编号改名不会改变现有端口。路由最终规则保持
`route.final=block`。

## 控制面与数据面

- `install.sh --skip-pages`：只部署数据面，适合迁移预发布。
- 完整 `install.sh`：数据面验证通过后发布 Pages 并接管规则同步定时器。
- ISP SOCKS5 预检默认开启，任何一个出口失败都会在写入正式配置前停止。
- `--skip-egress-preflight` 仅允许在不切 DNS 的受控预发布中使用。
- sing-box 由 systemd 自动恢复，并设置高文件句柄上限。

## 公司内网

硅谷机通过 `wg-quick@us` 接入公司 WireGuard：

- 隧道地址：`10.77.0.7/32`
- 隧道路由：`10.77.0.0/24`、`10.78.1.0/24`
- qd：`10.78.1.161`

WireGuard 不接管默认路由，硅谷公网出口仍为 `43.162.81.53`。公司内网统一
使用 `10.78.1.x` 地址访问。

## 安全基线

- SSH 只允许密钥认证，禁用 root 登录和交互式密码认证。
- UFW 默认拒绝入站，只开放 SSH、四组 Trojan/TCP 和 Hysteria2/UDP。
- 私钥、`.env`、ISP 清单和迁移包权限为 `600`，不进入 Git。
- 自动安全更新保持启用。
- BBR/fq、TCP Fast Open 和 16 MiB UDP 缓冲由安装脚本管理。

## 迁移验收门禁

Pages 订阅发布为 `tj.1761.org` 与 `hy.1761.org` 前必须同时满足：

1. 四个 ISP 从硅谷机预检全部成功。
2. sing-box 配置校验成功且服务稳定运行。
3. 八个入口均监听，UFW 与云安全组均放行。
4. 使用新 IP 绕过 DNS，真实验证 Trojan、Hysteria2 与对应出口。
5. Cloudflare Pages 订阅仍返回正确编号、端口和到期日。

上述门禁已经全部通过。两个硅谷域名均独立解析到 `43.162.81.53`，本地 `tx`
SSH 别名、出口监控和规则同步定时器均由硅谷机接管。

## 东京下线记录

- `ds-1`、`ds-2`、`ds-3`、`dawn` 的 SOCKS5 出口均已从硅谷验证。
- `dawn` 存在单服务器占用限制，已从东京释放并由硅谷独占。
- 8 个 Trojan/Hysteria2 入口和 4 组独立订阅均已验证。
- 公开订阅不包含东京 IP 或东京旧域名。
- 东京 COS 挂载为空且无业务依赖，不需要迁移。
- 东京最终配置归档保存在硅谷
  `/home/ubuntu/migration-backups/tokyo-final-*.tar.gz`，权限为 `600`。
- 东京旧 DNS 已删除，东京服务器已关机，本机不再保留 `tx-tokyo` SSH 别名。

如需恢复历史配置，应先从归档中核对 `.env`、ISP 清单和 systemd 配置，再按
当前门禁重新验证；不得直接恢复旧 DNS 或重新启用东京规则同步定时器。
