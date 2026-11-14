# 流量额度与计量

## 个人总流量：ISP + 公共直出

启用 `SUB_ACCOUNT_CREDENTIALS_FILE` 后，每个账号的 Trojan、Hysteria2 凭据独立，覆盖该账号获授权的 ISP 入口与公共直出入口。sing-box 通过 `stats.users` 的认证身份累计上传与下载；从 ISP 入口按规则转到 `direct-out` 的流量同样包含在个人总量中，不再只取 ISP outbound。管理员使用其他 ISP 线路时，仍使用管理员自己的凭据并计入管理员。节点订阅 URL、端口、TLS、出口路由和授权范围保持原有语义。

个人与公共套餐使用 KiwiVM 返回的同一 `reset_at`。本机保存逐采样区间，供应商失联跨账期时先保留证据，收到新重置时间后再归档，不按自然月清零。周期交界按采样结束时间归属，正常最多一个采样间隔的误差；长间隔跨界或代理计数器重启会标记部分统计。旧账期未发送快照单独排队，不因同一自然月内切换供应商账期而覆盖。D1 使用独立 `account_usage` / `account_generations` 表，重复上报不会重复加量，账本代次变化拒绝覆盖旧值。

首次启用没有完整历史：页面显示“接入后已用 · 历史未补齐”、统计起点，完整个人剩余额度暂不推算。旧个人 ISP 自然月账本保留用于诊断，不混入新账期。保留的旧凭据统一标记 `legacy-*`，其后续业务流量归入管理员可见的“旧节点未归属”，不猜测分摊。所有客户端须更新原订阅以切到个人凭据；重置订阅令牌不能替代更新代理凭据。旧共享凭据的停用需要单独安排用户切换，不在计量发布时突然断开用户。

个人 100 GB 继续是提醒额度，现覆盖 ISP + 直出且随 KiwiVM 账期重置。个人业务载荷只计一次；供应商整机账单包含两段网络传输、协议和系统流量，因此不把个人合计伪装成整机账单的精确分摊。管理员能查看各账号总量，普通用户只收到自己的明细。所有节点订阅流量条统一显示订阅所属账号总量，公共套餐的真实余量在网页单独展示。

### 配置与发布

1. 准备 0600 私有 JSON：`{"dawn":{"scopes":["dawn","tx"],"trojan":"独立随机凭据","hysteria":"另一独立随机凭据"}}`。管理员可列全部获授权 ISP；每种凭据至少 32 个 URL-safe 字符，跨账号/协议不得复用。
2. 用 `python3 metering/provision_accounts.py runtime.json meter.json accounts.json runtime-new.json meter-new.json` 生成候选配置。它保留路由和监听端口，为旧凭据改统计名、为新凭据启用用户统计，不直接修改服务。
3. 对候选运行 `sing-box check`，用隔离进程实测每个账号的 TCP/HY2、ISP/直出出口和用户计数；验证其他账号计数不增。备份原运行配置、采集配置、SQLite 和代码后，完成一次旧采集，再切换并重启 `sing-box-gw`。
4. 采集器必须同时部署 `collector.py` 和 `accounts.py`。运行配置中的 `account_users` 映射认证名到账号，`__legacy__` 为保留旧凭据统计集合。配置 `kiwivm` 与密钥要求沿用下节。
5. 应用更新后的 `schema.sql`。构建鉴权网站时设置 `SUB_ACCOUNT_CREDENTIALS_FILE`、`SUB_KIWIVM_VEID`；构建器把私有凭据写入 Functions 私有模块并生成 `SUB_ACCOUNT_USAGE_ENABLED=true`。控制台手工发布须同步设置该文本变量。先验证签名上报，再刷新所有人的订阅。不可将私有 Functions 源码或账号 JSON 当静态资产上传。

已启用账号账期的部署暂不接受旧的一键跨供应商迁移：迁移器在写入目标前明确拒绝，要求先配置目标供应商账期，避免丢失个人计量。

依据：[sing-box V2Ray 用户统计](https://sing-box.sagernet.org/configuration/experimental/v2ray-api/)、[v1.14.0 认证用户计数实现](https://github.com/SagerNet/sing-box/blob/v1.14.0/experimental/v2rayapi/stats.go)。

## KiwiVM 公共套餐（gw 当前模式）

公共套餐用量、总额度和下次重置时间直接来自 KiwiVM `getServiceInfo` 的 `data_counter`、`plan_monthly_data`、`data_next_reset`；前两项按 API 的 `monthly_data_multiplier` 换算。网页按 1024 进位显示 GB，与 KiwiVM 面板核对。公共余量不再用自然月网卡计数计算；启用个人总流量后，个人 100 GB 也使用供应商账期。

采集器每分钟查询供应商，只调用只读 `getServiceInfo`。服务器私有采集配置增加 `kiwivm: {"veid":"你的服务 ID","key_file":"/etc/subscription-meter-gw/kiwivm.key"}`，密钥文件必须为 0600。密钥不进入 Git、订阅、网页、D1 或报告；请求使用 HTTPS POST，禁止重定向。Pages 配置 `SUB_KIWIVM_VEID` 和 `SUB_KIWIVM_SOURCE`，仅允许指定采集源上报该服务。部署前应用 `schema.sql` 新增 `provider_usage` 表。

D1 独立保存供应商快照，不修改原有月账本。新快照按采集时间覆盖旧值，支持套餐升级、供应商修正和真实账期清零；重复及乱序上报不会恢复旧账期。无数据或查询异常显示待同步，不回退到自然月 0/1000 GB。超过 5 分钟未更新则保留上次已用量、隐藏失效的剩余额度；到重置时间后等待供应商确认新账期，不自行清零。

公共直出和管理员汇总订阅的流量条采用同一快照。标准订阅头只有上传/下载字段，因此以 `upload=0; download=供应商总已用` 携带总量，不代表真实下载拆分；`expire` 仍是订阅到期日期，不拿流量重置日期冒充到期。额外头 `X-Subscription-Usage-Source: kiwivm` 和 `X-Subscription-Usage-Reset-At` 标明来源和重置时间。没有可用快照或旧账期已结束时返回 503，让客户端保留旧配置。

网站不执行停机或限速；搬瓦工可能在公共套餐耗尽后暂停服务，页面不会承诺公共套餐超额不停用。迁移新机器时不复制旧机 KiwiVM 配置/密钥，需按新供应商重新对接套餐。

以下自然月公共网卡额度是未配置 KiwiVM 时的旧内部额度模式，不代表搬瓦工套餐余量；网卡账本继续用于诊断。

## 已确认规则

| 项目 | 规则 |
| --- | --- |
| 个人 ISP | 每个账号每月 100 GB，多条获授权 ISP 合并计算 |
| 公共额度 | 整机每月共用 1000 GB，已经包含个人 ISP 消耗和视频、下载等直出流量 |
| 计量方向 | 上传 + 下载；显示统一按 1024 进位，1 GiB = 1,073,741,824 字节，界面沿用 GB 标签 |
| 账期 | UTC 自然月，每月 1 日 00:00 重置 |
| 超额 | 页面提醒，不停止代理、不拒绝订阅更新 |
| 金额 | 本功能仅管理流量，没有价格、充值、扣款或支付 |

网站自然月额度与云厂商账期可能不同，也不替代 KiwiVM 的账单、剩余套餐流量。供应商计费以其平台为准。

## 数据来源

- **整机公共额度**：读取公网物理网卡（LA 为 `eth0`）的 `tx_bytes + rx_bytes`。包含代理两段传输、隧道和管理等其他整机流量；不会把个人计数再加一遍。
- **个人 ISP 额度**：sing-box V2Ray API 中对应 `isp-out-<id>` 的 outbound uplink/downlink 计数，统计代理载荷。个人入口里被规则送到 `direct-out` 的视频等流量不扣个人 ISP 额度。
- 用户页面只返回其账号授权范围内的个人合计，以及大家共用的整机合计，不返回他人的明细。
- 当月数据库没有用量记录时按初始化用量 `0 / 100 GB` 或 `0 / 1000 GB` 显示，不受导入时间影响；有记录就读取当月累计值。查询异常不等于没有记录，不能用零覆盖已知用量。

两个统计口径不同：个人是代理载荷，公共是网卡双向字节（含封装与两段转发），不能简单相加。网卡统计与云厂商账单也可能有边界和封装差异。

## 采集器与账本

`collector.py` 使用 Python 标准库读网卡、调用 `grpcurl` 只读查询 sing-box（`reset=false`），在本机 SQLite 持久保存原始基线、UTC 月累计量和待发送报告。每分钟采样一次。

- 首次接入只建立当前基线，过去流量不能反推；当月标注“部分统计”。
- 采集器重启保留基线和累计值。系统或 sing-box 重启后继续记录已知的新计数，并标记可能遗漏的旧进程尾段。
- 数据按采样结束时间归属月份，正常月界最多有一个采样间隔的误差；长时间中断且跨月时不臆测分摊，改为新的部分基线。
- 未取得某条 ISP 计数时不补零，也不把旧数据的时间刷新成当前时间。
- 每月一条待发送累计快照，断网时保留。报告经独立 `SUB_METER_KEY` HMAC 签名和时间戳验证；重试、重放和乱序不会重复累计或回退已记录的总量。
- 采集账本具有持久化代次标识；同一月份发现新代次时拒绝接收，避免账本丢失后把新零基线覆盖成“统计正常”。须恢复原账本或经核验的人工迁移后继续。
- 有效订阅始终携带 `Subscription-Userinfo`：无记录初始化为零，有记录显示已记录的上传、下载和额度；部分统计与待同步数据继续显示原值，网页保留状态。数据库查询异常时返回 503，让客户端保留上次配置与用量，不把异常当作零或移除流量条。
- 页面超额提醒基于已知用量。没有任何停用账号、修改路由或限制网速的代码。

## gw 隔离测试部署

2026-10-17 起，真实计量只向 `gw.1761.org` 的独立 D1 上报，source 为 `la-gw`。dl 首页已跳转至 gw，旧订阅下载已关闭；已下载的旧节点暂不强制断开。LA 原 `sing-box` 与 `sing-box-tx-direct` 二进制、配置、端口和进程保持不变。

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

## 客户端流量条

订阅响应通过 `Subscription-Userinfo: upload=...; download=...; total=...; expire=...` 下发数据库中的字节数，Clash 等客户端在更新订阅时绘制流量条。网站和客户端统一按 1024 进位：个人额度下发 107,374,182,400 字节（100 GiB），公共额度下发 1,073,741,824,000 字节（1000 GiB），Clash Verge 和网页均显示 100 GB / 1000 GB。界面沿用客户端的 GB 标签。原始累计字节数不换算回写、不清零；这次统一了应用内提示额度，不修改云厂商套餐。

- 每月 **1 日 00:00 UTC** 查询新的月份；新月无记录先显示零。历史账本保留，不删除、不因登录、导入或更新订阅而重置。
- `partial` 表示当前值从采集接入后开始累计，不是回填了整月历史。`stale` 保留最后一次采集数值，网页提示待同步。
- `X-Subscription-Usage-Status`、`X-Subscription-Usage-Started-At` 和 `X-Subscription-Usage-Updated-At` 提供统计状态及时间；标准客户端可能不展示这些扩展字段，可通过 `Profile-Web-Page-URL` 回到网页查看。
- 到期时间与流量重置日期分开；没有到期日的订阅继续下发 `expire=0`，不伪造一个月末到期日。
- DAWN 单条订阅使用对应 ISP 的 100 GB 额度，汇总订阅使用已经包含各线路的整机 1000 GB 公共池；不把几条独立个人额度相加后冒充一个人的用量。
- 后台每分钟采集，客户端卡片在客户端更新订阅时刷新，不是每分钟向客户端主动推送。

依据：[Clash Verge 订阅元信息读取](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src-tauri/src/config/prfitem.rs)、[流量单位换算](https://github.com/clash-verge-rev/clash-verge-rev/blob/dev/src/utils/parse-traffic.ts)。

## 多服务器迁移账本

`SUB_USAGE_SOURCE` 保留原身份。`SUB_USAGE_EXTRA_SOURCES` 是逗号分隔的额外采集源白名单，最多合计 16 个；每台并行服务器使用全新的唯一 source 和全新的本地 SQLite，旧机继续使用原账本。D1 表无需改结构：仍以 `(source, period, meter)` 分别保存单调累计值，查询时跨源求和。重复、乱序报告不会重复加量；每个 source 的 generation 检查仍独立生效。

迁移和回退均不删除源、不复制旧机累计数到新机、不改变 100/1000 GB 额度。公共池是所有已登记机器物理网卡总量之和，个人池是各机器同名 ISP outbound 的合计，不再叠加到公共池。并行期间仍显示总共 1000 GB 应用额度，而不是每台各获得 1000 GB。

只有旧机完成最终上报、明确下线后，才把其 source 加入 `SUB_USAGE_INACTIVE_SOURCES`：它的历史用量继续参与合计，但不再要求新的采样时间。仍在运行的排空旧机不能标为 inactive。缺少某个活跃源的数据时显示部分统计；数据库没有当月记录仍按初始化零用量显示。

详见 [GW 快速迁移](../migration/README.md)。
