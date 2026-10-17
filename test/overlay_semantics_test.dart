// 悬浮窗无障碍语义（#135）：窗内每个可交互元素都要能被读出「是什么、作用于谁」。
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

const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

/// 永远失败的房间信息客户端：不走网络，失败时机确定，从而拿到「可重试」的栏位。
class _FailingRoomInfoClient extends RoomInfoClient {
  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    throw RoomInfoException('测试注入：接口不可用');
  }
}

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
  testWidgets('悬浮球与逐栏「重试」都带可朗读标签（#135）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SemanticsHandle handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    await _pushConfig(tester, <String>['123456']);

    // 悬浮球是窗内唯一的菜单入口：读不出「打开菜单」就等于整个菜单不可达。
    final SemanticsNode ball = tester.getSemantics(
      find.byKey(const ValueKey<String>('overlayBall')),
    );
    expect(ball.label, contains('菜单'));
    expect(
      ball.getSemanticsData().flagsCollection.isButton,
      isTrue,
      reason: '悬浮球必须被读成按钮',
    );

    // 标识行关掉后，菜单是窗内唯一能重连的地方（UX-08）：重试按钮要说清是哪一栏。
    await tester.tap(find.byKey(const ValueKey<String>('overlayBall')));
    await tester.pump(const Duration(milliseconds: 300));

    final Finder retry = find.widgetWithText(TextButton, '重试');
    expect(retry, findsWidgets, reason: '失败栏位应当给出重试出口');
    final SemanticsNode retryNode = tester.getSemantics(retry.first);
    expect(retryNode.label, contains('重试'));
    expect(retryNode.label, contains('第 1 栏'), reason: '多栏时要说清重试的是哪一栏');
    expect(
      retryNode.getSemanticsData().flagsCollection.isButton,
      isTrue,
    );
  });
}
