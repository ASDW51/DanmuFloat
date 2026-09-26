// 主播列表的本地持久化：JSON 文件写入 App 私有目录（design.md 2.1 / 2.3）。
//
// 目录解析做成可注入，单测里换成临时目录即可跑，不依赖 path_provider 插件通道。
import 'dart:convert';
import 'dart:io';

import 'package:danmu_float/room/managed_room.dart';
import 'package:path_provider/path_provider.dart';

/// 列表文件名，与 design.md 2.3 的「房间列表（JSON）」对应。
const String roomStoreFileName = 'rooms.json';

/// 解析列表文件内容；坏数据一律按空列表处理，不让启动被一份脏文件卡住。
List<ManagedRoom> decodeRooms(String raw) {
  if (raw.trim().isEmpty) return const <ManagedRoom>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <ManagedRoom>[];
  }
  if (decoded is! Map) return const <ManagedRoom>[];
  final Object? rooms = decoded['rooms'];
  if (rooms is! List) return const <ManagedRoom>[];
  return rooms
      .map(ManagedRoom.tryParse)
      .whereType<ManagedRoom>()
      .toList(growable: false);
}

/// 序列化主播列表，结构 `{"rooms": [...]}`。
String encodeRooms(List<ManagedRoom> rooms) => const JsonEncoder.withIndent('  ')
    .convert(<String, Object?>{
  'rooms': rooms.map((ManagedRoom room) => room.toJson()).toList(),
});

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

  /// 读取全部主播；文件缺失或内容损坏时返回空列表。
  Future<List<ManagedRoom>> load() async {
    final File file = await _file();
    if (!await file.exists()) return const <ManagedRoom>[];
    return decodeRooms(await file.readAsString());
  }

  /// 覆盖写入全部主播。
  Future<void> save(List<ManagedRoom> rooms) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(encodeRooms(rooms), flush: true);
  }
}