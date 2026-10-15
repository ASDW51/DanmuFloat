import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/ui/danmu_text_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 相对亮度对比度：(L1 + 0.05) / (L2 + 0.05)，L 为较亮一方。
///
/// 直接算而不是"看着差不多"：UX-19 的成因就是没人算过，才让黑 54% 的文字铺在
/// 深色底上、5% 灰的文字铺在白底上（约 2.9:1）。
double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Material 3 浅色 / 深色的典型底色（测试里写死，避免依赖主题实现细节）。
const Color _lightSurface = Color(0xFFFFFFFF);
const Color _darkSurface = Color(0xFF1C1B1F);
const Color _darkSurfaceContainerHighest = Color(0xFF36343B);
const Color _lightSurfaceContainerHighest = Color(0xFFE6E0E9);

void main() {
  test('浅色次要文字对白底达到 WCAG AA（≥4.5:1）', () {
    expect(
      _contrast(secondaryTextColor(Brightness.light), _lightSurface),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('深色次要文字对深色 surface 达到 WCAG AA（≥4.5:1）', () {
    expect(
      _contrast(secondaryTextColor(Brightness.dark), _darkSurface),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('进场横幅「欢迎」在深浅两种主题下都达到 WCAG AA', () {
    expect(
      _contrast(
        entryBannerWelcomeColor(Brightness.light),
        _lightSurfaceContainerHighest,
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      _contrast(
        entryBannerWelcomeColor(Brightness.dark),
        _darkSurfaceContainerHighest,
      ),
      greaterThanOrEqualTo(4.5),
    );
    // 把这次的坑钉死：深色主题下不能再返回那个看不见的 Colors.black54。
    expect(entryBannerWelcomeColor(Brightness.dark), isNot(Colors.black54));
  });

  test('五个会话状态色在深浅两种主题下都达到 WCAG AA', () {
    for (final LiveSessionStage stage in LiveSessionStage.values) {
      expect(
        _contrast(stageTextColor(stage, Brightness.light), _lightSurface),
        greaterThanOrEqualTo(4.5),
        reason: '$stage 浅色主题下对比度不足',
      );
      expect(
        _contrast(stageTextColor(stage, Brightness.dark), _darkSurface),
        greaterThanOrEqualTo(4.5),
        reason: '$stage 深色主题下对比度不足',
      );
    }
  });
}
