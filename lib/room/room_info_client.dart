// 房间信息接口客户端（web 通道）。
//
// 依据 design.md 11.8 / 11.9 与参考实现 DouYinRecorder/src/douyin_api.ts 的 getRoomInfoByWeb：
// - 接口：GET https://live.douyin.com/webcast/room/web/enter/
// - 需 ttwid Cookie + ABogus 签名
// - 开播判定：room_status ∈ {0,1}（1 为电台）；status_code=30003 表示直播已结束
//
// 说明：本期仅实现 web 通道；webHTML / mobile / userHTML 与负载均衡按 11.8 后续补齐。
import 'dart:convert';

import '../credential/cookie_provider.dart';
import '../net/http_transport.dart';
import '../sign/abogus.dart';
import 'room_info.dart';

/// 组装 webcast/room/web/enter 的查询参数。
///
/// 顺序即签名字段顺序（ABogus 对整个参数字符串哈希），不得调整；
/// 取值与参考实现逐项一致。
String buildWebEnterParams(String webRid) {
  final List<String> pairs = <String>[
    'aid=6383',
    'live_id=1',
    'device_platform=web',
    'language=zh-CN',
    'enter_from=web_live',
    'cookie_enabled=true',
    'screen_width=1920',
    'screen_height=1080',
    'browser_language=zh-CN',
    'browser_platform=MacIntel',
    'browser_name=Chrome',
    'browser_version=108.0.0.0',
    'web_rid=$webRid',
    'Room-Enter-User-Login-Ab=0',
    'is_need_double_stream=false',
  ];
  return pairs.join('&');
}

/// 解析 web 接口响应体。独立为顶层函数以便离线单测。
RoomInfo parseWebEnterResponse(String body, {required String webRid}) {
  final String trimmed = body.trim();
  if (trimmed.isEmpty) {
    // 接口在 Cookie 缺 ttwid / 被风控时会以 200 + 空 body 静默失败。
    throw RoomInfoException('接口返回空响应，Cookie 可能缺少有效 ttwid 或被风控拦截');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException catch (error) {
    throw RoomInfoException('响应不是合法 JSON：${error.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw RoomInfoException('响应不是合法 JSON 对象');
  }

  final int statusCode = asInt(decoded['status_code']);
  if (statusCode == 30003) {
    // 直播已结束
    return RoomInfo.offline(webRid: webRid, api: RoomInfoApi.web);
  }
  if (statusCode != 0) {
    throw RoomInfoException('接口返回异常 status_code=$statusCode');
  }

  final Object? data = decoded['data'];
  if (data is! Map<String, dynamic>) {
    throw RoomInfoException('响应缺少 data 字段');
  }

  final Object? rooms = data['data'];
  if (rooms is! List || rooms.isEmpty || rooms.first is! Map) {
    throw RoomInfoException('响应未返回房间数据');
  }
  final Map<String, dynamic> room = _asMap(rooms.first)!;
  final Map<String, dynamic> user = _asMap(data['user']) ?? <String, dynamic>{};

  final int roomStatus = asInt(data['room_status']);
  return RoomInfo(
    living: roomStatus == 0 || roomStatus == 1,
    isLiveRadio: roomStatus == 1,
    webRid: webRid,
    liveId: asString(room['id_str']),
    owner: asString(user['nickname']),
    title: asString(room['title']),
    avatar: firstUrlFromImage(user['avatar_thumb']),
    cover: firstUrlFromImage(room['cover']),
    secUid: asString(user['sec_uid']),
    api: RoomInfoApi.web,
  );
}

/// 房间信息客户端。
class RoomInfoClient {
  RoomInfoClient({
    HttpTransport? transport,
    CookieProvider? cookieProvider,
    Abogus Function()? abogusFactory,
  })  : _transport = transport ?? IoHttpTransport(),
        _cookieProvider =
            cookieProvider ?? CookieProvider(transport: transport),
        _abogusFactory = abogusFactory ?? Abogus.new;

  static const String _enterPath = '/webcast/room/web/enter/';

  final HttpTransport _transport;
  final CookieProvider _cookieProvider;
  final Abogus Function() _abogusFactory;

  /// 由 webRid 取房间信息（含 liveId）。
  ///
  /// [credentialCookies] 为主播指定的凭证（见 CookieProvider）；不传时走匿名自动获取。
  Future<RoomInfo> fetchByWebRid(
    String webRid, {
    String? credentialCookies,
  }) async {
    final String cookies = normalizeCredentialCookies(credentialCookies) ??
        await _cookieProvider.getCookies();
    final AbogusResult abogus =
        _abogusFactory().sign(buildWebEnterParams(webRid));
    final Uri uri =
        Uri.parse('https://live.douyin.com$_enterPath?${abogus.query}');
    final HttpResponseData response = await _transport.get(
      uri,
      headers: <String, String>{
        'cookie': cookies,
        'User-Agent': abogus.userAgent,
      },
    );
    return parseWebEnterResponse(response.body, webRid: webRid);
  }

  void close() => _transport.close();
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return null;
}

/// 解析 [Image].url_list 的首个非空 URL。
String firstUrlFromImage(Object? image) {
  final Map<String, dynamic>? map = _asMap(image);
  if (map == null) return '';
  final Object? urlList = map['url_list'];
  if (urlList is! List) return '';
  for (final Object? url in urlList) {
    if (url is String && url.isNotEmpty) return url;
  }
  return '';
}

int asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String asString(Object? value) {
  if (value == null) return '';
  return value is String ? value : value.toString();
}