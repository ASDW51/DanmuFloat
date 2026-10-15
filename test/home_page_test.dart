// 首页悬浮窗状态收敛（PM-001）：窗口可能由弹幕页开启或进程重启后仍存活，
// 首页的「关闭悬浮窗」入口必须以窗口真实存在为准，而不是只认本页的开窗动作。
//
// 不依赖任何原生通道：本地存储用临时目录解析器注入、凭证用内存后端，插件窗口
// 查询通道用 mock 应答。悬浮窗上行状态经消息通道 handler 直接驱动首页监听分支。
import 'dart:io';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的窗口控制通道名（third_party/flutter_screen_overlay）。
const MethodChannel _overlayControlChannel = MethodChannel(
  'x-slayer/overlay_channel',
);

/// 插件的上行消息通道名：悬浮窗状态经它送进主 App 引擎。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

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

/// 向插件的窗口查询通道注入 mock：isActive 按 [active] 应答，权限恒为已授予，
/// 其余方法一律返回 false，保证测试不会真的去建窗 / 关窗，也不会因方法名
/// 不完全匹配而抛错导致异步挂起。
void _mockOverlayChannels(WidgetTester tester, {required bool active}) {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_overlayControlChannel,
      (MethodCall call) async {
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
