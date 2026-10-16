import 'dart:async';

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

    test('close() 清缓存但不关别人的 transport（谁 new 谁 close，#95）', () async {
      int calls = 0;
      final FakeTransport transport = FakeTransport((Uri uri, _) async {
        calls++;
        return const HttpResponseData(
          statusCode: 200,
          body: '',
          setCookie: <String>['ttwid=t1; Path=/'],
        );
      });
      final CookieProvider provider = CookieProvider(transport: transport);

      await provider.getCookies();
      expect(calls, 1);

      provider.close();
      expect(
        transport.closeCount,
        0,
        reason: '注入的 transport 归创建者管，关掉会把别人还在用的连接池关了',
      );

      // 缓存已清：下一次取要重新请求（缓存还在的话这里仍是 1 次）。
      await provider.getCookies();
      expect(calls, 2);
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

      // 续期基于当前时间（t0+6h+1s 再 +1h），故此刻起 6h 内仍命中缓存
      now = DateTime(2026, 1, 1, 6, 30, 0);
      expect(await provider.getCookies(), 'ttwid=t1');
      expect(calls, 2, reason: '续期后不应再发请求');
    });

    test('缓存已过期很久时续期仍生效：基于当前时间而不是旧时间戳（#80）', () async {
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

      // 过期 8 小时（远超 6h TTL）后才拿到缺 ttwid 的响应。旧实现在旧时间戳上加 1h
      // （t0+1h），续期后距当下仍是 7 小时前，等于没续上——上面那条用例只推进了
      // 6h+1s，落在「旧时间戳 +1h 也够用」的窗口里，所以漏掉了这个 bug。
      now = now.add(const Duration(hours: 8));
      expect(await provider.getCookies(), 'ttwid=t1');
      expect(calls, 2);

      // 紧接着再取：续期必须已经生效，直接命中缓存（旧实现在这里会再发一次请求）。
      expect(await provider.getCookies(), 'ttwid=t1');
      expect(calls, 2, reason: '续期没生效的话，每次取 Cookie 都会重新联网');

      // 续期点是 t0+8h 再 +1h：之后 6h TTL 内继续命中。
      now = now.add(const Duration(hours: 6, minutes: 30));
      expect(await provider.getCookies(), 'ttwid=t1');
      expect(calls, 2, reason: '续期后 6h TTL 内不应打扰服务端');

      // 越过续期点 6h：确实过期，这才重新请求。
      now = now.add(const Duration(minutes: 31));
      await provider.getCookies();
      expect(calls, 3);
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

    test('取匿名凭证永不返回时按超时抛 CookieFetchException（#76）', () async {
      final Completer<HttpResponseData> pending = Completer<HttpResponseData>();
      final CookieProvider provider = CookieProvider(
        transport: FakeTransport((Uri uri, _) => pending.future),
        // 阈值取短值：让超时在用例内落地。
        fetchTimeout: const Duration(milliseconds: 30),
      );

      await expectLater(
        provider.getCookies(),
        throwsA(
          isA<CookieFetchException>().having(
            (CookieFetchException error) => error.message,
            'message',
            contains('超时'),
          ),
        ),
      );
    });
  });
}