// 第 7 轮 ①：悬浮球 / 胶囊与菜单面板的底色成为独立角色。
//
// 零外观突变是硬约束：dark/light 的取值必须与原来的字面量逐位相等，否则会出现
// 「没改设置却变了样」——这正是 A 定下的钉子。
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('底色角色', () {
    test('dark：与原来的字面量逐位相等', () {
      expect(
        OverlayPalette.darkPalette.chromeBg.toARGB32(),
        Colors.white70.toARGB32(),
      );
      expect(
        OverlayPalette.darkPalette.menuBg.toARGB32(),
        Colors.white.withValues(alpha: 0.94).toARGB32(),
      );
      expect(
        OverlayTheme.dark.menuBg.toARGB32(),
        Colors.white.withValues(alpha: 0.94).toARGB32(),
      );
    });

    test('light：与原来的字面量逐位相等', () {
      expect(
        OverlayPalette.lightPalette.chromeBg.toARGB32(),
        Colors.black54.toARGB32(),
      );
      expect(
        OverlayPalette.lightPalette.menuBg.toARGB32(),
        Colors.black.withValues(alpha: 0.9).toARGB32(),
      );
      expect(
        OverlayTheme.light.chromeBg.toARGB32(),
        Colors.black54.toARGB32(),
      );
    });

    test('两个角色在 colorKeys 里，但不在 textColorKeys 里', () {
      expect(OverlayTheme.colorKeys, contains('chromeBg'));
      expect(OverlayTheme.colorKeys, contains('menuBg'));
      // 底色不参与对比度守卫：守卫校正的是文字色。
      expect(OverlayTheme.textColorKeys, isNot(contains('chromeBg')));
      expect(OverlayTheme.textColorKeys, isNot(contains('menuBg')));
    });

    test('角色覆盖能作用到底色，并随 toPalette 传下去', () {
      final OverlayTheme theme = OverlayTheme.dark.resolve(<String, int>{
        'chromeBg': 0xFF123456,
        'menuBg': 0xFF654321,
      });
      expect(theme.colorOf('chromeBg').toARGB32(), 0xFF123456);
      expect(theme.toPalette().chromeBg.toARGB32(), 0xFF123456);
      expect(theme.toPalette().menuBg.toARGB32(), 0xFF654321);
      expect(
        theme.toPalette().body.toARGB32(),
        OverlayTheme.dark.body.toARGB32(),
      );
    });

    test('高对比预设的两个底色都不透明', () {
      expect(OverlayTheme.contrast.chromeBg.a, 1.0);
      expect(OverlayTheme.contrast.menuBg.a, 1.0);
    });

    test('护眼预设沿用 maskColor 的暖色调', () {
      expect(
        OverlayTheme.sepia.menuBg.toARGB32(),
        OverlayTheme.sepia.maskColor.toARGB32(),
      );
      expect(
        HSVColor.fromColor(OverlayTheme.sepia.chromeBg).hue,
        closeTo(HSVColor.fromColor(OverlayTheme.sepia.maskColor).hue, 0.5),
      );
    });
  });
}
