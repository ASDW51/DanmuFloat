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
import 'package:flutter/foundation.dart';

/// 未开播时的复检间隔。
///
/// design.md 11.2 要求未开播不建立弹幕连接，但挂机看多栏是核心场景：主播开播后
/// 栏位必须自己接上，不能等用户发现并手动关窗重开（重开会重建全部栏位）。
const Duration defaultOfflineRecheckInterval = Duration(seconds: 30);

/// 未开播复检次数上限（默认间隔下约 10 分钟）。
///
/// 到顶后停止轮询，避免对着一个长期不开播的房间无限发请求；此时栏位保留
/// [LiveDanmuSession.autoRechecking] 为 false 的「未开播」，由界面上的手动重试兜底。
const int defaultMaxOfflineRechecks = 20;

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

/// 是否应给出「重试」入口：连接失败，或未开播且已停止自动复检（复检次数用尽）。
///
/// 悬浮窗栏位与 App 内弹幕页共用同一口径（UX-02）：这两种状态下会话不会自己恢复，
/// 必须给出可点出口，否则用户只能关窗 / 退出重进——那会重建全部栏位、把其它正常
/// 栏位的连接一并断掉，也会丢掉已收到的弹幕。
bool shouldOfferRetry(
  LiveSessionStage stage, {
  required bool autoRechecking,
}) =>
    stage == LiveSessionStage.error ||
    (stage == LiveSessionStage.offline && !autoRechecking);

/// 一个 webRid 对应一路弹幕会话。
class LiveDanmuSession {
  LiveDanmuSession({
    required this.webRid,
    RoomInfoClient? roomInfoClient,
    CookieProvider? cookieProvider,
    String? credentialCookies,
    DanmuSigner? signer,
    DanmuSocketFactory? socketFactory,
    String Function()? userUniqueIdFactory,
    this.bufferCapacity = 500,
    this.offlineRecheckInterval = defaultOfflineRecheckInterval,
    this.maxOfflineRechecks = defaultMaxOfflineRechecks,
  })  : _roomInfoClient = roomInfoClient ?? RoomInfoClient(),
        _cookieProvider =
            cookieProvider ?? CookieProvider(credentialCookies: credentialCookies),
        _credentialCookies = normalizeCredentialCookies(credentialCookies),
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

  /// 未开播复检间隔（测试注入更短的值，避免真等 30 秒）。
  final Duration offlineRecheckInterval;

  /// 未开播复检次数上限。
  final int maxOfflineRechecks;

  final RoomInfoClient _roomInfoClient;
  final CookieProvider _cookieProvider;
  final String? _credentialCookies;
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
  Timer? _offlineRecheckTimer;
  int _offlineRecheckCount = 0;
  bool _stopped = false;

  /// 正在走「解析房间 → 建连」或复检流程。
  ///
  /// 没有它时，复检定时器与手动重试可能并发进入，覆盖 `_socket` /
  /// `_eventSubscription` 造成连接泄漏（旧连接没人停）。
  bool _starting = false;

  /// 复检请求已发出、还没回来。
  ///
  /// 此时定时器已置空，光看定时器会把「正在复检」误判成「已停止复检」，
  /// 界面会过早给出重试入口。
  bool _rechecking = false;

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

  /// 是否已排定下一次未开播复检，或复检请求正在飞行中（界面据此显示「自动复检中」）。
  ///
  /// 复检次数到顶或会话已停止时为 false：此时栏位真的不会再自己恢复，
  /// 界面不该继续显示「自动复检中」骗用户，而应给出可点的重试入口。
  bool get autoRechecking => _offlineRecheckTimer != null || _rechecking;

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
    if (_stopped || _starting) return;
    _starting = true;
    // 主动发起的启动是一次全新尝试：清掉上一轮的复检定时器与计数。
    _cancelOfflineRecheck();
    _offlineRecheckCount = 0;
    try {
      _setStage(LiveSessionStage.resolvingRoom);
      _errorMessage = null;
      _signatureDegraded = false;
      _signatureWarning = null;

      final RoomInfo roomInfo;
      try {
        roomInfo = await _roomInfoClient.fetchByWebRid(
          webRid,
          credentialCookies: _credentialCookies,
        );
      } on Object catch (error) {
        _fail('房间信息获取失败：$error');
        return;
      }
      if (_stopped) return;
      _room = roomInfo;

      if (!roomInfo.living) {
        // 未开播不建连，但按固定间隔复检：挂机看多栏时主播开播后必须能自动接上，
        // 不能等用户自己发现再关窗重开（重开会把其它正常栏位的连接一并断掉）。
        _setStage(LiveSessionStage.offline);
        _scheduleOfflineRecheck();
        return;
      }
      await _connectLivingRoom(roomInfo);
    } finally {
      _starting = false;
    }
  }

  /// 已确认开播后的建连流程：签名 → 凭证 → 建立弹幕连接。
  Future<void> _connectLivingRoom(RoomInfo roomInfo) async {
    // 已离开「未开播」：复检预算重置，下次未开播重新拥有完整的复检次数。
    _offlineRecheckCount = 0;
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

  /// 手动重试：丢掉当前连接与订阅，重新走一遍「解析房间 → 签名 → 建连」。
  ///
  /// 与 [stop] 的区别是会话流保持打开：界面不必重建栏位，已收到的弹幕与滚动位置
  /// 都还在。复检正在飞行中时直接返回——两路并发建连会互相覆盖 `_socket`，
  /// 旧连接没人停；此时复检自己会把结果收敛掉。
  Future<void> restart() async {
    if (_stopped || _starting) return;
    _cancelOfflineRecheck();
    await _teardownConnection();
    await start();
  }

  /// 主动关闭：停止重连、取消复检并释放网络资源。
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _cancelOfflineRecheck();
    await _teardownConnection();
    _setStage(LiveSessionStage.idle);
    await _stages.close();
    await _danmu.close();
  }

  /// 断开当前连接并取消订阅，保留会话流（供 [restart] 复用）。
  Future<void> _teardownConnection() async {
    await _socket?.stop();
    _socket = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
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
    // 不变量：[_stages] 必须是「非 sync 的 broadcast」——监听回调要晚于本次状态写入
    // 所在的同步段执行，界面才能在回调里读到已经复位的 autoRechecking。谁把它改成
    // sync: true 或加上 distinct()，「复检预算用尽 → 放出重试入口」立刻退回永久
    // 「复检中…」（UX-08）。
    if (!_stages.isClosed) _stages.add(stage);
  }

  /// 安排下一次未开播复检。
  ///
  /// 次数到顶就不再安排：界面上的手动重试是此时的唯一出口（UX-02）。
  void _scheduleOfflineRecheck() {
    if (_stopped) return;
    if (_offlineRecheckCount >= maxOfflineRechecks) {
      // 预算用尽时补发一次 offline：阶段没变，但 autoRechecking 由 true 变 false，
      // 界面要据此把「复检中…」换成「未开播」并放出重试入口。此时该栏不会有弹幕事件
      // 触发重建，不补发这一条，界面就永远停在「复检中…」（UX-08）。
      //
      // 只在「这一次到顶」补发：真实路径里本方法在到顶后不再被调用，若将来改成每轮
      // 空转都调，这里会变成反复发同一条 offline（单测锁了「恰好一条」）。
      _setStage(LiveSessionStage.offline);
      return;
    }
    _offlineRecheckTimer?.cancel();
    _offlineRecheckTimer = Timer(offlineRecheckInterval, () {
      _offlineRecheckTimer = null;
      unawaited(_recheckOffline());
    });
  }

  void _cancelOfflineRecheck() {
    _offlineRecheckTimer?.cancel();
    _offlineRecheckTimer = null;
  }

  /// 未开播复检：只重新拉一次房间信息，开播了就接着走建连流程。
  ///
  /// 刻意不走 [start]：那会把阶段打回「解析房间」，栏位文案会在「未开播 · 自动复检中」
  /// 与「解析房间…」之间每 30 秒闪一次。复检失败也按「还没开播」处理，不把栏位打成
  /// 错误态——网络抖动不该让一个正常挂机的栏位变红。
  Future<void> _recheckOffline() async {
    if (_stopped || _starting) return;
    _starting = true;
    _rechecking = true;
    _offlineRecheckCount++;
    try {
      final RoomInfo roomInfo;
      try {
        roomInfo = await _roomInfoClient.fetchByWebRid(
          webRid,
          credentialCookies: _credentialCookies,
        );
      } on Object catch (error) {
        // 复检失败不打断会话：网络抖动不该把一个正常挂机的栏位打成错误态，
        // 下一轮继续复检即可，但日志要留下痕迹便于排查。
        debugPrint('未开播复检失败（$webRid）：$error');
        _scheduleOfflineRecheck();
        return;
      }
      if (_stopped) return;
      _room = roomInfo;
      if (!roomInfo.living) {
        _scheduleOfflineRecheck();
        return;
      }
      await _connectLivingRoom(roomInfo);
    } finally {
      _rechecking = false;
      _starting = false;
    }
  }
}