// 最小可观测界面（P0 第一步验收载体）：
// 输入 webRid → 解析房间信息 → 建立弹幕连接 → 实时滚动展示弹幕。
// 这里只做链路验证，正式的悬浮窗 UI（GridView + 每格 ListView）后续实现。
import 'dart:async';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 界面内保留的弹幕条数上限，与 design.md 第 8 章默认缓存一致。
const int _displayLimit = 500;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _webRidController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<DanmakuEvent> _events = <DanmakuEvent>[];

  LiveDanmuSession? _session;
  StreamSubscription<LiveSessionStage>? _stageSubscription;
  StreamSubscription<DanmakuEvent>? _danmuSubscription;

  LiveSessionStage _stage = LiveSessionStage.idle;
  String? _errorMessage;
  bool _autoScroll = true;
  int _received = 0;

  @override
  void dispose() {
    _stageSubscription?.cancel();
    _danmuSubscription?.cancel();
    _session?.stop();
    _webRidController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_session != null) {
      await _disconnect();
      return;
    }

    final String webRid = _webRidController.text.trim();
    if (webRid.isEmpty) {
      setState(() {
        _stage = LiveSessionStage.error;
        _errorMessage = '请输入 webRid（直播间号）';
      });
      return;
    }

    final LiveDanmuSession session = LiveDanmuSession(webRid: webRid);
    _stageSubscription = session.stages.listen((LiveSessionStage stage) {
      if (mounted) setState(() => _stage = stage);
    });
    _danmuSubscription = session.danmu.listen((DanmakuEvent event) {
      if (!mounted) return;
      setState(() {
        _events.add(event);
        _received++;
        if (_events.length > _displayLimit) {
          _events.removeRange(0, _events.length - _displayLimit);
        }
      });
      if (_autoScroll) _scrollToBottom();
    });
    setState(() {
      _session = session;
      _events.clear();
      _received = 0;
      _errorMessage = null;
      _stage = LiveSessionStage.resolvingRoom;
    });
    await session.start();
    if (!mounted) return;
    setState(() => _errorMessage = session.errorMessage);
  }

  Future<void> _disconnect() async {
    final LiveDanmuSession? session = _session;
    _session = null;
    await _danmuSubscription?.cancel();
    _danmuSubscription = null;
    await _stageSubscription?.cancel();
    _stageSubscription = null;
    await session?.stop();
    if (!mounted) return;
    setState(() {
      _stage = LiveSessionStage.idle;
      _errorMessage = null;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  /// 汇总当前诊断信息，供用户一键复制反馈（真机问题排查用）。
  String _buildDiagnostics() {
    final RoomInfo? room = _session?.room;
    final StringBuffer buffer = StringBuffer()
      ..writeln('阶段: ${_stageLabel(_stage)}')
      ..writeln('webRid: ${_webRidController.text.trim()}')
      ..writeln('已收条数: $_received')
      ..writeln('连接状态: ${_session?.connectionState.name ?? '未连接'}');
    if (room != null) {
      buffer
        ..writeln('主播: ${room.owner}')
        ..writeln('liveId: ${room.liveId}')
        ..writeln('标题: ${room.title}');
    }
    if (_errorMessage != null) {
      buffer.writeln('错误: $_errorMessage');
    }
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制诊断信息')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final RoomInfo? room = _session?.room;
    return Scaffold(
      appBar: AppBar(
        title: const Text('弹幕链路验证'),
        actions: <Widget>[
          IconButton(
            tooltip: '复制错误信息',
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
          _buildInputRow(),
          _buildStatusBar(room),
          const Divider(height: 1),
          Expanded(child: _buildEventList()),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggle,
        tooltip: _session == null ? '连接' : '断开',
        child: Icon(_session == null ? Icons.play_arrow : Icons.stop),
      ),
    );
  }

  Widget _buildInputRow() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          controller: _webRidController,
          enabled: _session == null,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'webRid（直播间号）',
            hintText: '例如 7350000000000000001',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _toggle(),
        ),
      );

  Widget _buildStatusBar(RoomInfo? room) {
    final Color color = switch (_stage) {
      LiveSessionStage.live => Colors.green,
      LiveSessionStage.offline => Colors.orange,
      LiveSessionStage.error => Colors.red,
      LiveSessionStage.idle => Colors.grey,
      _ => Colors.blue,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
              if (_session != null) ...<Widget>[
                const SizedBox(width: 12),
                Text('连接: ${_session!.connectionState.name}'),
              ],
            ],
          ),
          if (room != null) ...<Widget>[
            const SizedBox(height: 6),
            Text('主播: ${room.owner}  |  liveId: ${room.liveId}'),
            if (room.title.isNotEmpty)
              Text(room.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          if (_errorMessage != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
          ],
          if (_session?.signatureDegraded ?? false) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '签名已降级为 $fallbackDanmuSignature：${_session!.signatureWarning}',
              style: const TextStyle(color: Colors.orange, fontSize: 12),
            ),
          ],
          if (_session?.socketError != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '连接错误: ${_session!.socketError}',
              style: const TextStyle(color: Colors.red, fontSize: 12),
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
      return const Center(child: Text('暂无弹幕'));
    }
    return ListView.builder(
      controller: _scrollController,
      itemCount: _events.length,
      itemBuilder: (BuildContext context, int index) =>
          _buildEventTile(_events[index]),
    );
  }

  Widget _buildEventTile(DanmakuEvent event) {
    final DanmakuUser user = event.user;
    final List<InlineSpan> spans = <InlineSpan>[
      TextSpan(
        text: '${_timeLabel(event.timeMs)} ',
        style: const TextStyle(color: Colors.grey, fontSize: 12),
      ),
      if (user.nickName.isNotEmpty)
        TextSpan(
          text: user.nickName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      if (user.level > 0)
        TextSpan(
          text: ' Lv.${user.level}',
          style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
        ),
      if (user.fanLevel > 0)
        TextSpan(
          text: ' 灯牌${user.fanLevel}',
          style: const TextStyle(color: Colors.deepPurple, fontSize: 12),
        ),
      const TextSpan(text: '\n'),
      TextSpan(text: event.text),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text.rich(TextSpan(children: spans)),
    );
  }

  String _timeLabel(int timeMs) {
    if (timeMs <= 0) return '--:--:--';
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(timeMs);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}