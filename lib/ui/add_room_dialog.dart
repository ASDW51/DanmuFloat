// 添加主播表单：直播间号 / 链接 / 抖音号（必填）+ 备注（可选）。
//
// 链接支持直接粘贴分享文案：本地能抽取 webRid 就即时解析，
// 短链则联网跟随跳转后再抽取（design.md 11.9）。
// 解析不出来不拦：输入原样存成主播标识，交给连接阶段报错，
// 免得用户在添加这一步就被"必须是直播间号"挡住。
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/room/room_link_parser.dart';
import 'package:flutter/material.dart';

/// 打开添加主播表单；取消返回 null。
Future<ManagedRoom?> showAddRoomDialog(
  BuildContext context, {
  required Set<String> existingWebRids,
  RoomLinkResolver? resolver,
}) =>
    showDialog<ManagedRoom>(
      context: context,
      builder: (BuildContext context) => AddRoomDialog(
        existingWebRids: existingWebRids,
        resolver: resolver,
      ),
    );

class AddRoomDialog extends StatefulWidget {
  const AddRoomDialog({
    super.key,
    required this.existingWebRids,
    this.resolver,
  });

  /// 已在列表里的直播间号，用于拦截重复添加。
  final Set<String> existingWebRids;

  /// 短链解析器，默认走真实网络；单测可注入假实现。
  final RoomLinkResolver? resolver;

  @override
  State<AddRoomDialog> createState() => _AddRoomDialogState();
}

class _AddRoomDialogState extends State<AddRoomDialog> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  late final RoomLinkResolver _resolver =
      widget.resolver ?? RoomLinkResolver();

  bool _resolving = false;
  String? _error;

  /// 用户是否已取消（表单已 pop，但可能还在退场动画里）。
  ///
  /// 取消后解析才返回时必须直接丢弃结果：那时 `mounted` 仍为 true，再 pop 一次
  /// 会把首页路由也弹掉。
  bool _cancelled = false;

  @override
  void dispose() {
    _inputController.dispose();
    _nameController.dispose();
    // 注入的解析器由调用方负责释放。
    if (widget.resolver == null) _resolver.close();
    super.dispose();
  }

  Future<void> _submit() async {
    final String input = _inputController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = '请输入直播间号、链接或抖音号');
      return;
    }

    setState(() {
      _resolving = true;
      _error = null;
    });
    // 解析得到 webRid 就用结果；链接短链解析不出来时按原文保存，不拦用户。
    final String? parsed = await _resolver.resolve(input);
    if (!mounted || _cancelled) return;
    final String identifier = parsed ?? input;
    // 粘的是链接却没能解析出来（含超时）：必须说清楚，否则用户会以为加进去的就是
    // 链接对应的那个直播间（design.md 11.9 的降级路径）。
    final bool resolveFailed = parsed == null && firstHttpUri(input) != null;

    if (widget.existingWebRids.contains(identifier)) {
      setState(() {
        _resolving = false;
        _error = '该主播已在列表中（$identifier）';
      });
      return;
    }

    if (resolveFailed) {
      // 表单马上关闭，SnackBar 交给 App 级 messenger，落在首页上。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未能联网解析链接，已按原文添加')),
      );
    }
    Navigator.of(context).pop(
      ManagedRoom(
        webRid: identifier,
        name: _nameController.text.trim(),
        addedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加主播'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _inputController,
            autofocus: true,
            enabled: !_resolving,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '直播间号 / 链接 / 抖音号',
              hintText: '例如 7350000000000000001、直播间链接、抖音号',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            enabled: !_resolving,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              hintText: '不填则显示主播昵称',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          // 解析期间也能取消（UX-03）：短链联网可能很慢甚至挂住，用户不该被锁在
          // 一个只会转圈的表单里，只能杀进程。
          onPressed: () {
            _cancelled = true;
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _resolving ? null : _submit,
          child: _resolving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('添加'),
        ),
      ],
    );
  }
}