# DSH Relay — 把 DeepSeek Harness 会话加密转发到 Wear OS

在运行 DeepSeek Harness 的机器上放一个**发送端**，在公网/局域网放一个**服务端**，在手表上装一个 **Wear OS 客户端**。发送端把本机 dsh 的会话、事件与运行状态推出去，手表能像浏览器那样看对话、发消息、取消回合、切模型、看后台任务；所有流量走 AES-256-CBC + HMAC-SHA256，密钥自己定。

```
┌──────────────────────────────┐
│  运行 dsh 的机器（Windows）    │
│                              │
│   dsh web 127.0.0.1:3080     │   ← 原版 Web UI 与它同源
│        ▲  HTTP RPC + WebSocket│
│        │                     │
│   dsh-relay-sender.exe (C)   │   只出站，不监听端口
└──────────┬───────────────────┘
           │  AES-256-CBC + HMAC-SHA256
   ┌───────┴────────┐
   │ dsh-relay-server.exe (C) │   监听 :7777，多发送端 / 多客户端
   └───────┬────────┘
           │  同一套加密
   ┌───────┴────────┐
   │ Wear OS 客户端 (Flutter) │   armeabi-v7a 32 位，Wear Material 3
   └────────────────┘
```

三端对同一份协议实现，规范见 [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md)。

## 目录

| 路径 | 内容 |
| --- | --- |
| `common/` | 三端共用的 C 库：AES/SHA-256/SHA-1、JSON、帧与握手、TCP/HTTP/WebSocket |
| `agent/` | 发送端源码 |
| `server/` | 服务端源码 |
| `client_wear/` | Flutter Wear OS 客户端 |
| `protocol/` | 协议规范与测试向量生成器 |
| `scripts/` | 构建脚本 |
| `tests/` | C 一致性测试与 Node 端到端测试 |
| `docs/` | dsh Web UI 功能规格、dsh RPC 契约分析 |
| `third_party/deepseek-harness/` | dsh 源码（tag `dsh-v0.1.2-rc.1`），只读参考；**未随仓库分发**，需要时自行放置，缺失不影响构建 |

## 一、准备工具链

Windows 上原本需要 Visual Studio 才能编 C。这里用的是便携版 LLVM-MinGW，解压即用：

```powershell
# 下载（约 182 MB）
curl.exe -L -o tools\llvm-mingw.zip `
  https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/llvm-mingw-20260908-ucrt-x86_64.zip

# 校验（可选但建议）
(Get-FileHash tools\llvm-mingw.zip -Algorithm SHA256).Hash.ToLower()
# 期望 1bcf74d06b724aeecaa6412ca85f5b26fb1da770e7cdcefa9263c9c5c3ad34b6

# 解压
Expand-Archive tools\llvm-mingw.zip -DestinationPath tools\llvm-mingw -Force
```

若 GitHub 直连太慢，在下载 URL 前加镜像前缀，例如 `https://ghfast.top/`。

## 二、编译

```powershell
powershell -File scripts\build.ps1
```

产出在 `build\`：

| 文件 | 用途 |
| --- | --- |
| `dsh-relay-server.exe` | 服务端（图形界面） |
| `dsh-relay-sender.exe` | 发送端（图形界面） |
| `test_crypto.exe` | 加密一致性测试 |
| `test_http.exe` | dsh HTTP 客户端诊断 |

两个中继程序都是 Windows 图形程序（GUI 子系统）：**双击打开窗口**，加 `--console` 则按原来的控制台方式运行，供脚本与集成测试使用。它们共用同一份核心代码，界面只是第二个前端，不是第二套实现。

脚本会顺带跑加密一致性测试；**111 项断言必须全绿**，否则说明加密层与参考实现不一致，不要继续。

## 三、配置文件 config.json

两个程序都会在**自己所在目录**（不是当前工作目录）维护一个 `config.json`。首次运行时它不存在，程序用内置默认值启动并把它们写出来，于是你打开文件就能看到它认识哪些键、当时用了什么值。

服务端：

```json
{
  "port": 7777,
  "client_port": 7778,
  "passphrase": "",
  "log_level": "info"
}
```

`port` 是**发送端端口**，`client_port` 是**客户端端口**（见下一节）。

发送端：

```json
{
  "server_host": "127.0.0.1",
  "server_port": 7777,
  "passphrase": "",
  "dsh_url": "http://127.0.0.1:3080",
  "dsh_token": "",
  "device_name": "",
  "log_level": "info"
}
```

命令行参数**优先级高于文件**，并且生效的值会被写回文件。窗口里改完点“连接/启动”同样会落盘。

两个程序可以放在同一个目录：保存时会保留对方写入的键，不会互相覆盖。文件损坏时程序按默认值运行，并把原文件另存为 `config.json.bak` 而不是直接丢弃。

用 `--config PATH` 可以指向别的文件。

## 四、dsh 认证

发送端要代表本机 dsh 说话，必须通过 dsh web 的浏览器认证。**默认自动完成，无需任何手工步骤**：`dsh_token` 留空时，发送端读取本机 dsh 的凭据文件（`%USERPROFILE%\.dsh\.credentials.yaml` 里的 browser-session 签名密钥），在本地铸造一枚与浏览器完全同源的会话 cookie。cookie 的签名与时效校验由 dsh 服务端完成，铸造算法在 `tests/vectors.json` 里与 Node 交叉验证（`dsh web session cookies` 一节）。

`dsh web` 启动时打印的 token 仍然有效——它是另一种（一次性、只存在于 dsh 进程内存里的）凭据。想要显式指定时，把它填进发送端窗口的 **dsh token** 栏（或 `config.json` 的 `dsh_token`）：

```powershell
dsh web --no-open
# 输出：dsh web: http://127.0.0.1:3080/?token=a2K8Q1jXV0QFhS64GfF2Fwu2Jo9GrK56upx0dlKCeXQ
#                                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
#                                              填这一串
```

token 每次启动 dsh 都会变，因此自动模式更省事。两者都不可用时，发送端会明确报错并说明缺哪一种。dsh 装在非默认位置时，用 `--dsh-home PATH`（或 `config.json` 的 `dsh_home`）指向它的状态目录。

## 五、两个端口

服务端**监听两个端口**，而不是一个：

| 端口 | 默认 | 谁连它 |
| --- | --- | --- |
| 发送端端口 | 7777 | 运行 `dsh-relay-sender.exe` 的机器 |
| 客户端端口 | 7778 | 手表客户端 |

**连接来自哪个端口，就决定了它是什么**。发送端端口进来的连接若在握手里声称自己是客户端（或反过来），会在派生任何密钥之前被直接拒绝：

```
[info ] sender port  7777
[info ] client port  7778
[warn ] handshake: refused a client on the sender port (from 127.0.0.1:51234)
```

这样拆分有两个实际好处。一是信任域可以分开：发送端通常在可信内网里，手表可能在外网，两个端口可以套用完全不同的防火墙策略。二是角色不再由对端自称决定——改一个 wire 字段骗不过去，`role` 必须和端口一致。

两个端口必须不同；填成一样、或只开一个端口，等于放弃这道校验，程序会拒绝启动。

## 六、运行

**服务端**（放在能被手表访问到的那台机器上）：双击 `dsh-relay-server.exe`，填发送端端口、客户端端口与共享口令，点**启动服务**。窗口会显示两个端口各自的监听状态、在线发送端列表与实时日志。

**发送端**（与 dsh 同一台机器）：双击 `dsh-relay-sender.exe`，填中继地址、**发送端端口**、共享口令、dsh 地址，点**连接中继**。dsh token 留空即可，发送端会自己取得 dsh 认证（见第四节）。

**客户端**：见 [`client_wear/README.md`](client_wear/README.md)，它连的是**客户端端口**（默认 7778）。

三处口令必须完全一致。口令短于 8 个字符时程序会拒绝启动——它就是整条隧道密钥的全部熵来源。

需要在脚本或无人值守环境里跑，加 `--console`：

```powershell
build\dsh-relay-server.exe --console --port 7777 --client-port 7778 --passphrase 'your-long-secret'
build\dsh-relay-sender.exe --console --passphrase 'your-long-secret'
# dsh token 留空即自动取得认证；需要显式指定时再加 --dsh-token <token>
```

### 多客户端

暂不支持多客户端（懒得写）。

## 七、验证

下面的测试都扮演**客户端**，因此连客户端端口（7778）：

```powershell
# 会话列表、设备发现、请求往返（独立实现，用于交叉验证协议）
node tests\relay_client.mjs 127.0.0.1 7778 'your-long-secret'

# 订阅真实会话：snapshot -> 历史记录 -> 按 cursor 翻页
node tests\relay_follow.mjs 127.0.0.1 7778 'your-long-secret'
node tests\relay_follow.mjs 127.0.0.1 7778 'your-long-secret' session-xxxxxxxx-...

# 角色隔离：四种组合各试一次，两种必须被拒
node tests\relay_role_isolation.mjs 127.0.0.1 7777 7778 'your-long-secret'

# 参数整形契约：每个映射方法都必须到达 dsh，而不是被参数校验挡回
node tests\relay_methods.mjs 127.0.0.1 7778 'your-long-secret'
```

这些脚本用 Node 的 crypto 独立实现同一套协议，因此通过即说明线缆格式确实可互操作，而不只是 C 端自洽。

诊断 dsh 连接：

```powershell
build\test_http.exe http://127.0.0.1:3080 <token>
```

## 八、客户端与 Web UI 的对齐

客户端不是照抄 dsh 的接口文档猜出来的：`docs/DSH-WEBUI-SPEC.md` 与 `docs/DSH-RPC-CONTRACT.md` 是从 dsh 源码（tag `dsh-v0.1.2-rc.1`）逐行提取的权威规格——Web UI 实际装配的 40 个客户端插件行、51 个会话事件类型、52 个 slot、72 个 RPC 端点与 WebSocket 流协议。

发送端直接调 dsh 的**原生 RPC**（`POST /api/<namespace>/<method>` 与 `/api/remote.mux`），也就是浏览器 GUI 用的同一条通道，而不是自造旁路。因此客户端看到的数据与 Web UI 同源。

客户端说的是下面这层精简词汇，参数整形由发送端承担（例如 `session/page` 需要的 `address` 对象、`session/prompt` 需要的 `requestId` 与 `content` 数组都在发送端补齐）：

`sessions/list`、`session/page`、`session/prompt`、`session/cancel`、`session/rename`、`session/fork`、`session/selectModel`、`session/modelCatalog`、`session/subscribe`、`session/unsubscribe`、`commands/list`、`commands/execute`、`goals/*`、`settings/describe`、`skills/list`、`relay/status`。

未列出的方法会按逃生舱处理：客户端传什么方法名，发送端就把它当 dsh 端点调用，`payload` 原样作为 `args`。dsh 新增端点不需要改发送端。

## 九、安全

- **角色由端口决定**：发送端端口只接受发送端，客户端端口只接受客户端。`HELLO` 里的 `role` 与端口不符时，服务端在派生任何密钥之前就关闭连接，因此伪装角色的作用等于零。
- **加密**：AES-256-CBC，每帧独立随机 IV，PKCS#7 填充。
- **完整性**：HMAC-SHA256，encrypt-then-MAC，**先验证后解密**。头部也被 MAC 覆盖，因此帧类型与序号无法被改写。
- **抗重放**：严格递增序号，连接内有效。未通过 MAC 的帧不会推进任何状态。
- **认证**：握手携带 `HMAC(passphrase, "dsh-relay/v1" || nonce)` 作为持有口令的证明，口令本身从不上线；比较为常量时间。
- **密钥派生**：PBKDF2-HMAC-SHA256，50000 次迭代，盐由服务端每次连接随机生成，并与双方 nonce 混合。同一个口令不会产生重复的会话密钥。
- **暴露面**：发送端不监听任何端口，只主动出站；服务端只接受它已连接的发送端集合中存在的 `device`，不信任客户端指定的设备名。
- **dsh 认证**：发送端不掌握 dsh 的启动 token，而是读取本机 `~/.dsh/.credentials.yaml` 里的签名密钥，在本地铸造会话 cookie。该文件只有当前用户可读，而能读到它的进程本来就能冒充你调用本机 dsh——它不构成新的暴露面。铸出的 cookie 绑定请求的 Host 并带签发时间窗，离开本机即失效。

口令强度直接决定隧道强度——发送端会用 50000 次 PBKDF2，但弱口令仍可被离线暴力破解。用长口令。

## 十、排查

| 现象 | 原因与处理 |
| --- | --- |
| 发送端报 `dsh authentication failed` | token 过期，或 `--dsh-url` 与 token 来源不是同一个 dsh 实例（换端口后必须一起改） |
| 客户端显示 `relay/dsh-unavailable` | 发送端连上了服务端，但没有认证到本机 dsh；检查 token |
| 客户端显示 `relay/no-sender` | 没有发送端在线，或 `device` 名字写错 |
| 订阅后长时间没有 snapshot | 长会话需要先解压与投影，属正常；超过 30 秒仍无则看发送端日志 |
| 服务端拒绝连接 | 三端口令不一致。发送端/服务端在握手阶段就会拒绝，而不是等到数据帧 |

`--verbose` 打开 debug 日志，会打印每条 mux 帧与 relay 消息。

## 十一、版本基准

本文与协议对着 DeepSeek Harness tag `dsh-v0.1.2-rc.1`（commit `a66e470`）验证。dsh 的会话日志格式带 `SESSION_FORMAT_VERSION`，升级版本后需要重新核对 `docs/DSH-RPC-CONTRACT.md`。

## 十二、许可

GNU Affero General Public License v3.0，全文见 [`LICENSE`](LICENSE)。

```
Copyright (c) 2026 w600518
```

这是一份强 copyleft 许可：你可以自由使用、修改、分发，但**分发、或通过网络向他人提供服务时，必须一并提供完整源码**，且修改后的版本仍须沿用 AGPL-3.0。软件按原样提供，不含任何担保。

具体到本项目：把 `dsh-relay-server.exe` 放在服务器上让别人连，就落在这个「通过网络提供服务」的范围内，此时需要让使用者能取得对应源码。这也是 AGPL 与 GPL 的唯一实质差别——GPL 管不到网络服务，AGPL 管得到。

`third_party/` 下的 DeepSeek Harness 源码属于上游项目，适用其自身许可，不在本许可范围内。
