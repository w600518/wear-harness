# DeepSeek Harness 前后端 RPC 通信契约（权威清单）

**适用版本**：`dsh-v0.1.2-rc.1`
**源码根**：`third_party/deepseek-harness`（下文所有相对路径均相对该源码根）
**审计方法**：逐文件阅读源码；每条结论附 `文件:行号` 引用。凡源码未明确的，原文写「源码未明确」。
**本文件用途**：第三方客户端（Flutter / Wear OS）按同一协议实现时的唯一参考。

> 阅读约定：形如 `rpc-host.ts:209-245` 的简写指代「本节上下文所属包内的该文件」；首次出现时给出完整路径。完整索引见附录 A。

---

## 0. 结论速览

| 项 | 值 | 来源 |
| --- | --- | --- |
| HTTP 前缀 | `/api` | `packages/client/connection/src/api-path.ts:7` |
| 一元 RPC 载体 | `POST /api/<namespace>/<method>`，JSON body | `rpc-host.ts:209-245`；`client/rpc.ts:43-51` |
| 流式载体 | WebSocket `GET /api/remote.mux`（Upgrade） | `packages/api/gateway/src/stream-protocol.ts:6`；`gateway/src/index.ts:211-228` |
| 是否用 SSE | RPC/流式**不用** SSE。SSE 仅用于客户端插件 HMR：`GET /plugins/events` | `packages/client/hmr/src/events.ts:44`；`hmr/src/index.ts:176-178` |
| 默认监听 | `127.0.0.1:3080`（可用 `0.0.0.0`） | `packages/bundle/web-app/cordis.patch.yml:120-121` |
| 认证 | 进程启动 token（`?token=`）换 HttpOnly Cookie，名为 `dsh-auth-<base64url(sha256(authority))>`，`SameSite=Strict` | `browser-auth.ts:106-132, 223-302` |
| Host 校验 | Host 必须为 loopback 或 `trustedHosts`；`sec-fetch-site: cross-site` 拒绝；Origin 必须等于 Host | `api-request-trust.ts:91-118` |
| 请求体上限 | 300 MiB（默认） | `http-bridge.ts:12`；`connection/src/index.ts:83` |
| 事件日志 | `$DSH_HOME/sessions/<projectKey>/<encodeSegment(sessionId)>/session.jsonl.zstd` | `session-persistence-jsonl/src/format.ts:37-39, 180-241`；`bundle/base/cordis.patch.yml:110-113` |
| `SESSION_FORMAT_VERSION` | `0` | `packages/core/session/src/types.ts:87` |

---

## 1. 传输层

### 1.1 服务端路由注册

| 路由 | 类型 | 处理器 | 来源 |
| --- | --- | --- | --- |
| `/api` | HTTP `prefix` | Connection 共享通道：先查精确 Fetch 路由，再交 RPC 拦截器；未命中返回 404 | `connection/src/index.ts:113-127`；`rpc-host.ts:116-132` |
| `/api/remote.mux` | HTTP Upgrade（WebSocket） | Gateway 多路复用：认证后交给 `RemoteStreamMuxServer` | `gateway/src/index.ts:205-229`；`stream-server.ts:48-58` |
| `/plugins/<id>/client.js` | HTTP | 前端插件 bundle（由 `client-modules` 行注册，源码未明确其精确路径常量） | `bundle/web-app/cordis.patch.yml:153-158` |
| `/plugins/events` | HTTP `exact`，SSE | 客户端插件 HMR 事件流（`text/event-stream`） | `client/hmr/src/events.ts:44`；`hmr/src/index.ts:176-178` |
| 其余路径 | fallback | 前端 dist 静态服务（`registerFallback`），由 `frontend-static` 占位 | `host/webserver/src/index.ts:196-202`；`host/frontend-static/src/index.ts:124` |

`webServer` 只做路由分发，不定义业务路径（`host/webserver/src/index.ts:1-7`）。路由匹配规则：精确表优先，其后前缀表「最长前缀胜出」，前缀 `p` 匹配 `p` 与 `p/<任何>`（`host/webserver/src/index.ts:317-327`）。

### 1.2 `/api` 请求的信封

**请求**（客户端 → 服务端）：

```json
{
  "type": "client-request",
  "rpcId": "<调用方自铸的唯一字符串>",
  "method": "<namespace>/<method>",
  "payload": { "args": { "<参数名>": "<值>" } }
}
```

约束与来源：

- `type` 必须是字面量 `client-request`；`rpcId` 是非空字符串；`payload` 为任意 JSON（`rpc-schema.ts:35-40`）。
- HTTP 方法必须是 `POST`，否则 404（`rpc-host.ts:210`）。
- `Content-Type` 去掉参数后必须恰为 `application/json`，否则 415（`rpc-host.ts:214-217`）。
- body 必须是合法 JSON，否则 400（`rpc-host.ts:219-224`）。
- 路径中解析出的 endpoint 必须与信封 `method` 完全一致，否则返回 `gateway/bad-request`（`rpc-host.ts:231-237`）。
- `payload` 必须恰好含一个普通对象字段 `args`；不是普通对象、键数不为 1、或 `args` 不是普通对象，都会使调用失败（`gateway/src/index.ts:941-956`）。
- `args` 的键集合必须与方法的**位置参数名**集合一致（见 §2.1），缺失或多出字段报 `gateway/arguments-invalid`（`gateway/src/index.ts:1112-1138`）。

**响应**（服务端 → 客户端）：

```json
{
  "type": "server-response",
  "rpcId": "<与请求相同的 rpcId>",
  "result": { "ok": true,  "value": { } }
}
```

```json
{
  "type": "server-response",
  "rpcId": "<与请求相同的 rpcId>",
  "result": {
    "ok": false,
    "error": { "code": "gateway/internal", "message": "…", "details": {} }
  }
}
```

来源：`rpc.ts:61-77`（类型）、`rpc-schema.ts:21-47`（运行时校验）、`rpc-host.ts:270-277`（成功/失败统一走 `Response.json`）、`client/rpc.ts:73-102`（客户端反向校验）。

客户端不校验 HTTP 之外的错误语义，`response.ok === false` 直接抛 `transport failure for <channel>/<endpoint>: HTTP <status>`（`client/rpc.ts:52-54`）。`rpcId` 不匹配时抛 `rpcId mismatch`（`client/rpc.ts:56-58`）。

**独立于信封的 HTTP 状态码**（这些响应体不是 JSON 信封）：

| 状态 | 触发条件 | 来源 |
| --- | --- | --- |
| 401 | 无有效会话 Cookie / Cookie 归属不符 | `rpc-host.ts:163-167`；`api-request-trust.ts:96-99` |
| 403 | Host 不在可信集合、`sec-fetch-site: cross-site`、Origin 与 Host 不一致 | 同上 |
| 404 | 未知路径、非 POST、endpoint 路径不合法、无匹配注册 | `rpc-host.ts:210-213, 259-268` |
| 413 | `Content-Length` 或实际字节数超过上限；响应后立即 `req.destroy()` | `http-bridge.ts:47-66` |
| 415 | Content-Type 不是 `application/json` | `rpc-host.ts:214-217` |
| 400 | body 不是 JSON | `rpc-host.ts:219-224` |
| 500 | 端点处理器抛异常（**响应体是纯文本 `handler failure: <error>`，不是信封**） | `rpc-host.ts:242-244` |

> 第三方实现要点：`rpc-host.ts:242-244` 的 500 分支不产出信封。客户端必须同时处理「HTTP 非 2xx」与「合法信封中的 `ok:false`」两条路径。

### 1.3 endpoint 路径文法

endpoint 由 `/api/` 之后的部分组成，按 `/` 分段，每段必须匹配 `^[A-Za-z0-9_$.-]+$` 且非空、非 `.`、非 `..`（`rpc-host.ts:259-268`、`rpc.ts:113-119`）。因此合法 endpoint 形如 `session/list`、`goals/create`；`$` 开头的 Gateway 内部端点（`$events`、`$events/result`）也走同一文法（`stream-protocol.ts:9-12`）。

独立 RPC 通道（`connection.rpc.handle(channel, handler)`）可挂载在除 `/api` 之外的绝对前缀上，通道名须匹配 `^/[A-Za-z0-9._~-]+$` 且不得为 `/api`（`rpc-host.ts:32, 279-283`）。**本版本 Web 组合只用 `/api`**；`/rpc` 仅出现在单元测试中（`client/connection/tests/node-half.host.spec.ts:253-441`）。

### 1.4 认证

1. **落地页 token 交换**：启动时打印的 URL 带 `?token=<base64url(32 随机字节)>`。`GET /?token=…`（路径必须为 `/`、`method` 必须为 `GET`、`token` 参数**恰好一个**）时，服务端 `303` 重定向到 `/` 并 `Set-Cookie`；token 不匹配或重复则 401（`browser-auth.ts:223-266`）。

2. **Cookie 形态**（`browser-auth.ts:106-132`）：

```text
名称: dsh-auth-<base64url(sha256(authority))>
值:   v1.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret, base64url(JSON)))>
属性: Max-Age=<秒>; Path=/; Expires=<UTC>; HttpOnly; SameSite=Strict
payload: { "version": 1, "authority": "<host[:port]>", "issuedAt": <ms>, "expiresAt": <ms> }
```

签名密钥持久化在 credential 记录 `credentialKey('client-connection', 'browser-session')` 中（`browser-auth.ts:12, 161-178`）。Cookie 默认寿命 30 天（`connection/src/index.ts:80-90`）。校验要求：`payload.authority` 等于请求 Host、`issuedAt <= now < expiresAt`、`expiresAt > issuedAt`、且寿命不超过配置上限（`browser-auth.ts:289-302`）。

3. **请求头**：服务端只读 `host`、`cookie`、`origin`、`sec-fetch-site`（`api-request-trust.ts:19-23, 91-118`；`browser-auth.ts:289-296`）。**没有** `Authorization`、`X-Token` 之类的自定义鉴权头（源码未定义任何自定义认证请求头）。

4. **Host 白名单（DNS-rebinding 防线）**：`isLoopbackHostname` 只接受字面量 `localhost`、`[::1]`、以及任意 `127.x.y.z`（`loopback-hostname.ts:12-18`）。非 loopback 必须命中 `trustedHosts`（配置项，默认 `[]`），条目须为裸 `host` 或 `host:port`，带端口精确匹配，不带端口匹配该主机的任意端口（`api-request-trust.ts:49-83`；`connection/src/index.ts:70-90`）。

5. **浏览器标记**：`sec-fetch-site: cross-site` 直接拒绝；`Origin` 存在时必须与 Host 同源；`Origin: null` 会被解析失败而拒绝（`api-request-trust.ts:104-117`）。非浏览器客户端（curl、Flutter）只要不带 `Origin`，通过 Host 校验即可。

6. **WebSocket upgrade 认证**：在交给 WebSocket 库之前调用同一 `requestRejection`，失败时以裸 HTTP 401/403 关闭 socket（非 HTTP 响应对象）（`gateway/src/index.ts:214-221`；`stream-server.ts:213-224`）。

### 1.5 错误结构

通用失败结构（所有端点共用）：

```json
{ "code": "string", "message": "string", "details": { } }
```

- 结构定义：`rpc.ts:18-22`（`ConnectionRpcFailure`）；运行时校验 `rpc-schema.ts:10-14`（`details` 为 `string → unknown` 的记录）。
- 传输层失败统一折叠为 `gateway/internal`：`transportError()`（`rpc.ts:37-46`）。
- Gateway 把业务异常折叠为失败时：命中 `RemoteError` 结构标记则原样透出 `code/message/details`，否则折叠为 `gateway/internal`（`gateway/src/index.ts:998-1011`）。

**三个通用 code**（`packages/typert/protocol/src/types.ts:47-54`）：

| code | details | 语义 |
| --- | --- | --- |
| `gateway/bad-request` | `{ issues?: readonly object[] }` | owner 侧业务校验拒绝 |
| `gateway/cancelled` | `{}` | carrier 或后端取消 |
| `gateway/internal` | `{}` | carrier / dispatch / 未分类 Host 失败 |

**Gateway 基础设施 code**（`packages/api/gateway/src/types.ts:100-118`）：

`gateway/ambiguous-endpoint`、`gateway/arguments-invalid`、`gateway/binding-invalid`、`gateway/context-failed`、`gateway/context-not-found`、`gateway/context-unavailable`、`gateway/definition-unavailable`、`gateway/input-invalid`、`gateway/invocation-unavailable`、`gateway/lookup-failed`、`gateway/lookup-not-found`、`gateway/lookup-unavailable`、`gateway/method-unavailable`、`gateway/provider-mismatch`、`gateway/result-invalid`、`gateway/service-unavailable`、`gateway/signature-invalid`。

这 17 个 code 的 `details` **统一**为 `TypertGatewayFaultDetails`（`packages/api/gateway/src/remote-error-codes.ts:7-34`）：

```ts
{ endpoint: string; field?: string }
```

`RemoteError` 实例携带 `isDSHRemoteError: true` 结构标记，跨 realm 识别不依赖 `instanceof`（`packages/typert/protocol/src/remote-error.ts:12-49`）。

各业务命名空间追加的 code 见 §2 对应小节（`RemoteErrorDetailsMap` 声明合并）。

### 1.6 客户端连接生命周期

- 物理连接与逻辑流解耦：`ConnectionController` 维护「代（generation）」概念，指数退避，默认 `backoffBaseMs=500`、`backoffFactor=2`、`backoffMaxMs=10000`、`generationReadyTimeoutMs=3000`，退避延迟带抖动（实际为 `cap/2..cap`）（`client/connection/src/client/connection.ts:15-33, 152-160`）。
- 浏览器网络事件驱动暂停/恢复（`client/connection/src/client/index.ts:165-178`）。
- 每次成功建立代后广播 `connection/reset` 事件，要求刷新由 wire 派生的缓存（`client/connection/src/client/index.ts:19-28`）。
- 客户端打开流的入口只有一处：`ctx.connection.rpc.open(channel, endpoint, payload, signal)`；Web 端由 Gateway 通过 WebSocket 承载（`connection/src/rpc.ts:207-239`；`gateway/src/client/index.ts:457-473`）。

---

## 2. 一元 RPC 端点全表

### 2.1 命名与参数映射规则（先读这一节）

1. **endpoint 名** = `<namespace>/<method>`（`gateway/src/index.ts:1017-1019`）。
2. `namespace` 由服务构造时声明：`super(ctx, serviceKey, { namespace })`，缺省等于 serviceKey（`typert/protocol/src/index.ts:143-169`）。
3. `method` 默认等于被装饰方法名；`@Remote('alias')` 可改名；不带参数的 `@Remote` 用方法名（`typert/protocol/src/index.ts:176-203, 286-314`）。
4. **`args` 的键 = 方法的位置参数名**。反射模式下网关按 `methodParameterNames` 取源码参数名（`gateway/src/index.ts:678, 692-725`）；生成器同样把 `parameter.name` 直接写进 wire（`typert/generator/src/emitter.ts:305-311`）。
5. **名为 `signal` 的最后一个参数不是 wire 字段**：它由 carrier 注入（`gateway/src/index.ts:679-691`）。因此 `args` 中**不要**出现 `signal`。
6. `args` 必须与描述符声明的字段**精确匹配**：未知字段或多缺字段都拒绝（`gateway/src/index.ts:1112-1138`）。
7. 反射模式下**所有** JSON 字段都允许缺省（缺省即传 `undefined`），因此字段可选性在客户端侧并不由协议强制（`gateway/src/index.ts:1124-1132`）。
8. 部分参数是 **lookup 参数**（wire 类型与业务类型不同），典型为 `agent: Agent` 在 wire 上是 `SessionId`（`gateway/src/index.ts:694-724`；客户端实证 `packages/goal/goal/src/index.ts:622` 与 `packages/client/ui-goal/src/client/index.ts:90-105`）。

**客户端组装模板**：

```
POST /api/<namespace>/<method>
{ "type": "client-request", "rpcId": "<uuid>", "method": "<namespace>/<method>", "payload": { "args": { … } } }
```

### 2.2 `session`（SessionController）

来源：`packages/api/session-controller/src/index.ts:116`（`namespace: 'session'`）。

| 端点 | `args` 键（wire） | 返回 `value` |
| --- | --- | --- |
| `session/list` | `_request: SessionListRequest` | `{ items: SessionSummary[] }` |
| `session/search` | `request: SessionSearchRequest` | `{ items: SessionSearchItem[]; hasMore: boolean }` |
| `session/create` | `request: SessionCreateRequest` | `{ sessionId; agentPreset? }` |
| `session/selectModel` | `request: SessionSelectModelRequest` | `{ selected: ModelSelection }` |
| `session/modelCatalog` | （无） | `ModelCatalog` |
| `session/canOpenWorkspacePath` | （无） | `boolean` |
| `session/openWorkspacePath` | `request: SessionOpenWorkspacePathRequest` | `{ opened: true }` |
| `session/rename` | `request: SessionRenameRequest` | `{ title: string; seq: number }` |
| `session/fork` | `request: SessionForkRequest` | `{ sessionId }` |
| `session/prompt` | `request: SessionPromptRequest` | `{ accepted: true }` |
| `session/attachment` | `request: SessionAttachmentRequest` | `{ attachment: ImageAttachmentRef; data: string }` |
| `session/updateQueue` | `request: SessionUpdateQueueRequest` | `{ accepted: true }` |
| `session/cancel` | `request: SessionCancelRequest` | `{ accepted: true }` |
| `session/page` | `request: SessionPageRequest` | `SessionPage` |
| `session/follow` | `request: SessionFollowRequest` | **流式**，见 §3 |
| `session/control` | （无） | **流式**，见 §3 |

方法签名与行号：`list`(213)、`search`(224)、`create`(234)、`selectModel`(244)、`modelCatalog`(253)、`canOpenWorkspacePath`(262)、`openWorkspacePath`(274)、`rename`(305)、`fork`(315)、`prompt`(326)、`attachment`(337)、`updateQueue`(347)、`cancel`(357)、`page`(368)、`follow`(379)、`control`(389)。

字段定义（`packages/api/session-controller/src/types.ts`）：

```ts
SessionListRequest          { cursor?: string }
SessionSearchRequest        { query: string }
SessionSummary              { sessionId; updatedAt: number; running: boolean; blank: boolean;
                              parentSessionId?; origin?: 'subagent'; cwd?; projections?: SessionProjectionHints }
SessionSearchItem           { sessionId; snippet: string }
SessionCreateRequest        { workspaceId?; cwd?; sessionId?; agentPreset? }
SessionCreateValue          { sessionId; agentPreset? }
SessionSelectModelRequest   { sessionId; provider: string; model: string; reasoningEffort?: string }
SessionSelectModelValue     { selected: ModelSelection }        // ModelSelection = { provider, model, reasoningEffort? }
ModelCatalog                { default: ModelSelection; routableProviders: string[];
                              groups: ModelProviderGroup[]; failures: ModelCatalogFailure[] }
ModelProviderGroup          { id; name; models: ModelCatalogModel[] }
ModelCatalogModel           { id; name; description?; reasoning?: ModelReasoning }
ModelReasoning              { efforts: ModelReasoningEffort[]; defaultEffort? }
ModelReasoningEffort        { id; name; description? }
ModelCatalogFailure         { id; name; message }
SessionOpenWorkspacePathRequest { path: string }
SessionRenameRequest        { sessionId; title: string }
SessionForkRequest          { sessionId; atSeq? }
SessionPromptRequest        { requestId: SessionRequestId; sessionId; mode: 'queue' | 'steer';
                              content: PromptContentPart[]; clientTimeZone? }
PromptContentPart           = { type:'text'; text } | { type:'image'; mediaType; data; name? }
SessionAttachmentRequest    { sessionId; attachmentId }
SessionUpdateQueueRequest   { sessionId; itemId: MessageId; action: QueueAction }
QueueAction                 = { kind:'edit'; content: ContentBlock[] } | { kind:'remove' } | { kind:'steer' }
SessionCancelRequest        { sessionId }
```

行号：`types.ts:234-236`(List)、`:244-246`(Search)、`:155-164`(Summary)、`:167-170`(SearchItem)、`:255-266`(Create)、`:269-276`(selectModel)、`:118-146`(Catalog)、`:351-359`(openWorkspacePath)、`:279-288`(rename)、`:291-299`(fork)、`:302-314`(prompt)、`:72-79`(PromptContentPart)、`:317-326`(attachment)、`:329-338`(updateQueue)、`:148-152`(QueueAction)、`:341-348`(cancel)。

`session` 专属错误码（`packages/api/session-controller/src/types.ts:178-208` 与 `core/session/src/types.ts:468-473`）：

| code | details |
| --- | --- |
| `session/not-found` | `{ sessionId }` |
| `session/model-unavailable` | `{ provider, model }` |
| `session/conflict` | `{ sessionId, requestedCwd, existingCwd? }` |
| `session/agent-busy` | `{ reason }` |
| `session/invalid-time-zone` | `{ value }` |
| `session/workspace-attach-failed` | `{ sessionId, workspaceId }` |
| `session/attachment-invalid` | `{ reason }` |
| `session/queue-item-not-found` | `{ itemId }` |
| `session/steer-unavailable` | `{ itemId }` |
| `session/title-invalid` | `{ sessionId }` |
| `session/fork-unavailable` | `{ sessionId }` |
| `agent-preset/conflict` | `{ sessionId, requestedPreset, existingPreset? }` |
| `subagent/not-found` | `{ parentSessionId, childSessionId }` |
| `subagent/catalog-diagnostic` | `{ parentSessionId, childSessionId, reason: 'corrupt'\|'unsupported'\|'unavailable' }` |

### 2.3 `skills`（SessionSkillCatalog）

来源：`packages/api/session-controller/src/skill-catalog.ts:25`（`namespace: 'skills'`）。

| 端点 | `args` | 返回 `value` |
| --- | --- | --- |
| `skills/list` | `request: { sessionId }`、`signal`（carrier） | `{ skills: SkillEntry[] }` |

`SkillEntry = { name: string; description: string; whenToUse?: string; modelInvocable: boolean }`（`types.ts:217-226`）。错误码：`session/not-found`、`gateway/internal`（`skill-catalog.ts:51-57`）。

### 2.4 `fileReferences`（SessionFileReferences）

来源：`packages/api/session-controller/src/file-references.ts:22`。

| 端点 | `args` | 返回 `value` |
| --- | --- | --- |
| `fileReferences/list` | `agent`（= SessionId）、`query: string`、`signal`（carrier） | `FileReferenceCandidate[]` |

### 2.5 `settings`（SettingsController）

来源：`packages/api/settings-controller/src/index.ts:102`（`namespace: 'settings'`）。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `settings/describe` | （无） | `SettingsDescribeValue` |
| `settings/canOpenAgentPresetDirectory` | （无） | `boolean` |
| `settings/update` | `ns: string`、`patch: Record<string, JsonValue>`、`expectedRevision: number \| undefined` | `SettingsNamespaceView` |
| `settings/replace` | `ns`、`section: Record<string, JsonValue>`、`expectedRevision` | `SettingsNamespaceView` |
| `settings/mutate` | `ns`、`ops: SettingsPathOpView[]`、`expectedRevision` | `SettingsNamespaceView` |
| `settings/openSettingsDocument` | （无；`signal` 由 carrier 注入） | `SettingsDocumentOpenValue` |
| `settings/openAgentPresetDirectory` | `agentPreset: string` | `AgentPresetDirectoryOpenValue` |

行号：`describe`(116)、`canOpenAgentPresetDirectory`(130)、`update`(143)、`replace`(160)、`mutate`(179)、`openSettingsDocument`(194)、`openAgentPresetDirectory`(225)。

端点侧字段（`packages/settings/settings/src/types.ts`）：

```ts
SettingsDescribeValue  { writable: boolean; hasDocument: boolean; namespaces: SettingsNamespaceView[] }   // :66
SettingsNamespaceView  { ns: string; schema: JsonValue; value: JsonValue; base?: JsonValue; user?: JsonValue;
                         applies: 'live' | 'restart'; secrets: SettingsSecretView[]; revision: number }      // :33
SettingsSecretView     { path: string[]; set: boolean }                                                   // :21
SettingsPathOpView     = { op:'set'; path: string[]; value: JsonValue } | { op:'unset'; path: string[] }  // :61
```

`JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }`（`packages/util/values/src/index.ts:4`）。

错误码：`settings/conflict`（details `{ ns, expected, actual }`，`index.ts:330-341`）、`settings/rejected`（details `{ ns }`）、`gateway/bad-request`、`gateway/cancelled`、`gateway/internal`、`agent-preset/not-found`、`agent-preset/read-only`（`index.ts:225-258`）。`settings/conflict` 的来源是 Host 侧 `SettingsConflictError`（`code = 'SETTINGS_CONFLICT'`、字段 `expected/actual`，`packages/settings/settings/src/index.ts:154-173`）在 controller 里的映射。

### 2.6 `credentials`（CredentialsController）

来源：`packages/api/settings-controller/src/credentials.ts:70`。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `credentials/describe` | `refs: string[]`（≤64，须匹配 `^[A-Za-z_][A-Za-z0-9_]*$`） | `Record<string, CredentialInfo>` |
| `credentials/set` | `ref: string`、`value: string`（非空） | `null`（`Promise<void>` 序列化为 `null`；源码返回 `void`） |
| `credentials/unset` | `ref: string` | 同上 |

行号：`describe`(82)、`set`(99)、`unset`(112)。

```ts
CredentialInfo { configured: boolean; source?: string; writable: boolean }   // packages/credentials/credentials/src/types.ts:67
CredentialRef  = Branded<'CredentialRef'>    // 品牌字符串，POSIX 风格环境变量名（:14）
```

错误码：`credential/rejected`（details `{ ref }`，`credentials.ts:141-152`）、`gateway/bad-request`、`gateway/internal`。密钥**只单向过 wire**：没有任何读路径返回密钥值（`credentials.ts:64-66`）。

### 2.7 `workspace`（WorkspaceController）

来源：`packages/api/workspace-controller/src/index.ts:42`（`namespace: 'workspace'`）。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `workspace/create` | `request: { path: string }` | `{ workspace: WorkspaceView; created: boolean }` |
| `workspace/rename` | `request: { workspaceId; title }` | `{ workspace: WorkspaceView }` |
| `workspace/delete` | `request: { workspaceId }` | `{ deleted: true }` |
| `workspace/insertBefore` | `request: { workspaceId; beforeWorkspaceId? }` | `{ workspaceIds: WorkspaceId[] }` |
| `workspace/insertSessionBefore` | `request: { workspaceId; sessionId; beforeSessionId? }` | `{ workspace: WorkspaceView }` |
| `workspace/archiveSession` | `request: { sessionId }` | `{ archivedSessionIds: SessionId[] }` |
| `workspace/follow` | （无） | **流式**，见 §3 |

行号：`:57, 67, 77, 87, 97, 107, 117`。类型：`workspace-controller/src/types.ts:15-128`。

```ts
WorkspaceView { workspaceId; path: string; title: string; sessionIds: SessionId[];
                createdAt: string; updatedAt: string }   // ISO-8601 字符串
```

错误码（`types.ts:29-49`）：`workspace/invalid-path` `{ path }`、`workspace/name-conflict` `{ name }`、`workspace/move-invalid` `{ workspaceId, sessionId, beforeSessionId? }`、`directory-picker/unavailable|unreadable|exists|create-failed`。

### 2.8 `directoryPicker`（DirectoryPickerController）

来源：`packages/api/workspace-controller/src/directory-picker.ts:46`。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `directoryPicker/pick` | （无；`signal` 由 carrier 注入） | `string \| null`（宿主绝对路径，取消为 `null`） |
| `directoryPicker/list` | `path: string \| undefined` | `DirectoryListing` |
| `directoryPicker/createDirectory` | `path: string`、`name: string`（单段、非空白、无 `/` `\`） | `string`（新目录绝对路径） |

行号：`:54, 71, 87`。注意该命名空间仅在组合了 picking 后端时注册（`workspace-controller/src/index.ts:45-49`）。

### 2.9 `goals`（GoalService）

来源：`packages/goal/goal/src/index.ts:251`（`namespace: 'goals'`）。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `goals/create` | `agent`（= SessionId）、`request: CreateGoalRequest` | `{ ref: GoalRef }` |
| `goals/edit` | `agent`、`ref: GoalRef`、`request: EditGoalRequest` | `GoalView` |
| `goals/pause` | `agent`、`ref` | `GoalView` |
| `goals/resume` | `agent`、`ref` | `GoalView` |
| `goals/complete` | `agent`、`ref` | `GoalView` |
| `goals/clear` | `agent`、`ref` | `GoalRef` |

行号：`create`(622)、`edit`(326)、`pause`(349)、`resume`(361)、`complete`(388)、`clear`(430)。本命名空间全部方法**没有** `AbortSignal` 参数。

```ts
GoalRef            { id: GoalId; revision: number }
GoalSnapshot       { id; revision; objective: string; phase: GoalPhase;
                     blockedReason?: { code: string; message: string }; maxGoalRounds: number }
GoalView           = GoalSnapshot & { roundsStarted: number; createdAt: number;
                                      updatedAt: number; activation: 'armed' | 'disarmed' }
GoalPhase          = 'active' | 'paused' | 'blocked' | 'complete'
CreateGoalRequest  { objective: string; maxGoalRounds?: number }
CreateGoalResult   { ref: GoalRef }
EditGoalRequest    { objective?: string; maxGoalRounds?: number }   // 至少一个
```

行号：`packages/goal/goal/src/types.ts:19, 27, 33, 38, 44, 51, 59, 71, 74`。

**错误形态**：本命名空间**不抛 `RemoteError`**，失败是 `GoalError`（普通 `Error` 子类）带 `code: string`：`GOAL_AGENT_NOT_LIVE`、`GOAL_NOT_FOUND`、`GOAL_ALREADY_EXISTS`、`GOAL_STALE_REVISION`、`GOAL_INVALID_OBJECTIVE`、`GOAL_INVALID_MAX_ROUNDS`、`GOAL_INVALID_BLOCK_REASON`、`GOAL_INVALID_EDIT`、`GOAL_INVALID_TRANSITION`（`goal/goal/src/domain.ts:93-102`；抛出点 `index.ts:201-524`）。这些 code **不在** `RemoteErrorDetailsMap` 中，因此过 wire 时会被 Gateway 折叠为 `gateway/internal`（`gateway/src/index.ts:998-1010`）—— 第三方客户端无法从 wire 上区分这些具体原因，**源码未明确**提供映射。

### 2.10 `agentPresets`（AgentPresetService）

来源：`packages/preset/agent-presets/src/index.ts:164`。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `agentPresets/list` | （无） | `{ presets: AgentPresetRow[]; authorable: boolean }` |
| `agentPresets/select` | `agent`（= SessionId）、`agentPreset: string` | `string` |
| `agentPresets/read` | `agentPreset: string` | `AgentPresetDocument` |
| `agentPresets/copy` | `from: string`、`id: string`、`name?: string` | `void` |
| `agentPresets/deletePreset` | `id: string` | `void` |

行号：`list`(260)、`read`(512)、`copy`(564)、`deletePreset`(602)、`select`(694)。无 `AbortSignal` 参数。

```ts
AgentPresetRow      { id; trust: 'system'|'user'; isDefault: boolean; name?; description?; broken? }
AgentPresetRoster   { presets: AgentPresetRow[]; authorable: boolean }
AgentPresetDocument { agentPreset: string; trust; content: string; name?; description? }
```

行号：`preset/agent-presets/src/types.ts:11, 27, 48`。错误码：`agent-preset/not-found` `{ agentPreset, available }`、`agent-preset/invalid` `{ agentPreset, reason }`、`agent-preset/read-only` `{ agentPreset, reason }`、`agent-preset/locked` `{ sessionId, agentPreset }`、`gateway/bad-request`（`types.ts:37-43`）。

### 2.11 `subagents`（SubagentRuntime）

来源：`packages/subagent/subagent/src/index.ts:202`。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `subagents/list` | `parentSessionId: SessionId`、`signal`（carrier） | `SubagentCatalog` |
| `subagents/prompt` | `request: SubagentPromptRequest`、`signal`（carrier） | `{ messageId: MessageId }` |
| `subagents/interruptByParent` | `childSessionId`、`parentSessionId`、`mode: 'continuable'` | `{ accepted: true }` |

行号：`list`(383)、`prompt`(409)、`interruptByParent`(475)。

```ts
SubagentCatalog        { entries: SubagentListEntry[]; parentAvailable: boolean }
SubagentListEntry      = { kind:'child'; id; activity:'running'|'inactive'; hasChildren: boolean;
                           mode:'one-shot'; label? } | { kind:'child'; …; mode:'continuable'; label: string }
                       | { kind:'diagnostic'; id; reason:'corrupt'|'unsupported'|'unavailable' }
SubagentPromptRequest  { requestId; parentSessionId; childSessionId; mode:'continuable';
                         content: PromptContentPart[]; clientTimeZone? }
```

行号：`subagent/subagent/src/control-types.ts:33, 81, 98, 116, 121`。错误码：`subagent/invalid-time-zone` `{ value }`、`subagent/parent-unavailable` `{ parentSessionId }`、`subagent/not-resumable` `{ childSessionId }`、`subagent/unauthorized` `{ childSessionId }`、`subagent/attachment-invalid` `{ reason }`、`subagent/delivery-unavailable` `{ childSessionId }`、`subagent/projections-unavailable` `{}`（`control-types.ts:132-144`）。

### 2.12 `commands`（CommandRegistry）

来源：`packages/interaction/commands/src/index.ts:266`。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `commands/list` | `agent`（= SessionId） | `CommandDescriptor[]` |
| `commands/execute` | `agent`、`line: string`、`images: EncodedImageAttachment[]`、`signal`（carrier） | `CommandExecution \| undefined` |

行号：`list`(288)、`execute`(332)。

```ts
CommandDescriptor { name: string; description: string; input?: { hint: string; images?: boolean } }
CommandExecution  { commandId: CommandId; result: CommandResult }
CommandResult     = { kind:'success'; text?; sourceEventSeq? } | { kind:'error'; text: string }
```

行号：`interaction/commands/src/types.ts:14, 28, 43, 51`。本命名空间不抛 `RemoteError`。

### 2.13 `sessionReferenceResolver`

来源：`packages/context/session-reference/src/index.ts:92`（serviceKey 同名，未覆盖 namespace）。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `sessionReferenceResolver/candidates` | `agent`（= SessionId）、`query: string`、`signal`（carrier） | `SessionReferenceMentionCandidate[]` |

`SessionReferenceMentionCandidate = { sessionId; label; cwd?; sameWorkspace: boolean; createdAt: number; mention: string }`（`context/session-reference/src/types.ts:65`；`mention` 形如 `@[label](dsh-session:…)`）。该命名空间不抛 `RemoteError`，失败为 `SessionReferenceError` 的 `code`（`SESSION_REFERENCE_INVALID_REFERENCE`、`SESSION_REFERENCE_CANCELLED` 等，`context/session-reference/src/config.ts:21-31`），同样会被折叠为 `gateway/internal`。

### 2.14 `llm`（LlmRuntime）

来源：`packages/llm/llm/src/index.ts:335`（`super(ctx, 'llm')`，未传 options，namespace 即 serviceKey）。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `llm/listProviders` | （无） | `LlmProviderInfo[]` |
| `llm/listConfigurableProviders` | （无） | `LlmConfigurableProvider[]` |
| `llm/discoverModels` | `settingsNs: string`、`request: LlmModelDiscoveryRequest`、`signal`（carrier） | `LlmDiscoveredModel[]` |

行号：`listProviders`(461)、`listConfigurableProviders`(533)、`remoteDiscoverModels`(620，导出名 `discoverModels`)。三者均为 unary（未声明 `mode: 'stream'`）。

> 注意：同文件 `index.ts:580` 的 `discoverModels(...)` **没有** `@Remote`，不是端点（Host 内部方法）。wire 上的端点由 `remoteDiscoverModels` 实现，`@Remote('discoverModels')` 提供的才是端点名。

```ts
LlmProviderInfo           { id: string; name: string }                                     // types.ts:182
LlmConfigurableProvider   { provider: string; displayName: string; settingsNs: string;
                            settingsPath: readonly string[]; declared?: boolean }            // types.ts:204
LlmModelDiscoveryRequest  { provider?: string; baseURL?: string; api?: string; apiKey?: string }  // types.ts:233
LlmDiscoveredModel        { id: string; name?: string; contextWindow?: number; maxTokens?: number } // types.ts:273
```

错误码：`llm/model-discovery-rejected`（details `{ settingsNs: string; baseURL?: string }`，声明 `types.ts:258-266`，抛出 `index.ts:629-637`）。包内其他失败（`LlmError` 的 `NO_DISCOVERY`、`INVALID_DISCOVERY` 等）会先被该 catch 包装，不构成独立 wire code。

### 2.15 `messageFeedback`（MessageFeedbackService）

来源：`packages/feedback/message-feedback/src/index.ts:169`（`super(ctx, 'messageFeedback')`，未传 options）。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `messageFeedback/list` | `request: { sessionId }` | `MessageFeedbackListResult` |
| `messageFeedback/put` | `request: MessageFeedbackPutRequest` | `MessageFeedbackPutResult` |
| `messageFeedback/delete` | `request: MessageFeedbackDeleteRequest` | `MessageFeedbackDeleteResult` |

行号：`list`(190)、`put`(206)、`delete`(272)。三者**均无** `signal` 参数，因此 `args` 只有 `request` 一个字段。

```ts
MessageFeedbackListRequest   { sessionId: SessionId }                                  // types.ts:35
MessageFeedbackListValue     { items: MessageFeedbackItem[] }                          // :41
MessageFeedbackPutRequest    { sessionId; messageId: MessageId; rating: 'positive'|'negative';
                               note?: string; ifVersion: MessageFeedbackVersion | null } // :47
MessageFeedbackDeleteRequest { sessionId; messageId; ifVersion: MessageFeedbackVersion } // :61
MessageFeedbackDeleteValue   { absent: true }                                          // :71
MessageFeedbackItem          { messageId; rating; note?: string; version;
                               createdAt: number; updatedAt: number }                    // :19
```

**本命名空间的失败走业务 union，不走 `RemoteError`**（`types.ts:109-145`）：

```ts
MessageFeedbackListResult = { ok:true; value: MessageFeedbackListValue }
                          | { ok:false; error: { code:'session-not-found'; sessionId } }
// put / delete 的 error 分支 additionally:
//   { code:'target-not-found'; sessionId; messageId }
//   { code:'version-conflict'; current: MessageFeedbackItem | null }
//   { code:'note-blank' }
//   { code:'note-too-large'; maxBytes: number; actualBytes: number }
```

> 第三方实现要点：信封的 `result.ok` 与业务 union 的 `ok` **是两层**。业务拒绝依然以 `result.ok === true` 返回，reason 在 `value.error.code` 里。

### 2.16 `pluginInventory`

来源：`packages/host/plugin-inventory/src/index.ts:50`。

| 端点 | `args` 键 | 返回 `value` |
| --- | --- | --- |
| `pluginInventory/list` | （无） | `{ entries: PluginInventoryEntry[]; agentPresets?: AgentPresetPluginGroup[] }` |

```ts
PluginInventoryEntry { entryId; moduleName: string; enabled: boolean;
                       fiberPhase: 'pending'|'loading'|'active'|'failed'|'unloading'|null }
```

行号：`host/plugin-inventory/src/types.ts:7, 16, 29, 47, 63`。该端点源码中不抛任何错误。

### 2.17 `dynamicCordisRunner`（CordisHostRunner，可选组合）

来源：`packages/extensions/cordis-host-runner/src/index.ts:140`（`super(ctx, 'dynamicCordisRunner')`，未覆盖 namespace）。

| 端点 | `args` 键（行号） | 返回 `value` |
| --- | --- | --- |
| `dynamicCordisRunner/undefineFromPanel` | `agent`、`pluginId`(226) | `DynamicCordisUndefineReceipt` |
| `dynamicCordisRunner/runHostHalf` | `agent`、`pluginId`、`packageId`、`mode`、`requestId: ApprovalRequestId \| null`、`approveFutureVersions: boolean`(324) | `DynamicCordisHostHalfResult` |
| `dynamicCordisRunner/getClientCode` | `agent`、`pluginId`、`pluginRunId`(383) | `DynamicCordisClientSource` |
| `dynamicCordisRunner/resolveRequestRun` | `requestId`、`resolution`(412) | `DynamicCordisResolveAck` |
| `dynamicCordisRunner/settleUserRun` | `agent`、`pluginId`、`resolution`(437) | `DynamicCordisRunResponse` |
| `dynamicCordisRunner/stopFromPanel` | `agent`、`pluginId`(479) | `DynamicCordisStopResponse` |
| `dynamicCordisRunner/syncInspectManifest` | `providers: CordisInspectProviderManifest[]`(497) | `null` |
| `dynamicCordisRunner/resolveInspectQuery` | `agent`、`requestId`、`resolution`(510) | `DynamicCordisResolveAck` |
| `dynamicCordisRunner/inventory` | （无）(524) | `DynamicCordisInventoryRow[]` |
| `dynamicCordisRunner/reportRenderFailure` | `agent`、`pluginId`、`pluginRunId`、`failure`(683) | `null` |
| `dynamicCordisRunner/reportClientGuardFailure` | `agent`、`pluginId`、`pluginRunId`、`failure`(693→717) | `null` |
| `dynamicCordisRunner/invoke` | `pluginId`、`pluginRunId`、`method: string`、`args: JsonValue`(740) | `DynamicCordisInvokeResult` |

字段类型见 `packages/extensions/cordis-host-runner/src/types.ts`（本文件未逐字段展开，**源码未明确于本文档**）。该命名空间**在** `packages/api/remotes/src/client/index.ts:146-150` 的客户端挂载列表内（`dynamicRemote`），但其 Host 端插件属于可选组合。

### 2.18 其他未挂载命名空间（列表性说明）

以下命名空间存在 `@Remote` 服务，但**不在** `packages/api/remotes/src/client/index.ts:146-150` 的 Web 客户端挂载列表内，第三方客户端默认无需实现：

| 命名空间 | 来源 | 说明 |
| --- | --- | --- |
| `agentTeams` | `packages/experimental/agent-team/src/index.ts:81`；`@Remote('view'\|'createTask'\|'updateTask')`(:242,256,267) | 位于 `packages/experimental`（仓库说明：私有原型、官方发布排除，`AGENTS.md` 包分组） |
| （无）`webhook` | `packages/webhook/webhook/tests/runtime.spec.ts:210` 断言该包**没有** `@Remote` | 该包不提供 Remote 端点，非「未挂载」而是「不存在」 |

### 2.19 客户端挂载清单（第三方客户端应实现的集）

`packages/api/remotes/src/client/index.ts:146-150` 明确列出 Client 侧挂载的 12 个贡献：`agentPresets`、`commands`、`settings`（含 `credentials`）、`goals`、`llm`、`dynamicCordisRunner`、`pluginInventory`、`messageFeedback`、`sessionReferenceResolver`、`subagents`、`session`、`workspace`。

完整的 wire 命名空间清单（本版本可出现的全部）：`session`、`skills`、`fileReferences`、`settings`、`credentials`、`workspace`、`directoryPicker`、`goals`、`agentPresets`、`subagents`、`commands`、`sessionReferenceResolver`、`pluginInventory`、`llm`、`messageFeedback`、`dynamicCordisRunner`；另有 Gateway 内部两个：`$events`、`$events/result`。

按命名空间统计（本文档逐条列出的一元端点）：

| namespace | 一元端点数 | 流式端点数 |
| --- | --- | --- |
| `session` | 14 | 2（`session/follow`、`session/control`） |
| `skills` | 1 | 0 |
| `fileReferences` | 1 | 0 |
| `settings` | 7 | 0 |
| `credentials` | 3 | 0 |
| `workspace` | 6 | 1（`workspace/follow`） |
| `directoryPicker` | 3 | 0 |
| `goals` | 6 | 0 |
| `agentPresets` | 5 | 0 |
| `subagents` | 3 | 0 |
| `commands` | 2 | 0 |
| `sessionReferenceResolver` | 1 | 0 |
| `llm` | 3 | 0 |
| `messageFeedback` | 3 | 0 |
| `pluginInventory` | 1 | 0 |
| `dynamicCordisRunner` | 12 | 0 |
| `$events`（Gateway 内部） | 0 | 1 |
| `$events/result`（Gateway 内部） | 1 | 0 |
| **合计** | **72** | **4** |

> 注意：「挂载」是客户端命名空间服务化，端点是否可调用还取决于 Host 组合是否加载了对应插件。`dynamicCordisRunner` 在此列表中，但其 Host 端组合是可选的。

**开发夹具的覆盖范围（交叉校验用）**：`packages/client/connection/src/client/fixture.ts` 的 `call()` 分派 `switch (endpoint)`（:3436-3589）与 `open()` 分派（:3591-3604）覆盖以下端点，可作为上表的独立校验源：

`commands/list`、`commands/execute`、`fileReferences/list`、`sessionReferenceResolver/candidates`、`directoryPicker/pick`、`directoryPicker/list`、`directoryPicker/createDirectory`、`goals/create`、`goals/edit`、`goals/pause`、`goals/resume`、`goals/complete`、`goals/clear`、`agentPresets/list`、`agentPresets/select`、`agentPresets/read`、`agentPresets/copy`、`agentPresets/deletePreset`、`subagents/list`、`subagents/prompt`、`subagents/interruptByParent`、`credentials/describe`、`credentials/set`、`credentials/unset`、`settings/describe`、`settings/canOpenAgentPresetDirectory`、`settings/openSettingsDocument`、`settings/openAgentPresetDirectory`、`settings/update`、`settings/replace`、`settings/mutate`、`skills/list`、`session/openWorkspacePath`、`session/canOpenWorkspacePath`、`session/modelCatalog`、`llm/listProviders`、`llm/listConfigurableProviders`、`llm/discoverModels`、`session/list`、`session/search`、`session/create`、`session/selectModel`、`session/rename`、`session/fork`、`session/prompt`、`session/attachment`、`session/updateQueue`、`session/cancel`、`session/page`、`$events/result`、`workspace/create`、`workspace/rename`、`workspace/delete`、`workspace/insertBefore`、`workspace/insertSessionBefore`、`workspace/archiveSession`；流式：`$events`、`session/control`、`session/follow`、`workspace/follow`。

该夹具**不覆盖**：`messageFeedback/*`、`pluginInventory/list`、`dynamicCordisRunner/*`。夹具默认不在生产路径上启用，只在页面 URL 带 `fixture` 查询参数时生效（`packages/client/connection/src/client/index.ts:184-189`）。

---

## 3. 流式端点

### 3.1 载体：WebSocket 多路复用（不是 SSE）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 路径 | `/api/remote.mux` | `gateway/src/stream-protocol.ts:6` |
| 协议 | WebSocket **文本帧**，JSON；收到二进制帧即 `close(1003)` | `stream-server.ts:116-125` |
| URL 构造 | 同源 origin，`http:`→`ws:`、`https:`→`wss:` | `gateway/src/client/stream-client.ts:304-310` |
| 心跳 | 服务端周期性 `ping`；连续 `MAX_MISSED_HEARTBEATS = 2` 次未收到 `pong` 则 `terminate()` | `stream-server.ts:22, 75-94` |
| 认证 | Upgrade 时复用 HTTP 的 Host/Origin/Cookie 校验，失败回裸 401/403 | `gateway/src/index.ts:214-221`；`stream-server.ts:213-224` |
| 非法消息 | 解析失败 → `close(1008, 'invalid Remote stream request')` | `stream-server.ts:124-125` |

客户端来源：`client/hmr` 的 SSE 与本通道无关（`hmr/src/events.ts:44`）。

### 3.2 客户端 → 服务端消息

```ts
type RemoteStreamClientMessage =
  | { type: 'open';   streamId: string; endpoint: string; payload: unknown }
  | { type: 'cancel'; streamId: string }
```

来源：`stream-protocol.ts:242-284`。字段**精确**校验：`open` 的键必须恰为 `type/streamId/endpoint/payload`，`streamId` 非空，`endpoint` 非空；`cancel` 的键必须恰为 `type/streamId`（`stream-protocol.ts:270-284`）。

- `streamId` 由客户端自铸（浏览器端用 `randomUUID()`，`stream-client.ts:86`）。同一连接内重复 `streamId` 会让服务端抛错并关闭连接（`stream-server.ts:140-142`）。
- `payload` 与一元调用同构：`{ "args": { … } }`（`gateway/src/client/index.ts:468`；服务端 `remoteRequest()` 在 `gateway/src/index.ts:941-956` 做同样的精确校验）。
- **取消机制**：发送 `{ type: 'cancel', streamId }` 让服务端 abort 该逻辑流的 `AbortSignal`（`stream-server.ts:136-139`）。客户端迭代器提前返回（`return()`/`break`/signal abort）时也会自动补发 `cancel`（`stream-client.ts:113-119`）。物理连接断开时服务端 abort 全部活动流（`stream-server.ts:129-131`）。

### 3.3 服务端 → 客户端消息

```ts
type RemoteStreamServerMessage =
  | { type: 'item';  streamId: string; value?: unknown }
  | { type: 'error'; streamId: string; error: { code: string; message: string; details: object } }
  | { type: 'end';   streamId: string }
```

来源：`stream-protocol.ts:252-313`。`item` 的键为 `type/streamId` 或 `type/streamId/value`（`value` 可省略）。`error` 的 `error` 键必须恰为 `code/message/details`。

终结语义（`stream-server.ts:155-178`）：正常迭代结束发 `end`；抛错且未 abort 则发 `error`；`error` 帧本身无法编码或发送时，`close(1011)` 使整个物理代失效。客户端收到 `error` 时以 `RemoteError(code, message, details)` 抛出（`stream-client.ts:108-112`）。

### 3.4 流式端点清单

| endpoint | `args` | 首个 `item.value` | 后续 `item.value` | 来源 |
| --- | --- | --- | --- | --- |
| `session/follow` | `{ request: { address, maxMessages? } }` | `{ type:'snapshot', header, cursor, records, hasMore, projections }` | `{ type:'event', event: SessionWireEvent }` | `api/session-controller/src/types.ts:446-467`；`history.ts:105-190` |
| `session/control` | `{ }`（空 args） | `{ type:'baseline', value: SessionControlBaseline }` | `{ type:'queue'\|'jobs'\|'projection', … }` | `types.ts:493-513`；`control.ts:54-65` |
| `workspace/follow` | `{ }` | `{ type:'baseline', value: { items, archivedSessionIds } }` | `{ type:'upsert'\|'remove'\|'order'\|'archived', … }` | `workspace-controller/src/types.ts:112-128`；`feed.ts:82-93` |
| `$events` | `{ }`（必须恰为空对象） | `{ type:'ready', clientId, host: { home } }` | `{ type:'emit', event, args }` / `{ type:'waterfall', event, eventId, agentId, request }` / `{ type:'cancel', eventId }` | `stream-protocol.ts:14-70`；`gateway/src/index.ts:384-410` |
| `$events/result`（**一元**，走 POST） | `{ args: RemoteEventResult }` | — | — | `stream-protocol.ts:86-137`；`gateway/src/index.ts:357-371` |
| 任意一元端点 | — | — | — | 一元方法经流式通道打开会报 `gateway/signature-invalid`（`gateway/src/index.ts:321-329`） |

`session/control` 与 `workspace/follow` **没有参数**，因此 `args` 是空对象 `{}`（`gateway/src/index.ts:391-403` 对 `$events` 明确要求「恰为空的 args 对象」；`session/control`、`workspace/follow` 由同一 `remoteRequest` 路径校验，允许 `args` 为空对象）。

`session/follow` 的 `address` 判别联合：

```ts
SessionAddress =
  | { kind: 'session';   sessionId: SessionId }
  | { kind: 'subagent';  parentSessionId; childSessionId; mode: 'one-shot' | 'continuable' }
```

`maxMessages` 若提供必须是正安全整数，否则 `gateway/bad-request`（`history.ts:249-259`）。后续帧强制 gap-free：若服务端发现 seq 跳号，抛 `gateway/internal`「session event stream skipped seq N」（`history.ts:176-180`）。

### 3.5 浏览器侧的流生命周期（第三方客户端应复刻的语义）

- 一条物理 WebSocket 之上承载任意多条逻辑流；`RemoteStreamMuxClient` 负责 socket 保活与重连调度（`stream-client.ts:34-120`）。
- 领域层用 `RemoteStream` 包装逻辑流：每次 carrier 丢失后重开一个「代（generation）」，consumer 必须显式 `accept()` 首个基线/游标帧才算建立（`gateway/src/client/remote-stream.ts:8-29, 95-157`）。
- 重连时序由 Connection 的代信号驱动：`connection.generation.getSnapshot() !== undefined` 时第 2 次尝试直接重试；否则等待下一代（`remote-stream.ts:160-197`）。
- Snapshot 流（control / workspace）用 `RemoteSnapshotStream` 区分基线替换与增量更新（`client/snapshot-stream.ts`；`workspace-controller/src/client/index.ts:87-94`）。
- Journal 流（session 事件）用 `RemoteJournalStream` 处理 `opened/entry/prepend/replace`（`client/journal-stream.ts`；`session-controller/src/client/transport.ts:135-191`）。

---

## 4. 会话事件类型全表

### 4.1 事件信封

```ts
interface SessionEvent {
  type: string        // 事件 tag
  seq: number         // 会话内单调序号
  time: number        // Unix epoch 毫秒
  data: <该 type 对应载荷>
  ignorable?: true    // 读取方遇到不认识的 type 时可安全跳过；缺省表示必须读
  sourceEventSeqs?: number[]   // 仅 surface 事件
  surfaceOp?: 'append' | { op:'replace'; start: number; end: number }  // 仅 surface 事件
}
```

来源：`packages/core/session/src/types.ts:434-466`。

关键约束：

- **`ignorable` 语义**：缺省即「必需」。未知 type 且无 `ignorable: true` 时，读取方**必须拒绝**重建会话（`core/session/src/types.ts:442-452`；白名单 `core/session/src/known-event-types.ts:22-74`）。
- **surface 事件仅 3 种**：`user/message`、`assistant/message`、`tool/result`（`types.ts:373-376`）。只有它们可携带 `surfaceOp` / `sourceEventSeqs`（`types.ts:453-465`）。
- `surfaceOp: 'append'` 为普通追加；`{ op:'replace', start, end }` 用本节点替换 `start..end`（闭区间）的现存 surface 节点，且 `sourceEventSeqs` 必须包含所有被遮蔽节点的 seq（`types.ts:389-404`）。

### 4.2 核心会话与循环事件

| tag | data 字段 | 来源 |
| --- | --- | --- |
| `turn/start` | `{ turn: number }` | `core/session/src/types.ts:266` |
| `turn/end` | `{ turn: number; reason: TurnEndReason }` | `:275` |
| `step/start` | `{ turn: number; step: number }` | `:277` |
| `step/end` | `{ turn: number; step: number }` | `:279` |
| `user/message` | `UserMessage`（surface 事件） | `:287` |
| `assistant/chunk` | `{ turn; step; chunk: StreamChunk }` | `:289` |
| `assistant/message` | `{ turn; step; message: AssistantMessage; usage?: TokenUsage; interrupted?: true }`（surface） | `:300` |
| `tool/call` | `{ turn; step; callId: ToolCallId; name: string; arguments: string }` | `:306` |
| `tool/result` | `{ turn; step; message: ToolResultMessage; error?: { name; code }; meta?: JsonValue }`（surface） | `:318-324` |
| `request/header` | `{ header: EpochHeader; reason: 'initial'\|'resume'\|'change'\|'series'; startsSeries?: true }` | `:329-334` |
| `request/context` | `{ provider: string; model: string; contextWindow?: number }` | `:234-241` |
| `session/end-seed` | `Record<string, never>`（空载荷） | `:362` |

`TurnEndReason` 判别联合（`types.ts:193-215`）：

```ts
{ kind: 'completed' }
{ kind: 'aborted';  reason: TurnEndCancelCause }
{ kind: 'blocked' }
{ kind: 'error';    error: LlmFailure }
{ kind: 'max-tokens' }
{ kind: 'interrupted' }   // 持久化后端在重载时关闭崩溃遗留的 turn
TurnEndCancelCause = { kind:'user' } | { kind:'parent' } | { kind:'hook'; reason: string }
                   | { kind:'disposed' } | { kind:'legacy' }
```

`EpochHeader`（`types.ts:222-231`）：`{ config: LlmCallConfig; adapterDefaults?; system?: string; tools?: ToolSchema[] }`。

### 4.3 agent 与工具事件

| tag | data 字段 | 来源 |
| --- | --- | --- |
| `agent/inbox/spliced` | `{ target: 'next-turn'\|'next-step'; start: number; removedCount?: number; inserted: UserMessage[]; outcome?: 'canceled' }` | `core/agent/src/types.ts:58-64` |
| `tool/code-dispatch-start` | `{ rootCallId; parentCallId; subCallId; name; arguments: unknown }` | `core/tools/src/types.ts:11-17, 40` |
| `tool/code-dispatch` | `{ rootCallId; parentCallId; subCallId; name; arguments; isError: boolean; content: ContentBlock[] }` | `core/tools/src/types.ts:20-23, 56` |

### 4.4 交互类事件

| tag | data 字段 | 来源 |
| --- | --- | --- |
| `approval/asked` | `{ id: ApprovalRequestId; toolName: string; callId?: ToolCallId; reason?: string }` | `interaction/user-approval/src/types.ts:44-49` |
| `approval/decided` | `{ id: ApprovalRequestId; outcome: 'allowed-once'\|'rejected'\|'cancelled'\|'unavailable' }` | `:55-58` |
| `approval/policy` | `{ policy: 'ask'\|'never'; source?: 'delegation' }` | `interaction/user-approval/src/index.ts:33-37` |
| `command/run` | `{ commandId: CommandId; name: string; args?: string; source: { kind:'user' } }` | `interaction/commands/src/types.ts:97` |
| `command/done` | `{ commandId; kind: 'success'\|'error'; text?: string; sourceEventSeq?: SessionSeq }` | `:104-109` |
| `permission/preset` | `{ preset: string }` | `interaction/permission-presets/src/index.ts:53` |
| `sandbox/mode` | `{ mode: 'read-only'\|'workspace-write'\|'danger-full-access'; source?: 'delegation' }` | `sandbox/sandbox-policy/src/session-mode.ts:33-37, 42` |

### 4.5 goal / plan / todo / 状态类事件

| tag | data 字段 | 来源 |
| --- | --- | --- |
| `goal/change` | `{ kind:'goal/change'; version: 1; operation: Exclude<GoalOperation,'clear'>; goal: GoalSnapshot; roundsStarted: number; createdAt; updatedAt }` 或 `{ kind:'goal/change'; version: 1; operation:'clear'; cleared: GoalRef; clearedAt: number }` | `goal/goal/src/domain.ts:24-44, 66` |
| `plan/mode` | `{ active: boolean }` | `plan/plan-mode/src/index.ts:46` |
| `todo/write` | `{ todos: { content: string; status: 'pending'\|'in_progress'\|'completed' }[] }` | `todo/tool-todo/src/types.ts:21-32` |
| `model/selection` | `{ provider: string; model: string; reasoningEffort?: string }` | `api/session-controller/src/types.ts:41, 82-86` |
| `session/title` | `{ title: string; messageSeqs: SessionSeq[]; source: { kind:'fallback' } \| { kind:'provider'; provider: SessionTitleProviderId; model?: { provider; model } } \| { kind:'user' } }` | `session/session-title/src/types.ts:28-48` |
| `agent-preset/selected` | `{ agentPreset: string }` | `preset/agent-presets/src/session.ts:28` |
| `feedback/record` | `{ text: string }` | `feedback/command-feedback/src/index.ts:62` |

`GoalOperation = 'create'|'edit'|'pause'|'resume'|'complete'|'block'|'clear'`（`goal/goal/src/domain.ts:14-21`）。

### 4.6 压缩、重试、hook、工作流类事件

| tag | data 字段 | 来源 |
| --- | --- | --- |
| `compaction/start` | `{ compactionId; sourceCommandId?; turn: number \| null }` | `compaction/compaction/src/types.ts:24` |
| `compaction/summary` | `{ compactionId; sourceCommandId?; summary: ContentBlock[]; shadowedRange; shadowedSeqs; shadowedTokenCount; provider; model; maxTokens?; usage?; rawOutput?; llmStreamCall? }` | `:34-67` |
| `compaction/end` | `{ compactionId; sourceCommandId?; turn; error?: string }` | `:72` |
| `compaction/prune` | `{ shadowedRange: { start; end }; shadowedSeqs; shadowedTokenCount }` | `:82-89` |
| `llm/retry` | `{ retryId; turn; step; provider; mode:'normal'; policyKey; retry; maxRetries; delayMs; failure }` 或 `{ …; mode:'always'; policyKey; retry; delayMs; failure }` | `llm/llm-retry/src/types.ts:16-40` |
| `llm/retry-started` | `{ retryId; turn; step; retry }` | `:43-48` |
| `hook/invoked` | `{ turn; point: string; dialect: 'claude-code'\|'codex'; matcher?: string; handlerId: string }` | `hooks/hook-protocol/src/types.ts:19-25, 48` |
| `hook/result` | `{ turn; point; handlerId; decision: string; exitCode?: number; stderrSummary?: string; durationMs: number }` | `:31-39` |
| `tool-workflow/run-start` | `{ runId: WorkflowRunId; name: string }` | `workflow/tool-workflow/src/types.ts:14-17, 47` |
| `tool-workflow/agent-start` | `{ runId; seq: number; label: string; phase?: string; childId: SessionId }` | `:20-26, 52` |
| `tool-workflow/agent-end` | `{ runId; seq: number; outcome: WorkflowAgentOutcome }` | `:29-33, 57` |
| `tool-workflow/run-end` | `{ runId: WorkflowRunId; stopReason: WorkflowStopReason }` | `:36-39, 62` |

### 4.7 子代理、调度、搜索、遥测类事件

| tag | data 字段 | 来源 |
| --- | --- | --- |
| `subagent/descriptor` | `{ version: number; mode: 'one-shot'\|'continuable'; provider: string; label?: string }`，`mode:'continuable'` 时 `label: string` 必填并追加 `agentProvider?`、`agentModel?`、`agentReasoningEffort?`、`persona?`、`toolFilter?`；当前 `SUBAGENT_DESCRIPTOR_VERSION = 3` | `subagent/subagent/src/descriptor.ts:38, 48-91` |
| `subagent/model-selection-policy` | `{ allowedModels: { provider: string; model: string }[] }` | `subagent/tool-subagent/src/model-selection-state.ts:17-20` |
| `schedule/change` | `{ version:1; operation:'create'; schedule: ScheduleRecord }` \| `{ version:1; operation:'delete'; id }` \| `{ version:1; operation:'dispatch'; id; acceptedAt?: string }`；`ScheduleRecord = { id; kind:'after'; prompt; afterSeconds; scheduledAt } \| { id; kind:'at'; prompt; scheduledAt } \| { id; kind:'every'; prompt; everySeconds; scheduledAt }` | `schedule/schedule/src/types.ts:13-105, 219` |
| `web/deepseek-search-llm-request` | `DeepSeekSearchLlmRequest`（去掉密钥的辅助搜索请求） | `web/web-search-deepseek/src/provider.ts:83` |
| `session/title-llm-request` | `SessionTitleLlmRequestEventData` | `session/session-title-llm/src/index.ts:45` |
| `session-log-deepseek/delivery-accepted` | `{ sessionId: SessionId; throughSeq: SessionSeq }` | `session/session-log-deepseek/src/types.ts:57-62` |
| `team/member` | `{ version: 1; teamId: TeamId; member: TeamMemberSnapshot }` | `experimental/agent-team/src/types.ts:223` |
| `team/task` | `{ version: 1; teamId; task: TeamTaskSnapshot }` | `:225` |
| `team/message/queued` | `{ version: 1; teamId; message: TeamMessageSnapshot }` | `:227` |
| `team/message/delivered` | `{ version: 1; teamId; messageId; targetId: SessionId }` | `:229-234` |

### 4.8 wire 上的历史记录打包（`chunkrow/*`）

会话历史在 wire 与磁盘上都会把连续的同块 delta 打包（至少 3 个成员才打包）成三类行（`core/session/src/chunk-rows.ts:29, 49-70, 100`）：

| 行 type | data |
| --- | --- |
| `text-chunks` | `{ turn; step; index; dt: number[]; texts: string[] }` |
| `reasoning-chunks` | 同 `text-chunks` |
| `tool-call-chunks` | `{ turn; step; index; dt; id: ToolCallId; name?: string; args: string[] }` |

在**浏览器 wire**上不作为 `SessionEvent` 出现，而是包在两条记录壳里（`api/session-controller/src/types.ts:381-423`）：

```ts
SessionEventEntry { type: 'event';  event: SessionWireEvent }
SessionChunkRun   { type: 'chunks'; event: { type: 'chunkrow/text-chunks' | 'chunkrow/reasoning-chunks'
                                           | 'chunkrow/tool-call-chunks'; seq; time; data } }
SessionHistoryRecord = SessionEventEntry | SessionChunkRun
```

来源：`api/session-controller/src/history.ts:366-389`（`chunkEntryFor`）；`client/connection/src/client/fixture.ts:1455-1474`（同构实现）。

`SessionWireEvent`（浏览器侧事件形态，`types.ts:426-434`）：

```ts
{ type: string; seq: number; time: number; data: JsonValue;
  ignorable?: true; sourceEventSeqs?: number[]; surfaceOp?: SessionWireSurfaceOp }
SessionWireSurfaceOp = 'append' | { op: 'replace'; start: number; end: number }
```

`SessionWireHeader`（`types.ts:388-399`）：`{ version; id; createdAt; cwd?; parentSession?; seedLength?; origin?: 'subagent'; delegationDepth?; agentPreset? }`。注意 `seedLength` 是 fork 继承前缀长度（内部 `isSeeded` 字段被剥离，`history.ts:346-356`）。

### 4.9 事件投影（SessionProjectionMap）

Host/客户端还会暴露一组「投影」键值（`session/control` 的 `projections` 与 `projection` 帧），已确认的键：

| key | 值 | 来源 |
| --- | --- | --- |
| `todos` | `TodoItem[] \| null` | `todo/tool-todo/src/types.ts:39-46` |
| `title` | `string \| null`（最近一次 `session/title` 的文本，last-wins） | `session/session-title/src/types.ts:86-93` |
| `plan` | `{ active: boolean; pending: boolean }`（wire 视图） | `plan/plan-mode/src/index.ts:125-163` |
| `agentPreset` | `string \| null` | `preset/agent-presets/src/session.ts:35-44` |
| `sessionListMetadata` | `{ blank: boolean; lastPromptAt: number \| null }` | `api/session-controller/src/types.ts:16-24, 46-51` |
| `imageLimits` | `ImageAttachmentLimits` | `:19, 28` |
| `modelSelection` | `{ lastUsed: ModelSelection \| null; next: ModelSelection \| null }` | `:22-23, 96-102` |
| `subagentModelSelectionPolicy` | `AllowedModelRoute[] \| null` | `subagent/tool-subagent/src/model-selection-state.ts:24-29` |
| `schedule` | `readonly ScheduleRecord[]` | `schedule/schedule/src/types.ts:223-227` |
| `permissions` | `PermissionProjectionState`（Host 侧状态；wire 视图为 `PermissionSelect`） | `interaction/permission-presets/src/index.ts:38-43` |
| `turnBoundary` | `{ openTurnStartSeq; lastStepStartSeq; lastStepBoundary; lastTurn }` | `core/agent/src/types.ts:40-49` |
| `sandboxMode` | 由 sandbox 投影单元折叠 `sandbox/mode` 得到（投影 key 定义处 `key: 'sandboxMode'`） | `sandbox/sandbox-policy/src/index.ts:133`；事件 `src/session-mode.ts:30` |

---

## 5. 会话持久化格式

### 5.1 位置规则

| 层级 | 规则 | 来源 |
| --- | --- | --- |
| 根 | `root` 为必需配置项，Web 组合取 `dshHomePath('sessions')` | `session-persistence-jsonl/src/index.ts:70-78`；`bundle/base/cordis.patch.yml:110-113` |
| `$DSH_HOME` | 显式配置 > `$DSH_HOME` > `~/.dsh`；空白 `$DSH_HOME` 视为未设置 | `util/home-paths/src/index.ts:12-18, 62-88` |
| 项目目录 | `root/<projectKey(cwd)>`；`cwd` 缺失时用 `root/_no-cwd` | `session-persistence-jsonl/src/format.ts:180-212` |
| 会话目录 | `<项目目录>/<encodeSegment(sessionId)>` | `format.ts:214-224` |
| 日志文件 | `<会话目录>/session.jsonl.zstd`（zstd，默认）或 `session.jsonl`（`compression: 'none'`） | `format.ts:37-39, 226-241`；`index.ts:47-48` |

`projectKey`：`/`、`\`、`:` 折叠为单个 `-`，其他非 `[A-Za-z0-9._-]` 及 `~` 转义为 `~XXXX`（大写十六进制、4 位），前缀 `--`、截断到 251 字符、后缀 `--`；空结果回退 `root`（`format.ts:180-200`）。

`encodeSegment`：安全字符 `[A-Za-z0-9._-]` 原样；`.`, `..` 分别转 `~002E`、`~002E~002E`；其余（含 `~`）转 `~XXXX`；空串抛错（`format.ts:154-169`）。

### 5.2 文件结构

一行一个 JSON 记录，UTF-8，末尾换行。**第一行必须是 header**（`format.ts:314-329`）：

```json
{"type":"session","version":0,"id":"<sessionId>","createdAt":1750000000000,
 "cwd":"/abs/project","parentSession":"<parent>","seedLength":12,
 "origin":"subagent","delegationDepth":1,"agentPreset":"cordis"}
```

- 可选字段缺省即**不写**（不写 `null`）（`format.ts:66-89`）。
- `seedLength` 仅在 `isSeeded` 为真时写入（fork 继承前缀长度）。
- 若 header 含已废弃字段 `sandboxMode` 或 `approvalPolicy`，解析抛错（`format.ts:96-99`）。
- header 若带非当前 `version`，先于任何结构校验直接抛 `SessionFormatUnsupportedError`，错误文案区分「需要升级 harness」与「低于支持版本且无升级路径」（`format.ts:305-312`；`session-persistence/src/coordinator.ts:94-96`）。

其后每行是一个事件或一个打包行：

```json
{"type":"turn/start","seq":0,"time":1750000000000,"data":{"turn":1}}
{"type":"text-chunks","seq0":12,"time0":1750000001000,"data":{"turn":1,"step":1,"index":0,"dt":[3,2],"texts":["你","好","！"]}}
```

**磁盘上的行与浏览器 wire 不同**：磁盘用裸 tag（`session`、`text-chunks`、`reasoning-chunks`、`tool-call-chunks`），wire 用 `chunkrow/<kind>` 前缀（`chunk-rows.ts:9-12, 67-73`；`types.ts:406-414`）。

`sourceEventSeqs` 在磁盘上用区间压缩：连续的 3 个及以上 seq 压成 `[start, end]` 对，其他保持原样（`format.ts:259-288`；`core/session/src/seq-ranges.ts`）。

### 5.3 版本常量

```ts
export const SESSION_FORMAT_VERSION = 0
```

- 唯一真源：写 header 与加载检查都读它（`core/session/src/types.ts:87`；`core/session/src/index.ts:102-103, 152, 942`）。
- 语义：单一单调整数，无主次版本拆分；**仅结构变化才升版**（header 形状、事件信封、核心事件语义、surface 机制）。新增普通事件类型**不升版**，由 `ignorable` 标记覆盖词汇增长（`core/session/src/types.ts:64-86`）。
- 未发布期间固定为 `0`，无兼容承诺、无迁移路径（`AGENTS.md`「Pre-release stance」）。

### 5.4 读取/恢复接口（Host 侧）

抽象基类 `SessionPersistence extends Service` 的公开方法（`packages/session/session-persistence/src/index.ts:122-304`）：

| 方法 | 签名 | 行号 |
| --- | --- | --- |
| `locate` | `(meta: SessionHeader) => SessionLocation \| undefined` | `:134` |
| `create` | `(meta: SessionHeader, inheritedEventCount?: SessionLogOffset) => Promise<void>` | `:173` |
| `append` | `(id: SessionId, events: readonly SessionEvent[]) => Promise<void>` | `:195` |
| `prepare` | `(id: SessionId, signal?: AbortSignal) => Promise<SessionPreparation>` | `:207` |
| `load` | `(id: SessionId) => Promise<SessionInspection>` | `:236` |
| `inspect` | `(id: SessionId, signal?: AbortSignal) => Promise<SessionInspection>` | `:253` |
| `borrowSession` | `(id: SessionId, signal?: AbortSignal) => Promise<BorrowedSessionSource>` | `:264` |
| `readFrom` | `(id: SessionId, fromSeq: SessionLogOffset, signal?) => …` | `:284` |
| `list` | `(signal?: AbortSignal) => Promise<SessionHeader[]>` | `:292` |
| `listSnapshots` | `(signal?: AbortSignal) => Promise<SessionPersistenceSnapshot[]>` | `:304` |

返回结构（`session-persistence/src/index.ts:24-78`）：

```ts
SessionPersistenceSnapshot { meta: SessionHeader; inheritedEventCount: SessionLogOffset }
SessionStorageMetadata      { meta: SessionHeader; inheritedEventCount: SessionLogOffset }
SessionInspection           = SessionStorageMetadata & { events: readonly SessionEvent[] }
SessionEventSuffix          = SessionStorageMetadata & { fromSeq: SessionLogOffset; events: readonly SessionEvent[] }
SessionRawArtifact          = SessionStorageMetadata & { filename: string; content: string }
SessionLocation             { kind: string; path: string }
```

**扫描与容错**（`format.ts:337-471`）：

- `SessionLogScanner` 逐块扫描，只保留不完整的末行；`checkpoint()` 返回可安全追加的字节偏移（`:397-407`）。
- `finish()` 把**没有换行的末行**当作撕裂尾部忽略（`:409-421`）。
- 遇到无法解析的已提交事件或 seq 跳号时，只有在后续出现 `turn/end` 才立刻抛错，否则先记 issue 并在 `turn/end` 处抛出（`:424-454`）。
- 扫描始终会解码打包行，与写入时的 `packChunks` 开关无关（`:243-257`）。

### 5.5 resume / 会话激活路径（RPC 视角）

1. 冷读：`session/page` 与 `session/follow` 都走 `SessionQuery.observeSession`，不激活 Agent（`history.ts:192-206`）。
2. 显式激活：`ApiSessionAgentController.resolveAgent(sessionId)` 去重并发恢复，内部走 `ctx.agents.resume({ resumeSessionId })`（`api/session-controller/src/agent.ts:166-217, 398-462`）。
3. `session/follow` 的 snapshot 下发后，若数据源是 `prepared`，后台触发一次 promotion（激活），失败只记录 `api-session/error`（`history.ts:160-168`；`session-controller/src/index.ts:164-175`）。
4. 客户端可见的持久化事实：`session/page` 的 `throughSeq` 必须来自对应 follow 的 `cursor`，否则报 `session/page through seq N is past cursor M`（`history.ts:70-80`）。

### 5.6 附件与图片

- 图片字节不进事件日志：`session/attachment` 用 `{ sessionId, attachmentId }` 读取，返回 base64 `data`（`types.ts:316-326`）。
- 请求体上限默认 300 MiB，其值由默认聚合图片上限 200 MiB 经 base64 膨胀（约 267.7 MiB）加信封余量向上取整得到；桥接层在派发前把整个 body 读入内存，因此该上限同时是单请求常驻内存上界（`http-bridge.ts:8-12, 54-74`）。
- 附件 store 位于 `$DSH_HOME/attachments/v1`（`attachment/attachment-local/src/store.ts:47`）。

---

## 6. 第三方客户端实现要点（基于以上事实）

1. **一元调用**：`POST http://127.0.0.1:3080/api/<ns>/<method>`，`Content-Type: application/json`，body 为 `{type:"client-request",rpcId,method,payload:{args:{…}}}`；必须带 Cookie（`dsh-auth-*`）。先用浏览器/系统能力完成 `GET /?token=…` 的 303 + Set-Cookie 交换。
2. **流式调用**：升级到 `ws://127.0.0.1:3080/api/remote.mux`（同一 Cookie），文本帧 JSON；`open.streamId` 自铸 UUID；用 `cancel` 帧取消；收到 `error` 帧按 `code/message/details` 处理，`end` 帧表示正常收尾。
3. **心跳**：服务端每 `websocketHeartbeatIntervalMs`（默认 `2000` ms，`gateway/src/index.ts:116, 171-174`）发 Ping 控制帧；客户端必须回 Pong，连续漏 2 次（即 ≥2 个周期无响应）被 `terminate()`（`stream-server.ts:22, 75-94`）。
4. **`args` 键必须是参数名**，`signal` 永不出现在 `args` 里。`agent` 类参数在 wire 上是 SessionId 字符串。
5. **不要假设 SSE**：本版本 RPC 与流式全部走 HTTP POST + WebSocket；SSE 仅 `/plugins/events`（客户端插件 HMR），第三方客户端不需要。
6. **错误处理双通道**：HTTP 非 2xx（可能不是 JSON）与信封 `result.ok === false` 都要处理；`handler failure:` 纯文本 500 只可能来自端点抛异常（`rpc-host.ts:242-244`）。
7. **事件读取必须尊重 `ignorable`**：遇到未知 `type` 且无 `ignorable: true` 时不得静默跳过（`core/session/src/types.ts:442-452`）。
8. **持久化兼容以 `SESSION_FORMAT_VERSION` 为准**：读到非当前版本直接拒绝打开（`format.ts:305-312`）。

---

## 附录 A：端到端调用序列示例

以下序列全部由本文档已列出的源码事实拼接而成，不含未验证步骤。

**步骤 1 — token 交换（只做一次，进程生命周期内）**

```http
GET /?token=<dsh web 打印出的 URL 中的 token> HTTP/1.1
Host: 127.0.0.1:3080

=> 303 See Other
   location: /
   set-cookie: dsh-auth-<base64url(sha256("127.0.0.1:3080"))>=v1.<body>.<sig>; Max-Age=2592000; Path=/; Expires=…; HttpOnly; SameSite=Strict
```

依据：`browser-auth.ts:223-266`。

**步骤 2 — 一元调用（列出会话）**

```http
POST /api/session/list HTTP/1.1
Host: 127.0.0.1:3080
Content-Type: application/json
Cookie: dsh-auth-<…>=<…>

{"type":"client-request","rpcId":"1f0c…","method":"session/list","payload":{"args":{"_request":{}}}}
```

```json
{"type":"server-response","rpcId":"1f0c…","result":{"ok":true,
 "value":{"items":[{"sessionId":"abc","updatedAt":1750000000000,"running":false,"blank":false,"cwd":"/work"}]}}}
```

依据：`client/rpc.ts:34-60`（客户端组装）、`rpc-host.ts:203-247`（服务端解析）、`gateway/src/index.ts:443`（`{ args: prepared.args }`）。

**步骤 3 — 打开 WebSocket 并订阅会话事件**

```jsonc
// 客户端 → 服务端（文本帧）
{"type":"open","streamId":"9c2b…","endpoint":"session/follow","payload":{"args":{"request":{"address":{"kind":"session","sessionId":"abc"}}}}}

// 服务端 → 客户端
{"type":"item","streamId":"9c2b…","value":{"type":"snapshot","header":{"version":0,"id":"abc","createdAt":1750000000000,"cwd":"/work"},
  "cursor":41,"records":[…],"hasMore":false,"projections":{"asOfSeq":41,"values":{}}}}
{"type":"item","streamId":"9c2b…","value":{"type":"event","event":{"type":"assistant/chunk","seq":42,"time":1750000001000,"data":{…}}}}
```

**步骤 4 — 取消该流**

```json
{"type":"cancel","streamId":"9c2b…"}
```

依据：`stream-protocol.ts:242-284`、`stream-server.ts:134-153`、`api/session-controller/src/history.ts:143-190`。

**步骤 5 — 重连语义**

物理 WebSocket 断开后，客户端应保留逻辑流意图并按 Connection 的代信号重开：新代建立后重新发 `open`（同一 endpoint），并把新收到的 `session/follow` snapshot 作为新基线替换本地状态。依据：`gateway/src/client/remote-stream.ts:95-157`、`client/connection/src/client/index.ts:265-288`。

---

## 附录 B：本文件引用的关键文件索引

| 文件 | 承载内容 |
| --- | --- |
| `packages/client/connection/src/api-path.ts` | `/api` 前缀常量 |
| `packages/client/connection/src/rpc.ts` | 信封、失败、通道/流接口类型 |
| `packages/client/connection/src/rpc-schema.ts` | 信封运行时校验（zod） |
| `packages/client/connection/src/rpc-host.ts` | Host 侧 HTTP RPC 实现与状态码 |
| `packages/client/connection/src/http-bridge.ts` | node:http ↔ fetch 桥、体积上限 |
| `packages/client/connection/src/api-request-trust.ts` | Host/Origin/Sec-Fetch-Site 信任栅栏 |
| `packages/client/connection/src/browser-auth.ts` | token 交换与签名 Cookie |
| `packages/client/connection/src/loopback-hostname.ts` | loopback 判定 |
| `packages/client/connection/src/client/rpc.ts` | 浏览器一元调用实现 |
| `packages/client/connection/src/client/connection.ts` | 代/退避/重连控制器 |
| `packages/client/connection/src/client/fixture.ts` | 开发用内存夹具（含全套 endpoint 分派） |
| `packages/api/gateway/src/stream-protocol.ts` | WebSocket 路径与全部帧结构、`$events*` |
| `packages/api/gateway/src/stream-server.ts` | 多路复用服务端、心跳、取消 |
| `packages/api/gateway/src/client/stream-client.ts` | 多路复用客户端 |
| `packages/api/gateway/src/client/remote-stream.ts` | 逻辑流重连与 accept 语义 |
| `packages/api/gateway/src/index.ts` | 端点解析、参数装配、错误折叠 |
| `packages/api/remotes/src/client/index.ts` | 客户端挂载清单（12 个贡献） |
| `packages/api/remotes/src/remote-events.ts` | 转发 Host 事件白名单与模式 |
| `packages/api/session-controller/src/types.ts` | session 端点全部 wire 类型 |
| `packages/core/session/src/types.ts` | `SessionEventMap` 基础与 `SESSION_FORMAT_VERSION` |
| `packages/core/session/src/chunk-rows.ts` | 打包行格式 |
| `packages/session/session-persistence-jsonl/src/format.ts` | 磁盘布局与扫描器 |
| `packages/session/session-persistence/src/index.ts` | 持久化抽象接口 |
| `packages/core/session/src/known-event-types.ts` | 本仓库事件词汇白名单（生成物） |
