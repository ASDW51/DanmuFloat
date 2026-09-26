// App 内弹幕页：单个主播的房间信息 + 实时弹幕（浅色 Material 风格）。
//
// 与悬浮窗共用展示口径（danmaku_display.dart），差别只在配色：浮动窗是深色半透明，
// 这里是浅色页面，正文用默认文字色而不是白色。
// 进入页面即自动连接，退出即释放连接（prd 4.11 的连接释放要求）。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

/// 页面内保留的弹幕条数上限，与 design.md 第 8 章默认缓存一致。
const int _displayLimit = 500;

class DanmuPage extends StatefulWidget {
  const DanmuPage({super.key, required this.webRid, this.title});

  /// 要连接的直播间号。
  final String webRid;

  /// 列表里的展示名（备注 / 主播名），仅作标题占位，连接成功后改用主播昵称。
  final String? title;

  @override
  State<DanmuPage> createState() => _DanmuPageState();
}

class _DanmuPageState extends State<DanmuPage> {
  final List<DanmakuEvent> _events = <DanmakuEvent>[];
  final ScrollController _scrollController = ScrollController();

  LiveDanmuSession? _session;
  StreamSubscription<LiveSessionStage>? _stageSubscription;
  StreamSubscription<DanmakuEvent>? _danmuSubscription;

  LiveSessionStage _stage = LiveSessionStage.idle;
  String? _errorMessage;
  int _received = 0;
  bool _autoScroll = true;

  /// 在线人数，只取「xxx在线观众」房间统计消息（prd F6）。
  int _online = 0;

  /// 最新一条进场信息，固定显示在底部单行。
  DanmakuEvent? _latestEntry;

  bool _overlayVisible = false;
  OverlayStatus? _overlayState;
  StreamSubscription<dynamic>? _overlaySubscription;

  @override
  void initState() {
    super.initState();
    _overlaySubscription = FlutterScreenOverlay.overlayListener.listen(
      (dynamic message) {
        final OverlayStatus? state = OverlayStatus.tryParse(message);
        if (state == null || !mounted) return;
        setState(() => _overlayState = state);
      },
    );
    unawaited(_connect());
  }

  @override
  void dispose() {
    _overlaySubscription?.cancel();
    _stageSubscription?.cancel();
    _danmuSubscription?.cancel();
    _session?.stop();
    _scrollController.dispose();
    super.dispose();
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
        _latestEntry = event;
      } else if (isChatKind(event.kind)) {
        _events.add(event);
        if (_events.length > _displayLimit) {
          _events.removeRange(0, _events.length - _displayLimit);
        }
      }
    });
    if (_autoScroll) _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  /// 开启 / 关闭本房间的单栏悬浮窗。
  Future<void> _toggleOverlay() async {
    if (_overlayVisible) {
      await closeOverlayWindow();
      if (!mounted) return;
      setState(() => _overlayVisible = false);
      return;
    }

    final double dpr = MediaQuery.devicePixelRatioOf(context);
    if (!await ensureOverlayPermission()) {
      if (!mounted) return;
      _snack('未授予悬浮窗权限，无法开启');
      return;
    }
    await openOverlay(
      OverlayConfig(webRids: <String>[widget.webRid]),
      devicePixelRatio: dpr,
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
            tooltip: _autoScroll ? '关闭自动滚动' : '开启自动滚动',
            icon: Icon(_autoScroll ? Icons.vertical_align_bottom : Icons.pause),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() {
              _events.clear();
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
    if (_events.isEmpty) {
      return Center(
        child: Text(_errorMessage ?? '暂无弹幕', textAlign: TextAlign.center),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      itemCount: _events.length,
      itemBuilder: (BuildContext context, int index) =>
          _buildEventTile(_events[index]),
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
          style: const TextStyle(fontSize: 13),
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
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: '${formatClock(event.timeMs)} ',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            if (mark != null && markColor != null)
              TextSpan(
                text: '$mark ',
                style: TextStyle(color: markColor, fontSize: 12),
              ),
            if (user.level > 0)
              TextSpan(
                text: 'Lv.${user.level} ',
                style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
              ),
            if (user.fanLevel > 0)
              TextSpan(
                text: '灯牌${user.fanLevel} ',
                style: TextStyle(color: Colors.purple.shade400, fontSize: 12),
              ),
            if (user.nickName.isNotEmpty)
              TextSpan(
                text: '${user.nickName}: ',
                style: TextStyle(
                  color: Colors.indigo.shade400,
                  fontWeight: FontWeight.bold,
                ),
              ),
            TextSpan(
              text: event.text,
              style: TextStyle(color: markColor),
            ),
          ],
        ),
      ),
    );
  }
}