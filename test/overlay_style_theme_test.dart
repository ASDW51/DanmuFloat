// 第 6 轮 UX-30：style 消息携带 themeId / colorOverrides 的兼容性。
//
// 既有 test/overlay_bridge_test.dart 一行不改（PM 验收口径），新行为在这里钉。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('style 消息携带主题（UX-30）', () {
    test('老 payload 没有 themeId：由 lightTheme 推导，语义与旧版一致', () {
      final OverlayStyle? dark = OverlayStyle.tryParse(<String, Object?>{
        'type': overlayStyleType,
        'opacity': 0.6,
        'lightTheme': false,
      });
      expect(dark?.themeId, overlayStyleDarkThemeId);
      expect(dark?.colorOverrides, isEmpty);
      expect(dark?.lightTheme, isFalse);

      final OverlayStyle? light = OverlayStyle.tryParse(<String, Object?>{
        'type': overlayStyleType,
        'opacity': 0.6,
        'lightTheme': true,
      });
      expect(light?.themeId, overlayStyleLightThemeId);
      expect(light?.lightTheme, isTrue);
    });

    test('新字段往返一致', () {
      final OverlayStyle style = OverlayStyle(
        opacity: 0.6,
        themeId: 'sepia',
        colorOverrides: const <String, int>{'body': 0xFFE8DFD0},
      );
      final OverlayStyle? parsed = OverlayStyle.tryParse(style.toJson());
      expect(parsed?.themeId, 'sepia');
      expect(parsed?.colorOverrides, <String, int>{'body': 0xFFE8DFD0});
      // 旧键照旧写出来，旧版本回滚时仍能还原深浅。
      expect(style.toJson()['lightTheme'], isFalse);
    });

    test('未知 themeId 原样保留（渲染侧回落深色），非法颜色逐键丢弃', () {
      final OverlayStyle? parsed = OverlayStyle.tryParse(<String, Object?>{
        'type': overlayStyleType,
        'opacity': 0.6,
        'themeId': '来自未来的皮肤',
        'colorOverrides': <Object?, Object?>{
          'body': 0xFF112233,
          'userAccent': 0x80112233, // 半透明：判非法
          'chrome': 'x', // 类型不对：判非法
          7: 0xFF445566, // 键不是字符串：判非法
        },
      });
      expect(parsed?.themeId, '来自未来的皮肤');
      expect(parsed?.colorOverrides, <String, int>{'body': 0xFF112233});
    });

    test('多出额外键不影响既有字段的解析（前后版本互不阻塞）', () {
      final OverlayStyle? parsed = OverlayStyle.tryParse(<String, Object?>{
        'type': overlayStyleType,
        'opacity': 0.42,
        'fontSize': 18.0,
        'themeId': 'contrast',
        'colorOverrides': <String, int>{'body': 0xFF00FF00},
        '未来才有的键': 123,
      });
      expect(parsed?.opacity, 0.42);
      expect(parsed?.fontSize, 18.0);
      expect(parsed?.themeId, 'contrast');
      expect(parsed?.colorOverrides, <String, int>{'body': 0xFF00FF00});
    });

    test('parseColorOverrides 是下发与落盘的唯一实现：边界与落盘层一致', () {
      expect(parseColorOverrides(null), isEmpty);
      expect(parseColorOverrides('x'), isEmpty);
      expect(
        parseColorOverrides(<String, Object?>{'body': 0xFF000000}),
        <String, int>{'body': 0xFF000000},
      );
      expect(parseColorOverrides(<String, Object?>{'body': 0x00FFFFFF}), isEmpty);
      expect(parseColorOverrides(<String, Object?>{'': 0xFF000000}), isEmpty);
      expect(parseColorOverrides(<String, Object?>{'body': -1}), isEmpty);
    });
  });
}
