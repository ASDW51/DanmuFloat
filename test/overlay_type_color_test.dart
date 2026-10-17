// 第 8 轮 ④：各类型弹幕色由 OverlayTheme 逐预设给出，不再按 isLight 猜。
//
// 钉子：dark/light 必须与原取值表逐位相等（外观零突变）；sepia 必须整组换掉——
// 它此前继承深色皮肤的亮色，暖暗底上顶着刺眼前缀，护眼主题在类型弹幕这条路上是半成品。
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const Map<String, int> kinds = <String, int>{
    'screenChat': 0,
    'privilegeScreenChat': 1,
    'gift': 2,
    'member': 3,
    'like': 4,
    'social': 5,
    'roomRank': 6,
  };
  const List<Color> darkRef = <Color>[
    Colors.orangeAccent, Colors.lightGreenAccent, Colors.pinkAccent, Colors.tealAccent,
    Colors.redAccent, Colors.lightBlueAccent, Colors.amberAccent,
  ];
  const List<int> lightRef = <int>[
    0xFFB33A00, 0xFF2E7D32, 0xFFC2185B, 0xFF00695C, 0xFFC62828, 0xFF1565C0, 0xFF8D6E00,
  ];

  List<Color?> colorsOf(OverlayPalette p) => kinds.keys
      .map((String name) => p.typeColor(DanmakuKind.values.byName(name)))
      .toList();

  test('dark：与原来的取值表逐位相等', () {
    final List<Color?> got = colorsOf(OverlayPalette.darkPalette);
    for (int i = 0; i < got.length; i++) {
      expect(got[i]!.toARGB32(), darkRef[i].toARGB32(), reason: '第 $i 个');
    }
    // 直接与主题字段对齐，防「常量对了但没接进 toPalette」。
    expect(
      OverlayTheme.dark.toPalette().typeColor(DanmakuKind.gift)!.toARGB32(),
      Colors.pinkAccent.toARGB32(),
    );
  });

  test('light：与原来的取值表逐位相等', () {
    final List<Color?> got = colorsOf(OverlayPalette.lightPalette);
    for (int i = 0; i < got.length; i++) {
      expect(got[i]!.toARGB32(), lightRef[i], reason: '第 $i 个');
    }
  });

  test('护眼：整组与深色皮肤逐位不同，且组内两两不同', () {
    final List<Color?> dark = colorsOf(OverlayPalette.darkPalette);
    final List<Color?> sepia = colorsOf(OverlayTheme.sepia.toPalette());
    for (int i = 0; i < sepia.length; i++) {
      expect(sepia[i]!.toARGB32(), isNot(dark[i]!.toARGB32()), reason: '第 $i 个不应继承深色');
    }
    final Set<int> uniq = sepia.map((Color? c) => c!.toARGB32()).toSet();
    expect(uniq.length, sepia.length);
  });

  test('护眼：7 个类型色对自身 maskColor 均不低于 4.5:1', () {
    final OverlayTheme t = OverlayTheme.sepia;
    for (final Color? c in colorsOf(t.toPalette())) {
      expect(OverlayTheme.contrastRatio(c!, t.maskColor), greaterThanOrEqualTo(4.5));
    }
  });

  test('未登记的类型仍返回 null', () {
    int nonNull = 0;
    for (final DanmakuKind kind in DanmakuKind.values) {
      if (OverlayPalette.darkPalette.typeColor(kind) != null) nonNull++;
    }
    expect(nonNull, 7, reason: '只有这 7 类有专属色，其余走正文色');
  });

  test('类型色随主题变、不随角色覆盖变', () {
    final OverlayTheme themed = OverlayTheme.sepia.resolve(<String, int>{
      'body': 0xFF00FF00,
    });
    expect(
      themed.toPalette().typeColor(DanmakuKind.gift)!.toARGB32(),
      OverlayTheme.sepia.typeGift.toARGB32(),
    );
    expect(
      themed.toPalette().body.toARGB32(),
      0xFF00FF00,
      reason: '覆盖它自己该生效的部分仍要生效',
    );
  });

  test('两个角色集的口径：进 colorKeys、不进 textColorKeys', () {
    for (final String r in <String>['typeGift', 'typeRoomRank']) {
      expect(OverlayTheme.colorKeys, contains(r));
      expect(OverlayTheme.textColorKeys, isNot(contains(r)));
    }
  });
}
