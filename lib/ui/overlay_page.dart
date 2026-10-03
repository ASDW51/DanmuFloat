// 悬浮窗内容（prd F2 / F3）：1~9 栏布局，每栏独立会话、独立缓存、
// 独立滚动位置，栏与栏之间互不影响。
//
// 运行在独立 Flutter 引擎（前台服务进程内）：签名、房间信息、WebSocket 连接与
// 弹幕解析都在这个引擎里完成，因此每栏直接持有自己的 LiveDanmuSession，
// 而不是从主 App 接收弹幕——主 App 被杀不影响悬浮窗（prd 4.11）。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/auto_scroll.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

/// 每栏保留的弹幕条数上限，与 design.md 第 8 章默认缓存一致。
const int _displayLimit = 500;

/// 长按上下滑动调透明度的行程（dp）：滑过约一屏高即走完 0.2~0.8 的全程。
const double _gestureOpacityTravel = 240;

/// 悬浮窗配色（prd F20 样式预设）：深色为默认，浅色用于亮色直播画面。
///
/// 深浅两套在**同一处**收敛，避免把颜色散落在各个 build 里——
/// 否则加一套皮肤就得满文件找硬编码色值。
class OverlayPalette {
  const OverlayPalette({
    required this.isLight,
    required this.body,
    required this.secondary,
    required this.chrome,
    required this.divider,
    required this.bannerBg,
    required this.maskColor,
    required this.border,
    required this.userAccent,
    required this.levelColor,
    required this.fanLevelColor,
    required this.activeColor,
    required this.highlightStyle,
  });

  /// 是否为浅色皮肤。
  final bool isLight;

  /// 正文默认色（单栏未覆盖文字颜色时使用）。
  final Color body;

  /// 次要文字：状态提示、空列表占位、切换箭头等。
  final Color secondary;

  /// 栏目标识行的主播名等较醒目的文字。
  final Color chrome;

  /// 分隔线（栏间、标题行下方）。
  final Color divider;

  /// 底部进场单行底色。
  final Color bannerBg;

  /// 弹幕背景蒙版的基础色：深色皮肤为黑，浅色皮肤为白。
  final Color maskColor;

  /// 窗口边框色。
  final Color border;

  /// 用户昵称色。
  final Color userAccent;

  /// 荣誉等级（Lv.x）色。
  final Color levelColor;

  /// 粉丝灯牌等级色。
  final Color fanLevelColor;

  /// 「已生效」状态色：暂停中 / 焦点态按钮等。
  final Color activeColor;

  /// 高亮词样式（prd F11）：浅色皮肤下换成深色字 + 浅黄底，否则看不见。
  final TextStyle highlightStyle;

  static const OverlayPalette darkPalette = OverlayPalette(
    isLight: false,
    body: Colors.white,
    secondary: Colors.white54,
    chrome: Colors.white,
    divider: Colors.white24,
    bannerBg: Colors.white10,
    maskColor: Colors.black,
    border: Colors.white24,
    userAccent: Colors.lightBlueAccent,
    levelColor: Colors.amber,
    fanLevelColor: Colors.purpleAccent,
    activeColor: Colors.greenAccent,
    highlightStyle: TextStyle(
      color: Colors.yellowAccent,
      fontWeight: FontWeight.bold,
      backgroundColor: Color(0x38FFEB3B),
    ),
  );

  static const OverlayPalette lightPalette = OverlayPalette(
    isLight: true,
    body: Color(0xFF1B1B1B),
    secondary: Colors.black54,
    chrome: Colors.black87,
    divider: Colors.black26,
    bannerBg: Colors.black12,
    maskColor: Colors.white,
    border: Colors.black26,
    userAccent: Color(0xFF1565C0),
    levelColor: Color(0xFF8D6E00),
    fanLevelColor: Color(0xFF7B1FA2),
    activeColor: Color(0xFF2E7D32),
    highlightStyle: TextStyle(
      color: Color(0xFF7A4F00),
      fontWeight: FontWeight.bold,
      backgroundColor: Color(0x55FFC107),
    ),
  );

  /// 按皮肤开关取配色。
  static OverlayPalette of(bool light) => light ? lightPalette : darkPalette;

  /// 各类型在皮肤上的配色（列表过滤与类型前缀文案见 danmaku_display.dart）：
  /// 普通弹幕正文用 [body]；其余类型前缀与正文同色（prd F13 类型区分）。
  Color? typeColor(DanmakuKind kind) => isLight
      ? switch (kind) {
          DanmakuKind.screenChat => const Color(0xFFE65100),
          DanmakuKind.privilegeScreenChat => const Color(0xFF2E7D32),
          DanmakuKind.gift => const Color(0xFFC2185B),
          DanmakuKind.member => const Color(0xFF00695C),
          DanmakuKind.like => const Color(0xFFC62828),
          DanmakuKind.social => const Color(0xFF1565C0),
          DanmakuKind.roomRank => const Color(0xFF8D6E00),
          _ => null,
        }
      : switch (kind) {
          DanmakuKind.screenChat => Colors.orangeAccent,
          DanmakuKind.privilegeScreenChat => Colors.lightGreenAccent,
          DanmakuKind.gift => Colors.pinkAccent,
          DanmakuKind.member => Colors.tealAccent,
          DanmakuKind.like => Colors.redAccent,
          DanmakuKind.social => Colors.lightBlueAccent,
          DanmakuKind.roomRank => Colors.amberAccent,
          _ => null,
        };
}

/// 悬浮窗入口点对应的 App，由 `overlayMain()` 启动。
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) =>
      MaterialApp(debugShowCheckedModeBanner: false, home: const OverlayPage());
}

class OverlayPage extends StatefulWidget {
  const OverlayPage({super.key});

  @override
  State<OverlayPage> createState() => _OverlayPageState();
}

/// 单栏上报给悬浮窗页的聚合信息。
class _PaneReport {
  const _PaneReport({
    required this.webRid,
    required this.stage,
    required this.received,
    this.error,
  });

  final String webRid;
  final LiveSessionStage stage;
  final int received;
  final String? error;
}

/// 悬浮窗内的轻提示（悬浮窗没有 Scaffold，用弹窗代替 SnackBar）。
///
/// 页面级（悬浮球菜单）与栏级（弹幕行菜单）共用同一套弹窗外观。
Future<void> showOverlayNotice(
  BuildContext context,
  String title,
  String message,
) async {
  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

class _OverlayPageState extends State<OverlayPage> {
  StreamSubscription<dynamic>? _bridgeSubscription;

  List<String> _webRids = const <String>[];

  /// 栏位网格由当前栏位数实时推导。
  ///
  /// 不再跟着 config 下发缓存成字段：本地增 / 减栏位后布局必须立刻生效，
  /// 否则新增的栏位会被旧网格的行列数裁掉，看起来「栏位加了但没显示」。
  OverlayGrid get _grid => OverlayGrid(_webRids.length);

  double _opacity = defaultOverlayOpacity;
  double _fontSize = defaultDanmuFontSize;
  double _scrollSpeed = defaultDanmuScrollSpeed;

  /// 全局过滤偏好（prd F10 屏蔽 / F11 高亮 / F13 类型筛选）：各栏共用同一份。
  FilterPrefs _filter = const FilterPrefs();

  /// 各栏样式覆盖（prd F5），按 webRid 索引。
  Map<String, PaneStyle> _paneStyles = const <String, PaneStyle>{};

  /// 是否浅色皮肤（prd F20）。
  bool _lightTheme = false;

  /// 是否显示栏目标识行（prd F6）。
  bool _showTitleBar = true;

  /// 焦点模式其余栏的处理方式（prd F7）。
  String _focusBehavior = defaultFocusBehavior;

  /// 当前放大的栏位序号（prd F7）；null 表示平铺。
  int? _focusIndex;

  /// 手势临时调整的各栏透明度（prd F21），按栏位序号；仅本次会话有效。
  final Map<int, double> _gestureOpacity = <int, double>{};

  /// 长按调透明度期间是否已临时关闭窗口拖动（prd F21），避免重复下发。
  bool _gestureDragLock = false;

  /// 是否锁定窗口移动（悬浮球菜单可切换）。锁定后拖动落在栏内列表上，
  /// 弹幕才能正常滚动——插件会把窗口内任何超过 5px 的滑动都当作搬窗口。
  bool _dragLocked = false;

  /// 是否开启点击穿透（设置页 / 悬浮球菜单 / 通知栏按钮三处可切换）：
  /// 开启后窗口不接收触摸，点击直接落到下层画面，窗内所有交互失效。
  bool _clickThrough = false;

  /// 最近一次原生上报的窗口位置（dp）；用于去重，位置没变就不必重复落盘。
  double? _windowX;
  double? _windowY;

  /// 设备屏幕逻辑尺寸，随样式消息从主 App 下发（悬浮窗引擎查不到屏幕尺寸）；
  /// 0 表示未知，此时改尺寸只按固定上下限收敛。
  double _screenWidth = 0;
  double _screenHeight = 0;

  /// 悬浮球菜单是否展开。
  bool _menuOpen = false;

  /// 悬浮球吸附在窗口的哪个角（0 左上 / 1 右上 / 2 左下 / 3 右下）。
  int _ballCorner = 0;

  /// 是否临时隐藏悬浮球（仅本次会话有效）：隐藏后双击窗口任意位置唤回，
  /// 不落盘——否则下次开窗用户会找不到入口。
  bool _ballHidden = false;

  /// 本窗口当前的逻辑尺寸；展开菜单时取一次，之后随本地改尺寸同步。
  Size _windowSize = Size.zero;

  /// 悬浮球里改动、待上报给主 App 落盘的偏好增量。
  OverlayPrefsPatch? _pendingPatch;

  /// 列表菜单里改的过滤偏好（屏蔽用户 / 屏蔽词），随下次上报交主 App 落盘。
  /// 悬浮窗引擎写不了主 App 的过滤文件，只能整份带回去覆盖。
  FilterPrefs? _pendingFilter;

  /// 可在栏内快速切换的候选房间（prd F14 / F15），来自主 App 的主播列表。
  List<RoomOption> _roomOptions = const <RoomOption>[];

  /// 各栏最新上报，用于向主 App 汇报整体状态（主 App 不展示逐栏明细）。
  final Map<int, _PaneReport> _reports = <int, _PaneReport>{};
  Timer? _reportTimer;

  /// 权限被撤销后各栏已卸载，之后的上报统一按「权限已撤销」发送，
  /// 免得又被后续的栏位上报覆盖回正常状态。
  bool _permissionRevoked = false;

  @override
  void initState() {
    super.initState();
    // 插件在主 App 启动时就会预热本引擎，此处尽早注册监听，
    // 避免主 App 下发 config 时消息无人接收。
    _bridgeSubscription = FlutterScreenOverlay.overlayListener.listen(
      _onBridgeMessage,
    );
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _bridgeSubscription?.cancel();
    super.dispose();
  }

  void _onBridgeMessage(dynamic message) {
    if (isOverlayCloseMessage(message)) {
      // 主 App 关闭窗口前会下发本指令：卸载各栏以断开连接、清空内存缓存。
      setState(() {
        _webRids = const <String>[];
        _reports.clear();
        _focusIndex = null;
        _gestureOpacity.clear();
      });
      _reportState();
      return;
    }
    // 手动凭证同步（prd F27）：只改本引擎的取值来源，不动已建立的连接，
    // 各栏下次连接（新建 / 重连）时按新凭证取。
    final OverlayCredential? credential = OverlayCredential.tryParse(message);
    if (credential != null) {
      setManualCookies(credential.cookies);
      return;
    }
    // 纯样式调整：只改外观，各栏绑定与缓存都不动。
    final OverlayStyle? style = OverlayStyle.tryParse(message);
    if (style != null) {
      final bool lockChanged = style.dragLocked != _dragLocked;
      final bool clickThroughChanged = style.clickThrough != _clickThrough;
      setState(() {
        _opacity = style.opacity;
        _fontSize = style.fontSize;
        _scrollSpeed = style.scrollSpeed;
        _paneStyles = style.paneStyles;
        _lightTheme = style.lightTheme;
        _showTitleBar = style.showTitleBar;
        _focusBehavior = style.focusBehavior;
        _dragLocked = style.dragLocked;
        _clickThrough = style.clickThrough;
        if (style.screenWidth > 0) _screenWidth = style.screenWidth;
        if (style.screenHeight > 0) _screenHeight = style.screenHeight;
      });
      // 主 App 改了锁定状态（如换设备 / 恢复备份）时同步插件的拖动开关。
      if (lockChanged) _syncDragEnabled();
      // 主 App 设置页改了点击穿透：同步窗口 flag（插件只在悬浮窗引擎注册该通道）。
      if (clickThroughChanged) unawaited(_applyClickThrough(_clickThrough));
      return;
    }
    // 纯过滤调整：屏蔽 / 高亮 / 类型筛选，改了只影响后续判定，已有列表按新口径重建。
    final FilterPrefs? filter = OverlayFilter.tryParse(message);
    if (filter != null) {
      setState(() => _filter = filter);
      return;
    }
    // 通知栏「关闭点击穿透」按钮（原生侧改完 flag 后下发）：穿透开启时窗内收不到
    // 触摸，这是就地关掉的唯一入口，收到后把本地开关与待落盘增量同步过去。
    final OverlayClickThrough? clickThrough = OverlayClickThrough.tryParse(
      message,
    );
    if (clickThrough != null) {
      _setClickThrough(clickThrough.value);
      return;
    }
    // 原生上报窗口位置（拖动结束 / 贴边吸附收敛）：并入偏好增量交主 App 落盘，
    // 下次开窗按保存的位置还原。
    final OverlayWindowPosition? position = OverlayWindowPosition.tryParse(
      message,
    );
    if (position != null) {
      _onWindowPosition(position);
      return;
    }
    // 候选房间更新（prd F14 / F15）：只刷新切换弹窗里的可选项，不动各栏绑定。
    final List<RoomOption>? options = OverlayRooms.tryParse(message);
    if (options != null) {
      setState(() => _roomOptions = options);
      return;
    }
    final OverlayConfig? config = OverlayConfig.tryParse(message);
    if (config == null) return;
    final bool clickThroughChanged = config.clickThrough != _clickThrough;
    setState(() {
      _webRids = config.webRids;
      _opacity = config.opacity;
      _fontSize = config.fontSize;
      _scrollSpeed = config.scrollSpeed;
      _filter = config.filter;
      _paneStyles = config.paneStyles;
      _roomOptions = config.roomOptions;
      _lightTheme = config.lightTheme;
      _showTitleBar = config.showTitleBar;
      _focusBehavior = config.focusBehavior;
      _dragLocked = config.dragLocked;
      _ballCorner = config.ballCorner;
      _clickThrough = config.clickThrough;
      // 建窗时已按保存位置还原过，记下来当去重基准（旧配置没有该字段则不覆盖）。
      if (config.windowX != null) _windowX = config.windowX;
      if (config.windowY != null) _windowY = config.windowY;
      // 布局或房间变化会重建对应栏位，旧栏位的上报先作废。
      _reports.clear();
      // 栏位重排后原来的焦点与手势透明度都不再对应同一栏，一并复位。
      _focusIndex = null;
      _gestureOpacity.clear();
      // 重新授权后主 App 会再下发一次配置，此时恢复正常上报。
      _permissionRevoked = false;
    });
    // 复用已存在的窗口重排时（resizeOverlay 路径）不会重置窗口 flag，这里补一次。
    if (clickThroughChanged) unawaited(_applyClickThrough(_clickThrough));
  }

  /// 在悬浮窗内切换某栏绑定的直播间（prd F15 / F8）。
  ///
  /// 只改本栏绑定：栏位 key 含 webRid，改绑后该栏重建并新建会话，其余栏不受影响。
  /// 最新绑定经 [OverlayStatus.webRids] 回报给主 App 落盘持久化。
  void _rebindPane(int index, String webRid) {
    if (index < 0 || index >= _webRids.length) return;
    if (_webRids[index] == webRid) return;
    final List<String> next = List<String>.of(_webRids);
    next[index] = webRid;
    setState(() {
      _webRids = next;
      _reports.remove(index);
    });
    _reportState();
  }

  void _onPaneReport(int index, _PaneReport report) {
    _reports[index] = report;
    _scheduleReport();
  }

  /// 状态按秒节流上报，避免每条弹幕都发一次消息。
  void _scheduleReport() {
    if (_reportTimer?.isActive ?? false) return;
    _reportTimer = Timer(const Duration(seconds: 1), _onReportTick);
  }

  /// 节流到点：顺带核对一次权限，被撤销就卸载各栏断开全部连接。
  ///
  /// 悬浮窗跑在独立引擎里，权限查询通道未必注册到本引擎；查不到只当未知，
  /// 不能因为一次查询失败就误关窗口。
  Future<void> _onReportTick() async {
    if (!_permissionRevoked && await _permissionGone()) {
      if (!mounted) return;
      setState(() {
        _permissionRevoked = true;
        // 清空各栏 → 各栏 dispose → 断开全部直播间连接。
        _webRids = const <String>[];
        _reports.clear();
      });
    }
    _reportState();
  }

  Future<bool> _permissionGone() async {
    try {
      return !await FlutterScreenOverlay.isPermissionGranted();
    } on Object {
      return false;
    }
  }

  /// 阶段聚合优先级：异常 / 未开播最需要用户注意，其次是连接成功，再是进行中。
  static const List<LiveSessionStage> _stagePriority = <LiveSessionStage>[
    LiveSessionStage.error,
    LiveSessionStage.offline,
    LiveSessionStage.live,
    LiveSessionStage.connecting,
    LiveSessionStage.signing,
    LiveSessionStage.resolvingRoom,
    LiveSessionStage.idle,
  ];

  void _reportState() {
    if (_permissionRevoked) {
      unawaited(
        FlutterScreenOverlay.shareData(
          const OverlayStatus(
            stage: LiveSessionStage.error,
            received: 0,
            error: '悬浮窗权限已被撤销，已断开全部连接',
            permissionRevoked: true,
          ).toJson(),
        ),
      );
      return;
    }
    int received = 0;
    String? error;
    String? webRid;
    for (final _PaneReport report in _reports.values) {
      received += report.received;
      error ??= report.error;
      if (report.webRid.isNotEmpty && webRid == null) webRid = report.webRid;
    }
    LiveSessionStage stage = LiveSessionStage.idle;
    for (final LiveSessionStage candidate in _stagePriority) {
      if (_reports.values.any((_PaneReport r) => r.stage == candidate)) {
        stage = candidate;
        break;
      }
    }
    unawaited(
      FlutterScreenOverlay.shareData(
        OverlayStatus(
          stage: stage,
          received: received,
          webRid: webRid,
          error: error,
          webRids: _webRids,
          // 悬浮球里改的透明度 / 尺寸 / 锁定随本次上报带给主 App 落盘；
          // 带出去后就清空，避免每秒重复上报同一个值。
          prefsPatch: _takePendingPatch(),
          // 列表菜单里加的屏蔽用户 / 屏蔽词同理，整份带回去覆盖落盘。
          filter: _takePendingFilter(),
        ).toJson(),
      ),
    );
  }

  /// 取出待落盘的偏好增量并清空。
  OverlayPrefsPatch? _takePendingPatch() {
    final OverlayPrefsPatch? patch = _pendingPatch;
    _pendingPatch = null;
    return patch;
  }

  /// 取出待落盘的过滤偏好并清空。
  FilterPrefs? _takePendingFilter() {
    final FilterPrefs? filter = _pendingFilter;
    _pendingFilter = null;
    return filter;
  }

  /// 列表菜单里把某用户 / 某段文本加入屏蔽：立即按新口径刷新本窗口展示，
  /// 并把整份过滤偏好交主 App 落盘（悬浮窗引擎写不了主 App 的偏好文件）。
  void _onPaneFilterChanged(FilterPrefs prefs) {
    setState(() {
      _filter = prefs;
      _pendingFilter = prefs;
    });
    _reportState();
  }

  @override
  Widget build(BuildContext context) {
    final OverlayPalette palette = OverlayPalette.of(_lightTheme);
    return Material(
      color: Colors.transparent,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          // 有栏位时背景由各栏自己画（prd F5 每栏透明度可不同）；
          // 无栏位（等待配置）时退回全局透明度，避免窗口完全透明看不见。
          color: _webRids.isEmpty
              ? palette.maskColor.withValues(alpha: _opacity)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: palette.border),
        ),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: _webRids.isEmpty ? _buildPlaceholder() : _buildPanes(),
            ),
            // 悬浮球：点开是一个功能菜单（锁定移动 / 栏位增删与切换 / 尺寸 / 透明度）。
            // 悬浮窗没有系统控件，窗口内的操作入口只能自己画。
            if (!_ballHidden) _buildBallLayer(palette),
            if (_menuOpen && !_ballHidden) _buildMenuLayer(palette),
            // 悬浮球隐藏后唯一的唤回入口：双击窗口任意位置。
            // 用 translucent 命中，弹幕列表的滑动不受影响。
            if (_ballHidden)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: _revealBall,
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 悬浮球所在的角：吸附到用户选的位置。
  ///
  /// 四角都贴边 3dp；菜单在球的反侧收边 30dp（球径 24 + 间隙），
  /// 展开时球正好落在菜单外侧，不会被菜单盖住。
  Widget _buildBallLayer(OverlayPalette palette) {
    final bool right = _ballCorner.isOdd;
    final bool bottom = _ballCorner >= 2;
    return Positioned(
      left: right ? null : 3,
      right: right ? 3 : null,
      top: bottom ? null : 3,
      bottom: bottom ? 3 : null,
      child: _buildBall(palette),
    );
  }

  /// 悬浮球菜单：铺满窗口在球反侧的剩余空间，球在下方时从下往上展开。
  Widget _buildMenuLayer(OverlayPalette palette) {
    final bool bottom = _ballCorner >= 2;
    return Positioned(
      left: 3,
      right: 3,
      top: bottom ? 3 : 30,
      bottom: bottom ? 30 : 3,
      child: _buildMenu(palette),
    );
  }

  /// 悬浮球：未展开时是「调节」图标，展开后变成关闭图标。
  ///
  /// 闲置时半透明，避免一个小圆钮一直压在弹幕上；展开或按下时加深到接近不透明。
  Widget _buildBall(OverlayPalette palette) => Opacity(
    opacity: _menuOpen ? 0.95 : 0.4,
    child: Material(
      color: palette.isLight ? Colors.white70 : Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => setState(() {
          _menuOpen = !_menuOpen;
          // 展开时按当前实际窗口尺寸初始化滑杆取值。
          if (_menuOpen) _windowSize = MediaQuery.sizeOf(context);
        }),
        child: SizedBox(
          width: 24,
          height: 24,
          child: Icon(
            _menuOpen ? Icons.close : Icons.tune,
            size: 15,
            color: palette.chrome,
          ),
        ),
      ),
    ),
  );

  /// 悬浮球展开的功能菜单：紧凑排版并整体可滚动，
  /// 窗口被调小时也不会溢出（prd F2 延伸：尺寸 / 透明度等设置在悬浮窗内即可调）。
  Widget _buildMenu(OverlayPalette palette) {
    final double base = paneFontSize(_fontSize, _webRids.length);
    final double label = smallerFontSize(base, 2);
    final double widthLimit = _screenWidth > 0
        ? overlayWidthLimit(_screenWidth)
        : maxOverlayWidth;
    final double heightLimit = _screenHeight > 0
        ? overlayHeightLimit(_screenHeight)
        : maxOverlayHeight;
    final double currentWidth = _windowSize.width.clamp(
      minOverlayWidth,
      widthLimit,
    );
    final double currentHeight = _windowSize.height.clamp(
      minOverlayHeight,
      heightLimit,
    );

    return Material(
      color: palette.isLight
          ? Colors.white.withValues(alpha: 0.94)
          : Colors.black.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(8),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '锁定移动',
                    style: TextStyle(color: palette.chrome, fontSize: label),
                  ),
                ),
                Switch(
                  value: _dragLocked,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (bool _) => _toggleDragLock(),
                ),
              ],
            ),
            Text(
              _dragLocked ? '已锁定：拖动用于滚动弹幕' : '未锁定：拖动会移动悬浮窗',
              style: TextStyle(color: palette.secondary, fontSize: label),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '点击穿透',
                    style: TextStyle(color: palette.chrome, fontSize: label),
                  ),
                ),
                Switch(
                  value: _clickThrough,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (bool _) => unawaited(_toggleClickThrough()),
                ),
              ],
            ),
            Text(
              _clickThrough ? '已开启：点击落到下层画面，窗内无法操作' : '开启后点击可落到下层画面（窗内交互会失效）',
              style: TextStyle(color: palette.secondary, fontSize: label),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                _menuButton(palette, label, '添加栏位', _addPane),
                _menuButton(
                  palette,
                  label,
                  '减少栏位',
                  _webRids.length > 1 ? _removePane : null,
                ),
                _menuButton(palette, label, '栏位管理', _managePanes),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '悬浮球位置',
              style: TextStyle(color: palette.chrome, fontSize: label),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                for (int corner = 0; corner < ballCornerCount; corner++)
                  _menuButton(
                    palette,
                    label,
                    ballCornerLabels[corner],
                    corner == _ballCorner ? null : () => _setBallCorner(corner),
                  ),
                _menuButton(palette, label, '隐藏悬浮球', _hideBall),
              ],
            ),
            _menuSlider(
              palette,
              label,
              '透明度　${_opacity.toStringAsFixed(2)}',
              _opacity,
              minOverlayOpacity,
              maxOverlayOpacity,
              20,
              _setGlobalOpacity,
            ),
            _menuSlider(
              palette,
              label,
              '弹幕字号　${_fontSize.toStringAsFixed(0)}',
              _fontSize,
              minDanmuFontSize,
              maxDanmuFontSize,
              (maxDanmuFontSize - minDanmuFontSize).round(),
              _setGlobalFontSize,
            ),
            _menuSlider(
              palette,
              label,
              '窗口宽度　${currentWidth.toStringAsFixed(0)}',
              currentWidth,
              minOverlayWidth,
              widthLimit,
              ((widthLimit - minOverlayWidth) / 20).round(),
              (double value) => _setWindowSize(value, currentHeight),
            ),
            _menuSlider(
              palette,
              label,
              '窗口高度　${currentHeight.toStringAsFixed(0)}',
              currentHeight,
              minOverlayHeight,
              heightLimit,
              ((heightLimit - minOverlayHeight) / 20).round(),
              (double value) => _setWindowSize(currentWidth, value),
            ),
            Row(
              children: <Widget>[
                _menuButton(palette, label, '适配尺寸', _fitWindowToPaneCount),
                const SizedBox(width: 4),
                _menuButton(palette, label, '关闭悬浮窗', _closeOverlayFromMenu),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 菜单里的小按钮；[onPressed] 为 null 时禁用。
  Widget _menuButton(
    OverlayPalette palette,
    double fontSize,
    String text,
    VoidCallback? onPressed,
  ) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: palette.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    child: Text(text, style: TextStyle(fontSize: fontSize)),
  );

  /// 菜单里的一行滑杆（标题 + 滑杆），实时生效。
  Widget _menuSlider(
    OverlayPalette palette,
    double fontSize,
    String title,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        title,
        style: TextStyle(color: palette.chrome, fontSize: fontSize),
      ),
      SliderTheme(
        data: SliderThemeData(
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions <= 0 ? null : divisions,
          onChanged: onChanged,
        ),
      ),
    ],
  );

  Widget _buildPlaceholder() => Center(
    child: Text(
      '等待配置',
      style: TextStyle(
        color: OverlayPalette.of(_lightTheme).secondary,
        fontSize: 12,
      ),
    ),
  );

  /// 切换某栏的焦点态（prd F7）：已放大则还原，否则放大该栏。
  void _toggleFocus(int index) {
    setState(() {
      _focusIndex = _focusIndex == index ? null : index;
    });
  }

  /// 手势改某栏透明度（prd F21）：只改本次会话内的临时值，不落盘。
  void _setPaneOpacity(int index, double opacity) {
    setState(() => _gestureOpacity[index] = clampOverlayOpacity(opacity));
  }

  /// 长按调透明度期间临时开关窗口拖动（prd F21）。
  ///
  /// 插件把位移超过 5px 的滑动都用来移动窗口，会和栏内上下滑动抢手势，
  /// 因此按住时先按当前窗口尺寸原样重发一次 resizeOverlay 关掉拖动，松手恢复；
  /// 与悬浮球的持久锁定共用同一个开关（任一为真都不允许拖动）。
  void _setDragLock(bool locked) {
    if (_gestureDragLock == locked) return;
    _gestureDragLock = locked;
    _syncDragEnabled();
  }

  /// 是否处于「不允许拖动窗口」状态：持久锁定或长按调透明度期间。
  bool get _dragDisabled => _dragLocked || _gestureDragLock;

  /// 按当前锁定状态重发一次窗口尺寸，只为了改插件的拖动开关（尺寸不变）。
  void _syncDragEnabled() {
    // 栏位在关窗 / 重排时会被卸载，卸载途中补发的请求直接丢弃：
    // 此时窗口已不存在或即将重建，查 View 也会拿到已失活的祖先。
    if (!mounted) return;
    // 插件 resizeOverlay 按 dp 换算物理像素，所以这里要传当前窗口的**逻辑尺寸**，
    // 不能传 View 的物理尺寸（否则会被再乘一次像素比，窗口撑满屏幕）。
    final Size size = MediaQuery.sizeOf(context);
    unawaited(
      setOverlayDragEnabled(
        !_dragDisabled,
        width: size.width.round(),
        height: size.height.round(),
      ),
    );
  }

  /// 悬浮球菜单里的「锁定移动」开关。
  void _toggleDragLock() {
    setState(() {
      _dragLocked = !_dragLocked;
      _mergePatch(dragLocked: _dragLocked);
    });
    _syncDragEnabled();
    _reportState();
  }

  /// 悬浮球菜单里的「点击穿透」开关。
  ///
  /// 开启后窗口立刻不再接收触摸，窗内任何按钮都点不到，因此先把提示读完再生效；
  /// 关闭入口只保留通知栏按钮与主 App 设置页（窗内已点不到）。
  Future<void> _toggleClickThrough() async {
    if (_clickThrough) {
      _setClickThrough(false);
      return;
    }
    await _showNotice(
      '开启点击穿透',
      '开启后悬浮窗不再接收触摸，点击会直接落到下层画面。\n\n'
          '此时窗内菜单、列表滚动与长按调透明度都会失效，'
          '可下拉通知栏点「关闭点击穿透」，或回到主 App 设置页关闭。',
    );
    if (!mounted) return;
    _setClickThrough(true);
  }

  /// 切换点击穿透：更新本地开关、记待落盘增量、同步窗口 flag 并回报主 App。
  void _setClickThrough(bool value) {
    if (value == _clickThrough) return;
    setState(() {
      _clickThrough = value;
      // 穿透生效后菜单点不到，先收起，回来时是干净状态。
      _menuOpen = false;
      _mergePatch(clickThrough: value);
    });
    unawaited(_applyClickThrough(value));
    _reportState();
  }

  /// 把穿透状态同步到窗口 flag（插件 updateFlag，只在悬浮窗引擎注册了该通道）。
  Future<void> _applyClickThrough(bool value) async {
    try {
      await FlutterScreenOverlay.updateFlag(
        value ? OverlayFlag.clickThrough : OverlayFlag.defaultFlag,
      );
    } on Object catch (exception) {
      debugPrint('切换点击穿透失败: $exception');
    }
  }

  /// 合并一次待落盘的偏好增量（同字段以最新值为准）。
  void _mergePatch({
    double? opacity,
    double? fontSize,
    double? windowWidth,
    double? windowHeight,
    bool? dragLocked,
    int? ballCorner,
    bool? clickThrough,
    double? windowX,
    double? windowY,
  }) {
    final OverlayPrefsPatch base = _pendingPatch ?? const OverlayPrefsPatch();
    _pendingPatch = OverlayPrefsPatch(
      opacity: opacity ?? base.opacity,
      fontSize: fontSize ?? base.fontSize,
      windowWidth: windowWidth ?? base.windowWidth,
      windowHeight: windowHeight ?? base.windowHeight,
      dragLocked: dragLocked ?? base.dragLocked,
      ballCorner: ballCorner ?? base.ballCorner,
      clickThrough: clickThrough ?? base.clickThrough,
      windowX: windowX ?? base.windowX,
      windowY: windowY ?? base.windowY,
    );
  }

  /// 原生上报窗口位置（拖动结束 / 贴边吸附收敛后）：与上次不同才记入待落盘
  /// 增量并回报主 App，避免每次点按都重复写盘。
  void _onWindowPosition(OverlayWindowPosition position) {
    if (position.x == _windowX && position.y == _windowY) return;
    _windowX = position.x;
    _windowY = position.y;
    _mergePatch(windowX: position.x, windowY: position.y);
    _reportState();
  }

  /// 悬浮球吸附到窗口的某个角（0 左上 / 1 右上 / 2 左下 / 3 右下）。
  void _setBallCorner(int corner) {
    final int next = clampBallCorner(corner);
    if (next == _ballCorner) return;
    setState(() {
      _ballCorner = next;
      _mergePatch(ballCorner: next);
    });
    _reportState();
  }

  /// 隐藏悬浮球：入口临时收起，双击窗口任意位置唤回（仅本次会话有效）。
  void _hideBall() {
    setState(() {
      _ballHidden = true;
      _menuOpen = false;
    });
    unawaited(_showNotice('悬浮球已隐藏', '双击悬浮窗内任意位置即可重新显示。'));
  }

  /// 重新显示悬浮球（隐藏态下的双击唤回）。
  void _revealBall() => setState(() => _ballHidden = false);

  /// 悬浮球菜单里调全局透明度（只影响没有单栏覆盖的栏）。
  void _setGlobalOpacity(double value) {
    setState(() {
      _opacity = clampOverlayOpacity(value);
      _mergePatch(opacity: _opacity);
    });
    _scheduleReport();
  }

  /// 悬浮球菜单里调全局弹幕字号。
  void _setGlobalFontSize(double value) {
    setState(() {
      _fontSize = clampDanmuFontSize(value);
      _mergePatch(fontSize: _fontSize);
    });
    _scheduleReport();
  }

  /// 把窗口尺寸收敛到设备允许范围：主 App 下发过屏幕尺寸时按屏幕收敛，
  /// 否则只按固定上下限收敛（悬浮窗引擎自己查不到屏幕尺寸）。
  ({double width, double height}) _fitWindowSize(double width, double height) {
    if (_screenWidth > 0 && _screenHeight > 0) {
      return fitOverlaySize(
        (width: width, height: height),
        screenWidth: _screenWidth,
        screenHeight: _screenHeight,
      );
    }
    return (
      width: clampOverlayWidth(width),
      height: clampOverlayHeight(height),
    );
  }

  /// 悬浮球菜单里改窗口尺寸：本地立刻重排，并记下待落盘的尺寸。
  void _setWindowSize(double width, double height) {
    final ({double width, double height}) next = _fitWindowSize(width, height);
    if (next.width == _windowSize.width && next.height == _windowSize.height) {
      return;
    }
    setState(() {
      _windowSize = Size(next.width, next.height);
      _mergePatch(windowWidth: next.width, windowHeight: next.height);
    });
    // 插件 resizeOverlay 按 dp 换算物理像素，这里传逻辑尺寸。
    unawaited(
      FlutterScreenOverlay.resizeOverlay(
        next.width.round(),
        next.height.round(),
        !_dragDisabled,
      ),
    );
    _scheduleReport();
  }

  /// 悬浮球菜单里「适配尺寸」：按当前栏数套用推荐尺寸。
  void _fitWindowToPaneCount() {
    final ({double width, double height}) recommended = _fitWindowSize(
      recommendedOverlaySize(_webRids.length).width,
      recommendedOverlaySize(_webRids.length).height,
    );
    _setWindowSize(recommended.width, recommended.height);
  }

  /// 悬浮球菜单里的「添加栏位」：从未绑定的主播里挑一个追加到末尾。
  Future<void> _addPane() async {
    final Set<String> bound = _webRids.toSet();
    final List<RoomOption> candidates = <RoomOption>[
      for (final RoomOption option in _roomOptions)
        if (!bound.contains(option.webRid)) option,
    ];
    if (candidates.isEmpty) {
      await _showNotice('没有可添加的主播', '请先在主 App 的主播管理里添加更多主播。');
      return;
    }
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _RoomPickerDialog(
        options: candidates,
        current: '',
        fontSize: paneFontSize(_fontSize, _webRids.length + 1),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _webRids = <String>[..._webRids, picked];
      _reports.clear();
    });
    _reportState();
  }

  /// 悬浮球菜单里的「减少栏位」：移除最后一栏，至少保留一栏。
  void _removePane() {
    if (_webRids.length <= 1) return;
    setState(() {
      _webRids = _webRids.sublist(0, _webRids.length - 1);
      // 栏位序号整体前移，旧上报作废；焦点与手势透明度也一并复位。
      _reports.clear();
      _focusIndex = null;
      _gestureOpacity.clear();
    });
    _reportState();
  }

  /// 悬浮球菜单里的「栏位管理」：增删栏位、逐栏切换主播。
  Future<void> _managePanes() async {
    if (_roomOptions.isEmpty) {
      await _showNotice('暂无可切换的主播', '请先在主 App 的主播管理里添加主播。');
      return;
    }
    final List<String>? result = await showDialog<List<String>>(
      context: context,
      builder: (BuildContext context) => _PaneManagerDialog(
        webRids: _webRids,
        options: _roomOptions,
        fontSize: _fontSize,
      ),
    );
    if (result == null || !mounted) return;
    if (_sameWebRids(result, _webRids)) return;
    setState(() {
      _webRids = result;
      _reports.clear();
      _focusIndex = null;
      _gestureOpacity.clear();
    });
    _reportState();
  }

  bool _sameWebRids(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// 悬浮窗内的轻提示（悬浮窗没有 Scaffold，用弹窗代替 SnackBar）。
  Future<void> _showNotice(String title, String message) async {
    if (!mounted) return;
    await showOverlayNotice(context, title, message);
  }

  /// 悬浮球菜单里的「关闭悬浮窗」：先卸载各栏断开连接，再关窗。
  Future<void> _closeOverlayFromMenu() async {
    setState(() {
      _webRids = const <String>[];
      _reports.clear();
      _focusIndex = null;
      _gestureOpacity.clear();
      _menuOpen = false;
    });
    try {
      await FlutterScreenOverlay.closeOverlay();
    } on Object catch (exception) {
      debugPrint('关闭悬浮窗失败（窗口可能已被系统移除）: $exception');
    }
  }

  /// 按栏位数把窗口切成 rows × columns 网格（prd F4）：
  /// 1 栏铺满；2~4 栏 2 列；5 栏起 3 列。每格为标题行 + 弹幕列表两层。
  ///
  /// 只渲染实际存在的栏位：最后一行的空位不再补空栏，否则 3 个主播会画出 4 个格子。
  /// 焦点模式（prd F7）下按行 / 列加权：缩小让位给 3:1，隐藏则用 100:1
  /// 把非焦点栏压到近似零尺寸（仍保留 state，连接不会断）。
  Widget _buildPanes() {
    final OverlayPalette palette = OverlayPalette.of(_lightTheme);
    if (_grid.isSingle) {
      return _buildPane(index: 0, webRid: _webRids.first, palette: palette);
    }

    final int columns = _grid.columns;
    final int rows = _grid.rows;
    final int? focus = _focusIndex;
    final bool hide = _focusBehavior == focusBehaviorHide;
    final int focusRow = focus == null ? -1 : focus ~/ columns;
    final int focusColumn = focus == null ? -1 : focus % columns;

    int rowFlex(int row) =>
        focus == null ? 1 : (row == focusRow ? (hide ? 100 : 3) : 1);
    int columnFlex(int row, int column) =>
        focus != null && row == focusRow && column == focusColumn
        ? (hide ? 100 : 3)
        : 1;

    /// 非焦点栏在「隐藏」档下保留在树上但不占空间，连接与缓存照旧。
    Widget paneAt(int index) {
      final Widget pane = _buildPane(
        index: index,
        webRid: _webRids[index],
        palette: palette,
      );
      if (focus != null && hide && index != focus) {
        return Visibility(
          visible: false,
          maintainState: true,
          maintainSize: false,
          child: pane,
        );
      }
      return pane;
    }

    return Column(
      children: <Widget>[
        for (int row = 0; row < rows; row++) ...<Widget>[
          if (row > 0) Divider(height: 1, thickness: 1, color: palette.divider),
          Expanded(
            flex: rowFlex(row),
            child: Row(
              children: <Widget>[
                for (int column = 0; column < columns; column++)
                  if (row * columns + column < _webRids.length) ...<Widget>[
                    if (column > 0)
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: palette.divider,
                      ),
                    Expanded(
                      flex: columnFlex(row, column),
                      child: paneAt(row * columns + column),
                    ),
                  ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 栏位按「序号 + 房间」作 key：换房间即重建该栏，其它栏不受影响。
  ///
  /// 字号 / 透明度 / 颜色按 webRid 取单栏覆盖（prd F5），没有覆盖就用全局值；
  /// 覆盖的字号仍按栏数缩小，避免 9 栏下把某栏调大后撑破单元格。
  Widget _buildPane({
    required int index,
    required String webRid,
    required OverlayPalette palette,
  }) {
    final PaneStyle? style = _paneStyles[webRid];
    return _OverlayPane(
      key: ValueKey<String>('$index:$webRid'),
      index: index,
      webRid: webRid,
      fontSize: paneFontSize(style?.fontSize ?? _fontSize, _webRids.length),
      opacity: _gestureOpacity[index] ?? style?.opacity ?? _opacity,
      textColor: style?.textColor,
      scrollSpeed: _scrollSpeed,
      filter: _filter,
      roomOptions: _roomOptions,
      palette: palette,
      showTitleBar: _showTitleBar,
      focused: _focusIndex == index,
      // 单栏没有其它栏可让位，不显示焦点按钮。
      onToggleFocus: _grid.count > 1 ? () => _toggleFocus(index) : null,
      onOpacityChanged: (double value) => _setPaneOpacity(index, value),
      onDragLockChanged: _setDragLock,
      onSwitchRoom: (String next) => _rebindPane(index, next),
      onFilterChanged: _onPaneFilterChanged,
      onReport: _onPaneReport,
    );
  }
}

/// 单栏：独立会话、独立缓存与独立滚动位置。
class _OverlayPane extends StatefulWidget {
  const _OverlayPane({
    super.key,
    required this.index,
    required this.webRid,
    required this.fontSize,
    required this.opacity,
    required this.scrollSpeed,
    required this.filter,
    required this.roomOptions,
    required this.palette,
    required this.showTitleBar,
    required this.focused,
    required this.onOpacityChanged,
    required this.onDragLockChanged,
    required this.onSwitchRoom,
    required this.onFilterChanged,
    required this.onReport,
    this.textColor,
    this.onToggleFocus,
  });

  final int index;

  /// 本栏绑定的直播间号，空串表示未绑定房间。
  final String webRid;

  /// 本栏实际使用的正文字号（dp）：基准字号（含单栏覆盖）已按栏数缩小过。
  final double fontSize;

  /// 本栏弹幕背景蒙版不透明度（prd F5）：单栏覆盖优先，否则跟随全局；
  /// 手势调整期间由悬浮窗页下发临时值（prd F21）。
  final double opacity;

  /// 本栏正文字色（ARGB，prd F5）；null 用当前皮肤默认色。
  final int? textColor;

  /// 弹幕滚动速度倍数（prd F2「滚动速度」）。
  final double scrollSpeed;

  /// 全局过滤偏好（prd F10 / F11 / F13），各栏共用。
  final FilterPrefs filter;

  /// 可在本栏快速切换的候选房间（prd F14 / F15）；空表时标题行不可点。
  final List<RoomOption> roomOptions;

  /// 当前皮肤配色（prd F20）。
  final OverlayPalette palette;

  /// 是否渲染栏目标识行（prd F6）。
  final bool showTitleBar;

  /// 本栏是否处于焦点放大态（prd F7）。
  final bool focused;

  /// 焦点切换回调；null 表示单栏布局，不显示按钮（prd F7）。
  final VoidCallback? onToggleFocus;

  /// 手势调整本栏透明度（prd F21），由悬浮窗页记临时值并回流本栏。
  final ValueChanged<double> onOpacityChanged;

  /// 长按手势开始 / 结束时临时开关窗口拖动（prd F21）。
  final ValueChanged<bool> onDragLockChanged;

  /// 本栏改绑回调：由悬浮窗页统一改 `_webRids` 并回报主 App。
  final ValueChanged<String> onSwitchRoom;

  /// 弹幕行菜单里改了过滤偏好（屏蔽用户 / 加入屏蔽词）后回调，
  /// 由悬浮窗页刷新各栏展示并回报主 App 落盘。
  final ValueChanged<FilterPrefs> onFilterChanged;

  final void Function(int index, _PaneReport report) onReport;

  @override
  State<_OverlayPane> createState() => _OverlayPaneState();
}

class _OverlayPaneState extends State<_OverlayPane> {
  /// 本栏收到的全部相关弹幕（未过滤）。过滤在渲染时做，
  /// 这样在设置里改屏蔽词 / 类型后，已收到的弹幕也会立刻按新口径生效。
  final List<DanmakuEvent> _raw = <DanmakuEvent>[];
  final ScrollController _scrollController = ScrollController();
  late final DanmakuAutoScroller _autoScroller = DanmakuAutoScroller(
    _scrollController,
  )..speed = widget.scrollSpeed;

  StreamSubscription<LiveSessionStage>? _stageSubscription;
  StreamSubscription<DanmakuEvent>? _danmuSubscription;

  LiveDanmuSession? _session;
  LiveSessionStage _stage = LiveSessionStage.idle;
  String? _error;
  int _received = 0;

  /// 在线人数，取自最新的「xxx在线观众」房间统计消息（prd F6 栏目标识）。
  int _online = 0;

  /// 最新一条进场信息，固定显示在底部单行，不随弹幕列表滚动。
  DanmakuEvent? _latestEntry;

  /// 本栏是否已暂停（prd F9）：暂停时不自动滚动，但新弹幕仍写入缓存。
  bool _paused = false;

  /// 是否处于回溯态（prd F12）：暂停后向上翻看缓存时置位，页面显示「回到最新」。
  bool _backtracking = false;

  /// 是否正在长按上下滑动调透明度（prd F21）：期间显示数值提示。
  bool _adjustingOpacity = false;

  /// 本次长按手势开始时的透明度，滑动位移在此基准上叠加。
  double _gestureStartOpacity = defaultOverlayOpacity;

  bool get _bound => widget.webRid.isNotEmpty;

  /// 当前皮肤配色（prd F20）。
  OverlayPalette get _palette => widget.palette;

  /// 普通弹幕正文颜色：单栏覆盖优先（prd F5），否则用当前皮肤默认色。
  Color get _bodyColor =>
      widget.textColor == null ? _palette.body : Color(widget.textColor!);

  /// 按当前过滤口径派生的可见列表（prd F10 / F13）。
  List<DanmakuEvent> get _visible => <DanmakuEvent>[
    for (final DanmakuEvent event in _raw)
      if (isListKind(event.kind, widget.filter) &&
          !isBlockedBy(event, widget.filter))
        event,
  ];

  @override
  void initState() {
    super.initState();
    // 监听滚动位置以感知「向上回溯」（prd F12）：只在暂停态生效，见 _onScroll。
    _scrollController.addListener(_onScroll);
    if (!_bound) {
      _error = '未绑定房间';
      return;
    }
    // 直接赋值而不走 setState：initState 阶段本就处于 dirty 状态。
    _stage = LiveSessionStage.resolvingRoom;
    unawaited(_start());
  }

  /// 暂停态下离底超过阈值即进入回溯；回到底部则退出（prd F12 状态流转）。
  void _onScroll() {
    if (!_paused || !_scrollController.hasClients) return;
    final ScrollPosition position = _scrollController.position;
    final bool atBottom = position.maxScrollExtent - position.pixels <= 24;
    if (!atBottom && !_backtracking) {
      setState(() => _backtracking = true);
    } else if (atBottom && _backtracking) {
      setState(() => _backtracking = false);
    }
  }

  /// 暂停 / 继续本栏（prd F9）；继续时平滑追到最新一条。
  void _togglePaused() {
    setState(() {
      _paused = !_paused;
      _backtracking = false;
    });
    if (!_paused) _autoScroller.schedule();
  }

  /// 回溯态下的「回到最新」：跳到最新并恢复实时（prd F12）。
  void _backToLatest() {
    setState(() {
      _paused = false;
      _backtracking = false;
    });
    _autoScroller.jumpToLatest();
  }

  /// 单条弹幕的点击菜单：复制弹幕 / 复制 userId / 屏蔽该用户 / 加入屏蔽词。
  ///
  /// 判重下沉到弹幕行而不是整栏：栏级单击已用于双击暂停与长按调透明度，
  /// 行级 onTap 与它们共存（单击需等双击判定超时，略有延迟）。
  Future<void> _showEventMenu(DanmakuEvent event) async {
    final String userId = event.user.userId.trim();
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(event.text, maxLines: 3, overflow: TextOverflow.ellipsis),
        children: <Widget>[
          _eventMenuAction('copyText', '复制弹幕'),
          if (userId.isNotEmpty) _eventMenuAction('copyUser', '复制 userId'),
          if (userId.isNotEmpty) _eventMenuAction('blockUser', '屏蔽该用户'),
          _eventMenuAction('blockKeyword', '加入屏蔽词'),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copyText':
        await _copy(event.text);
      case 'copyUser':
        await _copy(userId);
      case 'blockUser':
        widget.onFilterChanged(withBlockedUser(widget.filter, userId));
        await _notice(
          '已屏蔽该用户',
          '${event.user.nickName}（$userId）已加入屏蔽名单，可在主 App 设置页管理。',
        );
      case 'blockKeyword':
        widget.onFilterChanged(withBlockedKeyword(widget.filter, event.text));
        await _notice('已加入屏蔽词', '「${event.text}」已加入屏蔽词，可在主 App 设置页管理。');
    }
  }

  /// 弹幕行菜单里的一项；点击后把动作标识回传给 [_showEventMenu]。
  Widget _eventMenuAction(String value, String label) => SimpleDialogOption(
    onPressed: () => Navigator.of(context).pop(value),
    child: Text(label),
  );

  /// 请主 App 代写剪贴板：悬浮窗引擎没有注册平台插件，`Clipboard` 在这里不可用。
  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    await FlutterScreenOverlay.shareData(OverlayClipboard(text).toJson());
    if (!mounted) return;
    await _notice('已复制到剪贴板', text);
  }

  /// 栏内轻提示（悬浮窗没有 Scaffold，用弹窗代替 SnackBar）。
  Future<void> _notice(String title, String message) async {
    if (!mounted) return;
    await showOverlayNotice(context, title, message);
  }

  /// 长按开始：记下起始透明度并临时关掉窗口拖动（prd F21）。
  void _onLongPressStart(LongPressStartDetails details) {
    _gestureStartOpacity = widget.opacity;
    setState(() => _adjustingOpacity = true);
    widget.onDragLockChanged(true);
  }

  /// 长按后上下滑动：向上滑提高透明度，向下滑降低（prd F21）。
  ///
  /// 位移以**起始值**为基准叠加，而不是逐帧累加，避免连续回调时累积误差。
  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final double delta = -details.offsetFromOrigin.dy / _gestureOpacityTravel;
    widget.onOpacityChanged(_gestureStartOpacity + delta);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    setState(() => _adjustingOpacity = false);
    widget.onDragLockChanged(false);
  }

  @override
  void dispose() {
    // 手势中途被卸载（关窗 / 换房）时补一次恢复，别让窗口永久失去拖动。
    if (_adjustingOpacity) widget.onDragLockChanged(false);
    _stageSubscription?.cancel();
    _danmuSubscription?.cancel();
    _session?.stop();
    _autoScroller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 样式消息改了滚动速度：同步到本栏，不重建列表。
  ///
  /// 过滤偏好变化时内存里的 [FilterPrefs] 会经 setState 重建本栏 widget，
  /// 可见列表在 build 时按新口径派生，无需在此重算。
  @override
  void didUpdateWidget(_OverlayPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _autoScroller.speed = widget.scrollSpeed;
  }

  Future<void> _start() async {
    final LiveDanmuSession session = LiveDanmuSession(webRid: widget.webRid);
    _session = session;
    _stageSubscription = session.stages.listen((LiveSessionStage stage) {
      if (!mounted) return;
      setState(() {
        _stage = stage;
        _error = session.errorMessage;
      });
      _report();
    });
    // 房间统计只用来更新在线人数、不进列表，因此过滤时不能挡掉。
    _danmuSubscription = session.danmu
        .where(
          (DanmakuEvent event) =>
              event.isDisplayable && isStreamRelevant(event.kind),
        )
        .listen(_onEvent);
    await session.start();
    if (!mounted) return;
    setState(() => _error = session.errorMessage ?? session.signatureWarning);
    _report();
  }

  void _onEvent(DanmakuEvent event) {
    if (!mounted) return;
    setState(() {
      // 在线人数取自「xxx在线观众」统计消息，比房间用户序列更及时。
      final int online = event.onlineCount;
      if (online > 0) _online = online;
      _received++;
      // 进场信息高频且信息量少，固定显示在底部单行，不混入弹幕列表刷屏；
      // 房间统计只贡献在线人数，同样不进列表。
      if (event.kind == DanmakuKind.member) {
        // 被屏蔽用户的进场也不展示（prd F10 全局生效）。
        if (isBlockedBy(event, widget.filter)) {
          if (_latestEntry?.user.userId == event.user.userId) {
            _latestEntry = null;
          }
        } else {
          _latestEntry = event;
          // 在类型筛选里勾选了「进场」时同样入列（prd F13），否则勾了没有效果。
          if (isListKind(event.kind, widget.filter)) _addToRaw(event);
        }
      } else if (event.kind != DanmakuKind.roomStats) {
        // 其余相关弹幕先全部入缓存，展示与否在 build 时按过滤口径决定
        // （这样改屏蔽词 / 类型能立刻作用到已收到的弹幕）。
        _addToRaw(event);
      }
    });
    // 暂停时不自动滚动，但弹幕已照常写入缓存，继续后可回看（prd F9 / F12）。
    if (!_paused) _autoScroller.schedule();
    _report();
  }

  /// 写入列表缓存并裁剪到展示上限。
  ///
  /// 暂停时不裁剪头部：裁剪会让列表整体上移，看起来像「暂停了还在滚动」。
  /// 暂停期间只追加，等继续后（自动滚到底部）再按上限裁剪。
  void _addToRaw(DanmakuEvent event) {
    _raw.add(event);
    if (_raw.length <= _displayLimit) return;
    if (_paused) {
      // 允许短时超出上限，避免暂停时列表位移；上限留一倍余量兜住内存。
      if (_raw.length > _displayLimit * 2) {
        _raw.removeRange(0, _displayLimit);
      }
      return;
    }
    _raw.removeRange(0, _raw.length - _displayLimit);
  }

  void _report() {
    widget.onReport(
      widget.index,
      _PaneReport(
        webRid: widget.webRid,
        stage: _stage,
        received: _received,
        error: _error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final OverlayPalette palette = _palette;
    return Container(
      // 每栏自带背景蒙版（prd F5）：未覆盖的栏用全局透明度。
      color: palette.maskColor.withValues(
        alpha: clampOverlayOpacity(widget.opacity),
      ),
      child: Column(
        children: <Widget>[
          // 隐藏栏目标识（prd F6）时连分隔线一起省掉，弹幕占满整栏。
          if (widget.showTitleBar) ...<Widget>[
            _buildTitleBar(),
            Divider(height: 1, color: palette.divider),
          ],
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 双击暂停 / 继续；长按后上下滑动调本栏透明度（prd F21）。
              onDoubleTap: _togglePaused,
              onLongPressStart: _onLongPressStart,
              onLongPressMoveUpdate: _onLongPressMoveUpdate,
              onLongPressEnd: _onLongPressEnd,
              child: _buildEventList(),
            ),
          ),
          if (_latestEntry != null) _buildEntryBanner(_latestEntry!),
        ],
      ),
    );
  }

  /// 连接状态灯的颜色：浅色皮肤下换深色系，否则亮色在浅底上看不见。
  Color _stageColor(LiveSessionStage stage) {
    final bool light = _palette.isLight;
    return switch (stage) {
      LiveSessionStage.live =>
        light ? const Color(0xFF2E7D32) : Colors.greenAccent,
      LiveSessionStage.offline =>
        light ? const Color(0xFFE65100) : Colors.orangeAccent,
      LiveSessionStage.error =>
        light ? const Color(0xFFC62828) : Colors.redAccent,
      LiveSessionStage.idle => light ? const Color(0xFF757575) : Colors.grey,
      _ => light ? const Color(0xFF1565C0) : Colors.lightBlueAccent,
    };
  }

  /// 栏目标识行（prd F6）：主播名 + 连接状态 / 在线人数。
  ///
  /// 有候选房间时整行可点，弹出房间选择切换本栏绑定（prd F15 / F8）。
  Widget _buildTitleBar() {
    final OverlayPalette palette = _palette;
    final String owner = _session?.room?.owner ?? '';
    final TextStyle labelStyle = TextStyle(
      color: palette.chrome,
      fontSize: smallerFontSize(widget.fontSize, 2),
    );
    final Widget bar = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _stageColor(_stage),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              owner.isEmpty
                  ? (_bound ? widget.webRid : '第 ${widget.index + 1} 栏未绑定')
                  : owner,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.chrome,
                fontSize: smallerFontSize(widget.fontSize, 1),
              ),
            ),
          ),
          // 有候选房间时给出可切换的提示（prd F15）。
          if (widget.roomOptions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Icon(Icons.swap_horiz, size: 13, color: palette.secondary),
            ),
          Text(
            // 已连上且有在线数据时右上是人数；否则退回连接状态，保证能看出当前所处阶段。
            _online > 0
                ? '在线 ${formatOnlineCount(_online)}'
                : _stageText(_stage),
            style: labelStyle,
          ),
          // 焦点模式（prd F7）：放大本栏 / 还原；单栏布局下没有其它栏可让位，不显示。
          if (widget.onToggleFocus != null)
            InkWell(
              onTap: widget.onToggleFocus,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(
                  widget.focused ? Icons.fullscreen_exit : Icons.fullscreen,
                  size: 14,
                  color: widget.focused
                      ? palette.activeColor
                      : palette.secondary,
                ),
              ),
            ),
          // 单栏暂停 / 继续（prd F9）：只影响本栏的自动滚动，不干扰其它栏。
          InkWell(
            onTap: _togglePaused,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                _paused ? Icons.play_arrow : Icons.pause,
                size: 14,
                color: _paused ? palette.activeColor : palette.secondary,
              ),
            ),
          ),
        ],
      ),
    );
    if (widget.roomOptions.isEmpty) return bar;
    return InkWell(onTap: _showRoomPicker, child: bar);
  }

  /// 弹出房间选择并切换本栏绑定（prd F15 / F8）。
  Future<void> _showRoomPicker() async {
    if (widget.roomOptions.isEmpty) return;
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _RoomPickerDialog(
        options: widget.roomOptions,
        current: widget.webRid,
        fontSize: widget.fontSize,
      ),
    );
    if (picked == null || !mounted) return;
    widget.onSwitchRoom(picked);
  }

  /// 连接状态的短文本（prd F6：栏目标识需含连接状态）。
  String _stageText(LiveSessionStage stage) => switch (stage) {
    LiveSessionStage.idle => _bound ? '未连接' : '未绑定',
    LiveSessionStage.resolvingRoom => '解析房间…',
    LiveSessionStage.signing => '签名中…',
    LiveSessionStage.connecting => '连接中…',
    LiveSessionStage.live => '已连接',
    LiveSessionStage.offline => '未开播',
    LiveSessionStage.error => '异常',
  };

  Widget _buildEventList() {
    final OverlayPalette palette = _palette;
    final List<DanmakuEvent> visible = _visible;
    return Stack(
      children: <Widget>[
        if (visible.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(
                _error ?? '暂无弹幕',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.secondary,
                  fontSize: smallerFontSize(widget.fontSize, 1),
                ),
              ),
            ),
          )
        else
          ListView.builder(
            controller: _scrollController,
            itemCount: visible.length,
            itemBuilder: (BuildContext context, int index) =>
                _buildEventTile(visible[index]),
          ),
        // 手势期间显示当前透明度（prd F21）：上下滑时一眼能看到调到多少。
        if (_adjustingOpacity)
          Positioned(
            left: 0,
            right: 0,
            top: 4,
            child: Center(child: _buildOpacityHud()),
          ),
        // 回溯态下的「回到最新」（prd F12）。
        if (_backtracking)
          Positioned(
            left: 0,
            right: 0,
            bottom: 4,
            child: Center(
              child: Material(
                color: palette.isLight ? Colors.white70 : Colors.black54,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _backToLatest,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    child: Text(
                      '回到最新',
                      style: TextStyle(
                        color: palette.chrome,
                        fontSize: smallerFontSize(widget.fontSize, 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 手势调透明度时的数值胶囊（prd F21）。
  Widget _buildOpacityHud() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: _palette.isLight ? Colors.white70 : Colors.black54,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      '透明度 ${clampOverlayOpacity(widget.opacity).toStringAsFixed(2)}',
      style: TextStyle(
        color: _palette.chrome,
        fontSize: smallerFontSize(widget.fontSize, 2),
      ),
    ),
  );

  /// 底部固定一行：最新一条进场信息（昵称 + 荣誉等级 + 灯牌等级 + 进场文案）。
  Widget _buildEntryBanner(DanmakuEvent event) {
    final OverlayPalette palette = _palette;
    final DanmakuUser user = event.user;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: palette.bannerBg,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: smallerFontSize(widget.fontSize, 2)),
          children: <InlineSpan>[
            TextSpan(
              text: '欢迎 ',
              style: TextStyle(color: palette.secondary),
            ),
            if (user.nickName.isNotEmpty)
              TextSpan(
                text: user.nickName,
                style: TextStyle(
                  color: palette.userAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            if (user.level > 0)
              TextSpan(
                text: ' Lv.${user.level}',
                style: TextStyle(color: palette.levelColor),
              ),
            if (user.fanLevel > 0)
              TextSpan(
                text: ' 灯牌${user.fanLevel}',
                style: TextStyle(color: palette.fanLevelColor),
              ),
            TextSpan(
              text: ' ${event.text}',
              style: TextStyle(color: _bodyColor),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 单条弹幕：荣誉等级 + 灯牌等级 + 昵称 + 内容；
  /// 飘屏 / 特权弹幕带类型前缀并整体着色，与普通弹幕区分。
  ///
  /// 单击弹出该条的功能菜单（复制 / 屏蔽）；滑动与双击暂停由上层手势接管。
  Widget _buildEventTile(DanmakuEvent event) {
    final OverlayPalette palette = _palette;
    final DanmakuUser user = event.user;
    final String? mark = danmakuTypeLabel(event.kind);
    final Color? markColor = palette.typeColor(event.kind);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_showEventMenu(event)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text.rich(
          TextSpan(
            style: TextStyle(fontSize: widget.fontSize),
            children: <InlineSpan>[
              if (mark != null && markColor != null)
                TextSpan(
                  text: '$mark ',
                  style: TextStyle(
                    color: markColor,
                    fontSize: smallerFontSize(widget.fontSize, 2),
                  ),
                ),
              // 等级与灯牌前置到昵称前，昵称后紧跟弹幕内容。
              if (user.level > 0)
                TextSpan(
                  // 荣誉等级：level > 0 才显示（大量用户无荣誉等级）
                  text: 'Lv.${user.level} ',
                  style: TextStyle(
                    color: palette.levelColor,
                    fontSize: smallerFontSize(widget.fontSize, 2),
                  ),
                ),
              if (user.fanLevel > 0)
                TextSpan(
                  // 灯牌等级：优先取 user.fans_club.data.level
                  text: '灯牌${user.fanLevel} ',
                  style: TextStyle(
                    color: palette.fanLevelColor,
                    fontSize: smallerFontSize(widget.fontSize, 2),
                  ),
                ),
              if (user.nickName.isNotEmpty)
                TextSpan(
                  text: '${user.nickName}: ',
                  style: TextStyle(
                    color: palette.userAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              // 正文按高亮词切分（prd F11）：命中片段用高亮样式。
              for (final HighlightSegment segment in splitHighlights(
                event.text,
                widget.filter.highlightKeywords,
                regex: widget.filter.regexEnabled,
              ))
                TextSpan(
                  text: segment.text,
                  style: segment.highlighted
                      ? palette.highlightStyle
                      : TextStyle(color: markColor ?? _bodyColor),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 栏内房间选择弹窗（prd F14 分组 / F15 快速切换 / F8 栏间切换）：
/// 按分组展示主 App 的主播列表，点选即切到该房间。
class _RoomPickerDialog extends StatelessWidget {
  const _RoomPickerDialog({
    required this.options,
    required this.current,
    required this.fontSize,
  });

  final List<RoomOption> options;

  /// 本栏当前绑定的直播间号，用于标出选中项。
  final String current;

  /// 本栏字号：弹窗内文字按它缩小，多栏小窗里也不会撑破。
  final double fontSize;

  /// 有分组的分组名，按候选列表里的出现顺序；未分组的不在表内，排在最后。
  List<String> get _groups {
    final List<String> groups = <String>[];
    for (final RoomOption option in options) {
      if (option.group.isEmpty || groups.contains(option.group)) continue;
      groups.add(option.group);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final List<String> groups = _groups;
    return AlertDialog(
      title: const Text('切换房间'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final String group in groups) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
                child: Text(
                  group,
                  style: TextStyle(
                    color: Colors.grey.shade700,
                    fontSize: smallerFontSize(fontSize, 3),
                  ),
                ),
              ),
              for (final RoomOption option in options)
                if (option.group == group) _tile(context, option),
            ],
            for (final RoomOption option in options)
              if (option.group.isEmpty) _tile(context, option),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, RoomOption option) {
    final bool selected = option.webRid == current;
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        size: 18,
        color: selected ? Colors.blue : Colors.grey,
      ),
      title: Text(
        option.name.isEmpty ? option.webRid : option.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: smallerFontSize(fontSize, 1)),
      ),
      subtitle: Text(
        option.webRid,
        style: TextStyle(fontSize: smallerFontSize(fontSize, 4)),
      ),
      onTap: () => Navigator.of(context).pop(option.webRid),
    );
  }
}

/// 栏位管理弹窗（悬浮球菜单入口）：增 / 减栏位、逐栏切换主播。
///
/// 在弹窗里改的是一份副本，点「保存」才回传；取消则完全不动窗口。
class _PaneManagerDialog extends StatefulWidget {
  const _PaneManagerDialog({
    required this.webRids,
    required this.options,
    required this.fontSize,
  });

  /// 当前各栏绑定的直播间号，按栏位顺序。
  final List<String> webRids;

  /// 全部候选房间（主 App 的主播列表），用于换绑。
  final List<RoomOption> options;

  /// 全局字号：弹窗文字按它缩小，小窗口里也不会撑破。
  final double fontSize;

  @override
  State<_PaneManagerDialog> createState() => _PaneManagerDialogState();
}

class _PaneManagerDialogState extends State<_PaneManagerDialog> {
  late final List<String> _webRids = List<String>.of(widget.webRids);

  /// 未绑定的候选房间，用于「添加栏位」。
  List<RoomOption> get _unbound => <RoomOption>[
    for (final RoomOption option in widget.options)
      if (!_webRids.contains(option.webRid)) option,
  ];

  String _label(String webRid) {
    for (final RoomOption option in widget.options) {
      if (option.webRid == webRid && option.name.isNotEmpty) return option.name;
    }
    return webRid;
  }

  Future<String?> _pickRoom({
    required List<RoomOption> candidates,
    required String current,
  }) => showDialog<String>(
    context: context,
    builder: (BuildContext context) => _RoomPickerDialog(
      options: candidates,
      current: current,
      fontSize: widget.fontSize,
    ),
  );

  /// 换绑某栏（候选是全部主播，方便换回来）。
  Future<void> _switch(int index) async {
    final String? picked = await _pickRoom(
      candidates: widget.options,
      current: _webRids[index],
    );
    if (picked == null || !mounted) return;
    setState(() => _webRids[index] = picked);
  }

  Future<void> _add() async {
    final List<RoomOption> candidates = _unbound;
    if (candidates.isEmpty) return;
    final String? picked = await _pickRoom(candidates: candidates, current: '');
    if (picked == null || !mounted) return;
    setState(() => _webRids.add(picked));
  }

  void _removeAt(int index) {
    if (_webRids.length <= 1) return;
    setState(() => _webRids.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final double titleSize = smallerFontSize(widget.fontSize, 1);
    final double subSize = smallerFontSize(widget.fontSize, 3);
    return AlertDialog(
      title: const Text('栏位管理'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '当前 ${_webRids.length} 栏；栏位过多时单格会变小，可配合「适配尺寸」调大窗口。',
              style: TextStyle(fontSize: subSize, color: Colors.grey),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (int index = 0; index < _webRids.length; index++)
                    ListTile(
                      dense: true,
                      title: Text(
                        '第 ${index + 1} 栏',
                        style: TextStyle(fontSize: titleSize),
                      ),
                      subtitle: Text(
                        '${_label(_webRids[index])}（${_webRids[index]}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: subSize),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          TextButton(
                            onPressed: () => _switch(index),
                            style: TextButton.styleFrom(
                              minimumSize: Size.zero,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              '切换',
                              style: TextStyle(fontSize: subSize),
                            ),
                          ),
                          IconButton(
                            tooltip: '移除本栏',
                            iconSize: 18,
                            visualDensity: VisualDensity.compact,
                            onPressed: _webRids.length > 1
                                ? () => _removeAt(index)
                                : null,
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _unbound.isEmpty ? null : _add,
                icon: const Icon(Icons.add, size: 18),
                label: Text(
                  _unbound.isEmpty ? '已无未添加的主播' : '添加栏位',
                  style: TextStyle(fontSize: titleSize),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(List<String>.of(_webRids)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
