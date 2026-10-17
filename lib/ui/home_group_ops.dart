// 分组改名的纯逻辑（#140）。
//
// 为什么单独抽出来：分组在数据层不是实体，而是各主播 `group` 字段的聚合。重命名、
// 合并、解散三个操作的差别**只在目标名**，改法完全一样——所以共用这一条路径，
// 一次返回整份新列表，由调用方一次落盘。
//
// 抽成纯函数还有一个现实原因：这三个操作在界面上要穿「长按标题 → 底部菜单 → 弹窗
// → 确认」四层，用 widget 测试驱动它既慢又脆；把「怎么改」钉在这里，「怎么点」只留
// 一条轻量用例。
import 'package:danmu_float/room/managed_room.dart';

/// 把 [from] 组的全部成员改到 [to]，返回新列表（不改原列表）。
///
/// [to] 为空串表示「移出分组」（解散）；[to] 等于某个已存在的分组名时，
/// 效果等价于合并——调用方不需要区分这两种情况。
///
/// 非该组成员原样保留，顺序不变：列表顺序是用户熟悉的添加顺序，改名不该打乱它。
List<ManagedRoom> regroupRooms(
  List<ManagedRoom> rooms, {
  required String from,
  required String to,
}) {
  if (from == to) return rooms;
  return <ManagedRoom>[
    for (final ManagedRoom room in rooms)
      if (room.group == from) room.copyWith(group: to) else room,
  ];
}

/// 每个分组的直播间数量（列表标题用），保持分组首次出现的顺序。
Map<String, int> groupCounts(List<ManagedRoom> rooms) {
  final Map<String, int> counts = <String, int>{};
  for (final ManagedRoom room in rooms) {
    if (room.group.isEmpty) continue;
    counts[room.group] = (counts[room.group] ?? 0) + 1;
  }
  return counts;
}
