// 第 6 轮 UX-33(F2)：悬浮窗内的配色入口弹窗。
//
// 抽成公开函数是为了能在这里直接挂载断言，而不必 mount 整个 OverlayPage
// （后者订阅静态单订阅流，每个测试文件只能 mount 一次）。
import 'package:danmu_float/ui/overlay_color_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('showOverlayColorDialog', () {
    /// 挂一个按钮把弹窗打开，并把返回值接到 [result] 上。
    Future<OverlayColorChoice?> Function() mount(
      WidgetTester tester,
      String themeId,
      int overrideCount,
    ) {
      OverlayColorChoice? result;
      bool done = false;
      return () async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  result = await showOverlayColorDialog(
                    context,
                    themeId: themeId,
                    overrideCount: overrideCount,
                  );
                  done = true;
                },
                child: const Text('打开配色'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开配色'));
        await tester.pumpAndSettle();
        return done ? result : result;
      };
    }

    testWidgets('四套预设都在，当前主题选中，按覆盖数给出说明', (WidgetTester tester) async {
      await mount(tester, 'light', 2)();
      expect(find.text('悬浮窗配色'), findsOneWidget);
      for (final String label in <String>['深邃', '清爽', '高对比', '护眼']) {
        expect(find.text(label), findsOneWidget, reason: '预设 $label 应当可选');
      }
      expect(find.text('将清除 2 个自定义颜色'), findsOneWidget);
    });

    testWidgets('没有自定义时说明文案不同', (WidgetTester tester) async {
      await mount(tester, 'dark', 0)();
      expect(find.text('当前没有自定义颜色'), findsOneWidget);
    });

    testWidgets('未知主题标识回退到深邃，不崩也不空选', (WidgetTester tester) async {
      await mount(tester, 'nope', 1)();
      final ChoiceChip dark = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey<String>('overlayColorChoice_dark')),
      );
      expect(dark.selected, isTrue);
    });

    testWidgets('换预设并确定：回报新主题且要求保留自定义', (WidgetTester tester) async {
      final OverlayColorChoice? choice = await () async {
        OverlayColorChoice? captured;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  captured = await showOverlayColorDialog(
                    context,
                    themeId: 'dark',
                    overrideCount: 3,
                  );
                },
                child: const Text('打开配色'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开配色'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('overlayColorChoice_sepia')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey<String>('overlayColorConfirm')));
        await tester.pumpAndSettle();
        return captured;
      }();
      expect(choice, isNotNull);
      expect(choice!.themeId, 'sepia');
      expect(choice.resetOverrides, isFalse);
    });

    testWidgets('勾选「全部跟随主题」后确定：要求清空覆盖', (WidgetTester tester) async {
      OverlayColorChoice? captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                captured = await showOverlayColorDialog(
                  context,
                  themeId: 'dark',
                  overrideCount: 2,
                );
              },
              child: const Text('打开配色'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开配色'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('overlayColorResetAll')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('overlayColorConfirm')));
      await tester.pumpAndSettle();
      expect(captured?.resetOverrides, isTrue);
      expect(captured?.themeId, 'dark');
    });

    testWidgets('取消：不回报任何结果', (WidgetTester tester) async {
      bool returned = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                await showOverlayColorDialog(
                  context,
                  themeId: 'dark',
                  overrideCount: 0,
                );
                returned = true;
              },
              child: const Text('打开配色'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开配色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(find.text('悬浮窗配色'), findsNothing);
    });
  });
}
