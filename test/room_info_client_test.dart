import 'dart:async';

import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/net/http_transport.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/room/room_info_client.dart';
import 'package:danmu_float/sign/abogus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';

const String _liveJson = '''
{
  "status_code": 0,
  "data": {
    "room_status": 0,
    "user": {
      "nickname": "主播A",
      "sec_uid": "MS4wLjABAAAA",
      "avatar_thumb": { "url_list": ["https://cdn/avatar.jpg"] }
    },
    "data": [
      {
        "id_str": "7350000000000000001",
        "title": "今晚八点直播",
        "cover": { "url_list": ["https://cdn/cover.jpg"] }
      }
    ]
  }
}
''';

void main() {
  group('buildWebEnterParams', () {
    test('参数顺序与取值与参考实现一致', () {
      expect(
        buildWebEnterParams('123456789'),
        'aid=6383&live_id=1&device_platform=web&language=zh-CN&enter_from=web_live'
        '&cookie_enabled=true&screen_width=1920&screen_height=1080'
        '&browser_language=zh-CN&browser_platform=MacIntel&browser_name=Chrome'
        '&browser_version=108.0.0.0&web_rid=123456789&Room-Enter-User-Login-Ab=0'
        '&is_need_double_stream=false',
      );
    });
  });

  group('parseWebEnterResponse', () {
    test('在播：提取 liveId 与主播信息', () {
      final RoomInfo info = parseWebEnterResponse(_liveJson, webRid: '123456789');
      expect(info.living, isTrue);
      expect(info.isLiveRadio, isFalse);
      expect(info.webRid, '123456789');
      expect(info.liveId, '7350000000000000001');
      expect(info.owner, '主播A');
      expect(info.title, '今晚八点直播');
      expect(info.avatar, 'https://cdn/avatar.jpg');
      expect(info.cover, 'https://cdn/cover.jpg');
      expect(info.secUid, 'MS4wLjABAAAA');
      expect(info.api, RoomInfoApi.web);
    });

    test('room_status=1 判定为电台且仍在播', () {
      final RoomInfo info = parseWebEnterResponse(
        _liveJson.replaceFirst('"room_status": 0', '"room_status": 1'),
        webRid: '123456789',
      );
      expect(info.living, isTrue);
      expect(info.isLiveRadio, isTrue);
    });

    test('room_status=2 判定为未开播（liveId 仍照常返回）', () {
      final RoomInfo info = parseWebEnterResponse(
        _liveJson.replaceFirst('"room_status": 0', '"room_status": 2'),
        webRid: '123456789',
      );
      expect(info.living, isFalse);
    });

    test('status_code=30003（直播已结束）返回离线空结果', () {
      final RoomInfo info = parseWebEnterResponse(
        '{"status_code":30003,"data":{}}',
        webRid: '123456789',
      );
      expect(info.living, isFalse);
      expect(info.liveId, '');
      expect(info.api, RoomInfoApi.web);
    });

    test('其它异常 status_code 抛 RoomInfoException', () {
      expect(
        () => parseWebEnterResponse('{"status_code":400,"data":{}}', webRid: '1'),
        throwsA(isA<RoomInfoException>()),
      );
    });

    test('缺少房间数据抛 RoomInfoException', () {
      expect(
        () => parseWebEnterResponse(
          '{"status_code":0,"data":{"room_status":0,"data":[]}}',
          webRid: '1',
        ),
        throwsA(isA<RoomInfoException>()),
      );
    });

    test('空响应抛可读的 RoomInfoException，而非裸 FormatException', () {
      expect(
        () => parseWebEnterResponse('', webRid: '1'),
        throwsA(
          isA<RoomInfoException>().having(
            (RoomInfoException e) => e.toString(),
            'message',
            contains('空响应'),
          ),
        ),
      );
    });

    test('非 JSON 响应包装成 RoomInfoException', () {
      expect(
        () => parseWebEnterResponse('<html>验证</html>', webRid: '1'),
        throwsA(isA<RoomInfoException>()),
      );
    });
  });

  group('RoomInfoClient.fetchByWebRid', () {
    test('先取 Cookie，再带 cookie 与 ABogus 签名请求 web 接口', () async {
      const String userAgent = 'UA-TEST';
      final FakeTransport transport = FakeTransport((Uri uri, _) async {
        if (uri.path == '/') {
          return const HttpResponseData(
            statusCode: 200,
            body: '',
            setCookie: <String>['ttwid=t1; Path=/', 'x=1; Path=/'],
          );
        }
        return const HttpResponseData(statusCode: 200, body: _liveJson);
      });

      final RoomInfoClient client = RoomInfoClient(
        transport: transport,
        cookieProvider: CookieProvider(transport: transport),
        abogusFactory: () => Abogus(
          fingerprint: '1500|900|1530|980|0|0|0|0|1800|1000|1600|900|1500|900|24|24|Win32',
          userAgent: userAgent,
          now: () => 1758900005000,
          randomDouble: () => 0.5,
        ),
      );

      final RoomInfo info = await client.fetchByWebRid('123456789');

      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.toString(), 'https://live.douyin.com/');

      final Uri enterUri = transport.requests.last;
      expect(enterUri.path, '/webcast/room/web/enter/');
      expect(
        enterUri.query,
        startsWith('${buildWebEnterParams('123456789')}&a_bogus='),
      );
      expect(
        transport.requestHeaders.last['cookie'],
        'ttwid=t1; x=1',
      );
      expect(transport.requestHeaders.last['User-Agent'], userAgent);
      expect(info.liveId, '7350000000000000001');
    });

    test('指定凭证时直接使用，不再取匿名', () async {
      final FakeTransport transport = FakeTransport(
        (Uri uri, _) async =>
            const HttpResponseData(statusCode: 200, body: _liveJson),
      );
      final RoomInfoClient client = RoomInfoClient(
        transport: transport,
        cookieProvider: CookieProvider(transport: transport),
        abogusFactory: () => _testAbogus('UA-TEST'),
      );

      await client.fetchByWebRid(
        '123456789',
        credentialCookies: 'ttwid=user; msToken=abc',
      );

      expect(transport.requests, hasLength(1));
      expect(
        transport.requestHeaders.last['cookie'],
        'ttwid=user; msToken=abc',
      );
    });

    test('接口永不返回时按超时抛 RoomInfoException，不再永久挂住（#76）', () async {
      // 永不返回的接口：模拟 DNS 挂起 / 服务端接受连接后不响应。
      final Completer<HttpResponseData> pending = Completer<HttpResponseData>();
      final FakeTransport transport = FakeTransport((Uri uri, _) {
        if (uri.path == '/') {
          return Future<HttpResponseData>.value(
            const HttpResponseData(
              statusCode: 200,
              body: '',
              setCookie: <String>['ttwid=t1; Path=/'],
            ),
          );
        }
        return pending.future;
      });
      final RoomInfoClient client = RoomInfoClient(
        transport: transport,
        cookieProvider: CookieProvider(transport: transport),
        abogusFactory: () => _testAbogus('UA-TEST'),
        // 阈值取短值：让超时在用例内落地（否则 flutter_test 会以悬挂定时器判失败）。
        requestTimeout: const Duration(milliseconds: 30),
      );

      await expectLater(
        client.fetchByWebRid('123456789'),
        throwsA(
          isA<RoomInfoException>().having(
            (RoomInfoException error) => error.message,
            'message',
            contains('超时'),
          ),
        ),
      );
    });
    test('不传 cookieProvider 时内建实例复用同一个 transport（#95）', () async {
      final FakeTransport transport = FakeTransport((Uri uri, _) async {
        if (uri.path == '/') {
          return const HttpResponseData(
            statusCode: 200,
            body: '',
            setCookie: <String>['ttwid=t1; Path=/'],
          );
        }
        return const HttpResponseData(statusCode: 200, body: _liveJson);
      });
      final RoomInfoClient client = RoomInfoClient(
        transport: transport,
        abogusFactory: () => _testAbogus('UA-TEST'),
      );

      await client.fetchByWebRid('123456789');

      // 旧实现把构造入参 transport（默认路径下为 null）透传给内建 CookieProvider，
      // 后者会再建一个 HttpClient：取 ttwid 那一步就跑到真实网络上去了，
      // 这里只会看到 1 次请求。
      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.toString(), 'https://live.douyin.com/');

      client.close();
      expect(
        transport.closeCount,
        0,
        reason: '注入的 transport 归创建者管，close() 不能替别人关连接池',
      );
    });

    test('注入的 CookieProvider 不被 close() 关闭（#95）', () async {
      final FakeTransport transport = FakeTransport(
        (Uri uri, _) async =>
            const HttpResponseData(statusCode: 200, body: _liveJson),
      );
      final _CountingCookieProvider cookieProvider =
          _CountingCookieProvider(credentialCookies: 'ttwid=user');
      final RoomInfoClient client = RoomInfoClient(
        transport: transport,
        cookieProvider: cookieProvider,
        abogusFactory: () => _testAbogus('UA-TEST'),
      );

      client.close();

      expect(cookieProvider.closeCount, 0, reason: '注入的实例归创建者管');
      expect(transport.closeCount, 0);
    });
  });
}

/// 记录 close 次数的假 Cookie 提供者（#95）。
class _CountingCookieProvider extends CookieProvider {
  _CountingCookieProvider({super.credentialCookies});

  int closeCount = 0;

  @override
  void close() {
    closeCount++;
  }
}

/// 确定性 ABogus（时间与随机数固定），便于断言请求 URL。
Abogus _testAbogus(String userAgent) => Abogus(
      fingerprint: '1500|900|1530|980|0|0|0|0|1800|1000|1600|900|1500|900|24|24|Win32',
      userAgent: userAgent,
      now: () => 1758900005000,
      randomDouble: () => 0.5,
    );