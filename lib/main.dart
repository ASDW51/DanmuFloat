import 'dart:async';

import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:danmu_float/ui/disclaimer_page.dart';
import 'package:danmu_float/ui/home_page.dart';
import 'package:danmu_float/ui/onboarding_page.dart';
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 主题偏好在首帧之前读回（prd F20）：否则会先按系统色渲染一帧再跳成用户选择。
  appThemeMode.value = await ThemeStore().load();
  runApp(const MainApp());
}

/// 悬浮窗入口点：由 flutter_screen_overlay 在**独立 Flutter 引擎**中启动
/// （主 App 启动时即预热，实际窗口由 showOverlay 唤起）。
///
/// 连接链路（签名 / 房间信息 / WebSocket / 解析）跑在这个引擎内，
/// 主 App 只负责下发房间配置与展示状态（prd 4.11）。
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const OverlayApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 深色 / 浅色模式（prd F20）：设置页改的是全局 [appThemeMode]，
    // 这里监听后即时切换，不必把回调从首页一路透传到设置页。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (BuildContext context, ThemeMode mode, Widget? child) =>
          MaterialApp(
        title: 'DanmuFloat',
        theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.blue,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        themeMode: mode,
        home: const AppEntry(),
      ),
    );
  }
}

/// 启动分流（prd F25 / 4.10）：未同意免责声明先进合规页；同意后若还没走过
/// 首次启动引导，先过一遍权限引导页，都完成后才进主播管理首页。
///
/// 「清除所有本地数据」会把合规状态一并清掉，此时由 [HomePage] 回调
/// [resetToDisclaimer] 把入口切回免责声明页。
class AppEntry extends StatefulWidget {
  const AppEntry({super.key});

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  final ComplianceStore _store = ComplianceStore();

  bool _loading = true;
  bool _accepted = false;
  bool _onboarded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ComplianceState state = await _store.load();
    if (!mounted) return;
    setState(() {
      _accepted = state.disclaimerAccepted;
      _onboarded = state.onboardingDone;
      _loading = false;
    });
  }

  Future<void> _agree() async {
    // 保留引导状态：清过数据后重进也应重新看一遍引导，所以不写死 false，
    // 而是沿用本次读到的值（清除数据后已随文件一起被删掉）。
    await _store.save(
      ComplianceState(disclaimerAccepted: true, onboardingDone: _onboarded),
    );
    if (!mounted) return;
    setState(() => _accepted = true);
  }

  /// 首次启动引导完成（prd 4.10）。
  Future<void> _finishOnboarding() async {
    await _store.save(
      const ComplianceState(disclaimerAccepted: true, onboardingDone: true),
    );
    if (!mounted) return;
    setState(() => _onboarded = true);
  }

  /// 清除所有本地数据后回到免责声明页（prd F26 硬要求）。
  void _resetToDisclaimer() {
    if (!mounted) return;
    setState(() {
      _accepted = false;
      _onboarded = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_accepted) return DisclaimerPage(onAgree: _agree);
    if (!_onboarded) return OnboardingPage(onDone: _finishOnboarding);
    return HomePage(onResetAll: _resetToDisclaimer);
  }
}
