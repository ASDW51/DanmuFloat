// 高性能模式强制确认（prd F4）：首页开窗与悬浮窗内加栏共用同一份实现与文案。
//
// 抽成公共实现而不是各写一份：两处规则必须一致，否则用户会以为「主 App 提醒、
// 悬浮窗里随便加」，正是 UX-05 要消除的割裂感。
import 'package:flutter/material.dart';

/// 弹出「高性能模式」确认；返回用户是否确认继续。
///
/// 刻意不提供「不再提示」：这是 prd F4 的强制确认，弱化它等于让低端机用户在不知情
/// 的情况下开满栏位（AGENTS.md 第 5 节）。
Future<bool> confirmHighPerformance(BuildContext context, int paneCount) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('高性能模式'),
      content: Text(
        '本次要开 $paneCount 栏：栏数越多，同时维持的弹幕连接与绘制负载越高，'
        '低端设备可能出现卡顿或发热。建议先按栏数调大悬浮窗尺寸，并关闭不必要的栏。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('继续开启'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
