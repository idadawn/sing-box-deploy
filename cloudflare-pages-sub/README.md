# Cloudflare Pages 订阅托管

这个目录将 v2rayN、Clash 订阅和 Clash Verge 全局扩展脚本托管在 Cloudflare Pages 上。相关文件由根目录的 `install.sh` 动态生成并部署，无需手动编辑。

- `Clash` 与 `v2rayN / v2rayNG` 订阅由私有 ISP 清单动态生成
- `/v2?isp=<编号>` 与 `/c?isp=<编号>` 只返回该 ISP 的两个 T 入口节点
- 主页从部署时生成的 `subscriptions.json` 自动展示每个编号的独立订阅和到期日（不公开 ISP 凭据）
- 单 ISP Clash 订阅通过 `Profile-Title` 自动显示为对应编号；不发送文件名响应头，避免部分客户端把引号或 `.yaml` 误当作订阅名
- 不带 `isp` 参数时返回全部未到期 ISP，过期编号会返回 HTTP 410
- AI 服务默认走 ISP-only 专用策略组，不使用 `DIRECT`
- Hugging Face、OneDrive、视频和软件包下载优先使用只含 T 节点的 `📦 TX 大流量` 组
- 服务端每天同步并校验 Loyalsoldier `release` 快照，客户端每 24 小时从本站镜像更新

## 订阅链接

部署完成后，订阅链接为：

- **v2rayN**: `https://<SUB_DOMAIN>/v2`
- **Clash**: `https://<SUB_DOMAIN>/c`
- **Clash Verge 全局扩展脚本**: `https://<SUB_DOMAIN>/s`

其中 `SUB_DOMAIN` 在根目录 `.env` 中配置。

## 目录结构

```
cloudflare-pages-sub/
├── functions/           # Cloudflare Pages Functions（由 install.sh 生成）
│   ├── v2.js            # v2rayN 订阅接口 (/v2)
│   └── c.js             # Clash 订阅接口 (/c)
├── _redirects           # 重定向规则（由 install.sh 生成）
├── global-extension.js  # 任意机场的全局扩展脚本（由 install.sh 生成）
├── subscriptions.json   # 主页公开订阅清单（由 install.sh 生成，不含凭据）
├── rules/               # Loyalsoldier 规则快照（由定时服务生成）
├── index.html           # 订阅入口页面
├── package.json         # 项目配置
├── wrangler.toml        # Wrangler 配置
└── README.md            # 本文档
```

## 自动部署（推荐）

运行根目录的 `install.sh` 会自动生成并部署：

```bash
sudo ./install.sh
```

前提条件：`.env` 中配置好 `CF_API_TOKEN`、`CF_ACCOUNT_ID` 和 `SUB_DOMAIN`。

安装脚本还会启用 `clash-rules-sync.timer`。它每天在北京时间 07:15 后检查上游，只有全部规则文件校验通过才替换旧快照并重新部署 Pages；失败时继续保留上一版。

## 手动部署

如需手动更新订阅配置：

```bash
cd cloudflare-pages-sub
export CLOUDFLARE_API_TOKEN="你的Token"
export CLOUDFLARE_ACCOUNT_ID="你的AccountID"
wrangler pages deploy . --project-name="${CF_PAGES_PROJECT:-sub-converter}" --branch=main
```

## 绑定自定义域名

1. 在 Pages 项目设置中点击 **Custom domains**
2. 添加你的 `SUB_DOMAIN`
3. Cloudflare DNS 中会自动添加 CNAME 记录
4. 等待 SSL 证书自动签发

## 客户端导入

### v2rayN

1. 订阅 → 订阅设置 → 添加
2. URL 填写 `https://<SUB_DOMAIN>/v2`
3. 更新订阅

### Clash Verge / Mihomo

1. 配置 → 新建
2. 订阅 URL 填写 `https://<SUB_DOMAIN>/c`
3. 下载并启用
4. 使用带 `isp=<编号>` 的独立链接时，所有 ISP 流量都固定到该编号；大流量规则仍可使用 `📦 TX 大流量`

### Clash Verge + 第三方机场

1. 打开 `https://<SUB_DOMAIN>/s`
2. 将完整内容粘贴到 Clash Verge 的“全局扩展脚本”
3. 保存并更新任意机场配置

脚本将机场节点用于 `🛫 机场中转`，最终网站出口固定为 T 后端的 ISP，或显式允许的 T 公网直出。
