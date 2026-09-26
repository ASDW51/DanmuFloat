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
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/ui/add_room_dialog.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:danmu_float/ui/settings_page.dart';
import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final RoomStore _store = RoomStore();
  final OverlayPrefsStore _prefsStore = OverlayPrefsStore();

  /// 刷新房间信息用的客户端：复用同一个实例以共享 ttwid 缓存与连接池。
  final RoomInfoClient _roomInfoClient = RoomInfoClient();

  List<ManagedRoom> _rooms = const <ManagedRoom>[];
  bool _loading = true;

  /// 正在刷新房间信息的直播间号（行内按钮转圈用）。
  final Set<String> _refreshing = <String>{};

  /// 悬浮窗样式与分栏偏好（透明度、上次勾选的主播）。
  OverlayPrefs _prefs = const OverlayPrefs();

  bool _overlayVisible = false;

  /// 监听悬浮窗上报：权限被撤销时悬浮窗会自行断开，这里同步按钮状态。
  StreamSubscription<OverlayStatus>? _overlaySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _overlaySubscription = overlayStatusStream.listen((OverlayStatus status) {
      if (!status.permissionRevoked || !mounted) return;
      setState(() => _overlayVisible = false);
    });
    unawaited(_load());
    unawaited(_loadPrefs());
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
    if (state == AppLifecycleState.resumed) unawaited(_checkOverlayAlive());
  }

  Future<void> _checkOverlayAlive() async {
    if (!_overlayVisible) return;
    if (await verifyOverlayPermission()) return;
    if (!mounted) return;
    setState(() => _overlayVisible = false);
    _snack('悬浮窗已失效（权限被撤销或被系统移除），已关闭');
  }

  // ---------- 本地列表 ----------

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
      shareOverlayStyle(opacity: prefs.opacity, fontSize: prefs.fontSize),
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
        ),
      ),
    );
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
    // 新加的主播还没有主播名与开播状态，顺手刷一次让行内立刻可读。
    unawaited(_refreshRoom(room.webRid));
  }

  Future<void> _remove(ManagedRoom room) async {
    final List<ManagedRoom> next = _rooms
        .where((ManagedRoom item) => item.webRid != room.webRid)
        .toList(growable: false);
    setState(() => _rooms = next);
    await _store.save(next);
    if (mounted) _snack('已移除 ${room.displayName}');
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
    if (mounted) _snack('已刷新 ${target.displayName}');
  }

  ManagedRoom? _roomOf(String webRid) {
    for (final ManagedRoom item in _rooms) {
      if (item.webRid == webRid) return item;
    }
    return null;
  }

  /// 单栏连接：进入 App 内弹幕页（页内可再开悬浮窗）。
  void _connectSingle(ManagedRoom room) {
    Navigator.of(context).push(
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
    final OverlayConfig config = _prefs.toConfig(webRids);
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
        _snack('未授予悬浮窗权限，无法开启');
        return;
      }
      await openOverlay(config, devicePixelRatio: dpr, size: size);
    }
    if (!mounted) return;
    setState(() => _overlayVisible = true);
  }

  Future<void> _closeOverlay() async {
    await closeOverlayWindow();
    if (!mounted) return;
    setState(() => _overlayVisible = false);
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
      body: _buildBody(),
    );
  }

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
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _rooms.length,
        separatorBuilder: (BuildContext context, int index) =>
            const Divider(height: 1),
        itemBuilder: (BuildContext context, int index) =>
            _buildRoomTile(_rooms[index]),
      ),
    );
  }

  /// 单行主播：整行点击 = 单栏连接；行内提供「刷新」「连接弹幕」，长按移除。
  Widget _buildRoomTile(ManagedRoom room) {
    final bool refreshing = _refreshing.contains(room.webRid);
    final bool? living = room.living;
    return ListTile(
      onTap: () => _connectSingle(room),
      onLongPress: () => _confirmRemove(room),
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
  static const int _maxSelectable = 9;

  late final Set<String> _selected = <String>{
    for (final String webRid in widget.initialSelection)
      if (widget.rooms.any((ManagedRoom room) => room.webRid == webRid))
        webRid,
  };

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
              '最多选择 $_maxSelectable 个主播，按选择顺序分配到各栏',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView(
                shrinkWrap: true,
                children: widget.rooms.map(_buildTile).toList(growable: false),
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