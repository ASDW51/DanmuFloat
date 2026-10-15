// LiveDanmuSession 失败 / 未开播后的重试能力（R1）。
//
// 独立成文件与既有 live_danmu_session_test.dart 并列：本文件只覆盖重试语义
// （canRetry 判定、旧连接释放、防重入），基础链路语义留在原文件。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRoomInfoClient extends RoomInfoClient {
  FakeRoomInfoClient(this.result);

  RoomInfo result;
  Object? error;
  int calls = 0;

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    calls++;
    if (error != null) throw error!;
    return result;
  }
}

class FakeCookieProvider extends CookieProvider {
  @override
  Future<String> getCookies() async => 'ttwid=t1';
}

class FakeSigner implements DanmuSigner {
  FakeSigner({this.gate});

  /// 非 null 时挂起签名阶段直到 complete：验证 start 重入保护用。
  Completer<void>? gate;

  @override
  Future<String> sign(Map<String, String> params) async {
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    return 'SIGN';
  }
}

class FakeSocket extends DanmuSocketClient {
  FakeSocket({
    required super.liveId,
    required super.userUniqueId,
    required super.signature,
    required super.cookies,
  });

  final StreamController<DanmuConnectionState> _states =
      StreamController<DanmuConnectionState>.broadcast();

  DanmuConnectionState _state = DanmuConnectionState.idle;
  bool started = false;
  bool stopped = false;

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
}

RoomInfo _livingRoom() => const RoomInfo(
      living: true,
      isLiveRadio: false,
      webRid: '12345',
      liveId: '7350000000000000001',
      owner: '主播A',
      title: '标题',
      avatar: '',
      cover: '',
      secUid: 'sec',
      api: RoomInfoApi.web,
    );

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeRoomInfoClient roomClient;
  late FakeSigner signer;
  final List<FakeSocket> sockets = <FakeSocket>[];

  LiveDanmuSession build() => LiveDanmuSession(
        webRid: '12345',
        roomInfoClient: roomClient,
        cookieProvider: FakeCookieProvider(),
        signer: signer,
        socketFactory: ({
          required String liveId,
          required String userUniqueId,
          required String signature,
          required String cookies,
        }) {
          final FakeSocket socket = FakeSocket(
            liveId: liveId,
            userUniqueId: userUniqueId,
            signature: signature,
            cookies: cookies,
          );
          sockets.add(socket);
          return socket;
        },
        userUniqueIdFactory: () => '7650000000000000000',
      );

  setUp(() {
    roomClient = FakeRoomInfoClient(_livingRoom());
    signer = FakeSigner();
    sockets.clear();
  });

  test('初始阶段与连接中不可重试，失败后可以', () async {
    final LiveDanmuSession session = build();
    expect(session.canRetry, isFalse, reason: 'idle 不应显示重试');

    await session.start();
    expect(session.canRetry, isFalse, reason: '连接中不显示重试');

    sockets.single.emitState(DanmuConnectionState.failed);
    await _tick();
    expect(session.stage, LiveSessionStage.error);
    expect(session.canRetry, isTrue);
    await session.stop();
  });

  test('房间信息获取失败后重试成功', () async {
    roomClient.error = const RoomInfoException('网络异常');
    final LiveDanmuSession session = build();
    await session.start();
    expect(session.stage, LiveSessionStage.error);
    expect(session.canRetry, isTrue);
    expect(sockets, isEmpty);

    // 网络恢复：重试后正常建连。
    roomClient = FakeRoomInfoClient(_livingRoom());
    await session.start();

    expect(session.stage, LiveSessionStage.connecting);
    expect(session.errorMessage, isNull);
    expect(sockets.single.started, isTrue);
    await session.stop();
  });

  test('未开播后重试：第二次解析到开播即正常建连', () async {
    roomClient = FakeRoomInfoClient(
      const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web),
    );
    final LiveDanmuSession session = build();
    await session.start();
    expect(session.stage, LiveSessionStage.offline);
    expect(session.canRetry, isTrue);
    expect(sockets, isEmpty, reason: '未开播不应建连');

    // 主播开播了：换回正常房间数据再重试。
    roomClient = FakeRoomInfoClient(_livingRoom());
    await session.start();

    expect(session.stage, LiveSessionStage.connecting);
    expect(sockets.length, 1);
    expect(sockets.single.started, isTrue);
    await session.stop();
  });

  test('重连耗尽失败后重试换新 socket，旧 socket 被 stop', () async {
    final LiveDanmuSession session = build();
    await session.start();
    final FakeSocket first = sockets.single;
    first.emitState(DanmuConnectionState.failed);
    await _tick();
    expect(session.stage, LiveSessionStage.error);

    await session.start();

    expect(sockets.length, 2, reason: '重试应建立新连接');
    expect(first.stopped, isTrue, reason: '旧连接必须被释放，不能残留重连循环');
    expect(sockets.last.started, isTrue);
    expect(session.stage, LiveSessionStage.connecting);
    await session.stop();
    expect(sockets.last.stopped, isTrue);
  });

  test('start 进行中重复调用被忽略（防重入）', () async {
    // 阻塞签名阶段，让 start 停在半路。
    final Completer<void> gate = Completer<void>();
    signer = FakeSigner(gate: gate);
    final LiveDanmuSession session = build();
    final Future<void> first = session.start();
    await _tick();
    expect(session.stage, LiveSessionStage.signing);

    // 未完成时再调用一次：应直接返回，不产生第二条链路。
    await session.start();
    gate.complete();
    await first;

    expect(sockets.length, 1, reason: '重入的 start 不应新建 socket');
    await session.stop();
  });
}
