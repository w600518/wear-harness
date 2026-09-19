# DSH Relay — 把 DeepSeek Harness 会话加密转发到 Wear OS 与 Android

本仓库把运行在本机的 DeepSeek Harness（下称 dsh）会话，经一条由使用方自持密钥的隧道转发到 Wear OS 手表与 Android 手机。发送端驻留在 dsh 所在的机器，服务端承担公网入口，客户端提供与 dsh Web UI 同源的会话视图与操作。全部流量为 AES-256-CBC 加密、HMAC-SHA256 认证，密钥由使用方设定。

```
┌──────────────────────────────────┐
│  运行 dsh 的机器（Windows）        │
│   dsh web 127.0.0.1:3080         │   ← 与 dsh Web UI 同源
│        ▲ HTTP RPC + WebSocket    │
│   dsh-relay-sender.exe (C)       │   只出站，不监听端口
└──────────┬───────────────────────┘
           │  AES-256-CBC + HMAC-SHA256
   ┌───────┴──────────────────┐
   │ dsh-relay-server.exe (C) │   发送端端口 + 客户端端口
   └───────┬──────────────────┘
           │  同一套加密
   ┌───────┴──────────────────────┐
   │ Wear OS 客户端 / Android 客户端 │   Flutter
   └──────────────────────────────┘
```

三端实现同一份协议，规范见 [`protocol/PROTOCOL.md`](protocol/PROTOCOL.md)。

## 目录

| 路径 | 内容 |
| --- | --- |
| `common/` | 三端共用的 C 库：AES/SHA-256/SHA-1、JSON、帧与握手、TCP/HTTP/WebSocket |
| `agent/` | 发送端源码 |
| `server/` | 服务端源码 |
| `client_wear/` | Flutter Wear OS 客户端，32 位 armeabi-v7a |
| `client_phone/` | Flutter Android 客户端，64 位 arm64-v8a |
| `protocol/` | 协议规范与测试向量生成器 |
| `scripts/` | 构建脚本 |
| `tests/` | C 一致性测试与 Node 端到端测试 |
| `docs/` | dsh Web UI 功能规格、dsh RPC 契约分析 |
| `third_party/deepseek-harness/` | dsh 源码（tag `dsh-v0.1.2-rc.1`），只读参考，未随仓库分发；缺失不影响构建 |

## 一、准备工具链

C 代码用便携版 LLVM-MinGW 编译，解压即用：

```powershell
# 下载（约 182 MB）
curl.exe -L -o tools\llvm-mingw.zip `
  https://github.com/mstorsjo/llvm-mingw/releases/download/20260908/llvm-mingw-20260908-ucrt-x86_64.zip

# 校验
(Get-FileHash tools\llvm-mingw.zip -Algorithm SHA256).Hash.ToLower()
# 期望 1bcf74d06b724aeecaa6412ca85f5b26fb1da770e7cdcefa9263c9c5c3ad34b6

Expand-Archive tools\llvm-mingw.zip -DestinationPath tools\llvm-mingw -Force
```

GitHub 直连缓慢时可给下载 URL 加镜像前缀，例如 `https://ghfast.top/`。

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

两个中继程序均为 Windows 图形程序（GUI 子系统）：双击打开窗口，加 `--console` 按控制台方式运行，供脚本与集成测试使用。二者共用同一份核心代码，界面是第二个前端，不是第二套实现。

构建脚本会顺带运行加密一致性测试，**111 项断言必须全部通过**；否则加密层与参考实现不一致，不应继续。

## 三、配置文件 config.json

两个程序各自在**程序所在目录**（不是当前工作目录）维护一份 `config.json`。首次运行时该文件不存在，程序以内置默认值启动并写回，因此打开文件即可看到它识别哪些键、当时采用何值。

服务端：

```json
{
  "port": 7777,
  "client_port": 7778,
  "passphrase": "",
  "log_level": "info"
}
```

`port` 为发送端端口，`client_port` 为客户端端口。

发送端：

```json
{
  "server_host": "127.0.0.1",
  "server_port": 7777,
  "passphrase": "",
  "dsh_url": "http://127.0.0.1:3080",
  "dsh_token": "",
  "device_name": "",
  "dsh_home": "",
  "log_level": "info"
}
```

命令行参数的优先级高于文件，生效的值会写回文件；窗口中点击连接或启动同样落盘。两个程序可放在同一目录，保存时各自保留对方写入的键。文件损坏时程序按默认值运行，并将原文件另存为 `config.json.bak`。

用 `--config PATH` 可指向其他文件。

## 四、dsh 认证

发送端代表本机 dsh 通信，须通过 dsh web 的浏览器认证。

**默认自动完成**：`dsh_token` 留空时，发送端读取本机 dsh 的凭据文件 `%USERPROFILE%\.dsh\.credentials.yaml` 中 browser-session 的签名密钥，在本地铸造一枚与浏览器同源的会话 cookie。cookie 的签名与时效校验由 dsh 服务端完成；铸造算法在 `tests/vectors.json` 的 `dsh web session cookies` 一节与 Node 实现交叉验证。

需要显式指定时，填入 `dsh web` 启动时打印的 token（窗口的 **dsh token** 栏，或 `config.json` 的 `dsh_token`）：

```powershell
dsh web --no-open
# 输出：dsh web: http://127.0.0.1:3080/?token=a2K8Q1jXV0QFhS64GfF2Fwu2Jo9GrK56upx0dlKCeXQ
#                                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

该 token 每次启动 dsh 都会变化，因此自动模式更为省事。两者都不可用时，发送端会报错并指明缺失的是哪一种。dsh 装在非默认位置时，用 `--dsh-home PATH`（或 `config.json` 的 `dsh_home`）指向其状态目录。

## 五、两个端口

服务端**监听两个端口**：

| 端口 | 默认 | 连接方 |
| --- | --- | --- |
| 发送端端口 | 7777 | 运行 `dsh-relay-sender.exe` 的机器 |
| 客户端端口 | 7778 | 手表与手机客户端 |

连接抵达哪个端口，就决定它是什么角色。发送端端口上声称自己是客户端的连接（或反之）会在派生任何密钥之前被直接拒绝：

```
[info ] sender port  7777
[info ] client port  7778
[warn ] handshake: refused a client on the sender port (from 127.0.0.1:51234)
```

如此拆分有两点实际作用：其一，信任域可以分开——发送端通常位于可信内网，客户端可能在外网，两个端口可套用不同的防火墙策略；其二，角色不由对端自称决定，`HELLO` 中的 `role` 必须与端口一致，否则拒绝。

两个端口必须不同。填成相同值、或只启用一个端口，等于放弃该校验，程序拒绝启动。

## 六、运行

**服务端**（部署于客户端可达的机器）：双击 `dsh-relay-server.exe`，填入发送端端口、客户端端口与共享口令，点击**启动服务**。窗口显示两个端口的监听状态、在线发送端列表与实时日志。

**发送端**（与 dsh 同机）：双击 `dsh-relay-sender.exe`，填入中继地址、发送端端口、共享口令与 dsh 地址，点击**连接中继**。dsh token 留空即可，发送端会自行取得认证（见第四节）。

**客户端**：见 [`client_wear/README.md`](client_wear/README.md) 与 [`client_phone/README.md`](client_phone/README.md)，连接的是**客户端端口**（默认 7778）。

三处口令必须完全一致。口令长度不足 8 个字符时程序拒绝启动。

在脚本或无人值守环境中运行，加 `--console`：

```powershell
build\dsh-relay-server.exe --console --port 7777 --client-port 7778 --passphrase 'your-long-secret'
build\dsh-relay-sender.exe --console --passphrase 'your-long-secret'
# dsh token 留空即自动取得认证；需显式指定时再加 --dsh-token <token>
```

服务端最多接受 64 个并发对端，并为每个发送端保留其最近一次的会话列表与运行状态，使中途加入的客户端无需等待重发即可获得完整视图。多客户端并发使用尚未支持。

## 七、验证

以下测试均扮演**客户端**，因此连接客户端端口（7778）：

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

这些脚本用 Node 的 crypto 独立实现同一套协议，通过即说明线缆格式确实可互操作，而非仅 C 端自洽。

诊断 dsh 连接：

```powershell
build\test_http.exe http://127.0.0.1:3080 <token>
```

## 八、客户端与 Web UI 的对齐

客户端的接口依据不是 dsh 的公开文档，而是从 dsh 源码（tag `dsh-v0.1.2-rc.1`）逐行提取的规格：`docs/DSH-WEBUI-SPEC.md` 与 `docs/DSH-RPC-CONTRACT.md` 记录了 Web UI 实际装配的 40 个客户端插件行、51 个会话事件类型、52 个 slot、72 个 RPC 端点与 WebSocket 流协议。

发送端调用 dsh 的**原生 RPC**（`POST /api/<namespace>/<method>` 与 `/api/remote.mux`），即浏览器 GUI 使用的同一条通道，不自造旁路，因此客户端所取数据与 Web UI 同源。

客户端使用下列精简词汇，参数整形由发送端承担（例如 `session/page` 所需的 `address` 对象、`session/prompt` 所需的 `requestId` 与 `content` 数组均在发送端补齐）：

`sessions/list`、`session/page`、`session/prompt`、`session/cancel`、`session/rename`、`session/fork`、`session/selectModel`、`session/modelCatalog`、`session/subscribe`、`session/unsubscribe`、`commands/list`、`commands/execute`、`goals/*`、`settings/describe`、`skills/list`、`relay/status`。

未列出的方法按逃生舱处理：客户端传什么方法名，发送端即将其作为 dsh 端点调用，`payload` 原样作为 `args`。dsh 新增端点无需改动发送端。

## 九、安全

- **角色由端口决定**：发送端端口只接受发送端，客户端端口只接受客户端。`HELLO` 中的 `role` 与端口不符时，服务端在派生任何密钥之前关闭连接。
- **加密**：AES-256-CBC，每帧独立随机 IV，PKCS#7 填充。
- **完整性**：HMAC-SHA256，encrypt-then-MAC，**先验证后解密**。头部同样被 MAC 覆盖，帧类型与序号无法被改写。
- **抗重放**：严格递增序号，连接内有效。MAC 未通过的帧不会推进任何状态。
- **认证**：握手携带 `HMAC(passphrase, "dsh-relay/v1" || nonce)` 作为持有口令的证明，口令本身不上线，比较为常量时间。
- **密钥派生**：PBKDF2-HMAC-SHA256，50000 次迭代；盐由服务端每次连接随机生成，并与双方 nonce 混合，同一口令不会产生重复的会话密钥。
- **暴露面**：发送端不监听任何端口，只主动出站；服务端只接受它已连接的发送端集合中存在的 `device`，不信任客户端指定的设备名。
- **dsh 认证**：发送端不掌握 dsh 的启动 token，而是读取本机 `~/.dsh/.credentials.yaml` 中的签名密钥，在本地铸造会话 cookie。该文件仅当前用户可读，而能读到它的进程本已可冒充本用户调用本机 dsh，因此不构成新的暴露面。铸出的 cookie 绑定请求的 Host 并带签发时间窗，离开本机即失效。

隧道重加密为**逐跳**而非端到端：服务端解密后重新加密，因此服务端能够看到明文。若服务端不可信，该架构不适用。

密钥由口令经 PBKDF2-HMAC-SHA256（50000 次迭代、连接随机盐）派生，盐与 nonce 公开，口令是唯一的保密输入，因此口令强度直接决定抵御离线暴力破解的能力。请使用长口令。

## 十、排查

| 现象 | 原因与处理 |
| --- | --- |
| 发送端报 `dsh authentication failed` | token 过期，或 `--dsh-url` 与 token 来源不是同一 dsh 实例（更换端口后须一并修改） |
| 客户端显示 `relay/dsh-unavailable` | 发送端已连上服务端，但未认证到本机 dsh；检查 token |
| 客户端显示 `relay/no-sender` | 无发送端在线，或 `device` 名称有误 |
| 订阅后长时间没有 snapshot | 长会话需先解压与投影，属正常；超过 30 秒仍无则查看发送端日志 |
| 服务端拒绝连接 | 三端口令不一致，发送端与服务端在握手阶段即拒绝，而非等到数据帧 |

`--verbose` 打开 debug 日志，打印每条 mux 帧与 relay 消息。

## 十一、版本基准

本文与协议对着 DeepSeek Harness tag `dsh-v0.1.2-rc.1`（commit `a66e470`）验证。dsh 的会话日志格式带 `SESSION_FORMAT_VERSION`，升级版本后需重新核对 `docs/DSH-RPC-CONTRACT.md`。

## 十二、许可

GNU Affero General Public License v3.0，全文见 [`LICENSE`](LICENSE)。

```
Copyright (c) 2026 w600518
```

AGPL-3.0 是强 copyleft 许可：可以自由使用、修改、分发，但**分发、或通过网络向他人提供服务时，必须一并提供完整源码**，修改后的版本仍须沿用 AGPL-3.0。软件按原样提供，不含任何担保。

就本项目而言，把 `dsh-relay-server.exe` 部署在服务器上供他人连接，属于上述「通过网络提供服务」，此时须使使用者能够取得对应源码。这是 AGPL 与 GPL 的唯一实质差别：GPL 不涉及网络服务，AGPL 涉及。

`third_party/` 下的 DeepSeek Harness 源码属于上游项目，适用其自身许可，不在本许可范围内。
