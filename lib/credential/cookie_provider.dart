// 凭证模块：匿名自动获取 ttwid（仅内存，不落盘）。
//
// 依据 design.md 2.2：
// - 请求 https://live.douyin.com/（桌面版 UA），从响应 set-cookie 提取并拼接为 Cookie 串；
// - 内存缓存 6 小时；若新响应不含 ttwid 且已有缓存，复用上次缓存。
import '../net/http_transport.dart';

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

/// 手动粘贴的凭证（prd F27 的兜底路径）：一旦设置就优先于匿名自动获取。
///
/// 明文只在内存中持有，密文由 CredentialStore 负责加密落盘；
/// 悬浮窗跑在独立引擎里，主 App 通过消息通道把它同步过去（见 overlay_launcher）。
String? _manualCookies;

/// 当前生效的手动凭证；null 表示走匿名自动获取。
///
/// 主 App 建窗、重排窗口时用它把凭证一并下发给悬浮窗引擎。
String? get manualCookies => _manualCookies;

/// 设置或清除手动凭证（传 null / 空串即回到匿名自动获取）。
void setManualCookies(String? cookies) {
  final String value = cookies?.trim() ?? '';
  _manualCookies = value.isEmpty ? null : value;
}

/// 提供匿名 Cookie 串（含 ttwid）。
class CookieProvider {
  CookieProvider({
    HttpTransport? transport,
    this.cacheTtl = const Duration(hours: 6),
    this.userAgent = defaultDesktopUserAgent,
    DateTime Function()? now,
  })  : _transport = transport ?? IoHttpTransport(),
        _now = now ?? DateTime.now;

  static final Uri _entryUri = Uri.parse('https://live.douyin.com/');

  final HttpTransport _transport;
  final Duration cacheTtl;
  final String userAgent;
  final DateTime Function() _now;

  DateTime? _cachedAt;
  String? _cachedCookies;

  /// 取得 Cookie 串。失败时抛 [CookieFetchException]。
  Future<String> getCookies() async {
    // 手动粘贴的凭证优先（prd F27）：用户已经明确指定，不再走匿名自动获取。
    final String? manual = _manualCookies;
    if (manual != null) return manual;

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