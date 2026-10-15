# DanmuFloat 产品自迭代 TODO

> 目标：按 `docs/ci-pr-workflow.md` 流程驱动产品自迭代，持续提升应用用户体验。
> 决策来源：产品经理（PM）子代理审查；实现与验证：Lead。
> 门禁：本机无 Flutter 环境，`flutter analyze` + `flutter test` 全部由远程 CI（GitHub Actions）兜底，PR 绿了才合入 `main`。
> 约束：不安装任何本地环境；遵守 AGENTS.md 硬边界（纯弹幕查看器、免责声明不可绕过、清除数据三步走、禁止商业用途）。

## 当前状态（截至本次更新）

| 项 | 状态 | 位置 |
| --- | --- | --- |
| 迭代基线 | 已就位 | `main` @ `75bf838`（含 PM-002） |
| PM-001 | ✅ 已合入 | PR #7 → `main` |
| PM-002 | ✅ 已合入 | PR #8 → `main` |
| PM-003 ~ PM-006 | ⬜ 未开始 | — |

已落地的测试辅助（供后续复用）：
- `pushOverlayStatusForTest()` — `lib/app/overlay_launcher.dart`，直接向状态广播流注入上报，避免模拟插件原生消息通道的编解码。
- `setOverlayShownForTest()` — `lib/app/overlay_launcher.dart`，置位「已建窗」全局状态。
- `HomePage.directoryResolver` / `HomePage.credentialStore` — 注入点，让 Widget 测试用临时目录 + 内存凭证后端，绕开 `path_provider` / `flutter_secure_storage` 原生通道。
- `test/home_page_test.dart` 的 `_pumpUntil` / `_mockPathProvider` / 双通道 mock（PM-002 攻坚沉淀，见 PM-002 的测试攻坚记录）。

---

## 待办清单

### ✅ PM-001　首页与弹幕页悬浮窗开关状态收敛（P0 · 已完成）

- 现状：从弹幕页开单栏悬浮窗后回首页，或进程重启后前台服务仍带窗存活时，首页**没有「关闭悬浮窗」入口**（`_overlayVisible` 只认本页多栏开窗动作）。
- 已实现：
  - 首页 `initState` / 回前台时按 `isOverlayActive()` 只读探测收敛开关状态
  - 悬浮窗上报含活跃栏位绑定时补置「已开启」
  - 弹幕页单栏窗随 config 下发候选房间（新增 `_loadRoomOptions()`），栏标题可点、加栏不再误报
  - 弹幕页回前台时按 `isOverlayActive` 纠错按钮状态
  - 新增 `isOverlayActive` 只读探测（与 `verifyOverlayPermission` 的拆除语义区分）
- 测试：`test/home_page_test.dart` 4 个用例（冷启动 / 未开启回归 / 上报活跃 / 权限撤销回归）
- 交付：PR #7 已合并 `main`

### ✅ PM-002　首页移除主播时同步卸载悬浮窗对应栏位（P0 · 已完成）

- 现状：`_remove()` 只调 `_syncOverlayRooms()` 推候选列表，而 `shareOverlayRooms` 在悬浮窗侧**只更新可切换候选、不卸载已绑定栏位** → 用户以为删掉了，那一栏还在拉弹幕、占连接。
- 已实现（`lib/ui/home_page.dart`）：
  - 新增 `_unbindRoomFromOverlay()`：被移除的主播正绑在某栏时，按剔除后的新绑定走 `resizeOverlay` 重排（悬浮窗重建栏位 → dispose 对应栏 → 停会话）
  - 是最后一栏时走 `_closeOverlay()` 关窗，避免下发空绑定的 config 留下空窗
  - 新绑定随 `_prefsStore.save` 落盘
- 测试：`test/home_page_test.dart` 新增 2 个用例（移除已绑定主播走重排且落盘不含它；移除最后一栏走关窗）
- 交付：PR #8 已合并 `main`
- 测试攻坚记录（后续写 widget 测试直接复用）：
  - 真实文件 I/O 在 testWidgets 的 FakeAsync 里永远等不到回包，读 / 写都要经 `tester.runAsync` 排空；固定 sleep 一次不可靠，用「runAsync 排空 50ms + pump」轮询到条件成立（`_pumpUntil`）
  - 插件是**两条** MethodChannel：控制通道 `x-slayer/overlay_channel`（isActive / checkPermission / closeOverlay），尺寸通道 `x-slayer/overlay`（resizeOverlay）——都要 mock，断言别串通道
  - `_loadFilter()` 走默认构造的 FilterStore，需给 `plugins.flutter.io/path_provider` 挂临时目录 mock，否则 runAsync 时抛 MissingPluginException
  - 底部菜单 / 对话框入场动画约 200ms，pump 100ms 时 sheet 还在视口外滑入途中，tap 打不中（只有 warning 不算失败，后续 tap 才炸）；每个动画推满 500ms 再 tap
  - 等待信号要选「最终效果」：列表项消失（setState 先于落盘）、落盘不含旧值（writeAsString 先截断再写，空读要继续等）都不行，要等插件调用 / 期望值真正出现

### ⬜ PM-003　悬浮窗内加栏位补高性能确认与上限（P1）

- 现状：首页多栏 `> maxStandardPaneCount`（4 栏）会强制确认高性能模式，但悬浮窗内「添加栏位 / 栏位管理」**无限加栏、无性能提醒**，与首页体验割裂；低端机卡顿发热却无提示。
- 期望：
  1. 悬浮窗内任意入口使栏数 > 4 时弹出与首页一致的强制确认（无「不再提示」）
  2. 设软硬上限（如 9 栏），超过不让再加并提示「已达上限」
- 建议落点：`lib/ui/overlay_page.dart` 的 `_addPane` / `_managePanes`；复用首页确认口径；新增常量置顶
- 测试：注入栏位计数，验证第 5 栏触发确认、第 10 栏被拒

### ⬜ PM-004　未开播栏位周期自动复检并提示重连中（P1）

- 现状：`LiveDanmuSession.start()` 在 `!roomInfo.living` 时直接 `stage = offline` 且**不重试**；悬浮窗挂机看多个房间时，未开播的房间「永远停在未开播」，主播开播后不会自动恢复。这是核心场景断裂。
- 期望：
  1. `offline` 态按固定间隔（如 30–45s）周期性复检房间信息，开播后自动转入正常弹幕流
  2. 栏目标识行显示「未开播 · 自动重连中」，让用户知道它没死
  3. 重试次数上限收敛（避免无限轮询）；达上限后给出**可点的手动重试出口**
  4. `stop()` 必须取消定时器，不得残留后台请求
- 建议落点：集中在 `lib/app/live_danmu_session.dart`；策略抽成纯函数便于单测；UI 侧改 `overlay_page.dart` 的 `_stageText`
- 测试：注入假 `RoomInfoClient`（先 false 后 true）验证自动转 live；验证 `stop()` 后不再重试
- ⚠️ 注意：此前有非受控实现在此处引入过定时器，导致 Widget 测试 10 分钟超时并被撤回。本次实现须确保定时器可取消、测试可控。

### ⬜ PM-005　添加主播短链解析加超时兜底（P2）

- 现状：`AddRoomDialog._submit` 直接 `await _resolver.resolve(input)`，短链需联网跟随跳转，**没有任何超时**；弱网/被墙时按钮一直转圈、输入被禁用，用户只能退出重进。与「解析不出来不拦、按原文保存」的设计哲学相悖。
- 期望：联网解析超过阈值（如 8s）即放弃，按原始输入保存并提示「未能联网解析，已按原文添加」；解析中取消按钮应可用
- 建议落点：`lib/room/room_link_parser.dart` 的 `resolve` 加 `.timeout()`；阈值常量置顶
- 测试：注入永不返回的假 transport，验证超时后返回 null 而非挂起

### ⬜ PM-006　首启引导手动步骤改中性视觉（P2）

- 现状：引导第 4 步「自启动权限」写死 `done: false, manual: true`，图标恒为橙色「未完成」警示色；但该权限各厂商 ROM 入口不一、App 永远无法自动判定，会让用户误以为「配置没做完、有问题」。
- 期望：手动类步骤用中性视觉（蓝色 `info_outline`），subtitle 明确「需手动在系统设置开启，可不处理」；消除「必须现在做完」的暗示
- 建议落点：`lib/ui/onboarding_page.dart` 的 `_StepTile`
- 测试：断言 manual 步骤渲染为中性图标、非橙色警示

---

## 明确不做（PM 已否决，防止后续「顺手加上」）

- 账号登录 / 发弹幕 / 打赏 / 评论等任何互动功能（项目硬边界）
- 云同步 / 多设备账号体系（导出导入备份已满足换机）
- 弹幕 AI 总结 / 情感分析 / 关键词趋势（超出「查看」范畴，涉隐私与合规）
- 自动推荐热门口直播间 / 内容广场（涉内容分发与版权风险）
- 悬浮窗内再做一套屏蔽词可视化编辑器（主路径已覆盖，属重复）
- 跨设备记忆窗口位置 / 云备份布局（本地已落盘，云同步违反隐私基调）
- 付费皮肤 / 主题商城 / 自定义背景图（禁止商业用途）
- 截图 / 录屏 / 弹幕叠游戏画面（权限与隐私复杂，超出「查看」语义）
- 任何「不再提示」类记忆开关（AGENTS.md 要求高性能模式强制确认）
- 给 `overlay_page.dart` 做顺手重构（AGENTS.md 要求 PR 单一目的）

---

## 执行流程（每轮）

```bash
source ~/gh.sh && gh auth setup-git

git checkout main && git pull --ff-only
git checkout -b <类型>/<简短描述>      # 如 fix/xxx、feat/xxx

# 实现 + 补单测
git add <files> && git commit -m "<类型>: <中文描述>"

git push -u origin <分支>
gh pr create --title "..." --body "..."
gh pr checks --watch                    # analyze-and-test 必须绿
gh pr merge --merge --delete-branch     # 绿了才合
git checkout main && git pull --ff-only
```

## 纪律提醒

- 每个 PR **单一目的**，不混入无关重构；分支名 `<类型>/<简短描述>`；提交信息 Conventional Commits 中文格式。
- 新增/修复**必须配单测**，与改动同 PR；单测用注入假实现（临时目录 / 内存后端 / 假 transport），不依赖网络、真机通道。
- 禁止 `dart format`；显式类型标注；中文注释解释「为什么」；常量集中文件顶部；fire-and-forget 用 `unawaited`。
- Widget 测试已知坑：`pumpAndSettle` 会因首页持续的 post-frame 回调永不空闲而超时，改用有限 `pump(Duration)`；`shareData` 的 `send` 需挂应答 handler。
- 悬浮窗尺寸单位：`showOverlay` 收物理像素，`resizeOverlay` 收 dp，不可混用。
