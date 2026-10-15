// 悬浮球与菜单的可点区域（UX-21）：窗内唯一的菜单入口、以及菜单里唯一的重连出口，
// 都不能是「看得见但点不准」的尺寸。
//
// 单独一个文件：OverlayPage 在 initState 里订阅 FlutterScreenOverlay.overlayListener
// （静态单订阅流），同一个测试文件里 mount 第二次会抛
// 「Bad state: Stream has already been listened to」。
import 'dart:async';

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
  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    throw RoomInfoException('测试注入：接口不可用');
  }
}

/// 下发一份带 [webRids] 的悬浮窗配置，并等会话建立 / 失败走完几轮异步。
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
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('悬浮球命中区 ≥32dp、菜单行高 ≥28dp，且菜单入口不丢（UX-21）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    await _pushConfig(tester, <String>['123456']);

    // 悬浮球是窗内**唯一**能打开功能菜单的入口：命中区必须大于 24dp 的视觉尺寸。
    // （旧版是 24×24、闲置 40% 透明，压在视频上很难点中。）
    final Size ball =
        tester.getSize(find.byKey(const ValueKey<String>('overlayBall')));
    expect(ball.width, greaterThanOrEqualTo(32));
    expect(ball.height, greaterThanOrEqualTo(32));

    await tester.tap(find.byKey(const ValueKey<String>('overlayBall')));
    await tester.pump(const Duration(milliseconds: 300));

    // 菜单里每一条都要点得准：旧版 vertical padding 2 + minimumSize zero，
    // 单栏字号 11dp 时行高只有 ≈17dp。
    final Size addRow =
        tester.getSize(find.widgetWithText(TextButton, '添加栏位'));
    expect(addRow.height, greaterThanOrEqualTo(28));

    // 放大命中区不等于删入口：几项都还在。
    expect(find.widgetWithText(TextButton, '减少栏位'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '栏位管理'), findsOneWidget);
  });
}
