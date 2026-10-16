// 主播列表持久化：JSON 结构、坏数据容错与落盘往返。
import 'dart:io';

import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ManagedRoom', () {
    test('展示名按备注 → 主播名 → 直播间号依次回落', () {
      expect(_room(name: '老王', owner: '主播A').displayName, '老王');
      expect(_room(owner: '主播A').displayName, '主播A');
      expect(_room().displayName, '735');
    });

    test('缺 room_id 的记录按坏数据跳过', () {
      expect(ManagedRoom.tryParse(<String, Object?>{'room_name': 'x'}), isNull);
      expect(ManagedRoom.tryParse(<String, Object?>{'room_id': '  '}), isNull);
      expect(ManagedRoom.tryParse('not a map'), isNull);
    });

    test('未刷新过的主播 living 为 null，刷新后可区分未开播', () {
      expect(ManagedRoom.tryParse(<String, Object?>{'room_id': '1'})!.living, isNull);
      expect(
        ManagedRoom.tryParse(<String, Object?>{'room_id': '1', 'living': false})!
            .living,
        isFalse,
      );
    });

    test('分组缺失或为空串时按未分组处理（prd F14）', () {
      expect(ManagedRoom.tryParse(<String, Object?>{'room_id': '1'})!.group, '');
      expect(
        ManagedRoom.tryParse(<String, Object?>{'room_id': '1', 'group': '  '})!
            .group,
        '',
      );
      expect(
        ManagedRoom.tryParse(<String, Object?>{'room_id': '1', 'group': ' 比赛 '})!
            .group,
        '比赛',
      );
    });

    test('copyWith 可写入 / 清空分组', () {
      expect(_room().copyWith(group: '关注').group, '关注');
      expect(_room().copyWith(group: '关注').copyWith(group: '').group, '');
    });

    test('老版本记录没有 last_refreshed_at 时按「从未刷新」处理', () {
      expect(
        ManagedRoom.tryParse(<String, Object?>{'room_id': '1'})!.lastRefreshedAt,
        isNull,
      );
      // 0 / 负数 / 非数字一律当没刷过，免得行内显示成 1970 年。
      expect(
        ManagedRoom.tryParse(
          <String, Object?>{'room_id': '1', 'last_refreshed_at': 0},
        )!.lastRefreshedAt,
        isNull,
      );
      expect(
        ManagedRoom.tryParse(
          <String, Object?>{'room_id': '1', 'last_refreshed_at': 'abc'},
        )!.lastRefreshedAt,
        isNull,
      );
    });

    test('copyWith 写入刷新时间，未传时保留原值（UX-04）', () {
      expect(
        _room().copyWith(lastRefreshedAt: 1700000123000).lastRefreshedAt,
        1700000123000,
      );
      expect(
        _room(lastRefreshedAt: 1700000123000)
            .copyWith(name: '老王')
            .lastRefreshedAt,
        1700000123000,
      );
    });
  });

  group('encodeRooms / decodeRooms', () {
    test('经 JSON 往返后保留备注、主播名、标题与开播状态', () {
      final List<ManagedRoom> decoded = decodeRooms(encodeRooms(<ManagedRoom>[
        _room(name: '老王', owner: '主播A', title: '今晚八点', living: true),
        _room(webRid: '736'),
      ]));

      expect(decoded.length, 2);
      expect(decoded.first.webRid, '735');
      expect(decoded.first.name, '老王');
      expect(decoded.first.owner, '主播A');
      expect(decoded.first.title, '今晚八点');
      expect(decoded.first.living, isTrue);
      expect(decoded.last.living, isNull);
    });

    test('分组随房间记录一起落盘，缺失时回落未分组（prd F14）', () {
      final List<ManagedRoom> decoded = decodeRooms(encodeRooms(<ManagedRoom>[
        _room(group: '比赛'),
        _room(webRid: '736'),
      ]));
      expect(decoded.first.group, '比赛');
      expect(decoded.last.group, '');
    });

    test('刷新时间随房间记录一起落盘，缺失时回落 null（UX-04）', () {
      final List<ManagedRoom> decoded = decodeRooms(encodeRooms(<ManagedRoom>[
        _room(lastRefreshedAt: 1700000123000),
        _room(webRid: '736'),
      ]));
      expect(decoded.first.lastRefreshedAt, 1700000123000);
      expect(decoded.last.lastRefreshedAt, isNull);
    });

    test('空内容、非 JSON、结构不符一律按空列表处理（备份导入用的宽松口径）', () {
      expect(decodeRooms(''), isEmpty);
      expect(decodeRooms('   '), isEmpty);
      expect(decodeRooms('{oops'), isEmpty);
      expect(decodeRooms('[]'), isEmpty);
      expect(decodeRooms('{"rooms":{}}'), isEmpty);
    });

    test('坏输入能被识别为「损坏」而不是「空列表」（#82）', () {
      // 宽松口径把这几类都当空列表；严格口径必须报损坏，否则调用方无法把
      // 「文件读不出来」与「真的没有主播」分开，下一次保存就会覆盖原件。
      expect(tryDecodeRooms(''), isNull);
      expect(tryDecodeRooms('   '), isNull);
      expect(tryDecodeRooms('{oops'), isNull);
      expect(tryDecodeRooms('{"rooms": ['), isNull);
      expect(tryDecodeRooms('[]'), isNull);
      expect(tryDecodeRooms('{"rooms":{}}'), isNull);
      // 合法但列表为空是正常状态，不能算损坏。
      expect(tryDecodeRooms('{"rooms":[]}'), isEmpty);
    });

    test('列表里的坏记录被跳过，好记录保留', () {
      final List<ManagedRoom> decoded = decodeRooms(
        '{"rooms":[{"room_name":"缺id"},{"room_id":"736"}]}',
      );
      expect(decoded.length, 1);
      expect(decoded.single.webRid, '736');
    });
  });

  group('RoomStore', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('room_store_test');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    RoomStore store() =>
        RoomStore(directoryResolver: () async => directory);

    test('文件不存在时返回空列表', () async {
      expect(await store().load(), isEmpty);
    });

    test('保存后可重新读出，且覆盖写不会残留旧数据', () async {
      final RoomStore roomStore = store();
      await roomStore.save(<ManagedRoom>[_room(), _room(webRid: '736')]);
      expect((await roomStore.load()).map((ManagedRoom r) => r.webRid),
          <String>['735', '736']);

      await roomStore.save(<ManagedRoom>[_room(webRid: '737')]);
      expect((await roomStore.load()).single.webRid, '737');
    });

    test('文件内容损坏时按空列表处理，不抛异常', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}$roomStoreFileName');
      await file.writeAsString('{broken');
      expect(await store().load(), isEmpty);
    });

    test('文件不存在时不算损坏（首次启动的正常路径）', () async {
      final RoomLoadResult result = await store().loadResult();
      expect(result.rooms, isEmpty);
      expect(result.corrupted, isFalse);
      expect(result.backupPath, isNull);
    });

    test('文件损坏时报告损坏，并把原文件留存为 .bad 而不是留原地被覆盖（#82）', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}$roomStoreFileName');
      await file.writeAsString('{broken');

      final RoomLoadResult result = await store().loadResult();

      expect(result.corrupted, isTrue, reason: '损坏必须与「列表为空」区分');
      expect(result.rooms, isEmpty);
      expect(result.backupPath, endsWith('$roomStoreFileName.bad'));
      // 原件必须被移走：留在原地会在下一次保存时被覆盖，等于没保住。
      expect(await file.exists(), isFalse);
      expect(await File(result.backupPath!).readAsString(), '{broken');
    });

    test('已有留存件时新损坏件带时间戳，不覆盖上一份（#82）', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}$roomStoreFileName');
      final File previous = File('${file.path}$roomStoreCorruptSuffix');
      await previous.writeAsString('上一份坏文件');
      await file.writeAsString('{broken-again');

      final RoomLoadResult result = await store().loadResult();

      expect(result.corrupted, isTrue);
      expect(result.backupPath, isNot(previous.path));
      expect(await previous.readAsString(), '上一份坏文件');
      expect(await File(result.backupPath!).readAsString(), '{broken-again');
    });

    test('save 成功后不残留临时文件（#82）', () async {
      await store().save(<ManagedRoom>[_room()]);
      final List<String> names = directory
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .toList();
      expect(names, <String>[roomStoreFileName]);
    });

    test('写入中途失败时原文件保持不变（#82）', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}$roomStoreFileName');
      await store().save(<ManagedRoom>[_room()]);
      final String before = await file.readAsString();

      // 用同名目录占住临时文件路径，让「写临时文件」这一步必然失败。
      final Directory blocker = Directory(
        '${directory.path}${Platform.pathSeparator}.$roomStoreFileName.tmp',
      );
      await blocker.create();

      await expectLater(
        store().save(<ManagedRoom>[_room(webRid: '999')]),
        throwsA(isA<FileSystemException>()),
      );

      // 原子写的全部意义：写不进去就保持旧文件，绝不出现半截新文件。
      expect(await file.readAsString(), before, reason: '写入失败不能动原文件');
      expect((await store().load()).single.webRid, '735');
    });

    test('rename 失败时抛出并清理临时文件（#82）', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}$roomStoreFileName');
      final Directory blocker = Directory(file.path);
      await blocker.create();

      await expectLater(
        store().save(<ManagedRoom>[_room()]),
        throwsA(isA<FileSystemException>()),
      );

      expect(await blocker.exists(), isTrue, reason: '失败不能碰坏目标');
      final List<String> leftovers = directory
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .where((String name) => name.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty, reason: '半截临时文件要清掉，不能越积越多');
    });

    test('clear 连留存件一起删，不留下主播列表明文（#82）', () async {
      final File file = File('${directory.path}${Platform.pathSeparator}$roomStoreFileName');
      await file.writeAsString('{broken');
      final String? backupPath = (await store().loadResult()).backupPath;
      expect(backupPath, isNotNull);
      final File tmp = File('${directory.path}${Platform.pathSeparator}.$roomStoreFileName.tmp');
      await tmp.writeAsString('半截');

      await store().clear();

      expect(await file.exists(), isFalse);
      expect(await File(backupPath!).exists(), isFalse);
      expect(await tmp.exists(), isFalse);
    });
  });
}

ManagedRoom _room({
  String webRid = '735',
  String name = '',
  String owner = '',
  String title = '',
  String group = '',
  bool? living,
  int? lastRefreshedAt,
}) =>
    ManagedRoom(
      webRid: webRid,
      name: name,
      owner: owner,
      title: title,
      group: group,
      living: living,
      lastRefreshedAt: lastRefreshedAt,
      addedAt: 1700000000,
    );