// 悬浮窗透明度（#177）：拉到 1.00 仍透出底下画面。
//
// 两条根因分别钉住：
//   一、有单栏覆盖时全局滑块被静默忽略——现在菜单必须把覆盖态说出来，且清除后回落；
//   二、即使全局 1.00 生效，分隔线与边框本身是半透明 chrome 色，圆角与网格缝隙仍透光。
//
// 单独一个文件：OverlayPage 在 initState 里订阅 FlutterScreenOverlay 的静态单订阅流，
// 同一个测试文件 mount 第二次会抛「Stream has already been listened to」。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
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

Future<void> _pushConfig(
  WidgetTester tester,
  List<String> webRids, {
  Map<String, Object?>? paneStyles,
}) async {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  unawaited(
    messenger.handlePlatformMessage(
      _messengerChannel.name,
      const JSONMessageCodec().encodeMessage(<String, Object?>{
        'type': 'config',
        'webRids': webRids,
        if (paneStyles != null) 'paneStyles': paneStyles,
      }),
      (ByteData? _) {},
    ),
  );
  await tester.pump();
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 各栏实际渲染的透明度（_OverlayPane 是私有类，只能按运行时类型名取）。
List<double> _paneOpacities(WidgetTester tester) => tester
    .widgetList<Widget>(
      find.byWidgetPredicate(
        (Widget widget) => widget.runtimeType.toString() == '_OverlayPane',
      ),
    )
    .map((Widget widget) => (widget as dynamic).opacity as double)
    .toList();

void main() {
  group('满不透明时不再有半透明 chrome（#177 根因二）', () {
    test('分隔线/边框在 1.00 时 alpha 为 255，低于上限时保持原色', () {
      const OverlayPalette palette = OverlayPalette.darkPalette;
      expect(
        palette.divider.a,
        lessThan(1),
        reason: '前提：chrome 色本身带 alpha，否则这条根因不存在',
      );

      final Color atMax = overlayChromeColor(palette, maxOverlayOpacity);
      expect(atMax.a, 1, reason: '1.00 时不允许再出现半透明分隔线');

      expect(
        overlayChromeColor(palette, 0.5),
        palette.divider,
        reason: '未拉满时保持原有观感，不要顺手改掉整体视觉',
      );
    });

    test('窗口底色本身不透明，1.00 时铺底即为 255', () {
      for (final OverlayPalette palette in <OverlayPalette>[
        OverlayPalette.darkPalette,
        OverlayPalette.lightPalette,
      ]) {
        expect(
          palette.maskColor.a,
          1,
          reason: '底色若自带 alpha，1.00 也会透出底下画面',
        );
      }
    });
  });

  group('单栏透明度优先级（#177 根因一）', () {
    test('手势覆盖 > 持久覆盖 > 全局', () {
      expect(
        paneOpacityFor(gesture: 0.3, persisted: 0.6, global: 1),
        0.3,
        reason: '窗内刚滑过的值优先，用户期待「我拖了就是它」',
      );
      expect(paneOpacityFor(gesture: null, persisted: 0.6, global: 1), 0.6);
      expect(paneOpacityFor(gesture: null, persisted: null, global: 0.8), 0.8);
    });

    test('越界值收敛到合法区间', () {
      expect(
        paneOpacityFor(gesture: 5, persisted: null, global: 1),
        maxOverlayOpacity,
      );
      expect(
        paneOpacityFor(gesture: null, persisted: -1, global: 1),
        minOverlayOpacity,
      );
    });
  });

  testWidgets('单栏覆盖不再静默：栏位按覆盖值渲染，菜单说明原因（#177）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: OverlayPage(roomInfoClient: _FailingRoomInfoClient())),
    );
    await _pushConfig(
      tester,
      <String>['111'],
      paneStyles: <String, Object?>{
        '111': <String, Object?>{'opacity': 0.5},
      },
    );

    expect(
      _paneOpacities(tester),
      <double>[0.5],
      reason: '有持久覆盖时栏位就该按 0.5 渲染——这是 prd F5 的既有语义',
    );

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('透明度（全局）'),
      findsOneWidget,
      reason: '全局滑块要写明它只管没覆盖的栏，否则「标签 1.00 / 实际 0.50」自相矛盾',
    );
    expect(
      find.textContaining('按栏独立配置'),
      findsOneWidget,
      reason: '覆盖态必须说出来，并指向设置页那个入口',
    );
  });
}
