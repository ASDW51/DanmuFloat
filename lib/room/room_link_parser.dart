// 房间 ID 解析（design.md 11.9）：把用户粘贴的内容归一为 webRid。
//
// 分两段：
// - 同步：纯数字 / live.douyin.com 链接 / 含 web_rid 的链接或页面文本，直接抽取；
// - 异步：v.douyin.com 短链无法本地展开，需联网跟随跳转后再从落地页里抽取。
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/net/http_transport.dart';

/// 直播间号（webRid）为纯数字，网页端常见 19 位，这里放宽到 4 位以上。
const String _digitPattern = r'\d{4,}';

final List<RegExp> _webRidPatterns = <RegExp>[
  RegExp('live\\.douyin\\.com/($_digitPattern)'),
  RegExp('[?&]web_rid=($_digitPattern)'),
  RegExp('"web_rid"\\s*:\\s*"?($_digitPattern)"?'),
];

/// 从文本中同步提取 webRid；提取不到时返回 null。
String? extractWebRid(String input) {
  final String text = input.trim();
  if (text.isEmpty) return null;
  if (RegExp('^$_digitPattern\$').hasMatch(text)) return text;
  for (final RegExp pattern in _webRidPatterns) {
    final String? value = pattern.firstMatch(text)?.group(1);
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// 文本中首个 http(s) 链接；分享文案常把链接夹在中文描述里。
Uri? firstHttpUri(String input) {
  final String? raw =
      _httpUriPattern.firstMatch(input)?.group(0);
  if (raw == null) return null;
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null) return null;
  return uri.host.contains('douyin.com') ? uri : null;
}

/// 匹配链接本体，遇到空白与中文标点即结束（分享文案里的链接常带尾随标点）。
final RegExp _httpUriPattern =
    RegExp(r'''https?://[^\s，。！？"'）】]+''');

/// 短链解析器：本地解析失败时联网跟随跳转。
class RoomLinkResolver {
  RoomLinkResolver({HttpTransport? transport, this.userAgent = defaultDesktopUserAgent})
      : _transport = transport ?? IoHttpTransport();

  final HttpTransport _transport;
  final String userAgent;

  /// 解析输入为 webRid；解析不到返回 null。
  ///
  /// 解析失败不是错误：调用方（添加主播表单）会退化成「按原文保存标识」，
  /// 所以这里网络异常也按 null 处理，不向上抛。
  Future<String?> resolve(String input) async {
    final String? local = extractWebRid(input);
    if (local != null) return local;

    final Uri? uri = firstHttpUri(input);
    if (uri == null) return null;
    try {
      final HttpResponseData response = await _transport.get(
        uri,
        headers: <String, String>{'User-Agent': userAgent},
      );
      // http 层默认跟随 3xx，落地页里带有直播间接跳信息。
      return extractWebRid(response.body);
    } on Object {
      return null;
    }
  }

  void close() => _transport.close();
}