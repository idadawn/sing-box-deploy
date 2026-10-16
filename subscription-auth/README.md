# 自由翱翔 · 个人办公空间

这是可选的 Pages 鉴权入口。默认 `SUB_AUTH_ENABLED=false`，提交代码不会改变现有生产链接，也不会创建正式账号。

当前约定的正式分配：`dawn → dawn,tx`、`zw → zw,tx`、`gj → gj,tx`、`crj → crj,tx`。`tx` 是已迁至 LA 的独立直出服务。账号权限由 D1 保存，URL 参数和前端列表不能扩大权限。

登录页与个人页面统一使用“自由翱翔”品牌。每条获授权线路提供“导入 Clash”和“导入 v2rayNG”：将完整个人订阅 URL 编码为客户端协议链接的 `url` 参数，账号的 ISP 与令牌不会因参数截断丢失。v2rayNG 入口用于 Android；未安装或浏览器无法唤起时，可复制同一专属链接手动导入。网页不自动启动客户端，也不宣称已经完成客户端内的导入。

## 行为与边界

- 首次使用通过一天有效、一次性的邀请设置密码；没有公开注册接口。邀请在 URL fragment 中，页面读取后立即清除。
- 密码使用随机盐、PBKDF2-SHA256 100,000 次及服务端 HMAC pepper；选用该轮数以兼容 Workers 的 PBKDF2 限制。密码至少 12 位。`SUB_AUTH_KEY` 同时参与密码 pepper 与订阅 HMAC，必须作为 Secret 保存并备份，不能随意更换。
- 网页会话是随机令牌，数据库仅存 SHA-256，7 天有效；Cookie 使用 `__Host-`、Secure、HttpOnly、SameSite=Strict。退出删除当前会话；修改密码删除该账号全部会话。
- 客户端链接使用独立的 HMAC 订阅令牌；登录或退出网页不影响自动更新。重置链接更新账号版本，旧令牌立即失效。订阅令牌不能登录网页、修改密码或生成其他账号的链接。
- 服务端鉴权覆盖 `/v2`、`/c`、`/s`、`/global-extension.js`、`/tx`、`/tx-v2`、`/subscriptions.json`。全局脚本在发送前移除其他 ISP 清单。重复参数、伪造令牌、跨账号请求均拒绝。
- 包含节点凭据的静态文件被删除，私有生成模块仅放在 Pages 不作静态上传的 `functions/` 中。全路径 middleware 加显式允许列表；数据库或 Secret 缺失时关闭访问。响应禁止缓存、跨域读取和 Referer 传播。
- POST 请求检查同源 Origin；每 IP 每 15 分钟最多 30 次账号操作，每账号最多 50 次登录尝试。数据库原子计数，成功登录时清理过期记录。
- 登录控制的是配置的查看与下载，不能撤回已经下载的节点凭据。当前部署沿用的 ISP 入站密码可能由多条线路共用：网页登录并不能阻止持有旧节点密码的人尝试其他入站端口。正式安全切换时需要另行安排每 ISP 独立凭据及旧凭据轮换，并协调客户端换链；本次开发不修改运行中的代理配置。

## 本地验证

```bash
bash tests/run.sh
npm ci --prefix cloudflare-pages-sub
node tests/auth-runtime.mjs
```

第一组用真实 SQLite 执行 D1 SQL，检查身份、权限、失效和并发更新条件；第二组用官方 Wrangler 的 Pages/Workers + D1 本地运行时测试四个虚构账号和全部配置格式。CI 同时执行两组。测试不读取 `.env`、私有 ISP 清单或真实服务器。

可视化预览：

```bash
preview_dir="$(mktemp -d)"
node tests/auth-fixture.mjs "$preview_dir"
# 以下命令在 preview_dir 中执行，使用项目中安装的 wrangler 绝对路径：
wrangler d1 execute SUB_AUTH_DB --local --file=fixture.sql
rm fixture.sql
wrangler pages dev . --ip=127.0.0.1 --port=8971
```

测试账号是 dawn / zw / gj / crj，测试密码为 `preview-only-passphrase`，页面标注虚构数据。这个密码绝不能用于生产。

## 正式启用步骤（另行安排切换）

1. 先确认用户允许旧公开链接失效，并约定所有人更新一次链接。保留部署资产备份；禁止将无鉴权版本作为启用后的线上回滚目标。
2. 在 Cloudflare 创建专用 D1，执行 `schema.sql`。将其以 `SUB_AUTH_DB` 绑定到目标环境；设置随机至少 32 字节的 `SUB_AUTH_KEY` 为 Pages Secret。生产、预览环境分离数据库和 Secret，测试环境不放真实节点凭据。当前用于 Pages 发布的 Token 未必具有 D1 管理权限，需使用已获授权的 D1 管理通道。
3. 在私有目录生成每个人的一次性邀请 SQL，通过 D1 管理通道导入。命令只输出文件位置，不打印凭据；不要把邀请、SQL、验证令牌文件上传 Git 或发给其他用户：

   ```bash
   node scripts/auth-invite.mjs dawn dawn,tx https://dl.1761.org
   node scripts/auth-invite.mjs zw zw,tx https://dl.1761.org
   node scripts/auth-invite.mjs gj gj,tx https://dl.1761.org
   node scripts/auth-invite.mjs crj crj,tx https://dl.1761.org
   ```

   重复账号 INSERT 会失败，不会覆盖现有账号。禁用用户可设置 `enabled=0`，会同时拒绝其会话和订阅令牌。重置遗忘密码需由管理员单独撤销会话、生成新邀请并按需更换 token_version；不提供未认证的重置接口。

4. 设置 `.env` 中 `SUB_AUTH_ENABLED=true`、`SUB_AUTH_D1_ID`。准备 `SUB_AUTH_VERIFY_FILE`（0600，仅服务器可读），其中至少两个具有不同 ISP 的已激活测试账号及其专属令牌：`[{"username":"dawn","token":"...","scopes":["dawn","tx"]}, ...]`。先在隔离环境激活、验证，不用生产账号密码做自动化测试。
5. 使用 `install.sh --pages-only` 发布。鉴权部署会检查匿名访问被拒、授权下载成功、不同账号不能交叉下载。首次启用验证失败时绝不自动重发无鉴权资产；修复绑定/Secret 后重新发布。已保护的本地资产也不能因环境变量丢失而被重建成公开版本。
6. 在 Cloudflare 将 Function 的超额行为设为 **fail closed**，实测生产 CPU 限额下的登录。检查自定义域名、`pages.dev` 主域名、分支别名和历史部署 URL。历史未鉴权部署不会因新版本发布而自动获得保护，需撤销旧部署的公开访问，并确认任何旧静态配置地址都无法绕过鉴权。
7. 将每份邀请私下交给对应用户，用户自己设密码。每个人登录后复制新链接更新客户端，再验证实际 ISP 出口；已有代理连接及已下载配置不会因网页鉴权自行失效。

## 部署结构

`scripts/build-auth.mjs` 在生成订阅后按显式开关打包登录页和 middleware，删除原静态凭据载体。私有目录 `functions/_private` 只参与 Worker 构建。`index.html` 只在启用时替换为登录页；未启用时原首页与所有旧链接保持原行为。无需修改 DNS、WireGuard、sing-box 服务或现有端口。

参考：[Pages D1 绑定](https://developers.cloudflare.com/pages/functions/bindings/#d1-databases)、[Pages middleware](https://developers.cloudflare.com/pages/functions/middleware/)、[Workers Web Crypto](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/)。
