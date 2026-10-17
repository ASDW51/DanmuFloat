// 设置页「关于 → 检查更新」（#166）。
//
// 单独成文件而不是塞进 settings_page.dart：这一块自己有状态机（未检查 / 检查中 /
// 已是最新 / 有新版本 / 失败），和设置页那一堆「改了就回调」的控件不是一类东西。
import 'dart:async';

import 'package:danmu_float/app/app_version.dart';
import 'package:danmu_float/net/update_checker.dart';
import 'package:danmu_float/storage/update_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 检查更新的界面状态。
enum UpdateCheckState { idle, checking, latest, available, failed }

/// 「关于」分区里的检查更新块。
class UpdateSection extends StatefulWidget {
  const UpdateSection({
    super.key,
    required this.checker,
    required this.prefsStore,
    this.currentVersion = appVersion,
    this.openUrl,
    this.now,
  });

  final UpdateChecker checker;
  final UpdatePrefsStore prefsStore;

  /// 当前版本号；单测可注入。
  final String currentVersion;

  /// 打开外部链接；单测注入替身，避免依赖 url_launcher 的平台通道。
  final Future<bool> Function(Uri url)? openUrl;

  /// 当前时间（毫秒）；单测可注入固定值。
  final int Function()? now;

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  UpdatePrefs _prefs = const UpdatePrefs();
  UpdateCheckState _state = UpdateCheckState.idle;
  ReleaseInfo? _release;

  /// 只在第一次 build 之后读盘：偏好文件很小，但也没必要和首帧抢时间。
  bool _loaded = false;

  int get _now => (widget.now ?? _defaultNow)();

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
  }

  Future<void> _loadPrefs() async {
    final UpdatePrefs prefs = await widget.prefsStore.load();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _loaded = true;
    });
  }

  Future<void> _persist(UpdatePrefs next) async {
    setState(() => _prefs = next);
    await widget.prefsStore.save(next);
  }

  /// 手动 / 自动检查共用这一条路径。
  ///
  /// 无论成功失败都写时间戳（失败也写）：弱网下才不会每次都被同一个请求拖住。
  Future<void> _check() async {
    if (_state == UpdateCheckState.checking) return;
    setState(() => _state = UpdateCheckState.checking);
    final ReleaseInfo? release = await widget.checker.fetchLatest();
    if (!mounted) return;
    await _persist(_prefs.copyWith(lastCheckedAt: _now));
    if (!mounted) return;
    if (release == null) {
      setState(() => _state = UpdateCheckState.failed);
      return;
    }
    setState(() {
      _release = release;
      _state = hasNewerVersion(release.version, widget.currentVersion)
          ? UpdateCheckState.available
          : UpdateCheckState.latest;
    });
  }

  Future<void> _setAutoCheck(bool value) async {
    await _persist(_prefs.copyWith(autoCheck: value));
  }

  Future<void> _openExternal(String? url) async {
    if (url == null) return;
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    final Future<bool> Function(Uri) open = widget.openUrl ?? _launchExternal;
    final bool ok = await open(uri);
    if (!mounted) return;
    if (!ok) {
      // 打不开就退回「可复制」：国内网络与无浏览器环境都可能失败（#166 风险项）。
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      _snack('打不开浏览器，下载地址已复制');
    }
  }

  static Future<bool> _launchExternal(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack(message);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showNotes(ReleaseInfo release) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('更新说明 · v${release.version}'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              release.notes.trim().isEmpty ? '这个版本没有填写更新说明。' : release.notes,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_openExternal(release.pageUrl));
            },
            child: const Text('打开发布页'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ReleaseInfo? release = _release;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ListTile(
          key: const ValueKey<String>('updateCheckTile'),
          leading: const Icon(Icons.system_update_alt),
          title: const Text('检查更新'),
          subtitle: Text(_subtitle()),
          trailing: _state == UpdateCheckState.checking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onTap: _state == UpdateCheckState.checking ? null : _check,
        ),
        if (release != null) ...<Widget>[
          ListTile(
            key: const ValueKey<String>('updateNotesTile'),
            leading: const Icon(Icons.article_outlined),
            title: const Text('更新日志'),
            subtitle: Text(_releaseSummary(release)),
            onTap: () => _showNotes(release),
          ),
          ListTile(
            key: const ValueKey<String>('updateOpenReleaseTile'),
            leading: const Icon(Icons.open_in_new),
            title: const Text('打开发布页'),
            subtitle: const Text('在浏览器里查看 Release 与下载产物'),
            onTap: () => _openExternal(release.pageUrl),
          ),
          if (release.apkUrl != null)
            ListTile(
              key: const ValueKey<String>('updateCopyApkTile'),
              leading: const Icon(Icons.download_outlined),
              title: const Text('复制 APK 下载地址'),
              subtitle: const Text('通用包；复制后到浏览器下载'),
              onTap: () => _copy(release.apkUrl!, '下载地址已复制'),
            ),
          if (release.sha256Url != null || release.apkSha256 != null)
            ListTile(
              key: const ValueKey<String>('updateCopyShaTile'),
              leading: const Icon(Icons.verified_outlined),
              title: const Text('复制 SHA256'),
              subtitle: Text(
                release.apkSha256 == null
                    ? '校验值清单地址（SHA256SUMS.txt）'
                    : '下载后可用它核对安装包是否完整',
              ),
              onTap: () => _copy(
                release.apkSha256 ?? release.sha256Url!,
                'SHA256 已复制',
              ),
            ),
        ],
        const Divider(height: 1),
        SwitchListTile(
          key: const ValueKey<String>('updateAutoCheckSwitch'),
          secondary: const Icon(Icons.schedule),
          title: const Text('自动检查更新'),
          subtitle: const Text('每 24 小时最多一次；会访问 github.com，暴露 IP 与「装了本 App」这一事实'),
          value: _prefs.autoCheck,
          onChanged: _loaded ? (bool value) => unawaited(_setAutoCheck(value)) : null,
        ),
        const Divider(height: 1),
      ],
    );
  }

  String _subtitle() {
    switch (_state) {
      case UpdateCheckState.checking:
        return '正在检查…';
      case UpdateCheckState.latest:
        return '已是最新版本（当前 ${appVersionLabel(widget.currentVersion)}）';
      case UpdateCheckState.available:
        return '发现新版本 v${_release?.version ?? ''}，当前 ${appVersionLabel(widget.currentVersion)}';
      case UpdateCheckState.failed:
        return '检查失败，可能是网络或 GitHub 限流；可稍后重试';
      case UpdateCheckState.idle:
        final int? last = _prefs.lastCheckedAt;
        if (last == null) return '从没检查过；当前 ${appVersionLabel(widget.currentVersion)}';
        return '上次检查：${_formatTime(last)}；当前 ${appVersionLabel(widget.currentVersion)}';
    }
  }

  String _releaseSummary(ReleaseInfo release) {
    final int? published = release.publishedAt;
    if (published == null) return 'v${release.version}';
    return 'v${release.version} · ${_formatTime(published)}';
  }

  static String _formatTime(int millis) {
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
