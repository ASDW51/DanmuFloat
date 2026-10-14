// App 内弹幕页失败态的手动重连（需求 P0-1）：失败时出现入口，点击后重建会话。
import 'dart:io';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首次 start 后立即进入失败态的假会话：模拟自动重连耗尽的死局。
class FailingSession extends LiveDanmuSession {
  FailingSession(String webRid)
    : super(webRid: webRid);

  int restarts = 0;

  @override
  LiveSessionStage get stage => LiveSessionStage.error;

  @override
  String? get errorMessage => '重连次数达上限，已停止连接';

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
  }

  @override
  Future<void> stop() async {}
}

/// 正常连接中的假会话：用于验证非失败态不出现重连入口。
class NormalSession extends LiveDanmuSession {
  NormalSession(String webRid) : super(webRid: webRid);

  @override
  LiveSessionStage get stage => LiveSessionStage.live;

  @override
  String? get errorMessage => null;

  @override
  Stream<LiveSessionStage> get stages =>
      Stream<LiveSessionStage>.value(stage);

  @override
  Stream<DanmakuEvent> get danmu => const Stream<DanmakuEvent>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  // 偏好落盘走临时目录，避免依赖 path_provider 插件通道。
  late Directory directory;
  late OverlayPrefsStore prefsStore;
  late FilterStore filterStore;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('danmu_page_test');
    prefsStore = OverlayPrefsStore(
      directoryResolver: () async => directory,
    );
    filterStore = FilterStore(directoryResolver: () async => directory);
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  testWidgets('失败态出现「重新连接」入口，点击后调用会话重启', (WidgetTester tester) async {
    final FailingSession session = FailingSession('12345');
    await tester.pumpWidget(
      MaterialApp(
        home: DanmuPage(
          webRid: '12345',
          createSession: (String webRid, String? credentialCookies) => session,
          prefsStore: prefsStore,
          filterStore: filterStore,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('重新连接'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(session.restarts, 1, reason: '点击重连应触发会话重启');
  });

  testWidgets('非失败态不显示重连入口', (WidgetTester tester) async {
    final NormalSession session = NormalSession('12345');
    await tester.pumpWidget(
      MaterialApp(
        home: DanmuPage(
          webRid: '12345',
          createSession: (String webRid, String? credentialCookies) => session,
          prefsStore: prefsStore,
          filterStore: filterStore,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('重新连接'), findsNothing);
  });
}
