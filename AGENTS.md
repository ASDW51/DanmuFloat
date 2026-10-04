# AGENTS.md — DanmuFloat 开发规范

本文件面向 AI 编码助手与协作者，约定本仓库的**代码规范、架构约束与验证门禁**。
分支、PR、发布等流程细节见 [CONTRIBUTING.md](CONTRIBUTING.md)，本文件不重复。

改动本仓库前请先通读本文件，并在提交前完成第 2 节的验证命令。

---

## 1. 项目定位与硬边界

DanmuFloat 是一个 Android 端的**纯弹幕查看器**，只做「把弹幕显示在悬浮窗里」这一件事。

- **不实现**账号登录、发弹幕、打赏等任何互动功能；此类需求一律拒绝，不要"顺手"加上。
- 仅允许**学习与研究**用途，**禁止任何商业用途**（见 [LICENSE](LICENSE)）。
- 首次启动必须勾选同意免责声明才能进入主界面；该合规入口不可绕过、不可弱化。
- 「清除所有本地数据」执行后，必须**关闭悬浮窗 → 断开连接 → 回到免责声明页**，三者缺一不可。

## 2. 环境与验证门禁

- Dart SDK `^3.10.9`，CI 使用 Flutter 3.38.10 stable，JDK 17。
- 提交前**必须**在本地跑通，且保持零告警、全绿：

```bash
flutter analyze   # 必须 No issues found
flutter test      # 必须全部通过
```

- CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）会对 push 到 `main` 和所有 PR 跑同样的命令，PR 需 CI 通过才可合并。
- **禁止执行 `dart format`**：不同 Dart 版本格式化行为差异大，会把未改动文件整体重排，导致 diff 无法 review。只手工调整本次改动涉及的代码。

## 3. 目录结构与分层

代码按职责分包，新增文件请归入对应目录，不要平铺在 `lib/` 根下：

| 目录 | 职责 |
| --- | --- |
| `lib/main.dart` | 应用入口、合规状态判定与首启分流 |
| `lib/app/` | 悬浮窗桥接与生命周期（建窗 / 关窗 / 会话） |
| `lib/connection/` | WebSocket 连接与消息收发 |
| `lib/danmu/` | 弹幕模型、协议解析、去重、滚动与展示 |
| `lib/room/` | 房间信息获取与 webRid 解析 |
| `lib/credential/` | 凭证管理与加密存储 |
| `lib/storage/` | 偏好设置与本地持久化 |
| `lib/compliance/` | 免责声明与合规 |
| `lib/system/` | 系统权限（悬浮窗 / 通知 / 电池优化） |
| `lib/ui/` | 页面：home / settings / overlay / danmu / disclaimer / onboarding / filter |
| `lib/net/`、`lib/sign/`、`lib/cache/` | 网络、签名、缓存等基础能力 |

- 跨包引用统一使用 `package:danmu_float/...` 绝对导入，不要用 `../` 相对路径。
- `third_party/` 是上游插件源码的内联副本，**Dart 代码保持上游原样**，不按本项目 lint 规则改写；确需改动 Android 侧时只做最小必要修改并保留说明注释。
- `test/` 与 `lib/` 结构同构，命名为 `<被测单元>_test.dart`。

## 4. Dart 代码风格

- 遵循 [analysis_options.yaml](analysis_options.yaml) 中的 `flutter_lints` 规则。
- **显式标注类型**：变量、参数、返回值都写清类型，不依赖类型推导（本仓库通行风格）。
- fire-and-forget 的 Future 用 `unawaited(...)` 包裹（`import 'dart:async'`），避免被 lint 拦下。
- 注释一律用**中文**，解释「**为什么**」而不是「是什么」；涉及需求条目的注明来源（如 `prd 4.11`、`F25`）。
- 常量与默认值集中在文件顶部，便于统一调整与复现。
- 捕获异常时用 `on Object catch (e)` 并给出可读的中文日志（`debugPrint`），不要吞掉异常静默失败。

## 5. 架构与关键约定

- **依赖注入**：与系统/网络/存储交互的外部依赖通过构造参数注入，并提供内存实现或假后端，保证可在纯 Dart 单测中替换；仅供测试使用的替换点用 `@visibleForTesting` 标注。
- **流（Stream）**：全局/静态单例持有的 `StreamController` 必须是 `broadcast`，且只订阅一次——非 broadcast 被多次 `listen` 会抛 `Bad state: Stream has already been listened to`。
- **时间戳单位统一为毫秒**。
- **悬浮窗尺寸单位**：建窗用的 `showOverlay` 收**物理像素**，改尺寸用的 `resizeOverlay` 收 **dp**，两者不可混用（混用会把窗口放大一个像素比而撑满屏幕）。尺寸下发前必须先收敛到当前屏幕范围内。
- **关闭悬浮窗的顺序**：先下发 `close` 指令，再清空各栏 webRid 并卸载栏位，最后补发一次聚合状态；否则插件只停前台服务、缓存引擎与 Dart widget 树不会销毁。
- **持久化**：悬浮窗位置、尺寸、吸附位置、透明度、字号、面板分页大小等设置需落盘，并在重开窗口时恢复。
- **权限**：悬浮窗、通知、电池优化白名单的申请入口必须在**任意时刻可达**（首启引导、设置页、首页 banner 三处均可重新进入申请流程），不得出现"跳过后再也找不到"的情况。
- **UI 文案**使用中文；用户可见提示（SnackBar、banner）要给出明确的可操作指引。

## 6. 测试规范

- 新增功能或修复缺陷时**补充对应测试用例**，与改动同 PR 提交。
- 单测不得依赖真机通道、网络或真实存储：通过注入的内存实现（假后端、临时目录、假 Preferences）来隔离。
- Widget 测试用 `WidgetTester` 驱动，必要时用 `scrollUntilVisible` 滚动到目标控件再断言。
- 测试用例描述用中文，说明「在什么场景下应发生什么」。

## 7. 提交与 PR

- 提交信息遵循 **Conventional Commits 中文格式**：`<类型>[(范围)][!]: <描述>`
  - 类型限小写英文：`build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test`
  - 描述用中文、结尾不加句号，header 整体 ≤ 100 字符
  - 破坏性变更在类型后加 `!`，并在正文说明变更点与迁移方式
- 分支名为 `<类型>/<简短描述>`，一律从上游最新 `main` 拉出。
- PR 聚焦单一目的，不混入无关重构；review 后追加 commit，**不对已 review 的分支 force push**。
- 发布 tag 必须严格等于 `v` + `pubspec.yaml` 的 version（去掉 `+n` 部分），版本号以 `pubspec.yaml` 为唯一来源。

## 8. 禁止事项

- 禁止提交任何凭证/签名文件：`android/key.properties`、`*.jks`、`*.base64.txt`（已被 `.gitignore` 忽略，**不要用 `git add -f` 绕过**）。
- 禁止执行 `dart format`。
- 禁止修改 `third_party/` 下的 Dart 源码风格。
- 禁止把无关改动（未要求的重构、格式化、文档）混入功能 PR。
- 禁止引入与项目定位冲突的互动功能（登录 / 发弹幕 / 打赏）。