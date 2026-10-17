// 首页悬浮窗状态收敛（PM-001）与「移除主播即卸载其栏位」（PM-002）。
//
// 不依赖任何原生通道：本地存储用临时目录解析器注入、凭证用内存后端，插件窗口
// 查询通道用 mock 应答。悬浮窗上报经 overlay_launcher 的测试辅助直接驱动首页监听分支。
import 'dart:async';
import 'dart:io';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/system/system_permissions.dart';
import 'package:danmu_float/ui/home_page.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的窗口控制通道名（third_party/flutter_screen_overlay）。
const MethodChannel _overlayControlChannel = MethodChannel(
  'x-slayer/overlay_channel',
);

/// 插件的窗口尺寸通道名（`resizeOverlay` 走它）。
///
/// 该通道的 handler 只注册在**悬浮窗引擎**（OverlayService）：主引擎直调必然抛
/// MissingPluginException，所以主 App 改尺寸只能经消息通道转给悬浮窗引擎执行。
/// 这里仍然挂上 mock，用来断言主 App 没有去直调它。
const MethodChannel _overlaySizeChannel = MethodChannel('x-slayer/overlay');

/// 记录尺寸通道上调过的插件方法（主 App 不该调它，PM-002 回归断言用）。
final List<MethodCall> _sizeCalls = <MethodCall>[];

/// 记录主 App 经消息通道发出去的载荷（改尺寸 / 凭证 / 配置都走它）。
final List<Object?> _sentMessages = <Object?>[];

/// 插件的双向消息通道名：主 App 下发的 config / credential / close 都经它 send 出去。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

/// 计数用的主播列表存储：断言「整批刷完只落盘一次」（UX-11）。
class _CountingRoomStore extends RoomStore {
  _CountingRoomStore({required super.directoryResolver});

  int saves = 0;

  @override
  Future<void> save(List<ManagedRoom> rooms) async {
    saves++;
    await super.save(rooms);
  }
}

/// 可挂起的假客户端：请求会停在 [gate] 上不返回，用来制造「在飞」窗口（UX-13）。
class _SuspendingRoomInfoClient extends _FakeRoomInfoClient {
  /// 记录真正发起过的请求；[_FakeRoomInfoClient.calls] 要等请求放行后才记，
  /// 这里要的是「飞行中」的计数。
  final List<String> started = <String>[];

  /// 非空时所有请求都挂在这里，直到测试放行。
  Completer<void>? gate;

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    started.add(webRid);
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    return super.fetchByWebRid(webRid, credentialCookies: credentialCookies);
  }
}

/// 给消息通道挂一个「立即应答」的 handler（PM-002 用）。
///
/// `FlutterScreenOverlay.shareData` 内部是 `BasicMessageChannel.send`，会 await
/// 原生侧回包；测试里没有真实原生侧，不挂 handler 这个 await 永远不会返回，
/// 整个移除流程就挂死在 10 分钟超时上。
void _mockMessengerReplies(WidgetTester tester) {
  _sentMessages.clear();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler(
    _messengerChannel.name,
    (ByteData? message) async {
      _sentMessages.add(const JSONMessageCodec().decodeMessage(message));
      return message;
    },
  );
  addTearDown(
    () => messenger.setMockMessageHandler(_messengerChannel.name, null),
  );
}

/// 给 path_provider 挂临时目录应答（PM-002 用）。
///
/// 首页 initState 里 `_loadFilter()` 走的 FilterStore 是默认构造，无法注入目录
/// 解析器、经 path_provider 原生通道取目录；测试里不挂 mock 会在 runAsync 排空
/// 真实事件循环时抛 MissingPluginException，打断整个移除流程。统一指到同一个
/// 临时目录，与注入的 RoomStore / OverlayPrefsStore 隔离在测试目录内。
void _mockPathProvider(WidgetTester tester, Directory dir) {
  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    channel,
    (MethodCall call) async => dir.path,
  );
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

/// 内存凭证后端：测试不依赖 flutter_secure_storage 原生通道。
class _MemoryCredentialBackend implements CredentialBackend {
  String? _stored;

  @override
  Future<String?> read() async => _stored;

  @override
  Future<void> write(String value) async => _stored = value;

  @override
  Future<void> delete() async => _stored = null;
}

/// 删除必失败的凭证后端：模拟清除本地数据时密文删不掉（#92）。
class _FailingDeleteCredentialBackend implements CredentialBackend {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}

  @override
  Future<void> delete() async => throw const FileSystemException('denied');
}

/// 假房间信息客户端：记录调用顺序，一律返回「直播中」。
///
/// 刷新相关用例（UX-04）靠它隔离网络，并断言批量刷新是串行、每个主播只刷一次。
class _FakeRoomInfoClient extends RoomInfoClient {
  final List<String> calls = <String>[];

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    calls.add(webRid);
    return RoomInfo(
      living: true,
      isLiveRadio: false,
      webRid: webRid,
      liveId: '7$webRid',
      owner: '主播$webRid',
      title: '标题$webRid',
      avatar: '',
      cover: '',
      secUid: 'sec',
      api: RoomInfoApi.web,
    );
  }
}

/// 临时目录解析器：把 RoomStore / OverlayPrefsStore 的落盘指向临时目录，
/// 不依赖 path_provider 原生通道，也不读写真实应用数据。
Future<Directory> Function() _tempResolver() {
  final Directory dir =
      Directory.systemTemp.createTempSync('danmu_float_home_test');
  return () async => dir;
}

/// 记录主 App 调过的插件方法（PM-002 用：断言走了 resize / close 路径）。
final List<MethodCall> _overlayCalls = <MethodCall>[];

/// 向插件的窗口查询通道注入 mock：isActive 按 [active] 应答，权限按
/// [permissionGranted] 应答（UX-16 用它模拟「拒绝且不再询问」），建窗 / 关窗 /
/// 改尺寸一律记进 [_overlayCalls] 后返回，保证测试不会真的去动窗口，
/// 也不会因方法名不完全匹配而抛错导致异步挂起。
void _mockOverlayChannels(
  WidgetTester tester, {
  required bool active,
  bool permissionGranted = true,
}) {
  _overlayCalls.clear();
  _sizeCalls.clear();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_overlayControlChannel,
      (MethodCall call) async {
    _overlayCalls.add(call);
    switch (call.method) {
      case 'isOverlayActive':
        return active;
      case 'checkPermission':
        return permissionGranted;
      case 'requestPermission':
        // 权限查询走插件通道（不经 systemPermissions），所以「不再弹框」要在这里模拟。
        return permissionGranted;
      default:
        return false;
    }
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_overlayControlChannel, null),
  );
  // 尺寸通道仍然 mock 上：主 App 不该再直调它（handler 只注册在悬浮窗引擎），
  // 挂上是为了把「误调」记录成断言失败，而不是让它抛 MissingPluginException
  // 之后被上层 catch 掩盖成假绿。
  messenger.setMockMethodCallHandler(_overlaySizeChannel, (MethodCall call) async {
    _sizeCalls.add(call);
    return true;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_overlaySizeChannel, null),
  );
}

/// 悬浮窗权限被「拒绝且不再询问」的假后端（UX-16）：请求也不再弹框，只能去系统设置。
class _DeniedOverlayPermissionBackend implements SystemPermissionBackend {
  int settingsOpens = 0;

  @override
  Future<bool> hasOverlayPermission() async => false;

  @override
  Future<bool> requestOverlayPermission() async => false;

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<bool> isBatteryOptimizationIgnored() async => true;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async {}

  @override
  Future<void> openAppSettings() async => settingsOpens++;
}

Future<void> _pumpHome(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: HomePage(
      directoryResolver: _tempResolver(),
      credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
    ),
  ));
  // 首页 build 里会因窗口尺寸同步排 post-frame 回调（见 _syncWindowSizeWithScreen），
  // 不能用 pumpAndSettle —— 它会因持续的 post-frame 回调永远不空闲而超时。
  // 改为推进一段固定虚拟时间：覆盖各 store 的异步加载与 1s 的状态探测延时常量。
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 2));
}

/// 在临时目录里预置主播列表与栏位偏好，供移除场景使用。
///
/// save/load 是真实文件 I/O：testWidgets 的用例体跑在 FakeAsync zone 里，
/// 直接 await 永远等不到完成回调（10 分钟超时的根因），必须经
/// [WidgetTester.runAsync] 逃出 FakeAsync 真实执行。
Future<Directory> _seedRooms(
  WidgetTester tester, {
  required List<ManagedRoom> rooms,
  required List<String> boundWebRids,
}) async {
  final Directory dir =
      Directory.systemTemp.createTempSync('danmu_float_home_test');
  addTearDown(() => dir.deleteSync(recursive: true));
  await tester.runAsync(() async {
    await RoomStore(directoryResolver: () async => dir).save(rooms);
    await OverlayPrefsStore(directoryResolver: () async => dir)
        .save(OverlayPrefs(webRids: boundWebRids));
  });
  return dir;
}

/// 等待 [condition] 成立：在 runAsync 排空真实事件循环（让 widget 内部 await 的
/// 真实文件 I/O 走完）后 pump 一帧处理 setState，直到条件满足或超时。
///
/// 固定 sleep 一次在 CI 冷 I/O 下不可靠（首轮 CI 200ms 后列表仍未渲染出来），
/// 改为轮询：每次排空 50ms 真实时间再 pump，共给到约 5s 预算。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (int i = 0; i < 100 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 无条件推进若干轮「真实时间 + pump」，用于没有可观察条件的真实文件 I/O。
///
/// 与 [_pumpUntil] 同款理由：`await` 链的每一跳都要先排真实事件循环、再 pump 一次才能
/// 落地。设置页回归用例里首页的读盘 / 落盘都没有 UI 可观察量，只能按轮数推进。
Future<void> _drainRealIo(WidgetTester tester, {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 模拟前后台切换：框架从 `flutter/lifecycle` 渠道接收状态，测试里发同一条消息即可。
///
/// 刻意先发 inactive 再发 resumed：测试进程初始就是 resumed，同状态可能被框架视为
/// 无变化而忽略。
Future<void> _lifecycle(WidgetTester tester, String state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.lifecycle.name,
    const StringCodec().encodeMessage('AppLifecycleState.$state'),
    (ByteData? _) {},
  );
  await tester.pump();
}

/// 把首页挂到指定目录上：与 _pumpHome 同样的注入口径，只是目录换成预置好的。
Future<void> _pumpHomeWithDir(WidgetTester tester, Directory dir) async {
  await tester.pumpWidget(MaterialApp(
    home: HomePage(
      directoryResolver: () async => dir,
      credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
    ),
  ));
  // 首页 initState 里 unawaited(_load()) 的真实文件读也在 FakeAsync 里等待，
  // pump 推不动它：轮询排空真实事件循环直到预置的主播渲染出来。
  await _pumpUntil(tester, () => find.text('主播甲').evaluate().isNotEmpty);
  // 再等「关闭悬浮窗」入口出现：它由 _reconcileOverlayVisible 的通道探测驱动，
  // 同时意味着 _loadPrefs 的真实读盘也已完成——_unbindRoomFromOverlay 依赖
  // _prefs.webRids，prefs 未就绪时移除会静默跳过重排。
  await _pumpUntil(
    tester,
    () => find.byTooltip('关闭悬浮窗').evaluate().isNotEmpty,
  );
}

/// 模拟「已建窗」的全局状态：真实取值来自建窗动作，测试里直接置位。
void _markOverlayShown() {
  setOverlayShownForTest(true);
  addTearDown(() => setOverlayShownForTest(false));
}
/// 放大测试视口（PM-002 用）：默认 800×600 下底部菜单里的「移除主播」
/// （Offset y≈635）落在视口外，tap 打不中。把高度提到 1200 让整个
/// bottom sheet 与确认对话框都可见可点。用完须恢复，避免影响其他用例。
Future<void> _withTallViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('「重试授权」仍被拒后 banner 补「去系统设置」出口（UX-16）',
      (WidgetTester tester) async {
    // 系统在「拒绝且不再询问」后不再弹框：只留「重试授权」就是一条走不通的路。
    // 权限查询走插件通道（FlutterScreenOverlay），所以要在通道这一层把权限置为拒绝。
    _mockOverlayChannels(tester, active: false, permissionGranted: false);
    final _DeniedOverlayPermissionBackend backend =
        _DeniedOverlayPermissionBackend();
    setSystemPermissionBackend(backend);
    addTearDown(
      () => setSystemPermissionBackend(const PlatformSystemPermissionBackend()),
    );

    await _pumpHome(tester);
    expect(
      find.text('悬浮窗权限未授予，当前仅能在 App 内查看'),
      findsOneWidget,
      reason: '权限被拒时 banner 是常驻的',
    );
    expect(
      find.text('去系统设置'),
      findsNothing,
      reason: '还没重试过，不必先给次级出口',
    );

    await tester.tap(find.widgetWithText(TextButton, '重试授权'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.text('去系统设置'),
      findsOneWidget,
      reason: '重试仍被拒时要给出真能走通的入口（AGENTS.md 第 5 节）',
    );
    await tester.tap(find.widgetWithText(TextButton, '去系统设置'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.settingsOpens, 1, reason: '点一次要真的跳一次系统设置');
  });

  testWidgets('悬浮窗由弹幕页开启（本页没开过）时，首页仍显示关闭入口（PM-001）',
      (WidgetTester tester) async {
    _mockOverlayChannels(tester, active: true);

    await _pumpHome(tester);

    expect(
      find.byTooltip('关闭悬浮窗'),
      findsOneWidget,
      reason: '悬浮窗真实存在时，首页必须提供关闭入口',
    );
  });

  testWidgets('悬浮窗未开启时，首页不显示关闭入口（PM-001 回归）',
      (WidgetTester tester) async {
    _mockOverlayChannels(tester, active: false);

    await _pumpHome(tester);

    expect(find.byTooltip('关闭悬浮窗'), findsNothing);
  });

  testWidgets('悬浮窗上报活跃栏位绑定后，首页补上已开启状态（PM-001）',
      (WidgetTester tester) async {
    _mockOverlayChannels(tester, active: false);

    await _pumpHome(tester);
    expect(find.byTooltip('关闭悬浮窗'), findsNothing);

    // 悬浮窗引擎完成配置装载并开始周期上报（弹幕页开的单栏窗同样会上报）。
    pushOverlayStatusForTest(const OverlayStatus(
      stage: LiveSessionStage.live,
      received: 10,
      webRids: <String>['12345'],
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.byTooltip('关闭悬浮窗'),
      findsOneWidget,
      reason: '有活跃栏位绑定的上报说明窗口活着，首页应出现关闭入口',
    );
  });

  testWidgets('设置页只写回自己改过的字段，不冲掉窗内刚改的偏好（#97 回归）',
      (WidgetTester tester) async {
    // 加高屏幕：设置页很长，目标开关要能直接点到，免得滚动把点击位置带偏。
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory dir =
        Directory.systemTemp.createTempSync('danmu_float_settings_merge');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    _mockOverlayChannels(tester, active: true);
    _mockPathProvider(tester, dir);

    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        directoryResolver: () async => dir,
        credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 2));
    // 首页 initState 的读盘与随后的落盘都是真实文件 I/O，且每一步 await 都要
    // 「排真实时间 + pump」才能推进（FakeAsync 里 pump 单独推不动真实 I/O）。
    // 先把它彻底跑完再动页面，否则残余的读回会把后面的内存改动覆盖成磁盘旧值。
    await _drainRealIo(tester);

    // 进设置页：它此刻拍下一份偏好快照，之后的改动都基于这份快照。
    await _pumpUntil(
      tester,
      () => find.byTooltip('设置').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('设置'));
    await _pumpUntil(
      tester,
      () => find.byType(SettingsPage).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(seconds: 1));

    // 用户在悬浮球菜单里把透明度调到 0.2：主 App 实时更新权威值并落盘。
    pushOverlayStatusForTest(const OverlayStatus(
      stage: LiveSessionStage.idle,
      received: 0,
      prefsPatch: OverlayPrefsPatch(opacity: 0.2),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    // 同样排空：让这次窗内改动的落盘链跑完，免得它与下面设置页的落盘交错。
    await _drainRealIo(tester, rounds: 10);

    // 接着在设置页里改一个与透明度无关的开关。
    final Finder titleBarSwitch = find.descendant(
      of: find.widgetWithText(ListTile, '显示栏目标识'),
      matching: find.byType(Switch),
    );
    await _pumpUntil(tester, () => titleBarSwitch.evaluate().isNotEmpty);
    // 设置页是长列表，目标开关可能在首屏之外：先滚到它再点。
    await tester.ensureVisible(titleBarSwitch);
    await tester.pump();
    final bool before = tester.widget<Switch>(titleBarSwitch).value;
    await tester.tap(titleBarSwitch);
    await tester.pump();

    // 落盘同样是多步真实 I/O：推进到写完，再读回偏好文件。
    await _drainRealIo(tester, rounds: 10);
    final OverlayPrefs? saved = await tester.runAsync(
      () => OverlayPrefsStore(directoryResolver: () async => dir).load(),
    );

    expect(
      saved!.opacity,
      0.2,
      reason: '窗内刚调的透明度不能被设置页的进页快照覆盖回旧值',
    );
    expect(
      saved.showTitleBar,
      !before,
      reason: '设置页里这次真正改动的开关要生效',
    );
  });

  testWidgets('权限撤销上报后，首页关闭入口消失并显示降级提示（PM-001 回归）',
      (WidgetTester tester) async {
    _mockOverlayChannels(tester, active: true);

    await _pumpHome(tester);
    expect(find.byTooltip('关闭悬浮窗'), findsOneWidget);

    pushOverlayStatusForTest(const OverlayStatus(
      stage: LiveSessionStage.error,
      received: 0,
      error: '悬浮窗权限已被撤销，已断开全部连接',
      permissionRevoked: true,
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.byTooltip('关闭悬浮窗'), findsNothing);
    expect(
      find.text('悬浮窗权限未授予，当前仅能在 App 内查看'),
      findsOneWidget,
      reason: '权限被撤销后应出现降级常驻提示',
    );
  });

  testWidgets('悬浮窗在窗内被关掉后，首页撤掉关闭入口（P2 回归）',
      (WidgetTester tester) async {
    _mockOverlayChannels(tester, active: true);

    await _pumpHome(tester);
    expect(find.byTooltip('关闭悬浮窗'), findsOneWidget);

    // 悬浮球菜单关窗：悬浮窗引擎在关窗前补发一次带 closed 的聚合状态。
    pushOverlayStatusForTest(const OverlayStatus(
      stage: LiveSessionStage.idle,
      received: 0,
      closed: true,
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.byTooltip('关闭悬浮窗'),
      findsNothing,
      reason: '窗口已被悬浮窗自己关掉，首页不该再显示关闭入口',
    );
  });

  testWidgets('主播行的「更多操作」把长按里的三个入口变成可见入口（UX-18）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ManagedRoom(
          webRid: '222',
          name: '主播乙',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    await _withTallViewport(tester);

    await _pumpHomeWithDir(tester, dir);

    // 可见入口是「每行一个」：两个主播就该有两个，不能再靠长按去猜。
    expect(find.byTooltip('更多操作'), findsNWidgets(2));

    // 点可见入口必须打开与长按同一份菜单——分组 / 凭证 / 移除三条都在；
    // 动画推满 500ms 再断言（同 _pumpHome 的理由，pumpAndSettle 在首页不收敛）。
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('设置分组'), findsOneWidget);
    expect(find.text('使用凭证'), findsOneWidget);
    expect(find.text('移除主播'), findsOneWidget);
  });

  testWidgets('窄屏（360dp）下标题列仍有可用宽度，副标题不折断（#148 / UX-18）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          // 19 位 webRid：room_link_parser 记录的网页端常见长度。
          webRid: '7350000000000000001',
          // 名字故意长到会被省略：这样标题的渲染框宽度就等于整列可用宽度，
          // getRect 量到的才是「标题列」而不是文字本身。
          name: '一个非常长的主播名字用来撑满整列宽度',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    // 360dp 是空间最紧的常见机型。原来的口径只要求「不溢出」，结果标题列被
    // 两个文字按钮压到 ~80dp，19 位 webRid 从中间折断（#148）；这里改成宽度下限。
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpHomeWithDir(tester, dir);

    expect(tester.takeException(), isNull, reason: '不溢出是底线，不是全部口径');
    expect(find.byTooltip('更多操作'), findsOneWidget);
    expect(find.byTooltip('刷新'), findsOneWidget, reason: '行内刷新入口不能丢');

    // 标题列（ListTile 给 title/subtitle 的宽度）必须够读：≥140dp。
    final Rect titleRect =
        tester.getRect(find.text('一个非常长的主播名字用来撑满整列宽度'));
    expect(
      titleRect.width,
      greaterThanOrEqualTo(140),
      reason: '「不溢出」不等于「还能读」：19 位 webRid 需要 ~127dp（#148）',
    );

    // 副标题里的 webRid 必须单行：从数字中间折断会把开播状态挤成孤儿行。
    final Size webRidSize = tester.getSize(find.text('7350000000000000001'));
    expect(
      webRidSize.height,
      lessThanOrEqualTo(20),
      reason: 'webRid 一行放不下就省略，不能再折成两行（#148）',
    );
  });

  testWidgets('系统大字号（1.5x）+ 360dp 下仍不溢出，标题列不被压垮（#148）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '一个非常长的主播名字用来撑满整列宽度',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    // 行内改成图标按钮后，trailing 的固有宽度不再随字号增长——这是本条的做法能
    // 扛住大字号的原因，用测试钉住它。
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pumpHomeWithDir(tester, dir);

    expect(tester.takeException(), isNull, reason: '大字号下不能溢出（UX-17 同类风险）');
    expect(
      tester.getRect(find.text('一个非常长的主播名字用来撑满整列宽度')).width,
      greaterThanOrEqualTo(140),
      reason: '图标按钮宽度固定，标题列不该被系统字号进一步压缩',
    );
  });

  testWidgets('「更多操作」菜单仍能到达刷新 / 连接弹幕 / 分组 / 凭证 / 移除（#148）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    await _withTallViewport(tester);

    await _pumpHomeWithDir(tester, dir);
    await _pumpUntil(
      tester,
      () => find.byTooltip('更多操作').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 收敛入口 ≠ 删入口：每个动作都还有可见入口（行内图标或本菜单）。
    for (final String label in <String>[
      '刷新',
      '连接弹幕',
      '设置分组',
      '使用凭证',
      '移除主播',
    ]) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '「$label」必须仍能从可见入口到达（AGENTS.md 第 5 节）',
      );
    }
  });

  testWidgets('移除正在悬浮窗显示的主播时，重排栏位并不再绑定它（PM-002）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ManagedRoom(
          webRid: '222',
          name: '主播乙',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>['111', '222'],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    await _withTallViewport(tester);

    await _pumpHomeWithDir(tester, dir);
    expect(find.text('主播甲'), findsOneWidget);
    expect(find.text('主播乙'), findsOneWidget);
    _overlayCalls.clear();

    // 长按主播甲 → 弹底部菜单 → 移除主播 → 二次确认。
    // 底部菜单 / 对话框各有约 200ms 的入场动画，pump 100ms 时 sheet 还在
    // 视口下方滑入途中，tap 会打不中（首轮 CI 的 hit-test warning）；这里把
    // 每个动画都推满（500ms），不用 pumpAndSettle（同 _pumpHome 的理由）。
    await tester.longPress(find.text('主播甲'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('移除主播'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('移除'));
    // 移除的 setState（列表项消失）发生在 await _store.save 之前，而重排 / 关窗
    // 在真实落盘完成之后才会执行：必须轮询等到插件调用真正出现，不能只等 UI。
    // （等待上限同样来自 _pumpUntil 的轮询预算，超时即按断言失败报告。）
    await _pumpUntil(
      tester,
      () => _sentMessages.any(
        (Object? message) => OverlayResize.tryParse(message) != null,
      ),
    );

    expect(find.text('主播甲'), findsNothing, reason: '主播甲应从列表移除');

    // 走了重排（resize）而不是关窗：还剩一栏可显示。
    expect(
      _sentMessages.any(
        (Object? message) => OverlayResize.tryParse(message) != null,
      ),
      isTrue,
      reason: '移除后应按剩余栏位重排，卸载被删主播那一栏',
    );
    expect(
      _overlayCalls.any((MethodCall call) => call.method == 'closeOverlay'),
      isFalse,
      reason: '还有剩余栏位，不应关窗',
    );
    // 尺寸只能经消息通道交给悬浮窗引擎执行：主引擎没有 `x-slayer/overlay` 的
    // handler，直调会抛 MissingPluginException，而且异常发生在下发配置之前，
    // 重排时房间绑定根本下不去。
    expect(
      _sizeCalls,
      isEmpty,
      reason: '主 App 不得直调只有悬浮窗引擎才注册的尺寸通道',
    );

    // 落盘的栏位绑定里也不再含被移除的主播。save 是 unawaited 的真实文件写，
    // 且 writeAsString 先截断再写入：赶上截断窗口会读到空内容，所以等待条件
    // 必须是「读到期望值」而不是「不含旧值」，空读一律继续等。
    OverlayPrefs persisted = const OverlayPrefs();
    bool hasExpected(List<String> webRids) =>
        webRids.length == 1 && webRids.first == '222';
    for (int i = 0; i < 20 && !hasExpected(persisted.webRids); i++) {
      await tester.runAsync(() async {
        persisted =
            await OverlayPrefsStore(directoryResolver: () async => dir).load();
        if (!hasExpected(persisted.webRids)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
    }
    expect(persisted.webRids, <String>['222'],
        reason: '落盘的栏位绑定应只剩主播乙');
  });

  testWidgets('移除最后一栏时直接关掉悬浮窗（PM-002）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>['111'],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    await _withTallViewport(tester);

    await _pumpHomeWithDir(tester, dir);
    _overlayCalls.clear();

    await tester.longPress(find.text('主播甲'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('移除主播'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('移除'));
    // 同上：等真实落盘完成、关窗调用真正发出（不能只等 UI 状态变化）。
    await _pumpUntil(
      tester,
      () => _overlayCalls.any(
        (MethodCall call) => call.method == 'closeOverlay',
      ),
    );

    // 没有剩余栏位可下发：走关窗，而不是下发空绑定的 config。
    // closeOverlay 走控制通道（_overlayCalls）；尺寸改由消息通道下发后，
    // 尺寸通道（_sizeCalls）不该再被主 App 调用。
    expect(
      _overlayCalls.any((MethodCall call) => call.method == 'closeOverlay'),
      isTrue,
      reason: '最后一栏被移除后应关窗，避免留下空窗',
    );
    expect(
      find.byTooltip('关闭悬浮窗'),
      findsNothing,
      reason: '窗口已关闭，不该再显示关闭入口',
    );
  });

  group('formatRefreshedAgo', () {
    final DateTime now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    test('未刷新过（null / 非正数）返回空串，行内不显示这一行', () {
      expect(formatRefreshedAgo(null, now: now), '');
      expect(formatRefreshedAgo(0, now: now), '');
      expect(formatRefreshedAgo(-5, now: now), '');
    });

    test('按分钟 / 小时 / 天分档给出相对时间', () {
      int ago(Duration duration) =>
          now.subtract(duration).millisecondsSinceEpoch;

      expect(formatRefreshedAgo(ago(const Duration(seconds: 5)), now: now), '刚刚');
      expect(
        formatRefreshedAgo(ago(const Duration(minutes: 3)), now: now),
        '3 分钟前',
      );
      expect(
        formatRefreshedAgo(ago(const Duration(hours: 5)), now: now),
        '5 小时前',
      );
      expect(formatRefreshedAgo(ago(const Duration(days: 2)), now: now), '2 天前');
    });

    test('时间戳比当前时间还新（时钟回拨）时按「刚刚」处理，不显示负数', () {
      expect(
        formatRefreshedAgo(
          now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
          now: now,
        ),
        '刚刚',
      );
    });
  });

  group('isRoomStale', () {
    const int now = 1700000000000;

    test('从没刷过（null / 非正数）算过期', () {
      expect(isRoomStale(null, now: now), isTrue);
      expect(isRoomStale(0, now: now), isTrue);
      expect(isRoomStale(-1, now: now), isTrue);
    });

    test('阈值内不算过期：回前台不该重复请求刚刷过的主播（UX-10）', () {
      expect(isRoomStale(now - 60 * 1000, now: now), isFalse);
      expect(
        isRoomStale(now - staleRoomRefreshAfter.inMilliseconds, now: now),
        isFalse,
        reason: '刚好等于阈值仍算新鲜，边界取「超过」而不是「达到」',
      );
      expect(
        isRoomStale(now - staleRoomRefreshAfter.inMilliseconds - 1, now: now),
        isTrue,
      );
    });

    test('时钟回拨（时间戳比现在新）不触发补刷', () {
      expect(isRoomStale(now + 5000, now: now), isFalse);
    });

    test('失败路径也要节流：距上次「尝试」超过阈值才允许再试（UX-13）', () {
      expect(
        shouldAttemptStaleRefresh(null, now: now),
        isTrue,
        reason: '从没试过就允许试',
      );
      expect(
        shouldAttemptStaleRefresh(now - 60 * 1000, now: now),
        isFalse,
        reason: '刚试过（哪怕失败了）不该再打一遍接口',
      );
      expect(
        shouldAttemptStaleRefresh(
          now - staleRoomRefreshAfter.inMilliseconds,
          now: now,
        ),
        isFalse,
        reason: '刚好等于窗口仍算「刚试过」',
      );
      expect(
        shouldAttemptStaleRefresh(
          now - staleRoomRefreshAfter.inMilliseconds - 1,
          now: now,
        ),
        isTrue,
      );
    });
  });

  testWidgets('「刷新全部」串行刷新每个主播，并把刷新时间落盘（UX-04）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(webRid: '735', name: '主播甲', addedAt: 1700000000),
        ManagedRoom(webRid: '736', name: '主播乙', addedAt: 1700000000),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);
    _mockMessengerReplies(tester);

    final _CountingRoomStore store = _CountingRoomStore(
      directoryResolver: () async => dir,
    );
    final _FakeRoomInfoClient client = _FakeRoomInfoClient();
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        directoryResolver: () async => dir,
        credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
        roomInfoClient: client,
        store: store,
      ),
    ));
    await _pumpUntil(tester, () => find.text('主播甲').evaluate().isNotEmpty);
    // 排掉 initState 里的悬浮窗存活探测延时常量（1s），否则用例结束时它还在等。
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('已刷新 刚刚'), findsNothing, reason: '还没刷新过，不显示刷新时间');

    await tester.tap(find.byTooltip('刷新全部'));
    await _pumpUntil(
      tester,
      () => find.textContaining('已刷新全部').evaluate().isNotEmpty,
    );

    expect(client.calls, <String>['735', '736'], reason: '串行按列表顺序各刷一次');
    expect(
      store.saves,
      1,
      reason: '整批刷完只落盘一次：逐条写会把 rooms.json 写 N 次（UX-11）',
    );
    expect(find.textContaining('直播中'), findsNWidgets(2));
    expect(find.text('已刷新 刚刚'), findsNWidgets(2));

    // 刷新时间要落盘：冷启动读回本地列表时行内仍能看出数据新旧。
    final List<ManagedRoom> saved =
        await tester.runAsync(
          () => RoomStore(directoryResolver: () async => dir).load(),
        ) ??
        const <ManagedRoom>[];
    expect(saved.length, 2);
    expect(
      saved.every((ManagedRoom room) => (room.lastRefreshedAt ?? 0) > 0),
      isTrue,
      reason: '刷新成功的时间必须写进 rooms.json',
    );

    // 排掉 SnackBar 的自动消失定时器与退场动画，避免用例结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('回前台只补刷过期房间：阈值内不重复、整批只落盘一次（UX-10 / UX-11 / UX-13）',
      (WidgetTester tester) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '735',
          name: '主播甲',
          addedAt: 1700000000,
          // 过期：距上次成功刷新已超过阈值。
          lastRefreshedAt: now - staleRoomRefreshAfter.inMilliseconds - 60000,
        ),
        ManagedRoom(
          webRid: '736',
          name: '主播乙',
          addedAt: 1700000000,
          // 刚刷过：阈值内，回前台不该再打一次接口。
          lastRefreshedAt: now,
        ),
        ManagedRoom(
          webRid: '737',
          name: '主播丙',
          addedAt: 1700000000,
          // 从没刷过：也算过期。
          lastRefreshedAt: 0,
        ),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);
    _mockMessengerReplies(tester);

    final _CountingRoomStore store = _CountingRoomStore(
      directoryResolver: () async => dir,
    );
    final _FakeRoomInfoClient client = _FakeRoomInfoClient();
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        directoryResolver: () async => dir,
        credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
        roomInfoClient: client,
        store: store,
      ),
    ));
    await _pumpUntil(tester, () => find.text('主播甲').evaluate().isNotEmpty);
    // 排掉 initState 里的悬浮窗存活探测延时常量（1s）。
    await tester.pump(const Duration(seconds: 2));
    client.calls.clear();
    _sentMessages.clear();

    // 进后台再回前台：首页据此静默补刷过期房间。
    await _lifecycle(tester, 'inactive');
    await _lifecycle(tester, 'resumed');
    await _pumpUntil(
      tester,
      () => find.text('已刷新 刚刚').evaluate().length == 3,
    );

    expect(
      client.calls,
      <String>['735', '737'],
      reason: '只补刷过期的两栏；阈值内的 736 不该被重复请求',
    );

    // 落盘发生在各条刷新之后，等它真正发生再断言：UI 更新早于 save，抢时序会读到 0。
    await _pumpUntil(tester, () => store.saves >= 1);
    expect(
      store.saves,
      1,
      reason: '补刷整批只落盘一次（UX-11）',
    );
    // 悬浮窗没开时 `_syncOverlayRooms` 直接返回、一条都不推：这里锁的是「不逐条推」，
    // 所以上限是 1 而不是恰好 1（开窗场景由 UX-04 用例覆盖）。
    expect(
      _sentMessages
          .where(
            (Object? message) => message is Map && message['type'] == 'rooms',
          )
          .length,
      lessThanOrEqualTo(1),
      reason: '每批最多推送一次悬浮窗候选（UX-13）',
    );

    // 同一节流窗口内再回前台不重复补刷：失败路径不写 lastRefreshedAt，
    // 只按它判断的话弱网下每次回前台都会把整列表重打一遍（UX-13）。
    await _lifecycle(tester, 'inactive');
    await _lifecycle(tester, 'resumed');
    await tester.pump(const Duration(seconds: 2));
    expect(client.calls, <String>['735', '737'], reason: '窗口内不重复补刷');

    // 排掉 SnackBar 与存活探测定时器，避免用例结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('补刷在飞时不再发第二条同主播请求（UX-13）', (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        // 从没刷过 → 回前台必定补刷。
        ManagedRoom(webRid: '735', name: '主播甲', addedAt: 1700000000),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);
    _mockMessengerReplies(tester);

    final _SuspendingRoomInfoClient client = _SuspendingRoomInfoClient();
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        directoryResolver: () async => dir,
        credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
        roomInfoClient: client,
      ),
    ));
    await _pumpUntil(tester, () => find.text('主播甲').evaluate().isNotEmpty);
    await tester.pump(const Duration(seconds: 2));

    // 挂住补刷的那条请求：该主播此刻正有一路在飞。
    client.gate = Completer<void>();
    await _lifecycle(tester, 'inactive');
    await _lifecycle(tester, 'resumed');
    await _pumpUntil(tester, () => client.started.isNotEmpty);
    expect(client.started, <String>['735']);

    // 行内刷新入口在补刷期间禁用：同一主播两路在飞会把风控风险翻倍。
    // 行内入口在 #148 里由文字按钮改成了图标按钮（省宽度），语义不变；
    // 用 tooltip 定位，避免和 AppBar 的「刷新全部」图标撞（FilledButton/IconButton 同名）。
    expect(
      tester
          .widget<IconButton>(find.ancestor(
            of: find.byTooltip('刷新'),
            matching: find.byType(IconButton),
          ))
          .onPressed,
      isNull,
      reason: '补刷在飞时行内入口不该再发一条',
    );

    // 批量刷新同样跳过正在补刷的主播。
    await tester.tap(find.byTooltip('刷新全部'));
    await tester.pump(const Duration(seconds: 1));
    expect(client.started, <String>['735'], reason: '批量刷新跳过在飞的主播');

    // 放行挂住的请求，别在用例结束时留下没跑完的 Future。
    client.gate!.complete();
    client.gate = null;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('主播列表文件损坏时给出留存提示，不把空列表当正常状态（#82）',
      (WidgetTester tester) async {
    final Directory dir =
        Directory.systemTemp.createTempSync('danmu_float_home_corrupt');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String roomsPath =
        '${dir.path}${Platform.pathSeparator}$roomStoreFileName';
    await tester.runAsync(() async {
      // 半截 JSON：写入中断最容易留下的形态，旧代码会当成「没有主播」。
      await File(roomsPath).writeAsString('{broken');
      await OverlayPrefsStore(directoryResolver: () async => dir)
          .save(const OverlayPrefs());
    });
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);

    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        directoryResolver: () async => dir,
        credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
      ),
    ));
    await _pumpUntil(
      tester,
      () => find.textContaining('主播列表文件损坏').evaluate().isNotEmpty,
    );

    expect(find.textContaining('主播列表文件损坏'), findsOneWidget);
    expect(
      find.text('主播列表读取失败，请先按上方提示处理，暂不要添加新主播'),
      findsOneWidget,
      reason: '损坏导致的空列表不能引导用户继续添加，否则等于坐实数据丢失',
    );
    expect(
      find.byKey(const ValueKey<String>('addFirstRoom')),
      findsNothing,
      reason: '损坏导致的空列表不给主行动（#142 / #82）',
    );
    // 原始字节必须已经被留存下来，不能被后续任何一次保存覆盖（#82 的不可逆点）。
    final bool backupExists = await tester.runAsync(
          () => File('$roomsPath$roomStoreCorruptSuffix').exists(),
        ) ??
        false;
    final String? backupContent = await tester.runAsync(
      () => File('$roomsPath$roomStoreCorruptSuffix').readAsString(),
    );
    expect(backupExists, isTrue, reason: '坏文件要先留存再返回空列表');
    expect(backupContent, '{broken', reason: '留存件必须是损坏前的原始字节');
    expect(await tester.runAsync(() => File(roomsPath).exists()), isFalse);

    // 排掉 initState 里悬浮窗状态探测的 1s 延时（_overlayAliveProbeDelay），
    // 否则用例结束时会因悬挂定时器报「Pending timers」。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('清除本地数据失败时不宣布重置，并明示失败项（#92）', (WidgetTester tester) async {
    final Directory dir =
        Directory.systemTemp.createTempSync('danmu_float_reset_fail');
    addTearDown(() => dir.deleteSync(recursive: true));
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);

    int resets = 0;
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        directoryResolver: () async => dir,
        // 凭证密文删除必失败：模拟 Keystore / 磁盘层面的删除失败。
        credentialStore: CredentialStore(backend: _FailingDeleteCredentialBackend()),
        onResetAll: () => resets++,
      ),
    ));
    await _pumpUntil(tester, () => find.byTooltip('设置').evaluate().isNotEmpty);

    // 走真实入口：设置页 → 数据与隐私 → 清除所有本地数据。
    await tester.tap(find.byTooltip('设置'));
    await _pumpUntil(
      tester,
      () => find.byType(SettingsPage).evaluate().isNotEmpty,
    );
    // 等设置页入场动画走完再滚动/点击，避免按到动画中的位置。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.scrollUntilVisible(
      find.text('清除所有本地数据'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    // scrollUntilVisible 只保证「进了视口」，可能正好停在底边外 1px（#143 加了预览卡
    // 后滚动位置变化，这里曾稳定地落在 601.2）。再 ensureVisible 一次，把它完整
    // 滚进来再点，避免这类与页面高度耦合的偶发失败。
    await tester.ensureVisible(find.text('清除所有本地数据'));
    await tester.pump();
    await tester.tap(find.text('清除所有本地数据'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilledButton, '清除并重置'));

    await _pumpUntil(
      tester,
      () => find.textContaining('未能清除').evaluate().isNotEmpty,
    );
    // 等设置页的退场动画走完，否则残留的设置页会让下面的断言数出两份文案。
    await tester.pump(const Duration(milliseconds: 600));

    // 失败必须可见，且不能假装已恢复初始状态。
    expect(find.textContaining('清除未完成'), findsOneWidget);
    expect(find.textContaining('凭证密文'), findsOneWidget);
    expect(
      resets,
      0,
      reason: '没清干净就不能回调外层切回免责声明页，否则界面口径与磁盘事实分裂',
    );
    // 设置页已弹回首页，用户能在首页看到失败原因。
    expect(find.text('清除所有本地数据'), findsNothing);
    // 排掉悬浮窗状态探测延时，避免悬挂定时器。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('悬浮窗正在显示的直播间在行内标出，换绑/关窗后立即更新（#144）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ManagedRoom(
          webRid: '222',
          name: '主播乙',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ManagedRoom(
          webRid: '333',
          name: '主播丙',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>['111', '222'],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    await _withTallViewport(tester);

    await _pumpHomeWithDir(tester, dir);
    await _pumpUntil(
      tester,
      () => find.byTooltip('关闭悬浮窗').evaluate().isNotEmpty,
    );
    expect(find.byTooltip('关闭悬浮窗'), findsOneWidget, reason: '前置：首页已认为悬浮窗开着');

    Finder tileOf(String name) =>
        find.ancestor(of: find.text(name), matching: find.byType(ListTile));
    expect(
      find.descendant(of: tileOf('主播甲'), matching: find.text('悬浮窗显示中')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tileOf('主播乙'), matching: find.text('悬浮窗显示中')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tileOf('主播丙'), matching: find.text('悬浮窗显示中')),
      findsNothing,
      reason: '没绑在栏位里的主播不能被标成「显示中」',
    );
    expect(find.text('悬浮窗显示中'), findsNWidgets(2));

    // 窗内换绑走既有上报链路（不新增通道 / 协议字段）：丙接替甲。
    pushOverlayStatusForTest(const OverlayStatus(
      stage: LiveSessionStage.live,
      received: 10,
      webRids: <String>['222', '333'],
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(of: tileOf('主播丙'), matching: find.text('悬浮窗显示中')),
      findsOneWidget,
      reason: '窗内换绑后标识要跟着换，否则又变成第二套绑定口径',
    );
    expect(
      find.descendant(of: tileOf('主播甲'), matching: find.text('悬浮窗显示中')),
      findsNothing,
    );

    // 关窗：标记必须跟着消失，否则「窗已经关了，标记还挂着」。
    pushOverlayStatusForTest(const OverlayStatus(
      stage: LiveSessionStage.idle,
      received: 0,
      closed: true,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('悬浮窗显示中'), findsNothing);
  });

  testWidgets('窄屏 360dp 加「悬浮窗显示中」标识不溢出，既有入口不被挤掉（#144）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>['111'],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: true);
    _mockMessengerReplies(tester);
    _markOverlayShown();
    // trailing 已经有两个按钮 + 「更多」，标识只能放 subtitle：360dp 是最紧的常见宽度。
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpHomeWithDir(tester, dir);
    await _pumpUntil(
      tester,
      () => find.text('悬浮窗显示中').evaluate().isNotEmpty,
    );

    expect(tester.takeException(), isNull, reason: '加标识不能溢出（UX-07 的窄屏教训）');
    expect(find.text('悬浮窗显示中'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.ancestor(
            of: find.byTooltip('刷新'),
            matching: find.byType(IconButton),
          ))
          .onPressed,
      isNotNull,
      reason: '既有的刷新入口必须仍然可点（AGENTS.md 要求不删既有入口）',
    );
    expect(find.byTooltip('更多操作'), findsOneWidget);
  });
  testWidgets('空列表时给出可点的主行动，并点明弹幕悬浮在其他应用之上（#142）',
      (WidgetTester tester) async {
    final Directory dir =
        Directory.systemTemp.createTempSync('danmu_float_home_empty');
    addTearDown(() => dir.deleteSync(recursive: true));
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);

    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        directoryResolver: () async => dir,
        credentialStore: CredentialStore(backend: _MemoryCredentialBackend()),
      ),
    ));
    final Finder addFirst =
        find.byKey(const ValueKey<String>('addFirstRoom'));
    await _pumpUntil(tester, () => addFirst.evaluate().isNotEmpty);

    expect(find.text('还没有直播间'), findsOneWidget);
    expect(
      find.textContaining('悬浮在其他应用之上'),
      findsOneWidget,
      reason: '空状态是唯一一次讲清价值主张的机会，必须说明弹幕悬浮在其他应用之上',
    );
    expect(
      find.textContaining('读取失败'),
      findsNothing,
      reason: '没有损坏警告时不该出现损坏文案',
    );

    // 与右上角 + 走同一个 _add()：点开的是同一个添加对话框，不是第二条路径。
    await tester.tap(addFirst);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('添加主播'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));

    // 排掉 initState 里悬浮窗状态探测的 1s 延时（_overlayAliveProbeDelay），
    // 否则用例结束时会因悬挂定时器报「Pending timers」。
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('列表非空时不渲染空状态引导块（#142）', (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '735',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);
    _mockMessengerReplies(tester);
    await _pumpHomeWithDir(tester, dir);

    expect(
      find.byKey(const ValueKey<String>('addFirstRoom')),
      findsNothing,
      reason: '列表有数据时不该再显示「添加第一个直播间」的引导',
    );
    expect(find.text('还没有直播间'), findsNothing);
  });
  testWidgets('搜索按主播名过滤、计数正确、清除后恢复，且行内操作照旧可用（#139）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(webRid: '735', name: '主播甲', addedAt: 1),
        ManagedRoom(webRid: '736', name: '主播乙', addedAt: 2),
        ManagedRoom(webRid: '737', name: '游戏主播丙', addedAt: 3),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);
    _mockMessengerReplies(tester);
    await _pumpHomeWithDir(tester, dir);
    expect(find.text('主播甲'), findsOneWidget);

    // 搜索与排序共用一个 AppBar 入口（不挤占既有五个动作）。
    await tester.tap(find.byTooltip('搜索与排序'));
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey<String>('homeSearchField')),
      '主播丙',
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('游戏主播丙'), findsOneWidget);
    expect(find.text('主播甲'), findsNothing, reason: '不匹配的行必须被过滤掉');
    expect(find.text('1 / 3'), findsOneWidget, reason: '搜索态要给出结果计数');
    // 过滤只影响可见性，不能把行内操作一起藏掉。
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('homeSearchClose')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('主播甲'), findsOneWidget);
    expect(find.text('游戏主播丙'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('搜索无结果时给出明确回执，不留空白列表（#139）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(webRid: '735', name: '主播甲', addedAt: 1),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);
    _mockMessengerReplies(tester);
    await _pumpHomeWithDir(tester, dir);

    await tester.tap(find.byTooltip('搜索与排序'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('homeSearchField')),
      '不存在的房间',
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('没有匹配的直播间'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('排序：直播中优先 / 最近刷新按预期重排，并落盘记住（#139）',
      (WidgetTester tester) async {
    final Directory dir = await _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '735',
          name: '主播甲',
          addedAt: 1,
          living: false,
          lastRefreshedAt: 1000,
        ),
        ManagedRoom(webRid: '736', name: '主播乙', addedAt: 2, living: true),
        ManagedRoom(
          webRid: '737',
          name: '主播丙',
          addedAt: 3,
          lastRefreshedAt: 3000,
        ),
      ],
      boundWebRids: <String>[],
    );
    _mockPathProvider(tester, dir);
    _mockOverlayChannels(tester, active: false);
    _mockMessengerReplies(tester);
    await _pumpHomeWithDir(tester, dir);

    double dyOf(String name) => tester.getTopLeft(find.text(name)).dy;

    await tester.tap(find.byTooltip('搜索与排序'));
    await tester.pump();
    await tester.tap(find.text('直播中优先'));
    await tester.pump();

    expect(dyOf('主播乙'), lessThan(dyOf('主播丙')), reason: '直播中排在未知之前');
    expect(dyOf('主播丙'), lessThan(dyOf('主播甲')), reason: '未知排在未开播之前');

    // 工具条还开着，直接切排序（图标是开关，再点会收起）。
    await tester.tap(find.text('最近刷新'));
    await tester.pump();

    expect(dyOf('主播丙'), lessThan(dyOf('主播甲')), reason: '3000 比 1000 新');
    expect(dyOf('主播甲'), lessThan(dyOf('主播乙')), reason: '从未刷新的排最后');

    // 落盘是真实文件 I/O：先给真实事件循环一点时间把写操作走完，否则重建页面会
    // 在写完成之前就去读，读到默认值（测试里的竞态，不是产品逻辑问题）。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );

    // 排序偏好必须落盘：重建页面后仍按「最近刷新」排列（#139）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    _mockOverlayChannels(tester, active: false);
    await _pumpHomeWithDir(tester, dir);
    expect(dyOf('主播丙'), lessThan(dyOf('主播甲')), reason: '重建后应读回落盘的排序');

    await tester.pump(const Duration(seconds: 2));
  });

  group('分组管理（#140）', () {
    Future<Directory> seedThreeGroups(WidgetTester tester) => _seedRooms(
      tester,
      rooms: <ManagedRoom>[
        ManagedRoom(
          webRid: '111',
          name: '主播甲',
          addedAt: DateTime.now().millisecondsSinceEpoch,
          group: '游戏',
        ),
        ManagedRoom(
          webRid: '222',
          name: '主播乙',
          addedAt: DateTime.now().millisecondsSinceEpoch,
          group: '游戏',
        ),
        ManagedRoom(
          webRid: '333',
          name: '主播丙',
          addedAt: DateTime.now().millisecondsSinceEpoch,
          group: '音乐',
        ),
      ],
      boundWebRids: <String>[],
    );

    testWidgets('分组标题显示数量，点击折叠后成员行不再渲染', (WidgetTester tester) async {
      final Directory dir = await seedThreeGroups(tester);
      _mockPathProvider(tester, dir);
      _mockOverlayChannels(tester, active: false);
      _mockMessengerReplies(tester);
      // 首页在 600dp 高时分组标题会落在视口外，先放大视口再挂载。
      await _withTallViewport(tester);
      await _pumpHomeWithDir(tester, dir);

      final Finder header =
          find.byKey(const ValueKey<String>('groupHeader_游戏'));
      expect(find.text('游戏 · 2 个直播间'), findsOneWidget);
      expect(find.text('主播甲'), findsOneWidget);
      // 展开态是「收起」箭头。
      expect(
        find.descendant(of: header, matching: find.byIcon(Icons.expand_less)),
        findsOneWidget,
      );

      await tester.tap(header);
      await tester.pump();

      // 先钉状态真的变了（箭头翻转），再钉渲染结果——两者分开断言，
      // 出问题时能立刻看出是「没点到」还是「收起后没少渲染」。
      expect(
        find.descendant(of: header, matching: find.byIcon(Icons.expand_more)),
        findsOneWidget,
        reason: '点标题应当切到收起态',
      );
      expect(
        find.text('主播甲'),
        findsNothing,
        reason: '收起后成员行不再渲染',
      );
      expect(
        find.text('游戏 · 2 个直播间'),
        findsOneWidget,
        reason: '标题必须留着，否则没法再展开',
      );
      expect(find.text('主播丙'), findsOneWidget, reason: '别的分组不受影响');

      await tester.tap(header);
      await tester.pump();
      expect(find.text('主播甲'), findsOneWidget, reason: '再点一次恢复渲染');

      // 折叠状态会落盘（真实文件写），收尾前给它时间跑完。
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('长按分组标题给出重命名 / 合并 / 解散三个入口', (WidgetTester tester) async {
      final Directory dir = await seedThreeGroups(tester);
      _mockPathProvider(tester, dir);
      _mockOverlayChannels(tester, active: false);
      _mockMessengerReplies(tester);
      await _withTallViewport(tester);
      await _pumpHomeWithDir(tester, dir);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('groupHeader_游戏')),
      );
      await tester.pump();
      await tester.longPress(
        find.byKey(const ValueKey<String>('groupHeader_游戏')),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // 分组操作入口都在：具体怎么改由 regroupRooms 的单测覆盖，
      // 这里只钉「长按标题能到达这三个操作」这层接线。
      expect(find.text('游戏'), findsWidgets);
      expect(find.text('重命名分组'), findsOneWidget);
      expect(find.text('合并到其他分组'), findsOneWidget);
      expect(find.text('解散分组'), findsOneWidget);
      expect(find.textContaining('2 个直播间'), findsWidgets);

      await tester.pump(const Duration(seconds: 10));
    });
  });
}
