// 弹幕展示口径：悬浮窗与 App 内弹幕页共用，避免两处过滤/文案各写一份后走样。
//
// 口径来源（design.md 11.7 与 prd F6）：
// - 列表只保留聊天类（普通 / 飘屏 / 特权），礼物、点赞、关注、榜单入列无意义
// - 进场消息固定在底部单行
// - 房间统计只贡献在线人数，不进列表
import 'package:danmu_float/danmu/model/danmaku_event.dart';

/// 是否属于列表展示的聊天类弹幕。
bool isChatKind(DanmakuKind kind) =>
    kind == DanmakuKind.chat ||
    kind == DanmakuKind.screenChat ||
    kind == DanmakuKind.privilegeScreenChat;

/// 弹幕流是否与本会话相关。
///
/// 房间统计必须放行：它不进列表，但在线人数只看它
/// （`DanmakuEvent.onlineCount`），挡掉会让人数一直为 0。
bool isStreamRelevant(DanmakuKind kind) =>
    kind == DanmakuKind.member ||
    kind == DanmakuKind.roomStats ||
    isChatKind(kind);

/// 聊天类的类型标记：普通弹幕无前缀，飘屏 / 特权带前缀。
String? danmakuTypeLabel(DanmakuKind kind) => switch (kind) {
      DanmakuKind.screenChat => '飘屏',
      DanmakuKind.privilegeScreenChat => '特权',
      _ => null,
    };

/// 在线人数：过万折算为「x.x万」，与平台展示口径一致。
String formatOnlineCount(int value) =>
    value >= 10000 ? '${(value / 10000).toStringAsFixed(1)}万' : '$value';

/// 弹幕时间：毫秒时间戳 → HH:mm:ss，无效时间戳给占位。
String formatClock(int timeMs) {
  if (timeMs <= 0) return '--:--:--';
  final DateTime time = DateTime.fromMillisecondsSinceEpoch(timeMs);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}