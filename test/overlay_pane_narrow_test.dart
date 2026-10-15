// 多栏窄窗下的栏目标识行：短状态词 + 不溢出（UX-07）。
//
// 单独一个文件：OverlayPage 在 initState 里订阅 FlutterScreenOverlay.overlayListener
// （静态单订阅流），同一个测试文件里 mount 第二次会抛
// 「Bad state: Stream has already been listened to」。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
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
  }) async => throw RoomInfoException('测试注入：接口不可用');
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

void main() {
  group('paneStageText', () {
    test('每个阶段都有短文案，且「复检中」与「已停止复检」区分开', () {
      expect(paneStageText(LiveSessionStage.error), '失败');
      expect(paneStageText(LiveSessionStage.live), '已连接');
      expect(paneStageText(LiveSessionStage.offline), '未开播');
      expect(
        paneStageText(LiveSessionStage.offline, autoRechecking: true),
        '复检中…',
      );
    });

    test('文案长度受控：多栏窄窗里每多一个字都可能撑破标识行', () {
      for (final LiveSessionStage stage in LiveSessionStage.values) {
        expect(
          paneStageText(stage).length,
          lessThanOrEqualTo(5),
          reason: '$stage 的短文案过长',
        );
      }
    });
  });

  testWidgets('5 栏窄窗下失败栏位的标识行不溢出（UX-07）',
      (WidgetTester tester) async {
    // 5 栏 → 网格 3 列；400dp 宽下单栏约 133dp，正是旧版长文案撑出溢出条的配置。
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    await _pushConfig(tester, <String>['1', '2', '3', '4', '5']);
    for (int i = 0; i < 40 && find.text('失败').evaluate().length < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('失败'), findsNWidgets(5), reason: '5 栏都应进入失败态');

    // RenderFlex overflow 会经 FlutterError 上报，widget 测试里直接判失败；这里显式
    // 取一次，把「不溢出」写成断言，而不是依赖日志被忽略。
    expect(tester.takeException(), isNull, reason: '标识行不得溢出');

    // 排掉状态上报的节流定时器，避免测试结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 2));
  });
}
