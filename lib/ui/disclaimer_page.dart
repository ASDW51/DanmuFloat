// 免责声明页（prd F25）：
// 首次启动强制勾选，未勾选不可进入主界面；从设置页可重进查看。
//
// 整页可滚动，底部固定勾选框与按钮，避免长文案把按钮顶出屏幕。
// 正文精简为核心要点，只保留合规与风险的必要结论。
import 'package:danmu_float/ui/danmu_text_colors.dart';
import 'package:flutter/material.dart';

/// 免责声明要点（精简）。
const List<String> _disclaimerPoints = <String>[
  '本工具仅供学习研究，禁止商业使用，与平台官方无任何关联。',
  '使用第三方接口存在风险，账号可能被限流或封禁，后果由用户自行承担。',
  // '默认匿名获取凭证，不代替用户登录；收到平台警告或协议变更时，核心功能可能被远程关闭。',
];

/// 数据与隐私要点（精简）。
const List<String> _privacyPoints = <String>[
  //'不存储账号密码，不持久化弹幕数据。',
  '凭证默认不落盘；仅手动粘贴的凭证加密保存在本地，可随时清除。',
];

class DisclaimerPage extends StatefulWidget {
  const DisclaimerPage({
    super.key,
    required this.onAgree,
    this.reviewMode = false,
  });

  /// 用户点击「同意并继续」后的持久化动作（写合规状态）。
  final Future<void> Function() onAgree;

  /// 已同意者从设置页重进时的只读模式（#85）。
  ///
  /// 同意是与本机当次操作绑定的授权记录，重进只应是「查看」：此前它照样显示未勾选的
  /// 勾选框与禁用的「同意并继续」，看着像还没同意过，也让人以为还能改。此模式只展示
  /// 「已同意」，不提供任何改状态的入口（首次启动的强制勾选路径不受影响）。
  final bool reviewMode;

  @override
  State<DisclaimerPage> createState() => _DisclaimerPageState();
}

class _DisclaimerPageState extends State<DisclaimerPage> {
  bool _checked = false;
  bool _submitting = false;

  /// 提交同意。
  ///
  /// 提交标志必须**异常安全复位**（#106）：旧实现把 `_submitting = false` 放在 await 之后，
  /// 落盘一抛异常就永远复位不了——按钮永久禁用并挂转圈，而首次启动时本页是根路由
  /// （无返回栈），用户没有任何出口，只能杀进程。
  Future<void> _agree() async {
    setState(() => _submitting = true);
    try {
      await widget.onAgree();
      if (!mounted) return;
      // 首次启动时本页是根页面（无返回栈），由外层切换到主界面；
      // 从设置页重进时直接返回上一页。
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on Object catch (exception) {
      debugPrint('提交免责声明失败: $exception');
      if (!mounted) return;
      // 明确告知同意没有存下来：否则用户以为已经同意，重启却又回到这一页。
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败，请重试')));
    } finally {
      if (mounted && _submitting) setState(() => _submitting = false);
    }
  }

  /// 首次启动的同意区：不勾选不可继续（prd F25 硬要求）。
  Widget _buildAgreeFooter() => Column(
        children: <Widget>[
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _checked,
            onChanged: _submitting
                ? null
                : (bool? value) => setState(() => _checked = value ?? false),
            title: const Text('我已阅读并同意上述声明'),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (!_checked || _submitting) ? null : _agree,
              child: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('同意并继续'),
            ),
          ),
        ],
      );

  /// 已同意者重进时的只读区（#85）：状态照实显示为「已同意」，且没有可改它的控件。
  Widget _buildAcceptedFooter() => Column(
        children: <Widget>[
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.check_circle_outline),
            title: Text('已同意上述声明'),
            subtitle: Text('首次启动时勾选，之后不可修改'),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('关闭'),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('免责声明')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              children: <Widget>[
                const Text(
                  'DanmuFloat 仅供学习研究使用',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  '请在使用前完整阅读以下条款。',
                  style: TextStyle(
                    fontSize: 12,
                    color: secondaryTextColor(Theme.of(context).brightness),
                  ),
                ),
                const SizedBox(height: 16),
                const _SectionHeader('免责声明'),
                for (int index = 0; index < _disclaimerPoints.length; index++)
                  _BulletItem(
                    '${index + 1}. ${_disclaimerPoints[index]}',
                  ),
                const SizedBox(height: 12),
                const _SectionHeader('数据与隐私'),
                for (final String item in _privacyPoints) _BulletItem(item),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: widget.reviewMode
                ? _buildAcceptedFooter()
                : _buildAgreeFooter(),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
}

class _BulletItem extends StatelessWidget {
  const _BulletItem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('• '),
            Expanded(
              child: Text(text, style: const TextStyle(height: 1.4)),
            ),
          ],
        ),
      );
}
