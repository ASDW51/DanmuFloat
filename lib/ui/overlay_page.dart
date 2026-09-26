// 悬浮窗内容（单栏，prd F2 / F3 的 1 栏布局）。
//
// 运行在独立 Flutter 引擎（前台服务进程内）：签名、房间信息、WebSocket 连接与
// 弹幕解析都在这个引擎里完成，因此这里直接持有 LiveDanmuSession，
// 而不是从主 App 接收弹幕——主 App 被杀不影响悬浮窗（prd 4.11）。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

/// 悬浮窗内保留的弹幕条数上限，与 design.md 第 8 章默认缓存一致。
const int _displayLimit = 500;

/// 弹幕列表只保留聊天内容：普通弹幕、飘屏弹幕、特权弹幕。
bool _isChatKind(DanmakuKind kind) =>
    kind == DanmakuKind.chat ||
    kind == DanmakuKind.screenChat ||
    kind == DanmakuKind.privilegeScreenChat;

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

class _OverlayPageState extends State<OverlayPage> {
  final List<DanmakuEvent> _events = <DanmakuEvent>[];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<dynamic>? _bridgeSubscription;
  StreamSubscription<LiveSessionStage>? _stageSubscription;
  StreamSubscription<DanmakuEvent>? _danmuSubscription;

  LiveDanmuSession? _session;
  LiveSessionStage _stage = LiveSessionStage.idle;
  String? _webRid;
  String? _error;
  int _received = 0;

  /// 在线人数，取自最新的「xxx在线观众」房间统计消息（prd F6 栏目标识）。
  int _online = 0;

  /// 最新一条进场信息，固定显示在底部单行，不随弹幕列表滚动。
  DanmakuEvent? _latestEntry;
  double _opacity = 0.8;
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
    _stageSubscription?.cancel();
    _danmuSubscription?.cancel();
    _session?.stop();
    _scrollController.dispose();
    super.dispose();
  }

  void _onBridgeMessage(dynamic message) {
    if (isOverlayCloseMessage(message)) {
      unawaited(_stopSession());
      return;
    }
    final OverlayConfig? config = OverlayConfig.tryParse(message);
    if (config == null) return;
    unawaited(_applyConfig(config));
  }

  /// 换房间时整条链路重建；重复下发同一房间则忽略。
  Future<void> _applyConfig(OverlayConfig config) async {
    if (config.webRid == _webRid && _session != null) return;
    await _stopSession();
    if (!mounted) return;
    setState(() {
      _webRid = config.webRid;
      _opacity = config.opacity;
      _events.clear();
      _received = 0;
      _online = 0;
      _latestEntry = null;
      _error = null;
      _stage = LiveSessionStage.resolvingRoom;
    });

    final LiveDanmuSession session = LiveDanmuSession(webRid: config.webRid);
    _stageSubscription = session.stages.listen((LiveSessionStage stage) {
      if (!mounted) return;
      setState(() => _stage = stage);
      _reportState();
    });
    _danmuSubscription = session.danmu
        .where((DanmakuEvent event) => event.isDisplayable)
        .listen((DanmakuEvent event) {
      if (!mounted) return;
      setState(() {
        // 在线人数取自「xxx在线观众」统计消息，比房间用户序列更及时。
        final int online = event.onlineCount;
        if (online > 0) _online = online;
        _received++;
        // 进场信息高频且信息量少，固定显示在底部单行，不混入弹幕列表刷屏。
        if (event.kind == DanmakuKind.member) {
          _latestEntry = event;
        } else if (_isChatKind(event.kind)) {
          // 弹幕列表只保留聊天内容；礼物/点赞/关注/榜单/在线人数等只用于状态与埋点。
          _events.add(event);
          if (_events.length > _displayLimit) {
            _events.removeRange(0, _events.length - _displayLimit);
          }
        }
      });
      _scrollToBottom();
      _scheduleReport();
    });
    setState(() => _session = session);
    await session.start();
    if (!mounted) return;
    setState(() {
      _error = session.errorMessage ?? session.signatureWarning;
    });
    _reportState();
  }

  Future<void> _stopSession() async {
    final LiveDanmuSession? session = _session;
    _session = null;
    await _danmuSubscription?.cancel();
    _danmuSubscription = null;
    await _stageSubscription?.cancel();
    _stageSubscription = null;
    await session?.stop();
  }

  /// 弹幕条数按秒节流上报，避免每条弹幕都发一次消息。
  void _scheduleReport() {
    if (_reportTimer?.isActive ?? false) return;
    _reportTimer = Timer(const Duration(seconds: 1), _reportState);
  }

  void _reportState() {
    unawaited(
      FlutterScreenOverlay.shareData(
        OverlayStatus(
          stage: _stage,
          received: _received,
          webRid: _webRid,
          error: _error,
        ).toJson(),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
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
        child: Column(
          children: <Widget>[
            _buildTitleBar(),
            const Divider(height: 1, color: Colors.white24),
            Expanded(child: _buildEventList()),
            if (_latestEntry != null) _buildEntryBanner(_latestEntry!),
          ],
        ),
      ),
    );
  }

  /// 栏目标识行（prd F6）：主播名 + 连接状态 + 在线人数。
  Widget _buildTitleBar() {
    final Color color = switch (_stage) {
      LiveSessionStage.live => Colors.greenAccent,
      LiveSessionStage.offline => Colors.orangeAccent,
      LiveSessionStage.error => Colors.redAccent,
      LiveSessionStage.idle => Colors.grey,
      _ => Colors.lightBlueAccent,
    };
    final String owner = _session?.room?.owner ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              owner.isEmpty ? (_webRid ?? '等待配置') : owner,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          Text(
            // 已连上且有在线数据时右上是人数；否则退回连接状态，保证能看出当前所处阶段。
            _online > 0 ? '在线 ${_formatCount(_online)}' : _stageText(_stage),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// 在线人数：过万折算为「x.x万」，与平台展示口径一致。
  String _formatCount(int value) =>
      value >= 10000 ? '${(value / 10000).toStringAsFixed(1)}万' : '$value';

  /// 连接状态的短文本（prd F6：栏目标识需含连接状态）。
  String _stageText(LiveSessionStage stage) => switch (stage) {
        LiveSessionStage.idle => '未连接',
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
        child: Text(
          _error ?? '暂无弹幕',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        color: Colors.white10,
        border: Border(top: BorderSide(color: Colors.white24)),
      ),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 11),
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

  /// 单条弹幕：荣誉等级 + 灯牌等级 + 昵称 + 内容。
  Widget _buildEventTile(DanmakuEvent event) {
    final DanmakuUser user = event.user;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 13),
          children: <InlineSpan>[
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
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}