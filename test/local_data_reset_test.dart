// 「清除所有本地数据」（prd F26）：主播列表、样式偏好、合规状态、凭证一并清空。
//
// 重点覆盖失败可见性（#92）：原先六项全走空体 _ignoreErrors，删不掉既没有日志
// 也没有返回值，调用方照常宣布「已恢复初始状态」；合规状态残留更会让下次冷启动
// 直接跳过免责声明页。
import 'dart:io';

import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/local_data_reset.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBackend implements CredentialBackend {
  FakeBackend(this.stored);

  String? stored;

  /// 非空时删除抛错，模拟 Keystore / 磁盘层面的删除失败。
  Object? deleteError;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String value) async => stored = value;

  @override
  Future<void> delete() async {
    final Object? error = deleteError;
    if (error != null) throw error;
    stored = null;
  }
}

/// 模拟「删除返回了但文件还在」：clear 什么都不做，用来验证删除后复核与兜底覆写。
class _IgnoringClearCompliance extends ComplianceStore {
  _IgnoringClearCompliance({required super.directoryResolver});

  @override
  Future<void> clear() async {}
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('danmu_reset');
  });

  tearDown(() async {
    setRoomCookieBindings(const <String, String>{});
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  /// 六项全部注入同一个临时目录：默认构造会走 path_provider 原生通道，
  /// 纯 Dart 单测里取不到目录（会被误报成「清除失败」）。
  LocalDataReset resetWith({
    RoomStore? rooms,
    OverlayPrefsStore? prefs,
    ComplianceStore? compliance,
    CredentialStore? credential,
  }) {
    Future<Directory> resolver() async => directory;
    return LocalDataReset(
      roomStore: rooms ?? RoomStore(directoryResolver: resolver),
      prefsStore: prefs ?? OverlayPrefsStore(directoryResolver: resolver),
      complianceStore: compliance ?? ComplianceStore(directoryResolver: resolver),
      credentialStore: credential ?? CredentialStore(backend: FakeBackend(null)),
      filterStore: FilterStore(directoryResolver: resolver),
      themeStore: ThemeStore(directoryResolver: resolver),
    );
  }

  test('清除所有本地数据后全部落盘内容回到初始状态', () async {
    Future<Directory> resolver() async => directory;
    final RoomStore rooms = RoomStore(directoryResolver: resolver);
    final OverlayPrefsStore prefs = OverlayPrefsStore(directoryResolver: resolver);
    final ComplianceStore compliance = ComplianceStore(directoryResolver: resolver);
    final FakeBackend backend = FakeBackend('ttwid=manual');
    final CredentialStore credential = CredentialStore(backend: backend);
    // 旧版单份明文读回后视为已配置一份凭证。
    expect(await credential.load(), isTrue);
    expect(credential.hasProfiles, isTrue);

    await rooms.save(const <ManagedRoom>[
      ManagedRoom(webRid: '123', owner: '主播A', addedAt: 1),
    ]);
    await prefs.save(const OverlayPrefs(webRids: <String>['123']));
    await compliance.save(const ComplianceState(disclaimerAccepted: true));

    final LocalDataResetResult result = await resetWith(
      rooms: rooms,
      prefs: prefs,
      compliance: compliance,
      credential: credential,
    ).clearAll();

    expect(result.clean, isTrue, reason: '全部成功时不该报任何失败项');
    expect(result.complianceRemains, isFalse);
    expect(await rooms.load(), isEmpty);
    expect((await prefs.load()).webRids, isEmpty);
    expect((await compliance.load()).disclaimerAccepted, isFalse);
    expect(await compliance.exists(), isFalse);
    expect(backend.stored, isNull);
    expect(credential.hasProfiles, isFalse);
  });

  test('单项清除失败不阻断其余项，且失败项被报告出来（#92）', () async {
    Future<Directory> resolver() async => directory;
    final RoomStore rooms = RoomStore(directoryResolver: resolver);
    final OverlayPrefsStore prefs = OverlayPrefsStore(directoryResolver: resolver);
    final FakeBackend backend = FakeBackend('ttwid=manual');

    await prefs.save(const OverlayPrefs(opacity: 0.5));

    // 合规存储目录解析失败（模拟单文件删不掉、复核也做不了）。
    final ComplianceStore brokenCompliance = ComplianceStore(
      directoryResolver: () async => throw const FileSystemException('denied'),
    );

    final LocalDataResetResult result = await resetWith(
      rooms: rooms,
      prefs: prefs,
      compliance: brokenCompliance,
      credential: CredentialStore(backend: backend),
    ).clearAll();

    expect(result.clean, isFalse, reason: '失败必须可见，不能再静默返回');
    expect(result.targets, contains(LocalDataReset.complianceTarget));
    expect(result.complianceRemains, isTrue, reason: '复核不了门禁就不能宣布重置成功');
    // 单项失败不阻断其余项：其余数据照常清干净。
    expect(await rooms.load(), isEmpty);
    expect((await prefs.load()).webRids, isEmpty);
    expect(backend.stored, isNull);
  });

  test('合规状态删除未生效时覆写「未同意」兜底，门禁安全就不报失败（#92）', () async {
    Future<Directory> resolver() async => directory;
    final _IgnoringClearCompliance compliance =
        _IgnoringClearCompliance(directoryResolver: resolver);
    await compliance.save(const ComplianceState(disclaimerAccepted: true));

    final LocalDataResetResult result =
        await resetWith(compliance: compliance).clearAll();

    expect(result.clean, isTrue, reason: '已兜底成未同意，门禁仍然成立');
    expect(result.complianceRemains, isFalse);
    expect((await compliance.load()).disclaimerAccepted, isFalse);
    // 文件还在但内容是「未同意」：冷启动仍会回到免责声明页，绕过不成立。
    expect(await compliance.exists(), isTrue);
  });

  test('凭证密文删除失败会被报告，内存凭证仍回到匿名（#92）', () async {
    final FakeBackend backend = FakeBackend('ttwid=manual')
      ..deleteError = const FileSystemException('denied');
    final CredentialStore credential = CredentialStore(backend: backend);
    expect(await credential.load(), isTrue);

    final LocalDataResetResult result =
        await resetWith(credential: credential).clearAll();

    expect(result.clean, isFalse);
    expect(result.targets, contains('凭证密文'));
    expect(
      credential.hasProfiles,
      isFalse,
      reason: '内存必须回到匿名，避免界面继续用一个已被要求删除的凭证',
    );
    expect(backend.stored, 'ttwid=manual', reason: '删除确实失败了，报告属实');
  });

  test('主播列表清除失败只影响该项，其余项照常清空（#92）', () async {
    Future<Directory> resolver() async => directory;
    final RoomStore brokenRooms = RoomStore(
      directoryResolver: () async => throw const FileSystemException('denied'),
    );
    final OverlayPrefsStore prefs = OverlayPrefsStore(directoryResolver: resolver);
    await prefs.save(const OverlayPrefs(opacity: 0.5));

    final LocalDataResetResult result =
        await resetWith(rooms: brokenRooms, prefs: prefs).clearAll();

    expect(result.targets, contains('主播列表'));
    expect(result.complianceRemains, isFalse);
    expect((await prefs.load()).webRids, isEmpty);
  });
}
