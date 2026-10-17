// 首页列表的视图偏好（#139）：排序方式落盘，搜索词只在本次会话内有效。
//
// 单独一个文件而不是塞进 overlay.json：那是悬浮窗的样式偏好，首页列表顺序与它
// 没有任何关系；混在一起会让「清空悬浮窗样式」和「重置列表排序」互相牵连。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 视图偏好文件名。
const String homeViewPrefsFileName = 'home_view.json';

/// 排序方式：添加顺序（默认，即改造前的行为）。
const String homeSortAdded = 'added';

/// 直播中优先：`living == true` → `null`（未知）→ `false`，同组内再按名称。
const String homeSortLivingFirst = 'livingFirst';

/// 最近刷新：`lastRefreshedAt` 降序，从未刷新的排最后。
const String homeSortRecentlyRefreshed = 'recentlyRefreshed';

/// 全部合法取值，顺序即菜单展示顺序。
const List<String> homeSortModes = <String>[
  homeSortAdded,
  homeSortLivingFirst,
  homeSortRecentlyRefreshed,
];

/// 排序方式的中文名（菜单展示用）。
const Map<String, String> homeSortLabels = <String, String>{
  homeSortAdded: '添加顺序',
  homeSortLivingFirst: '直播中优先',
  homeSortRecentlyRefreshed: '最近刷新',
};

/// 解析排序方式：缺失 / 非字符串 / 不认识都回落「添加顺序」，绝不抛（#139）。
///
/// 旧版本没有这个文件、新版本也可能被降级回去读，所以这里只做单向兜底：
/// 认不出的取值一律当默认，不让一个手改过的文件把列表卡死。
String parseHomeSortMode(Object? raw) =>
    raw is String && homeSortModes.contains(raw) ? raw : homeSortAdded;

/// 首页视图偏好。
@immutable
class HomeViewPrefs {
  const HomeViewPrefs({this.sortMode = homeSortAdded});

  final String sortMode;

  HomeViewPrefs copyWith({String? sortMode}) =>
      HomeViewPrefs(sortMode: sortMode ?? this.sortMode);

  Map<String, Object?> toJson() => <String, Object?>{
    'sortMode': parseHomeSortMode(sortMode),
  };

  /// 解析：非对象或损坏一律回落默认值（列表能开出来比记住排序更要紧）。
  static HomeViewPrefs tryParse(Object? raw) {
    if (raw is! Map) return const HomeViewPrefs();
    return HomeViewPrefs(sortMode: parseHomeSortMode(raw['sortMode']));
  }
}

/// 首页视图偏好的落盘存储。
class HomeViewPrefsStore {
  HomeViewPrefsStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = homeViewPrefsFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// 读取；文件缺失、内容损坏或 IO 失败都回落默认值并记日志（#139）。
  Future<HomeViewPrefs> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return const HomeViewPrefs();
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return const HomeViewPrefs();
      return HomeViewPrefs.tryParse(jsonDecode(raw));
    } on Object catch (exception) {
      debugPrint('读取首页视图偏好失败，按添加顺序处理: $exception');
      return const HomeViewPrefs();
    }
  }

  Future<void> save(HomeViewPrefs prefs) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(prefs.toJson()), flush: true);
  }
}
