# C — 会话消息流的渲染（视觉元素）

源码根：`third_party/deepseek-harness`（tag `dsh-v0.1.2-rc.1`，commit `a66e4702047846cdaa10c66c9d3df3951f5ea70d`）。
本文所有路径相对源码根，行号取自该 commit 的工作树文件。

覆盖包：`packages/client/ui-chat`、`ui-tool`、`ui-trajectory`、`ui-deliverables`、`ui-subagent`、`ui-workflow-run`、`ui-message-feedback`、`ui-jobs`、`ui-approval`、`ui-user-questions`、`ui-attachment`、`ui-goal`、`ui-conversation`、`packages/extensions/ui-cordis`、`packages/extensions/cordis-client-runner`。

---

## 1. UI 消息流的节点类型全表

### 1.1 三层 kind 必须区分

| 层 | 定义位置 | 作用 |
|---|---|---|
| Definition kind（事件层） | `uiConversation.events.register({ kind })` | 事件注册表键，同一 `(kind,id)` 折叠成一个 Context |
| ChatNodeDataMap kind（渲染层） | `ui-chat/src/client/contract/chat-nodes.ts:16` 的 merge 扩展 | `conversation.chat.node` 这个 keyed slot 的 dispatch 键 |
| 目标视图 kind | `ChatConversationViewNode.kind` | 最终节点携带的 kind |

渲染层 kind 与 Definition kind 可以不同名：`input-message` 定义产出 `user` / `steering` / `context` 三种节点（`ui-chat/src/client/conversation-nodes/message.ts:39-85`），`command` 定义在 name 为 `compact` 时产出 `manual-compaction` 而非 `command`（`ui-chat/src/client/conversation-nodes/command.ts:206-217`）。

`ChatNodeDataMap` 自身是空接口（`ui-chat/src/client/contract/chat-nodes.ts:16`），全部 kind 由各包 `declare module` 合并而来；`ChatNodeKind` 即其键集（`chat-nodes.ts:19`）。

### 1.2 Chat target 的 node kind 全表（17 个）

| # | node kind | 数据载荷类型 | 渲染视觉元素（组件） | 数据来源事件 | 声明处 |
|---|---|---|---|---|---|
| 1 | `user` | `ReferencedUserMessageNode` | 右对齐用户气泡：图片组（align end）+ 文本气泡 + 额外块 JSON + 复制/时钟操作条 | `user/message`（append 表面、`source.kind === 'user'` 且未被当前 next-step claim）= `message.ts:42-46`、`message.ts:72-78` | `ui-chat/.../message.ts:21-30` |
| 2 | `steering` | `ReferencedSteeringMessageNode` | 同上气泡，多 `data-pending-steering` 标记（进入活动 turn 的用户消息） | `user/message` 且 id 命中 `agent/inbox/spliced` 当前 claim（`message.ts:61-71`） | `message.ts:21-30` |
| 3 | `context` | `ContextMessageNode` | `ContextInjectionRow`：折叠披露行，标题为「上下文注入/会话召回」，展开为按 producer form 渲染的正文 | `user/message` 但 `source.kind !== 'user'`（`message.ts:50-59`） | `message.ts:21-30` |
| 4 | `system-prompt` | `{ text: string }` | `SystemPromptRow`：折叠披露行，展开为不透明代码块正文（完整 system prompt） | `request/header`（`request-prompt.ts:60-62`），仅当 `showsPrompt` 与 system 非空（`request-prompt.ts:92`） | `request-prompt.ts:8-13` |
| 5 | `assistant-step` | `AssistantChatData` | `AssistantMarkdown`：文本块 Markdown 流、推理块 Think 折叠行、连续图片组、未知块 JSON；中断时追加「已停止」标记 | `step/start`（start）+ `assistant/chunk`、`assistant/message`、`chunkrow/text-chunks`、`chunkrow/reasoning-chunks`、`chunkrow/tool-call-chunks`、`llm/retry`（update）（`assistant.ts:378-391`） | `assistant.ts:15-20` |
| 6 | `tool-call` | `ToolChatData { root: ToolCallBlock }` | `ToolCallTree`：根调用 + 递归子调用的卡片树，每层走 `tool.call.toolview` | `tool/call`（start）+ `tool/result`（append 表面）、`tool/code-dispatch-start`、`tool/code-dispatch`（按 `rootCallId` 归并）（`tool.ts:234-246`） | `tool.ts:11-16` |
| 7 | `command` | `CommandNode` | `CommandNodeView`（`ui-chat/src/client/chat/CommandNodeView.tsx`）：命名命令卡（走 `conversation.chat.commandview`，未占位时用 `GenericCommandCard`） | `command/run`（start）、`command/done`（update）（`command.ts:179-185`） | `command.ts:13-20` |
| 8 | `manual-compaction` | `ManualCompactionChatData` | `ManualCompactionNodeView`（同一文件）：手动 `/compact` 命令与其压缩事务合并为一张卡 | `command/run`/`command/done` 且 `name === 'compact'`，并吸收 `compaction/start|summary|end`、带 `sourceCommandId` 的替换 checkpoint（`command.ts:186-196`、`command.ts:209-216`） | `command.ts:13-20` |
| 9 | `compaction` | `CompactionSummaryNode` | `CompactionItem`：可展开的压缩标记行（图标 + 标题 + 「已完成 N 项 / M token」，展开为摘要 Markdown） | `compaction/start`、`compaction/summary`、`compaction/end`，以及无 `sourceCommandId` 的替换 checkpoint（`compaction.ts:35-49`） | `compaction.ts:10-15` |
| 10 | `model-retry` | `RetryChatData` | `ModelRetryItem`：`<details>` 折叠行，摘要为「等待/正在/已重试模型请求 (n/max) · Ns」并带倒计时，展开显示延迟与失败原因 | `llm/retry`（retry===1 时 start，否则 update）、`llm/retry-started`（`retry.ts:45-56`） | `retry.ts:10-15` |
| 11 | `turn-error` | `TurnErrorNode` | `TurnErrorItem`：错误状态点 + 「对话出错」+ 失败消息 + 错误码 | `turn/start`（start）、`turn/end` 且 `reason.kind === 'error'`（`turn-error.ts:60-65`） | `turn-error.ts:9-14` |
| 12 | `turn-max-tokens` | `TurnMaxTokensNode` | `TurnMaxTokensItem`：警告点 + 「输出达到上限」+ 提示语 | `turn/end` 且 `reason.kind === 'max-tokens'`（`turn-max-tokens.ts:51-55`） | `turn-max-tokens.ts:8-13` |
| 13 | `turn-process` | `TurnProcessChatData` | `TurnProcessNodeView`：Turn 级过程披露按钮（工具调用/消息/子代理计数或「思考了一会儿」），控制同 Turn 过程行折叠 | `turn/start` + 大量 turn 内 update（`turn-process.ts:222-238`） | `turn-process.ts:17-22` |
| 14 | `turn-tail` | `TurnTailChatData` | `TurnTailNodeView`：Turn 尾行（产出行链 + 复制/分支/用量/耗时操作条） | `turn/start`、`turn/end`、`tool/call`、`tool/result`、assistant/chunk、chunkrow*、step/start|end、llm/retry(-started)（`turn-tail.ts:183-192`） | `turn-tail.ts:16-21` |
| 15 | `unknown` | `UnknownSurfaceNode` | `UnknownNodeView`：未知 append 表面事件的 JSON 块 | 任何未被其他 Definition 认领的 append 表面事件（fallback，`fallback.ts:17-23`） | `fallback.ts:7-12` |
| 16 | `command-input` | `GoalCommandInputData` | `GoalCommandInputView`：人类输入的 `/goal` 命令行 | `command/run` 且 `name === 'goal'`（`ui-goal/src/client/goal-command-input.ts:39-41`） | `ui-goal/src/client/goal-command-input.ts:15-20` |
| 17 | `workflow-run` | `WorkflowRunChatData` | `WorkflowRunPanel`：一次 workflow run 的面板（phase 分组 + 成员状态，可打开子会话） | `tool-workflow/run-start`、`agent-start`、`agent-end`、`run-end`（`ui-workflow-run/src/client/workflow-definition.ts:152-159`） | `ui-workflow-run/src/client/workflow-definition.ts:37-42` |

### 1.3 渲染器注册（谁把 kind 落到组件）

| 注册者 | key 集 | 声明 children | 来源 |
|---|---|---|---|
| `ui-chat` | `user`、`steering`、`context`、`system-prompt`、`assistant-step`、`command`、`manual-compaction`、`compaction`、`model-retry`、`turn-error`、`turn-max-tokens`、`turn-process`、`turn-tail`、`unknown` | `command` 项声明 `conversation.chat.commandview`；`turn-tail` 项声明 `conversation.chat.turnTail` 与 `conversation.chat.assistant-actions` | `ui-chat/src/client/chat/register-node-renderers.ts:18-57` |
| `ui-tool` | `tool-call` | 声明 `tool.call.toolview` | `ui-tool/src/client/apply.ts:33-41` |
| `ui-goal` | `command-input` | 无 | `ui-goal/src/client/index.ts:60-64` |
| `ui-workflow-run` | `workflow-run` | 无 | `ui-workflow-run/src/client/index.ts:28-35` |

未注册 kind 的兜底：`ChatNodeSeat` 在 `renderSlot('conversation.chat.node', …, { fallback })` 里给未命中键渲染 JSON 块（`ui-chat/src/client/chat/ChatNodeSeat.tsx:136-146`）。

### 1.4 节点顺序与可见性

- 只有 `visibility === 'visible'` 的节点进入 `order`（`ui-chat/src/client/conversation-nodes/chat-snapshot-builder.ts:404`）。
- 排序键依次为 `anchor`、`rank`、`originalAnchor`、`key`（`chat-snapshot-builder.ts:406-413`）；`rank` 由 Turn-process 演示决定（开场人类输入优先、合成过程控件居中，`chat-snapshot-builder.ts:363-392`）。
- 合成 seq 偏移常量表定义在 `ui-chat/src/client/conversation-nodes/common.ts:14-20`（中断助手 -0.9、中断跟进 -0.8、过程控件 -0.1、max-tokens 提示 +0.05、最终跟进 +0.1）。
- `isActive`：只要 order 中存在非 `command` 节点，Chat target 即视为活跃（`chat-snapshot-builder.ts:861`）。

---

## 2. 助手文本与推理过程的渲染

### 2.1 流式分段的数据折叠

| 事实 | 处理 | 来源 |
|---|---|---|
| 分块协议 | `assistant/chunk` 的 `block-start`、`text-delta`、`reasoning-delta`、`tool-call-delta`、`block-end`、`usage` | `ui-chat/src/client/conversation-nodes/assistant.ts:104-148` |
| 历史打包行 | `chunkrow/text-chunks`、`chunkrow/reasoning-chunks`、`chunkrow/tool-call-chunks` 折叠进同一步的 blocks | `assistant.ts:201-247` |
| 首 token / 首可见时间 | 按块可见性记账，供 ttft 使用 | `assistant.ts:149-164`、`assistant.ts:225-246` |
| 最终消息 | `assistant/message` 覆盖 blocks，产出 `finalNode`（含 messageId、usage、timing、interrupted） | `assistant.ts:260-298` |
| 中断但无最终消息 | 用 step/turn 关闭边界 + 偏移生成「中断助手」节点，`interrupted: true` | `assistant.ts:284-297` |
| 重试重置 | `llm/retry` 把已累积 blocks 清空并置 `hidden` | `assistant.ts:90-96`、`assistant.ts:412-414` |
| 发布节流 | chunk 与 chunkrow 走 `animation-frame`，usage/finish 与 `step/start` 为 `none` | `assistant.ts:417-423` |

`status` 三态由 `settled` 与 `interrupted` 推导（`assistant.ts:346-348`）。

### 2.2 渲染

| 视觉元素 | 行为 | 来源 |
|---|---|---|
| 文本块 | `MarkdownText`，`streaming` 随 `status === 'running'` 传递（流式光标/渐进渲染由 primitives 负责） | `ui-chat/src/client/chat/AssistantNodeView.tsx:30-39`、`AssistantMarkdown.tsx:50-59` |
| 推理块 | `ReasoningRow`：`DisclosureRow` 折叠行，图标 +「思考」+ 一行摘要；运行时摘要取**最后一行**并跟随尾部，结束后取**第一行**；点击整行展开全文 | `ui-chat/src/client/chat/ReasoningRow.tsx:26-61` |
| 推理折叠/展开控件 | 有。折叠行本身就是展开按钮（`expandOnRowClick`）；运行时另有视觉隐藏的 `row.running` 供读屏 | `ReasoningRow.tsx:38-56` |
| Turn 级推理隐藏 | 当 turn-process 可折叠、该 step 是答案步、且容器未展开时，推理块整块隐藏，并可被 `搜索命中` 触发的 `revealProcess` 重新展开 | `AssistantNodeView.tsx:23-28`、`AssistantMarkdown.tsx:120-127`、`ui-chat/src/client/chat/searchable-hidden.ts` |
| 连续图片块 | 相邻 image 块合并为一个 gallery，key 取组首块索引，align `start` | `AssistantMarkdown.tsx:72-95` |
| 未知块 | `JsonBlock`，标签 `message.unknownBlock` | `AssistantMarkdown.tsx:99-107` |
| 仅 tool-call 头的节点 | 不画外壳（避免工具组之间出现空壳） | `AssistantMarkdown.tsx:41-44`、`AssistantMarkdown.tsx:97-98` |
| 中断标记 | `interrupted` 时在正文尾部追加 `message.stopped` 文本 | `AssistantMarkdown.tsx:114` |
| 中断节点的操作缺失 | 中断的 partial 无 `messageId`，因此不产出逐消息操作 | `ui-chat/src/client/chat/TurnTailNodeView.tsx:31-36` |

### 2.3 错误

助手节点本身没有 error 状态位（`AssistantChatData` 只有 `status/turn/step/blocks/time/usage/finalNode`，`ui-chat/src/client/contract/chat-nodes.ts:30-38`）。错误走两条独立展示：

- 终止失败：`turn/end` 的 `reason.kind === 'error'` → `turn-error` 节点（`MessageItem.tsx:118-132`）；`code === 'AUTH'` 换用 `message.failure.auth` 文案（`MessageItem.tsx:43-49`）。
- 模型请求自动重试：`llm/retry` → `model-retry` 节点（被动展示，非按钮）（`MessageItem.tsx:51-115`）。

---

## 3. 工具调用卡片（ui-tool）

### 3.1 从事件到卡片

| 阶段 | 事实 | 来源 |
|---|---|---|
| 根调用 | `tool/call` → `RunningToolCall{callId,name,argsRaw,turn,step,time,subCalls}` | `ui-chat/src/client/conversation-nodes/tool.ts:39-50` |
| 根结果 | `tool/result` → `ToolResultNode{seq,time,callId,call,callTime,content,isError,error,meta}`，`call` 从原调用补齐 | `tool.ts:52-68` |
| 子调用（Code Dispatch） | `tool/code-dispatch-start` / `tool/code-dispatch` 按 `rootCallId` 归并到根，边接受前做环与深度校验 | `tool.ts:79-166` |
| 深度上限 | `MAX_DEPTH = 256`；`ui-chat/src/client/model/tool-call-tree.ts:14` 另有 `MAX_TOOL_CALL_TREE_DEPTH = 256` | `tool.ts:18`、`tool.ts:168-206` |
| 中断补齐 | 已关闭但无结果的运行中调用被投影成 `isError:true, error:{name:'Interrupted',code:'interrupted'}` | `tool.ts:189-203` |
| 卡片分发 | `ToolCallTree` 对每个调用 `renderSlot('tool.call.toolview', owner, { entryKey: toolName, fallback: GenericToolCard })`；子调用递归复用同一路径 | `ui-tool/src/client/tool/ToolCallTree.tsx:14-47`、`ToolCallTree.tsx:49-87` |
| 选中高亮 | 容器带 `data-chat-anchor-key="call:<id>"` 与 `data-selected` | `ToolCallTree.tsx:34-39` |

`tool.call.toolview` 的 key 域是开放的线上工具名：未命中键回退到 generic 行，命中即替换（`ui-tool/src/client/contract/slots.ts:12-26`）。

### 3.2 generic 卡片显示的内容

| 元素 | 内容 | 来源 |
|---|---|---|
| 前导图标 | 按 variant 取图标；`error` 换成红点、`stopped` 换成告警点 | `ui-tool/src/client/tool/components/ToolRow.tsx:70-76` |
| 标题 | `tool.title.*` 字典键（search/read/bash/write/edit/code/generic），部分工具用专属标题（pwsh、cordis_*、inspect） | `ui-tool/src/client/tool/models/tool-call-model.ts:26-30`、`tool-call-model.ts:66-73` |
| 折叠摘要 | 由参数 JSON 摘要键推导（bash: description/command；read: path/file_path/url；search: query/pattern/url 或 queries 列表；write/edit: path），缺省回退首行文本；`others` 变体在无专属标题时显示 `<toolName> · <摘要>`；摘要为工作区路径时相对 cwd 并做 `~` 缩写 | `tool-call-model.ts:146-183`、`tool-call-model.ts:226-241` |
| 摘要后缀 | diff 行显示 `+A -R` 变更统计；todo 行显示并行进行中的 `+N` | `ToolRow.tsx:142-147`、`ui-tool/src/client/tool/toolviews/todo-row.tsx:52-67` |
| 失败行 | error 状态下折叠摘要整体替换为结果首行（不追加） | `ToolRow.tsx:136-138`、`tool-call-model.ts:246` |
| 文件路径链接 | `read`/`write`/`edit` 的 path 渲染为可点按钮，调用宿主默认应用打开（启用相对路径先经 cwd 解析） | `ToolRow.tsx:148`、`ToolRow.tsx:186-195`、`ui-chat/src/client/apply.ts:122-128` |
| 运行状态 | 状态点/扫光为纯颜色（`aria-hidden`），另有视觉隐藏文本 `row.running` / `row.failed` / `row.stopped` | `ToolRow.tsx:82-89`、`ToolRow.tsx:168` |
| 展开体 | 卡片类（终端/diff/read/search/web/ask-user）优先，否则显示 `IN/OUT` 卡（输入为格式化参数 JSON，输出为结果全文）；`code` 变体额外用 `CodeBlock`（typescript）渲染程序 | `ToolRow.tsx:208-271` |
| Inspect | 展开体内出现 Inspect 按钮，跳转到 trajectory 视图并聚焦该 callId | `ToolRow.tsx:272-281`、`ui-chat/src/client/chat/ChatView.tsx:246-248` |
| 耗时 | 卡片不含耗时字段（`ToolRowProps` 无此项）；耗时改由 turn-tail 的 `TurnTimePanel` 呈现 | `ToolRow.tsx:25-68`、`TurnTailNodeView.tsx:52-64` |

状态判定：未结算 → `running`；`error.code === 'interrupted'` → `stopped`；`isError` → `error`；否则 `ok`（`tool-call-model.ts:230-232`）。bash 卡另有「退出码非 0 或收到信号」→ error 的独立信号（`ui-tool/src/client/tool/models/terminal-card-model.ts:93-96`、`ui-tool/src/client/tool/toolviews/GenericToolCard.tsx:39-41`）。

### 3.3 keyed toolview 清单（业务定制视图）

| key | 组件 | 专属展示 | 注册处 |
|---|---|---|---|
| `bash` | `BashRow` | 终端卡片：命令、cwd、输出、退出码/信号；失败或持久 shell 结果回落到 IN/OUT；可键盘展开 | `ui-tool/src/client/tool/toolviews/bash-sample.tsx:42-163` |
| `pwsh` | 无独立注册（走 generic 表） | 用 bash 行族 + `tool.title.pwsh` 标题 | `tool-call-model.ts:41-73` |
| `read` | `ReadRow` | Read 卡片（按行号的文件内容），可打开被读路径 | `ui-tool/src/client/tool/toolviews/read-row.tsx:15-45` |
| `write`、`edit` | `FileMutationRow` | Diff 卡片（applied diffs 优先，write 空元数据回退参数 diff） | `ui-tool/src/client/tool/toolviews/file-mutation-row.tsx:15-47` |
| `grep`、`glob` | `SearchRow` | Search 卡片（matches/paths 两种形态 + 截断总量），截断时在卡下显示结果文本中的 spill 定位 | `ui-tool/src/client/tool/toolviews/search-row.tsx:47-49`、`ui-tool/src/client/tool/models/search-card-model.ts:82-100` |
| `web_search`、`web_fetch` | `WebRow` | Web 卡片（查询/URL 与结果） | `ui-tool/src/client/tool/toolviews/web-row.tsx:18-51` |
| `todo_write` | `TodoRow` | 计划行：`已完成 d/total · 当前项`，并行项数作为不可裁剪后缀 | `ui-tool/src/client/tool/toolviews/todo-row.tsx:26-78` |
| `ask_user_question` | `AskQuestionRow` | 问答卡片：等待/已回答/已取消/已中断四态，已答时列出问答对照 | `ui-tool/src/client/tool/toolviews/ask-question-row.tsx:140-207` |
| `skill` | `SkillRow` | skill 引用专用行（仅由记录的 call/result 推导） | `packages/client/ui-skill/src/client/index.ts:69-72` |
| `cordis_define` | `CordisDefineRow` | Cordis 定义卡（含清单/已加载包） | `packages/extensions/ui-cordis/src/client/index.ts:118-123` |
| `cordis_run` | `CordisRunRow` | 运行卡，并声明子 slot `tool.view.cordis` 供动态包渲染交互区 | `packages/extensions/ui-cordis/src/client/index.ts:125-137` |
| `cordis_stop`、`cordis_undefine` | `CordisActionRow` | 运行控制动作行 | `packages/extensions/ui-cordis/src/client/index.ts:139-146` |

未命中任何 key 的工具（含 `subagent`、`run_code` 之外的通用工具、`terminal_send` 的 generic 分支）走 `GenericToolCard` + variant 表（`GenericToolCard.tsx:30-67`、`tool-call-model.ts:41-63`）。本域内没有名为 `fs` 的 toolview 包；文件工具集中在 `read`/`write`/`edit` 三个 key。

### 3.4 结果超大时的处理

| 机制 | 事实 | 来源 |
|---|---|---|
| 卡片行数上限 | Chat 行的 diff/read/search 卡片上限均为 8 行（`CHAT_DIFF_MAX_LINES`、`CHAT_READ_MAX_LINES`、`CHAT_SEARCH_MAX_LINES`），中部折叠；details 面板沿用 primitives 默认上限 | `ui-tool/src/client/tool/models/diff-card-model.ts:15`、`read-card-model.ts:17`、`search-card-model.ts:12`、`ui-tool/src/client/tool/ToolDetails.tsx:35-50` |
| 终端卡片 | Chat 行与 bash 行传 `maxLines={Infinity}`，不二次截断，改用 `TerminalBlock` 自身的「展开剩余 N 行」控件 | `ToolRow.tsx:213-219`、`bash-sample.tsx:115-121`、`terminal-card-model.ts:16-31` |
| 搜索截断 | 结果 `meta.truncated` 为真时，卡片之外再渲染一段原始结果文本（其中带 spill 定位串）作为恢复线索 | `search-card-model.ts:88-99`、`ToolRow.tsx:233-238` |
| 结果落盘（spill） | 由 Host 写临时文件，客户端只展示文本里的 `spill://` 定位；客户端没有自己的 spill 实现 | `packages/client/ui-settings-plugins/src/client/locales.ts:45`、`packages/client/ui-tool/tests/search-card.client.spec.tsx:167` |
| details 面板 | 展开全文的阅读面：先显示格式化输入（json CodeBlock），再渲染 `conversation.details.tool`（卡片或纯文本回退） | `ui-chat/src/client/details/DetailsPanel.tsx:81-104` |

---

## 4. 审批请求（ui-approval）

### 4.1 位置与触发

| 事实 | 内容 | 来源 |
|---|---|---|
| 不在消息流里 | 审批是 composer 接管（`conversation.composer` chain 的 `priority: 1` 条目），槽位选择器匹配 `PendingApproval` | `packages/client/ui-approval/src/client/index.ts:80-89` |
| 触发通道 | 作用域 Remote Event `approval/request`，客户端监听后把请求包装成 `PendingApproval` 并注册为 Session 待决交互 | `ui-approval/src/client/index.ts:90-92`、`index.ts:35-68` |
| 生命周期 | 未回答时可通过 `delegate()` 交给下一个 waterfall；transport/scope/插件卸载结束走 `abort()` | `ui-approval/src/client/contract/slots.ts:117-149` |

### 4.2 渲染

| 视觉元素 | 内容 | 来源 |
|---|---|---|
| 卡片 | 顶部状态条 + 等待文案 | `ui-approval/src/client/ApprovalPanel.tsx:31-33` |
| 主标题 | `reason`，缺失时回退「<工具名> 请求提权」 | `ApprovalPanel.tsx:41` |
| 详情区 | `conversation.approval.detail` 子槽（callId 存在时）；ui-chat 占位者只提取并显示该调用参数里的 `command` | `ApprovalPanel.tsx:14-16`、`ApprovalPanel.tsx:42`、`ui-chat/src/client/chat/ApprovalCommand.tsx:16-39` |
| 选项 | 两个按钮：拒绝（outline）与「允许一次」（primary）；提交后按钮禁用 | `ApprovalPanel.tsx:44-51` |
| 决策取值 | `ApprovalDecision` 只有 `'allowed-once'` 与 `'rejected'` 两种 | `ui-approval/src/client/contract/slots.ts:64` |

### 4.3 回复通道

不是普通 RPC：`answer(outcome)` 解析 Remote Event 的 waterfall 结果，Host 侧的 waterfall 直接得到决策（`ui-approval/src/client/contract/slots.ts:121-125`、`ui-approval/src/client/index.ts:57-67`）。

---

## 5. 用户问题（ui-user-questions）

### 5.1 位置与渲染形态

| 事实 | 内容 | 来源 |
|---|---|---|
| 位置 | composer 接管（`conversation.composer` chain，选择器匹配 `PendingQuestion`），一个条目两种形态 | `packages/client/ui-user-questions/src/client/index.ts:94-103` |
| 形态路由 | 请求声明 `plan-review` 意图且可判定时渲染计划评审卡，否则渲染通用问答流；路由放在唯一条目内部避免同一 carrier 竞争 | `ui-user-questions/src/client/QuestionComposer.tsx:113-127` |
| 触发通道 | Remote Event `user-questions/request` | `ui-user-questions/src/client/index.ts:104-106` |

### 5.2 通用问答流

| 视觉/交互 | 事实 | 来源 |
|---|---|---|
| 单选与多选 | 选项容器 role 随 `multiSelect` 在 `group` 与 `radiogroup` 间切换；单选选中后自动前进到下一题，多选累加 | `QuestionComposer.tsx:318`、`QuestionComposer.tsx:188-198` |
| 自由文本 | 每题一个自适应高度的 textarea；单选的自定义答案会清空选项选择，多选保留 | `QuestionComposer.tsx:250-258` |
| 选项无自由文本 | 无选项的题只渲染框式自由文本块 | `QuestionComposer.tsx:82-95` |
| 导航与进度 | 逐题推进，草稿按请求 key 存进该条目的 Session 级 store，切题后返回保留 | `QuestionComposer.tsx:138-166` |
| 跳过 | 跳过标记该题并前进；最后一题跳过即提交 | `QuestionComposer.tsx:266-276` |
| 最小化 | 头部可折叠成条带，保留上方对话可读 | `QuestionComposer.tsx:152`、`QuestionComposer.tsx:292-301` |
| 取消 | 头部关闭按钮 → `pending.cancel()` → 以 `ASK_CANCELLED` 拒绝 waterfall | `QuestionComposer.tsx:168-177`、`ui-user-questions/src/client/contract/slots.ts:183-189` |
| 校验 | 未作答时给出 `error.incomplete` / `error.unanswered` 并定位到缺答的题 | `QuestionComposer.tsx:205-211`、`QuestionComposer.tsx:234-245` |
| 「推荐」标记 | 选项标签尾部 `(recommended)`/`（推荐）` 被拆出为推荐态，答案值保持不变 | `QuestionComposer.tsx:30-35` |

### 5.3 计划评审卡

`plan-review` 意图需要单题、带 detail、二值单选且含 approve 标签；不满足时交回通用流（`ui-user-questions/src/client/contract/slots.ts:46-96`），渲染由 `PlanReviewPanel` 负责（`ui-user-questions/src/client/PlanReviewPanel.tsx`）。

### 5.4 回复通道

`answer(批答案)` / `cancel()` 解析 Remote Event waterfall；中断时以 `ASK_ABORTED` 拒绝（`ui-user-questions/src/client/contract/slots.ts:161-198`、`ui-user-questions/src/client/index.ts:54-80`）。问答结果在会话流里另由 `ask_user_question` 卡片回显（`ui-tool/src/client/tool/toolviews/ask-question-row.tsx`）。

---

## 6. 图片与附件

### 6.1 历史图片渲染链路

| 层 | 事实 | 来源 |
|---|---|---|
| 槽位 | `conversation.message.images`（Chat 视图）与 `conversation.trajectory.images`（Trajectory 视图）各为 `single`/session 槽，owner 是 `MessageImagesOwnerProps{images, loadImage, align}` | `ui-chat/src/client/contract/slots.ts:203`、`ui-trajectory/src/client/trajectory-contract.ts:88-96`、`ui-conversation/src/client/contract/slots.ts:74-85` |
| 声明 children | Chat 视图在注册时声明 `conversation.message.images`；trajectory 视图声明 `conversation.trajectory.images` | `ui-chat/src/client/apply.ts:101-104`、`ui-trajectory/src/client/index.ts:83-85` |
| 唯一占位者 | `ui-attachment` 的 `MessageImages` 同时填入两个槽 | `ui-attachment/src/client/index.ts:19-26` |
| Chat 侧渲染点 | `renderMessageImages` 由 ChatView 绑定为 `renderSlot('conversation.message.images', {...owner, loadImage})` | `ui-chat/src/client/chat/ChatView.tsx:299-302` |
| 用户消息 | 气泡上方图片组，align `end` | `ui-chat/src/client/chat/MessageItem.tsx:178` |
| 助手消息 | 连续 image 块合并为一组，align `start` | `ui-chat/src/client/chat/AssistantMarkdown.tsx:72-95` |
| Trajectory 侧 | 台账渲染时传入同一 attachment 渲染器 | `ui-trajectory/src/client/TrajectoryView.tsx:137-140` |

`RMessageImages` = `(owner: Omit<MessageImagesOwnerProps,'loadImage'>) => ReactNode`，因此目标包不需要依赖附件实现（`ui-conversation/src/client/contract/slots.ts:85`）。

### 6.2 historical-images.ts（缓存与 URL 生命周期）

| 事实 | 内容 | 来源 |
|---|---|---|
| 定位 | `HistoricalImageCache`：Session 作用域的持久图片 URL 缓存，由 `ConversationAssembly` 持有 | `ui-conversation/src/client/conversation/historical-images.ts:15-29`、`ui-conversation/src/client/conversation/assembly.ts:171`、`assembly.ts:181` |
| 解析 | `resolve(sessionId, attachment)` 按 `sessionId:attachmentId` 去重，走 `session.readAttachment`，成功后用 `URL.createObjectURL`（无该 API 时退化为 `data:` base64） | `historical-images.ts:37-55`、`historical-images.ts:109-133` |
| 同步预读 | `peek()` 返回已缓存 URL，供缩略图同步显示 | `historical-images.ts:63-65` |
| 提交回声 | `seed()` 用提交时的本地预览 URL 占位，随后被权威字节替换并 revoke | `historical-images.ts:76-103` |
| 释放 | Session 作用域释放或插销卸载时 revoke 全部 blob URL、清条目并递增 generation 使在途请求作废 | `historical-images.ts:148-179` |
| 对外接口 | 视图通过 `ctx.uiConversation.imageUrl/peekImageUrl` 取得带 `peek` 的 loader | `assembly.ts:238`、`assembly.ts:248`、`ui-chat/src/client/apply.ts:131-134` |

### 6.3 缩略图与灯箱

| 事实 | 内容 | 来源 |
|---|---|---|
| 单图 | 长边 240px、宽高比夹在 [0.25, 4]（超出部分 `object-fit: cover` 裁切）、不放大超过原图；裁切锚点按极端宽高比选 top/left | `packages/client/ui-attachment/src/MessageImage.tsx:40-57` |
| 多图 | 固定 64px 方形磁贴（variant `tile`） | `MessageImage.tsx:143-152` |
| 加载与失败 | 加载中显示占位文本，失败渲染可重试按钮 | `MessageImage.tsx:120`、`MessageImage.tsx:132-134` |
| 点击 | 打开 `ImageLightbox` 原图预览 | `MessageImage.tsx:130-136` |
| 提交回声 | `preview` 分支直接显示本地 URL，无 loader 往返与失败面 | `MessageImage.tsx:85-88`、`MessageImage.tsx:118` |

### 6.4 附件 chip（输入区）

| 事实 | 内容 | 来源 |
|---|---|---|
| 槽位 | `conversation.input.attachments`（single，session-maybe），owner 提供草稿图片、可接受拖放、增删回调与拖放上限文案 | `ui-conversation/src/client/contract/slots.ts:138-143`、`slots.ts:37-49` |
| 占位者 | `ui-attachment` 的 `ComposerAttachments` | `ui-attachment/src/client/index.ts:15-18` |
| 形态 | 横向缩略图轨（`AttachmentRail`）：隐藏滚动条、边缘箭头翻页、悬停显示单项删除、单击打开原图 | `ui-attachment/src/AttachmentRail.tsx:1-3`、`AttachmentRail.tsx:47-72` |
| 渲染点 | 输入卡内由 `InputBar` 渲染该槽 | `ui-conversation/src/client/skeleton/InputBar.tsx:398` |

---

## 7. Turn 尾（turn tail）与 deliverables

### 7.1 turn-tail 节点

| 事实 | 内容 | 来源 |
|---|---|---|
| 数据 | `TurnTailChatData{turn,seq,time,closing,branchUnavailable,ttftMs?,tokensPerSecond?,tokenUsage?}` | `ui-chat/src/client/contract/chat-nodes.ts:86-98` |
| closing 选择 | 本 Turn 内最后一个「有文本」的已终结助手（按 finalNode.seq 排序取末位） | `ui-chat/src/client/conversation-nodes/turn-tail.ts:143-150` |
| branchUnavailable | closing 为空，或存在更晚的转录证据（tool/call、tool/result、错误 turn/end、llm/retry）时置真 | `turn-tail.ts:151-172` |
| 指标 | `ttftMs` / `tokensPerSecond` 由 `deriveTurnMetrics` 给出；Token 明细由 `deriveTurnTokenUsage` 汇总 | `turn-tail.ts:163-176` |
| 锚点 | `closingAnchor`：turn/end 或末次有文本的 assistant/message（+0.1）；被中断的流式 step 用 +0.8 偏移 | `turn-tail.ts:86-124`、`common.ts:14-20` |
| 渲染 | 先渲染 `conversation.chat.turnTail` chain，再渲染操作条（复制/插件动作/分支/用量 pill/耗时面板/时钟） | `ui-chat/src/client/chat/TurnTailNodeView.tsx:25-66` |
| 动作揭示 | 最新 Turn 常显，历史 Turn 悬停显示 | `TurnTailNodeView.tsx:41` |
| 数据共享 | 同 Turn 的助手节点可通过 `useTurnData('turn-tail')` 读到该数据（用于 file mentions 归属判断） | `ui-chat/src/client/chat/AssistantNodeView.tsx:13-22` |

### 7.2 deliverables（产出文件行）

| 事实 | 内容 | 来源 |
|---|---|---|
| 不是节点 | `deliverablesDefinition` 只发布 Turn 数据、不产 Node | `ui-deliverables/src/client/turn-deliverables.ts:147-193` |
| 数据来源 | 只认成功的 `write`、`edit`、`str_replace_editor`（且各命令参数完整）的调用参数路径；失败的 tool/result 不计入 | `turn-deliverables.ts:41-98`、`turn-deliverables.ts:162-179` |
| 发布键 | Turn 数据键 `deliverables`，值 `{produced: [{seq,path}]}` | `turn-deliverables.ts:17-26`、`turn-deliverables.ts:180-192` |
| 槽位 | `conversation.chat.turnTail` chain 的一个条目，选择器在无产出时返回 `null`（不挂载） | `ui-deliverables/src/client/index.ts:69-81`、`turn-deliverables.ts:137-145` |
| 行内容 | 标签 + 最多 6 个文件名 chip（`SHOWN_LIMIT = 6`），每个 chip 的 `title`/`aria-label` 是完整路径；余量以「还有 N 个」显示；产出多于 1 且宿主可打开目录时出现「在文件夹中显示」 | `ui-deliverables/src/client/ProducedFiles.tsx:9`、`ProducedFiles.tsx:43-82` |
| 打开能力 | 需要浏览器走 loopback 且 `remote.session.canOpenWorkspacePath()` 为真 | `ProducedFiles.tsx:40-42`、`ui-deliverables/src/client/index.ts:45-60` |
| 正文联动 | 同一批路径作为 inline code 的 link 解析器（`chatFileMentions`），仅当 basename 唯一时解析，避免打开错文件 | `ui-deliverables/src/client/index.ts:84-94`、`turn-deliverables.ts:205-235` |
| 消费的 Turn data | `owner.turn.data.get('deliverables')`，并按 closing seq 过滤更晚的写入 | `turn-deliverables.ts:122-145` |

---

## 8. goal 条、todo 列表与 jobs

三者都不在消息流节点里，分别落在输入 dock 与会话头部。

| 元素 | 位置（slot） | 数据来源 | 显示内容 | 来源 |
|---|---|---|---|---|
| GoalBar | `conversation.input.dock`，条目 `id: 'goal'`、`order: 10` | 投影键 `goal`（`useProjection('goal')`），值形如 `{goal: GoalSnapshot}` | goal 图标 + 阶段标签（active/paused/blocked）+ 目标文本（截断）+ 动作（active→暂停，paused→恢复，编辑，清除）；`undefined`（未就绪）、`null`（无 goal）与 `phase === 'complete'` 均不渲染 | `ui-goal/src/client/index.ts:81-108`、`ui-goal/src/client/GoalBar.tsx:175-186`、`GoalBar.tsx:28-32`、`GoalBar.tsx:77-78`、`GoalBar.tsx:126-166` |
| Goal 编辑形态 | 同一 dock 内的内联输入框（Enter 保存，Escape 取消） | 本地状态 | 输入框 + 保存/取消图标按钮，失败以内联 `role="alert"` 提示 | `GoalBar.tsx:80-124`、`GoalBar.tsx:37-63` |
| TodoPanel | `conversation.input.dock`，条目 `id: 'todo'`、`order: 0` | 投影键 `todos`（`useProjection('todos')`） | 头部：清单图标 + 标题 + 按状态计数的进度串（`done · active · pending`，零计数段省略）+ 折叠箭头；展开后逐项显示状态字形（完成/进行中/待办）与内容；目标为空时不渲染；默认折叠 | `ui-conversation/src/client/skeleton/TodoPanel.tsx:127-139`、`TodoPanel.tsx:88-121`、`TodoPanel.tsx:74-86`、`TodoPanel.tsx:27-72` |
| dock 渲染位置 | `ConversationRoot` 在 composer 卡片上方渲染整条 `conversation.input.dock` | 列表按 order 升序 | 因此 todo（0）在 goal（10）之上 | `ui-conversation/src/client/skeleton/ConversationRoot.tsx:350`、`ui-conversation/src/client/apply.ts:205` |
| 会话统计行 | `conversation.composer.dock`，条目 `id: 'stats'`、`order: 0` | `sessionStats` 投影（缺失时退化到窗口内折叠） | Turn/Step 计数、LLM 与工具墙钟、TTFT、解码吞吐、缓存命中 | `ui-chat/src/client/apply.ts:155-158`、`ui-chat/src/client/chat/StatsLine.tsx:1-3`、`StatsLine.tsx:19-34` |
| Jobs | 会话头部 `conversation.session.header.actions`，条目 `id: 'job-list'`、`order: 20` | `useSessions(state => state.jobsBySession[sessionId])`（列表镜像，插件自身不发 RPC） | 会话无 job 时完全不渲染；有 job 时是触发按钮（运行中显示状态点 + 「N 个运行中/空闲」计数），展开为弹出列表，每行：状态点、`kind`、`label`、`detail ?? 状态词`、时长（运行中按秒刷新，最多两位单位，小时封顶） | `ui-jobs/src/client/index.ts:32-41`、`ui-jobs/src/client/JobListAction.tsx:94-95`、`JobListAction.tsx:120-153`、`JobListAction.tsx:155-180`、`JobListAction.tsx:56-85` |

---

## 9. 消息级操作条

### 9.1 各操作的位置与通道

| 操作 | 位置 | 实现 | 通道/来源 |
|---|---|---|---|
| 复制 | 用户气泡下方与助手 turn-tail 的操作条 | `MessageIconActions` 的复制按钮（写入剪贴板，1 秒对勾反馈） | `ui-chat/src/client/chat/MessageIconActions.tsx:62-89` |
| 时钟 | 同一操作条（用户侧在图标前，助手侧在图标后） | 同日只显示 `HH:mm`，同年显示月日，跨年显示年月日 | `MessageIconActions.tsx:77-81`、`MessageIconActions.tsx:111`、`message-chrome.ts:82-96` |
| 分支（fork） | 仅助手 turn-tail（用户消息不传 `onBranch`） | 按钮触发 `forkAt(closing.finalNode.seq)`；`branchUnavailable` 时保留按钮但 `aria-disabled` 并说明原因 | `TurnTailNodeView.tsx:44-51`、`MessageIconActions.tsx:91-109`、`ui-chat/src/client/apply.ts:142-148` |
| 插件动作（Like/Dislike/备注） | `conversation.chat.assistant-actions`（`list`），插在复制与分支之间 | `extraActions` 位置 | `ui-chat/src/client/chat/TurnTailNodeView.tsx:34-36`、`MessageIconActions.tsx:90` |
| 用量与耗时 | 助手操作条末端 | `TurnUsagePanel`（token 明细 pill）与 `TurnTimePanel`（运行时长、tps、ttft） | `TurnTailNodeView.tsx:52-64` |
| 重试、编辑 | 会话流中没有这两个按钮 | 流内「重试」只是被动的 `model-retry` 折叠行；用户消息操作条不提供编辑 | `MessageItem.tsx:51-115`、`MessageItem.tsx:283-291` |

### 9.2 Like/Dislike 与备注

| 事实 | 内容 | 来源 |
|---|---|---|
| 槽位与条目 | `conversation.chat.assistant-actions`，`id: 'feedback'`，`order: 10`，owner 传 `messageId` | `ui-message-feedback/src/client/index.ts:65-82`、`ui-chat/src/client/contract/slots.ts:216-221` |
| 按钮语义 | 点赞/点踩为 `aria-pressed` 切换按钮；同一评价再点即撤回 | `ui-message-feedback/src/client/MessageFeedbackActions.tsx:97-105`、`ui-message-feedback/src/client/controller.ts:179-185` |
| 备注编辑器 | 已评分时出现备注触发器；点击打开 portal 到 `document.body` 的弹层（260px textarea + 保存/取消），Escape 或点击外部关闭；空备注保存即删除备注 | `MessageFeedbackActions.tsx:262-321`、`MessageFeedbackActions.tsx:288-321` |
| 首次读取时机 | 控件按消息挂载，但列表读取在首次 hover/focus 时触发，一次读取覆盖整个会话 | `MessageFeedbackActions.tsx:62-69`、`controller.ts:110-131` |
| RPC | `remote.messageFeedback.list` / `put` / `delete`，每次带 `ifVersion` 做 compare-and-set，`version-conflict` 用回包里的权威项就地调和 | `controller.ts:221-256`、`controller.ts:266-281` |

### 9.3 `maxNoteBytes: 8192` 的体现

| 层 | 事实 | 来源 |
|---|---|---|
| 配置 | Host 组合（Web bundle）写入 `maxNoteBytes: 8192`；该字段必填 | `packages/bundle/web-app/cordis.patch.yml:55`、`packages/feedback/message-feedback/README.md:34-40` |
| 校验 | 服务端按 UTF-8 字节比较，超限返回 `{code: 'note-too-large', maxBytes, actualBytes}` | `packages/feedback/message-feedback/src/index.ts:353-354`、`src/index.ts:156` |
| 客户端 | 不做输入期预校验，超长备注在保存时失败；客户端把该码翻成「备注过长」类文案 | `packages/client/ui-message-feedback/README.md:75`、`packages/client/ui-message-feedback/src/client/controller.ts:56-65` |
| 文档 | 子系统页说明 8192 是 Web Host 组合的取值，且 `maxNoteBytes` 只限制单条备注 | `docs/subsystems/feedback.md:200`、`docs/subsystems/feedback.md:217`、`docs/subsystems/feedback.md:222` |

---

## 10. Trajectory 视图与 Chat 视图的差异

### 10.1 结构差异

| 维度 | Chat | Trajectory |
|---|---|---|
| Target 名 | `chat` | `trajectory`（`ui-trajectory/src/client/trajectory-contract.ts:55-60`） |
| Definition 集合 | 见第 1 节（17 种渲染 kind） | `trajectory-inbox-next-step`、`trajectory-input-message`、`trajectory-request-header`、`trajectory-assistant-step`、`trajectory-turn-end`、`trajectory-tool-call`、`trajectory-compaction`、`trajectory-session-end`（`trajectory-message-definitions.ts:116`、`:137`；`trajectory-request-header-definition.ts:16`；`trajectory-assistant-definition.ts:406`、`:506`；`trajectory-tool-definition.ts:215`；`trajectory-compaction-definition.ts:81`、`:119`） |
| 节点载荷 | 各业务自定义 Chat data | 统一为 `TrajectoryContribution` 联合（node/assistant/tool/request-header/compaction/session-end/turn-end）（`trajectory-contract.ts:18-52`） |
| 快照 | `ChatSnapshot`（order/nodes/timeline/navigation/locations） | `TrajectorySnapshot{eventNodes,eventLocations,requests,callSchemas,partial,runningCalls}`（`trajectory-contract.ts:63-70`） |
| 视图主体 | 按 Turn/Step 的对话流（气泡、工具卡片、回合尾） | 以请求为单位的台账表格（`TrajectoryTable.tsx`，含请求编号、用量明细 `usage.*`、请求详情面板）与时间线（`TrajectoryTimeline.tsx`，列为输入/模型/工具，见 `TrajectoryTimeline.tsx:195-197`） |
| 工具栏 | 无 | `TrajectoryToolbar`：时长时间线开关、全部折叠/展开 Turn、全部折叠/展开调用、台账搜索框（`TrajectoryToolbar.tsx:38-127`） |
| 图片槽 | `conversation.message.images` | `conversation.trajectory.images`（`ui-trajectory/index.ts:83-85`） |
| 分页 | 常规 `loadOlder` / `loadThrough` | 视图内自己维护历史窗口（每页 50 节点）并调用 `loadOlder`（`TrajectoryView.tsx:34`、`TrajectoryView.tsx:159-174`） |

### 10.2 视图切换

| 步骤 | 事实 | 来源 |
|---|---|---|
| 注册 | Chat 视图注册 `conversation.view` `id: 'chat'`、`order: 0`；Trajectory 注册 `id: 'trajectory'`、`order: 10` | `ui-chat/src/client/apply.ts:94-99`、`ui-trajectory/src/client/index.ts:77-82` |
| Tab 渲染 | 头部在注册数大于 1 时渲染 `role="tablist"`，按钮点击调用 `selectView(viewTab.id)` | `ui-conversation/src/client/skeleton/ConversationSession.tsx:137-152` |
| 选择与激活 | `openView/selectView` → `activateView` → `uiConversation.binding(sessionId).activate(id)`；偏好按 Session 持久化（`readConversationViewPreference`） | `ui-conversation/src/client/apply.ts:133-139`、`apply.ts:245-248`、`ui-conversation/src/client/stores.ts:41` |
| 默认解析 | `resolveActiveView`：优先已存偏好，否则回退 `chat`；两者都未注册时返回 undefined（不渲染） | `ui-conversation/src/client/view-selection.ts:3-17` |
| 焦点跳转 | Chat 内工具卡片的 Inspect 按钮调用 `openView('trajectory', callId)`，切到 Trajectory 并对其聚焦 | `ui-chat/src/client/chat/ChatView.tsx:246-248` |
| 视图请求 | `conversation.view` 的 owner 带 `viewRequest` / `openView` / `completeViewRequest`，供一次性聚焦语义 | `ui-conversation/src/client/contract/slots.ts:202-210` |

---

## 11. 本域 Slot key 清单

cardinality/scope 取自各自 `SlotMap` 声明；declaredBy 为声明该槽的包；占用者为实际注册者。

| slot key | cardinality | scope | declaredBy | 占位者（key/id、order） | 声明处 |
|---|---|---|---|---|---|
| `conversation.view` | list | session | `ui-conversation` | `chat`（ui-chat，order 0）、`trajectory`（ui-trajectory，order 10） | `ui-conversation/src/client/contract/slots.ts:117`；占用 `ui-chat/src/client/apply.ts:96-99`、`ui-trajectory/src/client/index.ts:78-81` |
| `conversation.chat.node` | keyed（按 `ChatNodeKind`） | session | `ui-chat` | 17 个 key：14 个由 ui-chat 注册、`tool-call` 由 ui-tool、`command-input` 由 ui-goal、`workflow-run` 由 ui-workflow-run | `ui-chat/src/client/contract/slots.ts:190-197`；注册 `register-node-renderers.ts:18-57`、`ui-tool/src/client/apply.ts:33-41`、`ui-goal/src/client/index.ts:60-64`、`ui-workflow-run/src/client/index.ts:28-35` |
| `conversation.chat.commandview` | keyed（按命令名） | session | `ui-chat` | 当前无注册者，全部走 `GenericCommandCard` 回退 | `ui-chat/src/client/contract/slots.ts:209`；渲染 `ui-chat/src/client/chat/CommandNodeView.tsx:18-21` |
| `conversation.chat.turnTail` | chain（选择器路由） | session | `ui-chat` | `ui-deliverables`（选择器 `selectProducedFiles`） | `ui-chat/src/client/contract/slots.ts:215`；占用 `ui-deliverables/src/client/index.ts:69-81` |
| `conversation.chat.assistant-actions` | list | session | `ui-chat` | `feedback`（ui-message-feedback，order 10） | `ui-chat/src/client/contract/slots.ts:221`；占用 `ui-message-feedback/src/client/index.ts:66-82` |
| `conversation.message.images` | single | session | `ui-chat` | `ui-attachment` 的 `MessageImages` | `ui-chat/src/client/contract/slots.ts:203`；占用 `ui-attachment/src/client/index.ts:19-22` |
| `conversation.trajectory.images` | single | session | `ui-trajectory` | `ui-attachment` 的 `MessageImages`（同一组件） | `ui-trajectory/src/client/trajectory-contract.ts:95`；占用 `ui-attachment/src/client/index.ts:23-26` |
| `conversation.details.tool` | single | session | `ui-chat` | `ui-tool` 的 `ToolDetails` | `ui-chat/src/client/contract/slots.ts:227`；占用 `ui-tool/src/client/apply.ts:43-47` |
| `details` | single | session | `ui-layout` | `ui-chat` 的 `DetailsPanel`（声明 child `conversation.details.tool`） | `ui-layout/src/client/index.ts:75`；占用 `ui-chat/src/client/apply.ts:163-169` |
| `tool.call.toolview` | keyed（按线上工具名，开放键域） | session | `ui-tool` | 15 个 key：`bash`、`read`、`write`、`edit`、`grep`、`glob`、`web_search`、`web_fetch`、`todo_write`、`ask_user_question`（ui-tool，10 个）、`skill`（ui-skill）、`cordis_define`、`cordis_run`、`cordis_stop`、`cordis_undefine`（ui-cordis，4 个） | `ui-tool/src/client/contract/slots.ts:26`；占用 `ui-tool/src/client/apply.ts:49-55` + 各 toolview `apply`、`ui-skill/src/client/index.ts:69-72`、`ui-cordis/src/client/index.ts:118-146` |
| `tool.view.cordis` | keyed | session | `ui-cordis` | 由动态 Package 以自己的 Client 代码注册，约定 key 为 `'self'`（仓库内无内置占位者） | `packages/extensions/ui-cordis/src/client/slots.ts:31-35`；children 声明 `ui-cordis/src/client/index.ts:129`；渲染点 `ui-cordis/src/client/CordisRunRow.tsx:120` |
| `conversation.approval.detail` | single | session | `ui-approval` | `ui-chat` 的 `ApprovalCommand`（无 key） | `ui-approval/src/client/contract/slots.ts:37-41`；占用 `ui-chat/src/client/apply.ts:160-161` |
| `conversation.composer` | chain（选择器 + priority） | session | `ui-conversation` | `ApprovalPanel`（ui-approval，priority 1）、`QuestionComposer`（ui-user-questions，默认优先级）、`SubagentReadOnlyComposer`（ui-subagent，priority -10） | `ui-conversation/src/client/contract/slots.ts:119`；占用 `ui-approval/src/client/index.ts:80-89`、`ui-user-questions/src/client/index.ts:94-103`、`ui-subagent/src/client/index.ts:73-81` |
| `conversation.composer.bar` | single | session-maybe | `ui-conversation` | `ui-conversation` 自身（`ConversationRoot` 渲染） | `ui-conversation/src/client/contract/slots.ts:137`；children `apply.ts:204` |
| `conversation.input.dock` | list | session | `ui-conversation` | `todo`（ui-conversation，order 0）、`goal`（ui-goal，order 10） | `ui-conversation/src/client/contract/slots.ts:127`；占用 `ui-conversation/src/client/skeleton/TodoPanel.tsx:137-138`、`ui-goal/src/client/index.ts:81-85` |
| `conversation.composer.dock` | list | session | `ui-conversation` | `stats`（ui-chat，order 0） | `ui-conversation/src/client/contract/slots.ts:131`；占用 `ui-chat/src/client/apply.ts:155-158` |
| `conversation.session.header.actions` | list | session | `ui-conversation` | `job-list`（ui-jobs，order 20）；同槽另有 ui-agent-preset、ui-schedule 等条目（不属于本域） | `ui-conversation/src/client/contract/slots.ts:105-109`；占用 `ui-jobs/src/client/index.ts:32-41` |
| `conversation.session.header.lineage` | single | session | `ui-conversation` | `SubagentHeaderLineage`（ui-subagent） | `ui-conversation/src/client/contract/slots.ts:99-103`；占用 `ui-subagent/src/client/index.ts:65-72` |
| `conversation.session` / `conversation.session.header` | single | session | `ui-conversation` | ui-conversation 自渲染 | `ui-conversation/src/client/contract/slots.ts:95`、`:97`；渲染 `ConversationRoot.tsx:374-377` |

---

## 12. 源码未明确 / 不存在的项

| 问题点 | 结论 |
|---|---|
| 工具卡片的耗时显示 | 卡片模型与 props 都没有耗时字段，耗时只在 turn-tail 的 `TurnTimePanel`（`ToolRow.tsx:25-68`、`TurnTailNodeView.tsx:52-64`） |
| 会话流中的「重试」「编辑」按钮 | 不存在。用户消息操作条只有时钟与复制（`MessageItem.tsx:283-291`）；助手侧只有复制、插件动作、分支、用量（`TurnTailNodeView.tsx:44-66`）。队列中的待发消息编辑在 `conversation/queue/QueueDock.tsx`，属于输入域 |
| 客户端侧工具结果 spill 实现 | 无。客户端只渲染结果文本里 Host 写入的 `spill://` 定位串（`search-card-model.ts:88-99`、`ui-settings-plugins/src/client/locales.ts:45`） |
| `subagent` / `workflow` 的 keyed toolview | 不存在。subagent 的表现是头部血缘 + composer 接管；workflow 是独立 chat node（`workflow-run`） |
| `fs`、`cordis` 以外的业务定制 toolview | 本域内仅列于 3.3 的那些 key；其余工具走 generic 行 |
| 审批的 diff 预览 | 源码只提供 `conversation.approval.detail` 子槽与 ui-chat 的「命令文本」占位者，没有内建 diff 视图 |
| `tool.view.cordis` 的内置占位者 | 仓库内没有默认注册；由动态 Package 的 Client 代码注册 key `'self'`（`ui-cordis/src/client/slots.ts:24-35`） |

---

## 13. 关键聚合点（便于继续追查）

| 关注点 | 单一来源 |
|---|---|
| Definition 注册与唯一性校验 | `ui-conversation/src/client/conversation/event-registry.ts:13-43`、`definition-registry.ts:43-61` |
| 视图注册表 | `ui-conversation/src/client/conversation/view-registry.ts:12-19` |
| Chat 快照构建与顺序 | `ui-chat/src/client/conversation-nodes/chat-snapshot-builder.ts:401-413`、`:753-841` |
| Chat 节点分发 | `ui-chat/src/client/chat/ChatNodeSeat.tsx:124-148` |
| 工具卡片分发 | `ui-tool/src/client/tool/ToolCallTree.tsx:14-47` |
| 图片缓存接线 | `ui-conversation/src/client/conversation/assembly.ts:171-260` |
| 视图切换与偏好 | `ui-conversation/src/client/apply.ts:121-173`、`view-selection.ts`、`stores.ts:41` |
