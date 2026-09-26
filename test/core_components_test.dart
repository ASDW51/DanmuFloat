import 'package:danmu_float/cache/ring_buffer.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/danmu/dedup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MsgIdDeduplicator', () {
    test('同 msgId 第二次视为重复', () {
      final dedup = MsgIdDeduplicator();
      expect(dedup.isDuplicate(100), isFalse);
      expect(dedup.isDuplicate(100), isTrue);
      expect(dedup.length, 1);
    });

    test('msgId 为 0 不参与去重也不占容量', () {
      final dedup = MsgIdDeduplicator();
      expect(dedup.isDuplicate(0), isFalse);
      expect(dedup.isDuplicate(0), isFalse);
      expect(dedup.length, 0);
    });

    test('容量耗尽后淘汰最早一条', () {
      final dedup = MsgIdDeduplicator(capacity: 2);
      expect(dedup.isDuplicate(1), isFalse);
      expect(dedup.isDuplicate(2), isFalse);
      expect(dedup.isDuplicate(3), isFalse);
      expect(dedup.length, 2);
      // 1 已被淘汰，可再次通过
      expect(dedup.isDuplicate(1), isFalse);
      expect(dedup.isDuplicate(3), isTrue);
    });
  });

  group('RingBuffer', () {
    test('超出容量丢弃最旧一条，顺序保持旧到新', () {
      final buffer = RingBuffer<int>(3);
      for (final value in <int>[1, 2, 3, 4, 5]) {
        buffer.add(value);
      }
      expect(buffer.length, 3);
      expect(buffer.toList(), <int>[3, 4, 5]);
    });

    test('空缓冲与清空', () {
      final buffer = RingBuffer<String>(2);
      expect(buffer.isEmpty, isTrue);
      buffer.add('a');
      expect(buffer.isEmpty, isFalse);
      buffer.clear();
      expect(buffer.isEmpty, isTrue);
      expect(buffer.toList(), isEmpty);
    });

    test('toList 返回不可变快照', () {
      final buffer = RingBuffer<int>(2)..add(1);
      expect(() => buffer.toList().add(2), throwsUnsupportedError);
    });
  });

  group('ConnectionStateMachine', () {
    test('初始为 idle，连接中到已连接', () {
      final machine = ConnectionStateMachine();
      expect(machine.state, DanmuConnectionState.idle);
      machine.onConnecting();
      expect(machine.state, DanmuConnectionState.connecting);
      machine.onConnected();
      expect(machine.state, DanmuConnectionState.connected);
    });

    test('断线按固定 10s 重连，第 11 次进入 failed', () {
      final machine = ConnectionStateMachine();
      machine.onConnecting();

      for (var i = 0; i < 10; i++) {
        expect(machine.onDisconnected(), const Duration(seconds: 10));
      }
      expect(machine.reconnectAttempts, 10);
      expect(machine.state, DanmuConnectionState.reconnecting);

      expect(machine.onDisconnected(), isNull);
      expect(machine.state, DanmuConnectionState.failed);
    });

    test('连接成功后重连计数清零', () {
      final machine = ConnectionStateMachine();
      machine.onDisconnected();
      machine.onDisconnected();
      expect(machine.reconnectAttempts, 2);

      machine.onConnecting();
      machine.onConnected();
      expect(machine.reconnectAttempts, 0);
      expect(machine.onDisconnected(), const Duration(seconds: 10));
    });

    test('主动关闭后不再重连', () {
      final machine = ConnectionStateMachine()..onConnected();
      machine.onClosed();
      expect(machine.state, DanmuConnectionState.closed);
      expect(machine.onDisconnected(), isNull);
      expect(machine.state, DanmuConnectionState.closed);
    });

    test('reconnectInterval 可按配置覆盖', () {
      final machine = ConnectionStateMachine(
        maxReconnectAttempts: 1,
        reconnectInterval: const Duration(seconds: 3),
      );
      expect(machine.onDisconnected(), const Duration(seconds: 3));
      expect(machine.onDisconnected(), isNull);
    });
  });
}