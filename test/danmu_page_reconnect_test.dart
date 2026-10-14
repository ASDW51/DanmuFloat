// App 内弹幕页失败态的手动重连（需求 P0-1）：失败时出现入口，点击后重建会话。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSocket extends DanmuSocketClient {
  FakeSocket({
    required super.liveId,
    required super.userUniqueId,
    required super.signature,
    required super.cookies,
  });

  final StreamController<DanmuConnectionState> _states =
      StreamController<DanmuConnectionState>.broadcast();

  @override
  Stream<DanmuConnectionState> get states => _states.stream;

  @override
  DanmuConnectionState get state => DanmuConnectionState.idle;

  @override
  void start() {}

  @override
  Future<void> stop() async {}

  void emitState(DanmuConnectionState state) => _states.add(state);
}

/// 首次 start 后立即进入失败态的假会话：模拟自动重连耗尽的死局。
class FailingSession extends LiveDanmuSession {
  FailingSession(super.webRid) : super();

  final FakeSocket socket = FakeSocket(
    liveId: '1',
    userUniqueId: '1',
    signature: 's',
    cookies: 'c',
  );

  int restarts = 0;

  @override
  LiveSessionStage get stage =>
      restarts == 0 ? LiveSessionStage.error : LiveSessionStage.connecting;

  @override
  String? get errorMessage =>
      restarts == 0 ? '重连次数达上限，已停止连接' : null;

  @override
  Stream<LiveSessionStage> get stages =>
      Stream<LiveSessionStage>.value(stage);

  @override
  Stream<DanmakuEvent> get danmu => const Stream<DanmakuEvent>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> restart() async {
    restarts++;
    // 重连后模拟重新进入连接中。
    socket.emitState(DanmuConnectionState.connecting);
  }

  @override
  Future<void> stop() async {}
}

void main() {
  testWidgets('失败态出现「重新连接」入口，点击后调用会话重启', (WidgetTester tester) async {
    final FailingSession session = FailingSession('12345');
    await tester.pumpWidget(
      MaterialApp(
        home: DanmuPage(
          webRid: '12345',
          createSession: (String webRid, String? credentialCookies) => session,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('重新连接'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(session.restarts, 1, reason: '点击重连应触发会话重启');
  });

  testWidgets('非失败态不显示重连入口', (WidgetTester tester) async {
    final FailingSession session = FailingSession('12345')..restarts = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: DanmuPage(
          webRid: '12345',
          createSession: (String webRid, String? credentialCookies) => session,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('重新连接'), findsNothing);
  });
}
