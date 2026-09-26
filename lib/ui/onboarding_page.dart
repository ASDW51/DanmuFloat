// 首次启动引导（prd 4.10）：5 行步骤 + 状态图标 + 行内按钮。
//
// 顺序与 prd 4.10 流程图一致：悬浮窗权限 → 通知权限（Android 13+）→
// 电池优化白名单 → 自启动权限 → 前台服务类型声明。
// 悬浮窗权限与电池优化白名单跳系统页面，通知权限走系统授权框；
// 自启动只能进应用设置手动开，前台服务类型已随安装包声明、无需操作。
//
// 全部步骤都可以跳过：未授权只影响悬浮窗，App 内仍能查看弹幕（权限拒绝降级）。
import 'dart:async';

import 'package:danmu_float/system/system_permissions.dart';
import 'package:flutter/material.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.onDone});

  /// 引导结束（点击「完成」或「稍后设置」）后的持久化动作。
  final Future<void> Function() onDone;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with WidgetsBindingObserver {
  /// null 表示还没查出来，界面上按「未完成」显示。
  bool? _overlayGranted;
  bool? _notificationGranted;
  bool? _batteryIgnored;

  bool _busy = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页回到 App 时重新查询：跳出去授权的结果只能这样拿到。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final bool overlay = await systemPermissions.hasOverlayPermission();
    final bool notification =
        await systemPermissions.hasNotificationPermission();
    final bool battery =
        await systemPermissions.isBatteryOptimizationIgnored();
    if (!mounted) return;
    setState(() {
      _overlayGranted = overlay;
      _notificationGranted = notification;
      _batteryIgnored = battery;
    });
  }

  Future<void> _requestOverlay() async {
    if (_busy) return;
    setState(() => _busy = true);
    final bool granted = await systemPermissions.requestOverlayPermission();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _overlayGranted = granted;
    });
    if (!granted) _snack('未授予悬浮窗权限，已降级为 App 内查看，可稍后再开');
  }

  Future<void> _requestNotification() async {
    if (_busy) return;
    setState(() => _busy = true);
    final bool granted = await systemPermissions.requestNotificationPermission();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _notificationGranted = granted;
    });
    if (!granted) _snack('未授予通知权限，不影响查看弹幕，仅缺少前台服务通知');
  }

  Future<void> _requestBattery() async {
    await systemPermissions.requestIgnoreBatteryOptimizations();
    if (!mounted) return;
    // 跳出去授权要等用户回来才知道结果，这里只提示。
    _snack('授权后请返回本页，状态会自动刷新');
  }

  Future<void> _openAppSettings() => systemPermissions.openAppSettings();

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await widget.onDone();
    if (!mounted) return;
    setState(() => _finishing = false);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bool overlayGranted = _overlayGranted ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('首次启动引导')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              children: <Widget>[
                const Text(
                  '按顺序完成以下准备',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  '全部步骤都可跳过：未授权只影响悬浮窗，App 内仍可查看弹幕。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                _StepTile(
                  index: 1,
                  title: '悬浮窗权限',
                  subtitle: overlayGranted
                      ? '已授予，可开启悬浮窗查看弹幕'
                      : '未授予，当前仅能在 App 内查看（降级模式）',
                  done: overlayGranted,
                  actionLabel: overlayGranted ? null : '去授权',
                  onAction: overlayGranted || _busy ? null : _requestOverlay,
                ),
                _StepTile(
                  index: 2,
                  title: '通知权限（Android 13+）',
                  subtitle: (_notificationGranted ?? false)
                      ? '已授予，前台服务通知可正常显示'
                      : '未授予，仅缺少前台服务通知，不影响弹幕',
                  done: _notificationGranted ?? false,
                  actionLabel: (_notificationGranted ?? false) ? null : '请求授权',
                  onAction: (_notificationGranted ?? false) || _busy
                      ? null
                      : _requestNotification,
                ),
                _StepTile(
                  index: 3,
                  title: '电池优化白名单',
                  subtitle: (_batteryIgnored ?? false)
                      ? '已在白名单内，后台更不容易被系统回收'
                      : '未加入，长时间后台运行可能被系统回收',
                  done: _batteryIgnored ?? false,
                  actionLabel: (_batteryIgnored ?? false) ? null : '去设置',
                  onAction: (_batteryIgnored ?? false) ? null : _requestBattery,
                ),
                _StepTile(
                  index: 4,
                  title: '自启动权限（各厂商 ROM）',
                  subtitle: '厂商设置项各不相同，需在系统设置里手动开启',
                  done: false,
                  manual: true,
                  actionLabel: '去设置',
                  onAction: _openAppSettings,
                ),
                const _StepTile(
                  index: 5,
                  title: '前台服务类型声明',
                  subtitle: '已随安装包声明（specialUse），无需操作',
                  done: true,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _finishing ? null : _finish,
                    child: const Text('稍后设置'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _finishing ? null : _finish,
                    child: _finishing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('完成'),
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

/// 一行引导步骤：序号 + 状态图标 + 说明 + 行内按钮。
class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.done,
    this.manual = false,
    this.actionLabel,
    this.onAction,
  });

  final int index;
  final String title;
  final String subtitle;

  /// 是否已满足该步骤。
  final bool done;

  /// 该步骤无法自动判定，只能进系统设置手动确认。
  final bool manual;

  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    if (done) {
      icon = Icons.check_circle;
      color = Colors.green;
    } else if (manual) {
      icon = Icons.info_outline;
      color = Colors.blueGrey;
    } else {
      icon = Icons.radio_button_unchecked;
      color = Colors.orange;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: color),
      title: Text('$index. $title'),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: actionLabel == null
          ? null
          : TextButton(onPressed: onAction, child: Text(actionLabel!)),
    );
  }
}
