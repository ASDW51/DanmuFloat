import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/material.dart';

/// 悬浮窗配色主题（第 6 轮 UX-28）：把原先写死在 `OverlayPalette` 里的两套常量
/// 提升为「一份可 JSON 化、可被用户覆盖的纯数据」。
///
/// 为什么单独抽一个文件：`OverlayPalette` 是 widget 唯一可读的运行时对象，但它自己
/// 是 `const` 的两套取值（深/浅），用户改不了；配色一旦要开放给用户，就必须有
/// 「主题 = 一组角色取值」这一层数据，才能做到「预设 + 元素级覆盖」而不新增第二条
/// 取色路径。约定：**widget 仍然只读 `OverlayPalette`**，改的是它怎么被造出来。
///
/// 兼容钉子：`dark` / `light` 两个预设的每个字段都必须与 `overlay_page.dart` 里原有的
/// `OverlayPalette.darkPalette` / `lightPalette` **逐字段相等**，由
/// `test/overlay_theme_test.dart` 直接断言，保证默认外观零突变。
class OverlayTheme {
  const OverlayTheme({
    required this.id,
    required this.isLight,
    required this.body,
    required this.secondary,
    required this.chrome,
    required this.divider,
    required this.bannerBg,
    required this.maskColor,
    required this.border,
    required this.userAccent,
    required this.levelColor,
    required this.fanLevelColor,
    required this.activeColor,
    required this.highlightStyle,
  });

  /// 主题标识：落盘与下发都用它（未知值一律回落 [dark]，不崩不半残）。
  final String id;

  /// 是否为浅色系主题。类型前缀色等派生配色仍按它二选一（不开放给用户）。
  final bool isLight;

  /// 正文默认色。
  final Color body;

  /// 次要文字：状态提示、空列表占位、切换箭头等。
  final Color secondary;

  /// 栏目标识行的主播名、按钮文字等较醒目的文字。
  final Color chrome;

  /// 分隔线（栏间、标题行下方）。
  final Color divider;

  /// 底部进场单行底色。
  final Color bannerBg;

  /// 弹幕背景蒙版的基础色（再乘用户设置的窗口不透明度）。
  final Color maskColor;

  /// 窗口边框色。
  final Color border;

  /// 用户昵称色。
  final Color userAccent;

  /// 荣誉等级（Lv.x）色。
  final Color levelColor;

  /// 粉丝灯牌等级色。
  final Color fanLevelColor;

  /// 「已生效」状态色：暂停中 / 焦点态按钮等。
  final Color activeColor;

  /// 高亮词样式：与「高亮词」功能耦合，属语义色，不开放单独覆盖。
  final TextStyle highlightStyle;

  /// 可被用户按角色覆盖的颜色键（顺序即设置页的展示顺序）。
  static const List<String> colorKeys = <String>[
    'body',
    'secondary',
    'chrome',
    'userAccent',
    'levelColor',
    'fanLevelColor',
    'divider',
    'bannerBg',
    'border',
    'maskColor',
    'activeColor',
  ];

  /// 深邃（默认）：逐字段等于原有 `darkPalette`。
  static const OverlayTheme dark = OverlayTheme(
    id: 'dark',
    isLight: false,
    body: Colors.white,
    secondary: Colors.white54,
    chrome: Colors.white,
    divider: Colors.white24,
    bannerBg: Colors.white10,
    maskColor: Colors.black,
    border: Colors.white24,
    userAccent: Colors.lightBlueAccent,
    levelColor: Colors.amber,
    fanLevelColor: Colors.purpleAccent,
    activeColor: Colors.greenAccent,
    highlightStyle: TextStyle(
      color: Colors.yellowAccent,
      fontWeight: FontWeight.bold,
      backgroundColor: Color(0x38FFEB3B),
    ),
  );

  /// 清爽：逐字段等于原有 `lightPalette`。
  static const OverlayTheme light = OverlayTheme(
    id: 'light',
    isLight: true,
    body: Color(0xFF1B1B1B),
    secondary: Colors.black54,
    chrome: Colors.black87,
    divider: Colors.black26,
    bannerBg: Colors.black12,
    maskColor: Colors.white,
    border: Colors.black26,
    userAccent: Color(0xFF1565C0),
    levelColor: Color(0xFF8D6E00),
    fanLevelColor: Color(0xFF7B1FA2),
    activeColor: Color(0xFF2E7D32),
    highlightStyle: TextStyle(
      color: Color(0xFF7A4F00),
      fontWeight: FontWeight.bold,
      backgroundColor: Color(0x55FFC107),
    ),
  );

  /// 高对比：强光环境或视力受限时用。纯黑底 + 纯白正文，正文类配色 ≥7:1，
  /// 昵称 / 等级这类点缀色 ≥4.5:1（取值只动明度、不换色相，避免"换了个颜色"）。
  static const OverlayTheme contrast = OverlayTheme(
    id: 'contrast',
    isLight: false,
    body: Colors.white,
    secondary: Color(0xFFE6E6E6),
    chrome: Colors.white,
    divider: Color(0x66FFFFFF),
    bannerBg: Color(0x1FFFFFFF),
    maskColor: Colors.black,
    border: Color(0x8AFFFFFF),
    userAccent: Color(0xFF8FD3FF),
    levelColor: Color(0xFFFFD54F),
    fanLevelColor: Color(0xFFE1BEE7),
    activeColor: Color(0xFF69F0AE),
    highlightStyle: TextStyle(
      color: Color(0xFFFFE082),
      fontWeight: FontWeight.bold,
      backgroundColor: Color(0x55FFB300),
    ),
  );

  /// 护眼（暖暗）：夜间长时间观看时压低蓝光，用暖底 + 米白正文，
  /// 点缀色同步降饱和，避免在暖底上跳出刺眼的纯色。
  static const OverlayTheme sepia = OverlayTheme(
    id: 'sepia',
    isLight: false,
    body: Color(0xFFE8DFD0),
    secondary: Color(0xFFC9BDA8),
    chrome: Color(0xFFF0E6D2),
    divider: Color(0x33FFE9C4),
    bannerBg: Color(0x14FFE9C4),
    maskColor: Color(0xFF1A1713),
    border: Color(0x40FFE9C4),
    userAccent: Color(0xFFA8C7E8),
    levelColor: Color(0xFFE2C070),
    fanLevelColor: Color(0xFFC7A6D6),
    activeColor: Color(0xFF8FD5A6),
    highlightStyle: TextStyle(
      color: Color(0xFFFFE082),
      fontWeight: FontWeight.bold,
      backgroundColor: Color(0x33FFB300),
    ),
  );

  /// 全部内置预设（设置页按此顺序展示）。
  static const List<OverlayTheme> presets = <OverlayTheme>[
    dark,
    light,
    contrast,
    sepia,
  ];

  /// 按标识取预设；未知标识回落 [dark]——旧配置里没有主题标识时也走这里，
  /// 从而保持「默认深色」这一既有外观。
  static OverlayTheme preset(String id) {
    for (final OverlayTheme theme in presets) {
      if (theme.id == id) return theme;
    }
    return dark;
  }

  /// 合并元素级覆盖：[overrides] 的键是 [colorKeys] 中的角色名，值是 ARGB。
  ///
  /// 未知角色名与非法值一律忽略（不是整表丢弃），这样后续版本删改角色时，
  /// 旧配置里多出来的键不会让整份配色失效。
  OverlayTheme resolve(Map<String, int> overrides) {
    if (overrides.isEmpty) return this;
    final Map<String, Color> applied = <String, Color>{};
    for (final MapEntry<String, int> entry in overrides.entries) {
      if (!colorKeys.contains(entry.key)) continue;
      final Color? parsed = parseArgb(entry.value);
      if (parsed == null) continue;
      applied[entry.key] = parsed;
    }
    return copyWithColors(applied);
  }

  /// 按角色名覆盖颜色；未出现在 [colors] 里的角色保持原值。
  OverlayTheme copyWithColors(Map<String, Color> colors) => OverlayTheme(
    id: id,
    isLight: isLight,
    body: colors['body'] ?? body,
    secondary: colors['secondary'] ?? secondary,
    chrome: colors['chrome'] ?? chrome,
    divider: colors['divider'] ?? divider,
    bannerBg: colors['bannerBg'] ?? bannerBg,
    maskColor: colors['maskColor'] ?? maskColor,
    border: colors['border'] ?? border,
    userAccent: colors['userAccent'] ?? userAccent,
    levelColor: colors['levelColor'] ?? levelColor,
    fanLevelColor: colors['fanLevelColor'] ?? fanLevelColor,
    activeColor: colors['activeColor'] ?? activeColor,
    highlightStyle: highlightStyle,
  );

  /// 取某个角色的当前取值，供设置页展示色块与「恢复默认」使用。
  Color colorOf(String key) => _pick(key);

  Color _pick(String key) => switch (key) {
    'body' => body,
    'secondary' => secondary,
    'chrome' => chrome,
    'userAccent' => userAccent,
    'levelColor' => levelColor,
    'fanLevelColor' => fanLevelColor,
    'divider' => divider,
    'bannerBg' => bannerBg,
    'border' => border,
    'maskColor' => maskColor,
    'activeColor' => activeColor,
    _ => body,
  };

  /// 转成 widget 唯一可读的运行时对象。
  OverlayPalette toPalette() => OverlayPalette(
    isLight: isLight,
    body: body,
    secondary: secondary,
    chrome: chrome,
    divider: divider,
    bannerBg: bannerBg,
    maskColor: maskColor,
    border: border,
    userAccent: userAccent,
    levelColor: levelColor,
    fanLevelColor: fanLevelColor,
    activeColor: activeColor,
    highlightStyle: highlightStyle,
  );

  /// 把落盘/下发的整数解析成不透明色：非 int、越界、带 alpha（透明度）一律判非法。
  ///
  /// 为什么要求 alpha 必须为 255：角色色最终会与蒙版相乘渲染，允许半透明会让
  /// 「用户选的颜色」与「屏幕上看到的颜色」不一致，对比度校验也就失去意义；
  /// 需要半透明的元素（分割线、边框、进场底色）在预设里已经写死了自己的 alpha。
  static Color? parseArgb(Object? raw) {
    if (raw is! int) return null;
    if (raw < 0 || raw > 0xFFFFFFFF) return null;
    final int alpha = (raw >> 24) & 0xFF;
    if (alpha != 0xFF) return null;
    return Color(raw);
  }
}
