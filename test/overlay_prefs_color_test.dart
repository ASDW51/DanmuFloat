// 第 6 轮 UX-29：悬浮窗偏好的配色字段与旧配置迁移。
//
// 单独一个文件而不是塞进 overlay_prefs_store_test.dart：那边是「已有字段的收敛与
// 往返」，这里是「新字段 + 迁移」，分开更好定位失败来源。
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('配色字段默认值', () {
    test('不传新字段时：深色主题、无覆盖、无最近色、对比度自动校正', () {
      const OverlayPrefs prefs = OverlayPrefs();
      expect(prefs.themeId, defaultOverlayThemeId);
      expect(prefs.lightTheme, isFalse);
      expect(prefs.colorOverrides, isEmpty);
      expect(prefs.recentColors, isEmpty);
      expect(prefs.contrastPolicy, defaultOverlayContrastPolicy);
    });

    test('lightTheme 由 themeId 派生，不再是可独立存储的第二处真相', () {
      expect(const OverlayPrefs(themeId: overlayThemeLightId).lightTheme, isTrue);
      expect(const OverlayPrefs(themeId: 'contrast').lightTheme, isFalse);
      expect(const OverlayPrefs(themeId: 'sepia').lightTheme, isFalse);
    });

    test('copyWith(lightTheme:) 参数保留，内部换算成 themeId（老调用点零改动）', () {
      expect(const OverlayPrefs().copyWith(lightTheme: true).themeId, 'light');
      expect(
        const OverlayPrefs(themeId: 'light').copyWith(lightTheme: false).themeId,
        'dark',
      );
      // 两者都不传时保持原值，不会被默认值冲掉。
      expect(
        const OverlayPrefs(themeId: 'sepia').copyWith(opacity: 0.5).themeId,
        'sepia',
      );
    });
  });

  group('旧配置迁移', () {
    test('没有 themeId 的老 JSON：由 lightTheme 推导，外观与升级前一致', () {
      final OverlayPrefs? dark = OverlayPrefs.tryParse(<String, Object?>{
        'opacity': 0.5,
        'lightTheme': false,
      });
      expect(dark?.themeId, 'dark');
      expect(dark?.lightTheme, isFalse);

      final OverlayPrefs? light = OverlayPrefs.tryParse(<String, Object?>{
        'lightTheme': true,
      });
      expect(light?.themeId, 'light');
      expect(light?.lightTheme, isTrue);
    });

    test('连 lightTheme 都缺字段的老 JSON：回落深色', () {
      expect(OverlayPrefs.tryParse(<String, Object?>{})?.themeId, 'dark');
    });

    test('未知 themeId：原样保留，渲染侧回落深色而不是崩或半残', () {
      final OverlayPrefs? prefs = OverlayPrefs.tryParse(<String, Object?>{
        'themeId': '来自未来的皮肤',
      });
      expect(prefs?.themeId, '来自未来的皮肤');
      expect(OverlayTheme.preset(prefs!.themeId).id, 'dark');
    });

    test('栏级 textColor 继续保留：它是 body 的栏级覆盖，优先级高于主题', () {
      final OverlayPrefs? prefs = OverlayPrefs.tryParse(<String, Object?>{
        'panes': <Map<String, Object?>>[
          <String, Object?>{
            'index': 0,
            'room_id': '123',
            'textColor': 0xFFFFEB3B,
          },
        ],
      });
      expect(prefs?.paneStyles['123']?.textColor, 0xFFFFEB3B);
      expect(prefs?.themeId, 'dark');
    });
  });

  group('非法输入兜底', () {
    test('colorOverrides 逐键丢弃非法值，合法项照常生效', () {
      final OverlayPrefs? prefs = OverlayPrefs.tryParse(<String, Object?>{
        'colorOverrides': <Object?, Object?>{
          'body': 0xFF123456,
          'userAccent': 0x80123456, // 半透明：判非法
          'chrome': -1, // 越界：判非法
          'levelColor': 'not a color', // 类型不对：判非法
          42: 0xFF654321, // 键不是字符串：判非法
          'divider': 0xFFABCDEF,
        },
      });
      expect(prefs?.colorOverrides, <String, int>{
        'body': 0xFF123456,
        'divider': 0xFFABCDEF,
      });
    });

    test('colorOverrides 不是 Map 时视为空表', () {
      expect(
        OverlayPrefs.tryParse(<String, Object?>{'colorOverrides': 'x'})
            ?.colorOverrides,
        isEmpty,
      );
    });

    test('recentColors 过滤非法值、去重，并截到上限', () {
      final OverlayPrefs? prefs = OverlayPrefs.tryParse(<String, Object?>{
        'recentColors': <Object?>[
          0xFF111111,
          0x80111111, // 半透明：丢弃
          'x', // 类型不对：丢弃
          0xFF111111, // 重复：去重
          for (int i = 0; i < 20; i++) 0xFF200000 + i,
        ],
      });
      final List<int> recent = prefs!.recentColors;
      expect(recent.first, 0xFF111111);
      expect(recent.length, maxRecentOverlayColors);
      expect(recent.toSet().length, recent.length);
    });

    test('contrastPolicy 非法值回落 adjust', () {
      expect(
        OverlayPrefs.tryParse(<String, Object?>{'contrastPolicy': '乱写'})
            ?.contrastPolicy,
        defaultOverlayContrastPolicy,
      );
      expect(
        OverlayPrefs.tryParse(<String, Object?>{'contrastPolicy': 'warn'})
            ?.contrastPolicy,
        'warn',
      );
      expect(clampOverlayContrastPolicy(null), defaultOverlayContrastPolicy);
      expect(clampOverlayContrastPolicy('allow'), 'allow');
    });
  });

  test('落盘往返：新字段全部原样还原（data_transfer 走同一对编解码）', () {
    const OverlayPrefs prefs = OverlayPrefs(
      themeId: 'sepia',
      colorOverrides: <String, int>{'body': 0xFFE8DFD0, 'userAccent': 0xFFA8C7E8},
      recentColors: <int>[0xFFE8DFD0, 0xFFA8C7E8],
      contrastPolicy: 'warn',
    );
    final OverlayPrefs? restored = decodeOverlayPrefs(encodeOverlayPrefs(prefs));
    expect(restored?.themeId, 'sepia');
    expect(restored?.colorOverrides, prefs.colorOverrides);
    expect(restored?.recentColors, prefs.recentColors);
    expect(restored?.contrastPolicy, 'warn');
    expect(restored?.lightTheme, isFalse);
    // 旧字段照旧写出来，供旧版本回滚读取。
    expect(encodeOverlayPrefs(prefs).contains('"lightTheme"'), isTrue);
    expect(encodeOverlayPrefs(prefs).contains('"schemaVersion"'), isTrue);
  });
}
