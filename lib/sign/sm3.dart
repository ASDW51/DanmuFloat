// SM3 摘要算法（GB/T 32905-2016）纯 Dart 实现。
//
// 用途：ABogus 签名需要 SM3 哈希（对应参考实现里 sm-crypto 的 sm3）。
// 之所以自行实现而非引入第三方依赖，是为了满足 design.md「纯算法可移植 Dart」的要求，
// 并可用标准测试向量离线校验。
import 'dart:typed_data';

/// SM3 哈希。
abstract final class Sm3 {
  /// 初始向量。
  static const List<int> _iv = <int>[
    0x7380166f,
    0x4914b2b9,
    0x172442d7,
    0xda8a0600,
    0xa96f30bc,
    0x163138aa,
    0xe38dee4d,
    0xb0fb0e4e,
  ];

  /// 计算 [data] 的 SM3 摘要，返回 32 字节。
  static Uint8List digest(List<int> data) {
    final int bitLen = data.length * 8;
    final int paddedLen = ((data.length + 9 + 63) ~/ 64) * 64;
    final Uint8List buffer = Uint8List(paddedLen);
    buffer.setRange(0, data.length, data);
    buffer[data.length] = 0x80;
    final ByteData view = ByteData.view(buffer.buffer);
    view.setUint32(paddedLen - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF);
    view.setUint32(paddedLen - 4, bitLen & 0xFFFFFFFF);

    final Uint32List state = Uint32List.fromList(_iv);
    final Uint32List w = Uint32List(68);
    final Uint32List w1 = Uint32List(64);

    for (int offset = 0; offset < paddedLen; offset += 64) {
      for (int j = 0; j < 16; j++) {
        w[j] = view.getUint32(offset + j * 4);
      }
      for (int j = 16; j < 68; j++) {
        final int t = w[j - 16] ^ w[j - 9] ^ _rotl(w[j - 3], 15);
        w[j] = (_p1(t) ^ _rotl(w[j - 13], 7) ^ w[j - 6]) & 0xFFFFFFFF;
      }
      for (int j = 0; j < 64; j++) {
        w1[j] = (w[j] ^ w[j + 4]) & 0xFFFFFFFF;
      }

      int a = state[0];
      int b = state[1];
      int c = state[2];
      int d = state[3];
      int e = state[4];
      int f = state[5];
      int g = state[6];
      int h = state[7];

      for (int j = 0; j < 64; j++) {
        final int tj = j < 16 ? 0x79cc4519 : 0x7a879d8a;
        final int ss1 = _rotl((_rotl(a, 12) + e + _rotl(tj, j % 32)) & 0xFFFFFFFF, 7);
        final int ss2 = ss1 ^ _rotl(a, 12);
        final int ff = j < 16 ? (a ^ b ^ c) : ((a & b) | (a & c) | (b & c));
        final int gg = j < 16 ? (e ^ f ^ g) : ((e & f) | ((~e) & g));
        final int tt1 = (ff + d + ss2 + w1[j]) & 0xFFFFFFFF;
        final int tt2 = (gg + h + ss1 + w[j]) & 0xFFFFFFFF;
        d = c;
        c = _rotl(b, 9);
        b = a;
        a = tt1;
        h = g;
        g = _rotl(f, 19);
        f = e;
        e = _p0(tt2);
      }

      state[0] = (state[0] ^ a) & 0xFFFFFFFF;
      state[1] = (state[1] ^ b) & 0xFFFFFFFF;
      state[2] = (state[2] ^ c) & 0xFFFFFFFF;
      state[3] = (state[3] ^ d) & 0xFFFFFFFF;
      state[4] = (state[4] ^ e) & 0xFFFFFFFF;
      state[5] = (state[5] ^ f) & 0xFFFFFFFF;
      state[6] = (state[6] ^ g) & 0xFFFFFFFF;
      state[7] = (state[7] ^ h) & 0xFFFFFFFF;
    }

    final Uint8List out = Uint8List(32);
    final ByteData outView = ByteData.view(out.buffer);
    for (int i = 0; i < 8; i++) {
      outView.setUint32(i * 4, state[i]);
    }
    return out;
  }

  static int _rotl(int value, int shift) {
    final int n = shift & 31;
    final int v = value & 0xFFFFFFFF;
    if (n == 0) return v;
    return ((v << n) | (v >>> (32 - n))) & 0xFFFFFFFF;
  }

  static int _p0(int x) =>
      (x ^ _rotl(x, 9) ^ _rotl(x, 17)) & 0xFFFFFFFF;

  static int _p1(int x) =>
      (x ^ _rotl(x, 15) ^ _rotl(x, 23)) & 0xFFFFFFFF;
}