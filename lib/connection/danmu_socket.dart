// 弹幕 WebSocket 连接层（design.md 11.4 / 11.5）。
//
// - 每直播间一条独立连接；
// - 心跳：每 10s 发送文本帧 `:\x02hb`；
// - 超时：100s 未收到任何消息判定失联并重连（每秒检查一次）；
// - 重连：固定 10s，默认最多 10 次，达上限停止该房间；连接成功计数清零。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import '../danmu/model/danmaku_event.dart';
import '../danmu/push_frame_pipeline.dart';
import 'connection_state.dart';

/// 弹幕 WS 默认主机（与参考实现一致）。
const String defaultDanmuHost = 'webcast100-ws-web-hl.douyin.com';

/// 心跳文本帧。
const String danmuHeartbeatText = ':\u0002hb';

const String _wsPath = '/webcast/im/push/v2/';
const String _browserVersion =
    '5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/134.0.0.0 Safari/537.36';

/// application/x-www-form-urlencoded 编码，规则与 URLSearchParams 一致
/// （空格转 `+`，其余仅保留 `A-Za-z0-9*-._`）。
String formEncode(String value) {
  const String unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._';
  final StringBuffer output = StringBuffer();
  for (final int byte in utf8.encode(value)) {
    if (byte == 0x20) {
      output.write('+');
    } else if (byte < 0x80 && unreserved.contains(String.fromCharCode(byte))) {
      output.write(String.fromCharCode(byte));
    } else {
      output.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return output.toString();
}

/// 组装弹幕连接查询参数。顺序与参考实现 getWsInfo 的 webcast5Params 一致。
String buildDanmuWsQuery({
  required String liveId,
  required String userUniqueId,
  required String signature,
  int versionCode = 180800,
  String webcastSdkVersion = '1.0.15',
}) {
  final Map<String, String> params = <String, String>{
    'app_name': 'douyin_web',
    'room_id': liveId,
    'compress': 'gzip',
    'version_code': '$versionCode',
    'webcast_sdk_version': webcastSdkVersion,
    'update_version_code': webcastSdkVersion,
    'live_id': '1',
    'did_rule': '3',
    'user_unique_id': userUniqueId,
    'identity': 'audience',
    'signature': signature,
    'device_platform': 'web',
    'cookie_enabled': 'true',
    'screen_width': '1920',
    'screen_height': '1080',
    'browser_language': 'zh-CN',
    'browser_platform': 'Win32',
    'browser_name': 'Mozilla',
    'browser_version': _browserVersion,
    'browser_online': 'true',
    'tz_name': 'Etc/GMT-8',
    'host': 'https://live.douyin.com',
    'aid': '6383',
    'endpoint': 'live_pc',
    'support_wrds': '1',
    'im_path': '/webcast/im/fetch/',
    'need_persist_msg_count': '15',
    'heartbeatDuration': '0',
  };
  return params.entries
      .map((MapEntry<String, String> e) =>
          '${formEncode(e.key)}=${formEncode(e.value)}')
      .join('&');
}

/// 构造弹幕 WebSocket 地址。
Uri buildDanmuWsUri({
  required String liveId,
  required String userUniqueId,
  required String signature,
  int versionCode = 180800,
  String webcastSdkVersion = '1.0.15',
  String host = defaultDanmuHost,
}) {
  final String query = buildDanmuWsQuery(
    liveId: liveId,
    userUniqueId: userUniqueId,
    signature: signature,
    versionCode: versionCode,
    webcastSdkVersion: webcastSdkVersion,
  );
  return Uri.parse('wss://$host$_wsPath?$query');
}

/// 连接层抽象的通道，便于离线单测注入。
abstract class DanmuChannel {
  Stream<dynamic> get stream;

  void send(Object data);

  Future<void> close();
}

/// 可选的关闭信息：实现方（如 dart:io 通道）在连接关闭后提供关闭码与原因，
/// 供上层诊断「握手被拒」与「连上后被踢」这两类完全不同的失败。
abstract interface class DanmuChannelCloseInfo {
  int? get closeCode;
  String? get closeReason;
}

typedef DanmuChannelFactory = Future<DanmuChannel> Function(
  Uri uri,
  Map<String, String> headers,
);

/// 默认实现：dart:io WebSocket。
class IoDanmuChannel implements DanmuChannel, DanmuChannelCloseInfo {
  IoDanmuChannel(this._channel);

  static Future<DanmuChannel> connect(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final IOWebSocketChannel channel = IOWebSocketChannel.connect(
      uri,
      headers: headers,
    );
    await channel.ready;
    return IoDanmuChannel(channel);
  }

  final IOWebSocketChannel _channel;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(Object data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}

/// 单个直播间的弹幕连接。
class DanmuSocketClient {
  DanmuSocketClient({
    required this.liveId,
    required this.userUniqueId,
    required this.signature,
    required this.cookies,
    PushFramePipeline? pipeline,
    ConnectionStateMachine? stateMachine,
    DanmuChannelFactory? channelFactory,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.timeoutInterval = const Duration(seconds: 100),
    this.timeoutCheckInterval = const Duration(seconds: 1),
    String host = defaultDanmuHost,
  })  : pipeline = pipeline ?? PushFramePipeline(),
        _stateMachine = stateMachine ?? ConnectionStateMachine(),
        _channelFactory = channelFactory ?? IoDanmuChannel.connect,
        _host = host;

  final String liveId;
  final String userUniqueId;
  final String signature;
  final String cookies;
  final PushFramePipeline pipeline;

  final Duration heartbeatInterval;
  final Duration timeoutInterval;
  final Duration timeoutCheckInterval;

  final ConnectionStateMachine _stateMachine;
  final DanmuChannelFactory _channelFactory;
  final String _host;

  final StreamController<List<DanmakuEvent>> _events =
      StreamController<List<DanmakuEvent>>.broadcast();
  final StreamController<DanmuConnectionState> _states =
      StreamController<DanmuConnectionState>.broadcast();

  DanmuChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _timeoutTimer;
  Timer? _reconnectTimer;
  DateTime? _lastMessageAt;
  bool _stopped = false;
  String? _lastError;

  /// 最近一次建连失败或断线的原因，用于诊断；连接成功时清空。
  String? get lastError => _lastError;

  /// 解析出的弹幕事件流。
  Stream<List<DanmakuEvent>> get events => _events.stream;

  /// 连接状态流。
  Stream<DanmuConnectionState> get states => _states.stream;

  DanmuConnectionState get state => _stateMachine.state;

  DateTime Function() now = DateTime.now;

  /// 启动连接。重复调用无副作用。
  void start() {
    if (_stopped || _stateMachine.state == DanmuConnectionState.connecting) return;
    unawaited(_connect());
  }

  /// 主动停止：不再重连。
  Future<void> stop() async {
    _stopped = true;
    _stateMachine.onClosed();
    _emitState();
    await _teardown();
    await _events.close();
    await _states.close();
  }

  Future<void> _connect() async {
    if (_stopped) return;
    _stateMachine.onConnecting();
    _emitState();

    final Uri uri = buildDanmuWsUri(
      liveId: liveId,
      userUniqueId: userUniqueId,
      signature: signature,
      host: _host,
    );

    try {
      final DanmuChannel channel = await _channelFactory(uri, <String, String>{
        'Cookie': cookies,
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
        'Origin': 'https://live.douyin.com',
        'Referer': 'https://live.douyin.com/',
      });
      if (_stopped) {
        await channel.close();
        return;
      }
      _channel = channel;
      _lastMessageAt = now();
      _lastError = null;
      _stateMachine.onConnected();
      _emitState();
      _startTimers();
      _subscription = channel.stream.listen(
        _onData,
        onError: (Object error) {
          _lastError = error.toString();
          _onDisconnected();
        },
        onDone: _onDisconnected,
        cancelOnError: true,
      );
    } on Object catch (error) {
      _lastError = error.toString();
      _onDisconnected();
    }
  }

  void _startTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      _channel?.send(danmuHeartbeatText);
    });

    _timeoutTimer?.cancel();
    _timeoutTimer = Timer.periodic(timeoutCheckInterval, (_) {
      final DateTime? last = _lastMessageAt;
      if (last == null) return;
      if (now().difference(last) >= timeoutInterval) {
        // 100s 无消息：判定失联
        _onDisconnected();
      }
    });
  }

  void _onData(dynamic data) {
    _lastMessageAt = now();
    if (data is! List<int>) return;

    final PipelineOutput output = pipeline.process(
      data is Uint8List ? data : Uint8List.fromList(data),
    );
    if (output.events.isNotEmpty) {
      _events.add(output.events);
    }
    final Uint8List? ack = output.ackFrame;
    if (ack != null) {
      _channel?.send(ack);
    }
  }

  void _onDisconnected() {
    if (_stopped) return;
    final DanmuConnectionState current = _stateMachine.state;
    if (current == DanmuConnectionState.failed ||
        current == DanmuConnectionState.closed ||
        current == DanmuConnectionState.reconnecting) {
      // 已进入重连/终止流程，避免 onError 与 onDone 重复计数
      return;
    }

    // 关闭码须在 teardown 前读取（teardown 会释放通道）
    final DanmuChannel? closing = _channel;
    if (closing
        case DanmuChannelCloseInfo(
          closeCode: final int? code,
          closeReason: final String? reason,
        )) {
      if (code != null) {
        final String text = reason ?? '';
        _lastError =
            '连接被关闭 code=$code${text.isEmpty ? '' : ' reason=$text'}';
      }
    }
    unawaited(_teardown());

    final Duration? delay = _stateMachine.onDisconnected();
    _emitState();
    if (delay == null) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => unawaited(_connect()));
  }

  Future<void> _teardown() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final StreamSubscription<dynamic>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    final DanmuChannel? channel = _channel;
    _channel = null;
    await channel?.close();
  }

  void _emitState() {
    if (!_states.isClosed) _states.add(_stateMachine.state);
  }
}