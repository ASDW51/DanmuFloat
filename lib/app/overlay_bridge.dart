// 主 App 与悬浮窗引擎之间的消息协议。
//
// 悬浮窗由 flutter_screen_overlay 在**独立 Flutter 引擎**中启动（前台服务进程内），
// 两个引擎不共享内存对象，房间配置与运行状态只能经 BasicMessageChannel 传递，
// 且载荷必须是 JSON 可序列化的（插件用 JSONMessageCodec）。
//
// 协议约定：
//   主 App → 悬浮窗：config（要连接的房间）/ close（关闭悬浮窗）
//   悬浮窗 → 主 App：state（阶段、已收条数、错误摘要）
import 'package:danmu_float/app/live_danmu_session.dart';

const String overlayConfigType = 'config';
const String overlayCloseType = 'close';
const String overlayStateType = 'state';

/// 主 App 下发的连接配置。
class OverlayConfig {
  const OverlayConfig({required this.webRid, this.opacity = 0.8});

  final String webRid;

  /// 悬浮窗背景不透明度（prd F2 的「透明度」项）。
  final double opacity;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': overlayConfigType,
        'webRid': webRid,
        'opacity': opacity,
      };

  /// 解析主 App 下发的消息；非 config 消息或字段不合法时返回 null。
  static OverlayConfig? tryParse(Object? raw) {
    if (raw is! Map) return null;
    if (raw['type'] != overlayConfigType) return null;
    final Object? webRid = raw['webRid'];
    if (webRid is! String || webRid.isEmpty) return null;
    final Object? opacity = raw['opacity'];
    return OverlayConfig(
      webRid: webRid,
      opacity: opacity is num ? opacity.toDouble() : 0.8,
    );
  }
}

/// 消息是否为关闭悬浮窗指令。
bool isOverlayCloseMessage(Object? raw) =>
    raw is Map && raw['type'] == overlayCloseType;

/// 悬浮窗上报给主 App 的运行状态。
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