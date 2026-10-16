// 免责声明页（prd F25）：首次启动未勾选不可继续；已同意者从设置页重进为只读（#85）。
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

  // 设置页重进现在走只读模式（reviewMode，见下方 #85 的用例）；这条锁住「非只读时若
  // 页面在返回栈上，同意后回到上一页」的行为，首次启动的根页面路径不走这里。
  testWidgets('同意后若页面在返回栈上则返回上一页', (WidgetTester tester) async {
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

  testWidgets('已同意者重进为只读：显示「已同意」且没有可改状态的控件（#85）', (WidgetTester tester) async {
    int agreed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DisclaimerPage(
          onAgree: () async => agreed++,
          reviewMode: true,
        ),
      ),
    );

    // 状态照实显示为「已同意」：此前重进仍是未勾选的勾选框，看着像还没同意过。
    expect(find.text('已同意上述声明'), findsOneWidget);
    expect(find.text('首次启动时勾选，之后不可修改'), findsOneWidget);

    // 既没有勾选框也没有「同意并继续」：重进是查看，不是再同意一次。
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('同意并继续'), findsNothing);
    expect(agreed, 0, reason: '只读模式不该触发任何写合规状态的动作');

    await tester.tap(find.text('关闭'));
    await tester.pump();
    expect(agreed, 0);
  });

  testWidgets('首次启动路径不受影响：未勾选仍不可继续', (WidgetTester tester) async {
    int agreed = 0;
    await tester.pumpWidget(
      MaterialApp(home: DisclaimerPage(onAgree: () async => agreed++)),
    );

    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '同意并继续'))
          .onPressed,
      isNull,
      reason: 'prd F25 硬要求：未勾选不可进入主界面',
    );
  });

  testWidgets('同意回调失败时复位按钮并提示重试，不静默卡死（#106）', (WidgetTester tester) async {
    int calls = 0;
    bool failing = true;
    await tester.pumpWidget(
      MaterialApp(
        home: DisclaimerPage(
          onAgree: () async {
            calls++;
            if (failing) throw StateError('磁盘已满');
          },
        ),
      ),
    );

    await tester.tap(find.text('我已阅读并同意上述声明'));
    await tester.pump();
    await tester.tap(find.text('同意并继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, 1);
    expect(
      find.text('保存失败，请重试'),
      findsOneWidget,
      reason: '同意没写进磁盘要明说，否则用户以为已同意、重启却又回到本页',
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '同意并继续'))
          .onPressed,
      isNotNull,
      reason: '提交标志必须异常安全复位，否则按钮永久禁用并挂转圈（首启时本页无返回栈）',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 重试：写盘恢复后应能正常提交，不必重新勾选。
    failing = false;
    await tester.tap(find.text('同意并继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(calls, 2);
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '提交成功后也要把转圈收掉（首启时本页是根路由，无返回栈）',
    );
  });
}
