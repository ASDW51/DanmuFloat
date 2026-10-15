// 第 6 轮 UX-33(F) 第一步：偏好增量（patch）也能携带主题与角色覆盖。
//
// 「窗内改配色」要经悬浮球菜单回报给主 App，这条链路必须区分「没改」与「清空」。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OverlayPrefsPatch 的主题字段', () {
    test('往返一致', () {
      const OverlayPrefsPatch patch = OverlayPrefsPatch(
        themeId: 'sepia',
        colorOverrides: <String, int>{'body': 0xFFE8DFD0},
      );
      final OverlayPrefsPatch? parsed = OverlayPrefsPatch.tryParse(
        patch.toJson(),
      );
      expect(parsed?.themeId, 'sepia');
      expect(parsed?.colorOverrides, <String, int>{'body': 0xFFE8DFD0});
    });

    test('只有主题也算「有改动」，空 patch 仍然是空', () {
      expect(const OverlayPrefsPatch(themeId: 'light').isEmpty, isFalse);
      expect(
        const OverlayPrefsPatch(colorOverrides: <String, int>{}).isEmpty,
        isFalse,
      );
      expect(const OverlayPrefsPatch().isEmpty, isTrue);
      expect(OverlayPrefsPatch.tryParse(<String, Object?>{}), isNull);
    });

    test('缺 colorOverrides 键时解析为 null（「没改」），而非空表（「清空」）', () {
      final OverlayPrefsPatch? parsed = OverlayPrefsPatch.tryParse(
        <String, Object?>{'themeId': 'contrast'},
      );
      expect(parsed?.themeId, 'contrast');
      expect(parsed?.colorOverrides, isNull);

      final OverlayPrefsPatch? cleared = OverlayPrefsPatch.tryParse(
        <String, Object?>{'colorOverrides': <String, Object?>{}},
      );
      expect(cleared?.colorOverrides, isEmpty);
      expect(cleared?.colorOverrides, isNotNull);
    });

    test('非法颜色逐键丢弃；非字符串主题标识视为没改', () {
      final OverlayPrefsPatch? parsed = OverlayPrefsPatch.tryParse(
        <String, Object?>{
          'themeId': 42,
          'colorOverrides': <String, Object?>{
            'body': 0xFF112233,
            'chrome': 0x80112233,
          },
        },
      );
      expect(parsed?.themeId, isNull);
      expect(parsed?.colorOverrides, <String, int>{'body': 0xFF112233});
    });
  });

  group('appliedPatch 合并', () {
    test('patch 里的主题与覆盖生效，其余字段保持', () {
      const OverlayPrefs base = OverlayPrefs(
        themeId: 'dark',
        colorOverrides: <String, int>{'body': 0xFF111111},
        opacity: 0.5,
      );
      final OverlayPrefs merged = base.appliedPatch(
        const OverlayPrefsPatch(
          themeId: 'sepia',
          colorOverrides: <String, int>{'body': 0xFFE8DFD0},
        ),
      );
      expect(merged.themeId, 'sepia');
      expect(merged.colorOverrides, <String, int>{'body': 0xFFE8DFD0});
      expect(merged.opacity, 0.5);
    });

    test('patch 没带主题字段时不动现有取值（避免冲掉主 App 里的自定义）', () {
      const OverlayPrefs base = OverlayPrefs(
        themeId: 'contrast',
        colorOverrides: <String, int>{'chrome': 0xFF222222},
      );
      final OverlayPrefs merged = base.appliedPatch(
        const OverlayPrefsPatch(opacity: 0.8),
      );
      expect(merged.themeId, 'contrast');
      expect(merged.colorOverrides, <String, int>{'chrome': 0xFF222222});
    });

    test('显式传空表才是清空覆盖（回到全部跟随主题）', () {
      const OverlayPrefs base = OverlayPrefs(
        colorOverrides: <String, int>{'chrome': 0xFF222222},
      );
      final OverlayPrefs merged = base.appliedPatch(
        const OverlayPrefsPatch(colorOverrides: <String, int>{}),
      );
      expect(merged.colorOverrides, isEmpty);
    });
  });
}
