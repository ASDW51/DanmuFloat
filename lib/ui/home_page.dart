// 首页 = 主播管理：添加 / 持久化 / 刷新 / 连接弹幕。
//
// 交互约定（本轮确认）：
// - 右上角 + 添加主播，添加后立即落盘，冷启动或下拉刷新时重新读取
// - 行内「刷新」拉一次房间信息，更新主播名 / 标题 / 开播状态
// - 点击整行或行内「连接弹幕」= 单栏连接，进入 App 内弹幕页（页内可再开悬浮窗）
// - 右上角多栏按钮 = 勾选主播后开多栏悬浮窗（最多 9 栏，3×3）
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
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
import 'package:danmu_float/ui/add_room_dialog.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.onResetAll});

  /// 「清除所有本地数据」完成后回调外层，把入口切回免责声明页（prd F26）。
  final VoidCallback? onResetAll;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final RoomStore _store = RoomStore();
  final OverlayPrefsStore _prefsStore = OverlayPrefsStore();

  /// 凭证存储：手动粘贴的凭证加密落盘，启动时读回并接管取值（prd F27）。
  late final CredentialStore _credentialStore = CredentialStore();

  /// 「清除所有本地数据」用；与页面共用同一个凭证实例，清完状态才一致。
  late final LocalDataReset _dataReset =
      LocalDataReset(credentialStore: _credentialStore);

  /// 刷新房间信息用的客户端：复用同一个实例以共享 ttwid 缓存与连接池。
  final RoomInfoClient _roomInfoClient = RoomInfoClient();

  List<ManagedRoom> _rooms = const <ManagedRoom>[];
  bool _loading = true;

  /// 正在刷新房间信息的直播间号（行内按钮转圈用）。
  final Set<String> _refreshing = <String>{};

  /// 悬浮窗样式与分栏偏好（透明度、上次勾选的主播）。
  OverlayPrefs _prefs = const OverlayPrefs();

  /// 全局过滤偏好（prd F10 / F11 / F13），随建窗配置一并下发。
  final FilterStore _filterStore = FilterStore();
  FilterPrefs _filter = const FilterPrefs();

  bool _overlayVisible = false;

  /// 悬浮窗权限是否被拒（prd 4.10 权限拒绝降级）：为真时首页顶部常驻提示，
  /// 并给一个「重试授权」按钮，不阻断 App 内查看弹幕。
  bool _overlayPermissionDenied = false;

  /// 监听悬浮窗上报：权限被撤销时悬浮窗会自行断开，这里同步按钮状态。
  StreamSubscription<OverlayStatus>? _overlaySubscription;

  @override
  void initState() {
    super.initState();
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
      // 悬浮窗内切换了某栏绑定的房间（prd F8 / F15）：把最新绑定落盘。
      _applyReportedBindings(status.webRids);
    });
    unawaited(_load());
    unawaited(_loadPrefs());
    unawaited(_loadFilter());
    // 凭证要先于任何连接读回：刷新房间信息与弹幕连接都按同一份取值。
    unawaited(_credentialStore.load());
    unawaited(_refreshOverlayPermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
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
    }
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
    _snack(
      _overlayPermissionDenied
          ? '未授予悬浮窗权限，当前仅能在 App 内查看'
          : '已授予悬浮窗权限，可开启悬浮窗了',
    );
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

  /// 悬浮窗内改绑后回报的最新绑定：与本地偏好不一致时落盘（prd F8 / F15）。
  void _applyReportedBindings(List<String> webRids) {
    if (webRids.isEmpty) return;
    if (_sameWebRids(webRids, _prefs.webRids)) return;
    final OverlayPrefs next = _prefs.copyWith(webRids: webRids);
    setState(() => _prefs = next);
    unawaited(_prefsStore.save(next));
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
  }

  Future<void> _loadPrefs() async {
    final OverlayPrefs prefs = await _prefsStore.load();
    if (!mounted) return;
    setState(() => _prefs = prefs);
  }

  Future<void> _loadFilter() async {
    final FilterPrefs filter = await _filterStore.load();
    if (!mounted) return;
    setState(() => _filter = filter);
  }

  /// 设置页改样式：先更新内存并推给已开着的悬浮窗，需要落盘时才写文件。
  void _onPrefsChanged(OverlayPrefs prefs, {required bool persist}) {
    final bool sizeChanged = prefs.windowWidth != _prefs.windowWidth ||
        prefs.windowHeight != _prefs.windowHeight;
    setState(() => _prefs = prefs);
    // 只推样式与尺寸：此时窗口里绑的是哪些房间由当前持有悬浮窗的页面决定，
    // 重发 config 会把绑定冲掉。
    //
    // 这里不判断本页的开关状态：悬浮窗可能是在弹幕页开的，
    // 窗口是否已开由 overlay_launcher 统一持有，没开时两处调用会静默忽略。
    unawaited(
      shareOverlayStyle(
        opacity: prefs.opacity,
        fontSize: prefs.fontSize,
        scrollSpeed: prefs.scrollSpeed,
        paneStyles: prefs.paneStyles,
        lightTheme: prefs.lightTheme,
        showTitleBar: prefs.showTitleBar,
        focusBehavior: prefs.focusBehavior,
      ),
    );
    if (sizeChanged) {
      final Size screen = MediaQuery.sizeOf(context);
      updateOverlaySize(
        fitOverlaySize(
          prefs.windowSize,
          screenWidth: screen.width,
          screenHeight: screen.height,
        ),
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
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
          filter: _filter,
          filterStore: _filterStore,
          onFilterChanged: _onFilterChanged,
        ),
      ),
    );
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
      _refreshing.clear();
      _overlayVisible = false;
    });
    widget.onResetAll?.call();
  }

  Future<void> _add() async {
    final ManagedRoom? room = await showAddRoomDialog(
      context,
      existingWebRids:
          _rooms.map((ManagedRoom item) => item.webRid).toSet(),
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
    _syncOverlayRooms();
    if (mounted) _snack('已移除 ${room.displayName}');
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
        .map((ManagedRoom item) => item.webRid == room.webRid
            ? item.copyWith(group: group)
            : item)
        .toList(growable: false);
    setState(() => _rooms = next);
    await _store.save(next);
    _syncOverlayRooms();
    if (mounted) _snack(group.isEmpty ? '已移出分组' : '已归入「$group」');
  }

  // ---------- 单个主播 ----------

  /// 拉取一次房间信息，更新主播名 / 标题 / 开播状态并落盘。
  Future<void> _refreshRoom(String webRid) async {
    final ManagedRoom? current = _roomOf(webRid);
    if (current == null || _refreshing.contains(webRid)) return;
    setState(() => _refreshing.add(webRid));

    ManagedRoom? updated;
    String? error;
    try {
      final RoomInfo info = await _roomInfoClient.fetchByWebRid(webRid);
      updated = current.copyWith(
        // 未开播时接口不返回昵称/标题，保留上一次的缓存值。
        owner: info.owner.isNotEmpty ? info.owner : null,
        title: info.title.isNotEmpty ? info.title : null,
        living: info.living,
      );
    } on Object catch (exception) {
      error = '$exception';
    }
    if (!mounted) return;
    setState(() => _refreshing.remove(webRid));

    if (updated == null) {
      _snack('刷新失败：$error');
      return;
    }
    final ManagedRoom target = updated;
    final List<ManagedRoom> next = _rooms
        .map((ManagedRoom item) => item.webRid == webRid ? target : item)
        .toList(growable: false);
    setState(() => _rooms = next);
    await _store.save(next);
    _syncOverlayRooms();
    if (mounted) _snack('已刷新 ${target.displayName}');
  }

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
        initialSelection: _prefs.webRids
            .where(known.contains)
            .toList(growable: false),
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    final List<String> webRids =
        selected.map((ManagedRoom room) => room.webRid).toList(growable: false);
    // 超过 4 栏属于高性能模式，切换前强制确认（prd F4，无「不再提示」）。
    if (webRids.length > maxStandardPaneCount) {
      final bool goOn = await _confirmHighPerformance(webRids.length);
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
      await resizeOverlay(config, devicePixelRatio: dpr, size: size);
    } else {
      if (!await ensureOverlayPermission()) {
        if (!mounted) return;
        // 被拒后走降级：顶部常驻提示 + App 内查看（prd 4.10）。
        setState(() => _overlayPermissionDenied = true);
        _snack('未授予悬浮窗权限，无法开启；已降级为 App 内查看');
        return;
      }
      await openOverlay(config, devicePixelRatio: dpr, size: size);
      if (!mounted) return;
      setState(() => _overlayPermissionDenied = false);
    }
    if (!mounted) return;
    setState(() => _overlayVisible = true);
  }

  Future<void> _closeOverlay() async {
    await closeOverlayWindow();
    if (!mounted) return;
    setState(() => _overlayVisible = false);
  }

  /// 超过 4 栏的高性能模式确认（prd F4）：强制确认，不提供「不再提示」。
  Future<bool> _confirmHighPerformance(int paneCount) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('高性能模式'),
        content: Text(
          '本次要开 $paneCount 栏：栏数越多，同时维持的弹幕连接与绘制负载越高，'
          '低端设备可能出现卡顿或发热。建议先按栏数调大悬浮窗尺寸，并关闭不必要的栏。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续开启'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
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
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

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
      title: Text(room.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${room.webRid} · ${_livingLabel(living)}',
            style: const TextStyle(fontSize: 12),
          ),
          if (room.title.isNotEmpty)
            Text(
              room.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextButton(
            onPressed: refreshing ? null : () => _refreshRoom(room.webRid),
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

  /// 长按主播行的操作菜单（prd F14）：设置分组 / 移除主播。
  Future<void> _showRoomActions(ManagedRoom room) async {
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.current);

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
                    onPressed: () =>
                        setState(() => _controller.text = group),
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
          onPressed: () =>
              Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 多栏选择弹窗：勾选要连接的主播，确认后开悬浮窗。
class _MultiSelectDialog extends StatefulWidget {
  const _MultiSelectDialog({required this.rooms, this.initialSelection = const <String>[]});

  final List<ManagedRoom> rooms;

  /// 上次的栏位绑定，打开时预勾选（按传进来的顺序决定初始栏位顺序）。
  final List<String> initialSelection;

  @override
  State<_MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<_MultiSelectDialog> {
  /// 与悬浮窗最大栏位数一致（3×3 网格）。
  static const int _maxSelectable = maxPaneCount;

  late final Set<String> _selected = <String>{
    for (final String webRid in widget.initialSelection)
      if (widget.rooms.any((ManagedRoom room) => room.webRid == webRid))
        webRid,
  };

  /// 超过 4 栏为高性能模式，提示会在下一步弹出强制确认（prd F4）。
  bool get _highPerformance => _selected.length > maxStandardPaneCount;

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
              '最多选择 $_maxSelectable 个主播，按选择顺序分配到各栏'
              '${_highPerformance ? '；超过 $maxStandardPaneCount 栏需二次确认高性能模式' : ''}',
              style: TextStyle(
                fontSize: 12,
                color: _highPerformance ? Colors.orange.shade800 : Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: _buildEntries(),
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
    // 已达上限时禁用未勾选项，避免"选了却没生效"。
    final bool selectable = checked || _selected.length < _maxSelectable;
    return CheckboxListTile(
      dense: true,
      value: checked,
      title: Text(room.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(room.webRid, style: const TextStyle(fontSize: 12)),
      onChanged: selectable
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