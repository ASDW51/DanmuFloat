// 第 6 轮 UX-33(I)：悬浮窗状态点与弹幕页共用同一套状态色。
//
// 此前 overlay_page 自带一套 light/dark 取值、danmu_page 走 stageTextColor，同一个
// 连接状态在两处是两种颜色；这里把「只有一份实现」及其可读性钉住。
import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/ui/danmu_text_colors.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('悬浮窗状态点与弹幕页共用状态色（I）', () {
    test('四套预设下每种状态色对窗口底色都达标', () {
      for (final OverlayTheme theme in OverlayTheme.presets) {
        final Brightness brightness = theme.isLight
            ? Brightness.light
            : Brightness.dark;
        for (final LiveSessionStage stage in LiveSessionStage.values) {
          expect(
            OverlayTheme.contrastRatio(
              stageTextColor(stage, brightness),
              theme.maskColor,
            ),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.id} 主题下 $stage 的状态色不可读',
          );
        }
      }
    });

    test('浅色 live 取值是有意变更：与弹幕页同为 0xFF1B5E20（旧悬浮窗为 0xFF2E7D32）', () {
      expect(
        stageTextColor(LiveSessionStage.live, Brightness.light),
        const Color(0xFF1B5E20),
      );
    });

    test('深色与浅色两套取值不同，避免「浅色皮肤下用了原色」这类老问题', () {
      for (final LiveSessionStage stage in LiveSessionStage.values) {
        expect(
          stageTextColor(stage, Brightness.light),
          isNot(stageTextColor(stage, Brightness.dark)),
          reason: '$stage 的深浅两套取值不应相同',
        );
      }
    });
  });
}
