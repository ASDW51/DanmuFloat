// 房间信息接口客户端（web 通道）。
//
// 依据 design.md 11.8 / 11.9 与参考实现 DouYinRecorder/src/douyin_api.ts 的 getRoomInfoByWeb：
// - 接口：GET https://live.douyin.com/webcast/room/web/enter/
// - 需 ttwid Cookie + ABogus 签名
// - 开播判定：room_status ∈ {0,1}（1 为电台）；status_code=30003 表示直播已结束
//
// 说明：本期仅实现 web 通道；webHTML / mobile / userHTML 与负载均衡按 11.8 后续补齐。
import 'dart:async';
import 'dart:convert';

import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/net/http_transport.dart';
import 'package:danmu_float/room/room_info.dart';
import 'package:danmu_float/sign/abogus.dart';

/// 房间信息接口的超时阈值（#76）。
///
/// 超过即抛 [RoomInfoException]：接口挂起（DNS 挂起 / 建连无响应 / 服务端不返回）时
/// 会话会永久停在「解析房间…」，而该阶段没有任何重试出口，用户只能关窗或杀进程。
/// 阈值与 UX-03 的短链解析超时同量级。
const Duration defaultRoomInfoTimeout = Duration(seconds: 8);

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
    this.requestTimeout = defaultRoomInfoTimeout,
  })  : _transport = transport ?? IoHttpTransport(),
        _ownsTransport = transport == null,
        _ownsCookieProvider = cookieProvider == null,
        _abogusFactory = abogusFactory ?? Abogus.new {
    // 内建 CookieProvider 复用同一个 transport（#95）。旧写法把**构造入参** transport
    // （默认路径下为 null）透传下去，CookieProvider 会自己再建一个 —— 一次
    // `RoomInfoClient()` 就落地两个 HttpClient 与两份连接池，且其中一个无人关闭。
    _cookieProvider = cookieProvider ?? CookieProvider(transport: _transport);
  }

  static const String _enterPath = '/webcast/room/web/enter/';

  final HttpTransport _transport;
  late final CookieProvider _cookieProvider;
  final Abogus Function() _abogusFactory;

  /// [HttpTransport] / [CookieProvider] 是否由本实例自建（#95）。
  ///
  /// 注入的那份归创建者管（对照首页 `_roomInfoClient`、栏位 `widget.roomInfoClient`
  /// 的「谁 new 谁 close」约定），[close] 不能替别人关连接池。
  final bool _ownsTransport;
  final bool _ownsCookieProvider;

  /// 接口超时阈值（测试注入更短的值）。
  final Duration requestTimeout;

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
    final HttpResponseData response =
        await _requestEnter(uri, cookies, abogus.userAgent);
    return parseWebEnterResponse(response.body, webRid: webRid);
  }

  /// 请求房间信息接口；超时按接口失败处理（#76）。
  ///
  /// 超时必须变成异常而不是继续等待：会话拿到异常才会推进到 error 阶段，
  /// 「解析房间…」上原本不存在的重试入口才会出现。
  Future<HttpResponseData> _requestEnter(
    Uri uri,
    String cookies,
    String userAgent,
  ) async {
    try {
      return await _transport
          .get(
            uri,
            headers: <String, String>{
              'cookie': cookies,
              'User-Agent': userAgent,
            },
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw RoomInfoException(
        '房间信息接口超时（${requestTimeout.inSeconds} 秒），请检查网络后重试',
      );
    }
  }

  /// 释放自建资源（#95）：内建 [CookieProvider] 与自建传输。
  ///
  /// 注入的实例一律不动——它们由创建者负责关闭（首页自建自关；栏位 / 会话里注入的
  /// 假实现归测试管）。可重复调用。
  void close() {
    if (_ownsCookieProvider) _cookieProvider.close();
    if (_ownsTransport) _transport.close();
  }
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