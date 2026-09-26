// 系统权限通道（prd 4.10）：默认后端的方法名与返回值解析。
//
// 用 mock MethodChannel 顶替原生侧，验证「通道可用时按原生返回值」与
// 「通道不可用时按已满足处理（不误报）」两条路径。
import 'package:danmu_float/system/system_permissions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(systemChannelName);
  final List<String> calls = <String>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('查询类方法透传原生返回值', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      return switch (call.method) {
        'hasNotificationPermission' => false,
        'isBatteryOptimizationIgnored' => true,
        _ => null,
      };
    });

    const SystemPermissionBackend backend = PlatformSystemPermissionBackend();
    expect(await backend.hasNotificationPermission(), isFalse);
    expect(await backend.isBatteryOptimizationIgnored(), isTrue);
    expect(calls, <String>[
      'hasNotificationPermission',
      'isBatteryOptimizationIgnored',
    ]);
  });

  test('请求通知权限返回用户选择的结果', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      return false;
    });

    const SystemPermissionBackend backend = PlatformSystemPermissionBackend();
    expect(await backend.requestNotificationPermission(), isFalse);
    expect(calls, <String>['requestNotificationPermission']);
  });

  test('通道不可用时查询按已满足处理，跳转类调用不抛异常', () async {
    const SystemPermissionBackend backend = PlatformSystemPermissionBackend();
    // 未注册 mock handler：调用会抛 MissingPluginException。
    expect(await backend.hasNotificationPermission(), isTrue);
    expect(await backend.isBatteryOptimizationIgnored(), isTrue);
    await backend.requestIgnoreBatteryOptimizations();
    await backend.openAppSettings();
  });
}
