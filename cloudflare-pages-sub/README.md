# Cloudflare Pages 订阅托管

这个目录将 v2rayN 和 Clash 订阅配置托管在 Cloudflare Pages 上。`functions/v2.js` 和 `functions/c.js` 由根目录的 `install.sh` 动态生成并部署，无需手动编辑。

## 订阅链接

部署完成后，订阅链接为：

- **v2rayN**: `https://<SUB_DOMAIN>/v2`
- **Clash**: `https://<SUB_DOMAIN>/c`

其中 `SUB_DOMAIN` 在根目录 `.env` 中配置。

## 目录结构

```
cloudflare-pages-sub/
├── functions/           # Cloudflare Pages Functions（由 install.sh 生成）
│   ├── v2.js            # v2rayN 订阅接口 (/v2)
│   └── c.js             # Clash 订阅接口 (/c)
├── _redirects           # 重定向规则（由 install.sh 生成）
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

## 手动部署

如需手动更新订阅配置：

```bash
cd cloudflare-pages-sub
export CLOUDFLARE_API_TOKEN="你的Token"
export CLOUDFLARE_ACCOUNT_ID="你的AccountID"
wrangler pages deploy . --project-name="sub-converter" --branch=main
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
