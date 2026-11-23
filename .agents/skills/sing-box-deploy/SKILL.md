---
name: sing-box-deploy
description: 使用 idadawn/sing-box-deploy 为 Debian 或 Ubuntu 服务器准备固定 SOCKS5 出口、Trojan 和 Hysteria2 接入，校验私有配置，按需安装代理或发布 Cloudflare Pages 客户端订阅。
license: MIT
---

# sing-box 部署助手

## 准备材料

先按用户选用的功能列清单。只询问准备进度或列出缺项时，可直接使用下面的信息。令牌、线路密码、订阅链接和私钥由用户放入自己的私有文件或 Secret 管理器，聊天中只使用字段名和配置状态。

| 用户的目标 | 所需材料 |
| --- | --- |
| 基础代理 | 有公网 IPv4 的 Debian/Ubuntu 主机、systemd、sudo 或 root 权限、两个不同的 Cloudflare DNS only 子域名、ACME 联系邮箱、区域 DNS 编辑令牌。每条有效 SOCKS5 线路需要编号、出口地址、HTTP 和 SOCKS5 端口、用户名、密码、到期日或 `never`。为两种协议规划 TCP/UDP 端口，并分别准备 Trojan、Hysteria2 和混淆密码。 |
| 发布订阅 | 再准备自己的 Pages 项目、绑定的订阅域名、账户 ID、发布令牌，以及发布机可用的 Node.js 和 Wrangler。确认订阅面向谁；公开模式允许持有链接的人取得节点配置。 |
| 登录或计量 | 登录需要 D1、签名密钥、账号与线路授权、验证账号。计量另需独立上报密钥、支持统计的 sing-box 和持久化账本。按用户选择阅读对应组件文档。 |

## 找到项目与配置

Skill 安装目录提供本指南和[执行脚本](scripts/run.sh)。安装器、模板和测试在项目源码中。优先使用用户指定的可信项目副本。需要新副本时，在选定的工作目录克隆 `https://github.com/idadawn/sing-box-deploy.git`。以该版本的 README 和模板为准。项目资料可从[使用说明](https://github.com/idadawn/sing-box-deploy/blob/main/README.md)进入。

用户要创建配置时，从项目根目录的 `.env.example` 和 `isp-list.example.tsv` 初始化缺少的私有文件。按 README 设置 `0600` 权限，保留已有文件及线路行顺序。示例中的域名、线路和密码均需换成用户自己的值。已有私有配置可直接提供文件路径。安装器会相对项目根目录解析 `ISP_LIST_FILE`。

## 选择执行方式

在目标主机上将 `runner` 指向本 Skill 的 `scripts/run.sh`，`repo` 指向 sing-box-deploy 项目根目录。如果 Skill 安装在操作电脑上，目标机的新版项目 checkout 也自带 `.agents/skills/sing-box-deploy/scripts/run.sh`。

| 用户要求 | 在目标主机上执行 | 实际作用 |
| --- | --- | --- |
| 仅校验 | `bash "$runner" validate "$repo"` | 调用 `install.sh --validate-only`，用已有的 `jq` 和 `sing-box` 检查临时配置。 |
| 只安装代理 | `sudo bash "$runner" install-proxy "$repo"` | 调用 `--skip-pages`，安装依赖并配置系统服务。 |
| 只更新订阅 | `sudo bash "$runner" publish-pages "$repo"` | 调用 `--pages-only`，使用既有配置向指定 Pages 项目发布。 |
| 安装并发布 | `sudo bash "$runner" install-with-pages "$repo"` | 执行安装器的完整流程，包括已配置的订阅发布与规则同步。 |

默认配置是项目内的 `.env`。第三个参数可传另一份私有环境文件，支持绝对路径或相对项目根目录的路径。脚本把安装器的原始输出留在执行主机；成功时清理临时日志，失败时保留权限为 `0600` 的诊断文件。排错时只反馈错误类别、缺少的字段或下一步检查项。

按用户已经授权的目标和操作执行。准备或校验请求到相应步骤即结束。改动系统服务或发布订阅前，若目标主机、发布项目或操作范围尚未确定，先取得缺少的信息。

## 验收

- **校验**只报告本地配置检查结果。示例占位值也可能通过语法校验，凭据有效性和线路连通性要在目标环境分别验证。
- **代理**检查服务状态，并分别用 Trojan 和 Hysteria2 客户端验证预期出口。向用户反馈各项是否通过。
- **订阅**核实实际发布结果和授权范围。完整安装流程在发布依赖缺失时可能跳过 Pages，即使安装器返回成功也需单独验证。如果代理已正常运行而发布失败，修复发布问题后用 `publish-pages` 单独重试。鉴权、计量或迁移分别参阅源码中的 `subscription-auth/README.md`、`metering/README.md` 或 `migration/README.md`。
