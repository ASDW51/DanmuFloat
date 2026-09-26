// 主 App 与悬浮窗引擎之间的消息协议。
//
// 悬浮窗由 flutter_screen_overlay 在**独立 Flutter 引擎**中启动（前台服务进程内），
// 两个引擎不共享内存对象，房间配置与运行状态只能经 BasicMessageChannel 传递，
// 且载荷必须是 JSON 可序列化的（插件用 JSONMessageCodec）。
//
// 协议约定：
//   主 App → 悬浮窗：config（布局 + 各栏要连接的房间）/ close（关闭悬浮窗）
//   悬浮窗 → 主 App：state（阶段、已收条数、错误摘要）
import 'package:danmu_float/app/live_danmu_session.dart';

const String overlayConfigType = 'config';
const String overlayCloseType = 'close';
const String overlayStateType = 'state';

/// 悬浮窗分栏布局（prd F3）：P0 只做 1 栏与 4 栏，6 / 9 栏属 P2。
enum OverlayLayout {
  single(1),
  quad(4);

  const OverlayLayout(this.paneCount);

  /// 该布局的栏位数，也是每栏可绑定房间数的上限。
  final int paneCount;

  /// 由房间数回落布局：P0 只认 1 / 4，其余一律按单栏处理。
  static OverlayLayout fromRoomCount(int count) =>
      count >= 4 ? OverlayLayout.quad : OverlayLayout.single;
}

/// 主 App 下发的连接配置。
class OverlayConfig {
  const OverlayConfig({
    required this.webRids,
    this.layout = OverlayLayout.single,
    this.opacity = 0.8,
  });

  /// 各栏绑定的直播间号，按栏位顺序排列（栏 0 在前）。
  /// 数量可少于 [layout] 的栏位数，未覆盖的栏位显示为「未绑定房间」。
  final List<String> webRids;

  /// 分栏布局。
  final OverlayLayout layout;

  /// 悬浮窗背景不透明度（prd F2 的「透明度」项）。
  final double opacity;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayConfigType,
        'webRids': webRids,
        'layout': layout.name,
        'opacity': opacity,
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
    final Object? layout = raw['layout'];
    final Object? opacity = raw['opacity'];
    return OverlayConfig(
      webRids: parsed,
      // 缺省或未知布局时按房间数推断，保证 4 个房间不会被塞进单栏。
      layout: OverlayLayout.values.firstWhere(
        (OverlayLayout value) => value.name == layout,
        orElse: () => OverlayLayout.fromRoomCount(parsed.length),
      ),
      opacity: opacity is num ? opacity.toDouble() : 0.8,
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
  });

  final LiveSessionStage stage;
  final int received;
  final String? webRid;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayStateType,
        'stage': stage.name,
        'received': received,
        'webRid': webRid,
        'error': error,
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
    );
  }
}