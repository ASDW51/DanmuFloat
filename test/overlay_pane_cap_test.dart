// 悬浮窗加栏到顶与上限提示（UX-05 悬浮窗侧）。
//
// 单独一个文件：OverlayPage 在 initState 里订阅 FlutterScreenOverlay.overlayListener
// （静态单订阅流），同一个测试文件里 mount 第二次会抛
// 「Bad state: Stream has already been listened to」。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的双向消息通道：主 App 下发的配置经它上行到悬浮窗引擎。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

/// 永远失败的房间信息客户端：不走网络，失败时机确定。
class _FailingRoomInfoClient extends RoomInfoClient {
  int calls = 0;

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    calls++;
    throw RoomInfoException('测试注入：接口不可用');
  }
}

/// 下发一份带 [webRids] 的悬浮窗配置。
Future<void> _pushConfig(WidgetTester tester, List<String> webRids) async {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  unawaited(
    messenger.handlePlatformMessage(
      _messengerChannel.name,
      const JSONMessageCodec().encodeMessage(<String, Object?>{
        'type': 'config',
        'webRids': webRids,
      }),
      (ByteData? _) {},
    ),
  );
  await tester.pump();
}

/// 反复 pump 直到 [count] 个「失败」短状态词都出现（会话走完一轮异步流程）。
Future<void> _pumpUntilFailures(WidgetTester tester, int count) async {
  for (int i = 0; i < 40 && find.text('失败').evaluate().length < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('9 栏时菜单里的「添加栏位」禁用并写明上限（UX-05）',
      (WidgetTester tester) async {
    // 栏位达硬上限：窗内两个加栏入口都不该再放行，否则用户会以为能加到 10 栏。
    final List<String> webRids = <String>[
      for (int i = 0; i < maxPaneCount; i++) '${700 + i}',
    ];
    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    await _pushConfig(tester, webRids);
    await _pumpUntilFailures(tester, maxPaneCount);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump(const Duration(milliseconds: 300));

    final Finder capLabel = find.widgetWithText(
      TextButton,
      '已达上限 $maxPaneCount 栏',
    );
    expect(capLabel, findsOneWidget, reason: '到顶要写明为什么加不了');
    expect(
      tester.widget<TextButton>(capLabel).onPressed,
      isNull,
      reason: '到顶后入口禁用，不再让用户白选一次主播',
    );
    expect(find.text('添加栏位'), findsNothing);

    // 排掉状态上报的节流定时器，避免测试结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 2));
  });
}
