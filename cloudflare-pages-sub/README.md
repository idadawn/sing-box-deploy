# Cloudflare Pages 订阅发布

这个目录包含订阅首页和 Pages 项目的基础文件。根目录的安装脚本根据私有线路清单生成订阅、Functions 和客户端规则。构建后的目录可能包含节点凭据，应当作为私有发布产物处理。

## 发布前准备

| 配置 | 作用 |
| --- | --- |
| `CF_ACCOUNT_ID`、`CF_PAGES_PROJECT` | 指定自己的 Cloudflare 账户和目标 Pages 项目。 |
| `SUB_DOMAIN` | 客户端使用的订阅域名。在 Pages 项目中绑定自定义域名，等待 HTTPS 可用。 |
| `CF_API_TOKEN` | 用于发布 Pages 的令牌。基础代理证书另用 `CF_DNS_EDIT_TOKEN`。 |
| 发布工具 | 只更新 Pages 时，发布机需已有 `curl`、`flock`、`git`、`jq`、`node` 和 `wrangler`，以及通过校验的基础配置和线路清单。 |

在仓库根目录运行 `sudo bash install.sh --pages-only` 可生成、发布并验证订阅。启用鉴权的项目要先完成 [D1、密钥及验证账号配置](../subscription-auth/README.md)。规则同步脚本先验证整批快照，成功后才替换已发布的版本。

## 客户端如何导入

| 客户端 | 操作 |
| --- | --- |
| Clash/Mihomo | 在门户选择线路，复制 Clash 订阅，在客户端配置页添加远程订阅、更新并启用。 |
| v2rayN / v2rayNG | 复制对应格式的订阅，在订阅管理中添加并更新，再选择该线路的节点。 |
| Shadowrocket | 将节点订阅以 Subscribe 类型导入。需要 Telegram 专用分流时，把单独的规则模块添加到“配置 → 模块”。 |
| Clash Verge 全局扩展 | 从授权范围内取得扩展脚本，在全局扩展设置中保存，再更新所用配置。 |

`Profile-Title` 用于客户端命名，`Profile-Update-Interval` 提示更新周期。有限期线路按日期筛选，`never` 表示长期有效。登录模式下，客户端链接可以独立撤销。公开模式下，知道订阅链接的人可以取得节点配置，即使首页隐藏了线路。

停用旧订阅站的流程见[订阅鉴权](../subscription-auth/README.md)。客户端下载过的凭据需要在代理端单独轮换。
