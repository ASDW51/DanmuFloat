// 检查更新偏好（#166）：坏文件不炸、往返不丢字段。
import 'dart:io';

import 'package:danmu_float/storage/update_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdatePrefs.tryParse（#166）', () {
    test('缺字段回落默认：自动检查关闭、从没查过、没提示过', () {
      final UpdatePrefs prefs = UpdatePrefs.tryParse(<String, Object?>{});
      expect(prefs.autoCheck, isFalse, reason: '自动检查必须默认关闭（会访问 github.com）');
      expect(prefs.lastCheckedAt, isNull);
      expect(prefs.lastNotifiedVersion, isEmpty);
    });

    test('非对象 / 字段类型不对一律按默认处理', () {
      expect(UpdatePrefs.tryParse('oops').autoCheck, isFalse);
      expect(UpdatePrefs.tryParse(<String, Object?>{'lastCheckedAt': 'x'}).lastCheckedAt, isNull);
      expect(UpdatePrefs.tryParse(<String, Object?>{'lastNotifiedVersion': 5}).lastNotifiedVersion, isEmpty);
      // autoCheck 只认真正的 true：字符串 "true" 不算。
      expect(UpdatePrefs.tryParse(<String, Object?>{'autoCheck': 'true'}).autoCheck, isFalse);
    });

    test('正常字段逐项还原', () {
      final UpdatePrefs prefs = UpdatePrefs.tryParse(<String, Object?>{
        'autoCheck': true,
        'lastCheckedAt': 1700000000000,
        'lastNotifiedVersion': '0.2.0',
      });
      expect(prefs.autoCheck, isTrue);
      expect(prefs.lastCheckedAt, 1700000000000);
      expect(prefs.lastNotifiedVersion, '0.2.0');
    });
  });

  group('UpdatePrefsStore（#166）', () {
    test('落盘再读回，字段一个不少', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('danmu_float_update_prefs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final UpdatePrefsStore store =
          UpdatePrefsStore(directoryResolver: () async => dir);

      expect((await store.load()).autoCheck, isFalse, reason: '首次读盘是默认值');

      await store.save(
        const UpdatePrefs(
          autoCheck: true,
          lastCheckedAt: 1700000000000,
          lastNotifiedVersion: '0.2.0',
        ),
      );
      final UpdatePrefs loaded = await store.load();
      expect(loaded.autoCheck, isTrue);
      expect(loaded.lastCheckedAt, 1700000000000);
      expect(loaded.lastNotifiedVersion, '0.2.0');
    });

    test('文件损坏时回落默认，不抛（设置页必须能打开）', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('danmu_float_update_bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File file = File(
        '${dir.path}${Platform.pathSeparator}$updatePrefsFileName',
      );
      await file.writeAsString('{ not json');

      final UpdatePrefs prefs = await UpdatePrefsStore(
        directoryResolver: () async => dir,
      ).load();
      expect(prefs.autoCheck, isFalse);
      expect(prefs.lastCheckedAt, isNull);
    });
  });
}
