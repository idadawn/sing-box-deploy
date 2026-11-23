# 流量计量

计量包含个人用量和共享用量。个人用量回答“这个账号用了多少代理流量”，共享用量回答“整个套餐或服务器用了多少流量”。两者统计范围有重叠，直接相加会重复计量。

| 模式 | 统计来源与账期 |
| --- | --- |
| 按账号计量 | sing-box 按认证用户统计上传和下载。一个账号使用的 ISP 和公共直出流量归到同一账号。启用供应商账期时，以供应商返回的重置时间划分周期。 |
| 供应商套餐 | 可选 KiwiVM 接口提供整机已用量、总额度和重置时间。启用按账号计量时，各节点订阅的客户端流量条显示共享套餐，门户另列个人用量。 |
| 基础计量 | 未接入供应商时，按 UTC 自然月统计。个人线路取指定 SOCKS5 出站的载荷，整机取公网网卡的收发字节，包含系统流量及转发开销。 |

## 需要准备什么

- 可用的[鉴权门户](../subscription-auth/README.md)和已应用最新表结构的 D1。为每台采集器分配唯一的来源标识，并在门户中登记相同的来源。
- 支持 V2Ray 统计 API 的 sing-box、Python 3、`grpcurl` 和本目录的 [stats.proto](stats.proto)。统计接口只绑定回环地址。确认公网网卡名及待统计的出站标签。
- 按[采集配置模板](config.example.json)创建私有配置，替换来源、门户地址、网卡、出站映射及本机路径。采集器需要持久化 SQLite，并能写入其账本目录。备份账本可保留统计基线和代次。
- 为上报单独生成 43 至 128 个 URL 安全字符组成的随机密钥，例如用 `openssl rand -hex 32` 在私有终端生成。门户保存为 `SUB_METER_KEY`，采集器保存为 `0600` 的密钥文件。两端的值必须一致。
- 按账号统计需要 `SUB_ACCOUNT_CREDENTIALS_FILE`、匹配的代理认证用户以及采集器的 `account_users` 映射。接入 KiwiVM 时，还需服务 ID、受权采集来源和仅采集器可读的供应商 API 密钥。

## 接入与验证

1. 根据私有配置生成候选统计配置，运行 `sing-box check`。按账号计量可使用 [provision_accounts.py](provision_accounts.py) 生成代理和采集器的候选文件。
2. 验证每种协议的连接和计数归属。对一个账号产生少量流量，确认其计数增加、其他账号保持原值。按账号采集时同时安装 [collector.py](collector.py) 和 [accounts.py](accounts.py)。
3. 验证签名上报、门户显示和客户端流量条。已有共享凭据产生的历史用量保留为未归属；起始记录不完整时，门户标注部分统计。供应商数据过期时，展示最近已知值，并等待新快照确认账期。
4. 采集器在本地保存待发送的累计快照。重复和乱序上报不会重复加量。服务器迁移时为新机分配新来源和独立账本，保留旧来源以合并历史。旧机完成最后上报并退出后，才将其标为非活跃。
5. 在仓库根目录运行 `python3 tests/metering.py`。本地 Pages 运行时验证还可运行 `node tests/account-runtime.mjs`，所需依赖见 [CI](../.github/workflows/ci.yml)。

首次启用统计时，可在仓库根目录运行下面的检查。`METER_CONFIG` 指向私有采集配置，`CANDIDATE_CONFIG` 指向尚不存在的候选文件。单次采样检查应在代理已启用统计接口后执行。

```bash
python3 metering/collector.py "$METER_CONFIG" --prepare-config "$CANDIDATE_CONFIG"
sing-box check -c "$CANDIDATE_CONFIG"
python3 metering/collector.py "$METER_CONFIG" --sample-only
```

额度提醒由门户显示。供应商是否会在套餐用尽后暂停服务，取决于其套餐规则。
