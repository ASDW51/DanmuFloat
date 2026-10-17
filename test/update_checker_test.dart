// 检查更新（#166）：节流口径、Release 解析与「失败一律不抛」。
//
// 这里钉的是「查不到更新时 App 必须一切照旧」：限流、超时、畸形 JSON、非 200 都只能
// 变成 null，绝不能把异常抛给设置页或启动链路。
import 'package:danmu_float/net/http_transport.dart';
import 'package:danmu_float/net/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定应答的假 transport。
class _FakeTransport implements HttpTransport {
  _FakeTransport({
    this.statusCode = 200,
    this.body = '{}',
    this.delay = Duration.zero,
    this.throwOnGet = false,
  });

  final int statusCode;
  final String body;
  final Duration delay;
  final bool throwOnGet;
  int calls = 0;

  @override
  Future<HttpResponseData> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    calls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (throwOnGet) throw StateError('boom');
    return HttpResponseData(statusCode: statusCode, body: body);
  }

  @override
  void close() {}
}

const String _validBody = '''
{
  "tag_name": "v0.2.0",
  "name": "0.2.0",
  "published_at": "2026-10-01T12:30:00Z",
  "body": "- 修复悬浮窗白底白字\\n- 新增检查更新",
  "html_url": "https://github.com/ASDW51/DanmuFloat/releases/tag/v0.2.0",
  "assets": [
    {"name": "DanmuFloat-v0.2.0-arm64-v8a.apk", "browser_download_url": "https://example.com/arm64.apk", "digest": "sha256:arm"},
    {"name": "DanmuFloat-v0.2.0-universal.apk", "browser_download_url": "https://example.com/universal.apk", "digest": "sha256:abcdef"},
    {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"}
  ]
}
''';

void main() {
  group('shouldCheckForUpdate（#166）', () {
    test('开关关闭时永远不查', () {
      expect(shouldCheckForUpdate(null, 1000, enabled: false), isFalse);
      expect(shouldCheckForUpdate(0, 999999999999, enabled: false), isFalse);
    });

    test('从没查过就要查一次', () {
      expect(shouldCheckForUpdate(null, 1000, enabled: true), isTrue);
    });

    test('24 小时内不重复查，超过才查', () {
      const int now = 1000000000000;
      expect(
        shouldCheckForUpdate(now - 3600000, now, enabled: true),
        isFalse,
        reason: '一小时前刚查过，不该再打一次 GitHub',
      );
      expect(
        shouldCheckForUpdate(
          now - updateCheckInterval.inMilliseconds + 1,
          now,
          enabled: true,
        ),
        isFalse,
      );
      expect(
        shouldCheckForUpdate(
          now - updateCheckInterval.inMilliseconds,
          now,
          enabled: true,
        ),
        isTrue,
      );
    });
  });

  group('ReleaseInfo.tryParse（#166）', () {
    test('解析出版本号、时间、说明与产物地址', () {
      final ReleaseInfo? info = ReleaseInfo.tryParse(_validBody);
      expect(info, isNotNull);
      expect(info!.version, '0.2.0', reason: 'v 前缀要去掉，才能与当前版本比较');
      expect(info.name, '0.2.0');
      expect(info.publishedAt, isNotNull);
      expect(info.notes, contains('检查更新'));
      expect(info.pageUrl, contains('/releases/tag/v0.2.0'));
      expect(
        info.apkUrl,
        'https://example.com/universal.apk',
        reason: '优先通用包：arm64 精简包在别的机型上装不上',
      );
      expect(info.apkSha256, 'abcdef', reason: 'digest 的 sha256: 前缀要去掉');
      expect(info.sha256Url, 'https://example.com/SHA256SUMS.txt');
    });

    test('缺 tag_name / 畸形 JSON / 非对象一律返回 null，不抛', () {
      expect(ReleaseInfo.tryParse('not json'), isNull);
      expect(ReleaseInfo.tryParse('[]'), isNull);
      expect(ReleaseInfo.tryParse('{"name":"x"}'), isNull);
      expect(ReleaseInfo.tryParse('{"tag_name":""}'), isNull);
      expect(ReleaseInfo.tryParse('{"tag_name":123}'), isNull);
    });

    test('没有产物时地址为空，不影响其它字段', () {
      final ReleaseInfo? info = ReleaseInfo.tryParse(
        '{"tag_name":"v1.0.0","html_url":"https://example.com/r"}',
      );
      expect(info, isNotNull);
      expect(info!.apkUrl, isNull);
      expect(info.sha256Url, isNull);
      expect(info.apkSha256, isNull);
      expect(info.notes, isEmpty);
      expect(info.publishedAt, isNull);
    });
  });

  group('UpdateChecker.fetchLatest（#166）', () {
    test('200 + 合法 JSON 返回 ReleaseInfo，并带上 UA / Accept 头', () async {
      final _FakeTransport transport = _FakeTransport(body: _validBody);
      final UpdateChecker checker = UpdateChecker(transport: transport);
      final ReleaseInfo? info = await checker.fetchLatest();
      expect(info?.version, '0.2.0');
      expect(transport.calls, 1);
    });

    test('404 / 403 / 500 一律返回 null', () async {
      for (final int code in <int>[403, 404, 500]) {
        final UpdateChecker checker = UpdateChecker(
          transport: _FakeTransport(statusCode: code),
        );
        expect(await checker.fetchLatest(), isNull, reason: 'HTTP $code 不该抛');
      }
    });

    test('超时返回 null', () async {
      final UpdateChecker checker = UpdateChecker(
        transport: _FakeTransport(
          body: _validBody,
          delay: const Duration(milliseconds: 80),
        ),
        timeout: const Duration(milliseconds: 10),
      );
      expect(await checker.fetchLatest(), isNull);
    });

    test('transport 抛异常（DNS / TLS / 非 UTF-8 解码）返回 null', () async {
      final UpdateChecker checker = UpdateChecker(
        transport: _FakeTransport(throwOnGet: true),
      );
      expect(await checker.fetchLatest(), isNull);
    });

    test('200 但正文畸形返回 null', () async {
      final UpdateChecker checker = UpdateChecker(
        transport: _FakeTransport(body: '<html>oops</html>'),
      );
      expect(await checker.fetchLatest(), isNull);
    });
  });

  group('hasNewerVersion（#166）', () {
    test('比当前新才算更新', () {
      expect(hasNewerVersion('0.2.0', '0.1.0'), isTrue);
      expect(hasNewerVersion('0.1.0', '0.1.0'), isFalse);
      expect(hasNewerVersion('0.1.0', '0.2.0'), isFalse);
    });

    test('当前是 dev（未注入版本号）时不提示更新', () {
      expect(hasNewerVersion('9.9.9', 'dev'), isFalse);
      expect(hasNewerVersion('9.9.9', ''), isFalse);
    });
  });
}
