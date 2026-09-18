# B 域：布局 / 侧边栏 / 导航 / 设置

源码根：`third_party/deepseek-harness`（tag `dsh-v0.1.2-rc.1`，commit `a66e4702`）。
本文只依据源码与签入文档；凡源码未明确者，显式标注「源码未明确」。
所有行号均为该快照下的实际行号，路径相对源码根。

---

## 1. 整体页面骨架

### 1.1 组装链（自底向上）

| 层 | 事实 | 来源 |
|---|---|---|
| 浏览器 HTML 入口 | `apps/web/index.html` 提供 `#root`；`apps/web/src/main.ts` 只做一件事：`new AppWebEntry(el).run()` | `apps/web/src/main.ts:1-6` |
| 启动内核 | `AppWebEntry` 拥有「模块系统 + Cordis Loader + 无框架 boot 页」三件事；`run()` 先等待 `globalThis.__DSH_BOOT_READY__.promise`，再用 `window.__ModuleLoader__.create({ boot: window.__DSH_BOOT__, staticModules })` 建模块表，然后 `ctx.plugin(Loader)`、为 `manifest.plugins` 逐行 `loader.create({ name })`、`loader.await()`、最后 `assertEntriesActive()` 校验每一行都 active | `packages/client/web/src/boot.ts:46-135` |
| 平台单例表 | 只共享 8 个模块身份：`react`、`react/jsx-runtime`、`react-dom`、`react-dom/client`、`@deepseek-ai/cordis`、`dsh-client-store`、`dsh-client-ui-slots`、`dsh-client-ui-primitives` | `packages/client/web/src/seed.ts:23-36` |
| 挂载点交接 | `mountApp()` 用 `ctx.inject(['uiRenderer'], …)` 在 `uiRenderer` 激活后调用 `scope.uiRenderer.mount(this.container)`，因此替换 `uiRenderer` 会整树重挂 | `packages/client/web/src/boot.ts:95-101` |
| 渲染器 | `ui-renderer` 的 `mount()` 若发现容器内已有 `:scope > [data-dsh-boot]` 则走 `hydrateRoot` + `BootHandoff`（首帧保留 boot DOM，`useLayoutEffect` 后切换到 app），否则 `createRoot` + `flushSync` | `packages/client/ui-renderer/src/client/index.ts:58-80` |
| 骨架 | `ui-layout` 把 `AppFrame` 注册进内建 `root` slot，并在同一次 `register()` 里声明四个子 slot + 装一个 store（`createLayoutStore`）+ 用 `inject` 钩子把 store 的 bound actions 接到 `ctx.layout` 服务 | `packages/client/ui-layout/src/client/index.ts:118-146` |
| 三列网格 | `gridTemplateColumns: ${cols.sidebar}px minmax(0,1fr) ${cols.details}px`，列 occupant 固定位置：`sidebar` / `conversation`(CenterColumn) / `details`(DetailsColumn，外包 `SessionProvider`) / `shell.overlay` 浮层 | `packages/client/ui-layout/src/client/AppFrame.tsx:175-216` |
| 文档标题 | `DocumentTitle` 把当前 session 的持久标题写进 `document.title`，形式 `${title} — ${productTitle}`；`productTitle = process.env.DSH_CLIENT_TITLE ?? t('brand.localBuild')` | `packages/client/ui-layout/src/client/DocumentTitle.tsx:17-22`、`AppFrame.tsx:173` |

### 1.2 列宽解算（concession chain）

`computeColumns(viewport, sidebar, details)` 是纯函数，固定几何常量如下（全部 `columns.ts`）：

| 常量 | 值 | 含义 | 来源 |
|---|---|---|---|
| `CENTER_MIN` | 640 | 中列下限，只有最后回退可突破 | `ui-layout/src/client/columns.ts:21` |
| `SIDEBAR_MIN` / `SIDEBAR_MAX` / `SIDEBAR_DEFAULT` | 264 / 420 / 280 | 侧栏拖拽夹取与默认宽 | `:23-27` |
| `SIDEBAR_COLLAPSED` | 56 | 收起的控制轨道宽 | `:29` |
| `SIDEBAR_AUTO_COLLAPSE` | 1024 | 视口小于此值侧栏自动收起（deepsuite LG 断点） | `:33` |
| `DETAILS_MIN` / `DETAILS_MAX` / `DETAILS_DEFAULT` | 300 / 520 / 360 | 详情列夹取与默认宽 | `:35-39` |

三步让步顺序（`columns.ts:66-75`）：① 理想宽放得下 → 中列吃掉余量；② 详情列压到 `DETAILS_MIN`；③ 详情列派生归零（**不改偏好**，窗口变宽自动恢复）+ 中列吸收剩余缺口。侧栏永不让步。

### 1.3 路由 / 视图

源码中**没有路由表**：视图由「slot occupant + session 选中状态」决定，`ui-layout` 注释明确「导航状态住在 runtime sessions 服务里，不在 layout」。

| 视图 | 触发条件 | 源码事实 |
|---|---|---|
| hero 空态 | 无 session（`sessionId === undefined`），或当前 session 是 blank 且 `openState === 'open'` 或 summary 已证明 blank | `ui-conversation/src/client/skeleton/ConversationRoot.tsx:271-272`、`353` |
| 会话页 | 有 current session 且非 blank → `phase='active'`，渲染 `conversation.session` 与左右宽度手柄 | 同上 `:353`、`:380-389` |
| 转场中（settling） | `shellPhase==='blank' && openState==='loading' && summaryBlank!==true`，或 continuable 子代理父目录未定时；此相隐藏 composer，避免 hero/dock 闪烁 | 同上 `:253-270` |
| 详情面板（details） | `ctx.layout.details > 0` 且当前 session 非 blank；`AppFrame` 用 `useSessions` 选出 `detailsSession`，**切换 session 时自动 `closeDetails()`** | `ui-layout/src/client/AppFrame.tsx:100-118`、`:152` |
| overlay | `shell.overlay`（list/root）渲染在 `data-shell-overlay` 层，本身点击穿透，occupant 自行恢复 pointer events | `AppFrame.tsx:210-212`；`ui-layout/src/client/index.ts:75-85` |

`AppFrame` 只把 `sidebar` slot 以「实时参数」渲染（`{ collapsed, width }`），其余三个 occupant 不带 owner props（`AppFrame.tsx:194-211`）。

### 1.4 本域在 `docs/subsystems/slots.md` slot 树中的节点

`docs/subsystems/slots.md:110-163` 的树里，属于本域的是：

```text
root
├─ sidebar                      ← ui-layout 声明，ui-sidebar 占位
│  ├─ sidebar.brand.mark        ← ui-sidebar 声明
│  ├─ sidebar.brand.name        ← ui-sidebar 声明
│  ├─ sidebar.footer.action     ← ui-sidebar 声明
│  ├─ sidebar.workspaces        ← ui-sidebar 声明，ui-workspace 占位
│  │  └─ sidebar.workspaces.directoryFlow   ← ui-workspace 声明
│  └─ sidebar.settings          ← ui-sidebar 声明，ui-settings-general 占位
│     ├─ settings.trigger / settings.header / settings.action / settings.close
│     ├─ settings.onboarding
│     └─ settings.section
│        ├─ settings.general.item
│        ├─ settings.models.provider-card / settings.models.footer
│        └─ settings.plugins.tab
│           └─ settings.plugin.item
├─ details                       ← ui-layout 声明（occupant 为 ui-chat，属他域）
└─ shell.overlay                 ← ui-layout 声明
```

树中 `conversation.*`（除 `conversation.hero.workspace*`、`conversation.hero.agentPreset`）、`conversation.details.tool` 由 `ui-conversation`/`ui-chat` 拥有，不属本域。

---

## 2. 侧边栏

`SidebarRoot` 只管列几何：折叠 = 滑出 + 淡出（内容在展开宽度冻结，150ms 后卸载宽态内容），收起后进入 56px 轨道，四个上部控件按同一 top-down 顺序渐入；底部设置控件只做淡变。列自身还拥有「滚动条是否绘制」——指针不在列内时 2s 后隐藏滚动条。来源：`packages/client/ui-sidebar/src/client/SidebarRoot.tsx:26-35`、`:60-79`、`:81-122`、`:126-139`。

### 2.1 品牌区

| 元素 | 行为 | 来源 |
|---|---|---|
| 展开态 brand 按钮 | 同时是「新建会话」快捷入口（`onClick → startSession()`），aria-label 取 `t('session.new.label')` | `SidebarRoot.tsx:143-167` |
| `sidebar.brand.mark` | 以 `{ size: 24 }` 渲染，fallback 为 `FishLogo`（宽态与轨道态各渲染一次） | `:152`、`:178-181` |
| `sidebar.brand.name` | fallback 分两支：无构建版本 → `t('brand.localBuild')`；有 → 主标题 + 版本徽标 | `:154-165` |
| 版本徽标文本 | `DSH_CLIENT_VERSION` + `-${DSH_CLIENT_COMMIT_HASH}` + `-dirty`（当 `DSH_CLIENT_GIT_DIRTY === 'true'`） | `:37-45` |
| 收缩/展开按钮 | 轨道静止态显示鲸鱼标记，hover 换成 panel 图标；aria-label 在 `t('toggle.open')` / `t('toggle.collapse')` 间切换 | `:169-186` |
| 官方品牌占位 | `ui-brand-official` 仅在 `process.env.DSH_CLIENT_BUILD_PROFILE === 'official'` 时向 `sidebar.brand.mark` + `sidebar.brand.name` 注册 `OfficialBrandMark` / `OfficialBrandName`（两个注册装在一个 generator 里原子生效） | `packages/client/ui-brand-official/src/client/index.ts:16-22` |

### 2.2 工作区列表（`sidebar.workspaces` = WorkspaceBrowser）

一行工作区（`ProjectRowItem`）显示什么：

| 显示位 | 内容 | 来源 |
|---|---|---|
| 前导图标 | `IconFolderOpen16` / `IconFolderClose16`，展开+含当前会话时用 `folderActive` 态 | `ui-workspace/src/client/rows/Rows.tsx:148-150` |
| chevron | `IconTriangleRightFill14`，展开时旋转，仅 hover 显示（CSS 层） | `:151-153` |
| 标题 | 有 workspaceId → `group.label`（Host 标题）；无 workspaceId（Ungrouped 桶）→ 字典 `t('group.ungrouped')` | `:124-125`、`:155` |
| hover 悬停卡 | 标题 + 目录路径（`abbreviateHomePath(cwd, home)`，POSIX 家目录缩写为 `~`）+ 绝对创建时间；点按可复制路径；Ungrouped 桶无卡 | `:53-67`、`:197-213` |
| 行尾操作 | 「⋯」菜单（`rename` / `delete`，delete 为 danger）+ 「+」新建会话按钮 | `:128-131`、`:157-194` |
| 折叠逻辑 | 展开组最多 5 条普通会话行，blank 行不计入限额 | `WorkspaceBrowser.tsx:41-55` |

**工作区分组事实**（`ui-workspace/src/client/tree.ts`）：

- 每个 Host Workspace 一个 section，顺序 = Host registry 顺序（`tree.ts:200-213`）；成员按其 `workspaceIds` 存序解析（`buildGroup(..., 'account')`，`:161-165`）。
- 不在任何 Workspace 的会话落到 `UNGROUPED_KEY`（`''`）桶，顺序用浏览器本地序，未初始化前回退按 `updatedAt` 倒序（`tree.ts:169-184`、`:214-228`）。
- 可见性：`origin !== 'subagent'`、不在 archived 集合、`!blank || id === current`（`tree.ts:131-135`）。blank 行的标题恒为空串，由渲染层替换为本地化「新建会话」（`tree.ts:142-144`；`Rows.tsx:24-27`）。
- 排序比较器：`updatedAt` 倒序，`id` 升序做确定性 tiebreak（`tree.ts:119-123`）。

**切换 / 新建 / 目录选择器如何介入**：

| 动作 | 链路 | 来源 |
|---|---|---|
| 新建会话（分组 + 按钮） | 展开组 → `startSession(workspaceId)` | `WorkspaceBrowser.tsx:507-512` |
| 新建会话（侧栏 brand / New Session 按钮） | `SidebarRoot` → `ctx.uiWorkspace.startSession(workspaceId)`；无参时目标解析为「当前 Session 的 Workspace → 最近 Workspace → `sessions.clear()`」 | `ui-sidebar/src/client/index.ts:43-48`；`ui-workspace/src/client/navigation.ts:114-133` |
| 最近 Workspace 判定 | 组内会话 `updatedAt` 最大值；空组用 `Date.parse(workspace.createdAt)`；严格大于才换人（稳定 tiebreak 跟随 Host 顺序） | `navigation.ts:213-233` |
| 连接 Workspace | `connectWorkspace(workspaceId)`：同 workspace 已有在途 `create` 则复用（`connecting` Map），否则 `sessions.create({ workspaceId })` | `navigation.ts:107-112` |
| 新增工作区按钮 | 只有 directory-flow 洞被占位时才渲染（`directoryFlowAvailable`）；点击直接抬升目录流，无中间菜单 | `WorkspaceBrowser.tsx:1144-1179` |
| 目录流洞 | `WorkspacePickFlow` 组装 owner 会话 `{ open, busy, onPicked, onCancel, onError }`，`onPicked` → `createWorkspace({ path })` → 成功 `onPick(workspaceId)`（并 `startSession`），失败弹「Choose again」错误对话框 | `ui-workspace/src/client/WorkspacePicker.tsx:125-141`、`:159-173`、`:199-214` |
| 占位者 | `ui-directory-picker-browse`（应用内浏览对话框）与 `ui-directory-picker-native`（无渲染 driver）各自把同一个组件注册进**两个**洞，且用一个 generator 让两处注册原子生效 | `ui-directory-picker-browse/src/client/index.ts:85-93`；`ui-directory-picker-native/src/client/index.ts:33-41` |
| 选择器选择 | 由 Host 行 `@deepseek-ai/dsh-host-directory-picker-auto` 一次采样决定：loopback 绑定 + 非 SSH 启动 + 可服务显示会话才 native，其余一律 browse | `packages/host/directory-picker-auto/README.md`（Summary / How the choice is made 段） |

浏览态对话框自身形态：680×500 的 Miller 视图（选行后分两栏，256px 下限），标题 + 面包屑 + 可点击编辑的路径区；「新建文件夹」为嵌套对话框；「显示隐藏文件」为 foot 开关（纯客户端）；字典命名空间 `directory-browser`，键含 `browser.title` / `browser.home` / `browser.newFolder` / `browser.folderName` / `browser.createIn` / `browser.untitledFolder` / `browser.create` / `browser.cancel` / `browser.open` / `browser.editPath` / `browser.loading` / `browser.truncated` / `browser.showHidden`。来源：`ui-directory-picker-browse/src/client/DirectoryBrowser.tsx:1-36`；`.../src/client/index.ts:36-67`。

### 2.3 会话列表一行显示什么

`SessionNodeItem`（高度 34px，`Rows.tsx:362-364`）：

| 显示位 | 内容 | 来源 |
|---|---|---|
| 状态槽（16px） | 主状态点 `StateDot`；状态优先级：pendingInteraction（approval / plan-review / question，warning 点）> 自身 `running`（ongoing）> 运行中子代理数（ongoing，文案 `status.subagentsRunning.one/other`）> `completed`（done，绿点提醒）> idle（done）。多状态时只画第一个点，其余进 `visuallyHidden` 供读屏 | `Rows.tsx:226-268`、`:270-280`、`:446-453` |
| 标题 | `node.blank ? t('session.new') : node.title` | `:24-27`、`:454` |
| Schedule 指示 | `hasActiveSchedule` 时显示非交互 `IconAlarmClockOutline16`（role=img） | `:282-295`、`:455` |
| 时间 | 相对时间 `relativeTime` + 字典模板（zh: 刚刚/5分钟；en: now/5min）；**blank 行不显示时间** | `:29-33`、`:456-460` |
| 行尾「⋯」菜单 | `rename` / `fork` / `archive`；blank 行整块不渲染 | `:404-409`、`:461-487` |
| hover 卡 | 完整标题、相对时间（ago 模板）、全部适用状态；拖拽中或菜单打开时禁用 | `:297-314`、`:490-498` |

**选择 / 重命名 / 归档 / 分支 / 排序**：

| 操作 | 事实 | 来源 |
|---|---|---|
| 选择 | 整行 `onClick → onOpen(id)` → `sessions.open(sessionId)` | `Rows.tsx:420`；`ui-workspace/src/client/index.ts:102` |
| 重命名 | 行菜单 → 浏览器自持 `Modal` 对话框（跨行卸载存活）；提交 `renameSession(id, title)`；幂等性上「确认未改动的自动标题」正是把它钉住的动作，所以**不拦截**未变标题 | `WorkspaceBrowser.tsx:991-1022`、`:1302-1332` |
| 归档 | 无对话框直接提交（非破坏性：日志与记账槽位都保留，且无确认弹窗样式）；失败仅 console 诊断 | `Rows.tsx:400-409`、`:1024-1032` |
| 分支（fork） | `forkSession(id)` → `sessions.fork({ sessionId, increaseTitle: true })` 成功后 `sessions.open(childId)`；失败保持当前选择 | `ui-workspace/src/client/index.ts:113-119` |
| 置顶 | **源码未明确提供「置顶」概念**。等价能力是拖拽重排 + 可编辑顺序账户：默认 `orderBy='updated'`（活动提升），切成 `manual` 即用户自定序；会话拖拽在真实 Workspace 组内会调 `insertSessionBefore` 持久化，Ungrouped 与 flat 账户只写本地序 | `ui-workspace/src/client/stores.ts:13-16`、`:52-60`；`WorkspaceBrowser.tsx:350-402` |
| 会话排序账户 | 每个 Workspace 一个账户 + 浏览器本地 `FLAT_SESSION_ORDER_KEY`（`'__flat_session_order__'`）；切换为 `updated` 时按最近 `updatedAt` 一次性提升 | `stores.ts:11`、`:122-159`；`WorkspaceBrowser.tsx:302-328` |
| 视图选项菜单 | 一个「个性化」图标菜单：分组 `workspace` / `flat`（文案「按工作区分组」/「在一个列表中」），排序 `manual` / `updated` | `WorkspaceBrowser.tsx:162-209` |
| 工作区重命名/删除 | 同一浏览器自持 Modal；重命名有客户端重名冲突提示（`conflict.named`）；删除确认有三态（deleting / deleteCommittedId / deleteError），并在投影真正移除后关闭 | `WorkspaceBrowser.tsx:963-989`、`:1267-1357` |
| 拖拽 | 工作区行与会话行都走原生 HTML5 DnD；拖拽期间在 document 级 `preventDefault` 接受 drop，保证在列表外释放不会先渲染成被拒 | `WorkspaceBrowser.tsx:73-93`、`:213-230` |

### 2.4 搜索

| 事实 | 来源 |
|---|---|
| 搜索输入只在宽态渲染；轨道态是一个 36px 搜索按钮，点击先请求展开侧栏再在滑动（`EXPAND_SLIDE_MS=300`）结束后聚焦输入 | `WorkspaceBrowser.tsx:31-35`、`:882-907`、`:1182-1198` |
| query 在树与输入之外存活，因此折叠侧栏不会静默丢掉进行中的过滤 | `WorkspaceBrowser.tsx:872-874` |
| 输入净化：剔除 `\0`，截断到 `SEARCH_QUERY_MAX_CODE_UNITS = 500` 个 UTF-16 码元，且不切断代理对 | `:57-66`、`:39` |
| 输入后 `SEARCH_DEBOUNCE_MS = 250` 才发起远端内容搜索，`AbortController` 取消被取代的请求 | `:36`、`:926-961` |
| 结果合并规则（`deriveSearchResults`）：本地「标题或 Workspace 名小写包含」命中优先、按 recency 排序；随后追加 Host 内容命中的会话（保留后端顺序）；重复会话就地把后端 snippet 补上；blank 会话永不被查询命中（其标题本地化，匹配会绑定语言）；最后按 `limit` 截断，`hasMore = content.hasMore \|\| ordered.length > limit` | `ui-workspace/src/client/tree.ts:352-427` |
| 一行搜索结果：状态点 + 标题 + Schedule 指示 / 第二行 Workspace 标签（空则 `group.ungrouped`）+ snippet（若有）；点击只打开会话，不定位事件 | `Rows.tsx:316-360` |
| **Web 默认部署下内容搜索是关闭的**：`packages/bundle/web-app/cordis.patch.yml` 把 `session-query-sqlite` 覆写成 `path: ':memory:'` + `openAt: never`，源码注释说明全文搜索为 opt-in，需在更晚的 patch 层把 `openAt` 改为 `first-search` | `packages/bundle/web-app/cordis.patch.yml:21-29` |
| 关闭后的行为：`searchSessions` / `searchEvents` 在任何请求规范化与 SQLite 工作之前就抛 `SESSION_QUERY_SEARCH_DISABLED`（"session search is disabled: this deployment configures the session-query index with openAt \"never\""），SQLite 从不被 import 或打开；精确读/过滤/trace 仍可用 | `packages/session-query/session-query-sqlite/src/index.ts:92-110`、`:330-338` |
| 因此侧栏搜索在 Web 默认下仍可用「本地标题/工作区名」这一半，内容命中半边恒为空；`ui-workspace` 的 `searchSessions` 包装在 `!result.ok` 时 `throw`，前端把它落成 `status:'error'`（结果列表空、无错误文案渲染路径——源码未给出该错误态的用户可见文案） | `ui-workspace/src/client/index.ts:80-84`；`WorkspaceBrowser.tsx:947-955` |

### 2.5 底部动作与设置入口

| 事实 | 来源 |
|---|---|
| 结构：`footArea` 内先 `footerActions`（渲染 `sidebar.footer.action`，list/root，owner props `{ wide }`），再 `settingsArea`（渲染 `sidebar.settings`）——底部动作始终叠在设置之上 | `SidebarRoot.tsx:211-219` |
| `sidebar.footer.action` 在 Web 组合中**无已签入占位者**（`packages/bundle/web-app/cordis.patch.yml` 无对应注册；全仓 grep 只在该 slot 的声明处出现） | 见第 6 节清单 |
| 设置入口 = `sidebar.settings` 的占位者 `ui-settings-general` 的 `SettingsRoot`：一个触发按钮（`aria-haspopup="dialog"`、`aria-expanded={open}`）+ 连接状态指示 `ConnectionIndicator`；轨道态只显示图标，`ConnectionIndicator` 传 `state=undefined` 不显示 | `ui-settings-general/src/client/SettingsRoot.tsx:180-203` |
| 触发按钮内容来自 `settings.trigger`（`TriggerContent`）：宽态 16px 齿轮 + 文案 `settings.trigger`，轨道态 14px 齿轮（渲染尺寸 18） | `ui-settings-general/src/client/chrome.tsx:17-29` |
| 焦点管理：打开时聚焦关闭按钮；关闭后（`wasOpen` 提交后）把焦点还给触发按钮 | `SettingsRoot.tsx:117-126`、`:61-63` |

---

## 3. 会话列表数据面

### 3.1 `ui-session` 暴露什么

| 名称 | 类型/语义 | 来源 |
|---|---|---|
| `useSessions` | `SnapshotSelectorHook<SessionListState>`；root 级标准 props，任何 scope 都有。由 `ctx.slots.provideRoot({ hooks: { sessions: ctx.sessions.list } })` 提供 | `ui-session/src/client/index.ts:27-28`、`:104-110`、`:505-514` |
| `useSessionPendingInteraction` | `SnapshotSelectorHook<SessionPendingInteractionSnapshot>`（`ReadonlyMap<SessionId, interaction>`）；同样 root 级 | `:53-56`、`:104-110` |
| `useSession` | session scope 与 session-maybe scope 各一份；`SnapshotSelectorHook<SessionSnapshot>`（maybe 版为 `MaybeSnapshotSelectorHook`） | `:112-129` |
| `sessionId` | session scope 为 `SessionId`；session-maybe 为 `SessionId \| undefined` | 同上 |
| `useProjection` | `UseProjection`；Host 计算好的投影值按 key 寻址 | 同上 |
| 内置源 | `BUILTIN_SOURCE = { hooks: ['session'], keyedHooks: ['projection'], props: ['sessionId'] }`；`projection` 解析为 `binding.session.projections.faceOf(key)` | `:197-210` |
| `ctx.uiSession` 服务 | `provide(descriptor)` 注册 session 级标准源（静态 roster + 每 binding resolver，未声明成员会抛错）、`registerPendingInteraction(precedence)`（每 session 取优先级最高者）、`adapter`（供 renderer 的 scope 适配） | `:213-323`、`:442-496` |
| `SessionProvider` | `renderSessionArea(binding, { empty, children })`：无 sessionId 时渲染 `empty?.()`，否则以 `sessionId` 为 React key 渲染子树（identity 变化即重挂） | `ui-session/src/client/session-provider.tsx:13-20` |

数据面之外，列表读写的**真正动词都在 `ctx.sessions`（`ISessions`）**：`list`、`searchResultLimit`、`create(opts)`、`open(id)`、`openSubagent(address)`、`subagentAddress(id)`、`setSubagentCatalogOpen`、`refreshSubagents`、`clear()`、`refresh()`、`search(query, signal)`、`fork({ sessionId, atSeq?, increaseTitle? })`、`scope(id)`、`scopeOf(ctx)`、`sessionOf(ctx)`、`binding(id)`。见 `packages/api/session-controller/src/client/contract/sessions.ts:20-122`。

### 3.2 会话标题从哪来

- 服务包 `packages/session/session-title`：标题有三个来源、**新者胜**：① 内置 fallback——取第一条合格人类消息（`user/message` 的 text block）开头词；② 注册的异步 provider（模型生成）；③ 显式 `rename()`。每个被接受的修订都是**仅日志**的 `session/title` 事件，所以能随 replay/resume/分页存活，且永不进入模型面。用户来源的标题会**钉住**会话（后续用户消息不再排自动修订），显式 `refresh()` 是唯一的解钉动作。模型后端 provider 有 `session-title-first-prompt-llm` 与 `session-title-all-prompts-llm`。来源：`packages/session/session-title/README.md`（Summary / Choosing a title source 段）。
- 上限全部必填、库不给默认值：`fallbackMaxWords`、`fallbackMaxBytes`（不得超过 `maxTitleBytes`）、`maxTitleBytes`。来源同上（Minimal configuration 段）。
- 列表侧看到的标题字段是 `SessionSummary.displayTitle`；`SessionNode.title` 直接用 `displayTitle`（blank 除外，恒为空串）——见 `ui-workspace/src/client/tree.ts:142-144`、`:252`。
- 显式重命名走 session 面而非列表面：`sessions.binding(id)?.session.rename(title)`；未知 id 抛 `unknown session "<id>"`。来源：`ui-workspace/src/client/index.ts:105-112`。

### 3.3 列表排序 / 分组规则

| 维度 | 规则 | 来源 |
|---|---|---|
| 分组模式 | `groupBy: 'workspace' \| 'flat'`，默认 `workspace`；持久化 key `dsh.workspace.view.v5` | `ui-workspace/src/client/stores.ts:13-14`、`:55`、`:61` |
| 排序模式 | `orderBy: 'manual' \| 'updated'`，默认 `updated` | `:15-16`、`:56` |
| 工作区分组内 | 成员取自 `workspace.sessionIds` 的存序（Host 记账顺序），不是按时间算出来的 | `tree.ts:200-213`、`:159-165` |
| flat 模式 | 严格 recency 倒序，无分组、无父子相邻 | `tree.ts:322-337` |
| Ungrouped 桶 | 有本地序 → 用本地序（新增成员按 recency 追加）；无 → 纯 recency | `tree.ts:169-184`、`:214-228` |
| 活动提升 | `orderBy==='updated'` 时，`updatedAt` 相比上次观测有推进的会话会被提升到组首（按 recency 排序），其余保持原相对序 | `WorkspaceBrowser.tsx:123-160` |
| 折叠态展示 | 折叠组只渲染最多 5 条普通行（`COLLAPSED_SESSION_LIMIT=5`），blank 行不计入且排在隐藏普通行之后 | `WorkspaceBrowser.tsx:41-55`、`:376-396` |
| 展开态持久化 | 组展开状态显式持久化（`groupExpansion: Record<key, boolean>`），不是「默认展开」；当前会话所在组首次出现时自动置为展开 | `stores.ts:22-23`、`:65`；`WorkspaceBrowser.tsx:290-293` |
| 账户清理 | Workspace 列表 ready 后调用 `retainAccountKeys([UNGROUPED_KEY, FLAT_SESSION_ORDER_KEY, ...workspaceIds])`，删掉已消失 Workspace 的展开态与序账户 | `WorkspaceBrowser.tsx:864-871`；`stores.ts:66-77` |

---

## 4. 设置界面

### 4.1 壳与分页

`SettingsRoot` 是 `sidebar.settings` 的占位者，它本身**零文案**：触发标签、面板标题、关闭 aria、分页内容全部由 slot 提供（`ui-settings/src/client/contract/slots.ts:1-9`）。面板为居中 modal（源码注释称 figma 501:29947，1080×700），结构：`nav`（标题 `settings.header` + 分页行列表）| `content`（header：`settings.action` 区 + 关闭按钮 `settings.close`；options：当前分页 `settings.section`）。关闭路径三条：header 按钮、mask 点击、document 级 Escape（面板挂载期间才有监听）。`activeId` 在目标分页消失时回退到第一行。来源：`ui-settings-general/src/client/SettingsRoot.tsx:24`、`:47-101`。

分页按 `order` 升序渲染（`rows.sort((a,b)=>a.order-b.order)`，`ui-settings-general/src/client/index.ts:107-116`）。Web 组合的分页全集：

| order | id | 标签来源 | 组件 | 来源 |
|---|---|---|---|---|
| 0 | `general` | `t('general.nav')`（`settings` 命名空间 →「通用设置」/「General」） | `GeneralSection` | `ui-settings-general/src/client/index.ts:175-182`；`locales.ts:10`、`:29` |
| 10 | `models` | `t('nav')`（`settings.models`） | `ModelsSection` | `ui-settings-models/src/client/index.ts:131-141` |
| 15 | `plugins` | `t('nav')`（`settings.plugins`） | `PluginsSettingsSection` | `ui-settings-plugins/src/client/index.ts:145-153` |
| 20 | `agent-presets` | `settings.agentPreset` 的 `nav` | `AgentPresetSection` | `ui-agent-preset/src/client/index.ts:196-203` |

导航图标按 id 硬映射（`SettingsRoot.tsx:26-32`）：`models` → data 图标、`agent-presets` → agent-preset 图标、`plugins` → personalization 图标、其它 → 齿轮。

面板头部还有一个可选动作：`settings.action` 的 `open-document`（order 0），**只在 loopback 且存在本地设置文档时注册**（`ctx.remote.$host.isLoopback ? new SettingsDocumentStore(...) : undefined`）。来源：`ui-settings-general/src/client/index.ts:76-85`、`:164-172`。

onboarding：`SettingsRoot` 在「sessions 相位 ready 且（无 current 或 current 是 blank）」时，从 `settings.onboarding` 里取第一个未完成的步骤渲染，且一次只挂一个；`complete()` 把它加进本轮已完成集合，离开该空态时集合重置。来源：`SettingsRoot.tsx:138-149`、`:164-169`、`:216-220`。Web 组合注册两个步骤：`welcome-notice`（order -100，`WelcomeNotice`，命名空间 `ui-onboarding`）与 `deepseek-official`（order 0，`DeepSeekOnboardingDialog`）。来源：`ui-settings-models/src/client/index.ts:142-153`。

### 4.2 General 分页的全部行

General section 只做纵向堆叠，行自己画内部（含标签）——owner 不传任何 props（`ui-settings/src/client/contract/slots.ts:74-94`、`GeneralSection.tsx:14-19`）。按 order 升序：

| order | id | 行 | 可编辑项 | 设置命名空间 / 字段 | 来源 |
|---|---|---|---|---|---|
| -20 | `permission` | `PermissionRow`（ui-permission-presets） | 权限预设选择 | `permission`（`PERMISSION_SETTINGS_NS`），经 `remote.settings.mutate` 写 | `ui-permission-presets/src/client/index.ts:137-143`；`.../settings-store.ts:19-20`、`:143-144` |
| 0 | `language` | `LanguageRow` | 语言菜单（`Menu`，选项来自 locale 快照） | `locale.preference` → `locale.setLocale(id)` | `locale/src/client/index.ts:573-580`；`LanguageRow.tsx:41-64` |
| 10 | `appearance` | `AppearanceRow` | 三格：Light / Dark / System | `ui-theme.preference` → `theme.setTheme(id)` | `ui-theme/src/client/index.ts:454-461`；`AppearanceRow.tsx:30-59` |
| 11 | `font-size` | `FontSizeRow` | 步进器（12–17px 夹取；`setFontSize(px)` 越界或非整数抛错） | `ui-theme.fontSize` | `ui-theme/src/client/index.ts:463-477`；`FontSizeRow.tsx:44-67`；`ui-theme/src/client/index.ts:247-255` |
| 12 | `transcript-view` | `TranscriptViewRow` | 完成轮次过程内容展示模式 | `ui-chat.transcriptView`（`normal` \| `compact`，默认 `compact`） | `ui-chat/src/client/apply.ts:83-92`；`ui-chat/src/chat-settings.ts:6-28` |
| 20 | `composer-enter` | `EnterBehaviorRow` | agent 忙时 Enter 的语义 | `ui-conversation.busyEnter`（`queue` \| `steer`，默认 `queue`） | `ui-conversation/src/client/apply.ts:110-119`；`ui-conversation/src/submission-settings.ts:6-28` |

注意：`ui-agent-preset` **不在 General 里**再放一份「默认预设」控件——源码明确「默认预设就在能看到花名册的地方编辑（设置分页的 make default）」，避免同一字段出现重复控件（`ui-agent-preset/src/client/index.ts:10-12`）。

### 4.3 Models 分页

页面快照由三条读拼成（`ModelsSettingsStore.load()`）：`llm.listProviders` + `llm.listConfigurableProviders` 并行 → `joinProviderDirectory()` 得行目录；`settingsScope.describe().ensure()` 得 settings 命名空间视图与 writability；再对每行推导出的凭据引用做**一次批量** `credentials.describe(refs)`。凭据读失败只降级徽标（`credentialError`），不整体失败。来源：`ui-settings-models/src/client/store.ts:178-241`。

| 元素 | 事实 | 来源 |
|---|---|---|
| Provider 卡片一行 | 显示名 + （adapter 声明为非内置时的）`customTag` + 凭据点（configured 实心 / missing 空心，`role="img"` 带 aria-label 与 title）+ 「编辑」按钮 + 可移除时的「移除」危险按钮 | `ModelsSection.tsx:352-437` |
| 首启姿态 | 当**没有任何**可用 provider 时，一个整段 provider 且缺 key 的行渲染成「打开的设置卡」而非普通行；用户关掉后本会话回退为普通行，经 Edit 可重开 | `ModelsSection.tsx:141-145`、`:325-346`；`:230-240` |
| 编辑卡 | 一次只开一张；行编辑器、新增、自定义声明各自持有自己的开态，关掉一个不会丢弃另一个的草稿 | `ModelsSection.tsx:383-399`、`:230-240` |
| 新增 | 两种并行入口：「新增」（从 adapter 已认识的 addable 行里选）+「自定义新增」（手写 adapter 不知道的路由，协议选项从 `llm-pi-ai` 命名空间的 schema 读出）。两侧同宽同级 | `ModelsSection.tsx:294-305`、`:439-539` |
| 删除确认 | `Modal`；`removeProviderProfile` 先删凭据再 unset settings profile（第二步失败时行仍可见、整操作可安全重试，两个 unset 都幂等），settings 侧用的是 `{ op: 'unset', path: settingsPath }` 而不是用局部视图重建整个 namespace | `ModelsSection.tsx:113-130`、`:542-575` |
| 只读提示 | `!state.writable && status==='ready'` 时渲染 `t('readOnly')` | `ModelsSection.tsx:311` |
| 凭据引用推导 | 走 `profile.apiKeyEnv`；没有则页面的约定引用 `<ROUTE>_API_KEY`（`provider.toUpperCase().replace(/[^A-Z0-9]+/g,'_') + '_API_KEY'`） | `store.ts:111-113`、`:136-146` |
| 可用性判定 | `providerUsable(row)`：路由必须 active；`apiKeyEnv` 为 undefined（走 provider 自身认证链，如 Bedrock/Vertex/免认证网关）直接可用；否则要求该引用 `credential.configured === true` | `store.ts:253-267` |
| 首启就绪投影 | `onboardingReadiness()`：任何可用 provider → `provider-ready`；否则找 `deepseek-official` + `llm-deepseek` + 空 settingsPath 的行：缺行 → `adapter-absent`；行不 active → `provider-inactive`；凭据读失败或缺失 → `credentials-unavailable`；settings 只读 → `settings-read-only`；凭据只读 → `credential-read-only`；否则 `credential-missing` | `store.ts:269-337` |
| 凭据写入 | `credentials.set(ref, value)` / `credentials.unset(ref)` / `credentials.describe([ref])` | `operations.ts:84-95` |
| settings 写入 | `settings.mutate(ns, ops, expectedRevision)`；`code === 'settings/conflict'` 映射为 `{kind:'conflict'}`，其余 `{kind:'refused', message}` | `operations.ts:96-101` |
| 模型发现 | `llm.discoverModels(settingsNs, request)` → `{kind:'found', models}` 或 `{kind:'refused', message}` | `operations.ts:102-107` |
| 扩展位 | `settings.models.provider-card`（keyed，entryKey = `settingsNs`，owner props `{ provider, configured, keyConfigured }`）与 `settings.models.footer`（list，无 owner props） | `ui-settings-models/src/client/slot-contract.ts:23-55` |
| 刷新时机 | 订阅 `settings/document-updated`、`credentials/reference-updated`、`llm/adapters-updated`、`connection/reset`；未打开过（status 仍是 idle）的页面在后台失效时**不**拉取 | `ui-settings-models/src/client/index.ts:112-129`、`:49-57` |

### 4.4 Plugins 分页

分页结构：`PluginsSettingsSection` 渲染 `settings.plugins.tab` 的 tab 列表（ARIA tablist + ArrowLeft/Right/Home/End 键盘导航）；tab 首次被选中才挂载，之后隐藏但**保持挂载**，以保住草稿、展开态、搜索与清加快照。来源：`ui-settings-plugins/src/client/PluginsSettingsSection.tsx:33-116`。

| tab | order | 内容 | 来源 |
|---|---|---|---|
| `configurable` | 0 | `ConfigurablePluginsTab`：渲染 `settings.plugin.item`（keyed by namespace）。可渲染集合 = **Host 服务的 namespace 集合 ∩ 已注册卡片的 key**——Host 服务但无卡片 → 渲染空；卡片存在但 Host 未服务 → 永不派发也不计入空行。空行只在 Host 答复过一次后才出现（`loaded`） | `ui-settings-plugins/src/client/index.ts:157-165`；`tab-store.ts:17-35`、`:85-101` |
| `all` | 10 | `PluginInventorySettingsTab`（只读清单）：顶部搜索、可展开插件卡、preset 分组（可切换 preset）+ global 分组；行尾 `PhaseDot`（pending/loading/active/failed/unloading）+ 使能标签（enabled/disabled/conditional/failed/preset）；失败行排在前，非 enabled 但被某 preset 启用的行标 `presetEnabledTag` 并给出跳转 | `ui-settings-plugin-inventory/src/client/index.ts:50-57`；`PluginInventorySettingsTab.tsx:169-344`、`:448-479` |

`configurable` tab 在 Web 组合里已签入的四张卡片（order 未显式指定，按注册顺序）：

| key（= 设置命名空间） | 卡片 | 来源 |
|---|---|---|
| `shell` | `BashCard`（`SHELL_NS`） | `ui-settings-plugins/src/client/index.ts:167-173`；`bash-card-controller.ts:12` |
| `agent-loop` | `AgentLoopCard` | `:174-179`；`agent-loop-card-controller.ts:11` |
| `subagent-model-selection` | `SubagentModelSelectionCard` | `:180-185`；`subagent-model-selection-card-controller.ts:10` |
| `web-search-deepseek` | `WebSearchCard`（凭据默认引用 `DEEPSEEK_API_KEY`，字段 `apiKey`） | `:186-191`；`web-search-card-controller.ts:26-32` |

其他订阅：`credentials/reference-updated` → `webSearch.refreshCredential(ref)`；`llm/adapters-updated` 与 `settings/document-updated` → `subagentModelSelection.refreshCatalog()`；`connection/reset` → `resetConnection()`；`ctx.slots.subscribe('settings.plugin.item', …)` → 晚注册的卡片无需一次线读即可入列。来源：`ui-settings-plugins/src/client/index.ts:77-106`。

### 4.5 每个设置项写入什么 / 调用哪个 RPC

| 界面动作 | 服务方法 | 落到的 wire 调用 | 设置命名空间 / 字段 | 来源 |
|---|---|---|---|---|
| 切语言 | `locale.setLocale(id)`（先查 catalog，未知 id 抛错；写入**无条件下发**，切到当前语言也写，因为当前值可能只是浏览器推导的临时值） | `settings.mutate('locale', [{op:'set', path:['preference'], value:id}], revision)` | `locale.preference` | `locale/src/client/index.ts:236-242`；`settings-scope.ts:106-144` |
| 切外观 | `theme.setTheme(id)`（未注册 id 抛错；已是当前值则直接返回） | `settings.mutate('ui-theme', [{op:'set', path:['preference'], value:id}], revision)`（经 `ctx.settingsScope.bind({namespace:'ui-theme'})`） | `ui-theme.preference` | `ui-theme/src/client/index.ts:231-239`、`:430` |
| 改字号 | `theme.setFontSize(px)`（非整数或越界抛错） | 同上，`path:['fontSize']` | `ui-theme.fontSize` | `ui-theme/src/client/index.ts:247-255` |
| 改转写视图 | `transcriptView.setMode(mode)` | 同上（`ui-chat` scope） | `ui-chat.transcriptView` | `ui-chat/src/client/apply.ts:79-92`；`ui-chat/src/chat-settings.ts:6` |
| 改忙时 Enter | `submissionPolicy.setBusyEnter(behavior)` | 同上（`ui-conversation` scope） | `ui-conversation.busyEnter` | `ui-conversation/src/client/apply.ts:106-119`；`ui-conversation/src/submission-settings.ts:6` |
| 改权限预设 | `PermissionRow` 注入的 select | `settings.mutate('permission', …)` | `permission` | `ui-permission-presets/src/client/settings-store.ts:19-20`、`:143-144` |
| 改默认 agent preset | `makeDefault(id)` → `writeDefaultPreset` | `settings.update(...)`（**注意：这里走的是 `settings.update`，不是 `mutate`**） | `agent-presets` | `ui-agent-preset/src/client/settings-store.ts:16`、`:32` |
| Models：存/删 key | `storeCredential` / `removeCredential` | `credentials.set(ref, value)` / `credentials.unset(ref)` | 凭据引用（不在 settings 文档里） | `ui-settings-models/src/client/operations.ts:88-95` |
| Models：改 provider profile | `writeSettings` | `settings.mutate(ns, ops, expectedRevision?)` | 各 provider 命名空间（如 `llm-deepseek`、`llm-pi-ai`） | `operations.ts:96-101` |
| Models：探测可用模型 | `discoverModels` | `llm.discoverModels(settingsNs, request)` | — | `operations.ts:102-107` |
| 打开本地设置文档（header 动作） | `SettingsDocumentStore.open()` | `settings.openSettingsDocument()`（无参数） | — | `ui-settings-general/src/client/settings-document-store.ts:57-73` |
| Plugins 清单读取 | `list()` | `pluginInventory.list()` | — | `ui-settings-plugin-inventory/src/client/index.ts:36-42` |
| 断开重连（设置入口旁） | `connection.reconnect()` | —（连接层） | `—` | `ui-settings-general/src/client/index.ts:97` |

### 4.6 settings 传输基座（写入语义）

- 浏览器里**只有一个** `settings.describe` 读者：`SettingsDescribeMirror`。它在 `settings/document-updated` 与 `connection/reset` 两个信号上重新读取；首次连接也发 `connection/reset`，所以启动通常花两次读（预算由 `apps/web/tests/startup-rpc-budget.e2e.ts` 钉住；客户端代码新增直接 `settings.describe` 调用者即为回归）。来源：`ui-settings/src/client/index.ts:54-72`、`settings-mirror.ts:1-8`。
- 非 loopback 页面持久化为 `memory`：`const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'`；memory 模式下 scope 起始即 `unavailable`，写入直接 resolve 而不上线。来源：`ui-settings/src/client/index.ts:58`；`settings-mirror.ts:113-136`；`settings-scope.ts:71-83`、`:165-175`。
- 写路径：`set(field, value)` / `unset(field)` 都是 `mutate([...])` 的单操作形式；`mutate(ops, expectedRevision?)` 会 `structuredClone` 入参、串行排队（`tail`），携带 `expectedRevision ?? pendingRevision ?? snapshot.revision` 作为 fence；成功后若是最新写就把应答 `acceptView()` 折回镜像，被更新的写取代则把 revision 记进 `pendingRevision`；失败或拒绝且仍是最新写 → 触发一次镜像恢复读。来源：`settings-scope.ts:106-175`、`settings-mirror.ts:138-207`。
- 无 `decode` 时，section 必须是普通对象并通过 schema 复水验证，否则**整个 section 不发布值**（行自己渲染缺失态），而空数组/`null` 会被直接判为无效而非用对象默认值兜住。来源：`settings-scope.ts:202-216`。
- 已知限制（包 README 明示）：非 loopback 页面拿不到持久设置，scope 停在 `unavailable`，它支撑的每一行都是惰性的——尽管连接鉴权覆盖了 API。来源：`packages/client/ui-settings/README.md`（Known Limitations 段）。

---

## 5. 主题与本地化

### 5.1 `ui-theme`

| 事实 | 来源 |
|---|---|
| 偏好取值 `light` \| `dark` \| `system`，默认 `system`；设置命名空间 `ui-theme`，字段 `preference` 与 `fontSize` | `ui-theme/src/theme-settings.ts:6`、`:9`、`:12`、`:15`、`:21` |
| 字号约束：整数，`12..17`，默认 `14` | `:24-30`、`:43` |
| Host 侧注册 durable section（`ctx.inject(['settings'], …)` 内 `settings.register(THEME_SETTINGS_NAMESPACE, ThemeSettingsSchema)`），并参与 `webserver/index-inject`，往页面注入**内联 boot 脚本**——在开 body 之后、shell 挂载与 module script 之前，直接写 `documentElement.style.colorScheme`、`body[data-ds-dark-theme]`、`--dsh-content-font-size` | `ui-theme/src/index.ts:36-43`；`ui-theme/src/boot-theme.ts:12-37` |
| 浏览器侧 `ThemeRuntime` 是注册表 + 偏好拥有者：`light`/`dark` 内置（两套基础调色板在样式表里）；`register(definition)` 重复 id 抛错、`'system'` 不可注册为 id；`overrideTokens(source, tokens)` 按 seq 叠层、同 source 重调即整体替换并重排到最上层 | `ui-theme/src/client/index.ts:126-129`、`:275-317` |
| `ThemeRuntime` 自己持有 `matchMedia('(prefers-color-scheme: dark)')`，并在偏好为 `system` 且系统配色翻转时重发 `theme/change`；非浏览器运行（node e2e）无 matchMedia 时跳过 | `:158-196` |
| 快照 `ThemeSnapshot = { preference, fontSize, active, themes, revision }`；`active` 把 `system` 解析为具体主题，并把 override 层折进 tokens（按 seq，后者逐 token 胜，值按当前 colorScheme 取） | `:79-95`、`:319-352` |
| 主题令牌字典：`ThemeTokenInspection[]` 是注册表 + override-only 名字的并集，按名字排序，不读 DOM/computed style；内置清单 13 个 `--dsw-*` 别名令牌（`--dsw-alias-bg-base`、`-bg-layer-1/2`、`-bg-overlay`、`-border-l1/l2`、`-brand-primary`、`-label-primary/secondary`、`-state-error/success/warn-primary`、`--dsw-specific-sidebar-fill`），每个都要求同时给出 light/dark | `:131-145`、`:210-223` |
| 单值 override 抛教学式 `TypeError`（因为单值在切配色时会变得不可读），必须是 `{ light, dark }` 字符串对，且运行时校验（动态包可能传入无类型 JS） | `:383-403` |
| DOM 投影在 `ui-layout` 的 `ThemePresenter`（`ui-theme` 自身不碰 DOM）：写 `documentElement.style.colorScheme`、`body[data-ds-dark-theme]`（由 `active.colorScheme` 决定，绝不看 id）、`--dsh-content-font-size`、把 `active.tokens` 写成 body 内联变量，然后按 computed body 背景更新一个自持的 `meta[name="theme-color"]`；`dispose()` 只回收自己写过的东西 | `ui-layout/src/client/theme-presenter.ts:13-67`；`ui-layout/src/client/index.ts:148-158` |
| 初始字号防闪：`bootstrapFontSize()` 从 Host boot 脚本写的 `--dsh-content-font-size` 读回，非浏览器或无脚本时回退 schema 默认 | `ui-theme/src/client/index.ts:368-376` |

### 5.2 `locale`

| 事实 | 来源 |
|---|---|
| 签入语言**只有两种**：`LOCALE_IDS = ['zh','en']`；语言 id 走 BCP 47 风格正则 `^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$`；字典文件只有 `src/locales/en.ts`、`src/locales/zh.ts`（`locales/index.ts` 与 `locales/settings.ts` 只是再导出/`settings.locale` 命名空间） | `locale/src/locale-settings.ts:11-15`；目录树 `packages/client/locale/src/locales/` |
| 回退语言 `FALLBACK_LOCALE = 'en'`（理由源码写明：浏览器未点出已注册语言时的读者最不可能读中文）；`zh` 的 fallback 指向 `en`，`en` 无 fallback | `locale/src/client/index.ts:98-122` |
| 设置命名空间 `locale`，字段 `preference`（可选，缺省即交给浏览器） | `locale/src/locale-settings.ts:6`、`:9`、`:30-32` |
| 初始 locale：`detectBrowserLocale` 按 `navigator.languages` 顺序（末尾追加 `navigator.language`）先精确匹配 locale id，再匹配主语言子标签；**用 `window` 而非 `navigator` 做浏览器判定**（node 也有 `navigator`，不能让它决定） | `:499-527` |
| 切换：`setLocale(id)` 未知 id 抛错；只在与当前不同时才发布（避免无意义重渲），但 durable 写无条件下发 | `:236-242` |
| 语言包扩展：`addLanguage({ id, label, fallback })`——fallback 必须已注册且整条链必须终止于 `en`，否则抛错并回滚；返回幂等 disposer；移除当前语言时回退但不清理已存 id | `:256-278`、`:314-334` |
| 查找链：先按 active locale 的 fallback 链查 entry 自己的命名空间，未命中再在 `common` 命名空间重查同一链，仍未命中就把 key 本身当文案返回；`{name}` 占位由 `params` 替换 | `:446-463` |
| `register(ns, dicts)` 要求一次给全 `{ zh, en }`（双语平衡在注册期强制），`(ns, locale)` 重复即抛错；单语言无类型重载供语言包使用 | `:358-417` |
| 词典命名空间（本域可见）：`common`、`sidebar`、`workspace`、`settings`、`settings.locale`、`settings.theme`、`settings.models`、`settings.plugins`、`settings.pluginInventory`、`settings.agentPreset`、`directory-browser`、`settings.permission`、`permission.access` | 各包 `LocaleNamespaceMap` 声明与 `locale.register` 调用点：`ui-sidebar/src/client/index.ts:22`、`ui-workspace/src/client/index.ts:47`、`ui-settings-general/src/client/index.ts:48`、`locale/src/client/index.ts:44`、`ui-theme/src/client/index.ts:44`、`ui-settings-models/src/client/index.ts:38`、`ui-settings-plugins/src/client/PluginsSettingsSection.tsx:121`、`ui-settings-plugin-inventory/src/client/index.ts:21`、`ui-agent-preset/src/client/index.ts:42`、`ui-directory-picker-browse/src/client/index.ts:20`、`ui-permission-presets/src/client/PermissionRow.tsx:133`、`ui-permission-presets/src/client/index.ts:94`、`:104` |
| 文档语言同步：`document.documentElement.lang = snapshot.active === 'zh' ? 'zh-CN' : snapshot.active`，并在激活时立即同步一次（不等待首次变更） | `:146-150`、`:560-563` |
| 切换入口 UI：General 分页的 `LanguageRow` → `Menu` 弹层，选项是 locale 快照里的 `locales`（label 用各自语言书写），选中调 `setLocale(id)` 并关闭菜单 | `locale/src/client/LanguageRow.tsx:30-64` |

---

## 6. 本域 slot key 清单

cardinality / scope 取自各包 `declare module '@deepseek-ai/dsh-client-ui-slots'` 的 `SlotMap` 合并；declaredBy 是运行时 `children` / `register` 的声明点。

| slot key | cardinality | scope | declaredBy（声明点） | 占位者（occupant） | owner props |
|---|---|---|---|---|---|
| `root` | single | root | `ui-renderer` `registry.ts:43`（内建，唯一由 Cordis 服务直接渲染的 key） | `ui-layout` 的 `AppFrame` | `RootOwnerProps` |
| `sidebar` | single | root | `ui-layout` `index.ts:52`（声明）/`:127`（运行时） | `ui-sidebar` 的 `SidebarRoot` | `SidebarOwnerProps { collapsed, width }` |
| `conversation` | single | session-maybe | `ui-layout` `index.ts:65`/`:128` | `ui-conversation` 的 `ConversationRoot` | `{}`（空） |
| `details` | single | session | `ui-layout` `index.ts:75`/`:129` | `ui-chat` 的 `DetailsPanel`（`ui-chat/src/client/apply.ts:163-169`） | `{}`（空） |
| `shell.overlay` | list | root | `ui-layout` `index.ts:86`/`:130` | 无已签入注册（纯加性座位） | 无 |
| `sidebar.brand.mark` | single | root | `ui-sidebar` `contract/slots.ts:23`/`index.ts:57` | `ui-brand-official` 的 `OfficialBrandMark`（**仅 official 构建**） | `{ size: number }` |
| `sidebar.brand.name` | single | root | `ui-sidebar` `contract/slots.ts:28`/`index.ts:58` | `OfficialBrandName`（仅 official 构建） | 空（`children?: never`） |
| `sidebar.workspaces` | single | root | `ui-sidebar` `contract/slots.ts:35`/`index.ts:59` | `ui-workspace` 的 `WorkspaceBrowser` | `{ wide, expandSidebar }` |
| `sidebar.workspaces.directoryFlow` | single | root | `ui-workspace` `contract/slots.ts:58`，在 `register('sidebar.workspaces')` 的 children 里声明，`index.ts:141` | `ui-directory-picker-browse` 或 `-native` 的 flow 组件（二选一） | `DirectoryFlowOwnerProps` |
| `sidebar.settings` | single | root | `ui-sidebar` `contract/slots.ts:41`/`index.ts:60` | `ui-settings-general` 的 `SettingsRoot` | `{ wide }` |
| `sidebar.footer.action` | list | root | `ui-sidebar` `contract/slots.ts:46`/`index.ts:61` | 无已签入注册 | `{ wide }` |
| `settings.trigger` | single | root | `ui-settings` `contract/slots.ts:24`；运行时由 `ui-settings-general` 的 `register('sidebar.settings')` children 声明 `index.ts:150` | `ui-settings-general` 的 `TriggerContent` | `{ wide }` |
| `settings.header` | single | root | `ui-settings` `contract/slots.ts:30`；运行时 `index.ts:151` | `HeaderContent` | 空 |
| `settings.action` | list | root | `ui-settings` `contract/slots.ts:36`；运行时 `index.ts:152` | `SettingsDocumentAction`（id `open-document`, order 0，仅 loopback） | 空 |
| `settings.close` | single | root | `ui-settings` `contract/slots.ts:42`；运行时 `index.ts:153` | `CloseLabel` | 空 |
| `settings.section` | list | root | `ui-settings` `contract/slots.ts:54`；运行时 `index.ts:154` | `general`(0)、`models`(10)、`plugins`(15)、`agent-presets`(20) | `{ close: () => void }` |
| `settings.general.item` | list | root | `ui-settings` `contract/slots.ts:88`（类型住房在 ui-settings）；运行时由 `ui-settings-general` 的 `general` section children 声明 `index.ts:181` | `permission`(-20)、`language`(0)、`appearance`(10)、`font-size`(11)、`transcript-view`(12)、`composer-enter`(20) | 空 |
| `settings.onboarding` | list | root | `ui-settings` `contract/slots.ts:74`；运行时 `index.ts:155` | `welcome-notice`(-100)、`deepseek-official`(0) | `{ stepId, complete, openSection }` |
| `settings.plugins.tab` | list | root | `ui-settings` `contract/slots.ts:63`；运行时由 `ui-settings-plugins` 的 `plugins` section children 声明 `index.ts:152` | `configurable`(0)、`all`(10) | 空 |
| `settings.plugin.item` | keyed | root | `ui-settings-plugins` `slot-contract.ts:19`；运行时由 `configurable` tab children 声明 `index.ts:164` | key = `shell`、`agent-loop`、`subagent-model-selection`、`web-search-deepseek` | 空 |
| `settings.models.provider-card` | keyed | root | `ui-settings-models` `slot-contract.ts:33`；运行时由 `models` section children 声明 `index.ts:138` | 无已签入注册（entryKey = `settingsNs`） | `ProviderCardExtrasOwnerProps` |
| `settings.models.footer` | list | root | `ui-settings-models` `slot-contract.ts:38`；运行时 `index.ts:139` | 无已签入注册 | 空 |
| `conversation.hero.workspace.directoryFlow` | single | root | `ui-workspace` `contract/slots.ts:56`；运行时 `index.ts:151` | `ui-directory-picker-browse` 或 `-native` | `DirectoryFlowOwnerProps` |
| `conversation.hero.workspace` | single | root | `ui-conversation` `contract/slots.ts:121`（**他域声明**） | `ui-workspace` 的 `WorkspacePicker` | `EmptyWorkspaceOwnerProps` |
| `conversation.hero.agentPreset` | single | root | `ui-conversation` `apply.ts:208`（他域声明） | `ui-agent-preset` 的 `AgentPresetSeat` | `HeroAgentPresetOwnerProps` |

补充：本域包还占用两个他域座位——`ui-agent-preset` 向 `conversation.session.header.actions` 注册 `AgentPresetLabel`（id `agent-preset`, order -10，`ui-agent-preset/src/client/index.ts:158-165`），`ui-settings-plugin-inventory` 向 `settings.plugins.tab` 注册 `all`。

---

## 7. 每个用户操作触发的 RPC

`ctx.remote` 命名空间（`ui-settings/src/client/index.ts` 的 inject 声明展示了命名空间的声明方式）。本域实际触达的方法：

| 用户操作 | 调用点 | wire 方法 |
|---|---|---|
| 启动 Web（客户端冷启） | `ui-settings` mirror `ensure()`；`ui-settings-general` 注册 document 动作前读 `$host` | `settings.describe()`（启动通常 2 次）；`settings.describe` 之外的 `remote.$host` 是本地事实不产生 RPC |
| 新建/切换工作区（首次连接会话） | `UiWorkspaceService.connectWorkspace` → `sessions.create({ workspaceId })` → Host `session-controller` | `session.create` 系（客户端面为 `ctx.sessions.create`，wire 归属 `session-controller`） |
| 打开一个会话 | `ui-workspace` injected `open` | `sessions.open(sessionId)` |
| 侧栏新会话按钮 | `uiWorkspace.startSession()` | 同上 `session.create` → 随后本地 `open` |
| 工作区列表 / 归档集（流式） | `workspace-controller` client：`createWorkspaceStateStream` → `remote.workspace.follow(signal)`；增量为 `upsert` / `remove` / `order` / `archived` | `workspace.follow`（stream） |
| 新增工作区（采纳目录） | `workspaces.create({ path })` | `workspace.create` |
| 重命名工作区 | `workspaces.rename(workspaceId, title)` | `workspace.rename` |
| 删除工作区 | `workspaces.delete(workspaceId)` | `workspace.delete` |
| 拖动工作区排序 | `workspaces.insertBefore(workspaceId, beforeWorkspaceId?)` | `workspace.insertBefore` |
| 拖动会话排序（真实 Workspace 组内） | `workspaces.insertSessionBefore(workspaceId, sessionId, beforeSessionId?)` | `workspace.insertSessionBefore` |
| 归档会话 | `uiWorkspace.archiveSession(id)` → `workspaces.archiveSession(id)` | `workspace.archiveSession` |
| 重命名会话 | `sessions.binding(id)?.session.rename(title)` | 会话面 rename（`session.*`） |
| fork 会话 | `sessions.fork({ sessionId, increaseTitle: true })` | `session.fork` 系 |
| 侧栏搜索 | `sessions.search(query, signal)` | `session.search`；`session-query-sqlite` 在 `openAt:'never'` 下抛 `SESSION_QUERY_SEARCH_DISABLED` |
| 目录选择（原生） | `UiWorkspaceService.pickDirectory()` → `ctx.remote.directoryPicker.pick()` | `directoryPicker.pick`（需组合 `native` 能力，否则 `directory-picker/unavailable`） |
| 目录浏览（列表 / 新建文件夹） | `UiWorkspaceService.listDirectory(path, signal)` / `createDirectory(path, name)` | `directoryPicker.list` / `directoryPicker.createDirectory`（需 `browse` 能力；失败码映射为 `directory-picker/unreadable`、`directory-picker/exists`、`directory-picker/create-failed`） |
| 语言 / 外观 / 字号 / 权限 / 转写视图 / 忙时 Enter / 默认 preset | 各自 scope 或行 | `settings.mutate(ns, ops, expectedRevision)`；默认 preset 例外走 `settings.update(...)` |
| Models：编辑 provider profile | `ModelsOperations.writeSettings` | `settings.mutate(ns, ops, expectedRevision?)`，`settings/conflict` 单独映射 |
| Models：存/删 API key | `storeCredential` / `removeCredential` | `credentials.set(ref, value)` / `credentials.unset(ref)` |
| Models：页面加载与凭据徽标 | `ModelsSettingsStore.load` | `llm.listProviders()`、`llm.listConfigurableProviders()`、`credentials.describe(refs)` |
| Models：探测模型列表 | `discoverModels` | `llm.discoverModels(settingsNs, request)` |
| Plugins：清单 tab 加载/重试 | `list()` | `pluginInventory.list()` |
| 打开本地设置文档（loopback） | `SettingsDocumentStore.open()` | `settings.openSettingsDocument()` |
| 断开后手动重连 | `connection.reconnect()`（非 remote 命名空间，属 connection 服务） | —（WebSocket 重连） |
| agent preset：花名册读 | `controller.load()` / `section.load()` | `agentPresets.list()`；`agentPresets.read(id)`；`agentPresets.copy(...)`；`agentPresets.deletePreset(id)` |
| agent preset：为会话选定 | `seat.select(id)` → `agentPresets.select(session.id, staged)` | `agentPresets.select` |
| agent preset：打开预设目录 | `section.openLocation(id)`；可用性先问 `settings.canOpenAgentPresetDirectory()` | `settings.canOpenAgentPresetDirectory()` / `settings.openAgentPresetDirectory(id)` |

转发事件（`ctx.remote.$on`，非请求）：`settings/document-updated`、`connection/reset`、`credentials/reference-updated`、`llm/adapters-updated`（见 `ui-settings/src/client/index.ts:62-64`、`ui-settings-plugins/src/client/index.ts:80-95`、`ui-settings-models/src/client/index.ts:117-129`、`ui-agent-preset/src/client/index.ts:77-94`）。

---

## 8. 明确「源码未明确」的点

1. **置顶（pin）**：不存在独立的置顶字段或 API。可用的近似是 `orderBy: 'manual'` + 拖拽重排（真实 Workspace 组内持久化到 Host，Ungrouped/flat 账户仅本地）。
2. `sidebar.footer.action` 与 `shell.overlay`、`settings.models.provider-card`、`settings.models.footer` 在 Web 组合中**没有已签入占位者**——是纯加性扩展座位。
3. 侧栏搜索在后端内容搜索被禁用（Web 默认）时的**用户可见错误文案**：源码只把它落成 `status:'error'`，未见渲染该错误的路径，因此文案未明确。
4. `ui-agent-preset` 的 `writeDefaultPreset` 走 `settings.update`，与其它设置项走的 `settings.mutate` 不同；源码未解释这一差异（`ui-agent-preset/src/client/settings-store.ts:32`）。
5. locale 字典只签入 `zh` / `en`；任何其他语言均来自语言包插件的运行时 `addLanguage` + `register(ns, locale, dict)`，仓库内无第三个语言文件。
