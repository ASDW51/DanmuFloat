// 设置页「悬浮窗样式」：透明度 / 字号 / 窗口宽高滑杆的即时预览与落盘时机。
//
// 拖动过程只推给悬浮窗预览、不落盘；松手（onChangeEnd）才落盘。
import 'dart:io';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存凭证后端：设置页测试不依赖 Android Keystore 插件通道。
class FakeCredentialBackend implements CredentialBackend {
  String? stored;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String value) async => stored = value;

  @override
  Future<void> delete() async => stored = null;
}

void main() {
  testWidgets('五条滑杆默认取值落在可调范围内，并显示当前值', (WidgetTester tester) async {
    _useTallScreen(tester);
    await tester.pumpWidget(_wrap(const OverlayPrefs(), _noop));

    expect(find.text('弹幕背景透明度　0.80'), findsOneWidget);
    expect(find.text('弹幕字号　13'), findsOneWidget);
    expect(find.text('滚动速度　1.00x'), findsOneWidget);
    expect(find.text('整体宽度　400'), findsOneWidget);
    expect(find.text('整体高度　560'), findsOneWidget);

    final List<Slider> sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    expect(sliders.length, 5);
    expect(sliders[0].min, minOverlayOpacity);
    expect(sliders[0].max, maxOverlayOpacity);
    expect(sliders[0].value, defaultOverlayOpacity);
    expect(sliders[1].min, minDanmuFontSize);
    expect(sliders[1].max, maxDanmuFontSize);
    expect(sliders[1].value, defaultDanmuFontSize);
    expect(sliders[2].min, minDanmuScrollSpeed);
    expect(sliders[2].max, maxDanmuScrollSpeed);
    expect(sliders[2].value, defaultDanmuScrollSpeed);
    // 尺寸上限按屏幕收紧（测试环境逻辑尺寸 800×600），避免拖出屏幕。
    expect(sliders[3].min, minOverlayWidth);
    expect(sliders[3].max, overlayWidthLimit(_screenWidth));
    expect(sliders[3].value, defaultOverlayWidth);
    expect(sliders[4].min, minOverlayHeight);
    expect(sliders[4].max, overlayHeightLimit(_tallScreenHeight));
    expect(sliders[4].value, defaultOverlayHeight);
  });

  testWidgets('窗口尺寸上限跟随屏幕：默认值超出屏幕时显示为屏幕宽度', (WidgetTester tester) async {
    // 逻辑尺寸 360×2400：默认宽度 400 会被收到 360；
    // 高度取足够大，保证尺寸分区（排在新增的屏蔽与高亮分区之后）也被构建出来。
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const OverlayPrefs(), _noop));

    expect(find.text('整体宽度　360'), findsOneWidget);
    final Slider widthSlider =
        tester.widgetList<Slider>(find.byType(Slider)).elementAt(3);
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

  testWidgets('字号、滚动速度与窗口尺寸滑杆分别写回对应字段', (WidgetTester tester) async {
    _useTallScreen(tester);
    OverlayPrefs latest = const OverlayPrefs();
    await tester.pumpWidget(_wrap(const OverlayPrefs(), (OverlayPrefs prefs, {required bool persist}) {
      latest = prefs;
    }));

    // 字号滑杆在最右端：取到最大值。
    await _dragToEnd(tester, 1);
    expect(latest.fontSize, maxDanmuFontSize);
    // 滚动速度滑杆在最右端：取到最大倍数。
    await _dragToEnd(tester, 2);
    expect(latest.scrollSpeed, maxDanmuScrollSpeed);
    // 后续拖动不应冲掉字号与速度。
    await _dragToEnd(tester, 3);
    expect(latest.windowWidth, overlayWidthLimit(_screenWidth));
    expect(latest.fontSize, maxDanmuFontSize);
    expect(latest.scrollSpeed, maxDanmuScrollSpeed);
    await _dragToEnd(tester, 4);
    expect(latest.windowHeight, overlayHeightLimit(_tallScreenHeight));
    expect(latest.windowWidth, overlayWidthLimit(_screenWidth));
  });

  testWidgets('按栏数推荐尺寸使用上次勾选的栏数并落盘', (WidgetTester tester) async {
    _useTallScreen(tester);
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

  testWidgets('凭证状态行按来源显示，粘贴合法凭证后切换为手动粘贴', (WidgetTester tester) async {
    _useFullScreen(tester);
    final CredentialStore store =
        CredentialStore(backend: FakeCredentialBackend());
    await tester.pumpWidget(_wrapFull(prefs: const OverlayPrefs(), store: store));
    await tester.pumpAndSettle();
    expect(find.text('匿名自动获取（仅内存）'), findsOneWidget);

    await tester.enterText(_credentialField, 'ttwid=abc');
    await tester.tap(find.widgetWithText(FilledButton, '加密保存'));
    await tester.pumpAndSettle();

    expect(store.isManual, isTrue);
    expect(find.text('手动粘贴'), findsOneWidget);
    // 保存后清空输入框，不回显明文。
    expect(tester.widget<TextField>(_credentialField).controller?.text, '');
  });

  testWidgets('畸形凭证不保存，给出错误提示', (WidgetTester tester) async {
    _useFullScreen(tester);
    final FakeCredentialBackend backend = FakeCredentialBackend();
    await tester.pumpWidget(_wrapFull(
      prefs: const OverlayPrefs(),
      store: CredentialStore(backend: backend),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(_credentialField, '不是 cookie');
    await tester.tap(find.widgetWithText(FilledButton, '加密保存'));
    await tester.pumpAndSettle();

    expect(backend.stored, isNull);
    expect(find.text('格式应为 name=value，段之间用分号分隔'), findsOneWidget);
    expect(find.text('匿名自动获取（仅内存）'), findsOneWidget);
  });

  testWidgets('清除本地凭证需确认，确认后删除密文并回到匿名', (WidgetTester tester) async {
    _useFullScreen(tester);
    final FakeCredentialBackend backend = FakeCredentialBackend()
      ..stored = 'ttwid=abc';
    await tester.pumpWidget(_wrapFull(
      prefs: const OverlayPrefs(),
      store: CredentialStore(backend: backend),
    ));
    await tester.pumpAndSettle();
    expect(find.text('手动粘贴'), findsOneWidget);

    await tester.tap(find.text('清除本地凭证'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清除'));
    await tester.pumpAndSettle();

    expect(backend.stored, isNull);
    expect(find.text('匿名自动获取（仅内存）'), findsOneWidget);
  });

  testWidgets('清除所有本地数据需二次确认，确认后才回调外层重置', (WidgetTester tester) async {
    _useFullScreen(tester);
    int resets = 0;
    await tester.pumpWidget(_wrapFull(
      prefs: const OverlayPrefs(),
      store: CredentialStore(backend: FakeCredentialBackend()),
      onResetAll: () async => resets++,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('清除所有本地数据'));
    await tester.pumpAndSettle();
    // 只弹确认框，未确认前不执行。
    expect(resets, 0);

    await tester.tap(find.widgetWithText(FilledButton, '清除并重置'));
    await tester.pumpAndSettle();
    expect(resets, 1);
  });

  testWidgets('主题三选写回全局通知量并触发落盘，皮肤与栏位开关写回偏好', (WidgetTester tester) async {
    _useLongScreen(tester);
    appThemeMode.value = ThemeMode.system;
    final Directory directory =
        Directory.systemTemp.createTempSync('settings_theme_test');
    int resolved = 0;
    addTearDown(() {
      appThemeMode.value = ThemeMode.system;
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    OverlayPrefs latest = const OverlayPrefs();
    final List<bool> persisted = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: SettingsPage(
        prefs: const OverlayPrefs(),
        onChanged: (OverlayPrefs prefs, {required bool persist}) {
          latest = prefs;
          persisted.add(persist);
        },
        themeStore: ThemeStore(directoryResolver: () async {
          resolved++;
          return directory;
        }),
      ),
    ));

    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '跟随系统'))
          .selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '深色'));
    await tester.pumpAndSettle();
    expect(appThemeMode.value, ThemeMode.dark);
    // 主题改动要走一次 ThemeStore，才会落到 theme.json。
    expect(resolved, greaterThan(0));

    await tester.tap(_switchInTile('悬浮窗浅色皮肤'));
    await tester.pumpAndSettle();
    expect(latest.lightTheme, isTrue);
    expect(persisted.last, isTrue);

    await tester.tap(_switchInTile('显示栏目标识'));
    await tester.pumpAndSettle();
    expect(latest.showTitleBar, isFalse);

    await tester.tap(find.widgetWithText(ChoiceChip, '其余栏隐藏'));
    await tester.pumpAndSettle();
    expect(latest.focusBehavior, focusBehaviorHide);
  });
}

/// 测试环境的逻辑屏幕尺寸（Flutter 测试默认 800×600）。
const double _screenWidth = 800;
const double _screenHeight = 600;

/// 凭证粘贴框：按 labelText 定位，避免与「屏蔽与高亮」分区的关键词输入框混淆。
final Finder _credentialField = find.byWidgetPredicate(
  (Widget widget) =>
      widget is TextField && widget.decoration?.labelText == '手动粘贴凭证（兜底）',
);

/// 加高视口后的逻辑高度：设置页比默认测试视口高，五条滑杆要全部完成布局
/// （ListView 懒加载，视口外的项不会被构建，find 就找不到）。
const double _tallScreenHeight = 2000;

void _useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, _tallScreenHeight);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

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

/// 新增分区的测试视口：比 [_tallScreenHeight] 再高一些，
/// 保证「连接与凭证 / 数据与隐私」等靠后的分区也被构建出来。
void _useFullScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(_screenWidth, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 主题与「栏位与手势」分区排在页面靠后位置，需要更高的视口才不会被懒加载裁掉。
void _useLongScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(_screenWidth, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 定位某个 ListTile 里的开关：按标题精确匹配，避免与说明文字混淆。
Finder _switchInTile(String title) => find.descendant(
      of: find.widgetWithText(ListTile, title),
      matching: find.byType(Switch),
    );

Widget _wrapFull({
  required OverlayPrefs prefs,
  CredentialStore? store,
  ThemeStore? themeStore,
  Future<void> Function()? onResetAll,
}) =>
    MaterialApp(
      home: SettingsPage(
        prefs: prefs,
        onChanged: _noop,
        credentialStore: store,
        themeStore: themeStore,
        onResetAll: onResetAll,
      ),
    );

Widget _wrap(
  OverlayPrefs prefs,
  void Function(OverlayPrefs prefs, {required bool persist}) onChanged,
) =>
    MaterialApp(home: SettingsPage(prefs: prefs, onChanged: onChanged));