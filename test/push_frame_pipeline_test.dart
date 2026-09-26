import 'dart:io';
import 'dart:typed_data';

import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/proto/im_decoder.dart';
import 'package:danmu_float/danmu/proto/schema.dart';
import 'package:danmu_float/danmu/proto/wire.dart';
import 'package:danmu_float/danmu/push_frame_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 测试用编码器：按 schema 表把 fixture 编成 protobuf 字节。
// 生产侧只有解码与回执编码，这里补齐测试所需的编码能力以构造真实链路帧。
// ---------------------------------------------------------------------------

ProtobufWriter _encodeInto(String schemaName, Map<String, Object?> values) {
  final schema = imSchemas[schemaName]!;
  final writer = ProtobufWriter();
  schema.fields.forEach((number, spec) {
    final raw = values[spec.name];
    if (raw == null) return;
    if (spec.repeated) {
      for (final item in raw as List<Object?>) {
        _writeOne(writer, number, spec, item);
      }
    } else {
      _writeOne(writer, number, spec, raw);
    }
  });
  return writer;
}

void _writeOne(ProtobufWriter writer, int number, FieldSpec spec, Object? value) {
  switch (spec.kind) {
    case FieldKind.varint:
      writer.writeUint64Field(number, value! as int);
    case FieldKind.boolean:
      writer.writeBoolField(number, value! as bool);
    case FieldKind.string:
      writer.writeStringField(number, value! as String);
    case FieldKind.bytes:
      writer.writeBytesField(number, value! as Uint8List);
    case FieldKind.message:
      writer.writeMessageField(
        number,
        _encodeInto(spec.messageType!, value! as Map<String, Object?>),
      );
    case FieldKind.fixed32:
    case FieldKind.fixed64:
    case FieldKind.float:
    case FieldKind.double:
      throw UnsupportedError('测试编码器未覆盖 ${spec.kind}');
  }
}

String _schemaNameOf(String method) =>
    method.startsWith('Webcast') ? method.substring(7) : method;

/// 把一条业务消息包成完整的 WS 二进制帧：PushFrame{ gzip(Response{ messages[] }) }
///
/// [rawPayload] 用于未登记 schema 的 method（测试编码器无法按表编码时的兜底）。
Uint8List buildFrame({
  required String method,
  Map<String, Object?> body = const <String, Object?>{},
  int envelopeMsgId = 0,
  int logId = 123456789,
  bool needAck = false,
  String internalExt = '',
  Uint8List? rawPayload,
}) {
  final messageBytes = rawPayload ?? _encodeInto(_schemaNameOf(method), body).toBytes();
  final responseBytes = _encodeInto('Response', <String, Object?>{
    'messages': <Object?>[
      <String, Object?>{
        'method': method,
        'payload': messageBytes,
        'msg_id': envelopeMsgId,
      },
    ],
    'internal_ext': internalExt,
    'need_ack': needAck,
  }).toBytes();
  return _encodeInto('PushFrame', <String, Object?>{
    'LogID': logId,
    'payload': Uint8List.fromList(gzip.encode(responseBytes)),
    'payload_type': 'msg',
  }).toBytes();
}

// ---------------------------------------------------------------------------
// fixtures：取自真实抓包样本 data/messages/messages_WebcastChatMessage.json，
// 字段名与取值保持一致（仅裁剪与本链路无关的字段）。
// ---------------------------------------------------------------------------

Map<String, Object?> chatBody({String content = '来了来了'}) => <String, Object?>{
      'common': <String, Object?>{
        'method': 'WebcastChatMessage',
        'msg_id': 7686421297371468806,
        'room_id': 7686413720435657482,
        'create_time': 1758900000,
        'app_id': 1128,
      },
      'user': <String, Object?>{
        'id': 58702042894,
        'short_id': 6160980,
        'nickname': '🤍方',
        'level': 1,
        'avatar_thumb': <String, Object?>{
          'url_list': <Object?>['https://p3.douyinpic.com/aweme/100x100/avatar.jpeg'],
        },
        'badge_image_list': <Object?>[
          <String, Object?>{
            'url_list': <Object?>['https://p11-webcast.douyinpic.com/admin_badge.png'],
            'image_type': 3,
            'content': <String, Object?>{'alternative_text': '房管勋章'},
          },
          <String, Object?>{
            'url_list': <Object?>['https://p3-webcast.douyinpic.com/new_user_grade_level_v1_35.png'],
            'image_type': 1,
            'content': <String, Object?>{
              'level': 35,
              'alternative_text': '荣誉等级35级勋章',
            },
          },
          <String, Object?>{
            'url_list': <Object?>[
              'https://p11-webcast.douyinpic.com/ranklist_fansclub_advanced_badge_16.png',
            ],
            'image_type': 7,
            'content': <String, Object?>{
              'name': '柱子z',
              'font_color': '#FFFFFF',
              'level': 16,
              'alternative_text': '柱子z粉丝团等级16级勋章',
            },
          },
        ],
      },
      'content': content,
      'event_time': 1758900005,
    };

void main() {
  group('wire-format 读写', () {
    test('varint 往返（含超过 2^53 的大整数）', () {
      for (final value in <int>[0, 1, 127, 128, 300, 7686421297371468806]) {
        final writer = ProtobufWriter()..writeUint64Field(2, value);
        final reader = ProtobufReader(writer.toBytes());
        final tag = reader.readTag();
        expect(tag.fieldNumber, 2);
        expect(tag.wireType, WireType.varint);
        expect(reader.readVarint(), value);
      }
    });

    test('跳过未登记字段不报错', () {
      final writer = ProtobufWriter()
        ..writeStringField(99, '未登记字段')
        ..writeUint64Field(1, 42);
      final decoded = decodeSchema(writer.toBytes(), 'PushHeader');
      expect(decoded, isEmpty);
    });

    test('截断字节流抛 ProtoDecodeException', () {
      final truncated = Uint8List.fromList(<int>[0x08]);
      expect(() => decodeSchema(truncated, 'PushFrame'), throwsA(isA<ProtoDecodeException>()));
    });
  });

  group('PushFramePipeline 全链路', () {
    test('普通弹幕：用户信息、粉丝团等级、时间戳单位均正确', () {
      final pipeline = PushFramePipeline();
      final output = pipeline.process(buildFrame(method: 'WebcastChatMessage', body: chatBody()));

      expect(output.events, hasLength(1));
      final event = output.events.single;
      expect(event.kind, DanmakuKind.chat);
      expect(event.text, '来了来了');
      expect(event.method, 'WebcastChatMessage');
      expect(event.msgId, 7686421297371468806);
      expect(event.roomId, 7686413720435657482);
      // event_time 源字段为秒，统一转为毫秒
      expect(event.timeMs, 1758900005 * 1000);
      expect(event.user.userId, '58702042894');
      expect(event.user.nickName, '🤍方');
      expect(event.user.level, 1);
      expect(event.user.avatarUrl, 'https://p3.douyinpic.com/aweme/100x100/avatar.jpeg');
      // image_type 1 是荣誉等级（35），粉丝团等级应取 image_type 7 的 16
      expect(event.user.fanLevel, 16);
      expect(output.ackFrame, isNull);
      expect(pipeline.parseFailures, 0);
    });

    test('need_ack 为真时回执帧带回 LogID 与 internal_ext', () {
      final output = PushFramePipeline().process(buildFrame(
        method: 'WebcastChatMessage',
        body: chatBody(),
        logId: 99887766554433,
        needAck: true,
        internalExt: 'internal-ext-1',
      ));

      expect(output.ackFrame, isNotNull);
      final ack = decodePushFrame(output.ackFrame!);
      expect(ack.logId, 99887766554433);
      expect(ack.payloadType, 'internal-ext-1');
    });

    test('重复 msgId 去重：第二帧不再产出事件', () {
      final pipeline = PushFramePipeline();
      final frame = buildFrame(method: 'WebcastChatMessage', body: chatBody());

      expect(pipeline.process(frame).events, hasLength(1));
      expect(pipeline.process(frame).events, isEmpty);
      expect(pipeline.duplicates, 1);
      expect(pipeline.receivedMessages, 2);
    });

    test('礼物弹幕：数量与钻石价值映射正确', () {
      final output = PushFramePipeline().process(buildFrame(
        method: 'WebcastGiftMessage',
        body: <String, Object?>{
          'common': <String, Object?>{
            'msg_id': 10001,
            'room_id': 7686413720435657482,
            'create_time': 1758900100,
          },
          'user': <String, Object?>{'id': 111, 'nickname': '送礼人'},
          'repeat_count': 5,
          'gift': <String, Object?>{
            'id': 888,
            'name': '小心心',
            'diamond_count': 1,
          },
        },
      ));

      final event = output.events.single;
      expect(event.kind, DanmakuKind.gift);
      expect(event.text, '小心心 ×5');
      expect(event.count, 5);
      expect(event.amount, 1);
    });

    test('超过 1KB 的单条消息整条丢弃', () {
      final pipeline = PushFramePipeline(maxMessageBytes: 16);
      final output = pipeline.process(
        buildFrame(method: 'WebcastChatMessage', body: chatBody(content: '很长的弹幕内容' * 20)),
      );

      expect(output.events, isEmpty);
      expect(pipeline.oversizedDropped, 1);
    });

    test('未登记 method 透传为 other，不报错', () {
      final output = PushFramePipeline().process(buildFrame(
        method: 'WebcastLinkMicMethod',
        // 未登记 schema 的消息不做二次解码，按其原始字节透传
        rawPayload: Uint8List.fromList(<int>[0x08, 0x01]),
        envelopeMsgId: 555,
      ));

      final event = output.events.single;
      expect(event.kind, DanmakuKind.other);
      expect(event.method, 'WebcastLinkMicMethod');
      expect(event.msgId, 555);
    });

    test('脏帧只计数不抛异常', () {
      final pipeline = PushFramePipeline();
      final output = pipeline.process(Uint8List.fromList(<int>[0xFF, 0x00, 0x12]));

      expect(output.events, isEmpty);
      expect(output.ackFrame, isNull);
      expect(pipeline.parseFailures, 1);
      expect(pipeline.receivedFrames, 1);
    });
  });

  group('时间戳归一', () {
    test('秒转毫秒，毫秒原样保留，0 保持 0', () {
      expect(toMillis(1758900005), 1758900005000);
      expect(toMillis(1758900005000), 1758900005000);
      expect(toMillis(0), 0);
    });
  });
}