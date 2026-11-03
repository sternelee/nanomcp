# mcp-go → nanoui (Zig) 重写笔记

Task list in this repo's session: #1 read sources (in progress), #2 skeleton,
#3 config, #4 MCP protocol/transports, #5 gateway+auth, #6 registry, #7 UI,
#8 port tests, #9 build/test verification.

## User decisions (ask_user, m00070)
- Location: nanoui 仓库 `apps/` 目录下（新增 `apps/mcp-go`，参照 nanoterm 结构）
- Scope: 一次性全量重写（五页 UI、三种 transport、上游 OAuth、自建 OAuth 授权服务器、
  Market registry 搜索、导入、菜单栏）
- Tests: 移植对应测试（Go 版约 450 个测试函数：main_test.go 1,742 行 UI 测试 +
  internal 各包测试）用 ui.Tester / std.testing 保持行为等价

## nanoui 仓库结构（/Users/sternelee/www/github/nanoui，分支 mcpbox 与 main 同步）
- Zig 0.17.0（/opt/homebrew/bin/zig），v0.2.0，零依赖，MIT，AGENTS.md 硬规则：
  每文件 ≤600 行（`zig build lines`）、无 C shim、三平台都要构建、
  绝不开真窗口/发合成输入（用 ui.Tester、--nanoui-snapshot/--nanoui-script/--nanoui-eval）、
  不轮询、alloc 对象要释放（objc.Pool）、每 widget 行为配测试、
  改动后 `zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux` 和 `-Dtarget=x86_64-windows-gnu`，
  Linux 测试在容器（tools/linux.Dockerfile）跑。
- apps/ 下现有两个独立仓库 submodule：nanoterm（约13.5k行）、nanomon（约5.5k行），
  各自 build.zig.zon pin nanoui git 依赖；`zig build run --fork=../..`（Zig 0.17 内建旗标）
  用旁边的 nanoui 源码覆盖依赖树构建。
- 性能改动须 hillclimb（hillclimb/，5 场景，±5% 为噪声）。

## nanoui 关键 API（供重写用）
- 入口模式（apps/nanoterm/src/main.zig）：`nanoui.App.create(init, .{.name=...})` →
  `app.newWindow(.{.title,.width,.height,.min_width,.min_height,.content=.{.view=.{.ptr=&state,.build=fn} or .init(&state, viewFn)}, .on_close=.{.ctx,.func}})` → `app.run()`。
  `ui.View.init(&state, State.view)`，view 签名 `fn view(s:*State, c:*ui.Context) void`，立即模式每帧跑。
- 线程 → 主线程：`objc.dispatchMain(ctx, workFn)`（async 到主队列）、`objc.dispatchAfter(ns,...)`、
  `App.after(ms, ctx, fn)`；nanoterm 的做法：后台算完 `w.redraw()`（Window.redraw() 触发重画）。
- `nanoui.fdwatch.readable(fd, ctx, handler)` / `.exited(pid,...)`：libdispatch 源，主
  线程回调，不轮询 —— stdio 子进程读输出用这个（nanoterm proc.zig 有完整范例）。
- 目录：`nanoui.path(gpa, .{.data|.cache|.home|...}, app_name)`（macOS ~/Library/...，
  data/cache 自动创建）—— Go 版 mygo.PathUserData 的对应物；存 servers.json、
  gateway-tokens.json、credentials/ 目录。
- 网络：std.http.Client（Zig 0.17，70KB，线程安全连接池，TLS 默认开）；
  服务端 std.http.Server（30KB，per-connection：Server.init(reader,writer) → receiveHead() → Request），
  自己写 accept 循环 + std.net.Server。update.zig 里 nanoui 自己用 /usr/bin/curl 而非
  std.http —— 但 registry/OAuth 需要 POST+header，用 std.http.Client。
- Tray：`app.newTray(.{...})`，`tray.setSymbol/setMenu/setTitle`；菜单 `app.setMenu(template)`、
  `app.after(ms,...)`；window: show/hide/focus/redraw/setTitle/isVisible。
- UI 原语（src/ui/ui.zig）：column/row/end/card/scroll/divider/text/textf/button/checkbox/
  toggle/slider/segmented/textField/div(c).row().gap(8) 链式/list(虚拟化)/icon/label/badge/
  spacer/pressable/image；`ui.keys.label("⌘P")`；Shortcut/`c.OnShortcut`；Theme（theme.zig）。
  ui.Tester：`t.init(gpa, .init(&state, view), .{})`、clickText/hasText/screenshot/runScript。
- Liquid Glass `.glass(.{})`（macOS 26 材质），侧边栏玻璃可选；主题跟随系统 isDark()。

## mcp-go（/Users/sternelee/www/gitee/mcp-go）源码分析
Go 1.27，mygo v0.5.1 框架 + mark3labs/mcp-go v1.3.0（client/transport/mcp/server 包）。
27 个 .go 文件，10,808 行（含 1,742 行 main_test.go）。mygo.json: name mcp-go,
identifier dev.mcpgo.gateway, out build。resources/icon.png。
版本 const version = "0.1.0"。

### main.go（99 行）
config.Load（失败→Default）→ NewCredentialStore → gateway.New(cfg,creds,version) → newApp。
mygo.App.WhenReady: NewWindow(1080x740, min 820x560, StateKey "main", VibrancySidebar,
Content ui.View(a.view))；OnBeforeQuit 设 quitting + gw.Stop；关窗 e.PreventDefault()→Hide()
（菜单栏/Dock icon 再唤起）；runMenubar → a.onReload=mb.refresh, a.openMain=mb.open；
gw.SetOnChange(a.onChange)；go a.boot()。boot: busy="Starting the gateway…", gw.Start(ctx, cfg.Port),
完成后 busy="" + reload + 失败 toast。

### app.go（626 行）— UI 状态与外壳
- serverForm{editing,isNew,id,name,transport(int),command,args,env,url,headers,oauth,enabled,
  tokenHeader,tokenScheme,token,hasToken,clientID,clientSecret,err}
- transportOptions = ["stdio","SSE","HTTP"]
- pageDef{path,title,icon}; pages: /servers,/market,/routes,/tools,/settings（Cmd+1..5）
- inboundModes = [InboundOff, InboundToken, InboundOAuth]
- app struct: cfg,creds,gw,win,router(新窗口"/servers",Animation=ui.Snappy),panel(flyout),
  onReload,openMain,serversList/toolsList ui.ListState, status map[string]gateway.ServerView,
  tools []gateway.ToolView, events, flags map[string]*bool（稳定 bool 指针，enabled 开关）,
  sel,toolSel,panelTab,port(f64),busy,pending(toast),filter,serverView(0列表/1卡片),
  sidebarCollapsed,toolFilter,form,imp(importForm{open,text,err}),confirm,removeID,
  serversGrid,reg(registry.Client，测试可 stub),market,openExternal(测试可观察),
  auth(gateway.AuthState),authToken,authMode,callArgs,callResult,callErr,calling。
- reload(): 从 gw 拷 status/tools/events/auth/authToken/authMode + clampToolSelection，主
  线程跑；onChange→post(a.reload)；post: win!=nil 才 win.Update(fn)（测试无窗口时跳过）；
  toast: pending → 下帧 c.Toast()；sync(): busy="Connecting servers…", go gw.Sync → 回主线程。
- view(): toast→pageShortcuts(Cmd+数字)→vibrant时 Root 透明→Row{sidebar, content(Grow1,
  minWidth0, vibrant时加背景)}→router.View 分派五页→serverForm/importDialog/removeDialog。
- sidebar(216px/rail 64px, Animate 180ms)：head(折叠按钮+品牌 zap 图标+"MCP Gateway"+
  v0.1.0)、ui.Sidebar+SidebarItem(tooltip 含 ⌘N)、Divider、底部 livePill(serving/stopped)+
  summary()("N of M servers ready"/"No servers configured")；折叠状态存 cfg.SidebarCollapsed。
- 公共件：pageHeader(title,subtitle,actions)、emptyState、statusColor(Ready=Success,
  Connecting=Warning, NeedsAuth=Accent, Error=Danger, else TextMuted)、statusLabel
  (ready/connecting/sign in/error/off)、splitLines、parsePairs("Key: value"→map)、
  formatPairs(排序写回)。
- summary(): ready 数 / len(cfg.Servers)。

### internal/config（338+309+314+tests 行）
- Transport enum: stdio|sse|http, Label()→"stdio"/"SSE"/"HTTP"。
- InboundMode: off|token|oauth; RequiresToken() = token||oauth; Label()→"Token"/"Token + Off"→"Token + OAuth"/"Off"。
- DefaultPort = 7331。
- ServerConfig{ID(stable,16hex NewID=8字节hex),Name,Alias,Transport,Enabled,
  Command,Args,Env([]"K=V"),URL,Headers(map,非密),OAuth,TokenHeader,TokenScheme}。
  Validate(): name必填; stdio→command必填且不能OAuth/TokenHeader; http/sse→URL必填且
  http(s)://开头; OAuth和TokenHeader互斥; TokenHeader须合法header名[a-zA-Z0-9_-]。
- Config{Port,Servers,Inbound,SidebarCollapsed}; Default={Port:7331,Inbound:off};
  Server(id),Upsert,Remove; EnsureAliases(): alias空则用Name→aliasFor(小写,字母数字保留,
  -_空格.→_,trim _,空则"server")，冲突则 _2,_3…（返回是否改动）。
- Path(): mygo.PathUserData + "/servers.json"; Load()（无文件→Default，port0→7331，
  EnsureAliases）; Save(): MarshalIndent 2空格+换尾换行, tmp 0600 原子 rename。
- CredentialStore: backend 接口 get/set/delete。NewCredentialStore=mygo.Secrets（keychain）
  回退文件（dir = userData/credentials, key 带子目录: "oauth-token/<id>.json" 等, 0600,
  dir 0700, MaxSecretSize 内优先 keychain）；NewMemoryCredentialStore=测试用内存 map。
  Keys: "oauth-token/"+id, "oauth-client/"+id, "upstream-token/"+id, "inbound-token"。
  API: UpstreamToken/HasUpstreamToken/SetUpstreamToken, InboundToken/SetInboundToken,
  Client(id)→ClientCredentials{ClientID,Secret,Issuer,AuthMethod}, SaveClient,
  SignedIn(id)（读 token JSON: AccessToken非空且未过期）, SignOut, TokenStore(id)
  （适配 mcp-go transport.TokenStore: GetToken/SaveToken）。
- import.go: ParseMCPConfig — 容器键 ["mcpServers","servers","mcp"]，或单服务器对象
  (serverKeys: command,url,type,transport,args,env,headers,oauth)，或裸 name→server map。
  空→"there is not..."错误、非{→"the configuration should be a JSON object"、
  空map→"no servers were found in that configuration"。parseServer: name取键或raw.Name，
  Enabled默认true（可被raw.enabled覆盖），transport推断(type/transport→stdio/command/
  sse/event-stream/http/streamable-http/...；空type+command→stdio，空+url→http)，
  无名→defaultName(command的base / URL host / "Imported server")，Validate失败即错
  (错误带 "name: " 前缀)。stringList 接受单字符串或数组。keyValues env 排序 "K=V"。
  Config.Import(servers): 按 name 大小写不敏感匹配→保留 ID+Alias 计 Updated，否则
  NewID 计 Added，Upsert 后 EnsureAliases。ImportResult.Summary(): "Nothing was imported" /
  "Imported N server(s)" / "Updated N server(s)" / "Imported X and updated Y"。

### internal/gateway
- 常量: separator="__"; metaToolName="gateway__list_servers"; maxEvents=500;
  Status: disabled|connecting|ready|needs-auth|error。
- route{serverID,upstream,def}; ToolView{Name(带前缀),Upstream,ServerID,ServerName,
  Description,Schema(缩进JSON)}; ServerView{Config,Status,Err,Tools,SignedIn};
  Event{Time,ServerID,Text,Err}。
- Gateway 字段: cfg,creds,srv(下游 server.MCPServer),syncMu(串行 Sync/Reconnect/Stop),
  mu,upstreams,routes,status,errs,signedIn(缓存 keychain 读),authToken(缓存),
  tokens(*issuedTokens),events,pending(map pendingAuth),sessions,stream(StreamableHTTPServer),
  sse(SSEServer),http,port,onChange,version。
- New(): srv=mcp.NewMCPServer("mcp-gateway",version, WithInstructions("A gateway that
  aggregates...Tool names are prefixed..."), WithToolCapabilities(true)(发 tools/list_changed),
  WithRecovery(), WithHooks)；registerMetaTool()；trackSessions()。
- meta 工具 handler: 返回 {servers:[{name,transport,status,tools,error?}],tools:N} 缩进JSON。
- RefreshCredentials(): 对每个 非stdio且无TokenHeader 的 server 读 creds.SignedIn→signedIn map；
  inbound RequiresToken 时读 InboundToken→authToken（空 token 或不需要时才更新 authToken）。
  在后台线程调（读 keychain 慢）。
- Sync(): syncMu；RefreshCredentials；stale(配置里没了/禁用)→摘除+unregister+异步 Close+note
  "disconnected X"；enabled 未连→status=connecting+todo；逐个 connectOne（错误收集
  errors.Join）；禁用→status=disabled+删err。connectOne: connect() 失败时 NeedsAuthError
  →status=needs-auth+note "X: sign in required"；其他→status=error+note err；成功→存upstream,
  status=ready, registerLocked, note "X: N tools"。changed() 每次变更回调 onChange。
- registerLocked: 每工具 name=alias+"__"+t.Name，Description 空→"From X." 否则
  "[X] desc"，handler 调 owner.CallTool 失败→NewToolResultError("X: err")（工具错误不
  是协议错误），存 routes。unregisterLocked 按 serverID 删+DeleteTools。
- Start(port): port 1..65535; 已服务→错；base="http://127.0.0.1:port"；StreamableHTTP
  挂 /mcp，SSE 挂 /sse + /message(StaticBasePath"/",BaseURL=base)，/healthz；全部
  guard(resourcePath) 包裹。常驻端点: /oauth/callback（上游回调）、
  WellKnownProtectedResourcePath + resourcePaths=["mcp","sse"] 的
  /.well-known/oauth-protected-resource[/{path}]、oauth 模式才开:
  /.well-known/oauth-authorization-server、/oauth/register、/oauth/authorize、/oauth/token。
  net.Listen("127.0.0.1:port")（仅本机）；ReadHeaderTimeout 15s；goroutine Serve，
  Err以外错误→note "serving stopped: ..."；note "serving on <base>"；Sync 忽略错误。
- Stop(): syncMu；关 http，清 upstream/status/errs/routes，pending 重置，逐个 up.Close()，
  Shutdown 5s 超时；note "gateway stopped"。Serving()/Port()/BaseURL()（未服务用cfg.Port）/
  redirectURI()=BaseURL+"/oauth/callback" / Endpoints()=[/mcp,/sse,/message,/healthz]。
- handleHealth: GET → {"status":"ok","tools":N}。
- CallTool(name,args): 查 routes→upstream.CallTool；未知→`unknown tool "x"`；
  未连→`server of tool "x" is not connected`。
- Tools(): 排序 by name；schemaJSON: RawInputSchema 有效则 indent，否则 InputSchema indent。
- Upstream{Config,client,tools}: Tools()、CallTool(tools/call)、Close()。
- connect(): LogBuffer(50) 收 stderr → newClient → Start → Initialize(protocolVersion=
  LATEST, clientInfo {Name:"mcp-gateway",Version}) → ListTools；每步失败 needsAuth 检查
  （非stdio且无TokenHeader 且 OAuth/authorization required 错误）→NeedsAuthError，
  否则 withLogs(err, stderr)（err+"\n"+stderr文本）。
- newClient: stdio→NewStdioMCPClientWithOptions(cmd,env,args, WithCommandStderrWriter(logs));
  sse→oauthFor ? NewOAuthSSEClient(url,oauthConfig) : NewSSEMCPClient(url, WithHeaders);
  http→oauthFor ? NewOAuthStreamableHttpClient : NewStreamableHttpClient(WithHTTPHeaders)。
- oauthFor: 非stdio 且 (forceOAuth || sc.OAuth || (无TokenHeader && creds.SignedIn))。
- requestHeaders: sc.Headers + TokenHeader 时 creds.UpstreamToken 经 tokenValue(scheme,token)
  （scheme trim 空则裸token，否则 "scheme token"），token 覆盖同名手写 header。
- oauthConfig: creds.Client(id) 的 ClientID/Secret/Issuer/AuthMethod + RedirectURI=
  opts.redirectURI + TokenStore=creds.TokenStore(id) + PKCEEnabled + 30s HTTP client。
- LogBuffer(50行,单行512截断加"…"): Write 按\n切行，无\n超512也切；Lines/String。
- sessions.go: SessionView{ID,Client,Version,Protocol,Connected,LastActive,Calls}；
  hooks: OnRegisterSession→记 sessions[id]{Connected:now}；OnUnregister→删+note
  "agent disconnected: <name|id>"；AfterInitialize/AfterDiscover→introduce(clientInfo,
  protocol)（首命名→note "agent connected: X"）；BeforeCallTool→Calls++/LastActive。
  Sessions() 按 Connected 升序。

### internal/gateway/auth.go（自建 OAuth 授权服务器 + 入站 guard）
- authScope="mcp"; authCodeTTL=5min; resourcePaths=["mcp","sse"]。
- guard(resourcePath,next): mode 不需token→放行；bearerToken(r)（Authorization: Bearer x，
  case-insensitive scheme）== want(constant-time) 或 g.tokens.accepts(presented)→放行；
  否则 401 + WWW-Authenticate: Bearer resource_metadata="<base>/.well-known/oauth-protected-resource/<path>"
  + {"error":"invalid_token","error_description":"this gateway requires a bearer token"}。
- serveAsAuthServer: 非 oauth 模式→404。
- inbound(): 缓存的 (cfg.InboundMode(), authToken)。
- AuthState{Mode,HasToken,IssuedTokens,MetadataURL,AuthorizationServer}。
- GenerateAuthToken()=randomToken；SetInbound(mode,token): mode 无效错；RequiresToken 时
  token 和已知都空→`<mode.Label()> mode needs a token`；token非空→creds.SetInboundToken+缓存；
  cfg.Inbound=mode；切模式保留旧 token。RevokeIssuedTokens→tokens.revokeAll+note。
- handleProtectedResource: RFC9728 {resource: resourceURL(path), resource_name:"MCP Gateway",
  bearer_methods_supported:["header"], scopes_supported:["mcp"], oauth模式加
  authorization_servers:[base]}。
- handleAuthServerMetadata: RFC8414 {issuer, authorization_endpoint, token_endpoint,
  registration_endpoint, response_types_supported:["code"], grant_types_supported:
  ["authorization_code","refresh_token"], code_challenge_methods_supported:["S256"],
  token_endpoint_auth_methods_supported:["none"], scopes_supported:["mcp"]}。
- handleRegister: POST only, body≤64KB, client_name+redirect_uris；无redirect→
  invalid_redirect_uri "at least one redirect_uri is required"；非法URI（非http/https或无host）→
  invalid_redirect_uri `<q> is not an http or https URL`；成功→201 {client_id,client_name,
  redirect_uris,token_endpoint_auth_method:"none",grant_types,response_types}；note
  "registered OAuth client <name|(unnamed)>"。
- handleAuthorize: GET/POST；redirect_uri 必须在 client 注册列表（否则 400 HTML
  authorizeError）；response_type!=code→重定向 error unsupported_response_type；无
  challenge 或 method!=S256→invalid_request "PKCE with code_challenge_method=S256 is
  required"；GET→consentPage（HTML 表单隐藏字段回 POST /oauth/authorize，"Allow this
  client to use MCP Gateway?"）；POST→newCode→302 重定向 redirect_uri?code&state。
- handleToken: POST；authorization_code→exchangeCode（takeCode 先取后验防暴力：
  clientID/redirect_uri/PKCE(SHA256 base64url raw 常量时间) → issue(access,refresh)，
  200 {access_token,token_type:"Bearer",expires_in,scope:"mcp",refresh_token}）；
  refresh_token→renew→tokenResponse；其他→unsupported_grant_type
  "only authorization_code and refresh_token are supported"。
  响应 Cache-Control: no-store。

### internal/gateway/tokens.go（自建 AS 的令牌持久化）
- AccessTokenTTL=12h; RefreshTokenTTL=30天。文件 userData/gateway-tokens.json：
  {access:{<sha256hex>:{client_id,scope,expires_at}}, refresh:{...}, clients:{id:{redirect_uris,registered_at}}}
  （键是 token 的 sha256hex，文件本身不泄权）。tmp 0600 原子 rename。
- issuedTokens{mu,path,access,refresh,clients,codes}: load（坏文件忽略）、saveLocked、
  pruneLocked（过期删）、issue(clientID,scope)→(access,refresh,expiresAt) randomToken 32字节
  base64url raw、renew(refresh,clientID)（校验归属）、accepts(token)（过期顺手删）、
  count、revokeAll、registerClient(redirect_uris)→client_id、clientRedirects、
  newCode(clientID,redirectURI,challenge,scope)（TTL5min）、takeCode（一次性）、
  randomToken()=base64.RawURLEncoding(32B)。

### internal/gateway/oauth.go（上游 OAuth 流）
- pendingAuth{TTL 5min}; beginAuthTimeout=60s。BeginAuth(ctx,serverID): 查配置，构造
  transport.OAuthHandler（带 clientName "MCP Gateway", redirectURI, PKCE, TokenStore,
  creds.Client 已存凭据）→打开浏览器授权URL→pending[serverID]；handleOAuthCallback:
  换 token 存 TokenStore+saveClient+markSignedIn+note "signed in to X"+writeCallbackPage
  （成功/失败 HTML 页，textColor/mutedColor）。SignOut: 删 token+markSignedIn(false)。
  SetClientCredentials/ClientCredentials 存读 creds。

### internal/registry（305+tests）
- Client.Search(ctx,query,cursor,limit)→Page{...}：查官方 MCP registry；
  Server.ShortName()；Server.Install()/Package.Install()→Install{...}；
  EnvLines(vars) 渲染 "KEY=value" 行。Market 页用。

### UI 页（main 包）
- page_servers.go（871 行，35 函数）: serversPage、serversGridView(卡片/列表)、
  toolbarRow(搜索+视图切换+Add)、serversSummary、visibleServers(过滤)、serverMatches、
  clampSelection、selectedIndex、revealServer、serverRow、serverCard、serverMenu(右键/
  溢出菜单: edit/reconnect/sign in/out/forget token/remove)、serverSwitch(enabled开关)、
  serverDetail(状态描述)、signInOffered、addServer、tokenPlaceholder/tokenHint、
  forgetToken、editServer、serverForm(模态: name/transport segmented/stdio: command+args+env
  textarea / http+sse: url+headers textarea+oauth toggle+token header+scheme+token密码框 /
  clientID/clientSecret when oauth / enabled)、saveForm(校验+保存+sync)、askRemove、
  removeDialog(确认)、removeServer、importDialog(粘贴JSON)。
- page_market.go（275, 8函数）: marketPage(搜索框+结果列表)、marketRow、marketKind、
  marketSummary、marketSearch(more 分页, debounce marketSearchSoon)、installed、addFromMarket
  （Install→Config）。
- page_routes.go（96, 3函数）: routesPage（Sessions 列表 routeRow: client/version/protocol/
  connected时间/calls/lastActive relativeTime）。
- page_tools.go（271, 9函数）: toolsPage（过滤+表格 toolTable+详情 toolDetail(schema JSON+
  callTool: callArgs JSON textarea→gw.CallTool→callResult/callErr/calling）、transportWord、
  orPlaceholder、formatToolResult。
- page_settings.go（339, 14函数）: settingsPage 四卡：callersCard(入站 auth 模式
  segmented+token 显示/复制/rotate+revoke issued+解释 authExplanation)、serveCard(port 输入
  +start/stop+setPort/restart)、endpointsCard(endpoints 列表+clientConfig JSON+serverLine)、
  activityCard(events 时间线)。
- menubar.go（297, 11函数）: runMenubar(菜单栏 tray/panel 窗口)、toggle/open(page)/refresh、
  plural、panelView(panelTab: servers/routes)、panelServers、panelRoutes、panelServerRow、
  panelAgentRow、trayIcon(template PNG bytes)。
- ui_kit.go（113, 5函数）: SVG 图标常量（iconServers/Store/Routes/Tools/Sliders/Zap/
  ChevronsLeft/Right 等 lucide 风格 24 viewBox stroke 线稿）、statusPill、livePill、
  liveDot、surfaceShadow、card。
- mygo 测试模式（main_test.go 1,742 行，76 个 Test）: 无窗口 newApp + ui 渲染快照断言，
  openExternal/registry 可注入 stub。

## 关键移植决策
- mygo.Secrets(keychain) → macOS 用文件回退为主即可（或 Security framework 后续加）；
  首版 CredentialStore 用 userData/credentials/ 文件 0600（保持接口一致）。
- go 的 goroutine+Update(main) → std.Thread.spawn + objc.dispatchMain → win.redraw()。
- mcp-go 库的三 transport/下游 server → 自研: JSON-RPC 2.0 over stdio(child+fdwatch)、
  Streamable HTTP(std.http.Client + SSE 解析)、下游 std.http.Server accept 循环。
- OAuth 上游(动态注册+PKCE+刷新) 自研实现。

## 源码精读补充（第二批：oauth/registry/page_servers/page_market/page_routes）
- oauth.go：pendingAuth{serverID,verifier,handler,created} TTL=5min；BeginAuth 前置校验
  （stdio/有TokenHeader→"does not sign in with OAuth"；未 Serving→"start the gateway first..."）；
  connect 成功(已登录)→空URL；NeedsAuth→GetOAuthHandler，无 clientID→RegisterClient
  (clientName="MCP Gateway")否则提示手动填 client ID/secret；GenerateState/CodeVerifier/
  GetAuthorizationURL→pending[state]→note "waiting for sign-in in the browser"→saveClient。
  handleOAuthCallback：error/state/code/过期各错误页文案（"This sign-in has expired, or was
  already completed..."），ProcessAuthorizationResponse→note+markSignedIn+成功页
  "You can close this tab and return to MCP Gateway."→goroutine Reconnect。
  SignOut：creds.SignOut+markSignedIn(false)+Reconnect。writeCallbackPage(textColor
  ok=#111 else #b00020, muted=#555)。
- registry.go：DefaultBaseURL="https://registry.modelcontextprotocol.io"；Client{BaseURL,HTTP}
  可stub；Server{Name,Description,Version,Homepage,Remotes[{Type,URL}],Packages[{RegistryType,
  Identifier,Version,RuntimeHint,Arguments,Env}],UpdatedAt}+ShortName()；GET /v0/servers?
  search=&cursor=&limit=，Accept json，20s 超时，非200→"the registry answered <status>"；
  只取 _meta...official.isLatest=true 条目；Package.Arguments=runtimeArgs+Identifier+
  packageArgs；Install()：优先 streamable-http remote→sse remote→package.Install()
  （npm→RuntimeHint||npx，pypi→RuntimeHint||uvx，oci→docker run -i --rm，否则 false）；
  EnvLines: 有Default→K=V，Required→K=。
- page_servers.go（871行35函数）：serversPage；pageHeader actions(Spinner busy, Edit…,
  Reconnect, Remove, Paste JSON…, PrimaryButton Add server…)；emptyState "No servers yet"；
  toolbarRow(SearchField 280宽+serversSummary+Segmented List/Grid)；serversSummary 由
  ready/needs-auth/error/disabled 计数以 " · " 连接；visibleServers 过滤 Name/Alias/
  Transport.Label/Command/URL 小写包含；selectedIndex 返回配置索引或-1；serverRow(56高,
  ContextMenu, 单击选中双击编辑, Avatar+name+serverDetail, statusPill, transport badge,
  "%d tools" 右对齐54, signInOffered→Connect/Disconnect 按钮, serverSwitch)；
  serverDetail：Err 优先，stdio→command+args 否则 URL，前缀 "Off · "/"Connecting · "+
  "Sign in required · "；signInOffered=非stdio无TokenHeader&&(OAuth||SignedIn||needs-auth)；
  addServer 默认 enabled/tokenHeader=Authorization/tokenScheme=Bearer；
  serverForm(Modal)：Name/Transport Segmented，stdio→Command+Arguments(每行一个)+Environment
  (KEY=VALUE) textarea；否则 URL+oauth Switch("The gateway opens your browser and stores the
  token in the system keychain.")→Client ID/secret+非新时 "Sign in now"；非oauth→Token header/
  Scheme/Token(密码)+hasToken→Forget+Other headers textarea；Enabled switch；err 红字；
  Cancel/Save。saveForm：validate→Upsert→EnsureAliases→Save，OAuth→SetClientCredentials
  否则token非空→SetUpstreamToken，revealServer+toast "X saved"+sync。removeDialog 文案
  "Remove “X”?"/"Its tools are withdrawn...forgotten."；removeServer→SignOut+SetUpstreamToken("")
  +toast "X removed"。signIn：openAuthURL+toast "Already signed in"|"Finish signing in in your
  browser"。importPlaceholder=JSON 示例；importServers→ParseMCPConfig→Import→Save→toast Summary。
- page_market.go：marketPageSize=30；marketState{query,results,cursor,loading,searched,err,
  seq(debounce),sel,list}；首访空 query 自动搜；Changed→400ms debounce(seq 比对)；marketRow
  (Avatar+ShortName+Description+badge marketKind(remote|命令名|manual)+"v"+version，installed→
  badge "Added" | 不可装→"Manual" | PrimaryButton "Add X")；marketSummary("N shown, more on the
  registry"|"N found")；marketSearch 30s 超时，非 live 同步执行否则 goroutine+post；installed
  =URL匹配Remotes 或 pkg.Identifier 在 sc.Args；addFromMarket：Install→Remote→url+sse|http，
  本地→command+args+EnvLines。
- page_routes.go：header 右 "N connected"；空→"No agents connected"+Open Settings→router.Push
  ("/settings")；routeRow 56高：Avatar=Client||ID、version、monospace 10px ID、protocol badge、
  calls("no calls yet"/"1 call"/"N calls")、"connected "+relativeTime 右对齐150；
  relativeTime：<1min "just now"，<1h "Nm ago"，<24h "Nh ago"，否则 "Nd ago"。

## 源码精读补充（第三批：page_settings/page_tools/menubar/ui_kit + 测试模式）
- page_settings.go（14函数）：settingsPage=Column Fill Padding20 Gap14 {pageHeader+Scroll
  {serveCard,callersCard,endpointsCard,activityCard Gap16}}。callersCard(card iconShield
  "Callers")：Segmented(authMode, "Off","Token","Token + OAuth")→setAuthMode；Text 11
  TextMuted=authExplanation(mode)（token→"Callers must send the token below. Nothing else
  can reach the tools."；oauth→长文案"…sign-in server, anything running on this computer…"
  ；off→"Anything that can reach the port may call the tools. The port is loopback only."）；
  RequiresToken→Field("Token callers present", TextInput ReadOnly 320,
  Description "Send it as: Authorization: Bearer <token>")+Copy(clipboard,toast "Token copied")
  +New token→rotateAuthToken；auth.AuthorizationServer→"MCP clients can also sign in"+
  MetadataURL 说明+Copy discovery URL(toast)+Textf "%d issued token(s) are live."+Revoke them
  all(=0 disabled,toast "Every issued token was revoked")。
  setAuthMode：mode 越界→0；RequiresToken且token空→GenerateAuthToken(失败 toast
  "Could not make a token: "+err)；gw.SetInbound(mode,token)；cfg.Inbound=mode+Save
  （失败 "Could not save: "）；reload+toast "Callers now need: "+Label。
  rotateAuthToken：Generate→SetInbound→toast "A new token was issued; callers must use it now"。
  serveCard：Field Port(NumberInput 1..65535 w120)+Save port(!changed disabled；校验1-65535
  toast "Choose a port between 1 and 65535"，Save成功 toast "Port set to %d"，serving→restart)
  +Spacer+livePill(serving)+Stop/Start(start: busy="Starting the gateway…"+go Start+toast
  "Serving on "+BaseURL；stop: busy="Stopping the gateway…"；restart: busy="Moving the
  gateway…"，Stop→Start(port)，全部 post 回主线程 busy=""+reload)。
  endpointsCard：遍历 gw.Endpoints() 每行 Text monospace12+Copy(toast "Copied "+e)；
  Divider+"Paste the streamable HTTP endpoint…"+Copy client config(toast "Client configuration
  copied")；serverLine()：ready=0→"No server is connected yet, so clients would see only the
  gateway's own tool."否则 fmt "Clients now see the tools of %d connected server(s)."。
  clientConfig()={"mcpServers":{"gateway":{"url":BaseURL+"/mcp"}}} MarshalIndent 2空格。
  activityCard：events 倒序取最近100条，行=Time.Format("15:04:05") monospace11 TextMuted +
  Text12（Err→Danger 否则 TextMuted）Grow1；空→"Nothing yet."。
- page_tools.go：toolCallTimeout=60s。toolsPage：visibleTools(过滤 Name/ServerName/
  Description 小写含)+toolSel clamp；空tools→emptyState "No tools yet"/"Connect a server on
  the Servers page…"→PrimaryButton "Go to Servers"→router.Push；过滤行 SearchField
  (Placeholder "Filter by tool or server…",Label "Filter tools",280)+toolsSummary
  ("N tools"|"N of M tools shown")；visible空→emptyState "No tools match"/"Nothing matches
  %q."→"Clear the filter"；Row Grow1: 左 Column Grow3 MinWidth0 toolTable，右 Column Width380
  toolTable: Table(列 Tool 200/Server 110/Description)，选中行次要列色=AccentText.Alpha(0.82)，
  surfaceShadow+Grow1+Border1+Radius8。toolDetail(380宽 surfaceShadow Padding16 Gap8)：
  名14Bold、"%s · %s at %s"(ServerName,Upstream,transportWord) 11 muted、desc12、Copy name/
  Copy schema、Divider、"Input schema"+Scroll MinHeight80 MaxHeight220(空→"No parameters.")
  monospace11、Divider、"Test call"+TextArea(callArgs,72,`{"path": "/tmp"}`)+Spinner
  "Calling…"|PrimaryButton "Call tool"+Clear(callResult非空)；结果 Scroll Height130 Border
  Radius6（Err→Danger）。
  callTool：JSON 解析错→callErr+"Arguments are not valid JSON: "+err；calling=true，
  goroutine 60s ctx gw.CallTool→win.Update→err 或 result.IsError/formatToolResult。
  formatToolResult：全部 TextContent→join "\n"（IsError→"error: "+out）否则 MarshalIndent。
  transportWord(cfg.Server(id).Transport.Label()，无→"unknown")；orPlaceholder trim空→fallback。
- menubar.go（11函数）：panelWidth=360,panelHeight=480。runMenubar：NewTray(Icon=trayIcon
  (darwin), IconIsTemplate=darwin, ToolTip="MCP Gateway")；menu=[Open MCP Gateway→open
  ("/servers"), Show Routes→open("/routes"), Separator, RoleQuit]；linux→SetMenu；else
  OnClick toggle()+OnRightClick(先关 panel→SetMenu(menu)→PopUpMenu→defer SetMenu(nil))。
  toggle()：panel 已开→Close；否则 NewFlyout(Tray,PlacementBottom,Gap4,360x480,Focusable,
  Shadow,Popover,Content=panelView)→OnClosed panel=nil。open(page)：关panel→post Push→showMain。
  refresh()：title=agents>0?str(agents):""；tip="MCP Gateway · "+summary(+ · N agent(s)
  connected)；tray.SetTitle/SetToolTip。plural(1→"")。panelView：Root transparent；
  Column Fill FontSize13：Row(P14,16,10: Icon zap accent+Text Bold "MCP Gateway"+livePill+
  Button Open→openMain(panelTab==1?"/routes":"/servers"))+Row(Segmented panelTab
  "Servers","Routes")+Divider+Scroll Fill{Padding10,16,16 Gap2 panelServers|panelRoutes}。
  panelServers：遍历 cfg.Servers 有 status→panelServerRow；无→"No servers configured"。
  panelRoutes：Sessions()；空→"No agents connected"。panelServerRow：Row40 PaddingX8
  Clicked→openMain("/servers")，Avatar+名字+tools 文案("no tools yet"/"1 tool"/"N tools")
  +statusPill。panelAgentRow：Row40 Clicked→openMain("/routes")，Avatar=Client||ID+
  Row{label+v"+Version}+“connected "+relativeTime(Connected)+"badge Protocol"。
  trayIcon(template)：36px 手绘闪电多边形扫描线填充（{19.5,3},{4.5,21},{18,21},{16.5,33},
  {31.5,15},{18,15}），template=纯黑 else NRGBA{128}，png.Encode。
- ui_kit.go（5函数）：10个 lucide 风格 SVG（servers/tools/sliders/zap/shield/globe/activity/
  store/routes/chevrons-left/right，24 viewBox stroke 线稿）用 ui.MustParseSVG+ui.Icon。
  statusPill(c,s,onAccent)：Row Gap6 Shrink0，dot "●"9+label11，各 AnimateColor("status",
  color, statusAnimation{180ms EaseInOut})；onAccent→全 AccentText。statusColor: Ready→
  Success,Connecting→Warning,NeedsAuth→Accent,Error→Danger,else TextMuted（app.go）。
  statusLabel: ready/connecting/sign in/error/off。livePill(on,onText,offText)：off→TextMuted
  ，on→Success。liveDot 同理仅点+Tooltip。surfaceShadow(t,e)：luma(Rec601)<0.5→alpha0.4
  否则0.05，Shadow(0,1,3,0,RGBA(0,0,0,alpha))。card(c,icon,title,body)：Column Padding18
  Gap12 Radius12 Background Border+surfaceShadow，Row{Icon15 accent+Title15 Bold}+body。
- main_test.go（76 Test，51KB）模式：TestMain 用 os.MkdirTemp+"mygo.App.SetPath(PathUserData,
  dir)"隔离用户目录；newTestApp(t,servers...)：config.Default()+Servers+EnsureAliases+
  NewMemoryCredentialStore+gateway.New(cfg,creds,"test")+newApp；无窗口，ui.NewTester
  (a.view,1080,740)，断言 HasText/Find/Texts()，交互用 tt.Click/Type。UI 断言贯穿：
  空态文案、开关语义(Connect/Disconnect 仅 OAuth)、过滤、表单校验、导入、令牌轮换、
  快捷键 tooltip、颜色(像素取色 statusPill/liveDot/card hover lift/shadow)、减少动效仍换页、
  桌面偏好(字号缩放/对比度)下的稳健性。

## UI 主题决定（用户 m00278）
- UI 风格采用 apps/nanomon 的主题：src/theme.zig 照 nanomon 的结构移植——Colors 结构
  （sidebar/picked/on_picked/page/card/border/well/empty/separator/text/secondary/tertiary/
  accent/stripe/selection/on_selection/marked/control/control_on/hover/user/system/fast/
  frugal/gray/blue/green/red/orange/teal/purple/yellow），Codegraff 配色（暗色 bg
  #16140f、amber #e8a33d；亮色 bg #faf8f3、amber #c77d20），`colors(dark)` +
  `ui(dark: bool) nanoui.ui.Theme`（font "Geist"、mono "JetBrains Mono"、accent_text=
  on_picked、danger=红、success=绿）。窗口 `.theme = theme.ui(nanoui.isDark())`，
  测试 `t.init(..., .{ .theme = theme.ui(false/true) })`。布局/部件参考 nanomon 的
  view_kit.zig / view_side.zig / view_table.zig 风格（侧栏、表格、卡片）。

## Zig 实现的并发与生命周期（启动卡死修复，m00436）
- 症状：`zig build run` 窗口出现后卡死。根因：`state.init` 在主线程 `gw.sync()`→
  connectOne→handshake→`Session.call("initialize")`→`await` 无超时地
  `waitUncancelable`，一个死服务器永久冻结窗口；UI 开关/reconnect 同理。
- Session（session.zig）：`default_call_timeout` 30s（`Io.Clock.Duration`），
  `await` 用 `cond.waitTimeout` 到 deadline，Timeout→`error.TimedOut`；
  新增 `waiters` 计数，`deinit` 先置 closed+broadcast 再 join 所有 waiter，
  然后才释放 pending（修掉 close() 与等待线程的 UAF）。
- Gateway（gateway.zig + gateway_serve.zig）：`startAsync/syncAsync/reconnectAsync`
  spawn 分离线程跑 `sync/reconnect`（`sync_mu` 串行）；`state.init` 用
  `startAsync`，`resync` 用 `syncAsync`，UI 永不阻塞。关闭序：`setClosing()`
  （sync/reconnect 拿到 sync_mu 后先查 `closing`，connect 循环逐个查）→
  `wakeWaiters()`（对 upstreams 里每个 sess `markClosed`，等待中的调用立即
  返回 error.Closed）→ 加 sync_mu。`stop()` 同样先做这两步再 lock。
- `Gateway.deinit() bool`：prelude 后用 `sync_mu.tryLock()` 自旋 ≤2s；拿不到
  （说明有尚未注册进 upstreams 的 in-flight connect 叫不醒）就整体泄漏交给
  进程退出回收、返回 false，`state.deinit` 据此跳过 `gpa.destroy(gw)`。
  deinit 内含 listener 拆除（sessions.closeAll + l.stop + l.destroy），
  调用方不再先调 stop()。死服务器配置下退出从 30s 降到 ~2s，正常配置 ~0.5s。
- state.zig：修掉 `gw.cfg = &cfg`/`gw.creds = &store` 指向 init 栈局部
  （use-after-return，且 UI 改的 cfg gateway 看不到）——先建 self，
  `Gateway.init(gpa, io, &self.cfg, &self.creds, ...)`。
- 配置内存：App 新增 `cfg_arena`（`cfgAlloc()`），config.load 与所有 cfg 变更
  （toggleEnabled/saveForm/import/remove/ensureAliases）统一走它，退出时
  `cfg_arena.deinit()` 一次释放；upsert/form.save 原样存入传入 allocator 的
  字符串，所以调用处必须传 cfgAlloc()。
