import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRoomInfoClient extends RoomInfoClient {
  FakeRoomInfoClient(this.result);

  final RoomInfo result;
  Object? error;

  /// 非空时请求挂起，直到测试放行：用于观察「请求已发出、还没回来」的中间态。
  Completer<RoomInfo>? gate;
  final List<String> calls = <String>[];
  final List<String?> credentialCalls = <String?>[];

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    calls.add(webRid);
    credentialCalls.add(credentialCookies);
    if (gate != null) return gate!.future;
    if (error != null) throw error!;
    return result;
  }
}

/// 按调用次序依次返回不同房间信息，用于验证未开播复检（UX-01）：
/// 第一次返回未开播、第二次返回已开播，模拟主播中途开播。
class SequenceRoomInfoClient extends RoomInfoClient {
  SequenceRoomInfoClient(this.results);

  final List<RoomInfo> results;
  final List<String> calls = <String>[];

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    calls.add(webRid);
    final int index = calls.length - 1;
    return results[index < results.length ? index : results.length - 1];
  }
}

class FakeCookieProvider extends CookieProvider {
  FakeCookieProvider({this.error});

  Object? error;
  int calls = 0;

  @override
  Future<String> getCookies() async {
    calls++;
    if (error != null) throw error!;
    return 'ttwid=t1';
  }
}

class FakeSigner implements DanmuSigner {
  FakeSigner({this.signature = 'SIGN', this.error});

  final String signature;
  Object? error;
  Map<String, String>? lastParams;

  @override
  Future<String> sign(Map<String, String> params) async {
    lastParams = params;
    if (error != null) throw error!;
    return signature;
  }
}

class FakeSocket extends DanmuSocketClient {
  FakeSocket({
    required super.liveId,
    required super.userUniqueId,
    required super.signature,
    required super.cookies,
  });

  final StreamController<List<DanmakuEvent>> _events =
      StreamController<List<DanmakuEvent>>.broadcast();
  final StreamController<DanmuConnectionState> _states =
      StreamController<DanmuConnectionState>.broadcast();

  DanmuConnectionState _state = DanmuConnectionState.idle;
  bool started = false;
  bool stopped = false;

  @override
  Stream<List<DanmakuEvent>> get events => _events.stream;

  @override
  Stream<DanmuConnectionState> get states => _states.stream;

  @override
  DanmuConnectionState get state => _state;

  @override
  void start() => started = true;

  @override
  Future<void> stop() async {
    stopped = true;
  }

  void emitState(DanmuConnectionState state) {
    _state = state;
    _states.add(state);
  }

  void emitEvents(List<DanmakuEvent> events) => _events.add(events);
}

const String _liveId = '7350000000000000001';

RoomInfo _livingRoom() => const RoomInfo(
      living: true,
      isLiveRadio: false,
      webRid: '12345',
      liveId: _liveId,
      owner: '主播A',
      title: '标题',
      avatar: '',
      cover: '',
      secUid: 'sec',
      api: RoomInfoApi.web,
    );

DanmakuEvent _event(String text) => DanmakuEvent(
      kind: DanmakuKind.chat,
      method: 'WebcastChatMessage',
      msgId: 1,
      roomId: 1,
      timeMs: 1758900005000,
      text: text,
      user: DanmakuUser.empty,
    );

Future<void> _tick() => Future<void>.delayed(Duration.zero);

/// 轮询等待条件成立，超时即返回由调用方断言失败。
///
/// 复检由真实定时器驱动（测试注入毫秒级间隔），固定 sleep 会 flaky：等不到就让
/// 断言报错，而不是让测试偶发变红。
Future<void> _waitFor(bool Function() condition, {int timeoutMs = 2000}) async {
  final DateTime deadline =
      DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('LiveDanmuSession', () {
    late FakeRoomInfoClient roomClient;
    late FakeCookieProvider cookieProvider;
    late FakeSigner signer;
    late List<Map<String, String>> socketArgs;
    late FakeSocket socket;

    LiveDanmuSession build({
      String webRid = '12345',
      String? credentialCookies,
      RoomInfoClient? client,
      Duration offlineRecheckInterval = defaultOfflineRecheckInterval,
      int maxOfflineRechecks = defaultMaxOfflineRechecks,
    }) =>
        LiveDanmuSession(
          webRid: webRid,
          roomInfoClient: client ?? roomClient,
          cookieProvider: cookieProvider,
          credentialCookies: credentialCookies,
          signer: signer,
          offlineRecheckInterval: offlineRecheckInterval,
          maxOfflineRechecks: maxOfflineRechecks,
          socketFactory: ({
            required String liveId,
            required String userUniqueId,
            required String signature,
            required String cookies,
          }) {
            socketArgs.add(<String, String>{
              'liveId': liveId,
              'userUniqueId': userUniqueId,
              'signature': signature,
              'cookies': cookies,
            });
            socket = FakeSocket(
              liveId: liveId,
              userUniqueId: userUniqueId,
              signature: signature,
              cookies: cookies,
            );
            return socket;
          },
          userUniqueIdFactory: () => '7650000000000000000',
        );

    setUp(() {
      roomClient = FakeRoomInfoClient(_livingRoom());
      cookieProvider = FakeCookieProvider();
      signer = FakeSigner();
      socketArgs = <Map<String, String>>[];
    });

    test('未开播时不建立弹幕连接', () async {
      roomClient = FakeRoomInfoClient(
        const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web),
      );
      final LiveDanmuSession session = build();
      await session.start();

      expect(session.stage, LiveSessionStage.offline);
      expect(socketArgs, isEmpty, reason: '未开播不得发起弹幕连接');
      expect(cookieProvider.calls, 0, reason: '未开播不必取凭证');
      await session.stop();
    });

    test('未开播时按间隔自动复检，开播后自动接上弹幕连接（UX-01）', () async {
      final SequenceRoomInfoClient client = SequenceRoomInfoClient(<RoomInfo>[
        const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web),
        _livingRoom(),
      ]);
      final LiveDanmuSession session = build(
        client: client,
        offlineRecheckInterval: const Duration(milliseconds: 5),
      );
      final List<LiveSessionStage> stages = <LiveSessionStage>[];
      session.stages.listen(stages.add);

      await session.start();
      expect(session.stage, LiveSessionStage.offline);
      expect(
        session.autoRechecking,
        isTrue,
        reason: '未开播要排定复检，栏位才显示得出「自动复检中」',
      );
      expect(socketArgs, isEmpty, reason: '未开播不得发起弹幕连接');

      await _waitFor(() => socketArgs.isNotEmpty);
      expect(client.calls, hasLength(2), reason: '复检到开播即停止轮询');
      expect(session.autoRechecking, isFalse, reason: '已开播，不该再有复检定时器');

      socket.emitState(DanmuConnectionState.connected);
      await _tick();
      expect(session.stage, LiveSessionStage.live);
      expect(
        stages.where(
          (LiveSessionStage stage) => stage == LiveSessionStage.resolvingRoom,
        ),
        hasLength(1),
        reason: '复检不得重走 start()，否则文案会在「解析房间」与「未开播」之间反复闪',
      );
      await session.stop();
    });

    test('未开播复检次数达上限后停止轮询，栏位停在未开播（UX-01）', () async {
      final SequenceRoomInfoClient client = SequenceRoomInfoClient(<RoomInfo>[
        const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web),
      ]);
      final LiveDanmuSession session = build(
        client: client,
        offlineRecheckInterval: const Duration(milliseconds: 5),
        maxOfflineRechecks: 3,
      );

      await session.start();
      // 首次解析 1 次 + 复检 3 次。
      await _waitFor(() => client.calls.length >= 4);
      expect(client.calls, hasLength(4));
      expect(session.stage, LiveSessionStage.offline);
      expect(
        session.autoRechecking,
        isFalse,
        reason: '到顶后不该继续显示「自动复检中」，那是假承诺',
      );

      // 再等若干个间隔，确认是真的停了（而不是还没触发）。
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.calls, hasLength(4), reason: '达上限后必须停止轮询，避免无限请求');
      await session.stop();
    });

    test('stop() 取消复检定时器，会话结束后不再请求房间信息（UX-01）', () async {
      final SequenceRoomInfoClient client = SequenceRoomInfoClient(<RoomInfo>[
        const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web),
      ]);
      final LiveDanmuSession session = build(
        client: client,
        offlineRecheckInterval: const Duration(milliseconds: 5),
      );

      await session.start();
      await _waitFor(() => client.calls.length >= 2);
      await session.stop();
      final int settled = client.calls.length;

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        client.calls,
        hasLength(settled),
        reason: 'stop() 必须取消复检定时器，不能在会话结束后继续发请求',
      );
    });

    test('start() 重入不会重复建连（UX-01）', () async {
      final LiveDanmuSession session = build();

      final Future<void> first = session.start();
      final Future<void> second = session.start();
      await Future.wait(<Future<void>>[first, second]);

      expect(roomClient.calls, hasLength(1), reason: '重入的 start() 必须直接返回');
      expect(
        socketArgs,
        hasLength(1),
        reason: '重复建连会覆盖旧 socket 与订阅，造成连接泄漏',
      );
      await session.stop();
    });

    test('开播时按 liveId 建连，签名参数与凭证正确', () async {
      final LiveDanmuSession session = build();
      await session.start();

      expect(session.stage, LiveSessionStage.connecting);
      expect(session.room, isNotNull);
      expect(roomClient.calls, <String>['12345']);
      expect(socketArgs.single['liveId'], _liveId);
      expect(socketArgs.single['userUniqueId'], '7650000000000000000');
      expect(socketArgs.single['cookies'], 'ttwid=t1');
      expect(socketArgs.single['signature'], 'SIGN');
      expect(signer.lastParams!['room_id'], _liveId);
      expect(signer.lastParams!['user_unique_id'], '7650000000000000000');
      expect(socket.started, isTrue);

      await session.stop();
      expect(socket.stopped, isTrue);
    });

    test('指定凭证时透传给房间信息客户端', () async {
      final LiveDanmuSession session =
          build(credentialCookies: 'ttwid=abc; msToken=xyz');
      await session.start();

      expect(roomClient.credentialCalls.single, 'ttwid=abc; msToken=xyz');
      await session.stop();
    });

    test('凭证为空白时按未指定处理，透传 null', () async {
      final LiveDanmuSession session = build(credentialCookies: '   ');
      await session.start();

      expect(roomClient.credentialCalls.single, isNull);
      await session.stop();
    });

    test('未指定凭证时透传 null', () async {
      final LiveDanmuSession session = build();
      await session.start();

      expect(roomClient.credentialCalls.single, isNull);
      await session.stop();
    });

    test('弹幕进入缓冲并推送到 danmu 流，连接成功后进入 live', () async {
      final LiveDanmuSession session = build();
      final List<DanmakuEvent> received = <DanmakuEvent>[];
      session.danmu.listen(received.add);
      await session.start();

      socket.emitEvents(<DanmakuEvent>[_event('你好')]);
      await _tick();
      expect(session.buffer.length, 1);
      expect(session.buffer.single.text, '你好');
      expect(received.single.text, '你好');

      socket.emitState(DanmuConnectionState.connected);
      await _tick();
      expect(session.stage, LiveSessionStage.live);

      socket.emitState(DanmuConnectionState.reconnecting);
      await _tick();
      expect(session.stage, LiveSessionStage.connecting);

      socket.emitState(DanmuConnectionState.failed);
      await _tick();
      expect(session.stage, LiveSessionStage.error);

      await session.stop();
    });

    test('签名失败降级为固定值，仍继续建连', () async {
      signer.error = DanmuSignatureException('boom');
      final LiveDanmuSession session = build();
      await session.start();

      expect(socketArgs.single['signature'], fallbackDanmuSignature);
      expect(session.stage, LiveSessionStage.connecting);
      expect(session.signatureDegraded, isTrue);
      expect(session.signatureWarning, contains('boom'));
      await session.stop();
    });

    test('房间信息获取失败时报错且不建连', () async {
      roomClient.error = RoomInfoException('接口返回异常 status_code=1');
      final LiveDanmuSession session = build();
      await session.start();

      expect(session.stage, LiveSessionStage.error);
      expect(session.errorMessage, contains('房间信息获取失败'));
      expect(socketArgs, isEmpty);
      await session.stop();
    });

    test('凭证获取失败时报错且不建连', () async {
      cookieProvider.error = CookieFetchException('no set-cookie');
      final LiveDanmuSession session = build();
      await session.start();

      expect(session.stage, LiveSessionStage.error);
      expect(session.errorMessage, contains('凭证获取失败'));
      expect(socketArgs, isEmpty);
      await session.stop();
    });

    test('阶段流按顺序上报', () async {
      final LiveDanmuSession session = build();
      final List<LiveSessionStage> stages = <LiveSessionStage>[];
      session.stages.listen(stages.add);
      await session.start();
      await _tick();

      expect(
        stages,
        <LiveSessionStage>[
          LiveSessionStage.resolvingRoom,
          LiveSessionStage.signing,
          LiveSessionStage.connecting,
        ],
      );
      await session.stop();
    });

    test('重试：失败后重新走一遍流程，会话流保持打开（UX-02）', () async {
      roomClient.error = RoomInfoException('接口返回异常 status_code=1');
      final LiveDanmuSession session = build();
      final List<LiveSessionStage> stages = <LiveSessionStage>[];
      session.stages.listen(stages.add);
      await session.start();
      expect(session.stage, LiveSessionStage.error);

      // 网络恢复后点「重试」：同一个会话重新拉房间信息并建连。
      roomClient.error = null;
      await session.restart();

      expect(roomClient.calls, hasLength(2), reason: '重试要重新拉一次房间信息');
      expect(socketArgs, hasLength(1), reason: '重试后应重新建立弹幕连接');
      expect(session.stage, LiveSessionStage.connecting);
      expect(
        stages.last,
        LiveSessionStage.connecting,
        reason: '阶段流保持打开，界面不必重建栏位',
      );
      await session.stop();
    });

    test('重试：先停掉旧连接，且不重复订阅弹幕（UX-02）', () async {
      final LiveDanmuSession session = build();
      await session.start();
      final FakeSocket first = socket;
      expect(first.started, isTrue);

      await session.restart();

      expect(first.stopped, isTrue, reason: '旧连接必须先停掉，否则泄漏一个 socket');
      expect(identical(socket, first), isFalse, reason: '重试要新建连接');
      expect(socketArgs, hasLength(2));

      // 旧订阅必须取消：否则同一条弹幕会被新旧两个 socket 各推一次。
      socket.emitEvents(<DanmakuEvent>[_event('你好')]);
      await _tick();
      expect(session.buffer, hasLength(1));
      await session.stop();
    });

    test('重试：会话已停止时不再发起连接（UX-02）', () async {
      final LiveDanmuSession session = build();
      await session.start();
      await session.stop();
      final int callsBefore = roomClient.calls.length;

      await session.restart();

      expect(
        roomClient.calls,
        hasLength(callsBefore),
        reason: '已释放的会话不该被重试唤醒',
      );
      expect(session.stage, LiveSessionStage.idle);
    });

    test('复检请求飞行中仍算自动复检中，避免过早给出重试入口（UX-02）', () async {
      roomClient = FakeRoomInfoClient(
        const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web),
      );
      final LiveDanmuSession session = build(
        offlineRecheckInterval: const Duration(milliseconds: 5),
      );
      await session.start();
      expect(session.stage, LiveSessionStage.offline);
      expect(session.autoRechecking, isTrue, reason: '已排定下一次复检');

      // 复检请求已发出但还没回来：此时定时器已置空，仍要算「自动复检中」。
      roomClient.gate = Completer<RoomInfo>();
      await _waitFor(() => roomClient.calls.length >= 2);
      expect(
        session.autoRechecking,
        isTrue,
        reason: '请求飞行中不能算「已停止复检」，否则界面会骗用户去点重试',
      );

      roomClient.gate!.complete(
        const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web),
      );
      await _tick();
      await session.stop();
    });
  });

  group('shouldOfferRetry', () {
    test('异常态一律给重试入口', () {
      expect(
        shouldOfferRetry(LiveSessionStage.error, autoRechecking: false),
        isTrue,
      );
      expect(
        shouldOfferRetry(LiveSessionStage.error, autoRechecking: true),
        isTrue,
        reason: '连接失败后复检也救不回来，入口不能因为「还在复检」而消失',
      );
    });

    test('未开播只在停止自动复检后才给重试入口', () {
      expect(
        shouldOfferRetry(LiveSessionStage.offline, autoRechecking: true),
        isFalse,
        reason: '还在自动复检时给「重试」，会让用户以为这一栏已经死掉',
      );
      expect(
        shouldOfferRetry(LiveSessionStage.offline, autoRechecking: false),
        isTrue,
      );
    });

    test('正常流程中的阶段不给重试入口', () {
      for (final LiveSessionStage stage in <LiveSessionStage>[
        LiveSessionStage.idle,
        LiveSessionStage.resolvingRoom,
        LiveSessionStage.signing,
        LiveSessionStage.connecting,
        LiveSessionStage.live,
      ]) {
        expect(
          shouldOfferRetry(stage, autoRechecking: false),
          isFalse,
          reason: '$stage 阶段不该出现重试入口',
        );
      }
    });
  });
}