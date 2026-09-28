// 主 App 与悬浮窗引擎之间的消息协议。
//
// 悬浮窗由 flutter_screen_overlay 在**独立 Flutter 引擎**中启动（前台服务进程内），
// 两个引擎不共享内存对象，房间配置与运行状态只能经 BasicMessageChannel 传递，
// 且载荷必须是 JSON 可序列化的（插件用 JSONMessageCodec）。
//
// 协议约定：
//   主 App → 悬浮窗：config（各栏要连接的房间 + 外观）/ style（只改外观）
//                    / filter（屏蔽与高亮）/ credential（手动粘贴的凭证）/ close（关闭悬浮窗）
//   悬浮窗 → 主 App：state（阶段、已收条数、错误摘要）
import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';

const String overlayConfigType = 'config';
const String overlayStyleType = 'style';
const String overlayFilterType = 'filter';
const String overlayRoomsType = 'rooms';
const String overlayCredentialType = 'credential';
const String overlayCloseType = 'close';
const String overlayStateType = 'state';

/// 弹幕背景蒙版不透明度的可调范围（prd F2）：0 为全透明（只见弹幕文字）、
/// 1 为完全不透明（完全遮住直播画面）。注意作用对象是蒙版，不是窗口整体。
const double minOverlayOpacity = 0.0;
const double maxOverlayOpacity = 1.0;
const double defaultOverlayOpacity = 0.8;

/// 把透明度收敛到可调范围；NaN 等非法值回落默认值，
/// 避免直接把非法值塞进 BoxDecoration 让渲染报错。
double clampOverlayOpacity(double value) {
  if (value.isNaN) return defaultOverlayOpacity;
  return value.clamp(minOverlayOpacity, maxOverlayOpacity);
}

/// 弹幕基准字号（dp）的可调范围与默认值（prd F5）。
const double minDanmuFontSize = 9;
const double maxDanmuFontSize = 24;
const double defaultDanmuFontSize = 13;

double clampDanmuFontSize(double value) {
  if (value.isNaN) return defaultDanmuFontSize;
  return value.clamp(minDanmuFontSize, maxDanmuFontSize);
}

/// 分栏时实际使用的字号：栏数越多格子越小，基准字号等比缩小，
/// 否则 9 栏下弹幕会撑破单元格。
double paneFontSize(double base, int paneCount) {
  final double clamped = clampDanmuFontSize(base);
  if (paneCount <= 1) return clamped;
  return paneCount <= 4 ? clamped * 0.85 : clamped * 0.7;
}

/// 悬浮窗窗口尺寸（dp）的可调范围与默认值（prd 4.2：单栏最小 200×150）。
const double minOverlayWidth = 200;
const double maxOverlayWidth = 1080;
const double defaultOverlayWidth = 400;
const double minOverlayHeight = 150;
const double maxOverlayHeight = 1600;
const double defaultOverlayHeight = 560;

double clampOverlayWidth(double value) {
  if (value.isNaN) return defaultOverlayWidth;
  return value.clamp(minOverlayWidth, maxOverlayWidth);
}

double clampOverlayHeight(double value) {
  if (value.isNaN) return defaultOverlayHeight;
  return value.clamp(minOverlayHeight, maxOverlayHeight);
}

/// 焦点模式（prd F7）下其余栏的处理方式：缩小让位，或整体隐藏。
const String focusBehaviorShrink = 'shrink';
const String focusBehaviorHide = 'hide';
const String defaultFocusBehavior = focusBehaviorShrink;

/// 收敛焦点模式取值：不认识的值一律回落「缩小」，避免下发出非法枚举。
String clampFocusBehavior(Object? value) =>
    value == focusBehaviorHide ? focusBehaviorHide : focusBehaviorShrink;

/// 设备实际允许的窗口宽度上限：固定上限与屏幕宽度取小。
///
/// 插件把宽高换算成物理像素后直接写进 Android WindowManager，
/// 超过屏幕的宽高会让窗口溢出屏幕，因此可用上限还要受当前设备约束。
double overlayWidthLimit(double screenWidth) =>
    screenWidth.clamp(minOverlayWidth, maxOverlayWidth);

/// 设备实际允许的窗口高度上限，规则同 [overlayWidthLimit]。
double overlayHeightLimit(double screenHeight) =>
    screenHeight.clamp(minOverlayHeight, maxOverlayHeight);

/// 把窗口尺寸收敛到设备屏幕允许的范围内。
///
/// 滑杆上限已经按屏幕收紧过，这里再兜一次：历史保存的偏好、屏幕旋转等情况
/// 都可能让存量值超出当前屏幕。
({double width, double height}) fitOverlaySize(
  ({double width, double height}) size, {
  required double screenWidth,
  required double screenHeight,
}) =>
    (
      width: clampOverlayWidth(size.width)
          .clamp(minOverlayWidth, overlayWidthLimit(screenWidth)),
      height: clampOverlayHeight(size.height)
          .clamp(minOverlayHeight, overlayHeightLimit(screenHeight)),
    );

/// 屏幕尺寸变化（横竖屏切换 / 折叠屏展开）时按比例换算窗口尺寸。
///
/// 尺寸记的是 dp：竖屏下 400dp 可能占了大半个屏宽，旋到横屏后同样 400dp
/// 只剩窄窄一条，观感突变（prd F2「尺寸按比例」）。这里按新老屏幕尺寸的比值
/// 等比缩放，保持相对占屏比例不变，最后收敛到新屏幕允许的范围内。
///
/// 老屏幕尺寸缺失或非法时不做换算，只按新屏幕收敛。
({double width, double height}) scaleOverlaySizeToScreen(
  ({double width, double height}) size, {
  required double oldScreenWidth,
  required double oldScreenHeight,
  required double newScreenWidth,
  required double newScreenHeight,
}) {
  if (oldScreenWidth <= 0 || oldScreenHeight <= 0) {
    return fitOverlaySize(
      size,
      screenWidth: newScreenWidth,
      screenHeight: newScreenHeight,
    );
  }
  return fitOverlaySize(
    (
      width: size.width * (newScreenWidth / oldScreenWidth),
      height: size.height * (newScreenHeight / oldScreenHeight),
    ),
    screenWidth: newScreenWidth,
    screenHeight: newScreenHeight,
  );
}

/// 按栏数推荐的窗口尺寸，设置页「按栏数推荐」按钮用。
({double width, double height}) recommendedOverlaySize(int paneCount) =>
    switch (paneCount) {
      <= 1 => (width: 240, height: 320),
      <= 2 => (width: 400, height: 320),
      <= 4 => (width: 400, height: 560),
      <= 6 => (width: 560, height: 560),
      _ => (width: 560, height: 800),
    };

/// 悬浮窗最多支持的栏数（prd F3：3×3 网格）。
const int maxPaneCount = 9;

/// 无需二次确认的最大栏数（prd F4）：超过 4 栏属于高性能模式，切换前强制确认。
const int maxStandardPaneCount = 4;

/// 悬浮窗分栏网格（prd F3）：1~9 栏，最多 3 列 3 行。
///
/// 布局完全由栏位数推导，没有额外选项，故不占用协议字段单独传递。
class OverlayGrid {
  const OverlayGrid(this.count);

  /// 栏位数，等于本次要连接的房间数。
  final int count;

  /// 列数：1 栏单列铺满；2~4 栏 2 列；5~9 栏 3 列。
  int get columns => count <= 1 ? 1 : (count <= 4 ? 2 : 3);

  /// 行数（向上取整）。
  int get rows => count <= 0 ? 0 : (count + columns - 1) ~/ columns;

  /// 是否单栏铺满：单栏时字号不缩小。
  bool get isSingle => count <= 1;
}

/// 单栏样式覆盖（prd F5）：字段为 null 表示跟随全局设置。
///
/// 按 webRid 绑定而不是按栏位序号：调整栏位顺序（换绑房间）后样式仍跟着房间走，
/// 不会错位到别的直播间。
class PaneStyle {
  const PaneStyle({this.fontSize, this.opacity, this.textColor});

  /// 本栏正文基准字号（dp）；null 跟随全局（仍参与按栏数缩小）。
  final double? fontSize;

  /// 本栏弹幕背景蒙版不透明度；null 跟随全局。
  final double? opacity;

  /// 本栏正文字色（ARGB，不含前导 #）；null 跟随主题默认。
  final int? textColor;

  bool get isEmpty => fontSize == null && opacity == null && textColor == null;

  PaneStyle copyWith({
    double? fontSize,
    double? opacity,
    int? textColor,
    bool clearFontSize = false,
    bool clearOpacity = false,
    bool clearTextColor = false,
  }) =>
      PaneStyle(
        fontSize: clearFontSize ? null : (fontSize ?? this.fontSize),
        opacity: clearOpacity ? null : (opacity ?? this.opacity),
        textColor: clearTextColor ? null : (textColor ?? this.textColor),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        if (fontSize != null) 'fontSize': clampDanmuFontSize(fontSize!),
        if (opacity != null) 'opacity': clampOverlayOpacity(opacity!),
        if (textColor != null) 'textColor': textColor,
      };

  /// 解析单栏样式；结构对不上或三个字段都缺省时返回 null。
  static PaneStyle? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? fontSize = raw['fontSize'];
    final Object? opacity = raw['opacity'];
    final Object? textColor = raw['textColor'];
    final PaneStyle style = PaneStyle(
      fontSize:
          fontSize is num ? clampDanmuFontSize(fontSize.toDouble()) : null,
      opacity: opacity is num ? clampOverlayOpacity(opacity.toDouble()) : null,
      textColor: textColor is int ? textColor : null,
    );
    return style.isEmpty ? null : style;
  }

  @override
  bool operator ==(Object other) =>
      other is PaneStyle &&
      other.fontSize == fontSize &&
      other.opacity == opacity &&
      other.textColor == textColor;

  @override
  int get hashCode => Object.hash(fontSize, opacity, textColor);

  @override
  String toString() =>
      'PaneStyle(fontSize: $fontSize, opacity: $opacity, textColor: $textColor)';
}

/// 解析「webRid → 单栏样式」映射；非 Map 或空结果返回空表。
Map<String, PaneStyle> parsePaneStyles(Object? raw) {
  if (raw is! Map) return const <String, PaneStyle>{};
  final Map<String, PaneStyle> styles = <String, PaneStyle>{};
  raw.forEach((Object? key, Object? value) {
    if (key is! String) return;
    final String roomId = key.trim();
    if (roomId.isEmpty) return;
    final PaneStyle? style = PaneStyle.tryParse(value);
    if (style != null) styles[roomId] = style;
  });
  return styles;
}

/// 把「webRid → 单栏样式」序列化为 JSON 可传的映射。
Map<String, Object?> encodePaneStyles(Map<String, PaneStyle> styles) =>
    <String, Object?>{
      for (final MapEntry<String, PaneStyle> entry in styles.entries)
        entry.key: entry.value.toJson(),
    };

/// 可切换的直播间选项（prd F14 分组 / F15 快速切换 / F8 栏间切换）。
///
/// 由主 App 从本地主播列表（含分组）生成后下发，悬浮窗只读：切换本栏绑定时
/// 从这里取候选房间，改绑结果经 [OverlayStatus] 回报给主 App 落盘。
class RoomOption {
  const RoomOption({required this.webRid, this.name = '', this.group = ''});

  /// 直播间号，作为候选唯一键。
  final String webRid;

  /// 展示名，与首页口径一致（备注优先，其次主播名，最后退回直播间号）。
  final String name;

  /// 所属分组；空串表示未分组。
  final String group;

  Map<String, Object?> toJson() => <String, Object?>{
        'webRid': webRid,
        if (name.isNotEmpty) 'name': name,
        if (group.isNotEmpty) 'group': group,
      };

  /// 解析单条候选；缺少 webRid 时返回 null。
  static RoomOption? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? webRid = raw['webRid'];
    if (webRid is! String || webRid.trim().isEmpty) return null;
    final Object? name = raw['name'];
    final Object? group = raw['group'];
    return RoomOption(
      webRid: webRid.trim(),
      name: name is String ? name.trim() : '',
      group: group is String ? group.trim() : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoomOption &&
      other.webRid == webRid &&
      other.name == name &&
      other.group == group;

  @override
  int get hashCode => Object.hash(webRid, name, group);

  @override
  String toString() => 'RoomOption($webRid, $name, $group)';
}

/// 解析候选房间列表；非列表或坏记录一律跳过。
List<RoomOption> parseRoomOptions(Object? raw) {
  if (raw is! List) return const <RoomOption>[];
  final List<RoomOption> options = <RoomOption>[];
  for (final Object? item in raw) {
    final RoomOption? option = RoomOption.tryParse(item);
    if (option != null) options.add(option);
  }
  return options;
}

List<Map<String, Object?>> encodeRoomOptions(List<RoomOption> options) =>
    <Map<String, Object?>>[
      for (final RoomOption option in options) option.toJson(),
    ];

/// 主 App 下发的连接配置。
class OverlayConfig {
  const OverlayConfig({
    required this.webRids,
    this.opacity = defaultOverlayOpacity,
    this.fontSize = defaultDanmuFontSize,
    this.scrollSpeed = defaultDanmuScrollSpeed,
    this.filter = const FilterPrefs(),
    this.paneStyles = const <String, PaneStyle>{},
    this.roomOptions = const <RoomOption>[],
    this.lightTheme = false,
    this.showTitleBar = true,
    this.focusBehavior = defaultFocusBehavior,
  });

  /// 各栏绑定的直播间号，按栏位顺序排列（栏 0 在前）。
  final List<String> webRids;

  /// 悬浮窗背景不透明度（prd F2 的「透明度」项）。
  final double opacity;

  /// 弹幕基准字号（dp），各栏按 [grid] 的栏数缩小后使用。
  final double fontSize;

  /// 弹幕自动滚动速度倍数（prd F2 的「滚动速度」项）。
  final double scrollSpeed;

  /// 屏蔽 / 高亮 / 类型筛选偏好（prd F10 / F11 / F13），全局生效。
  final FilterPrefs filter;

  /// 各栏样式覆盖（prd F5），按 webRid 索引。
  final Map<String, PaneStyle> paneStyles;

  /// 可在栏内快速切换的直播间候选（prd F14 / F15），来自主 App 的主播列表。
  final List<RoomOption> roomOptions;

  /// 悬浮窗是否为浅色皮肤（prd F20 样式预设）；false 为默认深色。
  final bool lightTheme;

  /// 是否显示栏目标识行（prd F6）；false 时标题行不渲染，弹幕占满整栏。
  final bool showTitleBar;

  /// 焦点模式下其余栏的处理方式（prd F7）：缩小或隐藏。
  final String focusBehavior;

  /// 由房间数推导的网格布局。
  OverlayGrid get grid => OverlayGrid(webRids.length);

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayConfigType,
        'webRids': webRids,
        'opacity': clampOverlayOpacity(opacity),
        'fontSize': clampDanmuFontSize(fontSize),
        'scrollSpeed': clampDanmuScrollSpeed(scrollSpeed),
        'filter': filter.toJson(),
        'paneStyles': encodePaneStyles(paneStyles),
        'roomOptions': encodeRoomOptions(roomOptions),
        'lightTheme': lightTheme,
        'showTitleBar': showTitleBar,
        'focusBehavior': clampFocusBehavior(focusBehavior),
      };

  /// 解析主 App 下发的消息；非 config 消息或没有任何有效房间时返回 null。
  static OverlayConfig? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['type'] != overlayConfigType) return null;
    final Object? webRids = raw['webRids'];
    if (webRids is! List) return null;
    final List<String> parsed = webRids
        .whereType<String>()
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    if (parsed.isEmpty) return null;
    final Object? opacity = raw['opacity'];
    final Object? fontSize = raw['fontSize'];
    final Object? scrollSpeed = raw['scrollSpeed'];
    return OverlayConfig(
      webRids: parsed,
      opacity: opacity is num
          ? clampOverlayOpacity(opacity.toDouble())
          : defaultOverlayOpacity,
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : defaultDanmuFontSize,
      scrollSpeed: scrollSpeed is num
          ? clampDanmuScrollSpeed(scrollSpeed.toDouble())
          : defaultDanmuScrollSpeed,
      filter: parseFilterPrefs(raw['filter']),
      paneStyles: parsePaneStyles(raw['paneStyles']),
      roomOptions: parseRoomOptions(raw['roomOptions']),
      lightTheme: raw['lightTheme'] == true,
      showTitleBar: raw['showTitleBar'] != false,
      focusBehavior: clampFocusBehavior(raw['focusBehavior']),
    );
  }
}

/// 解析 JSON 里的过滤偏好；结构对不上时回落默认值。
FilterPrefs parseFilterPrefs(Object? raw) {
  if (raw is! Map) return const FilterPrefs();
  final Object? visibleKinds = raw['visibleKinds'];
  return FilterPrefs(
    blockedKeywords: raw['blockedKeywords'] is List
        ? normalizeKeywordList(List<Object?>.from(raw['blockedKeywords'] as List))
        : const <String>[],
    blockedUsers: raw['blockedUsers'] is List
        ? normalizeKeywordList(List<Object?>.from(raw['blockedUsers'] as List))
        : const <String>[],
    highlightKeywords: raw['highlightKeywords'] is List
        ? normalizeKeywordList(
            List<Object?>.from(raw['highlightKeywords'] as List))
        : const <String>[],
    visibleKinds:
        visibleKinds is List ? _kindsFromNames(visibleKinds) : defaultListKinds,
    // 老版本下发的 filter 没有这个键，缺省按关闭处理，等价于原来的子串匹配。
    regexEnabled: raw['regexEnabled'] == true,
  );
}

Set<DanmakuKind> _kindsFromNames(List<Object?> raw) {
  final Set<DanmakuKind> kinds = <DanmakuKind>{};
  for (final Object? item in raw) {
    if (item is! String) continue;
    for (final DanmakuKind kind in selectableListKinds) {
      if (kind.name == item) {
        kinds.add(kind);
        break;
      }
    }
  }
  return kinds.isEmpty ? defaultListKinds : Set<DanmakuKind>.unmodifiable(kinds);
}

/// 主 App 下发的纯过滤偏好调整（prd F10 / F11 / F13）。
///
/// 与 [OverlayStyle] 同理：设置页改屏蔽词时用它而不是重发 [OverlayConfig]，
/// 免得把当前窗口里绑定的房间冲掉。
class OverlayFilter {
  const OverlayFilter(this.prefs);

  final FilterPrefs prefs;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayFilterType,
        'filter': prefs.toJson(),
      };

  /// 解析过滤消息；非 filter 消息时返回 null。
  static FilterPrefs? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayFilterType) return null;
    return parseFilterPrefs(raw['filter']);
  }
}

/// 主 App 下发的候选房间更新（prd F14 分组 / F15 快速切换）。
///
/// 首页增删主播或改分组时用它推送候选列表，只更新切换弹窗里的可选项，
/// 不重发 [OverlayConfig]，避免把各栏已绑定的房间冲掉、触发无谓重连。
class OverlayRooms {
  const OverlayRooms(this.options);

  final List<RoomOption> options;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayRoomsType,
        'roomOptions': encodeRoomOptions(options),
      };

  /// 解析候选房间消息；非 rooms 消息时返回 null。
  static List<RoomOption>? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayRoomsType) return null;
    return parseRoomOptions(raw['roomOptions']);
  }
}

/// 主 App 下发的纯样式调整：只改外观，不动各栏已绑定的房间。
///
/// 设置页调透明度/字号时用它而不是重发 [OverlayConfig]——同一时刻窗口里绑的是
/// 哪些房间由当前持有悬浮窗的页面决定，设置页并不知道，重发 config 会把绑定冲掉。
class OverlayStyle {
  const OverlayStyle({
    required this.opacity,
    this.fontSize = defaultDanmuFontSize,
    this.scrollSpeed = defaultDanmuScrollSpeed,
    this.paneStyles = const <String, PaneStyle>{},
    this.lightTheme = false,
    this.showTitleBar = true,
    this.focusBehavior = defaultFocusBehavior,
  });

  final double opacity;
  final double fontSize;
  final double scrollSpeed;

  /// 各栏样式覆盖（prd F5），按 webRid 索引；空表表示各栏全部跟随全局。
  final Map<String, PaneStyle> paneStyles;

  /// 悬浮窗是否为浅色皮肤（prd F20）。
  final bool lightTheme;

  /// 是否显示栏目标识行（prd F6）。
  final bool showTitleBar;

  /// 焦点模式下其余栏的处理方式（prd F7）。
  final String focusBehavior;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayStyleType,
        'opacity': clampOverlayOpacity(opacity),
        'fontSize': clampDanmuFontSize(fontSize),
        'scrollSpeed': clampDanmuScrollSpeed(scrollSpeed),
        'paneStyles': encodePaneStyles(paneStyles),
        'lightTheme': lightTheme,
        'showTitleBar': showTitleBar,
        'focusBehavior': clampFocusBehavior(focusBehavior),
      };

  /// 解析样式消息；非 style 消息或缺少透明度时返回 null。
  static OverlayStyle? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayStyleType) return null;
    final Object? opacity = raw['opacity'];
    if (opacity is! num) return null;
    final Object? fontSize = raw['fontSize'];
    final Object? scrollSpeed = raw['scrollSpeed'];
    return OverlayStyle(
      opacity: clampOverlayOpacity(opacity.toDouble()),
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : defaultDanmuFontSize,
      scrollSpeed: scrollSpeed is num
          ? clampDanmuScrollSpeed(scrollSpeed.toDouble())
          : defaultDanmuScrollSpeed,
      paneStyles: parsePaneStyles(raw['paneStyles']),
      lightTheme: raw['lightTheme'] == true,
      showTitleBar: raw['showTitleBar'] != false,
      focusBehavior: clampFocusBehavior(raw['focusBehavior']),
    );
  }
}

/// 消息是否为关闭悬浮窗指令。
bool isOverlayCloseMessage(Object? raw) =>
    raw is Map && raw['type'] == overlayCloseType;

/// 主 App 同步给悬浮窗引擎的手动凭证（prd F27）。
///
/// 连接层整体跑在悬浮窗引擎里，两个引擎不共享内存对象，所以手动粘贴的凭证
/// 必须经消息通道下发。这是进程内的本地通道，不涉及上传或第三方转发（prd 3.2）。
class OverlayCredential {
  const OverlayCredential(this.cookies);

  /// 手动凭证的 Cookie 串；null 表示回到匿名自动获取。
  final String? cookies;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayCredentialType,
        'cookies': cookies,
      };

  /// 解析凭证消息；非 credential 消息时返回 null。
  static OverlayCredential? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayCredentialType) return null;
    final Object? cookies = raw['cookies'];
    final String value = cookies is String ? cookies.trim() : '';
    return OverlayCredential(value.isEmpty ? null : value);
  }
}

/// 关闭悬浮窗的指令载荷。
///
/// 插件关闭窗口只是停止前台服务并把 FlutterView 从缓存引擎上摘下来，
/// 引擎与 Dart 侧 widget 树都不会销毁，因此主 App 必须在关闭前显式下发本指令，
/// 让悬浮窗卸载各栏、断开全部直播间连接（prd 4.11）。
Map<String, Object?> buildOverlayCloseMessage() =>
    <String, Object?>{'type': overlayCloseType};

/// 悬浮窗上报给主 App 的运行状态。
///
/// 多栏布局下这里是**各栏聚合结果**：阶段取最需要注意的一栏，条数为各栏之和。
/// 每栏的实时状态由悬浮窗内各栏标题行自带（prd F6），主 App 不需要逐栏明细。
class OverlayStatus {
  const OverlayStatus({
    required this.stage,
    required this.received,
    this.webRid,
    this.error,
    this.permissionRevoked = false,
    this.webRids = const <String>[],
  });

  final LiveSessionStage stage;
  final int received;
  final String? webRid;
  final String? error;

  /// 悬浮窗自查发现权限已被撤销：此时各栏已卸载、连接已断开，
  /// 主 App 收到后应把「悬浮窗已开启」的状态改回未开启。
  final bool permissionRevoked;

  /// 各栏当前绑定的直播间号（prd F8 / F15）：用户在悬浮窗内切换房间后，
  /// 悬浮窗把最新绑定回报给主 App，由主 App 写入本地偏好持久化。
  final List<String> webRids;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayStateType,
        'stage': stage.name,
        'received': received,
        'webRid': webRid,
        'error': error,
        'permissionRevoked': permissionRevoked,
        if (webRids.isNotEmpty) 'webRids': webRids,
      };

  /// 解析悬浮窗上报的消息；非 state 消息时返回 null。
  static OverlayStatus? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['type'] != overlayStateType) return null;
    final Object? stageName = raw['stage'];
    final LiveSessionStage stage = LiveSessionStage.values.firstWhere(
      (LiveSessionStage value) => value.name == stageName,
      orElse: () => LiveSessionStage.idle,
    );
    final Object? received = raw['received'];
    final Object? webRid = raw['webRid'];
    final Object? error = raw['error'];
    final Object? webRids = raw['webRids'];
    return OverlayStatus(
      stage: stage,
      received: received is int ? received : 0,
      webRid: webRid is String ? webRid : null,
      error: error is String ? error : null,
      permissionRevoked: raw['permissionRevoked'] == true,
      webRids: webRids is List
          ? <String>[
              for (final Object? item in webRids)
                if (item is String && item.trim().isNotEmpty) item.trim(),
            ]
          : const <String>[],
    );
  }
}