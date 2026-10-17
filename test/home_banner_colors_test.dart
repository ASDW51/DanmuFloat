import 'package:danmu_float/ui/danmu_text_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 相对亮度对比度（与 `Color.computeLuminance()` 同口径）。
double contrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double high = la > lb ? la : lb;
  final double low = la > lb ? lb : la;
  return (high + 0.05) / (low + 0.05);
}

void main() {
  group('常驻提示条取色（#137）', () {
    for (final Brightness brightness in Brightness.values) {
      for (final bool danger in <bool>[false, true]) {
        test('$brightness / danger=$danger 下底色对正文、图标、按钮文字都 ≥4.5:1', () {
          final ({Color background, Color foreground}) colors = bannerColors(
            brightness: brightness,
            danger: danger,
          );
          // 三处共用同一前景色（见 bannerColors 的注释：拆开就会漂移），所以是同一
          // 组数值；分开断言是为了把「正文 / 图标 / 按钮文字都必须达标」写进用例名。
          expect(
            contrastRatio(colors.background, colors.foreground),
            greaterThanOrEqualTo(4.5),
            reason: '正文压底色',
          );
          expect(
            contrastRatio(colors.background, colors.foreground),
            greaterThanOrEqualTo(4.5),
            reason: '图标压底色',
          );
          expect(
            contrastRatio(colors.background, colors.foreground),
            greaterThanOrEqualTo(4.5),
            reason: '按钮文字压底色（深色 primary 曾只有 1.5:1）',
          );
        });
      }
    }

    test('浅色沿用原有底色；深色换成深底，不再出现近白的 shade50', () {
      expect(
        bannerColors(brightness: Brightness.light, danger: false).background,
        const Color(0xFFFFF3E0),
        reason: '浅色外观保持原样',
      );
      expect(
        bannerColors(brightness: Brightness.light, danger: true).background,
        const Color(0xFFFFEBEE),
        reason: '浅色外观保持原样',
      );
      expect(
        bannerColors(brightness: Brightness.dark, danger: false).background,
        isNot(const Color(0xFFFFF3E0)),
        reason: '防回退：深色下不能继续用近白的橙底（亮度 0.907）',
      );
      expect(
        bannerColors(brightness: Brightness.dark, danger: true).background,
        isNot(const Color(0xFFFFEBEE)),
        reason: '防回退：深色下不能继续用近白的红底',
      );
      expect(
        bannerColors(
          brightness: Brightness.dark,
          danger: false,
        ).background.computeLuminance(),
        lessThan(0.2),
      );
      expect(
        bannerColors(
          brightness: Brightness.dark,
          danger: true,
        ).background.computeLuminance(),
        lessThan(0.2),
      );
    });
  });
}
