import 'dart:convert';

import 'package:danmu_float/sign/sm3.dart';
import 'package:flutter_test/flutter_test.dart';

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Sm3（GB/T 32905-2016 标准测试向量）', () {
    test('空串', () {
      expect(
        _hex(Sm3.digest(<int>[])),
        '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b',
      );
    });

    test('abc', () {
      expect(
        _hex(Sm3.digest(utf8.encode('abc'))),
        '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
      );
    });

    test('abcd 重复 16 次（64 字节，跨分组）', () {
      expect(
        _hex(Sm3.digest(utf8.encode('abcd' * 16))),
        'debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732',
      );
    });
  });
}