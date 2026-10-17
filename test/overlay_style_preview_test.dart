// 设置页样式预览卡（#143）的验收用例。
//
// 钉死一件事：预览卡上显示的颜色 == 悬浮窗实际渲染用的颜色。
// 所以每条断言都拿 `OverlayTheme.preset(themeId).resolve(overrides).toPalette()`
// 的对应角色去比，而不是比某个写死的色值——一旦有人把颜色硬编码进卡片，这里立刻红。
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/ui/overlay_style_preview.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 取出某一行预览弹幕的富文本片段。
List<InlineSpan> _spansOf(WidgetTester tester, String key) {
  final Text text = tester.widget<Text>(
    find.descendant(
      of: find.byKey(ValueKey<String>(key)),
      matching: find.byType(Text),
    ),
  );
  final InlineSpan? span = text.textSpan;
  expect(span, isA<TextSpan>());
  return (span! as TextSpan).children ?? const <InlineSpan>[];
}

Color? _colorAt(WidgetTester tester, String key, int index) {
  final InlineSpan span = _spansOf(tester, key)[index];
  return (span as TextSpan).style?.color;
}

Future<void> _pumpPreview(
  WidgetTester tester, {
  required String themeId,
  Map<String, int> overrides = const <String, int>{},
  double opacity = 0.8,
  double fontSize = 13,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OverlayStylePreview(
          themeId: themeId,
          overrides: overrides,
          opacity: opacity,
          fontSize: fontSize,
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('设置页样式预览卡（#143）', () {
    for (final String themeId in <String>[
      'dark',
      'light',
      'contrast',
      'sepia',
    ]) {
      testWidgets('$themeId 预设：预览卡正文 / 昵称 / 类型色与主题解析结果一致',
          (WidgetTester tester) async {
        await _pumpPreview(tester, themeId: themeId);

        final OverlayPalette palette =
            OverlayTheme.preset(themeId).resolve(<String, int>{}).toPalette();

        // 普通弹幕行：[0] 昵称、[1] 正文。
        expect(_colorAt(tester, 'overlayPreviewChat', 0), palette.userAccent);
        expect(_colorAt(tester, 'overlayPreviewChat', 1), palette.body);

        // 礼物行：[0] 类型前缀、[1] 等级、[2] 灯牌、[3] 正文。
        expect(
          _colorAt(tester, 'overlayPreviewGift', 0),
          palette.typeColor(DanmakuKind.gift),
        );
        expect(_colorAt(tester, 'overlayPreviewGift', 1), palette.levelColor);
        expect(_colorAt(tester, 'overlayPreviewGift', 2), palette.fanLevelColor);
        expect(_colorAt(tester, 'overlayPreviewGift', 3), palette.body);
      });
    }

    testWidgets('角色级覆盖会同时作用到预览卡（改完配色立刻可见）',
        (WidgetTester tester) async {
      const int customBody = 0xFF102030;
      await _pumpPreview(
        tester,
        themeId: 'dark',
        overrides: const <String, int>{'body': customBody},
      );

      final OverlayPalette palette = OverlayTheme.preset('dark')
          .resolve(const <String, int>{'body': customBody})
          .toPalette();
      expect(palette.body.toARGB32(), customBody);
      expect(_colorAt(tester, 'overlayPreviewChat', 1), palette.body);
      expect(_colorAt(tester, 'overlayPreviewChat', 1)!.toARGB32(), customBody);
    });

    testWidgets('透明度与字号直接参与预览，调完立刻能看出差别',
        (WidgetTester tester) async {
      await _pumpPreview(tester, themeId: 'dark', opacity: 0.35, fontSize: 20);

      final OverlayPalette palette =
          OverlayTheme.preset('dark').resolve(<String, int>{}).toPalette();
      final InlineSpan highlight = _spansOf(tester, 'overlayPreviewHighlight')[0];
      expect(
        (highlight as TextSpan).style?.backgroundColor,
        palette.maskColor.withValues(alpha: 0.35),
        reason: '蒙版透明度必须真的进到预览里，否则「调了看不到效果」依旧',
      );

      final Text giftText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('overlayPreviewGift')),
          matching: find.byType(Text),
        ),
      );
      expect((giftText.textSpan! as TextSpan).style?.fontSize, 20);
    });

    testWidgets('未知主题标识回落深色，不抛', (WidgetTester tester) async {
      await _pumpPreview(tester, themeId: 'no-such-theme');
      expect(tester.takeException(), isNull);
      final OverlayPalette palette =
          OverlayTheme.preset('dark').resolve(<String, int>{}).toPalette();
      expect(_colorAt(tester, 'overlayPreviewChat', 1), palette.body);
    });
  });
}
