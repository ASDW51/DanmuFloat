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
  });
}