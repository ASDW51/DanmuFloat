// 悬浮窗与主 App 之间的消息协议：主 App 与悬浮窗引擎不共享内存，
// 载荷必须能经 JSONMessageCodec 往返，故用例统一走 jsonEncode/jsonDecode。
import 'dart:convert';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模拟 BasicMessageChannel 的 JSONMessageCodec 往返。
Object? roundTrip(Map<String, Object?> message) =>
    jsonDecode(jsonEncode(message));

void main() {
  group('OverlayConfig', () {
    test('经 JSON 往返后保留各栏房间、布局与 opacity', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(const OverlayConfig(
          webRids: <String>['735', '736', '737', '738'],
          layout: OverlayLayout.quad,
          opacity: 0.6,
        ).toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.webRids, <String>['735', '736', '737', '738']);
      expect(parsed.layout, OverlayLayout.quad);
      expect(parsed.opacity, 0.6);
    });

    test('缺省 layout 按房间数推断为 4 栏，缺省 opacity 回落为 0.8', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(<String, Object?>{
          'type': 'config',
          'webRids': <String>['1', '2', '3', '4'],
        }),
      );
      expect(parsed, isNotNull);
      expect(parsed!.layout, OverlayLayout.quad);
      expect(parsed.opacity, 0.8);
    });

    test('空白房间号被剔除，单栏布局只绑定一个房间', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(<String, Object?>{
          'type': 'config',
          'webRids': <String>[' 123 ', '', '  '],
          'layout': 'single',
        }),
      );
      expect(parsed, isNotNull);
      expect(parsed!.webRids, <String>['123']);
      expect(parsed.layout, OverlayLayout.single);
    });

    test('非 config 消息、无 webRids、无有效房间、非 Map 均返回 null', () {
      expect(
        OverlayConfig.tryParse(roundTrip(<String, Object?>{'type': 'state'})),
        isNull,
      );
      expect(
        OverlayConfig.tryParse(
          roundTrip(<String, Object?>{
            'type': 'config',
            'webRids': <String>[],
          }),
        ),
        isNull,
      );
      expect(
        OverlayConfig.tryParse(
          roundTrip(<String, Object?>{
            'type': 'config',
            'webRids': <String>[''],
          }),
        ),
        isNull,
      );
      expect(OverlayConfig.tryParse('config'), isNull);
      expect(OverlayConfig.tryParse(null), isNull);
    });
  });

  group('OverlayLayout', () {
    test('栏位数与按房间数的回落规则', () {
      expect(OverlayLayout.single.paneCount, 1);
      expect(OverlayLayout.quad.paneCount, 4);
      // 单栏只有一格，2 个及以上房间必须按 4 栏展示，否则多出的房间看不到。
      expect(OverlayLayout.fromRoomCount(1), OverlayLayout.single);
      expect(OverlayLayout.fromRoomCount(2), OverlayLayout.quad);
      expect(OverlayLayout.fromRoomCount(4), OverlayLayout.quad);
    });
  });

  group('OverlayStatus', () {
    test('经 JSON 往返后保留 stage、received、webRid、error', () {
      final OverlayStatus? parsed = OverlayStatus.tryParse(
        roundTrip(const OverlayStatus(
          stage: LiveSessionStage.live,
          received: 42,
          webRid: '735',
          error: 'boom',
        ).toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.stage, LiveSessionStage.live);
      expect(parsed.received, 42);
      expect(parsed.webRid, '735');
      expect(parsed.error, 'boom');
    });

    test('未知 stage 回落为 idle，非 state 消息返回 null', () {
      final OverlayStatus? parsed = OverlayStatus.tryParse(
        roundTrip(<String, Object?>{
          'type': 'state',
          'stage': 'no_such_stage',
          'received': 1,
        }),
      );
      expect(parsed, isNotNull);
      expect(parsed!.stage, LiveSessionStage.idle);
      expect(
        OverlayStatus.tryParse(roundTrip(<String, Object?>{'type': 'config'})),
        isNull,
      );
    });
  });

  test('close 指令识别，主 App 构造的关闭载荷可被悬浮窗识别', () {
    expect(isOverlayCloseMessage(roundTrip(buildOverlayCloseMessage())), isTrue);
    expect(isOverlayCloseMessage(roundTrip(<String, Object?>{'type': 'close'})),
        isTrue);
    expect(
        isOverlayCloseMessage(roundTrip(<String, Object?>{'type': 'config'})),
        isFalse);
    expect(isOverlayCloseMessage(null), isFalse);
  });
}