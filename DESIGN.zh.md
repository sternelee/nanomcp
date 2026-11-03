# nanomcp 设计说明

一个带窗口的 MCP 网关：把多个 MCP 服务器聚合到一个端点、一份工具列表、一份调用记录；
五页界面，三种上游 transport，上游 OAuth，自建 OAuth 授权服务器，Market registry 搜索、
配置导入与菜单栏。

- 平台：macOS、Linux、Windows；nanoui 0.17；零依赖；MIT。
- 每文件 ≤600 行；无 C shim；三平台都要构建。
- 测试不开真窗口、不发合成输入（`ui.Tester`、`--nanoui-snapshot`、`--nanoui-eval`）。
- 不轮询；分配的对象要释放（`objc.Pool`）；每个 widget 行为配测试。
- 性能改动须 hillclimb（`hillclimb/`，5 场景，±5% 为噪声）。

## nanoui 接口参考

- 入口：`nanoui.App.create(init, .{.name=...})` →
  `app.newWindow(.{.title,.width,.height,.min_width,.min_height,.content=.{.view=.init(&state, viewFn)}, .should_close=.{.ctx,.func}})` → `app.run()`。
  view 签名 `fn view(s:*State, c:*ui.Context) void`，立即模式每帧跑。
- 线程 → 主线程：`objc.dispatchMain(ctx, workFn)`、`objc.dispatchAfter(ns,...)`、
  `App.after(ms, ctx, fn)`；后台算完调用 `w.redraw()` 触发重画。
- 文件描述符：`nanoui.fdwatch.readable(fd, ctx, handler)` / `.exited(pid,...)`，
  主线程回调、不轮询。
- 目录：`nanoui.path(gpa, .{.data|.cache|.home|...}, app_name)` 给出用户数据目录，
  data/cache 自动创建；`servers.json`、`gateway-tokens.json`、`credentials/` 都在这里。
- 网络：`std.http.Client`（Zig 0.17，线程安全连接池，TLS 默认开）用于 registry 与 OAuth；
  服务端用 `std.http.Server` 加自己的 accept 循环。
- Tray：`app.newTray(.{...})`、`tray.setSymbol/setMenu/setTitle`；`app.setMenu(template)`。
  window：show/hide/focus/redraw/setTitle/isVisible。
- UI 原语：column/row/card/scroll/divider/text/textf/button/checkbox/toggle/slider/
  segmented/textField/div 链式/list(虚拟化)/icon/label/badge/spacer/pressable/image；
  `ui.keys.label("⌘P")`；`Shortcut`/`c.OnShortcut`；Theme 在 `theme.zig`。
- `ui.Tester`：`t.init(gpa, .init(&state, view), .{})`、clickText/hasText/screenshot/runScript。
- Liquid Glass `.glass(.{})`；主题跟随系统 `nanoui.isDark()`。

## 配置

### 基本类型

- `Transport`: `stdio | sse | http`，label 分别为 `"stdio"`、`"SSE"`、`"HTTP"`。
- `InboundMode`: `off | token | oauth`；`RequiresToken()` = `token || oauth`；
  label `"Off"`、`"Token"`、`"Token + OAuth"`。
- 默认端口 `7331`。

### ServerConfig

字段：`id`（稳定，16 个十六进制字符；新 id 为 8 字节随机数）、`name`、`alias`、
`transport`、`enabled`（默认 `false`）、stdio 的 `command`/`args`/`env`（`"K=V"`）、
SSE/HTTP 的 `url`/`headers`（非密）/`oauth`，以及静态凭据的 `tokenHeader`/`tokenScheme`
（token 本身存凭据库，不写进配置文件）。

校验：

- `name` 必填（去空白后非空）。
- stdio：`command` 必填；不能开 OAuth 或设置 token header。
- SSE/HTTP：`url` 必填且以 `http://` 或 `https://` 开头；OAuth 与 token header 互斥；
  token header 必须是合法 header 名 `[a-zA-Z0-9_-]`。

失败消息：`"name is required"`、`"unknown transport <q>"`、
`"command is required for stdio servers"`、`"signing in is only for SSE and HTTP servers"`、
`"URL is required for <label> servers"`、`"URL must start with http:// or https://"`、
`"the token and signing in cannot both be used"`、`"<q> is not a valid header name"`。

### Config

字段：`port`、`servers`、`inbound`、`sidebarCollapsed`；默认 `{port: 7331, inbound: off}`；
`Server(id)`、`Upsert`、`Remove`。

`EnsureAliases()`：alias 为空时由 name 生成——转小写，保留字母数字，`-_空格.` 转 `_`，
去掉尾部 `_`，结果为空则用 `"server"`；冲突时追加 `_2`、`_3`…，返回是否改动。

### 文件

- 路径：`<user data>/servers.json`。
- 读取：文件不存在→默认配置；`port` 为 0→7331；读后 `EnsureAliases`。
- 保存：2 空格缩进的 JSON，末尾换行；先写临时文件（0600）再原子 rename。

### 凭据库

接口 `get/set/delete`。没有系统钥匙串，值都放在 `<user data>/credentials/`：
目录 0700，文件 0600。键：

- `oauth-token/<id>`
- `oauth-client/<id>`
- `upstream-token/<id>`
- `inbound-token`

API：上游 token 的读/判断/写；入站 token 的读/写；client 凭据
`{client_id, secret, issuer, auth_method}` 的读/保存；`SignedIn(id)`（token 非空且未过期）；
`SignOut`；按 server id 的 token store（`GetToken`/`SaveToken`）。测试用内存实现。

### 导入

接受三种形状：

- 容器键：`mcpServers`、`servers` 或 `mcp`；
- 单个服务器对象（识别 `command,url,type,transport,args,env,headers,oauth`）；
- 裸的 name → server map。

错误文案：`"there is not..."`、`"the configuration should be a JSON object"`、
`"no servers were found in that configuration"`。

单个服务器：

- name 取键名或 `name` 字段；无名字时用 command 的 basename、URL 的 host，或
  `"Imported server"`。
- `enabled` 默认 true，可被同名字段覆盖。
- transport 推断：`type`/`transport` 为 `stdio`、`sse`/`event-stream`、
  `http`/`streamable-http`；没有 type 但有 command→stdio；没有 type 但有 url→http。
- 校验失败时错误前缀 `"name: "`。
- `args`、`env` 等列表字段接受单字符串或数组；env 输出排序后的 `"K=V"`。
- 导入按 name 大小写不敏感匹配：已有→保留 id 与 alias，计入 updated；否则生成新 id，
  计入 added；之后 `EnsureAliases`。
- 摘要：`"Nothing was imported"`、`"Imported N server(s)"`、`"Updated N server(s)"`、
  `"Imported X and updated Y"`。

## 网关

### 基本约定

- 工具名分隔符 `"__"`；元工具名 `"gateway__list_servers"`；事件上限 500。
- 状态：`disabled | connecting | ready | needs-auth | error`。
- `ToolView`：带 alias 前缀的名称、上游名、server id/name、描述、缩进后的 JSON schema。
- `ServerView`：配置、状态、错误、工具、`signedIn`。
- `Event`：时间、serverID、文本、是否错误。

### 同步

同步由一把 mutex 串行化。每次同步：

1. 刷新凭据（上游登录状态与入站 token）。
2. 配置里已删除或禁用的上游：断开、注销工具，记 `"disconnected X"`；禁用项状态设为
   `disabled` 并清掉错误。
3. 已启用但未连接的上游：状态设为 `connecting`，逐个连接并收集错误。
4. 每个连接：
   - 需要登录（非 stdio、无静态 token header，且 OAuth 或服务器要求授权）→
     `needs-auth`，记 `"X: sign in required"`；
   - 其他失败→`error`，记下原因；
   - 成功→保存上游、状态 `ready`、注册工具，记 `"X: N tools"`。
5. 每次变更通知界面。

### 工具注册

- 名称：`alias + "__" + 工具名`。
- 描述为空→`"From X."`，否则 `"[X] desc"`。
- 调用失败返回工具结果错误（不是协议错误）：`"X: err"`。
- 卸载按 server id 删除工具与路由。

### 服务

- 端口 1..65535；已在服务→错误。
- 只监听 `127.0.0.1:port`；读请求头超时 15s。
- 端点：
  - Streamable HTTP：`/mcp`
  - SSE：`/sse` 与 `/message`
  - `/healthz`
  - 上游 OAuth 回调：`/oauth/callback`
  - `/.well-known/oauth-protected-resource[/{path}]`（resource path 为 `mcp`、`sse`）
  - OAuth 模式另有：`/.well-known/oauth-authorization-server`、`/oauth/register`、
    `/oauth/authorize`、`/oauth/token`
- 失败→记 `"serving stopped: ..."`；成功→记 `"serving on <base>"`。
- 已服务时端口来自实际监听；`BaseURL()` 在未服务时用配置端口；
  `redirectURI()` = `BaseURL + "/oauth/callback"`；`Endpoints()` = `/mcp`、`/sse`、
  `/message`、`/healthz`。

### 停止

取得同步锁，关闭 listener，清空上游/状态/错误/路由与待处理授权，逐个关闭上游，
最多等 5 秒关闭；记 `"gateway stopped"`。

### 健康检查与调用

- `GET /healthz` → `{"status":"ok","tools":N}`。
- `CallTool(name, args)`：查路由后调用上游；未知工具→`unknown tool "x"`；
  所属服务器未连接→`server of tool "x" is not connected`。
- `Tools()` 按名称排序；schema 优先用原始 `inputSchema`，无效则用 `inputSchema` 的缩进 JSON。

### 上游

连接步骤：启动 client → `initialize`（最新协议版本，clientInfo
`{name: "mcp-gateway", version}`）→ `tools/list`。每一步失败先判断是否属于“需要登录”：
非 stdio、无静态 token header，且配置了 OAuth 或错误要求授权；否则把 stderr 附在错误后。

client 选择：

- stdio：子进程，环境 = 应用环境 + 配置项；PATH 自动补齐常见安装目录（`/opt/homebrew/bin`、
  `/usr/local/bin`、`~/.local/bin` 及系统目录），不含 `/` 的命令先在这些目录中解析。
- SSE：OAuth 时带 OAuth 配置，否则带配置 headers。
- HTTP：同上，使用 streamable HTTP。

`oauthFor` 条件：非 stdio，且（强制 OAuth、配置开 OAuth，或无静态 token header 且已登录）。

请求头：配置 headers + 静态 token。scheme 去空白后为空→裸 token，否则 `"scheme token"`；
token 覆盖同名手写 header。

OAuth 配置：已存的 client id/secret/issuer/auth method、redirect URI、PKCE、token store，
以及 30 秒超时的 HTTP client。

stderr 日志：最多 50 行，单行超过 512 字节截断并加 `"..."`；展示时按行拼接。

### 会话

- 记录：id、client、version、protocol、connected、last active、calls。
- 注册会话→记录时间；注销→记 `"agent disconnected: <name|id>"`。
- initialize 后首次拿到 client 名→记 `"agent connected: X"`。
- 每次 `tools/call` 更新 calls 与 last active。
- 列表按 connected 时间升序（先连接的在先）。

## 入站鉴权

自建 OAuth 授权服务器与入站 guard。

- scope `"mcp"`；授权码 TTL 5 分钟；resource paths 为 `mcp`、`sse`。
- guard：
  - 模式不需要 token→放行。
  - `Authorization: Bearer x`（scheme 大小写不敏感）等于期望 token（常量时间比较），
    或属于已签发 token→放行。
  - 否则 401，`WWW-Authenticate: Bearer resource_metadata="<base>/.well-known/oauth-protected-resource/<path>"`，
    body `{"error":"invalid_token","error_description":"this gateway requires a bearer token"}`。
- `AuthState`：模式、是否有 token、已签发数量、metadata URL、是否授权服务器。
- 生成 token；设置模式时：模式无效→错误；需要 token 且留空且没有已知 token→
  `<mode> mode needs a token`；非空→保存并缓存；切换模式保留旧 token。
- 吊销全部已签发 token。
- 受保护资源元数据（RFC 9728）：
  `{resource: resourceURL(path), resource_name: "MCP Gateway", bearer_methods_supported: ["header"], scopes_supported: ["mcp"]}`，
  OAuth 模式下加 `authorization_servers: [base]`。
- 授权服务器元数据（RFC 8414）：
  `{issuer, authorization_endpoint, token_endpoint, registration_endpoint,
  response_types_supported: ["code"],
  grant_types_supported: ["authorization_code", "refresh_token"],
  code_challenge_methods_supported: ["S256"],
  token_endpoint_auth_methods_supported: ["none"],
  scopes_supported: ["mcp"]}`。
- 注册：只接受 POST，body ≤64KB；需要 `client_name` 与 `redirect_uris`。
  - 没有 redirect→`invalid_redirect_uri` `"at least one redirect_uri is required"`；
  - 非 http/https 或没有 host→`invalid_redirect_uri` `<q> is not an http or https URL`；
  - 成功→201 `{client_id, client_name, redirect_uris, token_endpoint_auth_method: "none", grant_types, response_types}`，
    记 `"registered OAuth client <name|(unnamed)>"`。
- 授权：GET/POST。
  - `redirect_uri` 必须在 client 注册列表（否则 400 HTML 错误页）。
  - `response_type != code`→重定向 `unsupported_response_type`。
  - 缺 challenge 或 method 不是 S256→`invalid_request`
    `"PKCE with code_challenge_method=S256 is required"`。
  - GET→同意页（隐藏字段回 POST `/oauth/authorize`，文案
    `"Allow this client to use MCP Gateway?"`）。
  - POST→生成 code，302 回 `redirect_uri?code&state`。
- 换 token：POST。
  - `authorization_code`：先取后验（一次性），校验 client id、redirect URI、
    PKCE（SHA256 + base64url raw，常量时间）→签发 access 与 refresh，
    返回 `{access_token, token_type: "Bearer", expires_in, scope: "mcp", refresh_token}`。
  - `refresh_token`→续期。
  - 其他→`unsupported_grant_type`
    `"only authorization_code and refresh_token are supported"`。
  - 响应 `Cache-Control: no-store`。

## 令牌持久化

- access token 12 小时，refresh token 30 天。
- 文件 `<user data>/gateway-tokens.json`：
  `{access: {<sha256hex>: {client_id, scope, expires_at}}, refresh: {...},
  clients: {<id>: {redirect_uris, registered_at}}}`；键是 token 的 sha256，文件本身不泄权。
- 先写临时文件（0600）再原子 rename；坏文件忽略；读取时清理过期项。
- token 为 32 字节随机数的 base64url raw；授权码 TTL 5 分钟且只能使用一次。

## 上游 OAuth 流程

- 待处理授权 TTL 5 分钟；开始授权超时 60 秒。
- 开始前校验：
  - stdio 或带静态 token header→`"does not sign in with OAuth"`；
  - 未在服务→`"start the gateway first..."`；
  - 已连接且已登录→返回空 URL；
  - 需要认证时，若有 client id 直接授权，否则动态注册（clientName `"MCP Gateway"`）
    或提示手动填写 client id/secret。
- 生成 state 与 PKCE verifier，打开授权 URL，记
  `"waiting for sign-in in the browser"`，保存 client 凭据。
- 回调：错误、state、code、过期各有错误页文案
  （例如 `"This sign-in has expired, or was already completed..."`）；
  成功→保存 token、保存 client、标记已登录、记 `"signed in to X"`，
  成功页文案 `"You can close this tab and return to nanomcp."`，然后重连。
- 退出登录：删除 token、标记未登录、重连。
- 回调页配色：正常文字 `#111`，错误 `#b00020`，次要文字 `#555`。

## Registry（Market）

- 默认地址 `https://registry.modelcontextprotocol.io`；client 可注入
  `{base_url, http}`，测试可替换。
- 服务器字段：name、description、version、homepage、remotes（type/url）、
  packages（registry type/identifier/version/runtime hint/arguments/env）、updatedAt；
  `ShortName()` 取显示名。
- `GET /v0/servers?search=&cursor=&limit=`，`Accept: application/json`，20 秒超时；
  非 200→`"the registry answered <status>"`；只保留 `_meta...official.isLatest=true` 的条目。
- 包参数 = runtimeArgs + identifier + packageArgs。
- 安装优先：streamable-http remote → sse remote → package。
  包安装：npm→runtime hint 或 `npx`；pypi→runtime hint 或 `uvx`；oci→`docker run -i --rm`；
  其他不可安装。
- `EnvLines`：有默认值→`K=V`，必填→`K=`。

## 界面

### Servers 页

- 页头：spinner（忙时）、Edit、Reconnect、Remove、Paste JSON…、Add server…。
- 空态：`"No servers yet"`。
- 工具栏：搜索框宽 280 + 摘要 + List/Grid 分段。摘要按 ready/needs-auth/error/disabled
  计数，用 `" · "` 连接。
- 过滤：Name/Alias/Transport/Command/URL，小写包含匹配。
- 行高 56：单击选中、双击编辑；头像、名称、详情、状态胶囊、transport 徽章、
  工具数（右对齐 54）；OAuth 服务器可 Connect/Disconnect；启用开关。
- 详情：错误优先；stdio 显示 command + args，否则显示 URL；前缀
  `"Off · "`、`"Connecting · "`、`"Sign in required · "`。
  可登录条件：非 stdio、无 token header，且（OAuth、已登录或 needs-auth）。
- 新增默认：enabled、token header `Authorization`、scheme `Bearer`。
- 表单：
  - 名称、transport 分段；
  - stdio：Command、Arguments（每行一个）、Environment（`K=V`）；
  - 其他：URL、OAuth 开关（说明
    `"The gateway opens your browser and stores the token in the system keychain."`）、
    Client ID/secret、非新建时 “Sign in now”；
  - 非 OAuth：Token header、Token scheme、Token（密码框）；已有 token 时可 “Forget the
    saved token”；其他 headers；
  - Enabled；错误红字；Cancel/Save。
- 保存：校验→Upsert→EnsureAliases→保存；OAuth→保存 client 凭据，否则填了 token→保存上游 token；
  提示 `"X saved"` 并重新同步。
- 删除对话框：`"Remove “X”?"` /
  `"Its tools are withdrawn...forgotten."`；删除→退出登录 + 清 token + `"X removed"`。
- 登录：打开授权 URL；已登录提示 `"Already signed in"`，否则
  `"Finish signing in in your browser"`。
- 导入：JSON 示例占位；解析→导入→保存→摘要。

### Market 页

- 每页 30 条。状态：query、results、cursor、loading、searched、err、seq（防抖）、sel、list。
- 首次访问空查询自动搜索；输入后 400ms 防抖（用 seq 比对）。
- 行：头像、短名、描述、类型徽章（remote / 命令名 / manual）、版本；
  已安装→`"Added"`，不可安装→`"Manual"`，可安装→`"Add X"`。
- 摘要：`"N shown, more on the registry"` / `"N found"`。
- 搜索 30 秒超时；安装后 remote→URL（sse 或 http），本地→command/args/env。

### Routes 页

- 页头右侧 `"N connected"`。
- 空态：`"No agents connected"` + Open Settings。
- 行高 56：头像（client 或 id）、版本、等宽 10px id、protocol 徽章、
  调用数（`"no calls yet"` / `"1 call"` / `"N calls"`）、
  `"connected " + relativeTime`（右对齐 150）。
- `relativeTime`：<1 分钟 `"just now"`，<1 小时 `"Nm ago"`，<24 小时 `"Nh ago"`，
  否则 `"Nd ago"`。

### Tools 页

- 过滤 Name/ServerName/Description。
- 空态：`"No tools yet"` / `"Connect a server on the Servers page…"` + `"Go to Servers"`。
- 过滤后为空：`"No tools match"` / `"Nothing matches %q."` + `"Clear the filter"`。
- 表格列：Tool 200、Server 110、Description；选中行的次要列用强调色。
- 详情（宽 380）：名称、`"%s · %s at %s"`（server、upstream、transport）、描述、
  复制名称与 schema、输入 schema（空→`"No parameters."`）、
  测试调用（JSON 文本区，占位 `{"path": "/tmp"}`）、`"Calling…"`、`"Call tool"`、
  清除结果；结果错误显示为红色。

### Settings 页

四张卡：

- Callers：Off/Token/Token + OAuth 分段与说明文案；需要 token 时显示只读 token、
  `"Send it as: Authorization: Bearer <token>"`、复制、重新生成；授权服务器时显示
  discovery URL、已签发数量、全部吊销。
- Serve：端口 1..65535、保存、启动/停止、状态胶囊；启动时忙提示
  `"Starting the gateway…"`。
- Endpoints：`/mcp`、`/sse`、`/message`、`/healthz` 及复制；
  客户端配置 `{"mcpServers":{"gateway":{"url":BaseURL + "/mcp"}}}`。
- Activity：最近 100 条事件倒序，时间 `15:04:05` 等宽；错误红字。

### 菜单栏

- 托盘图标为模板闪电图；菜单 Open nanomcp、Show Routes、Quit。
- 标题显示已连接 agent 数；提示文字带 `"MCP Gateway · "` 与服务器摘要。
- 面板 360×480，tabs Servers/Routes；行高 40；点击行打开对应页面。

### UI kit

- lucide 风格线性图标：servers、tools、sliders、zap、shield、globe、activity、store、
  routes、chevrons。
- 状态胶囊：ready→成功色、connecting→警告色、needs-auth→强调色、error→危险色、
  其他→次要色；开/关状态用成功/次要色。
- 阴影按背景亮度：Rec601 luma < 0.5→alpha 0.4，否则 0.05。
- 卡片：圆角 12、内边距 18、间距 12、边框 + 阴影，图标 + 标题 + 内容。

## 测试

- 全部测试在进程内运行；UI 用 `ui.Tester` 离屏驱动 1080×740 窗口。
- 每个测试自建 gateway 与内存凭据库，不开窗口；registry 与“打开浏览器”可注入 stub。
- 用户目录用临时目录隔离；测试不写临时目录之外，不碰剪贴板。
- 断言覆盖：空态文案、开关语义、过滤、表单校验、导入、令牌轮换、快捷键提示、
  颜色（状态胶囊/状态点/卡片悬停与阴影）、减少动效时仍能换页、桌面字号与对比度偏好。

## 主题

- Colors：sidebar、picked、on_picked、page、card、border、well、empty、separator、text、
  secondary、tertiary、accent、stripe、selection、on_selection、marked、control、
  control_on、hover、user、system、fast、frugal、gray、blue、green、red、orange、teal、
  purple、yellow。
- Codegraff 配色：暗色背景 `#16140f`、amber `#e8a33d`；亮色背景 `#faf8f3`、amber `#c77d20`。
- 字体 Geist，等宽 JetBrains Mono；`accent_text = on_picked`；danger 红、success 绿。
- 窗口主题跟随系统深浅色；测试可显式传 `theme.ui(false/true)`。

## 并发与生命周期

- 网络调用与握手不阻塞界面：`startAsync/syncAsync/reconnectAsync` 在分离线程里跑
  `sync/reconnect`，用 `sync_mu` 串行；界面只读快照。
- `Session` 的调用默认 30 秒超时；`await` 等到 deadline，超时→`error.TimedOut`；
  `deinit` 先置 closed 并广播，再 join 所有等待者，最后释放待处理表。
- 关闭顺序：`setClosing()`（sync/reconnect 拿到 `sync_mu` 后先查 `closing`，连接循环
  逐个检查）→ `wakeWaiters()`（对每个上游 `markClosed`，等待中的调用立即
  `error.Closed`）→ 取 `sync_mu`。
- `Gateway.deinit() bool`：用 `tryLock` 自旋最多 2 秒；拿不到（还有未注册的 in-flight
  连接）就整体交给进程退出回收并返回 false，`state.deinit` 据此跳过销毁。
  deinit 内含 listener 拆除（关闭全部会话 + 停止 + 销毁）。
- 配置内存由 `cfg_arena` 统一管理：`config.load` 与所有配置变更都从它分配，退出时一次
  `deinit`；保存表单等把字符串原样存入传入的 allocator，因此调用处必须传 `cfgAlloc()`。
