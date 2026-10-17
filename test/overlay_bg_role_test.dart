// 第 7 轮 ①：悬浮球 / 胶囊与菜单面板的底色成为独立角色（#68）；#146 修正了其中写反的取值。
//
// 教训（#146）：原来的断言拿 `OverlayPalette.darkPalette` 这个「同一次提交里新建的常量」
// 去自证「与原来的字面量逐位相等」——两组常量一起写反也照样通过，属于自证陷阱。
// 现在改成对照**语义**：即 #68 之前那几句内联三元表达式在各自 isLight 下的分支。
// 另外补「底色 vs 前景」的实测对比度：对比度守卫只拿文字色比 maskColor（底色角色不在
// textColorKeys 里），所以「近白面板 + 纯白字」这类问题它一个都发现不了。
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// #68 之前球 / 胶囊底色的内联写法：`isLight ? white70 : black54`。
Color _ballBgFor(bool isLight) => isLight ? Colors.white70 : Colors.black54;

/// #68 之前菜单面板底色的内联写法：`isLight ? white@0.94 : black@0.9`。
///
/// 0.94×255≈240=0xF0、0.9×255≈230=0xE6；const 上下文里不能调 `withValues`。
Color _menuBgFor(bool isLight) =>
    isLight ? const Color(0xF0FFFFFF) : const Color(0xE6000000);

void main() {
  group('底色角色', () {
    test('dark / light 等于原三元表达式在各自 isLight 下的分支（#146）', () {
      for (final OverlayTheme theme in <OverlayTheme>[
        OverlayTheme.dark,
        OverlayTheme.light,
      ]) {
        expect(
          theme.chromeBg.toARGB32(),
          _ballBgFor(theme.isLight).toARGB32(),
          reason: '${theme.id} 的球 / 胶囊底色必须等于 #68 之前的字面量',
        );
        expect(
          theme.menuBg.toARGB32(),
          _menuBgFor(theme.isLight).toARGB32(),
          reason: '${theme.id} 的菜单面板底色必须等于 #68 之前的字面量；'
              '写反会让默认深色变成「近白面板 + 纯白字」（#146，1.14:1）',
        );
      }
    });

    test('旧参照常量与预设一致（常量本身不是标准答案）', () {
      expect(
        OverlayPalette.darkPalette.chromeBg.toARGB32(),
        _ballBgFor(false).toARGB32(),
      );
      expect(
        OverlayPalette.darkPalette.menuBg.toARGB32(),
        _menuBgFor(false).toARGB32(),
      );
      expect(
        OverlayPalette.lightPalette.chromeBg.toARGB32(),
        _ballBgFor(true).toARGB32(),
      );
      expect(
        OverlayPalette.lightPalette.menuBg.toARGB32(),
        _menuBgFor(true).toARGB32(),
      );
    });

    test('两个角色在 colorKeys 里，但不在 textColorKeys 里', () {
      expect(OverlayTheme.colorKeys, contains('chromeBg'));
      expect(OverlayTheme.colorKeys, contains('menuBg'));
      // 底色不参与对比度守卫：守卫校正的是文字色。这也是 #146 能静默通过门禁的原因，
      // 所以下面的组用显式的「底色 vs 前景」断言来兜。
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

  group('底色与前景的实测对比度（#146）', () {
    // 面板 / 球底都是半透明的，必须先展平到真实背衬（窗口蒙版 maskColor）再比；
    // 把背景「合成到自己身上」没有意义（见 flattenOver 的注释）。
    const List<OverlayTheme> presets = <OverlayTheme>[
      OverlayTheme.dark,
      OverlayTheme.light,
      OverlayTheme.contrast,
      OverlayTheme.sepia,
    ];

    for (final OverlayTheme theme in presets) {
      test('${theme.id}：菜单面板底 vs chrome / secondary 文字 ≥ 4.5:1', () {
        final Color panel =
            OverlayTheme.flattenOver(theme.menuBg, theme.maskColor);
        for (final Color foreground in <Color>[theme.chrome, theme.secondary]) {
          expect(
            OverlayTheme.contrastRatio(foreground, panel),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.id} 的面板底与面板字必须可读：'
                '#146 里 dark 实测只有 1.14:1，用户「看不见设置小窗的字体」',
          );
        }
      });

      test('${theme.id}：球 / 胶囊底 vs chrome 图标 ≥ 4.5:1', () {
        final Color ball =
            OverlayTheme.flattenOver(theme.chromeBg, theme.maskColor);
        expect(
          OverlayTheme.contrastRatio(theme.chrome, ball),
          greaterThanOrEqualTo(4.5),
          reason: '${theme.id} 的悬浮球图标压在底色上必须看得清（#146 dark 实测 2.10:1）',
        );
      });
    }
  });
}
