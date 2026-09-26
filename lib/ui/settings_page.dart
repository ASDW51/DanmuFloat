// 设置页：悬浮窗样式（prd F2 / F5）——背景透明度、弹幕字号、窗口尺寸。
//
// 拖动过程只做实时预览（persist: false，只推给悬浮窗），松手才落盘，
// 免得一次拖动写几十次文件。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.prefs, required this.onChanged});

  /// 进入页面时的偏好快照。
  final OverlayPrefs prefs;

  /// 偏好变化回调；[persist] 为真时调用方负责落盘。
  final void Function(OverlayPrefs prefs, {required bool persist}) onChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late OverlayPrefs _prefs = widget.prefs;

  void _apply(OverlayPrefs next, {required bool persist}) {
    setState(() => _prefs = next);
    widget.onChanged(next, persist: persist);
  }

  @override
  Widget build(BuildContext context) {
    // 窗口不能大于屏幕，滑杆上限按当前设备收紧；存量偏好超出时显示值也一并收敛。
    final Size screen = MediaQuery.sizeOf(context);
    final double widthLimit = overlayWidthLimit(screen.width);
    final double heightLimit = overlayHeightLimit(screen.height);
    final double widthValue =
        _prefs.windowWidth.clamp(minOverlayWidth, widthLimit);
    final double heightValue =
        _prefs.windowHeight.clamp(minOverlayHeight, heightLimit);
    final ({double width, double height}) recommended = fitOverlaySize(
      recommendedOverlaySize(_prefs.webRids.length),
      screenWidth: screen.width,
      screenHeight: screen.height,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: <Widget>[
          const _SectionTitle('悬浮窗样式'),
          _SliderGroup(
            title: '弹幕背景透明度　${_prefs.opacity.toStringAsFixed(2)}',
            hint: '越低越透。只影响弹幕背景蒙版，不改变悬浮窗整体与文字。',
            value: _prefs.opacity,
            min: minOverlayOpacity,
            max: maxOverlayOpacity,
            divisions: 12,
            onChanged: (double value) => _apply(
              _prefs.copyWith(opacity: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(opacity: value),
              persist: true,
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('弹幕字号'),
          _SliderGroup(
            title: '弹幕字号　${_prefs.fontSize.toStringAsFixed(0)}',
            hint: '悬浮窗与 App 内弹幕页都按此字号显示；多栏时按栏数自动缩小。',
            value: _prefs.fontSize,
            min: minDanmuFontSize,
            max: maxDanmuFontSize,
            divisions: (maxDanmuFontSize - minDanmuFontSize).round(),
            onChanged: (double value) => _apply(
              _prefs.copyWith(fontSize: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(fontSize: value),
              persist: true,
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('悬浮窗尺寸（整体）'),
          _SliderGroup(
            title: '整体宽度　${widthValue.toStringAsFixed(0)}',
            hint: '整个悬浮窗的宽度，多栏时各栏在内部自动平分，不需要按栏设置。',
            value: widthValue,
            min: minOverlayWidth,
            max: widthLimit,
            divisions: ((widthLimit - minOverlayWidth) / 20).round(),
            onChanged: (double value) => _apply(
              _prefs.copyWith(windowWidth: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(windowWidth: value),
              persist: true,
            ),
          ),
          _SliderGroup(
            title: '整体高度　${heightValue.toStringAsFixed(0)}',
            hint: '整个悬浮窗的高度，各栏等分；高度只影响可见弹幕条数，不影响连接。',
            value: heightValue,
            min: minOverlayHeight,
            max: heightLimit,
            divisions: ((heightLimit - minOverlayHeight) / 20).round(),
            onChanged: (double value) => _apply(
              _prefs.copyWith(windowHeight: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(windowHeight: value),
              persist: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                OutlinedButton.icon(
                  icon: const Icon(Icons.fit_screen_outlined),
                  label: const Text('按栏数推荐尺寸'),
                  onPressed: () => _applyRecommendedSize(recommended),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '按上次勾选的 ${_prefs.webRids.length} 栏推荐，'
                    '${recommended.width.toStringAsFixed(0)}'
                    '×'
                    '${recommended.height.toStringAsFixed(0)}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  /// 按上次勾选的栏数套用推荐尺寸；没勾过任何栏位时按单栏推荐。
  void _applyRecommendedSize(({double width, double height}) size) {
    _apply(
      _prefs.copyWith(windowWidth: size.width, windowHeight: size.height),
      persist: true,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
}

/// 一条带说明文字的滑杆。
///
/// 不用 ListTile 包 Slider：subtitle 的高度约束会把滑杆压扁。
class _SliderGroup extends StatelessWidget {
  const _SliderGroup({
    required this.title,
    required this.hint,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String title;
  final String hint;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 8),
            Text(title),
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: value.toStringAsFixed(0),
              // 拖动中实时预览，松手才落盘。
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
            Text(
              hint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
}
