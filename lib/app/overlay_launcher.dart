// 悬浮窗开关：主 App 与悬浮窗链路分属两个 Flutter 引擎，
// 主 App 只负责申请权限、建窗、下发配置（prd 4.11）。
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

/// 窗口尺寸（dp）：单栏最小 200×150、4 栏最小 320×240（prd 4.2），
/// 这里取便于阅读的默认值；插件按物理像素设置窗口，调用处需乘设备像素比。
({double width, double height}) overlaySizeFor(OverlayLayout layout) =>
    layout == OverlayLayout.quad
        ? (width: 400, height: 560)
        : (width: 240, height: 320);

/// 确保悬浮窗权限；用户拒绝时返回 false。
Future<bool> ensureOverlayPermission() async {
  if (await FlutterScreenOverlay.isPermissionGranted()) return true;
  return await FlutterScreenOverlay.requestPermission() ?? false;
}

/// 已建窗时按新尺寸重排并重新下发房间，无需关闭重开。
Future<void> resizeOverlay(
  OverlayConfig config, {
  required double devicePixelRatio,
}) async {
  final ({double width, double height}) size = overlaySizeFor(config.layout);
  await FlutterScreenOverlay.resizeOverlay(
    (size.width * devicePixelRatio).round(),
    (size.height * devicePixelRatio).round(),
    true,
  );
  await shareOverlayConfig(config);
}

/// 建窗并下发配置。
Future<void> openOverlay(
  OverlayConfig config, {
  required double devicePixelRatio,
}) async {
  final ({double width, double height}) size = overlaySizeFor(config.layout);
  await FlutterScreenOverlay.showOverlay(
    width: (size.width * devicePixelRatio).round(),
    height: (size.height * devicePixelRatio).round(),
    alignment: OverlayAlignment.centerRight,
    enableDrag: true,
    positionGravity: PositionGravity.auto,
    overlayTitle: 'DanmuFloat',
    overlayContent: '正在显示弹幕悬浮窗',
  );
  // 窗口建立后下发配置：此时悬浮窗引擎已随主 App 启动预热完毕。
  await shareOverlayConfig(config);
}

Future<void> shareOverlayConfig(OverlayConfig config) =>
    FlutterScreenOverlay.shareData(config.toJson());

/// 关闭悬浮窗：先让悬浮窗卸载各栏（断开全部连接、清空内存缓存）再关窗口。
///
/// 插件关闭窗口不会销毁缓存的引擎，只靠 dispose 收不到释放时机（prd 4.11）。
Future<void> closeOverlayWindow() async {
  await FlutterScreenOverlay.shareData(buildOverlayCloseMessage());
  await FlutterScreenOverlay.closeOverlay();
}