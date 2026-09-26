// 弹幕列表的「跟随底部」滚动（prd F2「滚动速度」）。
//
// 原实现是 jumpTo(maxScrollExtent) 瞬跳：消息突发时列表一帧铺满，滚过的内容
// 根本看不清。这里改成按速度平滑滚动，并做两件事：
// 1. 同一帧内的多次「有新消息」只触发一次滚动，避免每来一条就重启动画；
// 2. 时长按「距离 ÷ 速度」计算，视觉速度恒定，突发时也是匀速滚过。
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:flutter/widgets.dart';

/// 列表跟随底部的滚动控制器；悬浮窗各栏与 App 内弹幕页共用。
class DanmakuAutoScroller {
  DanmakuAutoScroller(this.controller);

  final ScrollController controller;

  /// 滚动速度倍数，由页面在偏好变化时更新。
  double speed = defaultDanmuScrollSpeed;

  bool _scheduled = false;
  bool _disposed = false;
  bool _animating = false;

  /// 是否正在执行自动滚动动画。
  ///
  /// 页面用它排除「自己滚动带来的位移」：自动滚动过程中列表自然不在底部，
  /// 若据此判定用户上滑，会误把自动滚动当成回溯。
  bool get animating => _animating;

  /// 标记「有新内容需要跟随」；同一帧内重复调用只滚动一次。
  void schedule() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed) return;
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    if (!controller.hasClients) return;
    final ScrollPosition position = controller.position;
    final double target = position.maxScrollExtent;
    final double distance = target - position.pixels;
    // 已在底部（或列表还没铺满）时不必启动动画，否则每帧都空转一次。
    if (distance <= 0.5) return;
    _animating = true;
    controller
        .animateTo(
      target,
      duration: danmuScrollDuration(distance, speed),
      curve: Curves.easeOut,
    )
        .whenComplete(() => _animating = false);
  }

  /// 立即跳到最新一条，不做动画：用户主动「跳到最新」时用。
  void jumpToLatest() {
    if (_disposed || !controller.hasClients) return;
    controller.jumpTo(controller.position.maxScrollExtent);
  }

  void dispose() {
    _disposed = true;
  }
}
