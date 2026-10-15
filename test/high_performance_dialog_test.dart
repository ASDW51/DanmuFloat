// 「高性能模式」强制确认弹窗（prd F4）：首页开窗与悬浮窗内加栏共用同一份实现，
// 所以这一份用例同时锁住两处的文案与「不提供不再提示」这条硬要求（UX-05）。
import 'package:danmu_float/ui/high_performance_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 把弹窗挂在一个按钮后面，用户选择写进 [result]，便于断言。
  ///
  /// 弹窗有入场动画，pump 足量再断言 / 点击；不要用 `pumpAndSettle`（首页场景会
  /// 因持续的 post-frame 回调永不空闲，这里保持同一习惯）。
  Future<void> pumpDialog(
    WidgetTester tester,
    List<bool> result, {
    required int paneCount,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              result.add(await confirmHighPerformance(context, paneCount));
            },
            child: const Text('开窗'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('开窗'));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('弹窗给出栏数与后果，且没有任何「不再提示」控件（prd F4）',
      (WidgetTester tester) async {
    final List<bool> result = <bool>[];
    await pumpDialog(tester, result, paneCount: 5);

    expect(find.text('高性能模式'), findsOneWidget);
    expect(find.textContaining('本次要开 5 栏'), findsOneWidget);
    expect(
      find.textContaining('不再提示'),
      findsNothing,
      reason: '强制确认，不提供记忆开关（AGENTS.md 第 5 节）',
    );
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('继续开启'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(result, <bool>[false], reason: '取消 = 不继续，栏数不该变');
  });

  testWidgets('确认后返回 true，调用方才会加上第 5 栏（UX-05）',
      (WidgetTester tester) async {
    final List<bool> result = <bool>[];
    await pumpDialog(tester, result, paneCount: 5);

    await tester.tap(find.text('继续开启'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(result, <bool>[true]);
  });
}
