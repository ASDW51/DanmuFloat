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

/// 悬浮窗 → 主 App：请求把一段文本写进系统剪贴板。
///
/// 悬浮窗跑在独立引擎里，没有注册平台插件，`Clipboard.setData` 在那边不可用；
/// 复制动作只能请主 App（有 Activity）代劳。
const String overlayClipboardType = 'clipboard';

/// 原生 → 悬浮窗：通知栏「关闭点击穿透」按钮触发，让悬浮窗把本地开关同步回关闭。
const String overlayClickThroughType = 'clickThrough';

/// 原生 → 悬浮窗：窗口拖动结束（或贴边吸附收敛）后上报窗口在屏幕上的位置。
///
/// 悬浮窗引擎拿不到原生侧的窗口 LayoutParams，只能由 OverlayService 上报，
/// 再随偏好增量交给主 App 落盘，下次开窗按保存的位置还原。
const String overlayPositionType = 'position';

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

/// 悬浮球在窗口内的吸附角：0 左上 / 1 右上 / 2 左下 / 3 右下。
const int ballCornerCount = 4;

/// 四个吸附角在菜单里的显示名，顺序与 [clampBallCorner] 的取值一致。
const List<String> ballCornerLabels = <String>['左上', '右上', '左下', '右下'];

/// 收敛悬浮球吸附角：不认识的值一律回落左上角。
int clampBallCorner(Object? value) =>
    value is int && value >= 0 && value < ballCornerCount ? value : 0;

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
}) => (
  width: clampOverlayWidth(
    size.width,
  ).clamp(minOverlayWidth, overlayWidthLimit(screenWidth)),
  height: clampOverlayHeight(
    size.height,
  ).clamp(minOverlayHeight, overlayHeightLimit(screenHeight)),
);

/// 把窗口在屏幕上的位置收敛到可见范围内（dp）。
///
/// 坐标系与插件一致：本项目窗口贴右（`OverlayAlignment.centerRight`），
/// x 从屏幕右边缘起算、向右为正，y 从屏幕垂直中心起算。存量位置在换设备 /
/// 旋转后可能越界，开窗还原前用它兜一次，避免窗口被摆到屏幕外。
({double x, double y}) fitOverlayOffset(
  ({double x, double y}) offset, {
  required ({double width, double height}) size,
  required double screenWidth,
  required double screenHeight,
}) {
  final double maxX = (screenWidth - size.width).clamp(0.0, double.infinity);
  final double maxY = ((screenHeight - size.height) / 2).clamp(
    0.0,
    double.infinity,
  );
  return (x: offset.x.clamp(0.0, maxX), y: offset.y.clamp(-maxY, maxY));
}

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
      <= 9 => (width: 560, height: 800),
      _ => (width: 720, height: 900),
    };

/// 无需二次确认的最大栏数（prd F4）：超过 4 栏属于高性能模式，切换前强制确认。
const int maxStandardPaneCount = 4;

/// 悬浮窗分栏网格：不再限制栏位上限，列数按栏位数推导、行数向上取整。
///
/// 布局完全由栏位数推导，没有额外选项，故不占用协议字段单独传递。
/// 栏位过多时单格会变小，由用户自行配合窗口尺寸调整（悬浮球菜单里可增 / 减栏位）。
class OverlayGrid {
  const OverlayGrid(this.count);

  /// 栏位数，等于本次要连接的房间数。
  final int count;

  /// 列数：1 栏单列铺满；2~4 栏 2 列；5 栏起 3 列。
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
  }) => PaneStyle(
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
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : null,
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
    this.dragLocked = false,
    this.ballCorner = 0,
    this.clickThrough = false,
    this.windowX,
    this.windowY,
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

  /// 是否锁定窗口位置（prd F21 延伸）：锁定后窗口不能拖动，栏内列表才能正常滑动。
  final bool dragLocked;

  /// 悬浮球吸附在窗口的哪个角（0 左上 / 1 右上 / 2 左下 / 3 右下）。
  final int ballCorner;

  /// 是否开启点击穿透：开启后悬浮窗不再接收触摸，点击直接落到下层画面。
  /// 代价是窗内所有交互（悬浮球菜单、列表滚动、长按调透明度）都会失效。
  final bool clickThrough;

  /// 上次保存的窗口水平位置（dp，从屏幕右边缘起算）；null 表示未保存过，
  /// 建窗时交给插件按默认位置（贴右居中）摆放。
  final double? windowX;

  /// 上次保存的窗口垂直位置（dp，从屏幕垂直中心起算）。
  final double? windowY;

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
    'dragLocked': dragLocked,
    'ballCorner': clampBallCorner(ballCorner),
    'clickThrough': clickThrough,
    if (windowX != null) 'windowX': windowX,
    if (windowY != null) 'windowY': windowY,
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
    final Object? windowX = raw['windowX'];
    final Object? windowY = raw['windowY'];
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
      dragLocked: raw['dragLocked'] == true,
      ballCorner: clampBallCorner(raw['ballCorner']),
      clickThrough: raw['clickThrough'] == true,
      windowX: windowX is num ? windowX.toDouble() : null,
      windowY: windowY is num ? windowY.toDouble() : null,
    );
  }
}

/// 解析 JSON 里的过滤偏好；结构对不上时回落默认值。
FilterPrefs parseFilterPrefs(Object? raw) {
  if (raw is! Map) return const FilterPrefs();
  final Object? visibleKinds = raw['visibleKinds'];
  return FilterPrefs(
    blockedKeywords: raw['blockedKeywords'] is List
        ? normalizeKeywordList(
            List<Object?>.from(raw['blockedKeywords'] as List),
          )
        : const <String>[],
    blockedUsers: raw['blockedUsers'] is List
        ? normalizeKeywordList(List<Object?>.from(raw['blockedUsers'] as List))
        : const <String>[],
    highlightKeywords: raw['highlightKeywords'] is List
        ? normalizeKeywordList(
            List<Object?>.from(raw['highlightKeywords'] as List),
          )
        : const <String>[],
    visibleKinds: visibleKinds is List
        ? _kindsFromNames(visibleKinds)
        : defaultListKinds,
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
  return kinds.isEmpty
      ? defaultListKinds
      : Set<DanmakuKind>.unmodifiable(kinds);
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
    this.dragLocked = false,
    this.clickThrough = false,
    this.screenWidth = 0,
    this.screenHeight = 0,
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

  /// 是否锁定窗口位置；锁定后窗口不能拖动（悬浮球菜单可切换）。
  final bool dragLocked;

  /// 是否开启点击穿透（设置页或悬浮球菜单可切换）。
  final bool clickThrough;

  /// 设备屏幕逻辑尺寸：悬浮窗引擎里查不到屏幕尺寸，只能由主 App 下发，
  /// 供悬浮球菜单调整窗口尺寸时收敛（避免放大后溢出屏幕）。0 表示未知。
  final double screenWidth;
  final double screenHeight;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': overlayStyleType,
    'opacity': clampOverlayOpacity(opacity),
    'fontSize': clampDanmuFontSize(fontSize),
    'scrollSpeed': clampDanmuScrollSpeed(scrollSpeed),
    'paneStyles': encodePaneStyles(paneStyles),
    'lightTheme': lightTheme,
    'showTitleBar': showTitleBar,
    'focusBehavior': clampFocusBehavior(focusBehavior),
    'dragLocked': dragLocked,
    'clickThrough': clickThrough,
    if (screenWidth > 0) 'screenWidth': screenWidth,
    if (screenHeight > 0) 'screenHeight': screenHeight,
  };

  /// 解析样式消息；非 style 消息或缺少透明度时返回 null。
  static OverlayStyle? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayStyleType) return null;
    final Object? opacity = raw['opacity'];
    if (opacity is! num) return null;
    final Object? fontSize = raw['fontSize'];
    final Object? scrollSpeed = raw['scrollSpeed'];
    final Object? screenWidth = raw['screenWidth'];
    final Object? screenHeight = raw['screenHeight'];
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
      dragLocked: raw['dragLocked'] == true,
      clickThrough: raw['clickThrough'] == true,
      screenWidth: screenWidth is num && screenWidth > 0
          ? screenWidth.toDouble()
          : 0,
      screenHeight: screenHeight is num && screenHeight > 0
          ? screenHeight.toDouble()
          : 0,
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
Map<String, Object?> buildOverlayCloseMessage() => <String, Object?>{
  'type': overlayCloseType,
};

/// 悬浮窗内改动、需要主 App 落盘的偏好增量（悬浮球菜单用）。
///
/// 悬浮窗引擎写不了主 App 的偏好文件（两个引擎不共享内存），用户在悬浮球里
/// 改了透明度 / 尺寸 / 锁定后，把变化随状态上报，由主 App 合并进 [OverlayPrefs]。
/// 字段为 null 表示本次没有改动，避免每秒上报都触发一次落盘。
class OverlayPrefsPatch {
  const OverlayPrefsPatch({
    this.opacity,
    this.fontSize,
    this.windowWidth,
    this.windowHeight,
    this.dragLocked,
    this.ballCorner,
    this.clickThrough,
    this.windowX,
    this.windowY,
  });

  final double? opacity;
  final double? fontSize;
  final double? windowWidth;
  final double? windowHeight;
  final bool? dragLocked;
  final int? ballCorner;
  final bool? clickThrough;

  /// 窗口在屏幕上的位置（dp），拖动 / 吸附收敛后由原生上报。
  final double? windowX;
  final double? windowY;

  bool get isEmpty =>
      opacity == null &&
      fontSize == null &&
      windowWidth == null &&
      windowHeight == null &&
      dragLocked == null &&
      ballCorner == null &&
      clickThrough == null &&
      windowX == null &&
      windowY == null;

  Map<String, Object?> toJson() => <String, Object?>{
    if (opacity != null) 'opacity': clampOverlayOpacity(opacity!),
    if (fontSize != null) 'fontSize': clampDanmuFontSize(fontSize!),
    if (windowWidth != null) 'windowWidth': clampOverlayWidth(windowWidth!),
    if (windowHeight != null) 'windowHeight': clampOverlayHeight(windowHeight!),
    if (dragLocked != null) 'dragLocked': dragLocked,
    if (ballCorner != null) 'ballCorner': clampBallCorner(ballCorner!),
    if (clickThrough != null) 'clickThrough': clickThrough,
    if (windowX != null) 'windowX': windowX,
    if (windowY != null) 'windowY': windowY,
  };

  /// 解析偏好增量；非对象或没有任何字段时返回 null。
  static OverlayPrefsPatch? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? opacity = raw['opacity'];
    final Object? fontSize = raw['fontSize'];
    final Object? windowWidth = raw['windowWidth'];
    final Object? windowHeight = raw['windowHeight'];
    final Object? dragLocked = raw['dragLocked'];
    final Object? ballCorner = raw['ballCorner'];
    final Object? clickThrough = raw['clickThrough'];
    final Object? windowX = raw['windowX'];
    final Object? windowY = raw['windowY'];
    final OverlayPrefsPatch patch = OverlayPrefsPatch(
      opacity: opacity is num ? clampOverlayOpacity(opacity.toDouble()) : null,
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : null,
      windowWidth: windowWidth is num
          ? clampOverlayWidth(windowWidth.toDouble())
          : null,
      windowHeight: windowHeight is num
          ? clampOverlayHeight(windowHeight.toDouble())
          : null,
      dragLocked: dragLocked is bool ? dragLocked : null,
      ballCorner: ballCorner is int ? clampBallCorner(ballCorner) : null,
      clickThrough: clickThrough is bool ? clickThrough : null,
      windowX: windowX is num ? windowX.toDouble() : null,
      windowY: windowY is num ? windowY.toDouble() : null,
    );
    return patch.isEmpty ? null : patch;
  }
}

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
    this.prefsPatch,
    this.filter,
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

  /// 悬浮球菜单里改动的偏好增量（透明度 / 字号 / 窗口尺寸 / 锁定 / 点击穿透）；
  /// null 表示本次上报没有改动，主 App 不需要落盘。
  final OverlayPrefsPatch? prefsPatch;

  /// 悬浮窗列表里改了过滤偏好（把某用户 / 某段文本加入屏蔽）后的完整取值；
  /// null 表示本次上报没有改动。悬浮窗引擎写不了主 App 的过滤文件，
  /// 只能整份带回来由主 App 落盘（覆盖式，不会与主 App 侧叠加）。
  final FilterPrefs? filter;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': overlayStateType,
    'stage': stage.name,
    'received': received,
    'webRid': webRid,
    'error': error,
    'permissionRevoked': permissionRevoked,
    if (webRids.isNotEmpty) 'webRids': webRids,
    if (prefsPatch != null && !prefsPatch!.isEmpty)
      'prefs': prefsPatch!.toJson(),
    if (filter != null) 'filter': filter!.toJson(),
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
    final Object? filter = raw['filter'];
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
      prefsPatch: OverlayPrefsPatch.tryParse(raw['prefs']),
      filter: filter is Map ? parseFilterPrefs(filter) : null,
    );
  }
}

/// 悬浮窗 → 主 App：请求复制一段文本（悬浮窗引擎没有剪贴板插件通道）。
///
/// 与 [OverlayStatus] 走同一条上行通道，只是类型不同：主 App 收到后调用
/// `Clipboard.setData` 完成复制。
class OverlayClipboard {
  const OverlayClipboard(this.text);

  /// 要写入剪贴板的文本；空串没有复制意义，由调用方过滤。
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': overlayClipboardType,
    'text': text,
  };

  /// 解析复制请求；非 clipboard 消息或文本为空时返回 null。
  static OverlayClipboard? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayClipboardType) return null;
    final Object? text = raw['text'];
    if (text is! String || text.isEmpty) return null;
    return OverlayClipboard(text);
  }
}

/// 原生 → 悬浮窗：点击穿透开关被窗外的入口（通知栏按钮）改成了某个值。
///
/// 穿透开启后悬浮窗收不到触摸，窗内没法关，通知栏提供唯一的就地关闭入口；
/// 关掉之后要通知悬浮窗把本地开关与待落盘增量同步过去。
class OverlayClickThrough {
  const OverlayClickThrough(this.value);

  /// 最新的点击穿透状态。
  final bool value;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': overlayClickThroughType,
    'value': value,
  };

  /// 解析穿透状态消息；非 clickThrough 消息或缺少布尔值时返回 null。
  static OverlayClickThrough? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayClickThroughType) return null;
    final Object? value = raw['value'];
    if (value is! bool) return null;
    return OverlayClickThrough(value);
  }
}

/// 原生 → 悬浮窗：窗口在屏幕上的位置（dp）。
///
/// 坐标系与插件一致（本项目窗口贴右）：x 从屏幕右边缘起算、向右为正，
/// y 从屏幕垂直中心起算。拖动结束或贴边吸附收敛后由 OverlayService 上报，
/// 悬浮窗把它并入偏好增量交给主 App 落盘，下次开窗按 [OverlayConfig] 里的位置还原。
class OverlayWindowPosition {
  const OverlayWindowPosition({required this.x, required this.y});

  final double x;
  final double y;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': overlayPositionType,
    'x': x,
    'y': y,
  };

  /// 解析位置消息；非 position 消息或坐标非法（缺字段 / NaN / 无穷）时返回 null。
  static OverlayWindowPosition? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayPositionType) return null;
    final Object? x = raw['x'];
    final Object? y = raw['y'];
    if (x is! num || y is! num) return null;
    final double valueX = x.toDouble();
    final double valueY = y.toDouble();
    if (valueX.isNaN ||
        valueY.isNaN ||
        valueX.isInfinite ||
        valueY.isInfinite) {
      return null;
    }
    return OverlayWindowPosition(x: valueX, y: valueY);
  }
}
