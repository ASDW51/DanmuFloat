# 贡献指南

感谢你愿意为 DanmuFloat 做贡献。在提交 Issue 或 PR 之前，请先阅读本指南。

## 项目定位

DanmuFloat 是一个 Android 端的**纯弹幕查看器**：只做「把弹幕显示在悬浮窗里」这一件事。

- 不登录账号、不发送弹幕、不做任何互动；
- 仅允许学习与研究用途，**禁止任何商业用途**（见 [LICENSE](LICENSE)）。

如果你的需求涉及账号登录、发弹幕、打赏等互动功能，本项目不会实现。

## 环境要求

- Flutter（Dart SDK `^3.10.9`，CI 使用 Flutter 3.38.10 stable）
- Android SDK + JDK 17
- Android 真机或模拟器（悬浮窗、前台服务相关功能建议使用真机调试）

## 本地开发

```bash
git clone https://github.com/ASDW51/DanmuFloat.git
cd DanmuFloat
flutter pub get

flutter run                 # 连接设备后调试运行
flutter analyze             # 静态检查（提交前必须通过）
flutter test                # 单元测试（提交前必须通过）
```

> 没有仓库写权限的外部贡献者请先 Fork，clone 自己的分支而非上面这条地址，具体见「[分支与 PR 流程](#分支与-pr-流程)」。

如需验证 Release 构建，先按 [README](README.md) 的「签名说明」配置签名：

```powershell
./scripts/generate-keystore.ps1
```

## 提交前检查

提交 PR 前请在本地完成以下检查，CI 会对同样的命令做门禁：

```bash
flutter analyze
flutter test
```

- **先让单测通过，再提 PR**。新增功能或修复缺陷时，请尽量补充对应的测试用例。
- 提交前请确认没有把 `android/key.properties`、`*.jks`、`*.base64.txt` 等签名与凭证文件加入暂存区。

## 提交信息规范

本项目遵循 [Conventional Commits](https://www.conventionalcommits.org/)，格式如下：

```text
<类型>[(范围)][!]: <描述>
```

- **类型**必填，用小写英文，取值范围：`build` `chore` `ci` `docs` `feat` `fix` `perf` `refactor` `revert` `style` `test`
- **范围**可选，用括号标注模块，例如 `fix(overlay): 修复锁定后窗口撑满屏幕`
- **描述**必填，用中文，结尾不加句号
- 标题整体不超过 100 字符；需要补充上下文时，空一行后写正文，正文可用 `-` 列表
- 破坏性变更在类型后加 `!`，如 `feat!: ...`，并在正文说明变更点与迁移方式

示例：

```text
feat(overlay): 持久化悬浮窗位置并修复横屏吸附范围

- 拖动结束与吸附收敛后上报位置（dp）
- 贯通协议、存储与建窗链路
```

提交信息会被 [git-cliff](cliff.toml) 用于自动生成 Release Notes，因此请保持规范，否则该条提交不会出现在 changelog 中。

## 分支与 PR 流程

### 一、外部贡献者（没有仓库写权限）

先在网页上 Fork 本仓库，然后：

```bash
# 1. clone 你自己的 fork
git clone https://github.com/<你的用户名>/DanmuFloat.git
cd DanmuFloat

# 2. 把上游仓库加为第二个 remote，方便后续同步
git remote add upstream https://github.com/ASDW51/DanmuFloat.git

# 3. 从上游最新的 main 拉出特性分支（不要直接在自己 fork 的 main 上改）
git fetch upstream
git checkout -b fix/overlay-drag upstream/main

# 4. 开发并提交（规范见下文「提交前检查」与「提交信息规范」）
git commit -m "fix(overlay): 修复锁定后窗口撑满屏幕"

# 5. 推送到自己的 fork
git push origin fix/overlay-drag
```

推送后在网页开 PR，base 选择 `ASDW51/DanmuFloat` 的 `main` 分支，并按 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md) 填写内容。

### 二、协作者（有仓库写权限）

不需要 Fork，直接在仓库内拉分支：

```bash
git fetch origin
git checkout -b fix/overlay-drag origin/main

# ... 开发与提交 ...

git push origin fix/overlay-drag
```

### 通用约定

- 分支名建议 `<类型>/<简短描述>`，例如 `fix/overlay-drag`。
- 分支一律从上游最新的 `main` 拉出，保证 PR 里只有你自己的改动。
- 保持 PR 聚焦单一目的，避免把无关的重构与功能改动混在同一个 PR 中。
- 等待 CI（`flutter analyze` + `flutter test`）通过并完成 review。review 后如需修改，请**追加提交**而不是 force push，否则历史评论会失去上下文。

## 代码风格

- 遵循 `analysis_options.yaml` 中的 `flutter_lints` 规则。
- **不要执行 `dart format`**：不同 Dart 版本的格式化器行为差异较大，会把未改动的文件整体重排，导致 diff 无法 review。请只手工调整本次改动涉及的代码。
- 涉及悬浮窗尺寸、协议字段等改动时，请一并更新相关注释与文档。

## 许可

向本项目提交贡献即表示你同意该贡献以本仓库的 [PolyForm Noncommercial License 1.0.0](LICENSE) 授权分发，且不得用于任何商业用途。