// 弹幕页就地显示调节面板（#145）的验收用例。
//
// 三个必须钉死的点：
// 1. 拖动只预览、松手才落盘（与设置页同一口径）；
// 2. 写回只带用户动过的字段——#97 的教训是「整份写回会把别处刚改的值覆盖回去」；
// 3. 上下限与设置页同源，不允许两处各写一套数字。
import 'dart:async';
import 'dart:io';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/danmu_display_sheet.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 面板回报的一次写回。
typedef _Call = ({OverlayPrefsPatch patch, bool persist});

/// 独立挂载面板：不需要弹幕会话，也不需要 socket。
Future<List<_Call>> _pumpSheet(
  WidgetTester tester, {
  required OverlayPrefs initial,
}) async {
  final List<_Call> calls = <_Call>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DanmuDisplaySheet(
          initial: initial,
          onChanged: (OverlayPrefsPatch patch, {required bool persist}) =>
              calls.add((patch: patch, persist: persist)),
        ),
      ),
    ),
  );
  await tester.pump();
  return calls;
}

void main() {
  group('弹幕页显示设置面板（#145）', () {
    testWidgets('拖动字号滑杆：过程中只预览，松手才落盘', (WidgetTester tester) async {
      final List<_Call> calls = await _pumpSheet(
        tester,
        initial: const OverlayPrefs(),
      );

      await tester.drag(
        find.byKey(const ValueKey<String>('danmuDisplayFontSize')),
        const Offset(60, 0),
      );
      await tester.pump();

      expect(calls, isNotEmpty, reason: '拖滑杆必须回报改动');
      expect(
        calls.any((_Call c) => !c.persist),
        isTrue,
        reason: '拖动过程中要实时预览（persist: false）',
      );
      expect(calls.last.persist, isTrue, reason: '松手才落盘（persist: true）');
    });

    testWidgets('只拖字号时，写回里不含透明度与滚动速度（#97 回归）',
        (WidgetTester tester) async {
      // 别处（设置页 / 悬浮窗）刚把透明度改成 0.15，而面板拿到的是更早的旧快照。
      const OverlayPrefs elsewhere = OverlayPrefs(opacity: 0.15);
      const OverlayPrefs staleSnapshot = OverlayPrefs(opacity: 0.9);

      final List<_Call> calls = await _pumpSheet(
        tester,
        initial: staleSnapshot,
      );
      await tester.drag(
        find.byKey(const ValueKey<String>('danmuDisplayFontSize')),
        const Offset(60, 0),
      );
      await tester.pump();

      for (final _Call call in calls) {
        expect(
          call.patch.opacity,
          isNull,
          reason: '没碰透明度，就不能把透明度写回（否则会覆盖别处的新值）',
        );
        expect(call.patch.scrollSpeed, isNull, reason: '没碰滚动速度');
        expect(call.patch.fontSize, isNotNull, reason: '动过的字号要在里面');
      }

      // 上层按 patch 增量合并到「当前偏好」，而不是旧快照：透明度保持别处的新值。
      OverlayPrefs current = elsewhere;
      for (final _Call call in calls) {
        current = current.appliedPatch(call.patch);
      }
      expect(current.opacity, 0.15, reason: '别处刚改的透明度不能被旧快照覆盖');
      expect(current.fontSize, isNot(defaultDanmuFontSize), reason: '字号应被改动');
    });

    testWidgets('三项滑杆的上下限与设置页同源', (WidgetTester tester) async {
      await _pumpSheet(tester, initial: const OverlayPrefs());

      Slider sliderOf(String key) => tester.widget<Slider>(
            find.byKey(ValueKey<String>(key)),
          );

      final Slider opacity = sliderOf('danmuDisplayOpacity');
      expect(opacity.min, minOverlayOpacity);
      expect(opacity.max, maxOverlayOpacity);

      final Slider fontSize = sliderOf('danmuDisplayFontSize');
      expect(fontSize.min, minDanmuFontSize);
      expect(fontSize.max, maxDanmuFontSize);

      final Slider scrollSpeed = sliderOf('danmuDisplayScrollSpeed');
      expect(scrollSpeed.min, minDanmuScrollSpeed);
      expect(scrollSpeed.max, maxDanmuScrollSpeed);
    });

    testWidgets('拖动滚动速度只回报 scrollSpeed，透明度与字号不受影响',
        (WidgetTester tester) async {
      final List<_Call> calls = await _pumpSheet(
        tester,
        initial: const OverlayPrefs(),
      );
      await tester.drag(
        find.byKey(const ValueKey<String>('danmuDisplayScrollSpeed')),
        const Offset(60, 0),
      );
      await tester.pump();

      expect(calls, isNotEmpty);
      for (final _Call call in calls) {
        expect(call.patch.scrollSpeed, isNotNull);
        expect(call.patch.opacity, isNull);
        expect(call.patch.fontSize, isNull);
      }
    });

    testWidgets('360dp 窄屏下弹幕页 AppBar 不溢出（新增图标未挤爆）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final Directory dir =
          Directory.systemTemp.createTempSync('danmu_display_page');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      const MethodChannel channel =
          MethodChannel('plugins.flutter.io/path_provider');
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => dir.path,
      );
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
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '360dp 下 AppBar 不能溢出');
      expect(find.byTooltip('显示设置'), findsOneWidget);
      // 既有四个入口一个都不能少（AGENTS 第 5 节）。
      expect(find.byTooltip('复制诊断信息'), findsOneWidget);
      expect(find.byTooltip('清空'), findsOneWidget);
      expect(find.byTooltip('暂停'), findsOneWidget);
    });
  });
  group('偏好增量的 scrollSpeed（#145）', () {
    test('往返一致、缺字段为 null、越界被收敛、能增量合并', () {
      const OverlayPrefsPatch patch = OverlayPrefsPatch(scrollSpeed: 1.5);
      expect(OverlayPrefsPatch.tryParse(patch.toJson())?.scrollSpeed, 1.5);
      expect(
        OverlayPrefsPatch.tryParse(<String, Object?>{'fontSize': 14})?.scrollSpeed,
        isNull,
        reason: '没这个键就是「这次不改」',
      );
      expect(
        OverlayPrefsPatch.tryParse(
          <String, Object?>{'scrollSpeed': 99},
        )?.scrollSpeed,
        maxDanmuScrollSpeed,
        reason: '越界值按公共常量收敛，与设置页同口径',
      );
      expect(const OverlayPrefs().appliedPatch(patch).scrollSpeed, 1.5);
    });
  });

}

class _FakeRoomInfoClient extends RoomInfoClient {
  @override
  Future<RoomInfo> fetchByWebRid(String webRid, {String? credentialCookies}) async =>
      RoomInfo(
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

  @override
  Stream<List<DanmakuEvent>> get events => _events.stream;

  @override
  Stream<DanmuConnectionState> get states => _states.stream;

  @override
  void start() {}

  @override
  Future<void> stop() async {}
}
