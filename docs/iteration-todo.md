# DanmuFloat 产品自迭代 TODO

> 目标：按 `docs/ci-pr-workflow.md` 流程驱动产品自迭代，持续提升应用用户体验。
> 决策来源：产品经理（PM）子代理审查；实现与验证：Lead。
> 门禁：本机无 Flutter 环境，`flutter analyze` + `flutter test` 全部由远程 CI（GitHub Actions）兜底，PR 绿了才合入 `main`。
> 约束：不安装任何本地环境；遵守 AGENTS.md 硬边界（纯弹幕查看器、免责声明不可绕过、清除数据三步走、禁止商业用途）。

## 当前状态（截至本次更新）

| 项 | 状态 | 位置 |
| --- | --- | --- |
| 迭代基线 | 已就位 | `main` @ e91eeac |
| CR-01 代码审查修复 | ✅ 已合入 | PR #11 / PR #12 → `main` |
| PM-001 | ✅ 已合入 | PR #7 → `main` |
| PM-002 | ✅ 已合入 | PR #8 → `main` |
| UX-01 未开播自动复检 | ✅ 已合入 | PR #14 → `main` |
| UX-02 手动重试入口 | ✅ 已合入 | PR #16 → `main` |
| UX-03 短链解析超时 + 可取消 | ✅ 已合入 | PR #15 → `main` |
| UX-04 刷新全部 + 陈旧可见 | ✅ 已合入 | PR #17 → `main` |
| UX-05 加栏确认 + 硬上限 | 🚧 进行中 | 分支 `feat/pane-add-guard`（首页侧已完成；悬浮窗侧等 UX-07 / UX-08 合入后再动同一文件） |
| UX-06 引导手动步骤视觉/文案 | ⬜ 未开始 | 见待办清单 |
| UX-07 ~ UX-11 | ⬜ 未开始 | 见待办清单（PM 第二轮新增；UX-07 为 P0） |

> 待办清单已按 PM 子代理 2026-10-15 的第一版审查**整版重写**：旧编号 PM-003 ~ PM-006 作废（保留项重新编号为 UX-01 ~ UX-06；其中旧 PM-006 的问题描述与现状不符，已改写为 UX-06）。

### PM 对当前体验的总体判断

主路径（加主播 → 开窗 → 看弹幕 → 落盘还原）已跑通，但**「连不上之后怎么办」这一整条链路是断的**：未开播的栏位永久停在「未开播」，重连次数耗尽后悬浮窗里没有任何重试入口，用户唯一出路是关窗重开——而重开又会重建全部栏位、把其它正常栏位的连接一并断掉，与「多直播间挂机看弹幕」的核心场景直接冲突。

其次是**信息不可信**：首页开播状态只在手动点行内「刷新」时更新，没有批量刷新、没有时间戳，挂后台几小时后看到的全是旧值；悬浮窗在栏目标识被关掉时连状态灯都消失，出错毫无迹象。

第三是**添加主播可能挂死**：短链解析没有超时，且解析期间「取消」被禁用，弱网下用户只能杀掉 App。

合规硬边界（免责声明不可绕过、清除数据三步走、纯查看器）已逐条复核，当前实现**没有违规**，本轮不动它们。

已落地的测试辅助（供后续复用）：
- `pushOverlayStatusForTest()` — `lib/app/overlay_launcher.dart`，直接向状态广播流注入上报，避免模拟插件原生消息通道的编解码。
- `setOverlayShownForTest()` — `lib/app/overlay_launcher.dart`，置位「已建窗」全局状态。
- `HomePage.directoryResolver` / `HomePage.credentialStore` — 注入点，让 Widget 测试用临时目录 + 内存凭证后端，绕开 `path_provider` / `flutter_secure_storage` 原生通道。
- `test/home_page_test.dart` 的 `_pumpUntil` / `_mockPathProvider` / 双通道 mock（PM-002 攻坚沉淀，见文末 PM-002 记录）。
- `test/home_page_test.dart` 的 `_sentMessages` — 消息通道 `x-slayer/overlay_messenger` 的载荷记录器（CR-01 沉淀），断言主 App 下发内容用它，而不是断言插件 MethodChannel。
- `TestDefaultBinaryMessenger.handlePlatformMessage` — 向插件「原生侧」注入一条消息（CR-01 沉淀），用于验证主 App 收到插件上报后的行为。

---

## 待办清单（PM 第一版 + 第二轮新增，按当前优先级排序）

> 第二轮（2026-10-15 复核 UX-01 ~ UX-04 落地代码后）新增 UX-07 ~ UX-11，并把它们插到 UX-05 / UX-06 之前：UX-07 是 UX-02 在多栏场景下的**回归**，UX-08 让重试入口在关掉栏目标识行后仍然可达。PM 建议顺序 **UX-07 → UX-08 → UX-09 → UX-10 → UX-05 → UX-06**，UX-11（批量刷新只落盘一次）视 PR 预算顺延。

### ✅ UX-01　未开播栏位周期自动复检，栏位显示「未开播 · 自动复检中」（P0 · 已合入 PR #14）

- **现状与问题**：`LiveDanmuSession.start()` 在 `!roomInfo.living` 时直接 `_setStage(LiveSessionStage.offline); return;`（`lib/app/live_danmu_session.dart:158-161`），**此后不再有任何重试**；`_OverlayPaneState._start()` 只在 `initState` 调一次 `session.start()`（`lib/ui/overlay_page.dart:1449-1460`、`1593-1619`），`DanmuPage._connect()` 同理（`lib/ui/danmu_page.dart:208-235`）。栏位文案写死「未开播」（`overlay_page.dart:1833`）。用户真机结果：挂机看 3 个房间，其中 1 个当时未开播，主播 10 分钟后开播，那一栏**永远不会有弹幕**，只能用户自己发现并手动关窗重开。
- **期望行为**：
  1. `offline` 态按固定间隔复检房间信息（建议 30s，常量置顶 `lib/app/live_danmu_session.dart`），开播后自动转入正常弹幕流，无需用户操作；
  2. 复检次数收敛（建议上限 20 次，约 10 分钟），达上限停在 `offline`，但**保留手动重试出口**（与 UX-02 复用同一入口）；
  3. 复检中栏位文案为「未开播 · 自动复检中」，让用户知道它没死；
  4. `stop()` 必须取消定时器，且每个 `await` 后都要重查 `_stopped`，不得在会话结束后残留请求或定时器。
- **验收标准**：注入假 `RoomInfoClient`（先返回未开播、第 2 次返回 `living: true`），推进假时间后 `stage` 变 `live` 且 socket 工厂被调用；复检期间 `stage` 保持 `offline`；`stop()` 后推进同等时间，`RoomInfoClient` 调用次数不再增加；达上限后不再发请求且 `stage` 仍为 `offline`。
- **建议测试**：扩展 `test/live_danmu_session_test.dart`（已有 `FakeRoomInfoClient` / `_tick()` 基建，第 176 行「未开播时不建立弹幕连接」用例须保留通过）。**定时器必须可注入**（构造参数给 `retryInterval`，默认 30s），测试用短间隔或 `fakeAsync` 推进，禁止依赖真实等待——此前非受控定时器曾导致 Widget 测试 10 分钟超时被撤回。
- **风险/依赖**：无新依赖、无权限变更，完全在合规边界内。风险是定时器泄漏与 `start()` 重入（`start()` 目前无重入保护，重试期间若再被调用会覆盖 `_socket` / `_eventSubscription` 造成连接泄漏，实现时需一并加保护）。

### ✅ UX-02　悬浮窗 / 弹幕页为「异常」栏位提供可点的手动重试入口（P0 · 已合入 PR #16）

- **现状与问题**：`DanmuSocketClient` 重连 10 次耗尽后进入 `failed`，`LiveDanmuSession._onConnectionState` 置 `_fail('重连次数达上限，已停止连接')`（`live_danmu_session.dart:230-241`），栏位只显示「异常」（`overlay_page.dart:1834`），错误正文 `_error` **仅在列表为空时**才显示（`overlay_page.dart:1842-1855`），一旦该栏已有历史弹幕，用户连原因都看不到。**窗内没有任何重试按钮**：唯一出路是悬浮球菜单「关闭悬浮窗」再重开，这会重建全部栏位、把其它正常栏位的连接一并断掉。App 内弹幕页同样只能在状态栏看到红字（`danmu_page.dart:561-564`），无重试。
- **期望行为**：
  1. 栏位处于 `error`（含 `socketError != null`）时，标题行状态文案改为可点，点击即重建本栏会话（重新走「解析房间 → 签名 → 连接」），不需要关窗；
  2. 状态文案用「连接失败 · 点此重试」这类**可操作指引**，而非裸「异常」；
  3. App 内弹幕页状态栏的「异常」同样给出「重试」按钮；
  4. 顺带修一个连带缺陷：`_rebindPane` 在 `_webRids[index] == webRid` 时直接 `return`（`overlay_page.dart:427-429`），导致连接失败后**在栏位管理里重选同一个主播不会触发任何重连**，用户以为点了有用。
- **验收标准**：注入假会话 / 假 socket 使栏位进入 `failed`，断言标题行出现「重试」类可点文案；点击后 socket 工厂被再次调用且 `stage` 回到 `resolvingRoom`；失败态下在栏位管理中重选同一 webRid 也能触发重建。
- **建议测试**：`test/overlay_page_test.dart`（现 60 行，可扩展）+ `test/live_danmu_session_test.dart` 补 `restart()` 语义用例。Widget 测试注意：悬浮窗内弹窗有入场动画，需 `pump` 足量再 tap；不要用 `pumpAndSettle`。
- **风险/依赖**：与 UX-01 共用「重建会话」能力，但范围独立：UX-01 改会话内部定时逻辑，UX-02 只加 UI 入口与 `restart()`。**建议先合 UX-01 再做本条**，避免同一文件两处并发改动。

### ✅ UX-03　添加主播：短链解析加超时兜底，「取消」在解析期间保持可用（P0 · 已合入 PR #15）

- **现状与问题**：`AddRoomDialog._submit` 直接 `await _resolver.resolve(input)`（`lib/ui/add_room_dialog.dart:73`），而 `RoomLinkResolver.resolve` 的 `_transport.get(...)` 没有任何超时（`lib/room/room_link_parser.dart:62-71`），`IoHttpTransport` 也未设 `HttpClient.connectionTimeout`（`lib/net/http_transport.dart:26-44`）。弱网 / DNS 挂起时该 Future 可能长期不返回；同时解析期间「取消」按钮 `onPressed: _resolving ? null : ...`（`add_room_dialog.dart:138`）、两个输入框也 `enabled: !_resolving`（第 105、118 行）——用户被锁在一个只会转圈的表单里，只能杀进程。这与「解析不出来不拦、按原文保存」的设计哲学（同文件第 5-6 行注释）相悖。
- **期望行为**：
  1. `resolve` 增加超时阈值（建议 8s，常量置顶 `room_link_parser.dart`），超时按解析失败处理返回 `null`，不向上抛；
  2. 超时 / 解析失败时**按原始输入保存**，并在对话框关闭后由首页 SnackBar 明确提示「未能联网解析，已按原文添加」；
  3. 解析期间「取消」始终可点，点击立即关闭对话框（不等待网络）；
  4. 解析期间「添加」保持禁用防重复提交（现状正确，勿改）。
- **验收标准**：注入永不返回的假 transport，`resolve` 在阈值后返回 `null` 而非挂起；Widget 测试断言：解析进行中「取消」按钮 `onPressed != null`、点击后对话框关闭且回调结果为 `null`；超时场景下仍以原文添加并出现提示文案。
- **建议测试**：`test/room_link_parser_test.dart`（已有 `FakeTransport`，第 103 行「网络异常按解析失败处理」用例可对齐）+ `test/add_room_dialog_test.dart`（已有 `openDialog` 辅助）。为避免测试真等 8s，超时值需可注入（构造参数或可覆盖常量）。
- **风险/依赖**：无。注意**不要**给 `HttpTransport` 引入新依赖或改接口签名，只在 `resolve` 层用 `Future.timeout`；若走 `HttpClient.connectionTimeout` 会牵动 `IoHttpTransport` 构造，影响面更大，不推荐。

### ✅ UX-04　首页支持「刷新全部主播」并显式暴露状态陈旧（P1 · 已合入 PR #17）

- **现状与问题**：`_buildRoomTile` 每行一个「刷新」按钮（`lib/ui/home_page.dart:965-974`），`_refreshRoom` 一次只处理一个 webRid（`home_page.dart:603-640`）；`didChangeAppLifecycleState` 回前台只做悬浮窗权限 / 开关收敛，**不刷新任何房间状态**（`home_page.dart:177-186`）；`_livingLabel` 的「未刷新」仅在 `living == null` 时出现（`home_page.dart:984-988`），而 `living` 一旦刷过一次就永久保留。用户真机结果：列表里 10 个主播，App 挂后台一夜后回前台，全部显示旧的开播状态，要逐行点 10 次「刷新」才能看准。
- **期望行为**：
  1. AppBar 增加「刷新全部」入口：串行（建议同时不超过 2 个）刷新全部主播，期间按钮禁用并显示进度（如「刷新中 3/10」），完成后 SnackBar 汇总「已刷新 10 个主播」；
  2. 单个失败不中断整批，失败项在汇总里计数（如「2 个失败」），失败原因仍走现有行内 SnackBar 口径；
  3. 主播行在状态后附带最近一次成功刷新的相对时间（如「直播中 · 3 分钟前」），让陈旧可见；
  4. 复用现有 `_refreshing` 集合与 `_refreshRoom` 的落盘逻辑，不新增第二套刷新实现。
- **验收标准**：注入假 `RoomInfoClient`，断言点「刷新全部」后每个 webRid 各被请求一次、刷新期间按钮禁用、结束后 `_rooms` 全部落盘且状态文案含相对时间；其中一个房间抛错时其余仍被刷新且汇总提示含失败数。
- **建议测试**：`test/home_page_test.dart`（已有 `_pumpUntil` / 双通道 mock / 注入目录等基建）。相对时间文案用可注入时钟或断言「含『前』字」，避免时间抖动导致 flaky。
- **风险/依赖**：需要给 `ManagedRoom` 增加「最近刷新时间」字段并落盘（`lib/room/managed_room.dart`），会**改动 `rooms.json` 结构**——必须保持向后兼容（`tryParse` 缺字段按 null 处理，旧备份可读）。这是本清单里唯一动持久化结构的一条；若认为风险偏高，可先只做「刷新全部 + 进度」，把相对时间拆到后续条目。

### 🚧 UX-05　悬浮窗内加栏位补高性能确认与硬上限（P2 · 进行中）

- **进展**：首页侧已完成（PR 待开）——`overlay_bridge.dart` 新增 `maxPaneCount = 9` 与纯判定 `canAddPane` / `needsHighPerformanceConfirm`，两处入口共用新建的 `lib/ui/high_performance_dialog.dart`，首页多选在勾满 9 栏后锁定未勾选行并给出上限提示。
- **待做**：悬浮窗内「添加栏位」（`_addPane`）与「栏位管理」里的加栏在栏数将 > 4 时弹同一确认、栏数达 9 时两个入口禁用并提示「已达上限 9 栏」、栏位管理弹窗说明文案补上当前上限。
- **为什么排在 UX-07 / UX-08 之后**：三者都改 `lib/ui/overlay_page.dart`（标题行 / 悬浮球菜单），必须串行合入；UX-07 是 P0 回归，先修。

- **现状与问题**：首页在栏数 > `maxStandardPaneCount`（4）时会强制确认高性能模式（`lib/ui/home_page.dart:688-691`、`744-767`，常量见 `lib/app/overlay_bridge.dart:197`），但悬浮窗内「添加栏位」按钮（`overlay_page.dart:733` → `_addPane` 1114-1138）与「栏位管理」里的「添加栏位」（`overlay_page.dart:2274-2284` → `_add` 2194-2200）**既无确认也无上限**。每一栏都是一条独立 WebSocket + 独立签名 / 解码链路，栏数只受本地主播数量限制，低端机加满后卡顿发热却没有任何提示，两处体验割裂。
- **期望行为**：
  1. 悬浮窗内任意入口使栏数将 > 4 时，弹出与首页一致的强制确认（标题「高性能模式」、文案口径对齐，**不提供「不再提示」**——AGENTS.md §5 要求强制确认）；
  2. 设硬上限（建议 9 栏，与 `recommendedOverlaySize` 的 `<= 9` 档对齐，常量置顶 `overlay_bridge.dart`），达到上限后两个入口均禁用并提示「已达上限 9 栏」；
  3. 栏位管理弹窗的说明文案同步给出当前上限。
- **验收标准**：栏数 4 → 加第 5 栏时弹确认；取消则栏数不变，确认则 +1；栏数 9 时「添加栏位」不可用且提示上限；确认弹窗内不存在任何「不再提示」控件。
- **建议测试**：`test/overlay_page_test.dart` 扩展（候选房间需经 `OverlayRooms` / `OverlayConfig` 消息下发，可参考 `test/overlay_bridge_test.dart` 的构造方式）；上限常量的边界（9 / 10）用纯函数或 `OverlayGrid` 级别用例覆盖更稳。
- **风险/依赖**：确认弹窗是异步 `await showDialog`，`_addPane` 的 `setState` 需在 `mounted` 检查之后；注意与 UX-02 同时改 `overlay_page.dart` 时的合并顺序。

### ⬜ UX-06　首启引导手动类步骤：视觉区分度 + 明确「可不处理」（P2）

- **现状与问题**：引导第 4 步写死 `done: false, manual: true`（`lib/ui/onboarding_page.dart:166-174`），`_StepTile` 对 `manual` 使用 `Icons.info_outline` + `Colors.blueGrey`（`onboarding_page.dart:249-251`）——**图标本身已是中性色，不是橙色警示**（旧 PM-006 的描述与当前代码不符）。但仍有真实问题：`manual` 分支与「已完成」的绿色 `check_circle` 视觉差异小，且 subtitle 只写「厂商设置项各不相同，需在系统设置里手动开启」，**没有说明「可以不做」**；在「按顺序完成以下准备」的强暗示下，用户会以为不点完这步就不算配置完成。
- **期望行为**：
  1. 手动类步骤视觉明确区别于「待完成」（保留中性色，图标建议 `Icons.tune` 或 `Icons.open_in_new` 之类「去设置」语义，不使用对勾）；
  2. subtitle 补一句「可不处理：不开启仅影响后台存活率，不影响弹幕查看」；
  3. 步骤标题区的引导语从「按顺序完成以下准备」改为不暗示「必须完成」的表述（如「以下准备可按需完成，随时可跳过」），与页面已有的「全部步骤都可跳过」口径一致。
- **验收标准**：manual 步骤不渲染为绿色对勾；subtitle 含「可不处理」；页面顶部引导语不含「完成以下准备」这类必须性措辞。
- **建议测试**：`test/onboarding_page_test.dart` 断言 manual 步骤的图标与文案，用 `find.byIcon` / `find.textContaining`。
- **风险/依赖**：纯文案与视觉，零风险。注意 AGENTS.md 要求「权限申请入口任意时刻可达」——本页是设置页「权限申请引导」的落地页，**不得删除任何步骤或按钮**，只调视觉与文案。

### ⬜ UX-07　多栏 / 窄窗下栏目标识行被重试入口撑溢出，重试反而点不到（P0）

- **现状与问题**：`_buildTitleBar` 是单行 `Row`，固定宽度子项已有状态点 / 换绑箭头 / 焦点 / 暂停（`lib/ui/overlay_page.dart` 标题栏区域），UX-02 又插入 `Icons.refresh` + 「点此重试」文案。5 栏起 `OverlayGrid` 变 3 列，`defaultOverlayWidth = 400` 时单栏仅约 133dp，扣掉栏内边距只剩约 110~120dp，而固定子项 + 重试按钮最小宽度已超出；`_stageText` 在 error / offline 态又更长。真机结果：栏目标识行右侧出现黄黑溢出条，**重试按钮被挤出可视区**——救活入口在最需要它的多栏场景下点不到。
- **期望行为**：
  1. 窄宽度下不溢出：阶段文案降级为短形态（error → 「失败」、offline 停止复检 → 「未开播」、复检中 → 「复检中…」），完整文案（含「点此重试」）只进 Tooltip 与无障碍标签；
  2. 重试入口改为图标按钮，或整体收进悬浮球菜单（与 UX-08 合并做更省事）；
  3. 换绑箭头 / 焦点 / 暂停在窄窗下可折叠，但**不得删掉任何功能**。
- **验收标准**：3 栏、窗口宽 400dp（单栏 ≈133dp）下渲染失败态栏位，`tester.takeException()` 为 null（无 `RenderFlex overflowed`）；重试入口 `find` 命中且 `tap` 可触发重建；单栏宽窗下文案保持完整。
- **建议测试**：新开独立文件（`OverlayPage` 的静态单订阅流每文件只能 mount 一次），用 `tester.view.physicalSize` 固定 3 栏窄窗尺寸断言无溢出且重试可点。
- **风险/依赖**：纯布局，零依赖。**溢出条只在 debug 构建可见，`flutter analyze` 不会报错**，必须靠这条 Widget 断言把回归锁住。与 UX-08 都改标题行 / 悬浮球菜单，**合并为一个 PR**（PM 决策 1）。

### ⬜ UX-08　隐藏栏目标识行后失败栏位既看不见也点不到；重试后失败原因还会消失（P1）

- **现状与问题**：
  1. 栏目标识行由 `_prefs.showTitleBar` 控制（设置页有开关），关掉后阶段文案、状态点、**重试入口**全部不渲染；窗内唯一入口悬浮球菜单里没有任何栏位连接状态或重试入口，用户只看到「有几栏一直没弹幕」，分不清未开播 / 连接失败 / 已静音。
  2. `_retry()` 先 `setState(() => _error = null)` 再 `restart()`，而 `_error` 只在 `_report()` 里由 `session.errorMessage` 回填；重试后若停在 `offline`（不再是 error），`_error` 永远为 null，空列表只剩「暂无弹幕」，用户失去唯一可查的原因。
- **期望行为**：
  1. 悬浮球菜单新增「栏位状态」区块：逐栏一行「第 N 栏 · 主播名 · 状态」，**仅对 `shouldOfferRetry(...)` 为真的栏位**显示「重试」按钮（复用既有判定，不新增口径）；栏位 ≤ 1 时可省略，避免单栏菜单变长；
  2. 该区块与 `showTitleBar` 无关，标识行关掉后仍是统一兜底入口；
  3. `_retry()` 不再无条件清空 `_error`：保留到下一次成功建连或用户主动清空。
- **验收标准**：`showTitleBar: false` + 一栏失败态下，菜单里能看到该栏状态与可点「重试」，点击触发重建；`showTitleBar: true` 时行为不变（无重复入口）；重试后再次失败，失败原因在空态文案里仍可见。
- **建议测试**：独立文件单次 mount；断言菜单中失败栏位「重试」存在、点击后 `restart` 生效（假 `RoomInfoClient` 计数）、二次失败后 `_error` 仍出现在空态文案。
- **风险/依赖**：`_reports` 里现成的逐栏 `_Report` 直接复用，无需新增状态。与 UX-07 严格串行 / 同 PR。

### ⬜ UX-09　弹幕页把内部枚举名直接显示给用户，失败原因不进诊断信息（P1）

- **现状与问题**：弹幕页状态栏渲染 `'连接: ${_session!.connectionState.name}'`，`DanmuConnectionState` 的 `.name` 是英文枚举名（`idle / connecting / connected / reconnecting / failed / closed`），真机出现「连接: reconnecting」这类内部术语，同行其它元素已是中文；「复制诊断信息」只含样式 / 凭证 / 悬浮窗开关，**不含连接状态与失败原因**，悬浮窗侧诊断完全缺失，用户报障时维护者无法区分签名降级 / 接口风控 / WS 握手被拒。
- **期望行为**：
  1. 状态栏把 `connectionState` 映射为中文短词（连接中 / 已连接 / 重连中 / 已停止 / 已关闭），新增纯函数便于单测，枚举 `.name` 不再出现在任何用户可见文案；
  2. 「复制诊断信息」补充当前会话阶段、`socketError`、是否签名降级、悬浮窗逐栏状态摘要——**仍不含任何凭证明文**。
- **验收标准**：状态栏不再出现英文枚举名；诊断文本含阶段与失败原因字段；纯函数对 6 个枚举值各返回互不相同的中文。
- **建议测试**：枚举映射纯单测；诊断文本用 `settings_page_test.dart` 断言包含关键字，并**新增一条「诊断文本不含凭证值」的断言**把合规底线锁死。
- **风险/依赖**：零依赖。合规提醒：新增诊断字段不得带 cookie / ttwid / 凭证。

### ⬜ UX-10　回前台后开播状态可能永久陈旧；从没刷新过的房间显示成「未开播」（P1）

- **现状与问题**：
  1. `didChangeAppLifecycleState` 回前台只收敛悬浮窗权限与开关，**不刷新任何房间信息**；挂后台一夜回前台，行内仍是昨晚的「直播中」，只有「已刷新 12 小时前」这行灰色小字暗示是旧值，判断成本全转嫁给用户。
  2. `living == null`（从未刷新成功）与 `living == false`（已下播）文案完全相同都是「未开播」；弱网 / 风控导致自动刷新失败后，用户会以为主播没播，实际是数据压根没拿到。
- **期望行为**：
  1. 回前台时若存在 `lastRefreshedAt` 早于阈值（**30 分钟**，PM 决策 3）或为 null 的房间，自动触发一次静默刷新（复用 `_refreshRoomQuiet` 串行路径，不弹 SnackBar、不推悬浮窗配置）；
  2. `living == null` 的文案改为「未刷新」（PM 决策 4），`living == false` 才叫「未开播」。
- **验收标准**：假时钟 + 假 `RoomInfoClient`，`lastRefreshedAt` 为 1 小时前时触发 `AppLifecycleState.resumed` 会刷新；为 1 分钟前时**不**刷新；`living == null` 的行显示「未刷新」。
- **建议测试**：`test/home_page_test.dart`（基建齐备），生命周期用 `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed)` 驱动。
- **风险/依赖**：**节流是硬要求**（30 分钟内不重复打接口），必须在测试里锁住，否则切前台频繁请求会被风控。不引入任何新依赖 / 权限 / 后台机制。

### ⬜ UX-11　批量刷新期间每个主播各落盘一次，N 个主播 = N 次全量写盘（P2）

- **现状与问题**：`_refreshRoomQuiet` 每次成功都 `await _store.save(next)`，`_refreshAll` 串行调用 N 次 → 写 N 次全量 `rooms.json`；PR #17 只做到了「只同步一次悬浮窗配置」，写盘次数没变。列表长时刷新全程伴随持续磁盘 I/O，进度条更易卡顿。
- **期望行为**：批量路径下内存状态逐条更新、**落盘合并为一次**（循环结束后统一 `save`）；单条刷新保持现状（点一次写一次）。中途失败仍要把已成功的部分落盘。
- **验收标准**：`_refreshAll` 完成时 `RoomStore.save` 只被调用 1 次且最终内容含全部更新；最后一条失败不丢前面的结果。
- **建议测试**：`test/home_page_test.dart` + `test/room_store_test.dart`。`_refreshRoomQuiet` 被两条路径共用，抽参数时不得改变单条路径语义（否则 UX-04 既有用例会挂）。
- **风险/依赖**：低。与 UX-10 都改 `_refreshRoomQuiet` / `_refreshAll` 一带，建议 UX-10 先合再动本条。

---

## PM 第二轮决策（已批准，实现时照此执行）

1. **UX-07 与 UX-08 合并为一个 PR**：两者都改标题行与悬浮球菜单，且 UX-08 的「菜单里逐栏状态 + 重试」正是 UX-07 最省事的解法（入口从挤不下的标题行挪进菜单，标题行只留短状态词）。
2. **UX-07 的重试入口形态**：收进悬浮球菜单（图标 + 逐栏列表），标题栏只保留短状态文案。标题栏空间是硬约束，菜单已有「栏位管理」这一同族入口，用户心智一致，代价是多一次点击。
3. **UX-10 自动刷新阈值 30 分钟**：房间接口对频繁请求不友好；30 分钟覆盖「挂后台回来」主场景，又不会在频繁切换 App 时打接口。阈值内不刷必须有测试。
4. **UX-10 的 `living == null` 文案用「未刷新」**：它描述的是本 App 的动作缺失，用户能据此理解「点一下刷新就好」，比「状态未知」更可操作。
5. **UX-09 诊断信息明确同意扩充**，但「不含任何凭证明文」要写成测试断言锁死，不能只靠注释约定。
6. **UX-11 可做但排在 UX-10 之后**；若本轮 PR 预算只够 3 条，先砍 UX-11（纯性能、用户感知弱）。
7. **本轮 PR 预算 3~4 个**：① UX-07 + UX-08 ② UX-09 ③ UX-10 ④ UX-05（顺延项）。UX-06 与 UX-11 视 CI 情况再排。
8. **本清单不触碰硬边界**：5 条全部是纯 UI / 纯函数 / 复用既有 `WidgetsBindingObserver`，无新依赖、无新权限、无后台机制；纯查看器、免责声明不可绕过、清除数据三步走均未被改动。

---

## 已完成（历史记录）

### ✅ CR-01　代码审查 5 项修复（2026-10-15）

- 来源：`dsh_code_review` 全项目审查。
- P1 窗口尺寸下发链路：插件把 `resizeOverlay` 的通道只注册在悬浮窗引擎，主引擎直调必然抛 `MissingPluginException`，设置页尺寸滑杆与「已建窗重排栏位」都会静默失效。改为新增 `resize` 消息（`OverlayResize`），主 App 经消息通道交给悬浮窗引擎执行。
- P2 关窗状态同步：窗内关窗（悬浮球菜单）后主 App 仍以为窗口存在，再开「多栏连接」会走重排分支、窗口不再出现。改为关窗前补发带 `closed` 的聚合状态（`OverlayStatus.closed`），主 App 据此复位「已建窗」与各页开关；权限撤销属同一根因，一并复位。
- P3 悬浮窗栏位回溯判定排除自动滚动动画，与弹幕页口径一致。
- P3 三处 `../` 相对导入改 `package:danmu_float/...` 绝对导入。
- P3 移除未使用的 `http` 直接依赖（仍作为 `flutter_js` 的传递依赖保留在 `pubspec.lock`）。
- 测试：新增 8 个用例；`test/home_page_test.dart` 的 PM-002 断言改为「消息通道收到 resize 且尺寸通道零调用」。
- 交付：PR #11 / PR #12 已合并 `main`；`main` 复跑门禁 `No issues found!` + 297 tests passed。

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
  - 插件有**两条** MethodChannel：控制通道 `x-slayer/overlay_channel`（isActive / checkPermission / closeOverlay），尺寸通道 `x-slayer/overlay`（resizeOverlay）——尺寸通道只在悬浮窗引擎注册，主 App 侧断言不要挂在它上面（CR-01 已改为断言消息通道）
  - `_loadFilter()` 走默认构造的 FilterStore，需给 `plugins.flutter.io/path_provider` 挂临时目录 mock，否则 runAsync 时抛 MissingPluginException
  - 底部菜单 / 对话框入场动画约 200ms，pump 100ms 时 sheet 还在视口外滑入途中，tap 打不中（只有 warning 不算失败，后续 tap 才炸）；每个动画推满 500ms 再 tap
  - 等待信号要选「最终效果」：列表项消失（setState 先于落盘）、落盘不含旧值（writeAsString 先截断再写，空读要继续等）都不行，要等插件调用 / 期望值真正出现

---

## 明确不做（PM 已否决，防止后续「顺手加上」）

- 账号登录 / 发弹幕 / 打赏 / 评论等任何互动功能（项目硬边界）
- 云同步 / 多设备账号体系（导出导入备份已满足换机）
- 弹幕 AI 总结 / 情感分析 / 关键词趋势（超出「查看」范畴，涉隐私与合规）
- 自动推荐热门直播间 / 内容广场（涉内容分发与版权风险）
- 悬浮窗内再做一套屏蔽词可视化编辑器（主路径已覆盖，属重复）
- 跨设备记忆窗口位置 / 云备份布局（本地已落盘，云同步违反隐私基调）
- 付费皮肤 / 主题商城 / 自定义背景图（禁止商业用途）
- 截图 / 录屏 / 弹幕叠游戏画面（权限与隐私复杂，超出「查看」语义）
- 任何「不再提示」类记忆开关（AGENTS.md 要求高性能模式强制确认）
- 给 `overlay_page.dart` 做顺手重构（AGENTS.md 要求 PR 单一目的）
- 任何需要新增本地环境、新依赖或新权限的方案（本轮约束）

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
- 新增/修复**必须配单测**，与改动同 PR；单测用注入假实现（临时目录 / 内存后端 / 假 transport / 可注入定时器），不依赖网络、真机通道与真实等待。
- 禁止 `dart format`；显式类型标注；中文注释解释「为什么」；常量集中文件顶部；fire-and-forget 用 `unawaited`。
- Widget 测试已知坑：`pumpAndSettle` 会因首页持续的 post-frame 回调永不空闲而超时，改用有限 `pump(Duration)`；`shareData` 的 `send` 需挂应答 handler。
- 悬浮窗 Widget 测试的硬约束：`OverlayPage` 在 `initState` 订阅 `FlutterScreenOverlay.overlayListener`（**静态单订阅流**），**一个测试文件只能 mount 一次 `OverlayApp`**，第二次会抛 `Bad state: Stream has already been listened to`；需要多个悬浮窗用例时**每个用例单独建文件**（UX-02 已按此拆出 `test/overlay_pane_retry_test.dart`）。
- 广播流断言前先让出一轮：`session.stages.listen(...)` 收集到的内容经微任务投递，`await session.restart()` 后立刻断言会读到上一阶段的旧值，需先 `await _tick()`。
- 悬浮窗尺寸单位：`showOverlay` 收物理像素，`resizeOverlay` 收 dp，不可混用。
- 时间戳单位：AGENTS.md 第 5 节要求**毫秒**；`ManagedRoom.addedAt` 是历史遗留的秒（为兼容已落盘数据保持原样），新字段一律毫秒（如 `lastRefreshedAt`）。
- 同时改 `lib/app/live_danmu_session.dart` / `lib/ui/overlay_page.dart` 的条目（UX-01 / UX-02 / UX-05 / UX-07 / UX-08）**串行合入**；UX-07 与 UX-08 合并为一个 PR，UX-05 排在其后。
