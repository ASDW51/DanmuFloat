// 悬浮窗引擎侧：改窗口尺寸的插件通道只注册在本引擎（OverlayService），主 App
// 只能把尺寸请求经消息通道转过来，由 OverlayPage 代为主调插件。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的尺寸通道（`resizeOverlay` 走它）。
const MethodChannel _sizeChannel = MethodChannel('x-slayer/overlay');

/// 插件的双向消息通道：主 App 下发的尺寸请求经它上行到悬浮窗引擎。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

void main() {
  testWidgets('收到主 App 的 resize 请求后，由悬浮窗引擎调插件改窗口尺寸',
      (WidgetTester tester) async {
    final List<MethodCall> sizeCalls = <MethodCall>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_sizeChannel, (MethodCall call) async {
      sizeCalls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_sizeChannel, null));

    await tester.pumpWidget(const OverlayApp());

    // 不 await 派发结果：testWidgets 跑在 FakeAsync 里，等 microtask 容易挂住；
    // 消息入队与后续派发都是同步的，pump 一帧即可让请求落到插件通道。
    unawaited(
      messenger.handlePlatformMessage(
        _messengerChannel.name,
        const JSONMessageCodec().encodeMessage(
          const OverlayResize(
            width: 320,
            height: 480,
            dragLocked: true,
          ).toJson(),
        ),
        (ByteData? _) {},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(sizeCalls, hasLength(1));
    expect(sizeCalls.single.method, 'resizeOverlay');
    expect(sizeCalls.single.arguments['width'], 320);
    expect(sizeCalls.single.arguments['height'], 480);
    expect(
      sizeCalls.single.arguments['enableDrag'],
      isFalse,
      reason: '主 App 下发的锁定状态要带上，否则插件会把拖动重新打开',
    );
  });
}
