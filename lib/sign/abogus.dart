// ABogus 签名（房间信息 Web 接口用）纯 Dart 移植。
//
// 来源：bili-live-tools/packages/DouYinRecorder/src/sign.ts
// （该 TS 实现又移植自 https://github.com/hua0512/rust-srec 的 abogus.rs）
//
// 移植要求：算法与常量逐项对齐，不得凭记忆改动；`now` 与 `randomDouble` 可注入，
// 以便与参考实现做确定性比对（见 test/abogus_test.dart）。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'sm3.dart';

/// 签名结果。
class AbogusResult {
  const AbogusResult({
    required this.query,
    required this.aBogus,
    required this.userAgent,
  });

  /// 已追加 `&a_bogus=` 的完整 query。
  final String query;

  /// 仅 a_bogus 值。
  final String aBogus;

  /// 本次签名使用（也必须用于请求头）的 User-Agent。
  final String userAgent;
}

/// ABogus 签名器。
///
/// 注意：[sign] 会修改内部 `_bigArray` 状态，因此每次签名都应使用新实例
/// （与参考实现「每次请求 new ABogus()」一致）。
class Abogus {
  Abogus({
    String? fingerprint,
    String? userAgent,
    List<int>? options,
    int Function()? now,
    double Function()? randomDouble,
  })  : userAgent = userAgent ?? defaultUserAgent,
        _options = List<int>.of(options ?? const <int>[0, 1, 14]),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _random = randomDouble ?? Random().nextDouble,
        _bigArray = List<int>.of(_bigArraySeed) {
    _fingerprint = fingerprint ?? _generateFingerprint();
  }

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';

  static const String _salt = 'cus';
  static const String _character =
      'Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe';
  static const String _character2 =
      'ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe';

  /// 256 字节置换表，逐项取自参考实现。
  static const List<int> _bigArraySeed = <int>[
    121, 243, 55, 234, 103, 36, 47, 228, 30, 231, 106, 6, 115, 95, 78, 101, 250, 207, 198, 50,
    139, 227, 220, 105, 97, 143, 34, 28, 194, 215, 18, 100, 159, 160, 43, 8, 169, 217, 180, 120,
    247, 45, 90, 11, 27, 197, 46, 3, 84, 72, 5, 68, 62, 56, 221, 75, 144, 79, 73, 161, 178, 81,
    64, 187, 134, 117, 186, 118, 16, 241, 130, 71, 89, 147, 122, 129, 65, 40, 88, 150, 110, 219,
    199, 255, 181, 254, 48, 4, 195, 248, 208, 32, 116, 167, 69, 201, 17, 124, 125, 104, 96, 83,
    80, 127, 236, 108, 154, 126, 204, 15, 20, 135, 112, 158, 13, 1, 188, 164, 210, 237, 222, 98,
    212, 77, 253, 42, 170, 202, 26, 22, 29, 182, 251, 10, 173, 152, 58, 138, 54, 141, 185, 33,
    157, 31, 252, 132, 233, 235, 102, 196, 191, 223, 240, 148, 39, 123, 92, 82, 128, 109, 57, 24,
    38, 113, 209, 245, 2, 119, 153, 229, 189, 214, 230, 174, 232, 63, 52, 205, 86, 140, 66, 175,
    111, 171, 246, 133, 238, 193, 99, 60, 74, 91, 225, 51, 76, 37, 145, 211, 166, 151, 213, 206,
    0, 200, 244, 176, 218, 44, 184, 172, 49, 216, 93, 168, 53, 21, 183, 41, 67, 85, 224, 155, 226,
    242, 87, 177, 146, 70, 190, 12, 162, 19, 137, 114, 25, 165, 163, 192, 23, 59, 9, 94, 179, 107,
    35, 7, 142, 131, 239, 203, 149, 136, 61, 249, 14, 156,
  ];

  static const List<int> _uaKey = <int>[0x00, 0x01, 0x0e];

  static const List<int> _sortIndex = <int>[
    18, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31, 35, 57, 39, 41, 43, 22, 28,
    32, 60, 36, 23, 29, 33, 37, 44, 45, 59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71,
  ];

  static const List<int> _sortIndex2 = <int>[
    18, 20, 26, 30, 34, 38, 40, 42, 21, 27, 31, 35, 39, 41, 43, 22, 28, 32, 36, 23, 29, 33, 37,
    44, 45, 46, 47, 48, 49, 50, 24, 25, 52, 53, 54, 55, 57, 58, 59, 60, 65, 66, 70, 71,
  ];

  final String userAgent;
  final List<int> _options;
  final int Function() _now;
  final double Function() _random;
  final List<int> _bigArray;

  late final String _fingerprint;

  static const int _pageId = 0;
  static const int _aid = 6383;

  /// 生成带 `a_bogus` 的 query。返回值的 [AbogusResult.query] 可直接用于 URL。
  AbogusResult sign(String params, [String body = '']) {
    final List<int> abDir = List<int>.filled(72, 0);
    abDir[8] = 3;
    abDir[18] = 44;

    final int startEncryption = _now();

    // Hash(Hash(params)) 与 Hash(Hash(body))
    final Uint8List array1 = Sm3.digest(Sm3.digest(utf8.encode(params + _salt)));
    final Uint8List array2 = Sm3.digest(Sm3.digest(utf8.encode(body + _salt)));

    // Hash(Base64(RC4(user_agent)))
    final Uint8List rc4Ua = _rc4(_uaKey, userAgent);
    final String uaB64 = _base64Encode(rc4Ua, 1);
    final Uint8List array3 = Sm3.digest(utf8.encode(uaB64));

    final int endEncryption = _now();

    final int startLow32 = startEncryption & 0xFFFFFFFF;
    abDir[20] = (startLow32 >>> 24) & 0xFF;
    abDir[21] = (startLow32 >>> 16) & 0xFF;
    abDir[22] = (startLow32 >>> 8) & 0xFF;
    abDir[23] = startLow32 & 0xFF;
    abDir[24] = startEncryption ~/ 0x100000000;
    abDir[25] = startEncryption ~/ 0x10000000000;

    abDir[26] = (_options[0] >>> 24) & 0xFF;
    abDir[27] = (_options[0] >>> 16) & 0xFF;
    abDir[28] = (_options[0] >>> 8) & 0xFF;
    abDir[29] = _options[0] & 0xFF;

    abDir[30] = (_options[1] ~/ 256) & 0xFF;
    abDir[31] = _options[1] % 256;
    abDir[32] = (_options[1] >>> 24) & 0xFF;
    abDir[33] = (_options[1] >>> 16) & 0xFF;

    abDir[34] = (_options[2] >>> 24) & 0xFF;
    abDir[35] = (_options[2] >>> 16) & 0xFF;
    abDir[36] = (_options[2] >>> 8) & 0xFF;
    abDir[37] = _options[2] & 0xFF;

    abDir[38] = array1[21];
    abDir[39] = array1[22];
    abDir[40] = array2[21];
    abDir[41] = array2[22];
    abDir[42] = array3[23];
    abDir[43] = array3[24];

    final int endLow32 = endEncryption & 0xFFFFFFFF;
    abDir[44] = (endLow32 >>> 24) & 0xFF;
    abDir[45] = (endLow32 >>> 16) & 0xFF;
    abDir[46] = (endLow32 >>> 8) & 0xFF;
    abDir[47] = endLow32 & 0xFF;
    abDir[48] = abDir[8];
    abDir[49] = endEncryption ~/ 0x100000000;
    abDir[50] = endEncryption ~/ 0x10000000000;

    abDir[51] = (_pageId >>> 24) & 0xFF;
    abDir[52] = (_pageId >>> 16) & 0xFF;
    abDir[53] = (_pageId >>> 8) & 0xFF;
    abDir[54] = _pageId & 0xFF;
    abDir[55] = _pageId;
    abDir[56] = _aid;
    abDir[57] = _aid & 0xFF;
    abDir[58] = (_aid >>> 8) & 0xFF;
    abDir[59] = (_aid >>> 16) & 0xFF;
    abDir[60] = (_aid >>> 24) & 0xFF;

    abDir[64] = _fingerprint.length;
    abDir[65] = _fingerprint.length;

    final List<int> sortedValues =
        _sortIndex.map((int i) => abDir[i]).toList(growable: false);
    final List<int> fpArray = _fingerprint.codeUnits;

    int abXor = 0;
    for (int idx = 0; idx < _sortIndex2.length; idx++) {
      final int value = abDir[_sortIndex2[idx]];
      abXor = idx == 0 ? value : abXor ^ value;
    }

    final List<int> allValues = <int>[...sortedValues, ...fpArray, abXor];
    final List<int> transformed = _transformBytes(allValues);
    final List<int> finalValues = <int>[..._generateRandomBytes(3), ...transformed];
    final String aBogus = _abogusEncode(finalValues);

    return AbogusResult(
      query: '$params&a_bogus=$aBogus',
      aBogus: aBogus,
      userAgent: userAgent,
    );
  }

  /// 与参考实现 `CryptoUtility.transformBytes` 一致：就地修改 `_bigArray`。
  List<int> _transformBytes(List<int> valuesList) {
    final List<int> result = <int>[];
    const int arrayLen = 256;
    int indexB = _bigArray[1];
    int initialValue = 0;
    int valueE = 0;

    for (int index = 0; index < valuesList.length; index++) {
      int sumInitial;
      if (index == 0) {
        initialValue = _bigArray[indexB];
        sumInitial = indexB + initialValue;
        _bigArray[1] = initialValue;
        _bigArray[indexB] = indexB;
      } else {
        sumInitial = initialValue + valueE;
      }
      final int sumInitialIdx = sumInitial % arrayLen;
      final int valueF = _bigArray[sumInitialIdx];
      result.add(valuesList[index] ^ valueF);

      final int nextIdx = (index + 2) % arrayLen;
      valueE = _bigArray[nextIdx];
      final int newSumInitialIdx = (indexB + valueE) % arrayLen;
      initialValue = _bigArray[newSumInitialIdx];

      final int tmp = _bigArray[newSumInitialIdx];
      _bigArray[newSumInitialIdx] = _bigArray[nextIdx];
      _bigArray[nextIdx] = tmp;

      indexB = newSumInitialIdx;
    }
    return result;
  }

  String _base64Encode(List<int> bytes, int alphabetIndex) {
    final String alphabet = alphabetIndex == 0 ? _character : _character2;
    final StringBuffer output = StringBuffer();
    for (int i = 0; i < bytes.length; i += 3) {
      final int b1 = bytes[i];
      final int b2 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      final int b3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      final int combined = (b1 << 16) | (b2 << 8) | b3;
      output.write(alphabet[(combined >> 18) & 63]);
      output.write(alphabet[(combined >> 12) & 63]);
      if (i + 1 < bytes.length) output.write(alphabet[(combined >> 6) & 63]);
      if (i + 2 < bytes.length) output.write(alphabet[combined & 63]);
    }
    String out = output.toString();
    while (out.length % 4 != 0) {
      out += '=';
    }
    return out;
  }

  String _abogusEncode(List<int> values) {
    final StringBuffer output = StringBuffer();
    for (int i = 0; i < values.length; i += 3) {
      final int v1 = values[i];
      final int v2 = i + 1 < values.length ? values[i + 1] : 0;
      final int v3 = i + 2 < values.length ? values[i + 2] : 0;
      final int n = ((v1 << 16) | (v2 << 8) | v3) & 0xFFFFFFFF;
      output.write(_character[(n & 0xfc0000) >> 18]);
      output.write(_character[(n & 0x03f000) >> 12]);
      if (i + 1 < values.length) output.write(_character[(n & 0x0fc0) >> 6]);
      if (i + 2 < values.length) output.write(_character[n & 0x3f]);
    }
    String out = output.toString();
    while (out.length % 4 != 0) {
      out += '=';
    }
    return out;
  }

  Uint8List _rc4(List<int> key, String plaintext) {
    final List<int> s = List<int>.generate(256, (int i) => i);
    int j = 0;
    for (int i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xFF;
      final int tmp = s[i];
      s[i] = s[j];
      s[j] = tmp;
    }
    final List<int> pt = plaintext.codeUnits;
    final Uint8List ct = Uint8List(pt.length);
    int i = 0;
    j = 0;
    for (int idx = 0; idx < pt.length; idx++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      final int tmp = s[i];
      s[i] = s[j];
      s[j] = tmp;
      final int k = s[(s[i] + s[j]) & 0xFF];
      ct[idx] = pt[idx] ^ k;
    }
    return ct;
  }

  /// 与参考实现 `StringProcessor.generateRandomBytes` 一致：每轮产出 4 字节。
  List<int> _generateRandomBytes(int length) {
    final List<int> result = <int>[];
    for (int i = 0; i < length; i++) {
      final int rd = (_random() * 10000).floor();
      result.add((rd & 255 & 170) | 1);
      result.add((rd & 255 & 85) | 2);
      result.add(((rd >> 8) & 170) | 5);
      result.add(((rd >> 8) & 85) | 40);
    }
    return result;
  }

  int _rand(int min, int max) => (_random() * (max - min + 1)).floor() + min;

  String _generateFingerprint() {
    final int innerWidth = _rand(1024, 1920);
    final int innerHeight = _rand(768, 1080);
    final int outerWidth = innerWidth + _rand(24, 32);
    final int outerHeight = innerHeight + _rand(75, 90);
    const int screenX = 0;
    final int screenY = const <int>[0, 30][_rand(0, 1)];
    final int sizeWidth = _rand(1024, 1920);
    final int sizeHeight = _rand(768, 1080);
    final int availWidth = _rand(1280, 1920);
    final int availHeight = _rand(800, 1080);
    return '$innerWidth|$innerHeight|$outerWidth|$outerHeight|$screenX|$screenY|0|0|'
        '$sizeWidth|$sizeHeight|$availWidth|$availHeight|$innerWidth|$innerHeight|24|24|Win32';
  }
}