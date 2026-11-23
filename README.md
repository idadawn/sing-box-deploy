# sing-box-deploy

在 Debian 或 Ubuntu 上部署和管理 sing-box。每条有效线路提供 Trojan（TCP）和 Hysteria2（UDP）两种接入方式，普通流量经该线路指定的 SOCKS5 出口转发。可以只运行代理，也可以为 Clash/Mihomo、v2rayN/v2rayNG 和 Shadowrocket 生成订阅。

## 通过 AI 助手使用

在 Codex 中打开本仓库即可使用 `$sing-box-deploy`。在其他项目里，把下面这句发给 Codex 即可安装。

```text
用 $skill-installer 安装 https://github.com/idadawn/sing-box-deploy/tree/main/.agents/skills/sing-box-deploy
```

也可以在目标项目目录用 npm 的 `npx` 安装。下面的命令安装到当前项目，Claude Code 用户将 `-a codex` 换成 `-a claude-code`。

```bash
npx skills add idadawn/sing-box-deploy --skill sing-box-deploy -a codex -y
```

安装后，可以直接给助手以下任一请求。

> 用 $sing-box-deploy 列出我在 Ubuntu 上只装基础代理需要准备什么。先做清单。

> 用 $sing-box-deploy 在我指定的 Debian 服务器上校验已有配置。到校验结束即可。

执行部署时提供自己的目标主机、项目目录和操作范围。域名、线路清单和令牌在自己的私有配置中填写。[Skill 使用说明](.agents/skills/sing-box-deploy/SKILL.md)

## 开始前需要准备什么

| 用途 | 需要准备 |
| --- | --- |
| 基础代理 · 主机 | 一台有公网 IPv4 的 Debian 或 Ubuntu 服务器，使用 systemd，具备 root 或 sudo 权限。服务器需能访问软件源、证书服务和选用的 SOCKS5 出口。 |
| 基础代理 · 域名和证书 | 一个由 Cloudflare 管理 DNS 的域名。为两种协议分别创建不同的子域名，用仅 DNS（DNS only）的 A 记录指向服务器。准备 ACME 联系邮箱，以及对该 DNS 区域有 DNS 编辑权限的 API 令牌。 |
| 基础代理 · 线路 | 至少一条有效的 SOCKS5 线路。向出口提供方取得地址、HTTP 和 SOCKS5 端口、用户名、密码及有效期。为线路分配唯一编号，用制表符填写私有清单。 |
| 基础代理 · 端口和密码 | 为各线路规划互不冲突的 Trojan TCP、Hysteria2 UDP 端口，在云安全组和主机防火墙放行，并核对 SSH 管理端口。分别生成 Trojan 密码、Hysteria2 密码和混淆密码。 |
| 发布订阅（可选） | Cloudflare 账户 ID、自己的 Pages 项目名、绑定到该项目的订阅域名，以及有 Pages 发布权限的 API 令牌。发布环境需能运行 Node.js 和 Wrangler。详见 [Pages 订阅](cloudflare-pages-sub/README.md)。 |
| 账号登录（可选） | 在订阅发布的基础上准备 D1 数据库、会话与订阅签名密钥、账号与线路的授权清单，以及用于发布验证的账号。详见 [订阅鉴权](subscription-auth/README.md)。 |
| 流量计量（可选） | 在鉴权门户上配置独立的上报密钥，准备支持统计接口的 sing-box、采集器和持久化账本。按账号统计还需独立节点凭据，读取供应商套餐还需其 API 凭据。详见 [流量计量](metering/README.md)。 |

## 从模板开始

首次准备服务器时，先安装 Git 并取得项目源码。已有仓库可直接进入下一步。

```bash
git clone https://github.com/idadawn/sing-box-deploy.git
cd sing-box-deploy
```

在仓库根目录创建私有配置。下面的命令保留已有文件。

```bash
umask 077
cp -n .env.example .env
cp -n isp-list.example.tsv isp-list.tsv
chmod 600 .env isp-list.tsv
```

1. 编辑 `.env`。基础安装必填 `TROJAN_DOMAIN`、`HYSTERIA_DOMAIN`、`CF_DNS_EDIT_TOKEN`、`ACME_EMAIL`、`ISP_LIST_FILE`、`TROJAN_PASSWORD`、`HYSTERIA_PASSWORD` 和 `HYSTERIA_OBFS_PASSWORD`。将占位值替换为自己的配置。每行使用 `KEY=value`，注释放在单独一行。
2. 编辑 `isp-list.tsv`。七列依次为编号、出口地址、HTTP 端口、SOCKS5 端口、用户名、密码、到期日。日期写成 `YYYY-MM-DD`，长期有效写成 `never`。脚本根据行顺序分配端口，更新已有清单时保留原顺序。
3. 核对 `TROJAN_PORT`、`HYSTERIA_PORT`、`ISP_PORT_STEP` 和 `SSH_PORT`。使用 `ISP_PORT_OVERRIDES` 单独指定线路端口时，需同时填写两种协议的端口，并预装 `jq`。

字段和文件格式见[环境变量模板](.env.example)和[线路清单模板](isp-list.example.tsv)。

## 校验与安装

- 查看脚本选项可运行 `bash install.sh --help`。
- 已安装 `jq` 和 `sing-box` 的主机可先运行 `bash install.sh --validate-only`，用私有配置生成并检查临时配置。实际连通性需在启动后分别用 TCP 和 UDP 客户端验证。
- **只安装代理**，运行 `sudo bash install.sh --skip-pages`。脚本安装依赖、预检 SOCKS5 出口并配置系统服务。
- **安装代理并发布订阅**，填好 `CF_API_TOKEN`、`CF_ACCOUNT_ID`、`CF_PAGES_PROJECT` 和 `SUB_DOMAIN` 后运行 `sudo bash install.sh`。只更新订阅时使用 `sudo bash install.sh --pages-only`。

启动后可用 `sudo bash manage.sh` 查看服务状态、日志和出口检查结果。验收时分别连接同一线路的两种协议，确认普通流量的出口与该线路一致。订阅、邀请、客户端配置和迁移包可能携带凭据，请通过私有渠道交付。

## 维护与开发

- [架构与路由](docs/architecture.md)说明线路选择、直连规则和故障行为。
- [迁移指南](migration/README.md)列出加密备份、并行迁移的准备条件、验证与回退步骤。
- [CI 工作流](.github/workflows/ci.yml)列出回归命令和 Node.js 版本。在仓库根目录运行 `bash tests/run.sh` 可执行基础回归。

项目使用 [MIT 许可证](LICENSE)。
