// 悬浮窗样式与分栏配置的本地持久化（design.md 2.1 / 2.3 的「分栏配置（JSON）」）。
//
// 与主播列表分两个文件存：主播列表是用户资产，分栏配置只是样式偏好，
// 写入时机与损坏后的影响面都不同，混在一个文件里容易互相覆盖。
//
// 布局（几行几列）由栏位数推导，没有可选项，故不入文件。
import 'dart:convert';
import 'dart:io';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/storage/my_theme.dart';

export 'package:danmu_float/storage/my_theme.dart';
import 'package:path_provider/path_provider.dart';

/// 分栏配置文件名。
const String overlayPrefsFileName = 'overlay.json';

/// 悬浮窗样式与分栏偏好。
/// 默认主题标识：与既有「深色」外观一一对应（第 6 轮 UX-29）。
const String defaultOverlayThemeId = 'dark';

/// 浅色主题标识：[OverlayPrefs.lightTheme] 由它派生，避免两处真相。
const String overlayThemeLightId = 'light';

/// 对比度策略默认值：自动提高对比度，但保留用户选择的色相与饱和度。
const String defaultOverlayContrastPolicy = 'adjust';

/// 最近使用色上限。
const int maxRecentOverlayColors = 8;

/// 偏好文件的 schema 版本，只写不分支（见 toJson 注释）。
const int overlayPrefsSchemaVersion = 2;

/// 对比度策略白名单：非法值一律回落默认值。
/// 钳制对比度策略；白名单的实现在桥接层（`clampOverlayStyleContrastPolicy`），
/// 这里只转发，避免同一套取值出现两份判断。
String clampOverlayContrastPolicy(Object? raw) =>
    clampOverlayStyleContrastPolicy(raw);

/// 记录一次「最近使用」的颜色：新色置顶、去重、截断到 [maxRecentOverlayColors]。
///
/// 只收不透明色（与 [parseColorOverrides] 同一口径）：半透明色换到别的角色上会叠出
/// 完全不同的观感，作为「最近使用」复用的价值很低。
///
/// 跨主题共用一份：颜色与主题无关，按主题分会把 8 个槽位打碎；「深色下选的色在
/// 浅色下不可读」由对比度策略兜住。
List<int> recordRecentColor(List<int> recent, int argb) {
  if (argb < 0 || argb > 0xFFFFFFFF || (argb >> 24) != 0xFF) return recent;
  return <int>[
    argb,
    for (final int color in recent)
      if (color != argb) color,
  ].take(maxRecentOverlayColors).toList();
}

/// 解析主题标识：没有 themeId 的旧配置由 lightTheme 推导（外观与升级前一致）。
String _parseThemeId(Map<dynamic, dynamic> raw) {
  final Object? id = raw['themeId'];
  if (id is String && id.isNotEmpty) return id;
  return raw['lightTheme'] == true
      ? overlayThemeLightId
      : defaultOverlayThemeId;
}

/// 解析最近使用色：只留合法的不透明色，去重、按首次出现顺序、最多 8 个。
List<int> _parseRecentColors(Object? raw) {
  if (raw is! List) return const <int>[];
  final List<int> result = <int>[];
  for (final Object? item in raw) {
    if (item is! int) continue;
    if (item < 0 || item > 0xFFFFFFFF) continue;
    if (((item >> 24) & 0xFF) != 0xFF) continue;
    if (result.contains(item)) continue;
    result.add(item);
    if (result.length >= maxRecentOverlayColors) break;
  }
  return result;
}

/// 校验自定义主题名：返回 null 表示合法，否则是给用户看的中文原因（#147）。
///
/// 只在这里定一套口径（保存 / 重命名共用），避免两处校验各自漂移。
String? _validateMyThemeName(String name) {
  if (name.isEmpty) return '名称不能为空';
  if (name.length > myThemeMaxNameLength) return '名称最多 $myThemeMaxNameLength 个字';
  return null;
}

/// 两份覆盖表是否逐项相同：「这套配色已经保存过了」的去重判断（#147）。
bool _sameOverrides(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, int> entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

class OverlayPrefs {
  const OverlayPrefs({
    this.webRids = const <String>[],
    this.opacity = defaultOverlayOpacity,
    this.fontSize = defaultDanmuFontSize,
    this.scrollSpeed = defaultDanmuScrollSpeed,
    this.windowWidth = defaultOverlayWidth,
    this.windowHeight = defaultOverlayHeight,
    this.paneStyles = const <String, PaneStyle>{},
    this.themeId = defaultOverlayThemeId,
    this.colorOverrides = const <String, int>{},
    this.recentColors = const <int>[],
    this.myThemes = const <MyTheme>[],
    this.gridDirection = overlayGridAuto,
    this.contrastPolicy = defaultOverlayContrastPolicy,
    this.showTitleBar = true,
    this.focusBehavior = defaultFocusBehavior,
    this.dragLocked = false,
    this.ballCorner = 0,
    this.clickThrough = false,
    this.windowX,
    this.windowY,
  });

  /// 上次勾选的主播，按栏位顺序排列（下次打开多栏弹窗时据此预勾选）。
  final List<String> webRids;

  /// 弹幕背景蒙版不透明度。
  final double opacity;

  /// 弹幕基准字号（dp）：单栏直接使用，多栏按栏数缩小。
  final double fontSize;

  /// 弹幕自动滚动速度倍数（prd F2「滚动速度」）。
  final double scrollSpeed;

  /// 悬浮窗窗口宽度（dp）。
  final double windowWidth;

  /// 悬浮窗窗口高度（dp）。
  final double windowHeight;

  /// 各栏样式覆盖（prd F5），按 webRid 索引。
  final Map<String, PaneStyle> paneStyles;

  /// 悬浮窗是否为浅色皮肤（prd F20 样式预设）；false 为默认深色。
  /// 主题标识（第 6 轮 UX-29）：取值是预设 id，未知值由渲染侧回落深色。
  final String themeId;

  /// 角色级颜色覆盖：角色名 → 不透明 ARGB；空表表示完全跟随主题。
  final Map<String, int> colorOverrides;

  /// 最近使用色（最多 [maxRecentOverlayColors] 个）。本轮只落盘，UI 与去重测试推后。
  final List<int> recentColors;

  /// 用户另存的具名主题（#147），上限 [maxMyThemes]。
  final List<MyTheme> myThemes;

  /// 分栏方向（#141）：缺字段即自动，旧备份照常可读。
  final String gridDirection;

  /// 对比度策略：adjust / warn / allow，非法值回落 adjust。
  final String contrastPolicy;

  /// 是否浅色皮肤。**由 [themeId] 派生**，不再单独存储——两处真相会互相打架。
  bool get lightTheme => themeId == overlayThemeLightId;

  /// 是否显示栏目标识行（prd F6）。
  final bool showTitleBar;

  /// 焦点模式下其余栏的处理方式（prd F7）。
  final String focusBehavior;

  /// 是否锁定窗口位置：锁定后窗口不能拖动，栏内弹幕列表才能正常上下滑动。
  final bool dragLocked;

  /// 悬浮球吸附在窗口的哪个角（0 左上 / 1 右上 / 2 左下 / 3 右下）。
  final int ballCorner;

  /// 是否开启点击穿透：开启后悬浮窗不接收触摸，点击落到下层画面（prd F2 延伸）。
  final bool clickThrough;

  /// 窗口在屏幕上的水平位置（dp，从屏幕右边缘起算）；null 表示未保存过。
  final double? windowX;

  /// 窗口在屏幕上的垂直位置（dp，从屏幕垂直中心起算）。
  final double? windowY;

  /// 窗口尺寸，供建窗 / 重排窗口时使用。
  ({double width, double height}) get windowSize => (
    width: clampOverlayWidth(windowWidth),
    height: clampOverlayHeight(windowHeight),
  );

  OverlayPrefs copyWith({
    List<String>? webRids,
    double? opacity,
    double? fontSize,
    double? scrollSpeed,
    double? windowWidth,
    double? windowHeight,
    Map<String, PaneStyle>? paneStyles,
    String? themeId,
    String? gridDirection,
    bool? lightTheme,
    Map<String, int>? colorOverrides,
    List<int>? recentColors,
    List<MyTheme>? myThemes,
    String? contrastPolicy,
    bool? showTitleBar,
    String? focusBehavior,
    bool? dragLocked,
    int? ballCorner,
    bool? clickThrough,
    double? windowX,
    double? windowY,
  }) => OverlayPrefs(
    webRids: webRids ?? this.webRids,
    opacity: opacity ?? this.opacity,
    fontSize: fontSize ?? this.fontSize,
    scrollSpeed: scrollSpeed ?? this.scrollSpeed,
    windowWidth: windowWidth ?? this.windowWidth,
    windowHeight: windowHeight ?? this.windowHeight,
    paneStyles: paneStyles ?? this.paneStyles,
    themeId: themeId ??
        (lightTheme == null
            ? this.themeId
            : (lightTheme ? overlayThemeLightId : defaultOverlayThemeId)),
    colorOverrides: colorOverrides ?? this.colorOverrides,
    recentColors: recentColors ?? this.recentColors,
    myThemes: myThemes ?? this.myThemes,
    gridDirection: gridDirection ?? this.gridDirection,
    contrastPolicy: clampOverlayContrastPolicy(contrastPolicy ?? this.contrastPolicy),
    showTitleBar: showTitleBar ?? this.showTitleBar,
    focusBehavior: focusBehavior ?? this.focusBehavior,
    dragLocked: dragLocked ?? this.dragLocked,
    ballCorner: ballCorner ?? this.ballCorner,
    clickThrough: clickThrough ?? this.clickThrough,
    windowX: windowX ?? this.windowX,
    windowY: windowY ?? this.windowY,
  );

  /// 合并悬浮窗上报的偏好增量（悬浮球菜单改的部分）。
  OverlayPrefs appliedPatch(OverlayPrefsPatch patch) => OverlayPrefs(
    webRids: webRids,
    opacity: patch.opacity ?? opacity,
    fontSize: patch.fontSize ?? fontSize,
    scrollSpeed: scrollSpeed,
    windowWidth: patch.windowWidth ?? windowWidth,
    windowHeight: patch.windowHeight ?? windowHeight,
    paneStyles: paneStyles,
    themeId: patch.themeId ?? themeId,
    colorOverrides: patch.colorOverrides ?? colorOverrides,
    gridDirection: patch.gridDirection ?? gridDirection,
    recentColors: recentColors,
    contrastPolicy: contrastPolicy,
    showTitleBar: showTitleBar,
    focusBehavior: focusBehavior,
    dragLocked: patch.dragLocked ?? dragLocked,
    ballCorner: patch.ballCorner ?? ballCorner,
    clickThrough: patch.clickThrough ?? clickThrough,
    windowX: patch.windowX ?? windowX,
    windowY: patch.windowY ?? windowY,
  );

  /// 组装成下发给悬浮窗的配置。
  ///
  /// [filter] 来自独立的过滤偏好存储（prd F10/F11/F13），随配置一起下发，
  /// 保证新开的窗口立刻带上当前的屏蔽与高亮口径。
  /// [roomOptions] 是可在栏内快速切换的候选房间（prd F14 / F15），
  /// 由首页从本地主播列表生成。
  OverlayConfig toConfig(
    List<String> rooms, {
    FilterPrefs filter = const FilterPrefs(),
    List<RoomOption> roomOptions = const <RoomOption>[],
  }) => OverlayConfig(
    webRids: rooms,
    opacity: clampOverlayOpacity(opacity),
    fontSize: clampDanmuFontSize(fontSize),
    scrollSpeed: clampDanmuScrollSpeed(scrollSpeed),
    filter: filter,
    paneStyles: _stylesFor(rooms),
    roomOptions: roomOptions,
    lightTheme: lightTheme,
    // config 也带上完整皮肤（#98）：它经 `resizeOverlay` 走出去时是那条路径上唯一的
    // 消息（如首页删除在播主播后的重排），不带就会把 sepia / contrast 换成 dark。
    themeId: themeId,
    colorOverrides: colorOverrides,
    gridDirection: gridDirection,
    myThemes: myThemes,
    contrastPolicy: contrastPolicy,
    showTitleBar: showTitleBar,
    focusBehavior: clampFocusBehavior(focusBehavior),
    dragLocked: dragLocked,
    ballCorner: clampBallCorner(ballCorner),
    clickThrough: clickThrough,
    windowX: windowX,
    windowY: windowY,
  );

  /// 只保留当前绑定的房间的样式，避免下发时带上已解绑房间的冗余覆盖。
  /// 把当前「基础预设 + 整份覆盖表」另存为具名主题（#147）。
  ///
  /// 返回 `(prefs, error)`：成功时 `prefs` 是新偏好、`error` 为 null；失败时 `prefs`
  /// 为 null、`error` 是给用户看的中文原因——UI 直接弹提示，不靠异常传递。
  ({OverlayPrefs? prefs, String? error}) saveAsMyTheme({
    required String id,
    required String name,
  }) {
    final String trimmed = name.trim();
    final String? invalid = _validateMyThemeName(trimmed);
    if (invalid != null) return (prefs: null, error: invalid);
    if (myThemes.length >= maxMyThemes) {
      return (prefs: null, error: '最多保存 $maxMyThemes 套主题，请先删除一套');
    }
    if (colorOverrides.isEmpty) {
      return (prefs: null, error: '当前没有任何自定义颜色，无需保存');
    }
    if (myThemes.any((MyTheme theme) => theme.name == trimmed)) {
      return (prefs: null, error: '已经有叫「$trimmed」的主题了');
    }
    if (myThemes.any(
      (MyTheme theme) =>
          theme.baseThemeId == themeId &&
          _sameOverrides(theme.overrides, colorOverrides),
    )) {
      return (prefs: null, error: '这套配色已经保存过了');
    }
    final MyTheme created = MyTheme(
      id: id,
      name: trimmed,
      baseThemeId: themeId,
      overrides: Map<String, int>.unmodifiable(colorOverrides),
    );
    return (
      prefs: copyWith(myThemes: <MyTheme>[...myThemes, created]),
      error: null,
    );
  }

  /// 重命名：只改 `name`，不动 `id` / 基础预设 / 覆盖表（#147）。
  ({OverlayPrefs? prefs, String? error}) renameMyTheme({
    required String id,
    required String name,
  }) {
    final int index = myThemes.indexWhere((MyTheme theme) => theme.id == id);
    if (index < 0) return (prefs: null, error: '这个主题已经不在了');
    final String trimmed = name.trim();
    final String? invalid = _validateMyThemeName(trimmed);
    if (invalid != null) return (prefs: null, error: invalid);
    if (myThemes.any(
      (MyTheme theme) => theme.id != id && theme.name == trimmed,
    )) {
      return (prefs: null, error: '已经有叫「$trimmed」的主题了');
    }
    final List<MyTheme> next = <MyTheme>[...myThemes];
    final MyTheme old = next[index];
    next[index] = MyTheme(
      id: old.id,
      name: trimmed,
      baseThemeId: old.baseThemeId,
      overrides: old.overrides,
    );
    return (prefs: copyWith(myThemes: next), error: null);
  }

  /// 用当前配色覆盖某个已保存主题（#147）：基础预设与覆盖表一起更新。
  ({OverlayPrefs? prefs, String? error}) updateMyThemeWithCurrent(String id) {
    final int index = myThemes.indexWhere((MyTheme theme) => theme.id == id);
    if (index < 0) return (prefs: null, error: '这个主题已经不在了');
    if (colorOverrides.isEmpty) {
      return (prefs: null, error: '当前没有任何自定义颜色，无需更新');
    }
    final List<MyTheme> next = <MyTheme>[...myThemes];
    final MyTheme old = next[index];
    next[index] = MyTheme(
      id: old.id,
      name: old.name,
      baseThemeId: themeId,
      overrides: Map<String, int>.unmodifiable(colorOverrides),
    );
    return (prefs: copyWith(myThemes: next), error: null);
  }

  /// 删除一条自定义主题（#147）。只动列表；调用方负责先二次确认。
  OverlayPrefs removeMyTheme(String id) => copyWith(
    myThemes: <MyTheme>[
      for (final MyTheme theme in myThemes)
        if (theme.id != id) theme,
    ],
  );

  /// 应用某个已保存主题：把「基础预设 + 覆盖表」一次性写回当前偏好（#147）。
  ///
  /// 这正是「不把自定义 id 塞进 themeId」的好处——应用只是一次普通赋值，渲染侧
  /// 仍走既有 `preset(themeId).resolve(colorOverrides)`，不需要任何新分支。
  /// 找不到 id 时返回 null（列表已被别处改过，调用方按「主题已经不在了」提示）。
  OverlayPrefs? applyMyTheme(String id) {
    for (final MyTheme theme in myThemes) {
      if (theme.id != id) continue;
      return copyWith(
        themeId: theme.baseThemeId,
        colorOverrides: Map<String, int>.unmodifiable(theme.overrides),
      );
    }
    return null;
  }

  Map<String, PaneStyle> _stylesFor(List<String> rooms) => <String, PaneStyle>{
    for (final String room in rooms)
      if (paneStyles[room] != null) room: paneStyles[room]!,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    // 按 design.md 2.3 的 panes 结构存放：每栏的房间与样式（prd F5）写在一起。
    'panes': <Map<String, Object?>>[
      for (int index = 0; index < webRids.length; index++)
        <String, Object?>{
          'index': index,
          'room_id': webRids[index],
          ...?paneStyles[webRids[index]]?.toJson(),
        },
    ],
    'opacity': clampOverlayOpacity(opacity),
    'fontSize': clampDanmuFontSize(fontSize),
    'scrollSpeed': clampDanmuScrollSpeed(scrollSpeed),
    // schemaVersion 只写不分支：字段级「缺则推导」已能兼容前后版本，多一层版本分支
    // 只会多出不可测路径；写出来是为了让备份文件可读、可人工诊断。
    'schemaVersion': overlayPrefsSchemaVersion,
    'themeId': themeId,
    // 继续写 lightTheme 作为旧版本回滚保险：老代码读它仍能还原深浅。
    'lightTheme': lightTheme,
    'colorOverrides': colorOverrides,
    'recentColors': recentColors,
    // 自定义主题（#147）：整份快照，缺字段的旧 JSON 读成空表。
    'gridDirection': parseGridDirection(gridDirection),
    'myThemes': <Object?>[
      for (final MyTheme theme in myThemes) theme.toJson(),
    ],
    'contrastPolicy': clampOverlayContrastPolicy(contrastPolicy),
    'showTitleBar': showTitleBar,
    'focusBehavior': clampFocusBehavior(focusBehavior),
    'dragLocked': dragLocked,
    'ballCorner': clampBallCorner(ballCorner),
    'clickThrough': clickThrough,
    'window': <String, Object?>{
      'width': clampOverlayWidth(windowWidth),
      'height': clampOverlayHeight(windowHeight),
      if (windowX != null) 'x': windowX,
      if (windowY != null) 'y': windowY,
    },
  };

  /// 解析一份偏好；结构完全对不上时返回 null，由调用方回落默认值。
  static OverlayPrefs? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? panes = raw['panes'];
    final Object? opacity = raw['opacity'];
    final Object? fontSize = raw['fontSize'];
    final Object? scrollSpeed = raw['scrollSpeed'];
    final Object? window = raw['window'];
    final Object? width = window is Map ? window['width'] : null;
    final Object? height = window is Map ? window['height'] : null;
    final Object? windowX = window is Map ? window['x'] : null;
    final Object? windowY = window is Map ? window['y'] : null;
    return OverlayPrefs(
      webRids: panes is List ? _parsePanes(panes) : const <String>[],
      paneStyles: panes is List
          ? _parsePaneStyles(panes)
          : const <String, PaneStyle>{},
      opacity: opacity is num
          ? clampOverlayOpacity(opacity.toDouble())
          : defaultOverlayOpacity,
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : defaultDanmuFontSize,
      scrollSpeed: scrollSpeed is num
          ? clampDanmuScrollSpeed(scrollSpeed.toDouble())
          : defaultDanmuScrollSpeed,
      windowWidth: width is num
          ? clampOverlayWidth(width.toDouble())
          : defaultOverlayWidth,
      windowHeight: height is num
          ? clampOverlayHeight(height.toDouble())
          : defaultOverlayHeight,
      themeId: _parseThemeId(raw),
      colorOverrides: parseColorOverrides(raw['colorOverrides']),
      recentColors: _parseRecentColors(raw['recentColors']),
      gridDirection: parseGridDirection(raw['gridDirection']),
      myThemes: parseMyThemes(raw['myThemes']),
      contrastPolicy: clampOverlayContrastPolicy(raw['contrastPolicy']),
      showTitleBar: raw['showTitleBar'] != false,
      focusBehavior: clampFocusBehavior(raw['focusBehavior']),
      dragLocked: raw['dragLocked'] == true,
      ballCorner: clampBallCorner(raw['ballCorner']),
      clickThrough: raw['clickThrough'] == true,
      windowX: windowX is num ? windowX.toDouble() : null,
      windowY: windowY is num ? windowY.toDouble() : null,
    );
  }

  /// 按栏位序号还原绑定顺序：显式带序号的先按序号排，缺序号的按出现顺序追加在后。
  /// 空房间与坏记录直接跳过。
  static List<String> _parsePanes(List<Object?> panes) {
    final List<({int index, String roomId})> indexed =
        <({int index, String roomId})>[];
    final List<String> unindexed = <String>[];
    for (final Object? pane in panes) {
      if (pane is! Map) continue;
      final Object? roomId = pane['room_id'];
      if (roomId is! String || roomId.trim().isEmpty) continue;
      final Object? index = pane['index'];
      if (index is int) {
        indexed.add((index: index, roomId: roomId.trim()));
      } else {
        unindexed.add(roomId.trim());
      }
    }
    indexed.sort(
      (({int index, String roomId}) a, ({int index, String roomId}) b) =>
          a.index.compareTo(b.index),
    );
    return <String>[
      for (final ({int index, String roomId}) item in indexed) item.roomId,
      ...unindexed,
    ];
  }

  /// 从 panes 里还原各栏样式覆盖（prd F5）：没有样式字段的记录直接跳过。
  static Map<String, PaneStyle> _parsePaneStyles(List<Object?> panes) {
    final Map<String, PaneStyle> styles = <String, PaneStyle>{};
    for (final Object? pane in panes) {
      if (pane is! Map) continue;
      final Object? roomId = pane['room_id'];
      if (roomId is! String || roomId.trim().isEmpty) continue;
      final PaneStyle? style = PaneStyle.tryParse(pane);
      if (style != null) styles[roomId.trim()] = style;
    }
    return styles;
  }

  @override
  String toString() => 'OverlayPrefs(webRids: $webRids, opacity: $opacity)';
}

/// 解析配置文件内容；内容损坏或结构对不上时返回 null。
OverlayPrefs? decodeOverlayPrefs(String raw) {
  if (raw.trim().isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  return OverlayPrefs.tryParse(decoded);
}

/// 序列化分栏配置。
String encodeOverlayPrefs(OverlayPrefs prefs) =>
    const JsonEncoder.withIndent('  ').convert(prefs.toJson());

class OverlayPrefsStore {
  OverlayPrefsStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = overlayPrefsFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// 读取偏好；文件缺失或内容损坏时返回默认偏好，不让启动被脏文件卡住。
  Future<OverlayPrefs> load() async {
    final File file = await _file();
    if (!await file.exists()) return const OverlayPrefs();
    return decodeOverlayPrefs(await file.readAsString()) ??
        const OverlayPrefs();
  }

  /// 覆盖写入偏好。
  Future<void> save(OverlayPrefs prefs) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(encodeOverlayPrefs(prefs), flush: true);
  }

  /// 删除偏好文件（「清除所有本地数据」用，见 prd F26）。
  Future<void> clear() async {
    final File file = await _file();
    if (await file.exists()) await file.delete();
  }
}
