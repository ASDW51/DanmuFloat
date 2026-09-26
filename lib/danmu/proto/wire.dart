import 'dart:convert';
import 'dart:typed_data';

/// protobuf wire type（tag 低 3 位）
class WireType {
  const WireType._();

  static const int varint = 0;
  static const int fixed64 = 1;
  static const int lengthDelimited = 2;
  static const int startGroup = 3;
  static const int endGroup = 4;
  static const int fixed32 = 5;
}

/// 解析失败异常。上层捕获后丢弃该条消息并计入埋点，不中断连接（design.md 第 5 章）。
class ProtoDecodeException implements Exception {
  ProtoDecodeException(this.message);

  final String message;

  @override
  String toString() => 'ProtoDecodeException: $message';
}

/// 通用 protobuf wire-format 读取器。
///
/// 不依赖 protoc 代码生成：字段号到字段名的映射由 schema 层负责，本层只按 wire type
/// 取值，未知字段直接跳过，避免协议新增字段导致解析失败。
class ProtobufReader {
  ProtobufReader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get isAtEnd => _pos >= _bytes.length;

  void _ensure(int count) {
    if (_pos + count > _bytes.length) {
      throw ProtoDecodeException('字节流越界：需要 $count 字节，剩余 ${_bytes.length - _pos}');
    }
  }

  int _readByte() {
    _ensure(1);
    return _bytes[_pos++];
  }

  /// 读 varint。按无符号 64 位解释，≥2^63 的值在 Dart 中表现为负数。
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _readByte();
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
      if (shift >= 64) throw ProtoDecodeException('varint 超过 64 位');
    }
  }

  /// 读 tag，拆出字段号与 wire type。
  ({int fieldNumber, int wireType}) readTag() {
    final tag = readVarint();
    final fieldNumber = tag >>> 3;
    if (fieldNumber == 0) throw ProtoDecodeException('字段号为 0');
    return (fieldNumber: fieldNumber, wireType: tag & 0x7);
  }

  ByteData _view(int count) {
    _ensure(count);
    final view = ByteData.sublistView(_bytes, _pos, _pos + count);
    _pos += count;
    return view;
  }

  int readFixed32() => _view(4).getUint32(0, Endian.little);

  int readFixed64() => _view(8).getUint64(0, Endian.little);

  double readFloat() => _view(4).getFloat32(0, Endian.little);

  double readDouble() => _view(8).getFloat64(0, Endian.little);

  /// 读 length-delimited 字节，返回的是原缓冲区的视图（不复制）。
  Uint8List readBytes() {
    final length = readVarint();
    if (length < 0) throw ProtoDecodeException('长度字段为负：$length');
    _ensure(length);
    final view = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return view;
  }

  /// 读字符串。容错解码非法 UTF-8，避免个别脏字节导致整帧失败。
  String readString() => utf8.decode(readBytes(), allowMalformed: true);

  /// 按 wire type 跳过当前字段。
  void skip(int wireType) {
    switch (wireType) {
      case WireType.varint:
        readVarint();
      case WireType.fixed64:
        _ensure(8);
        _pos += 8;
      case WireType.lengthDelimited:
        readBytes();
      case WireType.fixed32:
        _ensure(4);
        _pos += 4;
      case WireType.startGroup:
      case WireType.endGroup:
        throw ProtoDecodeException('不支持已废弃的 group 类型');
      default:
        throw ProtoDecodeException('未知 wire type：$wireType');
    }
  }
}

/// 通用 protobuf wire-format 写入器，用于构造回执帧。
class ProtobufWriter {
  final BytesBuilder _out = BytesBuilder();

  /// 写 varint。按无符号 64 位语义输出（负数按其 64 位补码展开为 10 字节）。
  void writeVarint(int value) {
    var v = value;
    for (var i = 0; i < 10; i++) {
      final byte = v & 0x7F;
      v = v >>> 7;
      if (v == 0) {
        _out.addByte(byte);
        return;
      }
      _out.addByte(byte | 0x80);
    }
    throw ProtoDecodeException('varint 超过 64 位');
  }

  void writeTag(int fieldNumber, int wireType) {
    writeVarint((fieldNumber << 3) | wireType);
  }

  void writeUint64Field(int fieldNumber, int value) {
    writeTag(fieldNumber, WireType.varint);
    writeVarint(value);
  }

  void writeBoolField(int fieldNumber, bool value) {
    writeTag(fieldNumber, WireType.varint);
    writeVarint(value ? 1 : 0);
  }

  void writeStringField(int fieldNumber, String value) {
    writeBytesField(fieldNumber, Uint8List.fromList(utf8.encode(value)));
  }

  void writeBytesField(int fieldNumber, Uint8List value) {
    writeTag(fieldNumber, WireType.lengthDelimited);
    writeVarint(value.length);
    _out.add(value);
  }

  void writeMessageField(int fieldNumber, ProtobufWriter sub) {
    writeBytesField(fieldNumber, sub.toBytes());
  }

  Uint8List toBytes() => _out.toBytes();
}