// 本地存储的原子写文件（#82）。
//
// 覆盖式 `writeAsString` 是「先截断、后写入」：写到一半被系统杀进程 / 磁盘满 /
// 掉电，目标文件就只剩半截 JSON，而读侧无法把「半截」与「本来就没数据」区分开，
// 下一次保存还会把空列表写回去——用户唯一的核心资产就此无声消失。
// 同目录「写临时文件 → flush → rename」后，磁盘上要么是旧文件、要么是新文件，
// 不存在半截状态（POSIX 同目录 rename 是原子操作）。
import 'dart:io';

import 'package:flutter/foundation.dart';

/// [file] 同目录下的临时文件路径：点前缀 + `.tmp` 后缀，不会被当成数据文件读。
String tmpPathFor(File file) {
  final String path = file.path;
  final int separator = path.lastIndexOf(Platform.pathSeparator);
  // 没有分隔符时 path 就是纯文件名，前缀点号即可。
  if (separator < 0) return '.$path.tmp';
  return '${path.substring(0, separator + 1)}.${path.substring(separator + 1)}.tmp';
}

/// 原子写入 [content]：先写同目录临时文件并 flush，再 rename 覆盖目标。
///
/// 失败时原样抛出（调用方决定怎么告诉用户），并顺手清掉半截临时文件；
/// 清理本身的失败不覆盖原始异常。
Future<void> writeFileAtomically(File file, String content) async {
  await file.parent.create(recursive: true);
  final File tmp = File(tmpPathFor(file));
  try {
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  } on Object {
    try {
      if (await tmp.exists()) await tmp.delete();
    } on Object catch (cleanupError) {
      // 只记日志：临时文件名固定，下次写入会复用它，不会越积越多。
      debugPrint('清理写入临时文件失败（${tmp.path}）：$cleanupError');
    }
    rethrow;
  }
}

/// 把读不出来的文件改名留存，返回留存后的路径；留不住返回 null。
///
/// 留存是为了保住「最后一次写入的原始字节」：坏文件留在原地会被下一次保存覆盖，
/// 用户连手工抢救的机会都没有。已有同名留存件时带上时间戳，坏文件一份都不覆盖。
Future<String?> quarantineFile(File file, {String suffix = '.bad'}) async {
  final String path = file.path;
  String target = '$path$suffix';
  try {
    if (await File(target).exists()) {
      target = '$path$suffix-${DateTime.now().millisecondsSinceEpoch}';
    }
    await file.rename(target);
    return target;
  } on Object catch (exception) {
    debugPrint('留存损坏文件失败（$path）：$exception');
    return null;
  }
}
