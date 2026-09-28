// 过滤设置二级页（prd F10 / F11 / F13）：正则开关、教程区、规则编辑与类型多选。
//
// 落盘走可注入目录，测试不依赖 path_provider 插件通道。
import 'dart:io';

import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/filter_page.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('设置页的「屏蔽与高亮」入口跳转到过滤二级页', (WidgetTester tester) async {
    _useTallScreen(tester);
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(prefs: const OverlayPrefs(), onChanged: _noop),
    ));
    await tester.pumpAndSettle();

    expect(find.text('屏蔽关键词 / 屏蔽用户 / 高亮词'), findsOneWidget);
    // 入口行摘要显示当前规模，便于不进页面就知道有没有配置过。
    expect(find.text('屏蔽 0 词 / 0 用户 · 高亮 0 词 · 类型 3 种'), findsOneWidget);

    await tester.tap(find.text('屏蔽关键词 / 屏蔽用户 / 高亮词'));
    await tester.pumpAndSettle();

    expect(find.text('使用正则表达式'), findsOneWidget);
    expect(find.text('使用教程'), findsOneWidget);
    expect(find.text('列表显示的类型'), findsOneWidget);
  });

  testWidgets('开启正则后立即回调，规则编辑器切到正则口径', (WidgetTester tester) async {
    _useTallScreen(tester);
    final List<FilterPrefs> changes = <FilterPrefs>[];
    await tester.pumpWidget(_wrapFilter(
      prefs: const FilterPrefs(),
      onChanged: changes.add,
    ));
    await tester.pumpAndSettle();

    await tester.tap(_switchInTile('使用正则表达式'));
    await tester.pumpAndSettle();

    expect(changes.last.regexEnabled, isTrue);
    // 开启后屏蔽关键词的输入框提示词改成正则示例。
    expect(find.text(r'如 ^6{3,}$'), findsOneWidget);
  });

  testWidgets('合法正则可添加，非法正则被拦下并提示', (WidgetTester tester) async {
    _useTallScreen(tester);
    final List<FilterPrefs> changes = <FilterPrefs>[];
    await tester.pumpWidget(_wrapFilter(
      prefs: const FilterPrefs(regexEnabled: true),
      onChanged: changes.add,
    ));
    await tester.pumpAndSettle();

    // 第一行输入框即「屏蔽关键词」。
    await tester.enterText(find.byType(TextField).first, r'^6{3,}$');
    await tester.tap(find.text('添加').first);
    await tester.pumpAndSettle();
    expect(changes.last.blockedKeywords, <String>[r'^6{3,}$']);

    // 非法正则（括号不闭合）不允许写入，给出明确提示。
    final int before = changes.length;
    await tester.enterText(find.byType(TextField).first, '(未闭合');
    await tester.tap(find.text('添加').first);
    await tester.pumpAndSettle();
    expect(changes.length, before);
    expect(find.text('正则写法不合法，请检查括号、方括号是否配对'), findsOneWidget);
  });

  testWidgets('存量非法正则会在页面顶部列出，且不影响其它规则', (WidgetTester tester) async {
    _useTallScreen(tester);
    await tester.pumpWidget(_wrapFilter(
      prefs: const FilterPrefs(
        blockedKeywords: <String>['(未闭合'],
        highlightKeywords: <String>[r'(抽奖|福利)'],
        regexEnabled: true,
      ),
      onChanged: _ignore,
    ));
    await tester.pumpAndSettle();

    expect(find.text('以下规则不是合法正则，已跳过（不影响其它规则）：'), findsOneWidget);
    expect(find.text('• (未闭合'), findsOneWidget);
  });

  testWidgets('高亮词与类型多选写回对应字段', (WidgetTester tester) async {
    _useTallScreen(tester);
    final List<FilterPrefs> changes = <FilterPrefs>[];
    await tester.pumpWidget(_wrapFilter(
      prefs: const FilterPrefs(),
      onChanged: changes.add,
    ));
    await tester.pumpAndSettle();

    // 第三个输入框是「高亮词」。
    await tester.enterText(find.byType(TextField).at(2), '抽奖');
    await tester.tap(find.text('添加').at(2));
    await tester.pumpAndSettle();
    expect(changes.last.highlightKeywords, <String>['抽奖']);

    await tester.tap(find.widgetWithText(FilterChip, '礼物'));
    await tester.pumpAndSettle();
    expect(changes.last.visibleKinds.contains(DanmakuKind.gift), isTrue);
    // 原有类型不被顺手清掉。
    expect(changes.last.visibleKinds.contains(DanmakuKind.chat), isTrue);
  });

  test('过滤偏好经文件往返保留正则开关', () async {
    final Directory directory =
        Directory.systemTemp.createTempSync('filter_page_test');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final FilterStore store = FilterStore(directoryResolver: () async => directory);

    await store.save(const FilterPrefs(
      blockedKeywords: <String>[r'^6{3,}$'],
      highlightKeywords: <String>[r'(抽奖|福利)'],
      regexEnabled: true,
    ));
    final FilterPrefs loaded = await store.load();
    expect(loaded.regexEnabled, isTrue);
    expect(loaded.blockedKeywords, <String>[r'^6{3,}$']);
    expect(loaded.highlightKeywords, <String>[r'(抽奖|福利)']);
  });

  test('老配置文件没有 regexEnabled 时按关闭处理', () {
    final FilterPrefs loaded = decodeFilterPrefs(
      '{"blockedKeywords":["加群"],"blockedUsers":[],"highlightKeywords":[]}',
    );
    expect(loaded.regexEnabled, isFalse);
    expect(loaded.blockedKeywords, <String>['加群']);
  });
}

const double _screenWidth = 800;
const double _tallScreenHeight = 2400;

void _useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(_screenWidth, _tallScreenHeight);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void _noop(OverlayPrefs prefs, {required bool persist}) {}

void _ignore(FilterPrefs prefs) {}

Widget _wrapFilter({
  required FilterPrefs prefs,
  required void Function(FilterPrefs prefs) onChanged,
}) {
  final Directory directory =
      Directory.systemTemp.createTempSync('filter_page_widget');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return MaterialApp(
    home: FilterSettingsPage(
      prefs: prefs,
      store: FilterStore(directoryResolver: () async => directory),
      onChanged: onChanged,
    ),
  );
}

/// 定位某个 ListTile 里的开关：按标题精确匹配。
Finder _switchInTile(String title) => find.descendant(
      of: find.widgetWithText(ListTile, title),
      matching: find.byType(Switch),
    );