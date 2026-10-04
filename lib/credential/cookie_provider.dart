// 凭证模块：匿名自动获取 ttwid（仅内存，不落盘）+ 按主播指定用户配置的凭证。
//
// 依据 design.md 2.2：
// - 请求 https://live.douyin.com/（桌面版 UA），从响应 set-cookie 提取并拼接为 Cookie 串；
// - 内存缓存 6 小时；若新响应不含 ttwid 且已有缓存，复用上次缓存。
import '../net/http_transport.dart';
import 'credential_store.dart';

/// 桌面版 Chrome UA，与参考实现一致。
const String defaultDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36';

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
    String? credentialCookies,
    DateTime Function()? now,
  })  : _transport = transport ?? IoHttpTransport(),
        _credentialCookies = normalizeCredentialCookies(credentialCookies),
        _now = now ?? DateTime.now;

  static final Uri _entryUri = Uri.parse('https://live.douyin.com/');

  final HttpTransport _transport;
  final Duration cacheTtl;
  final String userAgent;
  final DateTime Function() _now;

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
      // 新响应缺 ttwid：直接续期 1 小时后复用上次缓存（与参考实现一致）
      _cachedAt = cachedAt.add(const Duration(hours: 1));
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

  Future<String> _fetchCookies() async {
    final HttpResponseData response = await _transport.get(
      _entryUri,
      headers: <String, String>{'User-Agent': userAgent},
    );
    if (response.setCookie.isEmpty) {
      throw CookieFetchException('响应缺少 set-cookie，无法获取 ttwid');
    }
    final String cookies = joinCookieValues(response.setCookie);
    if (cookies.isEmpty) {
      throw CookieFetchException('set-cookie 解析结果为空，无法获取 ttwid');
    }
    return cookies;
  }
}