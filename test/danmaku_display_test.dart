// 弹幕展示口径：悬浮窗与 App 内弹幕页共用，这里锁死过滤范围与文案格式。
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('列表只保留聊天类：普通 / 飘屏 / 特权', () {
    expect(isChatKind(DanmakuKind.chat), isTrue);
    expect(isChatKind(DanmakuKind.screenChat), isTrue);
    expect(isChatKind(DanmakuKind.privilegeScreenChat), isTrue);
    expect(isChatKind(DanmakuKind.gift), isFalse);
    expect(isChatKind(DanmakuKind.member), isFalse);
    expect(isChatKind(DanmakuKind.roomStats), isFalse);
    expect(isChatKind(DanmakuKind.other), isFalse);
  });

  test('订阅范围含房间统计：它不进列表但在线人数只看它', () {
    expect(isStreamRelevant(DanmakuKind.roomStats), isTrue);
    expect(isStreamRelevant(DanmakuKind.member), isTrue);
    expect(isStreamRelevant(DanmakuKind.chat), isTrue);
    expect(isStreamRelevant(DanmakuKind.gift), isFalse);
    expect(isStreamRelevant(DanmakuKind.roomRank), isFalse);
    expect(isStreamRelevant(DanmakuKind.other), isFalse);
  });

  test('类型前缀：普通弹幕无前缀', () {
    expect(danmakuTypeLabel(DanmakuKind.screenChat), '飘屏');
    expect(danmakuTypeLabel(DanmakuKind.privilegeScreenChat), '特权');
    expect(danmakuTypeLabel(DanmakuKind.chat), isNull);
    // F13 起礼物可作为可选展示类型，带「礼物」前缀。
    expect(danmakuTypeLabel(DanmakuKind.gift), '礼物');
  });

  test('在线人数过万折算为 x.x万', () {
    expect(formatOnlineCount(0), '0');
    expect(formatOnlineCount(9999), '9999');
    expect(formatOnlineCount(10000), '1.0万');
    expect(formatOnlineCount(123456), '12.3万');
  });

  test('时间戳为毫秒，0 或负数给占位', () {
    expect(formatClock(0), '--:--:--');
    expect(formatClock(-1), '--:--:--');
    final int ms = DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch;
    expect(formatClock(ms), '03:04:05');
  });

  test('滚动速度越界收敛，NaN 回落默认值', () {
    expect(clampDanmuScrollSpeed(0.1), minDanmuScrollSpeed);
    expect(clampDanmuScrollSpeed(9), maxDanmuScrollSpeed);
    expect(clampDanmuScrollSpeed(1.25), 1.25);
    expect(clampDanmuScrollSpeed(double.nan), defaultDanmuScrollSpeed);
  });

  test('滚动动画时长与距离成正比：距离越大时长越长', () {
    // 900 距离 ÷ 900px/s = 1s。
    expect(danmuScrollDuration(900, 1), const Duration(seconds: 1));
    expect(
      danmuScrollDuration(1800, 1).inMilliseconds,
      greaterThan(danmuScrollDuration(900, 1).inMilliseconds),
    );
  });

  test('滚动速度越大时长越短，但被收敛在上下限内', () {
    expect(
      danmuScrollDuration(900, 3).inMilliseconds,
      lessThan(danmuScrollDuration(900, 0.5).inMilliseconds),
    );
    // 距离为 0 或非法时仍给一个最小可见时长，不会是 0。
    expect(danmuScrollDuration(0, 1).inMilliseconds, 80);
    expect(danmuScrollDuration(double.nan, 1).inMilliseconds, 80);
    // 超长距离封顶，避免动画明显落后于直播。
    expect(danmuScrollDuration(100000, 0.5).inMilliseconds, 1200);
  });
}