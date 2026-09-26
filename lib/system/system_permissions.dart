// 系统权限查询与请求（prd 4.10 首次启动引导 / 权限拒绝降级）。
//
// 通知权限（Android 13+）与电池优化白名单没有现成的插件接口，走自定义
// MethodChannel（android/app/src/main/kotlin/.../MainActivity.kt 实现）；
// 悬浮窗权限由 flutter_screen_overlay 提供，见 overlay_launcher。
//
// 后端做成可注入：单测换成内存实现即可，不依赖真机通道。
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 与 MainActivity 约定的方法通道名。
const String systemChannelName = 'danmu_float/system';

/// 系统权限后端。
abstract class SystemPermissionBackend {
  /// 是否已授予悬浮窗权限（查询，不发起申请）。
  Future<bool> hasOverlayPermission();

  /// 申请悬浮窗权限；最终是否授予以返回值为准。
  Future<bool> requestOverlayPermission();

  /// 是否已授予通知权限（Android 13 以下无此权限，视为已授予）。
  Future<bool> hasNotificationPermission();

  /// 弹系统授权框请求通知权限；返回最终是否授予。
  Future<bool> requestNotificationPermission();

  /// 当前 App 是否已在电池优化白名单内。
  Future<bool> isBatteryOptimizationIgnored();

  /// 跳系统页面请求加入电池优化白名单（用户确认与否只能回到 App 后重新查询）。
  Future<void> requestIgnoreBatteryOptimizations();

  /// 打开本应用的系统设置详情页（自启动等厂商 ROM 权限只能在这里手动开）。
  Future<void> openAppSettings();
}

/// 默认实现：悬浮窗走 flutter_screen_overlay，其余走平台通道。
class PlatformSystemPermissionBackend implements SystemPermissionBackend {
  const PlatformSystemPermissionBackend();

  static const MethodChannel _channel = MethodChannel(systemChannelName);

  @override
  Future<bool> hasOverlayPermission() => isOverlayPermissionGranted();

  @override
  Future<bool> requestOverlayPermission() => ensureOverlayPermission();

  @override
  Future<bool> hasNotificationPermission() =>
      _invokeBool('hasNotificationPermission');

  @override
  Future<bool> requestNotificationPermission() =>
      _invokeBool('requestNotificationPermission');

  @override
  Future<bool> isBatteryOptimizationIgnored() =>
      _invokeBool('isBatteryOptimizationIgnored');

  @override
  Future<void> requestIgnoreBatteryOptimizations() =>
      _invokeVoid('requestIgnoreBatteryOptimizations');

  @override
  Future<void> openAppSettings() => _invokeVoid('openAppSettings');

  /// 查询类调用：通道不可用（非 Android 运行或原生未注册）时按「已满足」处理，
  /// 避免在不支持的平台上一直提示用户去授权。
  Future<bool> _invokeBool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException catch (exception) {
      debugPrint('$method 失败: $exception');
      return true;
    }
  }

  Future<void> _invokeVoid(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      debugPrint('$method 通道不可用');
    } on PlatformException catch (exception) {
      debugPrint('$method 失败: $exception');
    }
  }
}

/// 当前后端；测试可替换为内存实现。
SystemPermissionBackend _backend = const PlatformSystemPermissionBackend();

SystemPermissionBackend get systemPermissions => _backend;

/// 替换后端（仅测试用）。
@visibleForTesting
void setSystemPermissionBackend(SystemPermissionBackend backend) {
  _backend = backend;
}
