// 无障碍语义（#135）：TalkBack 下一条弹幕必须能被当成一个单位读出来。
//
// 这里分两层：拼装规则（纯函数）与真实渲染（挂弹幕页 + 假会话）。
// 渲染层断言「标签里同时有昵称与正文」「节点数等于弹幕条数」，钉住「合并朗读」
// 而不是每段 TextSpan 各生成一个节点。
import 'dart:async';
import 'dart:io';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:danmu_float/ui/danmaku_semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuEvent _event({
  required String text,
  String nick = '',
  DanmakuKind kind = DanmakuKind.chat,
  int timeMs = 1758900005000,
  int level = 0,
  int fanLevel = 0,
}) => DanmakuEvent(
  kind: kind,
  method: 'WebcastChatMessage',
  msgId: 1,
  roomId: 1,
  timeMs: timeMs,
  text: text,
  user: DanmakuUser(
    userId: 'u1',
    nickName: nick,
    avatarUrl: '',
    level: level,
    fanLevel: fanLevel,
  ),
);

void main() {
  group('danmakuSemanticsLabel（#135）', () {
    test('时间、昵称、正文按「时:分，昵称：正文」拼装', () {
      final String label = danmakuSemanticsLabel(
        _event(text: '这条弹幕长这样', nick: '小明'),
      );
      expect(label, matches(RegExp(r'^\d{2}:\d{2}，小明：这条弹幕长这样$')));
    });

    test('没有昵称时不留空分隔符，正文仍然读得出来', () {
      expect(
        danmakuSemanticsLabel(_event(text: '匿名说一句')),
        matches(RegExp(r'^\d{2}:\d{2}，匿名说一句$')),
      );
    });

    test('类型前缀并入标签：礼物弹幕要读得出是礼物', () {
      final String label = danmakuSemanticsLabel(
        _event(text: '送出火箭', nick: '小红', kind: DanmakuKind.gift),
      );
      expect(label, contains('礼物'));
      expect(label, contains('小红：送出火箭'));
    });

    test('时间戳缺失时不出假时间', () {
      expect(
        danmakuSemanticsLabel(_event(text: '没有时间', nick: '小刚', timeMs: 0)),
        '小刚：没有时间',
      );
    });
  });

  group('paneStageSemanticsLabel（#135）', () {
    test('状态点补「第 N 栏 · 状态」，让颜色编码有等价文本', () {
      expect(
        paneStageSemanticsLabel(index: 0, stage: '已连接'),
        '第 1 栏 · 已连接',
      );
      expect(
        paneStageSemanticsLabel(index: 2, stage: '连接失败'),
        '第 3 栏 · 连接失败',
      );
    });
  });

  group('弹幕页渲染（#135）', () {
    testWidgets('一条弹幕 = 一个语义节点，标签含昵称与正文',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final _FakeSocket socket = await _pumpDanmuPage(tester);
      socket.emitEvents(<DanmakuEvent>[
        _event(text: '第一条正文', nick: '昵称A'),
        _event(text: '第二条正文', nick: '昵称B'),
      ]);
      await tester.pump();

      // 合并标签：昵称与正文在同一个节点里，而不是拆成「昵称」「正文」两个。
      expect(
        find.bySemanticsLabel(RegExp(r'昵称A：第一条正文$')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'昵称B：第二条正文$')),
        findsOneWidget,
      );

      // 节点数 = 弹幕条数：一条弹幕不会因为多段 TextSpan 被读成好几条。
      expect(
        find.bySemanticsLabel(RegExp(r'第[一二]条正文$')),
        findsNWidgets(2),
      );
    });
  });
}

/// 挂载弹幕页：假房间接口 + 假签名器 + 假 socket，不碰真实网络。
Future<_FakeSocket> _pumpDanmuPage(WidgetTester tester) async {
  final Directory dir = Directory.systemTemp.createTempSync('danmu_semantics');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  const MethodChannel channel = MethodChannel('plugins.flutter.io/path_provider');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (MethodCall call) async => dir.path);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

  final _FakeSocket socket = _FakeSocket();
  await tester.pumpWidget(
    MaterialApp(
      home: DanmuPage(
        webRid: '12345',
        sessionFactory: () => LiveDanmuSession(
          webRid: '12345',
          roomInfoClient: _FakeRoomInfoClient(),
          cookieProvider: _FakeCookieProvider(),
          signer: _FakeSigner(),
          socketFactory: ({
            required String liveId,
            required String userUniqueId,
            required String signature,
            required String cookies,
          }) =>
              socket,
        ),
      ),
    ),
  );
  await tester.pump();
  // 页面 initState 会真实读偏好与过滤：FakeAsync 下真实 I/O 不会自己推进。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  return socket;
}

class _FakeRoomInfoClient extends RoomInfoClient {
  @override
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async => RoomInfo(
    living: true,
    isLiveRadio: false,
    webRid: webRid,
    liveId: '7350000000000000001',
    owner: '主播A',
    title: '标题',
    avatar: '',
    cover: '',
    secUid: 'sec',
    api: RoomInfoApi.web,
  );
}

class _FakeCookieProvider extends CookieProvider {
  @override
  Future<String> getCookies() async => 'ttwid=t1';
}

class _FakeSigner implements DanmuSigner {
  @override
  Future<String> sign(Map<String, String> params) async => 'SIGN';

  @override
  FutureOr<void> dispose() {}
}

class _FakeSocket extends DanmuSocketClient {
  _FakeSocket()
    : super(
        liveId: '7350000000000000001',
        userUniqueId: '7650000000000000000',
        signature: 'SIGN',
        cookies: 'ttwid=t1',
      );

  final StreamController<List<DanmakuEvent>> _events =
      StreamController<List<DanmakuEvent>>.broadcast();
  final StreamController<DanmuConnectionState> _states =
      StreamController<DanmuConnectionState>.broadcast();

  void emitEvents(List<DanmakuEvent> events) => _events.add(events);

  @override
  Stream<List<DanmakuEvent>> get events => _events.stream;

  @override
  Stream<DanmuConnectionState> get states => _states.stream;

  @override
  void start() {}

  @override
  Future<void> stop() async {}
}
