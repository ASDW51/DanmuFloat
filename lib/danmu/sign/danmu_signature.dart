// 弹幕 WebSocket 签名（design.md 11.3 的「通道 A」）。
//
// 链路：X-MS-STUB = md5(逗号拼接的签名字段) → webmssdk.js 的 get_sign → signature
// X-MS-STUB 与签名字段为纯算法，可离线单测；get_sign 必须由 JS 引擎执行
// （flutter_js，Android 走 QuickJS，需真机验证）。
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';

/// 弹幕签名字段。Map 的插入顺序即 `k=v` 逗号拼接顺序，不得调整。
Map<String, String> buildDanmuSigParams({
  required String liveId,
  required String userUniqueId,
  int versionCode = 180800,
  String webcastSdkVersion = '1.0.15',
}) =>
    <String, String>{
      'live_id': '1',
      'aid': '6383',
      'version_code': '$versionCode',
      'webcast_sdk_version': webcastSdkVersion,
      'room_id': liveId,
      'sub_room_id': '',
      'sub_channel_id': '',
      'did_rule': '3',
      'user_unique_id': userUniqueId,
      'device_platform': 'web',
      'device_type': '',
      'ac': '',
      'identity': 'audience',
    };

/// X-MS-STUB = md5(逗号拼接的 `k=v`)。
String buildXMsStub(Map<String, String> params) {
  final String joined = params.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join(',');
  return md5.convert(utf8.encode(joined)).toString();
}

/// 生成 user_unique_id：每次启动随机，量级与参考实现一致。
String generateUserUniqueId([Random? random]) {
  const int min = 7300000000000000000;
  const int span = 7999999999999999999 - 7300000000000000000;
  final double fraction = (random ?? Random()).nextDouble();
  return (min + (fraction * span).floor()).toString();
}

/// 弹幕签名失败时的降级值（design.md 11.3），与参考实现一致。
const String fallbackDanmuSignature = '00000000';

/// 把 webmssdk.js 从 ESM 模块改写为可直接求值的脚本。
///
/// 该资源由 douyin web 版 `webmssdk.es5.js` 改造而来，头部残留两行 Node 专用
/// `import`（`crypto` 的 createHash、`buffer` 的 Buffer）。QuickJS 以脚本模式执行时
/// `import` 是保留字，会直接抛语法错误（真机实测 `SyntaxError: expecting '('`）。
/// 这两处引用只服务于 js-md5 的 Node 桥接，`get_sign` 路径不会走到，整行剥离即可。
String stripEsmModuleSyntax(String source) => source
    .replaceAll(RegExp(r'^[ \t]*import\s.*$', multiLine: true), '')
    .replaceFirst('export function get_sign', 'function get_sign');

class DanmuSignatureException implements Exception {
  DanmuSignatureException(this.message);

  final String message;

  @override
  String toString() => 'DanmuSignatureException: $message';
}

/// 弹幕签名器。
abstract class DanmuSigner {
  /// 按签名字段产出 signature；失败时抛 [DanmuSignatureException]。
  Future<String> sign(Map<String, String> params);
}

/// 通道 A 实现：flutter_js 执行本地打包的 webmssdk.js 的 `get_sign`。
///
/// 注意：webmssdk.js 只在加载阶段做字符串改写（剥离 ESM 的 `import`/`export`），
/// 不做热更新——design.md 12.2 将热更新与完整性校验列为待预研项。
class WebmssdkDanmuSigner implements DanmuSigner {
  WebmssdkDanmuSigner({
    this.assetPath = 'assets/webmssdk.js',
    JavascriptRuntime Function()? runtimeFactory,
  }) : _runtimeFactory = runtimeFactory ?? getJavascriptRuntime;

  /// 签名失败时的降级值（design.md 11.3）。
  static const String fallbackSignature = fallbackDanmuSignature;

  final String assetPath;
  final JavascriptRuntime Function() _runtimeFactory;

  JavascriptRuntime? _runtime;

  /// 最小浏览器环境兜底：webmssdk 内部会读取这些对象。
  /// 用 `typeof ... === 'undefined'` 守护，避免覆盖引擎已有实现。
  static const String _prelude = '''
var window = typeof window !== 'undefined' ? window : this;
var self = typeof self !== 'undefined' ? self : window;
var globalThis = typeof globalThis !== 'undefined' ? globalThis : window;
if (typeof navigator === 'undefined') {
  var navigator = {
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
    platform: 'Win32',
    language: 'zh-CN',
    languages: ['zh-CN', 'zh'],
    appVersion: '5.0 (Windows)',
    cookieEnabled: true,
    hardwareConcurrency: 8
  };
}
if (typeof location === 'undefined') {
  var location = {
    href: 'https://live.douyin.com/',
    origin: 'https://live.douyin.com',
    protocol: 'https:',
    host: 'live.douyin.com',
    hostname: 'live.douyin.com',
    pathname: '/',
    search: '',
    hash: ''
  };
}
if (typeof document === 'undefined') {
  var document = {
    cookie: '',
    referrer: 'https://live.douyin.com/',
    title: '',
    createElement: function () {
      return {
        style: {},
        getContext: function () { return null; },
        setAttribute: function () {},
        appendChild: function () {},
        getElementsByTagName: function () { return []; }
      };
    },
    getElementsByTagName: function () { return []; },
    addEventListener: function () {},
    removeEventListener: function () {}
  };
}
''';

  /// 只做一次加载；重复调用复用同一运行时。
  Future<JavascriptRuntime> _ensureRuntime() async {
    final JavascriptRuntime? existing = _runtime;
    if (existing != null) return existing;

    final String source = await rootBundle.loadString(assetPath);
    final String prepared = stripEsmModuleSyntax(source);

    final JavascriptRuntime runtime = _runtimeFactory();
    final JsEvalResult loadResult =
        runtime.evaluate('$_prelude\n$prepared\n0');
    if (loadResult.isError) {
      runtime.dispose();
      throw DanmuSignatureException('webmssdk.js 加载失败: ${loadResult.stringResult}');
    }
    _runtime = runtime;
    return runtime;
  }

  @override
  Future<String> sign(Map<String, String> params) async {
    final String stub = buildXMsStub(params);
    final JavascriptRuntime runtime = await _ensureRuntime();
    final JsEvalResult result =
        runtime.evaluate('get_sign(${jsonEncode(stub)})');
    if (result.isError) {
      throw DanmuSignatureException('get_sign 执行失败: ${result.stringResult}');
    }
    final String signature = result.stringResult.trim();
    if (signature.isEmpty || signature == 'undefined' || signature == 'null') {
      throw DanmuSignatureException('get_sign 返回空签名');
    }
    return signature;
  }

  void dispose() {
    _runtime?.dispose();
    _runtime = null;
  }
}