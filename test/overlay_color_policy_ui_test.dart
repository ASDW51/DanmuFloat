// 第 7 轮 ⑤b：配色区的对比度策略三态，以及「显示值 == 渲染值」。
//
// 关键断言：adjust 下设置页显示的是**校正后**的十六进制，而不是用户原色——窗内
// _palette 走的是同一个 enforceTextContrast(4.5) 调用，因此显示值即渲染值。
import 'package:danmu_float/ui/overlay_color_section.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const int nearBlack = 0xFF111111;

  Future<void> pump(
    WidgetTester tester, {
    required String policy,
    required Map<String, int> overrides,
    void Function(String policy)? onPolicy,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OverlayColorSection(
              themeId: 'dark',
              overrides: overrides,
              contrastPolicy: policy,
              onThemeChanged: (String _) {},
              onOverrideChanged: (String role, int? argb) {},
              onContrastPolicyChanged: onPolicy ?? (String _) {},
            ),
          ),
        ),
      ),
    );
    // 默认折叠，先展开。
    await tester.tap(find.byKey(const ValueKey<String>('overlayColorSection')));
    await tester.pumpAndSettle();
  }

  int guardedArgb() => OverlayTheme.preset('dark')
      .resolve(<String, int>{'body': nearBlack})
      .enforceTextContrast(4.5)
      .colorOf('body')
      .toARGB32();

  testWidgets('自动校正：显示校正后的取值，且与渲染值一致', (WidgetTester tester) async {
    await pump(
      tester,
      policy: 'adjust',
      overrides: <String, int>{'body': nearBlack},
    );
    final int guarded = guardedArgb();
    expect(guarded, isNot(nearBlack), reason: '这个颜色本就不可读，守卫必须动它');
    expect(find.text(formatHexColor(guarded)), findsWidgets);
    expect(find.text(formatHexColor(nearBlack)), findsNothing);
  });

  testWidgets('原样显示：不改色，显示用户选的取值', (WidgetTester tester) async {
    await pump(
      tester,
      policy: 'allow',
      overrides: <String, int>{'body': nearBlack},
    );
    expect(find.text(formatHexColor(nearBlack)), findsWidgets);
  });

  testWidgets('切换策略回报新取值', (WidgetTester tester) async {
    String? picked;
    await pump(
      tester,
      policy: 'adjust',
      overrides: const <String, int>{},
      onPolicy: (String policy) => picked = policy,
    );
    final Finder allow = find.byKey(
      const ValueKey<String>('overlayContrastPolicy_allow'),
    );
    await tester.ensureVisible(allow);
    await tester.pumpAndSettle();
    await tester.tap(allow);
    await tester.pumpAndSettle();
    expect(picked, 'allow');
  });

  testWidgets('三态都渲染出来，当前值选中', (WidgetTester tester) async {
    await pump(
      tester,
      policy: 'warn',
      overrides: const <String, int>{},
    );
    for (final String label in <String>['自动校正', '仅提示', '原样显示']) {
      expect(find.text(label), findsOneWidget);
    }
    final ChoiceChip warn = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey<String>('overlayContrastPolicy_warn')),
    );
    expect(warn.selected, isTrue);
  });
}
