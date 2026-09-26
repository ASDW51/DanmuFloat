// 悬浮窗内容（prd F2 / F3）：1 栏与 4 栏两种布局，每栏独立会话、独立缓存、
// 独立滚动位置，栏与栏之间互不影响。
//
// 运行在独立 Flutter 引擎（前台服务进程内）：签名、房间信息、WebSocket 连接与
// 弹幕解析都在这个引擎里完成，因此每栏直接持有自己的 LiveDanmuSession，
// 而不是从主 App 接收弹幕——主 App 被杀不影响悬浮窗（prd 4.11）。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

/// 每栏保留的弹幕条数上限，与 design.md 第 8 章默认缓存一致。
const int _displayLimit = 500;

/// 聊天类在深色背景上的配色（列表过滤与类型前缀文案见 danmaku_display.dart）：
/// 普通弹幕正文白色；飘屏橙黄、特权浅绿，前缀与正文同色。
Color? _typeColor(DanmakuKind kind) => switch (kind) {
      DanmakuKind.screenChat => Colors.orangeAccent,
      DanmakuKind.privilegeScreenChat => Colors.lightGreenAccent,
      _ => null,
    };

/// 悬浮窗入口点对应的 App，由 `overlayMain()` 启动。
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const OverlayPage(),
      );
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

class _OverlayPageState extends State<OverlayPage> {
  StreamSubscription<dynamic>? _bridgeSubscription;

  OverlayLayout _layout = OverlayLayout.single;
  List<String> _webRids = const <String>[];
  double _opacity = 0.8;

  /// 各栏最新上报，用于向主 App 汇报整体状态（主 App 不展示逐栏明细）。
  final Map<int, _PaneReport> _reports = <int, _PaneReport>{};
  Timer? _reportTimer;

  @override
  void initState() {
    super.initState();
    // 插件在主 App 启动时就会预热本引擎，此处尽早注册监听，
    // 避免主 App 下发 config 时消息无人接收。
    _bridgeSubscription =
        FlutterScreenOverlay.overlayListener.listen(_onBridgeMessage);
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
      });
      _reportState();
      return;
    }
    final OverlayConfig? config = OverlayConfig.tryParse(message);
    if (config == null) return;
    setState(() {
      _layout = config.layout;
      _webRids = config.webRids;
      _opacity = config.opacity;
      // 布局或房间变化会重建对应栏位，旧栏位的上报先作废。
      _reports.clear();
    });
  }

  void _onPaneReport(int index, _PaneReport report) {
    _reports[index] = report;
    _scheduleReport();
  }

  /// 状态按秒节流上报，避免每条弹幕都发一次消息。
  void _scheduleReport() {
    if (_reportTimer?.isActive ?? false) return;
    _reportTimer = Timer(const Duration(seconds: 1), _reportState);
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
        ).toJson(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: _opacity),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: _webRids.isEmpty ? _buildPlaceholder() : _buildPanes(),
      ),
    );
  }

  Widget _buildPlaceholder() => const Center(
        child: Text(
          '等待配置',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );

  /// 1 栏铺满；4 栏按 2×2 网格（prd F4），每栏为标题行 + 弹幕列表两层。
  Widget _buildPanes() {
    String roomAt(int index) =>
        index < _webRids.length ? _webRids[index] : '';

    if (_layout == OverlayLayout.single) {
      return _buildPane(index: 0, webRid: roomAt(0));
    }
    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(child: _buildPane(index: 0, webRid: roomAt(0))),
              const VerticalDivider(width: 1, thickness: 1, color: Colors.white24),
              Expanded(child: _buildPane(index: 1, webRid: roomAt(1))),
            ],
          ),
        ),
        const Divider(height: 1, thickness: 1, color: Colors.white24),
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(child: _buildPane(index: 2, webRid: roomAt(2))),
              const VerticalDivider(width: 1, thickness: 1, color: Colors.white24),
              Expanded(child: _buildPane(index: 3, webRid: roomAt(3))),
            ],
          ),
        ),
      ],
    );
  }

  /// 栏位按「序号 + 房间」作 key：换房间即重建该栏，其它栏不受影响。
  Widget _buildPane({required int index, required String webRid}) =>
      _OverlayPane(
        key: ValueKey<String>('$index:$webRid'),
        index: index,
        webRid: webRid,
        compact: _layout != OverlayLayout.single,
        onReport: _onPaneReport,
      );
}

/// 单栏：独立会话、独立缓存与独立滚动位置。
class _OverlayPane extends StatefulWidget {
  const _OverlayPane({
    super.key,
    required this.index,
    required this.webRid,
    required this.compact,
    required this.onReport,
  });

  final int index;

  /// 本栏绑定的直播间号，空串表示未绑定房间。
  final String webRid;

  /// 4 栏时为 true，字号相应缩小，保证小格子里仍看得清。
  final bool compact;

  final void Function(int index, _PaneReport report) onReport;

  @override
  State<_OverlayPane> createState() => _OverlayPaneState();
}

class _OverlayPaneState extends State<_OverlayPane> {
  final List<DanmakuEvent> _events = <DanmakuEvent>[];
  final ScrollController _scrollController = ScrollController();

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

  bool get _bound => widget.webRid.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (!_bound) {
      _error = '未绑定房间';
      return;
    }
    // 直接赋值而不走 setState：initState 阶段本就处于 dirty 状态。
    _stage = LiveSessionStage.resolvingRoom;
    unawaited(_start());
  }

  @override
  void dispose() {
    _stageSubscription?.cancel();
    _danmuSubscription?.cancel();
    _session?.stop();
    _scrollController.dispose();
    super.dispose();
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
        .where((DanmakuEvent event) =>
            event.isDisplayable && isStreamRelevant(event.kind))
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
        _latestEntry = event;
      } else if (isChatKind(event.kind)) {
        _events.add(event);
        if (_events.length > _displayLimit) {
          _events.removeRange(0, _events.length - _displayLimit);
        }
      }
    });
    _scrollToBottom();
    _report();
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _buildTitleBar(),
        const Divider(height: 1, color: Colors.white24),
        Expanded(child: _buildEventList()),
        if (_latestEntry != null) _buildEntryBanner(_latestEntry!),
      ],
    );
  }

  /// 栏目标识行（prd F6）：主播名 + 连接状态 / 在线人数。
  Widget _buildTitleBar() {
    final Color color = switch (_stage) {
      LiveSessionStage.live => Colors.greenAccent,
      LiveSessionStage.offline => Colors.orangeAccent,
      LiveSessionStage.error => Colors.redAccent,
      LiveSessionStage.idle => Colors.grey,
      _ => Colors.lightBlueAccent,
    };
    final String owner = _session?.room?.owner ?? '';
    final TextStyle labelStyle = TextStyle(
      color: Colors.white70,
      fontSize: widget.compact ? 10 : 11,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
                color: Colors.white,
                fontSize: widget.compact ? 10 : 12,
              ),
            ),
          ),
          Text(
            // 已连上且有在线数据时右上是人数；否则退回连接状态，保证能看出当前所处阶段。
            _online > 0 ? '在线 ${formatOnlineCount(_online)}' : _stageText(_stage),
            style: labelStyle,
          ),
        ],
      ),
    );
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
    if (_events.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Text(
            _error ?? '暂无弹幕',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white54,
              fontSize: widget.compact ? 10 : 12,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      itemCount: _events.length,
      itemBuilder: (BuildContext context, int index) =>
          _buildEventTile(_events[index]),
    );
  }

  /// 底部固定一行：最新一条进场信息（昵称 + 荣誉等级 + 灯牌等级 + 进场文案）。
  Widget _buildEntryBanner(DanmakuEvent event) {
    final DanmakuUser user = event.user;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: const BoxDecoration(
        color: Colors.white10,
        border: Border(top: BorderSide(color: Colors.white24)),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: widget.compact ? 10 : 11),
          children: <InlineSpan>[
            const TextSpan(
              text: '欢迎 ',
              style: TextStyle(color: Colors.white54),
            ),
            if (user.nickName.isNotEmpty)
              TextSpan(
                text: user.nickName,
                style: const TextStyle(
                  color: Colors.lightBlueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            if (user.level > 0)
              TextSpan(
                text: ' Lv.${user.level}',
                style: const TextStyle(color: Colors.amber),
              ),
            if (user.fanLevel > 0)
              TextSpan(
                text: ' 灯牌${user.fanLevel}',
                style: const TextStyle(color: Colors.purpleAccent),
              ),
            TextSpan(
              text: ' ${event.text}',
              style: const TextStyle(color: Colors.white),
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
  Widget _buildEventTile(DanmakuEvent event) {
    final DanmakuUser user = event.user;
    final String? mark = danmakuTypeLabel(event.kind);
    final Color? markColor = _typeColor(event.kind);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: widget.compact ? 11 : 13),
          children: <InlineSpan>[
            if (mark != null && markColor != null)
              TextSpan(
                text: '$mark ',
                style: TextStyle(color: markColor, fontSize: 10),
              ),
            // 等级与灯牌前置到昵称前，昵称后紧跟弹幕内容。
            if (user.level > 0)
              TextSpan(
                // 荣誉等级：level > 0 才显示（大量用户无荣誉等级）
                text: 'Lv.${user.level} ',
                style: const TextStyle(color: Colors.amber, fontSize: 11),
              ),
            if (user.fanLevel > 0)
              TextSpan(
                // 灯牌等级：优先取 user.fans_club.data.level
                text: '灯牌${user.fanLevel} ',
                style: const TextStyle(
                  color: Colors.purpleAccent,
                  fontSize: 11,
                ),
              ),
            if (user.nickName.isNotEmpty)
              TextSpan(
                text: '${user.nickName}: ',
                style: const TextStyle(
                  color: Colors.lightBlueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            TextSpan(
              text: event.text,
              style: TextStyle(color: markColor ?? Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}