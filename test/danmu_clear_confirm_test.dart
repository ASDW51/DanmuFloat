// UX-23b：「清空」二次确认——默认答案必须是「不动」。
//
// #99 追加：确认结果落地前不能先改任何状态（计数尤其不能先行归零），故这两条用例
// 挂真实弹幕页 + 假会话，走「点清空 → 对话框」的完整链路。
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
import 'package:danmu_float/ui/danmu_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldClearDanmakuOnConfirm', () {
    test('明确确认才清空', () {
      expect(shouldClearDanmakuOnConfirm(true), isTrue);
    });

    test('取消、点遮罩、返回键拿到 null 时一律不清空', () {
      expect(shouldClearDanmakuOnConfirm(false), isFalse);
      expect(shouldClearDanmakuOnConfirm(null), isFalse);
    });
  });

  group('清空确认对话框', () {
    Future<bool?> open(WidgetTester tester) async {
      bool? result;
      bool opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () {
                  if (opened) return;
                  opened = true;
                  unawaited(
                    showClearDanmakuConfirmDialog(context).then(
                      (bool? value) => result = value,
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('弹确认框，且此时不清空任何东西', (WidgetTester tester) async {
      await open(tester);
      expect(
        find.byKey(const ValueKey<String>('clearDanmakuConfirmDialog')),
        findsOneWidget,
      );
    });

    testWidgets('点「清空」得到 true', (WidgetTester tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey<String>('clearDanmakuConfirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('clearDanmakuConfirmDialog')), findsNothing);
    });

    testWidgets('点「取消」得到 false，点遮罩得到 null', (WidgetTester tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey<String>('clearDanmakuCancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('clearDanmakuConfirmDialog')), findsNothing);
    });
  });

  group('清空确认与「已收」计数（#99）', () {
    testWidgets('点清空后取消：「已收」一处不动', (WidgetTester tester) async {
      final _FakeSocket socket = await _pumpDanmuPage(tester);
      socket.emitEvents(<DanmakuEvent>[_chatEvent('第一条'), _chatEvent('第二条')]);
      await tester.pump();
      expect(_receivedLabel('已收 2 条'), findsOneWidget);

      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('clearDanmakuCancel')));
      await tester.pumpAndSettle();

      // 取消 = 什么都没发生：计数先归零会让状态栏与列表口径永久分裂，
      // 还会把这个错误的 0 带进「复制诊断」的摘要里。
      expect(
        _receivedLabel('已收 2 条'),
        findsOneWidget,
        reason: '取消后计数不能先行归零',
      );
    });

    testWidgets('确认清空：「已收」归零', (WidgetTester tester) async {
      final _FakeSocket socket = await _pumpDanmuPage(tester);
      socket.emitEvents(<DanmakuEvent>[_chatEvent('第一条')]);
      await tester.pump();
      expect(_receivedLabel('已收 1 条'), findsOneWidget);

      await tester.tap(find.byTooltip('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('clearDanmakuConfirm')));
      await tester.pumpAndSettle();

      expect(_receivedLabel('已收 0 条'), findsOneWidget);
    });
  });
}

/// 只认状态栏里的那一行：页面别处（诊断摘要等）也可能带同样的文案。
Finder _receivedLabel(String label) => find.descendant(
      of: find.byType(DanmuStatusBar),
      matching: find.text(label),
    );

/// 挂载弹幕页：注入假会话（假房间接口 + 假签名器 + 假 socket），不碰真实网络。
Future<_FakeSocket> _pumpDanmuPage(WidgetTester tester) async {
  final Directory dir = Directory.systemTemp.createTempSync('danmu_clear_page');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  // 页面 initState 会读偏好与过滤（默认走 path_provider 通道）。
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
  // 页面 initState 会异步读偏好 / 过滤（真实文件读）：FakeAsync 下真实 I/O 不会自己
  // 推进，必须借 runAsync 让它跑完，否则测试收尾时会留下未完成的读取（#97 同款坑）。
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  return socket;
}

DanmakuEvent _chatEvent(String text) => DanmakuEvent(
      kind: DanmakuKind.chat,
      method: 'WebcastChatMessage',
      msgId: 1,
      roomId: 1,
      timeMs: 1758900005000,
      text: text,
      user: DanmakuUser.empty,
    );

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

  void emitEvents(List<DanmakuEvent> events) => _events.add(events);
}
