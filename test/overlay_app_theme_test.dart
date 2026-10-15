// 第 6 轮 UX-32(H)：悬浮窗根 widget 的主题映射——弹窗等 Material 组件跟随皮肤。
//
// 这条链路此前是缺的：OverlayApp 没挂 theme，深色皮肤下弹窗仍是白底，
// 于是「多元素配色」在弹窗层是假的。
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 弹窗实际取到的底色（M3 的 AlertDialog 用 surfaceContainerHigh）。
Color _dialogSurface(OverlayPalette palette) =>
    overlayThemeData(palette).colorScheme.surfaceContainerHigh;

void main() {
  group('overlayThemeData', () {
    test('深色系主题（深邃/高对比/护眼）派生深色 scheme，浅色主题派生浅色 scheme', () {
      for (final OverlayTheme theme in OverlayTheme.presets) {
        final ThemeData data = overlayThemeData(theme.toPalette());
        expect(
          data.colorScheme.brightness,
          theme.isLight ? Brightness.light : Brightness.dark,
          reason: theme.id,
        );
        final double luminance = data.colorScheme.surfaceContainerHigh
            .computeLuminance();
        if (theme.isLight) {
          expect(luminance, greaterThan(0.8), reason: '${theme.id} 弹窗不是浅色');
        } else {
          expect(luminance, lessThan(0.2), reason: '${theme.id} 弹窗不是深色');
        }
      }
    });

    test('弹窗里的文字对底色都达标（守卫在主题映射里也生效）', () {
      for (final OverlayTheme theme in OverlayTheme.presets) {
        final ColorScheme scheme = overlayThemeData(theme.toPalette())
            .colorScheme;
        expect(
          OverlayTheme.contrastRatio(
            scheme.onSurface,
            scheme.surfaceContainerHigh,
          ),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.id} 弹窗正文不可读',
        );
        expect(
          OverlayTheme.contrastRatio(
            scheme.onSurfaceVariant,
            scheme.surfaceContainerHigh,
          ),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.id} 弹窗次要文字不可读',
        );
      }
    });

    test('弹窗底色取自窗口蒙版色，而不是写死的灰', () {
      // 护眼主题的蒙版是暖色，弹窗底色必须跟着暖，否则一眼看去是两套皮肤。
      final Color sepia = _dialogSurface(OverlayTheme.sepia.toPalette());
      final Color dark = _dialogSurface(OverlayTheme.dark.toPalette());
      expect(sepia, isNot(dark));
      expect(sepia.r, greaterThan(sepia.b), reason: '护眼底色应当偏暖');
    });
  });

  testWidgets('深色/浅色皮肤下弹窗实际渲染出的底色随之变化', (WidgetTester tester) async {
    for (final bool light in <bool>[false, true]) {
      final OverlayPalette palette = light
          ? OverlayTheme.light.toPalette()
          : OverlayTheme.dark.toPalette();
      await tester.pumpWidget(
        MaterialApp(
          theme: overlayThemeData(palette),
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (BuildContext context) =>
                    const AlertDialog(title: Text('弹窗')),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      final Material surface = tester
          .widgetList<Material>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Material),
            ),
          )
          .first;
      final double luminance = surface.color!.computeLuminance();
      if (light) {
        expect(luminance, greaterThan(0.8), reason: '浅色皮肤下弹窗应为浅色');
      } else {
        expect(luminance, lessThan(0.2), reason: '深色皮肤下弹窗应为深色');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
