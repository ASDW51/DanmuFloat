// 悬浮窗样式与分栏配置的本地持久化（design.md 2.1 / 2.3 的「分栏配置（JSON）」）。
//
// 与主播列表分两个文件存：主播列表是用户资产，分栏配置只是样式偏好，
// 写入时机与损坏后的影响面都不同，混在一个文件里容易互相覆盖。
//
// 布局（几行几列）由栏位数推导，没有可选项，故不入文件。
import 'dart:convert';
import 'dart:io';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:path_provider/path_provider.dart';

/// 分栏配置文件名。
const String overlayPrefsFileName = 'overlay.json';

/// 悬浮窗样式与分栏偏好。
class OverlayPrefs {
  const OverlayPrefs({
    this.webRids = const <String>[],
    this.opacity = defaultOverlayOpacity,
    this.fontSize = defaultDanmuFontSize,
    this.windowWidth = defaultOverlayWidth,
    this.windowHeight = defaultOverlayHeight,
  });

  /// 上次勾选的主播，按栏位顺序排列（下次打开多栏弹窗时据此预勾选）。
  final List<String> webRids;

  /// 弹幕背景蒙版不透明度。
  final double opacity;

  /// 弹幕基准字号（dp）：单栏直接使用，多栏按栏数缩小。
  final double fontSize;

  /// 悬浮窗窗口宽度（dp）。
  final double windowWidth;

  /// 悬浮窗窗口高度（dp）。
  final double windowHeight;

  /// 窗口尺寸，供建窗 / 重排窗口时使用。
  ({double width, double height}) get windowSize => (
        width: clampOverlayWidth(windowWidth),
        height: clampOverlayHeight(windowHeight),
      );

  OverlayPrefs copyWith({
    List<String>? webRids,
    double? opacity,
    double? fontSize,
    double? windowWidth,
    double? windowHeight,
  }) =>
      OverlayPrefs(
        webRids: webRids ?? this.webRids,
        opacity: opacity ?? this.opacity,
        fontSize: fontSize ?? this.fontSize,
        windowWidth: windowWidth ?? this.windowWidth,
        windowHeight: windowHeight ?? this.windowHeight,
      );

  /// 组装成下发给悬浮窗的配置。
  OverlayConfig toConfig(List<String> rooms) => OverlayConfig(
        webRids: rooms,
        opacity: clampOverlayOpacity(opacity),
        fontSize: clampDanmuFontSize(fontSize),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        // 按 design.md 2.3 的 panes 结构存放，后续每栏颜色等也挂在这里。
        'panes': <Map<String, Object?>>[
          for (int index = 0; index < webRids.length; index++)
            <String, Object?>{'index': index, 'room_id': webRids[index]},
        ],
        'opacity': clampOverlayOpacity(opacity),
        'fontSize': clampDanmuFontSize(fontSize),
        'window': <String, Object?>{
          'width': clampOverlayWidth(windowWidth),
          'height': clampOverlayHeight(windowHeight),
        },
      };

  /// 解析一份偏好；结构完全对不上时返回 null，由调用方回落默认值。
  static OverlayPrefs? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? panes = raw['panes'];
    final Object? opacity = raw['opacity'];
    final Object? fontSize = raw['fontSize'];
    final Object? window = raw['window'];
    final Object? width = window is Map ? window['width'] : null;
    final Object? height = window is Map ? window['height'] : null;
    return OverlayPrefs(
      webRids: panes is List ? _parsePanes(panes) : const <String>[],
      opacity: opacity is num
          ? clampOverlayOpacity(opacity.toDouble())
          : defaultOverlayOpacity,
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : defaultDanmuFontSize,
      windowWidth: width is num
          ? clampOverlayWidth(width.toDouble())
          : defaultOverlayWidth,
      windowHeight: height is num
          ? clampOverlayHeight(height.toDouble())
          : defaultOverlayHeight,
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
    indexed.sort((({int index, String roomId}) a,
            ({int index, String roomId}) b) =>
        a.index.compareTo(b.index));
    return <String>[
      for (final ({int index, String roomId}) item in indexed) item.roomId,
      ...unindexed,
    ];
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
    return decodeOverlayPrefs(await file.readAsString()) ?? const OverlayPrefs();
  }

  /// 覆盖写入偏好。
  Future<void> save(OverlayPrefs prefs) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(encodeOverlayPrefs(prefs), flush: true);
  }
}