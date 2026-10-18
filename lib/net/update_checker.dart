// 检查更新（#166）：GitHub Releases 查询与节流口径。
//
// 三件事必须守住，否则「查更新」会变成新的故障源：
// - **不抛**：404 / 500 / 超时 / 畸形 JSON 一律收敛成结果对象，调用方按「没查到」
//   处理（对齐 #109 的容错口径）；
// - **失败也算检查过**：时间戳照写，弱网下才不会每次回前台都重试一遍；
// - **纯函数在前**：版本比较、节流判断、安装包挑选都不碰网络，单测直接覆盖。
import 'dart:convert';
import 'dart:ffi' show Abi;

import 'package:danmu_float/app/app_version.dart';
import 'package:danmu_float/net/http_transport.dart';
import 'package:flutter/foundation.dart';

/// GitHub 最新 Release 的接口地址。
///
/// 注意：这个端点**只返回已发布且非 prerelease 的 Release**——仓库里只有 draft 时
/// 会 404（不是鉴权问题，公开仓库无需 token）。
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

/// 检查更新失败的原因。
///
/// 分开是为了文案能说实话：**404 不是「网络不好」，而是「还没发布过版本」**——
/// 混成一句「检查失败」会让维护者以为客户端坏了。
enum UpdateCheckFailure {
  /// 没有失败。
  none,

  /// 仓库还没有已发布的 Release（接口 404；draft 与 prerelease 都不算）。
  noRelease,

  /// 触发了 GitHub 的限流（403 / 429）。
  rateLimited,

  /// 网络层失败：DNS、TLS、超时、连接被重置等。
  network,

  /// 服务端错误（5xx）。
  serverError,

  /// 拿到了响应但解析不出 Release（改了接口或代理返回了 HTML）。
  malformed,
}

/// 一次检查更新的结果。
@immutable
class UpdateCheckResult {
  const UpdateCheckResult.release(ReleaseInfo this.release)
    : failure = UpdateCheckFailure.none;

  const UpdateCheckResult.failure(this.failure) : release = null;

  /// 解析出的 Release；失败时为 null。
  final ReleaseInfo? release;

  /// 失败原因；成功时为 [UpdateCheckFailure.none]。
  final UpdateCheckFailure failure;

  bool get isSuccess => release != null;
}

/// 一个 Release 产物。
@immutable
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url, this.sha256});

  final String name;
  final String url;

  /// 产物校验值（GitHub asset 的 `digest` 去掉 `sha256:` 前缀）；没有时为 null。
  final String? sha256;
}

/// 当前进程的 ABI 标签（Android 的 ABI 目录名）。
///
/// 用 `dart:ffi` 的 [Abi.current] 判断「这台机器该装哪个包」，而不是按版本号猜：
/// 同一个版本会同时产出 `arm64-v8a` 拆分包与 `universal` 通用包，装哪个取决于
/// **设备与已装包的 ABI**，与版本号无关。非 Android（单测跑在桌面 VM 上）返回空串，
/// 调用方据此回落到通用包。
String androidAbiTag([Abi? abi]) {
  switch (abi ?? Abi.current()) {
    case Abi.androidArm64:
      return 'arm64-v8a';
    case Abi.androidArm:
      return 'armeabi-v7a';
    case Abi.androidX64:
      return 'x86_64';
    case Abi.androidIA32:
      return 'x86';
    default:
      return '';
  }
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
    this.assets = const <ReleaseAsset>[],
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

  /// 全部产物（含 SHA256SUMS.txt）。
  final List<ReleaseAsset> assets;

  /// 只含 APK 的产物。
  List<ReleaseAsset> get apkAssets => assets
      .where((ReleaseAsset asset) => asset.name.endsWith('.apk'))
      .toList(growable: false);

  /// SHA256SUMS.txt 的地址；没有该产物时为 null。
  String? get sha256Url {
    for (final ReleaseAsset asset in assets) {
      if (asset.name == 'SHA256SUMS.txt') return asset.url;
    }
    return null;
  }

  /// 按当前设备的 ABI 挑安装包（#166 修正）。
  ///
  /// 顺序：**同 ABI 的拆分包 → 通用包 → 唯一的那个包**。
  /// 之前一律优先通用包是错的：arm64 机器装 `universal` 要多下几十 MB，
  /// 而 32 位机器又装不了 arm64 拆分包——必须按 ABI 判断。
  ReleaseAsset? selectApk(String abiTag) {
    final List<ReleaseAsset> apks = apkAssets;
    if (apks.isEmpty) return null;
    final String tag = abiTag.trim();
    if (tag.isNotEmpty) {
      for (final ReleaseAsset asset in apks) {
        if (asset.name.contains(tag)) return asset;
      }
    }
    for (final ReleaseAsset asset in apks) {
      if (asset.name.contains('universal')) return asset;
    }
    // 只剩一个产物时（或命名不规范），装它总比不给入口强。
    return apks.length == 1 ? apks.first : null;
  }

  /// 从 GitHub API 的响应体解析；任何畸形都返回 null，不抛。
  static ReleaseInfo? tryParse(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final Object? tag = decoded['tag_name'];
      if (tag is! String || tag.trim().isEmpty) return null;
      final String version = tag.trim().replaceFirst(RegExp(r'^[vV]'), '');

      final List<ReleaseAsset> assets = <ReleaseAsset>[];
      final Object? rawAssets = decoded['assets'];
      if (rawAssets is List) {
        for (final Object? item in rawAssets) {
          if (item is! Map) continue;
          final Object? name = item['name'];
          final Object? url = item['browser_download_url'];
          if (name is! String || url is! String) continue;
          final Object? digest = item['digest'];
          assets.add(
            ReleaseAsset(
              name: name,
              url: url,
              sha256: digest is String && digest.startsWith('sha256:')
                  ? digest.substring('sha256:'.length)
                  : null,
            ),
          );
        }
      }

      return ReleaseInfo(
        version: version,
        name: decoded['name'] is String
            ? decoded['name'] as String
            : 'v$version',
        publishedAt: _parseIsoMillis(decoded['published_at']),
        notes: decoded['body'] is String ? decoded['body'] as String : '',
        pageUrl: decoded['html_url'] is String
            ? decoded['html_url'] as String
            : latestReleasePageUrl,
        assets: List<ReleaseAsset>.unmodifiable(assets),
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

  /// 拉取最新 Release；任何失败都收敛成 [UpdateCheckResult]，不抛。
  Future<UpdateCheckResult> check() async {
    final HttpResponseData response;
    try {
      response = await _transport
          .get(
            Uri.parse(apiUrl),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
              // GitHub 要求带 UA，否则 403。
              'User-Agent': 'DanmuFloat',
            },
          )
          .timeout(timeout);
    } on Object catch (exception) {
      // 超时、DNS、TLS、非 UTF-8 正文（#109 的严格解码会抛）都收敛到这里。
      debugPrint('检查更新失败（网络）: $exception');
      return const UpdateCheckResult.failure(UpdateCheckFailure.network);
    }

    final int code = response.statusCode;
    if (code == 404) {
      // 只有 draft / 没有正式 Release 时就是这个结果，不是故障。
      debugPrint('检查更新：仓库还没有已发布的 Release（404）');
      return const UpdateCheckResult.failure(UpdateCheckFailure.noRelease);
    }
    if (code == 403 || code == 429) {
      debugPrint('检查更新失败：GitHub 限流（$code）');
      return const UpdateCheckResult.failure(UpdateCheckFailure.rateLimited);
    }
    if (code >= 500) {
      debugPrint('检查更新失败：服务端错误（$code）');
      return const UpdateCheckResult.failure(UpdateCheckFailure.serverError);
    }
    if (code != 200) {
      debugPrint('检查更新失败：HTTP $code');
      return const UpdateCheckResult.failure(UpdateCheckFailure.network);
    }

    final ReleaseInfo? release = ReleaseInfo.tryParse(response.body);
    if (release == null) {
      return const UpdateCheckResult.failure(UpdateCheckFailure.malformed);
    }
    return UpdateCheckResult.release(release);
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
