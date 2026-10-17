# 流量额度与计量

## 已确认规则

| 项目 | 规则 |
| --- | --- |
| 个人 ISP | 每个账号每月 100 GB，多条获授权 ISP 合并计算 |
| 公共额度 | 整机每月共用 1000 GB，已经包含个人 ISP 消耗和视频、下载等直出流量 |
| 计量方向 | 上传 + 下载，1 GB = 1,000,000,000 字节 |
| 账期 | UTC 自然月，每月 1 日 00:00 重置 |
| 超额 | 页面提醒，不停止代理、不拒绝订阅更新 |
| 金额 | 本功能仅管理流量，没有价格、充值、扣款或支付 |

网站自然月额度与云厂商账期可能不同，也不替代 KiwiVM 的账单、剩余套餐流量。供应商计费以其平台为准。

## 数据来源

- **整机公共额度**：读取公网物理网卡（LA 为 `eth0`）的 `tx_bytes + rx_bytes`。包含代理两段传输、隧道和管理等其他整机流量；不会把个人计数再加一遍。
- **个人 ISP 额度**：sing-box V2Ray API 中对应 `isp-out-<id>` 的 outbound uplink/downlink 计数，统计代理载荷。个人入口里被规则送到 `direct-out` 的视频等流量不扣个人 ISP 额度。
- 用户页面只返回其账号授权范围内的个人合计，以及大家共用的整机合计，不返回他人的明细。
- 没有数据时显示 `— / 100 GB` 或 `— / 1000 GB` 和“待接入”；不会用假零、随机数据或整机总量冒充个人用量。

两个统计口径不同：个人是代理载荷，公共是网卡双向字节（含封装与两段转发），不能简单相加。网卡统计与云厂商账单也可能有边界和封装差异。

## 采集器与账本

`collector.py` 使用 Python 标准库读网卡、调用 `grpcurl` 只读查询 sing-box（`reset=false`），在本机 SQLite 持久保存原始基线、UTC 月累计量和待发送报告。每分钟采样一次。

- 首次接入只建立当前基线，过去流量不能反推；当月标注“部分统计”。
- 采集器重启保留基线和累计值。系统或 sing-box 重启后继续记录已知的新计数，并标记可能遗漏的旧进程尾段。
- 数据按采样结束时间归属月份，正常月界最多有一个采样间隔的误差；长时间中断且跨月时不臆测分摊，改为新的部分基线。
- 未取得某条 ISP 计数时不补零，也不把旧数据的时间刷新成当前时间。
- 每月一条待发送累计快照，断网时保留。报告经独立 `SUB_METER_KEY` HMAC 签名和时间戳验证；重试、重放和乱序不会重复累计或回退已记录的总量。
- 采集账本具有持久化代次标识；同一月份发现新代次时拒绝接收，避免账本丢失后把新零基线覆盖成“统计正常”。须恢复原账本或经核验的人工迁移后继续。
- 页面和客户端只在当月统计完整且新鲜时展示可信剩余额度；不完整、过期或不可用时标注状态，并移除会误报 0 用量的 `Subscription-Userinfo`。正常订阅更新仍保留。
- 页面超额提醒基于已知用量。没有任何停用账号、修改路由或限制网速的代码。

## gw 隔离测试部署

2026-10-17 起，真实计量只向 `gw.1761.org` 的独立 D1 上报，source 为 `la-gw`。LA 原 `sing-box` 与 `sing-box-tx-direct` 二进制、配置、端口和进程保持不变，`dl` 不切换。

| 组件 | 测试环境位置 |
| --- | --- |
| 独立代理 | `sing-box-gw.service`，`/opt/sing-box-gw/sing-box` |
| 私有代理配置 | `/etc/sing-box-gw/config.json` |
| 独立状态目录 | `/var/lib/sing-box-gw` |
| DAWN / ZW / GJ / CRJ | Trojan TCP `23101–23104`；Hysteria2 UDP `24101–24104` |
| 公共直出 | TCP `23105`；UDP `24105` |
| 统计 API | `127.0.0.1:10085`，不开放公网 |
| 采集器 | `/opt/subscription-meter-gw/collector.py`、`stats.proto`、`grpcurl` |
| 私有采集配置与独立密钥 | `/etc/subscription-meter-gw/config.json`、`report.key` |
| 持久账本 | `/var/lib/subscription-meter-gw/state.sqlite3`，必须备份，不能删除后重建代替恢复 |
| 每分钟采集 | `subscription-meter-gw.service` / `.timer` |
| 受保护网站 | `free-flight-gw` Pages；`free-flight-gw-auth` D1 |

构建使用官方 sing-box `v1.14.0` 源码（`0b8995879f29a9b98ee027bc17b75e101445b238`）、Go 1.26.9、`GOOS=linux GOARCH=amd64 CGO_ENABLED=0` 与 `with_quic,with_v2ray_api,with_utls` 标签，grpcurl 固定 `v1.9.4`。构建和解压在独立目录完成，不覆盖 `/usr/local/bin/sing-box`。独立服务使用已有 ACME 管理的 `la.1761.org` 证书文件，不复制 DNS API 凭据、不另行申请证书；证书续期继续由原服务维护。服务设置 192 MiB 内存上限和较低 CPU 权重。

**个人计量仅覆盖使用 gw 新测试节点的流量。** 旧 dl 节点仍在使用，但没有接入个人统计，因此不会计入任何测试账号的个人额度。公共网卡合计包含新旧代理以及管理等全部整机流量。测试节点仍共用同一台 LA 主机和上游 ISP，不代表具备独占带宽或额外的 ISP 并发额度。

首次接入只记录接入后的增量，本月显示“部分统计”；没有恢复接入前历史。原 gw 专属订阅 URL 与账号密码不变，客户端更新订阅后获得新端口和独立凭据。每个 ISP 的 Trojan、Hysteria2 与混淆密码分别独立，避免一个账号的节点密码用于另一个账号端口。公共直出保持共享。

### 可重复部署与回退

1. 在独立目录准备带统计的二进制和配置，复制原路由语义并更换为新端口、独立凭据与只读证书路径。为合并的公共直出规则限定其入站，保持各 ISP 固定出口、`route.final=block`，不增加跨 ISP 回退。用新二进制 `check` 后只启动 `sing-box-gw`。
2. `collector.py` 保持只读查询，`reset=false`。sing-box v1.14.0 虽然源码 proto 包名为 `experimental.v2rayapi`，**实际注册名称**是 `v2ray.core.app.stats.command.StatsService`（见 `stats.go` 的 init），采集器必须调用此名称。未产生过连接的 outbound 可能尚无计数，先进行真实连通性测试；缺失计数仍不伪造零。
3. 确认 D1 已应用 `subscription-auth/schema.sql`，配置独立 `SUB_METER_KEY` Secret、`SUB_USAGE_SOURCE=la-gw`。私有采集配置映射到 `sing-box-gw.service` 和专用路径，`--sample-only` 应识别整机与四个 ISP。密钥文件 0600，账本目录 0700。
4. 在独立 gw 发布目录配置 `SUB_AUTH_ISP_CREDENTIALS_FILE`、`ISP_PORT_OVERRIDES` 和公共直出变量。先测试候选配置，再使用 `install.sh --pages-only` 发布 gw；原 dl 发布目录不修改。验证四个账号与原订阅 URL 的权限、更新和所有节点出口。
5. 执行一次真实采集和签名 HTTPS 上报，再启用 `subscription-meter-gw.timer`。用独立客户端传输已知体积，比较统计 API、SQLite、gw 页面三处增量，确认只增加相应个人计数，直出不增加个人计数。
6. 故障时先停止 gw 采集 timer，保留 SQLite、密钥和配置；如需撤回测试节点，回滚至**之前受保护的 gw 部署**，待测试客户端更新后再停止 `sing-box-gw`。不得回滚到公开无鉴权资产，不停止原 `sing-box` / `sing-box-tx-direct`，不修改 dl。

未来若将旧用户整体迁入统计，仍需另行安排客户端换链与旧凭据撤销；不能把本次独立测试当作全量切换或完整历史账单。

## 验证

```bash
node tests/usage.mjs
python3 tests/metering.py
bash tests/run.sh
node tests/auth-runtime.mjs
```

涵盖 UTC 月界、账号隔离、整机池不重复相加、签名和时间戳、重复/乱序上报、进程重置、持久化恢复、失联状态、原订阅地址更新及超额仍可下载。测试使用独立数据库与虚构计数；用户预览没有填入虚构用量。

接口依据：[sing-box V2Ray API](https://sing-box.sagernet.org/configuration/experimental/v2ray-api/)、[v1.14.0 QueryStats 消息协议](https://github.com/SagerNet/sing-box/blob/v1.14.0/experimental/v2rayapi/stats.proto)。

运行时服务名依据：[sing-box v1.14.0 stats.go](https://github.com/SagerNet/sing-box/blob/v1.14.0/experimental/v2rayapi/stats.go)。
