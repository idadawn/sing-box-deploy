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

## 当前上线边界

截至本次只读检查，LA 的 sing-box **1.14.0 未包含 `with_v2ray_api`，配置也未开启统计**。公网网卡可用于整机采集，但个人计量尚不可接入。当前没有安装采集器、启用 timer、替换二进制、修改配置或重启服务；生产订阅和 DNS 均保持原样。

正式接入前需安排受控切换：

1. 在独立环境准备与现有功能兼容、带 `with_v2ray_api` 的 sing-box 构建，以及官方 `grpcurl`。不能直接把缺少统计功能的现有二进制配上新配置就重启。个人用量归属依赖固定 ISP 出口；正式作为账号额度使用前，还应完成个人入口文档中的每 ISP 凭据隔离，避免共享密码被用于其他编号。
2. 复制 `config.example.json` 到服务器私有配置目录，确认公网网卡、服务、ISP ID 到 SOCKS outbound 的映射。内部 ID 保持原值，展示大小写不影响计量。
3. 运行 `python3 collector.py /etc/subscription-meter/config.json --prepare-config /root/sing-box-meter-candidate.json`，只产生 0600 候选文件，绝不覆盖当前配置。统计仅监听 `127.0.0.1:10085`。用目标二进制执行 `sing-box check` 并验证新旧路由与凭据一致，再按批准的窗口切换。
4. 在 D1 执行更新后的 `subscription-auth/schema.sql`（CREATE IF NOT EXISTS，不删除用户）。将新的随机独立密钥设为 Pages Secret `SUB_METER_KEY`，同一密钥放入采集器的 0600 `key_file`。不得复用 `SUB_AUTH_KEY`，不得放入 Git、页面或普通用户接口。`SUB_USAGE_SOURCE` 默认 `la`。
5. 将 `collector.py`、`stats.proto` 放入 `/opt/subscription-meter/`。先执行 `--sample-only` 检查可用性，验证每条个人计数与明确的单线路传输相符，并使用真实采集器验证 HTTPS 上报能通过站点 WAF、成功入账，再安装本目录配套的 systemd service/timer。密钥、账本和备份放在受限目录。
6. 首次累计只能从接入时开始；如需整月历史值，需要可核验的原始历史记录，不能把零当成历史用量。

密钥变更、账本丢失或采样中断后应核对完整性；本功能不是具有严格财务结算保证的账单系统。

## 验证

```bash
node tests/usage.mjs
python3 tests/metering.py
bash tests/run.sh
node tests/auth-runtime.mjs
```

涵盖 UTC 月界、账号隔离、整机池不重复相加、签名和时间戳、重复/乱序上报、进程重置、持久化恢复、失联状态、原订阅地址更新及超额仍可下载。测试使用独立数据库与虚构计数；用户预览没有填入虚构用量。

接口依据：[sing-box V2Ray API](https://sing-box.sagernet.org/configuration/experimental/v2ray-api/)、[v1.14.0 QueryStats 协议](https://github.com/SagerNet/sing-box/blob/v1.14.0/experimental/v2rayapi/stats.proto)。
