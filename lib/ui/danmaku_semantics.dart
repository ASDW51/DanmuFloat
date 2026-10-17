// 弹幕与悬浮窗的朗读标签（#135）。
//
// 为什么单独抽一个文件：同一条弹幕在弹幕页与悬浮窗里是两套各自的 Text.rich，
// 朗读标签若各写一份，两处迟早会不一致（「14:03」与「14:03:00」这种）。这里只留
// 一份拼装规则，两个页面都调它，测试也只测这一份。
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';

/// 一条弹幕的朗读标签，形如「14:03，礼物，昵称：正文」。
///
/// 时间、类型前缀、昵称都是**附加信息**，缺哪个就省哪段，不会留下空分隔符；
/// 正文永远在最后且一定出现——屏幕阅读器用户最需要的是「说了什么」。
String danmakuSemanticsLabel(DanmakuEvent event) {
  final List<String> parts = <String>[];
  final String clock = _clockOf(event.timeMs);
  if (clock.isNotEmpty) parts.add(clock);
  final String? mark = danmakuTypeLabel(event.kind);
  if (mark != null && mark.isNotEmpty) parts.add(mark);
  final String nick = event.user.nickName;
  if (nick.isNotEmpty) {
    parts.add('$nick：${event.text}');
  } else {
    parts.add(event.text);
  }
  return parts.join('，');
}

/// 毫秒时间戳转「时:分」；时间戳缺失（0 或非法）时返回空串，不显示 08:00 这种假时间。
String _clockOf(int timeMs) {
  if (timeMs <= 0) return '';
  final DateTime time = DateTime.fromMillisecondsSinceEpoch(timeMs);
  final String hour = time.hour.toString().padLeft(2, '0');
  final String minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// 逐栏状态点的朗读标签：「第 2 栏 · 已连接」。
///
/// 状态点只有颜色，色觉障碍与屏幕阅读器用户都拿不到这层信息，必须补等价文本。
String paneStageSemanticsLabel({required int index, required String stage}) =>
    '第 ${index + 1} 栏 · $stage';
