// 最小窗宽下的栏目标识行（UX-12）：人数给完整数字且不可省略，连接状态允许省略
// （状态点的颜色已经表示连接状态），极窄时折叠装饰性图标而不是裁掉数字。
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

/// 下发一份带 [webRids] 的悬浮窗配置（可反复下发，用来改变栏数）。
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
  // 会话建立与失败要走几轮异步：多 pump 几次让标识行稳定下来。
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('最小窗宽下标识行不溢出：折叠装饰图标，数字与状态点保留（UX-12）',
      (WidgetTester tester) async {
    // 窗口宽 200dp：2 栏时每栏内容约 88dp、9 栏（3 列）时约 54dp——都是真实可达的
    // 最小宽度，旧版标识行会在这里撑出溢出条（溢出仅 debug 可见，analyze 不报）。
    tester.view.physicalSize = const Size(200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );

    // 9 栏：54dp 属于极窄，连暂停图标都要让位（暂停还能双击切换）。
    await _pushConfig(tester, <String>[
      for (int i = 0; i < 9; i++) '${700 + i}',
    ]);
    expect(tester.takeException(), isNull, reason: '极窄下标识行不得溢出');
    expect(
      find.byIcon(Icons.pause),
      findsNothing,
      reason: '极窄时折叠装饰图标，把宽度让给人数',
    );
    expect(find.byIcon(Icons.fullscreen), findsNothing);

    // 2 栏：88dp 是「最小窗宽 + 2 栏」的常见边界，暂停图标还放得下，焦点 / 换绑让位。
    await _pushConfig(tester, <String>['700', '701']);
    expect(tester.takeException(), isNull, reason: '88dp 下标识行不得溢出');
    expect(
      find.byIcon(Icons.pause),
      findsNWidgets(2),
      reason: '88dp 还没到「极窄」，暂停入口不该被折叠掉',
    );
    expect(find.byIcon(Icons.fullscreen), findsNothing);

    // 同一份 2 栏配置在 400dp 宽下：图标要重新出现，证明折叠是「按需」而不是永久删掉入口。
    tester.view.physicalSize = const Size(400, 600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.pause), findsNWidgets(2));
    expect(find.byIcon(Icons.fullscreen), findsNWidgets(2));

    // 排掉状态上报的节流定时器，避免测试结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 2));
  });
}
