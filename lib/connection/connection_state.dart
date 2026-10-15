/// 单房间弹幕连接状态。
enum DanmuConnectionState {
  idle,
  connecting,
  connected,
  reconnecting,

  /// 重连次数达上限，停止重连该房间（design.md 11.5）
  failed,

  /// 用户主动关闭，不再重连
  closed,
}

/// 连接状态的中文文案（诊断信息与详情页共用）。
///
/// 直接写 `state.name` 会把 idle / connecting 这类英文标识暴露给用户：用户既看不懂，
/// 也没法据此描述问题，而诊断信息正是要复制给他人排查的（UX-09）。
String connectionStateLabel(DanmuConnectionState state) => switch (state) {
  DanmuConnectionState.idle => '未连接',
  DanmuConnectionState.connecting => '连接中',
  DanmuConnectionState.connected => '已连接',
  DanmuConnectionState.reconnecting => '重连中',
  DanmuConnectionState.failed => '重连失败',
  DanmuConnectionState.closed => '已关闭',
};

/// 连接状态机：只负责状态流转与重连计数，不做任何 IO，
/// 便于离线单测覆盖「固定 10s 重连、单房间最多 10 次、连接成功计数清零」口径。
class ConnectionStateMachine {
  ConnectionStateMachine({
    this.maxReconnectAttempts = 10,
    this.reconnectInterval = const Duration(seconds: 10),
  });

  /// 单房间最大重连次数（design.md 12.1）
  final int maxReconnectAttempts;

  /// 重连间隔，固定值（design.md 11.5）
  final Duration reconnectInterval;

  DanmuConnectionState _state = DanmuConnectionState.idle;
  int _reconnectAttempts = 0;

  DanmuConnectionState get state => _state;

  int get reconnectAttempts => _reconnectAttempts;

  void onConnecting() {
    _state = DanmuConnectionState.connecting;
  }

  /// 连接建立成功：重连计数清零。
  void onConnected() {
    _reconnectAttempts = 0;
    _state = DanmuConnectionState.connected;
  }

  /// 连接断开：返回需要等待的重连间隔；已达上限返回 null 并进入 failed。
  Duration? onDisconnected() {
    if (_state == DanmuConnectionState.closed) return null;
    if (_reconnectAttempts >= maxReconnectAttempts) {
      _state = DanmuConnectionState.failed;
      return null;
    }
    _reconnectAttempts++;
    _state = DanmuConnectionState.reconnecting;
    return reconnectInterval;
  }

  /// 主动关闭：不再重连。
  void onClosed() {
    _reconnectAttempts = maxReconnectAttempts;
    _state = DanmuConnectionState.closed;
  }

  void reset() {
    _reconnectAttempts = 0;
    _state = DanmuConnectionState.idle;
  }
}