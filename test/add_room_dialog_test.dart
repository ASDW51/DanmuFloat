// 添加主播表单：不限制输入形态是本轮明确的交互要求，用例把它锁住。
import 'dart:async';

import 'package:danmu_float/net/http_transport.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/room/room_link_parser.dart';
import 'package:danmu_float/ui/add_room_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';

void main() {
  /// 任何输入都不该联网的解析器：一旦发起请求就说明本地判断失效了。
  RoomLinkResolver offlineResolver() => RoomLinkResolver(
        transport: FakeTransport((Uri uri, Map<String, String> headers) async =>
            throw StateError('不应发起请求')),
      );

  Future<void> openDialog(
    WidgetTester tester, {
    required void Function(ManagedRoom?) onResult,
    RoomLinkResolver? resolver,
    Set<String> existing = const <String>{},
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  onResult(await showAddRoomDialog(
                    context,
                    existingWebRids: existing,
                    resolver: resolver ?? offlineResolver(),
                  ));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('非纯数字输入不拦，原样存成主播标识', (WidgetTester tester) async {
    ManagedRoom? result;
    await openDialog(tester, onResult: (ManagedRoom? room) => result = room);

    await tester.enterText(find.byType(TextField).first, 'moon_knight');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.webRid, 'moon_knight');
  });

  testWidgets('直播间链接解析成 webRid 后再保存', (WidgetTester tester) async {
    ManagedRoom? result;
    await openDialog(tester, onResult: (ManagedRoom? room) => result = room);

    await tester.enterText(
      find.byType(TextField).first,
      'https://live.douyin.com/123456',
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(result!.webRid, '123456');
  });

  testWidgets('备注写入备注字段，不影响标识', (WidgetTester tester) async {
    ManagedRoom? result;
    await openDialog(tester, onResult: (ManagedRoom? room) => result = room);

    await tester.enterText(find.byType(TextField).first, 'moon_knight');
    await tester.enterText(find.byType(TextField).last, '老王');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(result!.webRid, 'moon_knight');
    expect(result!.name, '老王');
    expect(result!.displayName, '老王');
  });

  testWidgets('空输入不提交，留在表单内提示', (WidgetTester tester) async {
    ManagedRoom? result;
    await openDialog(tester, onResult: (ManagedRoom? room) => result = room);

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('请输入直播间号、链接或抖音号'), findsOneWidget);
  });

  testWidgets('已在列表中的主播按解析结果判重', (WidgetTester tester) async {
    ManagedRoom? result;
    await openDialog(
      tester,
      onResult: (ManagedRoom? room) => result = room,
      existing: <String>{'123456'},
    );

    await tester.enterText(
      find.byType(TextField).first,
      'https://live.douyin.com/123456',
    );
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('该主播已在列表中（123456）'), findsOneWidget);
  });

  testWidgets('解析进行中「取消」仍可点，点了立即关闭表单（UX-03）',
      (WidgetTester tester) async {
    ManagedRoom? result;
    final Completer<HttpResponseData> pending = Completer<HttpResponseData>();
    await openDialog(
      tester,
      onResult: (ManagedRoom? room) => result = room,
      // 永不返回的传输层：模拟弱网 / DNS 挂起；阈值取短值，测试结束前让超时落地
      // （否则 flutter_test 会以「A Timer is still pending」判失败）。
      resolver: RoomLinkResolver(
        transport: FakeTransport(
          (Uri uri, Map<String, String> headers) => pending.future,
        ),
        resolveTimeout: const Duration(milliseconds: 20),
      ),
    );

    await tester.enterText(
      find.byType(TextField).first,
      'https://v.douyin.com/iABC123/',
    );
    await tester.tap(find.text('添加'));
    await tester.pump();

    final TextButton cancelButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '取消'),
    );
    expect(cancelButton.onPressed, isNotNull, reason: '解析期间取消必须可用');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull, reason: '取消不该等联网解析返回');
    expect(find.byType(AlertDialog), findsNothing);

    // 解析超时后结果才回来：此时表单已 pop，不能再 pop 一次把首页也弹掉。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('open'), findsOneWidget, reason: '首页不该被二次 pop 弹掉');
  });

  testWidgets('链接联网解析超时后按原文添加并提示（UX-03）',
      (WidgetTester tester) async {
    ManagedRoom? result;
    final Completer<HttpResponseData> pending = Completer<HttpResponseData>();
    await openDialog(
      tester,
      onResult: (ManagedRoom? room) => result = room,
      resolver: RoomLinkResolver(
        transport: FakeTransport(
          (Uri uri, Map<String, String> headers) => pending.future,
        ),
        resolveTimeout: const Duration(milliseconds: 20),
      ),
    );

    const String link = 'https://v.douyin.com/iABC123/';
    await tester.enterText(find.byType(TextField).first, link);
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(result, isNotNull, reason: '解析不出来不拦，按原文保存');
    expect(result!.webRid, link);
    expect(
      find.text('未能联网解析链接，已按原文添加'),
      findsOneWidget,
      reason: '粘的是链接却没解析出来，必须明确告知，否则用户以为加的是那个直播间',
    );

    // 排掉 SnackBar 的自动消失定时器，避免测试结束时残留 pending timer。
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}