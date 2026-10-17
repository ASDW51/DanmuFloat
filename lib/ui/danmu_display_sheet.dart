// 弹幕页的就地显示调节面板（#145）。
//
// 为什么单独抽成一个组件：弹幕页与悬浮窗读的是同一批弹幕，但只有悬浮窗能随手调
// 字号 / 透明度；退到 App 内想调大一点字号，得退出页面 → 设置页 → 拖滑杆 → 再回来。
// 这个面板把三项与设置页同源的调节搬进弹幕页，同时保持**一份偏好、一条落盘路径**。
//
// 为什么用 OverlayPrefsPatch 而不是整份 OverlayPrefs 写回：这是 #97 的教训——
// 弹幕页与设置页可能同时在改同一份偏好，拿进页快照整份 copyWith 写回，会把别处
// 刚改的值静默覆盖回旧值。这里每个滑杆只回报**自己那一个字段**，上层用
// appliedPatch 增量合并，谁也没动过的字段就不会被碰。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:flutter/material.dart';

/// 就地显示调节面板：字号 / 背景透明度 / 滚动速度。
///
/// [initial] 只用来摆滑杆的初始位置（打开面板那一刻的值），面板自己不持有
/// 「当前偏好」——真正的写回由 [onChanged] 增量交给上层。
class DanmuDisplaySheet extends StatefulWidget {
  const DanmuDisplaySheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  /// 打开面板那一刻的偏好快照，仅用于滑杆初始位置。
  final OverlayPrefs initial;

  /// 增量写回：只带用户这次真正动过的字段。
  ///
  /// `persist == false` 表示拖动中的实时预览，上层只更新界面、不落盘；
  /// `persist == true` 表示松手，此时才写文件（与设置页同一口径）。
  final void Function(OverlayPrefsPatch patch, {required bool persist})
  onChanged;

  @override
  State<DanmuDisplaySheet> createState() => _DanmuDisplaySheetState();
}

class _DanmuDisplaySheetState extends State<DanmuDisplaySheet> {
  late double _opacity = widget.initial.opacity;
  late double _fontSize = widget.initial.fontSize;
  late double _scrollSpeed = widget.initial.scrollSpeed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    '显示设置',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('danmuDisplayClose'),
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            _buildSlider(
              keyName: 'danmuDisplayOpacity',
              title: '弹幕背景透明度　${_opacity.toStringAsFixed(2)}',
              hint: '越低越透。与悬浮窗、设置页是同一个值。',
              value: _opacity,
              min: minOverlayOpacity,
              max: maxOverlayOpacity,
              divisions: 20,
              onValue: (double value) {
                setState(() => _opacity = value);
                widget.onChanged(
                  OverlayPrefsPatch(opacity: value),
                  persist: false,
                );
              },
              onEnd: (double value) {
                setState(() => _opacity = value);
                widget.onChanged(
                  OverlayPrefsPatch(opacity: value),
                  persist: true,
                );
              },
            ),
            _buildSlider(
              keyName: 'danmuDisplayFontSize',
              title: '弹幕字号　${_fontSize.toStringAsFixed(0)}',
              hint: '悬浮窗与 App 内弹幕页都按此字号显示。',
              value: _fontSize,
              min: minDanmuFontSize,
              max: maxDanmuFontSize,
              divisions: (maxDanmuFontSize - minDanmuFontSize).round(),
              onValue: (double value) {
                setState(() => _fontSize = value);
                widget.onChanged(
                  OverlayPrefsPatch(fontSize: value),
                  persist: false,
                );
              },
              onEnd: (double value) {
                setState(() => _fontSize = value);
                widget.onChanged(
                  OverlayPrefsPatch(fontSize: value),
                  persist: true,
                );
              },
            ),
            _buildSlider(
              keyName: 'danmuDisplayScrollSpeed',
              title: '滚动速度　${_scrollSpeed.toStringAsFixed(2)}x',
              hint: '越小滚得越慢、越好读。',
              value: _scrollSpeed,
              min: minDanmuScrollSpeed,
              max: maxDanmuScrollSpeed,
              divisions: ((maxDanmuScrollSpeed - minDanmuScrollSpeed) / 0.25)
                  .round(),
              onValue: (double value) {
                setState(() => _scrollSpeed = value);
                widget.onChanged(
                  OverlayPrefsPatch(scrollSpeed: value),
                  persist: false,
                );
              },
              onEnd: (double value) {
                setState(() => _scrollSpeed = value);
                widget.onChanged(
                  OverlayPrefsPatch(scrollSpeed: value),
                  persist: true,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 一行滑杆：标题带当前值，下面一句说明（与设置页 `_SliderGroup` 同口径）。
  ///
  /// 上下限一律取公共常量，不在这里另写一份数字：两处口径一旦分裂，用户就会
  /// 在弹幕页拖到一个设置页根本给不出的值（#145 验收第 3 条）。
  Widget _buildSlider({
    required String keyName,
    required String title,
    required String hint,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onValue,
    required ValueChanged<double> onEnd,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(title, style: const TextStyle(fontSize: 14)),
      Slider(
        key: ValueKey<String>(keyName),
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onValue,
        onChangeEnd: onEnd,
      ),
      Text(
        hint,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}
