# 自由翱翔 · 个人办公空间

这是可选的 Pages 鉴权入口。默认 `SUB_AUTH_ENABLED=false`，提交代码不会改变现有生产链接，也不会创建正式账号。

当前独立测试站为 **https://gw.1761.org**，使用独立的 `free-flight-gw` Pages 项目和 `free-flight-gw-auth` D1 数据库。`dl.1761.org` 首页通过 302 跳转到 gw，旧订阅路径已停用并返回 410。管理员预生成密码的账号可直接登录；一次性邀请方式仍可用于后续账号。密码和服务端 Secret 只保存在受限位置，不写入文档或 Git。

测试站使用 LA 上独立的 `sing-box-gw` 服务、端口和每 ISP 独立凭据，并接入真实计量；原代理不重启，`dl` 旧订阅现已关闭，旧代理端口和凭据暂未轮换。已有 gw 专属订阅链接不变，客户端更新后进入测试节点。个人计量只覆盖 gw 测试代理；公共整机网卡用量包含新旧服务。旧站公开订阅与历史 Pages 部署已撤除；后续若要让已下载的旧节点也失效，仍需另行关闭旧服务或轮换凭据。

D1 基础分配保持：`dawn → dawn,tx`、`zw → zw,tx`、`gj → gj,tx`、`crj → crj,tx`。`tx` 是已迁至 LA 的独立直出服务。普通账号权限由 D1 保存，URL 参数和前端列表不能扩大权限。gw 通过可信服务端配置 `SUB_ADMIN_USERS=dawn` 额外授权 DAWN 查看、导入全部四条 ISP 和公共直出；其余账号仍仅看同名 ISP 和公共直出。此权限不包含管理他人的账号或密码。

界面编号统一显示为 `DAWN / ZW / GJ / CRJ`，内部值不变。客户端节点去掉 `T-` 前缀，例如 `DAWN-TJ`、`DAWN-HY2`；直出为 `DIRECT-TJ`、`DIRECT-HY2`。页面精简为额度和导入按钮，链接与 Telegram 模块放入折叠区。

每人个人 ISP 每月 100 GB，整机全员共用 1000 GB，UTC 每月 1 日重置；超额只提醒，不停止服务。公共直出适合视频和下载。后台使用签名采集报告，当月没有记录时初始化为 0，有记录按数据库累计值显示；数据库故障不当作没有记录。接口、计量口径、隔离部署和迁移 SQL 见 [流量计量](../metering/README.md)。正式启用前先执行更新后的 `schema.sql`；采集密钥与登录密钥必须分开。

登录页与个人页面统一使用“自由翱翔”品牌。每条获授权线路提供“导入 Clash”“导入 v2rayNG”和“导入 Shadowrocket”：前两者将完整个人订阅 URL 编码为协议链接的 `url` 参数；Shadowrocket 使用 `shadowrocket://add/sub://` 加完整 URL 的 Base64 编码。账号的 ISP 与令牌不会因参数截断丢失。v2rayNG 入口用于 Android，Shadowrocket 入口用于 iPhone / iPad；未安装或浏览器无法唤起时，可复制同一专属链接手动导入。网页不自动启动客户端，也不宣称已经完成客户端内的导入。

快捷导入交付的是可持续更新的远程订阅 URL，不是一次性节点内容。相同账号在重复登录、退出和配置重新发布后保持同一订阅地址；节点接口保留 `Profile-Update-Interval: 24` 小时提示，客户端可手动更新，定时更新是否启用取决于客户端设置。只有主动重置订阅令牌或禁用账号等授权操作才会撤销旧链接。

Telegram 模块 `/sr` 保留，并在每条线路下提供“复制模块”入口。这是 Shadowrocket 的可选高优先级分流模块，不是节点订阅；把模块链接加入“配置 → 模块”并启用即可。Telegram 本身不依赖这个模块：现有分流规则或全局代理能正确代理 Telegram 时可以不添加。模块用于避免其他规则误将 Telegram 分到直连，不包含节点凭据。预览清单与正式生成清单都包含该入口。

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

## gw 独立节点凭据

`SUB_AUTH_ISP_CREDENTIALS_FILE` 可指定站外 0600 JSON 文件：顶层必须恰好包含全部有效 ISP ID，每项包含 `trojan`、`hysteria`、`obfs` 三个不同的 24–128 位 URL-safe 随机值。构建时验证所有值不重复，并仅注入 Functions 内部模板；公开清单和 `/api/me` 不包含这些字段，`/s` 在返回前按账号过滤。未启用鉴权时拒绝此选项，未指定文件时保持原有生成行为。

该文件仅控制鉴权站的客户端凭据，不修改运行中的代理。必须先在独立代理配置匹配凭据、用 `ISP_PORT_OVERRIDES` 指向独立端口并实测，再发布 gw。公共直出仍使用独立的 `TX_DIRECT_*` 变量。`SUB_USAGE_SOURCE=la-gw` 写入 Pages 配置，避免测试账本与未来旧节点计量混用；`SUB_METER_KEY` 通过独立 Secret 注入，不写入 `.env.example` 或 Git。

## 全线路查看权限

`SUB_ADMIN_USERS` 是服务器配置的账号白名单，默认空，不能由查询参数、请求头或前端授予。账号必须已经登录（或使用有效订阅令牌）且处于启用状态；禁用账号、撤销令牌和移除白名单仍会立即生效。当前仅在 gw 配置 `dawn`，dl 不改变。

DAWN 页面显示全部线路，每张卡片使用该 ISP 的真实用量和独立 100 GB 额度。DAWN 自己的个人合计仍由 D1 原始分配 `dawn,tx` 决定，不加上其他三人的流量。管理员带 `isp` 的订阅头使用对应 ISP 用量；汇总订阅使用整机公共池的 `Subscription-Userinfo`，不合并几个人的 100 GB 额度。公共直出仍使用整机 1000 GB 额度。

部署验证文件中 DAWN 的有效 `scopes` 应列出全部线路并显式设置 `can_view_all: true`，同时保留普通账号用于验证越权拒绝；这只是测试期望，不修改 D1 基础分配或生成新的登录/订阅令牌。

## 旧 dl 订阅停用

原 `sub-converter` 项目保留首页跳转至 `https://gw.1761.org/`，其余订阅、清单、模块、静态节点文件和隐藏路径均返回 **410 Gone**。只允许预先列出的 `/rules/` 公共规则文件继续读取。gw 的 `free-flight-gw` 项目、D1、账户和代理服务不变。

- 在旧发布目录设置 `SUB_LEGACY_RETIRED=true` 与 `SUB_PORTAL_REDIRECT_URL=https://gw.1761.org`，运行 `node scripts/build-retired.mjs cloudflare-pages-sub` 生成不含凭据的关闭站点，再发布到原项目。生成前先在站外私有目录备份；不得将旧站含凭据的备份上传。
- 构建会删除旧 Functions、隐藏重写和节点/清单文件，只发布关闭 Worker、安全规则和入口。`.subscriptions-retired` 标记会在变量遗漏时继续维持关闭，拒绝作用于已有鉴权的 gw 项目。
- 原 `install.sh --pages-only` 在退休标记或开关存在时拒绝重新生成公开订阅。日常 `sync-clash-rules.sh --deploy` 会再次构建关闭站点后发布，避免定时任务恢复旧入口。
- 使用 `SUB_PORTAL_REDIRECT_URL=https://gw.1761.org node scripts/verify-retired.mjs https://dl.1761.org` 检查关闭状态，并检查项目默认域名和部署地址。项目 Functions 应 fail closed；即使静态回退发生，构建目录也没有节点凭据。
- 新关闭版本验证成功后，通过 Pages API 移除原项目的其他历史部署及其别名。只保留关闭版本，不保留可公开访问的旧订阅快照；备份留在服务器私有目录。不要删除或修改 gw 项目的历史部署。

关闭订阅下载不会撤回客户端已经保存的节点密码。本次不重启或停用旧代理、不修改 gw 线路；需要停用旧节点本身时应另行安排。

所有有效节点订阅均提供客户端流量条所需的 `Subscription-Userinfo` 和网页入口 `Profile-Web-Page-URL`；无当月记录也显示零和额度，导入时间不影响计量。部分统计/待同步保留已记录数值，网页显示状态；统计查询异常返回 503，让客户端保留上次用量。UTC 每月 1 日清零仅通过新账期实现，不删除历史。
