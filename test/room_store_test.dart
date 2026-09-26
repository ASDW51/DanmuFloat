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

    test('空内容、非 JSON、结构不符一律按空列表处理', () {
      expect(decodeRooms(''), isEmpty);
      expect(decodeRooms('   '), isEmpty);
      expect(decodeRooms('{oops'), isEmpty);
      expect(decodeRooms('[]'), isEmpty);
      expect(decodeRooms('{"rooms":{}}'), isEmpty);
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
  });
}

ManagedRoom _room({
  String webRid = '735',
  String name = '',
  String owner = '',
  String title = '',
  String group = '',
  bool? living,
}) =>
    ManagedRoom(
      webRid: webRid,
      name: name,
      owner: owner,
      title: title,
      group: group,
      living: living,
      addedAt: 1700000000,
    );