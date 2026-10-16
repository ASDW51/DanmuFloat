// #98：config 消息也要携带完整皮肤（themeId / colorOverrides / contrastPolicy）。
//
// 既有 test/overlay_bridge_test.dart 一行不改（沿用 UX-30 定下的验收口径），新行为在这里钉：
// config 是「重排路径」（首页删除在播主播 → resizeOverlay）唯一的消息，不带皮肤就会把
// sepia / contrast 静默换成 dark，而磁盘上仍是 sepia。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('config 消息携带皮肤（#98）', () {
    test('4 套预设经 config 往返都不丢主题', () {
      for (final String themeId in <String>[
        overlayStyleDarkThemeId,
        overlayStyleLightThemeId,
        'contrast',
        'sepia',
      ]) {
        final OverlayConfig config = OverlayConfig(
          webRids: const <String>['12345'],
          lightTheme: themeId == overlayStyleLightThemeId,
          themeId: themeId,
          colorOverrides: const <String, int>{'body': 0xFF112233},
          contrastPolicy: overlayStyleWarnPolicy,
        );

        final OverlayConfig? parsed = OverlayConfig.tryParse(config.toJson());

        expect(
          parsed?.themeId,
          themeId,
          reason: '$themeId 不能在 config 路径上被折算成 dark/light',
        );
        expect(parsed?.colorOverrides, <String, int>{'body': 0xFF112233});
        expect(parsed?.contrastPolicy, overlayStyleWarnPolicy);
      }
    });

    test('老 payload 没有这三个键时行为与升级前一致', () {
      final OverlayConfig? light = OverlayConfig.tryParse(<String, Object?>{
        'type': overlayConfigType,
        'webRids': <String>['12345'],
        'lightTheme': true,
      });
      expect(light?.themeId, overlayStyleLightThemeId);
      expect(light?.colorOverrides, isEmpty);
      expect(light?.contrastPolicy, overlayStyleAdjustPolicy);

      // sepia 属深色系：只有 lightTheme 时仍是 dark，必须靠显式 themeId 才带得动。
      final OverlayConfig? sepia = OverlayConfig.tryParse(<String, Object?>{
        'type': overlayConfigType,
        'webRids': <String>['12345'],
        'lightTheme': false,
        'themeId': 'sepia',
      });
      expect(sepia?.themeId, 'sepia');
    });

    test('toConfig 一定带上主题三件套，重排路径不会换肤（#98）', () {
      const OverlayPrefs prefs = OverlayPrefs(
        themeId: 'sepia',
        colorOverrides: <String, int>{'body': 0xFFE8DFD0},
        contrastPolicy: overlayStyleWarnPolicy,
      );

      final OverlayConfig config = prefs.toConfig(const <String>['12345']);
      expect(config.themeId, 'sepia');
      expect(config.colorOverrides, <String, int>{'body': 0xFFE8DFD0});
      expect(config.contrastPolicy, overlayStyleWarnPolicy);

      // 往返一次仍一致：磁盘上的 themeId 与窗口实际渲染的那份不再各说各话。
      final OverlayConfig? reparsed = OverlayConfig.tryParse(config.toJson());
      expect(reparsed?.themeId, 'sepia');
      expect(reparsed?.colorOverrides, <String, int>{'body': 0xFFE8DFD0});
    });

    test('resolveThemeId：显式主题优先，老 payload 由 lightTheme 推导', () {
      expect(resolveThemeId(themeId: 'sepia', lightTheme: false), 'sepia');
      expect(resolveThemeId(themeId: 'contrast', lightTheme: true), 'contrast');
      expect(
        resolveThemeId(themeId: null, lightTheme: true),
        overlayStyleLightThemeId,
      );
      expect(
        resolveThemeId(themeId: '   ', lightTheme: false),
        overlayStyleDarkThemeId,
      );
    });
  });
}
