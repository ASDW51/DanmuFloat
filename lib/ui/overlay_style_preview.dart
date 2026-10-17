// 设置页的样式实时预览卡（#143）。
//
// 为什么需要它：设置页所谓「实时预览」其实是把改动推给悬浮窗窗口（persist: false），
// **没开窗时调字号 / 透明度 / 配色，屏幕上不会有任何变化**，用户只能「改一下 → 去开窗
// → 看一眼 → 回来再改」。这张卡用当前偏好就地渲染几条示例弹幕，把第 7 轮钉下的
// 「设置页显示的值 == 渲染值」在主 App 侧也落到实处。
//
// 数据源必须是悬浮窗同一份 OverlayTheme / OverlayPalette：这里不写任何颜色常量，
// 全部经 [paletteFor] 从主题解析出来，测试直接断言渲染色与解析色逐位相等。
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';

/// 由主题标识 + 角色级覆盖解析出调色板（预览卡与悬浮窗共用同一条解析路径）。
OverlayPalette paletteFor({
  required String themeId,
  Map<String, int> overrides = const <String, int>{},
}) => OverlayTheme.preset(themeId).resolve(overrides).toPalette();

/// 样式预览卡：3 条示例弹幕，覆盖正文 / 昵称 / 等级 / 灯牌 / 类型前缀 / 高亮词 / 蒙版。
///
/// 可独立挂载，不依赖 `OverlayApp`（那边有「每文件只能 mount 一次」的静态单订阅流）。
class OverlayStylePreview extends StatelessWidget {
  const OverlayStylePreview({
    super.key,
    required this.themeId,
    this.overrides = const <String, int>{},
    this.opacity = 0.8,
    this.fontSize = 13,
  });

  /// 主题标识（预设 id）。
  final String themeId;

  /// 角色级颜色覆盖（设置页配色区改的值）。
  final Map<String, int> overrides;

  /// 弹幕背景蒙版透明度：直接参与预览，否则「调透明度看不到效果」的抱怨依旧成立。
  final double opacity;

  /// 预览字号：与真实弹幕页同一口径，用户改完立刻能在卡里看到大小变化。
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final OverlayPalette palette = paletteFor(
      themeId: themeId,
      overrides: overrides,
    );
    return Container(
      key: const ValueKey<String>('overlayStylePreview'),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.chromeBg,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '预览',
            style: TextStyle(fontSize: 12, color: palette.secondary),
          ),
          const SizedBox(height: 6),
          _line(
            keyName: 'overlayPreviewChat',
            palette: palette,
            spans: <InlineSpan>[
              TextSpan(
                text: '小明：',
                style: TextStyle(
                  color: palette.userAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextSpan(
                text: '这条弹幕长这样',
                style: TextStyle(color: palette.body),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _line(
            keyName: 'overlayPreviewGift',
            palette: palette,
            spans: <InlineSpan>[
              TextSpan(
                text: '礼物 ',
                style: TextStyle(
                  color: palette.typeColor(DanmakuKind.gift),
                  fontSize: fontSize - 2,
                ),
              ),
              TextSpan(
                text: 'Lv.12 ',
                style: TextStyle(
                  color: palette.levelColor,
                  fontSize: fontSize - 2,
                ),
              ),
              TextSpan(
                text: '灯牌7 ',
                style: TextStyle(
                  color: palette.fanLevelColor,
                  fontSize: fontSize - 2,
                ),
              ),
              TextSpan(
                text: '送出一个火箭',
                style: TextStyle(color: palette.body),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _line(
            keyName: 'overlayPreviewHighlight',
            palette: palette,
            spans: <InlineSpan>[
              TextSpan(
                text: '高亮词',
                style: TextStyle(
                  color: palette.body,
                  backgroundColor: palette.maskColor.withValues(alpha: opacity),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 一行示例弹幕：字号跟随 [fontSize]，蒙版透明度只影响底色不影响正文（与窗内一致）。
  Widget _line({
    required String keyName,
    required OverlayPalette palette,
    required List<InlineSpan> spans,
  }) => Container(
    key: ValueKey<String>(keyName),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: palette.maskColor.withValues(alpha: opacity),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text.rich(
      TextSpan(
        style: TextStyle(fontSize: fontSize),
        children: spans,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
  );
}
