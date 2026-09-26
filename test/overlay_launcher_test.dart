// 悬浮窗状态流的可重复监听：插件侧通道是静态单例的非广播 StreamController，
// 主 App 侧每次进入弹幕页都会 listen 一次，必须能重复监听。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('同一状态流可被多次监听，不会抛 Bad state', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final List<StreamSubscription<OverlayStatus>> subscriptions =
        <StreamSubscription<OverlayStatus>>[
      overlayStatusStream.listen((OverlayStatus _) {}),
      overlayStatusStream.listen((OverlayStatus _) {}),
    ];
    expect(subscriptions.length, 2);
    for (final StreamSubscription<OverlayStatus> subscription
        in subscriptions) {
      await subscription.cancel();
    }
  });
}
