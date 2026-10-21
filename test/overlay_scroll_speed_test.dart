// 悬浮球菜单里的滚动速度（#178）。
//
// 速度是「边看边调」的参数：太快看不清、太慢追不上，要切回主 App 改就等于打断观看。
// 这里钉住三件事：滑杆存在且范围与设置页一致、拖动即时改到各栏、松手走回报链路。
//
// 单独一个文件：OverlayPage 在 initState 里订阅 FlutterScreenOverlay 的静态单订阅流，
// 同一个测试文件 mount 第二次会抛「Stream has already been listened to」。
import 'dart:async';

import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>(
      'x-slayer/overlay_messenger',
      JSONMessageCodec(),
    );

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

/// 打开悬浮球菜单（窗内唯一的菜单入口）。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.tune));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// 按标题前缀取那一行的滑杆：菜单里有 5 个滑杆，按下标取会一改顺序就错位。
Slider _sliderFor(WidgetTester tester, String titlePrefix) {
  final Finder title = find.textContaining(titlePrefix);
  expect(title, findsOneWidget, reason: '菜单里应有「$titlePrefix」这一行');
  final Finder column = find
      .ancestor(of: title, matching: find.byType(Column))
      .first;
  return tester.widget<Slider>(
    find.descendant(of: column, matching: find.byType(Slider)),
  );
}

/// 各栏收到的滚动速度（_OverlayPane 是私有类，只能按运行时类型名取）。
List<double> _paneSpeeds(WidgetTester tester) => tester
    .widgetList<Widget>(
      find.byWidgetPredicate(
        (Widget widget) => widget.runtimeType.toString() == '_OverlayPane',
      ),
    )
    .map((Widget widget) => (widget as dynamic).scrollSpeed as double)
    .toList();

void main() {
  testWidgets('菜单里有滚动速度滑杆，拖动即时改到各栏（#178）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    await _pushConfig(tester, <String>['111']);
    await _openMenu(tester);

    final Slider slider = _sliderFor(tester, '滚动速度');
    expect(slider.min, minDanmuScrollSpeed, reason: '范围必须与设置页一致');
    expect(slider.max, maxDanmuScrollSpeed);
    expect(slider.value, defaultDanmuScrollSpeed, reason: '默认 1.00');
    expect(find.text('滚动速度　1.00'), findsOneWidget);

    // 拖动即时生效：改到 2.50 后标签与各栏取值都要跟着变，不需要落盘。
    slider.onChanged!(2.5);
    await tester.pump();

    expect(find.text('滚动速度　2.50'), findsOneWidget);
    expect(
      _paneSpeeds(tester),
      everyElement(2.5),
      reason: '拖动就该立刻改到栏位的自动滚动器，不能等松手',
    );

    // 上限收敛：越界值要被 clamp 住，滑杆不会显示成 9.00。
    _sliderFor(tester, '滚动速度').onChanged!(9);
    await tester.pump();
    expect(find.text('滚动速度　3.00'), findsOneWidget);
    expect(_paneSpeeds(tester), everyElement(maxDanmuScrollSpeed));
  });
}
