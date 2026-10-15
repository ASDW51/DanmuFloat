// 添加主播表单：直播间号 / 链接 / 抖音号（必填）+ 备注（可选）。
//
// 链接支持直接粘贴分享文案：本地能抽取 webRid 就即时解析，
// 短链则联网跟随跳转后再抽取（design.md 11.9）。
// 解析不出来不拦：输入原样存成主播标识，交给连接阶段报错，
// 免得用户在添加这一步就被"必须是直播间号"挡住。
//
// 输入体验（R4）：解析出直播间号后即时回显在输入框下方，让用户在提交前
// 就知道「粘贴的内容被识别成了什么」；纯数字输入走数字键盘减少误触。
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/room/room_link_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// 输入框实时解析出的 webRid（R4）：null 表示还没识别出来。
  ///
  /// 只做本地同步解析，不发网络请求：短链在提交时才联网跟随。
  String? get _parsedPreview => extractWebRid(_inputController.text);

  @override
  void initState() {
    super.initState();
    _inputController.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _inputController.removeListener(_onInputChanged);
    _inputController.dispose();
    _nameController.dispose();
    // 注入的解析器由调用方负责释放。
    if (widget.resolver == null) _resolver.close();
    super.dispose();
  }

  void _onInputChanged() {
    if (!mounted) return;
    // 预览依赖输入内容，输入变化时刷新。
    setState(() {});
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
    if (!mounted) return;
    final String identifier = parsed ?? input;

    if (widget.existingWebRids.contains(identifier)) {
      setState(() {
        _resolving = false;
        _error = '该主播已在列表中（$identifier）';
      });
      return;
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
    final String? preview = _parsedPreview;
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
            // 纯数字时是直播间号，弹出数字键盘减少误触（R4）；
            // 链接 / 抖音号含字母符号，保持默认键盘与全字符输入。
            keyboardType: _isDigitsOnly(_inputController.text)
                ? TextInputType.number
                : TextInputType.url,
            inputFormatters: _isDigitsOnly(_inputController.text)
                ? const <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ]
                : null,
            decoration: InputDecoration(
              labelText: '直播间号 / 链接 / 抖音号',
              hintText: '例如 7350000000000000001、直播间链接、抖音号',
              border: const OutlineInputBorder(),
              isDense: true,
              // 识别结果即时回显（R4）：粘贴一段分享文案也能立刻看到解析出的号。
              helperText: preview == null ? null : '已识别直播间号：$preview',
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
          onPressed: _resolving ? null : () => Navigator.of(context).pop(),
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

  /// 是否为纯数字输入：粘贴后判一次即可。
  ///
  /// 不用 `int.tryParse`：webRid 常见 19 位，超出 int64 会解析失败被误判成链接。
  static bool _isDigitsOnly(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return RegExp(r'^\d+$').hasMatch(trimmed);
  }
}