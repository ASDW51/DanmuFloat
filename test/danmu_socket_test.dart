import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/connection/danmu_socket.dart';
import 'package:danmu_float/danmu/sign/danmu_signature.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假通道：记录发送内容，可主动推送数据或结束。
class FakeChannel implements DanmuChannel, DanmuChannelCloseInfo {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<Object> sent = <Object>[];
  bool closed = false;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  void send(Object data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void emit(Object data) => _controller.add(data);
}

class FakeChannelFactory {
  final List<FakeChannel> channels = <FakeChannel>[];
  final List<Uri> uris = <Uri>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];

  /// 为真时每次建连都抛错，用于验证重连次数达上限进入 failed。
  bool alwaysFail = false;

  Future<DanmuChannel> call(Uri uri, Map<String, String> header) async {
    uris.add(uri);
    headers.add(header);
    if (alwaysFail) {
      throw StateError('connect failed');
    }
    final FakeChannel channel = FakeChannel();
    channels.add(channel);
    return channel;
  }
}

Future<void> _tick([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('formEncode', () {
    test('空格转 +，保留字符不转义', () {
      expect(formEncode('a b'), 'a+b');
      expect(formEncode('a-b_c.d*e'), 'a-b_c.d*e');
    });

    test('其余字符按 UTF-8 大写十六进制转义', () {
      expect(formEncode('a/b'), 'a%2Fb');
      expect(formEncode('(x);y:z,q'), '%28x%29%3By%3Az%2Cq');
      expect(formEncode('中'), '%E4%B8%AD');
    });
  });

  group('buildDanmuWsUri', () {
    const String liveId = '7350000000000000001';
    const String uid = '7650000000000000000';
    const String signature = 'SIGN';

    test('scheme / host / path 与参考实现一致', () {
      final Uri uri = buildDanmuWsUri(
        liveId: liveId,
        userUniqueId: uid,
        signature: signature,
      );
      expect(uri.scheme, 'wss');
      expect(uri.host, defaultDanmuHost);
      expect(uri.path, '/webcast/im/push/v2/');
    });

    test('关键参数齐全且取值正确', () {
      final Uri uri = buildDanmuWsUri(
        liveId: liveId,
        userUniqueId: uid,
        signature: signature,
      );
      expect(uri.queryParameters['app_name'], 'douyin_web');
      expect(uri.queryParameters['room_id'], liveId);
      expect(uri.queryParameters['compress'], 'gzip');
      expect(uri.queryParameters['live_id'], '1');
      expect(uri.queryParameters['did_rule'], '3');
      expect(uri.queryParameters['identity'], 'audience');
      expect(uri.queryParameters['signature'], signature);
      expect(uri.queryParameters['endpoint'], 'live_pc');
      expect(uri.queryParameters['im_path'], '/webcast/im/fetch/');
      expect(uri.queryParameters['support_wrds'], '1');
      expect(uri.queryParameters['tz_name'], 'Etc/GMT-8');
      expect(uri.queryParameters['aid'], '6383');
      expect(uri.queryParameters['heartbeatDuration'], '0');
    });

    test('browser_version 按 form-urlencoded 编码（空格为 +）', () {
      final String query = buildDanmuWsQuery(
        liveId: liveId,
        userUniqueId: uid,
        signature: signature,
      );
      expect(query, contains('browser_version=5.0+%28Windows+NT+10.0%3B+Win64%3B+x64%29'));
      expect(query, isNot(contains(' ')), reason: '不应残留未编码空格');
    });
  });

  group('弹幕签名（通道 A 的纯算法部分）', () {
    test('X-MS-STUB = md5(逗号拼接)，与 Node crypto 基准一致', () {
      final Map<String, String> params = buildDanmuSigParams(
        liveId: '7350000000000000001',
        userUniqueId: '7650000000000000000',
      );
      expect(
        buildXMsStub(params),
        '5a38bbc5178eece1d4956a1f8b7c6d99',
      );
    });

    test('签名字段顺序与取值固定', () {
      final Map<String, String> params = buildDanmuSigParams(
        liveId: '123',
        userUniqueId: '456',
      );
      expect(
        params.keys.join(','),
        'live_id,aid,version_code,webcast_sdk_version,room_id,sub_room_id,'
        'sub_channel_id,did_rule,user_unique_id,device_platform,device_type,'
        'ac,identity',
      );
      expect(params['room_id'], '123');
      expect(params['user_unique_id'], '456');
      expect(params['version_code'], '180800');
      expect(params['webcast_sdk_version'], '1.0.15');
      expect(params['identity'], 'audience');
    });

    test('user_unique_id 落在参考实现区间且为纯数字', () {
      for (final int seed in <int>[1, 42, 9999]) {
        final String uid = generateUserUniqueId(Random(seed));
        expect(RegExp(r'^\d+$').hasMatch(uid), isTrue);
        final int value = int.parse(uid);
        expect(value, greaterThanOrEqualTo(7300000000000000000));
        expect(value, lessThanOrEqualTo(7999999999999999999));
      }
    });

    test('剥离 ESM 的 import/export，使脚本可在 QuickJS 中求值', () {
      const String source = '// header\n'
          'import { createHash } from "crypto";\n'
          'import { Buffer } from "buffer";\n'
          'var a = 1;\n'
          'export function get_sign(md5) { return md5; }\n';
      final String prepared = stripEsmModuleSyntax(source);
      expect(prepared, isNot(contains('import ')));
      expect(prepared, isNot(contains('export ')));
      expect(prepared, contains('function get_sign(md5)'));
      expect(prepared, contains('var a = 1;'));
    });

    test('真实 webmssdk.js 剥离后不含行首 import/export，且保留 get_sign', () {
      final String raw = File('assets/webmssdk.js').readAsStringSync();
      expect(raw, contains('import { createHash } from "crypto";'),
          reason: '资源头部应仍是 Node 改造版，否则本用例失去意义');
      final String prepared = stripEsmModuleSyntax(raw);
      expect(
        RegExp(r'^[ \t]*(import|export)\s', multiLine: true).hasMatch(prepared),
        isFalse,
        reason: '残留 ESM 语法会让 QuickJS 报 SyntaxError: expecting \'(\'',
      );
      expect(prepared, contains('function get_sign('));
    });
  });

  group('DanmuSocketClient', () {
    DanmuSocketClient build(
      FakeChannelFactory factory, {
      ConnectionStateMachine? stateMachine,
      Duration heartbeat = const Duration(milliseconds: 30),
      Duration timeout = const Duration(milliseconds: 60),
    }) =>
        DanmuSocketClient(
          liveId: '7350000000000000001',
          userUniqueId: '7650000000000000000',
          signature: 'SIGN',
          cookies: 'ttwid=t1',
          channelFactory: factory.call,
          stateMachine: stateMachine,
          heartbeatInterval: heartbeat,
          timeoutInterval: timeout,
          timeoutCheckInterval: const Duration(milliseconds: 10),
        );

    test('连接成功后进入 connected，请求头带 Cookie 与 Origin', () async {
      final FakeChannelFactory factory = FakeChannelFactory();
      final DanmuSocketClient client = build(factory);
      client.start();
      await _tick();

      expect(client.state, DanmuConnectionState.connected);
      expect(factory.headers.single['Cookie'], 'ttwid=t1');
      expect(factory.headers.single['Origin'], 'https://live.douyin.com');
      expect(factory.headers.single['Referer'], 'https://live.douyin.com/');
      await client.stop();
    });

    test('按心跳间隔发送 :\\x02hb 文本帧', () async {
      final FakeChannelFactory factory = FakeChannelFactory();
      final DanmuSocketClient client = build(factory);
      client.start();
      await _tick(100);

      expect(factory.channels.single.sent, contains(danmuHeartbeatText));
      await client.stop();
    });

    test('长时间无消息判定失联并按固定间隔重连', () async {
      final FakeChannelFactory factory = FakeChannelFactory();
      // 重连间隔取 300ms，远大于超时判定的观测窗口，避免两次建连混在同一断言里。
      final ConnectionStateMachine stateMachine = ConnectionStateMachine(
        maxReconnectAttempts: 3,
        reconnectInterval: const Duration(milliseconds: 300),
      );
      final DanmuSocketClient client = build(
        factory,
        stateMachine: stateMachine,
        timeout: const Duration(milliseconds: 30),
      );
      client.start();
      await _tick(60);

      expect(factory.channels.single.closed, isTrue, reason: '失联后应关闭旧连接');
      expect(stateMachine.state, DanmuConnectionState.reconnecting);

      await _tick(300);
      expect(factory.channels.length, 2, reason: '重连间隔到点后应重新建连');
      await client.stop();
    });

    test('重连次数达上限后进入 failed 且不再建连', () async {
      final FakeChannelFactory factory = FakeChannelFactory()..alwaysFail = true;
      final ConnectionStateMachine stateMachine = ConnectionStateMachine(
        maxReconnectAttempts: 1,
        reconnectInterval: const Duration(milliseconds: 10),
      );
      final DanmuSocketClient client = build(factory, stateMachine: stateMachine);
      client.start();
      await _tick(60);

      expect(stateMachine.state, DanmuConnectionState.failed);
      expect(factory.channels, isEmpty);
      final int attempts = factory.uris.length;
      await _tick(60);
      expect(factory.uris.length, attempts, reason: 'failed 后不应再尝试连接');
      await client.stop();
    });

    test('stop() 主动关闭后不再重连', () async {
      final FakeChannelFactory factory = FakeChannelFactory();
      final DanmuSocketClient client = build(factory);
      client.start();
      await _tick();
      await client.stop();

      expect(client.state, DanmuConnectionState.closed);
      await _tick(60);
      expect(factory.uris.length, 1);
    });

    test('建连失败时把异常记入 lastError', () async {
      final FakeChannelFactory factory = FakeChannelFactory()..alwaysFail = true;
      final DanmuSocketClient client = build(
        factory,
        stateMachine: ConnectionStateMachine(
          maxReconnectAttempts: 0,
          reconnectInterval: const Duration(milliseconds: 10),
        ),
      );
      client.start();
      await _tick();

      expect(client.lastError, contains('connect failed'));
      await client.stop();
    });

    test('成功建连后 lastError 清空', () async {
      final FakeChannelFactory factory = FakeChannelFactory();
      final DanmuSocketClient client = build(factory);
      client.start();
      await _tick();

      expect(client.lastError, isNull);
      await client.stop();
    });

    test('通道带关闭码断开时把关闭码记入 lastError', () async {
      final FakeChannelFactory factory = FakeChannelFactory();
      final DanmuSocketClient client = build(
        factory,
        stateMachine: ConnectionStateMachine(
          maxReconnectAttempts: 0,
          reconnectInterval: const Duration(milliseconds: 10),
        ),
      );
      client.start();
      await _tick();

      final FakeChannel channel = factory.channels.single;
      channel.closeCode = 4001;
      channel.closeReason = 'kicked';
      await channel.close();
      await _tick();

      expect(client.lastError, contains('code=4001'));
      expect(client.lastError, contains('kicked'));
      await client.stop();
    });
  });
}