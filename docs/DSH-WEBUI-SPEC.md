# DSH Web UI 权威功能规格

面向「在 Wear OS 上复刻 DeepSeek Harness Web UI」的功能规格文档。

| 项 | 值 |
|---|---|
| 源码根 | `third_party/deepseek-harness` |
| 版本 | tag `dsh-v0.1.2-rc.1`，commit `a66e4702047846cdaa10c66c9d3df3951f5ea70d` |
| 权威装配清单 | `packages/bundle/web-app/cordis.patch.yml` |
| 权威座位契约 | `packages/extensions/cordis-client-runner/src/client/slot-catalog.ts`（由 `scripts/gen-client-catalog.ts` 生成、`pnpm run verify-client-catalog` 守卫） |
| 架构文档 | `docs/subsystems/web-client.md`、`docs/subsystems/conversation.md`、`docs/subsystems/slots.md` |

本文只陈述源码事实。每条结论后附来源路径（除注明外，均相对源码根 `third_party/deepseek-harness`）。源码中找不到依据的条目，显式标注「源码未明确」。全文不含推测性设计建议。

少数条目标注「经 A/B/C/D1/D2 域核验」，指该结论来自本轮并行源码分析的分域底稿；这些底稿存放在工作区路径 `docs/_dsh-spec-parts/` 下（不在源码根内），共 5 份：`A-composer.md`、`B-navigation.md`、`C-conversation.md`、`D1-events.md`、`D2-rpc.md`。

---

## 0. 结论摘要

| 判定 | 模块 | 依据 |
|---|---|---|
| 核心 | 会话消息流（chat 视图 + keyed 节点渲染器） | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts:17` |
| 核心 | 输入区 composer（含停止/发送/队列/附件/命令/@ 引用） | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:42` |
| 核心 | 侧边栏 + 工作区/会话列表 + 新建会话 | `packages/client/ui-sidebar/src/client/SidebarRoot.tsx:52`、`packages/client/ui-workspace/src/client/index.ts:138` |
| 核心 | 三列页面骨架 + 详情列 + overlay 层 | `packages/client/ui-layout/src/client/AppFrame.tsx:91` |
| 核心 | 会话列表状态与投影（`useSessions`/`useSession`/`useProjection`） | `packages/client/ui-session/src/client/index.ts:104` |
| 核心 | 消息级驱动事件（turn/step/assistant/tool 事件族） | `packages/client/ui-chat/src/client/conversation-nodes/register.ts:21` |
| 核心 | 工具调用卡片与工具详情 | `packages/client/ui-tool/src/client/apply.ts:33` |
| 核心 | 审批与用户提问（composer 接管式交互） | `packages/client/ui-approval/src/client/index.ts:80`、`packages/client/ui-user-questions/src/client/index.ts:94` |
| 次要 | trajectory 第二视图 | `packages/client/ui-trajectory/src/client/trajectory-contract.ts:95` |
| 次要 | 设置面板全部分区 | `packages/client/ui-settings/src/client/contract/slots.ts:54` |
| 次要 | goal 条、todo 面板、后台任务列表、产出行 | `packages/client/ui-goal/src/client/index.ts:81`、`packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:127`、`packages/client/ui-jobs/src/client/index.ts:32`、`packages/client/ui-deliverables/src/client/index.ts:69` |
| 次要（出厂禁用） | Schedule 目录 | `packages/bundle/web-app/cordis.patch.yml:264` |
| 可裁剪 | 品牌标记/名称、消息 feedback、消息反馈备注 | `packages/bundle/web-app/cordis.patch.yml:217`、`:278` |

---

## 1. 权威装配清单

`packages/bundle/web-app/cordis.patch.yml` 在同一文件里装配三类行。浏览器 UI 的功能清单以其中 `dsh.client` 浏览器 roster 为准。

### 1.1 浏览器插件 roster（`dsh.client` 行）

段注释头在第 151 行；条目自 `modules`（`packages/bundle/web-app/cordis.patch.yml:157`）起、至 `ui-trajectory`（`:305`–`:306`）止，共 40 行，其中唯一 `disabled: true` 的是 `ui-schedule`（`:264`）。roster 行本身不写 `dsh.client` 键，该字段在各包自己的 `package.json` 中声明。

| 行 id | 包名 | 源文件行 |
|---|---|---|
| `modules` | `@deepseek-ai/dsh-client-modules` | `cordis.patch.yml:157` |
| `connection` | `@deepseek-ai/dsh-client-connection` | `:162` |
| `api-remotes` | `@deepseek-ai/dsh-api-remotes` | `:171` |
| `cordis-client-runner` | `@deepseek-ai/dsh-cordis-client-runner` | `:174` |
| `ui-theme` | `@deepseek-ai/dsh-client-ui-theme` | `:177` |
| `locale` | `@deepseek-ai/dsh-client-locale` | `:180` |
| `ui-layout` | `@deepseek-ai/dsh-client-ui-layout` | `:183` |
| `ui-renderer` | `@deepseek-ai/dsh-client-ui-renderer` | `:186` |
| `ui-session` | `@deepseek-ai/dsh-client-ui-session` | `:189` |
| `ui-sidebar` | `@deepseek-ai/dsh-client-ui-sidebar` | `:192` |
| `ui-settings` | `@deepseek-ai/dsh-client-ui-settings` | `:195` |
| `ui-settings-general` | `@deepseek-ai/dsh-client-ui-settings-general` | `:198` |
| `ui-settings-models` | `@deepseek-ai/dsh-client-ui-settings-models` | `:201` |
| `ui-settings-plugin-inventory` | `@deepseek-ai/dsh-client-ui-settings-plugin-inventory` | `:204` |
| `ui-conversation` | `@deepseek-ai/dsh-client-ui-conversation` | `:207` |
| `ui-approval` | `@deepseek-ai/dsh-client-ui-approval` | `:210` |
| `ui-chat` | `@deepseek-ai/dsh-client-ui-chat` | `:213` |
| `ui-brand-official` | `@deepseek-ai/dsh-client-ui-brand-official` | `:217` |
| `ui-attachment` | `@deepseek-ai/dsh-client-ui-attachment` | `:220` |
| `ui-tool` | `@deepseek-ai/dsh-client-ui-tool` | `:224` |
| `ui-cordis` | `@deepseek-ai/dsh-client-ui-cordis` | `:227` |
| `ui-workflow-run` | `@deepseek-ai/dsh-client-ui-workflow-run` | `:232` |
| `ui-deliverables` | `@deepseek-ai/dsh-client-ui-deliverables` | `:237` |
| `ui-workspace` | `@deepseek-ai/dsh-client-ui-workspace` | `:241` |
| `ui-input-trigger` | `@deepseek-ai/dsh-client-ui-input-trigger` | `:246` |
| `ui-commands` | `@deepseek-ai/dsh-client-ui-commands` | `:249` |
| `ui-skill` | `@deepseek-ai/dsh-client-ui-skill` | `:252` |
| `ui-subagent` | `@deepseek-ai/dsh-client-ui-subagent` | `:255` |
| `ui-reference` | `@deepseek-ai/dsh-client-ui-reference` | `:258` |
| `ui-schedule` | `@deepseek-ai/dsh-client-ui-schedule`（`disabled: true`） | `:264` |
| `ui-jobs` | `@deepseek-ai/dsh-client-ui-jobs` | `:269` |
| `ui-goal` | `@deepseek-ai/dsh-client-ui-goal` | `:273` |
| `ui-message-feedback` | `@deepseek-ai/dsh-client-ui-message-feedback` | `:278` |
| `ui-model-selection` | `@deepseek-ai/dsh-client-ui-model-selection` | `:282` |
| `ui-permission` | `@deepseek-ai/dsh-client-ui-permission-presets` | `:285` |
| `ui-agent-preset` | `@deepseek-ai/dsh-client-ui-agent-preset` | `:290` |
| `ui-settings-plugins` | `@deepseek-ai/dsh-client-ui-settings-plugins` | `:295` |
| `ui-plan` | `@deepseek-ai/dsh-client-ui-plan` | `:299` |
| `ui-user-questions` | `@deepseek-ai/dsh-client-ui-user-questions` | `:302` |
| `ui-trajectory` | `@deepseek-ai/dsh-client-ui-trajectory` | `:305` |

补充事实：`packages/client` 目录下共有 44 个包，其中 `ui-primitives`、`ui-slots`、`store`、`hmr`、`web`、`ui-directory-picker-browse`、`ui-directory-picker-native` 不在上面的 roster 行内。前三者由浏览器基线模块表提供（`packages/client/web/src/platform.ts` 的 `PLATFORM_MODULES`），`ui-directory-picker-*` 由 host 行 `directory-picker` 以 `-auto` 变体间接挂载（`cordis.patch.yml:83`）。

### 1.2 Web-only host 行（前端依赖的服务侧）

| 行 id | 包名 | 作用摘要 | 行 |
|---|---|---|---|
| `subagent-model-selection-settings` | `@deepseek-ai/dsh-tool-subagent/model-selection-settings` | 子代理委派工具预设的采样开关 | `:46` |
| `code-runtime` | `@deepseek-ai/dsh-code-runtime-worker-thread` | 代码运行 worker | `:49` |
| `message-feedback` | `@deepseek-ai/dsh-message-feedback`（`maxNoteBytes: 8192`） | 消息反馈存储 | `:52` |
| `session-log-download` | `@deepseek-ai/dsh-session-log-export` | `/export` 命令与下载对话框 | `:58` |
| `workspace` | `@deepseek-ai/dsh-workspace` | 工作区注册表 | `:61` |
| `session-reference` | `@deepseek-ai/dsh-session-reference` | 会话引用源 | `:64` |
| `file-reference-local` | `@deepseek-ai/dsh-file-reference-local` | 文件引用源 | `:67` |
| `session-stats` | `@deepseek-ai/dsh-session-stats` | `sessionStats` 投影 | `:72` |
| `session-turn-outline` | `@deepseek-ai/dsh-session-turn-outline` | `turnOutline` 投影 | `:77` |
| `directory-picker` | `@deepseek-ai/dsh-host-directory-picker-auto` | 目录选择器装配 | `:83` |
| `plugin-inventory` | `@deepseek-ai/dsh-host-plugin-inventory` | 插件清单只读投影 | `:87` |
| `session-controller` | `@deepseek-ai/dsh-api-session-controller` | 会话命令、冷读、实时控制 | `:91` |
| `settings-controller` | `@deepseek-ai/dsh-api-settings-controller` | 配置面读写 | `:96` |
| `workspace-controller` | `@deepseek-ai/dsh-api-workspace-controller` | 工作区命令与投影 | `:100` |
| `cordis-host-runner` | `@deepseek-ai/dsh-cordis-host-runner` | 自省/自改宿主面 | `:103` |
| `web-startup` | `@deepseek-ai/dsh-web-app/startup` | 启动参数服务 | `:108` |
| `webserver` | `@deepseek-ai/dsh-host-webserver` | HTTP 承载（默认 `127.0.0.1:3080`，gzip） | `:116` |
| `web-runtime` | `@deepseek-ai/dsh-web-app` | 前端 dist 解析、URL 打印、`webRuntime` | `:135` |
| `client-hmr` | `@deepseek-ai/dsh-client-hmr` | 客户端插件热重载链 | `:148` |
| `agent-presets` | `@deepseek-ai/dsh-agent-presets`（`default: standard`） | 每会话 agent 组合预设 | `:440` |

### 1.3 被 Web 面显式禁用的 agent 平面行

`cordis.patch.yml` 把随会话预设走的行在本面禁用（`disabled: true`），清单为 `tool-bash`、`tool-pwsh`、`tool-jobs`、`tool-fs`、`tool-fs-search`、`tool-str-replace-editor`、`skill-filesystem`、`tool-skill`、`command-goal`、`tool-goal`、`plan-mode`、`compaction-basic`、`command-compact`、`tool-result-pruner`、`tool-subagent-control`、`tool-subagent-list-agents`、`tool-subagent`、`tool-subagent-fork`、`workflow-worker-thread`、`tool-workflow`、`tool-ralph`、`agent-instructions`、`tool-todo`、`tool-web`（`cordis.patch.yml:325`–`:431`）。对复刻的含义：模型可见工具由 `agent-presets` 决定，不由浏览器 roster 决定。

---

## 2. 页面骨架与 slot 座位图

### 2.1 启动与根渲染

`ui-renderer` 是唯一通过 Cordis 服务渲染 `root` 的包，也是唯一绑定裸 observable 到 React hook 的包（`docs/subsystems/slots.md:15`、`:60`）。浏览器启动后由 `ui-layout` 的 `AppFrame` 占 `root`（`packages/client/ui-renderer/src/client/registry.ts:43`）。

三列栅格由 `AppFrame` 持有：`sidebar | center | details`，另加 `shell.overlay` 层；列宽由 `computeColumns` 求解，窗口变窄时侧边栏自动折叠（`packages/client/ui-layout/src/client/AppFrame.tsx:146`、`:179`、`:211`）。

### 2.2 完整 slot 座位图（52 个 key）

以下表由 `packages/extensions/cordis-client-runner/src/client/slot-catalog.ts` 提取，`declaredBy` 与 `source` 列来自该目录条目。`replaceRisk = shadows-shipped-ui` 表示注册即替换出厂 UI（复刻时需整块重写），`none` 表示可加性扩展。

| slot key | kind | scope | 出厂占位者 | replaceRisk | 声明源 |
|---|---|---|---|---|---|
| `root` | single | root | client-ui-layout AppFrame | shadows-shipped-ui | `packages/client/ui-renderer/src/client/registry.ts:43` |
| `sidebar` | single | root | client-ui-sidebar SidebarRoot | shadows-shipped-ui | `packages/client/ui-layout/src/client/index.ts:52` |
| `sidebar.brand.mark` | single | root | client-ui-brand-official OfficialBrandMark | shadows-shipped-ui | `packages/client/ui-sidebar/src/client/contract/slots.ts:23` |
| `sidebar.brand.name` | single | root | client-ui-brand-official OfficialBrandName | shadows-shipped-ui | `packages/client/ui-sidebar/src/client/contract/slots.ts:28` |
| `sidebar.workspaces` | single | root | client-ui-workspace WorkspaceBrowser | shadows-shipped-ui | `packages/client/ui-sidebar/src/client/contract/slots.ts:35` |
| `sidebar.workspaces.directoryFlow` | single | root | client-ui-directory-picker-browse BrowseDirectoryFlow；client-ui-directory-picker-native NativeDirectoryFlow | shadows-shipped-ui | `packages/client/ui-workspace/src/client/contract/slots.ts:59` |
| `sidebar.settings` | single | root | client-ui-settings-general SettingsRoot | shadows-shipped-ui | `packages/client/ui-sidebar/src/client/contract/slots.ts:41` |
| `sidebar.footer.action` | list | root | client-ui-cordis CordisPanel id `cordis-panel` | none | `packages/client/ui-sidebar/src/client/contract/slots.ts:46` |
| `conversation` | single | session-maybe | client-ui-conversation ConversationRoot | shadows-shipped-ui | `packages/client/ui-layout/src/client/index.ts:65` |
| `conversation.session` | single | session | client-ui-conversation ConversationSession | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:95` |
| `conversation.session.header` | single | session | client-ui-conversation ConversationSessionHeader | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:97` |
| `conversation.session.header.lineage` | single | session | client-ui-subagent SubagentHeaderLineage | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:99` |
| `conversation.session.header.actions` | list | session | client-ui-agent-preset AgentPresetLabel id `agent-preset`；client-ui-jobs JobListAction id `job-list`；client-ui-schedule ScheduleCatalogAction id `schedule-catalog`；experimental-client-ui-agent-team TeamAction id `agent-team` | none | `packages/client/ui-conversation/src/client/contract/slots.ts:105` |
| `conversation.session.header.utilities` | list | session | session-log-export SessionLogDownloadHeaderAction id `session-log-download` | none | `packages/client/ui-conversation/src/client/contract/slots.ts:111` |
| `conversation.view` | list | session | client-ui-chat ChatView id `chat`；client-ui-trajectory TrajectoryView id `trajectory` | none | `packages/client/ui-conversation/src/client/contract/slots.ts:117` |
| `conversation.chat.node` | keyed | session | 见 §3.3（17 个 key） | shadows-shipped-ui | `packages/client/ui-chat/src/client/contract/slots.ts:190` |
| `conversation.chat.commandview` | keyed | session | （出厂无占位者） | none | `packages/client/ui-chat/src/client/contract/slots.ts:209` |
| `conversation.chat.turnTail` | chain | session | client-ui-deliverables ProducedFiles | none | `packages/client/ui-chat/src/client/contract/slots.ts:215` |
| `conversation.chat.assistant-actions` | list | session | client-ui-message-feedback MessageFeedbackActions id `feedback` | none | `packages/client/ui-chat/src/client/contract/slots.ts:221` |
| `conversation.details.tool` | single | session | client-ui-tool ToolDetails | shadows-shipped-ui | `packages/client/ui-chat/src/client/contract/slots.ts:227` |
| `conversation.message.images` | single | session | client-ui-attachment MessageImages | shadows-shipped-ui | `packages/client/ui-chat/src/client/contract/slots.ts:203` |
| `conversation.trajectory.images` | single | session | client-ui-attachment MessageImages | shadows-shipped-ui | `packages/client/ui-trajectory/src/client/trajectory-contract.ts:95` |
| `conversation.composer` | chain | session | client-ui-approval ApprovalPanel；client-ui-subagent SubagentReadOnlyComposer；client-ui-user-questions QuestionComposer | none | `packages/client/ui-conversation/src/client/contract/slots.ts:119` |
| `conversation.composer.bar` | single | session-maybe | client-ui-conversation InputBar | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:137` |
| `conversation.composer.dock` | list | session | client-ui-chat StatsLine id `stats` | none | `packages/client/ui-conversation/src/client/contract/slots.ts:131` |
| `conversation.input.dock` | list | session | client-ui-conversation QueueDock id `queue`；client-ui-conversation TodoDock id `todo`；client-ui-goal GoalDock id `goal` | none | `packages/client/ui-conversation/src/client/contract/slots.ts:127` |
| `conversation.input.overlay` | list | session | client-ui-commands PopupSelectView id `command-popup`；client-ui-input-trigger MenuView id `slash-menu` | none | `packages/client/ui-conversation/src/client/contract/slots.ts:129` |
| `conversation.input.attachments` | single | session-maybe | client-ui-attachment ComposerAttachments | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:139` |
| `conversation.input.left` | list | session | （出厂无占位者） | none | `packages/client/ui-conversation/src/client/contract/slots.ts:133` |
| `conversation.input.right` | list | session | （出厂无占位者） | none | `packages/client/ui-conversation/src/client/contract/slots.ts:135` |
| `conversation.input.plan` | single | session | client-ui-plan PlanChip | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:145` |
| `conversation.input.model` | single | session | client-ui-model-selection ModelSelect | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:147` |
| `conversation.hero.brand.mark` | single | root | （出厂无占位者） | none | `packages/client/ui-conversation/src/client/contract/slots.ts:123` |
| `conversation.hero.workspace` | single | root | client-ui-workspace WorkspacePicker | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:121` |
| `conversation.hero.workspace.directoryFlow` | single | root | client-ui-directory-picker-browse BrowseDirectoryFlow；client-ui-directory-picker-native NativeDirectoryFlow | shadows-shipped-ui | `packages/client/ui-workspace/src/client/contract/slots.ts:57` |
| `conversation.hero.agentPreset` | single | root | client-ui-agent-preset AgentPresetSeat | shadows-shipped-ui | `packages/client/ui-conversation/src/client/contract/slots.ts:125` |
| `conversation.approval.detail` | single | session | client-ui-chat ApprovalCommand | shadows-shipped-ui | `packages/client/ui-approval/src/client/contract/slots.ts:37` |
| `tool.call.toolview` | keyed | session | 见 §3.4（15 个 key） | shadows-shipped-ui | `packages/client/ui-tool/src/client/contract/slots.ts:26` |
| `tool.view.cordis` | keyed | session | （出厂无占位者） | none | `packages/extensions/ui-cordis/src/client/slots.ts:31` |
| `details` | single | session | client-ui-chat DetailsPanel | shadows-shipped-ui | `packages/client/ui-layout/src/client/index.ts:75` |
| `shell.overlay` | list | root | （出厂无占位者） | none | `packages/client/ui-layout/src/client/index.ts:86` |
| `settings.trigger` | single | root | client-ui-settings-general TriggerContent | shadows-shipped-ui | `packages/client/ui-settings/src/client/contract/slots.ts:24` |
| `settings.header` | single | root | client-ui-settings-general HeaderContent | shadows-shipped-ui | `packages/client/ui-settings/src/client/contract/slots.ts:30` |
| `settings.action` | list | root | client-ui-settings-general SettingsDocumentAction id `open-document` | none | `packages/client/ui-settings/src/client/contract/slots.ts:36` |
| `settings.close` | single | root | client-ui-settings-general CloseLabel | shadows-shipped-ui | `packages/client/ui-settings/src/client/contract/slots.ts:42` |
| `settings.section` | list | root | client-ui-agent-preset AgentPresetSection id `agent-presets`；client-ui-settings-general GeneralSection id `general`；client-ui-settings-models ModelsSection id `models`；client-ui-settings-plugins PluginsSettingsSection id `plugins` | none | `packages/client/ui-settings/src/client/contract/slots.ts:54` |
| `settings.general.item` | list | root | client-locale LanguageRow id `language`；client-ui-chat TranscriptViewRow id `transcript-view`；client-ui-conversation EnterBehaviorRow id `composer-enter`；client-ui-permission-presets PermissionRow id `permission`；client-ui-theme AppearanceRow id `appearance`；client-ui-theme FontSizeRow id `font-size` | none | `packages/client/ui-settings/src/client/contract/slots.ts:89` |
| `settings.onboarding` | list | root | client-ui-settings-models WelcomeNotice id `welcome-notice`；client-ui-settings-models DeepSeekOnboardingDialog id `deepseek-official` | none | `packages/client/ui-settings/src/client/contract/slots.ts:74` |
| `settings.models.provider-card` | keyed | root | （出厂无占位者） | none | `packages/client/ui-settings-models/src/client/slot-contract.ts:33` |
| `settings.models.footer` | list | root | （出厂无占位者） | none | `packages/client/ui-settings-models/src/client/slot-contract.ts:38` |
| `settings.plugins.tab` | list | root | client-ui-settings-plugin-inventory PluginInventorySettingsTab id `all`；client-ui-settings-plugins ConfigurablePluginsTab id `configurable` | none | `packages/client/ui-settings/src/client/contract/slots.ts:63` |
| `settings.plugin.item` | keyed | root | client-ui-settings-plugins BashCard；AgentLoopCard；SubagentModelSelectionCard；WebSearchCard | none | `packages/client/ui-settings-plugins/src/client/slot-contract.ts:19` |

出厂无占位者的 6 个 key（`conversation.chat.commandview`、`conversation.input.left`、`conversation.input.right`、`conversation.hero.brand.mark`、`tool.view.cordis`、`shell.overlay`、以及 settings 的 models 两个）是纯扩展点：装空时该位置不渲染任何东西。

---

## 3. 会话与对话（核心界面）

### 3.1 数据通路

| 阶段 | 机制 | 来源 |
|---|---|---|
| 历史读取 | Host 会话日志经 Remote `follow()`/`page()` 送入浏览器 | `docs/subsystems/web-client.md:66` |
| 窗口表示 | 客户端保有一份连续逻辑事件窗口，元素为 `SessionEventLikeEntry`，即 `{type:'event'}` 或 `{type:'chunks'}`（`ChunkRowEvent`） | `packages/client/ui-conversation/src/client/contract/conversation.ts:119` |
| 事件关联 | `ui-conversation` 每 Session 一个 Assembler，对每个注册 Definition 调用 `match()` 抽取 `(kind, id)` | `docs/subsystems/conversation.md:11` |
| 折叠 | `start()`（唯一 start 事件）与 `update()`（升序 seq 重放）产生不可变 State | `docs/subsystems/conversation.md:219` |
| 视图 | 目标包（ui-chat / ui-trajectory）各自定义 `ConversationViewDefinition` 并物化最终 Node | `packages/client/ui-conversation/src/client/contract/conversation.ts:277` |
| 渲染 | Chat 视图按 keyed 渲染器消费 `node.data` 与约束 hook | `packages/client/ui-chat/src/client/contract/slots.ts:190` |

会话外壳相位由 `conversationPhase` 计算，取值 `blank | engaging | active`，输入 Session 生命周期与已激活目标（`packages/client/ui-conversation/src/client/contract/snapshot.ts:26`）。

### 3.2 驱动会话界面的事件族

| 事件 | 会话界面上的作用 | 证据 |
|---|---|---|
| `turn/start` | 开启一层 Turn；Location 边界与回合导航项的数据来源 | `packages/client/ui-conversation/src/client/contract/conversation.ts:92` |
| `step/start` | 开启一步；`assistant-step` 节点的唯一 start | `packages/client/ui-chat/src/client/conversation-nodes/assistant.ts:379` |
| `step/end` | 关闭 Step 边界；被打断的助手输出用该边界合成结束序号 | `packages/client/ui-chat/src/client/conversation-nodes/assistant.ts:250` |
| `user/message` | 用户消息节点（`user` key） | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts:19` |
| `assistant/chunk` | 流式块：`block-start` / `text-delta` / `reasoning-delta` / `tool-call-delta` / `block-end` / `usage` | `packages/client/ui-chat/src/client/conversation-nodes/assistant.ts:104` |
| `assistant/message` | 定型助手消息（含 `usage`、`interrupted`） | `packages/client/ui-chat/src/client/conversation-nodes/assistant.ts:265` |
| `chunkrow/text-chunks`、`chunkrow/reasoning-chunks`、`chunkrow/tool-call-chunks` | 历史打包的同类增量，客户端专有，只能作为 update | `docs/subsystems/conversation.md:45` |
| `tool/call`、`tool/result` | 工具调用行的生命周期（运行中/已结算/错误） | `docs/subsystems/conversation.md:5`，`packages/client/ui-tool/src/client/apply.ts:33` |
| `llm/retry` | 重置助手流并隐藏重试前的内容（`resetForRetry`） | `packages/client/ui-chat/src/client/conversation-nodes/assistant.ts:326` |
| 命令生命周期事件 | 命令行卡片与其关联的压缩事务 | `packages/client/ui-chat/src/client/conversation-nodes/command.ts`（注册于 `register.ts:28`） |
| `todo/write` | `todos` 投影（todo 面板） | `packages/todo/tool-todo/src/types.ts:39` |
| `goal/change` | `goal` 投影（GoalBar） | `packages/goal/goal/src/types.ts:116` |
| `permission/preset`、`sandbox/mode`、`approval/policy` | `permissions` 投影（权限芯片与设置行） | `packages/interaction/permission-presets/src/types.ts:35` |
| `plan/mode` | `plan` 投影（PlanChip 显隐、占位符切换） | `packages/plan/plan-mode/src/types.ts:43` |

### 3.2.1 权威事件词汇（51 项）

`packages/core/session/src/known-event-types.ts:22` 的 `KNOWN_SESSION_EVENT_TYPES` 是**本构建理解的完整事件词汇**，由 `scripts/gen-persistence-catalog.ts` 生成、`pnpm run verify-persistence-catalog` 守卫。持久化读路径拒绝解释包含该集合之外类型的日志，除非事件携带信封的 `ignorable` 标记（同文件 `:8`–`:20`）。逐一列出：

`agent-preset/selected`、`agent/inbox/spliced`、`approval/asked`、`approval/decided`、`approval/policy`、`assistant/chunk`、`assistant/message`、`command/done`、`command/run`、`compaction/end`、`compaction/prune`、`compaction/start`、`compaction/summary`、`feedback/record`、`goal/change`、`hook/invoked`、`hook/result`、`llm/retry`、`llm/retry-started`、`model/selection`、`permission/preset`、`plan/mode`、`request/context`、`request/header`、`sandbox/mode`、`schedule/change`、`session-log-deepseek/delivery-accepted`、`session/end-seed`、`session/title`、`session/title-llm-request`、`step/end`、`step/start`、`subagent/descriptor`、`subagent/model-selection-policy`、`team/member`、`team/message/delivered`、`team/message/queued`、`team/task`、`todo/write`、`tool-workflow/agent-end`、`tool-workflow/agent-start`、`tool-workflow/run-end`、`tool-workflow/run-start`、`tool/call`、`tool/code-dispatch`、`tool/code-dispatch-start`、`tool/result`、`turn/end`、`turn/start`、`user/message`、`web/deepseek-search-llm-request`。

与之对照，`chunkrow/text-chunks`、`chunkrow/reasoning-chunks`、`chunkrow/tool-call-chunks` 不是会话事件，而是客户端专有的 wire 标签，由 `ChunkRowEvent` 映射承接（`docs/subsystems/conversation.md:45`、`packages/client/ui-chat/src/client/conversation-nodes/assistant.ts:42`）。`ChunkRow` 没有 `SessionEventMap` 条目、没有 surfaceOp，并使用无斜杠的裸标签以避免与事件分类混淆（`packages/core/session/src/chunk-rows.ts:9`）；转换点是 `chunkEntryFor`（`packages/api/session-controller/src/history.ts:366`），产出 `{type:'chunks', event: ChunkRowEvent}`。

事件语义与版本机制（经 D1 域核验）：

| 事实 | 内容 | 来源 |
|---|---|---|
| surface 事件 | 51 项中仅 3 项是 surface 事件（`user/message`、`assistant/message`、`tool/result`），其余 48 项全部 log-only，不贡献派生历史 | `packages/core/session/src/types.ts:373` |
| 日志格式版本 | `SESSION_FORMAT_VERSION = 0` | `packages/core/session/src/types.ts:87` |
| bump 判据 | 取决于**写入者发出什么**，不是"新读者能否接受"；只有结构性变更（头形状、事件信封、核心事件语义、surface 机制）达标，新增普通事件类型不 bump，由逐事件 `ignorable` 覆盖词汇增长，存疑时 bump | `packages/core/session/src/types.ts:87` |
| `ignorable` 语义 | 缺席即必读；读者遇到未知类型必须拒绝重建该会话 | `packages/core/session/src/types.ts:443` |
| `ignorable` 现状 | 本构建的 51 个事件在**生产源码中没有任何一个写入过 `ignorable: true`**（该字面量只出现在测试与 fixture），因此当前全部事件都是 required-on-read | 经 D1 域全仓 grep 核验 |
| 持久化形态 | JSONL 首行为 `type:'session'` 的私有 header；路径 `<root>/<projectDir>/<sessionDir>/session.jsonl[.zstd]`；`packChunks` 默认 true、`compression` 默认 `zstd` | `packages/session/session-persistence-jsonl/src/format.ts:46`、`src/index.ts:47` |
| 打包最小规模 | `MIN_RUN = 3`，可打包种类仅 3 种 delta；块边界、usage、finish 始终一行一事件 | `packages/core/session/src/chunk-rows.ts` |

`docs/subsystems/session.md` 与 `packages/core/session/src/types.ts:259` 定义基础 `SessionEventMap`；各能力包通过 declaration merging 扩展该表，扩展点清单见附录 B。

### 3.3 Chat 节点渲染器全表（`conversation.chat.node` keyed）

| key | 出厂渲染组件 | payload 类型 | 触发事件/来源 |
|---|---|---|---|
| `user` | `UserMessageNodeView` | `UserMessageNode` | `user/message`（`register-node-renderers.ts:19`） |
| `steering` | `UserMessageNodeView` | `SteeringMessageNode` | 转向消息（`:21`） |
| `context` | `ContextMessageNodeView` | `ContextMessageNode` | 上下文注入消息（`:23`） |
| `system-prompt` | `SystemPromptNodeView` | 系统提示行 | `:25` |
| `assistant-step` | `AssistantNodeView` | `AssistantChatData`（`status: running\|settled\|interrupted`、`blocks`、`usage`、`finalNode`） | `step/start` + `assistant/chunk` 等（`contract/chat-nodes.ts:30`） |
| `command` | `CommandNodeView`（声明子槽 `conversation.chat.commandview`） | `CommandNode` | 命令行生命周期（`:28`） |
| `manual-compaction` | `ManualCompactionNodeView` | `ManualCompactionChatData`（命令 + 压缩摘要） | `contract/chat-nodes.ts:51` |
| `compaction` | `CompactionNodeView` | `CompactionSummaryNode` | `:37` |
| `model-retry` | `RetryNodeView` | `RetryChatData`（attempts + current） | `contract/chat-nodes.ts:57` |
| `turn-error` | `TurnErrorNodeView` | `TurnErrorNode` | `:41` |
| `turn-max-tokens` | `TurnMaxTokensNodeView` | `TurnMaxTokensNode` | `:43` |
| `turn-process` | `TurnProcessNodeView` | `TurnProcessChatData`（工具调用数、子代理数、消息数、推理内联开关） | `contract/chat-nodes.ts:101` |
| `turn-tail` | `TurnTailNodeView`（声明 `conversation.chat.turnTail` 与 `conversation.chat.assistant-actions`） | `TurnTailChatData`（closing、ttftMs、tokensPerSecond、tokenUsage） | `contract/chat-nodes.ts:86` |
| `unknown` | `UnknownNodeView` | `UnknownSurfaceNode` | `:56` |
| `tool-call` | `ToolCallTree`（声明 `tool.call.toolview`） | `ToolChatData`（root `ToolCallBlock`） | `contract/chat-nodes.ts:46`，`packages/client/ui-tool/src/client/apply.ts:33` |
| `command-input` | `GoalCommandInputView` | 目标命令输入投影 | `packages/client/ui-goal/src/client/index.ts:60` |
| `workflow-run` | `WorkflowRunPanel` | 工作流生命周期 | `packages/client/ui-workflow-run`（slot-catalog `conversation.chat.node` occupants） |

未占位的 key 渲染为空行（`packages/client/ui-chat/src/client/contract/slots.ts:188`）。

关于上表的四点补充（均经 C 域核验）：

| 事实 | 内容 |
|---|---|
| 渲染 kind 总数 | 17 个，由 4 个包合并声明进 `ChatNodeDataMap`：ui-chat 15 个、ui-goal 1 个（`command-input`）、ui-workflow-run 1 个（`workflow-run`） |
| Definition kind 与渲染 kind 不同名 | 事件层 Definition `input-message` 产出 `user` / `steering` / `context` 三个渲染 kind；Definition `command` 在命令名为 `compact` 时产出 `manual-compaction` |
| 权威清单来源 | 判断 kind 全集应以 `declare module '../contract/chat-nodes.ts'` 的合并声明为准，不能只看 `register-node-renderers.ts`（它只覆盖 ui-chat 自身的 14 个 key） |
| 中断消息 | 中断会在消息上追加 `message.stopped` 标记，且**没有 messageId**，因此该行不提供逐消息操作 |
| 错误呈现 | 错误走独立的 `turn-error` 节点，不挂在助手节点上 |

推理过程呈现：`ReasoningRow` 复用 DisclosureRow 的展开形态；运行中摘要取推理的最后一行，结束后取第一行；当 `turn-process` 处于可折叠状态时，推理块整块隐藏（经 C 域核验）。

### 3.4 工具调用卡片（`tool.call.toolview` keyed）

| key | 出厂视图 | 卡片内容 |
|---|---|---|
| `bash` | `BashRow` | 终端/命令卡片（`packages/client/ui-tool/src/client/apply.ts:49`） |
| `read` | `ReadRow` | 文件读取卡片（`:50`） |
| `edit`、`write` | `FileMutationRow` | 文件改动卡片（diff 模型，`:51`） |
| `grep`、`glob` | `SearchRow` | 搜索卡片（`:52`） |
| `web_search`、`web_fetch` | `WebRow` | 网页检索卡片（`:53`） |
| `todo_write` | `TodoRow` | 待办写入卡片（`:54`） |
| `ask_user_question` | `AskQuestionRow` | 反问卡片（`:55`） |
| `skill` | `SkillRow` | 技能调用行（slot-catalog `tool.call.toolview` occupants） |
| `cordis_define` | `CordisDefineRow` | 自省/自改行（同上） |
| `cordis_run` | `CordisRunRow` | 同上 |
| `cordis_stop`、`cordis_undefine` | `CordisActionRow` | 同上 |

卡片背后的模型文件：`packages/client/ui-tool/src/client/tool/models/` 下 `tool-call-model.ts`、`diff-card-model.ts`、`terminal-card-model.ts`、`read-card-model.ts`、`search-card-model.ts`、`web-card-model.ts`、`ask-question-card-model.ts`、`raw-tool-call.ts`。未知或畸形工具数据回落到通用形态（`packages/client/AGENTS.md`，Layering red lines 段）。

卡片行为细节：

| 事实 | 内容 | 来源 |
|---|---|---|
| 渲染入口 | `ToolChatData.root` 交给 `ToolCallTree` 递归渲染，子槽派发键是工具名 `renderSlot('tool.call.toolview', {entryKey: toolName}, {fallback: GenericToolCard})` | `packages/client/ui-tool/src/client/tool/ToolCallTree.tsx`、`packages/client/ui-tool/src/client/apply.ts:33` |
| 子调用 | `tool/code-dispatch` 子调用参与递归，深度上限 256 | 经 C 域核验 |
| 卡片显示 | 变体图标/状态点、标题、参数摘要、失败首行、文件路径链接、展开体（终端 / diff / read / search / web / ask-user 卡片或 IN-OUT） | 经 C 域核验 |
| 跳转按钮 | Inspect 按钮跳到 trajectory 视图 | 经 C 域核验 |
| 耗时 | 卡片本身**无耗时字段**；耗时显示在 turn-tail | 经 C 域核验 |
| 超长结果折叠 | diff / read / search 卡片上限 8 行后中部折叠；终端卡片在 chat 行 `maxLines=Infinity` | 经 C 域核验 |
| 内容溢出（spill） | 由 Host 落盘，客户端只在文本中显示 `spill://` 定位；**客户端无 spill 实现** | 经 C 域核验 |

工具详情面板：`details` slot 装 `DetailsPanel`，其子槽 `conversation.details.tool` 出厂装 `ToolDetails`（`packages/client/ui-chat/src/client/apply.ts:163`、`packages/client/ui-tool/src/client/apply.ts:43`）。打开详情列的 RPC 通道是 `openDetails` → `ctx.layout.openDetails()`（`packages/client/ui-chat/src/client/apply.ts:117`）。

### 3.5 审批与用户提问（composer 接管）

| 机制 | 事实 | 来源 |
|---|---|---|
| 审批入口 | 客户端订阅 scoped Remote waterfall 事件 `approval/request`，返回前不 `next()` | `packages/client/ui-approval/src/client/index.ts:90` |
| 审批呈现 | 以 `conversation.composer` chain 条目接管输入卡（priority 1），声明子槽 `conversation.approval.detail` | `:80`、`:86` |
| 审批载荷 | `toolName`、可选 `callId`、可选 `reason`、可选 `signal` | `:45` |
| 审批详情 | `ApprovalCommand` 占 `conversation.approval.detail` | `packages/client/ui-chat/src/client/apply.ts:160` |
| 提问入口 | scoped Remote waterfall 事件 `user-questions/request` | `packages/client/ui-user-questions/src/client/index.ts:104` |
| 提问优先级 | `plan-review` 型 precedence 2，普通提问 1 | `:91` |
| 提问形态 | 单一 chain 条目内两种形态：`plan-review` 渲染计划决策卡，其余走通用提问流程 | `:8` |
| 挂起交互模型 | `uiSession.registerPendingInteraction()` 注册域，跨域按 precedence 竞争同一 Session 的唯一挂起交互；插件销毁时先撤下可见值再委派结算 | `packages/client/ui-session/src/client/index.ts:304`、`:366` |
| 只读接管 | `SubagentReadOnlyComposer` 占 `conversation.composer` chain（子代理不可写时） | slot-catalog `conversation.composer` occupants |

交互细节：

| 事实 | 内容 |
|---|---|
| 审批出现位置 | **不在消息流内**；它是 composer 的接管卡片，由 Remote waterfall 事件驱动 |
| 审批卡片内容 | 理由行（缺省文案为「<工具名> 请求提权」）+ `conversation.approval.detail` 明细（ui-chat 的占位者只显示参数里的 command）+ 「拒绝」/「允许一次」两个按钮 |
| 审批决策 | 只有 `allowed-once` 与 `rejected` 两种；决策经 waterfall 返回值回传，**无独立 RPC** |
| 审批 diff 预览 | 源码无内建 diff 预览 |
| 提问形态 | 每题可选单选 / 多选 / 自由文本 / 跳过；支持逐题导航、Session 级草稿 store、最小化与取消（`ASK_CANCELLED`） |
| 提问的特例形态 | `plan-review` 意图走 `PlanReviewPanel`，由同一条目内部分支 |

以上六条均经 C 域源码核验（`docs/_dsh-spec-parts/C-conversation.md`）。

### 3.6 goal、todo、后台任务、产出行

| 面板 | 位置 | 数据源 | 用户操作 | 来源 |
|---|---|---|---|---|
| Goal 条 | `conversation.input.dock`（id `goal`，order 10） | `useProjection('goal')` | 编辑目标、暂停、恢复、清除 | `packages/client/ui-goal/src/client/index.ts:81`、`:86` |
| 目标命令输入 | `conversation.chat.node` key `command-input` | 目标命令投影 | — | `:60` |
| Todo 面板 | `conversation.input.dock`（id `todo`，order 0） | `useProjection('todos')` | 展开/折叠 | `packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:127` |
| 队列 dock | `conversation.input.dock`（id `queue`） | 输入状态里的 `queue` | 队列行操作 | `packages/client/ui-conversation/src/client/apply.ts:368` |
| 后台任务列表 | `conversation.session.header.actions`（id `job-list`，order 20） | `jobsBySession` 列表镜像，本插件不发 RPC、不持业务状态 | `packages/client/ui-jobs/src/client/index.ts:32` |
| 产出行 | `conversation.chat.turnTail` chain | 回合内已结算的文件写入/编辑调用 | `packages/client/ui-deliverables/src/client/index.ts:69` |
| 统计行 | `conversation.composer.dock`（id `stats`） | `sessionStats` 投影 | — | `packages/client/ui-chat/src/client/apply.ts:155` |

Goal 条四个动词分别调用 `ctx.remote.goals.edit / pause / resume / clear`，每次调用前用投影里的当前 `{id, revision}` 作 CAS 引用（`packages/client/ui-goal/src/client/index.ts:90`–`:105`）。

产出行同时通过 `chatFileMentions` 服务把回合收尾正文里的行内代码文件名链接成可打开文件（`packages/client/ui-deliverables/src/client/index.ts:85`）。可打开性由 `ctx.remote.session.canOpenWorkspacePath()` 判定（`:48`）。

回合尾部的构成顺序（经 C 域核验）：

| 顺序 | 内容 | 细节 |
|---|---|---|
| 1 | `conversation.chat.turnTail` chain | 出厂由 ui-deliverables 的产出文件行占位 |
| 2 | 产出文件行 | 取自 `write` / `edit` / `str_replace_editor` 成功结果的参数路径；最多 6 个 chip，超出显示余量，并提供「在文件夹中显示」 |
| 3 | 消息图标操作条 | 复制 / 分支 / 用量 / 耗时 / 时钟 |
| 4 | Turn 数据键 | `deliverables` |

消息级操作的实际范围（经 C 域核验）：

| 角色 | 可用操作 |
|---|---|
| 用户消息 | 时钟、复制（仅此两项） |
| 助手消息 | 复制、`conversation.chat.assistant-actions`（出厂为 ui-message-feedback，id `feedback` order 10）、分支（fork）、用量 |
| 会话流内的重试 / 编辑按钮 | **源码未提供** |

`maxNoteBytes: 8192` 由 Web bundle 配置（`packages/bundle/web-app/cordis.patch.yml:55`），Host 侧校验（`packages/feedback/message-feedback/src/index.ts:353`–`:354`），客户端不预校验；超长备注在保存时以 `note-too-large` 失败（经 C 域核验）。

### 3.7 视图切换：chat 与 trajectory

两个视图各自注册为 `conversation.view` 的列表条目（id `chat` order 0、id `trajectory`），标签来自注册项 `label`，仅当注册数大于 1 时头部渲染 tab 栏（`packages/client/ui-chat/src/client/apply.ts:94`、`packages/client/ui-conversation/src/client/skeleton/ConversationSession.tsx:137`）。

视图选择按 Session 持久化在会话外壳 store 中（`view: string | null`，null 解析为 Chat），并通过 `resolveActiveView` 与 View 名单变化重算（`packages/client/ui-conversation/src/client/contract/views.ts:21`、`packages/client/ui-conversation/src/client/apply.ts:133`）。目标包的 `openView(view, focus)` 支持一次性的 focus 请求（`packages/client/ui-conversation/src/client/contract/slots.ts:203`）。

两个视图的呈现取向不同：Chat 是对话式（节点按回合/步排布，见 §3.3）；Trajectory 是阶段式，其快照由请求头（`TrajectoryRequestHeaderState`）、请求视图、调用 schema 表、部分助手、运行中调用，以及 `request-header` / `compaction` / `session-end` / `turn-end` 等贡献类型组成（`packages/client/ui-trajectory/src/client/trajectory-contract.ts:9`、`:18`、`:63`）。Trajectory 另有自己的图片座位 `conversation.trajectory.images`（`:95`）。

### 3.8 消息流内的滚动与导航行为

| 行为 | 事实 | 来源 |
|---|---|---|
| 回合导航 | Chat 快照暴露 `navigation.items()`：每个已加载 Turn 的抬头预览与应答预览 | `packages/client/ui-chat/src/client/contract/snapshot.ts:44` |
| 历史分页 | `chat.loadOlder()` 与本视图按 seq 跳读的 `loadThrough(seq)` | `packages/client/ui-chat/src/client/apply.ts:129` |
| 滚动位置 | 每 Session 记忆 `{anchorKey, anchorTop, scrollTop}` 读阅位置 | `packages/client/ui-chat/src/client/contract/slots.ts:117` |
| 分叉 | 回合内 `forkAt(seq)` 调用 `ctx.sessions.fork({sessionId, atSeq, increaseTitle: true})` 并打开子会话 | `packages/client/ui-chat/src/client/apply.ts:142` |
| 正文宽度拖拽 | 两侧宽度手柄对称调整正文宽度，偏好写入 `localStorage` 键 `dsh.conversation.contentWidth`，最小 640px | `packages/client/ui-conversation/src/client/skeleton/ConversationRoot.tsx:17`、`:40` |
| 主题化测量 | 滚动容器上发布 `--dsh-composer-height` 与 `--dsh-conversation-viewport-height` | `:164` |
| 设置项 | 已结算回合的转录呈现模式由 `settings.general.item` 的 `transcript-view` 行控制 | `packages/client/ui-chat/src/client/apply.ts:83` |

---

## 4. 输入区（composer）能力矩阵

### 4.1 视觉构成

composer 是常驻 DOM 节点，跨「无会话 / 有会话 / hero / 停靠」四个状态保持同一棵树，只切换 owner props 的惰性与禁用（`packages/client/ui-conversation/src/client/skeleton/ConversationRoot.tsx:319`）。`InputBar` 的元素顺序如下。

| 位置 | 元素 | 条件 | 来源 |
|---|---|---|---|
| 卡内浮层锚点 | `conversation.input.overlay` 列表（出厂装命令弹窗与 `/` `@` 菜单） | 有会话 | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:395` |
| 卡内附件轨 | `conversation.input.attachments`（出厂装草稿图片轨与拖放目标） | 总是渲染 | `:398` |
| 文本区 | 一个 Lexical contenteditable，chips 以 decorator portal 渲染；单滚动容器，CSS 上限 14 行 | 总是渲染 | `:413`、`:436` |
| 占位符 | 空草稿且未认领时显示；文案随状态变化（工作区缺失 / 不可用 / 转向队列 / plan / 默认） | 总是 | `:355`、`:431` |
| 工具栏左 | 命令按钮（`+`，打开命令菜单） | 总是 | `:441` |
| 工具栏左 | 权限芯片 `PermissionSelect`（`permissions` 投影喂数据） | 命令面存在时 | `:331` |
| 工具栏左 | `conversation.input.plan`（出厂装 PlanChip） | 有会话 | `:457` |
| 工具栏左 | `conversation.input.left` 列表 | 有会话 | `:459` |
| 工具栏右 | `conversation.input.right` 列表 | 有会话 | `:464` |
| 工具栏右 | `conversation.input.model`（出厂装 ModelSelect） | 有会话 | `:467` |
| 工具栏右 | 上下文占用环 `ContextMeter` | `contextPressure` 与容量同时可见时 | `:468` |
| 工具栏右 | 停止按钮（方块图标） | 可续子代理运行中 | `:469` |
| 工具栏右 | 主按钮：运行中且草稿为空时是停止，否则是发送（上箭头） | 总是 | `:485` |
| 卡下方 | `conversation.composer.dock` 列表（出厂装 StatsLine） | 停靠形态且状态可用 | `:508` |
| 卡上方 | `conversation.input.dock` 列表（出厂装 QueueDock、TodoDock、GoalDock） | 有会话 | `ConversationRoot.tsx:350` |
| 卡上方（hero） | 品牌外壳、工作区选择行、agent 预设座席 | hero 相位 | `ConversationRoot.tsx:348` |

`ContextMeter` 细节：默认只画一个 14px 圆环，点击展开面板，显示占用百分比、`~已用/窗口` 与 system / tools / messages 三段构成条形图；无压力或无容量时报空（`packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx:55`、`:106`）。

`TodoPanel` 细节：默认折叠，头部显示 `已完成 · 进行中 · 待处理` 计数（零值段省略），展开后逐条列出内容与状态字形（完成圆圈勾、进行中渐变环、待处理虚线环）；`todos` 为空则整体不渲染（`packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:88`、`:75`）。

### 4.2 键盘与手势

| 手势 | 行为 | 来源 |
|---|---|---|
| Enter | 菜单打开时选中高亮项；否则提交 | `packages/client/ui-conversation/src/client/input/editor/keymap.ts:109` |
| Ctrl/Cmd + Enter | 加速提交（`accelerated`），空草稿且队列有待发时改为「转向队列」 | `keymap.ts:127`、`InputBar.tsx:271` |
| Shift + Enter | 无条件换行（在 IME 守卫之前判定） | `keymap.ts:112` |
| 上/下箭头、Tab | 交给触发器菜单仲裁；菜单无高亮时 Tab 放行给浏览器原生焦点遍历 | `keymap.ts:85`、`:89` |
| Escape | 先关弹层；已认领命令态不释放（只能退格删 token） | `keymap.ts:90` |
| 空格 | 触发器判定，命中则消费该按键 | `keymap.ts:100` |
| 粘贴 | 剪贴板文件走图片摄取，纯文本走净化插入 | `keymap.ts:130` |
| 拖放 | 文档级文件拖入经同一校验路径加入草稿图片 | `packages/client/ui-conversation/src/client/contract/slots.ts:43` |
| IME 守卫 | 组合中的 Enter/空格不提交、不判定（含 Safari 组合结束后 10ms 窗口与 keyCode 229） | `keymap.ts:42`、`:58` |
| 长按 Enter | `event.repeat` 直接返回，不会连发 | `keymap.ts:125` |

### 4.3 提交机器

| 事实 | 来源 |
|---|---|
| 输入状态为 `InputState`：`draft`（chips 展开为剪贴板投影）、`imageIds`、`draftRev`、`phase`（`plain\|adjudicating\|claimed\|submitting`）、`claim`、`occurrences`、`queue` | `packages/client/ui-conversation/src/client/contract/input.ts:321` |
| 公开动作面 `InputActions` 只有 `setDraft`、`addImages`、`removeImage`、`pruneImages`、`submit` | `:221` |
| 输入是纯状态机：`InputEvent` 输入、`InputEffect` 输出，副作用由 shell 执行 | `:359`、`:380` |
| 提交后保留用户在往返期间新敲的后缀文本 | `:391` |
| 队列行来自会话控制快照，含 `placement`（如 `queued`） | `:334`、`InputBar.tsx:134` |
| 发送成功后由 shell 清空草稿并切断撤销历史 | `:391` |

### 4.4 附件（图片）

| 能力 | 事实 | 来源 |
|---|---|---|
| 摄取校验 | 先判格式，再判单条数量上限、单文件字节上限、整条消息总字节上限；整批拒绝并弹出提示，不进入轨道 | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:220` |
| 上限来源 | `imageLimits` 投影（无附件服务时该键缺席，校验全部交给 Host） | `:83` |
| 支持的媒体类型 | `image/png`、`image/jpeg`、`image/webp`、`image/gif` | `packages/client/ui-conversation/src/client/contract/input.ts:25` |
| 浏览器侧身份 | 草稿图片以 `DraftAttachmentId` 标识，字节与 URL 留在 ConversationController | `:325`、`packages/client/ui-conversation/src/client/apply.ts:307` |
| 附件展示插件 | `conversation.input.attachments` 装 `ComposerAttachments`；消息流图片座 `conversation.message.images` 装 `MessageImages`；trajectory 侧 `conversation.trajectory.images` | slot-catalog occupants |
| 历史图片 | `historical-images.ts` 负责已持久化图片的授权 URL 装载 | `packages/client/ui-conversation/src/client/conversation/historical-images.ts:42` |
| 上传路由 | **不存在独立上传路由**：图片在客户端转成规范 base64 提示部分，随 `session/prompt` 的 `PromptContentPart[]` 内联上传 | `packages/client/ui-conversation/src/client/service.ts:388`、`:397`（`base64Of` 于 `:119`） |

### 4.5 命令面（`/`）与引用面（`@`）

| 能力 | 事实 | 来源 |
|---|---|---|
| 触发器管道 | `ui-input-trigger` 提供检测、菜单、键盘仲裁与lexicon；`ui-commands` 在其上提供命令表面 | `packages/bundle/web-app/cordis.patch.yml:244` |
| 命令列表来源 | `ctx.remote.commands.list(sessionId)` | `packages/client/ui-commands/src/client/service.ts:142` |
| 命令执行 | `ctx.remote.commands.execute(sessionId, line, images)` | `:405` |
| 会话内直通执行 | `session.command(line)`，返回 `{ok, value:{matched}}` | `packages/client/ui-conversation/src/client/apply.ts:344` |
| 命令弹窗 | `conversation.input.overlay` 的 `PopupSelectView`（id `command-popup`） | slot-catalog |
| 触发菜单 | 同槽的 `MenuView`（id `slash-menu`） | slot-catalog |
| 命令按钮 | 工具栏 `+` 按钮调用 `toggleCommandMenu` 打开命令源 | `InputBar.tsx:298`、`:441` |
| 引用插入 | `@` 插入结构化引用 chip（`ReferenceInsert`：source / ref / label / appearance / clipboardText） | `contract/input.ts:52` |
| 引用候选来源 | 文件引用 `ctx.remote.fileReferences.list(...)`；会话引用 `ctx.remote.sessionReferenceResolver.candidates(...)` | `packages/client/ui-reference/src/client/index.ts:49`、`:53` |
| 技能候选 | `ui-skill` 提供 skill 候选（子代理寻址会话返回空） | `packages/client/ui-skill/src/client/index.ts:96` |
| 命令的图片能力 | 命令认领可声明 `images: true`，认领提交时可携带序列化图片 | `contract/input.ts:39`、`:48` |

### 4.6 模型选择

| 能力 | 事实 | 来源 |
|---|---|---|
| 两个入口一个目录 | `/model` popupSelect 与 composer 座席共享同一个每会话目录 | `packages/client/ui-model-selection/src/client/index.ts:1` |
| 目录来源 | `ctx.remote.session.modelCatalog()` | `packages/client/ui-model-selection/src/client/catalog.ts:45` |
| 座席 | `conversation.input.model` 装 `ModelSelect` | `index.ts:161` |
| 选择写入 | `directory.select(selection)`，带 provider / model / reasoningEffort | `index.ts:82`、`:173` |
| 子代理会话 | 带地址的子代理会话两个入口都不可用 | `index.ts:133`、`:166` |
| 阻断语义 | 模型座席在 owner 阻断（如缺凭据）时保持可用，因为选模型正是清除阻断的手段 | `InputBar.tsx:121` |

### 4.7 权限预设

| 能力 | 事实 | 来源 |
|---|---|---|
| 按钮位 | composer 工具栏 `PermissionSelect`，读 `permissions` 投影 | `InputBar.tsx:109`、`:331` |
| 命令装饰 | `/permission` 的 popupSelect 装饰，选项来自同一投影，`custom` 仅作显示态不可选 | `packages/client/ui-permission-presets/src/client/index.ts:59`、`:145` |
| 选择写入 | 提交 `/permission <preset>` 命令行，两个界面写同一条路径 | `:161` |
| 高风险确认 | `fullAccess` 预设带确认弹窗（标题/描述/确认/取消/启用） | `:67` |
| 缺能力时 | 投影键缺席即整块隐藏（Host 未组合权限服务） | `:150` |

### 4.8 plan 模式

| 能力 | 事实 | 来源 |
|---|---|---|
| 座席 | `conversation.input.plan` 装 `PlanChip`，仅当投影的有效目标为 plan 模式时渲染 | `packages/client/ui-plan/src/client/index.ts:55`、`:1` |
| 退出动作 | 执行 `/plan off`（`ctx.remote.commands.execute`） | `:61` |
| 占位符联动 | plan 激活时 composer 占位符切换为 plan 文案；转向提示优先级更高 | `InputBar.tsx:355` |
| 客户端状态 | 零客户端 plan 状态，全部读投影 | `index.ts:7` |

### 4.9 goal 操作

| 能力 | 事实 | 来源 |
|---|---|---|
| 入口 | `conversation.input.dock` 的 GoalDock（order 10），仅在投影非空时渲染 | `packages/client/ui-goal/src/client/index.ts:81`、`:62` |
| 四个动词 | `onEdit(objective)`、`onPause`、`onResume`、`onClear` | `:86` |
| CAS 引用 | 调用时从 `goal` 投影读 `{id, revision}`，无当前目标时返回 `no-current-goal` | `:69`、`:76` |
| 本插件不创建目标 | 创建由部署侧另行暴露（`/goal` 通道） | `:9` |
| 命令输入节点 | `conversation.chat.node` key `command-input` | `:60` |

### 4.10 composer 接管（chain 选举）

`conversation.composer` 是 chain 槽：每个条目提供纯 `select(owner)`，按 priority 升序取第一个非空结果，否则渲染默认 composer（`packages/client/ui-conversation/src/client/skeleton/ConversationRoot.tsx:356`）。出厂三个接管者：

| 接管者 | 触发条件 | 来源 |
|---|---|---|
| `SubagentReadOnlyComposer` | 子代理会话不可写 | slot-catalog `conversation.composer` occupants |
| `ApprovalPanel`（priority 1） | 该 Session 的挂起交互是 `PendingApproval` | `packages/client/ui-approval/src/client/index.ts:80`、`:83` |
| `QuestionComposer` | 该 Session 的挂起交互是 `PendingQuestion` | `packages/client/ui-user-questions/src/client/index.ts:94` |

同一 Session 同时只向 UI 暴露一个挂起交互，跨域按 precedence 竞争（plan-review 2 > 普通提问 1 > 审批 0）（`packages/client/ui-session/src/client/index.ts:366`、`packages/client/ui-user-questions/src/client/index.ts:91`、`packages/client/ui-approval/src/client/index.ts:77`）。

---

## 5. 侧边栏与导航层

### 5.1 侧边栏结构

`SidebarRoot` 只有一个列的几何与骨架，内容全部来自座席（`packages/client/ui-sidebar/src/client/SidebarRoot.tsx:52`）：

| 区域 | 元素 | 座席 | 来源 |
|---|---|---|---|
| 顶部左 | 品牌标记（展开态用作新建会话快捷入口） | `sidebar.brand.mark`（fallback：`FishLogo`） | `:152` |
| 顶部左 | 品牌名（本地构建时显示 `本地构建` + 版本号-commit-dirty） | `sidebar.brand.name` | `:155`、`:38` |
| 顶部右 | 折叠/展开按钮；折叠时悬停显示面板图标 | 外壳自持 | `:171` |
| 第二行 | 新建会话按钮 | 外壳自持（`startSession`） | `:190` |
| 中部 | 浏览区（工作区 + 会话列表 + 搜索） | `sidebar.workspaces` | `:205` |
| 底部 | footer 动作（出厂装 `cordis-panel`） | `sidebar.footer.action` | `:214` |
| 底部 | 设置入口 | `sidebar.settings` | `:217` |

折叠态是 56px 轨道：宽内容冻结在展开宽度淡出后被列裁剪，settle 后卸载；滚动条只在指针位于列内（或离开后 2s 内）绘制（`SidebarRoot.tsx:27`、`:35`、`:106`）。

### 5.2 工作区浏览器与会话列表

`WorkspaceBrowser` 占满 `sidebar.workspaces`，自持一个浏览视图 store，并声明一个目录流子座（`packages/client/ui-workspace/src/client/index.ts:138`、`packages/client/ui-workspace/src/client/contract/slots.ts:4`）。它读全局 `useWorkspaces` 钩子取得真实 Host 工作区（`index.ts:77`）。

| 用户操作 | 调用 | 来源 |
|---|---|---|
| 在指定工作区新建会话 | `uiWorkspace.startSession(workspaceId)`（未指定时继承当前会话工作区，再退到最近工作区） | `contract/slots.ts:105` |
| 打开会话 | `sessions.open(sessionId)` | `index.ts:102` |
| 搜索会话 | `sessions.search(query, signal)`，上限 `sessions.searchResultLimit`，`hasMore` 表示需收窄查询 | `index.ts:80`、`:104`、`contract/slots.ts:112` |
| 重命名会话 | `sessions.binding(sessionId).session.rename(title)` | `index.ts:105` |
| 分叉会话 | `sessions.fork({sessionId, increaseTitle: true})` 后打开子会话 | `index.ts:113` |
| 重命名工作区 | `workspaces.rename(workspaceId, title)` | `index.ts:120` |
| 删除工作区 | `workspaces.delete(workspaceId)`（只删注册，目录与会话日志保留） | `index.ts:121` |
| 重排工作区 | `workspaces.insertBefore(workspaceId, beforeWorkspaceId)` | `index.ts:122` |
| 归档会话 | `uiWorkspace.archiveSession(sessionId)`（归档当前会话会清空选择回到新会话视图） | `index.ts:125`、`contract/slots.ts:131` |
| 重排会话 | `workspaces.insertSessionBefore(workspaceId, sessionId, beforeSessionId)`（DOM insertBefore 语义） | `index.ts:126` |
| 采纳目录为新工作区 | `workspaces.create({path})` | `index.ts:129` |

### 5.3 目录选择器

`directory-picker` host 行在启动时解析绑定宿主、SSH 启动与显示方式，再挂载匹配的双面目录选择器（`cordis.patch.yml:80`）。两个选择器实现各注册到两个目录流座位：`conversation.hero.workspace.directoryFlow` 与 `sidebar.workspaces.directoryFlow`（slot-catalog occupants、`packages/client/ui-workspace/src/client/contract/slots.ts:56`）。

触发面（"添加工作区…"入口）只在对应座位被占时出现；占位者负责 `open` 到 `onPicked(path)` 之间的全部交互，包括新建目录（`contract/slots.ts:20`、`:41`）。

### 5.4 会话搜索

全文本会话搜索在 Web 面默认**关闭**：`session-query-sqlite` 被覆写为 `path: ':memory:'`、`openAt: never`（`packages/bundle/web-app/cordis.patch.yml:26`），因此 `session.search` 会抛 `SESSION_QUERY_SEARCH_DISABLED`（`packages/session-query/session-query-sqlite/src/index.ts:330`–`:338`）。实际后果是侧栏搜索只剩「本地标题 / 工作区名」半边可用，Host 内容命中不会返回；该错误的用户可见文案源码未明确。

部署可在后续 patch 层把 `openAt` 覆盖为 `first-search`，从而把 `node:sqlite` 导入与内存句柄推迟到首次搜索，保持 Node 22 启动安静（`cordis.patch.yml:21`–`:29` 的注释）。浏览器侧搜索输入为 250ms debounce 加 `AbortController`，本地命中优先、内容命中随后，空白会话永不命中（经 B 域核验）。

### 5.5 侧边栏列表的排序与分组

Host workspace 顺序加 `sessionIds` 存序决定分组内次序，未分组桶用本地序，最近更新会提升位置，长列表折叠阈值为 5 条（经 B 域核验）。会话标题来自 `packages/session/session-title`：三个来源新者胜（首条合格人类消息的 fallback / 异步 provider / 显式 rename），每次修订写入仅日志的 `session/title` 事件，用户显式标题会钉住该会话（`packages/session/session-title/src/types.ts:86`）。

**不存在「置顶」概念**：等价能力是 `orderBy: manual` 加拖拽重排——真实 workspace 组内的拖拽会持久化为 `insertSessionBefore`，未分组与扁平视图只写本地顺序（经 B 域核验）。

### 5.6 启动链与「无路由表」事实

`apps/web/src/main.ts` 调用 `dsh-client-web` 的 `AppWebEntry.run()`（`packages/client/web/src/boot.ts`）：等待 `__DSH_BOOT_READY__`、建立模块表、挂载 Cordis Loader、`assertEntriesActive()`，随后 `ctx.inject(['uiRenderer'])` 调用 `uiRenderer.mount(#root)`；存在 boot DOM 时走 `hydrateRoot`（经 B 域核验）。

**本 UI 没有路由表**：视图由 slot 占位者加会话选中态决定，composer 呈现分 `hero` / `active` / `settling` 三相（`packages/client/ui-conversation/src/client/skeleton/ConversationRoot.tsx:271`、`:353`）。

列宽解算是纯函数三步让步链（`packages/client/ui-layout/src/client/columns.ts`）：中列下限 640；侧边栏宽度档 264 / 280 / 420，收起轨道 56，自动收起断点 1024；详情列 300 / 360 / 520（经 B 域核验）。

### 5.7 设置入口与文档标题

设置入口占 `sidebar.settings`，出厂装 `SettingsRoot`（slot-catalog）。页面标题由 `AppFrame` 内的 `DocumentTitle` 从当前会话标题派生，产品名来自 `process.env.DSH_CLIENT_TITLE`（`packages/client/ui-layout/src/client/AppFrame.tsx:173`、`:184`）。

---

## 6. 设置界面

### 6.1 面板骨架

设置外壳自身零文案：触发器标签、面板标题、头部动作、关闭按钮无障碍名、各分区内容全部由注册者提供（`packages/client/ui-settings/src/client/contract/slots.ts:1`–`:9`）。出厂由 `ui-settings-general` 提供外壳文案与触发器/标题/关闭三座（slot-catalog：`SettingsRoot`、`TriggerContent`、`HeaderContent`、`CloseLabel`）。

| 座席 | 语义 | 出厂占位者 |
|---|---|---|
| `settings.trigger` | 侧边栏脚部设置行内容（图标+标签） | `TriggerContent` |
| `settings.header` | 面板标题文本座位 | `HeaderContent` |
| `settings.action` | 内容列头部、关闭按钮之前的动作列表 | `SettingsDocumentAction` id `open-document` |
| `settings.close` | 关闭按钮的视觉隐藏标签 | `CloseLabel` |
| `settings.section` | 每个条目一个设置页 | `GeneralSection` id `general`、`ModelsSection` id `models`、`PluginsSettingsSection` id `plugins`、`AgentPresetSection` id `agent-presets` |
| `settings.onboarding` | 有序新手引导步骤，外壳一次挂载一个 | `WelcomeNotice` id `welcome-notice`、`DeepSeekOnboardingDialog` id `deepseek-official` |

### 6.2 General 分区

`settings.general.item` 是加性列表座，一个偏好项一行，行自己画内部与标签（`contract/slots.ts:89`）。出厂六行：

| 行 id | 归属包 | 内容 |
|---|---|---|
| `language` | `client-locale` | 界面语言 |
| `appearance` | `ui-theme` | 外观（明/暗） |
| `font-size` | `ui-theme` | 字号 |
| `permission` | `ui-permission-presets` | 之后新建会话的默认权限预设；经 Host Settings API 写入 | 
| `composer-enter` | `ui-conversation` | 生成中回车的处理方式 |
| `transcript-view` | `ui-chat` | 已结算回合的转录呈现模式 |

各行写入分别走 `ctx.settingsScope`（通用设置域）或对应 RPC（`packages/client/ui-permission-presets/src/client/index.ts:125`、`packages/client/ui-conversation/src/client/apply.ts:110`、`packages/client/ui-chat/src/client/apply.ts:83`）。

### 6.3 Models 分区

| 座席 | 语义 | 出厂占位者 |
|---|---|---|
| `settings.models.provider-card` | 每个 provider 一张卡 | 出厂无占位者（由 `ui-settings-models` 的 section 内部渲染） |
| `settings.models.footer` | 分区底部 | 出厂无占位者 |

该分区的数据面 RPC：`ctx.remote.llm.listProviders()`、`ctx.remote.llm.listConfigurableProviders()`、`ctx.remote.llm.discoverModels(settingsNs, request)`、`ctx.remote.credentials.describe/set/unset`、`ctx.remote.settings.mutate(ns, ops, expectedRevision)`（`packages/client/ui-settings-models/src/client/store.ts:182`、`packages/client/ui-settings-models/src/client/operations.ts:85`–`:103`）。

### 6.4 Plugins 分区

Plugins 分区有两个 tab：`all`（插件清单，`PluginInventorySettingsTab`）与 `configurable`（可配置插件卡片，`ConfigurablePluginsTab`）（slot-catalog）。可配置卡片座席 `settings.plugin.item` 出厂四张：`BashCard`、`AgentLoopCard`、`SubagentModelSelectionCard`、`WebSearchCard`（slot-catalog、`packages/client/ui-settings-plugins/src/client/slot-contract.ts:19`）。清单数据来自 `ctx.remote.pluginInventory.list()`（`packages/client/ui-settings-plugin-inventory/src/client/index.ts:37`）。

### 6.5 设置读写通道与主题

| 能力 | 事实 | 来源 |
|---|---|---|
| 面板打开态 | 外壳持有；分区收到 `close` 回调 | `contract/slots.ts:123` |
| 通用读写 | `ctx.settingsScope`（describe / bind / mutate），镜像更新发生在文档提交与重连之后 | `packages/client/ui-remotes` 未见；见 `packages/client/ui-settings/src/client/settings-scope.ts:131`、`packages/client/ui-permission-presets/src/client/index.ts:124` |
| 打开设置文档 | `ctx.remote.settings.openSettingsDocument()` | `packages/client/ui-settings-general/src/client/settings-document-store.ts:65` |
| 主题 | `ui-theme` 提供 `AppearanceRow`、`FontSizeRow` 两行与全局 `--dsw-*` token 表 | slot-catalog、`packages/client/AGENTS.md`（Styling and localization 段） |
| 主题细节 | 偏好取值 `light` / `dark` / `system`（默认 `system`）；字号范围 12–17（默认 14）；命名空间 `ui-theme`；Host 注入内联 boot 脚本防止首屏闪烁；`ThemeRuntime` 持有 `prefers-color-scheme` 监听与 override 叠层（token 必须同时给 light/dark 对，否则抛类型错误）；共 13 个 `--dsw-*` 别名令牌 | 经 B 域核验 |
| 主题 DOM 投影 | 实际写入位置在 `packages/client/ui-layout/src/client/theme-presenter.ts`（写 `colorScheme`、`body[data-ds-dark-theme]`、`--dsh-content-font-size`、令牌内联变量与 `meta theme-color`） | 经 B 域核验 |
| 本地化机制 | 每个产品可见字符串走类型化字典经 `t` 座位；`client-locale` 提供语言行 | `packages/client/AGENTS.md` 同上、slot-catalog |
| 语言清单 | 只签入 **zh 与 en** 两种；fallback 恒为 en；`register(ns, {zh, en})` 强制双语平衡；初始值由 `navigator.languages` 推导；语言包插件可 `addLanguage`，但链必须终止于 en | 经 B 域核验（`packages/client/locale`） |
| 非 loopback 页面的限制 | 设置持久化降级为 `memory`（`packages/client/ui-settings/src/client/index.ts:58`），scope 起始即 `unavailable`，所有设置行惰性渲染；`ui-settings/README.md` 将此列为已知限制 | 经 B 域核验 |

---

## 7. RPC 与事件面

### 7.1 Web UI 实际调用的 Remote 方法

以下为在 `packages/client/**` 中检索到的全部 `ctx.remote.<namespace>.<method>()` 调用点，即浏览器实际发起的请求面。

| 命名空间 | 方法 | 调用点 |
|---|---|---|
| `messageFeedback` | `put` / `delete` / `list` | `packages/client/ui-message-feedback/src/client/controller.ts:221`、`:243`、`:266` |
| `goals` | `edit` / `pause` / `resume` / `clear` | `packages/client/ui-goal/src/client/index.ts:90`、`:95`、`:100`、`:105` |
| `commands` | `list` / `execute` | `packages/client/ui-commands/src/client/service.ts:142`、`:405`；`packages/client/ui-plan/src/client/index.ts:61` |
| `settings` | `describe` / `mutate` / `update` / `openSettingsDocument` / `canOpenAgentPresetDirectory` / `openAgentPresetDirectory` | `packages/client/ui-settings/src/client/settings-mirror.ts:183`、`settings-scope.ts:131`、`packages/client/ui-agent-preset/src/client/settings-store.ts:32`、`settings-document-store.ts:65`、`section-store.ts:172`、`:290` |
| `llm` | `listProviders` / `listConfigurableProviders` / `discoverModels` | `packages/client/ui-settings-models/src/client/store.ts:182`、`:183`、`operations.ts:103` |
| `credentials` | `describe` / `set` / `unset` | `packages/client/ui-settings-models/src/client/operations.ts:85`、`:89`、`:93` |
| `session` | `modelCatalog` / `canOpenWorkspacePath` / `openWorkspacePath` | `packages/client/ui-model-selection/src/client/catalog.ts:45`、`packages/client/ui-deliverables/src/client/index.ts:48`、`packages/client/ui-chat/src/client/apply.ts:124` |
| `pluginInventory` | `list` | `packages/client/ui-settings-plugin-inventory/src/client/index.ts:37` |
| `agentPresets` | `list` / `read` / `copy` / `select` / `deletePreset` | `packages/client/ui-agent-preset/src/client/settings-store.ts:66`、`section-store.ts:206`、`:269`、`seat-store.ts:160`、`section-store.ts:320` |
| `fileReferences` | `list` | `packages/client/ui-reference/src/client/index.ts:49` |
| `sessionReferenceResolver` | `candidates` | `packages/client/ui-reference/src/client/index.ts:53` |
| `directoryPicker` | 经 `UiWorkspaceService` 使用 | `packages/client/ui-workspace/src/client/index.ts:75` |
| `$host` / `$on` | 只读宿主事实与事件转发入口 | `packages/client/ui-tool/src/client/apply.ts:29`、`packages/client/ui-approval/src/client/index.ts:90` |

模型选择写入经 `session.selectModel`（`packages/client/ui-model-selection/src/client/index.ts:6` 的模块契约说明）。

### 7.2 会话控制服务（`ctx.sessions`）

| 方法/属性 | 语义 | 证据 |
|---|---|---|
| `sessions.list` | 会话列表状态源（`current`、`byId`），可订阅 | `packages/client/ui-session/src/client/index.ts:509` |
| `sessions.binding(id)` | 取该会话的绑定（含 `session`、`sessionId`、`ctx`） | `packages/client/ui-conversation/src/client/apply.ts:345` |
| `sessions.scope(id)` / `sessions.scopeOf(actx)` | 会话作用域解析与反查 | `packages/client/ui-conversation/src/client/input/hub.ts:69` |
| `sessions.open(id)` | 选中并打开会话 | `packages/client/ui-workspace/src/client/index.ts:102` |
| `sessions.fork({sessionId, atSeq, increaseTitle})` | 分叉会话 | `packages/client/ui-chat/src/client/apply.ts:143` |
| `sessions.search(query, signal)` | 会话搜索 | `packages/client/ui-workspace/src/client/index.ts:81` |
| `sessions.searchResultLimit` | Host 固定的结果上限 | `packages/client/ui-workspace/src/client/index.ts:104` |
| `sessions.subagentAddress(id)` | 子代理寻址判定（有值则模型选择、技能候选等降级） | `packages/client/ui-model-selection/src/client/index.ts:133` |
| `sessions.openSubagent(address)` | 打开带地址的子代理会话 | `packages/client/ui-subagent/src/client/index.ts:56` |
| `sessions.remove(id)` | 释放会话 | `packages/client/ui-conversation/src/client/input/hub.ts`（测试对照：`packages/client/ui-session/tests`） |
| `session.command(line)` | 会话内命令通道 | `packages/client/ui-conversation/src/client/apply.ts:344` |
| `session.rename(title)` / `session.rename` | 会话重命名 | `packages/client/ui-workspace/src/client/index.ts:110` |
| `session.loadOlder()` / `session.loadThrough(seq)` | 历史分页与跳读 | `packages/client/ui-chat/src/client/apply.ts:129` |
| `session.projections.faceOf(key)` | 按投影键取可订阅面 | `packages/client/ui-goal/src/client/index.ts:70` |
| `conversation.cancel()` | 停止当前生成（scoped 服务） | `packages/client/ui-conversation/src/client/apply.ts:340` |

Host 侧由 `@deepseek-ai/dsh-api-session-controller` 持有 `ctx.sessionController`，并向浏览器生成 `session`、`skills`、`fileReferences` 三个 Remote 命名空间（`packages/api/session-controller/README.md:11`）。该 README 给出的激活策略是：列表、搜索、附件、历史分页、日志跟随、技能发现、工作区路径打开都可在不激活 Agent 的情况下读持久化；队列变更与取消需要活状态；模型、重命名、提示、文件引用操作可能解析或恢复会话；创建与分叉是仅有的两个直接创建新 Agent 的操作（`:28`）。

两条历史分页动词：`loadOlder()` 拉取一页 50 条消息，`loadThrough(seq)` 是回合跳转加载器，按 200 条一页循环直到窗口覆盖目标 seq；重复调用会降低共享目标，遇到无进展的一页即停止，并通过同一个 `loadingOlder` 快照位报告忙碌（`:30`）。普通记录覆盖 `[event.seq, event.seq]`，打包行覆盖 `[event.seq, event.seq + memberCount - 1]`（`:30`）。

提交回声：`session.beginSubmission` 在调用方序列化与提示之前就同步插入一条回声到 `SessionSnapshot.pendingSubmissions`，使对话界面能在点击那一帧显示消息；放置类型（`transcript` / `queued` / `steering`）由当前运行状态与请求的投递模式派生，并在序列化期间保持；关联标识是 `requestId`，Host 会把它回显为持久用户来源的 `rpcId`（`:32`）。回声在对应持久事件或队列项被观察到之后一帧退役，失败或放弃时立即退役；回声只存在于客户端内存，重载与重连仅用持久事件重建会话（`:32`）。

### 7.3 事件转发与请求-应答

| 机制 | 事实 | 来源 |
|---|---|---|
| 逻辑流 | 内部 `$events` 逻辑流是连接代数的来源；开场 `ready` 帧携带 Host home 并建立代数 | `docs/subsystems/web-client.md:32` |
| 普通事件 | `ctx.remote.$on()` 把允许列表内的普通事件投递到根 Client Context | `docs/subsystems/web-client.md:32` |
| 作用域瀑布 | 解析到会话 Context 的瀑布事件，监听者可返回结果、`next()` 或拒绝 | `docs/subsystems/web-client.md:32` |
| 审批 | 瀑布事件 `approval/request` | `packages/client/ui-approval/src/client/index.ts:90` |
| 提问 | 瀑布事件 `user-questions/request` | `packages/client/ui-user-questions/src/client/index.ts:104` |
| allowlist 归属 | `API_REMOTE_FORWARDED_EVENTS`，共 18 条（16 `emit` + 2 `waterfall`） | `packages/api/remotes/src/remote-events.ts:16`–`:35` |
| waterfall 应答路径 | 下行经 mux 的 `waterfall` 帧，上行**走 HTTP 一元调用** `connection.rpc.call('/api', '$events/result', { args })`，不占 mux 通道 | `packages/api/gateway/src/client/remote-events.ts:214`、`:233` |
| 转发帧类型 | `ready`（含 `clientId` 与 `host.home`）、`emit`、`waterfall`、`cancel`，结果 `outcome = next \| result{value} \| rejected{error}` | `packages/api/gateway/src/stream-protocol.ts:33`、`:44`、`:51`、`:60`、`:87` |
| 非 JSON 安全的 emit 参数 | Host 侧直接抛错，不做降级 | `packages/api/remotes/src/index.ts:158` |

转发的 18 个事件（`mode` 决定投递方式）：

`agent-preset/selected`（emit）、`api-session/activity`（emit）、`api-session/added`（emit）、`api-session/error`（emit）、`api-session/removed`（emit）、`api-session/status`（emit）、`commands/change`（emit）、`credentials/reference-updated`（emit）、`cordis/request-run`（emit）、`cordis/request-run-resolved`（emit）、`cordis/dynamic-package`（emit）、`cordis/dynamic-retract`（emit）、`cordis/inspect-query`（emit）、`cordis/inspect-query-resolved`（emit）、`llm/adapters-updated`（emit）、`settings/document-updated`（emit）、`approval/request`（waterfall）、`user-questions/request`（waterfall）。

### 7.4 传输层（HTTP 路由与物理载体）

Host 侧唯一的路由注册点是 `ctx.webServer`（`packages/host/webserver/src/index.ts:38`、`:133`–`:135`、`:165`、`:180`、`:196`）。

| 路径 | 类型 | 所有者 | 语义 |
|---|---|---|---|
| `/api` | prefix Fetch 桥 | `client-connection` 的 Host 半（`packages/client/connection/src/index.ts:114`–`:127`） | 先过 Host/Origin fence 与 cookie 鉴权，再桥接为 Fetch |
| `/api/<namespace>/<method>` | 共享通道端点，POST JSON | Gateway 拦截（`packages/api/gateway/src/index.ts:199`–`:203`） | 一元 RPC；未认领返回 404 |
| `/api/remote.mux` | WebSocket upgrade | `api-gateway`（`packages/api/gateway/src/index.ts:211`–`:228`） | 所有 Remote 流（`follow` / `control` / `$events`）复用的唯一物理 socket |
| `/api/session.export` | exact route，GET/HEAD | `session-log-export`（`packages/session-query/session-log-export/src/index.ts:39`、`:81`–`:94`） | query `sessionId`，可选 `includeDescendants`，返回 zip |
| `/plugins` | prefix | `client-modules` 节点半（`packages/client/modules/src/index.ts:586`） | `/plugins/<id>/client.js` 与组合包、map |
| `/plugins/events` | SSE | `client-hmr`（`packages/client/hmr/src/events.ts:44`） | 客户端插件热重载事件流 |
| 其余全部 | fallback | `frontend-static`（`packages/host/frontend-static/src/index.ts:124`–`:142`） | `/` 与 index 路径先过 `authorizeIndex`，其余静态资源公开 |

**载体事实纠正**：Remote 流的物理载体是 WebSocket mux，不是 SSE；浏览器侧唯一的 `EventSource` 是 HMR 那条（`packages/client/hmr/src/client/index.ts:166`）。`cordis.patch.yml:161` 把 connection 行注释成 "fetch/SSE client"，是注释措辞，与源码不符。

连接代数与重连：`ConnectionController` 持有 `generation` / `attempt` 私有状态且不进 store（`packages/client/connection/src/client/connection.ts:90`）；退避默认 `500ms` 起、上限 `10s`、因子 2，每次延迟取 cap/2 加随机抖动（`:27`–`:32`、`:157`–`:160`），最终档进入 `disconnected` 停止重试；浏览器 `offline` 挂起自动重试、`online` 把 attempt 归零并从 500ms 档重开（`:140`–`:150`）；generation 只在 source 报告 `ready` 之后发布，之后才允许跑基线读取（`packages/client/connection/src/client/index.ts:265`–`:281`）。

trust fence 是两道独立的门：Host/Origin 校验失败返回 403，浏览器鉴权失败返回 401（`packages/client/connection/src/rpc-host.ts:95`–`:99`）。Host 必须是 loopback 或命中 `trustedHosts`（条目带端口为精确匹配，不带端口匹配该 hostname 的任意端口）；`sec-fetch-site: cross-site` 一律拒绝；带 `Origin` 时必须与 Host 同权威（`packages/client/connection/src/api-request-trust.ts:91`–`:118`）。鉴权用每进程随机 launch token，仅在 `GET /` 单 token 匹配时写 HMAC 签名的 cookie（`Path=/; HttpOnly; SameSite=Strict`，不带 `Secure`）并 302 到干净路径（`packages/client/connection/src/browser-auth.ts:107`、`:122`、`:126`–`:158`、`:240`–`:268`）。
| 重连语义 | 物理与逻辑恢复分离：网关 mux 恢复载体，各 `RemoteStream` 在可用代数出现时重开自己的逻辑源；持久日志用开场快照替换窗口，控制流保留最后值后被新基线原子替换，普通通知不重放 | `docs/subsystems/web-client.md:74`–`:80` |

### 7.5 投影键表（`useProjection(key)` 的可用键）

| 键 | 提供者 | 含义 |
|---|---|---|
| `sessionListMetadata` | session-controller | 不激活会话即可摘要的持久事实 |
| `imageLimits` | session-controller | 图片摄取上限（composer 预校验） |
| `modelSelection` | session-controller | 已选模型选择 |
| `sessionStats` | session-stats | 全日志回合/步计数与墙钟时间 |
| `turnOutline` | session-turn-outline | 每个已开始回合的 start seq 与有界预览 |
| `title` | session-title | 归一化标题（last-wins，首条之前为 null） |
| `goal` | goal | 当前目标与已接纳轮数 |
| `plan` | plan-mode | plan 协作状态 |
| `todos` | tool-todo | 当前整份待办列表（整值替换，last-wins） |
| `permissions` | permission-presets | 权限选择（键缺席即无权限服务，客户端隐藏控件） |
| `tokenUsage` | token-meter | 全日志累计用量 |
| `contextPressure` | token-meter | 最新请求压力 + 最新已知容量 |
| `contextBreakdown` | token-meter | 下一次请求的 system/tools/messages 启发式构成 |
| `subagentTiming` | subagent | 子代理活动轮时长 |
| `subagent` | subagent | 子代理身份（无有效描述符为 null） |
| `agentPreset` | agent-presets | 会话运行的预设名 |
| `schedule` | schedule | 本会话 fork 后缀拥有的提醒 |

来源：`packages/api/session-controller/src/types.ts:25`、`packages/session/session-stats/src/types.ts:42`、`packages/session/session-turn-outline/src/types.ts:45`、`packages/session/session-title/src/types.ts:86`、`packages/goal/goal/src/types.ts:116`、`packages/plan/plan-mode/src/types.ts:43`、`packages/todo/tool-todo/src/types.ts:39`、`packages/interaction/permission-presets/src/types.ts:35`、`packages/llm/token-meter/src/projection.ts:69`、`packages/subagent/subagent/src/projection-types.ts:52`、`packages/preset/agent-presets/src/types.ts:65`、`packages/schedule/schedule/src/types.ts:224`。

补充事实（经 D1 域核验）：

| 事实 | 内容 |
|---|---|
| 投影键总数 | 共 25 个：上表 17 个为客户端可见键，其余 9 个是 host-only 键 |
| host-only 键 | `turnBoundary`、`timeContext`、`tmuxContext`、`llmRetry`、`sandboxMode`、`subagentModelSelectionPolicy`、`agentTeam`（另有 `titleInput`） |
| 客户端真实读取量 | 以 `useProjection` 字面键读取的只有 11 个；另有 3 个通过组件 prop 或投影 face 间接可达 |
| 读取方式的区分 | 消费矩阵必须区分三类：真 `useProjection` 字面键、投影 face 调用（如 `projections.faceOf('modelSelection')`，`packages/client/ui-model-selection/src/client/service.ts:82`）、组件 prop 传递（如标题经 prop 进入 DocumentTitle）；混为一谈会得到错误结论 |
| 无客户端消费点的键 | `compaction/prune`、`request/context` 以及全部审计类事件（approval / hook / web / title-llm）未找到客户端消费点 |

---

## 8. 最小可用信息密度分级

判定标准：缺了它，界面就不再是同一款产品（核心），还是可以整块留白而不改变产品身份（次要）。

| 模块 | 判定 | 依据 | 缺失后果 |
|---|---|---|---|
| 三列框架与 `root` 渲染 | 核心 | `packages/client/ui-layout/src/client/AppFrame.tsx:176` | 无页面骨架 |
| 会话消息流（`conversation.session` + `conversation.view` + ChatView） | 核心 | `packages/client/ui-chat/src/client/apply.ts:94` | 无对话主体 |
| keyed 节点渲染器（user / assistant-step / tool-call / turn-tail / turn-error 等） | 核心 | `packages/client/ui-chat/src/client/chat/register-node-renderers.ts:17` | 消息流为空壳 |
| composer（`conversation.composer.bar` = InputBar） | 核心 | `packages/client/ui-conversation/src/client/apply.ts:271` | 无法发消息 |
| 发送/停止与会话提示错误 | 核心 | `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:315`、`:94` | 无法控制生成 |
| 侧边栏 + 工作区/会话列表 | 核心 | `packages/client/ui-workspace/src/client/index.ts:138` | 无法切换会话 |
| 会话标准钩子（`useSessions`/`useSession`/`useProjection`） | 核心 | `packages/client/ui-session/src/client/index.ts:104` | 所有会话界面失去数据源 |
| 工具调用卡片与详情 | 核心 | `packages/client/ui-tool/src/client/apply.ts:33` | 无法观察工具行为 |
| 审批接管 | 核心 | `packages/client/ui-approval/src/client/index.ts:80` | 需要审批的工具会卡住 |
| 用户提问接管 | 核心 | `packages/client/ui-user-questions/src/client/index.ts:94` | 反问型交互会卡住 |
| 附件摄取与消息图片 | 次要 | `packages/client/ui-attachment/src/client/index.ts` | 纯文本仍可用 |
| 命令面 `/` 与引用面 `@` | 次要 | `packages/client/ui-commands`、`ui-input-trigger`、`ui-reference`、`ui-skill` | 文本通道仍可用，能力发现变差 |
| 模型选择座位与 `/model` | 次要（多 provider 部署下接近核心） | `packages/client/ui-model-selection/src/client/index.ts:161` | 无法换模型 |
| 权限预设（芯片 + `/permission` + 设置行） | 次要 | `packages/client/ui-permission-presets/src/client/index.ts:145` | 无权限服务时本就不渲染 |
| plan 芯片 | 次要 | `packages/client/ui-plan/src/client/index.ts:55` | plan 模式仍可由命令进入 |
| goal 条 | 次要 | `packages/client/ui-goal/src/client/index.ts:81` | 无目标时本就不渲染 |
| todo 面板 | 次要 | `packages/client/ui-conversation/src/client/skeleton/TodoPanel.tsx:88` | 无待办时本就不渲染 |
| 队列 dock | 次要 | `packages/client/ui-conversation/src/client/queue/QueueDock.tsx` | 运行中无法排队 |
| 后台任务列表 | 次要 | `packages/client/ui-jobs/src/client/index.ts:32` | 无任务时本就不渲染 |
| 产出行 + 文件提及链接 | 次要 | `packages/client/ui-deliverables/src/client/index.ts:69` | 回合尾部留白（该插件移除即整体关闭） |
| 上下文占用环 | 次要 | `packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx:87` | 无压力数据时本就不渲染 |
| 统计行 | 次要 | `packages/client/ui-chat/src/client/apply.ts:155` | 回合尾部少一行 |
| trajectory 视图 | 次要 | `packages/client/ui-trajectory/src/client/trajectory-contract.ts:95` | 视图 tab 不出现（注册数 ≤1 不渲染 tab 栏） |
| 消息 feedback（点赞/点踩+备注） | 次要 | `packages/bundle/web-app/cordis.patch.yml:278` | 消息操作条少一项 |
| 设置面板全部 | 次要（凭据配置在多 provider 部署下接近核心） | `packages/client/ui-settings/src/client/contract/slots.ts:54` | 无法配置 provider |
| 品牌标记/名称 | 可裁剪 | `packages/bundle/web-app/cordis.patch.yml:217` | 回落为内置鱼形标记与「本地构建」 |
| 子代理血缘与只读接管 | 次要 | slot-catalog：`SubagentHeaderLineage`、`SubagentReadOnlyComposer` | 子代理会话辨识度下降 |
| 工作流运行面板 | 次要 | slot-catalog：`WorkflowRunPanel` key `workflow-run` | 工作流运行不可见 |
| 自省面板（`cordis-panel`）与 cordis 工具视图 | 可裁剪 | slot-catalog：`sidebar.footer.action`、`tool.call.toolview` 的 cordis 键 | 面向开发者的自省能力消失 |
| Schedule 目录 | 可裁剪（出厂即禁用） | `packages/bundle/web-app/cordis.patch.yml:264` | 无影响（默认关闭） |

---

## 附录 A：源码未明确与源码不存在项

### A.1 源码中明确不存在

| 项 | 事实 |
|---|---|
| Wear OS / 小屏适配代码 | 源码中不存在（本仓库面向桌面 Web） |
| 路由表 | 不存在；视图由 slot 占位者与会话选中态决定（见 §5.6） |
| 会话流内的「重试」/「编辑」按钮 | 源码未提供（经 C 域核验） |
| 工具卡片上的耗时字段 | 不存在；耗时只在 turn-tail（经 C 域核验） |
| 客户端 spill 实现 | 不存在；spill 由 Host 落盘，客户端只显示 `spill://` 定位（经 C 域核验） |
| 内建审批 diff 预览 | 不存在（经 C 域核验） |
| 子代理与工作流的 keyed toolview | 不存在；子代理走头部血缘 + composer 接管，工作流走独立 chat node（经 C 域核验） |
| 「置顶」概念 | 不存在；等价能力是 `orderBy: manual` 加拖拽（见 §5.5） |
| 输入区的独立上传路由 | 不存在；图片内联进 `session/prompt`（见 §4.4） |
| composer 侧的数组化提交 block | 不存在；真实结构是 `Occurrence[]` 加 `PromptContentPart[]` |
| `packages/api/plugin-inventory` | 该包不存在，只读清单在 `packages/host/plugin-inventory` |
| `settings-controller` 的 Client 面 | 不存在（纯 Host 包） |
| 独立 RPC 形式的审批应答、plan 开关、权限切换 | 均不存在；分别经 waterfall 返回值、`/plan off` 命令、`/permission <id>` 命令 |
| 浏览器侧承载 Remote 的 EventSource | 不存在；Remote 走 WebSocket mux，唯一 SSE 是 HMR |
| `conversation.input.left` / `input.right` 的注册者 | 本仓库无占位者（仅声明与渲染点） |

### A.2 未核验或细节不足

| 项 | 状态 |
|---|---|
| 每个 slot 的完整 ownerProps 类型展开 | 未逐条抄录；权威来源为 `packages/extensions/cordis-client-runner/src/client/slot-catalog.ts` 的 `ownerProps` 字段 |
| 各 keyed 工具视图的字段级渲染细节 | 本文列到组件与模型文件层级；字段级细节见 `packages/client/ui-tool/src/client/tool/models/` |
| 搜索被禁用时的用户可见错误文案 | 源码未明确（见 §5.4） |
| `ui-directory-picker-*` 调用 `directoryPicker` 的具体路径 | 包内未检出方法级直接调用点（命名空间对象被整体注入 `UiWorkspaceService`） |
| `compaction/prune`、`request/context` 及审计类事件的客户端消费点 | 未找到 |
| Plan 模式的进入路径 | 由 `plan-mode` 包负责，不在客户端 UI 域内（本域只看到 PlanChip 的退出动作） |

### A.3 已由本次分析解决的早期疑点

| 项 | 结论 |
|---|---|
| Remote 事件转发 allowlist 内容 | 已核实为 18 条，见 §7.3 |
| 语言枚举清单 | 已核实为 zh 与 en 两种、fallback 恒为 en，见 §6.5 |
| slot 座位总数 | 已核实为 52 条，见 §2.2 |
| 浏览器 roster 行数 | 已核实为 40 行，见 §1.1 |
| 事件词汇总量 | 已核实为 51 项，见 §3.2.1 |

## 附录 B：`SessionEventMap` 声明合并点（事件词汇的来源文件）

除基础表 `packages/core/session/src/types.ts:259` 外，全仓库共 24 处 declaration merging 扩展点（已排除 `tests/`）。权威的合并结果见 §3.2.1 的 51 项集合：

`packages/core/agent/src/types.ts:52`、`packages/core/tools/src/types.ts:26`、`packages/api/session-controller/src/types.ts:36`、`packages/goal/goal/src/domain.ts:62`、`packages/plan/plan-mode/src/index.ts:40`、`packages/todo/tool-todo/src/types.ts:29`、`packages/interaction/commands/src/types.ts:86`、`packages/interaction/user-approval/src/types.ts:35`、`packages/interaction/user-approval/src/index.ts:24`、`packages/interaction/permission-presets/src/index.ts:46`、`packages/feedback/command-feedback/src/index.ts:57`、`packages/session/session-title/src/index.ts:72`、`packages/session/session-title-llm/src/index.ts:43`、`packages/session/session-log-deepseek/src/types.ts:55`、`packages/subagent/subagent/src/descriptor.ts:30`、`packages/subagent/tool-subagent/src/model-selection-state.ts:10`、`packages/workflow/tool-workflow/src/types.ts:42`、`packages/compaction/compaction/src/types.ts:18`、`packages/schedule/schedule/src/types.ts:214`、`packages/hooks/hook-protocol/src/types.ts:9`、`packages/sandbox/sandbox-policy/src/session-mode.ts:25`、`packages/llm/llm-retry/src/types.ts:7`、`packages/web/web-search-deepseek/src/provider.ts:81`、`packages/preset/agent-presets/src/session.ts:21`、`packages/experimental/agent-team/src/types.ts:220`（贡献 `team/member`、`team/task`、`team/message/queued`、`team/message/delivered` 四项；此项易被漏计）。

校验事实：上述 25 处声明点的合并结果与生成物 `KNOWN_SESSION_EVENT_TYPES` 的 51 项完全一致，无缺无多（经 D1 域机械校验）。

注意一个陷阱：`agent-preset/selected` 同时存在一个**同名的 Cordis 事件**（声明于 `packages/preset/agent-presets/src/types.ts:80`），它与同名 session 事件属于两张不同的表（经 D1 域核验）。
