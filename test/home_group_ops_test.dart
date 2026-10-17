// 分组改名的纯逻辑（#140）。
//
// 重命名、合并、解散在界面上是三个入口，在数据层是同一件事：把某一组全部成员的
// `group` 换成另一个值，并且**一次**返回整份新列表（调用方一次落盘）。这里逐条钉住
// 三种语义，以及「不该动的成员一个都不动」。
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/ui/home_group_ops.dart';
import 'package:flutter_test/flutter_test.dart';

ManagedRoom _room(String webRid, {String group = ''}) => ManagedRoom(
  webRid: webRid,
  name: '主播$webRid',
  addedAt: 1000,
  group: group,
);

void main() {
  group('regroupRooms（#140）', () {
    final List<ManagedRoom> rooms = <ManagedRoom>[
      _room('1', group: '游戏'),
      _room('2', group: '游戏'),
      _room('3', group: '音乐'),
      _room('4'),
    ];

    test('重命名：整组成员换成新名，其他分组与未分组原样不动', () {
      final List<ManagedRoom> next =
          regroupRooms(rooms, from: '游戏', to: '游戏区');

      expect(
        next.where((ManagedRoom room) => room.group == '游戏区').length,
        2,
        reason: '整组一起改，不能只改第一个',
      );
      expect(
        next.where((ManagedRoom room) => room.group == '游戏').isEmpty,
        isTrue,
        reason: '旧名不能残留，否则会出现两个分组并存',
      );
      expect(
        next.where((ManagedRoom room) => room.group == '音乐').length,
        1,
        reason: '别的分组不受影响',
      );
      expect(
        next.where((ManagedRoom room) => room.group.isEmpty).length,
        1,
        reason: '未分组的主播不该被顺手归进任何分组',
      );
    });

    test('合并：目标组名已存在时就是「并进去」，成员一个不少', () {
      final List<ManagedRoom> next =
          regroupRooms(rooms, from: '音乐', to: '游戏');

      expect(next.where((ManagedRoom room) => room.group == '游戏').length, 3);
      expect(
        next.where((ManagedRoom room) => room.group == '音乐').isEmpty,
        isTrue,
      );
      expect(next.length, rooms.length, reason: '合并不删直播间');
    });

    test('解散：目标为空串，成员移出分组但仍在列表里', () {
      final List<ManagedRoom> next = regroupRooms(rooms, from: '游戏', to: '');

      expect(next.length, rooms.length);
      expect(
        next.where((ManagedRoom room) => room.group.isEmpty).length,
        3,
        reason: '原 2 个组成员 + 原本未分组的 1 个',
      );
      expect(
        next.where((ManagedRoom room) => room.group == '游戏').isEmpty,
        isTrue,
      );
    });

    test('顺序保持不变：改名不该打乱用户熟悉的添加顺序', () {
      final List<ManagedRoom> next =
          regroupRooms(rooms, from: '游戏', to: '游戏区');
      expect(
        next.map((ManagedRoom room) => room.webRid).toList(),
        <String>['1', '2', '3', '4'],
      );
    });

    test('from 与 to 相同视为无操作，返回原列表实例', () {
      expect(
        identical(regroupRooms(rooms, from: '游戏', to: '游戏'), rooms),
        isTrue,
      );
    });

    test('不修改传入的列表', () {
      regroupRooms(rooms, from: '游戏', to: '游戏区');
      expect(rooms.first.group, '游戏', reason: '纯函数不该有副作用');
    });
  });

  group('groupCounts（#140）', () {
    test('按分组统计数量，跳过未分组', () {
      expect(
        groupCounts(<ManagedRoom>[
          _room('1', group: '游戏'),
          _room('2', group: '游戏'),
          _room('3', group: '音乐'),
          _room('4'),
        ]),
        <String, int>{'游戏': 2, '音乐': 1},
      );
    });

    test('空列表返回空表', () {
      expect(groupCounts(const <ManagedRoom>[]), isEmpty);
    });
  });
}
