// 设置页「悬浮窗样式」：透明度 / 字号 / 窗口宽高滑杆的即时预览与落盘时机。
//
// 拖动过程只推给悬浮窗预览、不落盘；松手（onChangeEnd）才落盘。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('四条滑杆默认取值落在可调范围内，并显示当前值', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const OverlayPrefs(), _noop));

    expect(find.text('弹幕背景透明度　0.80'), findsOneWidget);
    expect(find.text('弹幕字号　13'), findsOneWidget);
    expect(find.text('整体宽度　400'), findsOneWidget);
    expect(find.text('整体高度　560'), findsOneWidget);

    final List<Slider> sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.length, 4);
    expect(sliders[0].min, minOverlayOpacity);
    expect(sliders[0].max, maxOverlayOpacity);
    expect(sliders[0].value, defaultOverlayOpacity);
    expect(sliders[1].min, minDanmuFontSize);
    expect(sliders[1].max, maxDanmuFontSize);
    expect(sliders[1].value, defaultDanmuFontSize);
    // 尺寸上限按屏幕收紧（测试环境逻辑尺寸 800×600），避免拖出屏幕。
    expect(sliders[2].min, minOverlayWidth);
    expect(sliders[2].max, overlayWidthLimit(_screenWidth));
    expect(sliders[2].value, defaultOverlayWidth);
    expect(sliders[3].min, minOverlayHeight);
    expect(sliders[3].max, overlayHeightLimit(_screenHeight));
    expect(sliders[3].value, defaultOverlayHeight);
  });

  testWidgets('窗口尺寸上限跟随屏幕：默认值超出屏幕时显示为屏幕宽度', (WidgetTester tester) async {
    // 逻辑尺寸 360×800：默认宽度 400 会被收到 360。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const OverlayPrefs(), _noop));

    expect(find.text('整体宽度　360'), findsOneWidget);
    final Slider widthSlider =
        tester.widgetList<Slider>(find.byType(Slider)).elementAt(2);
    expect(widthSlider.max, 360);
    expect(widthSlider.value, 360);
  });

  testWidgets('拖动只预览不落盘，松手才落盘', (WidgetTester tester) async {
    final List<bool> persisted = <bool>[];
    OverlayPrefs latest = const OverlayPrefs();

    await tester.pumpWidget(_wrap(const OverlayPrefs(), (OverlayPrefs prefs, {required bool persist}) {
      latest = prefs;
      persisted.add(persist);
    }));

    // 按住滑杆拖动（不松手）：onChanged 触发、此时不落盘。
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(find.byType(Slider).first));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(persisted, isNotEmpty);
    expect(persisted.last, isFalse);

    // 松手触发 onChangeEnd：落盘一次，且值被收敛在范围内。
    await gesture.up();
    await tester.pumpAndSettle();
    expect(persisted.last, isTrue);
    expect(latest.opacity, greaterThanOrEqualTo(minOverlayOpacity));
    expect(latest.opacity, lessThanOrEqualTo(maxOverlayOpacity));
  });

  testWidgets('字号与窗口尺寸滑杆分别写回对应字段', (WidgetTester tester) async {
    OverlayPrefs latest = const OverlayPrefs();
    await tester.pumpWidget(_wrap(const OverlayPrefs(), (OverlayPrefs prefs, {required bool persist}) {
      latest = prefs;
    }));

    // 字号滑杆在最右端：取到最大值。
    await _dragToEnd(tester, 1);
    expect(latest.fontSize, maxDanmuFontSize);
    // 后续拖动不应冲掉字号。
    await _dragToEnd(tester, 2);
    expect(latest.windowWidth, overlayWidthLimit(_screenWidth));
    expect(latest.fontSize, maxDanmuFontSize);
    await _dragToEnd(tester, 3);
    expect(latest.windowHeight, overlayHeightLimit(_screenHeight));
    expect(latest.windowWidth, overlayWidthLimit(_screenWidth));
  });

  testWidgets('按栏数推荐尺寸使用上次勾选的栏数并落盘', (WidgetTester tester) async {
    OverlayPrefs latest = const OverlayPrefs();
    final List<bool> persisted = <bool>[];
    await tester.pumpWidget(_wrap(
      const OverlayPrefs(webRids: <String>['1', '2', '3', '4', '5']),
      (OverlayPrefs prefs, {required bool persist}) {
        latest = prefs;
        persisted.add(persist);
      },
    ));

    // 推荐值同样要收敛到屏幕内。
    final ({double width, double height}) expected = fitOverlaySize(
      recommendedOverlaySize(5),
      screenWidth: _screenWidth,
      screenHeight: _screenHeight,
    );
    await tester.tap(find.text('按栏数推荐尺寸'));
    await tester.pumpAndSettle();

    expect(latest.windowWidth, expected.width);
    expect(latest.windowHeight, expected.height);
    expect(persisted.last, isTrue);
  });
}

/// 测试环境的逻辑屏幕尺寸（Flutter 测试默认 800×600）。
const double _screenWidth = 800;
const double _screenHeight = 600;

/// 把第 [index] 条滑杆拖到最大端。
Future<void> _dragToEnd(WidgetTester tester, int index) async {
  final Finder slider = find.byType(Slider).at(index);
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(slider));
  await gesture.moveBy(const Offset(2000, 0));
  await gesture.up();
  await tester.pumpAndSettle();
}

void _noop(OverlayPrefs prefs, {required bool persist}) {}

Widget _wrap(
  OverlayPrefs prefs,
  void Function(OverlayPrefs prefs, {required bool persist}) onChanged,
) =>
    MaterialApp(home: SettingsPage(prefs: prefs, onChanged: onChanged));