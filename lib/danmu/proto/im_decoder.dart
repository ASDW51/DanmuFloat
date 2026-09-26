import 'dart:typed_data';

import 'package:danmu_float/danmu/proto/schema.dart';
import 'package:danmu_float/danmu/proto/wire.dart';

/// 一帧 WS 二进制报文（PushFrame）解出的内容。
class PushFrameData {
  const PushFrameData({required this.logId, required this.payload, required this.payloadType});

  /// PushFrame.LogID，回执时原样带回。
  final int logId;

  /// PushFrame.payload，gzip 压缩的 Response 字节。
  final Uint8List payload;
  final String payloadType;
}

/// Response.messages[] 中的一条壳消息，payload 需按 method 二次解码。
class EnvelopeMessage {
  const EnvelopeMessage({
    required this.method,
    required this.payload,
    required this.envelopeMsgId,
  });

  final String method;
  final Uint8List payload;

  /// Message.msg_id（壳层 id，去重以 common.msg_id 为准）。
  final int envelopeMsgId;
}

/// PushFrame.payload 解压后的负载。
class ResponseData {
  const ResponseData({
    required this.messages,
    required this.internalExt,
    required this.needAck,
    required this.heartbeatDuration,
  });

  final List<EnvelopeMessage> messages;

  /// 回执帧的 payload_type 取值来源。
  final String internalExt;
  final bool needAck;
  final int heartbeatDuration;
}

/// 按 schema 名解码一段 protobuf 字节，返回「字段名 → 值」映射。
///
/// 值类型约定：varint/fixed → int、boolean → bool、string → String、
/// bytes → `Uint8List`、message → `Map<String, Object?>`、repeated → `List`。
Map<String, Object?> decodeSchema(Uint8List bytes, String schemaName) {
  final schema = imSchemas[schemaName];
  if (schema == null) {
    throw ProtoDecodeException('未登记的 schema：$schemaName');
  }

  final out = <String, Object?>{};
  final reader = ProtobufReader(bytes);
  while (!reader.isAtEnd) {
    final tag = reader.readTag();
    final spec = schema.fields[tag.fieldNumber];
    if (spec == null) {
      reader.skip(tag.wireType);
      continue;
    }
    final value = _readValue(reader, tag.wireType, spec);
    if (value == null) continue;
    if (spec.repeated) {
      (out.putIfAbsent(spec.name, () => <Object?>[]) as List<Object?>).add(value);
    } else {
      out[spec.name] = value;
    }
  }
  return out;
}

/// 依声明类型取值。wire type 与声明不符时跳过该字段并返回 null，
/// 以兼容协议侧类型变更（容错要求见 design.md 第 5 章）。
Object? _readValue(ProtobufReader reader, int wireType, FieldSpec spec) {
  switch (spec.kind) {
    case FieldKind.varint:
      if (wireType != WireType.varint) break;
      return reader.readVarint();
    case FieldKind.boolean:
      if (wireType != WireType.varint) break;
      return reader.readVarint() != 0;
    case FieldKind.fixed64:
      if (wireType != WireType.fixed64) break;
      return reader.readFixed64();
    case FieldKind.fixed32:
      if (wireType != WireType.fixed32) break;
      return reader.readFixed32();
    case FieldKind.float:
      if (wireType != WireType.fixed32) break;
      return reader.readFloat();
    case FieldKind.double:
      if (wireType != WireType.fixed64) break;
      return reader.readDouble();
    case FieldKind.string:
      if (wireType != WireType.lengthDelimited) break;
      return reader.readString();
    case FieldKind.bytes:
      if (wireType != WireType.lengthDelimited) break;
      return reader.readBytes();
    case FieldKind.message:
      if (wireType != WireType.lengthDelimited) break;
      final type = spec.messageType;
      if (type == null || !imSchemas.containsKey(type)) break;
      return decodeSchema(reader.readBytes(), type);
  }
  reader.skip(wireType);
  return null;
}

PushFrameData decodePushFrame(Uint8List frame) {
  final map = decodeSchema(frame, 'PushFrame');
  final payload = map['payload'];
  return PushFrameData(
    logId: asInt(map['LogID']),
    payload: payload is Uint8List ? payload : Uint8List(0),
    payloadType: asString(map['payload_type']),
  );
}

ResponseData decodeResponse(Uint8List bytes) {
  final map = decodeSchema(bytes, 'Response');
  final messages = <EnvelopeMessage>[];
  for (final item in asMessageList(map['messages'])) {
    final method = asString(item['method']);
    final payload = item['payload'];
    if (method.isEmpty || payload is! Uint8List) continue;
    messages.add(EnvelopeMessage(
      method: method,
      payload: payload,
      envelopeMsgId: asInt(item['msg_id']),
    ));
  }
  return ResponseData(
    messages: messages,
    internalExt: asString(map['internal_ext']),
    needAck: asBool(map['need_ack']),
    heartbeatDuration: asInt(map['heartbeat_duration']),
  );
}

/// 构造回执帧：PushFrame{LogID, payload_type: Response.internal_ext}。
/// 缺失回执会被服务端断开（design.md 11.6）。
Uint8List encodeAckFrame({required int logId, required String internalExt}) {
  final writer = ProtobufWriter();
  writer.writeUint64Field(2, logId);
  writer.writeStringField(7, internalExt);
  return writer.toBytes();
}

// ---------------------------------------------------------------------------
// 解码结果读取辅助
// ---------------------------------------------------------------------------

Map<String, Object?>? asMessage(Object? value) =>
    value is Map<String, Object?> ? value : null;

List<Map<String, Object?>> asMessageList(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return value.whereType<Map<String, Object?>>().toList(growable: false);
}

int asInt(Object? value) => value is int ? value : 0;

bool asBool(Object? value) => value is bool && value;

String asString(Object? value) => value is String ? value : '';

/// 取 Image.url_list 中首个非空 URL。
String firstImageUrl(Object? image) {
  final map = asMessage(image);
  if (map == null) return '';
  final urls = map['url_list'];
  if (urls is List) {
    for (final url in urls) {
      if (url is String && url.isNotEmpty) return url;
    }
  }
  return '';
}