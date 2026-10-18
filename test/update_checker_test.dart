// 检查更新（#166）：节流口径、Release 解析与「失败一律不抛」。
//
// 这里钉的是「查不到更新时 App 必须一切照旧」：限流、超时、畸形 JSON、非 200 都只能
// 收敛成失败结果，绝不能把异常抛给设置页或启动链路；失败原因还要分得清
// （404 = 还没发布版本，不是网络坏了）。
import 'dart:ffi' show Abi;

import 'package:danmu_float/net/http_transport.dart';
import 'package:danmu_float/net/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定应答的假 transport。
class _FakeTransport implements HttpTransport {
  _FakeTransport({
    this.statusCode = 200,
    this.body = '{}',
    this.delay = Duration.zero,
    this.throwOnGet = false,
  });

  final int statusCode;
  final String body;
  final Duration delay;
  final bool throwOnGet;
  int calls = 0;

  @override
  Future<HttpResponseData> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    calls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (throwOnGet) throw StateError('boom');
    return HttpResponseData(statusCode: statusCode, body: body);
  }

  @override
  void close() {}
}

const String _validBody = '''
{
  "tag_name": "v0.2.0",
  "name": "0.2.0",
  "published_at": "2026-10-01T12:30:00Z",
  "body": "- 修复悬浮窗白底白字\\n- 新增检查更新",
  "html_url": "https://github.com/ASDW51/DanmuFloat/releases/tag/v0.2.0",
  "assets": [
    {"name": "DanmuFloat-v0.2.0-arm64-v8a.apk", "browser_download_url": "https://example.com/arm64.apk", "digest": "sha256:armhash"},
    {"name": "DanmuFloat-v0.2.0-universal.apk", "browser_download_url": "https://example.com/universal.apk", "digest": "sha256:abcdef"},
    {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"}
  ]
}
''';

void main() {
  group('shouldCheckForUpdate（#166）', () {
    test('开关关闭时永远不查', () {
      expect(shouldCheckForUpdate(null, 1000, enabled: false), isFalse);
      expect(shouldCheckForUpdate(0, 999999999999, enabled: false), isFalse);
    });

    test('从没查过就要查一次', () {
      expect(shouldCheckForUpdate(null, 1000, enabled: true), isTrue);
    });

    test('24 小时内不重复查，超过才查', () {
      const int now = 1000000000000;
      expect(
        shouldCheckForUpdate(now - 3600000, now, enabled: true),
        isFalse,
        reason: '一小时前刚查过，不该再打一次 GitHub',
      );
      expect(
        shouldCheckForUpdate(
          now - updateCheckInterval.inMilliseconds + 1,
          now,
          enabled: true,
        ),
        isFalse,
      );
      expect(
        shouldCheckForUpdate(
          now - updateCheckInterval.inMilliseconds,
          now,
          enabled: true,
        ),
        isTrue,
      );
    });
  });

  group('ReleaseInfo.tryParse（#166）', () {
    test('解析出版本号、时间、说明与产物地址', () {
      final ReleaseInfo? info = ReleaseInfo.tryParse(_validBody);
      expect(info, isNotNull);
      expect(info!.version, '0.2.0', reason: 'v 前缀要去掉，才能与当前版本比较');
      expect(info.name, '0.2.0');
      expect(info.publishedAt, isNotNull);
      expect(info.notes, contains('检查更新'));
      expect(info.pageUrl, contains('/releases/tag/v0.2.0'));
      expect(info.apkAssets, hasLength(2), reason: 'SHA256SUMS.txt 不算安装包');
      // 解析层只负责把产物拆出来；「挑哪个包」由 chooseApk 决定（下面单独一组）。
      expect(
        info.apkAssets.map((ReleaseAsset a) => a.name),
        containsAll(<String>[
          'DanmuFloat-v0.2.0-arm64-v8a.apk',
          'DanmuFloat-v0.2.0-universal.apk',
        ]),
      );
      expect(
        info.apkAssets
            .firstWhere((ReleaseAsset a) => a.name.contains('arm64'))
            .sha256,
        'armhash',
        reason: 'digest 的 sha256: 前缀要去掉',
      );
      expect(info.sha256Url, 'https://example.com/SHA256SUMS.txt');
    });

    test('缺 tag_name / 畸形 JSON / 非对象一律返回 null，不抛', () {
      expect(ReleaseInfo.tryParse('not json'), isNull);
      expect(ReleaseInfo.tryParse('[]'), isNull);
      expect(ReleaseInfo.tryParse('{"name":"x"}'), isNull);
      expect(ReleaseInfo.tryParse('{"tag_name":""}'), isNull);
      expect(ReleaseInfo.tryParse('{"tag_name":123}'), isNull);
    });

    test('没有产物时地址为空，不影响其它字段', () {
      final ReleaseInfo? info = ReleaseInfo.tryParse(
        '{"tag_name":"v1.0.0","html_url":"https://example.com/r"}',
      );
      expect(info, isNotNull);
      // matcher 不做类型提升，取一次非空引用再用。
      final ReleaseInfo parsed = info!;
      expect(parsed.apkAssets, isEmpty);
      expect(
        parsed.chooseApk(buildAbi: '', deviceAbi: 'arm64-v8a').asset,
        isNull,
      );
      expect(parsed.sha256Url, isNull);
      expect(parsed.notes, isEmpty);
      expect(parsed.publishedAt, isNull);
    });
  });

  group('UpdateChecker.check（#166）', () {
    test('200 + 合法 JSON 返回 ReleaseInfo', () async {
      final _FakeTransport transport = _FakeTransport(body: _validBody);
      final UpdateChecker checker = UpdateChecker(transport: transport);
      final UpdateCheckResult result = await checker.check();
      expect(result.isSuccess, isTrue);
      expect(result.release?.version, '0.2.0');
      expect(transport.calls, 1);
    });

    test('404 表示「还没有已发布的版本」，不是网络故障', () async {
      final UpdateChecker checker = UpdateChecker(
        transport: _FakeTransport(statusCode: 404),
      );
      final UpdateCheckResult result = await checker.check();
      expect(result.release, isNull);
      expect(
        result.failure,
        UpdateCheckFailure.noRelease,
        reason: '仓库只有 draft Release 时就是 404，文案不能写成「网络不好」',
      );
    });

    test('403 / 429 归为限流', () async {
      for (final int code in <int>[403, 429]) {
        final UpdateCheckResult result = await UpdateChecker(
          transport: _FakeTransport(statusCode: code),
        ).check();
        expect(result.failure, UpdateCheckFailure.rateLimited, reason: 'HTTP $code');
      }
    });

    test('5xx 归为服务端错误', () async {
      for (final int code in <int>[500, 502]) {
        final UpdateCheckResult result = await UpdateChecker(
          transport: _FakeTransport(statusCode: code),
        ).check();
        expect(result.failure, UpdateCheckFailure.serverError, reason: 'HTTP $code');
      }
    });

    test('其它非 200（如 301 未跟随）归为网络失败', () async {
      final UpdateCheckResult result = await UpdateChecker(
        transport: _FakeTransport(statusCode: 301),
      ).check();
      expect(result.failure, UpdateCheckFailure.network);
    });

    test('超时返回网络失败', () async {
      final UpdateCheckResult result = await UpdateChecker(
        transport: _FakeTransport(
          body: _validBody,
          delay: const Duration(milliseconds: 80),
        ),
        timeout: const Duration(milliseconds: 10),
      ).check();
      expect(result.release, isNull);
      expect(result.failure, UpdateCheckFailure.network);
    });

    test('transport 抛异常（DNS / TLS / 非 UTF-8 解码）返回网络失败', () async {
      final UpdateCheckResult result = await UpdateChecker(
        transport: _FakeTransport(throwOnGet: true),
      ).check();
      expect(result.failure, UpdateCheckFailure.network);
    });

    test('200 但正文畸形归为解析失败', () async {
      final UpdateCheckResult result = await UpdateChecker(
        transport: _FakeTransport(body: '<html>oops</html>'),
      ).check();
      expect(result.failure, UpdateCheckFailure.malformed);
    });
  });

  group('挑安装包：打包标识优先（#175）', () {
    const List<ReleaseAsset> assets = <ReleaseAsset>[
      ReleaseAsset(
        name: 'DanmuFloat-v0.2.0-arm64-v8a.apk',
        url: 'https://example.com/arm64.apk',
        sha256: 'armhash',
      ),
      ReleaseAsset(
        name: 'DanmuFloat-v0.2.0-universal.apk',
        url: 'https://example.com/universal.apk',
        sha256: 'unihash',
      ),
      ReleaseAsset(
        name: 'SHA256SUMS.txt',
        url: 'https://example.com/SHA256SUMS.txt',
      ),
    ];
    const ReleaseInfo release = ReleaseInfo(
      version: '0.2.0',
      name: '0.2.0',
      publishedAt: null,
      notes: '',
      pageUrl: 'https://example.com/r',
      assets: assets,
    );

    test('装了通用包就继续给通用包，不被设备 ABI 带跑', () {
      final ApkChoice choice = release.chooseApk(
        buildAbi: 'universal',
        deviceAbi: 'arm64-v8a',
      );
      expect(
        choice.asset?.url,
        'https://example.com/universal.apk',
        reason: '这就是「检测不准」的根因：设备是 arm64，但用户装的是通用包',
      );
      expect(choice.match, ApkMatch.buildMarker);
    });

    test('装了 arm64 拆分包就给拆分包', () {
      final ApkChoice choice = release.chooseApk(
        buildAbi: 'arm64-v8a',
        deviceAbi: 'universal',
      );
      expect(choice.asset?.url, 'https://example.com/arm64.apk');
      expect(choice.match, ApkMatch.buildMarker);
    });

    test('没有标识（老版本）时退回设备 ABI', () {
      final ApkChoice choice = release.chooseApk(
        buildAbi: '',
        deviceAbi: 'arm64-v8a',
      );
      expect(choice.asset?.url, 'https://example.com/arm64.apk');
      expect(choice.match, ApkMatch.deviceAbi);
    });

    test('设备 ABI 也没有对应产物时给通用包', () {
      final ApkChoice choice = release.chooseApk(
        buildAbi: '',
        deviceAbi: 'armeabi-v7a',
      );
      expect(choice.asset?.url, 'https://example.com/universal.apk');
      expect(choice.match, ApkMatch.universal);
    });

    test('标识写了产物里没有的值，仍然按设备 ABI 兜底', () {
      final ApkChoice choice = release.chooseApk(
        buildAbi: 'x86_64',
        deviceAbi: 'arm64-v8a',
      );
      expect(choice.asset?.url, 'https://example.com/arm64.apk');
      expect(choice.match, ApkMatch.deviceAbi);
    });

    test('只有单一产物时就用它；没有产物时返回 none', () {
      const ReleaseInfo single = ReleaseInfo(
        version: '0.2.0',
        name: 'x',
        publishedAt: null,
        notes: '',
        pageUrl: 'https://example.com/r',
        assets: <ReleaseAsset>[
          ReleaseAsset(name: 'DanmuFloat-v0.2.0.apk', url: 'https://example.com/a.apk'),
        ],
      );
      final ApkChoice onlyOne = single.chooseApk(
        buildAbi: '',
        deviceAbi: 'arm64-v8a',
      );
      expect(onlyOne.asset?.url, 'https://example.com/a.apk');
      expect(onlyOne.match, ApkMatch.onlyOne);

      const ReleaseInfo none = ReleaseInfo(
        version: '0.2.0',
        name: 'x',
        publishedAt: null,
        notes: '',
        pageUrl: 'https://example.com/r',
      );
      final ApkChoice empty = none.chooseApk(buildAbi: '', deviceAbi: '');
      expect(empty.asset, isNull);
      expect(empty.match, ApkMatch.none);
    });

    test('androidAbiTag 把 FFI 的 Abi 映射成 ABI 目录名', () {
      expect(androidAbiTag(Abi.androidArm64), 'arm64-v8a');
      expect(androidAbiTag(Abi.androidArm), 'armeabi-v7a');
      expect(androidAbiTag(Abi.androidX64), 'x86_64');
      expect(androidAbiTag(Abi.androidIA32), 'x86');
      expect(
        androidAbiTag(Abi.linuxX64),
        isEmpty,
        reason: '非 Android 平台没有 ABI 目录名，调用方据此回落通用包',
      );
    });
  });

  group('hasNewerVersion（#166）', () {
    test('比当前新才算更新', () {
      expect(hasNewerVersion('0.2.0', '0.1.0'), isTrue);
      expect(hasNewerVersion('0.1.0', '0.1.0'), isFalse);
      expect(hasNewerVersion('0.1.0', '0.2.0'), isFalse);
    });

    test('当前是 dev（未注入版本号）时不提示更新', () {
      expect(hasNewerVersion('9.9.9', 'dev'), isFalse);
      expect(hasNewerVersion('9.9.9', ''), isFalse);
    });
  });
}
