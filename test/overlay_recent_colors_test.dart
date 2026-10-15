// 第 7 轮 ②：「最近使用」色。
//
// 入库时机是**确认采用时**：色块 tap 与十六进制「应用」本就是同一个确认点，
// 取消（对话框返回 null）与「恢复默认」都不入库。
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/overlay_color_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('recordRecentColor', () {
    test('新色置顶：连续记录 9 个不同色后只留 8 个，最新在首位', () {
      List<int> recent = const <int>[];
      for (int i = 0; i < 9; i++) {
        recent = recordRecentColor(recent, 0xFF000000 + i);
      }
      expect(recent.length, maxRecentOverlayColors);
      expect(recent.first, 0xFF000008);
      // 最早那个被挤掉，其余保持「越新越前」。
      expect(recent, isNot(contains(0xFF000000)));
      expect(recent[1], 0xFF000007);
    });

    test('重复色只是移到最前，不产生新条目', () {
      final List<int> recent = recordRecentColor(
        <int>[0xFFAAAAAA, 0xFFBBBBBB],
        0xFFBBBBBB,
      );
      expect(recent, <int>[0xFFBBBBBB, 0xFFAAAAAA]);
    });

    test('非不透明色与越界值一律不收', () {
      const List<int> base = <int>[0xFF123456];
      expect(recordRecentColor(base, 0x80123456), base);
      expect(recordRecentColor(base, -1), base);
      expect(recordRecentColor(base, 0x1FFFFFFFF), base);
    });

    test('落盘往返仍保留最近色', () {
      final OverlayPrefs prefs = OverlayPrefs(
        recentColors: <int>[0xFF112233, 0xFF445566],
      );
      final OverlayPrefs? parsed = OverlayPrefs.tryParse(prefs.toJson());
      expect(parsed?.recentColors, <int>[0xFF112233, 0xFF445566]);
    });
  });

  group('取色弹窗里的最近使用', () {
    Future<void> pumpSection(
      WidgetTester tester,
      List<int> recent,
      void Function(String role, int? argb) onChanged,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OverlayColorSection(
                themeId: 'dark',
                overrides: const <String, int>{},
                recentColors: recent,
                contrastPolicy: 'allow',
                onThemeChanged: (String _) {},
                onOverrideChanged: onChanged,
                onContrastPolicyChanged: (String _) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('overlayColorSection')));
      await tester.pumpAndSettle();
    }

    testWidgets('点最近使用的色块即采用，并回报该颜色', (WidgetTester tester) async {
      final List<(String, int?)> calls = <(String, int?)>[];
      await pumpSection(tester, <int>[0xFF00BCD4], (String r, int? a) {
        calls.add((r, a));
      });
      final Finder pick = find.byKey(
        const ValueKey<String>('overlayRolePick_body'),
      );
      await tester.ensureVisible(pick);
      await tester.pumpAndSettle();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(find.text('最近使用'), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey<String>('overlayRecent_${0xFF00BCD4}')),
      );
      await tester.pumpAndSettle();
      expect(calls.single, ('body', 0xFF00BCD4));
    });

    testWidgets('没有最近色时不渲染这一块', (WidgetTester tester) async {
      await pumpSection(tester, const <int>[], (String r, int? a) {});
      final Finder pick = find.byKey(
        const ValueKey<String>('overlayRolePick_body'),
      );
      await tester.ensureVisible(pick);
      await tester.pumpAndSettle();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(find.text('最近使用'), findsNothing);
    });
  });
}
