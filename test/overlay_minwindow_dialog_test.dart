// 最小窗（200×150）下的窗内弹窗（UX-20）：默认 24dp insetPadding + 标题/内容/按钮行
// 会把内容区压到约 102dp，纵向一挤按钮就可能出屏点不到；这里钉住「收紧边距 + 整块可滚」。
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
  testWidgets('最小窗下打开栏位管理弹窗：不溢出，且边距收紧、整块可滚（UX-20）',
      (WidgetTester tester) async {
    // 窗口下限：高 150dp（minOverlayHeight），宽 200dp（minOverlayWidth 一档）。
    tester.view.physicalSize = const Size(200, 150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    await _pushConfig(tester, <String>['123456']);

    // 菜单在最小窗里要滚动才能看到「栏位管理」，先滚到它再点。
    await tester.tap(find.byKey(const ValueKey<String>('overlayBall')));
    await tester.pump(const Duration(milliseconds: 300));
    final Finder manage = find.widgetWithText(TextButton, '栏位管理');
    await tester.ensureVisible(manage);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(manage);
    await tester.pump(const Duration(milliseconds: 500));

    // 1) 打开过程不报溢出（溢出只在 debug 抛 RenderFlex overflowed）；
    // 2) 弹窗本身带上了收紧后的边距与可滚标记——这两条是属性断言，
    //    不依赖「我估的宽度准不准」，比截图式断言可靠。
    expect(tester.takeException(), isNull);
    final AlertDialog dialog = tester.widget<AlertDialog>(
      find.byType(AlertDialog),
    );
    expect(dialog.insetPadding, const EdgeInsets.all(8));
    expect(dialog.scrollable, isTrue);
  });
}
