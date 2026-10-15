// 菜单「栏位状态」里未绑定栏位的文案（UX-15）：写「第 N 栏 · 未绑定」，不写
// 「第 N 栏 ·  · 等待中」——空主播名加「等待中」既像排版事故，又让人以为正在连接。
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

/// 下发一份带 [webRids] 的悬浮窗配置（空串代表「未绑定的栏位」）。
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
  testWidgets('未绑定栏位在菜单里写「未绑定」，不出现「·  · 等待中」（UX-15）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    // 第 2 栏留空：用户在多选里取消勾选、或把某栏切到未绑定时就是这种状态。
    await _pushConfig(tester, <String>['123456', '']);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('栏位状态'), findsOneWidget);
    expect(
      find.textContaining('第 2 栏 · 未绑定'),
      findsOneWidget,
      reason: '未绑定栏要与标识行同口径写「未绑定」',
    );
    expect(
      find.textContaining('·  ·'),
      findsNothing,
      reason: '空主播名不能留下两个连着的分隔符',
    );
    expect(
      find.textContaining('第 2 栏 ·  · 等待中'),
      findsNothing,
      reason: '没有会话就没有「等待中」，那句话会让人以为正在连接',
    );
    // 已绑定的第 1 栏仍按「第 1 栏 · 主播 · 状态」渲染（失败态下是「失败」）。
    expect(find.textContaining('第 1 栏 · '), findsOneWidget);

    // 排掉状态上报的节流定时器，避免测试结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 2));
  });
}
