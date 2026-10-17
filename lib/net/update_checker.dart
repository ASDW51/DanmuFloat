// 检查更新（#166）：GitHub Releases 查询与节流口径。
//
// 三件事必须守住，否则「查更新」会变成新的故障源：
// - **不抛**：404 / 500 / 超时 / 畸形 JSON 一律返回 null 并记日志，调用方按「没查到」
//   处理（对齐 #109 的容错口径）；
// - **失败也算检查过**：时间戳照写，弱网下才不会每次回前台都重试一遍；
// - **纯函数在前**：版本比较、节流判断都不碰网络，单测直接覆盖。
import 'dart:convert';

import 'package:danmu_float/app/app_version.dart';
import 'package:danmu_float/net/http_transport.dart';
import 'package:flutter/foundation.dart';

/// GitHub 最新 Release 的接口地址。
const String latestReleaseApiUrl =
    'https://api.github.com/repos/ASDW51/DanmuFloat/releases/latest';

/// Release 页面（用户手动去翻也用得上）。
const String latestReleasePageUrl =
    'https://github.com/ASDW51/DanmuFloat/releases/latest';

/// 自动检查的最小间隔：日级足够（未认证的 GitHub API 是 60 次/小时/IP）。
const Duration updateCheckInterval = Duration(hours: 24);

/// 单次查询的超时：查不到就当没查到，不能拖住任何界面。
const Duration updateCheckTimeout = Duration(seconds: 12);

/// 是否该发起一次自动检查（#166 的节流口径）。
///
/// 关闭开关时永远为 false；从没查过时为 true；失败也会写时间戳，所以弱网下同样是
/// 24 小时一次，不会退化成「每次回前台都打一遍」。
bool shouldCheckForUpdate(
  int? lastCheckedAt,
  int now, {
  required bool enabled,
}) {
  if (!enabled) return false;
  if (lastCheckedAt == null) return true;
  return now - lastCheckedAt >= updateCheckInterval.inMilliseconds;
}

/// 一个 Release 里对用户有意义的信息。
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.name,
    required this.publishedAt,
    required this.notes,
    required this.pageUrl,
    this.apkUrl,
    this.sha256Url,
    this.apkSha256,
  });

  /// 去掉 `v` 前缀的版本号（与 [appVersion] 同口径，方便直接比较）。
  final String version;

  /// Release 标题。
  final String name;

  /// 发布时间（毫秒）；解析不出来为 null。
  final int? publishedAt;

  /// Release Notes（markdown 原文）。
  final String notes;

  /// Release 页面地址。
  final String pageUrl;

  /// 通用包下载地址；没有产物时为 null。
  final String? apkUrl;

  /// SHA256SUMS.txt 地址（用户可自行校验下载到的包）。
  final String? sha256Url;

  /// APK 的 sha256（GitHub 新版 API 的 asset.digest，形如 `sha256:...`）；没有时为 null。
  final String? apkSha256;

  /// 从 GitHub API 的响应体解析；任何畸形都返回 null，不抛。
  static ReleaseInfo? tryParse(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final Object? tag = decoded['tag_name'];
      if (tag is! String || tag.trim().isEmpty) return null;
      final String version = tag.trim().replaceFirst(
        RegExp(r'^[vV]'),
        '',
      );

      String? apkUrl;
      String? sha256Url;
      String? apkSha256;
      final Object? assets = decoded['assets'];
      if (assets is List) {
        for (final Object? item in assets) {
          if (item is! Map) continue;
          final Object? name = item['name'];
          final Object? url = item['browser_download_url'];
          if (name is! String || url is! String) continue;
          if (name == 'SHA256SUMS.txt') {
            sha256Url = url;
          } else if (name.endsWith('.apk')) {
            // 优先通用包：arm64 精简包在别的机型上装不上。
            if (apkUrl == null || name.contains('universal')) {
              apkUrl = url;
              final Object? digest = item['digest'];
              apkSha256 = digest is String && digest.startsWith('sha256:')
                  ? digest.substring('sha256:'.length)
                  : null;
            }
          }
        }
      }

      return ReleaseInfo(
        version: version,
        name: decoded['name'] is String ? decoded['name'] as String : 'v$version',
        publishedAt: _parseIsoMillis(decoded['published_at']),
        notes: decoded['body'] is String ? decoded['body'] as String : '',
        pageUrl: decoded['html_url'] is String
            ? decoded['html_url'] as String
            : latestReleasePageUrl,
        apkUrl: apkUrl,
        sha256Url: sha256Url,
        apkSha256: apkSha256,
      );
    } on Object catch (exception) {
      debugPrint('解析 Release 信息失败: $exception');
      return null;
    }
  }

  static int? _parseIsoMillis(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw)?.millisecondsSinceEpoch;
  }
}

/// 查询 GitHub 上的最新 Release。
class UpdateChecker {
  UpdateChecker({
    HttpTransport? transport,
    this.apiUrl = latestReleaseApiUrl,
    this.timeout = updateCheckTimeout,
  }) : _transport = transport ?? IoHttpTransport();

  final HttpTransport _transport;
  final String apiUrl;
  final Duration timeout;

  /// 拉取最新 Release；任何失败都返回 null（原因写日志，不打扰用户）。
  Future<ReleaseInfo?> fetchLatest() async {
    try {
      final HttpResponseData response = await _transport
          .get(
            Uri.parse(apiUrl),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
              // GitHub 要求带 UA，否则 403。
              'User-Agent': 'DanmuFloat',
            },
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        // 404 = 还没有 Release；403 = 限流；5xx = 服务端问题。都不该弹窗。
        debugPrint('检查更新失败：HTTP ${response.statusCode}');
        return null;
      }
      return ReleaseInfo.tryParse(response.body);
    } on Object catch (exception) {
      // 超时、DNS、TLS、非 UTF-8 正文（#109 的严格解码会抛）都收敛到这里。
      debugPrint('检查更新失败: $exception');
      return null;
    }
  }

  void close() => _transport.close();
}

/// 是否有新版本可比（[latest] 比当前 [current] 新）。
///
/// 当前版本是 `dev`（本地 / 未注入）时不提示：开发构建不该被更新提醒打扰。
bool hasNewerVersion(String latest, String current) {
  final String now = current.trim();
  // 未注入版本号的开发构建（dev）不提示更新：它比任何 Release 都「旧」，
  // 提醒只会变成噪音。
  if (now.isEmpty || now == 'dev') return false;
  return compareAppVersions(latest, now) > 0;
}
