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
    test('往返一致：主播 / 偏好 / 过滤 / 主题 / 合规状态都还原', () {
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
        compliance: const ComplianceState(
          disclaimerAccepted: true,
          onboardingDone: true,
        ),
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
      expect(bundle.compliance.disclaimerAccepted, isTrue);
      expect(bundle.compliance.onboardingDone, isTrue);
    });

    test('根对象带 App 标识与版本号', () {
      final Map<String, Object?> root = jsonDecode(
        encodeDataBundle(
          rooms: const <ManagedRoom>[],
          prefs: const OverlayPrefs(),
          filter: const FilterPrefs(),
          themeMode: ThemeMode.system,
          compliance: const ComplianceState(),
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
      expect(bundle.compliance.disclaimerAccepted, isFalse);
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

    LocalDataTransfer makeTransfer() {
      Future<Directory> resolve() async => directory;
      return LocalDataTransfer(
        roomStore: RoomStore(directoryResolver: resolve),
        prefsStore: OverlayPrefsStore(directoryResolver: resolve),
        filterStore: FilterStore(directoryResolver: resolve),
        themeStore: ThemeStore(directoryResolver: resolve),
        complianceStore: ComplianceStore(directoryResolver: resolve),
        directoryResolver: resolve,
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
        compliance: const ComplianceState(disclaimerAccepted: true),
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
      final ComplianceState compliance =
          await ComplianceStore(directoryResolver: resolve).load();
      expect(compliance.disclaimerAccepted, isTrue);
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
        complianceStore: ComplianceStore(directoryResolver: resolve),
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
  });
}
