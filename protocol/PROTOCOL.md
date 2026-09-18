# DSH Relay 协议规范 v1

> 三端（发送端 / 服务端 / Wear 客户端）之间的线缆契约。任何一端都必须严格按本文实现，改动需要同时更新三端。

## 1. 角色与拓扑

```
┌─────────────────────────────┐
│  运行 dsh 的机器             │
│  ┌───────────────────────┐  │
│  │ dsh web (127.0.0.1)   │  │
│  │  /api/<ns>/<method>   │  │  HTTP RPC
│  │  /api/remote.mux      │  │  WebSocket
│  └──────────┬────────────┘  │
│             │ 本机回环        │
│  ┌──────────┴────────────┐  │
│  │ 发送端 agent.exe (C)   │  │  只出站，不监听端口
│  └──────────┬────────────┘  │
└─────────────┼───────────────┘
              │  AES-256-CBC + HMAC-SHA256
      ┌───────┴────────┐
      │ 服务端 server.exe (C) │  监听 :7777（发送端）/ :7778（客户端）
      └───────┬────────┘
              │  同一套加密
      ┌───────┴────────┐
      │ Wear 客户端 (Flutter) │
      └────────────────┘
```

三个不变量：

1. **服务端不解析业务载荷**。它只读路由字段，其余字节原样转发，因此 dsh 的字段格式变化不会波及服务端。
2. **发送端是唯一理解 dsh 参数形状的组件**。客户端只说 relay 的方法名。
3. **握手之后不存在明文**。任何一端收到 `flags.bit0 = 1` 的帧都视为攻击。
4. **端口决定角色**。服务端在两个端口上监听：发送端连 `port`（默认 7777），客户端连 `client_port`（默认 7778）。`HELLO` 中的 `role` 必须与连接到达的端口一致，否则服务端在派生密钥之前关闭连接。角色因此不是对端自称的属性，而是连接本身的属性。

## 2. 层 1：加密隧道

### 2.1 帧格式

| 偏移 | 长度 | 字段 |
| --- | --- | --- |
| 0 | 4 | magic `DSHX` (ASCII) |
| 4 | 1 | version = 1 |
| 5 | 1 | type：1=HELLO，2=HELLO_ACK，3=DATA，4=BYE |
| 6 | 1 | flags：bit0=1 表示明文握手帧 |
| 7 | 1 | reserved = 0 |
| 8 | 4 | sequence，大端 uint32，**从 1 开始**，每帧 +1 |
| 12 | 4 | ciphertext length，大端 uint32，16 的正整数倍 |
| 16 | 16 | IV，每帧随机 |
| 32 | N | AES-256-CBC 密文（PKCS#7） |
| 32+N | 32 | HMAC-SHA256，覆盖字节 `[0, 32+N)` |

明文握手帧（HELLO / HELLO_ACK）：`flags.bit0 = 1`，IV 全 0，偏移 12 处是**明文长度**（不填充、不加密），**没有**末尾 32 字节 MAC。总长 = 32 + 明文长度。

### 2.2 接收校验顺序（不可交换）

1. 帧长、magic、version 校验。
2. **先验 HMAC**，失败即丢弃。此时头部尚未被信任。
3. 校验 `sequence > 已收到的最大 sequence`，否则判为重放。
4. 解密并去除 PKCS#7 填充。

> 第 2 步必须早于第 3 步：序列号位于被 MAC 覆盖的头部内，未经认证的头部不得影响任何状态或暴露重放窗口。

### 2.3 握手

客户端 → 服务端，HELLO（明文，UTF-8 JSON）：

```json
{ "role": 1, "name": "DESKTOP-PC", "nonce": "<32位hex>", "proof": "<64位hex>" }
```

`role`：1 = 发送端，2 = Wear 客户端。
`nonce`：16 字节随机数。
`proof = HMAC-SHA256(key = UTF8(passphrase), data = "dsh-relay/v1" || nonce_bytes)`。

服务端 → 客户端，HELLO_ACK（明文）：

```json
{ "ok": true, "server": "dsh-relay", "version": "1.0.0",
  "salt": "<32位hex>", "nonce": "<32位hex>" }
```

服务端**先验证 proof**再继续，随后校验 `role` 是否与连接到达的端口一致。口令本身从不上线；持有错误口令的对端会在握手阶段被拒绝，而不是在数据阶段。角色不符的对端同样在这一步被关闭，此时尚未派生任何密钥。

### 2.4 会话密钥派生

```
mixed  = server_salt(16) || client_nonce(16) || server_nonce(16)     // 48 字节
master = PBKDF2-HMAC-SHA256(pass = UTF8(passphrase), salt = mixed,
                            iterations = 50000, dkLen = 64)

key_c2s = HMAC-SHA256(key = master, data = "c2s\0")   // 4 字节，末位 0x00
key_s2c = HMAC-SHA256(key = master, data = "s2c\0")
mac_c2s = HMAC-SHA256(key = master, data = "mc2s")    // 4 字节，无 NUL
mac_s2c = HMAC-SHA256(key = master, data = "ms2c")
```

| 角色 | 加密用 | 解密用 | 发送 MAC | 接收 MAC |
| --- | --- | --- | --- | --- |
| 发送端 / Wear 客户端 | `key_c2s` | `key_s2c` | `mac_c2s` | `mac_s2c` |
| 服务端 | `key_s2c` | `key_c2s` | `mac_s2c` | `mac_c2s` |

每次连接的 salt 与 nonce 都重新生成，因此同一口令不会产生重复的会话密钥。

一致性基准见 `tests/vectors.json`（由 Node 的 crypto 生成），C 端测试 `tests/test_crypto.c` 与 Dart 端测试都对它断言。

## 3. 层 2：应用消息

加密 DATA 帧内是 UTF-8 JSON：

```json
{ "t": "<kind>", "id": "<可选关联 id>", "p": { } }
```

| kind | 方向 | 含义 |
| --- | --- | --- |
| `hello` | 发送端 → 服务端 | 设备自述（device / host / dshVersion / dshHome / capabilities） |
| `hello` | 客户端 → 服务端 | 客户端显示名 |
| `devices` | 服务端 → 客户端 | 在线发送端名册 |
| `sessions` | 发送端 → 客户端 | 会话列表快照 |
| `snapshot` | 发送端 → 客户端 | 某会话的打开窗口（含 cursor 与 projections） |
| `events` | 发送端 → 客户端 | 增量会话事件 |
| `state` | 发送端 → 客户端 | 会话控制基线 / 队列 / 后台任务 / 投影增量 |
| `request` | 客户端 → 发送端 | 调用一个 relay 方法 |
| `result` | 发送端 → 客户端 | `{ok:true, value}` |
| `error` | 发送端 → 客户端 | `{code, message, details}` |
| `ack` | 发送端 → 客户端 | 已接受但无返回值的确认 |
| `ping` / `pong` | 双向 | 保活 |

服务端在 `result` / `error` / `ack` 上按 `id` 把应答送回发起请求的那个客户端。`id` 由客户端生成并在全程回显。

## 4. 层 3：relay 方法（client → 发送端 → dsh）

客户端把方法名放进 `request.p.method`，发送端映射到 dsh 的真实 RPC 端点。**客户端不需要知道 dsh 的内部参数名**。

### 4.1 映射表

| relay 方法 | dsh 端点 | 参数键 | 说明 |
| --- | --- | --- | --- |
| `sessions/list` | `session/list` | `_request` | 会话列表 |
| `session/create` | `session/create` | `request` | 新建会话 |
| `session/page` | `session/page` | `request` | 历史翻页（见 4.3） |
| `session/prompt` | `session/prompt` | `request` | 发送用户输入 |
| `session/cancel` | `session/cancel` | `request` | 中断当前回合 |
| `session/rename` | `session/rename` | `request` | 重命名 |
| `session/fork` | `session/fork` | `request` | 分叉 |
| `session/selectModel` | `session/selectModel` | `request` | 切换模型 |
| `session/attachment` | `session/attachment` | `request` | 取附件 |
| `session/modelCatalog` | `session/modelCatalog` | 无 | 可用模型 |
| `commands/list` | `commands/list` | `request` | 斜杠命令目录 |
| `commands/execute` | `commands/execute` | `request` | 执行斜杠命令 |
| `agentPresets/list` | `agentPresets/list` | 无 | 智能体预设 |
| `settings/describe` | `settings/describe` | 无 | 设置描述 |
| `skills/list` | `skills/list` | `request` | 技能目录 |
| `pluginInventory/list` | `pluginInventory/list` | 无 | 插件清单 |

**未列出的方法按逃生舱处理**：客户端可以传任意方法名，发送端把 `payload` 原样当作 dsh 端点的 `args` 对象直通。这样 dsh 新增端点无需改发送端。

### 4.2 本地方法（发送端自己处理，不经过 dsh）

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `relay/status` | 无 | `{device, agentVersion, dshReachable, eventMux, followedSessions}` |
| `session/subscribe` | `{sessionId}` | `{subscribed:true}`，随后推送 `snapshot` 与 `events` |
| `session/unsubscribe` | `{sessionId}` | `{subscribed:false}` |

### 4.3 `session/page` 的 cursor 约束

dsh 要求 `throughSeq` 必须来自对应 `session/follow` 首帧的 `cursor`，否则报 `session/page through seq N is past cursor M`。

因此顺序**必须**是：

1. `session/subscribe` → 收到该会话的 `snapshot`，其中 `cursor` 即基线序号。
2. 之后才可以用该 `cursor` 调 `session/page` 向前翻历史。

发送端记录每个被订阅会话的 cursor，客户端不必自己传递。

### 4.4 `session/prompt` 的载荷

客户端发送：

```json
{ "sessionId": "session-…", "text": "用户输入", "mode": "queue" }
```

`mode` 取 `queue`（排队）或 `steer`（插入当前回合）。发送端补齐 dsh 需要的 `requestId` 与 `content: [{type:"text", text}]`。

## 5. 数据流

### 5.1 会话列表

发送端每 `poll_ms`（默认 3000ms）调一次 `session/list`，**仅在内容变化时**推送：

```json
{ "t": "sessions", "p": { "device": "desktop", "sessions": [ SessionSummary, … ] } }
```

`SessionSummary` 字段：`sessionId`、`updatedAt`、`running`、`blank`、`cwd`、`parentSessionId?`、`origin?`、`projections.values`（标题、token 用量、上下文压力、回合大纲、权限、模型选择等）。

### 5.2 会话订阅

`session/subscribe` 之后：

```json
{ "t":"snapshot", "p": { "device":…, "session":…, "cursor":N,
                         "header": {…}, "records": [ … ], "projections": {…} } }
{ "t":"events",   "p": { "device":…, "session":…, "events": [ SessionWireEvent ] } }
```

事件信封：`{type, seq, time, data, ignorable?, sourceEventSeqs?, surfaceOp?}`。
`seq` 在会话内单调递增；接收方应丢弃 `seq <= 已处理的最大 seq` 的重复事件。

### 5.3 会话控制

发送端在事件多路复用器上常驻订阅 `session/control`（无参数），把 `baseline` 与后续 `queue` / `jobs` / `projection` 帧包成：

```json
{ "t":"state", "p": { "device":…, "control": <原帧 value> } }
```

## 6. 错误

`error` 消息：`{ "code": …, "message": …, "details": {} }`。

| code | 来源 | 含义 |
| --- | --- | --- |
| `relay/no-sender` | 服务端 | 没有匹配的发送端在线 |
| `relay/bad-request` | 发送端 | 方法名过长或缺必需参数 |
| `relay/mux-unavailable` | 发送端 | dsh 事件多路复用器未连接 |
| `relay/dsh-unavailable` | 发送端 | 发送端没有已认证的 dsh 连接 |
| `dsh/call-failed` | 发送端 | dsh 返回 `ok:false` 或 HTTP 非 200，`message` 内含 dsh 原始错误 |

**注意**：dsh 在非 200 时返回的是纯文本 body（例如 `body is not JSON`、`handler failure: …`），不是 JSON 信封。发送端已把它折进 `dsh/call-failed` 的 `message`。

## 7. 上限与保活

| 项 | 值 |
| --- | --- |
| 单帧最大载荷 | 8 MiB |
| 发送端心跳 | 25s |
| 服务端发送超时 | 5s |
| 事件重放缓冲 | 每发送端 256 帧（新客户端接入时补发） |
| 请求挂起超时 | 120s |
| dsh 请求体上限 | 32 MiB |

## 8. 安全边界

- 加密：AES-256-CBC，每帧随机 IV，encrypt-then-MAC（HMAC-SHA256），先验证后解密。
- 重放：严格递增序列号，连接内有效。
- 认证：握手 proof，口令永不上线；常量时间比较。
- 口令要求：至少 8 字符，配置缺失时**拒绝启动**（不做默认口令）。
- 发送端不监听任何端口，只主动出站。
- 服务端不信任任何客户端指定的 `device`：只在其已连接的发送端集合中查找。

## 9. 参考实现与验证

| 组件 | 文件 |
| --- | --- |
| 加密内核（C） | `common/crypto/dsh_aes.c`、`dsh_sha256.c`、`dsh_sha1.c` |
| 帧与握手（C） | `common/wire/dsh_wire.c` |
| 消息与套接字（C） | `common/net/dsh_net.c` |
| dsh HTTP RPC 客户端 | `common/net/dsh_http.c` |
| dsh WebSocket 多路复用 | `common/net/dsh_ws.c` |
| 服务端 | `server/main.c` |
| 发送端 | `agent/main.c` |
| 跨语言向量 | `tests/vectors.json` |
| C 一致性测试 | `tests/test_crypto.c`（105 项断言） |
| 独立实现端到端测试 | `tests/relay_client.mjs` |
