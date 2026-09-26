// 新增连接前二次确认（prd F25）：「本次会话内不再提示」只作用于当次会话。
import 'package:danmu_float/compliance/connect_confirm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(resetConnectConfirm);

  testWidgets('取消返回 false，继续返回 true', (WidgetTester tester) async {
    expect(await _run(tester, tapConfirm: false), isFalse);
    resetConnectConfirm();
    expect(await _run(tester, tapConfirm: true), isTrue);
  });

  testWidgets('勾选本次会话内不再提示后，第二次直接放行且不再弹窗', (WidgetTester tester) async {
    expect(
      await _run(tester, tapConfirm: true, dontAskAgain: true),
      isTrue,
    );
    expect(connectConfirmSuppressed, isTrue);

    // 第二次不再出现弹窗，直接放行。
    expect(await _run(tester, dialogExpected: false), isTrue);
    expect(find.text('连接确认'), findsNothing);
  });

  testWidgets('弹窗列出本次全部直播间号', (WidgetTester tester) async {
    await _pumpHost(tester, webRids: <String>['735', '736']);
    await tester.tap(find.text('触发'));
    await tester.pumpAndSettle();

    expect(find.text('· 735'), findsOneWidget);
    expect(find.text('· 736'), findsOneWidget);
    expect(find.text('本次会话内不再提示'), findsOneWidget);
    expect(find.text('继续连接'), findsOneWidget);
  });
}

/// 点开确认弹窗并选择「继续/取消」，返回弹窗结果。
Future<bool?> _run(
  WidgetTester tester, {
  bool tapConfirm = true,
  bool dontAskAgain = false,
  bool dialogExpected = true,
}) async {
  bool? result;
  await _pumpHost(
    tester,
    webRids: <String>['735'],
    onResult: (bool? value) => result = value,
  );
  await tester.tap(find.text('触发'));
  await tester.pumpAndSettle();
  if (!dialogExpected) return result;
  if (dontAskAgain) {
    await tester.tap(find.text('本次会话内不再提示'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(tapConfirm ? '继续连接' : '取消'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required List<String> webRids,
  void Function(bool? result)? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                final bool value =
                    await confirmNewConnection(context, webRids: webRids);
                onResult?.call(value);
              },
              child: const Text('触发'),
            ),
          ),
        ),
      ),
    ),
  );
}
