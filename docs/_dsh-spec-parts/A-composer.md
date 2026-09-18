# A — 会话输入区（composer / input dock）源码规格

- 源码根：`third_party/deepseek-harness`（tag `dsh-v0.1.2-rc.1`，commit `a66e4702047846cdaa10c66c9d3df3951f5ea70d`）
- 本文所有路径相对源码根；所有行号取自当前签入源码。
- 只读分析，未修改源码根下任何文件。
- 文中「源码未明确」= 在相关包源码与签入注释中未找到该事实。

---

## 1. 输入区视觉构成

### 1.1 挂载骨架（谁在哪个槽位渲染什么）

输入区不是单一组件，而是 **一个 resident 外壳 + 一组槽位** 的合成产物。

| 视觉元素 | 渲染者 | 槽位 key | 数据来源 |
|---|---|---|---|
| 输入区整段（hero / active 定位、sticky、宽度手柄） | `ConversationRoot`（ui-conversation） | 声明 `conversation.composer`(chain)、`conversation.composer.bar`、`conversation.input.dock` | `renderSlotChain('conversation.composer', …, { fallback: composerBar, fallbackOnly: sessionId === undefined, overlay: true })`（`packages/client/ui-conversation/src/client/skeleton/ConversationRoot.tsx:356`） |
| 输入框卡片（capsule） | `InputBar`（默认 bar 条目） | `conversation.composer.bar` | `InputBar.tsx:387-393`（`data-composer-card`） |
| 文本编辑区 | `ComposerContentEditable`（Lexical root 绑定） | 无槽位，bar 内部 | `InputBar.tsx:415-430`；组件 `packages/client/ui-conversation/src/client/input/editor/ComposerContentEditable.tsx:37-48`（`role="textbox"`、`aria-multiline="true"`、`data-composer-input`） |
| 占位符文本 | `InputBar` 自绘 div（`empty && !claimActive` 时） | 无槽位 | `InputBar.tsx:431-435`（`data-composer-placeholder`，文案经 `aria-label` 同时供无障碍） |
| 引用 chip（`@` 引用） | `ReferenceChipNode.decorate()` → `ReferenceChip` → `DecoratorPortals` portal | 无槽位 | `packages/client/ui-conversation/src/client/input/editor/chip-node.tsx:187-195`、`ReferenceChip.tsx:26-35`、`DecoratorPortals.tsx:23-40` |
| 命令 token 高亮（claimed 态首 token 变 warn 色） | Lexical `TextNode` transform（纯装饰） | 无槽位 | `packages/client/ui-conversation/src/client/input/editor/claim-decor.ts:28-51` |
| 文本型引用装饰（`/name`、`@name`、`@dir/`） | `registerTextRefDecoration`（`text-ref.ts`） | 无槽位 | 扫描规则 `packages/client/ui-conversation/src/client/input/decorations.ts:24-63` |
| 附件 chip / 缩略图 rail | `ui-attachment` 的 `ComposerAttachments` | `conversation.input.attachments`（single, session-maybe） | 注册 `packages/client/ui-attachment/src/client/index.ts:15-18`；渲染 `ComposerAttachments.tsx:89-116`（`AttachmentRail` + `DropOverlay` + `ImageLightbox`） |
| 拖放覆盖层 | `ComposerAttachments` 的 `DropOverlay` | 无槽位（document 级 drag 监听） | `ComposerAttachments.tsx:30-79, 91-96` |
| 浮层（命令/引用候选菜单、popupSelect、审批浮层锚点） | `renderSlot('conversation.input.overlay')` 容器 | `conversation.input.overlay`（list, session） | 容器 `InputBar.tsx:394-396`；填充者见 §6.3 |
| 提交/停止按钮 | `InputBar` | 无槽位 | `InputBar.tsx:469-504`（`interruptible` 独立 Stop 按钮；主按钮 label `input.stop` / `input.send`，`primaryStops` 时显示方块停止图标） |
| 「指令」按钮（打开命令菜单） | `InputBar`（`IconPlusOutline16`，`aria-haspopup="listbox"`） | 无槽位 | `InputBar.tsx:441-454` |
| 队列 dock | `QueueDock`（ui-conversation queue 域） | `conversation.input.dock`（list, session, id `queue`, order 20） | 注册 `packages/client/ui-conversation/src/client/queue/QueueDock.tsx:294-315`；渲染位置 `ConversationRoot.tsx:350` |
| Todo 面板 | `TodoDock` / `TodoPanel`（ui-conversation skeleton 域） | `conversation.input.dock`（id `todo`, order 0） | 注册 `packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:133-139` |
| Goal 条 | `GoalDock` / `GoalBar`（ui-goal） | `conversation.input.dock`（id `goal`, order 10） | 注册 `packages/client/ui-goal/src/client/index.ts:81-108`；渲染 `GoalBar.tsx:127-168`（goal glyph + phase label + objective + pause/resume/edit/clear） |
| 权限选择器 | `PermissionSelect`（ui-conversation，**声明位于 ui-permission-presets 包的类型**） | 无槽位，`InputBar` 直接渲染 | `InputBar.tsx:331-333`；组件 `packages/client/ui-conversation/src/client/skeleton/PermissionSelect.tsx:86-193`；值来自 `useProjection('permissions')`（`InputBar.tsx:109`） |
| 模型选择器 | `ModelSelect`（ui-model-selection） | `conversation.input.model`（single, session） | 注册 `packages/client/ui-model-selection/src/client/index.ts:161-178`；渲染 `InputBar.tsx:467` |
| Plan 开关（chip） | `PlanChip`（ui-plan） | `conversation.input.plan`（single, session） | 注册 `packages/client/ui-plan/src/client/index.ts:55-67`；渲染 `InputBar.tsx:457`；组件 `PlanModeControl.tsx:19-68` |
| 上下文占用 meter（环 + 面板） | `ContextMeter`（ui-conversation） | 无槽位，`InputBar` 直接渲染 | `InputBar.tsx:468`；组件 `packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx:55-167` |
| 输入提示条（`css.notice`，role=status） | `InputBar`（`notice.level === 'info'`） | 无槽位 | `InputBar.tsx:377-381` |
| 错误 toast（banner） | `InputBar`（`Toast`） | 无槽位 | `InputBar.tsx:368-376`；来源见 §1.3 |
| 卡片下方 ambient 行（统计）+ 输入 dock 下方 slot 区 | `renderSlot('conversation.composer.dock')` | `conversation.composer.dock`（list, session） | 容器 `InputBar.tsx:508-510`；条目 `StatsLine`（ui-chat，id `stats`，order 0）注册于 `packages/client/ui-chat/src/client/apply.ts:155-158` |
| 测试/自动化锚点 | — | — | `data-composer-card`（`InputBar.tsx:390`）、`data-input-scroll`（413）、`data-composer-placeholder`（432）、`data-composer-chip`（`chip-node.tsx:121`）、`data-queue-dock`（`QueueDock.tsx:120`）、`data-goal-bar`（`GoalBar.tsx:82,128`）、`data-composer-seat`（`ConversationRoot.tsx:367`）、`data-submission-echo`（`QueueDock.tsx:270`）、`data-question-key`（`packages/client/ui-user-questions/src/client/QuestionComposer.tsx:279`） |

**声明与渲染分离**（重要）：`conversation.input.dock` 的**渲染点在 `ConversationRoot`**（`ConversationRoot.tsx:350`），它位于输入卡片**上方**；而 `conversation.input.attachments` / `overlay` / `plan` / `model` / `left` / `right` / `composer.dock` 的声明与渲染都在 `conversation.composer.bar` 的 `children` 里（`packages/client/ui-conversation/src/client/apply.ts:271-282`，渲染于 `InputBar.tsx`）。

### 1.2 占位符与提示文案

`InputBar` 的 placeholder 优先级链（`InputBar.tsx:355-364`）：

1. owner prop `placeholder`（hero / 无 workspace / blocked reason 由 `ConversationRoot` 传入，`ConversationRoot.tsx:329-344`）
2. `parentOffline` → `placeholder.parentOffline`
3. `disabled` → `placeholder.unavailable`
4. `canSteerQueue` → `placeholder.steerQueue`
5. `planActive` → `placeholder.plan`
6. 默认 → `placeholder.default`

中文文案（`packages/client/ui-conversation/src/client/locales.ts:15-21`）：`发消息或做任务… / 调用指令 @ 文件或对话`、`描述你想要构建的内容… / 调用指令 @ 文件或对话`、`选择一个工作区开始`、`Cmd/Ctrl+Enter 插话发送全部排队消息`。

claim ghost hint：claimed 且 token 后无参数时，把 `claim.hint`（或词典 `hint.<command>`，如 `hint.goal` / `hint.plan` / `hint.goal.active`）写入 CSS 变量 `--dsh-composer-hint`（`InputBar.tsx:338-353, 429`）。

### 1.3 错误面

| 来源 | 通道 | 位置 |
|---|---|---|
| 机器 notice（level=error） | Toast | `InputBar.tsx:101-103`（`useEffect` 把 `notice` 送 `showToast`） |
| 机器 notice（level=info） | 行内 `css.notice` | `InputBar.tsx:377-381` |
| `session.promptError` | Toast；`session/attachment-invalid`、`subagent/attachment-invalid` 走产品文案 | `InputBar.tsx:94-100` |
| 图片 intake 预检拒绝 | Toast（格式优先于数量/体积） | `InputBar.tsx:220-245` |

### 1.4 输入区被「接管」的两种形态

- **owner block**：任何插件经 `ctx.conversation.blocks.set(sessionId, { reason })` 把某会话输入变惰性；`ConversationRoot` 读 `composerBlock` 并以 `blocked` prop 下发（`ConversationRoot.tsx:328, 338-342`）。registry 实现见 `packages/client/ui-conversation/src/client/input/blocks.ts:20-44`，契约见 `contract/composer-blocks.ts:5-29`。已知使用者：ui-model-selection（blockReason `blocked.composer`，`ui-model-selection/src/client/index.ts:121`）。此时**模型 seat 仍可交互**（`InputBar.tsx:125`：`modelSeatLocked = removed || inert || !live`）。
- **chain takeover**：`conversation.composer` 是 chain 槽，审批/提问面板按 selector 接管整块输入区，见 §6.4。

### 1.5 无 session / 无 workspace 的 inert 形态

同一 DOM 树保持驻留：`workspaceTrigger = inert && !removed && onRequestWorkspace !== undefined`（`InputBar.tsx:131`），此时 editable div 变成工作区选择器触发器（`aria-haspopup="menu"`、Enter/Space 触发 `onRequestWorkspace`，`InputBar.tsx:304-310, 424-428`）。

---

## 2. 输入能力矩阵

### 2.1 纯文本提交

- 草稿文本真相在 shell 拥有的 Lexical 编辑器（`packages/client/ui-conversation/src/client/input/facade.ts:174-186`）；发布态是三层投影：`detectText`（chip 记为 U+FFFC）、`clipboardText`（chip 展开为 clipboardText）、以及 chip occurrence 列表（`packages/client/ui-conversation/src/client/input/editor/projection.ts:54-131, 196-229`）。
- 提交入口：`InputActions.submit()` → `SessionInputShell.submit('queue')`（`facade.ts:136-142, 360`；契约 `contract/input.ts:221-232`）。
- 机器判定：空行 no-op；`/` 开头进入 adjudicating；claimed 进入 begin-submit；其余走 detached default sink（`machine.ts:139-154`）。
- 发送 commit：清空草稿 + 切断 undo 历史（`facade.ts:662-677`）。纯文本后缀在 Host 往返期间**保留**（`retainSuffixOf` 快照，`machine.ts:132-137`、`facade.ts:666-671`）。
- 失败恢复：失败 send 的草稿快照按提交序重建（含 chip 节点）并回滚图片（`facade.ts:757-832`）。

### 2.2 斜杠命令 `/`

| 环节 | 机制 | 来源 |
|---|---|---|
| 触发检测 | `track(draft, caret, guard, draftRev)` 调 `detectTrigger`；无 hit 则关菜单 | `InputBar` → `facade.ts:246-250` → `ui-input-trigger/src/client/controller.ts:104-135` |
| 可用性 tier | `plain`（`/`、`@` 均活）、`claimed`（`/` 抑制、`@` 活）、`frozen`（全禁）；由 `guardOf(phase)` 派生 | `facade.ts:82-88`；语义 `ui-input-trigger/src/types.ts:218-222` |
| 候选列举 | host 目录（`commands/list`）+ 客户端 contribution，按 `available()` 过滤后模糊排序 | `ui-commands/src/client/service.ts:250-269`（`fuzzyCandidates` 同文件 108-120） |
| 菜单渲染 | `MenuView` 注册进 `conversation.input.overlay`（id `slash-menu`, order 0） | `ui-input-trigger/src/client/index.ts:65-85` |
| 键盘仲裁 | ↑/↓/Esc/Tab/Enter 由 `arbitrate` 处理；Enter 无 highlight 时下传提交 | `controller.ts:223-267`；keymap `editor/keymap.ts:85-129` |
| 空格判定 | `onSpace()` 轮询各源 `matchSpace`（同步热态），首个非 undefined 胜 | `controller.ts:275-288` |
| Enter 判定 | `adjudicate()` → 各源 `matchEnter(…, envelope)`，可 await 预热；首个非 undefined 胜 | `facade.ts:835-853`；`ui-commands/src/client/service.ts:319-364` |
| 执行 | `command.execute` transaction → `commands/execute` RPC；成功即清草稿并释放已消费图片 | `ui-commands/src/client/service.ts:400-415`；`facade.ts:862-895` |
| 纯文本命令（无 input 描述） | 菜单 pick / 裸 Enter 直接 detached 执行，先消费 trigger span | `ui-commands/src/client/service.ts:292-294, 361-363` |
| 空 draft 加速 Enter | 若有 queued 行则改走 `steerQueue()` 而非提交空草稿 | `InputBar.tsx:266-280`、`facade.ts:415-417`、`hub.ts:198-208` |

命令面还有**客户端 contribution / decoration** 两条注册路径（`register` / `decorate`），见 `ui-commands/src/client/service.ts:171-199`；`/permission` 与 `/model` 分别用 decoration 与 contribution 打开 popupSelect（`ui-permission-presets/src/client/index.ts:145-166`、`ui-model-selection/src/client/index.ts:130-154`）。

### 2.3 `@` 引用

- **唯一 `@` 源**：`ui-reference`，`trigger: '@'`, `name: 'reference'`, `showGroupTitle: false`（`packages/client/ui-reference/src/client/index.ts:44-114`）。
- 引用对象两类：**文件/目录**（`remote.fileReferences.list(sessionId, query, signal)`）与**会话**（`remote.sessionReferenceResolver.candidates(...)`；quoted 时不出会话行）（`ui-reference/src/client/index.ts:48-56`）。
- chip 插入：`onPick` 返回 `{ insert: { source, ref, label, appearance, clipboardText } }`；`appearance` 为 `file` / `folder` / `session`（`ui-reference/src/client/index.ts:77-108`）。
- 插入落点：`slash/input-insert-reference` 事件 → `SessionInputShell.insertReference` → 编辑器以 chip 节点替换 span，并补一个分隔空格（`facade.ts:493-506`）。
- 序列化：`codec.serialize(ref)` 即恒等返回 ref（`ui-reference/src/client/index.ts:110-113`）；`clipboardText` 亦为 ref。
- 目录行的 drill（Tab / chevron / 面包屑）返回 `{ text, continue: true }`，保留字面降级文本（`ui-reference/src/client/index.ts:84-86`）。
- **skill 不是 `@` 引用**：`ui-skill` 是 `/` 源，pick 落普通文本 `/name `（`packages/client/ui-skill/src/client/index.ts:137-182`），chip 视觉来自 lexicon 扫描，不走 chip 节点。

### 2.4 附件（图片）

| 环节 | 事实 | 来源 |
|---|---|---|
| 支持类型 | `image/png`、`image/jpeg`、`image/webp`、`image/gif` | `packages/client/ui-conversation/src/client/service.ts:403-413`；契约 `contract/input.ts:25` |
| 加入路径 1：粘贴文件 | `PASTE_COMMAND` 里取 `clipboardData.items` 的 file 项 | `editor/keymap.ts:130-149` |
| 加入路径 2：拖放 | document 级 `dragenter/dragover/dragleave/drop`，`canAcceptDrop` 时才 `onAddImages` | `ComposerAttachments.tsx:30-79` |
| 加入路径 3：`conversation.input.attachments` owner 回调 | `onAddImages` = `intakeImages`（限额预检） | `InputBar.tsx:398-407` |
| 限额预检 | 格式优先；再查 `maxImagesPerMessage` / `maxImageBytes` / `maxMessageImageBytes`；拒绝时整批不入 rail 并 Toast | `InputBar.tsx:220-245`；`imageLimits` 来自 host projection（`InputBar.tsx:85`） |
| 注册 | `conversation.createDraftImages(files)` 生成 browser-owned 描述符（`URL.createObjectURL` + 异步尺寸探测） | `service.ts:68-93, 255-263` |
| 状态 | 只有有序 id 进 `InputState.imageIds` | `facade.ts:285-316`；契约 `contract/input.ts:321-335` |
| **无独立上传路由** | 图片以 base64 内联进 `session/prompt` 的 `PromptContentPart[]`；序列化用 `FileReader` dataURL | `service.ts:118-131, 199-248, 388-400` |
| 读取已有图片 | `session/attachment`（`session.readAttachment`），客户端封装 `ctx.uiConversation.imageUrl` | `packages/api/session-controller/src/client/sessions/session.ts:290`；`ui-conversation/apply` 之外的使用见 `QueueDock.tsx:311` |
| 命令带图 | 仅 claim 声明 `images: true` 的命令接收；否则一条 notice 且草稿与图片全保留 | `facade.ts:386-390`；`ui-commands/src/client/service.ts:332-360`（`refuseImages`） |
| 图片-only 发送 | 空 draft + 有图 → 独立 image flight，成功 `send-committed`，失败回滚 rail | `facade.ts:361-381, 220-224` |
| 引用生命周期 | 成功发送后移出 registry；预览 URL 交给 durable image cache 或 revoke | `service.ts:371-386` |

### 2.5 键盘行为（完整 keymap）

注册于 `packages/client/ui-conversation/src/client/input/editor/keymap.ts:54-150`，全部 `COMMAND_PRIORITY_CRITICAL`（先于 `@lexical/plain-text` 默认行为）。

| 手势 | 行为 | 行号 |
|---|---|---|
| `Enter` | 有菜单 highlight → pick；否则提交；`event.repeat` 时吞掉（防连发）；`canSubmit()` false 时吞掉 | 109-129 |
| `Ctrl/Cmd+Enter` | 提交但 gesture = `accelerated`（交付模式与普通 Enter 互为反面） | 127；`submission-policy.ts:49-58` |
| `Shift+Enter` | **无条件**放行给原生换行（先于 IME 守卫判定） | 112 |
| `↑` / `↓` | 菜单移动高亮；无菜单放行 | 85-86, 69-76 |
| `Tab` | 菜单有 highlight 时 pick（drill 候选走 drill）；否则放行原生焦点遍历 | 89, 251-265 |
| `Esc` | 先关 popup，再让菜单 consume；claimed 无浮层时 **不**释放 claim（唯一退出是退格 token） | 90-99 |
| `Space` | 走 `onSpace()` 判定；应用了 claim/insert 才 preventDefault | 100-108, `facade.ts:423-429` |
| 粘贴 | 有 file → intake；有 text → `pasteText`（占位符消毒后插入，独立 undo 边界） | 130-149, `facade.ts:337-352` |
| IME 守卫 | `isComposing` 或 keyCode 229 或 compositionend 后 10ms 窗口（Safari 迟到的 closing keydown） | 42-46, 55-67 |
| 空 draft + 加速 Enter + 运行中 + 有排队 | `steerQueue()`（插话发送全部排队消息） | `InputBar.tsx:266-280` |

Bar 级前置门：`gate.current = { locked, machineBusy, canSteerQueue, running, subagent, resolveSubmitMode, intakeImages }`（`InputBar.tsx:251-254`），`registerComposerKeymap` 只在 `[editor, keyboard]` 变化时重注册（`InputBar.tsx:256-287`）。
`Ctrl/Cmd+Enter` 提示出现在 placeholder `placeholder.steerQueue`（`locales.ts:21,171`）。

### 2.6 提交时的结构（block）

- **提交不给 block 结构**（源码未明确 block 数组出现在 composer 侧）。提交事实是：
  - `session/prompt` 参数类型 `PromptContentPart[]`，由 `[...uploadedImages, { type:'text', text }]` 组成（`service.ts:212-213, 235-244`；类型见 `packages/api/session-controller/src/types.ts`）。
  - 图片 part 为 `{ type:'image', mediaType, data, name? }`（`service.ts:389-400`）。
- **输入侧的「结构」是 occurrence 列表**：`Occurrence { occurrenceId, source, ref, offset, length, label, appearance?, clipboardText, invalid? }`（`contract/input.ts:299-318`），提交前按 clipboard 偏移把 chip 替换为 owner codec 的 model 文本（`facade.ts:685-732`；偏移拼接在 711-724）。
- `ComposerBlock`（`contract/composer-blocks.ts:5-8`）是**惰性原因**，与提交结构无关。
- 队列行内容为 wire block 数组：`{ type:'text' }` / `{ type:'image', attachment }`（`queue/QueueDock.tsx:29-35, 114`）。

### 2.7 队列（排队 / 编辑 / 删除 / 立即插话）

- 队列数据源：`session.getSnapshot().queue`（authoritative session 快照），经 `queueReadFaceOf` 变成裸 observable 叠到 `InputState.queue`（`input/queue-store.ts:20-24`；契约 `contract/queue.ts:1-11`）。
- 队列 dock 只渲染 `placement === 'queued'` 的行，并把未落地的 `pendingSubmissions`（本地 echo）追加显示（`queue/QueueDock.tsx:65-87, 269-286`）。
- 折叠行为：1 行直接显示，多行默认折叠为计数表头；`rowCount === 0` 返回 null（`QueueDock.tsx:87-91, 122-137`）。
- 编辑：inline `input`，Enter 保存 / Esc 取消；`row.text === null` 的行禁编辑并给 `title` 说明（`QueueDock.tsx:145-163, 212-227`）。
- 删除：`{ kind:'remove' }`。插话：`{ kind:'steer' }`，仅在 `running` 时可用（`QueueDock.tsx:234-262`）。
- 队列可变性：`queueMutable = session.subagent === null`（`QueueDock.tsx:76`）。
- 整队插话：`InputHub.steerQueue` 对全部 queued 行依次 `{ kind:'steer' }`，`session/steer-unavailable` 与 `session/queue-item-not-found` 静默收敛，其它错误出一条 `queue.steerFailed`（`input/hub.ts:198-208`；文案 `locales.ts:143,293`）。

### 2.8 中断 / 停止生成

- Stop 按钮出现条件：`interruptible = running && continuable`（continuable 子会话时与主按钮并存，`InputBar.tsx:316, 469-484`）。
- 主按钮变停止的条件：`primaryStops = running && subagent === null && (empty || blocked !== undefined)`（`InputBar.tsx:315`）。
- 动作：`stop()` = 会话作用域 `conversation.cancel()` → `session/cancel`（`apply.ts:339-343`；`service.ts:327-331`）。
- 客户端侧取消：`SubmitMachine.onRelease` abort 掉 frozen 与全部 detached attempt（`machine.ts:226-236`）；scope disposer 走 `shell.dispose()`（`facade.ts:569-587`）。

### 2.9 权限 / 模型 / plan / goal 的操作面

| 操作 | UI 面 | 底层路径 |
|---|---|---|
| 切换权限预设 | `PermissionSelect` 菜单 → `command('/permission <id>')` | `PermissionSelect.tsx:119-124` → `InputBar` inject `command` → `session.command(line)` → `commands/execute`（`apply.ts:344-349`） |
| Full access 风险确认 | `RiskConfirmation` 需勾选 acknowledge 才确认 | `PermissionSelect.tsx:126-147, 177-190` |
| 切换模型 | `ModelSelect` seat（`ModelDirectory.select`）或 `/model` popup | `ui-model-selection/src/client/directory.ts:88-110` → `session/selectModel`；模型目录 `session/modelCatalog`（`catalog.ts:45`） |
| 进入 plan 模式 | **无独立开关**：经命令源 `/plan`；chip 只负责退出 | `ui-plan/src/client/index.ts:1-9`；退出执行 `/plan off`（同文件 60-65） |
| 目标编辑/暂停/继续/清除 | Goal 条 icon 按钮 | `remote.goals.edit/pause/resume/clear`，CAS ref 调用时从 `projections.faceOf('goal')` 读（`ui-goal/src/client/index.ts:69-107`） |

---

## 3. 每个操作触发的 RPC

### 3.1 RPC 方法名（Host `@Remote` 名）

| RPC 名 | Host 声明位置 | 输入区调用点 |
|---|---|---|
| `session/prompt` | `packages/api/session-controller/src/index.ts:326` | `session.prompt(content, mode, signal, requestId)`（`session.ts:242`），入口 `ConversationController.sendSession`（`service.ts:199-248`）、`send`（`service.ts:179-183`） |
| `session/updateQueue` | `packages/api/session-controller/src/index.ts:347` | `session.updateQueue(itemId, action)`（`session.ts:302`）→ `conversation.updateQueue`（`service.ts:314-324`）、`hub.steerQueue`（`hub.ts:202`） |
| `session/cancel` | `packages/api/session-controller/src/index.ts:357` | `session.cancel()`（`session.ts:320`）→ `apply.ts:340`（Stop 按钮） |
| `session/attachment` | `packages/api/session-controller/src/index.ts:337` | `session.readAttachment`（`session.ts:290`）→ 图片 URL 解析（`QueueDock.tsx:311` 的 `ctx.uiConversation.imageUrl`） |
| `session/selectModel` | `packages/api/session-controller/src/index.ts:244` | `ModelDirectory.select`（`ui-model-selection/src/client/directory.ts:92`） |
| `session/modelCatalog` | `packages/api/session-controller/src/index.ts:253` | `ModelCatalogDirectory`（`ui-model-selection/src/client/catalog.ts:45`） |
| `commands/list` | `packages/interaction/commands`（服务 `commands`，客户端经 `ctx.remote.commands.list`） | `ui-commands/src/client/service.ts:142` |
| `commands/execute` | 同上 | `ui-commands/src/client/service.ts:405`；`ui-plan/src/client/index.ts:61`；`session.command`（`session.ts:353`）；`ui-permission-presets/src/client/index.ts:161` |
| `goals/edit` / `goals/pause` / `goals/resume` / `goals/clear` | `packages/goal/goal/src/index.ts:326,349,361,430` | `ui-goal/src/client/index.ts:90,95,100,105` |
| `skills/list` | 由 `SessionSkillCatalog` 以命名空间 `skills` 注册（`packages/api/session-controller/src/skill-catalog.ts:20-36`） | `ui-skill/src/client/index.ts:101`（`ctx.remote.skills.list`） |
| `fileReferences/list` | 由 `SessionFileReferences` 以命名空间 `fileReferences` 注册（`packages/api/session-controller/src/file-references.ts:18-38`；底层服务 `packages/context/file-reference/src/index.ts:21-28`） | `ui-reference/src/client/index.ts:49`（`ctx.remote.fileReferences.list`） |
| `sessionReferenceResolver/candidates` | `packages/context/session-reference/src/index.ts:92`（服务 `sessionReferenceResolver`），`@Remote('candidates')` 见同文件 `:250` | `ui-reference/src/client/index.ts:53` |

### 3.2 会话对象面（`SessionFace`）→ 上行调用

| `SessionFace` 方法 | 客户端实现调用的 Remote | 声明 |
|---|---|---|
| `prompt` | `remote.session.prompt` 或 `remote.subagents.prompt`（subagent 会话分支） | `packages/api/session-controller/src/client/sessions/session.ts:242, 250` |
| `updateQueue` | `remote.session.updateQueue` | `session.ts:302` |
| `cancel` | `remote.session.cancel` 或 `remote.subagents.interruptByParent` | `session.ts:315-320` |
| `command` | `remote.commands.execute` | `session.ts:353` |
| `beginSubmission` | 纯本地（注册 echo，无 RPC） | `sessions/session.ts` 内；契约 `client/contract/session.ts:74` |

### 3.3 客户端服务 / 事件面（非 RPC 但驱动输入区）

| 调用 | 用途 | 来源 |
|---|---|---|
| `ctx.conversation.input.for(actx).notify(level, text)` | 命令准入失败、插话失败落到本会话 composer notice | `ui-commands/src/client/service.ts:472-478`；`QueueDock.tsx:310` |
| `actx.bail(actx, 'slash/input-consume-token', { guard })` | 命令执行后消费 token/span | `ui-commands/src/client/service.ts:461-469`；popup 版本 216-223 |
| scoped events `slash/input-begin-command` / `slash/input-insert-reference` / `slash/input-consume-token` / `slash/input-insert-text` | 输入机写入原语（bail 语义） | 声明 `contract/input.ts:136-163`；监听注册 `input/hub.ts:111-129` |
| `ctx.remote.$on('commands/change')` | 命令目录软失效 | `ui-commands/src/client/service.ts:157` |
| `ctx.remote.$on('agent-preset/selected')` | 命令目录 / skill 目录按会话重置 | `ui-commands/src/client/service.ts:161`；`ui-skill/src/client/index.ts:186` |
| `ctx.on('connection/reset')` | 命令目录硬重置、skill 全清 | `ui-commands/src/client/service.ts:162`；`ui-skill/src/client/index.ts:187` |
| `ctx.remote.$on('approval/request')` / `('user-questions/request')` | 审批/提问请求进入 pendingInteraction → 接管 composer 链 | `ui-approval/src/client/index.ts:90-92`；`ui-user-questions/src/client/index.ts:104-106` |
| `ctx.events.dispatch('emit', ['command/executed', …])` | 本机命令执行确认（本地事件） | `ui-commands/src/client/service.ts:417-432` |

设置面：busy-Enter 偏好写 Host user-settings（`ComposerSubmissionPolicy.setBusyEnter` → `settingsScope.set(BUSY_ENTER_FIELD, …)`，`input/submission-policy.ts:65-69`；namespace `ui-conversation`，字段 `busyEnter`，取值 `queue|steer`，默认 `queue`，`src/submission-settings.ts:6-18`）。

---

## 4. Slot key 清单（本域）

声明位置：`packages/client/ui-conversation/src/client/contract/slots.ts:92-148`（`SlotMap` 合并）；渲染期 children 声明：`apply.ts:197-234`（root）、`236-250`（session）、`252-269`（header）、`271-357`（composer bar）。

| slot key | cardinality | scope | 声明者（declaredBy） | 渲染位置 | 本域条目 |
|---|---|---|---|---|---|
| `conversation.composer` | `chain` | `session` | ui-conversation（`apply.ts:203`） | `ConversationRoot.tsx:356-360`（`renderSlotChain`） | ui-approval（priority 1，`ui-approval/src/client/index.ts:80-89`）、ui-user-questions（`ui-user-questions/src/client/index.ts:94-103`） |
| `conversation.composer.bar` | `single` | `session-maybe` | ui-conversation（`apply.ts:204`） | `ConversationRoot.tsx:329-344` | `InputBar`（ui-conversation 自身，`apply.ts:271-357`） |
| `conversation.composer.dock` | `list` | `session` | ui-conversation（`apply.ts:281`） | `InputBar.tsx:508-510` | ui-chat `stats` order 0（`ui-chat/src/client/apply.ts:155-158`） |
| `conversation.input.dock` | `list` | `session` | ui-conversation（`apply.ts:205`） | `ConversationRoot.tsx:350`（owner = `InputZone` = `{ session, input }`，`slots.ts:196-200`） | todo order 0（`TodoPanel.tsx:137-138`）、goal order 10（`ui-goal/src/client/index.ts:81-108`）、queue order 20（`queue/QueueDock.tsx:298-314`） |
| `conversation.input.overlay` | `list` | `session` | ui-conversation（`apply.ts:276`） | `InputBar.tsx:394-396` | slash-menu order 0（`ui-input-trigger/src/client/index.ts:65-85`）、command-popup order 1（`ui-commands/src/client/index.ts:64-74`） |
| `conversation.input.left` | `list` | `session` | ui-conversation（`apply.ts:277`） | `InputBar.tsx:459-461` | 未在源码中找到本仓库内的注册者 |
| `conversation.input.right` | `list` | `session` | ui-conversation（`apply.ts:279`） | `InputBar.tsx:463-466` | 未在源码中找到本仓库内的注册者 |
| `conversation.input.plan` | `single` | `session` | ui-conversation（`apply.ts:278`） | `InputBar.tsx:457` | ui-plan（`ui-plan/src/client/index.ts:55-67`） |
| `conversation.input.model` | `single` | `session` | ui-conversation（`apply.ts:280`） | `InputBar.tsx:467` | ui-model-selection（`ui-model-selection/src/client/index.ts:161-178`） |
| `conversation.input.attachments` | `single` | `session-maybe` | ui-conversation（`apply.ts:275`） | `InputBar.tsx:398-407`（owner = `ComposerAttachmentsOwnerProps`） | ui-attachment（`ui-attachment/src/client/index.ts:15-18`） |
| `conversation.approval.detail` | `single` | `session` | **ui-approval**（`ui-approval/src/client/contract/slots.ts:35-42`） | `ApprovalPanel.tsx:16` | ui-chat `ApprovalCommand`（`ui-chat/src/client/apply.ts:160-161`） |
| `settings.general.item`（本域相关条目） | `list` | 根 | ui-settings-general | 设置页 | ui-conversation `composer-enter` order 20（`apply.ts:110-119`）、ui-permission-presets `permission` order -20（`ui-permission-presets/src/client/index.ts:137-143`） |

owner props 类型：`ComposerChainProps`（`slots.ts:299-307`）、`ComposerBarOwnerProps`（`243-258`）、`InputZone`（`196-200`）、`ComposerAttachmentsOwnerProps`（`37-49`）、`InputControlOwnerProps`（`281-285`）。

**注意**：任务书中提到的 `ui-conversation/src/client/skeleton/QueueDock.tsx` 在源码中**不存在**；队列 dock 位于 `packages/client/ui-conversation/src/client/queue/QueueDock.tsx`。

---

## 5. 命令与引用的数据来源

### 5.1 `ui-commands` 命令注册表

来源三层：

1. **Host 命令目录**：`ctx.remote.commands.list(sessionId)`（RPC `commands/list`），按 sessionId 缓存于 `CommandDirectory`（`ui-commands/src/client/directory.ts:34-156`）。单飞、软失效（`commands/change`）、按会话硬重置（preset 切换）、重连全清（`service.ts:157-162`）。subagent 会话不拉目录（`service.ts:141`）。
2. **客户端 contribution**：`commandUi.register({ name, description, available(session), ui })`（`service.ts:171-181`）。UI 形态目前只有 `popupSelect`（`./contract.ts`）。与 host 同名冲突在候选合成时抛错（`service.ts:260-262`）。
3. **客户端 decoration**：`commandUi.decorate({ name, available, ui })`（`service.ts:189-199`），只装饰**可解析的 host 命令的裸调用**，不制造命令、不影响带参路径（`service.ts:284-288`）。

候选合成与筛选：host 目录 + 可用 contribution → 位置过滤（`inline` 位置丢弃带 `hint` 的行）→ 模糊排序（`service.ts:250-269`）。

已签入的两个注册者：`/model` contribution（`ui-model-selection/src/client/index.ts:130-154`）、`/permission` decoration（`ui-permission-presets/src/client/index.ts:145-166`）。

### 5.2 `ui-input-trigger` 触发器协议

服务面 `ctx.inputTriggers`：`registerSource(src)` + `sessionOf(actx)`（`ui-input-trigger/src/client/contract.ts:12-25`；实现 `service.ts:30-102`）。重名 `(trigger, name)` 抛错（`service.ts:51-53`）；菜单组序与 poll 序都是 `order` 升序（`service.ts:92`）。

源协议 `InputTriggerSource`（`ui-input-trigger/src/types.ts:149-216`）：

| 成员 | 作用 |
|---|---|
| `trigger: '/' \| '@'`、`name`、`order?`、`showGroupTitle?` | 注册身份与菜单分组 |
| `candidates(session, req)` | 异步候选（`req.query/quoted/position/drilled/signal`） |
| `header?(session, req)` | 同步面包屑；实现即参与 |
| `onPick(pick)` | 唯一 pick 出口，返回 `PickOutcome` |
| `matchSpace?(session, token)` | 空格热态同步判定 |
| `matchEnter?(session, line, signal, envelope)` | Enter 判定，可 await 预热；不接受整封 submission 时 throw |
| `warm?(session)` | 作用域出生预热 |
| `lexicon?(session)` + `subscribeLexicon?` | 纯文本引用装饰的热名单 |
| `codec?: { clipboardText, serialize }` | chip 的持久化/模型双投影 |

稳定性 tier 由输入相派生（`types.ts:218-222`），`@` 在 claimed 态仍可用。

已签入源清单：`/command`（`ui-commands/src/client/service.ts:148-156`，order 默认 0）、`/skill`（order 2，`ui-skill/src/client/index.ts:139`）、`@reference`（`ui-reference/src/client/index.ts:44-114`）。

### 5.3 `ui-skill` 提供的候选源

`/` 源，name `skill`，order 2。候选来自 `skills.list({ sessionId }, signal)`（RPC `skills/list`），按 session 缓存 + 单飞；`warm` 在作用域出生预热；preset 切换按会话失效、连接重置全清（`ui-skill/src/client/index.ts:74-194`）。pick 返回**纯文本** `/{name} `（`ui-skill/src/client/index.ts:172-181`）；lexicon 提供 skill 名集合供 chip 视觉扫描（同文件 159-171）。

### 5.4 `ui-reference` 提供的候选源

`@` 源，name `reference`，`showGroupTitle: false`。并行拉 `remote.fileReferences.list` 与 `remote.sessionReferenceResolver.candidates`；文件行 icon `file`/`folder`、目录行带 `drill`；会话行描述为「位置 · 相对时间」（`ui-reference/src/client/index.ts:44-73, 173-229`）。drill 面包屑只在 drilled 状态下给出（同文件 138-165）。

---

## 6. 状态与生命周期补充

### 6.1 输入状态机（SubmitMachine）

纯函数式：`dispatch(event) → effects`（`machine.ts:70-83`）。相：`plain | adjudicating | claimed | submitting`（`contract/input.ts:328`）。
关键不变量：
- 命令/裁决 attempt 占**唯一 frozen 槽**；普通消息在 Enter 处 detach，编辑区可立刻清空并接受下一条（`machine.ts:1-9, 122-137`）。
- claim 完整性：草稿不再以 token 为前缀即释放 claim（`machine.ts:86-92`）。
- 失败时若草稿仍等于发送快照且仍以 token 开头 → 回到 claimed 保留事务语义（`machine.ts:200-208`）。

### 6.2 编辑器与 shell

- shell = `SessionInputShell`，每个 session 一个，随 provide 物化创建、随 scope disposer 销毁（`input/hub.ts:74-131`）。
- 编辑器注册：`registerPlainText` + `registerHistory`（1000ms 合并窗）+ update listener + claim 装饰 + text-ref 装饰（`facade.ts:179-186`；`HISTORY_MERGE_DELAY_MS = 1000`，`facade.ts:114`）。
- 外部文本占位符消毒：`/[\uE100-\uE11D\uFFFC]/gu` 全剥（`facade.ts:111`），防止伪造 chip 位置。
- 草稿持久化镜像：`bindMirror(write)` 由 `ConversationSessionInjected.bindDraftMirror` 绑定（`apply.ts:244`；`facade.ts:602-607`）。
- 滚动：编辑区 14 行封顶（CSS），wheel 到边界后把 delta 转交会话滚动容器（`InputBar.tsx:199-213`）。

### 6.3 浮层（overlay）条目

| 条目 | id / order | 内容 |
|---|---|---|
| `MenuView`（slash 候选） | `slash-menu` / 0 | 分组候选、面包屑、pending 行、listbox aria（`ui-input-trigger/src/client/index.ts:65-85`） |
| `PopupSelectView`（命令弹窗） | `command-popup` / 1 | contribution/decoration 的 popupSelect 外壳（`ui-commands/src/client/index.ts:64-74`） |

### 6.4 composer 链接管（审批 / 提问）

- 审批：`PendingApproval`（kind `approval`），selector 命中即接管，`priority: 1`，并声明子槽 `conversation.approval.detail`（`ui-approval/src/client/index.ts:80-89`；契约 `ui-approval/src/client/contract/slots.ts:35-42, 69-159`）。决策集 `allowed-once | rejected`（同文件 64）。
- 提问：`PendingQuestion`，selector 命中接管；`plan-review` intent 走计划评审卡，其余走通用问答流（`ui-user-questions/src/client/index.ts:94-103`；`QuestionComposer.tsx:279`）。

---

## 7. 运行时装配（web-app bundle）

`packages/bundle/web-app/cordis.patch.yml` 已装载本域全部插件行：

| 行 id | 包名 | yml 行号 |
|---|---|---|
| `ui-conversation` | `@deepseek-ai/dsh-client-ui-conversation` | 207-208 |
| `ui-approval` | `@deepseek-ai/dsh-client-ui-approval` | 210-211 |
| `ui-chat` | `@deepseek-ai/dsh-client-ui-chat` | 213-214 |
| `ui-attachment` | `@deepseek-ai/dsh-client-ui-attachment` | 220-221 |
| `ui-input-trigger` | `@deepseek-ai/dsh-client-ui-input-trigger` | 246-247 |
| `ui-commands` | `@deepseek-ai/dsh-client-ui-commands` | 249-250 |
| `ui-skill` | `@deepseek-ai/dsh-client-ui-skill` | 252-253 |
| `ui-reference` | `@deepseek-ai/dsh-client-ui-reference` | 258-259 |
| `ui-goal` | `@deepseek-ai/dsh-client-ui-goal` | 273-274 |
| `ui-model-selection` | `@deepseek-ai/dsh-client-ui-model-selection` | 282-283 |
| `ui-permission` | `@deepseek-ai/dsh-client-ui-permission-presets` | 285-286 |
| `ui-plan` | `@deepseek-ai/dsh-client-ui-plan` | 299-300 |
| `ui-user-questions` | `@deepseek-ai/dsh-client-ui-user-questions` | 302-303 |

因此 §1 表格中的所有条目在当前 web 装配中均为**实际渲染**，而非可选占位。

---

## 8. 源码未明确 / 例外

1. `conversation.input.left` 与 `conversation.input.right` 在本仓库源码中**未找到注册者**（仅声明与渲染点）。
2. 输入区**没有**独立的图片上传 HTTP 路由；图片以 base64 内联在 `session/prompt`。相关路由字符串（如 `/attachments/…`）只出现在 host 侧对象存储路径与 LLM 适配器，不属输入区。
3. 任务书中列出的 `ui-conversation/src/client/skeleton/QueueDock.tsx` 不存在（实际为 `client/queue/QueueDock.tsx`）。
4. 「提交时的 block 结构」在 composer 侧不存在数组化 block；如需 block 语义，权威来源是 `PromptContentPart[]`（`packages/api/session-controller/src/types.ts`）与队列行的 wire content 数组（`queue/QueueDock.tsx:29-35`）。
5. `Shift+Enter` 之外的多行输入手势（如 Alt+Enter）源码未定义。
6. `/plan` 的进入路径只在命令源侧（`ui-plan` 注释明示 chip 只退出），其 host 命令实现位于 `packages/plan/plan-mode`，不在本域包内。
