// 首页悬浮窗状态收敛（PM-001）与「移除主播即卸载其栏位」（PM-002）。
//
// 不依赖任何原生通道：本地存储用临时目录解析器注入、凭证用内存后端，插件窗口
// 查询通道用 mock 应答。悬浮窗上报经 overlay_launcher 的测试辅助直接驱动首页监听分支。
import 'dart:io';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的窗口控制通道名（third_party/flutter_screen_overlay）。
const MethodChannel _overlayControlChannel = MethodChannel(
  'x-slayer/overlay_channel',
);

/// 插件的窗口尺寸通道名：resizeOverlay / closeOverlay 走的是它而不是上面的
/// 控制通道（third_party/flutter_screen_overlay 里是两个独立 MethodChannel）。
const MethodChannel _overlaySizeChannel = MethodChannel('x-slayer/overlay');

/// 记录尺寸 / 关窗通道上调过的插件方法（PM-002 用：断言走了 resize / close 路径）。
final List<MethodCall> _sizeCalls = <MethodCall>[];

/// 插件的双向消息通道名：主 App 下发的 config / credential / close 都经它 send 出去。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

/// 给消息通道挂一个「立即应答」的 handler（PM-002 用）。
///
/// `FlutterScreenOverlay.shareData` 内部是 `BasicMessageChannel.send`，会 await
/// 原生侧回包；测试里没有真实原生侧，不挂 handler 这个 await 永远不会返回，
/// 整个移除流程就挂死在 10 分钟超时上。
void _mockMessengerReplies(WidgetTester tester) {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler(
    _messengerChannel.name,
    (ByteData? message) async => message,
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

/// 临时目录解析器：把 RoomStore / OverlayPrefsStore 的落盘指向临时目录，
/// 不依赖 path_provider 原生通道，也不读写真实应用数据。
Future<Directory> Function() _tempResolver() {
  final Directory dir =
      Directory.systemTemp.createTempSync('danmu_float_home_test');
  return () async => dir;
}

/// 记录主 App 调过的插件方法（PM-002 用：断言走了 resize / close 路径）。
final List<MethodCall> _overlayCalls = <MethodCall>[];

/// 向插件的窗口查询通道注入 mock：isActive 按 [active] 应答，权限恒为已授予，
/// 建窗 / 关窗 / 改尺寸一律记进 [_overlayCalls] 后返回，保证测试不会真的去动窗口，
/// 也不会因方法名不完全匹配而抛错导致异步挂起。
void _mockOverlayChannels(WidgetTester tester, {required bool active}) {
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
        return true;
      default:
        return false;
    }
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_overlayControlChannel, null),
  );
  // resizeOverlay / closeOverlay 走独立尺寸通道：不 mock 会抛 MissingPluginException，
  // resize 记录不下来（重排断言失败），close 则被 finally 复位掩盖成假绿。
  messenger.setMockMethodCallHandler(_overlaySizeChannel, (MethodCall call) async {
    _sizeCalls.add(call);
    return true;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_overlaySizeChannel, null),
  );
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
      () => _sizeCalls.any(
        (MethodCall call) =>
            call.method == 'resizeOverlay' || call.method == 'closeOverlay',
      ),
    );

    expect(find.text('主播甲'), findsNothing, reason: '主播甲应从列表移除');

    // 走了重排（resize）而不是关窗：还剩一栏可显示。
    expect(
      _sizeCalls.any((MethodCall call) => call.method == 'resizeOverlay'),
      isTrue,
      reason: '移除后应按剩余栏位重排，卸载被删主播那一栏',
    );
    expect(
      _sizeCalls.any((MethodCall call) => call.method == 'closeOverlay'),
      isFalse,
      reason: '还有剩余栏位，不应关窗',
    );

    // 落盘的栏位绑定里也不再含被移除的主播（真实读盘须逃出 FakeAsync）。
    late final OverlayPrefs persisted;
    await tester.runAsync(() async {
      persisted =
          await OverlayPrefsStore(directoryResolver: () async => dir).load();
    });
    expect(persisted.webRids, isNot(contains('111')));
    expect(persisted.webRids, contains('222'));
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
      () => _sizeCalls.any((MethodCall call) => call.method == 'closeOverlay'),
    );

    // 没有剩余栏位可下发：走关窗，而不是下发空绑定的 config。
    expect(
      _sizeCalls.any((MethodCall call) => call.method == 'closeOverlay'),
      isTrue,
      reason: '最后一栏被移除后应关窗，避免留下空窗',
    );
    expect(
      find.byTooltip('关闭悬浮窗'),
      findsNothing,
      reason: '窗口已关闭，不该再显示关闭入口',
    );
  });
}
