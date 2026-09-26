// 房间 ID 解析：本地抽取各形态输入，短链走联网跳转。
import 'package:danmu_float/net/http_transport.dart';
import 'package:danmu_float/room/room_link_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_transport.dart';

void main() {
  group('extractWebRid', () {
    test('纯数字直接作为 webRid', () {
      expect(extractWebRid('7350000000000000001'), '7350000000000000001');
      expect(extractWebRid('  123456  '), '123456');
    });

    test('过短的纯数字不算直播间号', () {
      expect(extractWebRid('123'), isNull);
      expect(extractWebRid(''), isNull);
      expect(extractWebRid('abc'), isNull);
    });

    test('直播间链接取出路径中的 webRid', () {
      expect(
        extractWebRid('https://live.douyin.com/7350000000000000001'),
        '7350000000000000001',
      );
      expect(
        extractWebRid('https://live.douyin.com/123456?enter_from=web_live'),
        '123456',
      );
    });

    test('分享文案里夹带的链接也能取出', () {
      expect(
        extractWebRid('快来看这个直播间 https://live.douyin.com/123456 一起来'),
        '123456',
      );
    });

    test('带 web_rid 查询参数或页面文本可取出', () {
      expect(
        extractWebRid('https://live.douyin.com/webcast/room/web/enter/?web_rid=999888'),
        '999888',
      );
      expect(extractWebRid('{"web_rid":"123456"}'), '123456');
    });

    test('无直播间号信息时返回 null', () {
      expect(extractWebRid('https://v.douyin.com/iABC123/'), isNull);
      expect(extractWebRid('https://www.douyin.com/user/MS4wLjABAAAA'), isNull);
    });
  });

  group('firstHttpUri', () {
    test('取出分享文案里的抖音链接', () {
      final Uri? uri = firstHttpUri('分享 https://v.douyin.com/iABC123/ 快来看');
      expect(uri?.host, 'v.douyin.com');
    });

    test('非抖音链接与无链接文本返回 null', () {
      expect(firstHttpUri('https://example.com/x'), isNull);
      expect(firstHttpUri('没有链接'), isNull);
    });
  });

  group('RoomLinkResolver', () {
    test('本地可解析时不发起网络请求', () async {
      final FakeTransport transport =
          FakeTransport((Uri uri, Map<String, String> headers) async =>
              throw StateError('不应发起请求'));
      final RoomLinkResolver resolver = RoomLinkResolver(transport: transport);

      expect(await resolver.resolve('https://live.douyin.com/123456'), '123456');
      expect(transport.requests, isEmpty);
    });

    test('短链联网跟随跳转后从落地页提取 webRid', () async {
      final FakeTransport transport =
          FakeTransport((Uri uri, Map<String, String> headers) async =>
              const HttpResponseData(
                statusCode: 200,
                body: '<html><a href="https://live.douyin.com/555666">进入直播间</a></html>',
              ));
      final RoomLinkResolver resolver = RoomLinkResolver(transport: transport);

      expect(await resolver.resolve('https://v.douyin.com/iABC123/'), '555666');
      expect(transport.requests.single.host, 'v.douyin.com');
      // 落地页需要桌面 UA，否则可能被重定向到验证页。
      expect(transport.requestHeaders.single['User-Agent'], isNotEmpty);
    });

    test('落地页是用户主页（无 webRid）时返回 null', () async {
      final FakeTransport transport =
          FakeTransport((Uri uri, Map<String, String> headers) async =>
              const HttpResponseData(
                statusCode: 200,
                body: '<html>"sec_uid":"MS4wLjABAAAA"</html>',
              ));
      final RoomLinkResolver resolver = RoomLinkResolver(transport: transport);

      expect(await resolver.resolve('https://v.douyin.com/iABC123/'), isNull);
    });

    test('网络异常按解析失败处理，不向上抛', () async {
      final FakeTransport transport =
          FakeTransport((Uri uri, Map<String, String> headers) async =>
              throw const SocketExceptionStub());
      final RoomLinkResolver resolver = RoomLinkResolver(transport: transport);

      expect(await resolver.resolve('https://v.douyin.com/iABC123/'), isNull);
    });

    test('既不是数字也不是抖音链接时直接失败且不联网', () async {
      final FakeTransport transport =
          FakeTransport((Uri uri, Map<String, String> headers) async =>
              throw StateError('不应发起请求'));
      final RoomLinkResolver resolver = RoomLinkResolver(transport: transport);

      expect(await resolver.resolve('这不是链接'), isNull);
      expect(transport.requests, isEmpty);
    });
  });
}

/// 模拟网络异常（避免为造异常引入 dart:io 依赖）。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => '网络不可用';
}