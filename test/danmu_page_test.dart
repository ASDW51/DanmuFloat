// App 内弹幕页：失败 / 未开播后的「重试」入口（R1）与连接状态中文化（R3）。
//
// 通过 [DanmuPage.sessionFactory]（@visibleForTesting）注入假会话依赖，
// 房间信息客户端与 socket 全部离线可控，Widget 测试不触网。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRoomInfoClient extends RoomInfoClient {
  FakeRoomInfoClient(this.result);

  RoomInfo result;
  int calls = 0;

  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    calls++;
    return result;
  }
}

class FakeCookieProvider extends CookieProvider {
  @override
  Future<String> getCookies() async => 'ttwid=t1';
}

class FakeSigner implements DanmuSigner {
  @override
  Future<String> sign(Map<String, String> params) async => 'SIGN';
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

  @override
  Stream<DanmuConnectionState> get states => _states.stream;

  @override
  DanmuConnectionState get state => _state;

  @override
  void start() {}

  @override
  Future<void> stop() async {}

  void emitState(DanmuConnectionState state) {
    _state = state;
    _states.add(state);
  }
}

RoomInfo _offlineRoom() =>
    const RoomInfo.offline(webRid: '12345', api: RoomInfoApi.web);

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
  late FakeCookieProvider cookieProvider;
  late FakeSigner signer;
  final List<FakeSocket> sockets = <FakeSocket>[];

  Widget wrap() => MaterialApp(
        home: DanmuPage(
          webRid: '12345',
          title: '主播A',
          sessionFactory: (String webRid) => LiveDanmuSession(
            webRid: webRid,
            roomInfoClient: roomClient,
            cookieProvider: cookieProvider,
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
          ),
        ),
      );

  setUp(() {
    roomClient = FakeRoomInfoClient(_livingRoom());
    cookieProvider = FakeCookieProvider();
    signer = FakeSigner();
    sockets.clear();
  });

  testWidgets('未开播时显示重试按钮，点击后按新数据重新连接（R1）', (WidgetTester tester) async {
    roomClient = FakeRoomInfoClient(_offlineRoom());
    await tester.pumpWidget(wrap());
    await tester.pump();
    await _tick();
    await tester.pump();

    expect(find.text('主播未开播'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget, reason: '未开播应提供重试入口');

    // 主播开播了：换成有直播间的数据再点重试。
    roomClient.result = _livingRoom();
    await tester.tap(find.text('重试'));
    await tester.pump();
    await _tick();
    await tester.pump();

    expect(roomClient.calls, 2, reason: '重试应重新拉一次房间信息');
    expect(find.text('连接中…'), findsOneWidget);
  });

  testWidgets('重连耗尽（failed）时同样给出重试入口（R1）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await _tick();
    await tester.pump();

    sockets.single.emitState(DanmuConnectionState.failed);
    await tester.pump();
    await _tick();
    await tester.pump();

    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('正常连接中不显示重试按钮（R1）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await _tick();
    await tester.pump();

    sockets.single.emitState(DanmuConnectionState.connected);
    await tester.pump();
    await _tick();
    await tester.pump();

    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('连接状态展示中文短名而不是英文枚举（R3）', (WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();
    await _tick();
    await tester.pump();

    sockets.single.emitState(DanmuConnectionState.reconnecting);
    await tester.pump();
    await _tick();
    await tester.pump();

    expect(find.text('连接: 重连中'), findsOneWidget);
    expect(find.textContaining('reconnecting'), findsNothing);
  });
}
