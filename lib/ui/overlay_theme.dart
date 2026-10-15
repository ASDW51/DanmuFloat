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
    required this.chromeBg,
    required this.menuBg,
    required this.typeScreenChat,
    required this.typePrivilegeScreenChat,
    required this.typeGift,
    required this.typeMember,
    required this.typeLike,
    required this.typeSocial,
    required this.typeRoomRank,
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
  /// 悬浮球与胶囊的底色。它们不承载文字，与菜单面板语义不同，因此是独立角色。
  final Color chromeBg;

  /// 菜单面板底色：窗内唯一承载文字的面板。
  final Color menuBg;

  /// 各类型弹幕的前缀与正文字色（prd F13 类型区分）。normal 之外的 7 类由主题给出，
  /// 不再按 isLight 猜——否则护眼/高对比主题会整片继承深色皮肤的亮色。
  final Color typeScreenChat;
  final Color typePrivilegeScreenChat;
  final Color typeGift;
  final Color typeMember;
  final Color typeLike;
  final Color typeSocial;
  final Color typeRoomRank;

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
    'chromeBg',
    'menuBg',
    'typeScreenChat',
    'typePrivilegeScreenChat',
    'typeGift',
    'typeMember',
    'typeLike',
    'typeSocial',
    'typeRoomRank',
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
    chromeBg: Colors.white70,
    menuBg: Color(0xF0FFFFFF),
    typeScreenChat: Colors.orangeAccent,
    typePrivilegeScreenChat: Colors.lightGreenAccent,
    typeGift: Colors.pinkAccent,
    typeMember: Colors.tealAccent,
    typeLike: Colors.redAccent,
    typeSocial: Colors.lightBlueAccent,
    typeRoomRank: Colors.amberAccent,
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
    chromeBg: Colors.black54,
    menuBg: Color(0xE6000000),
    typeScreenChat: Color(0xFFE65100),
    typePrivilegeScreenChat: Color(0xFF2E7D32),
    typeGift: Color(0xFFC2185B),
    typeMember: Color(0xFF00695C),
    typeLike: Color(0xFFC62828),
    typeSocial: Color(0xFF1565C0),
    typeRoomRank: Color(0xFF8D6E00),
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
    chromeBg: Colors.black,
    menuBg: Colors.black,
    typeScreenChat: Colors.orangeAccent,
    typePrivilegeScreenChat: Colors.lightGreenAccent,
    typeGift: Colors.pinkAccent,
    typeMember: Colors.tealAccent,
    typeLike: Colors.redAccent,
    typeSocial: Colors.lightBlueAccent,
    typeRoomRank: Colors.amberAccent,
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
    chromeBg: Color(0xE61A1713),
    menuBg: Color(0xFF1A1713),
    typeScreenChat: Color(0xFFFFB74D),
    typePrivilegeScreenChat: Color(0xFFAED581),
    typeGift: Color(0xFFF48FB1),
    typeMember: Color(0xFF80CBC4),
    typeLike: Color(0xFFE57373),
    typeSocial: Color(0xFF90CAF9),
    typeRoomRank: Color(0xFFFFD54F),
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
    chromeBg: colors['chromeBg'] ?? chromeBg,
    menuBg: colors['menuBg'] ?? menuBg,
    typeScreenChat: colors['typeScreenChat'] ?? typeScreenChat,
    typePrivilegeScreenChat: colors['typePrivilegeScreenChat'] ?? typePrivilegeScreenChat,
    typeGift: colors['typeGift'] ?? typeGift,
    typeMember: colors['typeMember'] ?? typeMember,
    typeLike: colors['typeLike'] ?? typeLike,
    typeSocial: colors['typeSocial'] ?? typeSocial,
    typeRoomRank: colors['typeRoomRank'] ?? typeRoomRank,
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
    'chromeBg' => chromeBg,
    'menuBg' => menuBg,
    'typeScreenChat' => typeScreenChat,
    'typePrivilegeScreenChat' => typePrivilegeScreenChat,
    'typeGift' => typeGift,
    'typeMember' => typeMember,
    'typeLike' => typeLike,
    'typeSocial' => typeSocial,
    'typeRoomRank' => typeRoomRank,
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
    chromeBg: chromeBg,
    menuBg: menuBg,
    typeScreenChat: typeScreenChat,
    typePrivilegeScreenChat: typePrivilegeScreenChat,
    typeGift: typeGift,
    typeMember: typeMember,
    typeLike: typeLike,
    typeSocial: typeSocial,
    typeRoomRank: typeRoomRank,
    highlightStyle: highlightStyle,
  );

  /// 会被对比度守卫校正的文字角色（分隔线 / 底色 / 边框不参与文字对比度）。
  static const List<String> textColorKeys = <String>[
    'body',
    'secondary',
    'chrome',
    'userAccent',
    'levelColor',
    'fanLevelColor',
    'activeColor',
  ];

  /// 把半透明色按 alpha 合成到 [background] 上。
  ///
  /// 为什么必须先合成再算对比度：`Color.computeLuminance()` 只看 RGB、忽略 alpha，
  /// 不合成的话 `Colors.white54` 会被算成 21:1，而它在黑底上实际约 6:1——断言会变成假的。
  static Color flattenOver(Color color, Color background) {
    final double alpha = color.a;
    if (alpha >= 1) return color;
    return Color.from(
      alpha: 1,
      red: color.r * alpha + background.r * (1 - alpha),
      green: color.g * alpha + background.g * (1 - alpha),
      blue: color.b * alpha + background.b * (1 - alpha),
    );
  }

  /// WCAG 相对亮度对比度：(L1 + 0.05) / (L2 + 0.05)，L 为较亮一方。
  ///
  /// 全项目唯一的对比度口径：测试与守卫都调它，避免各写一份实现后互相漂移。
  static double contrastRatio(Color foreground, Color background) {
    // 前景展平到背景上（半透明前景的真实观感）；背景按自身 RGB 计算——把背景
    // 「合成到自己身上」是无意义的，半透明底色要由调用方先展平到真实背衬上。
    final Color fg = flattenOver(foreground, background);
    final Color bg = background;
    final double l1 = fg.computeLuminance();
    final double l2 = bg.computeLuminance();
    final double hi = l1 > l2 ? l1 : l2;
    final double lo = l1 > l2 ? l2 : l1;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 把 [foreground] 的明度沿明度轴调整到与 [background] 至少 [minimum] 的对比度。
  ///
  /// 只动明度、**不碰色相与饱和度**：用户选的是「这个颜色」，我们只能在可读性上补救，
  /// 不能替他换成另一种颜色（色相偏移恒为 0，由单测钉住 <15°）。搜索按 1/20 步长从
  /// 当前明度向两侧走，命中即停，因此改动幅度总是最小的那一档。
  static Color ensureContrast(
    Color foreground,
    Color background, {
    double minimum = 4.5,
  }) {
    if (contrastRatio(foreground, background) >= minimum) return foreground;
    final HSVColor hsv = HSVColor.fromColor(flattenOver(foreground, background));
    for (int step = 1; step <= 20; step++) {
      final double delta = step / 20;
      for (final double value in <double>[
        hsv.value + delta,
        hsv.value - delta,
      ]) {
        if (value < 0 || value > 1) continue;
        final Color candidate = hsv.withValue(value).toColor();
        if (contrastRatio(candidate, background) >= minimum) return candidate;
      }
    }
    // 两侧都到不了（例如背景亮度卡在中间）：退回黑白中对比度更高的一侧，
    // 宁可改变观感也不能把不可读的文字留在屏幕上。
    return contrastRatio(Colors.white, background) >=
            contrastRatio(Colors.black, background)
        ? Colors.white
        : Colors.black;
  }

  /// 对全部文字角色施加对比度守卫；[minimum] 为可读性下限。
  ///
  /// 没有任何角色需要改动时直接返回 `this`（用 identical 断言钉住），这样「合规就
  /// 不动」是可测的，而不是每次 resolve 都产出一份新对象。
  OverlayTheme enforceTextContrast(double minimum) {
    final Map<String, Color> fixed = <String, Color>{};
    for (final String key in textColorKeys) {
      final Color current = colorOf(key);
      final Color guarded = ensureContrast(current, maskColor, minimum: minimum);
      if (guarded != current) fixed[key] = guarded;
    }
    if (fixed.isEmpty) return this;
    return copyWithColors(fixed);
  }

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
