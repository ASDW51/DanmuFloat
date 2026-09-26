// 免责声明页（prd F25 / 附录 A + 2.5 合规前提）：
// 首次启动强制勾选，未勾选不可进入主界面；从设置页可重进查看。
//
// 整页可滚动，底部固定勾选框与按钮，避免长文案把按钮顶出屏幕。
import 'package:flutter/material.dart';

/// 合规前提（prd 2.5）：产品定位为自用 / 开源的边界说明。
const List<String> _compliancePremises = <String>[
  '本产品定位为自用 / 开源，不代表无合规风险，使用前请确认符合当地法律法规。',
  '不商业化、不收费、不投放广告，不诱导分享、不传播、不提供在线服务。',
  '凭证默认匿名自动获取，用户无需登录；仅在自动获取失败时由用户手动粘贴兜底。',
  '首次启动需勾选本声明；每次新增直播间连接前会再次确认。',
  '收到平台警告或协议变更时，核心功能可能被远程关闭。',
  '开源协议中明确「仅供学习研究，禁止商业使用」。',
];

/// 免责声明正文（prd 附录 A）。
const List<String> _disclaimerPoints = <String>[
  '本工具仅供学习研究使用，禁止任何商业用途。',
  '使用第三方接口存在风险，由用户自行承担。',
  '使用本工具可能导致账号被限流或封禁，风险由用户承担。',
  '本项目与平台官方无任何关联。',
  '本工具默认匿名获取凭证，不代替用户登录；自动获取失败时可由用户手动粘贴。',
  '凭证默认仅保存在内存、不落盘；仅手动粘贴的凭证才加密保存在本地，用户可随时清除。',
];

class DisclaimerPage extends StatefulWidget {
  const DisclaimerPage({super.key, required this.onAgree});

  /// 用户点击「同意并继续」后的持久化动作（写合规状态）。
  final Future<void> Function() onAgree;

  @override
  State<DisclaimerPage> createState() => _DisclaimerPageState();
}

class _DisclaimerPageState extends State<DisclaimerPage> {
  bool _checked = false;
  bool _submitting = false;

  Future<void> _agree() async {
    setState(() => _submitting = true);
    await widget.onAgree();
    if (!mounted) return;
    // 首次启动时本页是根页面（无返回栈），由外层切换到主界面；
    // 从设置页重进时直接返回上一页。
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _submitting = false);
  }

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
                const Text(
                  '请在使用前完整阅读以下条款。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                const _SectionHeader('合规前提'),
                for (final String item in _compliancePremises)
                  _BulletItem(item),
                const SizedBox(height: 12),
                const _SectionHeader('免责声明'),
                for (int index = 0; index < _disclaimerPoints.length; index++)
                  _BulletItem(
                    '${index + 1}. ${_disclaimerPoints[index]}',
                  ),
                const SizedBox(height: 12),
                const _SectionHeader('数据与隐私'),
                const _BulletItem('不存储账号密码，不代替用户登录任何账号。'),
                const _BulletItem('不持久化任何弹幕数据，弹幕仅保留在内存中，App 关闭即清空。'),
                const _BulletItem(
                  '凭证默认不落盘、不明文打印、不上传、不向第三方转发，并提供清除入口。',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: <Widget>[
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _checked,
                  onChanged: _submitting
                      ? null
                      : (bool? value) =>
                          setState(() => _checked = value ?? false),
                  title: const Text('我已阅读并同意上述声明'),
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    // 未勾选不可继续（prd F25 硬要求）。
                    onPressed:
                        (!_checked || _submitting) ? null : _agree,
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
            ),
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
