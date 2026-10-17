# GW 快速迁移

本工具面向已部署的 `sing-box-gw.service` 和 `subscription-meter-gw`。保持账号、专属订阅链接、客户端节点名称、密码、端口、TLS SNI、ISP 固定出口和路由规则。Cloudflare Pages/D1 保持原位置。支持 Linux systemd、与源机相同的 CPU 架构；当前 LA 为 amd64。Debian/Ubuntu/AlmaLinux 目标需预先具备 Python 3、sudo、OpenSSL、iproute2、useradd，SSH 主机密钥已核对并信任，sudo 可免密。

迁移通过修改受保护订阅的入口 IP 实现，不修改 DNS，不改变现有客户端配置，不操作已关闭的 dl，不停止或重启旧机上的任何代理。目标地址与 SNI 可以不同，证书仍验证原 SNI。

## 能做到什么

- `plan`：只读盘点源机、目标机、受保护发布目录和已有专属订阅，保存私有快照。
- `prepare`：复制实际 GW 二进制、配置、证书、规则文件、统计工具；只在第二台安装独立服务。源机账本不复制。
- `verify`：在操作电脑上启动临时、仅回环监听且关闭 TUN 的 Mihomo，四条 ISP 与公共直出分别验证 Trojan/Hysteria2；每个节点访问两个独立 IP 查询目标并核对预期出口。错误出口立即拒绝，临时请求失败最多重试两次。
- `switch --lines crj`：可先迁一条，再迁其他。只有最近 15 分钟验证通过且目标配置未变化才发布。发布后验证旧专属 URL 的入口、密码、SNI、权限和流量头，并确认新机完整计量报告被接收。
- `rollback`：只恢复所选线路的原订阅入口，新旧服务都保持运行。目标机已经失联时也能执行；仍需旧机和发布机可用。
- `recover`：SSH/发布中断时依据私有日志恢复原入口。发现发布目录另有修改则拒绝覆盖。
- `status`：显示两台服务状态、已切换线路与旧机 TCP 连接数，不输出密码。UDP socket 数不能代表 HY2 活跃会话，因此不据此自动下线。
- `sync-certs`：从仍在续期的旧机同步验证过的证书与私钥，使用 sing-box 文件自动加载机制，不重启代理。

## 连接连续性的边界

已有 TCP/QUIC 会话留在旧机，新机承接客户端取得新订阅后建立的连接。本工具不转移进程内存、TCP 状态或 QUIC 密钥。客户端更新配置可能主动断开或重建连接，无法承诺所有客户端绝对零中断；未更新订阅的设备会继续使用旧机。当前订阅建议更新周期为 24 小时，软件自身调度可能不同。

至少覆盖一个实际客户端更新周期并确认使用情况后，再人工安排旧机下线。长期连接、暂停的设备和客户端 DNS/配置缓存可能更久，不能靠等待 DNS TTL 判断排空。公共直出迁移后公网出口变为新服务器 IP；ISP 正常出口保持原 IP，显式视频/下载直出规则仍使用所在服务器的出口。

依据：[QUIC RFC 9000 §9.6](https://www.rfc-editor.org/rfc/rfc9000.html#section-9.6)、[sing-box TLS 文件自动加载](https://sing-box.sagernet.org/configuration/shared/tls/#certificate_path)。

## 使用步骤

先将本版本代码同步到本机和 **GW 受保护发布仓库**，保留其 `.env` 与私有凭据。不能使用旧 dl 的发布目录。第二台云安全组与系统防火墙须开放计划输出的 Trojan TCP、HY2 UDP 端口；统计 `127.0.0.1:10085` 不对公网开放。工具不会自动更改防火墙或系统网络参数。

准备一个 0600 的验证账号 JSON：使用现有专属订阅 token，不重置密码或链接。格式为账号数组，字段 `username`、`scopes`、`token`；管理员另加 `can_view_all: true`。至少包含一个普通账号，所有账号 scopes 合起来覆盖全部线路（含 tx）。不得把该文件提交 Git。

下面 `dmit` 是你配置的第二台 SSH 别名，示例 IP 必须替换成实际公网地址。新 source 必须从未使用过，未来再次迁移也不能复用。

```bash
MIGRATION_STATE="$HOME/.local/share/free-flight-gw/migrations/la-to-dmit"
python3 migrate-gw.py plan --state "$MIGRATION_STATE" \
  --source la --source-address 144.34.152.175 \
  --target dmit --target-address 198.51.100.20 --interface eth0 \
  --meter-source dmit-gw-202611 \
  --publisher tx --publisher-dir /home/ubuntu/app/free-flight-gw-staging \
  --accounts-file "$HOME/.local/share/free-flight-gw/verify-accounts.json"

python3 migrate-gw.py prepare --state "$MIGRATION_STATE"
python3 migrate-gw.py verify --state "$MIGRATION_STATE" \
  --mihomo '/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo'
python3 migrate-gw.py switch --state "$MIGRATION_STATE" --lines crj
# 观察和确认后，若已超过 15 分钟，先重新 verify
python3 migrate-gw.py switch --state "$MIGRATION_STATE" --lines all
python3 migrate-gw.py status --state "$MIGRATION_STATE"
```

不会自动创建/购买云服务器，也不会为新主机跳过 SSH 指纹校验。第二台已有 GW 文件、unit、端口占用或架构不同会被拒绝，不能用此流程覆盖现有部署。预部署中途失败时保留目标上的材料供排查，绝不自动删除目录或账本。修复原因后检查专属 unit，不能删除计量账本后当作新机重试。

回退与恢复：

```bash
python3 migrate-gw.py rollback --state "$MIGRATION_STATE" --lines crj
python3 migrate-gw.py rollback --state "$MIGRATION_STATE" --lines all
python3 migrate-gw.py recover --state "$MIGRATION_STATE"
python3 migrate-gw.py sync-certs --state "$MIGRATION_STATE"
```

切换/回退只更新 `.env` 中的入口和额外计量源，经过哈希比对与文件锁；不覆盖并发人工修改。发布日志及前置备份在发布仓库 `.migration-private/`，包含敏感信息。失败若已发布则自动恢复之前入口并复验；遇到网络中断或并发修改，保留 journal，使用 `recover` 核对。Cloudflare 传播及客户端刷新不是跨系统原子操作，恢复期间两台代理均保留。

## 流量与证书

每台服务器使用不同计量 source 和独立 SQLite。原 D1、月累计量不动，新增源后跨源合并；回退也保留新机已记录的流量。100 GB 个人与 1000 GB 公共池不翻倍，UTC 每月 1 日清零。准备阶段未登记的源会在本机耐久排队，切换时登记并补交。旧机仍在服务时持续采集；最终退出后才能将其列入 `SUB_USAGE_INACTIVE_SOURCES`，原 source 不能从白名单删除。详见 [计量说明](../metering/README.md#多服务器迁移账本)。

证书初始由旧机复制，目标不接收 Cloudflare DNS API 密钥；预部署拒绝有效期不足 7 天或不覆盖 SNI 的证书。重叠期间旧机负责续期，需在续期后运行 `sync-certs`。**关闭旧机之前必须在新机安排独立的证书续期并验证**，否则复制的证书到期后新连接会失败。此工具没有自动关闭旧机功能。

## 验证与只读盘点

```bash
python3 tests/migration.py
node tests/usage.mjs
bash tests/run.sh
node tests/auth-runtime.mjs

python3 migrate-gw.py audit-source --source la --source-address 144.34.152.175 \
  --state "$HOME/.local/share/free-flight-gw/audits/la-current" \
  --mihomo '/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo'
```

测试涵盖分批切换、原线路/凭据不变、非法包/路径拒绝、同机/异架构保护、原站与退休站保护、发布并发修改保护、失败回退、目标失联时回退、源机只读以及双机累计不重复/不清零。真实目标需在购买并完成 SSH 接入后运行 `prepare` 和 `verify`；仓库回归通过不代表新厂商线路质量已验证。
