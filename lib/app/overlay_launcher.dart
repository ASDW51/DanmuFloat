// 悬浮窗开关：主 App 与悬浮窗链路分属两个 Flutter 引擎，
// 主 App 只负责申请权限、建窗、下发配置（prd 4.11）。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

/// 窗口尺寸（dp）由设置页决定（prd 4.2 只约束单栏最小 200×150）。
///
/// 插件两个尺寸 API 的单位不一致：建窗用的 `showOverlay` 收物理像素（故 [openOverlay]
/// 里乘了设备像素比），改尺寸用的 `resizeOverlay` 内部自行按 dp 换算（故 [resizeOverlayWindow]
/// 传 dp）。混用会把窗口放大一个像素比，撑满屏幕。
///
/// 这里的宽高是**整个悬浮窗**的尺寸，内部各栏自动平分，不需要按栏数分别设置。

/// 窗口当前是否已建立。
///
/// 悬浮窗可以从首页（多栏）或弹幕页（单栏）开启，各页面自己的开关状态互不知晓；
/// 设置页改样式时必须与开窗来源无关，故把「窗口是否已开」记在这里。
bool _overlayShown = false;

/// 窗口当前是否已建立（供调用方决定走建窗还是重排）。
bool get overlayShown => _overlayShown;

/// 窗口拖动是否已锁定（锁定后栏内列表才能正常上下滑动）。
///
/// 插件只通过 `resizeOverlay(w, h, enableDrag)` 写这个开关，因此每次改尺寸
/// 都必须带上当前锁定状态，否则会把锁定冲掉。
bool _dragLocked = false;

/// 记录窗口拖动锁定状态（悬浮窗侧切换后主 App 落盘时同步过来）。
void setOverlayDragLock(bool locked) {
  _dragLocked = locked;
}

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
///
/// 注意插件两个 API 的单位不一致：`resizeOverlay` 内部会按 dp 换算成物理像素，
/// 所以这里要传 dp；而 `showOverlay` 直接把宽高当物理像素用（见 [openOverlay]）。
Future<void> resizeOverlayWindow(({double width, double height}) size) async {
  await FlutterScreenOverlay.resizeOverlay(
    size.width.round(),
    size.height.round(),
    // 改尺寸时必须带上当前锁定状态，否则插件会把拖动重新打开。
    !_dragLocked,
  );
}

({double width, double height})? _pendingSize;
Timer? _resizeTimer;

/// 实时改窗口尺寸：窗口没开时静默忽略，开了才 resize。
///
/// 拖滑杆会以帧级频率触发，这里把同一帧内的多次调用合并成一次下发，
/// 免得并发调用插件导致最终尺寸不是用户停手时的值。
void updateOverlaySize(({double width, double height}) size) {
  if (!_overlayShown) return;
  _pendingSize = size;
  _resizeTimer ??= Timer(const Duration(milliseconds: 16), () {
    _resizeTimer = null;
    final ({double width, double height})? pending = _pendingSize;
    _pendingSize = null;
    if (pending == null || !_overlayShown) return;
    unawaited(resizeOverlayWindow(pending));
  });
}

/// 已建窗时按新尺寸重排并重新下发房间，无需关闭重开。
Future<void> resizeOverlay(
  OverlayConfig config, {
  required ({double width, double height}) size,
}) async {
  _overlayShown = true;
  _dragLocked = config.dragLocked;
  await resizeOverlayWindow(size);
  // 凭证先于配置下发：新栏位在收到 config 后立刻开始连接，先到才能生效。
  await shareOverlayCredential(roomCookieBindings);
  await shareOverlayConfig(config);
}

/// 建窗并下发配置。
///
/// `showOverlay` 的宽高按**物理像素**设置（插件内部不再换算），故这里乘设备像素比；
/// 后续改尺寸走 [resizeOverlayWindow]，那条路径传的是 dp。
///
/// [screen] 是当前屏幕的逻辑尺寸：保存过窗口位置时用它把越界的存量坐标收敛回来。
Future<void> openOverlay(
  OverlayConfig config, {
  required double devicePixelRatio,
  required ({double width, double height}) size,
  required ({double width, double height}) screen,
}) async {
  await FlutterScreenOverlay.showOverlay(
    width: (size.width * devicePixelRatio).round(),
    height: (size.height * devicePixelRatio).round(),
    alignment: OverlayAlignment.centerRight,
    enableDrag: !config.dragLocked,
    positionGravity: PositionGravity.auto,
    // 有保存过位置就按它还原；没保存过（null）交给插件按默认位置摆放。
    startPosition: _resolveStartPosition(config, size: size, screen: screen),
    // 建窗时就要带上穿透状态：窗口一旦不可触摸，窗内没有入口改回来。
    flag: config.clickThrough
        ? OverlayFlag.clickThrough
        : OverlayFlag.defaultFlag,
    overlayTitle: 'DanmuFloat',
    overlayContent: '正在显示弹幕悬浮窗',
  );
  _overlayShown = true;
  _dragLocked = config.dragLocked;
  // 窗口建立后下发配置：此时悬浮窗引擎已随主 App 启动预热完毕。
  await shareOverlayCredential(roomCookieBindings);
  await shareOverlayConfig(config);
}

/// 还原上次保存的窗口位置（dp）；从未保存过或只有一个坐标时返回 null。
///
/// 存量坐标在换设备 / 旋转后可能越界，建窗前先用 [fitOverlayOffset] 收敛到当前屏幕内。
OverlayPosition? _resolveStartPosition(
  OverlayConfig config, {
  required ({double width, double height}) size,
  required ({double width, double height}) screen,
}) {
  final double? x = config.windowX;
  final double? y = config.windowY;
  if (x == null || y == null) return null;
  final ({double x, double y}) offset = fitOverlayOffset(
    (x: x, y: y),
    size: size,
    screenWidth: screen.width,
    screenHeight: screen.height,
  );
  return OverlayPosition(offset.x, offset.y);
}

/// 把「主播 → 凭证」绑定同步给悬浮窗引擎（prd F27）；空映射表示全部匿名自动获取。
///
/// 窗口没开时静默忽略：消息通道另一端没有监听者，下次建窗会随配置补发。
Future<void> shareOverlayCredential(Map<String, String> roomCookies) async {
  if (!_overlayShown) return;
  await FlutterScreenOverlay.shareData(OverlayCredential(roomCookies).toJson());
}

Future<void> shareOverlayConfig(OverlayConfig config) =>
    FlutterScreenOverlay.shareData(config.toJson());

/// 只推样式（透明度 + 字号 + 滚动速度 + 各栏覆盖 + 皮肤 / 标识 / 焦点行为 / 锁定），
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
  bool dragLocked = false,
  bool clickThrough = false,
  double screenWidth = 0,
  double screenHeight = 0,
}) async {
  // 主 App 侧的偏好是权威值：先记下锁定状态，后续改尺寸才不会被拖动开关冲掉。
  _dragLocked = dragLocked;
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
      dragLocked: dragLocked,
      clickThrough: clickThrough,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
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

/// 过滤偏好变化流（悬浮窗里把用户 / 文本加入屏蔽后由主 App 落盘的那份）。
///
/// 广播分发：首页、弹幕页等已打开的页面都按同一份口径刷新展示，
/// 避免一处改了屏蔽词、另一处还按旧口径显示。
Stream<FilterPrefs> get filterChangedStream =>
    (_filterController ??= StreamController<FilterPrefs>.broadcast()).stream;

StreamController<FilterPrefs>? _filterController;

/// 主 App 侧的过滤偏好存储（只为落盘悬浮窗内改动的过滤项）。
final FilterStore _filterStore = FilterStore();

StreamController<OverlayStatus> _relayOverlayStatus() {
  final StreamController<OverlayStatus> controller =
      StreamController<OverlayStatus>.broadcast();
  FlutterScreenOverlay.overlayListener.listen((dynamic message) {
    // 悬浮窗引擎没有剪贴板通道，复制请求从这里落到主 App 执行。
    final OverlayClipboard? clipboard = OverlayClipboard.tryParse(message);
    if (clipboard != null) {
      unawaited(Clipboard.setData(ClipboardData(text: clipboard.text)));
      return;
    }
    final OverlayStatus? status = OverlayStatus.tryParse(message);
    if (status == null) return;
    if (status.filter != null) unawaited(_persistFilter(status.filter!));
    if (!controller.isClosed) controller.add(status);
  }, onError: (Object error) => debugPrint('悬浮窗状态流异常: $error'));
  return controller;
}

/// 悬浮窗里改了过滤偏好：主 App 落盘并广播，供各页面刷新同一份口径。
Future<void> _persistFilter(FilterPrefs prefs) async {
  try {
    await _filterStore.save(prefs);
  } on Object catch (exception) {
    debugPrint('落盘过滤偏好失败: $exception');
  }
  if (!(_filterController?.isClosed ?? true)) _filterController!.add(prefs);
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
