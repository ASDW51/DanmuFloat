// 弹幕过滤偏好的本地持久化（prd F10 屏蔽 / F11 高亮 / F13 类型筛选，design.md 第 9 章）。
//
// 与主播列表、悬浮窗偏好分文件存：过滤是「展示口径」，损坏时回落到默认口径即可，
// 不应该连带影响用户资产（主播列表）。
//
// 目录解析做成可注入，单测里换成临时目录即可跑，不依赖 path_provider 插件通道。
import 'dart:convert';
import 'dart:io';

import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:path_provider/path_provider.dart';

/// 过滤偏好文件名。
const String filterStoreFileName = 'filter.json';

/// 解析过滤偏好；内容损坏或结构对不上时返回默认偏好。
FilterPrefs decodeFilterPrefs(String raw) {
  if (raw.trim().isEmpty) return const FilterPrefs();
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const FilterPrefs();
  }
  if (decoded is! Map) return const FilterPrefs();
  final Object? blockedKeywords = decoded['blockedKeywords'];
  final Object? blockedUsers = decoded['blockedUsers'];
  final Object? highlightKeywords = decoded['highlightKeywords'];
  final Object? visibleKinds = decoded['visibleKinds'];
  final Set<DanmakuKind> kinds = visibleKinds is List
      ? _parseKinds(visibleKinds)
      : defaultListKinds;
  return FilterPrefs(
    blockedKeywords: blockedKeywords is List
        ? normalizeKeywordList(List<Object?>.from(blockedKeywords))
        : const <String>[],
    blockedUsers: blockedUsers is List
        ? normalizeKeywordList(List<Object?>.from(blockedUsers))
        : const <String>[],
    highlightKeywords: highlightKeywords is List
        ? normalizeKeywordList(List<Object?>.from(highlightKeywords))
        : const <String>[],
    visibleKinds: kinds,
    // 老配置文件没有这个键，缺省按关闭处理，保持原有子串匹配行为。
    regexEnabled: decoded['regexEnabled'] == true,
  );
}

/// 解析类型名集合：忽略未登记的名字；全空时回落默认（只聊天类），
/// 免得一份坏数据把列表清空、用户以为功能坏了。
Set<DanmakuKind> _parseKinds(List<Object?> raw) {
  final Set<DanmakuKind> kinds = <DanmakuKind>{};
  for (final Object? item in raw) {
    if (item is! String) continue;
    for (final DanmakuKind kind in selectableListKinds) {
      if (kind.name == item) {
        kinds.add(kind);
        break;
      }
    }
  }
  return kinds.isEmpty ? defaultListKinds : Set<DanmakuKind>.unmodifiable(kinds);
}

/// 序列化过滤偏好。
String encodeFilterPrefs(FilterPrefs prefs) =>
    const JsonEncoder.withIndent('  ').convert(prefs.toJson());

class FilterStore {
  FilterStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = filterStoreFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// 读取过滤偏好；文件缺失或损坏时返回默认偏好，不让启动被脏文件卡住。
  Future<FilterPrefs> load() async {
    final File file = await _file();
    if (!await file.exists()) return const FilterPrefs();
    return decodeFilterPrefs(await file.readAsString());
  }

  /// 覆盖写入过滤偏好。
  Future<void> save(FilterPrefs prefs) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(encodeFilterPrefs(prefs), flush: true);
  }

  /// 删除偏好文件（「清除所有本地数据」用，见 prd F26）。
  Future<void> clear() async {
    final File file = await _file();
    if (await file.exists()) await file.delete();
  }
}
