// 悬浮窗失败态可达性：标识行只放短状态词，重试入口收进悬浮球菜单（UX-07 / UX-08）。
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
///
/// flutter_test 的 mock HttpClient 什么时候回失败不可控，靠它才能稳定复现失败态。
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

/// 反复 pump 直到 [finder] 命中（失败态要等会话走完一轮异步流程）。
Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('失败栏位：标识行只写短状态词，重试入口在悬浮球菜单里（UX-07 / UX-08）',
      (WidgetTester tester) async {
    final _FailingRoomInfoClient client = _FailingRoomInfoClient();
    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: client)),
    );
    await _pushConfig(tester, <String>['123456']);

    // 标识行只写「失败」：旧版长文案（「连接失败 · 点此重试」）在多栏窄窗里会把这一行
    // 撑出溢出条，而溢出只在 debug 可见、`flutter analyze` 也不报（UX-07）。
    final Finder shortLabel = find.text('失败');
    await _pumpUntilFound(tester, shortLabel);
    expect(shortLabel, findsOneWidget);
    expect(
      find.textContaining('点此重试'),
      findsNothing,
      reason: '标识行不再放长文案，重试入口统一收在悬浮球菜单',
    );

    // 短词看不出为什么失败：完整原因放在 Tooltip 里。
    final Tooltip tooltip = tester.widget<Tooltip>(
      find.ancestor(of: shortLabel, matching: find.byType(Tooltip)).first,
    );
    expect(tooltip.message, contains('房间信息获取失败'));

    // 打开悬浮球菜单：里面给出该栏状态与可点「重试」——标识行关掉后，这是窗内唯一
    // 能重连的地方（UX-08）。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('栏位状态'), findsOneWidget);
    expect(find.textContaining('第 1 栏'), findsOneWidget);
    final Finder retryButton = find.widgetWithText(TextButton, '重试');
    expect(retryButton, findsOneWidget);

    // 点「重试」要真的重走一遍：注入的假客户端被再调一次。
    final int before = client.calls;
    await tester.tap(retryButton);
    for (int i = 0; i < 20 && client.calls <= before; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(client.calls, greaterThan(before), reason: '菜单里的重试必须重建会话');

    // 重试仍失败时失败原因不能被清掉，否则空列表只剩「暂无弹幕」（UX-08）。
    await _pumpUntilFound(tester, find.text('失败'));
    final Tooltip afterRetry = tester.widget<Tooltip>(
      find.ancestor(of: find.text('失败'), matching: find.byType(Tooltip)).first,
    );
    expect(afterRetry.message, contains('房间信息获取失败'));

    // 排掉状态上报的节流定时器，避免测试结束时残留 pending timer。
    await tester.pump(const Duration(seconds: 2));
  });
}
