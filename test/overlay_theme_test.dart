import 'package:danmu_float/ui/overlay_page.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 相对亮度对比度：(L1 + 0.05) / (L2 + 0.05)，L 为较亮一方。
double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 把半透明色按 alpha 合成到 [base] 上再算对比度。
///
/// 为什么必须合成：`computeLuminance()` 只看 RGB、忽略 alpha——`Colors.white54`
/// 会被算成 21:1，而它在黑底上实际约 6:1。不合成就是把断言写成假的。
Color _flatten(Color color, Color base) {
  final double a = color.a;
  if (a >= 1) return color;
  return Color.from(
    alpha: 1,
    red: color.r * a + base.r * (1 - a),
    green: color.g * a + base.g * (1 - a),
    blue: color.b * a + base.b * (1 - a),
  );
}

/// 断言一组文字角色在指定主题下都达到对比度下限。
void _expectTextRoles(OverlayTheme theme, double minimum) {
  final List<String> textRoles = <String>[
    'body',
    'secondary',
    'chrome',
    'userAccent',
    'levelColor',
    'fanLevelColor',
    'activeColor',
  ];
  for (final String role in textRoles) {
    final Color fg = _flatten(theme.colorOf(role), theme.maskColor);
    expect(
      _contrast(fg, theme.maskColor),
      greaterThanOrEqualTo(minimum),
      reason: '${theme.id} 主题的 $role 对窗口底色对比度不足',
    );
  }
}

void main() {
  test('dark / light 预设与现有常量逐字段相等（默认外观零突变的钉子）', () {
    // 这是本 PR 唯一必须成立的硬约束：抽取出主题模型不能顺手改掉任何默认颜色。
    final OverlayPalette dark = OverlayTheme.dark.toPalette();
    expect(dark.isLight, OverlayPalette.darkPalette.isLight);
    expect(dark.body, OverlayPalette.darkPalette.body);
    expect(dark.secondary, OverlayPalette.darkPalette.secondary);
    expect(dark.chrome, OverlayPalette.darkPalette.chrome);
    expect(dark.divider, OverlayPalette.darkPalette.divider);
    expect(dark.bannerBg, OverlayPalette.darkPalette.bannerBg);
    expect(dark.maskColor, OverlayPalette.darkPalette.maskColor);
    expect(dark.border, OverlayPalette.darkPalette.border);
    expect(dark.userAccent, OverlayPalette.darkPalette.userAccent);
    expect(dark.levelColor, OverlayPalette.darkPalette.levelColor);
    expect(dark.fanLevelColor, OverlayPalette.darkPalette.fanLevelColor);
    expect(dark.activeColor, OverlayPalette.darkPalette.activeColor);
    expect(dark.highlightStyle, OverlayPalette.darkPalette.highlightStyle);

    final OverlayPalette light = OverlayTheme.light.toPalette();
    expect(light.isLight, OverlayPalette.lightPalette.isLight);
    expect(light.body, OverlayPalette.lightPalette.body);
    expect(light.secondary, OverlayPalette.lightPalette.secondary);
    expect(light.chrome, OverlayPalette.lightPalette.chrome);
    expect(light.divider, OverlayPalette.lightPalette.divider);
    expect(light.bannerBg, OverlayPalette.lightPalette.bannerBg);
    expect(light.maskColor, OverlayPalette.lightPalette.maskColor);
    expect(light.border, OverlayPalette.lightPalette.border);
    expect(light.userAccent, OverlayPalette.lightPalette.userAccent);
    expect(light.levelColor, OverlayPalette.lightPalette.levelColor);
    expect(light.fanLevelColor, OverlayPalette.lightPalette.fanLevelColor);
    expect(light.activeColor, OverlayPalette.lightPalette.activeColor);
    expect(light.highlightStyle, OverlayPalette.lightPalette.highlightStyle);
  });

  test('按标识取预设，未知标识回落 dark（旧配置不带主题标识的情形）', () {
    expect(OverlayTheme.preset('dark').id, 'dark');
    expect(OverlayTheme.preset('light').id, 'light');
    expect(OverlayTheme.preset('contrast').id, 'contrast');
    expect(OverlayTheme.preset('sepia').id, 'sepia');
    expect(OverlayTheme.preset('不认识的皮肤').id, 'dark');
    expect(OverlayTheme.preset('').id, 'dark');
    expect(OverlayTheme.presets.length, 4);
  });

  test('角色覆盖生效，未知角色与非法值被忽略而不是整表丢弃', () {
    final OverlayTheme resolved = OverlayTheme.dark.resolve(<String, int>{
      'body': 0xFFFF00FF,
      'userAccent': 0xFF00FF00,
      '不存在的角色': 0xFF123456,
      '带透明度的颜色': 0x80FFFFFF,
    });
    expect(resolved.colorOf('body'), const Color(0xFFFF00FF));
    expect(resolved.colorOf('userAccent'), const Color(0xFF00FF00));
    // 合法项照常生效，非法项各自被丢弃：其余角色保持深色预设原值。
    expect(resolved.colorOf('chrome'), OverlayTheme.dark.chrome);
    expect(resolved.id, 'dark');
    expect(resolved.isLight, isFalse);
  });

  test('空覆盖表直接返回原主题，不产生副本', () {
    expect(identical(OverlayTheme.dark.resolve(<String, int>{}), OverlayTheme.dark),
        isTrue);
  });

  test('parseArgb 只接受不透明的合法整数', () {
    expect(OverlayTheme.parseArgb(0xFF123456), const Color(0xFF123456));
    // 半透明会让「用户选的颜色」与屏幕上看到的颜色不一致，直接判非法。
    expect(OverlayTheme.parseArgb(0x80123456), isNull);
    expect(OverlayTheme.parseArgb(-1), isNull);
    expect(OverlayTheme.parseArgb(0x1FFFFFFFF), isNull);
    expect(OverlayTheme.parseArgb('0xFF123456'), isNull);
    expect(OverlayTheme.parseArgb(null), isNull);
  });

  test('四套预设的正文对窗口底色达标（含 alpha 合成）', () {
    for (final OverlayTheme theme in OverlayTheme.presets) {
      final Color body = _flatten(theme.body, theme.maskColor);
      expect(
        _contrast(body, theme.maskColor),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.id} 主题正文对比度不足',
      );
    }
  });

  test('文字角色对比度：高对比预设 ≥7:1，深色/护眼 ≥4.5:1', () {
    _expectTextRoles(OverlayTheme.contrast, 7);
    _expectTextRoles(OverlayTheme.dark, 4.5);
    _expectTextRoles(OverlayTheme.sepia, 4.5);
    // 浅色预设有意不在此断言：它的 secondary 是既有取值 Colors.black54，合成后实测
    // 约 4.47:1（略低于 4.5）。这是本轮开工前就存在的取值，改它属于可见的外观变更，
    // 已作为待裁决项记在 docs/iteration-todo.md 第 6 轮第 2 点，不在本 PR 顺手改。
  });
}
