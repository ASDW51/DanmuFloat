// App 内弹幕页：单个主播的房间信息 + 实时弹幕（浅色 Material 风格）。
//
// 与悬浮窗共用展示口径（danmaku_display.dart），差别只在配色：浮动窗是深色半透明，
// 这里是浅色页面，正文用默认文字色而不是白色。
// 进入页面即自动连接，退出即释放连接（prd 4.11 的连接释放要求）。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/danmu/auto_scroll.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 页面内保留的弹幕条数上限，与 design.md 第 8 章默认缓存一致。
const int _displayLimit = 500;

/// 高亮片段样式（prd F11）：浅色页面用黄底深字。
const TextStyle _highlightStyle = TextStyle(
  color: Color(0xFF7A5B00),
  fontWeight: FontWeight.bold,
  backgroundColor: Color(0x66FFEB3B),
);

class DanmuPage extends StatefulWidget {
  const DanmuPage({super.key, required this.webRid, this.title});

  /// 要连接的直播间号。
  final String webRid;

  /// 列表里的展示名（备注 / 主播名），仅作标题占位，连接成功后改用主播昵称。
  final String? title;

  @override
  State<DanmuPage> createState() => _DanmuPageState();
}

class _DanmuPageState extends State<DanmuPage> with WidgetsBindingObserver {
  /// 本页收到的全部相关弹幕（未过滤）。展示与否在 build 时按过滤口径派生，
  /// 这样从设置页改了屏蔽词 / 类型后重进本页能立刻按新口径显示。
  final List<DanmakuEvent> _raw = <DanmakuEvent>[];
  final ScrollController _scrollController = ScrollController();
  late final DanmakuAutoScroller _autoScroller =
      DanmakuAutoScroller(_scrollController);

  /// 悬浮窗样式偏好：本页用到字号与滚动速度。
  final OverlayPrefsStore _prefsStore = OverlayPrefsStore();
  OverlayPrefs _prefs = const OverlayPrefs();

  /// 全局过滤偏好（prd F10 / F11 / F13）。
  final FilterStore _filterStore = FilterStore();
  FilterPrefs _filter = const FilterPrefs();

  LiveDanmuSession? _session;
  StreamSubscription<LiveSessionStage>? _stageSubscription;
  StreamSubscription<DanmakuEvent>? _danmuSubscription;

  LiveSessionStage _stage = LiveSessionStage.idle;
  String? _errorMessage;
  int _received = 0;

  /// 是否已暂停跟随（prd F9）：暂停时不自动滚动，但新弹幕仍写入缓存。
  bool _paused = false;

  /// 是否处于回溯态（prd F12）：暂停后向上翻看缓存时置位，显示「回到最新」。
  bool _backtracking = false;

  /// 在线人数，只取「xxx在线观众」房间统计消息（prd F6）。
  int _online = 0;

  /// 最新一条进场信息，固定显示在底部单行。
  DanmakuEvent? _latestEntry;

  bool _overlayVisible = false;
  OverlayStatus? _overlayState;
  StreamSubscription<OverlayStatus>? _overlaySubscription;

  @override
  void initState() {
    super.initState();
    // 监听滚动位置以感知「向上回溯」（prd F12）：只在暂停态生效，见 _onScroll。
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _overlaySubscription = overlayStatusStream.listen((OverlayStatus state) {
      if (!mounted) return;
      setState(() {
        _overlayState = state;
        // 悬浮窗自查发现权限被撤销且已自行断开：按钮状态同步回未开启。
        if (state.permissionRevoked) _overlayVisible = false;
      });
    });
    unawaited(_loadPrefs());
    unawaited(_loadFilter());
    unawaited(_connect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
    _stageSubscription?.cancel();
    _danmuSubscription?.cancel();
    _session?.stop();
    _autoScroller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final OverlayPrefs prefs = await _prefsStore.load();
    if (!mounted) return;
    setState(() => _prefs = prefs);
    _autoScroller.speed = prefs.scrollSpeed;
  }

  Future<void> _loadFilter() async {
    final FilterPrefs filter = await _filterStore.load();
    if (!mounted) return;
    setState(() => _filter = filter);
  }

  /// 暂停态下离底超过阈值即进入回溯；回到底部则退出（prd F12 状态流转）。
  void _onScroll() {
    if (!_paused || !_scrollController.hasClients) return;
    // 自动滚动动画自身造成的位移不算用户回溯。
    if (_autoScroller.animating) return;
    final ScrollPosition position = _scrollController.position;
    final bool atBottom = position.maxScrollExtent - position.pixels <= 24;
    if (!atBottom && !_backtracking) {
      setState(() => _backtracking = true);
    } else if (atBottom && _backtracking) {
      setState(() => _backtracking = false);
    }
  }

  /// 暂停 / 继续跟随（prd F9）；继续时平滑追到最新一条。
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

  Future<void> _connect() async {
    final LiveDanmuSession session = LiveDanmuSession(webRid: widget.webRid);
    _session = session;
    _stageSubscription = session.stages.listen((LiveSessionStage stage) {
      if (!mounted) return;
      setState(() {
        _stage = stage;
        _errorMessage = session.errorMessage;
      });
    });
    // 房间统计只用来更新在线人数、进场只进底部单行，过滤时都不能挡掉。
    _danmuSubscription = session.danmu
        .where((DanmakuEvent event) =>
            event.isDisplayable && isStreamRelevant(event.kind))
        .listen(_onEvent);
    setState(() => _stage = LiveSessionStage.resolvingRoom);
    await session.start();
    if (!mounted) return;
    setState(() => _errorMessage = session.errorMessage ?? session.signatureWarning);
  }

  void _onEvent(DanmakuEvent event) {
    if (!mounted) return;
    setState(() {
      final int online = event.onlineCount;
      if (online > 0) _online = online;
      _received++;
      if (event.kind == DanmakuKind.member) {
        // 被屏蔽用户的进场也不展示（prd F10 全局生效）。
        if (isBlockedBy(event, _filter)) {
          if (_latestEntry?.user.userId == event.user.userId) {
            _latestEntry = null;
          }
        } else {
          _latestEntry = event;
          // 在类型筛选里勾选了「进场」时同样入列（prd F13），否则勾了没有效果。
          if (isListKind(event.kind, _filter)) _addToRaw(event);
        }
      } else if (event.kind != DanmakuKind.roomStats) {
        // 其余相关弹幕先全部入缓存，展示与否在 build 时按过滤口径派生。
        _addToRaw(event);
      }
    });
    if (!_paused) _autoScroller.schedule();
  }

  /// 写入列表缓存并裁剪到展示上限。
  void _addToRaw(DanmakuEvent event) {
    _raw.add(event);
    if (_raw.length > _displayLimit) {
      _raw.removeRange(0, _raw.length - _displayLimit);
    }
  }

  /// 按当前过滤口径派生的可见列表（prd F10 / F13）。
  List<DanmakuEvent> get _visible => <DanmakuEvent>[
        for (final DanmakuEvent event in _raw)
          if (isListKind(event.kind, _filter) && !isBlockedBy(event, _filter))
            event,
      ];

  /// 开启 / 关闭本房间的单栏悬浮窗。
  Future<void> _toggleOverlay() async {
    if (_overlayVisible) {
      await closeOverlayWindow();
      if (!mounted) return;
      setState(() => _overlayVisible = false);
      return;
    }

    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final Size screen = MediaQuery.sizeOf(context);
    if (!await ensureOverlayPermission()) {
      if (!mounted) return;
      _snack('未授予悬浮窗权限，无法开启');
      return;
    }
    await openOverlay(
      _prefs.toConfig(<String>[widget.webRid], filter: _filter),
      devicePixelRatio: dpr,
      // 窗口不能大于屏幕，否则会溢出。
      size: fitOverlaySize(
        _prefs.windowSize,
        screenWidth: screen.width,
        screenHeight: screen.height,
      ),
    );
    if (!mounted) return;
    setState(() => _overlayVisible = true);
  }

  /// 汇总当前诊断信息，供用户一键复制反馈（真机问题排查用）。
  String _buildDiagnostics() {
    final RoomInfo? room = _session?.room;
    final StringBuffer buffer = StringBuffer()
      ..writeln('页面: App 内弹幕页')
      ..writeln('阶段: ${_stageLabel(_stage)}')
      ..writeln('webRid: ${widget.webRid}')
      ..writeln('已收条数: $_received')
      ..writeln('连接状态: ${_session?.connectionState.name ?? '未连接'}');
    if (room != null) {
      buffer
        ..writeln('主播: ${room.owner}')
        ..writeln('liveId: ${room.liveId}')
        ..writeln('标题: ${room.title}');
    }
    if (_errorMessage != null) buffer.writeln('错误: $_errorMessage');
    if (_session?.signatureDegraded ?? false) {
      buffer.writeln('签名降级为 $fallbackDanmuSignature: ${_session!.signatureWarning}');
    }
    if (_session?.socketError != null) {
      buffer.writeln('连接错误: ${_session!.socketError}');
    }
    return buffer.toString().trimRight();
  }

  Future<void> _copyDiagnostics() async {
    await Clipboard.setData(ClipboardData(text: _buildDiagnostics()));
    if (!mounted) return;
    _snack('已复制诊断信息');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final RoomInfo? room = _session?.room;
    final String title = room != null && room.owner.isNotEmpty
        ? room.owner
        : (widget.title?.isNotEmpty ?? false ? widget.title! : widget.webRid);
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: <Widget>[
          IconButton(
            tooltip: _overlayVisible ? '关闭悬浮窗' : '开启悬浮窗',
            icon: Icon(
              _overlayVisible
                  ? Icons.picture_in_picture_alt
                  : Icons.picture_in_picture_alt_outlined,
            ),
            onPressed: _toggleOverlay,
          ),
          IconButton(
            tooltip: '复制诊断信息',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyDiagnostics,
          ),
          IconButton(
            tooltip: _paused ? '继续（跳到最新）' : '暂停',
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            onPressed: _togglePaused,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() {
              _raw.clear();
              _received = 0;
            }),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _buildStatusBar(room),
          const Divider(height: 1),
          Expanded(child: _buildEventList()),
          if (_latestEntry != null) _buildEntryBanner(_latestEntry!),
        ],
      ),
    );
  }

  Widget _buildStatusBar(RoomInfo? room) {
    final Color color = switch (_stage) {
      LiveSessionStage.live => Colors.green,
      LiveSessionStage.offline => Colors.orange,
      LiveSessionStage.error => Colors.red,
      LiveSessionStage.idle => Colors.grey,
      _ => Colors.blue,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(_stageLabel(_stage), style: TextStyle(color: color)),
              const SizedBox(width: 12),
              Text('已收 $_received 条'),
              if (_online > 0) ...<Widget>[
                const SizedBox(width: 12),
                Text('在线 ${formatOnlineCount(_online)}'),
              ],
              if (_session != null) ...<Widget>[
                const SizedBox(width: 12),
                Text('连接: ${_session!.connectionState.name}'),
              ],
            ],
          ),
          if (room != null && room.title.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(room.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (_errorMessage != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
          ],
          if (_overlayState != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '悬浮窗: ${_stageLabel(_overlayState!.stage)} · '
              '已收 ${_overlayState!.received} 条'
              '${_overlayState!.error == null ? '' : ' · ${_overlayState!.error}'}',
              style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  String _stageLabel(LiveSessionStage stage) => switch (stage) {
        LiveSessionStage.idle => '未连接',
        LiveSessionStage.resolvingRoom => '解析房间信息…',
        LiveSessionStage.signing => '生成签名…',
        LiveSessionStage.connecting => '连接中…',
        LiveSessionStage.live => '已连接',
        LiveSessionStage.offline => '主播未开播',
        LiveSessionStage.error => '异常',
      };

  Widget _buildEventList() {
    final List<DanmakuEvent> visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Text(_errorMessage ?? '暂无弹幕', textAlign: TextAlign.center),
      );
    }
    return Stack(
      children: <Widget>[
        ListView.builder(
          controller: _scrollController,
          itemCount: visible.length,
          itemBuilder: (BuildContext context, int index) =>
              _buildEventTile(visible[index]),
        ),
        // 回溯态下的「回到最新」（prd F12）。
        if (_backtracking)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _backToLatest,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Text(
                      '回到最新',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: smallerFontSize(_prefs.fontSize, 2),
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

  /// 底部固定一行：最新一条进场信息，不随弹幕列表滚动。
  Widget _buildEntryBanner(DanmakuEvent event) {
    final DanmakuUser user = event.user;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: const Border(top: BorderSide(color: Colors.black12)),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: smallerFontSize(_prefs.fontSize, 1)),
          children: <InlineSpan>[
            const TextSpan(
              text: '欢迎 ',
              style: TextStyle(color: Colors.black54),
            ),
            if (user.nickName.isNotEmpty)
              TextSpan(
                text: user.nickName,
                style: TextStyle(
                  color: Colors.indigo.shade400,
                  fontWeight: FontWeight.bold,
                ),
              ),
            if (user.level > 0)
              TextSpan(
                text: ' Lv.${user.level}',
                style: TextStyle(color: Colors.orange.shade800),
              ),
            if (user.fanLevel > 0)
              TextSpan(
                text: ' 灯牌${user.fanLevel}',
                style: TextStyle(color: Colors.purple.shade400),
              ),
            TextSpan(text: ' ${event.text}'),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 单条弹幕：时间 + 荣誉等级 + 灯牌等级 + 昵称 + 内容；
  /// 飘屏 / 特权弹幕带类型前缀并整体着色，与普通弹幕区分。
  Widget _buildEventTile(DanmakuEvent event) {
    final DanmakuUser user = event.user;
    final String? mark = danmakuTypeLabel(event.kind);
    final Color? markColor = switch (event.kind) {
      DanmakuKind.screenChat => Colors.orange.shade800,
      DanmakuKind.privilegeScreenChat => Colors.green.shade700,
      DanmakuKind.gift => Colors.pink.shade700,
      DanmakuKind.member => Colors.teal.shade700,
      DanmakuKind.like => Colors.red.shade700,
      DanmakuKind.social => Colors.blue.shade700,
      DanmakuKind.roomRank => Colors.amber.shade800,
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: _prefs.fontSize),
          children: <InlineSpan>[
            TextSpan(
              text: '${formatClock(event.timeMs)} ',
              style: TextStyle(
                color: Colors.grey,
                fontSize: smallerFontSize(_prefs.fontSize, 2),
              ),
            ),
            if (mark != null && markColor != null)
              TextSpan(
                text: '$mark ',
                style: TextStyle(
                  color: markColor,
                  fontSize: smallerFontSize(_prefs.fontSize, 2),
                ),
              ),
            if (user.level > 0)
              TextSpan(
                text: 'Lv.${user.level} ',
                style: TextStyle(
                  color: Colors.orange.shade800,
                  fontSize: smallerFontSize(_prefs.fontSize, 2),
                ),
              ),
            if (user.fanLevel > 0)
              TextSpan(
                text: '灯牌${user.fanLevel} ',
                style: TextStyle(
                  color: Colors.purple.shade400,
                  fontSize: smallerFontSize(_prefs.fontSize, 2),
                ),
              ),
            if (user.nickName.isNotEmpty)
              TextSpan(
                text: '${user.nickName}: ',
                style: TextStyle(
                  color: Colors.indigo.shade400,
                  fontWeight: FontWeight.bold,
                ),
              ),
            // 正文按高亮词切分（prd F11）：命中片段用高亮样式。
            for (final HighlightSegment segment in splitHighlights(
              event.text,
              _filter.highlightKeywords,
            ))
              TextSpan(
                text: segment.text,
                style: segment.highlighted
                    ? _highlightStyle
                    : TextStyle(color: markColor),
              ),
          ],
        ),
      ),
    );
  }
}