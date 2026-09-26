// 首次启动引导页（prd 4.10）：5 行步骤的渲染、状态切换与行内按钮行为。
//
// 所有系统权限都注入内存后端；悬浮窗权限默认拒绝，
// 用来验证「拒绝后降级为 App 内查看」的提示。
import 'package:danmu_float/system/system_permissions.dart';
import 'package:danmu_float/ui/onboarding_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSystemPermissionBackend implements SystemPermissionBackend {
  FakeSystemPermissionBackend({
    this.overlay = false,
    this.notification = false,
    this.battery = false,
  });

  bool overlay;
  bool notification;
  bool battery;
  int overlayRequests = 0;
  int notificationRequests = 0;
  int batteryRequests = 0;
  int settingsOpens = 0;

  @override
  Future<bool> hasOverlayPermission() async => overlay;

  @override
  Future<bool> requestOverlayPermission() async {
    overlayRequests++;
    return overlay;
  }

  @override
  Future<bool> hasNotificationPermission() async => notification;

  @override
  Future<bool> requestNotificationPermission() async {
    notificationRequests++;
    notification = true;
    return notification;
  }

  @override
  Future<bool> isBatteryOptimizationIgnored() async => battery;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async => batteryRequests++;

  @override
  Future<void> openAppSettings() async => settingsOpens++;
}

void main() {
  late FakeSystemPermissionBackend backend;

  setUp(() {
    backend = FakeSystemPermissionBackend();
    setSystemPermissionBackend(backend);
  });

  tearDown(() {
    setSystemPermissionBackend(const PlatformSystemPermissionBackend());
  });

  testWidgets('按 prd 4.10 顺序渲染 5 行步骤', (WidgetTester tester) async {
    _useTallScreen(tester);
    await tester.pumpWidget(_wrap(() async {}));
    await tester.pumpAndSettle();

    expect(find.text('1. 悬浮窗权限'), findsOneWidget);
    expect(find.text('2. 通知权限（Android 13+）'), findsOneWidget);
    expect(find.text('3. 电池优化白名单'), findsOneWidget);
    expect(find.text('4. 自启动权限（各厂商 ROM）'), findsOneWidget);
    expect(find.text('5. 前台服务类型声明'), findsOneWidget);
    // 电池优化与自启动各有一个「去设置」，前台服务类型行没有按钮。
    expect(find.widgetWithText(TextButton, '去设置'), findsNWidgets(2));
    expect(find.widgetWithText(TextButton, '去授权'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '请求授权'), findsOneWidget);
  });

  testWidgets('未授予时显示降级提示，点击去授权后仍拒绝给出提示', (WidgetTester tester) async {
    _useTallScreen(tester);
    await tester.pumpWidget(_wrap(() async {}));
    await tester.pumpAndSettle();

    expect(
      find.text('未授予，当前仅能在 App 内查看（降级模式）'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, '去授权'));
    await tester.pumpAndSettle();

    expect(backend.overlayRequests, 1);
    expect(find.text('未授予悬浮窗权限，已降级为 App 内查看，可稍后再开'), findsOneWidget);
    expect(find.text('未授予，当前仅能在 App 内查看（降级模式）'), findsOneWidget);
  });

  testWidgets('已授予悬浮窗权限时显示已授予且不再提供授权按钮', (WidgetTester tester) async {
    _useTallScreen(tester);
    backend.overlay = true;
    await tester.pumpWidget(_wrap(() async {}));
    await tester.pumpAndSettle();

    expect(find.text('已授予，可开启悬浮窗查看弹幕'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '去授权'), findsNothing);
  });

  testWidgets('请求通知权限后状态行切换为已授予，按钮消失', (WidgetTester tester) async {
    _useTallScreen(tester);
    await tester.pumpWidget(_wrap(() async {}));
    await tester.pumpAndSettle();

    expect(find.text('未授予，仅缺少前台服务通知，不影响弹幕'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '请求授权'));
    await tester.pumpAndSettle();

    expect(backend.notificationRequests, 1);
    expect(backend.notification, isTrue);
    expect(find.text('已授予，前台服务通知可正常显示'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '请求授权'), findsNothing);
  });

  testWidgets('电池优化与自启动分别跳系统页面', (WidgetTester tester) async {
    _useTallScreen(tester);
    await tester.pumpWidget(_wrap(() async {}));
    await tester.pumpAndSettle();

    // 电池优化行在自启动行之前：first 是电池优化，last 是自启动。
    final Finder settingsButtons =
        find.widgetWithText(TextButton, '去设置');

    await tester.tap(settingsButtons.first);
    await tester.pumpAndSettle();
    expect(backend.batteryRequests, 1);
    expect(backend.settingsOpens, 0);

    await tester.tap(settingsButtons.last);
    await tester.pumpAndSettle();
    expect(backend.settingsOpens, 1);
  });

  testWidgets('完成或稍后设置都会回调 onDone', (WidgetTester tester) async {
    _useTallScreen(tester);
    int done = 0;
    await tester.pumpWidget(_wrap(() async => done++));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, '稍后设置'));
    await tester.pumpAndSettle();
    expect(done, 1);

    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pumpAndSettle();
    expect(done, 2);
  });
}

/// 引导页 5 行步骤比默认测试视口高，ListView 懒加载要求视口足够高。
void _useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _wrap(Future<void> Function() onDone) =>
    MaterialApp(home: OnboardingPage(onDone: onDone));
