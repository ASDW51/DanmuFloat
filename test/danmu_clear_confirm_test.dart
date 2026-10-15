// UX-23b：「清空」二次确认——默认答案必须是「不动」。
import 'dart:async';

import 'package:danmu_float/ui/danmu_page.dart';
import 'package:flutter/material.dart';
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
}
