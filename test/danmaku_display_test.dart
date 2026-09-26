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
    expect(danmakuTypeLabel(DanmakuKind.gift), isNull);
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
}