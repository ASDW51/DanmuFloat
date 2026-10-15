# DanmuFloat 产品自迭代 TODO

> 目标：按 `docs/ci-pr-workflow.md` 流程驱动产品自迭代，持续提升应用用户体验。
> 决策来源：产品经理（PM）子代理审查；实现与验证：Lead。
> 门禁：本机无 Flutter 环境，`flutter analyze` + `flutter test` 全部由远程 CI（GitHub Actions）兜底，PR 绿了才合入 `main`。
> 约束：不安装任何本地环境；遵守 AGENTS.md 硬边界（纯弹幕查看器、免责声明不可绕过、清除数据三步走、禁止商业用途）。

## 当前状态（截至本次更新）

| 项 | 状态 | 位置 |
| --- | --- | --- |
| 迭代基线 | 已就位 | `main` @ 本轮 loop 末次合并点（第 5 轮确定性缺陷全部交付 #35 ~ #46；余 UX-22b 尾项 / UX-23b / UX-24 ~ UX-27） |
| CR-01 代码审查修复 | ✅ 已合入 | PR #11 / PR #12 → `main` |
| PM-001 | ✅ 已合入 | PR #7 → `main` |
| PM-002 | ✅ 已合入 | PR #8 → `main` |
| UX-01 未开播自动复检 | ✅ 已合入 | PR #14 → `main` |
| UX-02 手动重试入口 | ✅ 已合入 | PR #16 → `main` |
| UX-03 短链解析超时 + 可取消 | ✅ 已合入 | PR #15 → `main` |
| UX-04 刷新全部 + 陈旧可见 | ✅ 已合入 | PR #17 → `main` |
| UX-05 加栏确认 + 硬上限 | ✅ 已合入 | 首页侧 PR #23、悬浮窗侧 PR #24 → `main` |
| UX-06 引导手动步骤视觉/文案 | ✅ 已合入 | PR #25 → `main` |
| UX-07 标识行短文案 + 重试收进菜单 | ✅ 已合入 | PR #19 → `main` |
| UX-08 隐藏标识行后仍可重试 | ✅ 已合入 | PR #19 → `main` |
| UX-09 连接状态中文化 + 诊断扩充 | ✅ 已合入 | PR #20 → `main` |
| UX-10 回前台补刷过期房间 | ✅ 已合入 | PR #21 → `main` |
| UX-11 批量刷新只落盘一次 | ✅ 已合入 | PR #21 → `main` |
| UX-12 最小窗宽标识行溢出 | ✅ 已合入 | PR #27 → `main`（人数完整数字、不可省略） |
| UX-13 补刷失败节流 + 同主播互斥 | ✅ 已合入 | PR #21 → `main`（第三轮新增，与 UX-10 同批收口） |
| UX-14 弹幕页失败原因口径对齐 | ✅ 已合入 | PR #29 → `main` |
| UX-15 菜单未绑定栏位文案 | ✅ 已合入 | PR #30 → `main` |
| UX-16 权限 banner 补「去系统设置」 | ✅ 已合入 | PR #31 → `main` |
| UX-17 弹幕页状态栏溢出 | ✅ 已合入 | PR #35 → `main` |
| UX-18 首页操作只藏长按 | ✅ 已合入 | PR #36 → `main` |
| UX-19 深色模式文字不可见 | ✅ 已合入 | PR #38 → `main` |
| UX-20 最小窗宽弹窗溢出 | ✅ 已合入 | PR #40 → `main`（属性断言，未复现基线） |
| UX-21 悬浮球/菜单触控过小 | ✅ 已合入 | PR #39 → `main` |
| UX-22 术语不一致 | 🟡 部分交付 | a: PR #42（屏蔽词 + 诊断副标题）；b: 待做（直播间 / 栏位） |
| UX-23 添加无反馈 / 清空无确认 | 🟡 部分交付 | a: PR #41（过滤页）；b: 待做（弹幕页清空确认，需注入口） |
| UX-24 穿透态补关闭窗动作 | ⬜ 未开始 | 第 5 轮补充（P1）→ PR5（PM 建议优先） |
| UX-25 栏位异常/开播提醒 | ⬜ 未开始 | 第 5 轮补充（P2）→ PR7（先冒烟） |
| UX-26 查看弹幕时屏幕常亮 | ⬜ 未开始 | 第 5 轮补充（P2）→ PR6（零依赖） |
| UX-27 网络状态感知 | ⬜ 未开始 | 第 5 轮补充（P2）→ PR8（pub 依赖+权限） |

> 待办清单已按 PM 子代理 2026-10-15 的第一版审查**整版重写**：旧编号 PM-003 ~ PM-006 作废（保留项重新编号为 UX-01 ~ UX-06；其中旧 PM-006 的问题描述与现状不符，已改写为 UX-06）。
>
> 第三轮（2026-10-16 复核 UX-07 ~ UX-11 落地代码后）新增 UX-12 ~ UX-16；UX-10 的两处收口（失败路径也要节流、同一 webRid 单飞）并入 PR #21 落地，见表内 UX-13。第三轮决策见 [PM 第三轮决策](#pm-第三轮决策已批准实现时照此执行)。

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

### ✅ UX-05　悬浮窗内加栏位补高性能确认与硬上限（P2 · 已合入 PR #23 / PR #24）

> 交付拆分：PR #23 = 首页侧 + 公共确认弹窗（`lib/ui/high_performance_dialog.dart`、`maxPaneCount` / `canAddPane` / `needsHighPerformanceConfirm`）；PR #24 = 悬浮窗侧（两个加栏入口的确认与到顶禁用）。
>
> 已知缺口：「4 栏 → 加第 5 栏时弹确认、取消不加 / 确认 +1」的完整点击链路未覆盖（同属 `OverlayPage`、与到顶用例无法同文件 mount），当前由共用弹窗用例与阈值边界用例兜住；计划与 UX-12 的窄窗用例一并补。

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

### ✅ UX-06　首启引导手动类步骤：视觉区分度 + 明确「可不处理」（P2 · 已合入 PR #25）

- **现状与问题**：引导第 4 步写死 `done: false, manual: true`（`lib/ui/onboarding_page.dart:166-174`），`_StepTile` 对 `manual` 使用 `Icons.info_outline` + `Colors.blueGrey`（`onboarding_page.dart:249-251`）——**图标本身已是中性色，不是橙色警示**（旧 PM-006 的描述与当前代码不符）。但仍有真实问题：`manual` 分支与「已完成」的绿色 `check_circle` 视觉差异小，且 subtitle 只写「厂商设置项各不相同，需在系统设置里手动开启」，**没有说明「可以不做」**；在「按顺序完成以下准备」的强暗示下，用户会以为不点完这步就不算配置完成。
- **期望行为**：
  1. 手动类步骤视觉明确区别于「待完成」（保留中性色，图标建议 `Icons.tune` 或 `Icons.open_in_new` 之类「去设置」语义，不使用对勾）；
  2. subtitle 补一句「可不处理：不开启仅影响后台存活率，不影响弹幕查看」；
  3. 步骤标题区的引导语从「按顺序完成以下准备」改为不暗示「必须完成」的表述（如「以下准备可按需完成，随时可跳过」），与页面已有的「全部步骤都可跳过」口径一致。
- **验收标准**：manual 步骤不渲染为绿色对勾；subtitle 含「可不处理」；页面顶部引导语不含「完成以下准备」这类必须性措辞。
- **建议测试**：`test/onboarding_page_test.dart` 断言 manual 步骤的图标与文案，用 `find.byIcon` / `find.textContaining`。
- **风险/依赖**：纯文案与视觉，零风险。注意 AGENTS.md 要求「权限申请入口任意时刻可达」——本页是设置页「权限申请引导」的落地页，**不得删除任何步骤或按钮**，只调视觉与文案。

### ✅ UX-07　多栏 / 窄窗下栏目标识行被重试入口撑溢出，重试反而点不到（P0 · 已合入 PR #19）

- **现状与问题**：`_buildTitleBar` 是单行 `Row`，固定宽度子项已有状态点 / 换绑箭头 / 焦点 / 暂停（`lib/ui/overlay_page.dart` 标题栏区域），UX-02 又插入 `Icons.refresh` + 「点此重试」文案。5 栏起 `OverlayGrid` 变 3 列，`defaultOverlayWidth = 400` 时单栏仅约 133dp，扣掉栏内边距只剩约 110~120dp，而固定子项 + 重试按钮最小宽度已超出；`_stageText` 在 error / offline 态又更长。真机结果：栏目标识行右侧出现黄黑溢出条，**重试按钮被挤出可视区**——救活入口在最需要它的多栏场景下点不到。
- **期望行为**：
  1. 窄宽度下不溢出：阶段文案降级为短形态（error → 「失败」、offline 停止复检 → 「未开播」、复检中 → 「复检中…」），完整文案（含「点此重试」）只进 Tooltip 与无障碍标签；
  2. 重试入口改为图标按钮，或整体收进悬浮球菜单（与 UX-08 合并做更省事）；
  3. 换绑箭头 / 焦点 / 暂停在窄窗下可折叠，但**不得删掉任何功能**。
- **验收标准**：3 栏、窗口宽 400dp（单栏 ≈133dp）下渲染失败态栏位，`tester.takeException()` 为 null（无 `RenderFlex overflowed`）；重试入口 `find` 命中且 `tap` 可触发重建；单栏宽窗下文案保持完整。
- **建议测试**：新开独立文件（`OverlayPage` 的静态单订阅流每文件只能 mount 一次），用 `tester.view.physicalSize` 固定 3 栏窄窗尺寸断言无溢出且重试可点。
- **风险/依赖**：纯布局，零依赖。**溢出条只在 debug 构建可见，`flutter analyze` 不会报错**，必须靠这条 Widget 断言把回归锁住。与 UX-08 都改标题行 / 悬浮球菜单，**合并为一个 PR**（PM 决策 1）。

### ✅ UX-08　隐藏栏目标识行后失败栏位既看不见也点不到；重试后失败原因还会消失（P1 · 已合入 PR #19）

- **现状与问题**：
  1. 栏目标识行由 `_prefs.showTitleBar` 控制（设置页有开关），关掉后阶段文案、状态点、**重试入口**全部不渲染；窗内唯一入口悬浮球菜单里没有任何栏位连接状态或重试入口，用户只看到「有几栏一直没弹幕」，分不清未开播 / 连接失败 / 已静音。
  2. `_retry()` 先 `setState(() => _error = null)` 再 `restart()`，而 `_error` 只在 `_report()` 里由 `session.errorMessage` 回填；重试后若停在 `offline`（不再是 error），`_error` 永远为 null，空列表只剩「暂无弹幕」，用户失去唯一可查的原因。
- **期望行为**：
  1. 悬浮球菜单新增「栏位状态」区块：逐栏一行「第 N 栏 · 主播名 · 状态」，**仅对 `shouldOfferRetry(...)` 为真的栏位**显示「重试」按钮（复用既有判定，不新增口径）。显示条件（第三轮改写，取代旧的「栏位 ≤ 1 时可省略」）：

     | 场景 | 期望 |
     | --- | --- |
     | 单栏 + 健康（live / connecting / 复检中） | 菜单不显示该区块 |
     | 单栏 + error，或 offline 且复检已停 | 显示，且「重试」可点、点击触发重建 |
     | ≥ 2 栏 | 恒显示；非 retryable 行只给「第 N 栏 · 名称 · 状态」，无按钮 |

     该区块**不按 `showTitleBar` 门控**：标识行对重试只是「展示」（短状态词 + Tooltip），唯一可点入口本来就在菜单里；按 `showTitleBar` 门控只会多一条分支、多一组用例，对用户零收益。「`showTitleBar: true` 时行为不变」应理解为**不出现第二个可点重试入口**。
  2. 该区块与 `showTitleBar` 无关，标识行关掉后仍是统一兜底入口；
  3. `_retry()` 不再无条件清空 `_error`：保留到下一次成功建连或用户主动清空。
- **验收标准**：`showTitleBar: false` + 一栏失败态下，菜单里能看到该栏状态与可点「重试」，点击触发重建；`showTitleBar: true` 时行为不变（无重复入口）；重试后再次失败，失败原因在空态文案里仍可见。
- **建议测试**：独立文件单次 mount；断言菜单中失败栏位「重试」存在、点击后 `restart` 生效（假 `RoomInfoClient` 计数）、二次失败后 `_error` 仍出现在空态文案。
- **风险/依赖**：`_reports` 里现成的逐栏 `_Report` 直接复用，无需新增状态。与 UX-07 严格串行 / 同 PR。

### ✅ UX-09　弹幕页把内部枚举名直接显示给用户，失败原因不进诊断信息（P1 · 已合入 PR #20）

- **现状与问题**：弹幕页状态栏渲染 `'连接: ${_session!.connectionState.name}'`，`DanmuConnectionState` 的 `.name` 是英文枚举名（`idle / connecting / connected / reconnecting / failed / closed`），真机出现「连接: reconnecting」这类内部术语，同行其它元素已是中文；「复制诊断信息」只含样式 / 凭证 / 悬浮窗开关，**不含连接状态与失败原因**，悬浮窗侧诊断完全缺失，用户报障时维护者无法区分签名降级 / 接口风控 / WS 握手被拒。
- **期望行为**：
  1. 状态栏把 `connectionState` 映射为中文短词（连接中 / 已连接 / 重连中 / 已停止 / 已关闭），新增纯函数便于单测，枚举 `.name` 不再出现在任何用户可见文案；
  2. 「复制诊断信息」补充当前会话阶段、`socketError`、是否签名降级、悬浮窗逐栏状态摘要——**仍不含任何凭证明文**。
- **验收标准**：状态栏不再出现英文枚举名；诊断文本含阶段与失败原因字段；纯函数对 6 个枚举值各返回互不相同的中文。
- **建议测试**：枚举映射纯单测；诊断文本用 `settings_page_test.dart` 断言包含关键字，并**新增一条「诊断文本不含凭证值」的断言**把合规底线锁死。
- **风险/依赖**：零依赖。合规提醒：新增诊断字段不得带 cookie / ttwid / 凭证。

### ✅ UX-10　回前台后开播状态可能永久陈旧；从没刷新过的房间显示成「未开播」（P1 · 已合入 PR #21）

- **现状与问题**：
  1. `didChangeAppLifecycleState` 回前台只收敛悬浮窗权限与开关，**不刷新任何房间信息**；挂后台一夜回前台，行内仍是昨晚的「直播中」，只有「已刷新 12 小时前」这行灰色小字暗示是旧值，判断成本全转嫁给用户。
  2. `living == null`（从未刷新成功）与 `living == false`（已下播）文案完全相同都是「未开播」；弱网 / 风控导致自动刷新失败后，用户会以为主播没播，实际是数据压根没拿到。
     - **落地说明**：「未刷新」文案代码里**已存在**（`_livingLabel(null) => '未刷新'`，`lib/ui/home_page.dart`），本条只需保证补刷路径不改掉它。
- **期望行为**：
  1. 回前台时若存在 `lastRefreshedAt` 早于阈值（**30 分钟**，PM 决策 3）或为 null 的房间，自动触发一次静默刷新（复用 `_refreshRoomQuiet` 串行路径，不弹 SnackBar、不推悬浮窗配置）；
  2. `living == null` 的文案改为「未刷新」（PM 决策 4），`living == false` 才叫「未开播」。
- **验收标准**：假时钟 + 假 `RoomInfoClient`，`lastRefreshedAt` 为 1 小时前时触发 `AppLifecycleState.resumed` 会刷新；为 1 分钟前时**不**刷新；`living == null` 的行显示「未刷新」。
- **第三轮补的验收（已随 PR #21 落地）**：
  1. **失败路径也要节流**：`lastRefreshedAt` 只在成功时写，只按它判断会让弱网 / 被风控时每次回前台都重打整列表；因此另记「上次尝试时间」（纯内存、不落盘），同一 30 分钟窗口内不再自动补刷。断言：补刷失败后 1 分钟内再 `resumed` 不发请求；超过 30 分钟才允许再试。
  2. **同一 webRid 单飞**：补刷在飞时行内「刷新」与「刷新全部」必须跳过该主播，否则同一主播两路在飞，抵消 UX-04 刻意串行的风控考虑。断言：用可挂起的假 `RoomInfoClient` 制造重叠窗口，该 webRid 仍只收到 1 次请求。
  3. **每批至多推送一次悬浮窗候选**：补刷不是逐条推 `rooms`，一批 ≤ 1 条（否则像刷屏一样连发配置）。
- **建议测试**：`test/home_page_test.dart`（基建齐备）。生命周期**不要**用 `tester.binding.handleAppLifecycleStateChanged`（`WidgetsBinding` 上该成员带 `@protected`，在 App 测试里调用会被 `invalid_use_of_protected_member` 拦下），改为向 `flutter/lifecycle` 渠道发一条消息：`messenger.handlePlatformMessage(SystemChannels.lifecycle.name, const StringCodec().encodeMessage('AppLifecycleState.resumed'), (_) {})`；先发 `inactive` 再发 `resumed`，避免与测试进程初始的 `resumed` 同态被忽略。
- **风险/依赖**：**节流是硬要求**（30 分钟内不重复打接口），必须在测试里锁住，否则切前台频繁请求会被风控。不引入任何新依赖 / 权限 / 后台机制。

### ✅ UX-11　批量刷新期间每个主播各落盘一次，N 个主播 = N 次全量写盘（P2 · 已合入 PR #21）

- **现状与问题**：`_refreshRoomQuiet` 每次成功都 `await _store.save(next)`，`_refreshAll` 串行调用 N 次 → 写 N 次全量 `rooms.json`；PR #17 只做到了「只同步一次悬浮窗配置」，写盘次数没变。列表长时刷新全程伴随持续磁盘 I/O，进度条更易卡顿。
- **期望行为**：批量路径下内存状态逐条更新、**落盘合并为一次**（循环结束后统一 `save`）；单条刷新保持现状（点一次写一次）。中途失败仍要把已成功的部分落盘。
- **验收标准**：`_refreshAll` 完成时 `RoomStore.save` 只被调用 1 次且最终内容含全部更新；最后一条失败不丢前面的结果。
- **建议测试**：`test/home_page_test.dart` + `test/room_store_test.dart`。`_refreshRoomQuiet` 被两条路径共用，抽参数时不得改变单条路径语义（否则 UX-04 既有用例会挂）。
- **风险/依赖**：低。与 UX-10 都改 `_refreshRoomQuiet` / `_refreshAll` 一带，建议 UX-10 先合再动本条。

### ✅ UX-12　最小窗宽下标识行溢出：人数完整显示且不可省略（P1 · 已合入 PR #27）

- **口径裁定（本轮）**：**在线人数给完整数字、不可省略；连接状态用状态点的颜色表示即可、允许省略；其它不变。** 因此不再把状态词当唯一兜底，让位顺序改为「装饰图标 → 状态 →（绝不）人数」。
- **改动**：`formatOnlineCount` 不再折算「x.x万」，一律完整数字（悬浮窗标识行与 App 内弹幕页共用同一实现）；标识行改用 `LayoutBuilder`，人数 = `ConstrainedBox(可用宽 − 固定项)` + `FittedBox(fit: scaleDown)`（窄到放不下时整体等比缩小，绝不裁末尾几位），连接状态 `maxLines: 1` + `TextOverflow.ellipsis`；`<120dp` 折叠换绑箭头与焦点图标，`<84dp` 连暂停也让位（三者都有替代入口：换绑在「栏位管理」、焦点与暂停还能双击；人数没有）。
- **验收标准（已满足）**：新增 `test/overlay_pane_minwidth_test.dart` 覆盖 9 栏 @200dp（折叠暂停图标）、2 栏 @200dp（保留暂停、折叠焦点）、2 栏 @400dp（图标按需恢复），三处均 `takeException() == null`；`test/danmaku_display_test.dart` 断言 `10000 → '10000'`、`123456 → '123456'` 并显式断言不含「万」。
- **已知缺口**：`_online` 只能由真实 socket 的弹幕统计喂入，`OverlayPage` 未暴露注入点，故「极窄 + 六位人数」的 `FittedBox` 缩放分支未被 widget 用例直接命中；要覆盖需先在 `OverlayPage` 上开注入点。
- **风险/依赖**：已随 UX-05 悬浮窗侧串行完成（同改 `lib/ui/overlay_page.dart` 标识行）。

### ✅ UX-13　补刷失败没有节流，且同一主播可能并发两条请求（P1 · 已合入 PR #21）

- **现状与问题**：
  1. `isRoomStale` 只看 `lastRefreshedAt`，而它**只在成功时写**；弱网 / 被风控时每次回前台都会把整列表重打一遍——30 分钟节流对「失败」完全不生效，恰好放过了它该防的场景。
  2. 回前台补刷只在入口看 `_refreshAllRunning`，循环里不登记在飞集合；补刷可持续数秒，期间行内「刷新」仍可点、`_refreshAll` 也能启动 → 同一 webRid 两路在飞，抵消 UX-04 刻意串行的风控考虑。
- **期望行为**：同一 webRid 任意时刻只有一路在飞；补刷额外受「距上次尝试」的 30 分钟窗口约束（纯内存、不落盘）；补刷不制造额外视觉噪音（不弹提示），但行内入口在该主播在飞时置灰。
- **验收标准**：补刷失败后 1 分钟内再 `resumed` 不发请求；超过 30 分钟才允许再试；可挂起假客户端下，同一 webRid 在飞时行内入口禁用、批量刷新跳过它，仍只有 1 次请求；每批至多推送一次悬浮窗候选。
- **风险/依赖**：无新依赖 / 权限；`_lastStaleRefreshAttemptAt` 只在内存，进程重启即重置（可接受：重启本身就会走一次首刷）。

### ✅ UX-14　弹幕页失败原因不再被清掉，与悬浮窗同口径（P2 · 已合入 PR #29）

- **改动**：抽出纯函数 `nextErrorReason(current, {stage, message})`（有原因就覆盖、没原因就留着，只有 `live` 清空）；阶段监听改走它，`_retry()` 不再提前清空。

- **现状与问题**：弹幕页 `_retry()` 先 `setState(() => _errorMessage = null)`，阶段监听又**无条件** `_errorMessage = session.errorMessage` → 任何阶段变化（解析中 / 未开播）都会抹掉原因，空列表退回「暂无弹幕」；悬浮窗侧 UX-08 已改为「只覆盖、live 才清」。
- **期望行为**：与悬浮窗同口径；把「何时保留 / 清空原因」抽成纯函数（沿用 UX-09 的做法），页面只调用。
- **验收标准**：纯函数单测覆盖 error → offline → live 迁移（无需新增 widget 注入口）。
- **风险/依赖**：零依赖；`lib/ui/danmu_page.dart` 无其它待办竞争。

### ✅ UX-15　菜单未绑定栏位改写「第 N 栏 · 未绑定」（P2 · 已合入 PR #30）

- **改动**：抽出纯函数 `paneStatusLabel({index, webRid, name, stage})`，未绑定栏只写「第 N 栏 · 未绑定」，不再拼状态。
- **过程修正（已核实）**：`OverlayConfig.tryParse` 会过滤空 webRid，所以「未绑定栏」（`_OverlayPaneState._bound => widget.webRid.isNotEmpty`）在当前协议下无法在 widget 测试里复现——首轮 CI 的 widget 用例因此失败，改为纯函数覆盖三条分支，不用不可达状态编造绿灯。要真正打通该路径需先让协议允许占位栏位（独立变更）。

- **现状与问题**：`_buildPaneStatusRow` 用 `_roomNameOf(_webRids[index])`，未绑定栏 webRid 为空 → 名字空串；`_reports` 无条目时状态写死「等待中」→ 出现 `·  ·` 双空格且语义不符。
- **期望行为**：显示「第 N 栏 · 未绑定」，与标题行「第 N 栏未绑定」同口径。
- **验收标准**：多栏用例下发一个空 webRid 栏位，`find.textContaining('未绑定')` 命中且不出现 `·  ·`。
- **风险/依赖**：与 UX-12 同区域（标识行 / 菜单），需串行或拆两个小 PR。

### ✅ UX-16　权限 banner 补「去系统设置」出口（P2 · 已合入 PR #31）

- **改动**：`_retryOverlayPermission` 按结果置 `_overlayRetryFailed`，banner 在重试仍被拒时追加「去系统设置」（`systemPermissions.openAppSettings()`，无新权限 / 依赖）；未重试前不显示。
- **测试要点**：悬浮窗权限查询走插件通道 `FlutterScreenOverlay.checkPermission`，**不经** `systemPermissions`——`_mockOverlayChannels` 因此新增 `permissionGranted` 开关（默认 true，不影响既有用例）；假后端只用于断言 `openAppSettings` 被调用一次。

- **现状与问题**：首页 banner 只有「重试授权」走 `ensureOverlayPermission()`；系统不再弹框时点了没有任何反馈，也没有「去系统设置」出口（该出口只在引导页第 4 步与设置页入口里）。AGENTS §5 要求权限入口任意时刻可达，这里是「可达但走不通」。
- **期望行为**：重试返回 false 后 banner 给出「去系统设置」次级入口，复用 `systemPermissions.openAppSettings()`（无新权限 / 依赖）。
- **验收标准**：用现有 seam `setSystemPermissionBackend`（`lib/system/system_permissions.dart`，测试尚未用过）注入返回 false 的假后端，断言 banner 出现「去系统设置」且点击调用一次 `openAppSettings`。
- **风险/依赖**：改 `lib/ui/home_page.dart`，与 UX-05 首页侧同文件 → 排在 `feat/pane-add-guard` 之后合入。

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

## PM 第三轮决策（已批准，实现时照此执行）

1. **「栏位状态」显示条件按 UX-08 的三行矩阵**（多栏恒显示 / 单栏仅 unhealthy 显示），**不按 `showTitleBar` 门控**：标识行对重试只是展示，唯一可点入口本来就在菜单。
2. **复检预算用尽时补发一条 `offline` 是正确解法**：不新增独立信号流、不把 `LiveDanmuSession._stages` 改成 `sync: true`、不追加 `distinct()`——「非 sync 的 broadcast」正是「监听回调执行时 `autoRechecking` 已复位」的前提。单测锁「恰好补发一条」+「该事件到达时 `shouldOfferRetry(...)` 为 true」。
3. **UX-10 与 UX-11 并为一个 PR**（同一段刷新 / 落盘代码）；UX-11 的「只落盘一次」是**硬验收**，用 `@visibleForTesting RoomStore? store` 注入口断言 `save` 次数，不能只靠注释约定。
4. **UX-10 补两条硬验收**：① 失败路径同样受 30 分钟窗口节流（纯内存的「上次尝试时间」）；② 同一 webRid 任意时刻只允许一路在飞。`_syncOverlayRooms()` 保留，但口径改为「每批 ≤ 1 条，不逐条推送」。
5. **UX-05 拆两步**：先合 `feat/pane-add-guard`（首页侧 + 公共确认弹窗），再从新 `main` 做悬浮窗侧。
6. **本轮 PR 预算 3~4 个**：① #21 收口（UX-10 / UX-11 / UX-13）② docs 台账 ③ `feat/pane-add-guard` ④ UX-05 悬浮窗侧；UX-12 与 UX-06 进下一批（若允许第 5 个，UX-12 优先于 UX-06——它是用户可见的正确性兜底）。
7. **本批仍不触碰硬边界**：全部是纯 UI / 纯函数 / 复用既有 `WidgetsBindingObserver` 与注入点，无新依赖、无新权限、无后台机制。

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
- 为会话阶段流新增独立信号流，或把 `LiveDanmuSession._stages` 的 `broadcast()` 改成 `sync: true` / 追加 `distinct()`（会让「复检预算用尽 → 放出重试入口」退回永久「复检中…」，见 PM 第三轮决策 2）

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
- **同一分支不得叠加两个条目**：`feat/resume-stale-refresh` 上曾混入 UX-05 悬浮窗侧改动（还依赖未合并的 `feat/pane-add-guard`），一提交 CI 必红。提交前先 `git status` 确认改动只属于本条。
- **引用公共文件 / 常量前先确认它已在 `main`**：`lib/ui/high_performance_dialog.dart` 与 `canAddPane` / `maxPaneCount` / `needsHighPerformanceConfirm` 目前只存在于 `feat/pane-add-guard`，主线分支引用它们会直接编译不过。
- `lib/ui/overlay_page.dart` 的 UX-05（悬浮窗侧）、UX-12、UX-15 三处同区域，**必须串行合入**（顺序 UX-05 → UX-12 → UX-15）。
- 断言「落盘 / 推送次数」这类副作用时，要**等它真正发生**再断言（例如等 `rooms` 推送出现）；UI 更新早于 `save`，抢时序会随机读到旧值（PR #21 首轮 CI 两次栽在这里）。
- 影响按钮可用性的可变状态变更必须走 `setState`：`_autoRefreshing` 最初直接 `add`，行内按钮不变灰（PR #21 CI 抓到）。

---

## 第 5 轮（UI / 交互方向自迭代 · PM 子代理体检）

**总评**：悬浮窗侧经 UX-05/07/08/12/15 打磨已相当稳，短板转移到主 App —— `lib/ui/danmu_page.dart`（841 行、**零 widget 测试覆盖**）与 `lib/ui/home_page.dart` 展示层仍是「裸 `Row` 硬排 + 硬编码 `Colors.grey` / `Colors.black54` + 长按藏功能」。最该先修：弹幕页状态栏在主流机型宽度下必然溢出（默认路径，非极端组合）、深色模式下多处文字几乎不可见（设置页却明确提供深色模式）、首页含**移除主播**的三个操作零可见入口。

**本轮口径**：允许提出需要新增 pub 依赖 / Android 权限 / 后台机制 / 原生通道的方案（须写明「为什么非它不可」+ 替代方案 + 拒绝授权时的降级路径）；仍然禁止改宿主机环境、改 `.github/workflows/`、动摇 AGENTS.md 硬边界、删除既有功能入口。**本报告 7 条均未用到新依赖/权限。**

### UX-17　弹幕页状态栏在常见机型宽度 / 系统大字号下整体溢出（P1 · 新增）

- **现状**：`lib/ui/danmu_page.dart:594-630` 的 `_buildStatusBar` 是**没有任何 `Flexible` / `Wrap` 的裸 `Row`**：状态点(10)+间隔(6)+状态词(`:602`)+可选「重试」(`:605-617`)+间隔(12)+`已收 N`+间隔(12)+`在线 N`(`:620-623`)+间隔(12)+`连接: …`。在线人数自 UX-12 起是完整数字（`danmaku_display.dart:361`），5 位常见。按 14sp 估算无「重试」时 ≈345dp > 360dp 机型的 336dp 内容区；带「重试」≈417dp。`grep textScaler lib/` 为空 → 项目无字号收敛点，系统放大即触发。**证据分级：读代码推断**。
- **期望**：改为可换行/可让位（外层 `Wrap`，或给 `已收/在线/连接` 加 `Flexible`+ellipsis），**不删信息**；并把该行抽成公开组件 `lib/ui/danmu_status_bar.dart`（参数化 stage/stageLabel/received/online/connectionLabel/retryable/onRetry/errorMessage/overlaySummary），让这行第一次有测试面。
- **验收**：新增 `test/danmu_status_bar_test.dart`（挂载抽出的组件，**不涉及 OverlayPage 的单订阅流限制**）：① 360dp 定宽 + `retryable: true` 下 `takeException() == null`（**若修复前不报错，说明宽度估算有误 → 本条降级为纯防回归用例**）；② `textScaleFactorTestValue = 2.0` 同断言；③ 信息不丢：`在线`/`已收` 各命中 1，`重试` 按钮存在且高度 ≥40（顺带修 `:613` 的 ~17dp 触控高度）。
- **依赖**：与 UX-19 同文件 → 串行（PR1 → PR3）。

### UX-18　首页三个操作（含「移除主播」）只藏在长按里（P1 · 新增）

- **现状（已核实）**：`lib/ui/home_page.dart:1165-1167` 的 `ListTile` 只给 `onLongPress: () => _showRoomActions(room)`，`trailing`（`:1208-1231`）只有「刷新」「连接弹幕」，分组/凭证/移除全在 `_showRoomActions`（`:1263-1310`）里，无任何可见提示。
- **期望**：保留长按，`trailing` 追加可见「更多」按钮（tooltip `更多操作`，触控 ≥40dp），点击打开**同一份** `_showRoomActions`。360dp 空间账：40(leading)+32(padding)+64+100+40(trailing) ≈ 276dp，标题仍有 ~84dp。
- **验收**：`test/home_page_test.dart` 追加：① 2 个主播 → `find.byTooltip('更多操作')` 命中 2；② 点击后 `设置分组/使用凭证/移除主播` 各命中 1；③ 长按仍打开同一弹窗（保留旧行为）；④ 360×720 下 `takeException() == null`。
- **依赖**：只改 `home_page.dart`，与其它条目零冲突。

### UX-19　深色模式文字不可见 + 浅色次要文字对比度不足（P1 · 新增）

- **现状（已核实）**：① `danmu_page.dart:731` 进场「欢迎」用 `Colors.black54`，底色是 `surfaceContainerHighest`（`:722`）→ 深色主题下等于看不见；② `danmu_page.dart:484` 弹幕原文同样写死 `Colors.black54`，M3 底部弹窗深色底上同样看不见；③ `danmu_page.dart:787` 时间戳 `Colors.grey` 白底 ≈2.9:1（WCAG AA 需 4.5:1），`filter_page.dart:422`、`home_page.dart:1190/1365`、`onboarding_page.dart:133` 同理；④ `danmu_page.dart:582-588` 状态色用原生 `green/orange/grey`，浅色下 ≈2.6/2.2:1（状态词是文本，不能只靠圆点）。对照：悬浮窗侧已有 `OverlayPalette` 按皮肤取色（`overlay_page.dart:1929-1942`），主 App 无对应收敛点。
- **期望**：新增 `lib/ui/danmu_text_colors.dart`（`secondaryTextColor` / `stageTextColor` / `entryBannerWelcomeColor`，均按 `Brightness` 取色且 ≥4.5:1），三处硬编码改走它。
- **验收**：新增 `test/danmu_text_colors_test.dart` 用 `Color.computeLuminance()` 直接算：① light 对白底、dark 对 M3 深色 surface 均 ≥4.5；② `entryBannerWelcomeColor(dark)` 对深色 `surfaceContainerHighest` ≥4.5 且 `!= Colors.black54`；③ 五阶段 × 两 Brightness 全部 ≥4.5；④ 搭配 PR1 组件在 `ThemeData(brightness: dark)` 下断言状态词 `style.color == stageTextColor(..., dark)`。
- **依赖**：同文件 `danmu_page.dart` → 排在 PR1 之后（PR3）。

### UX-20　悬浮窗最矮（200×150）时窗内弹窗纵向溢出（P2 · 新增）

- **现状**：`overlay_page.dart` 5 处 `showDialog`（`:1284/:1324/:1702/:2087/:2457`）与 `showOverlayNotice`（`:233`）都没有 `insetPadding` / `scrollable`（grep 为空）；窗口高度下限 `minOverlayHeight = 150`（`overlay_bridge.dart:74`），AlertDialog 可用高度 ≈102dp，而「标题+内容+按钮」已 ≈120dp 起。**证据分级：读代码推断**。
- **期望**：窗内弹窗统一 `insetPadding: EdgeInsets.all(8)` + `scrollable: true`（`showOverlayNotice` 同理）。
- **验收**：新增 `test/overlay_minwindow_dialog_test.dart`（`OverlayApp` 每文件只能 mount 一次）：① `physicalSize = 200×150`；② 下发 1 栏 config → 悬浮球 → 栏位管理 → `takeException() == null` 且 `取消` 可点；③ `showOverlayNotice` 路径断言 `知道了` 命中。**若修复前已通过 → 降级为「收紧 insetPadding + 防回归用例」**。
- **依赖**：与 UX-21 同文件，同一 PR 内 UX-20 先于 UX-21。

### UX-21　悬浮球与菜单可点区域过小（P2 · 新增）

- **现状（已核实，均为代码常量）**：① 悬浮球 `overlay_page.dart:706-729` 仅 `SizedBox(24×24)` + 闲置 `Opacity(0.4)`，却是窗内**唯一**菜单入口（尺寸/透明度/加栏/关闭）；② `_menuButton`（`:970-982`）`padding vertical 2` + `minimumSize: Size.zero` + `shrinkWrap` → 行高 ≈17dp，「添加/减少栏位、栏位管理、关闭悬浮窗」全是这个高度；③ 菜单内栏位「重试」（`:939-948`）同款 ≈17dp —— 而 UX-08 的整个承诺就是「菜单是窗内唯一能重连的地方」。
- **期望**：视觉不变，只放大命中区：球外包 ≥32×32 `GestureDetector(behavior: opaque)`（闲置不透明度 0.4 → 0.55），`_menuButton` 与「重试」竖向 padding ≥6（行高 ≥28dp）；注释写明球扩大命中区会占用角落 32×32 的弹幕手势（那块本来被球压着）。
- **验收**：新增 `test/overlay_touch_target_test.dart`（独立 mount）：① 球尺寸 ≥32（给球加 `ValueKey('overlayBall')`，或断言承载 `InkWell` 的 `RenderBox` 尺寸）；② 展开菜单后 `添加栏位` 高度 ≥28，且 `减少栏位` 仍在（未删入口）；③ 200×400 下 `takeException() == null`。
- **依赖**：同一 PR 内排在 UX-20 之后。

### UX-22　同一功能多个名字（P2 · 新增）

- **现状（已核实）**：① 屏蔽名单在设置页 `settings_page.dart:278` 叫「屏蔽**关键词**」、过滤页 `filter_page.dart:67/204` 同，但 `filter_page.dart:219` 写「可与屏蔽**词**同时使用」，弹幕页 `danmu_page.dart:507/527` 与悬浮窗 `overlay_page.dart:1710/1728` 一律「屏蔽**词**」；② 同一对象三种叫法：首页「主播」（`home_page.dart:979/1004`）、添加表单「直播间号 / 抖音号」（`add_room_dialog.dart:124`）、状态文案「房间」（`danmu_page.dart:657`、`overlay_page.dart:2356`）；③ `settings_page.dart:472` 副标题「当前样式与凭证来源摘要」与实际内容（含主题/栏位/开关状态）不符；④ 悬浮窗「栏位 / 栏」混用。
- **期望**：术语表固定为 `屏蔽词` / `直播间` / `栏位`（列表标题可保留「主播管理」）；`:472` 副标题改为「当前样式、凭证来源与悬浮窗状态摘要」。
- **验收**：`settings_page_test.dart`（新副标题 + `屏蔽词`）、`filter_page_test.dart`（`屏蔽关键词` 命中 0）、复用 PR1 组件断言「解析直播间…」、`paneStageText` 纯函数扩展「栏位」口径。
- **依赖**：跨 4 文件；overlay 部分排在 PR4 之后，danmu 部分排在 PR3 之后。

### UX-23　点「添加」没反应；弹幕页「清空」误触即丢（P2 · 新增）

- **现状（已核实）**：① `filter_page.dart:391-411` 的 `_add()` 先 `_controller.clear()`（`:406`）再判重，空输入/已存在则 `if (next.length == widget.values.length) return;`（`:409`）静默返回且 `_error` 被清空 → 用户看到「输入框被清空、列表无变化、无提示」；② `danmu_page.dart:560-567` 的「清空」直接 `_raw.clear(); _received = 0;`，无确认无撤销，且 `_online` / 进场行未复位。
- **期望**：`_add()` 空输入 → `请输入内容`、重复 → `该词已在列表中`，**失败时不清空输入框**；「清空」前弹确认，确认后同时复位 `_received/_online/_latestEntry`。
- **验收**：`filter_page_test.dart` 追加（该页可注入内存 store，无需新注入口）：重复词 → `该词已在列表中` 且 controller 文本保留；空输入 → `请输入内容`；合法新词仍可加（回归）。弹幕页清空：需加 `@visibleForTesting RoomInfoClient? roomInfoClient` 注入口（与 `_OverlayPane` 同款，用「返回未开播」的假客户端即可稳定到 `offline`），否则降级为人工验收并排到 P2 末位。
- **依赖**：过滤页随时可做；弹幕页部分排在 PR3 之后。

### 本轮 PR 拆分与顺序

| PR | 覆盖 | 改动文件 | 测试 | 串行约束 |
| --- | --- | --- | --- | --- |
| PR1（P1） | UX-17 | `lib/ui/danmu_status_bar.dart`（新）、`danmu_page.dart` | `test/danmu_status_bar_test.dart`（新） | 无前置 |
| PR2（P1） | UX-18 | `home_page.dart` | `home_page_test.dart`（追加） | 与其它零冲突，可先合 |
| PR3（P1） | UX-19 | `lib/ui/danmu_text_colors.dart`（新）、`danmu_page.dart` | `test/danmu_text_colors_test.dart`（新） | **必须排在 PR1 后**（同文件） |
| PR4（P2） | UX-20 + UX-21 | `overlay_page.dart` | `test/overlay_minwindow_dialog_test.dart`、`test/overlay_touch_target_test.dart`（各自独立 mount） | 同 PR 内 UX-20 → UX-21 |

预算外按序插队：UX-22（overlay 部分排 PR4 后）→ UX-23（过滤页随时，弹幕页排 PR3 后）。**文件串行一句话**：`danmu_page.dart` = PR1 → PR3 → UX-23b；`overlay_page.dart` = PR4 → UX-22(overlay)。

### 明确不做（本轮）

1. 全局收敛 `textScaler`（锁 1.3 倍）——用压掉无障碍大字体换布局稳定，方向错误；改为让关键行可换行/可让位。
2. 删掉首页行内「连接弹幕」按钮只留整行点击——触碰「不删既有入口」红线，且带文字主按钮更好发现；只在 UX-18 里压缩宽度。
3. 设置页「恢复默认样式」一键重置——新增功能而非修缺陷，已有「导入数据」作逃生口。
4. 重做悬浮窗 `OverlayPalette` 配色——深浅皮肤已按画面亮度分别取色且经 UX-12 验证，本轮无新证据。
5. 给 `DanmuPage` 补整套 widget 测试基建——需三处注入口与 mock，成本远超本轮其余条目；只按 UX-17 抽一个可独测组件。
6. 弹幕页 AppBar 四个图标收敛成溢出菜单——360dp 下无溢出证据，属审美取舍。

### 第 5 轮补充（放宽口径后的新能力条目 UX-24 ~ UX-27）

**口径**：允许新增 pub 依赖 / Android 权限 / 后台机制 / 原生通道；仍禁止改宿主机环境、改 `.github/workflows/`、动 AGENTS.md 硬边界、删既有入口。每条须写「为什么非它不可 + 替代对比 + 拒绝授权时的降级路径」。

#### UX-24　悬浮窗常驻通知补「关闭悬浮窗」动作（P1 · 原生改动，复用既有通道）

- **现状（已核实）**：开启点击穿透后窗口 flag 含 `FLAG_NOT_TOUCHABLE`（`third_party/flutter_screen_overlay/android/.../OverlayService.java:66-68`），窗内收不到任何触摸；通知里只有「关闭点击穿透」一个动作（`:390-424`）→ 关一个窗要三步。
- **期望**：`buildOverlayNotification()` 在任何状态下都附「关闭悬浮窗」动作，点击后 `detachOverlayView()` + `stopSelf()` + 撤通知，并经既有下行通道让 Dart 侧收敛状态（先例 `:443-467`）。
- **权限/降级**：不新增权限与后台机制；通知渠道被关 → 动作消失，窗内悬浮球菜单仍是完整出口。
- **验收**：Dart 侧沿用注入下行消息的写法，断言关窗 + 聚合状态上报一次；原生动作项人工验收（开穿透 → 通知栏点「关闭悬浮窗」→ 窗口消失、服务停止、主 App 按钮状态纠正）。
- **PM 评估**：**已核实的确定性缺口、改动最小，建议优先**；若本轮只放 4 个 PR，用它换掉属读代码推断的 UX-20。

#### UX-25　栏位异常 / 开播的本机提醒（P2 · 插件新增自有通道）

- **现状（已核实）**：栏位 `error`（复检预算耗尽）或未开播房间开播时，唯一呈现是**窗内**标识行（`overlay_page.dart:914-951`）；用户离开去干别的就永远看不到。
- **为什么非它不可**：不能写进通知常驻文案（耗电、打断）；主 App 发通知不可靠（常已被杀，连接跑在插件前台服务引擎里）；`flutter_local_notifications` 要求该引擎有插件注册，而本仓库一律把悬浮窗引擎当无插件环境（`_copy` 走 `showData` 代理、`MissingPluginException` 当已授权），失败模式是**静默不提醒**。→ 在插件服务加 `x-slayer/overlay_notify` 通道（约 40 行 `NotificationManagerCompat`），与既有插件侧改动同一先例。
- **期望**：新增 `lib/app/overlay_alerts.dart`（`OverlayAlertSink` 抽象 + 纯逻辑合并节流：同栏 10 分钟一条、全局每分钟一条）；事件源为既有栏位状态上报（`error` 且不可重试）与 `offline → live`；设置页开关「栏位异常 / 开播提醒」（默认开）。
- **权限/降级**：复用已声明的 `POST_NOTIFICATIONS`（三处申请入口已齐，AGENTS §5）；被拒 → 退回窗内 `showOverlayNotice` + 标识行，开关副标题显示「提醒不可用：未授予通知权限」。
- **验收**：`test/overlay_alerts_test.dart` + 假 sink / 假通道：权限被拒不发系统通知、开关关闭不发、同栏 10 分钟内第二次被节流、`offline → live` 发一条且含主播名、通道抛 `MissingPluginException` 不崩；原生部分人工验收。
- ⚠️ 动工前先做一次「悬浮窗引擎能否拿到通道」的冒烟验证。

#### UX-26　App 内查看弹幕时保持屏幕常亮（P2 · 零依赖，复用 `danmu_float/system` 通道）

- **现状（已核实）**：弹幕页无任何常亮处理，系统 30 秒~2 分钟熄屏，读长弹幕要反复点屏。
- **方案**：在既有 `MainActivity.kt` 通道加 `setKeepScreenOn(true/false)`（`window.addFlags/clearFlags`，约 10 行、零依赖、零权限）；不引 `wakelock_plus`——为一句 `FLAG_KEEP_SCREEN_ON` 多一个插件不划算。
- **范围/可关闭**：只在弹幕页**可见**时置位，`dispose` 与生命周期 `paused` 清除；设置页「显示」分区开关（默认开）。
- **验收**：`test/keep_screen_on_test.dart` 挂载 `KeepScreenOnScope`（内含 `@visibleForTesting KeepScreenOnBackend`）即可，**不需要挂 `DanmuPage`**：挂载调 true 一次、卸载 / paused 调 false、假后端抛 `MissingPluginException` 不崩、设置关闭时一次都不调。

#### UX-27　网络状态感知：无网络文案 + 暂停复检预算 + 恢复即补刷（P2 · 新增 pub 依赖）

- **现状（读代码推断）**：无网络时只看到底层异常文案，无法区分「自己断网 / 服务端挂了」；且未开播复检在无网期间照常消耗重试预算与流量。
- **方案**：`connectivity_plus ^7.3.2`（`fluttercommunity.dev`、pub 160/160、Flutter Favorite、近 30 天约 398 万下载；要求 Dart ≥3.2 / Flutter ≥3.7，与仓库兼容）。零依赖替代（把 `SocketException` 归类为疑似断网）改善文案但**拿不到「网络回来了」事件**，故不采用。新增 `ACCESS_NETWORK_STATE`（正常权限、非运行时、无需申请入口）。**悬浮窗引擎不感知**，保持现状。
- **期望**：新增 `lib/net/network_status.dart`（抽象 `NetworkStatusSource`，真实现包 `connectivity_plus`）；无网时提示「当前无网络，已暂停自动复检」且不消耗复检预算；恢复即补一次复检。
- **降级**：查询失败 / `PlatformException` → 完全退回现状（照常按时间复检、按原始错误提示），连接功能不受影响。
- **验收**：`test/network_status_test.dart` 用假源 + 假 transport：无网 → 提示出现且请求次数 0；恢复 → 请求次数 +1 且提示消失；抛 `PlatformException` → 不显示提示、行为如常；正常联网 → 与本轮之前完全一致（防回归）。
- ⚠️ 动工前先做插件注册冒烟验证。

#### 第 5 轮补充：明确不做

1. 开机自恢复悬浮窗（`RECEIVE_BOOT_COMPLETED`）——Android 12+/15 限制 `BOOT_COMPLETED` 启前台服务，本项目的 `specialUse` 不在允许清单内，大概率抛 `ForegroundServiceStartNotAllowedException`；「主 App 冷启动探测并提示恢复」已覆盖同一需求。
2. 引入 `wakelock_plus` 做常亮——与复用既有通道相比无额外收益，只多一份依赖负担。
3. 在悬浮窗引擎里用 `flutter_local_notifications`——能否拿到插件注册要赌，失败模式是静默不提醒。
4. 屏幕常亮做成全局永久置位——与用户对耗电的预期不符。
5. 通知栏磁贴（`TileService`）作为悬浮窗开关——零权限但可发现性极差，收益不抵原生成本。
6. 任何使用数据采集 / 崩溃上报 / 联网统计——与「纯本地、非商业、免登录」定位直接冲突。
7. 上一版已列并维持不做：收敛全局 `textScaler`、删除首页「连接弹幕」按钮、设置页「恢复默认样式」、重做 `OverlayPalette`、给 `DanmuPage` 补全套测试基建、收敛 AppBar 图标。

#### 更新后的 PR 计划

- **已交付**：PR1 / UX-17（#35）、PR2 / UX-18（#36）。
- **待办**：PR3 / UX-19（`danmu_text_colors.dart` + 对比度单测）、PR4 / UX-20 + UX-21（overlay 最小窗）、UX-22（术语）、UX-23（添加反馈 / 清空确认）。
- **新能力（按收益 ÷ 改动面）**：**PR5 / UX-24（P1，建议优先）** → PR6 / UX-26（零依赖）→ PR7 / UX-25（需冒烟）→ PR8 / UX-27（pub 依赖 + 权限）。
- 若本轮只允许 4 个 PR：用 UX-24 换掉 UX-20。**跨文件串行**：`danmu_page.dart` → PR1 → PR3 → UX-23b；`overlay_page.dart` → PR4 → PR5 → UX-22(overlay)；插件 `OverlayService.java` → PR5 → PR7。

### 第 5 轮交付记录（截至 `1550b2a`）

| 条目 | 状态 | 交付说明 |
| --- | --- | --- |
| UX-17 状态栏溢出 | ✅ #35 | 抽出 `lib/ui/danmu_status_bar.dart`（状态行改 `Wrap`，状态词加 `Flexible`），`_buildStatusBar` 退化为「翻译会话状态 → 入参」。**CI 额外逮到**：2 倍系统字号下「状态点 + 状态词」这一组自身溢出 47px（外层 Wrap 救不了内层 Row），已一并修掉；对照组用例确认了「裸 Row 确实溢出」，未降级。 |
| UX-18 首页操作可见入口 | ✅ #36 | `trailing` 追加「更多操作」IconButton，点击走**同一份** `_showRoomActions`，长按保留。 |
| UX-19 深色模式对比度 | ✅ #38 | 新增 `lib/ui/danmu_text_colors.dart`（`secondaryTextColor` / `entryBannerWelcomeColor` / `stageTextColor`），四处硬编码改走它；单测用 `computeLuminance()` 直算 ≥4.5:1，并断言深色下不等于 `Colors.black54`。**未纳入**：PM 报告里同类 12px `Colors.grey` 还散在 `filter_page` / `home_page` / `onboarding_page`，可在 UX-22b 一并处理。 |
| UX-21 悬浮球 / 菜单命中区 | ✅ #39 | 球外套 34×34 命中区（球仍 24dp、闲置不透明度 0.4→0.55），菜单按钮与栏位「重试」`minimumSize` 由 `Size.zero` 改为 `Size(0, 28)`。**刻意不做 48dp**：最小窗 200×150 放不下。 |
| UX-20 最小窗弹窗溢出 | ✅ #40 | 窗内三处 `AlertDialog` 统一 `insetPadding: EdgeInsets.all(8)` + `scrollable: true`；测试用**属性断言**（弹窗对象属性）而非像素位置。**如实标注**：属读代码推断，未复现修复前基线，用例是防回归 + 属性钉死。 |
| UX-23a 过滤页添加反馈 | ✅ #41 | 重复 / 空输入给出 `errorText`（`该词已在列表中` / `请输入内容`）且**不再清空输入框**，只有成功路径才 `clear()` + 回调。 |
| UX-22a 术语（屏蔽词） | ✅ #42 | 「屏蔽关键词」统一为「屏蔽词」（设置页入口 + 过滤页分区 / 说明 / 教程 / 提示），诊断副标题改为「当前样式、凭证来源与悬浮窗状态摘要」；测试补 `findsNothing` 防回退。 |
| UX-22b 术语（直播间 / 栏位） | ⬜ 待做 | 首页 / 表单 / 状态文案的「主播 / 直播间号 / 房间」统一为「直播间」；悬浮窗内「栏位 / 栏」统一为「栏位」。 |
| UX-23b 弹幕页「清空」二次确认 | ⬜ 待做 | 需先给 `DanmuPage` 加 `@visibleForTesting RoomInfoClient? roomInfoClient` 注入口（与 `_OverlayPane` 同款），否则只能人工验收。 |

**本轮两条可复用的经验（后来者别重踩）**：

1. `find.widgetWithText(TextButton, '文案')` 抓不到 `TextButton.icon`——它的运行时类型是私有子类 `_TextButtonWithIcon`，而 `find.byType` 是**精确类型**匹配。改用 `ValueKey` 或 `find.text('文案')`；同时注意同一页可能有多个同名按钮（过滤页三个编辑器各一个「添加」），要 `.first` 或按 key 精确定位。
2. `gh pr create --body "..."` 里出现行内反引号会被 shell 当命令替换、把正文吃坏（本轮与 PR #30 各中一次）。**PR 正文一律用 `--body-file`**。

### 第 5 轮收尾记录（截至本轮 loop 结束）

本轮 loop 共合入 14 个 PR（`#33` ~ `#46`），第 5 轮 UI/交互体检里**所有确定性缺陷**已清空。

| 条目 | 状态 | 交付 |
| --- | --- | --- |
| UX-17 状态栏溢出 | ✅ #35 | 抽 `lib/ui/danmu_status_bar.dart`；CI 额外逮到 2× 字号下「状态点 + 状态词」整组溢出（外层 `Wrap` 救不了内层 `Row`），已一并修 |
| UX-18 首页操作可见入口 | ✅ #36 | `trailing` 补「更多操作」，复用同一份 `_showRoomActions`，长按保留 |
| UX-19 深色模式对比度 | ✅ #38 | 新增 `lib/ui/danmu_text_colors.dart`；单测用 `computeLuminance()` 直算 ≥4.5:1 |
| UX-20 最小窗弹窗溢出 | ✅ #40 | 三处 `AlertDialog` 统一 `insetPadding: 8` + `scrollable: true`；**属性断言**而非像素位置 |
| UX-21 悬浮球 / 菜单命中区 | ✅ #39 | 球外套 34×34 命中区；菜单按钮与栏位「重试」行高 17 → ≥28dp |
| UX-22a 术语（屏蔽词） | ✅ #42 | 「屏蔽关键词」→「屏蔽词」，诊断副标题与实际内容对齐 |
| UX-22b 术语（栏位）+ 灰色文字 | ✅ #44 #45 #46 | 过滤页 / 首页 / 首启 / 免责页的 12px 灰色正文统一走取色表；悬浮窗「N 栏」→「N 个栏位」 |
| UX-23a 过滤页添加反馈 | ✅ #41 | 重复 / 空输入给出 `errorText` 且不再清空输入框 |

**剩余（未动工，按建议顺序）**

1. **UX-24（唯一 P1）**：穿透态通知栏补「关闭悬浮窗」。改动落在 `third_party/flutter_screen_overlay` 的 Android 侧（新增一个通知 action），**仓库 CI 只跑 Dart 的 analyze/test，原生改动拿不到自动化门禁**，必须人工验收：开穿透 → 通知栏点「关闭悬浮窗」→ 窗口消失、前台服务停止、主 App 的开关状态由既有探测路径纠正。合入前请按 AGENTS §3 只做最小必要修改并留说明注释。
2. **UX-23b**：弹幕页「清空」二次确认。需先给 `DanmuPage` 加 `@visibleForTesting RoomInfoClient? roomInfoClient` 注入口（与 `_OverlayPane` 同款），否则「已连接时清空」这条路径在测试里不可达。
3. **UX-22b 尾项**：「主播 / 直播间号 / 房间」三种叫法统一为「直播间」（列表标题保留「主播管理」）；`filter_page.dart:304` 的 `muted ? Colors.grey[700]` 属选中态，需单独判断是否跟随主题。
4. **UX-25 / 26 / 27**：栏位提醒（`x-slayer/overlay_notify`）、屏幕常亮（`MainActivity.kt` + `KeepScreenOnScope`）、网络感知（`connectivity_plus`）。三条都要求先做「悬浮窗引擎能否拿到通道 / 插件注册」的冒烟验证，**验证通过前不要写业务代码**。

**本轮 loop 累计踩坑清单（新接手的人先看这里）**

1. `find.widgetWithText(TextButton, '文案')` 抓不到 `TextButton.icon`（运行时类型是私有子类 `_TextButtonWithIcon`，`find.byType` 是精确类型匹配）；同一页还可能有多个同名按钮（过滤页三个编辑器各一个「添加」），需 `.first` 或 `ValueKey`。
2. `gh pr create --body "..."` 里出现行内反引号会被 shell 当命令替换、把正文吃坏（两次）——**PR 正文一律 `--body-file`**。
3. 把颜色改成 `secondaryTextColor(Theme.of(context).brightness)` 时，**外层不能是 `const` 子树**，否则 `flutter analyze` 报 `const_eval_method_invocation`（过滤页、首页各中一次）；去掉外层 `const` 的同时，要把原先靠常量传播隐式 const 的 `Text` / `SizedBox` / `EdgeInsets` 显式补上 `const`，否则 `prefer_const_constructors` 会让「No issues found」不成立。
4. `OverlayPage` 在 `initState` 订阅静态单订阅流，**每个测试文件只能 mount 一次**；挂载用 `MaterialApp(home: OverlayPage(roomInfoClient: ...))` + 直接注入假客户端即可，无需 `OverlayApp`。

### 第 6 轮：悬浮窗配色体系（UX-28 ~ UX-34）

**问题**：悬浮窗只有「正文」一个元素能上色，且只有 6 个预设（`settings_page.dart` 的 `_paneColorChoices`：白/黄/橙/绿/蓝/粉），按栏存在 `PaneStyle.textColor`（`overlay_bridge.dart:239`）。而 `OverlayPalette`（`overlay_page.dart:64`）其实已有 **11 个纯色角色 + `highlightStyle` + `isLight`**，缺的不是元素，是「把它们暴露给用户」这一层。

**角色 ↔ 可见元素**（`overlay_page.dart` 行号为本轮核对结果）

| 角色 | 代表元素 | 建议 |
| --- | --- | --- |
| `body` | 弹幕正文、进场横幅正文（已有栏级 `textColor` 覆盖） | 开放 |
| `secondary` | 空列表/错误占位、切换箭头、菜单说明、栏位状态、横幅「欢迎」 | 开放 |
| `chrome` | 主播名、菜单分区标题与按钮、悬浮球图标、回溯胶囊、透明度 HUD | 开放 |
| `userAccent` / `levelColor` / `fanLevelColor` | 昵称 / `Lv.N` / 灯牌 N | 开放（最想要） |
| `divider` / `bannerBg` / `border` / `maskColor` | 分隔线 / 进场底色 / 窗口边框 / 窗口底色（再乘不透明度） | 开放，按预设收敛；`maskColor` 参与对比度校验 |
| `activeColor` | 重试按钮、焦点/暂停态图标 | 只随预设，不单独开放（语义=「已生效」） |
| `highlightStyle` | 高亮词前景+底色 | **不开放**：与「高亮词」功能耦合，独立改会让高亮失效 |
| `typeColor(kind)` | 7 类弹幕类型前缀色 | **不开放**：派生自 `isLight` 的 switch，7×2 组合爆炸、收益低 |

**三处已核实的缺口（比扩角色更该先补）**：① 状态点颜色 `_stageColor()` 与 `danmu_text_colors.dart:33` 的 `stageTextColor()` 是**两套并行口径**，应让主题提供 `stageColor` 并两处共用；② 球/菜单/胶囊底色直接写 `white70`/`black54`/`white@0.94`/`black@0.9`，无角色（建议新增 `chromeBg`）；③ `OverlayApp` 未挂 `theme`/`darkTheme`，深色皮肤下弹窗仍是白底——不修这条，「多元素配色」在弹窗层是假的。

**分层模型（不新增第二条取色路径）**：`OverlayTheme`（纯数据，可 JSON 化）→ `resolve(overrides)` 合并元素级覆盖 → `toPalette()` 产出 `OverlayPalette`（widget 仍然只读它）。优先级：预设默认值 → 全局角色覆盖 → 栏级 `PaneStyle.textColor`（只覆盖 `body`）→ 对比度守卫修正。

**4 套预设**：`dark` 深邃（默认）/ `light` 清爽 / `contrast` 高对比（≥7:1）/ `sepia` 护眼暖暗。**硬钉子**：`dark`/`light` 必须与现有 `darkPalette`/`lightPalette` 逐字段相等，默认外观零突变（单测断言）。

**数据模型与迁移**：`OverlayPrefs` 增 `themeId`（默认 `dark`）、`colorOverrides`（角色名→ARGB，空表=全跟随主题）、`recentColors`（≤8）、`contrastPolicy`（`adjust` 默认 / `warn` / `allow`）；`lightTheme` 从存储字段降级为派生 getter（`themeId == 'light'`），`copyWith(lightTheme:)` 参数保留 → 现有调用点零改动。JSON 增写 `schemaVersion: 2`（**只写不分支**）；迁移按「缺字段→推导」处理：无 `themeId` + `lightTheme:false`→`dark`、`true`→`light`（外观与今天一致），`panes[].textColor` 原样保留继续作栏级 body 覆盖，未知 `themeId` 回落 `dark`，非法颜色**逐键丢弃**（不整表弃）。

**可访问性**：默认 `adjust`——保留用户色相与饱和度，只调明度到达标（色相偏移 <15°，由单测钉住），并给一次轻提示；`warn` 在该行常驻显示实测比值；`allow` 只显示比值不干预。断言复用 `computeLuminance()` 现算 `(L1+0.05)/(L2+0.05)`。**已知例外**：浅色预设的 `secondary: Colors.black54` 实测约 4.47:1（低于 4.5），开放给用户前需先决定「修浅色预设」还是「按 warn 处理」。

**刷新与节流**：复用现有 `style` 消息（新增 `themeId`/`colorOverrides` 两个可选字段，缺字段由 `lightTheme` 推导，旧 payload 语义不变），不动 `config`（避免冲掉栏位绑定）；拖动取色期间只下发不落盘（沿用 `persist:false` / `onChangeEnd` 口径），窗内取色只本地 `setState`，点保存才经 `OverlayPrefsPatch` 回报一次；`resolve()` 结果缓存，不在 `build` 里逐行算对比度。

**PR 拆分（建议顺序 A → B → C → E → D → F，G 随 A）**

| # | 条目 | 范围 | 验收断言 | 降级 |
| --- | --- | --- | --- | --- |
| A | UX-28 抽出 `OverlayTheme` | 新增 `lib/ui/overlay_theme.dart` + 单测 | `preset('dark'/'light').toPalette()` 与原 const 逐字段相等；未知 id 回落 `dark`；覆盖生效且非法键忽略；预设对比度达标 | 只落新文件，`OverlayPalette.of` 原样不动（零行为变更） |
| B | UX-29 偏好扩展与迁移 | `lib/storage/overlay_prefs_store.dart` | 4 条旧 JSON 迁移用例；未知 themeId 回落；非法色逐键丢弃；`data_transfer` 往返一致 | `lightTheme` 保留为 getter + `copyWith` 参数 |
| C | UX-30 下发通道 | `overlay_bridge.dart` / `overlay_launcher.dart` / `overlay_page.dart` | 老 payload 解析后由 `lightTheme` 推导；新字段往返；旧进程忽略未知键 | 字段全可选 + `tryParse` 兜底 |
| E | UX-31 对比度守卫 | `lib/ui/overlay_theme.dart` | 全部 `_contrast` 断言（含色相偏移 <15°） | 纯函数，风险最低 |
| D | UX-32 主 App 配色 UI | `lib/ui/settings_page.dart` | chip 选中态；「恢复默认」清空该角色覆盖；最近色 ≤8 且去重 | 保持不混入无关重构 |
| F | UX-33 窗内配色入口 | `overlay_page.dart` / `overlay_bridge.dart`(patch) | 菜单行高 ≥28dp；200×150 弹窗不溢出；确认后 patch 含 `themeId` | 每个测试文件只能 mount 一次 |
| G | UX-34 高对比/护眼预设内容 | `lib/ui/overlay_theme.dart` | 两套预设对比度断言 | 可并入 A 或 E |

**明确不做**：渐变/图片/纹理背景（需自绘 painter，与「蒙版不透明度」语义冲突）；动画或随时间变化的配色（无法静态校验对比度）；栏级多角色覆盖（本轮多角色只做全局，栏级仅保留既有 `textColor`=`body` 覆盖）；引入配色类 pub 依赖（三滑杆自研约 60 行即可，且色环手势会与「位移 >5px 搬窗口」冲突）；系统/壁纸取色（需原生通道与权限）；开放 `typeColor()` 与 `highlightStyle`；改 `third_party` 原生侧（CI 无原生门禁，且本方案不需要）；悬浮窗自动跟随系统深浅色（需新增下发字段与生命周期联动）。

### 第 6 轮 PM 优先级裁决（本轮执行口径，2026-10-16）

**执行顺序**：A ✅ #49 → B → E → C → { H → I（同文件串行）∥ D（`settings_page.dart` 可并行）} → F；**G 已并入 A**（随 #49 交付）。

**插队两项（PM 判定本轮必做）**

- **H 弹窗未跟随主题**：`OverlayApp` 未挂 `theme`/`darkTheme`，深色皮肤下弹窗仍是白底——这是今天唯一用户可见的缺陷，且不修则本轮「多元素配色」在弹窗层是假的。**不能排在 A 之前**：`_lightTheme` 位于 `_OverlayPageState`，改根 widget 的爆炸半径覆盖 `overlay_page_test` / `overlay_pane_*` / `overlay_touch_target` / `overlay_minwindow_dialog` 四个测试文件；等 A/B/C 就位后按 `themeId` 映射 ThemeData 才是数据驱动且可测的。验收：widget 断言「深色皮肤下弹窗 surface 为深色」+ 既有 `overlay_*` 用例零回归。
- **I 状态点两套口径**：把 `overlay_page.dart` 的 `_stageColor()` 改为委托 `OverlayTheme`。**不并入 H**：统一后取值会变（浅色 live 由 `0xFF2E7D32` 变为 `danmu_text_colors.dart` 的 `0xFF1B5E20`），属可见外观变更，必须自带对比度断言与独立 diff。验收：状态点在 4 套预设下取自主题且 ≥4.5:1（复用 E 的口径函数）。

**范围调整**：`recentColors` 字段仍留在 B（迁移成本近零），但 UI 与去重测试推到第 7 轮——D 只做「预设 chips + 每元素跟随/自定义 + 十六进制输入 + 恢复默认」；E 先落唯一口径的 `contrastRatio(fg, bg)`（显式把 fg 的 alpha 展平到 bg 上）与断言，再落 `adjust` 明度校正（色相偏移 <15°）；B 不拆（`lightTheme` 降级为 getter 正是迁移机制本身）；C 不动。

**浅色预设 `secondary` 的裁决**：PM 复算 `Colors.black54`（`0x8A000000`，alpha 0.5412）展平到白底约 **4.61:1**，**高于** 4.5——我在 PR #49 注释里写的 4.47:1 是错的，已改成直接断言且 CI 实测通过。本轮不改浅色外观（改了会破坏 A 的「零突变」钉子）；若该断言将来失败，第 7 轮把它换成 `danmu_text_colors.dart` 的 `0xFF49454F` 并统一两处口径。

**由「缺口」改判为下一轮**：`chromeBg`（球 `white70`/`black54`、菜单 `white@0.94`/`black@0.9`、胶囊 `white70`/`black54` 三处 alpha 各不相同，**一个角色装不下**，须先定 1 个还是 2 个角色及各自在 4 套预设下的取值）；收益仅「允许用户改菜单底色」，优先级低于 H/I。
