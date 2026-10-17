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
import 'package:danmu_float/storage/home_view_prefs.dart';
import 'package:danmu_float/storage/prefs_merge.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:danmu_float/system/system_permissions.dart';
import 'package:danmu_float/ui/add_room_dialog.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:danmu_float/ui/high_performance_dialog.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:danmu_float/ui/danmu_text_colors.dart';
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
  late final HomeViewPrefsStore _viewPrefsStore;

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

  /// 主播列表文件读不出来时的常驻提示（#82）。
  ///
  /// 与「列表为空」严格区分：空列表是正常状态，而文件损坏必须让用户知道
  /// 「原文件还在、别继续添主播把新列表当成全部数据」。null 表示一切正常。
  String? _roomsLoadWarning;

  /// 损坏文件连副本都没留住时暂停保存：否则下一次保存会覆盖唯一一份原始数据（#82）。
  bool _roomsSaveBlocked = false;

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

  /// 首页列表排序方式（#139），落盘在 home_view.json；默认添加顺序。
  String _sortMode = homeSortAdded;

  /// 当前搜索词（仅本次会话有效，不落盘）。
  String _searchQuery = '';

  /// 搜索栏是否展开。
  bool _searching = false;

  final TextEditingController _searchController = TextEditingController();

  /// 全局过滤偏好（prd F10 / F11 / F13），随建窗配置一并下发。
  final FilterStore _filterStore = FilterStore();
  FilterPrefs _filter = const FilterPrefs();

  /// 设置页打开时它看到的偏好 / 过滤快照（#97）。
  ///
  /// 设置页与过滤二级页只会在各自的进页快照上 `copyWith` 并整份回传，因此「相对快照
  /// 变过的字段」正好是用户在页内真正改的东西。写回时据此取差量，把快照里那些用户没碰、
  /// 只是被悬浮窗引擎改过的旧值挡在外面。为 null（未经本页打开）时按整份写回处理。
  OverlayPrefs? _settingsPrefsSnapshot;
  FilterPrefs? _settingsFilterSnapshot;

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
    _viewPrefsStore = HomeViewPrefsStore(directoryResolver: resolver);
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
      // 悬浮窗内改的过滤偏好：这是窗内引擎的现状，不是「相对某份快照的差量」，
      // 因此整份采用。落盘集中在本页（#97）——launcher 只负责广播，不再自己写文件。
      setState(() => _filter = filter);
      unawaited(_filterStore.save(filter));
    });
    unawaited(_load());
    unawaited(_loadPrefs());
    unawaited(_loadViewPrefs());
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
    _searchController.dispose();
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

  /// 搜索词过滤后的房间（#139）：按 主播名 / 房间标题 / webRid / 分组名 做大小写
  /// 不敏感的子串匹配。空搜索词返回全部，顺序仍是文件顺序（排序在组内做）。
  List<ManagedRoom> get _visibleRooms {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _rooms;
    return <ManagedRoom>[
      for (final ManagedRoom room in _rooms)
        if (room.displayName.toLowerCase().contains(query) ||
            room.title.toLowerCase().contains(query) ||
            room.webRid.toLowerCase().contains(query) ||
            room.group.toLowerCase().contains(query))
          room,
    ];
  }

  /// 组内排序（#139）：分组维度优先于排序维度，与 [_buildGroupedRooms] 口径一致。
  ///
  /// 「直播中优先」把未知（null）排在已开播之后、未开播之前：未知是「还没查到」，
  /// 不该和确认未开播混在一起；同级按名称，避免每次重建顺序抖动。
  List<ManagedRoom> _sortedInGroup(List<ManagedRoom> rooms) {
    if (_sortMode == homeSortAdded) return rooms;
    final List<ManagedRoom> sorted = List<ManagedRoom>.of(rooms);
    if (_sortMode == homeSortRecentlyRefreshed) {
      sorted.sort((ManagedRoom a, ManagedRoom b) {
        final int aAt = a.lastRefreshedAt ?? 0;
        final int bAt = b.lastRefreshedAt ?? 0;
        if (aAt != bAt) return bAt.compareTo(aAt);
        return a.displayName.compareTo(b.displayName);
      });
      return sorted;
    }
    int rank(ManagedRoom room) =>
        room.living == true ? 0 : (room.living == null ? 1 : 2);
    sorted.sort((ManagedRoom a, ManagedRoom b) {
      final int byLive = rank(a).compareTo(rank(b));
      if (byLive != 0) return byLive;
      return a.displayName.compareTo(b.displayName);
    });
    return sorted;
  }

  /// 读回视图偏好（#139）；失败按默认值继续，不阻塞列表。
  Future<void> _loadViewPrefs() async {
    final HomeViewPrefs prefs = await _viewPrefsStore.load();
    if (!mounted) return;
    setState(() => _sortMode = prefs.sortMode);
  }

  /// 切换排序并落盘（#139）。落盘失败只记日志：排序是纯视图偏好，
  /// 失败也不该打断用户当前操作（下次进来回到默认而已）。
  void _setSortMode(String mode) {
    if (mode == _sortMode) return;
    setState(() => _sortMode = parseHomeSortMode(mode));
    unawaited(_saveSortMode());
  }

  Future<void> _saveSortMode() async {
    try {
      await _viewPrefsStore.save(HomeViewPrefs(sortMode: _sortMode));
    } on Object catch (exception) {
      debugPrint('保存首页排序偏好失败: $exception');
    }
  }

  /// 列表工具条：搜索框 + 三种排序（#139）。
  ///
  /// 为什么不做成弹出菜单：AppBar 已有五个动作，再并排加两个图标会在 360dp 上溢出
  /// （#148 的窄屏用例就是钉这个），而弹出菜单要把排序藏进二级、看不到当前选择。
  /// 这里用一个图标就地展开工具条：搜索框常驻当前会话、排序 chip 直接把「现在按
  /// 什么排」摆在眼前，点一下即切换，没有路由动画也不遮挡列表。
  Widget _buildListTools() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('homeSearchField'),
                controller: _searchController,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: '搜索主播名 / 房间标题 / 房间号 / 分组',
                  border: const OutlineInputBorder(),
                  suffixText: _searchQuery.trim().isEmpty
                      ? null
                      : '${_visibleRooms.length} / ${_rooms.length}',
                ),
                onChanged: (String value) =>
                    setState(() => _searchQuery = value),
              ),
            ),
            IconButton(
              key: const ValueKey<String>('homeSearchClose'),
              tooltip: '退出搜索',
              icon: const Icon(Icons.close),
              onPressed: () {
                _searchController.clear();
                setState(() {
                  _searchQuery = '';
                  _searching = false;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              '排序',
              style: TextStyle(
                fontSize: 12,
                color: secondaryTextColor(Theme.of(context).brightness),
              ),
            ),
            for (final String mode in homeSortModes)
              ChoiceChip(
                key: ValueKey<String>('homeSort_$mode'),
                label: Text(homeSortLabels[mode] ?? mode),
                selected: _sortMode == mode,
                onSelected: (bool _) => _setSortMode(mode),
              ),
          ],
        ),
      ],
    ),
  );

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
    await _persistRooms(_rooms);
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
    final RoomLoadResult result = await _store.loadResult();
    if (!mounted) return;
    setState(() {
      _rooms = result.rooms;
      _loading = false;
      _applyRoomsResult(result);
    });
    _syncCredentialBindings();
  }

  /// 记录一次读取结果：损坏时给出可操作提示，留存失败时进一步暂停保存（#82）。
  void _applyRoomsResult(RoomLoadResult result) {
    _roomsLoadWarning = _roomsWarningFor(result);
    _roomsSaveBlocked = result.corrupted && result.backupPath == null;
  }

  /// 读取结果 → 常驻提示文案；正常时返回 null（#82）。
  ///
  /// 提示里必须给出去哪儿找回原文件，只说「读取失败」等于让用户干着急。
  String? _roomsWarningFor(RoomLoadResult result) {
    if (!result.corrupted) return null;
    final String? backupPath = result.backupPath;
    if (backupPath == null) {
      return '主播列表文件损坏且未能留存副本，已暂停保存以免覆盖；'
          '请先在设置页导出备份，原文件仍是应用目录下的 ${_store.fileName}';
    }
    return '主播列表文件损坏，原文件已留存副本（${backupPath.split(Platform.pathSeparator).last}），'
        '当前列表显示为空；如需找回请从备份导入，不要直接继续添加';
  }

  /// 落盘主播列表；损坏且没能留存副本时拒绝写入（#82）。
  ///
  /// 留存成功时原始字节已安全躺在 `.bad` 副本里，继续写不会丢数据；
  /// 留存失败时原文件还在原路径，再写一次就真的没了。
  Future<void> _persistRooms(List<ManagedRoom> rooms) async {
    if (_roomsSaveBlocked) {
      _snack('原主播列表未能留存副本，已暂停保存以免覆盖；请先在设置页导出备份');
      return;
    }
    await _store.save(rooms);
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
      // 这里已经是最终值，不能走设置页那条差量合并（#97）。
      _applyPrefs(
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
        themeId: prefs.themeId,
        colorOverrides: prefs.colorOverrides,
        myThemes: prefs.myThemes,
        gridDirection: prefs.gridDirection,
        contrastPolicy: prefs.contrastPolicy,
        showTitleBar: prefs.showTitleBar,
        focusBehavior: prefs.focusBehavior,
        dragLocked: prefs.dragLocked,
        clickThrough: prefs.clickThrough,
        screenWidth: screen.width,
        screenHeight: screen.height,
      ),
    );
  }

  /// 设置页改样式：它只会报告「相对进页快照变过的字段」，这里以本页当前值合并后应用（#97）。
  ///
  /// 直接整份写回会出问题：悬浮窗引擎是并发的偏好修改者，用户在窗里改完透明度 / 字号、
  /// 或把某个用户加入屏蔽后，设置页再动任意一个控件都会把进页时的旧快照整份推回——
  /// 窗内刚做的修改被静默撤销。
  void _onPrefsChanged(OverlayPrefs prefs, {required bool persist}) {
    final OverlayPrefs? snapshot = _settingsPrefsSnapshot;
    final OverlayPrefs merged = snapshot == null
        ? prefs
        : mergeOverlayPrefsChanges(
            current: _prefs,
            previous: snapshot,
            next: prefs,
          );
    _applyPrefs(merged, persist: persist);
  }

  /// 应用一份「已经是最终值」的偏好：更新内存、推给悬浮窗、必要时落盘。
  void _applyPrefs(OverlayPrefs prefs, {required bool persist}) {
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
    // 记下设置页看到的快照：它只会在这份快照上 copyWith 并整份回传，
    // 后续写回据此取差量，避免把页内没碰过的字段按旧值覆盖（#97）。
    _settingsPrefsSnapshot = _prefs;
    _settingsFilterSnapshot = _filter;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => SettingsPage(
          prefs: _prefs,
          onChanged: _onPrefsChanged,
          onResetAll: _clearAllData,
          credentialStore: _credentialStore,
          onCredentialsChanged: _onCredentialsChanged,
          filter: _filter,
          onFilterChanged: _onFilterChanged,
          onDataImported: _reloadAfterImport,
        ),
      ),
    );
  }

  /// 导入数据后重新读回全部本地数据，并把最新样式 / 过滤 / 尺寸 / 候选房间
  /// 推给已开着的悬浮窗（不重发 config，避免冲掉栏内已绑定的房间）。
  Future<void> _reloadAfterImport() async {
    final RoomLoadResult rooms = await _store.loadResult();
    final OverlayPrefs prefs = await _prefsStore.load();
    final FilterPrefs filter = await _filterStore.load();
    final ThemeMode themeMode = await _themeStore.load();
    if (!mounted) return;
    appThemeMode.value = themeMode;
    setState(() {
      _rooms = rooms.rooms;
      _applyRoomsResult(rooms);
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

  /// 设置页 / 过滤二级页改过滤偏好：同款差量合并（#97），并由本页统一落盘与下发。
  ///
  /// 落盘集中在这里：此前过滤二级页自己整份覆盖 filter.json，两份互不可见的进页快照
  /// 叠在一起写，窗内刚屏蔽的用户会被解封。
  void _onFilterChanged(FilterPrefs filter) {
    _applyFilterChange(previous: _settingsFilterSnapshot, next: filter);
  }

  /// 弹幕页改过滤偏好：它直接给出自己那份旧值，无需另存快照（#97）。
  void _onDanmuFilterChanged(FilterPrefs previous, FilterPrefs next) {
    _applyFilterChange(previous: previous, next: next);
  }

  /// 以本页当前过滤偏好为基，把 [previous] → [next] 之间变过的字段合并进来并落盘。
  ///
  /// [previous] 为 null 表示改动方没有基线（未经本页打开的独立挂载），按整份采用处理。
  void _applyFilterChange({
    required FilterPrefs? previous,
    required FilterPrefs next,
  }) {
    final FilterPrefs merged = previous == null
        ? next
        : mergeFilterPrefsChanges(
            current: _filter,
            previous: previous,
            next: next,
          );
    setState(() => _filter = merged);
    unawaited(_filterStore.save(merged));
    unawaited(shareOverlayFilter(merged));
  }

  /// 清除所有本地数据（prd F26 硬要求）：
  /// 先关闭悬浮窗断开全部连接，再清空持久化数据，最后回到免责声明页。
  ///
  /// 清除失败时不宣布重置（#92）：磁盘数据还在却显示「已恢复初始状态」，
  /// 会让用户在错误认知下处置设备；合规状态残留更会让下次冷启动直接
  /// 跳过免责声明页，静默击穿 AGENTS.md 第 1 节的硬边界。
  Future<void> _clearAllData() async {
    await teardownOverlay();
    final LocalDataResetResult result = await _dataReset.clearAll();
    if (!mounted) return;
    if (!result.clean) {
      // 悬浮窗已按顺序关闭，这一步不可逆也没关系；但内存态不能装作已重置，
      // 否则界面口径与磁盘事实分裂。
      _snack(
        result.complianceRemains
            ? '合规状态未能清除，本次重置已中止；请重试，否则重启后可能跳过免责声明页'
            : '清除未完成：${result.targets} 未能清除，请重试；'
                '若反复失败，请先在设置页导出备份',
      );
      return;
    }
    // 主题偏好文件已被删掉，界面上的主题也一并复位（prd F20）。
    appThemeMode.value = ThemeMode.system;
    setState(() {
      _rooms = const <ManagedRoom>[];
      _roomsLoadWarning = null;
      _roomsSaveBlocked = false;
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
    await _persistRooms(next);
    _syncOverlayRooms();
    // 新加的主播还没有主播名与开播状态，顺手刷一次让行内立刻可读。
    unawaited(_refreshRoom(room.webRid));
  }

  Future<void> _remove(ManagedRoom room) async {
    final List<ManagedRoom> next = _rooms
        .where((ManagedRoom item) => item.webRid != room.webRid)
        .toList(growable: false);
    setState(() => _rooms = next);
    await _persistRooms(next);
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
    await _persistRooms(next);
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
    await _persistRooms(next);
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
    if (persist) await _persistRooms(next);
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
    await _persistRooms(_rooms);
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
        builder: (BuildContext context) => DanmuPage(
          webRid: room.webRid,
          title: room.displayName,
          // 页内长按弹幕屏蔽用户 / 加屏蔽词：由本页合并落盘（#97）。
          onFilterChanged: _onDanmuFilterChanged,
        ),
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
            tooltip: '搜索与排序',
            icon: const Icon(Icons.search),
            onPressed: () => setState(() => _searching = !_searching),
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
          // 数据是否还在比权限更要紧，排在权限提示之后、进度条之前（#82）。
          if (_roomsLoadWarning != null) _buildRoomsLoadWarning(),
          if (_refreshAllRunning) _buildRefreshAllProgress(),
          if (_searching) _buildListTools(),
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

  /// 两条常驻提示条（权限被拒 prd 4.10 / 主播列表损坏 #82）的共同外观。
  ///
  /// 底色与前景按 brightness 成对取自 [bannerColors]（#137）：若只换底色、正文继续
  /// 继承 onSurface，深色主题下就是浅字压浅底（实测 1.13~1.18:1）。这里把正文、
  /// 图标、按钮文字一次钉到同一前景色上，不依赖「继承的主题色刚好对」这种巧合。
  Widget _banner({
    required bool danger,
    required IconData icon,
    required String text,
    required List<Widget> actions,
  }) {
    final ({Color background, Color foreground}) colors = bannerColors(
      brightness: Theme.of(context).brightness,
      danger: danger,
    );
    return Material(
      color: colors.background,
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 13, color: colors.foreground),
        child: IconTheme.merge(
          data: IconThemeData(color: colors.foreground),
          child: Theme(
            // 按钮文字同样是「浅色主题下恰好可读」的重灾区（深色 primary 压在
            // shade50 上只有 1.5:1），所以在这里统一覆盖，而不是逐个按钮传 style。
            data: Theme.of(context).copyWith(
              textButtonTheme: TextButtonThemeData(
                style: TextButton.styleFrom(
                  foregroundColor: colors.foreground,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
              child: Row(
                children: <Widget>[
                  Icon(icon),
                  const SizedBox(width: 8),
                  Expanded(child: Text(text)),
                  ...actions,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 悬浮窗权限被拒时的常驻提示（prd 4.10 权限拒绝降级）。
  ///
  /// 用普通容器而不是 MaterialBanner：MaterialBanner 需要 ScaffoldMessenger
  /// 且会被后续 SnackBar 顶掉，这里的提示应当一直可见。
  Widget _buildPermissionBanner() => _banner(
    danger: false,
    icon: Icons.warning_amber_rounded,
    text: '悬浮窗权限未授予，当前仅能在 App 内查看',
    actions: <Widget>[
      TextButton(onPressed: _retryOverlayPermission, child: const Text('重试授权')),
      // 重试仍被拒（系统不再弹框）时给一条真能走通的出口（UX-16）。
      if (_overlayRetryFailed)
        TextButton(
          onPressed: () => unawaited(_openSystemSettings()),
          child: const Text('去系统设置'),
        ),
    ],
  );

  /// 主播列表文件损坏时的常驻提示（#82）。
  ///
  /// 与权限 banner 同样用普通容器：这条提示直接关系到用户数据是否还在，
  /// 不能让后续 SnackBar 顶掉；文案本身已给出找回副本与导出备份的出路。
  Widget _buildRoomsLoadWarning() => _banner(
    danger: true,
    icon: Icons.error_outline,
    text: _roomsLoadWarning ?? '',
    actions: <Widget>[
      TextButton(onPressed: _openSettings, child: const Text('去设置')),
      // 留存失败时不给「知道了」：保存仍被暂停，提示必须一直在（#82）。
      if (!_roomsSaveBlocked)
        TextButton(
          onPressed: () => setState(() => _roomsLoadWarning = null),
          child: const Text('知道了'),
        ),
    ],
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
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.live_tv,
                      size: 56,
                      color: secondaryTextColor(Theme.of(context).brightness),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      // 文件损坏时列表为空是「读不出来」而不是「真没有」：此时引导添加
                      // 等于坐实数据丢失（#82），所以只给标题与提示，不给主按钮。
                      _roomsLoadWarning != null ? '主播列表读取失败' : '还没有直播间',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_roomsLoadWarning != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          '主播列表读取失败，请先按上方提示处理，暂不要添加新主播',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: secondaryTextColor(
                              Theme.of(context).brightness,
                            ),
                            fontSize: 12,
                          ),
                        ),
                      )
                    else ...<Widget>[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          // 第一屏是唯一一次讲清价值主张的机会：必须点明弹幕是
                          // 「悬浮在其他应用之上」，否则用户不知道加完会发生什么。
                          '保存直播间后，弹幕会悬浮在其他应用之上显示，'
                          '一边看直播一边刷弹幕，不打断当前操作。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: secondaryTextColor(
                              Theme.of(context).brightness,
                            ),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        // 与右上角 + 走同一个 _add()：只包一层按钮，不新增添加路径。
                        key: const ValueKey<String>('addFirstRoom'),
                        onPressed: _add,
                        icon: const Icon(Icons.add),
                        label: const Text('添加第一个直播间'),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '支持直播间号 / 分享链接 / 抖音号',
                        style: TextStyle(
                          color: secondaryTextColor(
                            Theme.of(context).brightness,
                          ),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    // 搜索无结果时给一句明确回执：空列表 + 只剩分组标题会让人以为数据丢了（#139）。
    if (_searchQuery.trim().isNotEmpty && _visibleRooms.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的直播间',
          style: TextStyle(
            color: secondaryTextColor(Theme.of(context).brightness),
          ),
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
  ///
  /// 搜索（#139）先过滤再分组：分组标题只在组内还有匹配行时出现，避免出现
  /// 「有标题、下面一片空白」；排序在组内进行，分组维度优先于排序维度。
  List<Widget> _buildGroupedRooms() {
    final List<ManagedRoom> visible = _visibleRooms;
    final List<String> groups = <String>[
      for (final String group in _groups)
        if (visible.any((ManagedRoom room) => room.group == group)) group,
    ];
    final List<Widget> children = <Widget>[];
    for (final String group in groups) {
      children.add(_buildGroupHeader(group));
      final List<ManagedRoom> members = _sortedInGroup(<ManagedRoom>[
        for (final ManagedRoom room in visible)
          if (room.group == group) room,
      ]);
      for (final ManagedRoom room in members) {
        children.add(_buildRoomTile(room));
        children.add(const Divider(height: 1));
      }
    }
    final List<ManagedRoom> ungrouped = _sortedInGroup(<ManagedRoom>[
      for (final ManagedRoom room in visible)
        if (room.group.isEmpty) room,
    ]);
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
    // 这一栏当前是否正在悬浮窗里显示（prd F8 / F15 的状态回报已写进 _prefs.webRids，
    // 与「多栏连接」弹窗同源）。用户挂机看几个直播间、回到首页想确认「在看哪几个」时，
    // 这是唯一能直接回答的地方——窗内「栏位状态」藏在悬浮球菜单里（#144）。
    // 关窗后 _overlayVisible 为 false，标识必须跟着消失，否则会出现「窗没了标记还挂着」。
    final bool inOverlay =
        _overlayVisible && _prefs.webRids.contains(room.webRid);
    // 数据新旧直接影响「要不要再刷一次」的判断，行内必须能看出来（UX-04）。
    final String refreshedAgo = formatRefreshedAgo(
      room.lastRefreshedAt,
      now: DateTime.now(),
    );
    return ListTile(
      onTap: () => _connectSingle(room),
      onLongPress: () => _showRoomActions(room),
      // 头像底色是开播状态的唯一编码（#135）：色觉障碍与屏幕阅读器用户拿不到
      // 这层信息，补等价文本，视觉不变。
      leading: Semantics(
        label: living == true ? '直播中' : '未开播',
        excludeSemantics: true,
        child: CircleAvatar(
          backgroundColor: roomAvatarBackgroundColor(living: living),
          child: Text(
            room.displayName.characters.first,
            style: TextStyle(color: roomAvatarForegroundColor()),
          ),
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
          if (inOverlay)
            // 放 subtitle 而不是 trailing：行内已有「刷新」「连接弹幕」「更多操作」，
            // 360dp 窄屏再往 trailing 塞文字必然溢出（UX-07 的教训）。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.push_pin_outlined,
                  size: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '悬浮窗显示中',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          // 开播状态是扫视重点，单独一行（#148）：跟 19 位 webRid 挤在一起时，窄屏上
          // 这行会被从数字中间折断，把「直播中 / 未开播」推成孤儿行。
          Text(
            _livingLabel(living),
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            room.webRid,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: secondaryTextColor(Theme.of(context).brightness),
            ),
          ),
          if (refreshedAgo.isNotEmpty)
            Text(
              '已刷新 $refreshedAgo',
              style: TextStyle(
                fontSize: 12,
                color: secondaryTextColor(Theme.of(context).brightness),
              ),
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
              style: TextStyle(
                fontSize: 12,
                color: credentialTextColor(Theme.of(context).brightness),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (refreshing)
            // 补刷期间也禁用：同一主播不能两路在飞（UX-13）；补刷不是用户点的，
            // 因此不转圈，避免「整列表突然都在刷」的视觉噪音。
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          // 行内只留图标按钮（#148）：原来「刷新」「连接弹幕」两个文字按钮把 360dp
          // 机型的标题列压到 ~80dp（19 位 webRid 从中间折断、房间标题只剩几个字），
          // 而且文字按钮的固有宽度会随系统字号继续变宽。图标宽度固定 48dp，
          // 标题列回到 ~176dp；「刷新」的文字语义由 tooltip 提供（TalkBack 可读），
          // 「连接弹幕」与整行点击本来就是同一个动作，已并入「更多操作」菜单。
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed:
                refreshing || _autoRefreshing.contains(room.webRid)
                ? null
                : () => _refreshRoom(room.webRid),
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
              // 行内不再放「刷新」文字按钮（#148：两个文字按钮把标题列压到 ~80dp），
              // 行内改图标按钮，菜单里也留一份显式文字入口。
              leading: const Icon(Icons.refresh),
              title: const Text('刷新'),
              subtitle: _refreshing.contains(room.webRid)
                  ? const Text('正在刷新…')
                  : null,
              enabled: !_refreshing.contains(room.webRid),
              onTap: () => Navigator.of(context).pop('refresh'),
            ),
            ListTile(
              // 「连接弹幕」原来独占行内约 80dp，动作与整行点击完全相同（都是
              // _connectSingle）；挪进菜单，入口没少、宽度省了下来（#148）。
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('连接弹幕'),
              onTap: () => Navigator.of(context).pop('connect'),
            ),
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
    if (action == 'refresh') await _refreshRoom(room.webRid);
    if (action == 'connect') await _connectSingle(room);
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
            style: TextStyle(
              fontSize: 12,
              color: secondaryTextColor(Theme.of(context).brightness),
            ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '还没有配置凭证，可在「设置 · 连接与凭证」里添加',
              style: TextStyle(
                fontSize: 12,
                color: secondaryTextColor(Theme.of(context).brightness),
              ),
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
