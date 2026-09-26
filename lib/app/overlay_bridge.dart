// 主 App 与悬浮窗引擎之间的消息协议。
//
// 悬浮窗由 flutter_screen_overlay 在**独立 Flutter 引擎**中启动（前台服务进程内），
// 两个引擎不共享内存对象，房间配置与运行状态只能经 BasicMessageChannel 传递，
// 且载荷必须是 JSON 可序列化的（插件用 JSONMessageCodec）。
//
// 协议约定：
//   主 App → 悬浮窗：config（各栏要连接的房间 + 外观）/ style（只改外观）
//                    / close（关闭悬浮窗）
//   悬浮窗 → 主 App：state（阶段、已收条数、错误摘要）
import 'package:danmu_float/app/live_danmu_session.dart';

const String overlayConfigType = 'config';
const String overlayStyleType = 'style';
const String overlayCloseType = 'close';
const String overlayStateType = 'state';

/// 弹幕背景蒙版不透明度的可调范围（prd F2）：低于 0.2 看不清弹幕，
/// 高于 0.8 会挡住直播画面。注意作用对象是蒙版，不是窗口整体。
const double minOverlayOpacity = 0.2;
const double maxOverlayOpacity = 0.8;
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

/// 按栏数推荐的窗口尺寸，设置页「按栏数推荐」按钮用。
({double width, double height}) recommendedOverlaySize(int paneCount) =>
    switch (paneCount) {
      <= 1 => (width: 240, height: 320),
      <= 2 => (width: 400, height: 320),
      <= 4 => (width: 400, height: 560),
      <= 6 => (width: 560, height: 560),
      _ => (width: 560, height: 800),
    };

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

/// 主 App 下发的连接配置。
class OverlayConfig {
  const OverlayConfig({
    required this.webRids,
    this.opacity = defaultOverlayOpacity,
    this.fontSize = defaultDanmuFontSize,
  });

  /// 各栏绑定的直播间号，按栏位顺序排列（栏 0 在前）。
  final List<String> webRids;

  /// 悬浮窗背景不透明度（prd F2 的「透明度」项）。
  final double opacity;

  /// 弹幕基准字号（dp），各栏按 [grid] 的栏数缩小后使用。
  final double fontSize;

  /// 由房间数推导的网格布局。
  OverlayGrid get grid => OverlayGrid(webRids.length);

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayConfigType,
        'webRids': webRids,
        'opacity': clampOverlayOpacity(opacity),
        'fontSize': clampDanmuFontSize(fontSize),
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
    return OverlayConfig(
      webRids: parsed,
      opacity: opacity is num
          ? clampOverlayOpacity(opacity.toDouble())
          : defaultOverlayOpacity,
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : defaultDanmuFontSize,
    );
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
  });

  final double opacity;
  final double fontSize;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayStyleType,
        'opacity': clampOverlayOpacity(opacity),
        'fontSize': clampDanmuFontSize(fontSize),
      };

  /// 解析样式消息；非 style 消息或缺少透明度时返回 null。
  static OverlayStyle? tryParse(Object? raw) {
    if (raw is! Map || raw['type'] != overlayStyleType) return null;
    final Object? opacity = raw['opacity'];
    if (opacity is! num) return null;
    final Object? fontSize = raw['fontSize'];
    return OverlayStyle(
      opacity: clampOverlayOpacity(opacity.toDouble()),
      fontSize: fontSize is num
          ? clampDanmuFontSize(fontSize.toDouble())
          : defaultDanmuFontSize,
    );
  }
}

/// 消息是否为关闭悬浮窗指令。
bool isOverlayCloseMessage(Object? raw) =>
    raw is Map && raw['type'] == overlayCloseType;

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
  });

  final LiveSessionStage stage;
  final int received;
  final String? webRid;
  final String? error;

  /// 悬浮窗自查发现权限已被撤销：此时各栏已卸载、连接已断开，
  /// 主 App 收到后应把「悬浮窗已开启」的状态改回未开启。
  final bool permissionRevoked;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayStateType,
        'stage': stage.name,
        'received': received,
        'webRid': webRid,
        'error': error,
        'permissionRevoked': permissionRevoked,
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
    return OverlayStatus(
      stage: stage,
      received: received is int ? received : 0,
      webRid: webRid is String ? webRid : null,
      error: error is String ? error : null,
      permissionRevoked: raw['permissionRevoked'] == true,
    );
  }
}