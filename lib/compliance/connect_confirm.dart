// 新增直播间连接前的二次确认（prd F25 / 4.9 流程末步）。
//
// 「本次会话内不再提示」只保存在内存：App 进程存活期间有效，重启后恢复提示。
import 'package:flutter/material.dart';

/// 本次会话是否已勾选「不再提示」。
bool _suppressedThisSession = false;

/// 本次会话是否已免打扰（供界面决定是否还弹窗）。
bool get connectConfirmSuppressed => _suppressedThisSession;

/// 重置会话内免打扰标志（仅供测试）。
@visibleForTesting
void resetConnectConfirm() => _suppressedThisSession = false;

/// 连接前二次确认；返回 true 表示用户确认继续建立连接。
///
/// 已勾选过「本次会话内不再提示」时直接放行，不再弹窗。
Future<bool> confirmNewConnection(
  BuildContext context, {
  required List<String> webRids,
}) async {
  if (_suppressedThisSession) return true;
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => _ConnectConfirmDialog(webRids: webRids),
  );
  return result ?? false;
}

class _ConnectConfirmDialog extends StatefulWidget {
  const _ConnectConfirmDialog({required this.webRids});

  /// 本次将建立连接的直播间号（多栏时一并列出）。
  final List<String> webRids;

  @override
  State<_ConnectConfirmDialog> createState() => _ConnectConfirmDialogState();
}

class _ConnectConfirmDialogState extends State<_ConnectConfirmDialog> {
  bool _dontAskAgain = false;

  void _confirm() {
    if (_dontAskAgain) _suppressedThisSession = true;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连接确认'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '本次将为以下直播间建立弹幕连接。本工具仅供学习研究，'
            '使用第三方接口的风险由你自行承担，请勿用于商业用途。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final String webRid in widget.webRids)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('· $webRid'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _dontAskAgain,
            onChanged: (bool? value) =>
                setState(() => _dontAskAgain = value ?? false),
            title: const Text('本次会话内不再提示'),
            subtitle: const Text('重启 App 后恢复提示', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('继续连接'),
        ),
      ],
    );
  }
}
