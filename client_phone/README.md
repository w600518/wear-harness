# client_wear — DSH Relay 的 Wear OS 客户端

手表端界面：浏览远端 dsh 的会话列表、阅读对话、发送输入、中断回合。全部流量经 relay 的 AES-256-CBC + HMAC-SHA256 隧道，协议规范见 [`../protocol/PROTOCOL.md`](../protocol/PROTOCOL.md)。

目标设备是 **32 位 armeabi-v7a 的 Wear OS 手表**，UI 为手写的 Wear Material 3 风格。

## 环境

| 组件 | 版本 / 路径 |
| --- | --- |
| Flutter | 3.44.9 stable，`F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat` |
| Dart | 3.12.2 |
| JDK | 21，`F:\Java\jdk-21.0.2`（需 `JAVA_HOME`） |
| Android SDK | `F:\Android\SDK`（platform android-36、build-tools 36.0.0） |
| Gradle | 9.1.0，wrapper 自动下载 |

`android/local.properties` 已固定 `sdk.dir` 与 `flutter.sdk`；Gradle 分发包指向 `mirrors.cloud.tencent.com`，因为 `services.gradle.org` 在本机不可达。

## 构建 32 位 APK

```powershell
$env:JAVA_HOME = "F:\Java\jdk-21.0.2"
$env:ANDROID_HOME = "F:\Android\SDK"
Set-Location "C:\Users\wxd72\Desktop\Wear harness\client_wear"

& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" pub get
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" build apk --target-platform android-arm --release
```

产物：`build\app\outputs\flutter-apk\app-release.apk`。

`android/app/build.gradle.kts` 里 `minSdk = 26`、`abiFilters += "armeabi-v7a"`，所以产物只含 32 位原生库：

```powershell
# 确认 APK 里只有 armeabi-v7a
tar -tf build\app\outputs\flutter-apk\app-release.apk | Select-String 'lib/'
```

## 测试

```powershell
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" analyze   # 应无任何输出
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" test      # 54 项
```

密码学测试读取 `test/fixtures/vectors.json`（由 `../protocol/tools/generate-vectors.mjs` 用 Node 的 crypto 生成，与 C 端 `tests/vectors.json` 同源），逐字节比对：

- SHA-256 / HMAC-SHA256 / PBKDF2-HMAC-SHA256 全部向量
- AES-256 单块（FIPS-197 C.3）与 AES-256-CBC + PKCS#7 全部向量
- 完整封帧等于 `frameTotalHex`，含 32 字节头、密文与 32 字节 HMAC
- 重放被拒、乱序被拒、翻转密文一比特在 MAC 阶段失败（而非填充阶段）、改序号失败、错误口令无法开启

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `lib/crypto/` | AES-256-CBC、SHA-256/HMAC/PBKDF2、帧格式与会话密钥派生 |
| `lib/relay/relay_client.dart` | 连接、握手、帧收发、请求-应答、订阅 |
| `lib/relay/session_store.dart` | 把 dsh 事件折叠成可渲染的对话行 |
| `lib/state/relay_session.dart` | 应用级状态：连接生命周期、自动重连、动作 |
| `lib/pages/` | 会话列表、对话、连接设置 |
| `lib/wear_m3/` | 手写的 Wear M3 组件（ScalingLazyColumn、卡片、芯片、圆形进度、TimeText、PositionIndicator） |

### 对话渲染

`SessionStore` 消费 relay 的 `sessions` / `snapshot` / `events` / `state` 消息，并把 dsh 的事件折叠成五种行：

- `UserMessageItem` — `user/message`
- `AssistantMessageItem` — `assistant/message`，并在流式期间由 `assistant/chunk` 与 `chunkrow/{text,reasoning}-chunks` 增量累积；`assistant/message` 到达时用完整文本定稿
- `ToolCallItem` — `tool/call` 与配对的 `tool/result`
- `ApprovalItem` — `approval/asked`
- `StatusItem` — `turn/end` 的中断/失败、`plan/mode`、`goal/change`、命令失败等

`goal`、`todo`、`model/selection`、`permission/preset`、`sandbox/mode` 与标题既来自事件，也来自 snapshot 与 `session/control` 的投影基线。

### 与 Web UI 的一致性

客户端的 RPC 词汇由发送端翻译成 dsh 的真实端点（`session/list`、`session/page`、`session/prompt`、`session/cancel`、`session/rename`、`session/selectModel`、`session/modelCatalog`、`commands/*` 等），也就是浏览器 GUI 使用的同一条通道。参数整形（`session/page` 的 `address` 对象、`session/prompt` 的 `requestId` 与 `content` 数组、子代理会话的 durable parent 地址）由发送端承担，客户端不需知道这些细节。dsh 的原始错误码一路透传，因此客户端能区分 `session/not-found`、`session/agent-busy` 等具体条件。

## 已知边界

- 审批与用户提问在 dsh 里不是消息流节点，而是输入区的 chain 接管，且没有独立 RPC。客户端把它们显示为醒目状态行，并提示通过 `/` 命令通道回应，而不是伪造一个不存在的审批接口。
- 图片附件未实现：dsh 把图片内联进 `session/prompt` 的 `content` 数组，手表端拍照上传尚未接入。
- 会话全文搜索在 Web 端默认关闭（`session-query-sqlite` 为 `openAt: never`），客户端因此只做列表内的本地过滤。
- 设置只存在内存中，重启应用后需要重新填写连接信息。
