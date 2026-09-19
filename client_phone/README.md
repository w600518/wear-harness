# client_phone — DSH Relay 的方屏版客户端

方屏版运行于 Android 手机与平板等方形屏幕设备，完成与 `client_wear`（手表版）相同的操作：浏览远端 dsh 的会话列表、阅读对话、发送输入、中断回合、切换模型与查看后台任务。全部流量经 relay 的 AES-256-CBC + HMAC-SHA256 隧道，协议规范见 [`../protocol/PROTOCOL.md`](../protocol/PROTOCOL.md)。

构建目标为 64 位 arm64-v8a。

## 与 client_wear 的关系

本目录是 `client_wear` 的副本，二者共用同一套实现。差异集中在下表各处；改动涉及公共代码时，两个目录需要同步。

| 项 | `client_wear` | `client_phone` |
| --- | --- | --- |
| 应用 ID | `com.dsh.client_wear` | `com.dsh.client_phone` |
| 应用名 | `client_wear` | `方屏版` |
| `android.hardware.type.watch` | 声明，仅限手表安装 | 不声明，手机与手表均可安装 |
| 构建目标 | `android-arm`，armeabi-v7a，约 15.0 MB | `android-arm64`，arm64-v8a，约 16.8 MB |
| `ScalingLazyColumn.scalingEnabled` | 默认 `true`，条目随屏幕缩放 | 默认 `false`，条目不缩放 |
| `PositionIndicator` | 沿表圈绘制弧形拇指 | 提供 `straight` 参数并默认 `true`，绘制竖直滚动条 |
| 表冠 | `MainActivity` 读表冠事件并驱动滚动与震动 | 不读取表冠；`rotary_scroll.dart` 共享，但没有事件源 |

除 `package:client_wear/` 与 `package:client_phone/` 的导入前缀外，Dart 源码内容一致。`MainActivity.kt` 是两端的第二个例外：手表版在其中接入表冠（读事件、震动），方屏版仍是默认的空实现，`VIBRATE` 权限也只声明在手表版清单中。

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
Set-Location "C:\Users\wxd72\Desktop\Wear harness\client_phone"

& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" pub get
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" build apk --target-platform android-arm64 --release
```

产物为 `build\app\outputs\flutter-apk\app-release.apk`，约 16.8 MB。

`--target-platform android-arm64` 决定 APK 携带的原生库。`android/app/build.gradle.kts` 中的 `abiFilters += "armeabi-v7a"` 沿用自 `client_wear` 副本，指向 32 位，因此目标 ABI 必须由构建命令显式给出。

```powershell
# 核对：完整原生库应只出现在 lib/arm64-v8a/ 下，其余 ABI 目录只留依赖的少量存根
tar -tf build\app\outputs\flutter-apk\app-release.apk | Select-String 'lib/'
```

## 测试

```powershell
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" analyze   # No issues found!
& "F:\flutter_windows_3.44.9-stable\flutter\bin\flutter.bat" test      # 55 项
```

密码学测试读取 `test/fixtures/vectors.json`，它是仓库根 `tests/vectors.json` 的逐字节副本，由 `fixture copy` 用例核对一致性。两者均由 `protocol/tools/generate-vectors.mjs` 生成，不应手工编辑。

## 连接设置

地址、端口、口令与设备名（`relay.host`、`relay.port`、`relay.passphrase`、`relay.deviceName`）持久化于 `SharedPreferences`，应用重启后无需重新填写。四个字段初始为空，未填写完整时连接保持拒绝。

## 代码结构与对话渲染

与 [`../client_wear/README.md`](../client_wear/README.md) 相同：`lib/crypto/` 承担加密与帧格式，`lib/relay/` 承担连接与事件折叠，`lib/state/` 承担应用级状态，`lib/pages/` 与 `lib/wear_m3/` 承担界面。

## 已知边界

- 审批与用户提问在 dsh 中不是消息流节点，而是输入区的 chain 接管，且没有独立 RPC。客户端将其显示为状态行，并提示通过 `/` 命令通道回应，不伪造审批接口。
- 图片附件未实现：dsh 将图片内联进 `session/prompt` 的 `content` 数组，拍照上传尚未接入。
- 会话全文搜索在 Web 端默认关闭（`session-query-sqlite` 为 `openAt: never`），客户端因此只做列表内的本地过滤。
