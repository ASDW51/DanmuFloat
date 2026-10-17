import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/ui/danmu_text_colors.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 相对亮度对比度（与 `Color.computeLuminance()` 同口径）。
double contrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double high = la > lb ? la : lb;
  final double low = la > lb ? lb : la;
  return (high + 0.05) / (low + 0.05);
}

/// 弹幕列表 / 进场行的实际底色：与页面用同一套 M3 colorScheme。
Color surfaceOf(Brightness brightness) =>
    ThemeData(brightness: brightness).colorScheme.surface;

void main() {
  group('主 App 弹幕语义色（#138）', () {
    for (final Brightness brightness in Brightness.values) {
      final Color surface = surfaceOf(brightness);

      test('$brightness 下昵称 / 等级 / 灯牌 / 凭证名对列表底色都 ≥4.5:1', () {
        expect(
          contrastRatio(nicknameColor(brightness), surface),
          greaterThanOrEqualTo(4.5),
          reason: '昵称',
        );
        expect(
          contrastRatio(levelTextColor(brightness), surface),
          greaterThanOrEqualTo(4.5),
          reason: '等级 Lv.N',
        );
        expect(
          contrastRatio(fanBadgeColor(brightness), surface),
          greaterThanOrEqualTo(4.5),
          reason: '灯牌',
        );
        expect(
          contrastRatio(credentialTextColor(brightness), surface),
          greaterThanOrEqualTo(4.5),
          reason: '凭证名',
        );
      });

      test('$brightness 下 7 类类型前缀色对列表底色都 ≥4.5:1', () {
        for (final DanmakuKind kind in <DanmakuKind>[
          DanmakuKind.screenChat,
          DanmakuKind.privilegeScreenChat,
          DanmakuKind.gift,
          DanmakuKind.member,
          DanmakuKind.like,
          DanmakuKind.social,
          DanmakuKind.roomRank,
        ]) {
          expect(
            contrastRatio(danmuTypeColor(kind, brightness), surface),
            greaterThanOrEqualTo(4.5),
            reason: '${kind.name} 前缀色',
          );
        }
      });
    }

    test('头像底色与头像里的白字在两套主题下都 ≥4.5:1', () {
      final Color foreground = roomAvatarForegroundColor();
      for (final bool? living in <bool?>[true, false, null]) {
        expect(
          contrastRatio(roomAvatarBackgroundColor(living: living), foreground),
          greaterThanOrEqualTo(4.5),
          reason: 'living=$living 的头像',
        );
      }
    });

    test('类型前缀色直接取自 OverlayTheme，不再有第二份色表', () {
      final OverlayTheme dark = OverlayTheme.preset(defaultOverlayThemeId);
      final OverlayTheme light = OverlayTheme.preset(overlayStyleLightThemeId);
      expect(
        danmuTypeColor(DanmakuKind.screenChat, Brightness.dark),
        dark.typeScreenChat,
      );
      expect(
        danmuTypeColor(DanmakuKind.privilegeScreenChat, Brightness.dark),
        dark.typePrivilegeScreenChat,
      );
      expect(danmuTypeColor(DanmakuKind.gift, Brightness.dark), dark.typeGift);
      expect(
        danmuTypeColor(DanmakuKind.member, Brightness.dark),
        dark.typeMember,
      );
      expect(danmuTypeColor(DanmakuKind.like, Brightness.dark), dark.typeLike);
      expect(
        danmuTypeColor(DanmakuKind.social, Brightness.dark),
        dark.typeSocial,
      );
      expect(
        danmuTypeColor(DanmakuKind.roomRank, Brightness.dark),
        dark.typeRoomRank,
      );
      expect(
        danmuTypeColor(DanmakuKind.screenChat, Brightness.light),
        light.typeScreenChat,
      );
      expect(
        danmuTypeColor(DanmakuKind.roomRank, Brightness.light),
        light.typeRoomRank,
      );
    });

    test('不显示前缀的类型走兜底色，不会抛', () {
      expect(
        danmuTypeColor(DanmakuKind.chat, Brightness.light),
        secondaryTextColor(Brightness.light),
      );
    });
  });
}
