import 'dart:io';

import 'package:danmu_float/storage/home_view_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('首页视图偏好（#139）', () {
    test('解析：缺失 / 非字符串 / 不认识一律回落添加顺序', () {
      expect(parseHomeSortMode(null), homeSortAdded);
      expect(parseHomeSortMode(42), homeSortAdded);
      expect(parseHomeSortMode('unknown'), homeSortAdded);
      expect(parseHomeSortMode(homeSortLivingFirst), homeSortLivingFirst);
      expect(parseHomeSortMode(homeSortRecentlyRefreshed),
          homeSortRecentlyRefreshed);
    });

    test('tryParse：非对象回落默认，坏字段回落默认', () {
      expect(HomeViewPrefs.tryParse(null).sortMode, homeSortAdded);
      expect(HomeViewPrefs.tryParse('oops').sortMode, homeSortAdded);
      expect(HomeViewPrefs.tryParse(<String, Object?>{'sortMode': 1}).sortMode,
          homeSortAdded);
      expect(
        HomeViewPrefs.tryParse(<String, Object?>{
          'sortMode': homeSortLivingFirst,
        }).sortMode,
        homeSortLivingFirst,
      );
    });

    test('三种排序都有中文名，菜单不会出现空标签', () {
      for (final String mode in homeSortModes) {
        expect(homeSortLabels[mode], isNotNull, reason: mode);
        expect(homeSortLabels[mode], isNotEmpty, reason: mode);
      }
      expect(homeSortLabels.length, homeSortModes.length);
    });

    test('落盘后能读回；文件不存在时是默认值', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('danmu_float_home_view');
      addTearDown(() => dir.deleteSync(recursive: true));
      final HomeViewPrefsStore store =
          HomeViewPrefsStore(directoryResolver: () async => dir);

      expect((await store.load()).sortMode, homeSortAdded);

      await store.save(
        const HomeViewPrefs(sortMode: homeSortRecentlyRefreshed),
      );
      expect((await store.load()).sortMode, homeSortRecentlyRefreshed);
    });

    test('文件内容损坏时回落默认，不抛（列表必须能开出来）', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('danmu_float_home_view_bad');
      addTearDown(() => dir.deleteSync(recursive: true));
      final HomeViewPrefsStore store =
          HomeViewPrefsStore(directoryResolver: () async => dir);
      final File file = File(
        '${dir.path}${Platform.pathSeparator}$homeViewPrefsFileName',
      );
      await file.writeAsString('{ not json');

      expect((await store.load()).sortMode, homeSortAdded);
    });
  });
  group('分组收起状态（#140）', () {
    test('缺字段回落「全部展开」，非法项逐条丢弃', () {
      expect(HomeViewPrefs.tryParse(<String, Object?>{}).collapsedGroups, isEmpty);
      expect(
        HomeViewPrefs.tryParse(<String, Object?>{
          'collapsedGroups': <Object?>['游戏', 42, '', null, '音乐'],
        }).collapsedGroups,
        <String>{'游戏', '音乐'},
      );
      expect(
        HomeViewPrefs.tryParse(<String, Object?>{'collapsedGroups': 'oops'})
            .collapsedGroups,
        isEmpty,
      );
    });

    test('与排序一起往返落盘，互不覆盖', () async {
      final Directory dir =
          Directory.systemTemp.createTempSync('danmu_float_home_view_groups');
      addTearDown(() => dir.deleteSync(recursive: true));
      final HomeViewPrefsStore store =
          HomeViewPrefsStore(directoryResolver: () async => dir);

      await store.save(
        const HomeViewPrefs(
          sortMode: homeSortLivingFirst,
          collapsedGroups: <String>{'游戏', '音乐'},
        ),
      );
      final HomeViewPrefs loaded = await store.load();
      expect(loaded.sortMode, homeSortLivingFirst);
      expect(loaded.collapsedGroups, <String>{'游戏', '音乐'});

      // 只改排序也必须把折叠状态带回去：整份覆盖写，漏字段就等于清空。
      await store.save(loaded.copyWith(sortMode: homeSortAdded));
      final HomeViewPrefs again = await store.load();
      expect(again.sortMode, homeSortAdded);
      expect(again.collapsedGroups, <String>{'游戏', '音乐'});
    });
  });
}
