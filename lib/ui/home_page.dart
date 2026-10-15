// 首页 = 主播管理：添加 / 持久化 / 刷新 / 连接弹幕。
//
// 交互约定（本轮确认）：
// - 右上角 + 添加主播，添加后立即落盘，冷启动或下拉刷新时重新读取
// - 行内「刷新」拉一次房间信息，更新主播名 / 标题 / 开播状态
// - 点击整行或行内「连接弹幕」= 单栏连接，进入 App 内弹幕页（页内可再开悬浮窗）
// - 右上角多栏按钮 = 勾选主播后开多栏悬浮窗（栏位不限，按栏数推导网格）
import 'dart:async';
import 'dart:io';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/local_data_reset.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:danmu_float/system/system_permissions.dart';
import 'package:danmu_float/ui/add_room_dialog.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:danmu_float/ui/high_performance_dialog.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:flutter/material.dart';

/// 冷启动 / 回前台时探测悬浮窗是否存活前的延后时长（PM-001）。
///
/// 主 App 启动时前台服务可能还在恢复窗口，立刻查 `isActive` 会拿到「未激活」
/// 的中间态；延后再查一次，把偶发的中间态避过去，避免漏掉关闭入口。
const Duration _overlayAliveProbeDelay = Duration(seconds: 1);

/// 「最近刷新」的相对时间文案；[refreshedAt] 为 epoch 毫秒，null / 非正数返回空串。
///
/// [now] 由调用方注入，便于单测固定在某个时间点。只做到「天」这一档：再久远对
/// 「这份数据是不是过期了」的判断已没有区别（UX-04）。
String formatRefreshedAgo(int? refreshedAt, {required DateTime now}) {
  if (refreshedAt == null || refreshedAt <= 0) return '';
  final int seconds =
      (now.millisecondsSinceEpoch - refreshedAt) ~/ 1000;
  // 时钟回拨（seconds 为负）时按「刚刚」处理，不显示「-3 分钟前」这种文案。
  if (seconds < 60) return '刚刚';
  if (seconds < 3600) return '${seconds ~/ 60} 分钟前';
  if (seconds < 86400) return '${seconds ~/ 3600} 小时前';
  return '${seconds ~/ 86400} 天前';
}

/// 回前台时房间数据超过这个时长就算过期，需要静默补刷（UX-10）。
///
/// 定 30 分钟：切出去几分钟再回来不该看到整列表重刷（费流量、列表乱跳），而隔夜回来时
/// 旧数据会一直显示「未开播」，用户又不知道那只是过期结论。
const Duration staleRoomRefreshAfter = Duration(minutes: 30);

/// 房间数据是否过期（UX-10）：从没刷过、或距上次成功刷新超过 [after]。
///
/// [now] 与 [lastRefreshedAt] 都是 epoch 毫秒（AGENTS 第 5 节）；时钟回拨导致差值为负
/// 时按「刚刷过」处理，不触发补刷。
bool isRoomStale(
  int? lastRefreshedAt, {
  required int now,
  Duration after = staleRoomRefreshAfter,
}) {
  if (lastRefreshedAt == null || lastRefreshedAt <= 0) return true;
  return now - lastRefreshedAt > after.inMilliseconds;
}

/// 距离上次自动补刷尝试是否已过 [after]（UX-13）。
///
/// 只按 `lastRefreshedAt`（成功才写）判断会漏掉失败路径：弱网或被风控时每次回前台都
/// 会把整列表重打一遍，而 30 分钟节流对「失败」完全不生效——恰好放过了它该防的场景。
/// 因此再记一个「上次尝试时间」（纯内存，不落盘）。
bool shouldAttemptStaleRefresh(
  int? lastAttemptAt, {
  required int now,
  Duration after = staleRoomRefreshAfter,
}) {
  if (lastAttemptAt == null) return true;
  return now - lastAttemptAt > after.inMilliseconds;
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.onResetAll,
    this.directoryResolver,
    this.credentialStore,
    this.roomInfoClient,
    this.store,
  });

  /// 「清除所有本地数据」完成后回调外层，把入口切回免责声明页（prd F26）。
  final VoidCallback? onResetAll;

  /// 各 store 的目录解析器可注入，便于单测用临时目录隔离、不依赖 path_provider
  /// 插件通道（默认走应用私有目录）。
  final Future<Directory> Function()? directoryResolver;

  /// 凭证存储可整体注入（默认用加密落盘后端）；单测传内存后端以避开
  /// flutter_secure_storage 的原生通道。
  final CredentialStore? credentialStore;

  /// 房间信息客户端可注入（默认走真实接口）；单测传假实现以隔离网络。
  final RoomInfoClient? roomInfoClient;

  /// 主播列表存储可注入（默认落应用私有目录）；单测传计数实现来断言
  /// 「整批只落盘一次」（UX-11）。
  @visibleForTesting
  final RoomStore? store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  /// 各 store 用注入的目录解析器构造时可隔离到临时目录（单测用）；
  /// 默认走应用私有目录。字段在 [initState] 按 [widget.directoryResolver] 初始化。
  late final RoomStore _store;
  late final OverlayPrefsStore _prefsStore;

  /// 凭证存储：用户配置的多份凭证加密落盘，启动时读回；主播可分别指定使用哪份。
  late final CredentialStore _credentialStore;

  /// 已配置的凭证列表，用于长按菜单里的「使用凭证」选择与行内展示。
  List<CredentialProfile> _credentials = const <CredentialProfile>[];

  /// 「清除所有本地数据」用；与页面共用同一个凭证实例，清完状态才一致。
  late final LocalDataReset _dataReset = LocalDataReset(
    credentialStore: _credentialStore,
  );

  /// 刷新房间信息用的客户端：复用同一个实例以共享 ttwid 缓存与连接池。
  late final RoomInfoClient _roomInfoClient =
      widget.roomInfoClient ?? RoomInfoClient();

  List<ManagedRoom> _rooms = const <ManagedRoom>[];
  bool _loading = true;

  /// 正在刷新房间信息的直播间号（行内按钮转圈用）。
  final Set<String> _refreshing = <String>{};

  /// 回前台自动补刷正在飞的直播间号（UX-13）。
  ///
  /// 与 [_refreshing] 分开：补刷不是用户点的，行内不该转圈、也不该让它挡住行内刷新
  /// 按钮的可用性；但两条路径必须互斥——房间接口对同 IP 并发不友好（UX-04 为此刻意
  /// 串行），同一 webRid 两路在飞会把风控风险成倍放大。
  final Set<String> _autoRefreshing = <String>{};

  /// 上次自动补刷的尝试时间（epoch 毫秒，纯内存）：成功与失败都算一次尝试，
  /// 否则失败路径等于没有节流（UX-13）。
  int? _lastStaleRefreshAttemptAt;

  /// 是否正在「刷新全部」；以及它的进度（已完成 / 总数），用于列表上方的进度条。
  ///
  /// 批量刷新可能要跑十几秒，没有进度用户会以为卡死并反复点按钮（UX-04）。
  bool _refreshAllRunning = false;
  int _refreshAllDone = 0;
  int _refreshAllTotal = 0;

  /// 悬浮窗样式与分栏偏好（透明度、上次勾选的主播）。
  OverlayPrefs _prefs = const OverlayPrefs();

  /// 全局过滤偏好（prd F10 / F11 / F13），随建窗配置一并下发。
  final FilterStore _filterStore = FilterStore();
  FilterPrefs _filter = const FilterPrefs();

  /// 主 App 主题偏好；导入数据后要按备份里的值复位。
  final ThemeStore _themeStore = ThemeStore();

  bool _overlayVisible = false;

  /// 悬浮窗权限是否被拒（prd 4.10 权限拒绝降级）：为真时首页顶部常驻提示，
  /// 并给一个「重试授权」按钮，不阻断 App 内查看弹幕。
  bool _overlayPermissionDenied = false;

  /// 「重试授权」仍被拒后置位：此时 banner 要补一条真能走通的出口（UX-16）。
  ///
  /// 系统在「拒绝且不再询问」后不再弹框，再点「重试授权」没有任何反馈，
  /// 属于「入口可达但走不通」。
  bool _overlayRetryFailed = false;

  /// 监听悬浮窗上报：权限被撤销时悬浮窗会自行断开，这里同步按钮状态。
  StreamSubscription<OverlayStatus>? _overlaySubscription;

  /// 悬浮窗里改了屏蔽（弹幕行菜单）后主 App 落盘的那份偏好：跟着刷新本页口径。
  StreamSubscription<FilterPrefs>? _filterSubscription;

  /// 本地偏好是否已读回：读回前不动窗口尺寸，否则会把默认值当成用户设置。
  bool _prefsReady = false;

  /// 上一次构建时的屏幕逻辑尺寸，用于感知横竖屏切换。
  Size? _lastScreenSize;

  @override
  void initState() {
    super.initState();
    // 单测可注入临时目录解析器，把本地存储隔离到临时目录、不依赖 path_provider
    // 插件通道（见 HomePage.directoryResolver）。默认仍走应用私有目录。
    final Future<Directory> Function()? resolver = widget.directoryResolver;
    _store = widget.store ?? RoomStore(directoryResolver: resolver);
    _prefsStore = OverlayPrefsStore(directoryResolver: resolver);
    _credentialStore = widget.credentialStore ?? CredentialStore();
    WidgetsBinding.instance.addObserver(this);
    _overlaySubscription = overlayStatusStream.listen((OverlayStatus status) {
      if (!mounted) return;
      if (status.permissionRevoked) {
        setState(() {
          _overlayVisible = false;
          _overlayPermissionDenied = true;
        });
        return;
      }
      // 悬浮窗在窗内被关掉（悬浮球菜单 / 通知栏）：窗口已不存在，撤掉本页的开关
      // 状态，否则用户再点「多栏连接」会走重排分支，窗口不会重新建出来。
      if (status.closed) {
        // 关窗前那一次上报可能还带着刚改的偏好（透明度 / 尺寸 / 锁定），
        // 先落盘再撤状态，免得最后几秒的改动丢掉。
        _applyReportedStatus(status);
        setState(() => _overlayVisible = false);
        return;
      }
      // 悬浮窗有活跃栏位绑定 = 窗口真实存在（PM-001）：弹幕页开的单栏窗也会持续
      // 上报，这里据此把本页状态补成「已开启」，让首页出现关闭入口。
      // webRids 为空的上报（如权限自查中的空窗上报）不动本页状态。
      if (status.webRids.isNotEmpty && !_overlayVisible) {
        setState(() => _overlayVisible = true);
      }
      // 悬浮窗内切换了某栏绑定的房间，或经悬浮球菜单改了偏好（prd F8 / F15 / F21）：
      // 把最新绑定与偏好落盘。
      _applyReportedStatus(status);
    });
    _filterSubscription = filterChangedStream.listen((FilterPrefs filter) {
      if (!mounted) return;
      setState(() => _filter = filter);
    });
    unawaited(_load());
    unawaited(_loadPrefs());
    unawaited(_loadFilter());
    // 凭证要先于任何连接读回：刷新房间信息与弹幕连接都按同一份取值。
    unawaited(_loadCredentials());
    unawaited(_refreshOverlayPermission());
    // 悬浮窗可能是在弹幕页开的、或进程重启后前台服务仍带着窗口活着（PM-001）：
    // 本页的开关状态只认「窗口真实是否存在」，进首页时先对齐一次，否则用户
    // 会面对一个关不掉的悬浮窗——首页上没有任何关闭入口。
    unawaited(_reconcileOverlayVisible());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
    _filterSubscription?.cancel();
    _roomInfoClient.close();
    super.dispose();
  }

  /// 回到前台时核对一次悬浮窗是否仍然有效（不做系统回调，见 overlay_launcher）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkOverlayAlive());
      // 用户可能刚从系统设置里改了悬浮窗权限，回来重新对一次。
      unawaited(_refreshOverlayPermission());
      // 悬浮窗可能在后台期间被用户从通知栏 / 悬浮球关掉，或由弹幕页新开：
      // 每次回前台都重新收敛一次开关状态（PM-001）。
      unawaited(_reconcileOverlayVisible());
      // 后台期间主播可能已开播 / 下播，列表里的旧结论要静默补一次（UX-10）。
      unawaited(_refreshStaleRooms());
    }
  }

  /// 回前台静默补刷过期房间（UX-10）。
  ///
  /// 只刷「从没刷过」或「超过 [staleRoomRefreshAfter]」的房间，且不弹提示；整批只推送
  /// 一次悬浮窗候选（≤1 条，不是逐条），否则一批补刷会像刷屏一样连发配置。
  ///
  /// 两层节流（UX-13）：一是「距上次尝试」的窗口——失败路径没有写 `lastRefreshedAt`，
  /// 弱网下每次回前台都会把整列表重打；二是同一 webRid 的在飞互斥（[_autoRefreshing]）。
  Future<void> _refreshStaleRooms() async {
    // 全量刷新进行中就不插队：它已经在逐条刷了，再插一遍等于把接口请求翻倍。
    if (_refreshAllRunning || !mounted) return;
    final int now = _nowMillis();
    if (!shouldAttemptStaleRefresh(_lastStaleRefreshAttemptAt, now: now)) {
      return;
    }
    final List<String> stale = <String>[
      for (final ManagedRoom room in _rooms)
        if (!_refreshing.contains(room.webRid) &&
            !_autoRefreshing.contains(room.webRid) &&
            isRoomStale(room.lastRefreshedAt, now: now))
          room.webRid,
    ];
    if (stale.isEmpty) return;
    // 先记尝试时间再发请求：中途失败也要算这一次，否则失败就会变成「每次都试」。
    _lastStaleRefreshAttemptAt = now;
    // 走 setState：行内刷新按钮要跟着置灰，否则用户点了没反应会以为按钮坏了。
    setState(() => _autoRefreshing.addAll(stale));
    try {
      for (final String webRid in stale) {
        final String? error = await _refreshRoomQuiet(webRid, persist: false);
        // 静默刷新失败不打扰用户（不是他主动点的），但日志要留痕：用户反馈「回来还是
        // 旧数据」时，得能看出到底是没刷还是刷失败了。
        if (error != null) debugPrint('回前台补刷主播失败（$webRid）：$error');
        if (!mounted) return;
      }
    } finally {
      // 页面已销毁时不能 setState，但仍要清掉在飞标记（只为不留悬空状态）。
      if (mounted) {
        setState(() => _autoRefreshing.removeAll(stale));
      } else {
        _autoRefreshing.removeAll(stale);
      }
    }
    await _store.save(_rooms);
    if (!mounted) return;
    _syncOverlayRooms();
  }

  /// 悬浮窗真实存在但本页不知道时，补上「已开启」状态（PM-001）。
  ///
  /// 只补正、不纠错：误判「已开」的情形由 [_checkOverlayAlive]（本页以为开着时）
  /// 与权限撤回上报兜住，两边口径合起来覆盖开 / 关两个方向。
  ///
  /// 冷启动时前台服务恢复窗口需要时间，立刻查询会拿到「未激活」的中间态；
  /// 短暂延后再查，把偶发的中间态避过去（延时常量见文件顶部）。
  Future<void> _reconcileOverlayVisible() async {
    if (_overlayVisible) return;
    await Future<void>.delayed(_overlayAliveProbeDelay);
    if (!mounted || _overlayVisible) return;
    if (!await isOverlayActive()) return;
    setState(() => _overlayVisible = true);
  }

  Future<void> _checkOverlayAlive() async {
    if (!_overlayVisible) return;
    if (await verifyOverlayPermission()) return;
    if (!mounted) return;
    setState(() {
      _overlayVisible = false;
      _overlayPermissionDenied = true;
    });
    _snack('悬浮窗已失效（权限被撤销或被系统移除），已关闭');
  }

  /// 查询悬浮窗权限并更新常驻提示（prd 4.10）。
  Future<void> _refreshOverlayPermission() async {
    final bool granted = await isOverlayPermissionGranted();
    if (!mounted) return;
    if (granted == !_overlayPermissionDenied) return;
    setState(() => _overlayPermissionDenied = !granted);
  }

  /// banner 上的「重试授权」：重新申请一次，仍被拒就保持提示。
  Future<void> _retryOverlayPermission() async {
    await ensureOverlayPermission();
    await _refreshOverlayPermission();
    if (!mounted) return;
    // 仍被拒时补「去系统设置」出口：系统不再弹框的情况下，只留「重试授权」是死胡同（UX-16）。
    setState(() => _overlayRetryFailed = _overlayPermissionDenied);
    _snack(
      _overlayPermissionDenied ? '未授予悬浮窗权限，当前仅能在 App 内查看；可去系统设置里手动打开' : '已授予悬浮窗权限，可开启悬浮窗了',
    );
  }

  /// banner 上的「去系统设置」：跳系统设置手动开权限。
  ///
  /// AGENTS.md 第 5 节要求权限入口任意时刻可达；系统在「拒绝且不再询问」后不再弹框，
  /// 此时只有系统设置里能真正打开它（UX-16）。
  Future<void> _openSystemSettings() async {
    await systemPermissions.openAppSettings();
  }

  // ---------- 本地列表 ----------

  /// 本地主播列表转成悬浮窗可切换的候选房间（prd F14 / F15）。
  List<RoomOption> get _roomOptions => <RoomOption>[
        for (final ManagedRoom room in _rooms)
          RoomOption(
            webRid: room.webRid,
            name: room.displayName,
            group: room.group,
          ),
      ];

  /// 悬浮窗内改绑房间，或经悬浮球菜单改了透明度 / 字号 / 尺寸 / 锁定时回报的状态：
  /// 与本地偏好不一致时落盘（prd F8 / F15 / F21）。
  void _applyReportedStatus(OverlayStatus status) {
    OverlayPrefs next = _prefs;
    final List<String> webRids = status.webRids;
    if (webRids.isNotEmpty && !_sameWebRids(webRids, next.webRids)) {
      next = next.copyWith(webRids: webRids);
    }
    final OverlayPrefsPatch? patch = status.prefsPatch;
    if (patch != null) next = next.appliedPatch(patch);
    if (identical(next, _prefs)) return;
    setState(() => _prefs = next);
    unawaited(_prefsStore.save(next));
    // 主 App 侧记下锁定状态：后续改尺寸时不能被拖动开关冲掉。
    setOverlayDragLock(next.dragLocked);
  }

  /// 推送候选房间列表给已开着的悬浮窗；没开时静默忽略，下次建窗随 config 补发。
  void _syncOverlayRooms() => unawaited(shareOverlayRooms(_roomOptions));

  /// 读取本地保存的主播（首次打开与下拉刷新都走这里）。
  Future<void> _load() async {
    final List<ManagedRoom> rooms = await _store.load();
    if (!mounted) return;
    setState(() {
      _rooms = rooms;
      _loading = false;
    });
    _syncCredentialBindings();
  }

  /// 读回已配置的凭证列表，并重建「主播 → 凭证」绑定。
  Future<void> _loadCredentials() async {
    await _credentialStore.load();
    if (!mounted) return;
    setState(() => _credentials = _credentialStore.profiles);
    _syncCredentialBindings();
  }

  /// 设置页里凭证被增删改后回调：刷新本地列表并把新绑定推给已开着的悬浮窗。
  void _onCredentialsChanged() {
    setState(() => _credentials = _credentialStore.profiles);
    _syncCredentialBindings();
  }

  /// 依据当前主播列表与凭证列表重建绑定：
  /// - 主 App 侧存进全局映射，刷新 / 连接时按主播取值；
  /// - 同步推给已开着的悬浮窗引擎（没开时静默忽略，下次建窗随配置补发）。
  void _syncCredentialBindings() {
    final Map<String, String> bindings = buildRoomCookieBindings(
      rooms: _rooms.map(
        (ManagedRoom room) =>
            (webRid: room.webRid, credentialId: room.credentialId),
      ),
      profiles: _credentials,
    );
    setRoomCookieBindings(bindings);
    unawaited(shareOverlayCredential(bindings));
  }

  /// 取主播绑定的凭证名；未绑定或绑定的凭证已删除时返回 null。
  String? _credentialNameOf(ManagedRoom room) {
    final String? id = room.credentialId;
    if (id == null) return null;
    for (final CredentialProfile profile in _credentials) {
      if (profile.id == id) return profile.name;
    }
    return null;
  }

  Future<void> _loadPrefs() async {
    final OverlayPrefs prefs = await _prefsStore.load();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _prefsReady = true;
    });
  }

  /// 屏幕尺寸变化时按比例换算窗口尺寸并落盘（prd F2）。
  ///
  /// 只在尺寸真的变了时动手，且延后到本帧结束再改：build 期间不能 setState。
  void _syncWindowSizeWithScreen(Size screen) {
    final Size? previous = _lastScreenSize;
    _lastScreenSize = screen;
    if (!_prefsReady || previous == null || previous == screen) return;
    final ({double width, double height}) scaled = scaleOverlaySizeToScreen(
      _prefs.windowSize,
      oldScreenWidth: previous.width,
      oldScreenHeight: previous.height,
      newScreenWidth: screen.width,
      newScreenHeight: screen.height,
    );
    if (scaled.width == _prefs.windowWidth &&
        scaled.height == _prefs.windowHeight) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onPrefsChanged(
        _prefs.copyWith(windowWidth: scaled.width, windowHeight: scaled.height),
        persist: true,
      );
    });
  }

  Future<void> _loadFilter() async {
    final FilterPrefs filter = await _filterStore.load();
    if (!mounted) return;
    setState(() => _filter = filter);
  }

  /// 把当前样式偏好连同屏幕尺寸 / 锁定状态推给已开着的悬浮窗。
  ///
  /// 只推样式，不动各栏已绑定的房间（重发 config 会把绑定冲掉）。窗口没开时
  /// 由 overlay_launcher 静默忽略。屏幕尺寸是悬浮窗侧换算横竖屏与收敛尺寸的依据。
  void _pushOverlayStyle(OverlayPrefs prefs) {
    final Size screen = MediaQuery.sizeOf(context);
    unawaited(
      shareOverlayStyle(
        opacity: prefs.opacity,
        fontSize: prefs.fontSize,
        scrollSpeed: prefs.scrollSpeed,
        paneStyles: prefs.paneStyles,
        lightTheme: prefs.lightTheme,
        showTitleBar: prefs.showTitleBar,
        focusBehavior: prefs.focusBehavior,
        dragLocked: prefs.dragLocked,
        clickThrough: prefs.clickThrough,
        screenWidth: screen.width,
        screenHeight: screen.height,
      ),
    );
  }

  /// 设置页改样式：先更新内存并推给已开着的悬浮窗，需要落盘时才写文件。
  void _onPrefsChanged(OverlayPrefs prefs, {required bool persist}) {
    final bool sizeChanged = prefs.windowWidth != _prefs.windowWidth ||
        prefs.windowHeight != _prefs.windowHeight;
    setState(() => _prefs = prefs);
    // 这里不判断本页的开关状态：悬浮窗可能是在弹幕页开的，
    // 窗口是否已开由 overlay_launcher 统一持有，没开时调用会静默忽略。
    _pushOverlayStyle(prefs);
    if (sizeChanged) {
      final Size screen = MediaQuery.sizeOf(context);
      updateOverlaySize(
        fitOverlaySize(
          prefs.windowSize,
          screenWidth: screen.width,
          screenHeight: screen.height,
        ),
      );
    }
    if (persist) unawaited(_prefsStore.save(prefs));
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SettingsPage(
          prefs: _prefs,
          onChanged: _onPrefsChanged,
          onResetAll: _clearAllData,
          credentialStore: _credentialStore,
          onCredentialsChanged: _onCredentialsChanged,
          filter: _filter,
          filterStore: _filterStore,
          onFilterChanged: _onFilterChanged,
          onDataImported: _reloadAfterImport,
        ),
      ),
    );
  }

  /// 导入数据后重新读回全部本地数据，并把最新样式 / 过滤 / 尺寸 / 候选房间
  /// 推给已开着的悬浮窗（不重发 config，避免冲掉栏内已绑定的房间）。
  Future<void> _reloadAfterImport() async {
    final List<ManagedRoom> rooms = await _store.load();
    final OverlayPrefs prefs = await _prefsStore.load();
    final FilterPrefs filter = await _filterStore.load();
    final ThemeMode themeMode = await _themeStore.load();
    if (!mounted) return;
    appThemeMode.value = themeMode;
    setState(() {
      _rooms = rooms;
      _prefs = prefs;
      _filter = filter;
      _prefsReady = true;
    });
    _pushOverlayStyle(prefs);
    unawaited(shareOverlayFilter(filter));
    _syncOverlayRooms();
    _syncCredentialBindings();
    if (_overlayVisible) {
      final Size screen = MediaQuery.sizeOf(context);
      updateOverlaySize(
        fitOverlaySize(
          prefs.windowSize,
          screenWidth: screen.width,
          screenHeight: screen.height,
        ),
      );
    }
  }

  /// 设置页改过滤偏好：更新内存并推给已开着的悬浮窗（落盘由设置页负责）。
  void _onFilterChanged(FilterPrefs filter) {
    setState(() => _filter = filter);
    unawaited(shareOverlayFilter(filter));
  }

  /// 清除所有本地数据（prd F26 硬要求）：
  /// 先关闭悬浮窗断开全部连接，再清空持久化数据，最后回到免责声明页。
  Future<void> _clearAllData() async {
    await teardownOverlay();
    await _dataReset.clearAll();
    if (!mounted) return;
    // 主题偏好文件已被删掉，界面上的主题也一并复位（prd F20）。
    appThemeMode.value = ThemeMode.system;
    setState(() {
      _rooms = const <ManagedRoom>[];
      _prefs = const OverlayPrefs();
      _filter = const FilterPrefs();
      _credentials = const <CredentialProfile>[];
      _refreshing.clear();
      _overlayVisible = false;
    });
    // 凭证密文已被删除，全局绑定同步清空（悬浮窗已关闭，无需再下发）。
    setRoomCookieBindings(const <String, String>{});
    widget.onResetAll?.call();
  }

  Future<void> _add() async {
    final ManagedRoom? room = await showAddRoomDialog(
      context,
      existingWebRids: _rooms.map((ManagedRoom item) => item.webRid).toSet(),
    );
    if (room == null || !mounted) return;

    final List<ManagedRoom> next = <ManagedRoom>[..._rooms, room];
    setState(() => _rooms = next);
    await _store.save(next);
    _syncOverlayRooms();
    // 新加的主播还没有主播名与开播状态，顺手刷一次让行内立刻可读。
    unawaited(_refreshRoom(room.webRid));
  }

  Future<void> _remove(ManagedRoom room) async {
    final List<ManagedRoom> next = _rooms
        .where((ManagedRoom item) => item.webRid != room.webRid)
        .toList(growable: false);
    setState(() => _rooms = next);
    await _store.save(next);
    // 主播被移除后它绑定的凭证不再有任何作用，重建一次绑定以免留下悬挂项。
    _syncCredentialBindings();
    // 正在悬浮窗里显示的主播要先把它的栏位卸掉（PM-002），再推候选列表。
    await _unbindRoomFromOverlay(room.webRid);
    _syncOverlayRooms();
    if (mounted) _snack('已移除 ${room.displayName}');
  }

  /// 把被移除的主播从悬浮窗的栏位绑定里摘掉（PM-002）。
  ///
  /// 只推候选房间列表（[shareOverlayRooms]）不会卸载已绑定的栏位：那一栏会继续
  /// 连着被移除的直播间、继续占用一条连接，用户以为删掉了其实没删。这里按新绑定
  /// 重排一次，悬浮窗会重建栏位、自动 dispose 对应栏并停掉它的会话。
  ///
  /// 窗口没开、或该主播当前没绑在任何栏位上时不动；若它是最后一栏则直接关窗——
  /// 空绑定下发不出去（OverlayConfig 至少要一个房间），留着只会是个空窗。
  Future<void> _unbindRoomFromOverlay(String webRid) async {
    if (!overlayShown) return;
    final List<String> current = _prefs.webRids;
    if (!current.contains(webRid)) return;

    final List<String> remaining =
        current.where((String item) => item != webRid).toList(growable: false);
    final OverlayPrefs nextPrefs = _prefs.copyWith(webRids: remaining);
    setState(() => _prefs = nextPrefs);
    unawaited(_prefsStore.save(nextPrefs));

    if (remaining.isEmpty) {
      await _closeOverlay();
      return;
    }

    final Size screen = MediaQuery.sizeOf(context);
    await resizeOverlay(
      nextPrefs.toConfig(
        remaining,
        filter: _filter,
        roomOptions: _roomOptions,
      ),
      // 窗口不能大于屏幕，否则会溢出（与 _openMulti 同一口径）。
      size: fitOverlaySize(
        nextPrefs.windowSize,
        screenWidth: screen.width,
        screenHeight: screen.height,
      ),
    );
  }

  /// 设置 / 修改某主播的分组（prd F14）；留空表示移出分组。
  Future<void> _editGroup(ManagedRoom room) async {
    final String? group = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _GroupDialog(
        title: room.displayName,
        current: room.group,
        groups: _groups,
      ),
    );
    if (group == null || !mounted) return;
    final List<ManagedRoom> next = _rooms
        .map(
          (ManagedRoom item) =>
              item.webRid == room.webRid ? item.copyWith(group: group) : item,
        )
        .toList(growable: false);
    setState(() => _rooms = next);
    await _store.save(next);
    _syncOverlayRooms();
    if (mounted) _snack(group.isEmpty ? '已移出分组' : '已归入「$group」');
  }

  /// 指定 / 取消某主播连接时使用的凭证（prd F27）。
  ///
  /// 弹窗返回空串表示改回匿名自动获取，null 表示取消；凭证在设置页统一管理。
  Future<void> _editCredential(ManagedRoom room) async {
    final String? selected = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => _CredentialPickerDialog(
        title: room.displayName,
        current: room.credentialId,
        profiles: _credentials,
      ),
    );
    if (selected == null || !mounted) return;

    final bool anonymous = selected.isEmpty;
    final List<ManagedRoom> next = _rooms
        .map(
          (ManagedRoom item) => item.webRid == room.webRid
              ? item.copyWith(
                  credentialId: anonymous ? null : selected,
                  clearCredentialId: anonymous,
                )
              : item,
        )
        .toList(growable: false);
    setState(() => _rooms = next);
    await _store.save(next);
    _syncCredentialBindings();
    if (!mounted) return;
    _snack(anonymous ? '已改为匿名自动获取' : '已指定凭证，下次连接生效');
  }

  // ---------- 单个主播 ----------

  /// 拉取一次房间信息，更新主播名 / 标题 / 开播状态并落盘，并给出行内提示。
  Future<void> _refreshRoom(String webRid) async {
    // 回前台补刷正在飞的先让开：同一主播两路在飞会把风控风险翻倍（UX-13）。
    if (_roomOf(webRid) == null ||
        _refreshing.contains(webRid) ||
        _autoRefreshing.contains(webRid)) {
      return;
    }
    setState(() => _refreshing.add(webRid));

    final String? error = await _refreshRoomQuiet(webRid);
    if (!mounted) return;
    setState(() => _refreshing.remove(webRid));

    if (error != null) {
      _snack('刷新失败：$error');
      return;
    }
    _syncOverlayRooms();
    final ManagedRoom? target = _roomOf(webRid);
    if (target != null) _snack('已刷新 ${target.displayName}');
  }

  /// 刷新单个主播的静默版本：成功返回 null，失败返回可读原因。
  ///
  /// 与 [_refreshRoom] 的区别是不弹提示、不推送悬浮窗候选：批量刷新时由调用方
  /// 统一收尾，否则刷 8 个主播会弹 8 个 SnackBar、发 8 次配置（UX-04）。
  ///
  /// [persist] 为 false 时不落盘：批量刷新逐条写 rooms.json 会把同一个文件写 N 次
  /// （8 个主播就是 8 次），由调用方在整批结束后统一保存一次（UX-11）。
  Future<String?> _refreshRoomQuiet(
    String webRid, {
    bool persist = true,
  }) async {
    final ManagedRoom? current = _roomOf(webRid);
    if (current == null) return '主播已不在列表中';

    ManagedRoom? updated;
    try {
      final RoomInfo info = await _roomInfoClient.fetchByWebRid(
        webRid,
        // 指定了凭证的主播用它的凭证刷新，未指定的走匿名自动获取。
        credentialCookies: roomCookiesFor(webRid),
      );
      updated = current.copyWith(
        // 未开播时接口不返回昵称/标题，保留上一次的缓存值。
        owner: info.owner.isNotEmpty ? info.owner : null,
        title: info.title.isNotEmpty ? info.title : null,
        living: info.living,
        // 只有成功这一条路径写时间：失败还标「刚刚刷新过」等于骗用户（UX-04）。
        lastRefreshedAt: _nowMillis(),
      );
    } on Object catch (exception) {
      return '$exception';
    }
    if (!mounted) return '页面已关闭';

    final ManagedRoom target = updated;
    final List<ManagedRoom> next = _rooms
        .map((ManagedRoom item) => item.webRid == webRid ? target : item)
        .toList(growable: false);
    setState(() => _rooms = next);
    if (persist) await _store.save(next);
    return null;
  }

  /// 串行刷新列表里全部主播（UX-04）。
  ///
  /// 刻意串行而不是并发：房间接口对同 IP 的并发请求不友好，一次打太多容易整批失败；
  /// 串行还能让进度条逐行往前走，用户看得见进展。
  Future<void> _refreshAll() async {
    if (_refreshAllRunning) return;
    final List<String> targets = <String>[
      for (final ManagedRoom room in _rooms)
        if (!_refreshing.contains(room.webRid) &&
            !_autoRefreshing.contains(room.webRid))
          room.webRid,
    ];
    if (targets.isEmpty) {
      _snack(_rooms.isEmpty ? '列表为空，没有可刷新的主播' : '所有主播都在刷新中');
      return;
    }
    // 行内正在单独刷新的主播会被跳过：提示里说清楚，否则用户会以为漏刷了。
    final int skipped = _rooms.length - targets.length;

    setState(() {
      _refreshAllRunning = true;
      _refreshAllDone = 0;
      _refreshAllTotal = targets.length;
    });
    int ok = 0;
    int failed = 0;
    for (final String webRid in targets) {
      final String? error = await _refreshRoomQuiet(webRid, persist: false);
      if (!mounted) return;
      if (error == null) {
        ok++;
      } else {
        failed++;
      }
      setState(() => _refreshAllDone++);
    }
    if (!mounted) return;
    // 整批刷完只落盘一次：逐条写会把 rooms.json 写 N 次，慢且更容易留下半批数据（UX-11）。
    await _store.save(_rooms);
    if (!mounted) return;
    setState(() => _refreshAllRunning = false);
    _syncOverlayRooms();
    String summary = failed == 0
        ? '已刷新全部 $ok 个主播'
        : '刷新完成：成功 $ok 个，失败 $failed 个';
    if (skipped > 0) summary = '$summary（$skipped 个正在刷新中，已跳过）';
    _snack(summary);
  }

  /// 当前时间（epoch 毫秒）；与 [formatRefreshedAgo] 的口径一致（AGENTS 第 5 节）。
  int _nowMillis() => DateTime.now().millisecondsSinceEpoch;

  ManagedRoom? _roomOf(String webRid) {
    for (final ManagedRoom item in _rooms) {
      if (item.webRid == webRid) return item;
    }
    return null;
  }

  /// 已使用的分组名，按列表中首次出现的顺序（prd F14）；未分组不在其中。
  List<String> get _groups {
    final List<String> groups = <String>[];
    for (final ManagedRoom room in _rooms) {
      if (room.group.isEmpty || groups.contains(room.group)) continue;
      groups.add(room.group);
    }
    return groups;
  }

  /// 单栏连接：进入 App 内弹幕页（页内可再开悬浮窗）。
  Future<void> _connectSingle(ManagedRoom room) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            DanmuPage(webRid: room.webRid, title: room.displayName),
      ),
    );
  }

  // ---------- 多栏悬浮窗 ----------

  Future<void> _openMulti() async {
    final Set<String> known =
        _rooms.map((ManagedRoom room) => room.webRid).toSet();
    final List<ManagedRoom>? selected = await showDialog<List<ManagedRoom>>(
      context: context,
      builder: (BuildContext context) => _MultiSelectDialog(
        rooms: _rooms,
        // 带出上次的栏位绑定；期间被移除的主播不再预勾选。
        initialSelection:
            _prefs.webRids.where(known.contains).toList(growable: false),
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    final List<String> webRids =
        selected.map((ManagedRoom room) => room.webRid).toList(growable: false);
    // 超过 4 栏属于高性能模式，切换前强制确认（prd F4，无「不再提示」）；
    // 与悬浮窗内加栏共用同一份弹窗，保证两处口径一致（UX-05）。
    if (needsHighPerformanceConfirm(webRids.length)) {
      final bool goOn = await confirmHighPerformance(context, webRids.length);
      if (!goOn || !mounted) return;
    }
    // 点「开启悬浮窗」后直接连接：连接前的二次确认已按需求移除。
    final OverlayConfig config = _prefs.toConfig(
      webRids,
      filter: _filter,
      roomOptions: _roomOptions,
    );
    final Size screen = MediaQuery.sizeOf(context);
    // 窗口不能大于屏幕，否则会溢出。
    final ({double width, double height}) size = fitOverlaySize(
      _prefs.windowSize,
      screenWidth: screen.width,
      screenHeight: screen.height,
    );
    final double dpr = MediaQuery.devicePixelRatioOf(context);

    // 记住本次栏位绑定，下次打开多栏弹窗直接带出。
    final OverlayPrefs nextPrefs = _prefs.copyWith(webRids: webRids);
    setState(() => _prefs = nextPrefs);
    unawaited(_prefsStore.save(nextPrefs));

    if (overlayShown) {
      // 已建窗（含在弹幕页开的单栏窗）：按新尺寸重排并重新下发房间，无需关闭重开。
      await resizeOverlay(config, size: size);
    } else {
      if (!await ensureOverlayPermission()) {
        if (!mounted) return;
        // 被拒后走降级：顶部常驻提示 + App 内查看（prd 4.10）。
        setState(() => _overlayPermissionDenied = true);
        _snack('未授予悬浮窗权限，无法开启；已降级为 App 内查看');
        return;
      }
      await openOverlay(
        config,
        devicePixelRatio: dpr,
        size: size,
        screen: (width: screen.width, height: screen.height),
      );
      if (!mounted) return;
      setState(() => _overlayPermissionDenied = false);
    }
    if (!mounted) return;
    setState(() => _overlayVisible = true);
    // 窗口刚建立 / 刚重排：把屏幕尺寸与锁定状态补给悬浮窗，供其换算与收敛尺寸。
    _pushOverlayStyle(nextPrefs);
  }

  Future<void> _closeOverlay() async {
    await closeOverlayWindow();
    if (!mounted) return;
    setState(() => _overlayVisible = false);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // 横竖屏切换时按屏幕比例换算窗口尺寸（prd F2「尺寸按比例」）。
    _syncWindowSizeWithScreen(MediaQuery.sizeOf(context));
    return Scaffold(
      appBar: AppBar(
        title: const Text('主播管理'),
        actions: <Widget>[
          if (_overlayVisible)
            IconButton(
              tooltip: '关闭悬浮窗',
              icon: const Icon(Icons.close),
              onPressed: _closeOverlay,
            ),
          IconButton(
            tooltip: '刷新全部',
            icon: _refreshAllRunning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _rooms.isEmpty || _refreshAllRunning ? null : _refreshAll,
          ),
          IconButton(
            tooltip: '多栏连接',
            icon: const Icon(Icons.grid_view),
            onPressed: _rooms.isEmpty ? null : _openMulti,
          ),
          IconButton(
            tooltip: '添加主播',
            icon: const Icon(Icons.add),
            onPressed: _add,
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_overlayPermissionDenied && !_overlayVisible)
            _buildPermissionBanner(),
          if (_refreshAllRunning) _buildRefreshAllProgress(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 「刷新全部」进行中的进度条：批量刷新可能持续十几秒，没有进度用户会以为卡死。
  Widget _buildRefreshAllProgress() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(
              value: _refreshAllTotal == 0
                  ? null
                  : _refreshAllDone / _refreshAllTotal,
            ),
            const SizedBox(height: 6),
            Text(
              '正在刷新 $_refreshAllDone/$_refreshAllTotal …',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      );

  /// 悬浮窗权限被拒时的常驻提示（prd 4.10 权限拒绝降级）。
  ///
  /// 用普通容器而不是 MaterialBanner：MaterialBanner 需要 ScaffoldMessenger
  /// 且会被后续 SnackBar 顶掉，这里的提示应当一直可见。
  Widget _buildPermissionBanner() => Material(
        color: Colors.orange.shade50,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: <Widget>[
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade900),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '悬浮窗权限未授予，当前仅能在 App 内查看',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _retryOverlayPermission,
                child: const Text('重试授权'),
              ),
              // 重试仍被拒（系统不再弹框）时给一条真能走通的出口（UX-16）。
              if (_overlayRetryFailed)
                TextButton(
                  onPressed: () => unawaited(_openSystemSettings()),
                  child: const Text('去系统设置'),
                ),
            ],
          ),
        ),
      );

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_rooms.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.55,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('还没有主播'),
                    SizedBox(height: 8),
                    Text(
                      '点击右上角 + 添加直播间号 / 链接 / 抖音号',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: _buildGroupedRooms(),
      ),
    );
  }

  /// 按分组铺开列表（prd F14）：有分组的分组在前、按首次出现顺序，
  /// 「未分组」固定排在最后；只有未分组时不显示分组标题。
  List<Widget> _buildGroupedRooms() {
    final List<String> groups = _groups;
    final List<Widget> children = <Widget>[];
    for (final String group in groups) {
      children.add(_buildGroupHeader(group));
      for (final ManagedRoom room in _rooms) {
        if (room.group != group) continue;
        children.add(_buildRoomTile(room));
        children.add(const Divider(height: 1));
      }
    }
    final List<ManagedRoom> ungrouped = <ManagedRoom>[
      for (final ManagedRoom room in _rooms)
        if (room.group.isEmpty) room,
    ];
    if (ungrouped.isNotEmpty) {
      if (groups.isNotEmpty) children.add(_buildGroupHeader('未分组'));
      for (final ManagedRoom room in ungrouped) {
        children.add(_buildRoomTile(room));
        children.add(const Divider(height: 1));
      }
    }
    return children;
  }

  /// 分组标题行；长按整行不生效，仅作为分隔标识。
  Widget _buildGroupHeader(String title) => Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        ),
      );

  /// 单行主播：整行点击 = 单栏连接；行内提供「刷新」「连接弹幕」，
  /// 长按弹出「设置分组 / 移除」。
  Widget _buildRoomTile(ManagedRoom room) {
    final bool refreshing = _refreshing.contains(room.webRid);
    final bool? living = room.living;
    final String? credentialName = _credentialNameOf(room);
    // 数据新旧直接影响「要不要再刷一次」的判断，行内必须能看出来（UX-04）。
    final String refreshedAgo = formatRefreshedAgo(
      room.lastRefreshedAt,
      now: DateTime.now(),
    );
    return ListTile(
      onTap: () => _connectSingle(room),
      onLongPress: () => _showRoomActions(room),
      leading: CircleAvatar(
        backgroundColor: living == true ? Colors.green : Colors.grey.shade400,
        child: Text(
          room.displayName.characters.first,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      title: Text(
        room.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${room.webRid} · ${_livingLabel(living)}',
            style: const TextStyle(fontSize: 12),
          ),
          if (refreshedAgo.isNotEmpty)
            Text(
              '已刷新 $refreshedAgo',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          if (room.title.isNotEmpty)
            Text(
              room.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          if (credentialName != null)
            Text(
              '凭证：$credentialName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextButton(
            // 补刷期间也禁用：同一主播不能两路在飞（UX-13）；补刷不是用户点的，
            // 因此不转圈，避免「整列表突然都在刷」的视觉噪音。
            onPressed:
                refreshing || _autoRefreshing.contains(room.webRid)
                ? null
                : () => _refreshRoom(room.webRid),
            child: refreshing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('刷新'),
          ),
          TextButton(
            onPressed: () => _connectSingle(room),
            child: const Text('连接弹幕'),
          ),
          IconButton(
            // 长按是隐藏操作：新用户看不到分组 / 凭证 /「移除主播」在哪，TalkBack
            // 用户更不可发现（UX-18）。这里补一个可见入口，打开的仍是同一份
            // _showRoomActions，长按行为保持不动。
            tooltip: '更多操作',
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showRoomActions(room),
          ),
        ],
      ),
    );
  }

  String _livingLabel(bool? living) => switch (living) {
        true => '直播中',
        false => '未开播',
        null => '未刷新',
      };

  Future<void> _confirmRemove(ManagedRoom room) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('移除主播'),
        content: Text('确定从列表移除「${room.displayName}」？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _remove(room);
  }

  /// 长按主播行的操作菜单（prd F14 / F27）：设置分组 / 使用凭证 / 移除主播。
  Future<void> _showRoomActions(ManagedRoom room) async {
    final String? credentialName = _credentialNameOf(room);
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: Text(
                room.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                room.group.isEmpty
                    ? '${room.webRid} · 未分组'
                    : '${room.webRid} · ${room.group}',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('设置分组'),
              onTap: () => Navigator.of(context).pop('group'),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('使用凭证'),
              subtitle: Text(
                credentialName == null ? '当前：匿名自动获取' : '当前：$credentialName',
              ),
              onTap: () => Navigator.of(context).pop('credential'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('移除主播'),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'group') await _editGroup(room);
    if (action == 'credential') await _editCredential(room);
    if (action == 'remove') await _confirmRemove(room);
  }
}

/// 两个绑定列表是否逐项相同（顺序敏感：栏位顺序即绑定顺序）。
bool _sameWebRids(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// 分组编辑弹窗（prd F14）：可点已有分组快速填入，也可输入新分组名；
/// 留空保存表示移出分组。
class _GroupDialog extends StatefulWidget {
  const _GroupDialog({
    required this.title,
    required this.current,
    required this.groups,
  });

  /// 主播展示名，用于提示当前操作对象。
  final String title;

  /// 当前分组；空串表示未分组。
  final String current;

  /// 已有分组名，作为快捷选项。
  final List<String> groups;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置分组'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.title,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '分组名',
              hintText: '留空表示不分组',
              border: OutlineInputBorder(),
            ),
          ),
          if (widget.groups.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final String group in widget.groups)
                  ActionChip(
                    label: Text(group),
                    onPressed: () => setState(() => _controller.text = group),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: <Widget>[
        // 取消返回 null；保存返回去空白后的分组名（空串即移出分组）。
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 主播凭证选择弹窗（prd F27）：选一份已配置凭证，或改回匿名自动获取。
///
/// 返回空串表示匿名自动获取，返回凭证 id 表示指定该份，null 表示取消。
class _CredentialPickerDialog extends StatelessWidget {
  const _CredentialPickerDialog({
    required this.title,
    required this.current,
    required this.profiles,
  });

  /// 主播展示名，用于提示当前操作对象。
  final String title;

  /// 当前绑定的凭证 id；null 表示匿名自动获取。
  final String? current;

  /// 已配置的凭证列表。
  final List<CredentialProfile> profiles;

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text('使用凭证 · $title'),
      children: <Widget>[
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(''),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              current == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: const Text('匿名自动获取'),
            subtitle: const Text('不指定，自动获取 ttwid（仅内存）'),
          ),
        ),
        for (final CredentialProfile profile in profiles)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(profile.id),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                current == profile.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(profile.name),
              subtitle: const Text('已加密保存'),
            ),
          ),
        if (profiles.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '还没有配置凭证，可在「设置 · 连接与凭证」里添加',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
      ],
    );
  }
}

/// 多栏选择弹窗：勾选要连接的主播，确认后开悬浮窗。
class _MultiSelectDialog extends StatefulWidget {
  const _MultiSelectDialog({
    required this.rooms,
    this.initialSelection = const <String>[],
  });

  final List<ManagedRoom> rooms;

  /// 上次的栏位绑定，打开时预勾选（按传进来的顺序决定初始栏位顺序）。
  final List<String> initialSelection;

  @override
  State<_MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<_MultiSelectDialog> {
  late final Set<String> _selected = <String>{
    for (final String webRid in widget.initialSelection)
      if (widget.rooms.any((ManagedRoom room) => room.webRid == webRid)) webRid,
  };

  /// 超过 4 栏为高性能模式，提示会在下一步弹出强制确认（prd F4）。
  bool get _highPerformance => needsHighPerformanceConfirm(_selected.length);

  /// 已达硬上限：未勾选的主播一律不可再勾（已勾选的仍可取消，见 prd F2 的 1~9 栏）。
  bool get _atPaneCap => !canAddPane(_selected.length);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('多栏连接'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '按选择顺序分配到各栏'
              '${_highPerformance ? '；超过 $maxStandardPaneCount 栏需二次确认高性能模式' : ''}'
              '${_atPaneCap ? '；已达上限 $maxPaneCount 栏，取消勾选后可换别的' : ''}',
              style: TextStyle(
                fontSize: 12,
                color: _highPerformance ? Colors.orange.shade800 : Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(shrinkWrap: true, children: _buildEntries()),
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
          onPressed: _selected.isEmpty ? null : _confirm,
          child: const Text('开启悬浮窗'),
        ),
      ],
    );
  }

  /// 勾选列表按分组铺开（prd F14）：有分组的分组在前、未分组在后。
  List<Widget> _buildEntries() {
    final List<String> groups = <String>[];
    for (final ManagedRoom room in widget.rooms) {
      if (room.group.isEmpty || groups.contains(room.group)) continue;
      groups.add(room.group);
    }
    final List<Widget> children = <Widget>[];
    for (final String group in groups) {
      children.add(_groupLabel(group));
      for (final ManagedRoom room in widget.rooms) {
        if (room.group == group) children.add(_buildTile(room));
      }
    }
    for (final ManagedRoom room in widget.rooms) {
      if (room.group.isEmpty) children.add(_buildTile(room));
    }
    return children;
  }

  Widget _groupLabel(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.grey,
          ),
        ),
      );

  Widget _buildTile(ManagedRoom room) {
    final bool checked = _selected.contains(room.webRid);
    return CheckboxListTile(
      dense: true,
      value: checked,
      title: Text(
        room.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(room.webRid, style: const TextStyle(fontSize: 12)),
      // 已到硬上限时只锁「未勾选」的行：已勾选的必须还能取消，否则用户被卡死在 9 栏。
      onChanged: checked || !_atPaneCap
          ? (bool? value) => setState(() {
                if (value ?? false) {
                  _selected.add(room.webRid);
                } else {
                  _selected.remove(room.webRid);
                }
              })
          : null,
    );
  }

  /// 确认时按勾选先后顺序返回，与「按选择顺序分配到各栏」的提示一致。
  void _confirm() {
    final List<ManagedRoom> ordered = <ManagedRoom>[];
    for (final String webRid in _selected) {
      for (final ManagedRoom room in widget.rooms) {
        if (room.webRid == webRid) {
          ordered.add(room);
          break;
        }
      }
    }
    Navigator.of(context).pop(ordered);
  }
}
