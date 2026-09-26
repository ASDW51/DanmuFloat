// 添加主播表单：不限制输入形态是本轮明确的交互要求，用例把它锁住。
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
}