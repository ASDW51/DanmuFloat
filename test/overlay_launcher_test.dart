// 主 App 侧的悬浮窗链路：状态流可重复监听，且窗口控制有明确分工——
// 插件改尺寸的 `x-slayer/overlay` 通道只注册在悬浮窗引擎，主 App 只能把尺寸请求
// 经消息通道转过去；悬浮窗自己关掉窗口后，主 App 必须复位「已建窗」。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 插件的尺寸通道：`resizeOverlay` 走它，但 handler 只注册在悬浮窗引擎
/// （OverlayService）；主引擎调用只会抛 MissingPluginException。
const MethodChannel _sizeChannel = MethodChannel('x-slayer/overlay');

/// 插件的双向消息通道：主 App 下发的 config / credential / resize 都经它 send 出去。
const BasicMessageChannel<dynamic> _messengerChannel =
    BasicMessageChannel<dynamic>('x-slayer/overlay_messenger',
        JSONMessageCodec());

/// 主 App 经消息通道发出去的载荷（已解码）。
final List<Object?> _sentMessages = <Object?>[];

/// 尺寸通道被调用过的方法（正常情况下应始终为空）。
final List<MethodCall> _sizeCalls = <MethodCall>[];

/// 挂上两条通道的 mock：尺寸通道只记录调用，消息通道记录载荷并立即应答
/// （`send` 会 await 原生侧回包，不应答会挂到测试超时）。
void _bindOverlayChannels() {
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  _sentMessages.clear();
  _sizeCalls.clear();
  messenger.setMockMethodCallHandler(_sizeChannel, (MethodCall call) async {
    _sizeCalls.add(call);
    return true;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_sizeChannel, null));
  messenger.setMockMessageHandler(
    _messengerChannel.name,
    (ByteData? message) async {
      _sentMessages.add(const JSONMessageCodec().decodeMessage(message));
      return message;
    },
  );
  addTearDown(
    () => messenger.setMockMessageHandler(_messengerChannel.name, null),
  );
}

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

  test('改窗口尺寸经消息通道下发，不直调主引擎没有的尺寸通道', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _bindOverlayChannels();
    setOverlayDragLock(true);
    addTearDown(() => setOverlayDragLock(false));

    await resizeOverlayWindow((width: 320, height: 480));

    // 主引擎的插件实例没注册 `x-slayer/overlay`，直调必然抛 MissingPluginException：
    // 设置页拖尺寸滑杆与「已建窗时重排栏位」都会静默失效。
    expect(_sizeCalls, isEmpty);
    final OverlayResize? resize = OverlayResize.tryParse(_sentMessages.single);
    expect(resize, isNotNull);
    expect(resize!.width, 320);
    expect(resize.height, 480);
    expect(
      resize.dragLocked,
      isTrue,
      reason: '改尺寸必须带上锁定状态，否则插件会把已锁定的窗口重新打开拖动',
    );
  });

  test('已建窗重排按「尺寸 → 凭证 → 配置」下发，尺寸不再挡住建窗配置', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _bindOverlayChannels();
    setOverlayShownForTest(false);
    addTearDown(() => setOverlayShownForTest(false));

    await resizeOverlay(
      const OverlayConfig(webRids: <String>['111']),
      size: (width: 400, height: 560),
    );

    expect(_sentMessages, hasLength(3));
    expect(OverlayResize.tryParse(_sentMessages[0]), isNotNull, reason: '先下发尺寸');
    expect(
      OverlayCredential.tryParse(_sentMessages[1]),
      isNotNull,
      reason: '凭证要先于配置下发，新栏位连上就能取到',
    );
    final OverlayConfig? config = OverlayConfig.tryParse(_sentMessages[2]);
    expect(config, isNotNull, reason: '配置必须发得出去，否则房间绑定下不去');
    expect(config!.webRids, <String>['111']);
  });

  test('悬浮窗在窗内关掉后，主 App 复位「已建窗」', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _bindOverlayChannels();
    // 状态流初始化时才会注册插件通道的 handler，先订阅一次。
    final StreamSubscription<OverlayStatus> subscription =
        overlayStatusStream.listen((OverlayStatus _) {});
    addTearDown(subscription.cancel);
    setOverlayShownForTest(true);
    addTearDown(() => setOverlayShownForTest(false));
    expect(overlayShown, isTrue);

    // 悬浮球菜单关窗：悬浮窗引擎在关窗前补发一次带 closed 的聚合状态。
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      _messengerChannel.name,
      const JSONMessageCodec().encodeMessage(<String, Object?>{
        'type': 'state',
        'stage': 'idle',
        'received': 0,
        'closed': true,
      }),
      (ByteData? _) {},
    );
    // 消息先入队、再由状态流异步派发：排空 microtask 后再断言。
    await Future<void>.delayed(Duration.zero);

    expect(
      overlayShown,
      isFalse,
      reason: '窗口已被悬浮窗自己关掉，主 App 不能继续以为它还在，否则下次开窗只重排、不建窗',
    );
  });
}
