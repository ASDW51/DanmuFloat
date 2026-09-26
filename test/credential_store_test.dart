// 凭证管理（prd F27）：格式校验、加密落盘往返、清除、解密失败不静默降级，
// 以及 CookieProvider 对手动凭证的优先级。
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/net/http_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存后端：单测不依赖 Android Keystore 插件通道。
class FakeBackend implements CredentialBackend {
  FakeBackend({this.readError});

  String? stored;

  /// 读取时抛出的异常，用来模拟解密失败。
  Object? readError;

  @override
  Future<String?> read() async {
    final Object? error = readError;
    if (error != null) throw error;
    return stored;
  }

  @override
  Future<void> write(String value) async => stored = value;

  @override
  Future<void> delete() async => stored = null;
}

/// 记录请求的假传输层，用于验证「手动凭证优先」时不联网。
class RecordingTransport implements HttpTransport {
  int calls = 0;

  @override
  Future<HttpResponseData> get(Uri uri, {Map<String, String>? headers}) async {
    calls++;
    return const HttpResponseData(
      statusCode: 200,
      body: '',
      setCookie: <String>['ttwid=anonymous'],
    );
  }

  @override
  void close() {}
}

void main() {
  tearDown(() => setManualCookies(null));

  group('validateManualCookies', () {
    test('接受分号分隔的 name=value 列表', () {
      expect(validateManualCookies('ttwid=abc; msToken=xyz'), isNull);
      expect(validateManualCookies('  ttwid=abc  '), isNull);
    });

    test('拒绝空值、超长与换行', () {
      expect(validateManualCookies('   '), isNotNull);
      expect(validateManualCookies('a=${'x' * maxManualCookiesLength}'), isNotNull);
      expect(validateManualCookies('ttwid=a\nCookie: b'), isNotNull);
    });

    test('拒绝缺等号、空名与非法字符', () {
      expect(validateManualCookies('ttwid'), isNotNull);
      expect(validateManualCookies('=abc'), isNotNull);
      expect(validateManualCookies('tt wid=abc'), isNotNull);
      expect(validateManualCookies('ttwid=a\u0000b'), isNotNull);
    });
  });

  group('CredentialStore', () {
    test('保存后加密落盘、状态为手动，并能读回生效', () async {
      final FakeBackend backend = FakeBackend();
      final CredentialStore store = CredentialStore(backend: backend);

      expect(await store.saveManual('ttwid=abc'), isNull);
      expect(backend.stored, 'ttwid=abc');
      expect(store.source, CredentialSource.manual);
      expect(manualCookies, 'ttwid=abc');

      // 新实例冷启动读回。
      setManualCookies(null);
      final CredentialStore restored = CredentialStore(backend: backend);
      expect(await restored.load(), CredentialLoadResult.manual);
      expect(manualCookies, 'ttwid=abc');
    });

    test('校验不通过时不写盘、不接管取值', () async {
      final FakeBackend backend = FakeBackend();
      final CredentialStore store = CredentialStore(backend: backend);

      expect(await store.saveManual('不是 cookie'), isNotNull);
      expect(backend.stored, isNull);
      expect(store.source, CredentialSource.anonymous);
      expect(manualCookies, isNull);
    });

    test('清除本地凭证后回到匿名自动获取，且不影响其他信息', () async {
      final FakeBackend backend = FakeBackend();
      final CredentialStore store = CredentialStore(backend: backend);
      await store.saveManual('ttwid=abc');

      await store.clearManual();
      expect(backend.stored, isNull);
      expect(store.source, CredentialSource.anonymous);
      expect(manualCookies, isNull);
    });

    test('解密失败不静默降级：标记失败并回落匿名', () async {
      final FakeBackend backend = FakeBackend(readError: Exception('bad key'))
        ..stored = 'ttwid=abc';
      final CredentialStore store = CredentialStore(backend: backend);

      expect(await store.load(), CredentialLoadResult.decryptFailed);
      expect(store.decryptFailed, isTrue);
      expect(store.isManual, isFalse);
      expect(manualCookies, isNull);
    });

    test('无已保存凭证时按匿名加载', () async {
      final CredentialStore store = CredentialStore(backend: FakeBackend());
      expect(await store.load(), CredentialLoadResult.anonymous);
      expect(store.decryptFailed, isFalse);
    });
  });

  group('CookieProvider 优先级', () {
    test('设置手动凭证后不再联网取匿名凭证', () async {
      final RecordingTransport transport = RecordingTransport();
      setManualCookies('ttwid=manual');
      final String cookies =
          await CookieProvider(transport: transport).getCookies();

      expect(cookies, 'ttwid=manual');
      expect(transport.calls, 0);
    });

    test('清除手动凭证后回到匿名自动获取', () async {
      final RecordingTransport transport = RecordingTransport();
      setManualCookies('ttwid=manual');
      setManualCookies(null);
      final String cookies =
          await CookieProvider(transport: transport).getCookies();

      expect(cookies, 'ttwid=anonymous');
      expect(transport.calls, 1);
    });
  });
}
