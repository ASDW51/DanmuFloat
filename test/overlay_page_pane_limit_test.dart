// 悬浮窗内加栏位的高性能确认与硬上限（PM-003）。
//
// 首页多栏超过 4 栏会强制确认高性能模式，但悬浮窗内的「添加栏位 / 栏位管理」
// 原先无限加栏、无性能提醒，与首页体验割裂。本文件验证悬浮窗侧同一口径：
// 第 5 栏触发确认（可取消）、达到 9 栏（硬上限）拒绝再加。
//
// 测试隔离要点：
// - config 下发走「平台 → 框架」方向：用 handlePlatformMessage 把 config 消息
//   注入 x-slayer/overlay_messenger 通道，页面注册的 overlayListener 即可收到；
//   setMockMessageHandler 只拦截框架 → 平台方向，接不到下行消息。
// - 上报走「框架 → 平台」方向：echo mock 原样回显，避免 shareData 挂死。
// - 各栏的 LiveDanmuSession 用真实实现：房间信息请求会被 flutter_test 的假
//   HttpClient 挡下（状态码 400），会话进入 error 阶段——不影响栏位增删逻辑，
//   页面标题回落为 webRid 展示，因此 finder 都按 webRid 匹配。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的双向消息通道：页面收 config、发 state 都走它。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>(
      'x-slayer/overlay_messenger',
      JSONMessageCodec(),
    );

/// 插件控制通道：isPermissionGranted / updateFlag / resizeOverlay 都走它。
const MethodChannel _controlChannel = MethodChannel('x-slayer/overlay_channel');

/// 控制通道挂默认应答：权限视为已授予、其余操作返回 null 即可，
/// 状态上报周期里的权限核对不会误判成「已撤销」而清空栏位。
void _mockControlChannel(WidgetTester tester) {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_controlChannel, (MethodCall call) async {
    if (call.method == 'isPermissionGranted') return true;
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_controlChannel, null),
  );}

/// 上报方向（框架 → 平台）挂 echo 应答，避免 shareData 等待回复挂死。
void _mockMessengerEcho(WidgetTester tester) {
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

/// 向页面注入 config 消息（平台 → 框架方向，与插件真实下发路径一致）。
void _sendConfigToPage(Map<String, Object?> configJson) {
  final ByteData? encoded = const JSONMessageCodec().encodeMessage(configJson);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        _messengerChannel.name,
        encoded,
        (ByteData? _) {},
      );
}

/// 组一份 N 栏的 config 消息（候选给足 12 个主播，保证有得加）。
Map<String, Object?> _configJson(List<String> webRids) => <String, Object?>{
  'type': overlayConfigType,
  'webRids': webRids,
  'roomOptions': <Map<String, Object?>>[
    for (int i = 1; i <= 12; i++)
      <String, Object?>{'webRid': '$i', 'name': '主播$i'},
  ],
};

/// 挂载悬浮窗页并注入 config；轮询到第一个栏位标题（webRid 文案）渲染出来
/// 即认为 config 已生效。
Future<void> _pumpOverlay(
  WidgetTester tester,
  Map<String, Object?> configJson,
) async {
  // 插件桥接流是非广播单例，中继状态跨用例残留：先重置再挂载，
  // 每个用例都拿到全新的插件订阅（PM-003 攻坚）。
  resetOverlayBridgeForTest();
  _mockMessengerEcho(tester);
  _mockControlChannel(tester);
  await tester.pumpWidget(
    const MaterialApp(debugShowCheckedModeBanner: false, home: OverlayPage()),
  );
  final String firstRid = (configJson['webRids']! as List<Object?>).first
      .toString();
  // config 经 handlePlatformMessage 异步投递：轮询等页面收到并渲染栏位。
  _sendConfigToPage(configJson);
  for (int i = 0; i < 50 && find.text(firstRid).evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 100));
}

/// 展开悬浮球菜单（点悬浮球图标）。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.tune));
  await tester.pump(const Duration(milliseconds: 200));
}

/// 生成 1~count 的栏位绑定（webRid 是数字串，候选里一定存在）。
List<String> _rids(int count) =>
    List<String>.generate(count, (int index) => '${index + 1}');

void main() {
  testWidgets('悬浮窗内加第 5 栏时弹高性能确认，取消后不加栏（PM-003）', (
    WidgetTester tester,
  ) async {
    await _pumpOverlay(tester, _configJson(_rids(4)));

    await _openMenu(tester);
    await tester.tap(find.text('添加栏位'));
    await tester.pump(const Duration(milliseconds: 300));

    // 高性能确认弹窗出现（prd F4，与首页同一口径）。
    expect(find.text('高性能模式'), findsOneWidget);
    expect(find.textContaining('本次要开 5 栏'), findsOneWidget);

    // 取消：确认弹窗关闭，未进入房间选择。
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('高性能模式'), findsNothing);
    expect(find.text('切换房间'), findsNothing);
  });

  testWidgets('悬浮窗内确认高性能后弹房间选择并加到 5 栏（PM-003）', (
    WidgetTester tester,
  ) async {
    await _pumpOverlay(tester, _configJson(_rids(4)));

    await _openMenu(tester);
    await tester.tap(find.text('添加栏位'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('继续开启'));
    await tester.pump(const Duration(milliseconds: 200));

    // 进入房间选择弹窗（候选只列未绑定的：主播5~12）。
    expect(find.text('切换房间'), findsOneWidget);
    await tester.tap(find.text('主播5').last);
    await tester.pump(const Duration(milliseconds: 200));

    // 第 5 栏出现：标题回落为 webRid '5'。
    expect(find.text('5'), findsWidgets);
  });

  testWidgets('悬浮窗内达到 9 栏上限后拒绝再加并提示（PM-003）', (
    WidgetTester tester,
  ) async {
    // 直接以 9 栏开窗（config 由主 App 下发，9 栏是允许的最大值）。
    await _pumpOverlay(tester, _configJson(_rids(9)));

    await _openMenu(tester);
    await tester.tap(find.text('添加栏位'));
    await tester.pump(const Duration(milliseconds: 300));

    // 达到上限：不弹选择框，直接提示已达上限。
    expect(find.text('已达上限'), findsOneWidget);
    expect(find.text('最多支持 9 栏，无法继续添加。'), findsOneWidget);
  });

  testWidgets('栏位管理里达到 9 栏后添加按钮禁用并显示已达上限（PM-003）', (
    WidgetTester tester,
  ) async {
    await _pumpOverlay(tester, _configJson(_rids(9)));

    await _openMenu(tester);
    await tester.tap(find.text('栏位管理'));
    await tester.pump(const Duration(milliseconds: 300));

    final Finder addFinder = find.widgetWithText(TextButton, '已达上限（9 栏）');
    expect(addFinder, findsOneWidget);
    final TextButton button = tester.widget<TextButton>(
      find.descendant(of: addFinder, matching: find.byType(TextButton)),
    );
    expect(button.onPressed, isNull, reason: '达到硬上限后添加按钮应禁用');
  });

  testWidgets('栏位管理里从 4 栏添加触发高性能确认，确认后可加到 5 栏（PM-003）', (
    WidgetTester tester,
  ) async {
    await _pumpOverlay(tester, _configJson(_rids(4)));

    await _openMenu(tester);
    await tester.tap(find.text('栏位管理'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('添加栏位'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('高性能模式'), findsOneWidget);
    await tester.tap(find.text('继续开启'));
    await tester.pump(const Duration(milliseconds: 200));

    // 选主播5 加进来并保存。
    await tester.tap(find.text('主播5').last);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('保存'));
    await tester.pump(const Duration(milliseconds: 200));

    // 保存后回到页面，第 5 栏标题显示 webRid '5'。
    expect(find.text('5'), findsWidgets);
  });
}
