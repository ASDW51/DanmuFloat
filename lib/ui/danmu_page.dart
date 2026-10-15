// App 内弹幕页：单个主播的房间信息 + 实时弹幕（浅色 Material 风格）。
//
// 与悬浮窗共用展示口径（danmaku_display.dart），差别只在配色：浮动窗是深色半透明，
// 这里是浅色页面，正文用默认文字色而不是白色。
// 进入页面即自动连接，退出即释放连接（prd 4.11 的连接释放要求）。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/danmu/auto_scroll.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/danmu_status_bar.dart';
import 'package:danmu_float/ui/danmu_text_colors.dart';
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

/// 汇总诊断信息，供用户一键复制反馈（真机问题排查用）。
///
/// 抽成顶层纯函数而不是页面方法：诊断内容会经剪贴板外发给他人，必须能脱离页面单测
/// ——尤其要能断言凭证不出现在里面（见 test/danmu_diagnostics_test.dart）。
///
/// [stageLabel] 由调用方给出：阶段文案要读会话的自动复检状态，属于页面侧的口径。
String buildDanmuDiagnostics({
  required String webRid,
  required String stageLabel,
  required int received,
  required LiveDanmuSession? session,
  required String? errorMessage,
}) {
  final RoomInfo? room = session?.room;
  final StringBuffer buffer = StringBuffer()
    ..writeln('页面: App 内弹幕页')
    ..writeln('阶段: $stageLabel')
    ..writeln('webRid: $webRid')
    ..writeln('已收条数: $received')
    ..writeln(
      '连接状态: ${session == null ? '未连接' : connectionStateLabel(session.connectionState)}',
    );
  if (room != null) {
    buffer
      ..writeln('主播: ${room.owner}')
      ..writeln('liveId: ${room.liveId}')
      ..writeln('标题: ${room.title}');
  }
  if (errorMessage != null) buffer.writeln('错误: $errorMessage');
  if (session?.signatureDegraded ?? false) {
    buffer.writeln(
      '签名降级为 $fallbackDanmuSignature: ${session?.signatureWarning}',
    );
  }
  final String? socketError = session?.socketError;
  if (socketError != null) buffer.writeln('连接错误: $socketError');
  return buffer.toString().trimRight();
}

/// 阶段变化后该保留哪条失败原因（UX-14，与悬浮窗 UX-08 同口径）。
///
/// 抽成纯函数是为了不依赖 widget 注入口就能覆盖 error → offline → live 的迁移：
/// 只有真正连上（live）才算翻篇，其余阶段一律「有原因就覆盖、没原因就留着」，
/// 否则「解析中 / 未开播」会把用户唯一能看到的失败原因抹掉，空列表退回「暂无弹幕」。
String? nextErrorReason(
  String? current, {
  required LiveSessionStage stage,
  String? message,
}) {
  if (message != null && message.isNotEmpty) return message;
  return stage == LiveSessionStage.live ? null : current;
}

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
  late final DanmakuAutoScroller _autoScroller = DanmakuAutoScroller(
    _scrollController,
  );

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

  /// 悬浮窗里改了屏蔽（弹幕行菜单）后主 App 落盘的那份偏好：跟着刷新本页展示。
  StreamSubscription<FilterPrefs>? _filterSubscription;

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
        // 悬浮窗自查发现权限被撤销且已自行断开，或在窗内被关掉（悬浮球菜单 /
        // 通知栏）：按钮状态同步回未开启。
        if (state.permissionRevoked || state.closed) _overlayVisible = false;
        // 悬浮球里改的透明度 / 字号 / 尺寸 / 锁定 / 吸附角：本地偏好同步跟上，
        // 否则本页仍持有旧值，再从这里开窗会把悬浮窗里改过的设置冲回旧值。
        final OverlayPrefsPatch? patch = state.prefsPatch;
        if (patch != null) _prefs = _prefs.appliedPatch(patch);
      });
    });
    _filterSubscription = filterChangedStream.listen((FilterPrefs filter) {
      if (!mounted) return;
      setState(() => _filter = filter);
    });
    unawaited(_loadPrefs());
    unawaited(_loadFilter());
    unawaited(_connect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _overlaySubscription?.cancel();
    _filterSubscription?.cancel();
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
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkOverlayAlive());
      // 窗口可能在后台期间由别的页面（首页多栏）关掉，本页不知道（PM-001）：
      // 只读探测一次，把按钮状态与真实窗口对齐，否则本页的「关闭悬浮窗」
      // 会关在一个已经不存在的窗口上（close 是幂等的，但按钮状态是错的）。
      unawaited(_reconcileOverlayVisible());
    }
  }

  /// 悬浮窗已不存在但本页仍以为开着时，纠正按钮状态（PM-001）。
  ///
  /// 只纠错、不补正：窗口存在与否以首页 / 弹幕页里真正执行开窗动作的页面为准，
  /// 这里只为「别处关了窗」的场景兜底，避免状态错位越积越多。
  Future<void> _reconcileOverlayVisible() async {
    if (!_overlayVisible) return;
    if (await isOverlayActive()) return;
    if (!mounted) return;
    setState(() => _overlayVisible = false);
  }

  Future<void> _checkOverlayAlive() async {
    if (!_overlayVisible) return;
    if (await verifyOverlayPermission()) return;
    if (!mounted) return;
    setState(() => _overlayVisible = false);
    _snack('悬浮窗已失效（权限被撤销或被系统移除），已关闭');
  }

  /// 是否可手动重试：连接失败，或未开播且已停止自动复检（复检次数用尽）。
  ///
  /// 这两种状态下会话不会自己恢复，必须给出可点出口（UX-02）。
  bool get _retryable => shouldOfferRetry(
        _stage,
        autoRechecking: _session?.autoRechecking ?? false,
      );

  /// 重连当前直播间：复用同一个会话，已收到的弹幕与滚动位置都还在。
  Future<void> _retry() async {
    final LiveDanmuSession? session = _session;
    if (session == null) return;
    // 不在这里清空原因：与悬浮窗同口径，重试后若仍失败 / 停在未开播，
    // 上一次的原因要留到真正连上（live）为止（UX-14）。
    await session.restart();
  }

  Future<void> _connect() async {
    final LiveDanmuSession session = LiveDanmuSession(
      webRid: widget.webRid,
      // 首页已建立「主播 → 凭证」绑定；本主播指定了凭证就用它，否则匿名自动获取。
      credentialCookies: roomCookiesFor(widget.webRid),
    );
    _session = session;
    _stageSubscription = session.stages.listen((LiveSessionStage stage) {
      if (!mounted) return;
      setState(() {
        _stage = stage;
        // 失败原因只覆盖、不随阶段清空：重试后若停在未开播，用户仍要能看到原因（UX-14）。
        _errorMessage = nextErrorReason(
          _errorMessage,
          stage: stage,
          message: session.errorMessage,
        );
      });
    });
    // 房间统计只用来更新在线人数、进场只进底部单行，过滤时都不能挡掉。
    _danmuSubscription = session.danmu
        .where(
          (DanmakuEvent event) =>
              event.isDisplayable && isStreamRelevant(event.kind),
        )
        .listen(_onEvent);
    setState(() => _stage = LiveSessionStage.resolvingRoom);
    await session.start();
    if (!mounted) return;
    setState(
      () => _errorMessage = session.errorMessage ?? session.signatureWarning,
    );
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
  ///
  /// 暂停时不裁剪头部：裁剪会让列表整体上移，看起来像「暂停了还在滚动」。
  void _addToRaw(DanmakuEvent event) {
    _raw.add(event);
    if (_raw.length <= _displayLimit) return;
    if (_paused) {
      // 允许短时超出上限，避免暂停时列表位移；留一倍余量兜住内存。
      if (_raw.length > _displayLimit * 2) {
        _raw.removeRange(0, _displayLimit);
      }
      return;
    }
    _raw.removeRange(0, _raw.length - _displayLimit);
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
    // 候选房间随 config 一起下发（PM-001）：没有候选时栏标题不可点、加栏按钮
    // 会误报「请先在主 App 添加主播」，用户会以为功能坏了。本页不持有主播列表，
    // 从本地存储现读一次（本页只读，不维护列表状态）。
    final List<RoomOption> roomOptions = await _loadRoomOptions();
    await openOverlay(
      _prefs.toConfig(
        <String>[widget.webRid],
        filter: _filter,
        roomOptions: roomOptions,
      ),
      devicePixelRatio: dpr,
      // 窗口不能大于屏幕，否则会溢出。
      size: fitOverlaySize(
        _prefs.windowSize,
        screenWidth: screen.width,
        screenHeight: screen.height,
      ),
      screen: (width: screen.width, height: screen.height),
    );
    if (!mounted) return;
    setState(() => _overlayVisible = true);
    // 建窗期间首页可能也在同步候选（如首页开着且刚增删主播），后到者覆盖：
    // 这里在 config 之后补推一次，保证本窗的候选以最新主播列表为准。
    if (roomOptions.isNotEmpty) unawaited(shareOverlayRooms(roomOptions));
    // 补推屏幕尺寸与锁定状态：悬浮窗引擎拿不到屏幕尺寸，横竖屏换算与尺寸收敛
    // 都要靠这里下发的值。
    unawaited(
      shareOverlayStyle(
        opacity: _prefs.opacity,
        fontSize: _prefs.fontSize,
        scrollSpeed: _prefs.scrollSpeed,
        paneStyles: _prefs.paneStyles,
        lightTheme: _prefs.lightTheme,
        themeId: _prefs.themeId,
        colorOverrides: _prefs.colorOverrides,
        contrastPolicy: _prefs.contrastPolicy,
        showTitleBar: _prefs.showTitleBar,
        focusBehavior: _prefs.focusBehavior,
        dragLocked: _prefs.dragLocked,
        clickThrough: _prefs.clickThrough,
        screenWidth: screen.width,
        screenHeight: screen.height,
      ),
    );
  }

  /// 从本地主播列表构建悬浮窗候选房间（PM-001）。
  ///
  /// 口径与首页一致（备注优先，其次主播名，最后直播间号）；读取失败按空列表
  /// 处理——候选缺失只影响「栏内切换 / 加栏」的可用性，不该阻断开窗。
  Future<List<RoomOption>> _loadRoomOptions() async {
    try {
      final List<ManagedRoom> rooms = await RoomStore().load();
      return <RoomOption>[
        for (final ManagedRoom room in rooms)
          RoomOption(
            webRid: room.webRid,
            name: room.displayName,
            group: room.group,
          ),
      ];
    } on Object catch (exception) {
      debugPrint('读取候选房间列表失败: $exception');
      return const <RoomOption>[];
    }
  }

  /// 汇总当前诊断信息，供用户一键复制反馈（真机问题排查用）。
  String _buildDiagnostics() => buildDanmuDiagnostics(
    webRid: widget.webRid,
    stageLabel: _stageLabel(_stage),
    received: _received,
    session: _session,
    errorMessage: _errorMessage,
  );

  Future<void> _copyDiagnostics() async {
    await Clipboard.setData(ClipboardData(text: _buildDiagnostics()));
    if (!mounted) return;
    _snack('已复制诊断信息');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 应用过滤偏好：刷新本页展示、落盘，并同步给已开着的悬浮窗（prd F10）。
  Future<void> _applyFilter(FilterPrefs next) async {
    setState(() => _filter = next);
    await _filterStore.save(next);
    await shareOverlayFilter(next);
  }

  /// 单击弹幕弹出的功能菜单：复制弹幕 / 复制 userId / 屏蔽该用户 / 加入屏蔽词。
  Future<void> _showEventMenu(DanmakuEvent event) async {
    final String userId = event.user.userId.trim();
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              dense: true,
              title: Text(
                event.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: secondaryTextColor(Theme.of(context).brightness),
                  fontSize: 13,
                ),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制弹幕'),
              onTap: () => Navigator.of(context).pop('copyText'),
            ),
            if (userId.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('复制 userId'),
                onTap: () => Navigator.of(context).pop('copyUser'),
              ),
            if (userId.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.block),
                title: const Text('屏蔽该用户'),
                onTap: () => Navigator.of(context).pop('blockUser'),
              ),
            ListTile(
              leading: const Icon(Icons.filter_alt_off_outlined),
              title: const Text('加入屏蔽词'),
              onTap: () => Navigator.of(context).pop('blockKeyword'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copyText':
        await Clipboard.setData(ClipboardData(text: event.text));
        if (mounted) _snack('已复制弹幕');
      case 'copyUser':
        await Clipboard.setData(ClipboardData(text: userId));
        if (mounted) _snack('已复制 userId');
      case 'blockUser':
        await _applyFilter(withBlockedUser(_filter, userId));
        if (mounted) _snack('已屏蔽该用户');
      case 'blockKeyword':
        await _applyFilter(withBlockedKeyword(_filter, event.text));
        if (mounted) _snack('已加入屏蔽词');
    }
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

  /// 状态栏交给 [DanmuStatusBar] 渲染（UX-17）：本页只把会话状态翻译成它的入参，
  /// 布局与溢出防护归组件所有——这样那一行才能被单独挂载测试，而不是埋在 800 行页面里。
  Widget _buildStatusBar(RoomInfo? room) {
    return DanmuStatusBar(
      stageLabel: _stageLabel(_stage),
      stageColor: _stageColor(context, _stage),
      received: _received,
      online: _online,
      connectionLabel: _session == null
          ? null
          : connectionStateLabel(_session!.connectionState),
      retryable: _retryable,
      onRetry: _retry,
      roomTitle: (room != null && room.title.isNotEmpty) ? room.title : null,
      errorMessage: _errorMessage,
      overlaySummary: _overlayState == null
          ? null
          : '悬浮窗: ${_stageLabel(_overlayState!.stage)} · '
              '已收 ${_overlayState!.received} 条'
              '${_overlayState!.error == null ? '' : ' · ${_overlayState!.error}'}',
    );
  }

  /// 状态色统一走 [stageTextColor]：旧版直接用 green/orange/grey 原色，浅色主题下
  /// 对白底只有约 2.2~2.9:1，而状态词是中文文本，不能只靠旁边 10dp 的圆点传达。
  Color _stageColor(BuildContext context, LiveSessionStage stage) =>
      stageTextColor(stage, Theme.of(context).brightness);

  /// 未开播且仍在自动复检时补一句「自动复检中」：让用户知道会话没死，不用退出重连。
  String _stageLabel(LiveSessionStage stage) => switch (stage) {
    LiveSessionStage.idle => '未连接',
    LiveSessionStage.resolvingRoom => '解析房间信息…',
    LiveSessionStage.signing => '生成签名…',
    LiveSessionStage.connecting => '连接中…',
    LiveSessionStage.live => '已连接',
    LiveSessionStage.offline =>
      (_session?.autoRechecking ?? false) ? '主播未开播 · 自动复检中' : '主播未开播',
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
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
            TextSpan(
              text: '欢迎 ',
              style: TextStyle(
                color: entryBannerWelcomeColor(Theme.of(context).brightness),
              ),
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
  /// 单击弹出该条的功能菜单（复制 / 屏蔽）。
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
    return InkWell(
      onTap: () => unawaited(_showEventMenu(event)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text.rich(
          TextSpan(
            style: TextStyle(fontSize: _prefs.fontSize),
            children: <InlineSpan>[
              TextSpan(
                text: '${formatClock(event.timeMs)} ',
                style: TextStyle(
                  color: secondaryTextColor(Theme.of(context).brightness),
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
                regex: _filter.regexEnabled,
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
      ),
    );
  }
}
