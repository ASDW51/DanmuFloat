// 「清除所有本地数据」（prd F26）：主播列表、样式偏好、合规状态、凭证一并清空。
import 'dart:io';

import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/local_data_reset.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBackend implements CredentialBackend {
  FakeBackend(this.stored);

  String? stored;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String value) async => stored = value;

  @override
  Future<void> delete() async => stored = null;
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

    await LocalDataReset(
      roomStore: rooms,
      prefsStore: prefs,
      complianceStore: compliance,
      credentialStore: credential,
    ).clearAll();

    expect(await rooms.load(), isEmpty);
    expect((await prefs.load()).webRids, isEmpty);
    expect((await compliance.load()).disclaimerAccepted, isFalse);
    expect(backend.stored, isNull);
    expect(credential.hasProfiles, isFalse);
  });

  test('单项清除失败不阻断其余项', () async {
    Future<Directory> resolver() async => directory;
    final RoomStore rooms = RoomStore(directoryResolver: resolver);
    final OverlayPrefsStore prefs = OverlayPrefsStore(directoryResolver: resolver);
    final FakeBackend backend = FakeBackend('ttwid=manual');

    await prefs.save(const OverlayPrefs(opacity: 0.5));

    // 合规存储目录解析失败（模拟单文件删不掉）。
    final ComplianceStore brokenCompliance = ComplianceStore(
      directoryResolver: () async => throw const FileSystemException('denied'),
    );

    await LocalDataReset(
      roomStore: rooms,
      prefsStore: prefs,
      complianceStore: brokenCompliance,
      credentialStore: CredentialStore(backend: backend),
    ).clearAll();

    expect(await rooms.load(), isEmpty);
    expect((await prefs.load()).webRids, isEmpty);
    expect(backend.stored, isNull);
  });
}
