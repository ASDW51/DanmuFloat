// 本地数据备份 / 恢复：JSON 编解码、错误分支与覆盖落盘。
//
// 各 store 一律注入临时目录，测试不依赖 path_provider 插件通道。
import 'dart:convert';
import 'dart:io';

import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/data_transfer.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('备份编解码', () {
    test('往返一致：主播 / 偏好 / 过滤 / 主题都还原', () {
      final String raw = encodeDataBundle(
        rooms: <ManagedRoom>[
          const ManagedRoom(webRid: '123', name: '备注', group: '朋友', addedAt: 1),
        ],
        prefs: const OverlayPrefs(
          webRids: <String>['123'],
          opacity: 0.5,
          windowWidth: 300,
          windowHeight: 400,
        ),
        filter: const FilterPrefs(
          blockedKeywords: <String>['广告', r'^\d+$'],
          highlightKeywords: <String>['抽奖'],
          regexEnabled: true,
        ),
        themeMode: ThemeMode.dark,
      );

      final DataBundle bundle = decodeDataBundle(raw);

      expect(bundle.rooms, hasLength(1));
      expect(bundle.rooms.first.webRid, '123');
      expect(bundle.rooms.first.group, '朋友');
      expect(bundle.prefs.opacity, 0.5);
      expect(bundle.prefs.webRids, <String>['123']);
      expect(bundle.filter.blockedKeywords, <String>['广告', r'^\d+$']);
      expect(bundle.filter.highlightKeywords, <String>['抽奖']);
      expect(bundle.filter.regexEnabled, isTrue);
      expect(bundle.themeMode, ThemeMode.dark);
    });

    test('自定义主题随备份往返一致（#147）', () {
      const MyTheme theme = MyTheme(
        id: '1700000000000',
        name: '夜间护眼',
        baseThemeId: 'dark',
        overrides: <String, int>{'menuBg': 0xFF101820},
      );
      final String raw = encodeDataBundle(
        rooms: <ManagedRoom>[],
        prefs: const OverlayPrefs(myThemes: <MyTheme>[theme]),
        filter: const FilterPrefs(),
        themeMode: ThemeMode.system,
      );

      final DataBundle bundle = decodeDataBundle(raw);

      expect(bundle.prefs.myThemes, hasLength(1), reason: '备份必须保留用户另存的主题');
      expect(bundle.prefs.myThemes.single.id, theme.id);
      expect(bundle.prefs.myThemes.single.name, theme.name);
      expect(bundle.prefs.myThemes.single.baseThemeId, theme.baseThemeId);
      expect(bundle.prefs.myThemes.single.overrides, theme.overrides);
    });

    test('备份里没有合规分区（#85）：同意状态不随备份搬运', () {      final Map<String, Object?> root = jsonDecode(
        encodeDataBundle(
          rooms: const <ManagedRoom>[],
          prefs: const OverlayPrefs(),
          filter: const FilterPrefs(),
          themeMode: ThemeMode.system,
        ),
      ) as Map<String, Object?>;

      expect(
        root.containsKey('compliance'),
        isFalse,
        reason: '同意是与本机当次操作绑定的授权记录，写进备份就能被外部 JSON 改写',
      );
    });

    test('根对象带 App 标识与版本号', () {
      final Map<String, Object?> root = jsonDecode(
        encodeDataBundle(
          rooms: const <ManagedRoom>[],
          prefs: const OverlayPrefs(),
          filter: const FilterPrefs(),
          themeMode: ThemeMode.system,
        ),
      ) as Map<String, Object?>;
      expect(root['app'], dataBundleAppId);
      expect(root['version'], dataBundleVersion);
      expect(root['exportedAt'], isA<String>());
    });

    test('空内容 / 坏 JSON / 非对象分别给出对应中文提示', () {
      expect(
        () => decodeDataBundle('   '),
        throwsA(isA<DataTransferException>().having(
          (DataTransferException e) => e.message,
          'message',
          contains('内容为空'),
        )),
      );
      expect(
        () => decodeDataBundle('不是 json'),
        throwsA(isA<DataTransferException>().having(
          (DataTransferException e) => e.message,
          'message',
          contains('不是合法的 JSON'),
        )),
      );
      expect(
        () => decodeDataBundle('[1,2,3]'),
        throwsA(isA<DataTransferException>().having(
          (DataTransferException e) => e.message,
          'message',
          contains('根节点应为对象'),
        )),
      );
    });

    test('非本 App 备份被拒', () {
      expect(
        () => decodeDataBundle('{"app":"other","version":1}'),
        throwsA(isA<DataTransferException>().having(
          (DataTransferException e) => e.message,
          'message',
          contains('不是 DanmuFloat 的备份'),
        )),
      );
    });

    test('缺版本号 / 版本过新分别报错', () {
      expect(
        () => decodeDataBundle('{"app":"$dataBundleAppId"}'),
        throwsA(isA<DataTransferException>().having(
          (DataTransferException e) => e.message,
          'message',
          contains('缺少版本号'),
        )),
      );
      expect(
        () => decodeDataBundle(
          '{"app":"$dataBundleAppId","version":${dataBundleVersion + 1}}',
        ),
        throwsA(isA<DataTransferException>().having(
          (DataTransferException e) => e.message,
          'message',
          contains('备份版本过新'),
        )),
      );
    });

    test('分区局部缺失时退回默认值，不整份拒绝', () {
      final DataBundle bundle =
          decodeDataBundle('{"app":"$dataBundleAppId","version":1}');
      expect(bundle.rooms, isEmpty);
      expect(bundle.prefs.opacity, const OverlayPrefs().opacity);
      expect(bundle.filter.blockedKeywords, isEmpty);
      expect(bundle.themeMode, ThemeMode.system);
    });

    test('备份文件名带时间戳', () {
      expect(
        backupFileName(DateTime(2026, 9, 28, 3, 4, 5)),
        'danmu_float_backup_20260928_030405.json',
      );
    });
  });

  group('LocalDataTransfer', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('data_transfer_test');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    LocalDataTransfer makeTransfer({
      SaveTextToDownloads? saveToDownloads,
      FilterStore? filterStore,
    }) {
      Future<Directory> resolve() async => directory;
      return LocalDataTransfer(
        roomStore: RoomStore(directoryResolver: resolve),
        prefsStore: OverlayPrefsStore(directoryResolver: resolve),
        filterStore: filterStore ?? FilterStore(directoryResolver: resolve),
        themeStore: ThemeStore(directoryResolver: resolve),
        directoryResolver: resolve,
        saveToDownloads: saveToDownloads,
      );
    }

    test('导入覆盖现有数据，落盘结果与备份一致', () async {
      final LocalDataTransfer transfer = makeTransfer();
      final String raw = encodeDataBundle(
        rooms: <ManagedRoom>[
          const ManagedRoom(webRid: '999', name: '新主播', addedAt: 1),
        ],
        prefs: const OverlayPrefs(opacity: 0.3, webRids: <String>['999']),
        filter: const FilterPrefs(blockedKeywords: <String>['广告']),
        themeMode: ThemeMode.light,
      );

      final DataImportSummary summary = await transfer.importJson(raw);

      expect(summary.rooms, 1);
      expect(summary.blockedKeywords, 1);
      expect(summary.highlightKeywords, 0);
      expect(summary.regexEnabled, isFalse);
      expect(summary.description, contains('已导入 1 个主播'));

      // 落盘后再读回，验证覆盖真的写进了各文件。
      Future<Directory> resolve() async => directory;
      final List<ManagedRoom> rooms = await RoomStore(directoryResolver: resolve).load();
      expect(rooms.single.webRid, '999');
      final OverlayPrefs prefs =
          await OverlayPrefsStore(directoryResolver: resolve).load();
      expect(prefs.opacity, 0.3);
      expect(prefs.webRids, <String>['999']);
      final FilterPrefs filter =
          await FilterStore(directoryResolver: resolve).load();
      expect(filter.blockedKeywords, <String>['广告']);
      expect(await ThemeStore(directoryResolver: resolve).load(), ThemeMode.light);
      // 合规状态不参与导入（#85）：导入前是什么，导入后还是什么。
      final ComplianceState compliance =
          await ComplianceStore(directoryResolver: resolve).load();
      expect(
        compliance.disclaimerAccepted,
        isFalse,
        reason: '同意只能由本机首次启动时的勾选写下，导入不得改写它',
      );
    });

    test('导出后再导入：数据原样还原', () async {
      final LocalDataTransfer transfer = makeTransfer();
      Future<Directory> resolve() async => directory;
      await RoomStore(directoryResolver: resolve).save(<ManagedRoom>[
        const ManagedRoom(webRid: '42', name: '甲', addedAt: 7),
      ]);
      await FilterStore(directoryResolver: resolve).save(
        const FilterPrefs(highlightKeywords: <String>['抽奖'], regexEnabled: true),
      );

      final String exported = await transfer.exportJson();
      // 清掉现有数据后导入，模拟换设备恢复。
      await LocalDataTransfer(
        roomStore: RoomStore(directoryResolver: resolve),
        prefsStore: OverlayPrefsStore(directoryResolver: resolve),
        filterStore: FilterStore(directoryResolver: resolve),
        themeStore: ThemeStore(directoryResolver: resolve),
        directoryResolver: resolve,
      ).importJson(exported);

      final List<ManagedRoom> rooms = await RoomStore(directoryResolver: resolve).load();
      expect(rooms.single.webRid, '42');
      expect(rooms.single.name, '甲');
      final FilterPrefs filter =
          await FilterStore(directoryResolver: resolve).load();
      expect(filter.highlightKeywords, <String>['抽奖']);
      expect(filter.regexEnabled, isTrue);
    });

    test('坏备份不落盘，抛异常', () async {
      final LocalDataTransfer transfer = makeTransfer();
      await expectLater(
        transfer.importJson('{"app":"other"}'),
        throwsA(isA<DataTransferException>()),
      );
    });

    test('exportToFile 写出 JSON 文件', () async {
      final LocalDataTransfer transfer = makeTransfer();
      final String json = await transfer.exportJson();
      final String? path = await transfer.exportToFile(json);
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(File(path).readAsStringSync(), json);
    });

    test('exportToDownloads 优先写公共目录并回传展示位置', () async {
      String? savedName;
      String? savedContent;
      final LocalDataTransfer transfer = makeTransfer(
        saveToDownloads: ({required String fileName, required String content}) async {
          savedName = fileName;
          savedContent = content;
          return '下载/$fileName';
        },
      );

      final String json = await transfer.exportJson();
      final String? location = await transfer.exportToDownloads(json);

      expect(location, startsWith('下载/danmu_float_backup_'));
      expect(savedName, startsWith('danmu_float_backup_'));
      expect(savedContent, json);
    });

    test('公共目录写不进去时退回私有目录文件', () async {
      final LocalDataTransfer transfer = makeTransfer(
        saveToDownloads: ({required String fileName, required String content}) async =>
            null,
      );

      final String json = await transfer.exportJson();
      final String? location = await transfer.exportToDownloads(json);

      expect(location, isNotNull);
      expect(File(location!).existsSync(), isTrue);
      expect(File(location).readAsStringSync(), json);
    });

    test('公共目录通道抛异常时退回私有目录文件', () async {
      final LocalDataTransfer transfer = makeTransfer(
        saveToDownloads: ({required String fileName, required String content}) async =>
            throw Exception('通道不可用'),
      );

      final String json = await transfer.exportJson();
      final String? location = await transfer.exportToDownloads(json);

      expect(location, isNotNull);
      expect(File(location!).existsSync(), isTrue);
    });

    test('导入旧备份不改写本机同意状态（#85）', () async {
      Future<Directory> resolve() async => directory;
      // 本机还没同意过：首次启动时的那次勾选是唯一的写入来源。
      expect(
        (await ComplianceStore(directoryResolver: resolve).load())
            .disclaimerAccepted,
        isFalse,
      );

      // 旧版本备份会带 compliance 分区：把它写成「已同意」也不能改写本机状态，
      // 否则一份外部 JSON 就能让合规入口被绕过（AGENTS.md 硬边界）。
      final String forged = jsonEncode(<String, Object?>{
        'app': dataBundleAppId,
        'version': dataBundleVersion,
        'rooms': <String, Object?>{'rooms': <Object?>[]},
        'overlayPrefs': <String, Object?>{},
        'filter': <String, Object?>{},
        'theme': <String, Object?>{},
        'compliance': <String, Object?>{
          'disclaimerAccepted': true,
          'onboardingDone': true,
        },
      });
      await makeTransfer().importJson(forged);
      final ComplianceState afterForged =
          await ComplianceStore(directoryResolver: resolve).load();
      expect(
        afterForged.disclaimerAccepted,
        isFalse,
        reason: '外部 JSON 不得把本机置为「已同意」',
      );
      expect(
        afterForged.onboardingDone,
        isFalse,
        reason: '引导完成标志同样不随备份搬运，否则换设备会被直接跳过',
      );

      // 反向：整块读不出来也不该影响导入——它已不是备份格式的一部分，拿它中止导入
      // 只会让旧备份变得无法恢复。
      final String malformed = jsonEncode(<String, Object?>{
        'app': dataBundleAppId,
        'version': dataBundleVersion,
        'rooms': <String, Object?>{'rooms': <Object?>[]},
        'overlayPrefs': <String, Object?>{},
        'filter': <String, Object?>{},
        'theme': <String, Object?>{},
        'compliance': '坏了',
      });
      await makeTransfer().importJson(malformed);
      expect(
        (await ComplianceStore(directoryResolver: resolve).load())
            .disclaimerAccepted,
        isFalse,
      );
    });

    test('分区存在但读不出来时拒绝导入，现有数据一个字节都不改（#84）', () async {
      Future<Directory> resolve() async => directory;
      // 先放一份「现有数据」，导入被拒后它必须原样还在。
      await RoomStore(directoryResolver: resolve).save(<ManagedRoom>[
        const ManagedRoom(webRid: '111', name: '旧主播', addedAt: 1),
      ]);
      await OverlayPrefsStore(directoryResolver: resolve)
          .save(const OverlayPrefs(opacity: 0.9));
      final OverlayPrefs before =
          await OverlayPrefsStore(directoryResolver: resolve).load();

      // 备份里 overlayPrefs 是字符串而不是对象：旧实现会静默回落默认值，
      // 于是「导入成功」却把样式 / 主题 / 栏位整体清成默认。
      final String raw = jsonEncode(<String, Object?>{
        'app': dataBundleAppId,
        'version': dataBundleVersion,
        'rooms': <String, Object?>{'rooms': <Object?>[]},
        'overlayPrefs': '坏了',
        'filter': <String, Object?>{},
        'theme': <String, Object?>{},
        'compliance': <String, Object?>{},
      });

      await expectLater(
        makeTransfer().importJson(raw),
        throwsA(
          isA<DataTransferException>().having(
            (DataTransferException error) => error.message,
            'message',
            allOf(contains('悬浮窗偏好'), contains('已中止导入')),
          ),
        ),
      );

      final List<ManagedRoom> rooms =
          await RoomStore(directoryResolver: resolve).load();
      expect(rooms.single.webRid, '111', reason: '被拒绝的导入不能动现有主播列表');
      expect(
        (await OverlayPrefsStore(directoryResolver: resolve).load()).opacity,
        before.opacity,
        reason: '被拒绝的导入不能把偏好覆盖成默认值',
      );
    });

    test('主体分区解析不出来时同样拒绝（#84）', () async {
      // rooms 是对象但缺 rooms 列表：tryDecodeRooms 会判为损坏。
      final String raw = jsonEncode(<String, Object?>{
        'app': dataBundleAppId,
        'version': dataBundleVersion,
        'rooms': <String, Object?>{},
        'overlayPrefs': <String, Object?>{},
        'filter': <String, Object?>{},
        'theme': <String, Object?>{},
        'compliance': <String, Object?>{},
      });

      await expectLater(
        makeTransfer().importJson(raw),
        throwsA(
          isA<DataTransferException>().having(
            (DataTransferException error) => error.message,
            'message',
            contains('主播列表'),
          ),
        ),
      );
    });

    test('主题分区带非法 themeMode 时也拒绝导入（#84）', () async {
      final String raw = jsonEncode(<String, Object?>{
        'app': dataBundleAppId,
        'version': dataBundleVersion,
        'rooms': <String, Object?>{'rooms': <Object?>[]},
        'overlayPrefs': <String, Object?>{},
        'filter': <String, Object?>{},
        'theme': <String, Object?>{'themeMode': 'neon'},
        'compliance': <String, Object?>{},
      });

      await expectLater(
        makeTransfer().importJson(raw),
        throwsA(
          isA<DataTransferException>().having(
            (DataTransferException error) => error.message,
            'message',
            contains('主题'),
          ),
        ),
      );
    });

    test('写到一半失败时把已覆盖的分区回滚回旧值（#84）', () async {
      Future<Directory> resolve() async => directory;
      await RoomStore(directoryResolver: resolve).save(<ManagedRoom>[
        const ManagedRoom(webRid: '111', name: '旧主播', addedAt: 1),
      ]);
      final OverlayPrefs prefsBefore =
          await OverlayPrefsStore(directoryResolver: resolve).load();

      final String raw = encodeDataBundle(
        rooms: <ManagedRoom>[
          const ManagedRoom(webRid: '999', name: '备份主播', addedAt: 2),
        ],
        prefs: const OverlayPrefs(opacity: 0.3),
        filter: const FilterPrefs(blockedKeywords: <String>['广告']),
        themeMode: ThemeMode.light,
      );

      // 第 3 步（过滤设置）必定失败：前两步已经覆盖了 rooms / prefs，必须被回滚。
      final LocalDataTransfer transfer = makeTransfer(
        filterStore: _FailingFilterStore(directoryResolver: resolve),
      );

      await expectLater(
        transfer.importJson(raw),
        throwsA(
          isA<DataTransferException>().having(
            (DataTransferException error) => error.message,
            'message',
            allOf(contains('过滤设置'), contains('已回滚 2 个分区')),
          ),
        ),
      );

      final List<ManagedRoom> rooms =
          await RoomStore(directoryResolver: resolve).load();
      expect(rooms.single.webRid, '111', reason: '失败前已覆盖的主播列表要回滚');
      expect(
        (await OverlayPrefsStore(directoryResolver: resolve).load()).opacity,
        prefsBefore.opacity,
        reason: '失败前已覆盖的偏好要回滚',
      );
    });
  });
}

/// 写入必定失败的过滤存储：用来验证中途失败会回滚（#84）。
///
/// 无法用真实存储制造「第 3 步失败而前两步成功」，所以只替换失败的那一个分区。
class _FailingFilterStore extends FilterStore {
  _FailingFilterStore({super.directoryResolver});

  @override
  Future<void> save(FilterPrefs prefs) async {
    throw const FileSystemException('磁盘已满');
  }
}
