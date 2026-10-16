// 主播列表的本地持久化：JSON 文件写入 App 私有目录（design.md 2.1 / 2.3）。
//
// 目录解析做成可注入，单测里换成临时目录即可跑，不依赖 path_provider 插件通道。
//
// 写入一律走「同目录临时文件 + rename」的原子路径；读取把「没有数据」与「数据损坏」
// 分成两种结果（#82）：主播列表是用户唯一不可重建的资产，一份半截文件不能既被
// 当成空列表显示、又被下一次保存覆盖掉。
import 'dart:convert';
import 'dart:io';

import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/atomic_file_write.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 列表文件名，与 design.md 2.3 的「房间列表（JSON）」对应。
const String roomStoreFileName = 'rooms.json';

/// 损坏留存文件的名字前缀：`.bad` 与 `.bad-<毫秒>`（#82）。
const String roomStoreCorruptSuffix = '.bad';

/// 解析列表内容；**坏输入返回 null**，与「合法但列表为空」区分开（#82）。
///
/// 判损坏的情形：内容为空（截断写入最常见的形态）、JSON 解析失败、根节点不是
/// 对象、`rooms` 不是数组。数组里的单条坏记录仍然跳过——个别记录坏掉不该让整份
/// 列表读不出来。
List<ManagedRoom>? tryDecodeRooms(String raw) {
  if (raw.trim().isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final Object? rooms = decoded['rooms'];
  if (rooms is! List) return null;
  return rooms
      .map(ManagedRoom.tryParse)
      .whereType<ManagedRoom>()
      .toList(growable: false);
}

/// 宽松解析列表内容：坏数据一律按空列表处理。
///
/// 只用于备份分区（导入时单个分区坏掉退回默认值，不该让整份备份不可用，prd F26）；
/// 读本地 rooms.json 请用 [RoomStore.loadResult]，它要把损坏报给调用方。
List<ManagedRoom> decodeRooms(String raw) =>
    tryDecodeRooms(raw) ?? const <ManagedRoom>[];

/// 序列化主播列表，结构 `{"rooms": [...]}`。
String encodeRooms(List<ManagedRoom> rooms) => const JsonEncoder.withIndent('  ')
    .convert(<String, Object?>{
  'rooms': rooms.map((ManagedRoom room) => room.toJson()).toList(),
});

/// 一次读取的结果：主播列表 + 「是不是坏了」。
///
/// [corrupted] 与「列表为空」是两回事：前者必须提示用户并留住原始文件，后者是
/// 正常状态。#82 的根因正是把前者当成了后者，之后的保存再把空列表写回去。
class RoomLoadResult {
  const RoomLoadResult({
    required this.rooms,
    this.corrupted = false,
    this.backupPath,
  });

  /// 读到的主播；[corrupted] 为真时恒为空列表。
  final List<ManagedRoom> rooms;

  /// 文件存在但读不出内容。
  final bool corrupted;

  /// 损坏文件的留存路径（`rooms.json.bad`）；留存也失败时为 null，
  /// 此时原文件仍在原地，用户可按 [RoomStore.fileName] 自行找回。
  final String? backupPath;

  /// 文件不存在（首次启动）的正常结果。
  static const RoomLoadResult absent = RoomLoadResult(rooms: <ManagedRoom>[]);
}

class RoomStore {
  RoomStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = roomStoreFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// 读取全部主播；文件缺失或损坏都返回空列表（调用方多数只关心列表本身）。
  ///
  /// 需要区分「损坏」的调用方（首页要提示用户）改用 [loadResult]。
  Future<List<ManagedRoom>> load() async => (await loadResult()).rooms;

  /// 读取全部主播，并把「文件不存在」与「文件坏了」分开报告。
  ///
  /// 判定损坏时先把文件改名留存：留存后原始字节不再受任何一次保存影响，
  /// 用户至少还有手工恢复的机会（留在原地被下一次保存覆盖是 #82 里不可逆的一步）。
  Future<RoomLoadResult> loadResult() async {
    final File file = await _file();
    if (!await file.exists()) return RoomLoadResult.absent;
    String raw;
    try {
      raw = await file.readAsString();
    } on Object catch (exception) {
      // 连读都读不出来（权限 / IO 故障）：没碰过内容，留在原地即可。
      debugPrint('读取主播列表失败（${file.path}）：$exception');
      return const RoomLoadResult(rooms: <ManagedRoom>[], corrupted: true);
    }
    final List<ManagedRoom>? rooms = tryDecodeRooms(raw);
    if (rooms != null) return RoomLoadResult(rooms: rooms);
    final String? backupPath =
        await quarantineFile(file, suffix: roomStoreCorruptSuffix);
    debugPrint(
      backupPath == null
          ? '主播列表文件损坏，且留存失败；原文件仍在 ${file.path}'
          : '主播列表文件损坏，已留存为 $backupPath',
    );
    return RoomLoadResult(
      rooms: const <ManagedRoom>[],
      corrupted: true,
      backupPath: backupPath,
    );
  }

  /// 覆盖写入全部主播：同目录临时文件 + rename，中途失败不动原文件（#82）。
  Future<void> save(List<ManagedRoom> rooms) async {
    final File file = await _file();
    await writeFileAtomically(file, encodeRooms(rooms));
  }

  /// 删除列表文件，连同损坏留存件与写入中途留下的临时文件一起删
  /// （「清除所有本地数据」用，prd F26）。
  ///
  /// 留存件与临时件同样是主播列表明文，清除数据时漏下任何一个都等于没清干净。
  /// 删除失败原样抛出，由 #92 的调用方汇总成「哪几项没清掉」告知用户，
  /// 不在这里吞掉。
  Future<void> clear() async {
    final Directory directory = await _directoryResolver();
    if (!await directory.exists()) return;
    final String corruptPrefix = '$fileName$roomStoreCorruptSuffix';
    final String tmpName = '.$fileName.tmp';
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (name != fileName &&
          name != tmpName &&
          !name.startsWith(corruptPrefix)) {
        continue;
      }
      await entity.delete();
    }
  }
}
