// 悬浮窗栏位失败态：标题栏必须给出可点的重试入口（UX-02）。
//
// 单独一个文件：OverlayPage 在 initState 里订阅 FlutterScreenOverlay.overlayListener
// （静态单订阅流），同一个测试文件里 mount 第二次会抛
// 「Bad state: Stream has already been listened to」。
import 'dart:async';

import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的双向消息通道：主 App 下发的配置经它上行到悬浮窗引擎。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

void main() {
  testWidgets('连接失败后标题栏给出可点的重试入口（UX-02）', (WidgetTester tester) async {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    await tester.pumpWidget(const OverlayApp());
    // 下发带一个主播的配置：该栏建立会话。
    unawaited(
      messenger.handlePlatformMessage(
        _messengerChannel.name,
        const JSONMessageCodec().encodeMessage(<String, Object?>{
          'type': 'config',
          'webRids': <String>['123456'],
        }),
        (ByteData? _) {},
      ),
    );
    await tester.pump();

    // 测试环境里 HTTP 一律失败：房间信息拉取报错 → 该栏进入异常态。
    final Finder retry = find.text('连接失败 · 点此重试');
    for (int i = 0; i < 40 && retry.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(retry, findsOneWidget, reason: '失败后必须给出可点的重试入口');

    // 失败原因要能查到：标题栏空间有限，明细放在 Tooltip 里。
    final Tooltip tooltip = tester.widget<Tooltip>(
      find.ancestor(of: retry, matching: find.byType(Tooltip)).first,
    );
    expect(tooltip.message, contains('房间信息获取失败'));

    // 点重试后即使再次失败，入口也必须还在：不能一次失败就锁死。
    await tester.tap(retry);
    await tester.pump();
    for (int i = 0; i < 40 && retry.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(retry, findsOneWidget);

    // 排掉状态上报的节流定时器，避免测试结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 2));
  });
}
