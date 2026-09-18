# D1 — Session 事件词汇表（SessionEventMap 全表）

- 源码根：`third_party/deepseek-harness`
- tag：`dsh-v0.1.2-rc.1`，commit `a66e4702047846cdaa10c66c9d3df3951f5ea70d`
- 分析方式：只读。全仓 `packages/**` grep 声明点（排除 `tests/`），逐包读取 payload 声明，并用源码生成的权威清单交叉验证。
- 本文所有路径相对源码根；行号为声明所在行。

## 0. 权威数据源与校验结论

本表的完整性有**两个独立来源互相校验**，结论一致：51 项事件，无缺无多。

| 来源 | 位置 | 性质 |
|---|---|---|
| `SessionEventMap` 基础成员 | `packages/core/session/src/types.ts:259` | 人工维护，12 项 |
| declaration merging 扩展点 | 全仓 24 处（见 §1） | 人工维护，39 项 |
| `KNOWN_SESSION_EVENT_TYPES` | `packages/core/session/src/known-event-types.ts:22` | **生成物**，由 `scripts/gen-persistence-catalog.ts` 产出，51 项 |
| Session Persistence Event Catalog | `docs/persistence-catalog.md` | 生成物，逐事件给出 payload / surface 徽章 / 声明点，51 项 |

生成物 `KNOWN_SESSION_EVENT_TYPES` 是持久化读路径实际使用的「本构建认识的事件集合」（`packages/core/session/src/known-event-types.ts:8`），因此它就是权威全表。

### 0.1 关键统计

| 指标 | 值 | 来源 |
|---|---|---|
| 事件总数 | 51 | `packages/core/session/src/known-event-types.ts:22` |
| surface 事件（产生 LLM 消息、携带 `surfaceOp`） | 3 | `packages/core/session/src/types.ts:373` |
| log-only 事件 | 48 | `docs/persistence-catalog.md`（逐事件徽章） |
| `ignorable: true` 的生产写入点 | **0** | 全仓 grep 结果仅出现在 `tests/` 与 `*.spec.ts` |
| `SESSION_FORMAT_VERSION` | `0` | `packages/core/session/src/types.ts:87` |
| 声明点总数（含基础） | 25 | 见 §1 |

## 1. 声明点清单（25 处）

`packages/**` 下 `interface SessionEventMap` / `declare module '@deepseek-ai/dsh-session/types'` 的**非测试**声明点。

| # | 相对路径:行号 | 贡献事件数 | 事件 |
|---|---|---|---|
| 1 | `packages/core/session/src/types.ts:259` | 12 | `turn/start` `turn/end` `step/start` `step/end` `user/message` `assistant/chunk` `assistant/message` `tool/call` `tool/result` `request/header` `request/context` `session/end-seed` |
| 2 | `packages/core/agent/src/types.ts:52` | 1 | `agent/inbox/spliced` |
| 3 | `packages/core/tools/src/types.ts:26` | 2 | `tool/code-dispatch-start` `tool/code-dispatch` |
| 4 | `packages/api/session-controller/src/types.ts:36` | 1 | `model/selection` |
| 5 | `packages/goal/goal/src/domain.ts:62` | 1 | `goal/change` |
| 6 | `packages/plan/plan-mode/src/index.ts:40` | 1 | `plan/mode` |
| 7 | `packages/todo/tool-todo/src/types.ts:29` | 1 | `todo/write` |
| 8 | `packages/interaction/commands/src/types.ts:86` | 2 | `command/run` `command/done` |
| 9 | `packages/interaction/user-approval/src/types.ts:35` | 2 | `approval/asked` `approval/decided` |
| 10 | `packages/interaction/user-approval/src/index.ts:24` | 1 | `approval/policy` |
| 11 | `packages/interaction/permission-presets/src/index.ts:46` | 1 | `permission/preset` |
| 12 | `packages/feedback/command-feedback/src/index.ts:57` | 1 | `feedback/record` |
| 13 | `packages/session/session-title/src/index.ts:72` | 1 | `session/title` |
| 14 | `packages/session/session-title-llm/src/index.ts:43` | 1 | `session/title-llm-request` |
| 15 | `packages/session/session-log-deepseek/src/types.ts:55` | 1 | `session-log-deepseek/delivery-accepted` |
| 16 | `packages/subagent/subagent/src/descriptor.ts:30` | 1 | `subagent/descriptor` |
| 17 | `packages/subagent/tool-subagent/src/model-selection-state.ts:10` | 1 | `subagent/model-selection-policy` |
| 18 | `packages/workflow/tool-workflow/src/types.ts:42` | 4 | `tool-workflow/run-start` `tool-workflow/agent-start` `tool-workflow/agent-end` `tool-workflow/run-end` |
| 19 | `packages/compaction/compaction/src/types.ts:18` | 4 | `compaction/start` `compaction/summary` `compaction/prune` `compaction/end` |
| 20 | `packages/schedule/schedule/src/types.ts:214` | 1 | `schedule/change` |
| 21 | `packages/hooks/hook-protocol/src/types.ts:9` | 2 | `hook/invoked` `hook/result` |
| 22 | `packages/sandbox/sandbox-policy/src/session-mode.ts:25` | 1 | `sandbox/mode` |
| 23 | `packages/llm/llm-retry/src/types.ts:7` | 2 | `llm/retry` `llm/retry-started` |
| 24 | `packages/web/web-search-deepseek/src/provider.ts:81` | 1 | `web/deepseek-search-llm-request` |
| 25 | `packages/preset/agent-presets/src/session.ts:21` | 1 | `agent-preset/selected` |

**与任务书给出的清单差异**：任务书列出的 21 个位置全部核实存在；额外发现 1 处未列出的声明点——`packages/experimental/agent-team/src/types.ts:220`（贡献 `team/member` `team/task` `team/message/queued` `team/message/delivered`）。

排除的测试声明点（不计入）：`packages/core/session/tests/fork.spec.ts:7`、`packages/core/session/tests/gen-persistence-catalog.spec.ts`（该文件本身是生成器的测试，含内联 `SessionEventMap` 字符串）、`packages/session/session-telemetry/tests/telemetry.spec.ts:20`、`packages/session/session-projection/tests/registry.spec.ts:37`、`packages/session/session-projection-cache/tests/{fixtures,cache}.spec.ts`。

## 2. 完整事件表

「载荷要点」取声明原文的关键字段；「客户端消费」标注 `packages/client/**/src/` 下**非测试**的实际读取点，未找到即写「无」。

### 2.1 `turn/*` 与 `step/*`（循环边界）

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `turn/start` | `packages/core/session/src/types.ts:266` | `{ turn: number }` | 循环在认领排队输入或执行 pre-step **之前**打开该 turn（`packages/core/session/src/types.ts:260`） | `packages/client/ui-chat/src/client/conversation-nodes/turn-tail.ts:115`；`packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts:409` |
| `turn/end` | `packages/core/session/src/types.ts:275` | `{ turn: number; reason: TurnEndReason }` | 关闭该 turn，`reason` 说明终止原因（`packages/core/session/src/types.ts:267`） | `packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts:508` |
| `step/start` | `packages/core/session/src/types.ts:277` | `{ turn: number; step: number }` | 打开 turn 内的一步：一次模型调用 + 它请求的工具执行（`packages/core/session/src/types.ts:276`） | `packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts:409` |
| `step/end` | `packages/core/session/src/types.ts:279` | `{ turn: number; step: number }` | 关闭该步（`packages/core/session/src/types.ts:278`） | `packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts:318` |

`TurnEndReason` 是 merge-extensible 联合，`TurnEndReasonMap` 定义 6 个已注册变体：`completed` / `aborted`（含 `TurnEndCancelCause`，若 `legacy` 则来自粗粒度取消记录的导入）/ `blocked` / `error`（携带 `LlmFailure`，始终为结构化失败）/ `max-tokens` / `interrupted`（持久化后端在重载时关闭崩溃遗留 turn 时写入，循环本身从不发出）（`packages/core/session/src/types.ts:193`、`:204`、`:211`、`:188`）。

### 2.2 `user/*`、`assistant/*` 与 `agent/*`

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `user/message` | `packages/core/session/src/types.ts:287` | `UserMessage`（**surface**） | 模型可见面的一条 user-role 消息，三种来源：本 turn 认领的直接人类提示、`agent.inject()` 合成上下文（文件变更通知、子目录 AGENTS.md、skill 内容、cron 通知等）、已进入的 goal 续跑轮次；三者逐字投影 `content`，由 `source` 区分（`packages/core/session/src/types.ts:280`） | `packages/client/ui-trajectory/src/client/trajectory-message-definitions.ts:139` |
| `assistant/chunk` | `packages/core/session/src/types.ts:289` | `{ turn; step; chunk: StreamChunk }` | 原始流式 chunk，用于 token 级重放保真（`packages/core/session/src/types.ts:288`） | `packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts:122` |
| `assistant/message` | `packages/core/session/src/types.ts:300` | `{ turn; step; message: AssistantMessage; usage?: TokenUsage; interrupted?: true }`（**surface**） | 一步的组装后 assistant 消息（派生历史用它）。适配器报告了 token 计量时 `usage` 同行携带（不存在单独的 usage 记录）。流中途被取消的 turn 以 `interrupted: true` 落定已交付文本/推理前缀，未派发的工具调用不出现（`packages/core/session/src/types.ts:290`） | `packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts:308` |
| `agent/inbox/spliced` | `packages/core/agent/src/types.ts:58` | `{ target: InboxTarget; start: number; removedCount?: number; inserted: UserMessage[]; outcome?: 'canceled' }` | agent 的两条有序待发消息列表（`next-turn` / `next-step`）之一发生一次归一化变更。实时派发先于投影变更，因此同步观察者可读到拼接前的 inbox（`packages/core/agent/src/types.ts:53`） | `packages/client/ui-chat/src/client/model/steering-history.ts:23`；`packages/client/ui-trajectory/src/client/trajectory-message-definitions.ts:118` |

### 2.3 `tool/*` 与 workflow

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `tool/call` | `packages/core/session/src/types.ts:306` | `{ turn; step; callId: ToolCallId; name: string; arguments: string }` | 模型请求一次工具调用；`arguments` 是模型产出的**原始未解析** JSON 字符串，`callId` 与其 `tool/result` 配对（`packages/core/session/src/types.ts:301`） | `packages/client/ui-trajectory/src/client/trajectory-tool-definition.ts:31` |
| `tool/result` | `packages/core/session/src/types.ts:318` | `{ turn; step; message: ToolResultMessage; error?: { name; code }; meta?: JsonValue }`（**surface**） | 已完成的工具调用的模型可见结果、可选内部失败身份、可选工具私有 `meta` 展示载荷。`meta` 对核心不透明，但必须可 JSON 序列化——`Session.append` 用 `isJsonValue` 运行时校验全部事件数据（`packages/core/session/src/types.ts:307`） | `packages/client/ui-trajectory/src/client/trajectory-tool-definition.ts:49` |
| `tool/code-dispatch-start` | `packages/core/tools/src/types.ts:40` | `{ rootCallId; parentCallId; subCallId; name; arguments }` | `run_code` 程序内部一次子派发**开始**：调度器实际启动该调用时追加（非提交时），因此「有 start」等价于已进入工具体流水线（`packages/core/tools/src/types.ts:28`） | `packages/client/ui-chat/src/client/model/tool-call-tree.ts:58` |
| `tool/code-dispatch` | `packages/core/tools/src/types.ts:56` | 同上 + `{ isError: boolean; content: ContentBlock[] }` | 一次桥接子派发**落定**，用 `tool/result` 自身的词汇（`content` + `isError`）给出完整模型可见结果；每个已 start 的子调用恰好落定一次（含中止）。log-only：`deriveMessages()` 忽略它（`packages/core/tools/src/types.ts:41`） | `packages/client/ui-chat/src/client/conversation-nodes/tool.ts:142` |
| `tool-workflow/run-start` | `packages/workflow/tool-workflow/src/types.ts:47` | `ToolWorkflowRunStartData`：`{ runId; name }` | 打开一条顶层 workflow 记录 | `packages/client/ui-workflow-run/src/client/workflow-definition.ts:153` |
| `tool-workflow/agent-start` | `packages/workflow/tool-workflow/src/types.ts:52` | `{ runId; seq; label; phase?; childId }` | 某个 workflow 成员的子 Session 发布后记录该成员 | `packages/client/ui-workflow-run/src/client/workflow-definition.ts:154` |
| `tool-workflow/agent-end` | `packages/workflow/tool-workflow/src/types.ts:57` | `{ runId; seq; outcome: WorkflowAgentOutcome }` | 落定一个先前的 workflow 成员 | `packages/client/ui-workflow-run/src/client/workflow-definition.ts:155` |
| `tool-workflow/run-end` | `packages/workflow/tool-workflow/src/types.ts:62` | `{ runId; stopReason: WorkflowStopReason }` | 存活资源静默后落定整条 workflow 记录 | `packages/client/ui-workflow-run/src/client/workflow-definition.ts:156` |

### 2.4 `request/*`

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `request/header` | `packages/core/session/src/types.ts:329` | `{ header: EpochHeader; reason: RequestHeaderReason; startsSeries?: true }` | 下一次请求的完整 header，在派发前于其 step 内追加。它只进日志；最新快照重建请求 header（`packages/core/session/src/types.ts:325`） | `packages/client/ui-trajectory/src/client/trajectory-request-header-definition.ts:18` |
| `request/context` | `packages/core/session/src/types.ts:339` | `RequestContext`：`{ provider; model; contextWindow? }` | 下一次请求的路由元数据，仅在路由或容量变化时记录；不参与请求重建，也不参与 header 相等判断（`packages/core/session/src/types.ts:335`） | 无 |

`EpochHeader` 字段：`config: LlmCallConfig`（provider、model、reasoning effort、采样标量）、`adapterDefaults?: LlmCallConfigAdapterDefaults`（由确切适配器物化而非调用方提议）、`system?: string`、`tools?: ToolSchema[]`；规范空的可选字段不存在（`packages/core/session/src/types.ts:222`）。

`RequestHeaderReason` 是 4 值闭集，语义有精确区分：`'initial'` 全日志首个 header（新对话）；`'resume'` 一个 loop 实例在**已有 header 的日志**上的首次请求（进程重启、fork seed）；`'change'` 后续请求用了不同 header，此时 `startsSeries` 保留重合的序列边界；`'series'` 未变化的 header 开始了一条显式不同的消息序列，或跟随一次 surface 替换（`packages/core/session/src/types.ts:243`、`:251`）。

### 2.5 `session/*` 与 `session-log-deepseek/*`

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `session/end-seed` | `packages/core/session/src/types.ts:362` | `Record<string, never>`（空载荷） | 标记构造器 seed 的结束。此前序号的更小事件来自 seed（resume、fork 或 replay），本生命周期没有产生其中任何一个。读法：取**存储历史中最后一个**；已在 seed 末尾的一个不会被重新标记，因此重新打开未改动会话不会让日志随每次拾取而增长。`Session` 的构造器是唯一合法写入者（`packages/core/session/src/types.ts:340`） | `packages/client/ui-trajectory/src/client/trajectory-compaction-definition.ts:121` |
| `session/title` | `packages/session/session-title/src/index.ts:77` | `SessionTitleEventData` | 最新值胜出的会话标题快照；只进日志，绝不进入模型面或派生历史（`packages/session/session-title/src/index.ts:73`） | 经 `title` 投影消费（`packages/client/ui-layout/src/client/DocumentTitle.tsx:12`） |
| `session/title-llm-request` | `packages/session/session-title-llm/src/index.ts:45` | `SessionTitleLlmRequestEventData`：`{ titleProvider; messageSeqs; route; system; messages; maxTokens }` | 一次会话标题模型请求的派发前只读记录 | 无 |
| `session-log-deepseek/delivery-accepted` | `packages/session/session-log-deepseek/src/types.ts:57` | `{ sessionId: SessionId; throughSeq: SessionSeq }` | 记录已配置端点接受了一次截至 `throughSeq` 的投递；继承的 fork 标记保留父 id（`packages/session/session-log-deepseek/src/types.ts:56`） | 无 |

### 2.6 交互与审批

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `approval/asked` | `packages/interaction/user-approval/src/types.ts:44` | `{ id: ApprovalRequestId; toolName: string; callId?: ToolCallId; reason?: string }` | 一个审批问题被提交给应答链——只读审计。`id` 与总会紧随的 `approval/decided` 配对（`packages/interaction/user-approval/src/types.ts:36`） | 无 |
| `approval/decided` | `packages/interaction/user-approval/src/types.ts:55` | `{ id: ApprovalRequestId; outcome: ApprovalOutcome }` | 先前一次 ask 的结果（同一 `id`）——只读审计。每次 ask 恰好一条，在结果已知时追加：一个决定、一次取消，或失败关闭的 `'unavailable'`（`packages/interaction/user-approval/src/types.ts:50`） | 无 |
| `approval/policy` | `packages/interaction/user-approval/src/index.ts:33` | `{ policy: ApprovalPolicy; source?: 'delegation' }` | 会话审批策略被切换。**最后一个**此类事件即会话的覆盖值（`packages/interaction/user-approval/src/index.ts:25`） | 经 `permissions` 投影消费（`packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:109`） |
| `command/run` | `packages/interaction/commands/src/types.ts:97` | `{ commandId: CommandId; name: string; args?: string; source: CommandSource }` | 一条已解析的斜杠命令进入其处理器。与 `command/done` 按 `commandId` 配对，镜像 `tool/call`↔`tool/result`。`args` 是 `parseCommand` 自己的切分（名称与逐字 rawInput，含分隔空白）；当定义设 `recordInput: false` 时 `args` 缺席（`packages/interaction/commands/src/types.ts:87`） | `packages/client/ui-chat/src/client/conversation-nodes/command.ts:38` |
| `command/done` | `packages/interaction/commands/src/types.ts:104` | `{ commandId; kind: 'success' \| 'error'; text?: string; sourceEventSeq?: SessionSeq }` | 配对命令落定。`kind`/`text` 携带处理器的逐字结果（抛出/中止的处理器以 `kind: 'error'` 落定）。成功的命令可指出更早的权威域事件以支持更丰富的客户端计算展示（`packages/interaction/commands/src/types.ts:98`） | `packages/client/ui-chat/src/client/conversation-nodes/command.ts:52` |
| `permission/preset` | `packages/interaction/permission-presets/src/index.ts:53` | `{ preset: string }` | 把选中的预设记录为持久、只进日志的用户意图。knob 事件在同一 turn 内跟随并控制执行；本事件留在模型 transcript 之外，让权限投影单元在 bundle 匹配时保留选择（`packages/interaction/permission-presets/src/index.ts:47`） | 经 `permissions` 投影消费 |
| `sandbox/mode` | `packages/sandbox/sandbox-policy/src/session-mode.ts:33` | `{ mode: SandboxMode; source?: 'delegation' }` | 会话沙箱模式被切换。**最后一个**此类事件即会话的覆盖值（由 `sandboxMode` 投影单元折叠）；`source: 'delegation'` 标记注入到子会话的覆盖（`packages/sandbox/sandbox-policy/src/session-mode.ts:26`） | 经 `permissions` 投影消费 |

### 2.7 Agent 预设、goal、plan、todo、schedule、feedback

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `agent-preset/selected` | `packages/preset/agent-presets/src/session.ts:28` | `{ agentPreset: string }` | 会话在创建后被选中 agent 预设（此时会话仍为 blank）。只进日志：它记录后续 turn 实际运行的组合，使 resume 或 fork 的会话重建同一组合，而非 header 中创建时的值（`packages/preset/agent-presets/src/session.ts:22`） | 无直接事件消费点。注意区分：`packages/client/ui-commands/src/client/service.ts:161` 监听的是**同名的 cordis 事件**（声明于 `packages/preset/agent-presets/src/types.ts:80`，见 `docs/event-producer-consumer.md`），不是本 session 事件；投影键 `agentPreset` 亦无 `useProjection` 消费点 |
| `goal/change` | `packages/goal/goal/src/domain.ts:66` | `GoalChangeMeta`：`GoalSnapshotChangeMeta \| GoalClearChangeMeta`（`kind: 'goal/change'`，`version: 1`，`operation`，完整快照或清除墓碑） | 变更后的完整 goal 状态，或清除墓碑（`packages/goal/goal/src/domain.ts:63`） | 经 `goal` 投影消费（`packages/client/ui-goal/src/client/GoalBar.tsx:176`） |
| `plan/mode` | `packages/plan/plan-mode/src/index.ts:46` | `{ active: boolean }` | 说明 plan 模式自此点起是否生效：只进日志、非 surface、整值替换。**最后一个** `plan/mode` 胜出；完全不含此事件的日志经投影单元的 fold 折叠为 inactive（`packages/plan/plan-mode/src/index.ts:41`） | 经 `plan` 投影消费（`packages/client/ui-plan/src/client/PlanModeControl.tsx:20`） |
| `todo/write` | `packages/todo/tool-todo/src/types.ts:31` | `{ todos: TodoItem[] }` | 整表快照；重放时最新写入胜出。只进日志的 UI 状态，永不进入派生历史（`packages/todo/tool-todo/src/types.ts:30`） | 经 `todos` 投影消费（`packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:128`） |
| `schedule/change` | `packages/schedule/schedule/src/types.ts:219` | `ScheduleChange`（`ScheduleCreateChange \| ScheduleDeleteChange \| ScheduleDispatchChange`，`packages/schedule/schedule/src/types.ts:105`） | 带版本的 Schedule 变更。拥有包在接收候选事件前校验完整的会话本地转移流（`packages/schedule/schedule/src/types.ts:215`） | 经 `schedule` 投影消费（`packages/client/ui-schedule/src/client/ScheduleCatalogAction.tsx:106`） |
| `feedback/record` | `packages/feedback/command-feedback/src/index.ts:62` | `{ text: string }` | 一条记录下来的人类对会话的评语。只进日志且独立于其触发方式；绝不进入模型上下文或派生历史（`packages/feedback/command-feedback/src/index.ts:58`） | 无 |

`TodoItem` 刻意最小化：只有人类可读的 `content` 行和三态 `status`（`'pending' | 'in_progress' | 'completed'`）；没有 id、priority 或 `activeForm`——列表在每次写入时整体替换（last-write-wins），条目不需要稳定身份（`packages/todo/tool-todo/src/types.ts:11`）。

### 2.8 `compaction/*`

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `compaction/start` | `packages/compaction/compaction/src/types.ts:24` | `{ compactionId: CompactionId; sourceCommandId?: CommandId; turn: number \| null }` | 标记一次压缩的开始——只进日志，持有锁直到 `compaction/end`。编号 owner 被那个打开的 turn 严格包含；`null` 标识 turn 之间的独立手动事务（`packages/compaction/compaction/src/types.ts:20`） | `packages/client/ui-chat/src/client/conversation-nodes/compaction.ts:40` |
| `compaction/summary` | `packages/compaction/compaction/src/types.ts:34` | `{ compactionId; sourceCommandId?; summary: ContentBlock[]; shadowedRange; shadowedSeqs; shadowedTokenCount; provider; model; maxTokens?; usage? }` 与一个 `rawOutput`/`llmStreamCall` 判别联合 | 完成的摘要、其输入、其模型调用事实——只进日志，无 surfaceOp。摘要内容在 `data.summary`；真正的 surface 替换由紧随其后的 `user/message` 事件执行。**该相邻性是契约性的**——被遮蔽的计价字段就是替换的阴影价格（`packages/compaction/compaction/src/types.ts:26`） | `packages/client/ui-chat/src/client/conversation-nodes/compaction.ts:23` |
| `compaction/prune` | `packages/compaction/compaction/src/types.ts:82` | `{ shadowedRange: { start; end }; shadowedSeqs: SessionSeq[]; shadowedTokenCount: number }` | 一次无模型 prune 替换的阴影价格——只进日志，无 surfaceOp。共享的阴影价格协议：一个 surface `replace` 事件由紧靠其前的计量事件定价。替换**必须**在本事件之后立即同步追加（`packages/compaction/compaction/src/types.ts:74`） | 无（`ui-conversation/src/client/contract/records.ts:188` 消费 `compaction/summary`，prune 无消费点） |
| `compaction/end` | `packages/compaction/compaction/src/types.ts:72` | `{ compactionId; sourceCommandId?; turn: number \| null; error?: string }` | 标记一次压缩的结束——只进日志，释放锁。其 owner 与 `compaction/start` 匹配；`error` 记录不成功的尝试（`packages/compaction/compaction/src/types.ts:69`） | `packages/client/ui-chat/src/client/conversation-nodes/compaction.ts:42` |

### 2.9 `hook/*`、`llm/*`、`model/*`、`subagent/*`

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `hook/invoked` | `packages/hooks/hook-protocol/src/types.ts:19` | `{ turn; point; dialect: HookDialect; matcher?; handlerId }` | 一个 hook 命令在某 hook 点被调用——只进日志记录（带 `surfaceOp` 的都不是）。`dialect` 是运行它的桥（`claude-code`/`codex`），`point` 是 hook 点（`PreToolUse`、`Stop` 等），`matcher` 是选中它的 matcher-group 模式（全匹配时缺席），`handlerId` 是命令的稳定 id（使 invoked/result 对可关联）；`turn` 是调用所居的那个打开的 turn（`packages/hooks/hook-protocol/src/types.ts:11`） | 无 |
| `hook/result` | `packages/hooks/hook-protocol/src/types.ts:31` | `{ turn; point; handlerId; decision: string; exitCode?; stderrSummary?; durationMs }` | 与 `hook/invoked` 按 `handlerId` 配对的只进日志结果。decision 是解析出的权限结果、`continue:false` 时的 `stop`，或 `pass`；退出码可缺席，stderr 有界，duration 是墙钟运行时间（`packages/hooks/hook-protocol/src/types.ts:27`） | 无 |
| `llm/retry` | `packages/llm/llm-retry/src/types.ts:9` | `LlmRetryEventData`，一个判别联合：`mode: 'normal'` 变体带 `{ retryId; turn; step; provider; policyKey; retry; maxRetries; delayMs; failure }`，`mode: 'always'` 变体带 `{ retryId; turn; step; provider; policyKey; retry; delayMs; failure }`（无 `maxRetries`） | 一次失败的请求尝试之后安排的一次 provider 路由重试的持久、非 surface 记录（`packages/llm/llm-retry/src/types.ts:8`） | `packages/client/ui-chat/src/client/conversation-nodes/retry.ts:25` |
| `llm/retry-started` | `packages/llm/llm-retry/src/types.ts:11` | `{ retryId; turn; step; retry }` | 重试等待成功之后、下一次请求尝试开始之前写入的持久转移（`packages/llm/llm-retry/src/types.ts:10`） | `packages/client/ui-chat/src/client/conversation-nodes/retry.ts:51` |
| `model/selection` | `packages/api/session-controller/src/types.ts:41` | `ModelSelection`：`{ provider; model; reasoningEffort? }` | 为后续 prompt 组装请求的、经完整校验的模型选择。只进日志：绝不进入派生的模型历史（`packages/api/session-controller/src/types.ts:38`） | 经 `modelSelection` 投影消费（`packages/client/ui-model-selection/src/client/service.ts:82`） |
| `subagent/descriptor` | `packages/subagent/subagent/src/descriptor.ts:38` | `SubagentDescriptorData = OneShotSubagentDescriptorData \| ContinuableSubagentDescriptorData`；版本常量 `SUBAGENT_DESCRIPTOR_VERSION = 3` | 一个 session-backed 子 agent 的持久身份与生命周期模式，由建立它的 provider 在子会话初始 turn 内、其首次请求之前追加一次。continuable 记录还携带其可续跑的组成。只进日志：不带 `surfaceOp`，永不进入模型历史，且能存活压缩（`packages/subagent/subagent/src/descriptor.ts:33`） | 经 `subagent` 投影消费（`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:281`） |
| `subagent/model-selection-policy` | `packages/subagent/tool-subagent/src/model-selection-state.ts:17` | `{ allowedModels: AllowedModelRoute[] }` | 记录本会话的委派工具暴露子 provider、model 与 reasoning-effort 选择。在首次模型请求之前追加；缺席即表示固定路由定义。只进日志：不带 `surfaceOp` 且永不进入模型历史（`packages/subagent/tool-subagent/src/model-selection-state.ts:12`） | 无 `useProjection` 消费点（键 `subagentModelSelectionPolicy` 为 host-only 状态） |

### 2.10 `team/*`（experimental）

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `team/member` | `packages/experimental/agent-team/src/types.ts:223` | `{ version: 1; teamId: TeamId; member: TeamMemberSnapshot }` | 整体 teammate 生命周期值，仅存于 Team Lead Session（`packages/experimental/agent-team/src/types.ts:222`） | 经 `agentTeam` 投影（host-only 状态，无 `useProjection` 消费点） |
| `team/task` | `packages/experimental/agent-team/src/types.ts:225` | `{ version: 1; teamId: TeamId; task: TeamTaskSnapshot }` | 整体共享任务值，仅存于 Team Lead Session（`packages/experimental/agent-team/src/types.ts:224`） | 同上 |
| `team/message/queued` | `packages/experimental/agent-team/src/types.ts:227` | `{ version: 1; teamId: TeamId; message: TeamMessageSnapshot }` | 持久化信箱入队，在尝试投递之前存储（`packages/experimental/agent-team/src/types.ts:226`） | 同上 |
| `team/message/delivered` | `packages/experimental/agent-team/src/types.ts:229` | `{ version: 1; teamId: TeamId; messageId: TeamMessageId; targetId: SessionId }` | 目标 Session 已记录该消息的持久确认（`packages/experimental/agent-team/src/types.ts:228`） | 同上 |

### 2.11 `web/*`

| 事件 type | 声明位置 | 载荷要点 | 语义（何时发出） | 客户端消费 |
|---|---|---|---|---|
| `web/deepseek-search-llm-request` | `packages/web/web-search-deepseek/src/provider.ts:83` | `DeepSeekSearchLlmRequest`：`{ apiVersion; body: {...} }`（无凭据） | 一次辅助 DeepSeek 搜索请求的派发前记录。`recordRequest` 回调在派发前立即调用；抛出会阻止派发，使模型可见的辅助输入无法逃过日志（`packages/web/web-search-deepseek/src/provider.ts:82`、`:105`） | 无 |

## 3. 核心循环事件精确字段（问题 2）

以下为 `packages/core/session/src/types.ts` 的逐字段原文。

| 事件 | 精确字段（类型） |
|---|---|
| `turn/start` | `turn: number`（`:266`） |
| `turn/end` | `turn: number`；`reason: TurnEndReason`（`:275`） |
| `step/start` | `turn: number`；`step: number`（`:277`） |
| `step/end` | `turn: number`；`step: number`（`:279`） |
| `user/message` | `UserMessage`（`UserMessage extends Message`，`role: 'user'`；`source` 为 merge-extensible `MessageSourceMap`，`packages/core/session/src/types.ts:287` → `docs/subsystems/session.md:14`） |
| `assistant/chunk` | `turn: number`；`step: number`；`chunk: StreamChunk`（`:289`） |
| `assistant/message` | `turn: number`；`step: number`；`message: AssistantMessage`；`usage?: TokenUsage`；`interrupted?: true`（`:300`） |
| `tool/call` | `turn: number`；`step: number`；`callId: ToolCallId`；`name: string`；`arguments: string`（`:306`） |
| `tool/result` | `turn: number`；`step: number`；`message: ToolResultMessage`；`error?: { name: string; code: string }`；`meta?: JsonValue`（`:318`） |
| `request/header` | `header: EpochHeader`；`reason: RequestHeaderReason`；`startsSeries?: true`（`:329`） |
| `request/context` | `provider: string`；`model: string`；`contextWindow?: number`（`:234`） |
| `session/end-seed` | `Record<string, never>`（`:362`） |

### 3.1 `EpochHeader` 逐字段（`:222`）

| 字段 | 类型 | 说明 |
|---|---|---|
| `config` | `LlmCallConfig` | 会话的调用配置（provider、model、reasoning effort、采样标量） |
| `adapterDefaults?` | `LlmCallConfigAdapterDefaults` | 由确切适配器物化而非调用方提议的有效配置字段 |
| `system?` | `string` | 渲染后的系统提示文本；无系统提示的请求缺席 |
| `tools?` | `ToolSchema[]` | 组装后的工具 schema；无工具的请求缺席 |

### 3.2 事件信封（`SessionEvent`，`:434`）

每个事件恒有 `type: K`、`seq: SessionSeq`（会话内单调序号）、`time: number`（Unix epoch 毫秒）、`data: SessionEventMap[K]`。条件字段：`ignorable?: true` 恒可存在；`sourceEventSeqs?: SessionSeq[]` 与 `surfaceOp?: SurfaceOp` **仅**存在于 `SurfaceEventType` 变体（`:453`）。编译器在 `Session.append()` 调用点强制这一区分（`:430`）。

## 4. invariant / 版本机制（问题 3）

### 4.1 `ignorable` 的必读/可忽略语义

| 事实 | 来源 |
|---|---|
| `ignorable?: true` 标记「读者可在不认识 `type` 时安全跳过」 | `packages/core/session/src/types.ts:452` |
| **缺席即必读**：读者遇到不带该标记的未知类型**必须拒绝重建会话**，而不是静默丢弃 | `packages/core/session/src/types.ts:443` |
| 理由：一个未被识别的必读事件可能改变日志其余部分的解释方式 | `packages/core/session/src/types.ts:446` |
| 写入者只对「纯信息性、其丢失不影响重建」的记录设 `true` | `packages/core/session/src/types.ts:448` |
| 默认必读的取向：遗忘标记会过度拒绝（一种不便），而不是静默恢复一个被掏空的会话 | `packages/core/session/src/types.ts:449` |
| 运行时校验：seed 事件的 `ignorable` 若非 `undefined` 且非 `true` 即抛错 | `packages/core/session/src/index.ts:239` |
| 持久化读路径的实际消费者：`KNOWN_SESSION_EVENT_TYPES` 之外的类型，只有带 `ignorable` 标记才放行 | `packages/core/session/src/known-event-types.ts:9` |
| 事件名注册制被否决的理由：它不分类「省略是否安全」，且会让读取依赖组合 | `packages/core/session/src/known-event-types.ts:17` |

**实测结论：当前 51 个事件没有任何一个在生产源码里被写入 `ignorable: true`。** 全仓 grep 该字面量，命中全部位于 `tests/` 与 `*.spec.ts`（如 `packages/session/session-persistence/tests/persistence.spec.ts:1364`、`packages/session/session-log-deepseek/tests/upload.spec.ts:217`、`packages/core/session/tests/session.spec.ts:1125`）。即：本构建认识的全部事件都是 required-on-read，未知类型一律拒绝。

### 4.2 `SESSION_FORMAT_VERSION`

值 `0`，声明在 `packages/core/session/src/types.ts:87`。契约（同处 JSDoc，`:64`）：

| 规则 | 内容 |
|---|---|
| 唯一真源 | 每个新写入 `SessionHeader` 都盖上它，每个持久化后端在 load 时都强制校验。写点和 load 检查读同一常量 |
| 单一单调整数 | 无 major/minor 拆分 |
| bump 判据 | 由**写入者发出什么**决定，绝不是「更新的读者能否接受」 |
| 何时 bump | 恰在「旧运行时无法以完整语义正确性处理新日志」时。能解析不出错不算正确——静默跳过塑造重建的内容即为错误读取 |
| 达到该门槛的仅限结构性变更 | header 形状、`SessionEvent` 信封、核心事件语义，或 surface 机制（`SurfaceEventType` 集合与 `SurfaceOp` 变体） |
| 不 bump 的情况 | 新增一个普通事件类型不 bump——逐事件的 `ignorable` 守卫覆盖词汇增长 |
| 存疑时 | **bump**：近乎恒等的升级步骤几乎免费，而漏掉一次 bump 会让旧运行时静默错误读取新日志 |
| 机制记录 | upgrade-step 链、内存视图转换、migrate-on-continue 记录在 Agent Note `.agents/notes/implemented/architecture/2026-08-10-session-log-version-mechanism.md` |
| 不承诺兼容 | 仓库根 `AGENTS.md`「Pre-release stance」：后端拒绝旧磁盘格式，SQLite 用单调 `SCHEMA_VERSION`，`dsh-session` 保持 `SESSION_FORMAT_VERSION` 为 `0` 且无兼容承诺 |

### 4.3 拒读行为的实现点

| 行为 | 位置 |
|---|---|
| 解码任何事件行**之前**先拒绝外来格式版本，早于当前 header 形状校验 | `packages/session/session-persistence-jsonl/src/format.ts:305` |
| 理由：未来格式不必满足本构建的结构检查，其用户必须看到「升级 harness」而不是「会话日志损坏」 | `packages/session/session-persistence-jsonl/src/format.ts:299` |
| `assertSessionEventEnvelope` 拒绝已废弃的 `request/header-delta` legacy 格式 | `packages/core/session/src/index.ts:215` |
| 信封只允许 7 个键：`type`、`seq`、`time`、`data`、`surfaceOp`、`sourceEventSeqs`、`ignorable` | `packages/core/session/src/index.ts:218` |

## 5. 持久化映射（问题 4）

### 5.1 分层

| 层 | 职责 | 位置 |
|---|---|---|
| `session-persistence` | 与后端无关的 Service Definition（`ctx.sessionPersistence`）与写路径编排 `PersistenceCoordinator`；后端把事件作为事件溯源日志存储，把不可重放的非日志元数据单独携带 | `packages/session/session-persistence/src/index.ts:1`、`:82` |
| `session-persistence-jsonl` | JSONL 物理后端：路径净化、目录布局、header 行（反）序列化、截断修复偏移计算 | `packages/session/session-persistence-jsonl/src/format.ts:1` |
| 编解码核心 | chunk 行打包（`packages/core/session/src/chunk-rows.ts`）、序号区间编码（`seq-ranges.ts`）、存储记录解码 | `packages/core/session/src/` |

### 5.2 日志格式

第一行是私有 version-0 物理 header，`type: 'session'` 标签（`packages/session/session-persistence-jsonl/src/format.ts:46`）：

| 字段 | 规则 |
|---|---|
| `version` | 来自 `SESSION_FORMAT_VERSION` |
| `id` / `createdAt` | 必填 |
| `cwd` / `parentSession` / `origin` / `agentPreset` | 可选，`undefined` 时整键省略（绝不写 null） |
| `seedLength?` | 仅 seeded header 写入；未 seeded 且 cut 非 0 时抛错 |
| `delegationDepth` | 必写，缺省 `0` |
| 已退役字段拒绝 | `sandboxMode` / `approvalPolicy` 若出现在 header 行即抛错 |

物理文件路径：`<root>/<projectDir>/<sessionDir>/session.jsonl`（或 `.jsonl.zstd`）。`SessionId` 是未校验的 branded string，因此用 `encodeSegment` 做单段注入式转义（`../`、绝对路径、NUL、分隔符全部中和；安全码元保持字面；`~` 一律转 `~XXXX`；操作 UTF-16 码元以保留孤立代理项）（`packages/session/session-persistence-jsonl/src/format.ts:143`、`:234`）。

事件行编码：`eventLines(events, packChunks)` 在 `packChunks` 开启时把 delta-chunk 连续段打包成 `text-chunks` / `reasoning-chunks` / `tool-call-chunks` 存储行，关闭时一行一个事件。两种模式下 provenance 都在存储边界做区间编码。**读取与布局无关**（`scanLog` 始终解码行），因此该开关只改变新写入的字节（`packages/session/session-persistence-jsonl/src/format.ts:243`）。

| 配置项 | 值 | 位置 |
|---|---|---|
| `packChunks` 默认 | `true` | `packages/session/session-persistence-jsonl/src/index.ts:47`、`:138` |
| `compression` 默认 | `'zstd'` | `packages/session/session-persistence-jsonl/src/index.ts:48` |

### 5.3 chunks 打包（`assistant/chunk` 专有优化）

| 事实 | 位置 |
|---|---|
| 动机：provider 流式 token 级 delta，使日志存有数百行近似相同的行，其 JSON 信封比载荷大约 56 倍（真实 DeepSeek 会话实测） | `packages/core/session/src/chunk-rows.ts:2` |
| 打包单元：每个连续同块 delta 段压成**一个**存储行 | `packages/core/session/src/chunk-rows.ts:5` |
| 可打包的 delta 种类：`text-delta` / `reasoning-delta` / `tool-call-delta`；块边界、usage 与 finish chunk **始终**一行一个事件 | `packages/core/session/src/chunk-rows.ts:29` |
| 打包行是**编码词汇，不是 session 事件**：永不进入 `Session.snapshotEvents()`，没有 `SessionEventMap` 条目，使用无斜杠的裸类型标签，使读者无法把它们与事件分类混淆 | `packages/core/session/src/chunk-rows.ts:9` |
| 行类型与载荷 | `TextRunData`：`{ turn; step; index; dt: number[]; texts: string[] }`；`ToolCallRunData`：`{ turn; step; index; dt; id: ToolCallId; name?; args: string[] }`（`packages/core/session/src/chunk-rows.ts:40`、`:50`、`:55`） |
| 成员重建 | 成员 k 重建为 seq `seq0 + k`、time `time0` 加前 k 个 gap；墙钟回退时 gap 可为负（`packages/core/session/src/chunk-rows.ts:36`） |
| 最小打包成员数 `MIN_RUN = 3`；这是格式常量而非可调项，两种布局解码完全一致 | `packages/core/session/src/chunk-rows.ts:95` |
| token 边界是数据，`texts` 绝不 join | `packages/core/session/src/chunk-rows.ts:49` |
| 编码器白名单精确形状；未完全识别的一律逐字保留，未知字段或未来 chunk 变体失去压缩而不丢数据 | `packages/core/session/src/chunk-rows.ts:13` |
| 解码器在展开前校验，遇到畸形行标签值大声失败，而不是静默丢弃整段 | `packages/core/session/src/chunk-rows.ts:16` |

### 5.4 客户端看到的 `SessionEventLikeEntry` 与 `chunkrow/*`

`packages/api/session-controller` 是客户端契约的拥有者。

| 类型 | 定义 | 位置 |
|---|---|---|
| `SessionEventEntry` | `{ type: 'event'; event: SessionWireEvent }` | `packages/api/session-controller/src/types.ts:382` |
| `ChunkRowEvent` | 映射类型：`[Kind in ChunkRow['type']]: { type: \`chunkrow/${Kind}\`; seq: number; time: number; data: Extract<ChunkRow, { type: Kind }>['data'] }` | `packages/api/session-controller/src/types.ts:407` |
| `SessionChunkRun` | `{ type: 'chunks'; event: ChunkRowEvent }` | `packages/api/session-controller/src/types.ts:417` |
| `SessionHistoryRecord` | `SessionEventEntry \| SessionChunkRun` | `packages/api/session-controller/src/types.ts:423` |
| `SessionEventLikeEntry` | `{ type: 'event'; event: SessionEvent } \| { type: 'chunks'; event: ChunkRowEvent }` | `packages/api/session-controller/src/client/contract/events.ts:10` |
| `SessionLiveEventEntry` | `Extract<SessionEventLikeEntry, { type: 'event' }>`——活事件恒为裸事件，绝不打包 | `packages/api/session-controller/src/client/contract/events.ts:15` |

**转换点**：`pageRecords(events)` 对一页事件调用 `packChunkRuns(events)`，把 `ChunkRow` 经 `chunkEntryFor` 转成 `chunkrow/{text,reasoning,tool-call}-chunks` 并包进 `{ type: 'chunks' }`，其余事件经 `entryFor` 包成 `{ type: 'event' }`（`packages/api/session-controller/src/history.ts:366`、`:387`）。因此 `chunkrow/*` 是**客户端专有 wire 标签**，由 session-controller 从 `ChunkRow` 转出，源码中定义为 `ChunkRowEvent`；它本身**不是** `SessionEventMap` 成员。

客户端消费点（`packages/client/**/src/`，非测试）：

| 文件:行号 | 处理内容 |
|---|---|
| `packages/client/ui-chat/src/client/conversation-nodes/assistant.ts:43` | 三种 `chunkrow/*` 的判别 |
| `packages/client/ui-chat/src/client/conversation-nodes/turn-tail.ts:41` | 同上，turn 尾部 |
| `packages/client/ui-chat/src/client/conversation-nodes/turn-process.ts:45` | 同上，过程分组 |
| `packages/client/ui-chat/src/client/conversation-nodes/fallback.ts:19` | 打包行从 fallback 中排除（返回 `null`） |
| `packages/client/ui-trajectory/src/client/trajectory-assistant-definition.ts:51` | 三种 `chunkrow/*` 的判别 |
| `packages/client/ui-conversation/src/client/conversation/assembler.ts:132` | 分支 `input.type === 'chunks'`，且禁止打包行作为 `role: 'start'` 的 Match（`:133` 抛错） |

客户端纪律（`packages/client/AGENTS.md`「Conversation Node discipline」）：打包行是 **update-only**，消费 Assistant delta 的 Definition 必须同时实现 scalar 与 `chunkrow/*` 两个分支而**不展开成员**。

## 6. Projection 键（问题 5）

`SessionProjectionMap`（客户端可见）与 `SessionProjectionStateMap`（host fold 状态）是两张 merge-extensible 表，二者都在 `packages/session/session-projection` 的基础声明中为空（`packages/session/session-projection/src/types.ts:17`、`:24`）。领域包按需 merge；`wire` 块使该键客户端可见，host-only 键只出现在 StateMap（`docs/subsystems/session-projection.md:11`）。

### 6.1 完整键表

| 键 | 可见性 | 声明位置（StateMap / Map） | 定义位置 | Web 消费者 |
|---|---|---|---|---|
| `turnBoundary` | host-only | `packages/core/agent/src/projection.ts:7` | `packages/core/agent-loop/src/index.ts:56` | 无 `useProjection` 消费点 |
| `timeContext` | host-only | `packages/context/time-context/src/index.ts:29` | `packages/context/time-context/src/index.ts:153` | 无 |
| `tmuxContext` | host-only | `packages/context/tmux-context/src/index.ts:211` | `packages/context/tmux-context/src/index.ts:220` | 无 |
| `sessionListMetadata` | 客户端可见 | `packages/api/session-controller/src/types.ts:19` / `:27` | `packages/api/session-controller/src/list.ts:92` | 会话列表冷启动摘要（`list.ts:96` 定义 wire） |
| `imageLimits` | 客户端可见 | `packages/api/session-controller/src/types.ts:21` / `:29` | `packages/api/session-controller/src/list.ts:101` | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:85` |
| `modelSelection` | 客户端可见 | `packages/api/session-controller/src/types.ts:23` / `:31` | `packages/api/session-controller/src/model-selection-projection.ts:59` | 经投影 face 消费：`packages/client/ui-model-selection/src/client/service.ts:82`（`projections.faceOf('modelSelection')`）；本包内无 `useProjection` 字面键读取点 |
| `goal` | 客户端可见 | `packages/goal/goal/src/types.ts:114` / `:123` | `packages/goal/goal/src/index.ts:163` | `packages/client/ui-goal/src/client/GoalBar.tsx:176` |
| `permissions` | 客户端可见 | `packages/interaction/permission-presets/src/index.ts:41` / `packages/interaction/permission-presets/src/types.ts:42` | `packages/interaction/permission-presets/src/index.ts:238` | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:109` |
| `llmRetry` | host-only | `packages/llm/llm-retry/src/index.ts:119` | `packages/llm/llm-retry/src/index.ts:126` | 无 `useProjection` 消费点（重试 UI 由 `llm/retry` 事件驱动） |
| `tokenUsage` | 客户端可见 | `packages/llm/token-meter/src/usage-projection.ts:91` / `packages/llm/token-meter/src/projection.ts:71` | `packages/llm/token-meter/src/usage-projection.ts:122` | `packages/client/ui-chat/src/client/chat/StatsLine.tsx:165` |
| `contextPressure` | 客户端可见 | `packages/llm/token-meter/src/usage-projection.ts:92` / `packages/llm/token-meter/src/projection.ts:73` | `packages/llm/token-meter/src/usage-projection.ts:182` | `packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx:56` |
| `contextBreakdown` | 客户端可见 | `packages/llm/token-meter/src/breakdown-projection.ts:18` / `packages/llm/token-meter/src/projection.ts:75` | `packages/llm/token-meter/src/breakdown-projection.ts:59` | `packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx:57` |
| `plan` | 客户端可见 | `packages/plan/plan-mode/src/types.ts:41` / `:45` | `packages/plan/plan-mode/src/index.ts:132` | `packages/client/ui-plan/src/client/PlanModeControl.tsx:20`；`packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:60` |
| `agentPreset` | 客户端可见 | `packages/preset/agent-presets/src/types.ts:63` / `:67` | `packages/preset/agent-presets/src/session.ts:36` | 无 `useProjection` 消费点 |
| `sandboxMode` | host-only | `packages/sandbox/sandbox-policy/src/index.ts:99` | `packages/sandbox/sandbox-policy/src/index.ts:133` | 无（经 `permissions` 聚合后可见） |
| `schedule` | 客户端可见 | `packages/schedule/schedule/src/projection.ts:89` / `packages/schedule/schedule/src/types.ts:226` | `packages/schedule/schedule/src/projection.ts:70` | `packages/client/ui-schedule/src/client/ScheduleCatalogAction.tsx:106` |
| `sessionStats` | 客户端可见 | `packages/session/session-stats/src/projection.ts:84` / `packages/session/session-stats/src/types.ts:44` | `packages/session/session-stats/src/projection.ts:130` | `packages/client/ui-chat/src/client/chat/StatsLine.tsx:170` |
| `title` | 客户端可见 | `packages/session/session-title/src/types.ts:82` / `:92`（另有 `titleInput` host-only，`:84`） | `packages/session/session-title/src/index.ts:264` | 经组件的 `title` prop 消费（`packages/client/ui-layout/src/client/DocumentTitle.tsx:6`、`:17`）；本包内无 `useProjection` 字面键读取点 |
| `turnOutline` | 客户端可见 | `packages/session/session-turn-outline/src/types.ts:43` / `:47` | `packages/session/session-turn-outline/src/projection.ts:86` | `packages/client/ui-chat/src/client/chat/ChatView.tsx:230` |
| `subagentTiming` | 客户端可见 | `packages/subagent/subagent/src/projection.ts:50` / `packages/subagent/subagent/src/projection-types.ts:54` | `packages/subagent/subagent/src/projection.ts:64` | 经摘要的 `projectionValues` 读取（`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:94`）；本包内无 `useProjection` 字面键读取点 |
| `subagent` | 客户端可见 | `packages/subagent/subagent/src/projection.ts:51` / `packages/subagent/subagent/src/projection-types.ts:64` | `packages/subagent/subagent/src/projection.ts:170` | `packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:281` |
| `subagentModelSelectionPolicy` | host-only | `packages/subagent/tool-subagent/src/model-selection-state.ts:27` | `packages/subagent/tool-subagent/src/model-selection-state.ts:38` | 无 |
| `todos` | 客户端可见 | `packages/todo/tool-todo/src/types.ts:37` / `:45` | `packages/todo/tool-todo/src/index.ts:135` | `packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:128` |
| `agentTeam` | host-only | `packages/experimental/agent-team/src/projection.ts:160` | `packages/experimental/agent-team/src/projection.ts:309` | 无 |

### 6.2 客户端 `useProjection` 实际读取的全部键（16 个，非测试）

`packages/client/**/src/` 中字面键调用点穷举：

| 键 | 消费点 |
|---|---|
| `turnOutline` | `packages/client/ui-chat/src/client/chat/ChatView.tsx:230` |
| `tokenUsage` | `packages/client/ui-chat/src/client/chat/StatsLine.tsx:165` |
| `sessionStats` | `packages/client/ui-chat/src/client/chat/StatsLine.tsx:170` |
| `contextPressure` | `packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx:56` |
| `contextBreakdown` | `packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx:57` |
| `plan` | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:60`；`packages/client/ui-plan/src/client/PlanModeControl.tsx:20` |
| `goal` | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:62`；`packages/client/ui-goal/src/client/GoalBar.tsx:176` |
| `imageLimits` | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:85` |
| `permissions` | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:109` |
| `todos` | `packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:128` |
| `schedule` | `packages/client/ui-schedule/src/client/ScheduleCatalogAction.tsx:106` |

另有经共享组件读取而非字面键的键：`subagentTiming` 与 `subagent`（`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:94`、`:281`）、`modelSelection`（`packages/client/ui-model-selection/src/client/ModelSelect.tsx:225`）、`title`（`packages/client/ui-layout/src/client/DocumentTitle.tsx:12`）。

### 6.3 契约要点（`packages/session/session-projection/src/index.ts:145`、`docs/subsystems/session-projection.md`）

| 事实 | 位置 |
|---|---|
| `ProjectionDefinition.apply` 必须是纯同步转移：不关心的事件**必须返回同一 state 引用**，`Object.is` 相等产生零下游工作 | `docs/subsystems/session-projection.md:37` |
| **整值事件规则是承重的**：携带状态的日志事件带完整的变更后状态，绝不带裸 delta；这让每次转移平凡廉价、每个送出值自描述（消费方 last-wins） | `docs/subsystems/session-projection.md:70` |
| `wire` 块仅在键同时存在于 `SessionProjectionMap` 时合法；host-only 单元省略它 | `docs/subsystems/session-projection.md:46` |
| `stateVersion` 是持久化缓存失效版本：序列化字段或 fold 语义变更时必须 bump，使旧单元的 `(sessionId, key, ver, seq, val)` 行被丢弃而不是被前向应用成垃圾 | `docs/subsystems/session-projection.md:60` |
| `snapshot(session)` 完全同步，返回 `{ asOfSeq, values }`；`asOfSeq` 是最后被反映事件的 seq（空日志为 `-1`）。每个值在返回前过 `viewSchema` | `docs/subsystems/session-projection.md:74`、`:102` |
| 变更馈送仅在 `view` 结果按 `Object.is` 变化时触发；对象值 view 必须复用引用以在纯内部状态变化时抑制发布 | `docs/subsystems/session-projection.md:102` |
| 注册是 effect，disposer 随调用 fiber 走；卸载的域插件的键（连同其缓存单元）从后续 drive 和 snapshot 中消失，客户端读作能力缺失 | `docs/subsystems/session-projection.md:106` |
| 同键不同 `stateVersion` 抛错；同版本注册者共享一个单元并被计数 | `docs/subsystems/session-projection.md:106` |
| 框架驱动、域计算：注册表只订阅一次 `session/event`，对每个已提交事件折过每个单元；域不持有订阅，客户端从不折叠域事件 | `docs/subsystems/session-projection.md:5` |

## 7. 明确「源码未明确」的条目

| 项 | 状态 |
|---|---|
| 生产代码中 `ignorable: true` 的实际使用 | 源码未明确（0 处；仅测试使用） |
| `compaction/prune` 的客户端消费点 | 未找到（`packages/client/**/src/` 无匹配） |
| `request/context` 的客户端消费点 | 未找到 |
| `approval/asked` / `approval/decided` / `hook/*` / `web/*` / `session/title-llm-request` / `session-log-deepseek/delivery-accepted` / `subagent/model-selection-policy` 的客户端消费点 | 未找到（均为 log-only，不进入 UI） |
| `agent-preset/selected`（session 事件）的客户端消费点 | 未找到。同名 cordis 事件有消费点，但属于不同的事件表 |
| `agentPreset`、`llmRetry`、`turnBoundary`、`sandboxMode`、`subagentModelSelectionPolicy`、`agentTeam` 的 `useProjection` 消费点 | 未找到（均为 host-only 或仅经组件 prop / 投影 face 间接可达） |
| `team/*` 的客户端 UI 消费 | 未找到（`agentTeam` 为 host-only 状态） |

### 7.1 复核记录

本文所有行号经二次实测校验。以下三处初稿标注在复核中被修正，此处留痕以示未经验证的引用已剔除：

| 初稿标注 | 实际事实 | 复核方式 |
|---|---|---|
| `modelSelection` 由 `packages/client/ui-model-selection/src/client/ModelSelect.tsx:225` 消费 | 该文件无 `modelSelection` 字样；真实消费点是同包 `service.ts:82` 的 `projections.faceOf('modelSelection')` | 对 `packages/client` 全目录 grep `modelSelection` |
| `subagentTiming` 由 `SubagentHeaderLineage.tsx:94` 经 `useProjection` 消费 | 该处是 `summary.projectionValues?.subagentTiming`，非 `useProjection` 调用 | 读取该文件 90–100 行 |
| `title` 由 `DocumentTitle.tsx:12` 经 `useProjection` 消费 | 该组件通过 `title?: string` prop 接收（`:6`、`:17`），文件内无 `useProjection` | 读取该文件全文 |

