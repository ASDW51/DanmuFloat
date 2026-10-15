import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:flutter/material.dart';

/// 弹幕页顶部状态栏（UX-17）：状态行 + 房间标题 + 错误 / 悬浮窗摘要。
///
/// 为什么单独抽成组件：这一行原本是 `danmu_page.dart` 里一个**没有任何 Flexible /
/// Wrap 的裸 Row**，而在线人数自 UX-12 起是完整数字（`formatOnlineCount` 不再折算成
/// 「x.x 万」），5 位数在 360dp 机型上必然把「在线人数 / 连接状态」挤出屏幕——正是
/// 悬浮窗侧 UX-12 已经修过的那类问题。`DanmuPage` 有 841 行却零 widget 测试覆盖，
/// 溢出一直没人拦；搬到这里后这一行第一次能被单独挂载断言。
///
/// 布局约定：信息**一条都不删**（UX-12 已裁定人数不可省略），装不下时用 [Wrap]
/// 整块换行，而不是裁剪文本或藏起某一段。
class DanmuStatusBar extends StatelessWidget {
  const DanmuStatusBar({
    super.key,
    required this.stageLabel,
    required this.stageColor,
    required this.received,
    this.online = 0,
    this.connectionLabel,
    this.retryable = false,
    this.onRetry,
    this.roomTitle,
    this.errorMessage,
    this.overlaySummary,
  });

  /// 状态词（由页面按会话阶段算好，「自动复检中」这类附加信息也在里面）。
  final String stageLabel;

  /// 状态点与状态词共用的颜色。
  final Color stageColor;

  /// 已收到的弹幕条数。
  final int received;

  /// 在线人数；0 表示未知，不显示这一段。
  final int online;

  /// 连接状态文案（`connectionStateLabel` 的结果）；null 表示无会话，不显示。
  final String? connectionLabel;

  /// 是否给出「重试」出口（失败 / 停止复检时为真）。
  final bool retryable;

  /// 「重试」的点击回调。
  final VoidCallback? onRetry;

  /// 房间标题；为空则不显示这一行。
  final String? roomTitle;

  /// 失败原因；同一阶段内一直保留（UX-14），非空时以红色显示。
  final String? errorMessage;

  /// 悬浮窗侧摘要（阶段 / 已收条数 / 错误），由页面拼好传入。
  final String? overlaySummary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 用 Wrap 而不是 Row：装不下时整段换到第二行，任何一段都不会被裁掉。
          // spacing 是同一行内各项的间距，runSpacing 是换行后的行距，两者都取原来
          // 手工 SizedBox 的 12，视觉上与旧版一致。
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: <Widget>[
              // 状态点与状态词必须成组，否则换行时会把点单独留在上一行。
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: stageColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(stageLabel, style: TextStyle(color: stageColor)),
                ],
              ),
              // 失败 / 停止复检后给可点出口（UX-02）：详情页只能退出去重进，
              // 那会丢掉已收到的弹幕与当前滚动位置。
              // 这里不写 minimumSize / tapTargetSize 覆盖：旧版把按钮压到 ~17dp，
              // 是「能看见但点不准」，交给 Material 默认的 40/48 触控高度（UX-17）。
              if (retryable)
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              Text('已收 $received 条'),
              if (online > 0) Text('在线 ${formatOnlineCount(online)}'),
              if (connectionLabel != null) Text('连接: $connectionLabel'),
            ],
          ),
          if (roomTitle != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(roomTitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (errorMessage != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(errorMessage!, style: const TextStyle(color: Colors.red)),
          ],
          if (overlaySummary != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              overlaySummary!,
              style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
