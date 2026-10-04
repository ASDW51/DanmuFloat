# DanmuFloat

> 多直播间弹幕悬浮窗（Android）。纯弹幕查看器，把弹幕以悬浮窗形式覆盖在其他应用之上。

[English](#english) | 中文

## 简介

DanmuFloat 是一个 Android 端的弹幕悬浮窗应用。添加直播间后，它会把弹幕以悬浮窗的形式
覆盖在任意应用之上，方便在游戏、观影等场景下查看直播弹幕。支持同时监控多个直播间，
每个直播间独立一栏、独立连接与滚动。

本应用仅做「查看弹幕」一件事：不登录账号、不发送弹幕、不做任何互动。

## 功能特性

- **多直播间悬浮窗**：多栏布局（1 栏铺满，2–4 栏 2 列，5 栏及以上 3 列），每栏独立连接与滚动位置。
- **弹幕展示**：普通 / 飘屏 / 特权弹幕区分显示；等级、灯牌、荣誉等信息前置；底部固定最新一条进场消息；栏标题行显示在线人数。
- **悬浮球交互**：锁定移动、增 / 减栏位、逐栏换绑、窗口宽高 / 透明度 / 字号滑杆、适配尺寸、关闭悬浮窗；悬浮球支持四角吸附、闲置半透明与隐藏。
- **窗口位置与尺寸持久化**：拖动结束后保存位置，重开窗口按上次位置与尺寸还原；仅在窗口越过左右屏幕边界时吸附到对应边缘。
- **凭证管理**：默认匿名自动获取；可全局配置多份凭证并为主播分别指定，凭证加密保存在本地。
- **弹幕过滤与样式**：关键字过滤、主题 / 皮肤、透明度与字号调节。
- **数据与隐私**：支持数据备份导出 / 导入、一键清除本地数据；首次启动需阅读并同意免责声明。

## 免责声明与合规

- 本项目仅供**学习与研究**使用，**禁止任何商业用途**。

## 环境要求

- Flutter（Dart SDK `^3.10.9`）
- Android SDK + JDK 17
- Android 真机或模拟器（悬浮窗、前台服务等建议使用真机调试）

## 构建与运行

```bash
git clone https://github.com/ASDW51/DanmuFloat.git
cd DanmuFloat
flutter pub get

flutter run                 # 连接设备后调试运行
flutter test                # 运行单元测试
flutter build apk --debug   # 构建调试包
flutter build apk --release # 构建发布包（需先配置签名，见下）
```

> **签名说明**：Release 包使用 `android/key.properties` 指定的签名。本地执行
> `scripts/generate-keystore.ps1` 即可生成 keystore 与 `key.properties`（两者均已被
> `.gitignore` 忽略，不会入库，请离线备份）。未配置时构建会回退 debug 签名并打印警告，
> 仅供本地调试，不可用于发布。正式发布由 [`.github/workflows/release.yml`](.github/workflows/release.yml)
> 从仓库 Secrets 还原签名文件后自动构建，产物与 SHA256 校验和见 [Releases](https://github.com/ASDW51/DanmuFloat/releases)。

## 权限说明

| 权限 | 用途 |
| --- | --- |
| `INTERNET` | 请求房间信息接口、建立弹幕 WebSocket |
| `SYSTEM_ALERT_WINDOW` | 悬浮窗覆盖在其他应用之上（由插件合并声明） |
| `FOREGROUND_SERVICE_SPECIAL_USE` | 悬浮窗前台服务保活（Android 14+） |
| `POST_NOTIFICATIONS` | 前台服务常驻通知（Android 13+） |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | 申请电池优化白名单，降低后台被系统回收的概率 |

首次启动会引导你依次授予悬浮窗、通知与电池优化白名单权限。

## 第三方与致谢

- [`flutter_screen_overlay`](third_party/flutter_screen_overlay)：悬浮窗基础能力，MIT 许可。
  本项目使用本地内联副本（`third_party/`），修复了上行消息转发通道被覆盖的问题，详见
  `pubspec.yaml` 与 `third_party/flutter_screen_overlay/LICENSE`。
- 项目参考：[renmu123/biliLive-tools](https://github.com/renmu123/biliLive-tools)。

## 授权许可

本项目采用 [**PolyForm Noncommercial License 1.0.0**](LICENSE)：仅允许非商业用途。
**这不是 OSI 定义下的开源许可**，任何商业使用（包括但不限于销售、广告变现、商业服务）
均被禁止。详见 [LICENSE](LICENSE)。

---

## English

# DanmuFloat

> A multi-room danmaku (bullet comment) overlay for Android. A pure viewer that displays live
> comments in a floating window on top of other apps.

### Overview

DanmuFloat is an Android app that shows live-stream danmaku in a floating overlay above any other
app. Add a room and its comments will float on your screen — handy while gaming or watching video.
You can monitor several rooms at once; each room gets its own pane with an independent connection
and scroll position.

It does exactly one thing — display danmaku. It does not log in, send comments, or interact.

### Features

- **Multi-room overlay**: multi-pane layout (1 pane full width; 2–4 panes in 2 columns; 5+ panes in 3 columns), each with its own connection and scroll state.
- **Rich display**: distinguishes normal / scrolling / privileged danmaku; shows level, fan badge and honor before the nickname; a fixed bottom line for the latest "entered the room" message; viewer count in the pane title.
- **Floating ball controls**: lock movement, add / remove panes, rebind a pane, sliders for width / height / opacity / font size, fit-to-screen, close overlay; the ball snaps to corners, fades when idle and can be hidden.
- **Persistent position and size**: the window position is saved after dragging and restored on reopen; it only snaps to a screen edge when dragged across the left or right boundary.
- **Credential management**: anonymous by default; configure multiple named credentials and assign them per room; stored encrypted on device.
- **Filtering and styling**: keyword filters, themes / skins, opacity and font size.
- **Data and privacy**: export / import backups, one-tap local data wipe; the disclaimer must be accepted on first launch.

### Disclaimer and Compliance

- This project is for **study and research only**. **Any commercial use is prohibited.**

### Requirements

- Flutter (Dart SDK `^3.10.9`)
- Android SDK + JDK 17
- A real Android device or emulator (a physical device is recommended for overlay / foreground service testing)

### Build and Run

```bash
git clone https://github.com/ASDW51/DanmuFloat.git
cd DanmuFloat
flutter pub get

flutter run                 # debug run on a connected device
flutter test                # run unit tests
flutter build apk --debug   # build a debug APK
flutter build apk --release # build a release APK (signing config required, see below)
```

> **Signing**: release APKs are signed with the config in `android/key.properties`. Run
> `scripts/generate-keystore.ps1` locally to create the keystore and `key.properties` (both are
> git-ignored and never committed — keep an offline backup). If the file is missing, the build
> falls back to the debug signing config and prints a warning; that is for local debugging only and
> must not be published. Releases are built by [`.github/workflows/release.yml`](.github/workflows/release.yml),
> which restores the keystore from repository secrets; downloads and SHA256 checksums are on the
> [Releases](https://github.com/ASDW51/DanmuFloat/releases) page.

### Permissions

| Permission | Purpose |
| --- | --- |
| `INTERNET` | Fetch room info and open the danmaku WebSocket |
| `SYSTEM_ALERT_WINDOW` | Draw the overlay above other apps (declared by the plugin) |
| `FOREGROUND_SERVICE_SPECIAL_USE` | Keep the overlay foreground service alive (Android 14+) |
| `POST_NOTIFICATIONS` | Persistent notification for the foreground service (Android 13+) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Request the battery-optimization allowlist so the app is less likely to be killed in the background |

First launch guides you through granting the overlay, notification and battery-optimization permissions.

### Third-party and Credits

- [`flutter_screen_overlay`](third_party/flutter_screen_overlay): overlay foundation, MIT licensed. This project uses an inlined copy (`third_party/`) that fixes the upstream-message forwarding channel being overwritten; see `pubspec.yaml` and `third_party/flutter_screen_overlay/LICENSE`.
- Project reference: [renmu123/biliLive-tools](https://github.com/renmu123/biliLive-tools).

### License

Licensed under the [**PolyForm Noncommercial License 1.0.0**](LICENSE): noncommercial use only.
**This is not an OSI-approved open-source license.** Any commercial use (including but not limited
to selling, ad monetization, or commercial services) is prohibited. See [LICENSE](LICENSE).