import 'package:danmu_float/ui/home_page.dart';
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/material.dart';

void main() {
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
    return MaterialApp(
      title: 'DanmuFloat',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomePage(),
    );
  }
}