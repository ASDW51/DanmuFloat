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
    test('经 JSON 往返后保留 webRid 与 opacity', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(const OverlayConfig(webRid: '7350000000000000001', opacity: 0.6)
            .toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.webRid, '7350000000000000001');
      expect(parsed.opacity, 0.6);
    });

    test('缺省 opacity 回落为 0.8', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(<String, Object?>{'type': 'config', 'webRid': '123'}),
      );
      expect(parsed, isNotNull);
      expect(parsed!.opacity, 0.8);
    });

    test('非 config 消息、webRid 为空、非 Map 均返回 null', () {
      expect(
        OverlayConfig.tryParse(roundTrip(<String, Object?>{'type': 'state'})),
        isNull,
      );
      expect(
        OverlayConfig.tryParse(
          roundTrip(<String, Object?>{'type': 'config', 'webRid': ''}),
        ),
        isNull,
      );
      expect(OverlayConfig.tryParse('config'), isNull);
      expect(OverlayConfig.tryParse(null), isNull);
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

  test('close 指令识别', () {
    expect(isOverlayCloseMessage(roundTrip(<String, Object?>{'type': 'close'})),
        isTrue);
    expect(
        isOverlayCloseMessage(roundTrip(<String, Object?>{'type': 'config'})),
        isFalse);
    expect(isOverlayCloseMessage(null), isFalse);
  });
}