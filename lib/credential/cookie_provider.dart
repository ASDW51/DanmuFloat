// 凭证模块：匿名自动获取 ttwid（仅内存，不落盘）+ 按主播指定用户配置的凭证。
//
// 依据 design.md 2.2：
// - 请求 https://live.douyin.com/（桌面版 UA），从响应 set-cookie 提取并拼接为 Cookie 串；
// - 内存缓存 6 小时；若新响应不含 ttwid 且已有缓存，复用上次缓存。
import 'dart:async';

import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/net/http_transport.dart';

/// 桌面版 Chrome UA，与参考实现一致。
const String defaultDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36';

/// 匿名 ttwid 获取的超时阈值（#76）。
///
/// 取凭证是房间解析的第一步：这一步挂起同样会让栏位永久停在「解析房间…」，
/// 而且它与接口请求各自独立，两层都要有失败出口。
const Duration defaultCookieFetchTimeout = Duration(seconds: 8);

class CookieFetchException implements Exception {
  CookieFetchException(this.message);

  final String message;

  @override
  String toString() => 'CookieFetchException: $message';
}

/// 把 set-cookie 头列表拼成 Cookie 请求头（仅保留 `name=value`）。
String joinCookieValues(Iterable<String> setCookieValues) {
  final List<String> pairs = <String>[];
  for (final String raw in setCookieValues) {
    final String pair = raw.split(';').first.trim();
    if (pair.isNotEmpty) pairs.add(pair);
  }
  return pairs.join('; ');
}

/// 手动凭证的规范形式：去空白，空串按「未指定」处理。
String? normalizeCredentialCookies(String? cookies) {
  final String value = cookies?.trim() ?? '';
  return value.isEmpty ? null : value;
}

/// 当前生效的「主播 → 凭证」绑定快照（webRid → Cookie 串）。
///
/// 主 App 与悬浮窗跑在各自引擎里，各维护一份：
/// - 主 App 由首页在主播列表 / 凭证变化时重建（见 home_page）；
/// - 悬浮窗经消息通道收到主 App 下发的映射后写入（见 overlay_page）。
/// 未出现在映射里的主播一律走匿名自动获取。
Map<String, String> _roomCookieBindings = const <String, String>{};

/// 当前生效的主播凭证绑定（主 App 建窗 / 重排时下发给悬浮窗引擎）。
Map<String, String> get roomCookieBindings => _roomCookieBindings;

/// 取某个主播指定的凭证；未指定返回 null（走匿名自动获取）。
String? roomCookiesFor(String webRid) => _roomCookieBindings[webRid];

/// 覆盖当前主播凭证绑定；空 key / 空值一律丢弃。
void setRoomCookieBindings(Map<String, String> bindings) {
  _roomCookieBindings = Map<String, String>.unmodifiable(
    <String, String>{
      for (final MapEntry<String, String> entry in bindings.entries)
        if (entry.key.isNotEmpty && normalizeCredentialCookies(entry.value) != null)
          entry.key: entry.value.trim(),
    },
  );
}

/// 把「主播 → 凭证 id」的绑定解析成「webRid → Cookie 串」。
///
/// 未绑定或绑定的凭证已被删除的主播不会出现在结果里，按匿名自动获取连接。
Map<String, String> buildRoomCookieBindings({
  required Iterable<({String webRid, String? credentialId})> rooms,
  required Iterable<CredentialProfile> profiles,
}) {
  final Map<String, String> byId = <String, String>{
    for (final CredentialProfile profile in profiles)
      profile.id: profile.cookies,
  };
  return <String, String>{
    for (final ({String webRid, String? credentialId}) room in rooms)
      if (room.credentialId != null && byId[room.credentialId] != null)
        room.webRid: byId[room.credentialId]!,
  };
}

/// 提供 Cookie 串：默认匿名自动获取（含 ttwid），也可固定使用指定凭证。
class CookieProvider {
  CookieProvider({
    HttpTransport? transport,
    this.cacheTtl = const Duration(hours: 6),
    this.userAgent = defaultDesktopUserAgent,
    this.fetchTimeout = defaultCookieFetchTimeout,
    String? credentialCookies,
    DateTime Function()? now,
  })  : _transport = transport ?? IoHttpTransport(),
        _ownsTransport = transport == null,
        _credentialCookies = normalizeCredentialCookies(credentialCookies),
        _now = now ?? DateTime.now;

  static final Uri _entryUri = Uri.parse('https://live.douyin.com/');

  final HttpTransport _transport;

  /// [HttpTransport] 是否由本实例自建（#95）：只有自建的才由本实例关闭。
  final bool _ownsTransport;
  final Duration cacheTtl;
  final String userAgent;
  final DateTime Function() _now;

  /// 取匿名凭证的超时阈值（测试注入更短的值）。
  final Duration fetchTimeout;

  /// 固定的用户配置凭证；非空时优先于匿名自动获取，不再联网。
  final String? _credentialCookies;

  DateTime? _cachedAt;
  String? _cachedCookies;

  /// 取得 Cookie 串。失败时抛 [CookieFetchException]。
  Future<String> getCookies() async {
    // 主播指定了凭证：直接使用，不再走匿名自动获取（prd F27）。
    final String? credential = _credentialCookies;
    if (credential != null) return credential;

    final DateTime now = _now();
    final String? cached = _cachedCookies;
    final DateTime? cachedAt = _cachedAt;
    if (cached != null && cachedAt != null && now.difference(cachedAt) < cacheTtl) {
      return cached;
    }

    final String cookies = await _fetchCookies();

    if (!cookies.contains('ttwid') && cached != null && cachedAt != null) {
      // 新响应缺 ttwid：续期后复用上次缓存（与参考实现一致）。
      //
      // 续期必须基于**当前时间**（#80）：这个分支只在缓存已过期（now - cachedAt ≥ cacheTtl）
      // 时才会走到，若仍在旧时间戳上累加，续期结果几乎总是依旧过期——下一次调用立刻又发一次
      // 请求，每次只把时间戳往前挪 1 小时，要连续调用多次才收敛；服务端一段时间不返回 ttwid
      // （如风控降级）时就退化成每次取 Cookie 都联网，正是这段缓存想避免的事。
      _cachedAt = now.add(const Duration(hours: 1));
      return cached;
    }

    _cachedCookies = cookies;
    _cachedAt = now;
    return cookies;
  }

  /// 清空内存缓存。
  void clearCache() {
    _cachedCookies = null;
    _cachedAt = null;
  }

  /// 释放资源（#95）：清缓存，并关闭**自建**的传输层。
  ///
  /// 注入的 transport 归创建者管（对照仓库「谁 new 谁 close」的约定：首页 /
  /// 弹幕页 / 栏位各自关自己 new 的那份），这里若一并关掉，会把别人还在用的
  /// 连接池关掉。可重复调用。
  void close() {
    clearCache();
    if (_ownsTransport) _transport.close();
  }

  Future<String> _fetchCookies() async {
    final HttpResponseData response = await _requestEntry();
    if (response.setCookie.isEmpty) {
      throw CookieFetchException('响应缺少 set-cookie，无法获取 ttwid');
    }
    final String cookies = joinCookieValues(response.setCookie);
    if (cookies.isEmpty) {
      throw CookieFetchException('set-cookie 解析结果为空，无法获取 ttwid');
    }
    return cookies;
  }

  /// 请求入口页取 set-cookie；超时按取凭证失败处理（#76）。
  ///
  /// 不设阈值时这一步会永久挂起：调用方（房间解析）会一直等在「解析房间…」，
  /// 而它没有任何失败出口或重试入口。
  Future<HttpResponseData> _requestEntry() async {
    try {
      return await _transport
          .get(
            _entryUri,
            headers: <String, String>{'User-Agent': userAgent},
          )
          .timeout(fetchTimeout);
    } on TimeoutException {
      throw CookieFetchException(
        '获取匿名凭证超时（${fetchTimeout.inSeconds} 秒），请检查网络后重试',
      );
    }
  }
}