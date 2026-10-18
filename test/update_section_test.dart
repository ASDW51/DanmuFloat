// 设置页「关于 → 检查更新」的交互（#166）。
//
// 网络、偏好存储、打开链接全部注入替身：这一块的每条路径（有新版本 / 已是最新 /
// 失败 / 打不开浏览器）都要能在纯 Dart 里跑。
import 'dart:io';

import 'package:danmu_float/net/http_transport.dart';
import 'package:danmu_float/net/update_checker.dart';
import 'package:danmu_float/storage/update_prefs.dart';
import 'package:danmu_float/ui/update_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定应答的假 transport。
class _FakeTransport implements HttpTransport {
  _FakeTransport({this.statusCode = 200, this.body = '{}'});

  final int statusCode;
  final String body;

  @override
  Future<HttpResponseData> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async => HttpResponseData(statusCode: statusCode, body: body);

  @override
  void close() {}
}

/// 内存偏好存储：widget 测试不碰真实文件。
class _MemoryPrefsStore extends UpdatePrefsStore {
  _MemoryPrefsStore()
    : super(directoryResolver: () async => Directory.systemTemp);

  /// 读盘返回值：用例按需改，默认是「从没查过、自动检查关闭」。
  UpdatePrefs initial = const UpdatePrefs();
  UpdatePrefs saved = const UpdatePrefs();
  int saves = 0;

  @override
  Future<UpdatePrefs> load() async => initial;

  @override
  Future<void> save(UpdatePrefs prefs) async {
    saved = prefs;
    saves++;
  }
}

const String _releaseBody = '''
{
  "tag_name": "v0.2.0",
  "name": "0.2.0",
  "published_at": "2026-10-01T12:30:00Z",
  "body": "- 修复悬浮窗白底白字\\n- 新增检查更新",
  "html_url": "https://github.com/ASDW51/DanmuFloat/releases/tag/v0.2.0",
  "assets": [
    {"name": "DanmuFloat-v0.2.0-arm64-v8a.apk", "browser_download_url": "https://example.com/arm64.apk", "digest": "sha256:armhash"},
    {"name": "DanmuFloat-v0.2.0-universal.apk", "browser_download_url": "https://example.com/universal.apk", "digest": "sha256:abcdef"},
    {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"}
  ]
}
''';

Widget _wrap(UpdateSection section) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: section)),
);

void main() {
  testWidgets('未检查时说明当前版本，点一下查到新版本并给出更新日志（#166）', (
    WidgetTester tester,
  ) async {
    final List<Uri> opened = <Uri>[];
    final _MemoryPrefsStore store = _MemoryPrefsStore();
    await tester.pumpWidget(
      _wrap(
        UpdateSection(
          checker: UpdateChecker(transport: _FakeTransport(body: _releaseBody)),
          prefsStore: store,
          currentVersion: '0.1.0',
          openUrl: (Uri uri) async {
            opened.add(uri);
            return true;
          },
          now: () => 1700000000000,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('从没检查过'), findsOneWidget);
    expect(find.textContaining('v0.1.0'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('updateCheckTile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('发现新版本 v0.2.0'), findsOneWidget);
    expect(find.text('更新日志'), findsOneWidget, reason: 'App 内要能看到更新日志');
    expect(find.text('打开发布页'), findsOneWidget);
    expect(find.text('复制 APK 下载地址'), findsOneWidget);
    expect(
      find.textContaining('DanmuFloat-v0.2.0-universal.apk'),
      findsOneWidget,
      reason: '测试跑在桌面 VM 上，ABI 未知时应回落通用包并写明选的是哪个包',
    );
    expect(find.text('复制 SHA256'), findsOneWidget);
    expect(
      store.saved.lastCheckedAt,
      1700000000000,
      reason: '检查过就要记时间戳，用于 24 小时节流',
    );

    // 打开更新说明：notes 原文要能读到。
    await tester.tap(find.byKey(const ValueKey<String>('updateNotesTile')));
    await tester.pumpAndSettle();
    expect(find.textContaining('修复悬浮窗白底白字'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // 打开发布页走注入的 openUrl，不碰 url_launcher 的平台通道。
    await tester.tap(find.byKey(const ValueKey<String>('updateOpenReleaseTile')));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), contains('/releases/tag/v0.2.0'));
  });

  testWidgets('已是最新版本时只给结论，不出现更新日志入口（#166）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        UpdateSection(
          checker: UpdateChecker(
            transport: _FakeTransport(
              body: '{"tag_name":"v0.1.0","html_url":"https://example.com"}',
            ),
          ),
          prefsStore: _MemoryPrefsStore(),
          currentVersion: '0.1.0',
          openUrl: (Uri uri) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('updateCheckTile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('已是最新版本'), findsOneWidget);
    expect(find.text('更新日志'), findsNothing);
  });

  testWidgets('查询失败给出可重试的说明，且不弹错误（#166）', (
    WidgetTester tester,
  ) async {
    final _MemoryPrefsStore store = _MemoryPrefsStore();
    await tester.pumpWidget(
      _wrap(
        UpdateSection(
          checker: UpdateChecker(transport: _FakeTransport(statusCode: 403)),
          prefsStore: store,
          currentVersion: '0.1.0',
          openUrl: (Uri uri) async => true,
          now: () => 1700000000000,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('updateCheckTile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('限流'), findsOneWidget);
    expect(
      find.textContaining('网络不可用'),
      findsNothing,
      reason: '限流不是网络故障，文案要分开',
    );
    expect(
      store.saved.lastCheckedAt,
      1700000000000,
      reason: '失败也要记时间戳，否则弱网下每次进来都重试',
    );
  });

  testWidgets('仓库只有草稿（404）时说「还没发布版本」，不说网络故障（#166）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        UpdateSection(
          checker: UpdateChecker(transport: _FakeTransport(statusCode: 404)),
          prefsStore: _MemoryPrefsStore(),
          currentVersion: '0.1.0',
          openUrl: (Uri uri) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('updateCheckTile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有发布任何版本'), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsNothing);
  });

  testWidgets('自动检查开关默认关闭，打开后落盘（#166）', (WidgetTester tester) async {
    final _MemoryPrefsStore store = _MemoryPrefsStore();
    await tester.pumpWidget(
      _wrap(
        UpdateSection(
          checker: UpdateChecker(transport: _FakeTransport()),
          prefsStore: store,
          currentVersion: '0.1.0',
          openUrl: (Uri uri) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final SwitchListTile autoSwitch = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey<String>('updateAutoCheckSwitch')),
    );
    expect(autoSwitch.value, isFalse, reason: '会访问 github.com，必须默认关闭');
    expect(find.textContaining('会访问 github.com'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('updateAutoCheckSwitch')));
    await tester.pumpAndSettle();
    expect(store.saved.autoCheck, isTrue);
    expect(store.saves, 1);
  });

  testWidgets('打不开浏览器时退回「已复制地址」（#166）', (WidgetTester tester) async {
    final List<MethodCall> platformCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        platformCalls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _wrap(
        UpdateSection(
          checker: UpdateChecker(transport: _FakeTransport(body: _releaseBody)),
          prefsStore: _MemoryPrefsStore(),
          currentVersion: '0.1.0',
          openUrl: (Uri uri) async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('updateCheckTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('updateOpenReleaseTile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('下载地址已复制'), findsOneWidget);
    final Iterable<MethodCall> clipboard = platformCalls.where(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    expect(clipboard, isNotEmpty);
  });
}
