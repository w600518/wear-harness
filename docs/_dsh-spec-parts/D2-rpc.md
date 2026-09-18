# D2 — Host↔Browser 通信面（Remote RPC、事件流、HTTP 路由）

源码根：`third_party/deepseek-harness`（tag `dsh-v0.1.2-rc.1`，commit `a66e4702047846cdaa10c66c9d3df3951f5ea70d`）。
本文所有路径相对源码根，只依据源码与签入文档；源码未明确处直接标注。

**涉及包的实际位置（核实结果）**

| 职责 | 实际路径 | 说明 |
|---|---|---|
| 浏览器侧 fetch 客户端、`/api` 载体、trust 检查 | `packages/client/connection` | 存在，Host/Client 双面（`src/index.ts` + `src/client/index.ts`） |
| Remote 装配（BFF） | `packages/api/remotes` | 存在；Host 面注册事件源，Client 面 `$mount` 各贡献 |
| Typert RPC 网关（含 WebSocket mux） | `packages/api/gateway` | 存在，非 `remotes` 子目录 |
| Session Remote 与 Client 模型 | `packages/api/session-controller` | 存在，Host/Client 双面 |
| Workspace Remote 与 Client 模型 | `packages/api/workspace-controller` | 存在 |
| Settings / Credentials Remote | `packages/api/settings-controller` | 存在；无 Client 面（纯 Host 包） |
| plugin-inventory | 只在 `packages/host/plugin-inventory` | `packages/api/plugin-inventory` **不存在**（`packages/api` 下仅 `gateway`/`remotes`/`session-controller`/`settings-controller`/`workspace-controller`） |
| Web 服务器（路由表/WebSocket upgrade/索引注入） | `packages/host/webserver` | 存在 |
| SPA dist 服务 + 索引鉴权 | `packages/host/frontend-static` | 存在 |
| 浏览器 shell 入口 | `apps/web`（Vite）+ `packages/client/web`（boot kernel） | `apps/web/src/main.ts` 只有 6 行，真正内核在 `packages/client/web/src/boot.ts` |

---

## 1. 传输机制全貌

### 1.1 HTTP 路由表

Host 侧唯一路由注册点是 `ctx.webServer`（`packages/host/webserver/src/index.ts:38` 定义 `kind: 'exact' | 'prefix'`；`:133-135` 三张表 `exact`/`prefixes`/`upgrades`；`:165` `register`；`:180` `registerUpgrade`；`:196` `registerFallback`）。

| 路径 | 类型 | 方法 | 所有者 | 语义 |
|---|---|---|---|---|
| `/api` | prefix（Fetch 桥） | 任意（实际 POST JSON） | `client-connection` Host 半（`packages/client/connection/src/index.ts:114-127`） | 先 `requestRejection()`（Host/Origin fence + cookie 鉴权），再 `bridge()` 缓冲 body 转 Fetch |
| `/api/<endpoint>` | 共享通道端点 | POST，`content-type: application/json` | Gateway interceptor 认领（`packages/api/gateway/src/index.ts:199-203`） | 端点形如 `<namespace>/<method>`；未认领返回 404 |
| `/api/remote.mux` | exact upgrade（WebSocket） | WS | `api-gateway`（`packages/api/gateway/src/index.ts:211-228`，常量 `packages/api/gateway/src/stream-protocol.ts:6`） | 所有 Remote 流（`follow`/`control`/`$events`）复用这一条物理 socket |
| `/api/session.export` | exact route | GET / HEAD | `session-log-export`（`packages/session-query/session-log-export/src/index.ts:39` 常量，`:81-94` 注册） | query `sessionId`、可选 `includeDescendants`；返回 `application/zip` |
| `/plugins` | prefix | GET | `client-modules` 节点半（`packages/client/modules/src/index.ts:586`） | 提供 `/plugins/<id>/client.js`、`/plugins/??<id>,<id>/client.js&rev=...` 组合包与 `.map` |
| `/plugins/events` | SSE | GET | `client-hmr`（`packages/client/hmr/src/events.ts:44`，`packages/client/hmr/src/index.ts:163` `content-type: text/event-stream`） | 客户端插件 HMR 事件流（EventSource） |
| fallback（其余全部） | fallback seat | GET / HEAD 以外 405 | `frontend-static`（`packages/host/frontend-static/src/index.ts:124-142`） | `/` 与配置的 index 路径先过 `ctx.connection.authorizeIndex`，其余静态资源公开；越界 403、缺失 404 |

请求体的内存上限 `DEFAULT_MAX_REQUEST_BODY_BYTES = 300 MiB`（`packages/client/connection/src/http-bridge.ts:12`），由 `maxRequestBodyBytes` 配置（`packages/client/connection/src/index.ts:83-89`）；未压缩/未流式，超限 413（`http-bridge.ts:47-53, 59-64`）。

### 1.2 WebSocket 与 SSE 的用法

- **WebSocket**：只有一条，即 `/api/remote.mux`，由 `RemoteStreamMuxServer` 服务（`packages/api/gateway/src/stream-server.ts:25`）；浏览器侧 `RemoteStreamMuxClient` 在 Gateway Client 插件激活时启动并保持空闲连接（`packages/api/gateway/src/client/index.ts:148, 162, 168`）。
- **SSE**：只有 HMR 的 `/plugins/events` 使用 `EventSource`（`packages/client/hmr/src/client/index.ts:166`）。`cordis.patch.yml:161` 把 connection 描述为 “fetch/SSE client”，但源码中浏览器主链路是 **HTTP POST + WebSocket mux**，不是 SSE。
- **无 EventSource 承载 Remote**：`$events` 走的是同一 mux 上的一条逻辑流（`stream-protocol.ts:9`）。

### 1.3 连接代数（generation）与重连语义

`ConnectionController`（`packages/client/connection/src/client/connection.ts:90`）持有 `generation`/`attempt` 私有状态，**不进 store**（同文件 `:86-89` 注释）。

- 默认退避：`backoffBaseMs=500`、`backoffFactor=2`、`backoffMaxMs=10_000`、`generationReadyTimeoutMs=3_000`（`connection.ts:27-32`）。
- 每次延迟为 cap/2 + rand·(cap/2)，即 50%–100% 抖动（`connection.ts:157-160`）；最终档位进入 `disconnected` 并停止重试（`connection.ts:198-205`）。
- `reconnect()` 重置 attempt、置 `immediateRetry`、发布 `connecting`，并中断当前 generation 或延迟等待（`connection.ts:126-134`）。
- 浏览器断网：`offline` → `disconnected` 并挂起自动重试；`online` → attempt 归零、从 500ms 档重开（`connection.ts:140-150`；网络监听 `packages/client/connection/src/client/index.ts:165-178`）。
- generation 编号单调递增，只在 source 报告 `ready` 后发布；`onConnected` 之后才允许跑 baseline 读取（`packages/client/connection/src/client/index.ts:265-281`；README 同义表述 `packages/client/connection/README.md:44`）。
- 状态去重与监听器异常隔离：`emitState`（`connection.ts:292-296`）、`callSink`（`connection.ts:299-305`）。
- 建立后 Client 侧发 `connection/reset` 事件，供 wire 派生缓存重拉（`packages/api/gateway/src/client/index.ts:169`；事件声明 `packages/client/connection/src/client/index.ts:19-28`）。
- 每次重试前向 mux 请求一次全新物理连接（`packages/api/gateway/src/client/index.ts:170-173` → `streams.reconnect()`）。

### 1.4 trust fence 与 trustedHosts

两道独立的门（`packages/client/connection/src/rpc-host.ts:95-99`）：先 fence（失败 403），再鉴权（失败 401）。

- **Host/Origin fence** `isTrustedApiRequest`（`packages/client/connection/src/api-request-trust.ts:91-118`）：
  - 每个请求都要求 `Host` 存在且可解析；hostname 必须是 loopback 或命中 `trustedHosts`，否则拒（`:99-103`）。
  - `trustedHosts` 条目规则：带端口 = 精确 `host:port`；不带端口 = 任意端口的该 hostname（`:75-83`）。
  - `sec-fetch-site: cross-site` 一律拒（`:106`）。
  - 若带 `Origin`，其 `host` 必须与 Host 完全一致；`Origin: null` 等价于不透明源，拒（`:111-117`）。
  - 配置项在加载期用 `assertTrustedAuthority` 校验为裸权威（`api-request-trust.ts:49-53`，调用点 `packages/client/connection/src/index.ts:106`）。
- **浏览器鉴权** `BrowserAuth`（`packages/client/connection/src/browser-auth.ts:185`）：
  - 每进程随机 launch token（`:53-57`），经 `authenticatedUrl()` 作为根 URL 唯一 query `?token=`（`:15`、`:223`）。
  - 仅在 `GET /` 且单 token 匹配时写签名 cookie 并 302 到干净 `/`（`:240-268`）；cookie 名 `dsh-auth-<sha256(authority)>`（`:107`），负载 `v1.<body>.<sig>` HMAC-SHA256（`:126-131`、`:135-158`），属性 `Path=/; HttpOnly; SameSite=Strict`（`:122`），`Max-Age` 由 `cookieMaxAgeDays`（默认 30）派生（`:81`、`:198`）。
  - 断言绑定的密钥存在 `ctx.credentials` 的 owner-scoped 记录 `client-connection/browser-session`（`:162-177`，README `packages/client/connection/README.md:37`）。
  - 说明：cookie **不带 `Secure`**（loopback HTTP 是有意选择，README `:62`）；无登出接口（README `:63`）。
- **部署接线**：`dsh web` 计算 LAN 字面量并注入 `webRuntime.trustedHosts`，patch 行把它转给 connection 的 `trustedHosts`（`packages/bundle/web-app/src/index.ts:235, 240`；`packages/bundle/web-app/cordis.patch.yml:169`）；CLI 打印与打开的是 `connection.authenticatedUrl(...)`（`packages/bundle/web-app/src/index.ts:271-284`）。
- `dsh web --host 0.0.0.0` 未受支持（README `packages/client/connection/README.md:39`）。

---

## 2. RPC 方法全表

装饰器来自 `@deepseek-ai/dsh-typert-protocol` 的 `Remote` / `RemoteScope`，业务类继承 `TypertRemoteService`（`packages/api/gateway/README.md:27`）。`@Remote` 无参时线名 = 方法名。所有方法调用经 `ctx.connection.rpc.call('/api', '<ns>/<method>', { args })`。

### 2.1 `session`（Host：`SessionController`；`packages/api/session-controller/src/index.ts:84, 116`）

| 方法 | 参数要点 | 返回 | 语义 | Web UI 调用 |
|---|---|---|---|---|
| `list` | `_request`（保留空对象）、`signal` | `SessionListValue{items}` | 读全部可见 Session，不唤醒 Agent | 间接：`SessionManager.refreshList`（`.../client/sessions/manager.ts:463`） |
| `search` | `{query}`、`signal` | `SessionSearchValue` | 逐字内容检索，不唤醒 Agent | 间接：`manager.ts:535` |
| `create` | `SessionCreateRequest`（workspaceId/cwd/preset） | `SessionCreateValue` | 创建或幂等收养普通 Session | 间接：`manager.ts:564` |
| `selectModel` | `SessionSelectModelRequest` | `SessionSelectModelValue` | 显式唤醒后设 Session 级模型 | 间接（`services` 内） |
| `modelCatalog` | 无 | `ModelCatalog` | 当前可路由模型、默认模型、隔离的 provider 失败 | **直接**：`packages/client/ui-model-selection/src/client/catalog.ts:45`；`ui-settings-plugins/src/client/subagent-model-selection-card-controller.ts:322` |
| `canOpenWorkspacePath` | 无 | `boolean` | 本部署能否把路径交给桌面打开 | **直接**：`packages/client/ui-deliverables/src/client/index.ts:48` |
| `openWorkspacePath` | `{path}`、`signal` | `SessionOpenWorkspacePathValue` | 在 Host 桌面打开路径；空 path → `gateway/bad-request` | **直接**：`packages/client/ui-chat/src/client/apply.ts:124` |
| `rename` | `SessionRenameRequest` | `SessionRenameValue` | 显式标题重命名 | 间接：`session.ts:338` |
| `fork` | `SessionForkRequest` | `SessionForkValue` | 从已完成轮前缀分叉 | 间接：`manager.ts:600` |
| `prompt` | `SessionPromptRequest`、`signal` | `SessionPromptValue` | 提交提示（queue/steer） | 间接：`session.ts:242` |
| `attachment` | `SessionAttachmentRequest` | `SessionAttachmentValue` | 取经 Session 日志授权的图片 | 间接：`session.ts:290` |
| `updateQueue` | `SessionUpdateQueueRequest` | `SessionUpdateQueueValue` | 变更仍待处理的队列项 | 间接：`session.ts:302` |
| `cancel` | `SessionCancelRequest` | `SessionCancelValue` | 取消当前轮，保留待处理 inbox | 间接：`session.ts:320` |
| `page` | `SessionPageRequest`、`signal` | `SessionPage` | 冷安全、按消息对齐的历史页 | 间接：`transport.ts:199` |
| `follow` | **stream**：`SessionFollowRequest`、`signal` | `AsyncIterable<SessionFollowFrame>` | 开屏快照 + 无缺口事件帧 | 间接：`transport.ts:173` |
| `control` | **stream**：`signal` | `AsyncIterable<SessionControlFrame>` | 进程内控制基线 + 替换帧 | 间接：`transport.ts:119` |

### 2.2 `skills`（`SessionSkillCatalog`，`packages/api/session-controller/src/skill-catalog.ts:20, 25, 35`）

| 方法 | 参数要点 | 返回 | 语义 | Web UI |
|---|---|---|---|---|
| `list` | `SkillListRequest`、`signal` | `SkillListValue` | 用户可调用技能发现；冷态用记录 preset 的 standing scope，不启动 Agent | 经 UI 技能域；包内未在 `packages/client` 命中直接调用（源码未在 client 目录检出调用点） |

### 2.3 `fileReferences`（`SessionFileReferences`，`packages/api/session-controller/src/file-references.ts:17, 22, 32`）

| 方法 | 参数要点 | 返回 | 语义 | Web UI |
|---|---|---|---|---|
| `list` | `agent`、`query`、`signal` | `FileReferenceCandidate[]` | Agent 作用域文件引用补全 | **直接**：`packages/client/ui-reference/src/client/index.ts:49` |

### 2.4 `workspace`（`WorkspaceController`，`packages/api/workspace-controller/src/index.ts:34, 42`）

| 方法 | 参数要点 | 返回 | 语义 | Web UI |
|---|---|---|---|---|
| `create` | `{path}` | `WorkspaceCreateValue` | 注册或幂等解析目录 | 间接：`packages/api/workspace-controller/src/client/model.ts:86` |
| `rename` | `{workspaceId, title}` | `WorkspaceValue` | 非空唯一标题 | 间接：`model.ts:98` |
| `delete` | `{workspaceId}` | `WorkspaceDeleteValue` | 仅移除注册 | 间接：`model.ts:109` |
| `insertBefore` | `{workspaceId, beforeWorkspaceId?}` | `WorkspaceOrderValue` | 改显示顺序 | 间接：`model.ts:128` |
| `insertSessionBefore` | Workspace/Session/anchor | `WorkspaceValue` | Workspace 内 Session 排序 | 间接：`model.ts:151` |
| `archiveSession` | `{sessionId}` | `WorkspaceArchiveValue` | 从导航隐藏 | 间接：`model.ts:168` |
| `follow` | **stream**：`signal` | `AsyncIterable<WorkspaceFollowFrame>` | 基线 + `upsert`/`remove`/`order`/`archived` 增量 | 间接：`packages/api/workspace-controller/src/client/index.ts:81`；UI 走 `ctx.workspaces` |

### 2.5 `directoryPicker`（`DirectoryPickerController`，`packages/api/workspace-controller/src/directory-picker.ts:41, 46`）

| 方法 | 参数要点 | 返回 | 语义 |
|---|---|---|---|
| `pick` | `signal` | `string \| null` | OS 原生选择器；不可用能力 → `directory-picker/unavailable` |
| `list` | `path?`、`signal` | `DirectoryListing` | 应用内浏览一级目录（缺省 home） |
| `createDirectory` | `path`、`name` | `string` | 校验单一非空段名后创建 |

Web UI：`ui-directory-picker-browse` / `ui-directory-picker-native` 占 `conversation.hero.workspace.directoryFlow` 与 `sidebar.workspaces.directoryFlow`（见 §5）。包内未在 `packages/client` 检出 `remote.directoryPicker.*` 直接调用点 —— 源码未明确其调用路径。

### 2.6 `settings`（`SettingsController`，`packages/api/settings-controller/src/index.ts:88, 102`）

| 方法 | 参数要点 | 返回 | 语义 | Web UI |
|---|---|---|---|---|
| `describe` | 无 | `SettingsDescribeValue` | 全部命名空间 `redactSecrets: true` + schema；无 provider → `gateway/internal` | **直接**：`packages/client/ui-settings/src/client/settings-mirror.ts:183` |
| `canOpenAgentPresetDirectory` | 无 | `boolean` | 能否原生打开 preset 目录 | **直接**：`ui-agent-preset/src/client/section-store.ts:172` |
| `update` | `ns`、`patch`、`expectedRevision?` | `SettingsNamespaceView` | 合并写；冲突 `settings/conflict`，其他拒 `settings/rejected` | **直接**：`ui-agent-preset/src/client/settings-store.ts:32` |
| `replace` | `ns`、`section`、`expectedRevision?` | `SettingsNamespaceView` | 整段替换 | 未见 client 目录直接调用点 |
| `mutate` | `ns`、`SettingsPathOpView[]`、`expectedRevision?` | `SettingsNamespaceView` | 按路径编辑 | **直接**：`ui-settings/src/client/settings-scope.ts:131`；`ui-permission-presets/src/client/settings-store.ts:143`；`ui-settings-models/src/client/operations.ts:97` |
| `openSettingsDocument` | `signal` | `SettingsDocumentOpenValue` | 物化并原生打开文档 | **直接**：`ui-settings-general/src/client/settings-document-store.ts:65` |
| `openAgentPresetDirectory` | `agentPreset`、`signal` | `AgentPresetDirectoryOpenValue` | 仅用户自撰 preset；非用户 → `agent-preset/read-only` | **直接**：`ui-agent-preset/src/client/section-store.ts:290` |

### 2.7 `credentials`（`CredentialsController`，`packages/api/settings-controller/src/credentials.ts:67, 70`）

| 方法 | 参数要点 | 返回 | 语义 | Web UI |
|---|---|---|---|---|
| `describe` | `refs: string[]`（≤64，名称须匹配 `^[A-Za-z_][A-Za-z0-9_]*$`） | `Record<string, CredentialInfo>` | 批量元数据，字段逐项拷贝；越界 → `gateway/bad-request` | **直接**：`ui-settings-models/src/client/store.ts:217`、`operations.ts:85`；`ui-settings-plugins/src/client/web-search-card-controller.ts:128` |
| `set` | `ref`、`value`（非空） | `void` | 仅此方向传值；拒 → `credential/rejected` | **直接**：`ui-settings-models/src/client/operations.ts:89`；`ui-settings-plugins/.../web-search-card-controller.ts:172` |
| `unset` | `ref` | `void` | 移除引用 | **直接**：`ui-settings-models/src/client/operations.ts:93` |

### 2.8 其余同装配的命名空间（`packages/api/remotes/src/client/index.ts:146-152` 的 12 个 contribution）

| 命名空间 | Host 归属包 | 方法（行号） | Web UI 调用点 |
|---|---|---|---|
| `agentPresets` | `packages/preset/agent-presets` | `list`:260、`read`:512、`copy`:564、`deletePreset`:602、`select`:694 | `ui-agent-preset/src/client/section-store.ts:206,269,320`、`seat-store.ts:160`、`settings-store.ts:66` |
| `commands` | `packages/interaction/commands` | `list`:288、`execute`:332 | `ui-commands/src/client/service.ts:142,405`；`ui-plan/src/client/index.ts:61` |
| `goals` | `packages/goal/goal` | `edit`:326、`pause`:349、`resume`:361、`complete`:388、`clear`:430、`create`:622 | 经 `ui-goal`（包内未检出 `remote.goal*` 直接调用；源码未明确） |
| `llm` | `packages/llm/llm` | `listProviders`:461、`listConfigurableProviders`:533、`discoverModels`:620 | `ui-settings-models/src/client/store.ts:182-183`、`operations.ts:103` |
| `dynamic` | `packages/extensions/cordis-host-runner` | `undefineFromPanel`:226、`runHostHalf`:324、`getClientCode`:383、`resolveRequestRun`:412、`settleUserRun`:437、`stopFromPanel`:479、`syncInspectManifest`:497、`resolveInspectQuery`:510、`inventory`:524、`reportRenderFailure`:683、`reportClientGuardFailure`:717、`invoke`:740 | 经 `packages/client/ui-cordis`（包内未检出直接调用；源码未明确） |
| `pluginInventory` | `packages/host/plugin-inventory` | `list`:65 | `ui-settings-plugin-inventory/src/client/index.ts:37` |
| `messageFeedback` | `packages/feedback/message-feedback` | `list`:190、`put`:206、`delete`:272 | `ui-message-feedback/src/client/controller.ts:266,221,243` |
| `sessionReferenceResolver` | `packages/context/session-reference` | `candidates`:250 | `ui-reference/src/client/index.ts:53` |
| `subagents` | `packages/subagent/subagent` | `list`:383、`prompt`:409、`interruptByParent`:475 | 间接：`session-controller/.../session.ts:250,315`、`manager.ts:372` |
| `session` / `skills` / `fileReferences` | `packages/api/session-controller` | 见 §2.1–2.3 | 同上 |
| `workspace` / `directoryPicker` | `packages/api/workspace-controller` | 见 §2.4–2.5 | 同上 |

`settings` 与 `credentials` 由同一个 `settingsControllerRemote` 贡献提供——`SettingsController` 构造器内 `ctx.plugin(CredentialsController)`（`packages/api/settings-controller/src/index.ts:107`）。同理 `session` 贡献内含 `ctx.plugin(SessionFileReferences)` 与 `ctx.plugin(SessionSkillCatalog)`（`packages/api/session-controller/src/index.ts:134-135`），`workspace` 贡献内含 `ctx.plugin(DirectoryPickerController)`（`packages/api/workspace-controller/src/index.ts:49`）。

---

## 3. 事件转发

**allowlist 唯一归属**：`packages/api/remotes/src/remote-events.ts:16-35` 的 `API_REMOTE_FORWARDED_EVENTS`，共 **18 条**，每条形如 `{ event, mode }`，`mode: 'emit' | 'waterfall'`。两套编译面同时列出该文件（`packages/api/remotes/README.md:52`）。

| # | event | mode |
|---|---|---|
| 1 | `agent-preset/selected` | emit |
| 2 | `approval/request` | waterfall |
| 3 | `api-session/activity` | emit |
| 4 | `api-session/added` | emit |
| 5 | `api-session/error` | emit |
| 6 | `api-session/removed` | emit |
| 7 | `api-session/status` | emit |
| 8 | `commands/change` | emit |
| 9 | `credentials/reference-updated` | emit |
| 10 | `cordis/request-run` | emit |
| 11 | `cordis/request-run-resolved` | emit |
| 12 | `cordis/dynamic-package` | emit |
| 13 | `cordis/dynamic-retract` | emit |
| 14 | `cordis/inspect-query` | emit |
| 15 | `cordis/inspect-query-resolved` | emit |
| 16 | `llm/adapters-updated` | emit |
| 17 | `settings/document-updated` | emit |
| 18 | `user-questions/request` | waterfall |

**Host 侧转发循环**（`packages/api/remotes/src/index.ts:37-78`）：

- `emit` 条：`ctx.on(event, (...args) => queue.push({ event, args: assertJsonArgs(...) }))`（`:49-53`）；非无损 JSON 参数直接抛（`:158-164`）。
- `waterfall` 条：从 `this` 取 `carrierKeyOf` → `ctx`（`:59-64`），投递 `TypertRemoteEventInvocation`（`:140-152`）；队列已结束时直接 `next()`。
- Host 为每个 Client 流建**独立**的队列与监听器集合（`:46-47`），源的全部监听器在 `ready` 之前同步挂好，`registerRemoteEvents` 才暴露 `$events`（`:38-41`；语义见 `packages/api/gateway/README.md:37`）。
- 队列是拉驱动的 `Deque` + waiter（`:81-119`）；source 结束/中止时对未决 waterfall 全部 `reject`（`:93-101`）。

**线协议**（`packages/api/gateway/src/stream-protocol.ts`）：

| 常量/帧 | 值/字段 | 行 |
|---|---|---|
| 逻辑流端点 | `$events` | `:9` |
| 结果端点 | `$events/result` | `:12` |
| 打开负载 | `{ args: {} }` | `:15` |
| ready 判别 | `{ type: 'ready' }` | `:18` |
| `RemoteEventReadyFrame` | `{ type:'ready', clientId, host:{home} }` | `:33-38` |
| `RemoteEventEmitFrame` | `{ type:'emit', event, args }` | `:44-48` |
| `RemoteEventInvocationFrame` | `{ type:'waterfall', event, eventId, agentId, request }` | `:51-57` |
| `RemoteEventCancellationFrame` | `{ type:'cancel', eventId }` | `:60-63` |
| `RemoteEventResult` | `{ clientId, eventId, outcome }`，outcome = `next` \| `result{value?}` \| `rejected{error}` | `:87-94` |

**waterfall 的请求-应答**（`packages/api/gateway/src/client/remote-events.ts`）：

1. Host → Client：mux 上 `waterfall` 帧（含 `agentId`、`eventId`）。
2. Client 用 `typert.contexts.getClient('agent').resolve(agentId)` 找目标 Context（`:190-196`）。
3. 在目标 Context 上跑 Cordis waterfall，末位 `next` 桩返回私有哨兵 `REMOTE_EVENT_NEXT`（`:59, 233-241`）。
4. 结果必须是 `next` 或无损 JSON（`:242-247`）。
5. **应答走 HTTP 一元调用**：`connection.rpc.call('/api', '$events/result', { args: result }, signal)`（`:214-219`）—— 即 waterfall 的返回值不占 mux 通道。
6. `$events/result` 由 Gateway 无条件下认领（`packages/api/gateway/src/index.ts:267`）。取消则发 `cancel` 帧（`:60-63`）。

**Client 订阅面**：`ctx.remote.$on(event, listener)`（`packages/api/gateway/src/client/index.ts:211-216`），键集合即 allowlist，监听器签名来自各 owner 包的 `Events` 声明（`packages/api/remotes/src/client/index.ts:41-49`）。实际订阅点：`ui-commands`（`:157,161`）、`ui-model-selection`（`:57-59`）、`ui-approval`（`:90`）、`ui-user-questions`（`:104`）、`ui-settings*`、`ui-agent-preset`、`ui-skill`、`session-controller/client/index.ts:92-102`。

---

## 4. Client 侧模型 API

### 4.1 `ClientSessions`（`ctx.sessions`，`ISessions`）

契约：`packages/api/session-controller/src/client/contract/sessions.ts:21-123`；实现 `.../client/sessions/service.ts:182`。

| 成员 | 签名要点 |
|---|---|
| `list` | `ObservableSnapshot<SessionListState>`（useSessions 标准源，只读面） |
| `searchResultLimit` | `number`（wire schema 固定上界） |
| `create(opts?)` | `{workspaceId?, cwd?, sessionId?}` → `Promise<SessionId>` |
| `open(id)` / `openSubagent(address)` / `clear()` | 选择/清空当前会话；未知 id 立即失败 |
| `subagentAddress(id)` | `SubagentAddress \| undefined` |
| `setSubagentCatalogOpen(parentSessionId, open)` | 目录菜单是否消费实时成员变更 |
| `refreshSubagents(parentSessionId)` | `Promise<void>` |
| `refresh()` | 重拉 Host 权威列表 |
| `search(query, signal)` | `Promise<RemoteResult<{items, hasMore}>>` |
| `fork({sessionId, atSeq?, increaseTitle?})` | `Promise<SessionId>` |
| `scope(id)` / `scopeOf(ctx)` / `sessionOf(ctx)` / `binding(id)` | Agent 作用域与绑定解析 |
| 事件处理 | `handleControlFrame` / `handleSessionAdded|Removed|Status|Activity|Error` / `handleConnected`（`service.ts:346-391`） |

### 4.2 `SessionManager`（`.../client/sessions/manager.ts:95`）

公开成员：`select`:168、`selectSubagent`:191、`clearSelection`:206、`subagentAddress`:216、`navigationAddress`:225、`drop`:245、`dispose`:255、`get`:288、`refreshSubagents`:355、`setSubagentCatalogOpen`:436、`refreshList`:453、`search`:531、`create`:553、`fork`:596、`subscribe`:643、`getListSnapshot`:651、`handleControlFrame`:662、`handleSessionAdded`:709、`handleSessionRemoved`:732、`handleSessionStatus`:765、`handleSessionActivity`:776、`handleSessionError`:785、`handleConnected`:793。
快照类型：`SessionListSnapshot`（`:50-64`）、`SubagentCatalogSnapshot`（`:65-67`）、`SessionSearchResultItem`（`:44`）、`SessionListPhase`（`:41`）。

### 4.3 `Session`（实现 `SessionFace`）

`SessionFace = ISession & ObservableSnapshot<SessionSnapshot>`（`contract/session.ts:145`）。
行为动词（`contract/session.ts:60-138`）：`beginSubmission(input)` → `SubmissionHandle{requestId, abandon()}`；`prompt(content, mode, signal?, requestId?)`；`readAttachment(attachmentId)`；`updateQueue(itemId, action)`；`cancel()`；`rename(title)`；`loadOlder()`；`loadThrough(seq)`；`command(line)`；另加 `projections.faceOf(key)`。
Observable：`getSnapshot()`（`SnapshotStore` 语义）+ `subscribe()`（`session.ts:459-477`）。
`SessionSnapshot` 字段：`sessionId, queue, pendingSubmissions, running, subagent, removed, openState, openError, hasMore, loadingOlder, promptError, blank, lastAgentError, promptAttempted, awaitingFirstTurn`（`contract/snapshot.ts:65-88`）。
事件窗口：`SessionEventSource = ObservableSnapshot<SessionEventWindow>`（`contract/events.ts:92`），窗口 delta 为 `replace` / `prepend` / `append`（`:78-81`）。

### 4.4 `follow()` / `page()` / queue / control 流的语义

- **`follow()`**：Gateway `RemoteJournalStream`，绑定一个普通 Session 或直接子 Agent 地址；**先开 follow 再取首页**，只发布连续 `replace`/`prepend`/`append`；重连或序号缺口用 tail page 修复（`packages/api/session-controller/README.md:30`；实现 `.../client/transport.ts:135-213`）。
- **`page()`（`ClientSessionPageRequest`）**：向后分页两个动词——`loadOlder()` 拉 50 条；`loadThrough(seq)` 循环 200 条页直到覆盖目标 seq，重复调用会下调共享目标，无进展页即停，忙态由 `loadingOlder` 表示（README `:30`）。
- **记录区间**：普通记录 `[event.seq, event.seq]`；打包行 `[event.seq, event.seq + memberCount - 1]`（README `:30`）。
- **queue**：`SessionQueueMirror`（`.../client/sessions/queue-mirror.ts:27`）维护 `snapshot()`/`replace()`/`acceptDurable(event)`；`QueuedMessage` 带 `rpcId` 关联本地提交回声（`contract/snapshot.ts:10-19`）。
- **control 流**：`RemoteSnapshotStream`，每代以完整进程内基线开屏，重连即替换 queue/jobs/projection，不把瞬时值当持久事件（README `:30`；`transport.ts:113-132`）。
- **本地提交回声**：`beginSubmission` 先同步插入 `pendingSubmissions`，durable 事件或队列项到达后一帧退休（README `:32`）。
- **通知纪律**：`notifyNow` 只用于用户手势直回声，结构更新走微任务批 `markDirty`，可见流式块走累积 `markFrameDirty`（`packages/client/AGENTS.md` 规则；实现 `.../client/sessions/notifier.ts:31,39,50`）。

### 4.5 `ClientWorkspaceModel`（`packages/api/workspace-controller/src/client/model.ts:54`）

| 成员 | 要点 |
|---|---|
| `create(input)` / `rename(workspaceId, title)` / `delete(workspaceId)` | 返回 `RemoteResult<...>` |
| `insertBefore(...)`:120 / `insertSessionBefore(...)`:146 / `archiveSession(sessionId)`:165 | 同上 |
| `replaceBaseline`:177 / `upsertView`:188 / `removeView`:193 / `replaceOrder`:198 / `replaceArchived`:207 | `WorkspaceFollowSink` 增量入口 |
| `handleCarrierFailure`:212 / `handleStreamFailure`:222 | 可重试损失 vs 终态失败 |
| `subscribe`:234 / `getSnapshot`:243 | 框架无关的可观察快照（`WorkspaceSnapshot`：`items`/`archivedSessionIds`/`state`/`phase`/`error`，`:28-35`） |

竞态规则：更新的 Host 行按 `updatedAt` 胜；已提交流顺序胜过旧一元响应；被删 Workspace 不可被延迟数据复活（`packages/api/workspace-controller/README.md:27`）。
对外服务面 `ctx.workspaces`（`IWorkspaces`，`.../client/service.ts:33-78`；实现 `:80`），装配在 `.../client/index.ts:44-57`。

---

## 5. slot 契约表（全量 52 项）

来源：`packages/extensions/cordis-client-runner/src/client/slot-catalog.ts`（生成物，头部声明由 `scripts/gen-client-catalog.ts` 生成，`slot-catalog.ts:1-14`）。条目自第 83 行起，`CLIENT_SLOT_API` 数组共 **52** 条（`key:` 行计数）。`occupants` 多值以 `；` 分隔。

| # | slot key | kind | scope | occupants | replaceRisk | declaredBy | source |
|---|---|---|---|---|---|---|---|
| 1 | `conversation` | single | session-maybe | client-ui-conversation ConversationRoot | shadows-shipped-ui | an entry in `root` (client-ui-layout) | `packages/client/ui-layout/src/client/index.ts:65` |
| 2 | `conversation.approval.detail` | single | session | client-ui-chat ApprovalCommand | shadows-shipped-ui | an entry in `conversation.composer` (client-ui-approval) | `packages/client/ui-approval/src/client/contract/slots.ts:37` |
| 3 | `conversation.chat.assistant-actions` | list | session | client-ui-message-feedback MessageFeedbackActions id `feedback` | none | an entry in `conversation.chat.node` (client-ui-chat) | `packages/client/ui-chat/src/client/contract/slots.ts:221` |
| 4 | `conversation.chat.commandview` | keyed | session | （空） | none | an entry in `conversation.chat.node` (client-ui-chat) | `packages/client/ui-chat/src/client/contract/slots.ts:209` |
| 5 | `conversation.chat.node` | keyed | session | client-ui-chat UserMessageNodeView `user`；UserMessageNodeView `steering`；ContextMessageNodeView `context`；SystemPromptNodeView `system-prompt`；AssistantNodeView `assistant-step`；CommandNodeView `command`；ManualCompactionNodeView `manual-compaction`；CompactionNodeView `compaction`；RetryNodeView `model-retry`；TurnErrorNodeView `turn-error`；TurnMaxTokensNodeView `turn-max-tokens`；TurnProcessNodeView `turn-process`；TurnTailNodeView `turn-tail`；UnknownNodeView `unknown`；client-ui-goal GoalCommandInputView `command-input`；client-ui-tool ToolCallTree `tool-call`；client-ui-workflow-run WorkflowRunPanel `workflow-run` | shadows-shipped-ui | an entry in `conversation.view` (client-ui-chat) | `packages/client/ui-chat/src/client/contract/slots.ts:190` |
| 6 | `conversation.chat.turnTail` | chain | session | client-ui-deliverables ProducedFiles | none | an entry in `conversation.chat.node` (client-ui-chat) | `packages/client/ui-chat/src/client/contract/slots.ts:215` |
| 7 | `conversation.composer` | chain | session | client-ui-approval ApprovalPanel；client-ui-subagent SubagentReadOnlyComposer；client-ui-user-questions QuestionComposer | none | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:119` |
| 8 | `conversation.composer.bar` | single | session-maybe | client-ui-conversation InputBar | shadows-shipped-ui | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:137` |
| 9 | `conversation.composer.dock` | list | session | client-ui-chat StatsLine id `stats` | none | an entry in `conversation.composer.bar` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:131` |
| 10 | `conversation.details.tool` | single | session | client-ui-tool ToolDetails | shadows-shipped-ui | an entry in `details` (client-ui-chat) | `packages/client/ui-chat/src/client/contract/slots.ts:227` |
| 11 | `conversation.hero.agentPreset` | single | root | client-ui-agent-preset AgentPresetSeat | shadows-shipped-ui | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:125` |
| 12 | `conversation.hero.brand.mark` | single | root | （空） | none | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:123` |
| 13 | `conversation.hero.workspace` | single | root | client-ui-workspace WorkspacePicker | shadows-shipped-ui | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:121` |
| 14 | `conversation.hero.workspace.directoryFlow` | single | root | client-ui-directory-picker-browse BrowseDirectoryFlow；client-ui-directory-picker-native NativeDirectoryFlow | shadows-shipped-ui | an entry in `conversation.hero.workspace` (client-ui-workspace) | `packages/client/ui-workspace/src/client/contract/slots.ts:57` |
| 15 | `conversation.input.attachments` | single | session-maybe | client-ui-attachment ComposerAttachments | shadows-shipped-ui | an entry in `conversation.composer.bar` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:139` |
| 16 | `conversation.input.dock` | list | session | client-ui-conversation QueueDock `queue`；TodoDock `todo`；client-ui-goal GoalDock `goal` | none | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:127` |
| 17 | `conversation.input.left` | list | session | （空） | none | an entry in `conversation.composer.bar` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:133` |
| 18 | `conversation.input.model` | single | session | client-ui-model-selection ModelSelect | shadows-shipped-ui | an entry in `conversation.composer.bar` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:147` |
| 19 | `conversation.input.overlay` | list | session | client-ui-commands PopupSelectView `command-popup`；client-ui-input-trigger MenuView `slash-menu` | none | an entry in `conversation.composer.bar` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:129` |
| 20 | `conversation.input.plan` | single | session | client-ui-plan PlanChip | shadows-shipped-ui | an entry in `conversation.composer.bar` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:145` |
| 21 | `conversation.input.right` | list | session | （空） | none | an entry in `conversation.composer.bar` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:135` |
| 22 | `conversation.message.images` | single | session | client-ui-attachment MessageImages | shadows-shipped-ui | an entry in `conversation.view` (client-ui-chat) | `packages/client/ui-chat/src/client/contract/slots.ts:203` |
| 23 | `conversation.session` | single | session | client-ui-conversation ConversationSession | shadows-shipped-ui | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:95` |
| 24 | `conversation.session.header` | single | session | client-ui-conversation ConversationSessionHeader | shadows-shipped-ui | an entry in `conversation` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:97` |
| 25 | `conversation.session.header.actions` | list | session | client-ui-agent-preset AgentPresetLabel `agent-preset`；client-ui-jobs JobListAction `job-list`；client-ui-schedule ScheduleCatalogAction `schedule-catalog`；experimental-client-ui-agent-team TeamAction `agent-team` | none | an entry in `conversation.session.header` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:105` |
| 26 | `conversation.session.header.lineage` | single | session | client-ui-subagent SubagentHeaderLineage | shadows-shipped-ui | an entry in `conversation.session.header` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:99` |
| 27 | `conversation.session.header.utilities` | list | session | session-log-export SessionLogDownloadHeaderAction `session-log-download` | none | an entry in `conversation.session.header` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:111` |
| 28 | `conversation.trajectory.images` | single | session | client-ui-attachment MessageImages | shadows-shipped-ui | an entry in `conversation.view` (client-ui-trajectory) | `packages/client/ui-trajectory/src/client/trajectory-contract.ts:95` |
| 29 | `conversation.view` | list | session | client-ui-chat ChatView `chat`；client-ui-trajectory TrajectoryView `trajectory` | none | an entry in `conversation.session` (client-ui-conversation) | `packages/client/ui-conversation/src/client/contract/slots.ts:117` |
| 30 | `details` | single | session | client-ui-chat DetailsPanel | shadows-shipped-ui | an entry in `root` (client-ui-layout) | `packages/client/ui-layout/src/client/index.ts:75` |
| 31 | `root` | single | root | client-ui-layout AppFrame | shadows-shipped-ui | the runtime itself (built in; always present) | `packages/client/ui-renderer/src/client/registry.ts:43` |
| 32 | `settings.action` | list | root | client-ui-settings-general SettingsDocumentAction `open-document` | none | an entry in `sidebar.settings` (client-ui-settings-general) | `packages/client/ui-settings/src/client/contract/slots.ts:36` |
| 33 | `settings.close` | single | root | client-ui-settings-general CloseLabel | shadows-shipped-ui | an entry in `sidebar.settings` (client-ui-settings-general) | `packages/client/ui-settings/src/client/contract/slots.ts:42` |
| 34 | `settings.general.item` | list | root | client-locale LanguageRow `language`；client-ui-chat TranscriptViewRow `transcript-view`；client-ui-conversation EnterBehaviorRow `composer-enter`；client-ui-permission-presets PermissionRow `permission`；client-ui-theme AppearanceRow `appearance`；client-ui-theme FontSizeRow `font-size` | none | an entry in `settings.section` (client-ui-settings-general) | `packages/client/ui-settings/src/client/contract/slots.ts:89` |
| 35 | `settings.header` | single | root | client-ui-settings-general HeaderContent | shadows-shipped-ui | an entry in `sidebar.settings` (client-ui-settings-general) | `packages/client/ui-settings/src/client/contract/slots.ts:30` |
| 36 | `settings.models.footer` | list | root | （空） | none | an entry in `settings.section` (client-ui-settings-models) | `packages/client/ui-settings-models/src/client/slot-contract.ts:38` |
| 37 | `settings.models.provider-card` | keyed | root | （空） | none | an entry in `settings.section` (client-ui-settings-models) | `packages/client/ui-settings-models/src/client/slot-contract.ts:33` |
| 38 | `settings.onboarding` | list | root | client-ui-settings-models WelcomeNotice `welcome-notice`；DeepSeekOnboardingDialog `deepseek-official` | none | an entry in `sidebar.settings` (client-ui-settings-general) | `packages/client/ui-settings/src/client/contract/slots.ts:74` |
| 39 | `settings.plugin.item` | keyed | root | client-ui-settings-plugins BashCard；AgentLoopCard；SubagentModelSelectionCard；WebSearchCard | none | an entry in `settings.plugins.tab` (client-ui-settings-plugins) | `packages/client/ui-settings-plugins/src/client/slot-contract.ts:19` |
| 40 | `settings.plugins.tab` | list | root | client-ui-settings-plugin-inventory PluginInventorySettingsTab `all`；client-ui-settings-plugins ConfigurablePluginsTab `configurable` | none | an entry in `settings.section` (client-ui-settings-plugins) | `packages/client/ui-settings/src/client/contract/slots.ts:63` |
| 41 | `settings.section` | list | root | client-ui-agent-preset AgentPresetSection `agent-presets`；client-ui-settings-general GeneralSection `general`；client-ui-settings-models ModelsSection `models`；client-ui-settings-plugins PluginsSettingsSection `plugins` | none | an entry in `sidebar.settings` (client-ui-settings-general) | `packages/client/ui-settings/src/client/contract/slots.ts:54` |
| 42 | `settings.trigger` | single | root | client-ui-settings-general TriggerContent | shadows-shipped-ui | an entry in `sidebar.settings` (client-ui-settings-general) | `packages/client/ui-settings/src/client/contract/slots.ts:24` |
| 43 | `shell.overlay` | list | root | （空） | none | an entry in `root` (client-ui-layout) | `packages/client/ui-layout/src/client/index.ts:86` |
| 44 | `sidebar` | single | root | client-ui-sidebar SidebarRoot | shadows-shipped-ui | an entry in `root` (client-ui-layout) | `packages/client/ui-layout/src/client/index.ts:52` |
| 45 | `sidebar.brand.mark` | single | root | client-ui-brand-official OfficialBrandMark | shadows-shipped-ui | an entry in `sidebar` (client-ui-sidebar) | `packages/client/ui-sidebar/src/client/contract/slots.ts:23` |
| 46 | `sidebar.brand.name` | single | root | client-ui-brand-official OfficialBrandName | shadows-shipped-ui | an entry in `sidebar` (client-ui-sidebar) | `packages/client/ui-sidebar/src/client/contract/slots.ts:28` |
| 47 | `sidebar.footer.action` | list | root | client-ui-cordis CordisPanel `cordis-panel` | none | an entry in `sidebar` (client-ui-sidebar) | `packages/client/ui-sidebar/src/client/contract/slots.ts:46` |
| 48 | `sidebar.settings` | single | root | client-ui-settings-general SettingsRoot | shadows-shipped-ui | an entry in `sidebar` (client-ui-sidebar) | `packages/client/ui-sidebar/src/client/contract/slots.ts:41` |
| 49 | `sidebar.workspaces` | single | root | client-ui-workspace WorkspaceBrowser | shadows-shipped-ui | an entry in `sidebar` (client-ui-sidebar) | `packages/client/ui-sidebar/src/client/contract/slots.ts:35` |
| 50 | `sidebar.workspaces.directoryFlow` | single | root | client-ui-directory-picker-browse BrowseDirectoryFlow；client-ui-directory-picker-native NativeDirectoryFlow | shadows-shipped-ui | an entry in `sidebar.workspaces` (client-ui-workspace) | `packages/client/ui-workspace/src/client/contract/slots.ts:59` |
| 51 | `tool.call.toolview` | keyed | session | client-ui-skill SkillRow `skill`；client-ui-tool AskQuestionRow `ask_user_question`；BashRow `bash`；FileMutationRow `edit`；FileMutationRow `write`；ReadRow `read`；SearchRow `grep`；SearchRow `glob`；TodoRow `todo_write`；WebRow `web_search`；WebRow `web_fetch`；client-ui-cordis CordisDefineRow `cordis_define`；CordisRunRow `cordis_run`；CordisActionRow `cordis_stop`；CordisActionRow `cordis_undefine` | shadows-shipped-ui | an entry in `conversation.chat.node` (client-ui-tool) | `packages/client/ui-tool/src/client/contract/slots.ts:26` |
| 52 | `tool.view.cordis` | keyed | session | （空） | none | an entry in `tool.call.toolview` (client-ui-cordis) | `packages/extensions/ui-cordis/src/client/slots.ts:31` |

**分布统计（对 52 条机器计数）**：kind = single 27、list 17、keyed 6、chain 2；scope = root 24、session 25、session-maybe 3（`conversation`/`conversation.composer.bar`/`conversation.input.attachments`）；replaceRisk = `shadows-shipped-ui` 28、`none` 24。

**通用规则**（`slot-catalog.ts:68-75`，`CLIENT_NOTES`）：只经 `ctx.slots.register(options, Component)` 贡献；必须包在 `ctx.slots.inject(key, ...)` 内；不传 `priority`（门面自动分配且低于所有随包条目）；浏览器半无法 `import`，只能 `React.createElement` + `styles.insert(css)`；注册失败会在浏览器半 load report 中体现，用 `cordis_inspect what:"temporary"` 读回。

---

## 6. 装配清单核对（`packages/bundle/web-app/cordis.patch.yml`）

**roster 边界**：段注释头是 **第 151 行**（`# ── browser plugin roster (dsh.client rows; node halves are layer-2 hosts) ──`），最后一条 roster 条目结束于 **第 306 行**（`ui-trajectory` 的 `- id:` 在 305、`name:` 在 306）；第 307 行为空行，第 308 行起是下一段（`# ── the agent plane moves behind agent presets ──`）。
说明：该文件里 roster 行本身**不写 `dsh.client:` 键**——`dsh.client` 是各包 `package.json` 的 manifest 字段，patch 文件里的这些行是 Loader 行，注释在 `:41-42` 与 `:151` 明确它们共同构成被 modules 节点半扫描进 `window.__DSH_BOOT__` 的浏览器 roster。核实样本：`packages/client/ui-trajectory/package.json` 的 `"dsh": { "client": { "inject": [5 个包名], "platform": "web" } }`；`packages/client/modules/package.json` 与 `packages/api/remotes/package.json` 同为 `"dsh": { "platform": "web", "immediately": true }`（`immediately` 只给 stage-one 预取的基础设施行，`packages/client/AGENTS.md` 的 `dsh.client` manifest 语义条）。

**roster 行 ↔ 包名对照（40 行，行号区间为 patch 文件行）**

| # | id | 包名 | 行 | disabled |
|---|---|---|---|---|
| 1 | `modules` | `@deepseek-ai/dsh-client-modules` | 157-158 | |
| 2 | `connection` | `@deepseek-ai/dsh-client-connection` | 162-169 | （带 `inject: [webRuntime]` 与 `trustedHosts` 配置） |
| 3 | `api-remotes` | `@deepseek-ai/dsh-api-remotes` | 171-172 | |
| 4 | `cordis-client-runner` | `@deepseek-ai/dsh-cordis-client-runner` | 174-175 | |
| 5 | `ui-theme` | `@deepseek-ai/dsh-client-ui-theme` | 177-178 | |
| 6 | `locale` | `@deepseek-ai/dsh-client-locale` | 180-181 | |
| 7 | `ui-layout` | `@deepseek-ai/dsh-client-ui-layout` | 183-184 | |
| 8 | `ui-renderer` | `@deepseek-ai/dsh-client-ui-renderer` | 186-187 | |
| 9 | `ui-session` | `@deepseek-ai/dsh-client-ui-session` | 189-190 | |
| 10 | `ui-sidebar` | `@deepseek-ai/dsh-client-ui-sidebar` | 192-193 | |
| 11 | `ui-settings` | `@deepseek-ai/dsh-client-ui-settings` | 195-196 | |
| 12 | `ui-settings-general` | `@deepseek-ai/dsh-client-ui-settings-general` | 198-199 | |
| 13 | `ui-settings-models` | `@deepseek-ai/dsh-client-ui-settings-models` | 201-202 | |
| 14 | `ui-settings-plugin-inventory` | `@deepseek-ai/dsh-client-ui-settings-plugin-inventory` | 204-205 | |
| 15 | `ui-conversation` | `@deepseek-ai/dsh-client-ui-conversation` | 207-208 | |
| 16 | `ui-approval` | `@deepseek-ai/dsh-client-ui-approval` | 210-211 | |
| 17 | `ui-chat` | `@deepseek-ai/dsh-client-ui-chat` | 213-214 | |
| 18 | `ui-brand-official` | `@deepseek-ai/dsh-client-ui-brand-official` | 217-218 | |
| 19 | `ui-attachment` | `@deepseek-ai/dsh-client-ui-attachment` | 220-221 | |
| 20 | `ui-tool` | `@deepseek-ai/dsh-client-ui-tool` | 224-225 | |
| 21 | `ui-cordis` | `@deepseek-ai/dsh-client-ui-cordis` | 227-228 | |
| 22 | `ui-workflow-run` | `@deepseek-ai/dsh-client-ui-workflow-run` | 232-233 | |
| 23 | `ui-deliverables` | `@deepseek-ai/dsh-client-ui-deliverables` | 237-238 | |
| 24 | `ui-workspace` | `@deepseek-ai/dsh-client-ui-workspace` | 241-242 | |
| 25 | `ui-input-trigger` | `@deepseek-ai/dsh-client-ui-input-trigger` | 246-247 | |
| 26 | `ui-commands` | `@deepseek-ai/dsh-client-ui-commands` | 249-250 | |
| 27 | `ui-skill` | `@deepseek-ai/dsh-client-ui-skill` | 252-253 | |
| 28 | `ui-subagent` | `@deepseek-ai/dsh-client-ui-subagent` | 255-256 | |
| 29 | `ui-reference` | `@deepseek-ai/dsh-client-ui-reference` | 258-259 | |
| 30 | `ui-schedule` | `@deepseek-ai/dsh-client-ui-schedule` | 264-266 | **`disabled: true`（266）** |
| 31 | `ui-jobs` | `@deepseek-ai/dsh-client-ui-jobs` | 269-270 | |
| 32 | `ui-goal` | `@deepseek-ai/dsh-client-ui-goal` | 273-274 | |
| 33 | `ui-message-feedback` | `@deepseek-ai/dsh-client-ui-message-feedback` | 278-279 | |
| 34 | `ui-model-selection` | `@deepseek-ai/dsh-client-ui-model-selection` | 282-283 | |
| 35 | `ui-permission` | `@deepseek-ai/dsh-client-ui-permission-presets` | 285-286 | |
| 36 | `ui-agent-preset` | `@deepseek-ai/dsh-client-ui-agent-preset` | 290-291 | |
| 37 | `ui-settings-plugins` | `@deepseek-ai/dsh-client-ui-settings-plugins` | 295-296 | |
| 38 | `ui-plan` | `@deepseek-ai/dsh-client-ui-plan` | 299-300 | |
| 39 | `ui-user-questions` | `@deepseek-ai/dsh-client-ui-user-questions` | 302-303 | |
| 40 | `ui-trajectory` | `@deepseek-ai/dsh-client-ui-trajectory` | 305-306 | |

**roster 内 `disabled: true` 只有一行**：`ui-schedule`（行 264-266，理由注释在 261-263：随包图解析但默认关闭，由 Schedule overlay 同一行开启）。

另有 roster **之外**的客户端包行：`client-hmr`（`@deepseek-ai/dsh-client-hmr`，行 148-149），位于 roster 段之前；注释（144-147）说明其节点半是客户端包、故不能挂在 web-runtime 之下。

**shell 入口**：`apps/web/index.html:11-12` 只有 `<div id="root">` 与 `<script type="module" src="/src/main.ts">`；`apps/web/src/main.ts:4-6` new `AppWebEntry(el).run()`；`AppWebEntry` 在 `packages/client/web/src/boot.ts:22`，读 `window.__DSH_BOOT__`（`:69`）与 `window.__ModuleLoader__`（`:56`），等待 `__DSH_BOOT_READY__`（`:54`），逐行 create 插件并 `assertEntriesActive`（`:138-158`）。`apps/web` 本身不注入 `window.__DSH_BOOT__`（`packages/bundle/web-app/src/index.ts:153` 注释同义）。

---

## 7. 源码未明确 / 需注意的边界

1. **`packages/api/plugin-inventory` 不存在**；只读插件清单的 Remote 在 `packages/host/plugin-inventory/src/index.ts:46, 65`。
2. **ROLE 划分**：`settings-controller` 无 Client 面（目录仅 `src/index.ts`/`src/credentials.ts`/`src/types.ts`/tests），其 Client 消费由 `dsh-api-settings-controller/remote` 生成的声明合并提供。
3. **`/rpc` 独立通道**：`HostConnectionRpc.handle()` 存在（`packages/client/connection/src/rpc.ts:140-143`），但仓库内非测试代码只使用 `intercept('/api', ...)`（Gateway 是唯一调用点，`packages/api/gateway/src/index.ts:199`）；`handle('/rpc')` 仅见于测试（`packages/client/connection/tests/node-half.host.spec.ts:253`）。
4. **SSE 只服务 HMR**：仓库中浏览器侧 `EventSource` 只有 `packages/client/hmr/src/client/index.ts:166`。
5. **`directoryPicker` 的 UI 调用路径**：`packages/client` 下未检出 `remote.directoryPicker.*` 调用点；对应两个 slot 由 `ui-directory-picker-*` 占据（§5 第 14/50 行），但调用链未被本次 grep 证实。
6. **`goals` / `dynamic`(cordis) 的 UI 调用点**：同样未在 `packages/client` 检出直接 `remote.*` 调用，源码未明确。
7. **`$events` 无重放**：普通转发事件在断线后不重放，需 owner 提供查询/游标/开屏基线（`packages/api/remotes/README.md:73`；`packages/api/gateway/README.md:76`）。
8. **cookie 不带 `Secure`，且无登出**（`packages/client/connection/README.md:62-63`）。
9. **`/api` 桥在内存中缓冲整个请求体**，`maxRequestBodyBytes` 默认 300 MiB 同时也是每请求常驻上限（`README.md:61`）。
10. **`websocketHeartbeatIntervalMs` 同时是 Ping 周期与 Pong 截止**，默认 2000ms（`packages/api/gateway/src/index.ts:120-123`；README `:77`）。
