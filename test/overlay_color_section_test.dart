// 第 6 轮 UX-32(D)：主 App 的悬浮窗配色设置区。
//
// 这个 widget 被单独抽成公开类就是为了能在这里直接挂载断言，不必先搭起整个设置页。
import 'package:danmu_float/ui/overlay_color_section.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('纯函数', () {
    test('withColorOverride 设置与清除，且不改动传入的 map', () {
      const Map<String, int> origin = <String, int>{'chrome': 0xFF111111};
      expect(
        withColorOverride(origin, 'body', 0xFF123456),
        <String, int>{'chrome': 0xFF111111, 'body': 0xFF123456},
      );
      expect(withColorOverride(origin, 'body', null), origin);
      expect(withColorOverride(origin, 'chrome', null), isEmpty);
      expect(origin, <String, int>{'chrome': 0xFF111111});
    });

    test('parseHexColor 只收 6 位，带不带 # 都认', () {
      expect(parseHexColor('#FF9800'), 0xFFFF9800);
      expect(parseHexColor('ff9800'), 0xFFFF9800);
      expect(parseHexColor('  #ff9800 '), 0xFFFF9800);
      // 8 位在「AARRGGBB / RRGGBBAA」上有歧义，一律拒收而不是猜。
      expect(parseHexColor('#FF9800FF'), isNull);
      expect(parseHexColor('#FF980'), isNull);
      expect(parseHexColor('紫色'), isNull);
      expect(parseHexColor(''), isNull);
    });

    test('formatHexColor 与 parseHexColor 往返一致', () {
      for (final int argb in overlayColorSwatches) {
        expect(parseHexColor(formatHexColor(argb)), argb, reason: '$argb');
      }
      expect(formatHexColor(0xFF0A0B0C), '#0A0B0C');
    });

    test('展示名与主题角色 / 预设一一对应（漏一个就会有元素改不了）', () {
      for (final String role in OverlayTheme.colorKeys) {
        expect(
          overlayColorRoleLabels.containsKey(role),
          isTrue,
          reason: '角色 $role 没有展示名',
        );
      }
      for (final OverlayTheme preset in OverlayTheme.presets) {
        expect(
          overlayThemeLabels.containsKey(preset.id),
          isTrue,
          reason: '预设 ${preset.id} 没有展示名',
        );
      }
    });

    test('候选取色全部是不透明色（半透明会被落盘层丢弃）', () {
      for (final int argb in overlayColorSwatches) {
        expect((argb >> 24) & 0xFF, 0xFF, reason: '$argb');
      }
    });
  });

  group('OverlayColorSection', () {
    /// 角色行在展开区里、可能落在视口之外：先滚到可见再点，避免 tap 打空。
    Future<void> tapVisible(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }
    Future<void> pump(
      WidgetTester tester, {
      String themeId = 'dark',
      Map<String, int> overrides = const <String, int>{},
      ValueChanged<String>? onThemeChanged,
      void Function(String role, int? argb)? onOverrideChanged,
    }) async {
      await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OverlayColorSection(
              // 本文件断言的是「用户选的色被如实展示与回报」，所以用原样显示；
              // 自动校正下的显示值由 test/overlay_color_policy_ui_test.dart 覆盖。
              contrastPolicy: 'allow',
              onContrastPolicyChanged: (String _) {},
              themeId: themeId,
              overrides: overrides,
              onThemeChanged: onThemeChanged ?? (_) {},
              onOverrideChanged: onOverrideChanged ?? (_, _) {},
            ),
          ),
        ),
      ),
      );
      // 配色区默认折叠：先展开「逐元素取色」再断言各行。
      await tester.tap(
        find.byKey(const ValueKey<String>('overlayColorSection')),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('当前主题的 chip 处于选中态，点其它 chip 回报其标识', (WidgetTester tester) async {
      String? selected;
      await pump(
        tester,
        themeId: 'sepia',
        onThemeChanged: (String id) => selected = id,
      );

      final ChoiceChip sepia = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey<String>('overlayTheme_sepia')),
      );
      expect(sepia.selected, isTrue);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey<String>('overlayTheme_dark')),
            )
            .selected,
        isFalse,
      );

      await tester.tap(find.byKey(const ValueKey<String>('overlayTheme_light')));
      expect(selected, 'light');
    });

    testWidgets('每个角色都有一行，且未覆盖时显示「跟随主题」', (WidgetTester tester) async {
      await pump(tester);
      for (final String role in OverlayTheme.colorKeys) {
        expect(
          find.byKey(ValueKey<String>('overlayRole_$role')),
          findsOneWidget,
          reason: role,
        );
      }
      expect(find.text('跟随主题'), findsNWidgets(OverlayTheme.colorKeys.length));
      expect(find.text('全部元素跟随主题'), findsOneWidget);
    });

    testWidgets('打开开关回报该角色的当前主题取值，关闭回报 null', (WidgetTester tester) async {
      final List<(String, int?)> calls = <(String, int?)>[];
      await pump(
        tester,
        onOverrideChanged: (String role, int? argb) => calls.add((role, argb)),
      );

      // 开启自定义应当以「当前主题在该角色上的取值」为起点，而不是弹一个无关颜色。
      // 这条验的是「开启/关闭自定义时该角色取什么值」，不是命中区域；真实点击路径
      // 已由取色对话框那几条用例覆盖（先 ensureVisible 再 tap）。
      tester
          .widget<Switch>(
            find.byKey(const ValueKey<String>('overlayRoleFollow_body')),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();
      expect(calls.single.$1, 'body');
      expect(
        calls.single.$2,
        OverlayTheme.dark.colorOf('body').toARGB32(),
        reason: '开启自定义时应以当前主题取值为起点，而不是弹一个无关的颜色',
      );

      calls.clear();
      await pump(
        tester,
        overrides: <String, int>{'body': 0xFF123456},
        onOverrideChanged: (String role, int? argb) => calls.add((role, argb)),
      );
      expect(find.text('#123456'), findsOneWidget);
      // 关闭自定义即回到跟随主题，回报 null。
      // 这条验的是「开启/关闭自定义时该角色取什么值」，不是命中区域；真实点击路径
      // 已由取色对话框那几条用例覆盖（先 ensureVisible 再 tap）。
      tester
          .widget<Switch>(
            find.byKey(const ValueKey<String>('overlayRoleFollow_body')),
          )
          .onChanged!(false);
      await tester.pumpAndSettle();
      expect(calls.single, ('body', null));
    });

    testWidgets('取色对话框：点候选色块回报该颜色', (WidgetTester tester) async {
      final List<(String, int?)> calls = <(String, int?)>[];
      await pump(
        tester,
        onOverrideChanged: (String role, int? argb) => calls.add((role, argb)),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey<String>('overlayRolePick_userAccent')),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择颜色'), findsNothing); // 只是 tooltip，弹窗标题是角色名
      expect(
        find.byKey(const ValueKey<String>('overlayColorHexField')),
        findsOneWidget,
      );

      final int target = overlayColorSwatches[1];
      await tester.tap(find.byKey(ValueKey<String>('overlaySwatch_$target')));
      await tester.pumpAndSettle();
      expect(calls.single, ('userAccent', target));
    });

    testWidgets('取色对话框：十六进制输入，非法不关闭并给提示，合法回报解析值', (WidgetTester tester) async {
      final List<(String, int?)> calls = <(String, int?)>[];
      await pump(
        tester,
        onOverrideChanged: (String role, int? argb) => calls.add((role, argb)),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey<String>('overlayRolePick_border')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('overlayColorHexField')),
        '#GGGGGG',
      );
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.textContaining('6 位十六进制'), findsOneWidget);
      expect(calls, isEmpty, reason: '非法输入不该关闭弹窗或回报');

      await tester.enterText(
        find.byKey(const ValueKey<String>('overlayColorHexField')),
        '#00BCD4',
      );
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(calls.single, ('border', 0xFF00BCD4));
    });

    testWidgets('取色对话框：恢复默认回报 null（即使该角色本来就有覆盖）', (WidgetTester tester) async {
      final List<(String, int?)> calls = <(String, int?)>[];
      await pump(
        tester,
        overrides: <String, int>{'divider': 0xFF00BCD4},
        onOverrideChanged: (String role, int? argb) => calls.add((role, argb)),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey<String>('overlayRolePick_divider')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('overlayColorReset')));
      await tester.pumpAndSettle();
      expect(calls.single, ('divider', null));
    });

    testWidgets('取色对话框：取消不回报任何改动', (WidgetTester tester) async {
      final List<(String, int?)> calls = <(String, int?)>[];
      await pump(
        tester,
        onOverrideChanged: (String role, int? argb) => calls.add((role, argb)),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey<String>('overlayRolePick_maskColor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
    });
  });
}
