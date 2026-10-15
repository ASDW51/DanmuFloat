// 第 6 轮 UX-31：对比度守卫（唯一口径的比值函数 + 只调明度的自动校正）。
//
// 为什么单独一个文件：overlay_theme_test.dart 管的是「模型与预设不变形」，
// 这里管的是「可读性守卫」，失败时能一眼看出是模型坏了还是守卫坏了。
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contrastRatio', () {
    test('黑白极值等于 21:1，同色等于 1:1', () {
      expect(OverlayTheme.contrastRatio(Colors.white, Colors.black), 21);
      expect(OverlayTheme.contrastRatio(Colors.black, Colors.black), 1);
    });

    test('半透明前景先按 alpha 合成：white54 在黑底上远低于 21:1', () {
      // 这条是「口径正确」的证明：不合成 alpha 的话会是 21:1，把不可读当成达标。
      final double ratio =
          OverlayTheme.contrastRatio(Colors.white54, Colors.black);
      expect(ratio, greaterThan(4.5));
      expect(ratio, lessThan(7));
    });

    test('背景自身的 alpha 也被展平（半透明底色不会算出虚高的对比度）', () {
      final double opaque =
          OverlayTheme.contrastRatio(Colors.white, Colors.black);
      final double translucent =
          OverlayTheme.contrastRatio(Colors.white, Colors.black54);
      expect(translucent, lessThan(opaque));
    });
  });

  group('ensureContrast', () {
    test('已达标时原样返回，不做无谓改动', () {
      const Color fg = Color(0xFFFFFFFF);
      const Color bg = Color(0xFF000000);
      expect(identical(OverlayTheme.ensureContrast(fg, bg), fg), isTrue);
      // 半透明但达标的颜色也应原样保留（合成只用于判定，不改写取值）。
      expect(
        identical(
          OverlayTheme.ensureContrast(Colors.white54, Colors.black),
          Colors.white54,
        ),
        isTrue,
      );
    });

    test('不可读时只调明度：达标，且色相偏移 <15°、饱和度基本不变', () {
      const Color background = Color(0xFF1A1A1A);
      const Color foreground = Color(0xFF333333);
      expect(
        OverlayTheme.contrastRatio(foreground, background),
        lessThan(4.5),
      );

      final Color fixed = OverlayTheme.ensureContrast(foreground, background);
      expect(
        OverlayTheme.contrastRatio(fixed, background),
        greaterThanOrEqualTo(4.5),
      );

      final HSVColor before = HSVColor.fromColor(foreground);
      final HSVColor after = HSVColor.fromColor(fixed);
      double hueShift = (after.hue - before.hue).abs();
      if (hueShift > 180) hueShift = 360 - hueShift;
      expect(hueShift, lessThan(15), reason: '不能把用户选的颜色换成另一种颜色');
      expect((after.saturation - before.saturation).abs(), lessThan(0.02));
    });

    test('极端组合都能被救到达标（含深底深字 / 浅底浅字 / 半透明）', () {
      final List<(Color, Color)> combos = <(Color, Color)>[
        (const Color(0xFF202020), const Color(0xFF1A1A1A)),
        (const Color(0xFFEEEEEE), const Color(0xFFF5F5F5)),
        (Colors.white24, Colors.black),
        (const Color(0xFF0000FF), const Color(0xFF000080)),
      ];
      for (final (Color foreground, Color background) in combos) {
        final Color fixed =
            OverlayTheme.ensureContrast(foreground, background);
        expect(
          OverlayTheme.contrastRatio(fixed, background),
          greaterThanOrEqualTo(4.5),
          reason: '$foreground 在 $background 上仍不可读',
        );
      }
    });
  });

  group('enforceTextContrast', () {
    test('四套预设本来就达标：守卫不改动任何角色，且返回原对象', () {
      for (final OverlayTheme theme in OverlayTheme.presets) {
        expect(
          identical(theme.enforceTextContrast(4.5), theme),
          isTrue,
          reason: '${theme.id} 竟然需要校正，说明预设本身不达标',
        );
      }
    });

    test('按更高下限（7:1）施加守卫后，全部文字角色都达标', () {
      final OverlayTheme guarded =
          OverlayTheme.preset('dark').enforceTextContrast(7);
      for (final String key in OverlayTheme.textColorKeys) {
        expect(
          OverlayTheme.contrastRatio(guarded.colorOf(key), guarded.maskColor),
          greaterThanOrEqualTo(7),
          reason: key,
        );
      }
    });

    test('守卫只动文字角色：分隔线 / 边框 / 底色 / 进场底色保持不变', () {
      final OverlayTheme guarded =
          OverlayTheme.preset('dark').enforceTextContrast(7);
      expect(guarded.divider, OverlayTheme.dark.divider);
      expect(guarded.border, OverlayTheme.dark.border);
      expect(guarded.maskColor, OverlayTheme.dark.maskColor);
      expect(guarded.bannerBg, OverlayTheme.dark.bannerBg);
      expect(guarded.highlightStyle, OverlayTheme.dark.highlightStyle);
    });

    test('浅色预设的 4.61:1 余量被钉住（低于 4.5 时这里会失败）', () {
      // PM 复算的临界值：Colors.black54 展平到白底约 4.61:1。它只比线高 0.11，
      // 是全项目最贴近阈值的取值——一旦被改动吃掉余量，这条断言会立刻失败。
      expect(
        OverlayTheme.contrastRatio(
          OverlayTheme.light.secondary,
          OverlayTheme.light.maskColor,
        ),
        greaterThanOrEqualTo(4.5),
      );
    });
  });
}
