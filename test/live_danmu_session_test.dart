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
  final List<String> calls = <String>[];
  final List<String?> credentialCalls = <String?>[];

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    calls.add(webRid);
    credentialCalls.add(credentialCookies);
    if (error != null) throw error!;
    return result;
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

void main() {
  group('LiveDanmuSession', () {
    late FakeRoomInfoClient roomClient;
    late FakeCookieProvider cookieProvider;
    late FakeSigner signer;
    late List<Map<String, String>> socketArgs;
    late FakeSocket socket;

    LiveDanmuSession build({String webRid = '12345', String? credentialCookies}) =>
        LiveDanmuSession(
          webRid: webRid,
          roomInfoClient: roomClient,
          cookieProvider: cookieProvider,
          credentialCookies: credentialCookies,
          signer: signer,
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
  });
}