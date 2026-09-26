// 单房间弹幕会话：把「webRid → liveId → 签名 → WS 连接」串成一条链路，
// 对界面层只暴露连接状态、房间信息与弹幕流。
//
// 阶段划分对齐 design.md：11.2 未开播不连接、11.3 签名失败降级为 00000000、
// 11.5 心跳/超时/重连由 DanmuSocketClient 负责。
import 'dart:async';

import 'package:danmu_float/cache/ring_buffer.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';

/// 会话阶段，供界面提示当前进度。
enum LiveSessionStage {
  /// 未启动
  idle,

  /// 正在解析房间信息（webRid → liveId）
  resolvingRoom,

  /// 正在生成弹幕签名
  signing,

  /// 正在建立弹幕连接
  connecting,

  /// 已连接，弹幕持续流入
  live,

  /// 主播未开播，不建立弹幕连接
  offline,

  /// 寻址或连接失败
  error,
}

/// 便于单测注入假连接。
typedef DanmuSocketFactory = DanmuSocketClient Function({
  required String liveId,
  required String userUniqueId,
  required String signature,
  required String cookies,
});

/// 一个 webRid 对应一路弹幕会话。
class LiveDanmuSession {
  LiveDanmuSession({
    required this.webRid,
    RoomInfoClient? roomInfoClient,
    CookieProvider? cookieProvider,
    DanmuSigner? signer,
    DanmuSocketFactory? socketFactory,
    String Function()? userUniqueIdFactory,
    this.bufferCapacity = 500,
  })  : _roomInfoClient = roomInfoClient ?? RoomInfoClient(),
        _cookieProvider = cookieProvider ?? CookieProvider(),
        _signer = signer ?? WebmssdkDanmuSigner(),
        _socketFactory = socketFactory ?? _defaultSocketFactory,
        _userUniqueIdFactory = userUniqueIdFactory ?? generateUserUniqueId,
        _buffer = RingBuffer<DanmakuEvent>(bufferCapacity);

  static DanmuSocketClient _defaultSocketFactory({
    required String liveId,
    required String userUniqueId,
    required String signature,
    required String cookies,
  }) =>
      DanmuSocketClient(
        liveId: liveId,
        userUniqueId: userUniqueId,
        signature: signature,
        cookies: cookies,
      );

  final String webRid;
  final int bufferCapacity;

  final RoomInfoClient _roomInfoClient;
  final CookieProvider _cookieProvider;
  final DanmuSigner _signer;
  final DanmuSocketFactory _socketFactory;
  final String Function() _userUniqueIdFactory;
  final RingBuffer<DanmakuEvent> _buffer;

  final StreamController<LiveSessionStage> _stages =
      StreamController<LiveSessionStage>.broadcast();
  final StreamController<DanmakuEvent> _danmu =
      StreamController<DanmakuEvent>.broadcast();

  DanmuSocketClient? _socket;
  StreamSubscription<List<DanmakuEvent>>? _eventSubscription;
  StreamSubscription<DanmuConnectionState>? _stateSubscription;
  bool _stopped = false;

  LiveSessionStage _stage = LiveSessionStage.idle;
  RoomInfo? _room;
  String? _errorMessage;
  bool _signatureDegraded = false;
  String? _signatureWarning;

  /// 阶段变化流。
  Stream<LiveSessionStage> get stages => _stages.stream;

  /// 弹幕流（已去重、已过滤空文本）。
  Stream<DanmakuEvent> get danmu => _danmu.stream;

  LiveSessionStage get stage => _stage;

  /// 解析到的房间信息，寻址成功后可用。
  RoomInfo? get room => _room;

  String? get errorMessage => _errorMessage;

  /// 是否因签名失败而降级（design.md 11.3）。
  bool get signatureDegraded => _signatureDegraded;

  /// 签名降级的原始原因，便于诊断。
  String? get signatureWarning => _signatureWarning;

  /// 弹幕连接最近一次失败/断线的原因。
  String? get socketError => _socket?.lastError;

  DanmuConnectionState get connectionState =>
      _socket?.state ?? DanmuConnectionState.idle;

  /// 当前缓冲的弹幕快照（旧 → 新）。
  List<DanmakuEvent> get buffer => _buffer.toList();

  /// 解析房间信息 → 签名 → 建立弹幕连接。失败只上报错误，不抛出。
  Future<void> start() async {
    if (_stopped) return;
    _setStage(LiveSessionStage.resolvingRoom);
    _errorMessage = null;
    _signatureDegraded = false;
    _signatureWarning = null;

    final RoomInfo roomInfo;
    try {
      roomInfo = await _roomInfoClient.fetchByWebRid(webRid);
    } on Object catch (error) {
      _fail('房间信息获取失败：$error');
      return;
    }
    if (_stopped) return;
    _room = roomInfo;

    if (!roomInfo.living) {
      _setStage(LiveSessionStage.offline);
      return;
    }

    final String userUniqueId = _userUniqueIdFactory();
    _setStage(LiveSessionStage.signing);
    String signature;
    try {
      signature = await _signer.sign(
        buildDanmuSigParams(liveId: roomInfo.liveId, userUniqueId: userUniqueId),
      );
    } on Object catch (error) {
      // design.md 11.3：签名失败降级为固定值，仍尝试连接。
      // 这里放宽到所有异常，避免 flutter_js 加载失败等错误直接打断会话。
      _signatureDegraded = true;
      _signatureWarning = error.toString();
      signature = fallbackDanmuSignature;
    }
    if (_stopped) return;

    final String cookies;
    try {
      cookies = await _cookieProvider.getCookies();
    } on Object catch (error) {
      _fail('凭证获取失败：$error');
      return;
    }
    if (_stopped) return;

    _setStage(LiveSessionStage.connecting);
    final DanmuSocketClient socket = _socketFactory(
      liveId: roomInfo.liveId,
      userUniqueId: userUniqueId,
      signature: signature,
      cookies: cookies,
    );
    _socket = socket;
    _eventSubscription = socket.events.listen((List<DanmakuEvent> events) {
      for (final DanmakuEvent event in events) {
        _buffer.add(event);
        if (!_danmu.isClosed) _danmu.add(event);
      }
    });
    _stateSubscription = socket.states.listen((DanmuConnectionState state) {
      _onConnectionState(state);
    });
    socket.start();
  }

  /// 主动关闭：停止重连并释放网络资源。
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _socket?.stop();
    _socket = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
    _setStage(LiveSessionStage.idle);
    await _stages.close();
    await _danmu.close();
  }

  void _onConnectionState(DanmuConnectionState state) {
    switch (state) {
      case DanmuConnectionState.connected:
        _setStage(LiveSessionStage.live);
      case DanmuConnectionState.connecting:
      case DanmuConnectionState.reconnecting:
        _setStage(LiveSessionStage.connecting);
      case DanmuConnectionState.failed:
        _fail('重连次数达上限，已停止连接');
      case DanmuConnectionState.idle:
      case DanmuConnectionState.closed:
        break;
    }
  }

  void _fail(String message) {
    _errorMessage = message;
    _setStage(LiveSessionStage.error);
  }

  void _setStage(LiveSessionStage stage) {
    _stage = stage;
    if (!_stages.isClosed) _stages.add(stage);
  }
}