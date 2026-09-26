// 悬浮窗开关：主 App 与悬浮窗链路分属两个 Flutter 引擎，
// 主 App 只负责申请权限、建窗、下发配置（prd 4.11）。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

/// 窗口尺寸（dp）由设置页决定（prd 4.2 只约束单栏最小 200×150）；
/// 插件按物理像素设置窗口，调用处需乘设备像素比。
///
/// 这里的宽高是**整个悬浮窗**的尺寸，内部各栏自动平分，不需要按栏数分别设置。

/// 窗口当前是否已建立。
///
/// 悬浮窗可以从首页（多栏）或弹幕页（单栏）开启，各页面自己的开关状态互不知晓；
/// 设置页改样式时必须与开窗来源无关，故把「窗口是否已开」记在这里。
bool _overlayShown = false;

/// 窗口当前是否已建立（供调用方决定走建窗还是重排）。
bool get overlayShown => _overlayShown;

/// 只查询悬浮窗权限，不发起申请（首页常驻 banner 用）。
///
/// 通道不可用（非 Android 运行）或查询抛错时按「未授予」处理：首页只会多显示
/// 一条可关闭的提示，不会误导用户以为悬浮窗可用。
Future<bool> isOverlayPermissionGranted() async {
  try {
    return await FlutterScreenOverlay.isPermissionGranted();
  } on Object catch (exception) {
    debugPrint('查询悬浮窗权限失败: $exception');
    return false;
  }
}

/// 确保悬浮窗权限；用户拒绝时返回 false。
Future<bool> ensureOverlayPermission() async {
  if (await isOverlayPermissionGranted()) return true;
  try {
    return await FlutterScreenOverlay.requestPermission() ?? false;
  } on Object catch (exception) {
    debugPrint('申请悬浮窗权限失败: $exception');
    return false;
  }
}

/// 只调整窗口尺寸，不下发配置：设置页改大小时走这里，
/// 不动各栏已绑定的房间（窗口里绑了哪些房间由持有窗口的页面决定）。
Future<void> resizeOverlayWindow(
  ({double width, double height}) size, {
  required double devicePixelRatio,
}) async {
  await FlutterScreenOverlay.resizeOverlay(
    (size.width * devicePixelRatio).round(),
    (size.height * devicePixelRatio).round(),
    true,
  );
}

({double width, double height})? _pendingSize;
double _pendingDevicePixelRatio = 1;
Timer? _resizeTimer;

/// 实时改窗口尺寸：窗口没开时静默忽略，开了才 resize。
///
/// 拖滑杆会以帧级频率触发，这里把同一帧内的多次调用合并成一次下发，
/// 免得并发调用插件导致最终尺寸不是用户停手时的值。
void updateOverlaySize(
  ({double width, double height}) size, {
  required double devicePixelRatio,
}) {
  if (!_overlayShown) return;
  _pendingSize = size;
  _pendingDevicePixelRatio = devicePixelRatio;
  _resizeTimer ??= Timer(const Duration(milliseconds: 16), () {
    _resizeTimer = null;
    final ({double width, double height})? pending = _pendingSize;
    _pendingSize = null;
    if (pending == null || !_overlayShown) return;
    unawaited(
      resizeOverlayWindow(pending, devicePixelRatio: _pendingDevicePixelRatio),
    );
  });
}

/// 已建窗时按新尺寸重排并重新下发房间，无需关闭重开。
Future<void> resizeOverlay(
  OverlayConfig config, {
  required double devicePixelRatio,
  required ({double width, double height}) size,
}) async {
  _overlayShown = true;
  await resizeOverlayWindow(size, devicePixelRatio: devicePixelRatio);
  // 凭证先于配置下发：新栏位在收到 config 后立刻开始连接，先到才能生效。
  await shareOverlayCredential(manualCookies);
  await shareOverlayConfig(config);
}

/// 建窗并下发配置。
Future<void> openOverlay(
  OverlayConfig config, {
  required double devicePixelRatio,
  required ({double width, double height}) size,
}) async {
  await FlutterScreenOverlay.showOverlay(
    width: (size.width * devicePixelRatio).round(),
    height: (size.height * devicePixelRatio).round(),
    alignment: OverlayAlignment.centerRight,
    enableDrag: true,
    positionGravity: PositionGravity.auto,
    overlayTitle: 'DanmuFloat',
    overlayContent: '正在显示弹幕悬浮窗',
  );
  _overlayShown = true;
  // 窗口建立后下发配置：此时悬浮窗引擎已随主 App 启动预热完毕。
  await shareOverlayCredential(manualCookies);
  await shareOverlayConfig(config);
}

/// 把手动粘贴的凭证同步给悬浮窗引擎（prd F27）；null 表示回到匿名自动获取。
///
/// 窗口没开时静默忽略：消息通道另一端没有监听者，下次建窗会随配置补发。
Future<void> shareOverlayCredential(String? cookies) async {
  if (!_overlayShown) return;
  await FlutterScreenOverlay.shareData(OverlayCredential(cookies).toJson());
}

Future<void> shareOverlayConfig(OverlayConfig config) =>
    FlutterScreenOverlay.shareData(config.toJson());

/// 只推样式（透明度 + 字号 + 滚动速度 + 各栏覆盖 + 皮肤 / 标识 / 焦点行为），
/// 不动各栏已绑定的房间：设置页调样式走这里。
///
/// 窗口没开时直接忽略：消息通道另一端没有监听者。
Future<void> shareOverlayStyle({
  required double opacity,
  required double fontSize,
  required double scrollSpeed,
  Map<String, PaneStyle> paneStyles = const <String, PaneStyle>{},
  bool lightTheme = false,
  bool showTitleBar = true,
  String focusBehavior = defaultFocusBehavior,
}) async {
  if (!_overlayShown) return;
  await FlutterScreenOverlay.shareData(
    OverlayStyle(
      opacity: opacity,
      fontSize: fontSize,
      scrollSpeed: scrollSpeed,
      paneStyles: paneStyles,
      lightTheme: lightTheme,
      showTitleBar: showTitleBar,
      focusBehavior: focusBehavior,
    ).toJson(),
  );
}

/// 临时开关窗口拖动（prd F21「滑动调透明度」）。
///
/// 插件在 `OverlayService.onTouch` 里把任何位移超过 5px 的滑动都用来移动窗口，
/// 与悬浮窗内的滑动手势冲突，因此在长按调透明度期间先关掉它，松手再恢复。
/// 插件只在 resizeOverlay 里写这个开关，所以这里按当前尺寸原样重发一次，
/// 只为了改开关（尺寸不变，窗口不会跳动）。
///
/// 不判断 [overlayShown]：本函数也由悬浮窗引擎调用，而那个引擎里的
/// [_overlayShown] 是另一份全局变量（两个引擎不共享内存），恒为 false。
Future<void> setOverlayDragEnabled(
  bool enabled, {
  required int width,
  required int height,
}) async {
  try {
    await FlutterScreenOverlay.resizeOverlay(width, height, enabled);
  } on Object catch (exception) {
    debugPrint('切换窗口拖动失败: $exception');
  }
}

/// 只推过滤偏好（屏蔽词 / 屏蔽用户 / 高亮词 / 类型筛选），不动各栏已绑定的房间：
/// 设置页改屏蔽与高亮走这里（prd F10 / F11 / F13）。
///
/// 窗口没开时直接忽略：消息通道另一端没有监听者，下次建窗会随 config 补发。
Future<void> shareOverlayFilter(FilterPrefs prefs) async {
  if (!_overlayShown) return;
  await FlutterScreenOverlay.shareData(OverlayFilter(prefs).toJson());
}

/// 只推候选房间列表（prd F14 分组 / F15 快速切换），不动各栏已绑定的房间：
/// 首页增删主播或改分组走这里。
///
/// 窗口没开时直接忽略：消息通道另一端没有监听者，下次建窗会随 config 补发。
Future<void> shareOverlayRooms(List<RoomOption> options) async {
  if (!_overlayShown) return;
  await FlutterScreenOverlay.shareData(OverlayRooms(options).toJson());
}

/// 悬浮窗上报的状态流（已解析、广播）。
///
/// 插件侧 `overlayListener` 是静态单例的普通 StreamController（非 broadcast），
/// 只能被 listen 一次：多次进入弹幕页/首页会抛
/// `Bad state: Stream has already been listened to`。
/// 因此这里只订阅插件一次，再以广播流分发。
Stream<OverlayStatus> get overlayStatusStream =>
    (_statusController ??= _relayOverlayStatus()).stream;

StreamController<OverlayStatus>? _statusController;

StreamController<OverlayStatus> _relayOverlayStatus() {
  final StreamController<OverlayStatus> controller =
      StreamController<OverlayStatus>.broadcast();
  FlutterScreenOverlay.overlayListener.listen(
    (dynamic message) {
      final OverlayStatus? status = OverlayStatus.tryParse(message);
      if (status != null && !controller.isClosed) controller.add(status);
    },
    onError: (Object error) => debugPrint('悬浮窗状态流异常: $error'),
  );
  return controller;
}

/// 关闭悬浮窗：先让悬浮窗卸载各栏（断开全部连接、清空内存缓存）再关窗口。
///
/// 插件关闭窗口不会销毁缓存的引擎，只靠 dispose 收不到释放时机（prd 4.11）。
Future<void> closeOverlayWindow() async {
  try {
    await FlutterScreenOverlay.shareData(buildOverlayCloseMessage());
    await FlutterScreenOverlay.closeOverlay();
  } finally {
    // 即使插件抛错也要复位：否则后续样式/尺寸会推给已经不存在的窗口。
    _overlayShown = false;
  }
}

/// 拆除悬浮窗，容忍窗口已被系统移除的情况（插件侧可能抛错）。
Future<void> teardownOverlay() async {
  try {
    await closeOverlayWindow();
  } on Object catch (exception) {
    debugPrint('拆除悬浮窗失败（窗口可能已被系统移除）: $exception');
  }
  _overlayShown = false;
}

/// 回到前台时核对悬浮窗是否仍然有效：权限被撤销、或窗口被系统移除都算失效。
///
/// 插件只在主 App 引擎注册了权限查询通道，悬浮窗引擎查不到，因此不做系统回调、
/// 也不在悬浮窗内自查，只在用户回到 App 时核对一次（改动小、成本低）。
/// 失效时顺手拆掉残留窗口——权限被撤销后 Dart 侧的 widget 树与各栏连接仍在跑。
Future<bool> verifyOverlayPermission() async {
  if (await FlutterScreenOverlay.isPermissionGranted() &&
      await FlutterScreenOverlay.isActive()) {
    return true;
  }
  await teardownOverlay();
  return false;
}