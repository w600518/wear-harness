# client_wear — DSH Relay 的 Wear OS 客户端

在 32 位 armeabi-v7a 的 Wear OS 手表上浏览远端 dsh 的会话列表、阅读对话、发送输入、中断回合、切换模型与查看后台任务。全部流量经 relay 的 AES-256-CBC + HMAC-SHA256 隧道，协议规范见 [`../protocol/PROTOCOL.md`](../protocol/PROTOCOL.md)。

界面由手写的 Wear Material 3 风格组件构成，不依赖 `flutter_wear` 或 Wear Compose。

## 环境

| 组件 | 版本 / 路径 |
| --- | --- |
| Flutter | 3.44.9 stable，`F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat` |
| Dart | 3.12.2 |
| JDK | 21，`F:\Java\jdk-21.0.2`（需 `JAVA_HOME`） |
| Android SDK | `F:\Android\SDK`（platform android-36、build-tools 36.0.0） |
| Gradle | 9.1.0，wrapper 自动下载 |

`android/local.properties` 已固定 `sdk.dir` 与 `flutter.sdk`；Gradle 分发包指向 `mirrors.cloud.tencent.com`，因为本机无法访问 `services.gradle.org`。

## 构建

```powershell
$env:JAVA_HOME = "F:\Java\jdk-21.0.2"
$env:ANDROID_HOME = "F:\Android\SDK"
Set-Location "C:\Users\wxd72\Desktop\Wear harness\client_wear"

& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" pub get
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" build apk --target-platform android-arm --release
```

产物为 `build\app\outputs\flutter-apk\app-release.apk`，约 15.0 MB。

**`--target-platform android-arm` 不可省略。** `android/app/build.gradle.kts` 中的 `minSdk = 26` 与 `abiFilters += "armeabi-v7a"` 只描述最低系统版本与目标 ABI，不足以约束打包结果：省略该参数时 Flutter 会为三个 ABI 各打入一份完整原生库，产物达约 49.9 MB。带上它则只含 armeabi-v7a 一份。

```powershell
# 核对：完整原生库应只出现在 lib/armeabi-v7a/ 下
tar -tf build\app\outputs\flutter-apk\app-release.apk | Select-String 'lib/'
```

## 测试

```powershell
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" analyze   # No issues found!
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" test      # 55 项
```

密码学测试读取 `test/fixtures/vectors.json`，它是仓库根 `tests/vectors.json` 的逐字节副本（由 `protocol/tools/generate-vectors.mjs` 生成，并由 `tests/test_crypto.c` 断言），逐字节比对：

- SHA-256 / HMAC-SHA256 / PBKDF2-HMAC-SHA256 全部向量
- AES-256 单块（FIPS-197 C.3）与 AES-256-CBC + PKCS#7 全部向量
- 完整封帧等于 `frameVector`，含 32 字节头、密文与 32 字节 HMAC
- 重放被拒、乱序被拒、翻转密文一比特在 MAC 阶段失败（而非填充阶段）、改序号失败、错误口令无法开启

其中 `fixture copy` 用例核对副本与仓库根文件是否仍逐字节一致。两者由生成器维护，不应手工编辑。

## 表冠

表冠驱动当前页面的滚动，并在滚动时轻震。Flutter 在 Wear OS 上没有转动的输入接口，所以这条链路走 platform channel：`MainActivity` 读原生事件，`RotaryScroll` 在 Dart 侧决定滚到哪里、何时震动。

三处平台差异在实现里都做了处理，没有一处是可选的：

- **事件层级**：在 `dispatchGenericMotionEvent` 拦截。Flutter 的 activity 把 motion 事件交给自己的 view，view 会消费滚轮事件，`onGenericMotionEvent` 那一层从未被调用过。
- **轴的名称**：这块手表把表冠报成 `SOURCE_MOUSE`（`0x2002`）而不是 AOSP 的 `SOURCE_ROTARY_ENCODER`，转动量落在 `AXIS_VSCROLL` 上，`AXIS_SCROLL` 恒为 0。代码因此不判断 source，只在三个滚动轴里取第一个非零值。
- **震动的接口**：使用欧加私有的 `android.os.linearmotorvibrator.LinearmotorVibrator` 与 `WaveformEffect`（type 302 / strength 2），与厂方的表冠反馈是同一个效果。该类不在公开 SDK 中，故经反射调用；反射失败或服务缺失时回退到 `VibrationEffect.createOneShot(30ms, 80)`。

行为上：列表确实移动了才震，两次之间至少间隔 40 ms；到达顶端或底端时不震（留 0.5 像素的舍入余量，并把累积清零，避免回转时补发）；页面没有可滚内容时不震。判据是「滚动是否真的发生」，由 Dart 侧给出，因为只有它知道列表在哪里。

开关在客户端设置页，键为 `watch.crownVibrate`，默认开启，改动即时下发原生。

## 连接设置

地址、端口、口令与设备名（`relay.host`、`relay.port`、`relay.passphrase`、`relay.deviceName`）持久化于 `SharedPreferences`，应用重启后无需重新填写。四个字段初始为空，未填写完整时连接保持拒绝。表冠震动开关（`watch.crownVibrate`）同样持久化，默认开启。

`VIBRATE` 权限在清单中声明。缺了它震动会被静默丢弃，在手腕上表现得像表冠坏了。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `lib/crypto/` | AES-256-CBC、SHA-256/HMAC/PBKDF2、帧格式与会话密钥派生 |
| `lib/relay/relay_client.dart` | 连接、握手、帧收发、请求-应答、订阅 |
| `lib/relay/session_store.dart` | 把 dsh 事件折叠成可渲染的对话行 |
| `lib/state/relay_session.dart` | 应用级状态：连接生命周期、自动重连、动作 |
| `lib/state/rotary_scroll.dart` | 表冠的滚动与震动：页面认领、按实际位移请求震动 |
| `lib/pages/` | 会话列表、对话、连接设置 |
| `lib/wear_m3/` | 手写的 Wear M3 组件（ScalingLazyColumn、卡片、芯片、圆形进度、TimeText、PositionIndicator） |
| `android/app/src/main/kotlin/.../MainActivity.kt` | 读表冠事件、把滚动量交给 Dart、调用震动 |

### 对话渲染

`SessionStore` 消费 relay 的 `sessions` / `snapshot` / `events` / `state` 消息，把 dsh 事件折叠成五种行：

- `UserMessageItem` — `user/message`
- `AssistantMessageItem` — `assistant/message`，流式期间由 `assistant/chunk` 与 `chunkrow/{text,reasoning}-chunks` 增量累积，`assistant/message` 到达时以完整文本定稿
- `ToolCallItem` — `tool/call` 与配对的 `tool/result`
- `ApprovalItem` — `approval/asked`
- `StatusItem` — `turn/end` 的中断与失败、`plan/mode`、`goal/change`、命令失败等

`goal`、`todo`、`model/selection`、`permission/preset`、`sandbox/mode` 与标题既来自事件，也来自 snapshot 与 `session/control` 的投影基线。

RPC 词汇由发送端翻译为 dsh 的真实端点（`session/page`、`session/prompt`、`session/cancel`、`session/selectModel`、`commands/*` 等），即浏览器 GUI 使用的同一条通道；参数整形（`session/page` 的 `address` 对象、`session/prompt` 的 `requestId` 与 `content` 数组）由发送端承担，dsh 的原始错误码一路透传。

## 已知边界

- 审批与用户提问在 dsh 中不是消息流节点，而是输入区的 chain 接管，且没有独立 RPC。客户端将其显示为状态行，并提示通过 `/` 命令通道回应，不伪造审批接口。
- 图片附件未实现：dsh 将图片内联进 `session/prompt` 的 `content` 数组，端上拍照上传尚未接入。
- 会话全文搜索在 Web 端默认关闭（`session-query-sqlite` 为 `openAt: never`），客户端因此只做列表内的本地过滤。
