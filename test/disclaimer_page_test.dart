// 免责声明页（prd F25）：未勾选不可继续；从设置页重进时同意后返回上一页。
import 'package:danmu_float/ui/disclaimer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('未勾选时「同意并继续」禁用，勾选后可点并触发回调', (WidgetTester tester) async {
    int agreed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DisclaimerPage(
          onAgree: () async => agreed++,
        ),
      ),
    );

    FilledButton agreeButton() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, '同意并继续'),
        );
    expect(agreeButton().onPressed, isNull);

    await tester.tap(find.text('我已阅读并同意上述声明'));
    await tester.pump();
    expect(agreeButton().onPressed, isNotNull);

    await tester.tap(find.text('同意并继续'));
    await tester.pump();
    expect(agreed, 1);
  });

  testWidgets('从设置页重进时，同意后返回上一页', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) =>
                      DisclaimerPage(onAgree: () async {}),
                ),
              ),
              child: const Text('打开声明'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开声明'));
    await tester.pumpAndSettle();
    expect(find.text('免责声明'), findsWidgets);

    await tester.tap(find.text('我已阅读并同意上述声明'));
    await tester.pump();
    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();

    expect(find.text('打开声明'), findsOneWidget);
    expect(find.text('免责声明'), findsNothing);
  });
}
