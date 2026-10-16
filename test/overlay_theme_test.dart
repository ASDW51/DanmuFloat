import 'package:danmu_float/ui/overlay_page.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(
      OverlayTheme.contrastRatio(theme.colorOf(role), theme.maskColor),
      greaterThanOrEqualTo(minimum),
      reason: '${theme.id} 主题的 $role 对窗口底色对比度不足',
    );
  }
}

/// 取一组覆盖「文字 / 底色 / 类型」三个角色族的字段，用于比较两份调色板。
List<int> _argbOf(OverlayPalette palette) => <int>[
  palette.body.toARGB32(),
  palette.secondary.toARGB32(),
  palette.chromeBg.toARGB32(),
  palette.menuBg.toARGB32(),
  palette.maskColor.toARGB32(),
  palette.border.toARGB32(),
  palette.typeScreenChat.toARGB32(),
  palette.typeGift.toARGB32(),
];

void main() {
  test(悬浮窗运行时调色板初值取自主题预设，且与旧常量逐位相等, () {
    // 旧常量还在文件里，很容易被当成「拿调色板」的入口；这条钉子把运行时初值
    // 钉在主题产出上，同时保证默认外观零突变（与旧常量逐位相等）。
    final OverlayPalette initial = overlayPaletteNotifier.value;
    final OverlayPalette fromTheme = OverlayTheme.dark.toPalette();
    expect(initial.isLight, fromTheme.isLight);
    expect(_argbOf(initial), _argbOf(fromTheme));
    expect(_argbOf(initial), _argbOf(OverlayPalette.darkPalette));
  });

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
      expect(
        OverlayTheme.contrastRatio(theme.body, theme.maskColor),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.id} 主题正文对比度不足',
      );
    }
  });

  test('文字角色对比度：四套预设分别在 4.5:1 / 7:1 阈值下达标', () {
    _expectTextRoles(OverlayTheme.contrast, 7);
    _expectTextRoles(OverlayTheme.dark, 4.5);
    _expectTextRoles(OverlayTheme.sepia, 4.5);
    // 浅色预设也一并断言，而不是只把数值写在注释里：它的 secondary 是既有取值
    // Colors.black54（0x8A000000，alpha 0.5412），展平到白色蒙版后约 4.61:1——只高出
    // 4.5 线 0.11，是全项目最贴近阈值的一处取值，最需要被用例盯住。
    // PM 口径：本轮不改浅色外观（改了会破坏本 PR 的「零突变」钉子）；若这条断言将来
    // 失败，说明余量被吃掉，单开一项到第 7 轮把它换成 danmu_text_colors.dart 里的
    // 0xFF49454F，并顺带统一两处对比度口径。
    _expectTextRoles(OverlayTheme.light, 4.5);
  });
}
