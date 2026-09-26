import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/net/http_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';

void main() {
  group('joinCookieValues', () {
    test('仅保留 name=value 并去掉属性段', () {
      expect(
        joinCookieValues(<String>[
          'ttwid=abc; Path=/; Expires=Wed, 21 Oct 2025 07:28:00 GMT',
          'passport_csrf_token=xyz; Path=/',
        ]),
        'ttwid=abc; passport_csrf_token=xyz',
      );
    });

    test('空输入返回空串', () {
      expect(joinCookieValues(const <String>[]), '');
    });
  });

  group('CookieProvider', () {
    test('首次请求取回含 ttwid 的 Cookie，并在 TTL 内命中缓存', () async {
      int calls = 0;
      final FakeTransport transport = FakeTransport((Uri uri, _) async {
        calls++;
        expect(uri.toString(), 'https://live.douyin.com/');
        return const HttpResponseData(
          statusCode: 200,
          body: '',
          setCookie: <String>['ttwid=t1; Path=/', 'other=1; Path=/'],
        );
      });
      DateTime now = DateTime(2026, 1, 1, 0, 0, 0);
      final CookieProvider provider = CookieProvider(
        transport: transport,
        now: () => now,
      );

      expect(await provider.getCookies(), 'ttwid=t1; other=1');

      now = now.add(const Duration(hours: 5));
      expect(await provider.getCookies(), 'ttwid=t1; other=1');
      expect(calls, 1, reason: 'TTL 内应命中内存缓存，不再发请求');
    });

    test('新响应缺 ttwid 且有缓存时复用旧缓存并续期 1 小时', () async {
      int calls = 0;
      final FakeTransport transport = FakeTransport((Uri uri, _) async {
        calls++;
        return calls == 1
            ? const HttpResponseData(
                statusCode: 200,
                body: '',
                setCookie: <String>['ttwid=t1; Path=/'],
              )
            : const HttpResponseData(
                statusCode: 200,
                body: '',
                setCookie: <String>['passport=2; Path=/'],
              );
      });
      DateTime now = DateTime(2026, 1, 1, 0, 0, 0);
      final CookieProvider provider = CookieProvider(
        transport: transport,
        now: () => now,
      );

      expect(await provider.getCookies(), 'ttwid=t1');

      // 越过 6h TTL 触发重新请求；响应无 ttwid → 回退旧缓存
      now = now.add(const Duration(hours: 6, seconds: 1));
      expect(await provider.getCookies(), 'ttwid=t1');
      expect(calls, 2);

      // 参考实现是在旧时间戳上 +1h（t0+1h），故此刻起 6h 内仍命中缓存
      now = DateTime(2026, 1, 1, 6, 30, 0);
      expect(await provider.getCookies(), 'ttwid=t1');
      expect(calls, 2, reason: '续期后不应再发请求');
    });

    test('无 set-cookie 时抛 CookieFetchException', () async {
      final FakeTransport transport = FakeTransport(
        (Uri uri, _) async => const HttpResponseData(statusCode: 200, body: ''),
      );
      final CookieProvider provider = CookieProvider(transport: transport);
      expect(
        provider.getCookies(),
        throwsA(isA<CookieFetchException>()),
      );
    });

    test('请求头携带桌面版 UA', () async {
      final FakeTransport transport = FakeTransport(
        (Uri uri, _) async => const HttpResponseData(
          statusCode: 200,
          body: '',
          setCookie: <String>['ttwid=t1; Path=/'],
        ),
      );
      await CookieProvider(transport: transport).getCookies();
      expect(
        transport.requestHeaders.single['User-Agent'],
        defaultDesktopUserAgent,
      );
    });
  });
}