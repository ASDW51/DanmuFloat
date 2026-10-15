// 首页悬浮窗状态收敛（PM-001）：窗口可能由弹幕页开启或进程重启后仍存活，
// 首页的「关闭悬浮窗」入口必须以窗口真实存在为准，而不是只认本页的开窗动作。
//
// 插件通道全部 mock：窗口查询走 mock 应答；悬浮窗上行状态经
// handlePlatformMessage 注入（等价于插件原生侧发来的 JSON）。
// 测试不依赖真机，也不真的建窗 / 关窗。
import 'dart:io';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的窗口控制通道名（third_party/flutter_screen_overlay）。
const MethodChannel _overlayControlChannel = MethodChannel(
  'x-slayer/overlay_channel',
);

/// path_provider 通道名：首页各 store 默认从这里解析应用目录。
const MethodChannel _pathProviderChannel = MethodChannel(
  'plugins.flutter.io/path_provider',
);

/// 插件的上行消息通道名：悬浮窗状态经它送进主 App 引擎。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

/// 把应用支持目录指向临时目录：测试不读写真实应用数据，
/// 也避免 path_provider 插件通道缺失导致的未捕获异步异常。
Future<void> _mockAppDirectory(WidgetTester tester) async {
  final Directory dir = await Directory.systemTemp.createTemp(
    'danmu_float_home_test',
  );
  addTearDown(() => dir.delete(recursive: true));
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_pathProviderChannel,
      (MethodCall call) async {
    if (call.method == 'getApplicationSupportPath') return dir.path;
    if (call.method == 'getApplicationDocumentsPath') return dir.path;
    if (call.method == 'getTemporaryPath') return dir.path;
    throw MissingPluginException('测试未实现: ${call.method}');
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_pathProviderChannel, null),
  );
}

/// 向插件的窗口查询通道注入 mock：isActive 按 [active] 应答，权限恒为已授予，
/// 其余方法一律抛错，保证测试不会真的去建窗 / 关窗。
void _mockOverlayChannels(WidgetTester tester, {required bool active}) {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_overlayControlChannel,
      (MethodCall call) async {
    if (call.method == 'isOverlayActive') return active;
    if (call.method == 'checkPermission') return true;
    throw MissingPluginException('测试未实现: ${call.method}');
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(_overlayControlChannel, null),
  );
}

/// 模拟悬浮窗引擎上报一条状态（PM-001 测试用）。
///
/// overlay_launcher 在主 App 引擎里对 _messengerChannel 注册了 handler，
/// 这里按平台侧上行的路径把 JSON 塞给框架，驱动首页的状态监听分支。
Future<void> _pushOverlayStatus(
  WidgetTester tester,
  OverlayStatus status,
) async {
  final ByteData? encoded =
      const JSONMessageCodec().encodeMessage(status.toJson());
  await TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger.handlePlatformMessage(
    _messengerChannel.name,
    encoded,
    (ByteData? reply) {},
  );
}

Future<void> _pumpHome(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: HomePage()));
  // 首页 initState 有一串异步加载（列表 / 偏好 / 凭证 / 权限 / 状态收敛），
  // 还要等 1s 的状态探测延时常量过去，才能把收敛结果断言出来。
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  testWidgets('悬浮窗由弹幕页开启（本页没开过）时，首页仍显示关闭入口（PM-001）',
      (WidgetTester tester) async {
    await _mockAppDirectory(tester);
    // 窗口已被弹幕页打开：isActive 返回真。
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
    await _mockAppDirectory(tester);
    _mockOverlayChannels(tester, active: false);

    await _pumpHome(tester);

    expect(find.byTooltip('关闭悬浮窗'), findsNothing);
  });

  testWidgets('悬浮窗上报活跃栏位绑定后，首页补上已开启状态（PM-001）',
      (WidgetTester tester) async {
    await _mockAppDirectory(tester);
    // 初始未检测到窗口（例如前台服务还在恢复中）。
    _mockOverlayChannels(tester, active: false);

    await _pumpHome(tester);
    expect(find.byTooltip('关闭悬浮窗'), findsNothing);

    // 悬浮窗引擎完成配置装载并开始周期上报（弹幕页开的单栏窗同样会上报）。
    await _pushOverlayStatus(
      tester,
      const OverlayStatus(
        stage: LiveSessionStage.live,
        received: 10,
        webRids: <String>['12345'],
      ),
    );
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
    await _mockAppDirectory(tester);
    _mockOverlayChannels(tester, active: true);

    await _pumpHome(tester);
    expect(find.byTooltip('关闭悬浮窗'), findsOneWidget);

    await _pushOverlayStatus(
      tester,
      const OverlayStatus(
        stage: LiveSessionStage.error,
        received: 0,
        error: '悬浮窗权限已被撤销，已断开全部连接',
        permissionRevoked: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.byTooltip('关闭悬浮窗'), findsNothing);
    expect(
      find.text('悬浮窗权限未授予，当前仅能在 App 内查看'),
      findsOneWidget,
      reason: '权限被撤销后应出现降级常驻提示',
    );
  });
}
