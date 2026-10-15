// 第 7 轮 ⑤：对比度策略要真正作用于悬浮窗渲染，而不是停在偏好字段里。
//
// 背景：第 6 轮把 contrastPolicy 落进了偏好，但窗内调色板构造处从未调用
// enforceTextContrast，adjust/warn/allow 三态没有任何运行时效果。本文件钉住
// 「策略经过消息通道到达窗内」与「adjust 下渲染值确实达标」这两件事。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('对比度策略经 style 通道下发', () {
    test('三态都能往返，未知值回落到 adjust', () {
      for (final String policy in <String>['adjust', 'warn', 'allow']) {
        // tryParse 的前置条件是 raw[type] == overlayStyleType 且 opacity 为数值，
        // 缺任一项直接返回 null（真实 payload 由 shareOverlayStyle 发全量，必然满足）。
        final OverlayStyle? style = OverlayStyle.tryParse(<String, Object?>{
          'type': overlayStyleType,
          'opacity': 0.8,
          'contrastPolicy': policy,
        });
        expect(style?.contrastPolicy, policy);
        expect(style?.toJson()['contrastPolicy'], policy);
      }
      expect(
        OverlayStyle.tryParse(<String, Object?>{
          'type': overlayStyleType,
          'opacity': 0.8,
          'contrastPolicy': 'bogus',
        })
            ?.contrastPolicy,
        overlayStyleAdjustPolicy,
      );
    });

    test('老 payload 没有该字段时默认 adjust', () {
      final OverlayStyle? style = OverlayStyle.tryParse(<String, Object?>{
        'type': overlayStyleType,
        'opacity': 0.8,
        'lightTheme': false,
      });
      expect(style?.contrastPolicy, overlayStyleAdjustPolicy);
    });

    test('存储层的钳制转发到桥接层白名单', () {
      expect(clampOverlayContrastPolicy('allow'), 'allow');
      expect(clampOverlayContrastPolicy('warn'), 'warn');
      expect(clampOverlayContrastPolicy('nope'), defaultOverlayContrastPolicy);
      expect(clampOverlayContrastPolicy(null), defaultOverlayContrastPolicy);
    });
  });

  group('策略对渲染取值的作用', () {
    const int nearBlack = 0xFF111111;

    test('adjust：不可读的自定义色被校正到 ≥4.5:1，且色相不变', () {
      final OverlayTheme base = OverlayTheme.dark.resolve(<String, int>{
        'body': nearBlack,
      });
      // 窗内 _palette 在 adjust 下做的就是这一步。
      // 只取 Color：本文件不导入 OverlayPalette 的声明库，避免为一个类型名拉进整个页面。
      final Color rendered = base.enforceTextContrast(4.5).toPalette().body;
      expect(
        OverlayTheme.contrastRatio(rendered, OverlayTheme.dark.maskColor),
        greaterThanOrEqualTo(4.5),
      );
      // 守卫只动 HSV 的 value：色相必须保持，否则「我选的色怎么变样了」。
      expect(
        HSVColor.fromColor(rendered).hue,
        closeTo(HSVColor.fromColor(const Color(nearBlack)).hue, 0.5),
      );
    });

    test('warn/allow：不经过守卫，用户选色原样渲染', () {
      final Color asIs = OverlayTheme.dark
          .resolve(<String, int>{'body': nearBlack})
          .toPalette()
          .body;
      expect(asIs, const Color(nearBlack));
    });

    test('合规的取值在 adjust 下保持不变（守卫是幂等的）', () {
      final OverlayTheme base = OverlayTheme.dark.resolve(<String, int>{
        'body': 0xFFFFFFFF,
      });
      expect(identical(base.enforceTextContrast(4.5), base), isTrue);
    });
  });
}
